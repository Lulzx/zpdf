//! PDF Page Tree Parser
//!
//! PDFs store pages in a tree structure for efficiency with large documents.
//! Structure: Catalog -> Pages (root) -> [Pages | Page] -> ...
//!
//! We flatten this to a simple array for O(1) page access.

const std = @import("std");
const parser = @import("parser.zig");
const xref_mod = @import("xref.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const XRefTable = xref_mod.XRefTable;

pub const Page = struct {
    /// Object reference for this page
    ref: ObjRef,
    /// Page dictionary
    dict: Object.Dict,
    /// Inherited MediaBox [x0, y0, x1, y1]
    media_box: [4]f64,
    /// Inherited CropBox (defaults to MediaBox)
    crop_box: [4]f64,
    /// Rotation in degrees (0, 90, 180, 270)
    rotation: i32,
    /// Inherited Resources dictionary
    resources: ?Object.Dict,
};

pub const PageTreeError = error{
    CatalogNotFound,
    PagesNotFound,
    InvalidPageTree,
    InvalidPageObject,
    CircularReference,
    OutOfMemory,
};

/// Resolve object reference using XRef table
pub fn resolveRef(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    ref: ObjRef,
    resolved_cache: *std.AutoHashMap(u32, Object),
) !Object {
    // Check cache first
    if (resolved_cache.get(ref.num)) |cached| {
        return cached;
    }

    const entry = xref.get(ref.num) orelse return Object{ .null = {} };

    switch (entry.entry_type) {
        .free => return Object{ .null = {} },
        .in_use => {
            if (entry.offset >= data.len) return Object{ .null = {} };

            var p = parser.Parser.initAt(allocator, data, entry.offset);
            const indirect = p.parseIndirectObject() catch return Object{ .null = {} };

            try resolved_cache.put(ref.num, indirect.obj);
            return indirect.obj;
        },
        .compressed => {
            // Object is inside an object stream
            return resolveCompressedObject(allocator, data, xref, entry, resolved_cache);
        },
    }
}

fn resolveCompressedObject(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    entry: xref_mod.XRefEntry,
    resolved_cache: *std.AutoHashMap(u32, Object),
) !Object {
    const objstm_num: u32 = @intCast(entry.offset);
    const index = entry.gen_or_index;

    // Get the object stream
    const objstm_entry = xref.get(objstm_num) orelse return Object{ .null = {} };
    if (objstm_entry.entry_type != .in_use) return Object{ .null = {} };

    var p = parser.Parser.initAt(allocator, data, objstm_entry.offset);
    const indirect = p.parseIndirectObject() catch return Object{ .null = {} };

    const stream = switch (indirect.obj) {
        .stream => |s| s,
        else => return Object{ .null = {} },
    };

    // Decompress stream
    const decompress = @import("decompress.zig");
    const decoded = decompress.decompressStream(
        allocator,
        stream.data,
        stream.dict.get("Filter"),
        stream.dict.get("DecodeParms"),
    ) catch return Object{ .null = {} };
    defer allocator.free(decoded);

    // Parse object stream header
    const n = stream.dict.getInt("N") orelse return Object{ .null = {} };
    const first = stream.dict.getInt("First") orelse return Object{ .null = {} };

    if (n <= 0 or first < 0) return Object{ .null = {} };

    // Parse offset pairs from header
    var header_parser = parser.Parser.init(allocator, decoded);
    var offsets: std.ArrayList(struct { num: u32, offset: u64 }) = .empty;
    defer offsets.deinit(allocator);

    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const obj = header_parser.parseObject() catch break;
        const num: u32 = switch (obj) {
            .integer => |int| @intCast(int),
            else => break,
        };

        const offset_obj = header_parser.parseObject() catch break;
        const offset: u64 = switch (offset_obj) {
            .integer => |int| @intCast(int),
            else => break,
        };

        try offsets.append(allocator, .{ .num = num, .offset = offset });
    }

    // Find our object
    if (index >= offsets.items.len) return Object{ .null = {} };

    const obj_offset: usize = @intCast(first);
    const rel_offset = offsets.items[index].offset;

    if (obj_offset + rel_offset >= decoded.len) return Object{ .null = {} };

    var obj_parser = parser.Parser.initAt(allocator, decoded, obj_offset + @as(usize, @intCast(rel_offset)));
    const result = obj_parser.parseObject() catch return Object{ .null = {} };

    try resolved_cache.put(offsets.items[index].num, result);
    return result;
}

/// Build page array from PDF document
pub fn buildPageTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
) PageTreeError![]Page {
    var resolved_cache = std.AutoHashMap(u32, Object).init(allocator);
    defer resolved_cache.deinit();

    // Get Root from trailer
    const root_ref = switch (xref.trailer.get("Root") orelse return PageTreeError.CatalogNotFound) {
        .reference => |r| r,
        else => return PageTreeError.CatalogNotFound,
    };

    // Resolve catalog
    const catalog = resolveRef(allocator, data, xref, root_ref, &resolved_cache) catch
        return PageTreeError.CatalogNotFound;

    const catalog_dict = switch (catalog) {
        .dict => |d| d,
        else => return PageTreeError.CatalogNotFound,
    };

    // Get Pages reference
    const pages_ref = switch (catalog_dict.get("Pages") orelse return PageTreeError.PagesNotFound) {
        .reference => |r| r,
        else => return PageTreeError.PagesNotFound,
    };

    // Build page list
    var pages: std.ArrayList(Page) = .empty;
    errdefer pages.deinit(allocator);

    // Track visited nodes to detect cycles
    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit();

    // Inherited attributes
    const default_mediabox = [4]f64{ 0, 0, 612, 792 }; // Letter size default

    try walkPageTree(
        allocator,
        data,
        xref,
        &resolved_cache,
        &visited,
        &pages,
        pages_ref,
        default_mediabox,
        null, // crop_box
        0, // rotation
        null, // resources
    );

    return pages.toOwnedSlice(allocator);
}

fn walkPageTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    visited: *std.AutoHashMap(u32, void),
    pages: *std.ArrayList(Page),
    node_ref: ObjRef,
    inherited_mediabox: [4]f64,
    inherited_cropbox: ?[4]f64,
    inherited_rotation: i32,
    inherited_resources: ?Object.Dict,
) PageTreeError!void {
    // Cycle detection
    if (visited.contains(node_ref.num)) {
        return PageTreeError.CircularReference;
    }
    visited.put(node_ref.num, {}) catch return PageTreeError.OutOfMemory;
    defer _ = visited.remove(node_ref.num);

    // Resolve node
    const node = resolveRef(allocator, data, xref, node_ref, cache) catch
        return PageTreeError.InvalidPageTree;

    const dict = switch (node) {
        .dict => |d| d,
        else => return PageTreeError.InvalidPageTree,
    };

    // Check Type
    const type_name = dict.getName("Type") orelse return PageTreeError.InvalidPageTree;

    // Get inherited attributes at this level
    const mediabox = extractBox(dict, "MediaBox") orelse inherited_mediabox;
    const cropbox = extractBox(dict, "CropBox") orelse inherited_cropbox;
    const rotation = @as(i32, @intCast(dict.getInt("Rotate") orelse inherited_rotation));
    const resources = dict.getDict("Resources") orelse inherited_resources;

    if (std.mem.eql(u8, type_name, "Pages")) {
        // Intermediate node - recurse into Kids
        const kids = dict.getArray("Kids") orelse return PageTreeError.InvalidPageTree;

        for (kids) |kid| {
            const kid_ref = switch (kid) {
                .reference => |r| r,
                else => continue,
            };

            try walkPageTree(
                allocator,
                data,
                xref,
                cache,
                visited,
                pages,
                kid_ref,
                mediabox,
                cropbox,
                rotation,
                resources,
            );
        }
    } else if (std.mem.eql(u8, type_name, "Page")) {
        // Leaf node - add to pages list
        pages.append(allocator, .{
            .ref = node_ref,
            .dict = dict,
            .media_box = mediabox,
            .crop_box = cropbox orelse mediabox,
            .rotation = rotation,
            .resources = resources,
        }) catch return PageTreeError.OutOfMemory;
    }
    // Ignore unknown types
}

fn extractBox(dict: Object.Dict, key: []const u8) ?[4]f64 {
    const array = dict.getArray(key) orelse return null;
    if (array.len != 4) return null;

    var box: [4]f64 = undefined;
    for (array, 0..) |elem, i| {
        box[i] = switch (elem) {
            .integer => |n| @floatFromInt(n),
            .real => |n| n,
            else => return null,
        };
    }
    return box;
}

/// Get page content stream(s)
pub fn getPageContents(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    page: Page,
    cache: *std.AutoHashMap(u32, Object),
) ![]const u8 {
    const contents = page.dict.get("Contents") orelse return &[_]u8{};

    return getStreamData(allocator, data, xref, contents, cache);
}

fn getStreamData(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    obj: Object,
    cache: *std.AutoHashMap(u32, Object),
) ![]const u8 {
    switch (obj) {
        .reference => |ref| {
            const resolved = try resolveRef(allocator, data, xref, ref, cache);
            return getStreamData(allocator, data, xref, resolved, cache);
        },
        .stream => |s| {
            const decompress = @import("decompress.zig");
            return decompress.decompressStream(
                allocator,
                s.data,
                s.dict.get("Filter"),
                s.dict.get("DecodeParms"),
            ) catch return s.data;
        },
        .array => |arr| {
            // Concatenate multiple content streams
            var result: std.ArrayList(u8) = .empty;
            errdefer result.deinit(allocator);

            for (arr) |item| {
                const stream_data = try getStreamData(allocator, data, xref, item, cache);
                defer if (stream_data.ptr != data.ptr) allocator.free(stream_data);

                try result.appendSlice(allocator, stream_data);
                try result.append(allocator, '\n'); // Separate streams
            }

            return result.toOwnedSlice(allocator);
        },
        else => return &[_]u8{},
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "extractBox" {
    const allocator = std.testing.allocator;

    // Create a simple dict with MediaBox
    var entries = [_]Object.Dict.Entry{
        .{
            .key = "MediaBox",
            .value = Object{
                .array = @constCast(&[_]Object{
                    .{ .integer = 0 },
                    .{ .integer = 0 },
                    .{ .integer = 612 },
                    .{ .integer = 792 },
                }),
            },
        },
    };

    const dict = Object.Dict{ .entries = &entries };

    const box = extractBox(dict, "MediaBox");
    try std.testing.expect(box != null);
    try std.testing.expectApproxEqRel(@as(f64, 0), box.?[0], 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 612), box.?[2], 0.001);

    _ = allocator;
}

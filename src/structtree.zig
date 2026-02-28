//! PDF Structure Tree Parser
//!
//! Parses the document's logical structure tree (StructTreeRoot) to enable
//! reading order extraction based on semantic tagging (PDF/UA, Tagged PDF).
//!
//! Structure tree elements define the logical reading order through:
//! - /S (structure type): Document, Part, Sect, P, H1-H6, Table, TR, TH, TD, etc.
//! - /K (kids): child elements or MCIDs (marked content IDs)
//! - /P (parent): parent element reference
//!
//! MCIDs link structure elements to content via BDC/EMC operators in content streams.

const std = @import("std");
const parser = @import("parser.zig");
const pagetree = @import("pagetree.zig");
const xref_mod = @import("xref.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const XRefTable = xref_mod.XRefTable;

/// A node in the structure tree
pub const StructElement = struct {
    /// Structure type (Document, Part, Sect, P, H1, Table, TR, TD, Figure, etc.)
    struct_type: []const u8,
    /// Title/alt text if present
    title: ?[]const u8 = null,
    alt_text: ?[]const u8 = null,
    /// Children: either more elements or MCIDs
    children: []const StructChild,
    /// Page reference (if this element is on a specific page)
    page_ref: ?ObjRef = null,
};

/// Child of a structure element - either another element or a marked content reference
pub const StructChild = union(enum) {
    /// Reference to another structure element
    element: *const StructElement,
    /// Marked Content ID on a page
    mcid: MarkedContentRef,
};

/// Reference to marked content in a page's content stream
pub const MarkedContentRef = struct {
    /// The MCID value
    mcid: i32,
    /// Page reference (if different from parent)
    page_ref: ?ObjRef = null,
    /// Content stream reference (for XObjects)
    stream_ref: ?ObjRef = null,
};

/// Parsed structure tree
pub const StructTree = struct {
    /// Root element (typically /Document)
    root: ?*const StructElement,
    /// All elements as individual heap allocations (stable pointers, used for cleanup)
    elements: []*StructElement,
    /// Allocator used
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StructTree) void {
        for (self.elements) |elem| {
            self.allocator.free(elem.children);
            self.allocator.destroy(elem);
        }
        self.allocator.free(self.elements);
    }

    /// Get reading order as a flat list of MCIDs per page
    /// Returns a map: page_index -> []MarkedContentRef in reading order
    pub fn getReadingOrder(self: *const StructTree, allocator: std.mem.Allocator) !std.AutoHashMap(usize, std.ArrayList(MarkedContentRef)) {
        var result = std.AutoHashMap(usize, std.ArrayList(MarkedContentRef)).init(allocator);
        errdefer {
            var it = result.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            result.deinit();
        }

        if (self.root) |root| {
            try collectMcidsInOrder(root, &result, allocator, null, 0);
        }

        return result;
    }
};

const MAX_STRUCT_DEPTH: u32 = 256;

fn collectMcidsInOrder(
    elem: *const StructElement,
    result: *std.AutoHashMap(usize, std.ArrayList(MarkedContentRef)),
    allocator: std.mem.Allocator,
    parent_page: ?ObjRef,
    depth: u32,
) !void {
    if (depth >= MAX_STRUCT_DEPTH) return;

    // Skip artifacts - they're not part of reading order
    if (std.mem.eql(u8, elem.struct_type, "Artifact")) return;

    const current_page = elem.page_ref orelse parent_page;

    for (elem.children) |child| {
        switch (child) {
            .element => |sub_elem| {
                try collectMcidsInOrder(sub_elem, result, allocator, current_page, depth + 1);
            },
            .mcid => |mcr| {
                const page_ref = mcr.page_ref orelse current_page;
                if (page_ref) |pr| {
                    // Use object number as page index proxy (will be resolved later)
                    const page_idx: usize = pr.num;

                    const gop = try result.getOrPut(page_idx);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .empty;
                    }
                    try gop.value_ptr.append(allocator, mcr);
                }
            },
        }
    }
}

/// Parse the structure tree from a PDF document
pub fn parseStructTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
) !StructTree {
    // Get Root from trailer
    const root_ref = switch (xref.trailer.get("Root") orelse return emptyTree(allocator)) {
        .reference => |r| r,
        else => return emptyTree(allocator),
    };

    // Resolve catalog
    const catalog = pagetree.resolveRef(allocator, data, xref, root_ref, cache) catch
        return emptyTree(allocator);

    const catalog_dict = switch (catalog) {
        .dict => |d| d,
        else => return emptyTree(allocator),
    };

    // Get StructTreeRoot
    const struct_tree_ref = switch (catalog_dict.get("StructTreeRoot") orelse return emptyTree(allocator)) {
        .reference => |r| r,
        else => return emptyTree(allocator),
    };

    const struct_tree_obj = pagetree.resolveRef(allocator, data, xref, struct_tree_ref, cache) catch
        return emptyTree(allocator);

    const struct_tree_dict = switch (struct_tree_obj) {
        .dict => |d| d,
        else => return emptyTree(allocator),
    };

    // Parse the tree starting from /K.
    // Elements are individually heap-allocated so that pointers stored in
    // StructChild.element remain stable even as the tracking list grows.
    var elements: std.ArrayList(*StructElement) = .empty;
    errdefer {
        for (elements.items) |elem| {
            allocator.free(elem.children);
            allocator.destroy(elem);
        }
        elements.deinit(allocator);
    }

    const root_kids = struct_tree_dict.get("K") orelse return emptyTree(allocator);
    const root_elem = try parseStructElement(allocator, data, xref, cache, root_kids, &elements);

    const elements_slice = try elements.toOwnedSlice(allocator);

    return StructTree{
        .root = root_elem,
        .elements = elements_slice,
        .allocator = allocator,
    };
}

fn emptyTree(allocator: std.mem.Allocator) StructTree {
    return StructTree{
        .root = null,
        .elements = &.{},
        .allocator = allocator,
    };
}

fn parseStructElement(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    obj: Object,
    elements: *std.ArrayList(*StructElement),
) !?*const StructElement {
    // Resolve if reference
    const resolved = switch (obj) {
        .reference => |r| pagetree.resolveRef(allocator, data, xref, r, cache) catch return null,
        else => obj,
    };

    switch (resolved) {
        .dict => |dict| {
            // Check if it's a StructElem
            const type_name = dict.getName("Type");
            if (type_name != null and !std.mem.eql(u8, type_name.?, "StructElem")) {
                // Could be MCR (Marked Content Reference)
                if (std.mem.eql(u8, type_name.?, "MCR")) {
                    return null; // Handled separately
                }
            }

            const struct_type = dict.getName("S") orelse "Unknown";
            const title = dict.getString("T");
            const alt = dict.getString("Alt");
            const page_ref = switch (dict.get("Pg") orelse Object{ .null = {} }) {
                .reference => |r| r,
                else => null,
            };

            // Parse children
            var children: std.ArrayList(StructChild) = .empty;
            errdefer children.deinit(allocator);

            if (dict.get("K")) |kids| {
                try parseKids(allocator, data, xref, cache, kids, &children, elements, page_ref);
            }

            const children_slice = try children.toOwnedSlice(allocator);

            // Heap-allocate the element so its address remains stable even as
            // the `elements` tracking list grows and its backing array is reallocated.
            const elem_ptr = try allocator.create(StructElement);
            elem_ptr.* = .{
                .struct_type = struct_type,
                .title = title,
                .alt_text = alt,
                .children = children_slice,
                .page_ref = page_ref,
            };
            try elements.append(allocator, elem_ptr);
            return elem_ptr;
        },
        .integer => |mcid| {
            // Direct MCID - shouldn't happen at top level but handle it
            _ = mcid;
            return null;
        },
        else => return null,
    }
}

fn parseKids(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    kids_obj: Object,
    children: *std.ArrayList(StructChild),
    elements: *std.ArrayList(*StructElement),
    parent_page: ?ObjRef,
) !void {
    switch (kids_obj) {
        .array => |arr| {
            for (arr) |item| {
                try parseKids(allocator, data, xref, cache, item, children, elements, parent_page);
            }
        },
        .integer => |mcid| {
            // Direct MCID
            try children.append(allocator, .{
                .mcid = .{
                    .mcid = @intCast(mcid),
                    .page_ref = parent_page,
                    .stream_ref = null,
                },
            });
        },
        .reference => |ref| {
            // Could be another StructElem or MCR
            const resolved = pagetree.resolveRef(allocator, data, xref, ref, cache) catch return;
            try parseKids(allocator, data, xref, cache, resolved, children, elements, parent_page);
        },
        .dict => |dict| {
            // Check if it's an MCR (Marked Content Reference)
            const type_name = dict.getName("Type");
            if (type_name != null and std.mem.eql(u8, type_name.?, "MCR")) {
                const mcid = dict.getInt("MCID") orelse return;
                const pg = switch (dict.get("Pg") orelse Object{ .null = {} }) {
                    .reference => |r| r,
                    else => parent_page,
                };
                const stm = switch (dict.get("Stm") orelse Object{ .null = {} }) {
                    .reference => |r| r,
                    else => null,
                };

                try children.append(allocator, .{
                    .mcid = .{
                        .mcid = @intCast(mcid),
                        .page_ref = pg,
                        .stream_ref = stm,
                    },
                });
            } else {
                // It's a StructElem
                const struct_type = dict.getName("S") orelse return;
                const title = dict.getString("T");
                const alt = dict.getString("Alt");
                const page_ref = switch (dict.get("Pg") orelse Object{ .null = {} }) {
                    .reference => |r| r,
                    else => parent_page,
                };

                var sub_children: std.ArrayList(StructChild) = .empty;
                errdefer sub_children.deinit(allocator);

                if (dict.get("K")) |sub_kids| {
                    try parseKids(allocator, data, xref, cache, sub_kids, &sub_children, elements, page_ref);
                }

                const sub_children_slice = try sub_children.toOwnedSlice(allocator);

                const elem_ptr = try allocator.create(StructElement);
                elem_ptr.* = .{
                    .struct_type = struct_type,
                    .title = title,
                    .alt_text = alt,
                    .children = sub_children_slice,
                    .page_ref = page_ref,
                };
                try elements.append(allocator, elem_ptr);
                try children.append(allocator, .{ .element = elem_ptr });
            }
        },
        else => {},
    }
}

/// Content with MCID tagging
pub const TaggedContent = struct {
    /// MCID of this content
    mcid: i32,
    /// Structure type (P, Span, H1, etc.)
    tag: []const u8,
    /// Text content
    text: []const u8,
    /// Position (if available)
    x: f64 = 0,
    y: f64 = 0,
};

/// Extract text from content stream with MCID tracking
pub const MarkedContentExtractor = struct {
    allocator: std.mem.Allocator,
    /// Collected content by MCID
    content_by_mcid: std.AutoHashMap(i32, std.ArrayList(u8)),
    /// Current MCID stack
    mcid_stack: std.ArrayList(i32),
    /// Current tag stack
    tag_stack: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) MarkedContentExtractor {
        return .{
            .allocator = allocator,
            .content_by_mcid = std.AutoHashMap(i32, std.ArrayList(u8)).init(allocator),
            .mcid_stack = .empty,
            .tag_stack = .empty,
        };
    }

    pub fn deinit(self: *MarkedContentExtractor) void {
        var it = self.content_by_mcid.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.content_by_mcid.deinit();
        self.mcid_stack.deinit(self.allocator);
        self.tag_stack.deinit(self.allocator);
    }

    /// Called when BDC (begin marked content) is encountered
    pub fn beginMarkedContent(self: *MarkedContentExtractor, tag: []const u8, mcid: ?i32) !void {
        try self.tag_stack.append(self.allocator, tag);
        if (mcid) |m| {
            try self.mcid_stack.append(self.allocator, m);
            // Ensure we have a buffer for this MCID
            const gop = try self.content_by_mcid.getOrPut(m);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
        } else {
            // No MCID, push sentinel
            try self.mcid_stack.append(self.allocator, -1);
        }
    }

    /// Called when EMC (end marked content) is encountered
    pub fn endMarkedContent(self: *MarkedContentExtractor) void {
        if (self.mcid_stack.items.len > 0) {
            _ = self.mcid_stack.pop();
        }
        if (self.tag_stack.items.len > 0) {
            _ = self.tag_stack.pop();
        }
    }

    /// Get current MCID (innermost)
    pub fn currentMcid(self: *const MarkedContentExtractor) ?i32 {
        // Find innermost non-sentinel MCID
        var i = self.mcid_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.mcid_stack.items[i] >= 0) {
                return self.mcid_stack.items[i];
            }
        }
        return null;
    }

    /// Add text to current MCID
    pub fn addText(self: *MarkedContentExtractor, text: []const u8) !void {
        if (self.currentMcid()) |mcid| {
            if (self.content_by_mcid.getPtr(mcid)) |buf| {
                try buf.appendSlice(self.allocator, text);
            }
        }
    }

    /// Get text for an MCID
    pub fn getTextForMcid(self: *const MarkedContentExtractor, mcid: i32) ?[]const u8 {
        if (self.content_by_mcid.get(mcid)) |buf| {
            return buf.items;
        }
        return null;
    }
};

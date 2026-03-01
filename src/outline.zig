//! PDF Document Outline (Bookmarks / Table of Contents)
//!
//! Parses the /Outlines tree from the document catalog.
//! The outline is a linked-list tree:
//!   Catalog → /Outlines → {/First, /Last, /Count}
//!   Each item: {/Title, /Dest or /A, /Next, /First, /Last, /Count, /Parent}

const std = @import("std");
const parser = @import("parser.zig");
const pagetree = @import("pagetree.zig");
const xref_mod = @import("xref.zig");
const root = @import("root.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const XRefTable = xref_mod.XRefTable;
const Page = pagetree.Page;

pub const OutlineItem = struct {
    title: []const u8,
    page: ?usize,
    level: u32,
};

/// Parse the document outline tree into a flat list of items.
pub fn parseOutline(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    pages: []const Page,
) ![]OutlineItem {
    // Get catalog
    const root_ref = switch (xref.trailer.get("Root") orelse return allocator.alloc(OutlineItem, 0)) {
        .reference => |r| r,
        else => return allocator.alloc(OutlineItem, 0),
    };
    const catalog = try pagetree.resolveRef(arena, data, xref, root_ref, cache);
    const catalog_dict = switch (catalog) {
        .dict => |d| d,
        else => return allocator.alloc(OutlineItem, 0),
    };

    // Get /Outlines dict
    const outlines_obj = catalog_dict.get("Outlines") orelse return allocator.alloc(OutlineItem, 0);
    const outlines_dict = switch (outlines_obj) {
        .dict => |d| d,
        .reference => |r| blk: {
            const obj = pagetree.resolveRef(arena, data, xref, r, cache) catch
                return allocator.alloc(OutlineItem, 0);
            break :blk switch (obj) {
                .dict => |d| d,
                else => return allocator.alloc(OutlineItem, 0),
            };
        },
        else => return allocator.alloc(OutlineItem, 0),
    };

    // Get /First child
    const first_obj = outlines_dict.get("First") orelse return allocator.alloc(OutlineItem, 0);

    var items: std.ArrayList(OutlineItem) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(@constCast(item.title));
        }
        items.deinit(allocator);
    }

    try walkOutlineChain(allocator, arena, data, xref, cache, pages, first_obj, 0, &items);

    return items.toOwnedSlice(allocator);
}

fn walkOutlineChain(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    pages: []const Page,
    first_obj: Object,
    level: u32,
    items: *std.ArrayList(OutlineItem),
) !void {
    // Safety: prevent infinite loops from circular references
    const MAX_ITEMS = 10_000;
    var current_obj = first_obj;

    while (items.items.len < MAX_ITEMS) {
        const item_dict = switch (current_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = pagetree.resolveRef(arena, data, xref, r, cache) catch return;
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return,
                };
            },
            else => return,
        };

        // Extract /Title (may be UTF-16BE encoded)
        const title_raw = item_dict.getString("Title") orelse "";
        const title = root.decodePdfString(allocator, title_raw) catch try allocator.dupe(u8, title_raw);
        errdefer allocator.free(title);

        // Resolve destination page
        var dest_page: ?usize = null;

        // Try /Dest first
        if (item_dict.get("Dest")) |dest_obj| {
            dest_page = resolveDestToPage(arena, data, xref, cache, pages, dest_obj);
        }

        // Try /A (action) if no /Dest
        if (dest_page == null) {
            if (item_dict.get("A")) |action_obj| {
                const action = switch (action_obj) {
                    .dict => |d| d,
                    .reference => |r| blk: {
                        const obj = pagetree.resolveRef(arena, data, xref, r, cache) catch null;
                        break :blk if (obj) |o| switch (o) {
                            .dict => |d| d,
                            else => null,
                        } else null;
                    },
                    else => null,
                };
                if (action) |act| {
                    const action_type = act.getName("S");
                    if (action_type) |s| {
                        if (std.mem.eql(u8, s, "GoTo")) {
                            if (act.get("D")) |d_obj| {
                                dest_page = resolveDestToPage(arena, data, xref, cache, pages, d_obj);
                            }
                        }
                    }
                }
            }
        }

        try items.append(allocator, .{
            .title = title,
            .page = dest_page,
            .level = level,
        });

        // Recurse into children
        if (item_dict.get("First")) |child_first| {
            try walkOutlineChain(allocator, arena, data, xref, cache, pages, child_first, level + 1, items);
        }

        // Follow /Next sibling
        const next_obj = item_dict.get("Next") orelse return;
        current_obj = next_obj;
    }
}

fn resolveDestToPage(
    arena: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    pages: []const Page,
    dest_obj: Object,
) ?usize {
    const arr = switch (dest_obj) {
        .array => |a| a,
        .reference => |r| blk: {
            const obj = pagetree.resolveRef(arena, data, xref, r, cache) catch return null;
            break :blk switch (obj) {
                .array => |a| a,
                else => return null,
            };
        },
        else => return null,
    };
    if (arr.len == 0) return null;

    // First element should be a page reference
    const page_ref = switch (arr[0]) {
        .reference => |r| r,
        else => return null,
    };

    for (pages, 0..) |p, idx| {
        if (p.ref.eql(page_ref)) return idx;
    }
    return null;
}

pub fn freeOutline(allocator: std.mem.Allocator, items: []OutlineItem) void {
    for (items) |item| {
        allocator.free(@constCast(item.title));
    }
    allocator.free(items);
}

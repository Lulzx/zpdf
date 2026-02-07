//! WebAssembly API for zpdf
//!
//! Provides a minimal API for browser-based PDF text extraction.
//! Uses memory-based loading since file I/O is not available in WASM.

const std = @import("std");
const zpdf = @import("root.zig");

// Use WASM page allocator
var wasm_allocator = std.heap.wasm_allocator;

// Document handle storage (simple slot-based system)
const MAX_DOCUMENTS = 16;
var documents: [MAX_DOCUMENTS]?*zpdf.Document = [_]?*zpdf.Document{null} ** MAX_DOCUMENTS;

fn findFreeSlot() ?usize {
    for (documents, 0..) |doc, i| {
        if (doc == null) return i;
    }
    return null;
}

// ============================================================================
// Memory Management (for JS to allocate buffers)
// ============================================================================

export fn wasm_alloc(len: usize) ?[*]u8 {
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, len: usize) void {
    wasm_allocator.free(ptr[0..len]);
}

// ============================================================================
// Document API
// ============================================================================

/// Open a PDF from memory buffer
/// Returns document handle (0-15) or -1 on error
export fn zpdf_open_memory(data: [*]const u8, len: usize) i32 {
    const slot = findFreeSlot() orelse return -1;
    const slice = data[0..len];

    const doc = zpdf.Document.openFromMemory(wasm_allocator, slice, zpdf.ErrorConfig.default()) catch return -1;
    documents[slot] = doc;
    return @intCast(slot);
}

/// Close a document and free resources
export fn zpdf_close(handle: i32) void {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        doc.close();
        documents[idx] = null;
    }
}

/// Get the number of pages in the document
export fn zpdf_page_count(handle: i32) i32 {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return -1;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        return @intCast(doc.pageCount());
    }
    return -1;
}

/// Extract text from a single page
/// Returns pointer to text buffer, sets out_len to buffer length
/// Caller must free with wasm_free
export fn zpdf_extract_page(handle: i32, page_num: i32, out_len: *usize) ?[*]u8 {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return null;
    if (page_num < 0) return null;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        var buffer: std.ArrayList(u8) = .empty;
        doc.extractText(@intCast(page_num), buffer.writer(wasm_allocator)) catch return null;

        // Handle empty buffer - toOwnedSlice returns undefined ptr for empty slice
        if (buffer.items.len == 0) {
            out_len.* = 0;
            return null;
        }

        const slice = buffer.toOwnedSlice(wasm_allocator) catch return null;
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

/// Extract text from all pages (sequential, single-threaded)
/// Returns pointer to text buffer, sets out_len to buffer length
/// Caller must free with wasm_free
export fn zpdf_extract_all(handle: i32, out_len: *usize) ?[*]u8 {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return null;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        var buffer: std.ArrayList(u8) = .empty;
        doc.extractAllText(buffer.writer(wasm_allocator)) catch return null;

        // Handle empty buffer - toOwnedSlice returns undefined ptr for empty slice
        if (buffer.items.len == 0) {
            out_len.* = 0;
            return null;
        }

        const slice = buffer.toOwnedSlice(wasm_allocator) catch return null;
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

/// Extract text from all pages as Markdown with semantic formatting
/// Returns pointer to Markdown text buffer, sets out_len to buffer length
/// Caller must free with wasm_free
export fn zpdf_extract_all_markdown(handle: i32, out_len: *usize) ?[*]u8 {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return null;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        const result = doc.extractAllMarkdown(wasm_allocator) catch return null;

        // extractAllMarkdown returns an allocated slice; treat zero-length as "no data"
        if (result.len == 0) {
            out_len.* = 0;
            return null;
        }

        out_len.* = result.len;
        return result.ptr;
    }
    return null;
}

/// Get page dimensions
/// Returns 0 on success, -1 on error
export fn zpdf_get_page_info(handle: i32, page_num: i32, width: *f64, height: *f64, rotation: *i32) i32 {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return -1;
    if (page_num < 0) return -1;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        const page_idx: usize = @intCast(page_num);
        if (page_idx >= doc.pages.items.len) return -1;

        const page = doc.pages.items[page_idx];
        width.* = page.media_box[2] - page.media_box[0];
        height.* = page.media_box[3] - page.media_box[1];
        rotation.* = page.rotation;
        return 0;
    }
    return -1;
}

// ============================================================================
// Text with bounds API
// ============================================================================

/// Text span structure for bounds extraction
pub const TextSpan = extern struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    text_ptr: [*]const u8,
    text_len: usize,
    font_size: f64,
};

/// Extract text with bounding boxes from a page
/// Returns pointer to TextSpan array, sets out_count to number of spans
/// Caller must free with zpdf_free_bounds
export fn zpdf_extract_bounds(handle: i32, page_num: i32, out_count: *usize) ?[*]TextSpan {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return null;
    if (page_num < 0) return null;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        const spans = doc.extractTextWithBounds(@intCast(page_num), wasm_allocator) catch return null;
        if (spans.len == 0) {
            out_count.* = 0;
            return null;
        }

        const c_spans = wasm_allocator.alloc(TextSpan, spans.len) catch return null;
        for (spans, 0..) |span, i| {
            c_spans[i] = .{
                .x0 = span.x0,
                .y0 = span.y0,
                .x1 = span.x1,
                .y1 = span.y1,
                .text_ptr = span.text.ptr,
                .text_len = span.text.len,
                .font_size = span.font_size,
            };
        }

        out_count.* = spans.len;
        return c_spans.ptr;
    }
    return null;
}

/// Free bounds array
export fn zpdf_free_bounds(ptr: ?[*]TextSpan, count: usize) void {
    if (ptr) |p| {
        wasm_allocator.free(p[0..count]);
    }
}

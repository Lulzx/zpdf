const std = @import("std");
const builtin = @import("builtin");
const zpdf = @import("root.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

pub const ZpdfDocument = opaque {};

var c_allocator: std.mem.Allocator = std.heap.page_allocator;

export fn zpdf_open(path_ptr: [*:0]const u8) ?*ZpdfDocument {
    const path = std.mem.span(path_ptr);
    const doc = zpdf.Document.open(c_allocator, path) catch return null;
    return @ptrCast(doc);
}

/// Open from caller-owned memory without copying.
/// The caller must ensure the memory remains valid until zpdf_close.
export fn zpdf_open_memory_unsafe(data: [*]const u8, len: usize) ?*ZpdfDocument {
    const slice = data[0..len];
    const doc = zpdf.Document.openFromMemoryUnsafe(c_allocator, slice, zpdf.ErrorConfig.default()) catch return null;
    return @ptrCast(doc);
}

/// Backward-compatible alias of zpdf_open_memory_unsafe.
export fn zpdf_open_memory(data: [*]const u8, len: usize) ?*ZpdfDocument {
    return zpdf_open_memory_unsafe(data, len);
}

export fn zpdf_close(handle: ?*ZpdfDocument) void {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        doc.close();
    }
}

export fn zpdf_page_count(handle: ?*ZpdfDocument) c_int {
    if (handle) |h| {
        const doc: *const zpdf.Document = @ptrCast(@alignCast(h));
        return @intCast(doc.pageCount());
    }
    return -1;
}

export fn zpdf_is_encrypted(handle: ?*ZpdfDocument) bool {
    if (handle) |h| {
        const doc: *const zpdf.Document = @ptrCast(@alignCast(h));
        return doc.isEncrypted();
    }
    return false;
}

export fn zpdf_extract_page(handle: ?*ZpdfDocument, page_num: c_int, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0) return null;

        var buffer: std.ArrayList(u8) = .empty;
        doc.extractText(@intCast(page_num), buffer.writer(c_allocator)) catch return null;

        const slice = buffer.toOwnedSlice(c_allocator) catch return null;
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

/// Extract text from all pages in reading order
/// Uses structure tree when available, falls back to geometric sorting
export fn zpdf_extract_all(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    return zpdf_extract_all_reading_order(handle, out_len);
}

/// Extract all pages in fast stream-order mode.
export fn zpdf_extract_all_fast(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const result = doc.extractAllTextFast(c_allocator) catch return null;
        out_len.* = result.len;
        return result.ptr;
    }
    return null;
}

/// Alias for zpdf_extract_all (parallel is deprecated, uses sequential)
export fn zpdf_extract_all_parallel(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    return zpdf_extract_all_reading_order(handle, out_len);
}

export fn zpdf_free_buffer(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| {
        c_allocator.free(p[0..len]);
    }
}

export fn zpdf_get_page_info(handle: ?*ZpdfDocument, page_num: c_int, width: *f64, height: *f64, rotation: *c_int) c_int {
    if (handle) |h| {
        const doc: *const zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0 or @as(usize, @intCast(page_num)) >= doc.pages.items.len) return -1;

        const page = doc.pages.items[@intCast(page_num)];
        width.* = page.media_box[2] - page.media_box[0];
        height.* = page.media_box[3] - page.media_box[1];
        rotation.* = page.rotation;
        return 0;
    }
    return -1;
}

pub const CTextSpan = extern struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    text: [*]const u8,
    text_len: usize,
    font_size: f64,
};

export fn zpdf_extract_bounds(handle: ?*ZpdfDocument, page_num: c_int, out_count: *usize) ?[*]CTextSpan {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0) return null;

        const spans = doc.extractTextWithBounds(@intCast(page_num), c_allocator) catch return null;
        defer zpdf.Document.freeTextSpans(c_allocator, spans);
        if (spans.len == 0) {
            out_count.* = 0;
            return null;
        }

        const c_spans = c_allocator.alloc(CTextSpan, spans.len) catch return null;
        var copied: usize = 0;
        errdefer {
            for (0..copied) |i| {
                const span = c_spans[i];
                if (span.text_len > 0) {
                    const ptr: [*]u8 = @ptrCast(@constCast(span.text));
                    c_allocator.free(ptr[0..span.text_len]);
                }
            }
            c_allocator.free(c_spans);
        }
        for (spans, 0..) |span, i| {
            const text_copy = c_allocator.dupe(u8, span.text) catch return null;
            c_spans[i] = .{
                .x0 = span.x0,
                .y0 = span.y0,
                .x1 = span.x1,
                .y1 = span.y1,
                .text = text_copy.ptr,
                .text_len = text_copy.len,
                .font_size = span.font_size,
            };
            copied = i + 1;
        }

        out_count.* = spans.len;
        return c_spans.ptr;
    }
    return null;
}

export fn zpdf_free_bounds(ptr: ?[*]CTextSpan, count: usize) void {
    if (ptr) |p| {
        for (0..count) |i| {
            const span = p[i];
            if (span.text_len > 0) {
                const text_ptr: [*]u8 = @ptrCast(@constCast(span.text));
                c_allocator.free(text_ptr[0..span.text_len]);
            }
        }
        c_allocator.free(p[0..count]);
    }
}

/// Extract text from a single page in reading order (visual order)
export fn zpdf_extract_page_reading_order(handle: ?*ZpdfDocument, page_num: c_int, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0 or @as(usize, @intCast(page_num)) >= doc.pages.items.len) return null;

        const page_idx: usize = @intCast(page_num);
        const page = doc.pages.items[page_idx];
        const page_width = page.media_box[2] - page.media_box[0];

        // Extract spans with bounds
        const spans = doc.extractTextWithBounds(page_idx, c_allocator) catch return null;
        if (spans.len == 0) {
            out_len.* = 0;
            return null;
        }
        defer zpdf.Document.freeTextSpans(c_allocator, spans);

        // Analyze layout for reading order
        var layout_result = zpdf.layout.analyzeLayout(c_allocator, spans, page_width) catch return null;
        defer layout_result.deinit();

        // Get text in reading order
        const text = layout_result.getTextInOrder(c_allocator) catch return null;
        out_len.* = text.len;
        return text.ptr;
    }
    return null;
}

/// Extract text from all pages in reading order (sequential)
/// Uses structure tree when available, falls back to geometric sorting
export fn zpdf_extract_all_reading_order(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const result = doc.extractAllTextStructured(c_allocator) catch return null;
        out_len.* = result.len;
        return result.ptr;
    }
    return null;
}

/// Alias for zpdf_extract_all_reading_order (parallel is deprecated)
export fn zpdf_extract_all_reading_order_parallel(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    return zpdf_extract_all_reading_order(handle, out_len);
}

/// Extract text from a single page as Markdown
export fn zpdf_extract_page_markdown(handle: ?*ZpdfDocument, page_num: c_int, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0 or @as(usize, @intCast(page_num)) >= doc.pages.items.len) return null;

        const result = doc.extractMarkdown(@intCast(page_num), c_allocator) catch return null;
        out_len.* = result.len;
        return result.ptr;
    }
    return null;
}

/// Extract text from all pages as Markdown
export fn zpdf_extract_all_markdown(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const result = doc.extractAllMarkdown(c_allocator) catch return null;

        // extractAllMarkdown returns an allocated slice; treat zero-length as "no data"
        if (result.len == 0) {
            c_allocator.free(result);
            out_len.* = 0;
            return null;
        }

        out_len.* = result.len;
        return result.ptr;
    }
    return null;
}

// =========================================================================
// Document Metadata
// =========================================================================

pub const CMetadata = extern struct {
    title: [*]const u8,
    title_len: usize,
    author: [*]const u8,
    author_len: usize,
    subject: [*]const u8,
    subject_len: usize,
    keywords: [*]const u8,
    keywords_len: usize,
    creator: [*]const u8,
    creator_len: usize,
    producer: [*]const u8,
    producer_len: usize,
    creation_date: [*]const u8,
    creation_date_len: usize,
    mod_date: [*]const u8,
    mod_date_len: usize,
};

fn sliceToPtr(s: ?[]const u8) struct { ptr: [*]const u8, len: usize } {
    if (s) |slice| {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }
    return .{ .ptr = "".ptr, .len = 0 };
}

export fn zpdf_get_metadata(handle: ?*ZpdfDocument, out: *CMetadata) c_int {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const meta = doc.metadata();
        const title = sliceToPtr(meta.title);
        const author = sliceToPtr(meta.author);
        const subject = sliceToPtr(meta.subject);
        const keywords = sliceToPtr(meta.keywords);
        const creator = sliceToPtr(meta.creator);
        const producer = sliceToPtr(meta.producer);
        const creation_date = sliceToPtr(meta.creation_date);
        const mod_date = sliceToPtr(meta.mod_date);
        out.* = .{
            .title = title.ptr,
            .title_len = title.len,
            .author = author.ptr,
            .author_len = author.len,
            .subject = subject.ptr,
            .subject_len = subject.len,
            .keywords = keywords.ptr,
            .keywords_len = keywords.len,
            .creator = creator.ptr,
            .creator_len = creator.len,
            .producer = producer.ptr,
            .producer_len = producer.len,
            .creation_date = creation_date.ptr,
            .creation_date_len = creation_date.len,
            .mod_date = mod_date.ptr,
            .mod_date_len = mod_date.len,
        };
        return 0;
    }
    return -1;
}

// =========================================================================
// Document Outline
// =========================================================================

pub const COutlineItem = extern struct {
    title: [*]const u8,
    title_len: usize,
    page: c_int, // -1 if unresolved
    level: c_int,
};

export fn zpdf_get_outline(handle: ?*ZpdfDocument, out: *?[*]COutlineItem, count: *usize) c_int {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const items = doc.getOutline(c_allocator) catch return -1;

        if (items.len == 0) {
            c_allocator.free(items);
            out.* = null;
            count.* = 0;
            return 0;
        }

        const c_items = c_allocator.alloc(COutlineItem, items.len) catch {
            zpdf.outline.freeOutline(c_allocator, items);
            return -1;
        };

        for (items, 0..) |item, i| {
            c_items[i] = .{
                .title = item.title.ptr,
                .title_len = item.title.len,
                .page = if (item.page) |p| @intCast(p) else -1,
                .level = @intCast(item.level),
            };
        }

        // Store the original items for freeing later - we need the title allocations
        // We embed metadata in a separate allocation
        out.* = c_items.ptr;
        count.* = items.len;

        // Free the zig-level slice (but NOT the titles - they're owned by c_items now)
        c_allocator.free(items);

        return 0;
    }
    return -1;
}

export fn zpdf_free_outline(ptr: ?[*]COutlineItem, count: usize) void {
    if (ptr) |p| {
        for (0..count) |i| {
            const item = p[i];
            if (item.title_len > 0) {
                const title_ptr: [*]u8 = @ptrCast(@constCast(item.title));
                c_allocator.free(title_ptr[0..item.title_len]);
            }
        }
        c_allocator.free(p[0..count]);
    }
}

// =========================================================================
// Text Search
// =========================================================================

pub const CSearchResult = extern struct {
    page: c_int,
    offset: usize,
    context: [*]const u8,
    context_len: usize,
};

export fn zpdf_search(handle: ?*ZpdfDocument, query: [*]const u8, query_len: usize, out: *?[*]CSearchResult, count: *usize) c_int {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const results = doc.search(c_allocator, query[0..query_len]) catch return -1;

        if (results.len == 0) {
            c_allocator.free(results);
            out.* = null;
            count.* = 0;
            return 0;
        }

        const c_results = c_allocator.alloc(CSearchResult, results.len) catch {
            zpdf.Document.freeSearchResults(c_allocator, results);
            return -1;
        };

        for (results, 0..) |r, i| {
            c_results[i] = .{
                .page = @intCast(r.page),
                .offset = r.offset,
                .context = r.context.ptr,
                .context_len = r.context.len,
            };
        }

        out.* = c_results.ptr;
        count.* = results.len;

        // Free the zig-level slice but not the context strings
        c_allocator.free(results);

        return 0;
    }
    return -1;
}

export fn zpdf_free_search_results(ptr: ?[*]CSearchResult, count: usize) void {
    if (ptr) |p| {
        for (0..count) |i| {
            const r = p[i];
            if (r.context_len > 0) {
                const ctx_ptr: [*]u8 = @ptrCast(@constCast(r.context));
                c_allocator.free(ctx_ptr[0..r.context_len]);
            }
        }
        c_allocator.free(p[0..count]);
    }
}

// =========================================================================
// Page Label
// =========================================================================

export fn zpdf_get_page_label(handle: ?*ZpdfDocument, page_num: c_int, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0) return null;
        const label = doc.getPageLabel(c_allocator, @intCast(page_num)) orelse return null;
        out_len.* = label.len;
        return label.ptr;
    }
    return null;
}

// =========================================================================
// Links
// =========================================================================

pub const CLink = extern struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    uri: [*]const u8,
    uri_len: usize,
    dest_page: c_int, // -1 if none
};

export fn zpdf_get_page_links(handle: ?*ZpdfDocument, page_num: c_int, out: *?[*]CLink, count: *usize) c_int {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0) return -1;

        const links = doc.getPageLinks(@intCast(page_num), c_allocator) catch return -1;

        if (links.len == 0) {
            c_allocator.free(links);
            out.* = null;
            count.* = 0;
            return 0;
        }

        const c_links = c_allocator.alloc(CLink, links.len) catch {
            zpdf.Document.freeLinks(c_allocator, links);
            return -1;
        };

        for (links, 0..) |link, i| {
            const uri_ptr: [*]const u8 = if (link.uri) |u| u.ptr else "";
            const uri_len: usize = if (link.uri) |u| u.len else 0;
            c_links[i] = .{
                .x0 = link.rect[0],
                .y0 = link.rect[1],
                .x1 = link.rect[2],
                .y1 = link.rect[3],
                .uri = uri_ptr,
                .uri_len = uri_len,
                .dest_page = if (link.dest_page) |p| @intCast(p) else -1,
            };
        }

        out.* = c_links.ptr;
        count.* = links.len;
        c_allocator.free(links);
        return 0;
    }
    return -1;
}

export fn zpdf_free_links(ptr: ?[*]CLink, count: usize) void {
    if (ptr) |p| {
        for (0..count) |i| {
            const link = p[i];
            if (link.uri_len > 0) {
                const uri_ptr: [*]u8 = @ptrCast(@constCast(link.uri));
                c_allocator.free(uri_ptr[0..link.uri_len]);
            }
        }
        c_allocator.free(p[0..count]);
    }
}

// =========================================================================
// Images
// =========================================================================

pub const CImageInfo = extern struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    width: u32,
    height: u32,
};

export fn zpdf_get_page_images(handle: ?*ZpdfDocument, page_num: c_int, out: *?[*]CImageInfo, count: *usize) c_int {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0) return -1;

        const images = doc.getPageImages(@intCast(page_num), c_allocator) catch return -1;

        if (images.len == 0) {
            c_allocator.free(images);
            out.* = null;
            count.* = 0;
            return 0;
        }

        const c_images = c_allocator.alloc(CImageInfo, images.len) catch {
            c_allocator.free(images);
            return -1;
        };

        for (images, 0..) |img, i| {
            c_images[i] = .{
                .x0 = img.rect[0],
                .y0 = img.rect[1],
                .x1 = img.rect[2],
                .y1 = img.rect[3],
                .width = img.width,
                .height = img.height,
            };
        }

        out.* = c_images.ptr;
        count.* = images.len;
        c_allocator.free(images);
        return 0;
    }
    return -1;
}

export fn zpdf_free_images(ptr: ?[*]CImageInfo, count: usize) void {
    if (ptr) |p| {
        c_allocator.free(p[0..count]);
    }
}

// =========================================================================
// Form Fields
// =========================================================================

pub const CFormField = extern struct {
    name: [*]const u8,
    name_len: usize,
    value: [*]const u8,
    value_len: usize,
    field_type: c_int, // 0=text, 1=button, 2=choice, 3=signature, 4=unknown
    has_rect: bool,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

export fn zpdf_get_form_fields(handle: ?*ZpdfDocument, out: *?[*]CFormField, count: *usize) c_int {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const fields = doc.getFormFields(c_allocator) catch return -1;

        if (fields.len == 0) {
            c_allocator.free(fields);
            out.* = null;
            count.* = 0;
            return 0;
        }

        const c_fields = c_allocator.alloc(CFormField, fields.len) catch {
            zpdf.Document.freeFormFields(c_allocator, fields);
            return -1;
        };

        for (fields, 0..) |f, i| {
            const val_ptr: [*]const u8 = if (f.value) |v| v.ptr else "";
            const val_len: usize = if (f.value) |v| v.len else 0;
            c_fields[i] = .{
                .name = f.name.ptr,
                .name_len = f.name.len,
                .value = val_ptr,
                .value_len = val_len,
                .field_type = switch (f.field_type) {
                    .text => 0,
                    .button => 1,
                    .choice => 2,
                    .signature => 3,
                    .unknown => 4,
                },
                .has_rect = f.rect != null,
                .x0 = if (f.rect) |r| r[0] else 0,
                .y0 = if (f.rect) |r| r[1] else 0,
                .x1 = if (f.rect) |r| r[2] else 0,
                .y1 = if (f.rect) |r| r[3] else 0,
            };
        }

        out.* = c_fields.ptr;
        count.* = fields.len;
        c_allocator.free(fields);
        return 0;
    }
    return -1;
}

export fn zpdf_free_form_fields(ptr: ?[*]CFormField, count: usize) void {
    if (ptr) |p| {
        for (0..count) |i| {
            const f = p[i];
            if (f.name_len > 0) {
                const name_ptr: [*]u8 = @ptrCast(@constCast(f.name));
                c_allocator.free(name_ptr[0..f.name_len]);
            }
            if (f.value_len > 0) {
                const val_ptr: [*]u8 = @ptrCast(@constCast(f.value));
                c_allocator.free(val_ptr[0..f.value_len]);
            }
        }
        c_allocator.free(p[0..count]);
    }
}

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

export fn zpdf_open_memory(data: [*]const u8, len: usize) ?*ZpdfDocument {
    const slice = data[0..len];
    const doc = zpdf.Document.openFromMemory(c_allocator, slice, zpdf.ErrorConfig.default()) catch return null;
    return @ptrCast(doc);
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

export fn zpdf_extract_all(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));

        var buffer: std.ArrayList(u8) = .empty;
        doc.extractAllText(buffer.writer(c_allocator)) catch return null;

        const slice = buffer.toOwnedSlice(c_allocator) catch return null;
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

export fn zpdf_extract_all_parallel(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const result = doc.extractAllTextParallel(c_allocator) catch return null;
        out_len.* = result.len;
        return result.ptr;
    }
    return null;
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
        if (spans.len == 0) {
            out_count.* = 0;
            return null;
        }

        const c_spans = c_allocator.alloc(CTextSpan, spans.len) catch return null;
        for (spans, 0..) |span, i| {
            c_spans[i] = .{
                .x0 = span.x0,
                .y0 = span.y0,
                .x1 = span.x1,
                .y1 = span.y1,
                .text = span.text.ptr,
                .text_len = span.text.len,
                .font_size = span.font_size,
            };
        }

        out_count.* = spans.len;
        return c_spans.ptr;
    }
    return null;
}

export fn zpdf_free_bounds(ptr: ?[*]CTextSpan, count: usize) void {
    if (ptr) |p| {
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
        defer c_allocator.free(spans);

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
export fn zpdf_extract_all_reading_order(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const num_pages = doc.pages.items.len;
        if (num_pages == 0) {
            out_len.* = 0;
            return null;
        }

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(c_allocator);

        for (0..num_pages) |page_idx| {
            if (page_idx > 0) {
                result.append(c_allocator, '\x0c') catch continue; // Form feed between pages
            }

            const page = doc.pages.items[page_idx];
            const page_width = page.media_box[2] - page.media_box[0];

            const spans = doc.extractTextWithBounds(page_idx, c_allocator) catch continue;
            if (spans.len == 0) continue;
            defer c_allocator.free(spans);

            var layout_result = zpdf.layout.analyzeLayout(c_allocator, spans, page_width) catch continue;
            defer layout_result.deinit();

            const text = layout_result.getTextInOrder(c_allocator) catch continue;
            defer c_allocator.free(text);

            result.appendSlice(c_allocator, text) catch continue;
        }

        const slice = result.toOwnedSlice(c_allocator) catch return null;
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

/// Extract text from all pages in reading order (parallel)
/// On WASM, falls back to sequential extraction since threads are not available.
export fn zpdf_extract_all_reading_order_parallel(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    if (comptime is_wasm) {
        // WASM doesn't support threads, fall back to sequential
        return zpdf_extract_all_reading_order(handle, out_len);
    }

    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const num_pages = doc.pages.items.len;
        if (num_pages == 0) {
            out_len.* = 0;
            return null;
        }

        // Allocate result buffers for each page
        const results = c_allocator.alloc([]u8, num_pages) catch return null;
        defer c_allocator.free(results);
        @memset(results, &[_]u8{});

        const Thread = std.Thread;
        const cpu_count = Thread.getCpuCount() catch 4;
        const num_threads: usize = @min(num_pages, @min(cpu_count, 8));

        const Context = struct {
            doc: *zpdf.Document,
            results: [][]u8,
        };

        const ctx = Context{
            .doc = doc,
            .results = results,
        };

        const worker = struct {
            fn run(c: Context, start: usize, end: usize) void {
                // Thread-local arena for all allocations
                var arena = std.heap.ArenaAllocator.init(c_allocator);
                defer arena.deinit();
                const thread_alloc = arena.allocator();

                // Thread-local object cache (required for thread safety)
                var local_cache = std.AutoHashMap(u32, zpdf.Object).init(thread_alloc);
                defer local_cache.deinit();

                for (start..end) |page_idx| {
                    const page = c.doc.pages.items[page_idx];
                    const page_width = page.media_box[2] - page.media_box[0];

                    // Get content stream with thread-local cache
                    const content = zpdf.pagetree.getPageContents(
                        thread_alloc,
                        c.doc.data,
                        &c.doc.xref_table,
                        page,
                        &local_cache,
                    ) catch continue;

                    if (content.len == 0) continue;

                    // Extract spans with bounds
                    var collector = zpdf.interpreter.SpanCollector.init(c_allocator);
                    extractTextFromContentWithBoundsLocal(content, &collector) catch continue;
                    collector.flush() catch continue;

                    const spans = collector.spans.toOwnedSlice(c_allocator) catch continue;
                    if (spans.len == 0) continue;
                    defer c_allocator.free(spans);

                    // Analyze layout
                    var layout_result = zpdf.layout.analyzeLayout(c_allocator, spans, page_width) catch continue;
                    defer layout_result.deinit();

                    const text = layout_result.getTextInOrder(c_allocator) catch continue;
                    c.results[page_idx] = text;
                }
            }
        }.run;

        // Spawn threads
        var threads: [8]?Thread = [_]?Thread{null} ** 8;
        const pages_per_thread = (num_pages + num_threads - 1) / num_threads;

        for (0..num_threads) |i| {
            const start = i * pages_per_thread;
            const end = @min(start + pages_per_thread, num_pages);
            if (start < end) {
                threads[i] = Thread.spawn(.{}, worker, .{ ctx, start, end }) catch null;
            }
        }

        // Wait for all threads
        for (&threads) |*t| {
            if (t.*) |thread| thread.join();
        }

        // Calculate total size
        var total_size: usize = 0;
        var non_empty_count: usize = 0;
        for (results) |r| {
            if (r.len > 0) {
                total_size += r.len;
                non_empty_count += 1;
            }
        }
        if (non_empty_count > 1) {
            total_size += non_empty_count - 1; // separators
        }

        if (total_size == 0) {
            out_len.* = 0;
            return null;
        }

        var output = c_allocator.alloc(u8, total_size) catch return null;
        var pos: usize = 0;
        var first_written = false;
        for (results) |r| {
            if (r.len > 0) {
                if (first_written) {
                    output[pos] = '\x0c';
                    pos += 1;
                }
                @memcpy(output[pos..][0..r.len], r);
                pos += r.len;
                c_allocator.free(r);
                first_written = true;
            }
        }

        out_len.* = pos;
        return output.ptr;
    }
    return null;
}

/// Local version of content extraction with bounds (for thread safety)
fn extractTextFromContentWithBoundsLocal(content: []const u8, collector: *zpdf.interpreter.SpanCollector) !void {
    var lexer = zpdf.interpreter.ContentLexer.init(collector.allocator, content);
    var operands: [64]zpdf.interpreter.Operand = undefined;
    var operand_count: usize = 0;

    var current_x: f64 = 0;
    var current_y: f64 = 0;
    var font_size: f64 = 12;

    while (try lexer.next()) |token| {
        switch (token) {
            .number => |n| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .number = n };
                    operand_count += 1;
                }
            },
            .string => |s| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .string = s };
                    operand_count += 1;
                }
            },
            .hex_string => |s| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .hex_string = s };
                    operand_count += 1;
                }
            },
            .name => |n| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .name = n };
                    operand_count += 1;
                }
            },
            .array => |arr| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .array = arr };
                    operand_count += 1;
                }
            },
            .operator => |op| {
                if (op.len > 0) switch (op[0]) {
                    'T' => if (op.len == 2) switch (op[1]) {
                        'f' => if (operand_count >= 2) {
                            font_size = operands[1].number;
                            collector.setFontSize(font_size);
                        },
                        'd', 'D' => if (operand_count >= 2) {
                            current_x += operands[0].number;
                            current_y += operands[1].number;
                            try collector.flush();
                            collector.setPosition(current_x, current_y);
                        },
                        'm' => if (operand_count >= 6) {
                            current_x = operands[4].number;
                            current_y = operands[5].number;
                            try collector.flush();
                            collector.setPosition(current_x, current_y);
                        },
                        '*' => {
                            try collector.flush();
                        },
                        'j' => if (operand_count >= 1) {
                            try writeTextOperandLocal(operands[0], collector);
                        },
                        'J' => if (operand_count >= 1) {
                            try writeTJArrayWithBoundsLocal(operands[0], collector);
                        },
                        else => {},
                    },
                    '\'' => if (operand_count >= 1) {
                        try collector.flush();
                        try writeTextOperandLocal(operands[0], collector);
                    },
                    '"' => if (operand_count >= 3) {
                        try collector.flush();
                        try writeTextOperandLocal(operands[2], collector);
                    },
                    else => {},
                };
                operand_count = 0;
            },
        }
    }
}

fn writeTextOperandLocal(operand: zpdf.interpreter.Operand, collector: *zpdf.interpreter.SpanCollector) !void {
    const data = switch (operand) {
        .string => |s| s,
        .hex_string => |s| s,
        else => return,
    };

    for (data) |byte| {
        if (byte >= 32 and byte < 127) {
            try collector.writeByte(byte);
        } else if (byte == 0) {
            // CID separator
        } else {
            const codepoint = zpdf.encoding.win_ansi_encoding[byte];
            if (codepoint != 0 and codepoint < 128) {
                try collector.writeByte(@truncate(codepoint));
            } else if (codepoint != 0) {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch 1;
                try collector.writeAll(buf[0..len]);
            }
        }
    }
}

fn writeTJArrayWithBoundsLocal(operand: zpdf.interpreter.Operand, collector: *zpdf.interpreter.SpanCollector) !void {
    const arr = switch (operand) {
        .array => |a| a,
        else => return,
    };

    for (arr) |item| {
        switch (item) {
            .string, .hex_string => try writeTextOperandLocal(item, collector),
            .number => |n| {
                if (n < -100) {
                    try collector.flush();
                }
            },
            else => {},
        }
    }
}

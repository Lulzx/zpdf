//! ZPDF CLI - Text extraction tool
//!
//! Usage: zpdf extract [options] input.pdf [pages]
//!        zpdf info input.pdf
//!        zpdf bench input.pdf
//!
//! Designed to be a drop-in comparison with `mutool draw -F txt`

const std = @import("std");
const zpdf = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "extract")) {
        try runExtract(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "info")) {
        try runInfo(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "search")) {
        try runSearch(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "bench")) {
        try runBench(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
    }
}

fn printUsage() !void {
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const stdout = &bw.interface;
    defer stdout.flush() catch {};
    try stdout.writeAll(
        \\ZPDF - Zero-copy PDF text extraction
        \\
        \\Usage: zpdf <command> [options] <input.pdf> [pages]
        \\
        \\Commands:
        \\  extract     Extract text from PDF (like mutool draw -F txt)
        \\  info        Show PDF structure information (metadata, outline, etc.)
        \\  search      Search for text across all pages
        \\  bench       Benchmark extraction performance
        \\  help        Show this help
        \\
        \\Extract options:
        \\  -o FILE         Output to file (default: stdout)
        \\  -p PAGES        Page range (e.g., "1-10" or "1,3,5")
        \\  -f, --format    Output format: text, json, or markdown (default: text)
        \\  -m, --markdown  Shortcut for --format markdown
        \\  --sequential    Disable parallel extraction
        \\  --reading-order Use visual reading order (experimental, slower)
        \\  --strict        Fail on any parse error
        \\  --permissive    Continue past all errors
        \\  --json          Shortcut for --format json
        \\
        \\Examples:
        \\  zpdf extract document.pdf              # All pages to stdout
        \\  zpdf extract -o out.txt document.pdf   # All pages to file
        \\  zpdf extract -p 1-10 document.pdf      # First 10 pages
        \\  zpdf extract --markdown doc.pdf        # Export as Markdown
        \\  zpdf extract -f md -o out.md doc.pdf   # Markdown to file
        \\  zpdf extract --reading-order doc.pdf   # Visual reading order
        \\  zpdf search "revenue" document.pdf      # Search across all pages
        \\  zpdf bench document.pdf                # Benchmark vs mutool
        \\
    );
}

const ExtractionMode = enum {
    normal, // Default: use structure tree for reading order (falls back to stream order)
    visual, // Use visual layout analysis for reading order (experimental)
};

const OutputFormat = enum {
    text, // Plain text (default)
    json, // JSON with positions
    markdown, // Markdown with headings, lists, etc.
};

fn runExtract(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var page_range: ?[]const u8 = null;
    var error_mode: zpdf.ErrorConfig = zpdf.ErrorConfig.default();
    var output_format: OutputFormat = .text;
    var sequential = false;
    var extraction_mode: ExtractionMode = .normal;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) page_range = args[i];
        } else if (std.mem.eql(u8, arg, "--strict")) {
            error_mode = zpdf.ErrorConfig.strict();
        } else if (std.mem.eql(u8, arg, "--permissive")) {
            error_mode = zpdf.ErrorConfig.permissive();
        } else if (std.mem.eql(u8, arg, "--json")) {
            output_format = .json;
        } else if (std.mem.eql(u8, arg, "--markdown") or std.mem.eql(u8, arg, "-m")) {
            output_format = .markdown;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i < args.len) {
                const fmt = args[i];
                if (std.mem.eql(u8, fmt, "text") or std.mem.eql(u8, fmt, "txt")) {
                    output_format = .text;
                } else if (std.mem.eql(u8, fmt, "json")) {
                    output_format = .json;
                } else if (std.mem.eql(u8, fmt, "markdown") or std.mem.eql(u8, fmt, "md")) {
                    output_format = .markdown;
                } else {
                    std.debug.print("Unknown format: {s}. Use text, json, or markdown.\n", .{fmt});
                    return;
                }
            }
        } else if (std.mem.eql(u8, arg, "--sequential")) {
            sequential = true;
        } else if (std.mem.eql(u8, arg, "--reading-order")) {
            extraction_mode = .visual;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            input_file = arg;
        }
    }

    const path = input_file orelse {
        std.debug.print("Error: No input file specified\n", .{});
        return;
    };

    // Open document
    const doc = zpdf.Document.openWithConfig(allocator, path, error_mode) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return;
    };
    defer doc.close();

    // Warn about encrypted PDFs
    if (doc.isEncrypted()) {
        std.debug.print("Warning: {s} is encrypted. Text extraction may produce incorrect results.\n", .{path});
    }

    // Setup output
    const output_handle = if (output_file) |out_path|
        std.fs.cwd().createFile(out_path, .{}) catch |err| {
            std.debug.print("Error creating {s}: {}\n", .{ out_path, err });
            return;
        }
    else
        null;
    defer if (output_handle) |h| h.close();

    // Parse page range
    const pages = parsePageRange(allocator, page_range, doc.pages.items.len) catch |err| {
        std.debug.print("Error parsing page range: {}\n", .{err});
        return;
    };
    defer allocator.free(pages);

    // Use parallel structured extraction for all pages (text mode only, normal mode)
    const use_parallel = !sequential and output_format == .text and page_range == null and extraction_mode == .normal;

    // Use buffered output
    var write_buf: [4096]u8 = undefined;

    // Handle markdown format separately (extracts all at once)
    if (output_format == .markdown and page_range == null) {
        const result = doc.extractAllMarkdown(allocator) catch |err| {
            std.debug.print("Error during markdown extraction: {}\n", .{err});
            return;
        };
        defer allocator.free(result);

        if (output_handle) |h| {
            h.writeAll(result) catch |err| {
                std.debug.print("Error writing output: {}\n", .{err});
                return;
            };
        } else {
            std.fs.File.stdout().writeAll(result) catch |err| {
                std.debug.print("Error writing output: {}\n", .{err});
                return;
            };
        }
    } else if (use_parallel) {
        // Structure tree extraction (uses stream order as fallback)
        const result = doc.extractAllTextStructured(allocator) catch |err| {
            std.debug.print("Error during structured extraction: {}\n", .{err});
            return;
        };
        defer allocator.free(result);

        if (output_handle) |h| {
            h.writeAll(result) catch |err| {
                std.debug.print("Error writing output: {}\n", .{err});
                return;
            };
        } else {
            std.fs.File.stdout().writeAll(result) catch |err| {
                std.debug.print("Error writing output: {}\n", .{err});
                return;
            };
        }
    } else if (output_handle) |h| {
        var file_writer = h.writer(&write_buf);
        const writer = &file_writer.interface;
        defer writer.flush() catch {};
        try doExtract(doc, pages, output_format, extraction_mode, allocator, writer);
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&write_buf);
        const writer = &stdout_writer.interface;
        defer writer.flush() catch {};
        try doExtract(doc, pages, output_format, extraction_mode, allocator, writer);
    }

    // Report errors if any
    if (doc.errors.items.len > 0) {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_bw = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_bw.interface;
        defer stderr.flush() catch {};
        try stderr.print("\nWarning: {} errors encountered during extraction\n", .{doc.errors.items.len});
        for (doc.errors.items[0..@min(10, doc.errors.items.len)]) |err| {
            try stderr.print("  - {s} at offset {}\n", .{ err.message, err.offset });
        }
        if (doc.errors.items.len > 10) {
            try stderr.print("  ... and {} more\n", .{doc.errors.items.len - 10});
        }
    }
}

fn doExtract(doc: *zpdf.Document, pages: []const usize, output_format: OutputFormat, extraction_mode: ExtractionMode, allocator: std.mem.Allocator, writer: anytype) !void {
    if (output_format == .json) {
        try writer.writeAll("{\n");

        // Metadata
        const meta = doc.metadata();
        try writer.writeAll("  \"metadata\": {");
        var meta_first = true;
        inline for (.{
            .{ "title", meta.title },
            .{ "author", meta.author },
            .{ "subject", meta.subject },
            .{ "keywords", meta.keywords },
            .{ "creator", meta.creator },
            .{ "producer", meta.producer },
            .{ "creation_date", meta.creation_date },
            .{ "mod_date", meta.mod_date },
        }) |pair| {
            if (pair[1]) |val| {
                if (!meta_first) try writer.writeAll(",");
                try writer.print("\n    \"{s}\": \"", .{pair[0]});
                try writeJsonEscapedString(writer, val);
                try writer.writeAll("\"");
                meta_first = false;
            }
        }
        if (!meta_first) try writer.writeAll("\n  ");
        try writer.writeAll("},\n");

        // Page count
        try writer.print("  \"page_count\": {},\n", .{doc.pages.items.len});

        // Outline
        const outline_items = doc.getOutline(allocator) catch &.{};
        defer if (outline_items.len > 0) {
            for (outline_items) |item| {
                allocator.free(@constCast(item.title));
            }
            allocator.free(outline_items);
        };

        try writer.writeAll("  \"outline\": [");
        for (outline_items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\n    {\"title\": \"");
            try writeJsonEscapedString(writer, item.title);
            try writer.print("\", \"page\": {}, \"level\": {}}}", .{
                if (item.page) |p| @as(i32, @intCast(p)) else @as(i32, -1),
                item.level,
            });
        }
        if (outline_items.len > 0) try writer.writeAll("\n  ");
        try writer.writeAll("],\n");

        // Pages
        try writer.writeAll("  \"pages\": [\n");
    }

    for (pages, 0..) |page_num, idx| {
        if (output_format == .json) {
            if (idx > 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.print("      \"page\": {}", .{page_num + 1});

            // Page label
            if (doc.getPageLabel(allocator, page_num)) |label| {
                defer allocator.free(label);
                try writer.writeAll(",\n      \"label\": \"");
                try writeJsonEscapedString(writer, label);
                try writer.writeAll("\"");
            }

            try writer.writeAll(",\n      \"text\": \"");
        }

        switch (output_format) {
            .markdown => {
                const text = doc.extractMarkdown(page_num, allocator) catch |err| {
                    std.debug.print("Error extracting page {}: {}\n", .{ page_num + 1, err });
                    continue;
                };
                defer allocator.free(text);
                try writer.writeAll(text);
                if (idx + 1 < pages.len) {
                    try writer.writeAll("\n---\n\n");
                }
            },
            .json, .text => {
                const text = switch (extraction_mode) {
                    .normal => doc.extractTextStructured(page_num, allocator) catch |err| {
                        std.debug.print("Error extracting page {}: {}\n", .{ page_num + 1, err });
                        continue;
                    },
                    .visual => extractPageReadingOrder(doc, page_num, allocator) catch |err| {
                        std.debug.print("Error extracting page {}: {}\n", .{ page_num + 1, err });
                        continue;
                    },
                };
                defer allocator.free(text);

                if (output_format == .json) {
                    try writeJsonEscapedString(writer, text);
                    try writer.writeAll("\"");

                    // Links for this page
                    try writer.writeAll(",\n      \"links\": [");
                    if (doc.getPageLinks(page_num, allocator)) |links| {
                        defer zpdf.Document.freeLinks(allocator, links);
                        for (links, 0..) |link, li| {
                            if (li > 0) try writer.writeAll(",");
                            try writer.writeAll("\n        {");
                            if (link.uri) |uri| {
                                try writer.writeAll("\"uri\": \"");
                                try writeJsonEscapedString(writer, uri);
                                try writer.writeAll("\", ");
                            }
                            if (link.dest_page) |dp| {
                                try writer.print("\"dest_page\": {}, ", .{dp});
                            }
                            try writer.print("\"rect\": [{d:.1}, {d:.1}, {d:.1}, {d:.1}]}}", .{
                                link.rect[0], link.rect[1], link.rect[2], link.rect[3],
                            });
                        }
                        if (links.len > 0) try writer.writeAll("\n      ");
                    } else |_| {}
                    try writer.writeAll("]");

                    // Images for this page
                    try writer.writeAll(",\n      \"images\": [");
                    if (doc.getPageImages(page_num, allocator)) |images| {
                        defer zpdf.Document.freeImages(allocator, images);
                        for (images, 0..) |img, ii| {
                            if (ii > 0) try writer.writeAll(",");
                            try writer.print("\n        {{\"rect\": [{d:.1}, {d:.1}, {d:.1}, {d:.1}], \"width\": {}, \"height\": {}}}", .{
                                img.rect[0], img.rect[1], img.rect[2], img.rect[3],
                                img.width, img.height,
                            });
                        }
                        if (images.len > 0) try writer.writeAll("\n      ");
                    } else |_| {}
                    try writer.writeAll("]");

                    try writer.writeAll("\n    }");
                } else if (idx + 1 < pages.len) {
                    try writer.writeAll(text);
                    try writer.writeByte('\x0c');
                } else {
                    try writer.writeAll(text);
                }
            },
        }
    }

    if (output_format == .json) {
        try writer.writeAll("\n  ]\n}\n");
    }
}

fn writeJsonEscapedString(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0c' => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u00{X:0>2}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Extract text from a single page in reading order
fn extractPageReadingOrder(doc: *zpdf.Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
    const page = doc.pages.items[page_num];
    const page_width = page.media_box[2] - page.media_box[0];

    const spans = try doc.extractTextWithBounds(page_num, allocator);
    if (spans.len == 0) {
        return allocator.alloc(u8, 0);
    }
    defer zpdf.Document.freeTextSpans(allocator, spans);

    var layout_result = try zpdf.layout.analyzeLayout(allocator, spans, page_width);
    defer layout_result.deinit();

    return layout_result.getTextInOrder(allocator);
}

/// Extract text from all pages in reading order (parallel)
fn extractAllTextReadingOrderParallel(doc: *zpdf.Document, allocator: std.mem.Allocator) ![]u8 {
    const num_pages = doc.pages.items.len;
    if (num_pages == 0) return try allocator.alloc(u8, 0);

    // Allocate result buffers for each page
    const results = try allocator.alloc([]u8, num_pages);
    defer allocator.free(results);
    @memset(results, &[_]u8{});

    const Thread = std.Thread;
    const cpu_count = Thread.getCpuCount() catch 4;
    const num_threads: usize = @min(num_pages, @min(cpu_count, 8));

    const Context = struct {
        doc: *zpdf.Document,
        results: [][]u8,
        alloc: std.mem.Allocator,
    };

    const ctx = Context{
        .doc = doc,
        .results = results,
        .alloc = allocator,
    };

    const worker = struct {
        fn run(c: Context, start: usize, end: usize) void {
            for (start..end) |page_idx| {
                const page = c.doc.pages.items[page_idx];
                const page_width = page.media_box[2] - page.media_box[0];

                const spans = c.doc.extractTextWithBounds(page_idx, c.alloc) catch continue;
                if (spans.len == 0) continue;
                defer zpdf.Document.freeTextSpans(c.alloc, spans);

                var layout_result = zpdf.layout.analyzeLayout(c.alloc, spans, page_width) catch continue;
                defer layout_result.deinit();

                const text = layout_result.getTextInOrder(c.alloc) catch continue;
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

    if (total_size == 0) return allocator.alloc(u8, 0);

    var output = try allocator.alloc(u8, total_size);
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
            allocator.free(r);
            first_written = true;
        }
    }

    return output;
}

fn runInfo(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: No input file specified\n", .{});
        return;
    }

    const path = args[0];

    const doc = zpdf.Document.open(allocator, path) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return;
    };
    defer doc.close();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_bw.interface;
    defer stdout.flush() catch {};

    try stdout.print(
        \\ZPDF Document Info
        \\==================
        \\File: {s}
        \\Size: {} bytes
        \\Pages: {}
        \\XRef entries: {}
        \\Encrypted: {s}
        \\
    , .{
        path,
        doc.data.len,
        doc.pages.items.len,
        doc.xref_table.entries.count(),
        if (doc.isEncrypted()) "yes" else "no",
    });

    // Print metadata
    const meta = doc.metadata();
    var has_meta = false;
    inline for (.{ .{ "Title", meta.title }, .{ "Author", meta.author }, .{ "Subject", meta.subject }, .{ "Keywords", meta.keywords }, .{ "Creator", meta.creator }, .{ "Producer", meta.producer }, .{ "Created", meta.creation_date }, .{ "Modified", meta.mod_date } }) |pair| {
        if (pair[1]) |val| {
            if (!has_meta) {
                try stdout.writeAll("\nMetadata:\n");
                has_meta = true;
            }
            try stdout.print("  {s}: {s}\n", .{ pair[0], val });
        }
    }

    // Print page sizes
    try stdout.writeAll("\nPage sizes:\n");
    for (doc.pages.items, 0..) |page, i| {
        const width = page.media_box[2] - page.media_box[0];
        const height = page.media_box[3] - page.media_box[1];
        try stdout.print("  Page {}: {d:.0} x {d:.0} pts", .{ i + 1, width, height });
        if (page.rotation != 0) {
            try stdout.print(" (rotated {}°)", .{page.rotation});
        }
        try stdout.writeByte('\n');
        if (i >= 9) {
            if (doc.pages.items.len > 10) {
                try stdout.print("  ... and {} more pages\n", .{doc.pages.items.len - 10});
            }
            break;
        }
    }

    // Print outline
    const outline_items = doc.getOutline(allocator) catch &.{};
    defer if (outline_items.len > 0) {
        for (outline_items) |item| {
            allocator.free(@constCast(item.title));
        }
        allocator.free(outline_items);
    };

    if (outline_items.len > 0) {
        try stdout.writeAll("\nOutline:\n");
        for (outline_items, 0..) |item, i| {
            // Indent by level
            var indent: u32 = 0;
            while (indent < item.level) : (indent += 1) {
                try stdout.writeAll("  ");
            }
            try stdout.print("  {s}", .{item.title});
            if (item.page) |p| {
                try stdout.print(" (page {})", .{p + 1});
            }
            try stdout.writeByte('\n');
            if (i >= 49) {
                if (outline_items.len > 50) {
                    try stdout.print("  ... and {} more entries\n", .{outline_items.len - 50});
                }
                break;
            }
        }
    }

    // Print form fields count
    if (doc.getFormFields(allocator)) |fields| {
        defer zpdf.Document.freeFormFields(allocator, fields);
        if (fields.len > 0) {
            try stdout.print("\nForm fields: {}\n", .{fields.len});
        }
    } else |_| {}
}

fn runSearch(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: zpdf search <query> <input.pdf>\n", .{});
        return;
    }

    const query = args[0];
    const path = args[1];

    const doc = zpdf.Document.openWithConfig(allocator, path, zpdf.ErrorConfig.default()) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return;
    };
    defer doc.close();

    const results = doc.search(allocator, query) catch |err| {
        std.debug.print("Error searching: {}\n", .{err});
        return;
    };
    defer zpdf.Document.freeSearchResults(allocator, results);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_bw.interface;
    defer stdout.flush() catch {};

    if (results.len == 0) {
        try stdout.print("No matches found for \"{s}\" in {s}\n", .{ query, path });
        return;
    }

    try stdout.print("Found {} match{s} for \"{s}\" in {s}:\n\n", .{
        results.len,
        if (results.len == 1) "" else "es",
        query,
        path,
    });

    for (results) |r| {
        try stdout.print("  Page {}, offset {}: \"...{s}...\"\n", .{
            r.page + 1,
            r.offset,
            r.context,
        });
    }
}

fn runBench(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: No input file specified\n", .{});
        return;
    }

    const path = args[0];
    const parallel = args.len > 1 and std.mem.eql(u8, args[1], "--parallel");

    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_bw.interface;
    defer stdout.flush() catch {};

    try stdout.print("Benchmarking: {s}{s}\n\n", .{ path, if (parallel) " (parallel)" else "" });

    const RUNS = 5;
    var times: [RUNS]i64 = undefined;
    var page_count: usize = 0;

    for (&times) |*t| {
        const start = std.time.nanoTimestamp();

        const doc = zpdf.Document.open(allocator, path) catch |err| {
            std.debug.print("Error opening {s}: {}\n", .{ path, err });
            return;
        };
        page_count = doc.pages.items.len;

        if (parallel) {
            // Use structured extraction (reading order) with parallel support
            const result = doc.extractAllTextStructured(allocator) catch {
                doc.close();
                continue;
            };
            allocator.free(result);
        } else {
            var counter = CharCounter{};
            for (0..doc.pages.items.len) |page_num| {
                doc.extractText(page_num, &counter) catch continue;
            }
        }

        doc.close();

        const end = std.time.nanoTimestamp();
        t.* = @intCast(end - start);
    }

    // Calculate stats
    var sum: i64 = 0;
    var min: i64 = times[0];
    var max: i64 = times[0];
    for (times) |t| {
        sum += t;
        if (t < min) min = t;
        if (t > max) max = t;
    }
    const mean_ns = @divTrunc(sum, RUNS);
    const mean_ms = @as(f64, @floatFromInt(mean_ns)) / 1_000_000.0;

    try stdout.print("ZPDF Results ({} runs):\n", .{RUNS});
    try stdout.print("  Mean:   {d:.2} ms\n", .{mean_ms});
    try stdout.print("  Min:    {d:.2} ms\n", .{@as(f64, @floatFromInt(min)) / 1_000_000.0});
    try stdout.print("  Max:    {d:.2} ms\n", .{@as(f64, @floatFromInt(max)) / 1_000_000.0});
    try stdout.print("  Pages:  {}\n", .{page_count});
    try stdout.print("  Pages/s: {d:.0}\n", .{@as(f64, @floatFromInt(page_count)) / (mean_ms / 1000.0)});

    // Try to run mutool for comparison
    try stdout.writeAll("\nAttempting mutool comparison...\n");

    var child = std.process.Child.init(&.{ "mutool", "convert", "-F", "text", "-o", "/dev/null", path }, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    const mutool_start = std.time.nanoTimestamp();
    const term = child.spawnAndWait() catch {
        try stdout.writeAll("  mutool not found or failed\n");
        return;
    };
    const mutool_end = std.time.nanoTimestamp();

    if (term.Exited == 0) {
        const mutool_ms = @as(f64, @floatFromInt(mutool_end - mutool_start)) / 1_000_000.0;
        try stdout.print("  MuPDF:  {d:.2} ms\n", .{mutool_ms});
        try stdout.print("  Speedup: {d:.2}x\n", .{mutool_ms / mean_ms});
    } else {
        try stdout.writeAll("  mutool failed\n");
    }
}

const CharCounter = struct {
    count: usize = 0,

    pub fn writeAll(self: *CharCounter, data: []const u8) !void {
        self.count += data.len;
    }

    pub fn writeByte(self: *CharCounter, _: u8) !void {
        self.count += 1;
    }

    pub fn print(self: *CharCounter, comptime fmt: []const u8, args: anytype) !void {
        _ = fmt;
        _ = args;
        self.count += 1;
    }
};

fn parsePageRange(allocator: std.mem.Allocator, range_str: ?[]const u8, total_pages: usize) ![]usize {
    if (range_str == null or range_str.?.len == 0) {
        // Return all pages
        const pages = try allocator.alloc(usize, total_pages);
        for (pages, 0..) |*p, i| {
            p.* = i;
        }
        return pages;
    }

    const spec = range_str.?;

    // Count how many pages we'll need
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, spec, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.indexOf(u8, trimmed, "-")) |dash_pos| {
            const start_str = trimmed[0..dash_pos];
            const end_str = trimmed[dash_pos + 1 ..];
            const start = (std.fmt.parseInt(usize, start_str, 10) catch 1) -| 1;
            const end = std.fmt.parseInt(usize, end_str, 10) catch total_pages;
            count += @min(end, total_pages) -| start;
        } else {
            count += 1;
        }
    }

    var pages = try allocator.alloc(usize, count);
    var idx: usize = 0;

    iter = std.mem.splitScalar(u8, spec, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.indexOf(u8, trimmed, "-")) |dash_pos| {
            const start_str = trimmed[0..dash_pos];
            const end_str = trimmed[dash_pos + 1 ..];
            const start = (std.fmt.parseInt(usize, start_str, 10) catch 1) -| 1;
            const end = std.fmt.parseInt(usize, end_str, 10) catch total_pages;

            var page = start;
            while (page < @min(end, total_pages)) : (page += 1) {
                if (idx < pages.len) {
                    pages[idx] = page;
                    idx += 1;
                }
            }
        } else {
            const page = (std.fmt.parseInt(usize, trimmed, 10) catch continue) -| 1;
            if (page < total_pages and idx < pages.len) {
                pages[idx] = page;
                idx += 1;
            }
        }
    }

    return pages[0..idx];
}

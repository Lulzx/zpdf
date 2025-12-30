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
        \\  info        Show PDF structure information
        \\  bench       Benchmark extraction performance
        \\  help        Show this help
        \\
        \\Extract options:
        \\  -o FILE     Output to file (default: stdout)
        \\  -p PAGES    Page range (e.g., "1-10" or "1,3,5")
        \\  -j N        Parallel threads (default: 1)
        \\  --strict    Fail on any parse error
        \\  --permissive  Continue past all errors
        \\  --json      Output as JSON with positions
        \\
        \\Examples:
        \\  zpdf extract document.pdf              # All pages to stdout
        \\  zpdf extract -o out.txt document.pdf   # All pages to file
        \\  zpdf extract -p 1-10 document.pdf      # First 10 pages
        \\  zpdf bench document.pdf                # Benchmark vs mutool
        \\
    );
}

fn runExtract(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var page_range: ?[]const u8 = null;
    var error_mode: zpdf.ErrorConfig = zpdf.ErrorConfig.default();
    var json_output = false;

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
            json_output = true;
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

    // Use buffered output
    var write_buf: [4096]u8 = undefined;

    if (output_handle) |h| {
        var file_writer = h.writer(&write_buf);
        const writer = &file_writer.interface;
        defer writer.flush() catch {};
        try doExtract(doc, pages, json_output, writer);
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&write_buf);
        const writer = &stdout_writer.interface;
        defer writer.flush() catch {};
        try doExtract(doc, pages, json_output, writer);
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

fn doExtract(doc: *zpdf.Document, pages: []const usize, json_output: bool, writer: anytype) !void {
    if (json_output) {
        try writer.writeAll("{\n  \"pages\": [\n");
    }

    for (pages, 0..) |page_num, idx| {
        if (json_output) {
            if (idx > 0) try writer.writeAll(",\n");
            try writer.print("    {{\"page\": {}, \"text\": \"", .{page_num + 1});
        }

        doc.extractText(page_num, writer) catch |err| {
            std.debug.print("Error extracting page {}: {}\n", .{ page_num + 1, err });
            continue;
        };

        if (json_output) {
            try writer.writeAll("\"}");
        } else if (idx + 1 < pages.len) {
            try writer.writeByte('\x0c'); // Form feed between pages
        }
    }

    if (json_output) {
        try writer.writeAll("\n  ]\n}\n");
    }
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
        \\
    , .{
        path,
        doc.data.len,
        doc.pages.items.len,
        doc.xref_table.entries.count(),
    });

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
}

fn runBench(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: No input file specified\n", .{});
        return;
    }

    const path = args[0];
    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_bw.interface;
    defer stdout.flush() catch {};

    try stdout.print("Benchmarking: {s}\n\n", .{path});

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

        var counter = CharCounter{};
        for (0..doc.pages.items.len) |page_num| {
            doc.extractText(page_num, &counter) catch continue;
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

    var child = std.process.Child.init(&.{ "mutool", "draw", "-F", "txt", "-o", "/dev/null", path }, allocator);
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

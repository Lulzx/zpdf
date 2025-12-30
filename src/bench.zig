//! ZPDF Benchmark Suite
//!
//! Measures extraction performance against MuPDF baseline.
//! Run with: zig build bench -- path/to/test.pdf

const std = @import("std");
const zpdf = @import("root.zig");

const WARMUP_RUNS = 2;
const BENCH_RUNS = 5;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print(
            \\ZPDF Benchmark Suite
            \\
            \\Usage: zig build bench -- <pdf_file> [options]
            \\
            \\Options:
            \\  --no-mutool     Skip MuPDF comparison
            \\  --threads N     Test parallel extraction with N threads
            \\  --verbose       Show per-page timings
            \\
        , .{});
        return;
    }

    const pdf_path = args[1];
    var skip_mutool = false;
    var verbose = false;

    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-mutool")) skip_mutool = true;
        if (std.mem.eql(u8, arg, "--verbose")) verbose = true;
    }

    const stdout = std.io.getStdOut().writer();

    try stdout.print(
        \\╔══════════════════════════════════════════════════════════════╗
        \\║                    ZPDF Benchmark Suite                      ║
        \\╚══════════════════════════════════════════════════════════════╝
        \\
        \\File: {s}
        \\
    , .{pdf_path});

    // Get file size
    const file = std.fs.cwd().openFile(pdf_path, .{}) catch |err| {
        std.debug.print("Error opening file: {}\n", .{err});
        return;
    };
    const file_size = (try file.stat()).size;
    file.close();

    try stdout.print("Size: {d:.2} MB\n\n", .{@as(f64, @floatFromInt(file_size)) / (1024 * 1024)});

    // Benchmark ZPDF
    try stdout.writeAll("── ZPDF Performance ───────────────────────────────────────────\n");

    var times: [BENCH_RUNS]i64 = undefined;
    var page_count: usize = 0;

    for (&times) |*t| {
        const start = std.time.nanoTimestamp();

        const doc = zpdf.Document.open(allocator, pdf_path) catch |err| {
            std.debug.print("ZPDF error: {}\n", .{err});
            return;
        };
        page_count = doc.pages.items.len;

        var counter = CharCounter{};
        for (0..doc.pages.items.len) |pn| {
            doc.extractText(pn, &counter) catch continue;
        }

        doc.close();

        const end = std.time.nanoTimestamp();
        t.* = end - start;
    }

    const stats = calcStats(&times);
    try stdout.print("Time:      {d:>8.2} ms (±{d:.2})\n", .{ stats.mean / 1e6, stats.stddev / 1e6 });
    try stdout.print("Pages:     {}\n", .{page_count});
    try stdout.print("Throughput:{d:>8.2} MB/s\n", .{
        @as(f64, @floatFromInt(file_size)) / (stats.mean / 1e9) / (1024 * 1024),
    });

    // MuPDF comparison
    if (!skip_mutool) {
        try stdout.writeAll("\n── MuPDF Comparison ───────────────────────────────────────────\n");

        if (benchMutool(allocator, pdf_path)) |mutool_ns| {
            try stdout.print("MuPDF:     {d:>8.2} ms\n", .{mutool_ns / 1e6});
            try stdout.print("Speedup:   {d:>8.2}x\n", .{mutool_ns / stats.mean});
        } else |_| {
            try stdout.writeAll("(mutool not found)\n");
        }
    }

    _ = verbose;
}

const Stats = struct { mean: f64, stddev: f64 };

fn calcStats(times: []const i64) Stats {
    var sum: f64 = 0;
    for (times) |t| sum += @floatFromInt(t);
    const mean = sum / @as(f64, @floatFromInt(times.len));

    var variance: f64 = 0;
    for (times) |t| {
        const diff = @as(f64, @floatFromInt(t)) - mean;
        variance += diff * diff;
    }

    return .{ .mean = mean, .stddev = @sqrt(variance / @as(f64, @floatFromInt(times.len))) };
}

const CharCounter = struct {
    count: usize = 0,
    pub fn writeAll(self: *CharCounter, data: []const u8) !void {
        self.count += data.len;
    }
    pub fn writeByte(self: *CharCounter, _: u8) !void {
        self.count += 1;
    }
};

fn benchMutool(allocator: std.mem.Allocator, pdf_path: []const u8) !f64 {
    const start = std.time.nanoTimestamp();

    var child = std.process.Child.init(&.{ "mutool", "draw", "-F", "txt", "-o", "/dev/null", pdf_path }, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    _ = try child.spawnAndWait();

    return @floatFromInt(std.time.nanoTimestamp() - start);
}

//! ZPDF Benchmark Suite
//!
//! Measures extraction performance against MuPDF baseline.
//! Run with: zig build bench -- path/to/test.pdf

const std = @import("std");
const zpdf = @import("root.zig");

const WARMUP_RUNS = 2;
const BENCH_RUNS = 5;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

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

    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-mutool")) skip_mutool = true;
    }

    std.debug.print(
        \\╔══════════════════════════════════════════════════════════════╗
        \\║                    ZPDF Benchmark Suite                      ║
        \\╚══════════════════════════════════════════════════════════════╝
        \\
        \\File: {s}
        \\
    , .{pdf_path});

    // Get file size
    const file = std.Io.Dir.cwd().openFile(io, pdf_path, .{}) catch |err| {
        std.debug.print("Error opening file: {}\n", .{err});
        return;
    };
    const file_size = (try file.stat(io)).size;
    file.close(io);

    std.debug.print("Size: {d:.2} MB\n\n", .{@as(f64, @floatFromInt(file_size)) / (1024 * 1024)});

    // Benchmark ZPDF
    std.debug.print("── ZPDF Performance ───────────────────────────────────────────\n", .{});

    var times: [BENCH_RUNS]i128 = undefined;
    var page_count: usize = 0;

    for (&times) |*t| {
        const start = std.Io.Clock.awake.now(io).nanoseconds;

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

        const end = std.Io.Clock.awake.now(io).nanoseconds;
        t.* = end - start;
    }

    const stats = calcStats(&times);
    std.debug.print("Time:      {d:>8.2} ms (±{d:.2})\n", .{ stats.mean / 1e6, stats.stddev / 1e6 });
    std.debug.print("Pages:     {}\n", .{page_count});
    std.debug.print("Throughput:{d:>8.2} MB/s\n", .{
        @as(f64, @floatFromInt(file_size)) / (stats.mean / 1e9) / (1024 * 1024),
    });

    // MuPDF comparison
    if (!skip_mutool) {
        std.debug.print("\n── MuPDF Comparison ───────────────────────────────────────────\n", .{});

        if (benchMutool(allocator, io, pdf_path)) |mutool_ns| {
            std.debug.print("MuPDF:     {d:>8.2} ms\n", .{mutool_ns / 1e6});
            std.debug.print("Speedup:   {d:>8.2}x\n", .{mutool_ns / stats.mean});
        } else |_| {
            std.debug.print("(mutool not found)\n", .{});
        }
    }
}

const Stats = struct { mean: f64, stddev: f64 };

fn calcStats(times: []const i128) Stats {
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

fn benchMutool(allocator: std.mem.Allocator, io: std.Io, pdf_path: []const u8) !f64 {
    const start = std.Io.Clock.awake.now(io).nanoseconds;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "mutool", "draw", "-F", "txt", "-o", "/dev/null", pdf_path },
        .stderr = .ignore,
        .stdout = .ignore,
    });
    _ = try child.wait(io);

    return @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds - start);
}

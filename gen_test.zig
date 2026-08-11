const std = @import("std");
const compat = @import("src/compat.zig");
const testpdf = @import("src/testpdf.zig");

pub const main = compat.MainWithArgs(mainInner).main;

fn mainInner(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const output_path = if (args.len > 1) args[1] else "test.pdf";

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello from zpdf!");
    defer allocator.free(pdf_data);

    const file = try compat.createFileCwd(output_path);
    defer compat.closeFile(file);
    try compat.writeAllFile(file, pdf_data);

    std.debug.print("Generated {s} ({} bytes)\n", .{ output_path, pdf_data.len });
}

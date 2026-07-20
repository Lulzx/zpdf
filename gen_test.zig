const std = @import("std");
const compat = @import("src/compat.zig");
const testpdf = @import("src/testpdf.zig");

pub fn main() !void {
    var gpa = compat.generalPurposeAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Zig 0.16 file I/O requires an Io implementation. Keep this local to the
    // standalone generator instead of adopting the richer process.Init entrypoint.
    var threaded: if (@hasDecl(std.process, "Init")) std.Io.Threaded else void = if (@hasDecl(std.process, "Init")) .init(allocator, .{}) else {};
    defer if (@hasDecl(std.process, "Init")) threaded.deinit();
    if (@hasDecl(std.process, "Init")) compat.setIo(threaded.io());

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello from zpdf!");
    defer allocator.free(pdf_data);

    const file = try compat.createFileCwd("test.pdf");
    defer compat.closeFile(file);
    try compat.writeAllFile(file, pdf_data);

    std.debug.print("Generated test.pdf ({} bytes)\n", .{pdf_data.len});
}

const std = @import("std");

/// Debug/general-purpose allocator type renamed in Zig 0.16.
pub const GeneralPurposeAllocator = if (@hasDecl(std.heap, "GeneralPurposeAllocator"))
    std.heap.GeneralPurposeAllocator
else
    std.heap.DebugAllocator;

pub fn generalPurposeAllocator() GeneralPurposeAllocator(.{}) {
    return if (comptime @hasDecl(std.heap, "GeneralPurposeAllocator"))
        .{}
    else
        .init;
}

/// Build a Zig entrypoint that supplies an allocator and argv to `main_fn` on
/// both the pre-0.16 process API and the Zig 0.16 `std.process.Init` API.
pub fn MainWithArgs(comptime main_fn: anytype) type {
    return if (@hasDecl(std.process, "Init")) struct {
        pub fn main(init: std.process.Init) !void {
            setIo(init.io);
            const args = try init.minimal.args.toSlice(init.arena.allocator());
            try main_fn(init.gpa, args);
        }
    } else struct {
        pub fn main() !void {
            var gpa = generalPurposeAllocator();
            defer _ = gpa.deinit();
            const allocator = gpa.allocator();

            const args = try std.process.argsAlloc(allocator);
            defer std.process.argsFree(allocator, args);

            try main_fn(allocator, args);
        }
    };
}

/// Compatibility helpers for Zig 0.15.x and 0.16.x.
///
/// Zig 0.16 removed std.ArrayList(u8).writer(allocator). This small adapter
/// provides the subset of writer behavior used by zpdf while relying only on
/// ArrayList methods that are available in both 0.15 and 0.16.
pub fn arrayListWriter(list: *std.ArrayList(u8), allocator: std.mem.Allocator) ArrayListWriter {
    return .{
        .list = list,
        .allocator = allocator,
    };
}

pub const ArrayListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: @This(), byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.allocator, fmt, args);
    }
};

pub const has_legacy_fs_file = @hasDecl(std.fs, "File");
pub const File = if (has_legacy_fs_file) std.fs.File else std.Io.File;

var current_io: if (has_legacy_fs_file) void else ?std.Io = if (has_legacy_fs_file) {} else null;

pub fn setIo(io_value: anytype) void {
    if (comptime !has_legacy_fs_file) current_io = io_value;
}

fn currentIo() std.Io {
    return current_io orelse @panic("std.Io not initialized");
}

pub fn stdoutWriter(buffer: []u8) if (has_legacy_fs_file) @TypeOf(std.fs.File.stdout().writer(buffer)) else @TypeOf(std.Io.File.stdout().writer(currentIo(), buffer)) {
    return if (comptime has_legacy_fs_file)
        std.fs.File.stdout().writer(buffer)
    else
        std.Io.File.stdout().writer(currentIo(), buffer);
}

pub fn stderrWriter(buffer: []u8) if (has_legacy_fs_file) @TypeOf(std.fs.File.stderr().writer(buffer)) else @TypeOf(std.Io.File.stderr().writer(currentIo(), buffer)) {
    return if (comptime has_legacy_fs_file)
        std.fs.File.stderr().writer(buffer)
    else
        std.Io.File.stderr().writer(currentIo(), buffer);
}

pub fn writeAllStdout(bytes: []const u8) !void {
    if (comptime has_legacy_fs_file) {
        try std.fs.File.stdout().writeAll(bytes);
    } else {
        var buffer: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(currentIo(), &buffer);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }
}

pub fn createFileCwd(path: []const u8) !File {
    return if (comptime has_legacy_fs_file)
        try std.fs.cwd().createFile(path, .{})
    else
        try std.Io.Dir.cwd().createFile(currentIo(), path, .{});
}

pub fn closeFile(file: File) void {
    if (comptime has_legacy_fs_file)
        file.close()
    else
        file.close(currentIo());
}

pub fn fileSizeCwd(path: []const u8) !u64 {
    if (comptime has_legacy_fs_file) {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        return (try file.stat()).size;
    } else {
        const file = try std.Io.Dir.cwd().openFile(currentIo(), path, .{});
        defer file.close(currentIo());
        return (try file.stat(currentIo())).size;
    }
}

pub fn deleteFileCwd(path: []const u8) void {
    if (comptime has_legacy_fs_file) {
        std.fs.cwd().deleteFile(path) catch {};
    } else {
        std.Io.Dir.cwd().deleteFile(currentIo(), path) catch {};
    }
}

pub fn readFileAllocAlignedCwd(allocator: std.mem.Allocator, path: []const u8, comptime alignment: std.mem.Alignment) ![]align(alignment.toByteUnits()) u8 {
    if (comptime has_legacy_fs_file) {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alignedAlloc(u8, alignment, stat.size);
        errdefer allocator.free(data);
        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) return error.UnexpectedEof;
        return data;
    } else {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        const data = try allocator.alignedAlloc(u8, alignment, stat.size);
        errdefer allocator.free(data);
        const bytes_read = try file.readPositionalAll(io, data, 0);
        if (bytes_read != stat.size) return error.UnexpectedEof;
        return data;
    }
}

pub fn mmapFileReadOnlyCwd(allocator: std.mem.Allocator, path: []const u8) ![]align(std.heap.page_size_min) u8 {
    if (comptime has_legacy_fs_file) {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        return std.posix.mmap(
            null,
            stat.size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
    } else {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        return std.posix.mmap(
            null,
            stat.size,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
    }
}

pub fn writeAllFile(file: File, bytes: []const u8) !void {
    if (comptime has_legacy_fs_file) {
        try file.writeAll(bytes);
    } else {
        var buffer: [4096]u8 = undefined;
        var w = file.writer(currentIo(), &buffer);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }
}

pub fn fileWriter(file: File, buffer: []u8) if (has_legacy_fs_file) @TypeOf(file.writer(buffer)) else @TypeOf(file.writer(currentIo(), buffer)) {
    return if (comptime has_legacy_fs_file)
        file.writer(buffer)
    else
        file.writer(currentIo(), buffer);
}

pub fn nanoTimestamp() i128 {
    return if (comptime @hasDecl(std.time, "nanoTimestamp"))
        std.time.nanoTimestamp()
    else
        @intCast(std.Io.Timestamp.now(currentIo(), .awake).nanoseconds);
}

pub fn runIgnored(argv: []const []const u8, allocator: std.mem.Allocator) !u8 {
    if (comptime @hasDecl(std.process.Child, "init")) {
        var child = std.process.Child.init(argv, allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        const term = try child.spawnAndWait();
        return switch (term) {
            .Exited => |code| code,
            else => 255,
        };
    } else {
        var child = try std.process.spawn(currentIo(), .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try child.wait(currentIo());
        return switch (term) {
            .exited => |code| code,
            else => 255,
        };
    }
}

test "compat ArrayList writer" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    var writer = arrayListWriter(&list, std.testing.allocator);
    try writer.writeAll("hello");
    try writer.writeByte(' ');
    try writer.print("{}", .{123});

    try std.testing.expectEqualStrings("hello 123", list.items);
}

test "compat cwd file helpers" {
    var threaded: if (has_legacy_fs_file) void else std.Io.Threaded = if (has_legacy_fs_file) {} else .init(std.testing.allocator, .{});
    defer if (!has_legacy_fs_file) threaded.deinit();
    if (!has_legacy_fs_file) setIo(threaded.io());

    const path = "zpdf-compat-test.tmp";
    deleteFileCwd(path);
    defer deleteFileCwd(path);

    const file = try createFileCwd(path);
    try writeAllFile(file, "abc123");
    closeFile(file);

    try std.testing.expectEqual(@as(u64, 6), try fileSizeCwd(path));
    const data = try readFileAllocAlignedCwd(std.testing.allocator, path, .fromByteUnits(1));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("abc123", data);
}

test "compat nano timestamp returns monotonic-ish value" {
    var threaded: if (has_legacy_fs_file) void else std.Io.Threaded = if (has_legacy_fs_file) {} else .init(std.testing.allocator, .{});
    defer if (!has_legacy_fs_file) threaded.deinit();
    if (!has_legacy_fs_file) setIo(threaded.io());

    _ = nanoTimestamp();
}

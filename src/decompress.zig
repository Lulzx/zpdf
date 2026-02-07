//! PDF Stream Decompression
//!
//! PDF supports multiple compression filters. In practice:
//! - FlateDecode (zlib/deflate): ~90% of streams
//! - DCTDecode (JPEG): images only
//! - ASCII85Decode: legacy, rare
//! - ASCIIHexDecode: legacy, rare
//! - LZWDecode: legacy, some old PDFs
//! - CCITTFaxDecode: fax images
//!
//! We optimize heavily for FlateDecode since it's the hot path.

const std = @import("std");
const Object = @import("parser.zig").Object;

pub const DecompressError = error{
    UnsupportedFilter,
    InvalidFilterParams,
    DecompressFailed,
    OutputTooLarge,
    InvalidPredictor,
};

/// Maximum decompressed size (prevent DoS)
const MAX_DECOMPRESSED_SIZE: usize = 256 * 1024 * 1024; // 256 MB

/// Decompress a PDF stream based on its /Filter entry
pub fn decompressStream(
    allocator: std.mem.Allocator,
    data: []const u8,
    filter: ?Object,
    params: ?Object,
) ![]u8 {
    const filters = switch (filter orelse return try allocator.dupe(u8, data)) {
        .name => |n| &[_][]const u8{n},
        .array => |arr| blk: {
            var names: [16][]const u8 = undefined;
            var count: usize = 0;
            for (arr) |item| {
                if (item == .name and count < 16) {
                    names[count] = item.name;
                    count += 1;
                }
            }
            break :blk names[0..count];
        },
        else => return try allocator.dupe(u8, data),
    };

    var current = data;
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);

    for (filters, 0..) |f, i| {
        const param = if (params) |p| switch (p) {
            .dict => p,
            .array => |arr| if (i < arr.len) arr[i] else null,
            else => null,
        } else null;

        const result = try applyFilter(allocator, current, f, param);

        if (owned) |o| allocator.free(o);
        owned = result;
        current = result;
    }

    const final = owned orelse try allocator.dupe(u8, data);
    owned = null; // Prevent double-free
    return final;
}

fn applyFilter(
    allocator: std.mem.Allocator,
    data: []const u8,
    filter_name: []const u8,
    params: ?Object,
) ![]u8 {
    if (std.mem.eql(u8, filter_name, "FlateDecode") or
        std.mem.eql(u8, filter_name, "Fl"))
    {
        return decodeFlateDecode(allocator, data, params);
    }

    if (std.mem.eql(u8, filter_name, "ASCII85Decode") or
        std.mem.eql(u8, filter_name, "A85"))
    {
        return decodeASCII85(allocator, data);
    }

    if (std.mem.eql(u8, filter_name, "ASCIIHexDecode") or
        std.mem.eql(u8, filter_name, "AHx"))
    {
        return decodeASCIIHex(allocator, data);
    }

    if (std.mem.eql(u8, filter_name, "LZWDecode") or
        std.mem.eql(u8, filter_name, "LZW"))
    {
        return decodeLZW(allocator, data, params);
    }

    if (std.mem.eql(u8, filter_name, "RunLengthDecode") or
        std.mem.eql(u8, filter_name, "RL"))
    {
        return decodeRunLength(allocator, data);
    }

    // DCTDecode (JPEG) and CCITTFaxDecode are for images - pass through for now
    if (std.mem.eql(u8, filter_name, "DCTDecode") or
        std.mem.eql(u8, filter_name, "DCT") or
        std.mem.eql(u8, filter_name, "CCITTFaxDecode") or
        std.mem.eql(u8, filter_name, "CCF") or
        std.mem.eql(u8, filter_name, "JBIG2Decode") or
        std.mem.eql(u8, filter_name, "JPXDecode"))
    {
        // These are image formats - return as-is for image extraction
        return try allocator.dupe(u8, data);
    }

    return DecompressError.UnsupportedFilter;
}

// ============================================================================
// FLATEDECODE - THE HOT PATH
// ============================================================================

fn decodeFlateDecode(
    allocator: std.mem.Allocator,
    data: []const u8,
    params: ?Object,
) ![]u8 {
    // Use Zig's built-in zlib/flate decompressor
    var input: std.Io.Reader = .fixed(data);
    var decomp: std.compress.flate.Decompress = .init(&input, .zlib, &.{});

    // Read all decompressed data using allocating writer
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    _ = decomp.reader.streamRemaining(&aw.writer) catch |err| {
        // Some PDFs have truncated streams - try to use what we have
        if (aw.written().len > 0 and err == error.EndOfStream) {
            // Continue with what we have
        } else {
            return DecompressError.DecompressFailed;
        }
    };

    if (aw.written().len > MAX_DECOMPRESSED_SIZE) {
        return DecompressError.OutputTooLarge;
    }

    // Apply predictor if specified
    if (params) |p| {
        if (p == .dict) {
            const predictor = if (p.dict.get("Predictor")) |pred|
                if (pred == .integer) @as(i32, @intCast(pred.integer)) else 1
            else
                1;

            if (predictor > 1) {
                const columns = if (p.dict.get("Columns")) |c|
                    if (c == .integer) @as(u32, @intCast(c.integer)) else 1
                else
                    1;

                const colors = if (p.dict.get("Colors")) |c|
                    if (c == .integer) @as(u32, @intCast(c.integer)) else 1
                else
                    1;

                const bits = if (p.dict.get("BitsPerComponent")) |b|
                    if (b == .integer) @as(u32, @intCast(b.integer)) else 8
                else
                    8;

                const unpredicted = try applyPredictor(
                    allocator,
                    aw.written(),
                    predictor,
                    columns,
                    colors,
                    bits,
                );

                aw.deinit();
                return unpredicted;
            }
        }
    }

    return try allocator.dupe(u8, aw.written());
}

/// Apply PNG predictor to decoded data
fn applyPredictor(
    allocator: std.mem.Allocator,
    data: []const u8,
    predictor: i32,
    columns: u32,
    colors: u32,
    bits: u32,
) ![]u8 {
    if (predictor == 1) {
        // No prediction
        return try allocator.dupe(u8, data);
    }

    if (predictor == 2) {
        // TIFF Predictor 2
        return applyTiffPredictor(allocator, data, columns, colors, bits);
    }

    if (predictor >= 10 and predictor <= 15) {
        // PNG predictors
        return applyPngPredictor(allocator, data, columns, colors, bits);
    }

    return DecompressError.InvalidPredictor;
}

fn applyTiffPredictor(
    allocator: std.mem.Allocator,
    data: []const u8,
    columns: u32,
    colors: u32,
    bits: u32,
) ![]u8 {
    _ = bits; // TODO: handle non-8-bit

    const bytes_per_row = columns * colors;
    const num_rows = data.len / bytes_per_row;

    var output = try allocator.alloc(u8, data.len);
    errdefer allocator.free(output);

    var row: usize = 0;
    while (row < num_rows) : (row += 1) {
        const row_start = row * bytes_per_row;
        const row_data = data[row_start..][0..bytes_per_row];
        const out_row = output[row_start..][0..bytes_per_row];

        // First pixel unchanged
        var col: usize = 0;
        while (col < colors) : (col += 1) {
            out_row[col] = row_data[col];
        }

        // Subsequent pixels: add to previous
        while (col < bytes_per_row) : (col += 1) {
            out_row[col] = row_data[col] +% out_row[col - colors];
        }
    }

    return output;
}

fn applyPngPredictor(
    allocator: std.mem.Allocator,
    data: []const u8,
    columns: u32,
    colors: u32,
    bits: u32,
) ![]u8 {
    const bytes_per_pixel = (colors * bits + 7) / 8;
    const row_bytes = (columns * colors * bits + 7) / 8;
    const src_row_bytes = row_bytes + 1; // +1 for filter type byte

    const num_rows = data.len / src_row_bytes;
    const out_len = num_rows * row_bytes;

    var output = try allocator.alloc(u8, out_len);
    errdefer allocator.free(output);

    var prev_row: ?[]const u8 = null;

    var row: usize = 0;
    while (row < num_rows) : (row += 1) {
        const src_start = row * src_row_bytes;
        if (src_start >= data.len) break;

        const filter_type = data[src_start];
        const src_row = data[src_start + 1 ..][0..row_bytes];
        const out_row = output[row * row_bytes ..][0..row_bytes];

        switch (filter_type) {
            0 => {
                // None
                @memcpy(out_row, src_row);
            },
            1 => {
                // Sub
                for (out_row, 0..) |*b, i| {
                    const left: u8 = if (i >= bytes_per_pixel) out_row[i - bytes_per_pixel] else 0;
                    b.* = src_row[i] +% left;
                }
            },
            2 => {
                // Up
                for (out_row, 0..) |*b, i| {
                    const up: u8 = if (prev_row) |pr| pr[i] else 0;
                    b.* = src_row[i] +% up;
                }
            },
            3 => {
                // Average
                for (out_row, 0..) |*b, i| {
                    const left: u16 = if (i >= bytes_per_pixel) out_row[i - bytes_per_pixel] else 0;
                    const up: u16 = if (prev_row) |pr| pr[i] else 0;
                    b.* = src_row[i] +% @as(u8, @truncate((left + up) / 2));
                }
            },
            4 => {
                // Paeth
                for (out_row, 0..) |*b, i| {
                    const left: i16 = if (i >= bytes_per_pixel) out_row[i - bytes_per_pixel] else 0;
                    const up: i16 = if (prev_row) |pr| pr[i] else 0;
                    const up_left: i16 = if (prev_row != null and i >= bytes_per_pixel)
                        prev_row.?[i - bytes_per_pixel]
                    else
                        0;

                    b.* = src_row[i] +% paeth(left, up, up_left);
                }
            },
            else => {
                // Unknown filter - copy as-is
                @memcpy(out_row, src_row);
            },
        }

        prev_row = out_row;
    }

    return output;
}

fn paeth(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);

    if (pa <= pb and pa <= pc) {
        return @truncate(@as(u16, @bitCast(a)));
    } else if (pb <= pc) {
        return @truncate(@as(u16, @bitCast(b)));
    } else {
        return @truncate(@as(u16, @bitCast(c)));
    }
}

// ============================================================================
// ASCII85DECODE
// ============================================================================

fn decodeASCII85(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var tuple: u32 = 0;
    var count: u8 = 0;
    var i: usize = 0;

    while (i < data.len) : (i += 1) {
        const c = data[i];

        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;

        // End of data marker
        if (c == '~') {
            if (i + 1 < data.len and data[i + 1] == '>') break;
            continue;
        }

        // 'z' represents 4 zero bytes
        if (c == 'z') {
            if (count != 0) return DecompressError.DecompressFailed;
            try output.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
            continue;
        }

        // Regular ASCII85 character
        if (c < '!' or c > 'u') continue;

        tuple = tuple * 85 + (c - '!');
        count += 1;

        if (count == 5) {
            try output.append(allocator, @truncate(tuple >> 24));
            try output.append(allocator, @truncate(tuple >> 16));
            try output.append(allocator, @truncate(tuple >> 8));
            try output.append(allocator, @truncate(tuple));
            tuple = 0;
            count = 0;
        }
    }

    // Handle remaining bytes
    if (count > 0) {
        var j: u8 = count;
        while (j < 5) : (j += 1) {
            tuple = tuple * 85 + 84;
        }

        if (count >= 2) try output.append(allocator, @truncate(tuple >> 24));
        if (count >= 3) try output.append(allocator, @truncate(tuple >> 16));
        if (count >= 4) try output.append(allocator, @truncate(tuple >> 8));
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// ASCIIHEXDECODE
// ============================================================================

fn decodeASCIIHex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var high: ?u4 = null;

    for (data) |c| {
        // End marker
        if (c == '>') break;

        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;

        const nibble: ?u4 = if (c >= '0' and c <= '9')
            @truncate(c - '0')
        else if (c >= 'A' and c <= 'F')
            @truncate(c - 'A' + 10)
        else if (c >= 'a' and c <= 'f')
            @truncate(c - 'a' + 10)
        else
            null;

        if (nibble) |n| {
            if (high) |h| {
                try output.append(allocator, (@as(u8, h) << 4) | n);
                high = null;
            } else {
                high = n;
            }
        }
    }

    // Trailing nibble is padded with 0
    if (high) |h| {
        try output.append(allocator, @as(u8, h) << 4);
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// LZWDECODE
// ============================================================================

fn decodeLZW(
    allocator: std.mem.Allocator,
    data: []const u8,
    params: ?Object,
) ![]u8 {
    _ = params; // TODO: EarlyChange parameter

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // LZW uses variable-length codes
    const LzwTable = struct {
        entries: [4096][]const u8,
        size: u16,

        fn init() @This() {
            var table: @This() = undefined;
            table.size = 258;

            // Initialize with single-byte entries
            var i: u16 = 0;
            while (i < 256) : (i += 1) {
                table.entries[i] = &[_]u8{@truncate(i)};
            }

            return table;
        }

        fn add(self: *@This(), entry: []const u8) void {
            if (self.size < 4096) {
                self.entries[self.size] = entry;
                self.size += 1;
            }
        }

        fn get(self: @This(), code: u16) ?[]const u8 {
            if (code < self.size) return self.entries[code];
            return null;
        }
    };

    var table = LzwTable.init();
    var bit_pos: usize = 0;
    var code_size: u4 = 9;
    var prev_code: ?u16 = null;

    while (true) {
        // Read next code
        const code = readBits(data, bit_pos, code_size) orelse break;
        bit_pos += code_size;

        // Clear table
        if (code == 256) {
            table = LzwTable.init();
            code_size = 9;
            prev_code = null;
            continue;
        }

        // End of data
        if (code == 257) break;

        // Output string for code
        if (table.get(code)) |entry| {
            try output.appendSlice(allocator, entry);

            if (prev_code) |pc| {
                if (table.get(pc)) |prev_entry| {
                    // Add new entry: prev_entry + first byte of current
                    var new_entry = try allocator.alloc(u8, prev_entry.len + 1);
                    @memcpy(new_entry[0..prev_entry.len], prev_entry);
                    new_entry[prev_entry.len] = entry[0];
                    table.add(new_entry);
                }
            }
        } else if (prev_code) |pc| {
            // Code not in table - special case
            if (table.get(pc)) |prev_entry| {
                var new_entry = try allocator.alloc(u8, prev_entry.len + 1);
                @memcpy(new_entry[0..prev_entry.len], prev_entry);
                new_entry[prev_entry.len] = prev_entry[0];
                try output.appendSlice(allocator, new_entry);
                table.add(new_entry);
            }
        }

        prev_code = code;

        // Increase code size when needed
        if (table.size >= (@as(u16, 1) << code_size) and code_size < 12) {
            code_size += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

fn readBits(data: []const u8, bit_pos: usize, count: u4) ?u16 {
    const byte_pos = bit_pos / 8;
    const bit_offset: u3 = @truncate(bit_pos % 8);

    if (byte_pos + 2 >= data.len) return null;

    // Read 3 bytes to ensure we have enough bits
    const b0: u24 = data[byte_pos];
    const b1: u24 = if (byte_pos + 1 < data.len) data[byte_pos + 1] else 0;
    const b2: u24 = if (byte_pos + 2 < data.len) data[byte_pos + 2] else 0;

    const combined: u24 = (b0 << 16) | (b1 << 8) | b2;
    const shift: u5 = @as(u5, 24 - @as(u5, count)) - bit_offset;

    return @truncate(combined >> shift);
}

// ============================================================================
// RUNLENGTHDECODE
// ============================================================================

fn decodeRunLength(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        const length = data[i];
        i += 1;

        if (length == 128) {
            // End of data
            break;
        } else if (length < 128) {
            // Copy next length+1 bytes literally
            const copy_len = @as(usize, length) + 1;
            if (i + copy_len > data.len) break;
            try output.appendSlice(allocator, data[i..][0..copy_len]);
            i += copy_len;
        } else {
            // Repeat next byte (257-length) times
            const repeat_count = 257 - @as(usize, length);
            if (i >= data.len) break;
            const byte = data[i];
            i += 1;
            try output.appendNTimes(allocator, byte, repeat_count);
        }
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "decodeASCIIHex" {
    const allocator = std.testing.allocator;

    const input = "48656C6C6F>";
    const result = try decodeASCIIHex(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello", result);
}

test "decodeASCIIHex with whitespace" {
    const allocator = std.testing.allocator;

    const input = "48 65 6C\n6C 6F>";
    const result = try decodeASCIIHex(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello", result);
}

test "decodeASCII85" {
    const allocator = std.testing.allocator;

    // "Hello world" in ASCII85
    const input = "87cURD]j7BEbo7~>";
    const result = try decodeASCII85(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello world", result);
}

test "decodeRunLength" {
    const allocator = std.testing.allocator;

    // [2, 'A', 'B', 'C'] = copy 3 bytes
    // [254, 'X'] = repeat 'X' 3 times
    // [128] = end
    const input = [_]u8{ 2, 'A', 'B', 'C', 254, 'X', 128 };
    const result = try decodeRunLength(allocator, &input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("ABCXXX", result);
}

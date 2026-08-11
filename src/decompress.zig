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
    return decodeFlateDecodeWithLimit(allocator, data, params, MAX_DECOMPRESSED_SIZE);
}

fn decodeFlateDecodeWithLimit(
    allocator: std.mem.Allocator,
    data: []const u8,
    params: ?Object,
    max_size: usize,
) ![]u8 {
    // Use Zig's built-in zlib/flate decompressor
    var input: std.Io.Reader = .fixed(data);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&input, .zlib, &decompress_buffer);

    // Pull bounded chunks so a compression bomb cannot allocate beyond the cap.
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = decomp.reader.readSliceShort(&chunk) catch return DecompressError.DecompressFailed;
        if (output.items.len > max_size or n > max_size - output.items.len) return DecompressError.OutputTooLarge;
        const new_len = output.items.len + n;
        try output.ensureTotalCapacityPrecise(allocator, new_len);
        output.appendSliceAssumeCapacity(chunk[0..n]);
        if (n < chunk.len) break;
    }

    // Apply predictor if specified
    if (params) |p| {
        if (p == .dict) {
            const predictor = if (p.dict.get("Predictor")) |pred| switch (pred) {
                .integer => |value| std.math.cast(i32, value) orelse return DecompressError.InvalidFilterParams,
                else => 1,
            } else 1;

            if (predictor > 1) {
                const columns = if (p.dict.get("Columns")) |c| switch (c) {
                    .integer => |value| std.math.cast(u32, value) orelse return DecompressError.InvalidFilterParams,
                    else => 1,
                } else 1;

                const colors = if (p.dict.get("Colors")) |c| switch (c) {
                    .integer => |value| std.math.cast(u32, value) orelse return DecompressError.InvalidFilterParams,
                    else => 1,
                } else 1;

                const bits = if (p.dict.get("BitsPerComponent")) |b| switch (b) {
                    .integer => |value| std.math.cast(u32, value) orelse return DecompressError.InvalidFilterParams,
                    else => 8,
                } else 8;

                const unpredicted = try applyPredictor(
                    allocator,
                    output.items,
                    predictor,
                    columns,
                    colors,
                    bits,
                );
                return unpredicted;
            }
        }
    }

    return output.toOwnedSlice(allocator);
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
    if (columns == 0 or colors == 0 or bits != 8) return DecompressError.InvalidFilterParams;
    const bytes_per_row = std.math.mul(usize, columns, colors) catch return DecompressError.InvalidFilterParams;
    if (bytes_per_row == 0) return DecompressError.InvalidFilterParams;
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
    if (columns == 0 or colors == 0 or
        !(bits == 1 or bits == 2 or bits == 4 or bits == 8 or bits == 16))
    {
        return DecompressError.InvalidFilterParams;
    }
    const pixel_bits = std.math.mul(usize, colors, bits) catch return DecompressError.InvalidFilterParams;
    const row_bits = std.math.mul(usize, columns, pixel_bits) catch return DecompressError.InvalidFilterParams;
    const rounded_pixel_bits = std.math.add(usize, pixel_bits, 7) catch return DecompressError.InvalidFilterParams;
    const rounded_row_bits = std.math.add(usize, row_bits, 7) catch return DecompressError.InvalidFilterParams;
    const row_bytes = rounded_row_bits / 8;
    const src_row_bytes = std.math.add(usize, row_bytes, 1) catch return DecompressError.InvalidFilterParams;
    const bytes_per_pixel = rounded_pixel_bits / 8;
    if (bytes_per_pixel == 0 or row_bytes == 0) return DecompressError.InvalidFilterParams;

    const num_rows = data.len / src_row_bytes;
    const out_len = std.math.mul(usize, num_rows, row_bytes) catch return DecompressError.InvalidFilterParams;

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

        fn add(self: *@This(), entry: []const u8) bool {
            if (self.size < 4096) {
                self.entries[self.size] = entry;
                self.size += 1;
                return true;
            }
            return false;
        }

        fn get(self: @This(), code: u16) ?[]const u8 {
            if (code < self.size) return self.entries[code];
            return null;
        }

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            var i: u16 = 258;
            while (i < self.size) : (i += 1) alloc.free(@constCast(self.entries[i]));
            self.size = 258;
        }
    };

    var table = LzwTable.init();
    defer table.deinit(allocator);
    var bit_pos: usize = 0;
    var code_size: u4 = 9;
    var prev_code: ?u16 = null;

    while (true) {
        // Read next code
        const code = readBits(data, bit_pos, code_size) orelse break;
        bit_pos += code_size;

        // Clear table
        if (code == 256) {
            table.deinit(allocator);
            table = LzwTable.init();
            code_size = 9;
            prev_code = null;
            continue;
        }

        // End of data
        if (code == 257) break;

        // Output string for code
        if (table.get(code)) |entry| {
            if (entry.len > MAX_DECOMPRESSED_SIZE - output.items.len) return DecompressError.OutputTooLarge;
            try output.appendSlice(allocator, entry);

            if (prev_code) |pc| {
                if (table.get(pc)) |prev_entry| {
                    // Add new entry: prev_entry + first byte of current
                    var new_entry = try allocator.alloc(u8, prev_entry.len + 1);
                    @memcpy(new_entry[0..prev_entry.len], prev_entry);
                    new_entry[prev_entry.len] = entry[0];
                    if (!table.add(new_entry)) allocator.free(new_entry);
                }
            }
        } else if (prev_code) |pc| {
            // Code not in table - special case
            if (table.get(pc)) |prev_entry| {
                var new_entry = try allocator.alloc(u8, prev_entry.len + 1);
                @memcpy(new_entry[0..prev_entry.len], prev_entry);
                new_entry[prev_entry.len] = prev_entry[0];
                if (new_entry.len > MAX_DECOMPRESSED_SIZE - output.items.len) {
                    allocator.free(new_entry);
                    return DecompressError.OutputTooLarge;
                }
                output.appendSlice(allocator, new_entry) catch |err| {
                    allocator.free(new_entry);
                    return err;
                };
                if (!table.add(new_entry)) allocator.free(new_entry);
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
            if (copy_len > MAX_DECOMPRESSED_SIZE - output.items.len) return DecompressError.OutputTooLarge;
            try output.appendSlice(allocator, data[i..][0..copy_len]);
            i += copy_len;
        } else {
            // Repeat next byte (257-length) times
            const repeat_count = 257 - @as(usize, length);
            if (i >= data.len) break;
            if (repeat_count > MAX_DECOMPRESSED_SIZE - output.items.len) return DecompressError.OutputTooLarge;
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

test "predictors reject unsafe dimensions and unsupported TIFF bit depths" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidFilterParams, applyTiffPredictor(allocator, "abc", 0, 1, 8));
    try std.testing.expectError(error.InvalidFilterParams, applyTiffPredictor(allocator, "abc", 1, 0, 8));
    try std.testing.expectError(error.InvalidFilterParams, applyTiffPredictor(allocator, "abc", 1, 1, 4));
    try std.testing.expectError(error.InvalidFilterParams, applyPngPredictor(allocator, "abc", 0, 1, 8));
    try std.testing.expectError(error.InvalidFilterParams, applyPngPredictor(allocator, "abc", 1, 1, 3));
}

test "FlateDecode enforces output limit while streaming" {
    const compressed = [_]u8{
        0x78, 0x9c, 0xed, 0xc1, 0x31, 0x01, 0x00, 0x00, 0x00, 0xc2, 0xa0, 0x6c, 0xeb, 0x5f, 0xca, 0x1a,
        0x1e, 0x40, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xaf,
        0x06, 0xe2, 0x0c, 0x34, 0x6e,
    };
    try std.testing.expectError(
        error.OutputTooLarge,
        decodeFlateDecodeWithLimit(std.testing.allocator, &compressed, null, 1_000),
    );
}

//! SIMD-accelerated utilities for PDF parsing
//!
//! These are the hot paths that can beat MuPDF:
//! 1. Whitespace skipping (content streams are whitespace-heavy)
//! 2. Delimiter detection (finding string/array/dict boundaries)
//! 3. Keyword search (finding "stream", "endstream", "startxref")
//! 4. Number parsing (content streams are full of coordinates)

const std = @import("std");
const builtin = @import("builtin");

// Detect available SIMD
const has_avx2 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
const has_sse42 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2);
const has_neon = builtin.cpu.arch == .aarch64;

/// Vector type for SIMD operations
const Vec = if (has_avx2)
    @Vector(32, u8)
else if (has_sse42 or has_neon)
    @Vector(16, u8)
else
    @Vector(8, u8); // Fallback

const vec_len = @typeInfo(Vec).vector.len;

// ============================================================================
// WHITESPACE SKIPPING
// ============================================================================

/// PDF whitespace characters: space, tab, LF, CR, FF, NUL
const ws_mask_space: Vec = @splat(' ');
const ws_mask_tab: Vec = @splat('\t');
const ws_mask_lf: Vec = @splat('\n');
const ws_mask_cr: Vec = @splat('\r');
const ws_mask_ff: Vec = @splat(0x0C);
const ws_mask_nul: Vec = @splat(0x00);

/// Skip whitespace using SIMD - returns index of first non-whitespace
pub fn skipWhitespace(data: []const u8, start: usize) usize {
    var i = start;

    // Process in vector-sized chunks
    while (i + vec_len <= data.len) {
        const chunk: Vec = data[i..][0..vec_len].*;

        // Compare against all whitespace characters
        const is_space = chunk == ws_mask_space;
        const is_tab = chunk == ws_mask_tab;
        const is_lf = chunk == ws_mask_lf;
        const is_cr = chunk == ws_mask_cr;
        const is_ff = chunk == ws_mask_ff;
        const is_nul = chunk == ws_mask_nul;

        // Combine results
        const is_ws = @as(@Vector(vec_len, bool), is_space) |
            @as(@Vector(vec_len, bool), is_tab) |
            @as(@Vector(vec_len, bool), is_lf) |
            @as(@Vector(vec_len, bool), is_cr) |
            @as(@Vector(vec_len, bool), is_ff) |
            @as(@Vector(vec_len, bool), is_nul);

        // Find first non-whitespace
        const mask = ~@as(std.meta.Int(.unsigned, vec_len), @bitCast(is_ws));
        if (mask != 0) {
            return i + @ctz(mask);
        }

        i += vec_len;
    }

    // Scalar fallback for remainder
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0x0C and c != 0x00) {
            return i;
        }
    }

    return i;
}

// ============================================================================
// DELIMITER DETECTION
// ============================================================================

/// PDF delimiters
const delimiters = "()<>[]{}/%";

/// Find next delimiter - critical for tokenization
pub fn findDelimiter(data: []const u8, start: usize) ?usize {
    var i = start;

    // SIMD path: check for any delimiter
    while (i + vec_len <= data.len) {
        const chunk: Vec = data[i..][0..vec_len].*;

        var found = @as(@Vector(vec_len, bool), @splat(false));
        inline for (delimiters) |d| {
            const mask: Vec = @splat(d);
            found = found | (chunk == mask);
        }

        // Also check for whitespace as "delimiter" for tokens
        found = found | (chunk == ws_mask_space);
        found = found | (chunk == ws_mask_tab);
        found = found | (chunk == ws_mask_lf);
        found = found | (chunk == ws_mask_cr);

        const mask = @as(std.meta.Int(.unsigned, vec_len), @bitCast(found));
        if (mask != 0) {
            return i + @ctz(mask);
        }

        i += vec_len;
    }

    // Scalar fallback
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (isDelimiterOrWhitespace(c)) return i;
    }

    return null;
}

fn isDelimiterOrWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0C, 0x00 => true,
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

// ============================================================================
// KEYWORD SEARCH
// ============================================================================

/// Find "stream\r\n" or "stream\n" - critical for stream parsing
pub fn findStreamKeyword(data: []const u8, start: usize) ?usize {
    // "stream" is 6 bytes - we can use SIMD to find 's' then verify
    const s_mask: Vec = @splat('s');

    var i = start;
    while (i + vec_len <= data.len) {
        const chunk: Vec = data[i..][0..vec_len].*;
        const is_s = chunk == s_mask;
        const mask = @as(std.meta.Int(.unsigned, vec_len), @bitCast(is_s));

        if (mask != 0) {
            // Found 's' - check if it's "stream"
            var bit_pos: usize = 0;
            var remaining = mask;
            while (remaining != 0) {
                bit_pos = @ctz(remaining);
                const pos = i + bit_pos;

                if (pos + 6 <= data.len and std.mem.eql(u8, data[pos..][0..6], "stream")) {
                    // Verify followed by whitespace
                    if (pos + 6 < data.len) {
                        const next = data[pos + 6];
                        if (next == '\r' or next == '\n' or next == ' ') {
                            return pos;
                        }
                    }
                }

                remaining &= remaining - 1; // Clear lowest bit
            }
        }

        i += vec_len;
    }

    // Scalar fallback
    return std.mem.indexOf(u8, data[start..], "stream");
}

/// Find "endstream" - needed to know stream length
pub fn findEndstreamKeyword(data: []const u8, start: usize) ?usize {
    const e_mask: Vec = @splat('e');

    var i = start;
    while (i + vec_len <= data.len) {
        const chunk: Vec = data[i..][0..vec_len].*;
        const is_e = chunk == e_mask;
        const mask = @as(std.meta.Int(.unsigned, vec_len), @bitCast(is_e));

        if (mask != 0) {
            var bit_pos: usize = 0;
            var remaining = mask;
            while (remaining != 0) {
                bit_pos = @ctz(remaining);
                const pos = i + bit_pos;

                if (pos + 9 <= data.len and std.mem.eql(u8, data[pos..][0..9], "endstream")) {
                    return pos;
                }

                remaining &= remaining - 1;
            }
        }

        i += vec_len;
    }

    return std.mem.indexOf(u8, data[start..], "endstream");
}

/// Find "startxref" from end of file
pub fn findStartxref(data: []const u8) ?usize {
    // Search backwards - startxref should be near EOF
    const search_len = @min(data.len, 1024);
    const search_start = data.len - search_len;

    return if (std.mem.indexOf(u8, data[search_start..], "startxref")) |pos|
        search_start + pos
    else
        null;
}

// ============================================================================
// NUMBER PARSING
// ============================================================================

/// Fast integer parsing - content streams are full of numbers
pub fn parseInt(data: []const u8) ?struct { value: i64, consumed: usize } {
    if (data.len == 0) return null;

    var i: usize = 0;
    var negative = false;

    // Handle sign
    if (data[0] == '-') {
        negative = true;
        i = 1;
    } else if (data[0] == '+') {
        i = 1;
    }

    if (i >= data.len or data[i] < '0' or data[i] > '9') return null;

    var value: i64 = 0;

    // SIMD path for long numbers (rare but possible)
    // For typical PDF numbers (< 8 digits), scalar is fine
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        value = value * 10 + (data[i] - '0');
    }

    return .{
        .value = if (negative) -value else value,
        .consumed = i,
    };
}

/// Fast float parsing
pub fn parseFloat(data: []const u8) ?struct { value: f64, consumed: usize } {
    if (data.len == 0) return null;

    var i: usize = 0;
    var negative = false;

    // Handle sign
    if (data[0] == '-') {
        negative = true;
        i = 1;
    } else if (data[0] == '+') {
        i = 1;
    }

    var int_part: i64 = 0;
    var frac_part: i64 = 0;
    var frac_digits: u32 = 0;
    var has_int = false;
    var has_frac = false;

    // Integer part
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        int_part = int_part * 10 + (data[i] - '0');
        has_int = true;
    }

    // Decimal point
    if (i < data.len and data[i] == '.') {
        i += 1;

        // Fractional part
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
            frac_part = frac_part * 10 + (data[i] - '0');
            frac_digits += 1;
            has_frac = true;
        }
    }

    if (!has_int and !has_frac) return null;

    var value: f64 = @floatFromInt(int_part);
    if (frac_digits > 0) {
        const divisor = std.math.pow(f64, 10.0, @floatFromInt(frac_digits));
        value += @as(f64, @floatFromInt(frac_part)) / divisor;
    }

    return .{
        .value = if (negative) -value else value,
        .consumed = i,
    };
}

// ============================================================================
// STRING SCANNING
// ============================================================================

/// Find matching parenthesis for PDF string literals
/// PDF strings can be nested: (hello (world))
pub fn findStringEnd(data: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;

    // Use SIMD to find ( ) \ characters quickly
    const open_mask: Vec = @splat('(');
    const close_mask: Vec = @splat(')');
    const escape_mask: Vec = @splat('\\');

    while (i + vec_len <= data.len and depth > 0) {
        const chunk: Vec = data[i..][0..vec_len].*;

        const is_open = chunk == open_mask;
        const is_close = chunk == close_mask;
        const is_escape = chunk == escape_mask;

        const interesting = @as(@Vector(vec_len, bool), is_open) |
            @as(@Vector(vec_len, bool), is_close) |
            @as(@Vector(vec_len, bool), is_escape);

        const mask = @as(std.meta.Int(.unsigned, vec_len), @bitCast(interesting));

        if (mask == 0) {
            // No interesting characters - skip entire chunk
            i += vec_len;
            continue;
        }

        // Process byte-by-byte within this chunk
        var j: usize = 0;
        while (j < vec_len and depth > 0) : (j += 1) {
            const c = data[i + j];
            if (c == '\\') {
                j += 1; // Skip escaped character
            } else if (c == '(') {
                depth += 1;
            } else if (c == ')') {
                depth -= 1;
            }
        }
        i += j;

        if (depth == 0) return i;
    }

    // Scalar fallback
    while (i < data.len and depth > 0) : (i += 1) {
        const c = data[i];
        if (c == '\\' and i + 1 < data.len) {
            i += 1;
        } else if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
        }
    }

    return if (depth == 0) i else null;
}

/// Find '>' for hex strings
pub fn findHexStringEnd(data: []const u8, start: usize) ?usize {
    const close_mask: Vec = @splat('>');

    var i = start;
    while (i + vec_len <= data.len) {
        const chunk: Vec = data[i..][0..vec_len].*;
        const is_close = chunk == close_mask;
        const mask = @as(std.meta.Int(.unsigned, vec_len), @bitCast(is_close));

        if (mask != 0) {
            return i + @ctz(mask);
        }

        i += vec_len;
    }

    // Scalar fallback
    while (i < data.len) : (i += 1) {
        if (data[i] == '>') return i;
    }

    return null;
}

// ============================================================================
// SUBSTRING SEARCH
// ============================================================================

/// Find a substring in data. Used for finding keywords like "startxref", "stream", etc.
pub fn findSubstring(data: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > data.len) return null;

    const first_byte = needle[0];
    const first_mask: Vec = @splat(first_byte);

    var i: usize = 0;

    // SIMD path: find potential matches using first byte
    while (i + vec_len <= data.len) {
        const chunk: Vec = data[i..][0..vec_len].*;
        const matches = chunk == first_mask;
        var mask = @as(std.meta.Int(.unsigned, vec_len), @bitCast(matches));

        while (mask != 0) {
            const offset = @ctz(mask);
            const pos = i + offset;

            // Verify full needle match
            if (pos + needle.len <= data.len) {
                if (std.mem.eql(u8, data[pos..][0..needle.len], needle)) {
                    return pos;
                }
            }

            // Clear this bit and continue
            mask &= mask - 1;
        }

        i += vec_len;
    }

    // Scalar fallback for remainder
    while (i + needle.len <= data.len) : (i += 1) {
        if (data[i] == first_byte) {
            if (std.mem.eql(u8, data[i..][0..needle.len], needle)) {
                return i;
            }
        }
    }

    return null;
}

/// Find all occurrences of a substring (returns iterator)
pub fn findAllSubstrings(data: []const u8, needle: []const u8) SubstringIterator {
    return .{ .data = data, .needle = needle, .pos = 0 };
}

pub const SubstringIterator = struct {
    data: []const u8,
    needle: []const u8,
    pos: usize,

    pub fn next(self: *SubstringIterator) ?usize {
        if (self.pos >= self.data.len) return null;

        const result = findSubstring(self.data[self.pos..], self.needle);
        if (result) |offset| {
            const absolute_pos = self.pos + offset;
            self.pos = absolute_pos + 1;
            return absolute_pos;
        }
        return null;
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "skipWhitespace" {
    const data = "   \t\n\r  hello";
    const result = skipWhitespace(data, 0);
    try std.testing.expectEqual(@as(usize, 8), result);
    try std.testing.expectEqual(@as(u8, 'h'), data[result]);
}

test "skipWhitespace no whitespace" {
    const data = "hello";
    const result = skipWhitespace(data, 0);
    try std.testing.expectEqual(@as(usize, 0), result);
}

test "findDelimiter" {
    const data = "hello world/name";
    const result = findDelimiter(data, 0);
    try std.testing.expectEqual(@as(usize, 5), result.?); // space after "hello"
}

test "parseInt" {
    const result1 = parseInt("12345abc");
    try std.testing.expectEqual(@as(i64, 12345), result1.?.value);
    try std.testing.expectEqual(@as(usize, 5), result1.?.consumed);

    const result2 = parseInt("-999");
    try std.testing.expectEqual(@as(i64, -999), result2.?.value);
}

test "parseFloat" {
    const result1 = parseFloat("3.14159");
    try std.testing.expectApproxEqRel(@as(f64, 3.14159), result1.?.value, 0.00001);

    const result2 = parseFloat("-0.5");
    try std.testing.expectApproxEqRel(@as(f64, -0.5), result2.?.value, 0.00001);

    const result3 = parseFloat(".25");
    try std.testing.expectApproxEqRel(@as(f64, 0.25), result3.?.value, 0.00001);
}

test "findStringEnd" {
    const data = "hello (nested) world)extra";
    const result = findStringEnd(data, 0);
    try std.testing.expectEqual(@as(usize, 21), result.?);
}

test "findHexStringEnd" {
    const data = "48656C6C6F>rest";
    const result = findHexStringEnd(data, 0);
    try std.testing.expectEqual(@as(usize, 10), result.?);
}

test "findSubstring" {
    const data = "hello world startxref 12345";
    const result = findSubstring(data, "startxref");
    try std.testing.expectEqual(@as(usize, 12), result.?);
}

test "findSubstring not found" {
    const data = "hello world";
    const result = findSubstring(data, "missing");
    try std.testing.expect(result == null);
}

test "findSubstring at start" {
    const data = "startxref 12345";
    const result = findSubstring(data, "startxref");
    try std.testing.expectEqual(@as(usize, 0), result.?);
}

test "findAllSubstrings" {
    const data = "one stream two stream three stream";
    var iter = findAllSubstrings(data, "stream");

    try std.testing.expectEqual(@as(usize, 4), iter.next().?);
    try std.testing.expectEqual(@as(usize, 15), iter.next().?);
    try std.testing.expectEqual(@as(usize, 27), iter.next().?);
    try std.testing.expect(iter.next() == null);
}

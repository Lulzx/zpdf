//! PDF Object Parser
//!
//! Recursive descent parser for PDF objects.
//! Handles: null, bool, int, real, string, name, array, dict, stream, reference
//!
//! Key insight: PDF syntax is simple but has edge cases:
//! - Strings can contain nested parens: (hello (world))
//! - Names can have hex escapes: /Name#20With#20Spaces
//! - Streams require dictionary to know length
//! - References are "N M R" - must lookahead

const std = @import("std");
const simd = @import("simd.zig");

/// PDF Object types
pub const Object = union(enum) {
    null: void,
    boolean: bool,
    integer: i64,
    real: f64,
    string: []const u8,
    hex_string: []const u8,
    name: []const u8,
    array: []Object,
    dict: Dict,
    stream: Stream,
    reference: ObjRef,

    pub const Dict = struct {
        entries: []Entry,

        pub const Entry = struct {
            key: []const u8,
            value: Object,
        };

        pub fn get(self: Dict, key: []const u8) ?Object {
            for (self.entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            }
            return null;
        }

        pub fn getInt(self: Dict, key: []const u8) ?i64 {
            const obj = self.get(key) orelse return null;
            return switch (obj) {
                .integer => |i| i,
                else => null,
            };
        }

        pub fn getName(self: Dict, key: []const u8) ?[]const u8 {
            const obj = self.get(key) orelse return null;
            return switch (obj) {
                .name => |n| n,
                else => null,
            };
        }

        pub fn getDict(self: Dict, key: []const u8) ?Dict {
            const obj = self.get(key) orelse return null;
            return switch (obj) {
                .dict => |d| d,
                else => null,
            };
        }

        pub fn getArray(self: Dict, key: []const u8) ?[]Object {
            const obj = self.get(key) orelse return null;
            return switch (obj) {
                .array => |a| a,
                else => null,
            };
        }
    };

    pub const Stream = struct {
        dict: Dict,
        data: []const u8,
    };
};

pub const ObjRef = struct {
    num: u32,
    gen: u16,

    pub fn eql(self: ObjRef, other: ObjRef) bool {
        return self.num == other.num and self.gen == other.gen;
    }
};

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    InvalidHexString,
    InvalidName,
    InvalidDictionary,
    InvalidArray,
    InvalidStream,
    InvalidReference,
    NestingTooDeep,
    OutOfMemory,
};

const MAX_NESTING = 100;

/// PDF Object Parser
pub const Parser = struct {
    data: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    nesting: usize,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Parser {
        return .{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .nesting = 0,
        };
    }

    pub fn initAt(allocator: std.mem.Allocator, data: []const u8, offset: usize) Parser {
        return .{
            .data = data,
            .pos = offset,
            .allocator = allocator,
            .nesting = 0,
        };
    }

    /// Parse a single PDF object
    pub fn parseObject(self: *Parser) ParseError!Object {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.data.len) return ParseError.UnexpectedEof;

        const c = self.data[self.pos];

        // Check for specific starters
        if (c == '/') return self.parseName();
        if (c == '(') return self.parseString();
        if (c == '<') {
            if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '<') {
                return self.parseDictOrStream();
            }
            return self.parseHexString();
        }
        if (c == '[') return self.parseArray();

        // Check for keywords or numbers
        if (isDigit(c) or c == '-' or c == '+' or c == '.') {
            return self.parseNumberOrReference();
        }

        // Keywords
        if (self.matchKeyword("null")) return Object{ .null = {} };
        if (self.matchKeyword("true")) return Object{ .boolean = true };
        if (self.matchKeyword("false")) return Object{ .boolean = false };

        return ParseError.UnexpectedToken;
    }

    /// Parse "obj ... endobj" wrapper, returning the inner object
    pub fn parseIndirectObject(self: *Parser) ParseError!struct { num: u32, gen: u16, obj: Object } {
        self.skipWhitespaceAndComments();

        // Parse "N M obj"
        const num = try self.parseUnsignedInt();
        self.skipWhitespaceAndComments();
        const gen = try self.parseUnsignedInt();
        self.skipWhitespaceAndComments();

        if (!self.matchKeyword("obj")) return ParseError.UnexpectedToken;

        const obj = try self.parseObject();

        self.skipWhitespaceAndComments();
        _ = self.matchKeyword("endobj"); // Optional, some PDFs omit it

        return .{
            .num = @intCast(num),
            .gen = @intCast(gen),
            .obj = obj,
        };
    }

    fn parseName(self: *Parser) ParseError!Object {
        if (self.data[self.pos] != '/') return ParseError.InvalidName;
        self.pos += 1;

        const start = self.pos;

        // Name continues until whitespace or delimiter
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWhitespace(c) or isDelimiter(c)) break;
            self.pos += 1;
        }

        const raw_name = self.data[start..self.pos];

        // Check for hex escapes (#XX)
        if (std.mem.indexOf(u8, raw_name, "#")) |_| {
            return Object{ .name = try self.decodeNameEscapes(raw_name) };
        }

        return Object{ .name = raw_name };
    }

    fn decodeNameEscapes(self: *Parser, raw: []const u8) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '#' and i + 2 < raw.len) {
                const hex = raw[i + 1 .. i + 3];
                const byte = std.fmt.parseInt(u8, hex, 16) catch {
                    try result.append(self.allocator, raw[i]);
                    i += 1;
                    continue;
                };
                try result.append(self.allocator, byte);
                i += 3;
            } else {
                try result.append(self.allocator, raw[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn parseString(self: *Parser) ParseError!Object {
        if (self.data[self.pos] != '(') return ParseError.InvalidString;
        self.pos += 1;

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var depth: usize = 1;

        while (self.pos < self.data.len and depth > 0) {
            const c = self.data[self.pos];

            if (c == '\\' and self.pos + 1 < self.data.len) {
                self.pos += 1;
                const escaped = self.data[self.pos];
                self.pos += 1;

                const decoded: u8 = switch (escaped) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'b' => 0x08,
                    'f' => 0x0C,
                    '(' => '(',
                    ')' => ')',
                    '\\' => '\\',
                    '\r' => {
                        // Line continuation - skip \r and optional \n
                        if (self.pos < self.data.len and self.data[self.pos] == '\n') {
                            self.pos += 1;
                        }
                        continue;
                    },
                    '\n' => continue, // Line continuation
                    '0'...'7' => blk: {
                        // Octal escape
                        var octal: u8 = escaped - '0';
                        var count: usize = 1;
                        while (count < 3 and self.pos < self.data.len) {
                            const oc = self.data[self.pos];
                            if (oc >= '0' and oc <= '7') {
                                octal = octal * 8 + (oc - '0');
                                self.pos += 1;
                                count += 1;
                            } else break;
                        }
                        break :blk octal;
                    },
                    else => escaped,
                };
                try result.append(self.allocator, decoded);
            } else if (c == '(') {
                depth += 1;
                try result.append(self.allocator, c);
                self.pos += 1;
            } else if (c == ')') {
                depth -= 1;
                if (depth > 0) try result.append(self.allocator, c);
                self.pos += 1;
            } else {
                try result.append(self.allocator, c);
                self.pos += 1;
            }
        }

        return Object{ .string = try result.toOwnedSlice(self.allocator) };
    }

    fn parseHexString(self: *Parser) ParseError!Object {
        if (self.data[self.pos] != '<') return ParseError.InvalidHexString;
        self.pos += 1;

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var high_nibble: ?u4 = null;

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            self.pos += 1;

            if (c == '>') break;
            if (isWhitespace(c)) continue;

            const nibble: ?u4 = if (c >= '0' and c <= '9')
                @truncate(c - '0')
            else if (c >= 'A' and c <= 'F')
                @truncate(c - 'A' + 10)
            else if (c >= 'a' and c <= 'f')
                @truncate(c - 'a' + 10)
            else
                null;

            if (nibble) |n| {
                if (high_nibble) |h| {
                    try result.append(self.allocator, (@as(u8, h) << 4) | n);
                    high_nibble = null;
                } else {
                    high_nibble = n;
                }
            }
        }

        // Trailing nibble padded with 0
        if (high_nibble) |h| {
            try result.append(self.allocator, @as(u8, h) << 4);
        }

        return Object{ .hex_string = try result.toOwnedSlice(self.allocator) };
    }

    fn parseArray(self: *Parser) ParseError!Object {
        if (self.data[self.pos] != '[') return ParseError.InvalidArray;
        self.pos += 1;

        self.nesting += 1;
        if (self.nesting > MAX_NESTING) return ParseError.NestingTooDeep;
        defer self.nesting -= 1;

        var elements: std.ArrayList(Object) = .empty;
        errdefer elements.deinit(self.allocator);

        while (true) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.data.len) return ParseError.UnexpectedEof;

            if (self.data[self.pos] == ']') {
                self.pos += 1;
                break;
            }

            const element = try self.parseObject();
            try elements.append(self.allocator, element);
        }

        return Object{ .array = try elements.toOwnedSlice(self.allocator) };
    }

    fn parseDictOrStream(self: *Parser) ParseError!Object {
        const dict = try self.parseDict();

        self.skipWhitespaceAndComments();

        // Check for stream
        if (self.matchKeyword("stream")) {
            // Skip single newline after "stream"
            if (self.pos < self.data.len and self.data[self.pos] == '\r') self.pos += 1;
            if (self.pos < self.data.len and self.data[self.pos] == '\n') self.pos += 1;

            // Get length from dictionary
            const length = dict.getInt("Length") orelse {
                // Try to find endstream
                if (simd.findSubstring(self.data[self.pos..], "endstream")) |end_pos| {
                    var actual_end = end_pos;
                    // Remove trailing whitespace
                    while (actual_end > 0 and isWhitespace(self.data[self.pos + actual_end - 1])) {
                        actual_end -= 1;
                    }
                    const stream_data = self.data[self.pos .. self.pos + actual_end];
                    self.pos += end_pos + 9; // Skip past "endstream"
                    return Object{ .stream = .{ .dict = dict, .data = stream_data } };
                }
                return ParseError.InvalidStream;
            };

            if (length < 0) return ParseError.InvalidStream;
            const len: usize = @intCast(length);

            if (self.pos + len > self.data.len) return ParseError.InvalidStream;

            const stream_data = self.data[self.pos .. self.pos + len];
            self.pos += len;

            self.skipWhitespaceAndComments();
            _ = self.matchKeyword("endstream");

            return Object{ .stream = .{ .dict = dict, .data = stream_data } };
        }

        return Object{ .dict = dict };
    }

    fn parseDict(self: *Parser) ParseError!Object.Dict {
        if (self.pos + 1 >= self.data.len or
            self.data[self.pos] != '<' or
            self.data[self.pos + 1] != '<')
        {
            return ParseError.InvalidDictionary;
        }
        self.pos += 2;

        self.nesting += 1;
        if (self.nesting > MAX_NESTING) return ParseError.NestingTooDeep;
        defer self.nesting -= 1;

        var entries: std.ArrayList(Object.Dict.Entry) = .empty;
        errdefer entries.deinit(self.allocator);

        while (true) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.data.len) return ParseError.UnexpectedEof;

            // Check for end of dict
            if (self.pos + 1 < self.data.len and
                self.data[self.pos] == '>' and
                self.data[self.pos + 1] == '>')
            {
                self.pos += 2;
                break;
            }

            // Parse key (must be name)
            const key_obj = try self.parseObject();
            const key = switch (key_obj) {
                .name => |n| n,
                else => return ParseError.InvalidDictionary,
            };

            // Parse value
            const value = try self.parseObject();

            try entries.append(self.allocator, .{ .key = key, .value = value });
        }

        return Object.Dict{ .entries = try entries.toOwnedSlice(self.allocator) };
    }

    fn parseNumberOrReference(self: *Parser) ParseError!Object {
        const start = self.pos;

        // Parse first number
        const first = try self.parseNumber();

        // Save position to backtrack if not a reference
        const after_first = self.pos;

        self.skipWhitespaceAndComments();

        // Check if this could be a reference (N M R)
        if (self.pos < self.data.len and isDigit(self.data[self.pos])) {
            const second_start = self.pos;
            const second = self.parseNumber() catch {
                self.pos = after_first;
                return first;
            };

            self.skipWhitespaceAndComments();

            if (self.pos < self.data.len and self.data[self.pos] == 'R') {
                self.pos += 1;

                // Verify both are non-negative integers
                const num = switch (first) {
                    .integer => |i| if (i >= 0) @as(u32, @intCast(i)) else {
                        self.pos = after_first;
                        return first;
                    },
                    else => {
                        self.pos = after_first;
                        return first;
                    },
                };

                const gen = switch (second) {
                    .integer => |i| if (i >= 0 and i <= 65535) @as(u16, @intCast(i)) else {
                        self.pos = after_first;
                        return first;
                    },
                    else => {
                        self.pos = after_first;
                        return first;
                    },
                };

                return Object{ .reference = .{ .num = num, .gen = gen } };
            }

            // Not a reference, backtrack
            _ = second_start;
        }

        self.pos = after_first;
        _ = start;
        return first;
    }

    fn parseNumber(self: *Parser) ParseError!Object {
        const start = self.pos;
        var has_dot = false;
        var has_digits = false;

        // Sign
        if (self.pos < self.data.len and (self.data[self.pos] == '-' or self.data[self.pos] == '+')) {
            self.pos += 1;
        }

        // Digits and dot
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c >= '0' and c <= '9') {
                has_digits = true;
                self.pos += 1;
            } else if (c == '.' and !has_dot) {
                has_dot = true;
                self.pos += 1;
            } else {
                break;
            }
        }

        if (!has_digits) return ParseError.InvalidNumber;

        const num_str = self.data[start..self.pos];

        if (has_dot) {
            const value = std.fmt.parseFloat(f64, num_str) catch return ParseError.InvalidNumber;
            return Object{ .real = value };
        } else {
            const value = std.fmt.parseInt(i64, num_str, 10) catch return ParseError.InvalidNumber;
            return Object{ .integer = value };
        }
    }

    fn parseUnsignedInt(self: *Parser) ParseError!u64 {
        const start = self.pos;

        while (self.pos < self.data.len and isDigit(self.data[self.pos])) {
            self.pos += 1;
        }

        if (self.pos == start) return ParseError.InvalidNumber;

        return std.fmt.parseInt(u64, self.data[start..self.pos], 10) catch ParseError.InvalidNumber;
    }

    fn matchKeyword(self: *Parser, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.data.len) return false;

        if (!std.mem.eql(u8, self.data[self.pos..][0..keyword.len], keyword)) return false;

        // Ensure it's not part of a longer token
        if (self.pos + keyword.len < self.data.len) {
            const next = self.data[self.pos + keyword.len];
            if (!isWhitespace(next) and !isDelimiter(next)) return false;
        }

        self.pos += keyword.len;
        return true;
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];

            if (isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '%') {
                // Comment - skip to end of line
                while (self.pos < self.data.len and
                    self.data[self.pos] != '\n' and
                    self.data[self.pos] != '\r')
                {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x00;
}

fn isDelimiter(c: u8) bool {
    return c == '(' or c == ')' or c == '<' or c == '>' or
        c == '[' or c == ']' or c == '{' or c == '}' or
        c == '/' or c == '%';
}

// ============================================================================
// TESTS
// ============================================================================

test "parse null" {
    var parser = Parser.init(std.testing.allocator, "null");
    const obj = try parser.parseObject();
    try std.testing.expect(obj == .null);
}

test "parse boolean" {
    var parser1 = Parser.init(std.testing.allocator, "true");
    const obj1 = try parser1.parseObject();
    try std.testing.expect(obj1.boolean == true);

    var parser2 = Parser.init(std.testing.allocator, "false");
    const obj2 = try parser2.parseObject();
    try std.testing.expect(obj2.boolean == false);
}

test "parse integer" {
    var parser = Parser.init(std.testing.allocator, "12345");
    const obj = try parser.parseObject();
    try std.testing.expectEqual(@as(i64, 12345), obj.integer);
}

test "parse negative integer" {
    var parser = Parser.init(std.testing.allocator, "-999");
    const obj = try parser.parseObject();
    try std.testing.expectEqual(@as(i64, -999), obj.integer);
}

test "parse real" {
    var parser = Parser.init(std.testing.allocator, "3.14159");
    const obj = try parser.parseObject();
    try std.testing.expectApproxEqRel(@as(f64, 3.14159), obj.real, 0.00001);
}

test "parse name" {
    var parser = Parser.init(std.testing.allocator, "/Type");
    const obj = try parser.parseObject();
    try std.testing.expectEqualStrings("Type", obj.name);
}

test "parse string" {
    var parser = Parser.init(std.testing.allocator, "(Hello World)");
    const obj = try parser.parseObject();
    defer std.testing.allocator.free(obj.string);
    try std.testing.expectEqualStrings("Hello World", obj.string);
}

test "parse nested string" {
    var parser = Parser.init(std.testing.allocator, "(Hello (nested) World)");
    const obj = try parser.parseObject();
    defer std.testing.allocator.free(obj.string);
    try std.testing.expectEqualStrings("Hello (nested) World", obj.string);
}

test "parse hex string" {
    var parser = Parser.init(std.testing.allocator, "<48656C6C6F>");
    const obj = try parser.parseObject();
    defer std.testing.allocator.free(obj.hex_string);
    try std.testing.expectEqualStrings("Hello", obj.hex_string);
}

test "parse array" {
    var parser = Parser.init(std.testing.allocator, "[1 2 3]");
    const obj = try parser.parseObject();
    defer std.testing.allocator.free(obj.array);

    try std.testing.expectEqual(@as(usize, 3), obj.array.len);
    try std.testing.expectEqual(@as(i64, 1), obj.array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), obj.array[1].integer);
    try std.testing.expectEqual(@as(i64, 3), obj.array[2].integer);
}

test "parse dictionary" {
    var parser = Parser.init(std.testing.allocator, "<< /Type /Page /Count 5 >>");
    const obj = try parser.parseObject();
    defer std.testing.allocator.free(obj.dict.entries);

    try std.testing.expectEqualStrings("Page", obj.dict.getName("Type").?);
    try std.testing.expectEqual(@as(i64, 5), obj.dict.getInt("Count").?);
}

test "parse reference" {
    var parser = Parser.init(std.testing.allocator, "10 0 R");
    const obj = try parser.parseObject();

    try std.testing.expectEqual(@as(u32, 10), obj.reference.num);
    try std.testing.expectEqual(@as(u16, 0), obj.reference.gen);
}

test "parse complex object" {
    const input =
        \\<< /Type /Page
        \\   /MediaBox [0 0 612 792]
        \\   /Contents 5 0 R
        \\   /Resources << /Font << /F1 6 0 R >> >>
        \\>>
    ;

    var parser = Parser.init(std.testing.allocator, input);
    const obj = try parser.parseObject();
    defer std.testing.allocator.free(obj.dict.entries);

    try std.testing.expectEqualStrings("Page", obj.dict.getName("Type").?);

    const mediabox = obj.dict.getArray("MediaBox").?;
    try std.testing.expectEqual(@as(usize, 4), mediabox.len);
}

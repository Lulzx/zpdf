//! PDF Content Stream Interpreter
//!
//! Interprets PDF page content streams to extract text.
//! Handles text positioning, font switching, and output.
//!
//! Key operators:
//! - BT/ET: Begin/end text object
//! - Tf: Set font and size
//! - Tm/Td/TD/T*: Text positioning
//! - Tj/TJ/'/": Show text
//!
//! Streaming architecture: outputs directly to writer, no intermediate buffer

const std = @import("std");
const parser = @import("parser.zig");
const encoding_mod = @import("encoding.zig");
const decompress = @import("decompress.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const FontEncoding = encoding_mod.FontEncoding;

/// Text state within a content stream
const TextState = struct {
    /// Character spacing (Tc)
    char_spacing: f64 = 0,
    /// Word spacing (Tw)
    word_spacing: f64 = 0,
    /// Horizontal scaling (Tz) in percent
    horizontal_scale: f64 = 100,
    /// Text leading (TL)
    leading: f64 = 0,
    /// Text rise (Ts)
    rise: f64 = 0,
    /// Current font name
    font_name: ?[]const u8 = null,
    /// Current font size
    font_size: f64 = 12,
    /// Text matrix [a b c d e f]
    text_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    /// Line matrix (start of current line)
    line_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    /// Previous Y position (for detecting line breaks)
    prev_y: f64 = 0,
    /// Previous X end position (for detecting word breaks)
    prev_x_end: f64 = 0,
};

/// Graphics state (subset relevant to text extraction)
const GraphicsState = struct {
    /// Current transformation matrix
    ctm: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    /// Text state
    text: TextState = .{},
};

/// Content stream interpreter for text extraction
pub fn ContentInterpreter(comptime Writer: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        writer: Writer,

        /// PDF document data
        data: []const u8,
        /// Resolve function for object references
        resolve_fn: *const fn (ObjRef) Object,

        /// Graphics state stack
        state_stack: std.ArrayList(GraphicsState),
        /// Current graphics state
        state: GraphicsState,

        /// Font cache
        fonts: std.StringHashMap(FontEncoding),

        /// Resources dictionary
        resources: ?Object.Dict,

        /// Inside text object (BT...ET)?
        in_text: bool,

        /// Last output ended with space?
        last_was_space: bool,

        pub fn init(
            allocator: std.mem.Allocator,
            writer: Writer,
            data: []const u8,
            resources: ?Object.Dict,
            resolve_fn: *const fn (ObjRef) Object,
        ) Self {
            return .{
                .allocator = allocator,
                .writer = writer,
                .data = data,
                .resolve_fn = resolve_fn,
                .state_stack = std.ArrayList(GraphicsState).init(allocator),
                .state = .{},
                .fonts = std.StringHashMap(FontEncoding).init(allocator),
                .resources = resources,
                .in_text = false,
                .last_was_space = true,
            };
        }

        pub fn deinit(self: *Self) void {
            self.state_stack.deinit();

            var it = self.fonts.valueIterator();
            while (it.next()) |font| {
                var f = font.*;
                f.deinit();
            }
            self.fonts.deinit();
        }

        /// Process a content stream
        pub fn process(self: *Self, content: []const u8) !void {
            var lexer = ContentLexer.init(content);
            var operand_stack: [64]Operand = undefined;
            var stack_size: usize = 0;

            while (try lexer.next()) |token| {
                switch (token) {
                    .number => |n| {
                        if (stack_size < 64) {
                            operand_stack[stack_size] = .{ .number = n };
                            stack_size += 1;
                        }
                    },
                    .string => |s| {
                        if (stack_size < 64) {
                            operand_stack[stack_size] = .{ .string = s };
                            stack_size += 1;
                        }
                    },
                    .hex_string => |s| {
                        if (stack_size < 64) {
                            operand_stack[stack_size] = .{ .hex_string = s };
                            stack_size += 1;
                        }
                    },
                    .name => |n| {
                        if (stack_size < 64) {
                            operand_stack[stack_size] = .{ .name = n };
                            stack_size += 1;
                        }
                    },
                    .operator => |op| {
                        try self.executeOperator(op, operand_stack[0..stack_size]);
                        stack_size = 0;
                    },
                    .array => |arr| {
                        if (stack_size < 64) {
                            operand_stack[stack_size] = .{ .array = arr };
                            stack_size += 1;
                        }
                    },
                }
            }
        }

        fn executeOperator(self: *Self, op: []const u8, operands: []const Operand) !void {
            // Graphics state operators
            if (std.mem.eql(u8, op, "q")) {
                try self.state_stack.append(self.state);
            } else if (std.mem.eql(u8, op, "Q")) {
                if (self.state_stack.items.len > 0) {
                    self.state = self.state_stack.pop();
                }
            } else if (std.mem.eql(u8, op, "cm")) {
                // Modify CTM - not critical for basic text extraction
            }
            // Text object operators
            else if (std.mem.eql(u8, op, "BT")) {
                self.in_text = true;
                self.state.text = .{};
            } else if (std.mem.eql(u8, op, "ET")) {
                self.in_text = false;
            }
            // Text state operators
            else if (std.mem.eql(u8, op, "Tc")) {
                if (operands.len >= 1) {
                    self.state.text.char_spacing = operands[0].asNumber();
                }
            } else if (std.mem.eql(u8, op, "Tw")) {
                if (operands.len >= 1) {
                    self.state.text.word_spacing = operands[0].asNumber();
                }
            } else if (std.mem.eql(u8, op, "Tz")) {
                if (operands.len >= 1) {
                    self.state.text.horizontal_scale = operands[0].asNumber();
                }
            } else if (std.mem.eql(u8, op, "TL")) {
                if (operands.len >= 1) {
                    self.state.text.leading = operands[0].asNumber();
                }
            } else if (std.mem.eql(u8, op, "Tf")) {
                if (operands.len >= 2) {
                    self.state.text.font_name = operands[0].asName();
                    self.state.text.font_size = operands[1].asNumber();
                    try self.loadFont(operands[0].asName() orelse "");
                }
            } else if (std.mem.eql(u8, op, "Tr")) {
                // Text rendering mode - not needed for extraction
            } else if (std.mem.eql(u8, op, "Ts")) {
                if (operands.len >= 1) {
                    self.state.text.rise = operands[0].asNumber();
                }
            }
            // Text positioning operators
            else if (std.mem.eql(u8, op, "Td")) {
                if (operands.len >= 2) {
                    const tx = operands[0].asNumber();
                    const ty = operands[1].asNumber();
                    try self.moveText(tx, ty);
                }
            } else if (std.mem.eql(u8, op, "TD")) {
                if (operands.len >= 2) {
                    const tx = operands[0].asNumber();
                    const ty = operands[1].asNumber();
                    self.state.text.leading = -ty;
                    try self.moveText(tx, ty);
                }
            } else if (std.mem.eql(u8, op, "Tm")) {
                if (operands.len >= 6) {
                    const new_y = operands[5].asNumber();
                    try self.checkLineBreak(new_y);

                    self.state.text.text_matrix = .{
                        operands[0].asNumber(),
                        operands[1].asNumber(),
                        operands[2].asNumber(),
                        operands[3].asNumber(),
                        operands[4].asNumber(),
                        new_y,
                    };
                    self.state.text.line_matrix = self.state.text.text_matrix;
                }
            } else if (std.mem.eql(u8, op, "T*")) {
                try self.moveText(0, -self.state.text.leading);
            }
            // Text showing operators
            else if (std.mem.eql(u8, op, "Tj")) {
                if (operands.len >= 1) {
                    try self.showText(operands[0]);
                }
            } else if (std.mem.eql(u8, op, "TJ")) {
                if (operands.len >= 1) {
                    try self.showTextArray(operands[0]);
                }
            } else if (std.mem.eql(u8, op, "'")) {
                // Move to next line and show text
                try self.moveText(0, -self.state.text.leading);
                if (operands.len >= 1) {
                    try self.showText(operands[0]);
                }
            } else if (std.mem.eql(u8, op, "\"")) {
                // Set spacing, move to next line, show text
                if (operands.len >= 3) {
                    self.state.text.word_spacing = operands[0].asNumber();
                    self.state.text.char_spacing = operands[1].asNumber();
                    try self.moveText(0, -self.state.text.leading);
                    try self.showText(operands[2]);
                }
            }
            // Inline image - skip
            else if (std.mem.eql(u8, op, "BI")) {
                // Would need to skip to EI
            }
        }

        fn moveText(self: *Self, tx: f64, ty: f64) !void {
            // Calculate new position
            const new_x = self.state.text.line_matrix[4] + tx;
            const new_y = self.state.text.line_matrix[5] + ty;

            try self.checkLineBreak(new_y);

            // Update matrices
            self.state.text.line_matrix[4] = new_x;
            self.state.text.line_matrix[5] = new_y;
            self.state.text.text_matrix = self.state.text.line_matrix;
        }

        fn checkLineBreak(self: *Self, new_y: f64) !void {
            const y_diff = @abs(new_y - self.state.text.prev_y);

            // Significant Y movement = new line
            if (y_diff > self.state.text.font_size * 0.3 and self.state.text.prev_y != 0) {
                try self.writer.writeByte('\n');
                self.last_was_space = true;
            }

            self.state.text.prev_y = new_y;
        }

        fn showText(self: *Self, operand: Operand) !void {
            const str = switch (operand) {
                .string => |s| s,
                .hex_string => |s| s,
                else => return,
            };

            // Get font encoding
            const font_name = self.state.text.font_name orelse "";
            const font = self.fonts.get(font_name);

            if (font) |enc| {
                try enc.decode(str, self.writer);
            } else {
                // Fallback: assume WinAnsi or raw bytes
                for (str) |byte| {
                    if (byte >= 32 and byte < 127) {
                        try self.writer.writeByte(byte);
                    } else if (byte == 0) {
                        // Null often used as separator
                        try self.writer.writeByte(' ');
                    }
                }
            }

            self.last_was_space = false;
        }

        fn showTextArray(self: *Self, operand: Operand) !void {
            const arr = switch (operand) {
                .array => |a| a,
                else => return,
            };

            for (arr) |item| {
                switch (item) {
                    .string, .hex_string => try self.showText(item),
                    .number => |n| {
                        // Negative number = move right (space between glyphs)
                        // Large negative = word space
                        if (n < -100 and !self.last_was_space) {
                            try self.writer.writeByte(' ');
                            self.last_was_space = true;
                        }
                    },
                    else => {},
                }
            }
        }

        fn loadFont(self: *Self, font_name: []const u8) !void {
            // Check if already loaded
            if (self.fonts.contains(font_name)) return;

            // Get font from resources
            const font_dict = blk: {
                const resources = self.resources orelse break :blk null;
                const fonts = resources.getDict("Font") orelse break :blk null;
                const font_obj = fonts.get(font_name) orelse break :blk null;

                // Resolve if reference
                const resolved = switch (font_obj) {
                    .reference => |ref| self.resolve_fn(ref),
                    else => font_obj,
                };

                break :blk switch (resolved) {
                    .dict => |d| d,
                    else => null,
                };
            };

            if (font_dict) |fd| {
                const enc = try encoding_mod.parseFontEncoding(
                    self.allocator,
                    fd,
                    struct {
                        fn resolve(obj: Object) !Object {
                            return obj; // Simplified - would need proper resolution
                        }
                    }.resolve,
                );
                try self.fonts.put(font_name, enc);
            } else {
                // Use default encoding
                const enc = FontEncoding.init(self.allocator);
                try self.fonts.put(font_name, enc);
            }
        }
    };
}

/// Operand types for content stream
pub const Operand = union(enum) {
    number: f64,
    string: []const u8,
    hex_string: []const u8,
    name: []const u8,
    array: []const Operand,

    fn asNumber(self: Operand) f64 {
        return switch (self) {
            .number => |n| n,
            else => 0,
        };
    }

    fn asName(self: Operand) ?[]const u8 {
        return switch (self) {
            .name => |n| n,
            else => null,
        };
    }
};

/// Content stream lexer
pub const ContentLexer = struct {
    data: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    // Temporary storage for arrays
    array_buffer: [256]Operand = undefined,

    pub const Token = union(enum) {
        number: f64,
        string: []const u8,
        hex_string: []const u8,
        name: []const u8,
        operator: []const u8,
        array: []const Operand,
    };

    pub fn init(data: []const u8) ContentLexer {
        return .{
            .data = data,
            .pos = 0,
            .allocator = undefined,
        };
    }

    pub fn next(self: *ContentLexer) !?Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.data.len) return null;

        const c = self.data[self.pos];

        // String literal
        if (c == '(') return Token{ .string = self.scanString() };

        // Hex string
        if (c == '<') {
            if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '<') {
                // Dictionary start - skip for content streams (inline images)
                self.pos += 2;
                return self.next();
            }
            return Token{ .hex_string = self.scanHexString() };
        }

        // Name
        if (c == '/') return Token{ .name = self.scanName() };

        // Array
        if (c == '[') return Token{ .array = self.scanArray() };

        // End markers
        if (c == ']' or c == '>') {
            self.pos += 1;
            return self.next();
        }

        // Number
        if (c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9')) {
            return Token{ .number = self.scanNumber() };
        }

        // Operator (identifier)
        if (isAlpha(c) or c == '\'' or c == '"' or c == '*') {
            return Token{ .operator = self.scanOperator() };
        }

        // Unknown - skip
        self.pos += 1;
        return self.next();
    }

    fn skipWhitespaceAndComments(self: *ContentLexer) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];

            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x00) {
                self.pos += 1;
            } else if (c == '%') {
                // Skip comment
                while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn scanString(self: *ContentLexer) []const u8 {
        self.pos += 1; // Skip '('
        const start = self.pos;
        var depth: usize = 1;

        while (self.pos < self.data.len and depth > 0) {
            const c = self.data[self.pos];
            if (c == '\\' and self.pos + 1 < self.data.len) {
                self.pos += 2;
            } else if (c == '(') {
                depth += 1;
                self.pos += 1;
            } else if (c == ')') {
                depth -= 1;
                if (depth > 0) self.pos += 1;
            } else {
                self.pos += 1;
            }
        }

        const result = self.data[start..self.pos];
        if (self.pos < self.data.len) self.pos += 1; // Skip ')'
        return result;
    }

    fn scanHexString(self: *ContentLexer) []const u8 {
        self.pos += 1; // Skip '<'
        const start = self.pos;

        while (self.pos < self.data.len and self.data[self.pos] != '>') {
            self.pos += 1;
        }

        const result = self.data[start..self.pos];
        if (self.pos < self.data.len) self.pos += 1; // Skip '>'
        return result;
    }

    fn scanName(self: *ContentLexer) []const u8 {
        self.pos += 1; // Skip '/'
        const start = self.pos;

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWhitespace(c) or isDelimiter(c)) break;
            self.pos += 1;
        }

        return self.data[start..self.pos];
    }

    fn scanNumber(self: *ContentLexer) f64 {
        const start = self.pos;
        var has_dot = false;

        if (self.data[self.pos] == '-' or self.data[self.pos] == '+') {
            self.pos += 1;
        }

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c >= '0' and c <= '9') {
                self.pos += 1;
            } else if (c == '.' and !has_dot) {
                has_dot = true;
                self.pos += 1;
            } else {
                break;
            }
        }

        return std.fmt.parseFloat(f64, self.data[start..self.pos]) catch 0;
    }

    fn scanOperator(self: *ContentLexer) []const u8 {
        const start = self.pos;

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWhitespace(c) or isDelimiter(c)) break;
            self.pos += 1;
        }

        return self.data[start..self.pos];
    }

    fn scanArray(self: *ContentLexer) []const Operand {
        self.pos += 1; // Skip '['

        var count: usize = 0;

        while (self.pos < self.data.len and count < 256) {
            self.skipWhitespaceAndComments();

            if (self.pos >= self.data.len) break;

            const c = self.data[self.pos];

            if (c == ']') {
                self.pos += 1;
                break;
            }

            // Parse element
            if (c == '(') {
                self.array_buffer[count] = .{ .string = self.scanString() };
                count += 1;
            } else if (c == '<') {
                self.array_buffer[count] = .{ .hex_string = self.scanHexString() };
                count += 1;
            } else if (c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9')) {
                self.array_buffer[count] = .{ .number = self.scanNumber() };
                count += 1;
            } else if (c == '/') {
                self.array_buffer[count] = .{ .name = self.scanName() };
                count += 1;
            } else {
                self.pos += 1;
            }
        }

        return self.array_buffer[0..count];
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x00;
}

fn isDelimiter(c: u8) bool {
    return c == '(' or c == ')' or c == '<' or c == '>' or
        c == '[' or c == ']' or c == '{' or c == '}' or
        c == '/' or c == '%';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// ============================================================================
// TESTS
// ============================================================================

test "lexer basic tokens" {
    const content = "BT /F1 12 Tf (Hello) Tj ET";

    var lexer = ContentLexer.init(content);

    // BT
    const t1 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("BT", t1.operator);

    // /F1
    const t2 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("F1", t2.name);

    // 12
    const t3 = (try lexer.next()).?;
    try std.testing.expectEqual(@as(f64, 12), t3.number);

    // Tf
    const t4 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("Tf", t4.operator);

    // (Hello)
    const t5 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("Hello", t5.string);

    // Tj
    const t6 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("Tj", t6.operator);

    // ET
    const t7 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("ET", t7.operator);

    // EOF
    const t8 = try lexer.next();
    try std.testing.expect(t8 == null);
}

test "lexer TJ array" {
    const content = "[(Hello ) -200 (World)] TJ";

    var lexer = ContentLexer.init(content);

    const arr = (try lexer.next()).?;
    try std.testing.expect(arr == .array);
    try std.testing.expectEqual(@as(usize, 3), arr.array.len);

    const op = (try lexer.next()).?;
    try std.testing.expectEqualStrings("TJ", op.operator);
}

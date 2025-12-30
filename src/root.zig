//! ZPDF - Zero-copy PDF Parser
//!
//! High-performance PDF text extraction library designed to beat MuPDF.
//!
//! Key design principles:
//! 1. Memory-mapped, zero-copy where possible
//! 2. Lazy parsing - only decode what's accessed
//! 3. SIMD-accelerated lexing for structural parsing
//! 4. Streaming extraction - no intermediate fz_stext_page equivalent
//! 5. Explicit error budgets - caller controls tolerance

const std = @import("std");

// Internal modules
pub const parser = @import("parser.zig");
pub const xref = @import("xref.zig");
pub const pagetree = @import("pagetree.zig");
pub const encoding = @import("encoding.zig");
pub const interpreter = @import("interpreter.zig");
pub const decompress = @import("decompress.zig");
pub const simd = @import("simd.zig");

// Re-exports
pub const Object = parser.Object;
pub const ObjRef = parser.ObjRef;
pub const XRefTable = xref.XRefTable;
pub const Page = pagetree.Page;
pub const FontEncoding = encoding.FontEncoding;

/// Error handling configuration
pub const ErrorConfig = struct {
    /// Maximum errors before aborting
    max_errors: u32 = 100,
    /// Continue on parse errors?
    continue_on_parse_error: bool = true,
    /// Continue on missing objects?
    continue_on_missing_object: bool = true,
    /// Continue on encoding errors?
    continue_on_encoding_error: bool = true,
    /// Log errors to stderr?
    log_errors: bool = false,

    pub fn default() ErrorConfig {
        return .{};
    }

    pub fn strict() ErrorConfig {
        return .{
            .max_errors = 0,
            .continue_on_parse_error = false,
            .continue_on_missing_object = false,
            .continue_on_encoding_error = false,
        };
    }

    pub fn permissive() ErrorConfig {
        return .{
            .max_errors = std.math.maxInt(u32),
            .continue_on_parse_error = true,
            .continue_on_missing_object = true,
            .continue_on_encoding_error = true,
        };
    }
};

/// Parse error record
pub const ParseError = struct {
    kind: Kind,
    offset: u64,
    message: []const u8,

    pub const Kind = enum {
        invalid_header,
        invalid_xref,
        missing_object,
        invalid_stream,
        encoding_error,
        syntax_error,
    };
};

/// PDF Document
pub const Document = struct {
    /// Memory-mapped file data (zero-copy base)
    data: []const u8,
    /// Whether we own the data (mmap'd)
    owns_data: bool,

    /// Cross-reference table
    xref_table: XRefTable,

    /// Page array (flattened from tree)
    pages: std.ArrayList(Page),

    /// Object resolution cache
    object_cache: std.AutoHashMap(u32, Object),

    /// Allocator
    allocator: std.mem.Allocator,

    /// Error configuration
    error_config: ErrorConfig,

    /// Accumulated errors
    errors: std.ArrayList(ParseError),

    /// Open a PDF file
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Document {
        return openWithConfig(allocator, path, ErrorConfig.default());
    }

    /// Open a PDF file with custom error configuration
    pub fn openWithConfig(allocator: std.mem.Allocator, path: []const u8, config: ErrorConfig) !*Document {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const size = stat.size;

        // Memory map the file
        const data = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );

        return openFromMemoryOwned(allocator, data, config);
    }

    /// Open from owned memory (will be freed on close)
    fn openFromMemoryOwned(allocator: std.mem.Allocator, data: []align(std.heap.page_size_min) u8, config: ErrorConfig) !*Document {
        const doc = try allocator.create(Document);
        errdefer allocator.destroy(doc);

        doc.* = .{
            .data = data,
            .owns_data = true,
            .xref_table = XRefTable.init(allocator),
            .pages = .empty,
            .object_cache = std.AutoHashMap(u32, Object).init(allocator),
            .allocator = allocator,
            .error_config = config,
            .errors = .empty,
        };

        try doc.parseDocument();
        return doc;
    }

    /// Open a PDF from memory buffer (not owned)
    pub fn openFromMemory(allocator: std.mem.Allocator, data: []const u8, config: ErrorConfig) !*Document {
        const doc = try allocator.create(Document);
        errdefer allocator.destroy(doc);

        doc.* = .{
            .data = data,
            .owns_data = false,
            .xref_table = XRefTable.init(allocator),
            .pages = .empty,
            .object_cache = std.AutoHashMap(u32, Object).init(allocator),
            .allocator = allocator,
            .error_config = config,
            .errors = .empty,
        };

        try doc.parseDocument();
        return doc;
    }

    fn parseDocument(self: *Document) !void {
        // Verify header
        if (!std.mem.startsWith(u8, self.data, "%PDF-")) {
            if (!self.error_config.continue_on_parse_error) {
                return error.InvalidPdfHeader;
            }
            try self.errors.append(self.allocator, .{
                .kind = .invalid_header,
                .offset = 0,
                .message = "Invalid PDF header",
            });
        }

        // Parse XRef
        self.xref_table = xref.parseXRef(self.allocator, self.data) catch |err| {
            if (self.error_config.continue_on_parse_error) {
                try self.errors.append(self.allocator, .{
                    .kind = .invalid_xref,
                    .offset = 0,
                    .message = "Failed to parse XRef table",
                });
                return;
            } else {
                return err;
            }
        };

        // Build page tree
        const pages_slice = pagetree.buildPageTree(self.allocator, self.data, &self.xref_table) catch |err| {
            if (self.error_config.continue_on_parse_error) {
                try self.errors.append(self.allocator, .{
                    .kind = .syntax_error,
                    .offset = 0,
                    .message = "Failed to build page tree",
                });
                return;
            } else {
                return err;
            }
        };

        // Move pages to ArrayList
        for (pages_slice) |page| {
            try self.pages.append(self.allocator, page);
        }
        self.allocator.free(pages_slice);
    }

    /// Close the document and free resources
    pub fn close(self: *Document) void {
        if (self.owns_data) {
            const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(@ptrCast(@constCast(self.data.ptr)));
            std.posix.munmap(aligned_ptr[0..self.data.len]);
        }

        self.xref_table.deinit();
        self.object_cache.deinit();
        self.errors.deinit(self.allocator);
        self.pages.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Get number of pages
    pub fn pageCount(self: *const Document) usize {
        return self.pages.items.len;
    }

    /// Resolve an object reference
    pub fn resolve(self: *Document, ref: ObjRef) !Object {
        return pagetree.resolveRef(
            self.allocator,
            self.data,
            &self.xref_table,
            ref,
            &self.object_cache,
        );
    }

    /// Extract text from a page, streaming directly to writer
    pub fn extractText(self: *Document, page_num: usize, writer: anytype) !void {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        const page = self.pages.items[page_num];

        // Get content stream
        const content = pagetree.getPageContents(
            self.allocator,
            self.data,
            &self.xref_table,
            page,
            &self.object_cache,
        ) catch |err| {
            if (self.error_config.continue_on_parse_error) {
                try self.errors.append(self.allocator, .{
                    .kind = .invalid_stream,
                    .offset = 0,
                    .message = "Failed to get page contents",
                });
                return;
            } else {
                return err;
            }
        };

        const should_free = content.ptr != self.data.ptr and content.len > 0;
        defer if (should_free) self.allocator.free(@constCast(content));

        if (content.len == 0) return;

        // Simple text extraction using content lexer
        try extractTextFromContent(content, page.resources, writer);
    }

    /// Extract text from all pages
    pub fn extractAllText(self: *Document, writer: anytype) !void {
        for (0..self.pages.items.len) |i| {
            if (i > 0) try writer.writeByte('\x0c'); // Form feed between pages
            try self.extractText(i, writer);
        }
    }

    /// Get page metadata
    pub fn getPageInfo(self: *const Document, page_num: usize) ?PageInfo {
        if (page_num >= self.pages.items.len) return null;

        const page = self.pages.items[page_num];
        return .{
            .width = page.media_box[2] - page.media_box[0],
            .height = page.media_box[3] - page.media_box[1],
            .rotation = page.rotation,
        };
    }

    pub const PageInfo = struct {
        width: f64,
        height: f64,
        rotation: i32,
    };
};

/// Extract text from content stream (simplified version)
fn extractTextFromContent(content: []const u8, resources: ?Object.Dict, writer: anytype) !void {
    _ = resources;

    var lexer = interpreter.ContentLexer.init(content);
    var operands: [64]interpreter.Operand = undefined;
    var operand_count: usize = 0;

    var in_text = false;
    var prev_y: f64 = 0;
    var font_size: f64 = 12;

    while (try lexer.next()) |token| {
        switch (token) {
            .number => |n| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .number = n };
                    operand_count += 1;
                }
            },
            .string => |s| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .string = s };
                    operand_count += 1;
                }
            },
            .hex_string => |s| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .hex_string = s };
                    operand_count += 1;
                }
            },
            .name => |n| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .name = n };
                    operand_count += 1;
                }
            },
            .array => |arr| {
                if (operand_count < 64) {
                    operands[operand_count] = .{ .array = arr };
                    operand_count += 1;
                }
            },
            .operator => |op| {
                // Text object
                if (std.mem.eql(u8, op, "BT")) {
                    in_text = true;
                } else if (std.mem.eql(u8, op, "ET")) {
                    in_text = false;
                }
                // Font
                else if (std.mem.eql(u8, op, "Tf") and operand_count >= 2) {
                    font_size = operands[1].number;
                }
                // Text positioning
                else if (std.mem.eql(u8, op, "Td") or std.mem.eql(u8, op, "TD")) {
                    if (operand_count >= 2) {
                        const ty = operands[1].number;
                        if (@abs(ty) > font_size * 0.5 and prev_y != 0) {
                            try writer.writeByte('\n');
                        }
                        prev_y = ty;
                    }
                } else if (std.mem.eql(u8, op, "Tm") and operand_count >= 6) {
                    const ty = operands[5].number;
                    if (@abs(ty - prev_y) > font_size * 0.5 and prev_y != 0) {
                        try writer.writeByte('\n');
                    }
                    prev_y = ty;
                } else if (std.mem.eql(u8, op, "T*")) {
                    try writer.writeByte('\n');
                }
                // Show text
                else if (std.mem.eql(u8, op, "Tj") and operand_count >= 1) {
                    try writeTextOperand(operands[0], writer);
                } else if (std.mem.eql(u8, op, "TJ") and operand_count >= 1) {
                    try writeTJArray(operands[0], writer);
                } else if (std.mem.eql(u8, op, "'") and operand_count >= 1) {
                    try writer.writeByte('\n');
                    try writeTextOperand(operands[0], writer);
                } else if (std.mem.eql(u8, op, "\"") and operand_count >= 3) {
                    try writer.writeByte('\n');
                    try writeTextOperand(operands[2], writer);
                }

                operand_count = 0;
            },
        }
    }
}

fn writeTextOperand(operand: interpreter.Operand, writer: anytype) !void {
    const data = switch (operand) {
        .string => |s| s,
        .hex_string => |s| s,
        else => return,
    };

    // Simple WinAnsi-ish decoding
    for (data) |byte| {
        if (byte >= 32 and byte < 127) {
            try writer.writeByte(byte);
        } else if (byte == 0) {
            // CID separator
        } else {
            // Extended character - use WinAnsi table or fallback
            const codepoint = encoding.win_ansi_encoding[byte];
            if (codepoint != 0 and codepoint < 128) {
                try writer.writeByte(@truncate(codepoint));
            } else if (codepoint != 0) {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch 1;
                try writer.writeAll(buf[0..len]);
            }
        }
    }
}

fn writeTJArray(operand: interpreter.Operand, writer: anytype) !void {
    const arr = switch (operand) {
        .array => |a| a,
        else => return,
    };

    for (arr) |item| {
        switch (item) {
            .string, .hex_string => try writeTextOperand(item, writer),
            .number => |n| {
                if (n < -100) {
                    try writer.writeByte(' ');
                }
            },
            else => {},
        }
    }
}

// ============================================================================
// CONVENIENCE FUNCTIONS
// ============================================================================

/// Extract text from a PDF file to a string
pub fn extractTextFromFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const doc = try Document.open(allocator, path);
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try doc.extractAllText(output.writer(allocator));

    return output.toOwnedSlice(allocator);
}

/// Extract text from a PDF in memory to a string
pub fn extractTextFromMemory(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const doc = try Document.openFromMemory(allocator, data, ErrorConfig.default());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try doc.extractAllText(output.writer(allocator));

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "ErrorConfig presets" {
    const strict = ErrorConfig.strict();
    try std.testing.expectEqual(@as(u32, 0), strict.max_errors);

    const permissive = ErrorConfig.permissive();
    try std.testing.expect(permissive.continue_on_parse_error);
}

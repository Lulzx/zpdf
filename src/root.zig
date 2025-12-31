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
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// Internal modules
pub const parser = @import("parser.zig");
pub const xref = @import("xref.zig");
pub const pagetree = @import("pagetree.zig");
pub const encoding = @import("encoding.zig");
pub const interpreter = @import("interpreter.zig");
pub const decompress = @import("decompress.zig");
pub const simd = @import("simd.zig");
pub const layout = @import("layout.zig");

// Re-exports
pub const Object = parser.Object;
pub const ObjRef = parser.ObjRef;
pub const XRefTable = xref.XRefTable;
pub const Page = pagetree.Page;
pub const FontEncoding = encoding.FontEncoding;
pub const TextSpan = layout.TextSpan;
pub const LayoutResult = layout.LayoutResult;

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

    /// Allocator for long-lived allocations
    allocator: std.mem.Allocator,

    /// Arena for parsed objects (freed on close)
    parsing_arena: std.heap.ArenaAllocator,

    /// Error configuration
    error_config: ErrorConfig,

    /// Accumulated errors
    errors: std.ArrayList(ParseError),

    /// Pre-resolved font encodings (key: "pageNum:fontName")
    font_cache: std.StringHashMap(encoding.FontEncoding),

    /// Open a PDF file (not available on WASM)
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Document {
        return openWithConfig(allocator, path, ErrorConfig.default());
    }

    /// Open a PDF file with custom error configuration (not available on WASM)
    pub fn openWithConfig(allocator: std.mem.Allocator, path: []const u8, config: ErrorConfig) !*Document {
        if (comptime is_wasm) {
            @compileError("File I/O is not available on WASM. Use openFromMemory instead.");
        }

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
        if (comptime is_wasm) {
            @compileError("openFromMemoryOwned is not available on WASM. Use openFromMemory instead.");
        }

        const doc = try allocator.create(Document);
        errdefer allocator.destroy(doc);

        doc.* = .{
            .data = data,
            .owns_data = true,
            .xref_table = XRefTable.init(allocator),
            .pages = .empty,
            .object_cache = std.AutoHashMap(u32, Object).init(allocator),
            .allocator = allocator,
            .parsing_arena = std.heap.ArenaAllocator.init(allocator),
            .error_config = config,
            .errors = .empty,
            .font_cache = std.StringHashMap(encoding.FontEncoding).init(allocator),
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
            .parsing_arena = std.heap.ArenaAllocator.init(allocator),
            .error_config = config,
            .errors = .empty,
            .font_cache = std.StringHashMap(encoding.FontEncoding).init(allocator),
        };

        try doc.parseDocument();
        return doc;
    }

    fn parseDocument(self: *Document) !void {
        const arena = self.parsing_arena.allocator();

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

        // Parse XRef (HashMap uses base allocator, parsed objects use arena)
        self.xref_table = xref.parseXRef(self.allocator, arena, self.data) catch |err| {
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

        // Build page tree (uses arena for all allocations)
        const pages_slice = pagetree.buildPageTree(arena, self.data, &self.xref_table) catch |err| {
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

        // Move pages to ArrayList (arena allocated slice, no need to free)
        for (pages_slice) |page| {
            try self.pages.append(self.allocator, page);
        }
    }

    /// Lazy-load fonts for a specific page (called on first extraction)
fn ensurePageFonts(self: *Document, page_idx: usize) void {
    const arena = self.parsing_arena.allocator();
    const page = self.pages.items[page_idx];
    if (page.resources == null) return;
    const resources = page.resources.?;
    const fonts_dict_obj = resources.get("Font") orelse return;

    const fonts_dict_resolved = switch (fonts_dict_obj) {
        .reference => |ref| pagetree.resolveRef(arena, self.data, &self.xref_table, ref, &self.object_cache) catch null,
        else => fonts_dict_obj,
    };

    if (fonts_dict_resolved == null or fonts_dict_resolved.? != .dict) return;

    const fonts_dict = fonts_dict_resolved.?.dict;

    for (fonts_dict.entries) |entry| {
        // Create cache key
        var key_buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ page_idx, entry.key }) catch continue;

        // Skip if already cached
        if (self.font_cache.contains(key)) continue;

        // Resolve font dictionary
        const font_obj = switch (entry.value) {
            .reference => |ref| pagetree.resolveRef(arena, self.data, &self.xref_table, ref, &self.object_cache) catch continue,
            .dict => entry.value,
            else => continue,
        };

        const fd = switch (font_obj) {
            .dict => |d| d,
            else => continue,
        };

        const Resolver = struct {
            arena: std.mem.Allocator,
            data: []const u8,
            xref_table: *const xref.XRefTable,
            object_cache: *std.AutoHashMap(u32, parser.Object),

            fn resolve(self_resolver: @This(), obj: parser.Object) parser.Object {
                return switch (obj) {
                    .reference => |ref| pagetree.resolveRef(self_resolver.arena, self_resolver.data, self_resolver.xref_table, ref, self_resolver.object_cache) catch obj,
                    else => obj,
                };
            }
        };
        const resolver = Resolver{
            .arena = arena,
            .data = self.data,
            .xref_table = &self.xref_table,
            .object_cache = &self.object_cache,
        };

        // Use the comprehensive parseFontEncoding
        const enc = encoding.parseFontEncoding(arena, fd, struct {
            fn wrapper(ctx: *const anyopaque, obj: parser.Object) parser.Object {
                const r: *const Resolver = @alignCast(@ptrCast(ctx));
                return r.resolve(obj);
            }
        }.wrapper, &resolver) catch continue;

        // Need to dupe key since bufPrint uses stack buffer
        const owned_key = arena.dupe(u8, key) catch continue;
        self.font_cache.put(owned_key, enc) catch {};
    }
}

    /// Close the document and free resources
    pub fn close(self: *Document) void {
        if (self.owns_data and !is_wasm) {
            const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(@ptrCast(@constCast(self.data.ptr)));
            std.posix.munmap(aligned_ptr[0..self.data.len]);
        }

        // Free the arena which contains all parsed objects
        self.parsing_arena.deinit();

        self.xref_table.deinit();
        self.object_cache.deinit();
        self.errors.deinit(self.allocator);
        self.pages.deinit(self.allocator);
        self.font_cache.deinit();

        self.allocator.destroy(self);
    }

    /// Get number of pages
    pub fn pageCount(self: *const Document) usize {
        return self.pages.items.len;
    }

    /// Resolve an object reference
    pub fn resolve(self: *Document, ref: ObjRef) !Object {
        return pagetree.resolveRef(
            self.parsing_arena.allocator(),
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
        const arena = self.parsing_arena.allocator();

        // Get content stream (allocated from arena, no need to free)
        const content = pagetree.getPageContents(
            arena,
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

        if (content.len == 0) return;

        // Lazy-load fonts for this page
        self.ensurePageFonts(page_num);

        // Simple text extraction using content lexer
        try extractTextFromContent(arena, content, page_num, &self.font_cache, writer);
    }

    /// Extract text from all pages
    pub fn extractAllText(self: *Document, writer: anytype) !void {
        for (0..self.pages.items.len) |i| {
            if (i > 0) try writer.writeByte('\x0c'); // Form feed between pages
            try self.extractText(i, writer);
        }
    }

    /// Extract text with bounding boxes from a page
    pub fn extractTextWithBounds(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]TextSpan {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        const page = self.pages.items[page_num];
        const arena = self.parsing_arena.allocator();

        const content = pagetree.getPageContents(
            arena,
            self.data,
            &self.xref_table,
            page,
            &self.object_cache,
        ) catch return &.{};

        if (content.len == 0) return &.{};

        // Lazy-load fonts for this page (needed for proper text decoding)
        self.ensurePageFonts(page_num);

        var collector = interpreter.SpanCollector.init(allocator);
        errdefer collector.deinit();

        try extractTextFromContentWithBounds(content, page.resources, &collector, &self.font_cache, page_num);
        try collector.flush();

        return collector.spans.toOwnedSlice(collector.allocator);
    }

    /// Analyze page layout (columns, paragraphs, reading order)
    pub fn analyzePageLayout(self: *Document, page_num: usize, allocator: std.mem.Allocator) !LayoutResult {
        const spans = try self.extractTextWithBounds(page_num, allocator);
        const page = self.pages.items[page_num];
        const page_width = page.media_box[2] - page.media_box[0];
        return layout.analyzeLayout(allocator, spans, page_width);
    }

    /// Extract text from all pages in parallel (returns concatenated result)
    /// Only available on non-WASM targets (use extractAllText on WASM)
    pub const extractAllTextParallel = if (is_wasm)
        @compileError("extractAllTextParallel is not available on WASM targets")
    else
        extractAllTextParallelImpl;

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

/// Extract text from content stream using pre-resolved fonts
fn extractTextFromContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    page_num: usize,
    font_cache: *const std.StringHashMap(encoding.FontEncoding),
    writer: anytype,
) !void {
    var lexer = interpreter.ContentLexer.init(allocator, content);
    var operands: [64]interpreter.Operand = undefined;
    var operand_count: usize = 0;

    var current_font: ?*const encoding.FontEncoding = null;
    var prev_y: f64 = 0;
    var font_size: f64 = 12;

    // Buffer for font cache key lookup
    var key_buf: [64]u8 = undefined;

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
                // Fast path: switch on first character to minimize string comparisons
                if (op.len > 0) switch (op[0]) {
                    'B' => if (op.len == 2 and op[1] == 'T') {},
                    'E' => if (op.len == 2 and op[1] == 'T') {},
                    'T' => if (op.len == 2) switch (op[1]) {
                        'f' => if (operand_count >= 2) {
                            // Set font: /FontName size Tf
                            if (operands[0] == .name) {
                                const font_name = operands[0].name;
                                const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ page_num, font_name }) catch "";
                                current_font = font_cache.getPtr(key);
                            }
                            font_size = operands[1].number;
                        },
                        'd', 'D' => if (operand_count >= 2) {
                            const ty = operands[1].number;
                            if (@abs(ty) > font_size * 0.5 and prev_y != 0) {
                                try writer.writeByte('\n');
                            }
                            prev_y = ty;
                        },
                        'm' => if (operand_count >= 6) {
                            const ty = operands[5].number;
                            if (@abs(ty - prev_y) > font_size * 0.5 and prev_y != 0) {
                                try writer.writeByte('\n');
                            }
                            prev_y = ty;
                        },
                        '*' => {
                            try writer.writeByte('\n');
                        },
                        'j' => if (operand_count >= 1) {
                            try writeTextWithFont(operands[0], current_font, writer);
                        },
                        'J' => if (operand_count >= 1) {
                            try writeTJArrayWithFont(operands[0], current_font, writer);
                        },
                        else => {},
                    },
                    '\'' => if (operand_count >= 1) {
                        try writer.writeByte('\n');
                        try writeTextWithFont(operands[0], current_font, writer);
                    },
                    '"' => if (operand_count >= 3) {
                        try writer.writeByte('\n');
                        try writeTextWithFont(operands[2], current_font, writer);
                    },
                    else => {},
                };

                operand_count = 0;
            },
        }
    }
}

fn writeTextWithFont(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, writer: anytype) !void {
    const data = switch (operand) {
        .string => |s| s,
        .hex_string => |s| s,
        else => return,
    };

    if (font) |enc| {
        try enc.decode(data, writer);
    } else {
        try writeTextOperand(operand, writer);
    }
}

fn writeTJArrayWithFont(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, writer: anytype) !void {
    const arr = switch (operand) {
        .array => |a| a,
        else => return,
    };

    for (arr) |item| {
        switch (item) {
            .string, .hex_string => try writeTextWithFont(item, font, writer),
            .number => |n| {
                if (n < -100) {
                    try writer.writeByte(' ');
                }
            },
            else => {},
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

fn extractTextFromContentWithBounds(
    content: []const u8,
    resources: ?Object.Dict,
    collector: *interpreter.SpanCollector,
    font_cache: *std.StringHashMap(encoding.FontEncoding),
    page_num: usize,
) !void {
    _ = resources;

    var lexer = interpreter.ContentLexer.init(collector.allocator, content);
    var operands: [64]interpreter.Operand = undefined;
    var operand_count: usize = 0;

    var current_x: f64 = 0;
    var current_y: f64 = 0;
    var font_size: f64 = 12;
    var current_font: ?*const encoding.FontEncoding = null;

    // Buffer for font cache key lookup
    var key_buf: [64]u8 = undefined;

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
                if (op.len > 0) switch (op[0]) {
                    'T' => if (op.len == 2) switch (op[1]) {
                        'f' => if (operand_count >= 2) {
                            // Set font: /FontName size Tf
                            if (operands[0] == .name) {
                                const font_name = operands[0].name;
                                // Look up font with page:font_name key
                                const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ page_num, font_name }) catch "";
                                current_font = font_cache.getPtr(key);
                            }
                            font_size = operands[1].number;
                            collector.setFontSize(font_size);
                        },
                        'd', 'D' => if (operand_count >= 2) {
                            current_x += operands[0].number;
                            current_y += operands[1].number;
                            try collector.flush();
                            collector.setPosition(current_x, current_y);
                        },
                        'm' => if (operand_count >= 6) {
                            current_x = operands[4].number;
                            current_y = operands[5].number;
                            try collector.flush();
                            collector.setPosition(current_x, current_y);
                        },
                        '*' => {
                            try collector.flush();
                        },
                        'j' => if (operand_count >= 1) {
                            try writeTextToCollector(operands[0], current_font, collector);
                        },
                        'J' => if (operand_count >= 1) {
                            try writeTJArrayToCollector(operands[0], current_font, collector);
                        },
                        else => {},
                    },
                    '\'' => if (operand_count >= 1) {
                        try collector.flush();
                        try writeTextToCollector(operands[0], current_font, collector);
                    },
                    '"' => if (operand_count >= 3) {
                        try collector.flush();
                        try writeTextToCollector(operands[2], current_font, collector);
                    },
                    else => {},
                };
                operand_count = 0;
            },
        }
    }
}

fn writeTextToCollector(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, collector: *interpreter.SpanCollector) !void {
    const data = switch (operand) {
        .string => |s| s,
        .hex_string => |s| s,
        else => return,
    };

    if (font) |enc| {
        // Use font encoding to decode text
        try enc.decode(data, collector);
    } else {
        // Fallback to simple WinAnsi-ish decoding
        for (data) |byte| {
            if (byte >= 32 and byte < 127) {
                try collector.writeByte(byte);
            } else if (byte == 0) {
                // CID separator - ignore
            } else {
                const codepoint = encoding.win_ansi_encoding[byte];
                if (codepoint != 0 and codepoint < 128) {
                    try collector.writeByte(@truncate(codepoint));
                } else if (codepoint != 0) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch 1;
                    try collector.writeAll(buf[0..len]);
                }
            }
        }
    }
}

fn writeTJArrayToCollector(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, collector: *interpreter.SpanCollector) !void {
    const arr = switch (operand) {
        .array => |a| a,
        else => return,
    };

    for (arr) |item| {
        switch (item) {
            .string, .hex_string => try writeTextToCollector(item, font, collector),
            .number => |n| {
                // TJ spacing: negative = move right (add space), positive = move left (kern)
                if (n < -150) {
                    try collector.flush();
                }
                const adjustment = -n / 1000.0 * collector.current_font_size;
                collector.current_x += adjustment;
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
// Parallel extraction (non-WASM only)
// ============================================================================

const extractAllTextParallelImpl = if (is_wasm) struct {
    fn notAvailable(_: *Document, _: std.mem.Allocator) ![]u8 {
        @compileError("extractAllTextParallel not available on WASM");
    }
}.notAvailable else struct {
    fn impl(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        const num_pages = self.pages.items.len;
        if (num_pages == 0) return try allocator.alloc(u8, 0);

        // Preload all fonts before spawning threads
        for (0..num_pages) |i| {
            self.ensurePageFonts(i);
        }

        // Allocate result buffers for each page
        const results = try allocator.alloc([]u8, num_pages);
        defer allocator.free(results);
        @memset(results, &[_]u8{});

        const Thread = std.Thread;
        const cpu_count = Thread.getCpuCount() catch 4;
        const num_threads: usize = @min(num_pages, @min(cpu_count, 8));

        const Context = struct {
            doc: *Document,
            results: [][]u8,
            alloc: std.mem.Allocator,
        };

        const ctx = Context{
            .doc = self,
            .results = results,
            .alloc = allocator,
        };

        // Thread worker - each thread uses its own arena and cache
        const worker = struct {
            fn run(c: Context, start: usize, end: usize) void {
                // Thread-local arena for all allocations
                var arena = std.heap.ArenaAllocator.init(c.alloc);
                defer arena.deinit();
                const thread_alloc = arena.allocator();

                // Thread-local object cache
                var local_cache = std.AutoHashMap(u32, Object).init(thread_alloc);
                defer local_cache.deinit();

                for (start..end) |page_num| {
                    // Extract directly to fixed buffer to avoid allocations
                    var buf: [65536]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&buf);

                    const page = c.doc.pages.items[page_num];
                    const content = pagetree.getPageContents(
                        thread_alloc,
                        c.doc.data,
                        &c.doc.xref_table,
                        page,
                        &local_cache,
                    ) catch continue;

                    extractTextFromContent(thread_alloc, content, page_num, &c.doc.font_cache, fbs.writer()) catch continue;

                    if (fbs.pos > 0) {
                        c.results[page_num] = c.alloc.dupe(u8, buf[0..fbs.pos]) catch &[_]u8{};
                    }
                }
            }
        }.run;

        // Spawn threads
        var threads: [8]?Thread = [_]?Thread{null} ** 8;
        const pages_per_thread = (num_pages + num_threads - 1) / num_threads;

        for (0..num_threads) |i| {
            const start = i * pages_per_thread;
            const end = @min(start + pages_per_thread, num_pages);
            if (start < end) {
                threads[i] = Thread.spawn(.{}, worker, .{ ctx, start, end }) catch null;
            }
        }

        // Wait for all threads
        for (&threads) |*t| {
            if (t.*) |thread| thread.join();
        }

        // Calculate total size - only count separators between non-empty results
        var total_size: usize = 0;
        var non_empty_count: usize = 0;
        for (results) |r| {
            if (r.len > 0) {
                total_size += r.len;
                non_empty_count += 1;
            }
        }
        if (non_empty_count > 1) {
            total_size += non_empty_count - 1; // separators between non-empty results
        }

        if (total_size == 0) return allocator.alloc(u8, 0);

        var output = try allocator.alloc(u8, total_size);
        var pos: usize = 0;
        var first_written = false;
        for (results) |r| {
            if (r.len > 0) {
                if (first_written) {
                    output[pos] = '\x0c';
                    pos += 1;
                }
                @memcpy(output[pos..][0..r.len], r);
                pos += r.len;
                allocator.free(r);
                first_written = true;
            }
        }

        return output;
    }
}.impl;

// ============================================================================
// TESTS
// ============================================================================

test "ErrorConfig presets" {
    const strict = ErrorConfig.strict();
    try std.testing.expectEqual(@as(u32, 0), strict.max_errors);

    const permissive = ErrorConfig.permissive();
    try std.testing.expect(permissive.continue_on_parse_error);
}

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
pub const structtree = @import("structtree.zig");
pub const markdown = @import("markdown.zig");

// Re-exports
pub const Object = parser.Object;
pub const ObjRef = parser.ObjRef;
pub const XRefTable = xref.XRefTable;
pub const Page = pagetree.Page;
pub const FontEncoding = encoding.FontEncoding;
pub const TextSpan = layout.TextSpan;
pub const LayoutResult = layout.LayoutResult;
pub const StructTree = structtree.StructTree;
pub const StructElement = structtree.StructElement;
pub const MarkdownOptions = markdown.MarkdownOptions;
pub const MarkdownRenderer = markdown.MarkdownRenderer;

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
pub const ParseErrorRecord = struct {
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
    errors: std.ArrayList(ParseErrorRecord),

    /// Pre-resolved font encodings (key: "pageNum:fontName")
    font_cache: std.StringHashMap(encoding.FontEncoding),

    /// Font encoding cache by object ID (avoids re-parsing same font object)
    font_obj_cache: std.AutoHashMap(u32, encoding.FontEncoding),

    /// Cached structure tree reading order (parsed lazily)
    /// Key: page index, Value: list of MCIDs in reading order
    cached_reading_order: ?std.AutoHashMap(usize, std.ArrayList(structtree.MarkedContentRef)) = null,
    reading_order_parsed: bool = false,

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
            .font_obj_cache = std.AutoHashMap(u32, encoding.FontEncoding).init(allocator),
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
            .font_obj_cache = std.AutoHashMap(u32, encoding.FontEncoding).init(allocator),
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
            // Create cache key for page:name lookup
            var key_buf: [64]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ page_idx, entry.key }) catch continue;

            // Skip if already cached for this page
            if (self.font_cache.contains(key)) continue;

            // Check if font value is a reference - we can reuse by object ID
            const font_obj_id: ?u32 = switch (entry.value) {
                .reference => |ref| ref.num,
                else => null,
            };

            // If we've already parsed this object ID, reuse the encoding
            if (font_obj_id) |obj_id| {
                if (self.font_obj_cache.get(obj_id)) |cached_enc| {
                    // Reuse existing encoding - just add new key mapping
                    const owned_key = arena.dupe(u8, key) catch continue;
                    self.font_cache.put(owned_key, cached_enc) catch {};
                    continue;
                }
            }

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

            // Cache by object ID for reuse across pages
            if (font_obj_id) |obj_id| {
                self.font_obj_cache.put(obj_id, enc) catch {};
            }
        }
    }

    /// Close the document and free resources
    pub fn close(self: *Document) void {
        if (self.owns_data and !is_wasm) {
            const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(@ptrCast(@constCast(self.data.ptr)));
            std.posix.munmap(aligned_ptr[0..self.data.len]);
        }

        // Free cached reading order
        if (self.cached_reading_order) |*cache| {
            var it = cache.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            cache.deinit();
        }

        // Free the arena which contains all parsed objects
        self.parsing_arena.deinit();

        self.xref_table.deinit();
        self.object_cache.deinit();
        self.errors.deinit(self.allocator);
        self.pages.deinit(self.allocator);
        self.font_cache.deinit();
        self.font_obj_cache.deinit();

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

        // Extract text with full Form XObject support
        const ctx = ExtractionContext{
            .allocator = arena,
            .data = self.data,
            .xref_table = &self.xref_table,
            .object_cache = &self.object_cache,
            .font_cache = &self.font_cache,
            .page_num = page_num,
            .depth = 0,
        };
        try extractTextFromContentFull(content, page.resources, &ctx, writer);
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

        {
            var nw: NullWriter = .{};
            try extractContentStream(content, .{ .bounds = &collector }, &self.font_cache, page_num, collector.allocator, &nw);
        }
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

    /// Check if the document has a structure tree (is tagged)
    pub fn hasStructureTree(self: *Document) bool {
        const arena = self.parsing_arena.allocator();

        // Get Root from trailer
        const root_ref = switch (self.xref_table.trailer.get("Root") orelse return false) {
            .reference => |r| r,
            else => return false,
        };

        const catalog = pagetree.resolveRef(arena, self.data, &self.xref_table, root_ref, &self.object_cache) catch return false;

        const catalog_dict = switch (catalog) {
            .dict => |d| d,
            else => return false,
        };

        return catalog_dict.get("StructTreeRoot") != null;
    }

    /// Ensure reading order is parsed and cached (called once per document)
    fn ensureReadingOrder(self: *Document) void {
        if (self.reading_order_parsed) return;
        self.reading_order_parsed = true;

        const arena = self.parsing_arena.allocator();

        // Parse structure tree once
        var tree = structtree.parseStructTree(arena, self.data, &self.xref_table, &self.object_cache) catch return;
        defer tree.deinit();

        if (tree.root == null) return;

        // Build page index mapping (object number -> page index)
        var page_obj_to_idx = std.AutoHashMap(u32, usize).init(arena);
        for (self.pages.items, 0..) |p, idx| {
            page_obj_to_idx.put(p.ref.num, idx) catch continue;
        }

        // Get reading order for all pages
        var reading_order = tree.getReadingOrder(arena) catch return;

        // Build per-page reading order cache
        var cache = std.AutoHashMap(usize, std.ArrayList(structtree.MarkedContentRef)).init(self.allocator);
        var has_entries = false;

        var it = reading_order.iterator();
        while (it.next()) |entry| {
            const obj_num = entry.key_ptr.*;
            if (page_obj_to_idx.get(@intCast(obj_num))) |page_idx| {
                var page_mcids = cache.getPtr(page_idx) orelse blk: {
                    cache.put(page_idx, .empty) catch continue;
                    break :blk cache.getPtr(page_idx).?;
                };
                for (entry.value_ptr.items) |mcr| {
                    page_mcids.append(self.allocator, mcr) catch continue;
                    has_entries = true;
                }
            }
        }

        // Only set cache if we have actual entries
        if (has_entries) {
            self.cached_reading_order = cache;
        } else {
            cache.deinit();
        }
    }

    /// Extract text using structure tree reading order (for tagged PDFs)
    /// Falls back to geometric sorting if no structure tree is present
    pub fn extractTextStructured(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        // Ensure reading order is cached (done once per document)
        self.ensureReadingOrder();

        const arena = self.parsing_arena.allocator();
        const page = self.pages.items[page_num];

        // Get content stream
        const content = pagetree.getPageContents(
            arena,
            self.data,
            &self.xref_table,
            page,
            &self.object_cache,
        ) catch return allocator.alloc(u8, 0);

        if (content.len == 0) return allocator.alloc(u8, 0);

        // Lazy-load fonts for this page
        self.ensurePageFonts(page_num);

        // Check if we have cached reading order for this page
        if (self.cached_reading_order) |*cache| {
            if (cache.get(page_num)) |mcids| {
                // Extract text with MCID tracking
                var extractor = structtree.MarkedContentExtractor.init(allocator);
                defer extractor.deinit();

                {
                    var nw: NullWriter = .{};
                    extractContentStream(content, .{ .structured = &extractor }, &self.font_cache, page_num, arena, &nw) catch
                        return self.extractTextGeometric(page_num, allocator);
                }

                // Collect text in structure tree order
                var result: std.ArrayList(u8) = .empty;
                errdefer result.deinit(allocator);
                // Pre-size: ~50 bytes per MCID on average
                try result.ensureTotalCapacity(allocator, mcids.items.len * 50);

                for (mcids.items) |mcr| {
                    if (extractor.getTextForMcid(mcr.mcid)) |text| {
                        if (result.items.len > 0 and text.len > 0) {
                            try result.append(allocator, ' ');
                        }
                        try result.appendSlice(allocator, text);
                    }
                }

                if (result.items.len > 0) {
                    return result.toOwnedSlice(allocator);
                }
                result.deinit(allocator);
            }
        }

        // Fall back to geometric sorting
        return self.extractTextGeometric(page_num, allocator);
    }

    /// Extract text using geometric sorting (fallback when no structure tree)
    /// Simple Y→X sort to match PyMuPDF's sort=True behavior
    fn extractTextGeometric(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        const spans = self.extractTextWithBounds(page_num, allocator) catch |err| {
            // If bounds extraction fails, fall back to stream order
            if (err == error.OutOfMemory) return err;
            return self.extractTextStreamOrder(page_num, allocator);
        };

        if (spans.len == 0) {
            allocator.free(spans);
            return allocator.alloc(u8, 0);
        }
        defer allocator.free(spans);

        return layout.sortGeometric(allocator, spans) catch {
            return self.extractTextStreamOrder(page_num, allocator);
        };
    }

    /// Extract text in raw stream order (last resort fallback)
    fn extractTextStreamOrder(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        // Pre-size for typical page: ~2KB of text
        try output.ensureTotalCapacity(allocator, 2048);

        const arena = self.parsing_arena.allocator();
        const page = self.pages.items[page_num];
        const content = pagetree.getPageContents(arena, self.data, &self.xref_table, page, &self.object_cache) catch return output.toOwnedSlice(allocator);

        self.ensurePageFonts(page_num);
        try extractTextFromContent(arena, content, page_num, &self.font_cache, output.writer(allocator));
        return output.toOwnedSlice(allocator);
    }

    /// Extract text from all pages using structure tree order
    pub fn extractAllTextStructured(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        const num_pages = self.pages.items.len;
        if (num_pages == 0) return allocator.alloc(u8, 0);

        // Skip pre-loading for large documents (lazy load is faster)
        if (num_pages <= 100) {
            // Pre-cache reading order once
            self.ensureReadingOrder();
            // Pre-load all fonts (avoids per-page overhead)
            for (0..num_pages) |i| {
                self.ensurePageFonts(i);
            }
        }

        // Check if we have any structure tree data with actual entries
        const has_structure = if (self.cached_reading_order) |cache| cache.count() > 0 else false;

        // For documents without structure tree, use fast stream order
        if (!has_structure) {
            var result: std.ArrayList(u8) = .empty;
            errdefer result.deinit(allocator);
            // Pre-size buffer: ~2KB average text per page
            try result.ensureTotalCapacity(allocator, num_pages * 2048);

            const arena = self.parsing_arena.allocator();
            for (0..num_pages) |page_num| {
                if (page_num > 0) try result.append(allocator, '\x0c');
                const page = self.pages.items[page_num];
                const content = pagetree.getPageContents(arena, self.data, &self.xref_table, page, &self.object_cache) catch continue;
                if (content.len > 0) {
                    try extractTextFromContent(arena, content, page_num, &self.font_cache, result.writer(allocator));
                }
            }
            return result.toOwnedSlice(allocator);
        }

        // Sequential extraction with structure tree
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        // Pre-size buffer: ~2KB average text per page
        try result.ensureTotalCapacity(allocator, num_pages * 2048);

        const arena = self.parsing_arena.allocator();

        for (0..num_pages) |page_num| {
            if (page_num > 0) try result.append(allocator, '\x0c'); // Form feed

            const page = self.pages.items[page_num];

            // Get content stream
            const content = pagetree.getPageContents(
                arena,
                self.data,
                &self.xref_table,
                page,
                &self.object_cache,
            ) catch continue;

            if (content.len == 0) continue;

            // Check if we have cached reading order for this page
            var used_structure = false;
            if (self.cached_reading_order) |*cache| {
                if (cache.get(page_num)) |mcids| {
                    // Extract text with MCID tracking
                    var extractor = structtree.MarkedContentExtractor.init(allocator);
                    defer extractor.deinit();

                    if (nw_blk: {
                        var nw: NullWriter = .{};
                        break :nw_blk extractContentStream(content, .{ .structured = &extractor }, &self.font_cache, page_num, arena, &nw);
                    }) |_| {
                        // Collect text in structure tree order
                        const start_len = result.items.len;
                        for (mcids.items) |mcr| {
                            if (extractor.getTextForMcid(mcr.mcid)) |text| {
                                if (result.items.len > start_len and text.len > 0 and result.items[result.items.len - 1] != '\x0c') {
                                    try result.append(allocator, ' ');
                                }
                                try result.appendSlice(allocator, text);
                            }
                        }
                        if (result.items.len > start_len) {
                            used_structure = true;
                        }
                    } else |_| {}
                }
            }

            // Fall back to stream order if structure tree didn't produce text
            if (!used_structure) {
                try extractTextFromContent(arena, content, page_num, &self.font_cache, result.writer(allocator));
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Extract text from a page as Markdown
    pub fn extractMarkdown(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        return self.extractMarkdownWithOptions(page_num, allocator, markdown.MarkdownOptions{});
    }

    /// Extract text from a page as Markdown with custom options
    pub fn extractMarkdownWithOptions(
        self: *Document,
        page_num: usize,
        allocator: std.mem.Allocator,
        options: markdown.MarkdownOptions,
    ) ![]u8 {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        const page = self.pages.items[page_num];
        const page_width = page.media_box[2] - page.media_box[0];

        // Extract spans with bounds
        const spans = try self.extractTextWithBounds(page_num, allocator);
        if (spans.len == 0) {
            allocator.free(spans);
            return allocator.alloc(u8, 0);
        }
        defer allocator.free(spans);

        // Render to Markdown
        var renderer = markdown.MarkdownRenderer.init(allocator, options);
        return renderer.render(spans, page_width);
    }

    /// Extract text from all pages as Markdown
    pub fn extractAllMarkdown(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        return self.extractAllMarkdownWithOptions(allocator, markdown.MarkdownOptions{});
    }

    /// Extract text from all pages as Markdown with custom options
    pub fn extractAllMarkdownWithOptions(
        self: *Document,
        allocator: std.mem.Allocator,
        options: markdown.MarkdownOptions,
    ) ![]u8 {
        const num_pages = self.pages.items.len;
        if (num_pages == 0) return allocator.alloc(u8, 0);

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // Pre-size: ~3KB average per page for markdown
        try result.ensureTotalCapacity(allocator, num_pages * 3072);

        for (0..num_pages) |page_num| {
            if (page_num > 0 and options.page_breaks_as_hr) {
                try result.appendSlice(allocator, "\n---\n\n");
            }

            const page_md = self.extractMarkdownWithOptions(page_num, allocator, options) catch continue;
            defer allocator.free(page_md);

            try result.appendSlice(allocator, page_md);
        }

        return result.toOwnedSlice(allocator);
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

/// Context for text extraction (allows Form XObject recursion)
const ExtractionContext = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    xref_table: *const XRefTable,
    object_cache: *std.AutoHashMap(u32, Object),
    font_cache: *const std.StringHashMap(encoding.FontEncoding),
    page_num: usize,
    depth: u8, // Recursion depth for nested Form XObjects

    const MAX_DEPTH: u8 = 10; // Prevent infinite recursion
};

/// Extraction mode: controls how operators are dispatched
const ExtractionMode = union(enum) {
    /// Basic text extraction to writer (supports Form XObjects via Do)
    stream: struct {
        resources: ?Object.Dict,
        ctx: *const ExtractionContext,
    },
    /// Collect spans with bounding boxes
    bounds: *interpreter.SpanCollector,
    /// Track marked content IDs for structure tree reading order
    structured: *structtree.MarkedContentExtractor,
};

/// Try to buffer a token as an operand. Returns true if consumed (not an operator).
fn pushOperand(operands: []interpreter.Operand, count: *usize, token: interpreter.ContentLexer.Token) bool {
    switch (token) {
        .operator => return false,
        .number => |n| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .number = n };
                count.* += 1;
            }
        },
        .string => |s| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .string = s };
                count.* += 1;
            }
        },
        .hex_string => |s| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .hex_string = s };
                count.* += 1;
            }
        },
        .name => |n| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .name = n };
                count.* += 1;
            }
        },
        .array => |a| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .array = a };
                count.* += 1;
            }
        },
    }
    return true;
}

/// Look up a font encoding in the cache by page number and font name.
fn lookupFont(
    font_cache: *const std.StringHashMap(encoding.FontEncoding),
    key_buf: *[64]u8,
    page_num: usize,
    font_name: []const u8,
) ?*const encoding.FontEncoding {
    const key = std.fmt.bufPrint(key_buf, "{d}:{s}", .{ page_num, font_name }) catch return null;
    return font_cache.getPtr(key);
}

/// Extract text from content stream using pre-resolved fonts
fn extractTextFromContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    page_num: usize,
    font_cache: *const std.StringHashMap(encoding.FontEncoding),
    writer: anytype,
) !void {
    // Simple path without Form XObject support (for backward compatibility)
    try extractContentStream(content, .{ .stream = .{
        .resources = null,
        .ctx = &.{
            .allocator = allocator,
            .data = &.{},
            .xref_table = undefined,
            .object_cache = undefined,
            .font_cache = font_cache,
            .page_num = page_num,
            .depth = 0,
        },
    } }, font_cache, page_num, allocator, writer);
}

/// Extract text with full context (supports Form XObjects)
fn extractTextFromContentFull(
    content: []const u8,
    resources: ?Object.Dict,
    ctx: *const ExtractionContext,
    writer: anytype,
) !void {
    try extractContentStream(content, .{ .stream = .{
        .resources = resources,
        .ctx = ctx,
    } }, ctx.font_cache, ctx.page_num, ctx.allocator, writer);
}

/// Unified content stream extraction. All three extraction paths go through this.
fn extractContentStream(
    content: []const u8,
    mode: ExtractionMode,
    font_cache: *const std.StringHashMap(encoding.FontEncoding),
    page_num: usize,
    allocator: std.mem.Allocator,
    writer: anytype,
) !void {
    var lexer = interpreter.ContentLexer.init(allocator, content);
    var operands: [64]interpreter.Operand = undefined;
    var operand_count: usize = 0;

    var current_font: ?*const encoding.FontEncoding = null;
    var prev_x: f64 = 0;
    var prev_y: f64 = 0;
    var current_x: f64 = 0;
    var current_y: f64 = 0;
    var font_size: f64 = 12;

    var key_buf: [64]u8 = undefined;

    // Text buffer for structured mode (MCID tracking)
    var text_buf: [4096]u8 = undefined;
    var text_pos: usize = 0;

    while (try lexer.next()) |token| {
        if (pushOperand(&operands, &operand_count, token)) continue;

        // token is an operator
        const op = token.operator;
        if (op.len > 0) switch (op[0]) {
            'B' => switch (mode) {
                .stream => if (op.len == 2 and op[1] == 'T') {},
                .bounds => {},
                .structured => |extractor| {
                    if (std.mem.eql(u8, op, "BDC")) {
                        if (operand_count >= 2) {
                            const tag = operands[0].asName() orelse "Unknown";
                            const mcid = extractMcidFromDict(operands[1]);
                            try extractor.beginMarkedContent(tag, mcid);
                        }
                    } else if (std.mem.eql(u8, op, "BMC")) {
                        if (operand_count >= 1) {
                            const tag = operands[0].asName() orelse "Unknown";
                            try extractor.beginMarkedContent(tag, null);
                        }
                    }
                },
            },
            'E' => switch (mode) {
                .stream => if (op.len == 2 and op[1] == 'T') {},
                .bounds => {},
                .structured => |extractor| {
                    if (std.mem.eql(u8, op, "EMC")) {
                        extractor.endMarkedContent();
                    }
                },
            },
            'D' => switch (mode) {
                .stream => |s| if (op.len == 2 and op[1] == 'o') {
                    if (operand_count >= 1 and operands[0] == .name) {
                        try handleDoOperator(operands[0].name, s.resources, s.ctx, writer);
                    }
                },
                .bounds, .structured => {},
            },
            'T' => if (op.len == 2) switch (op[1]) {
                'f' => if (operand_count >= 2) {
                    if (operands[0] == .name) {
                        current_font = lookupFont(font_cache, &key_buf, page_num, operands[0].name);
                    }
                    font_size = operands[1].number;
                    if (mode == .bounds) {
                        mode.bounds.setFontSize(font_size);
                    }
                },
                'd', 'D' => if (operand_count >= 2) {
                    switch (mode) {
                        .stream => {
                            const wmode = if (current_font) |f| f.wmode else 0;
                            const displacement = if (wmode == 1) operands[0].number else operands[1].number;
                            if (@abs(displacement) > font_size * 0.5 and prev_y != 0) {
                                try writer.writeByte('\n');
                            }
                            prev_y = operands[1].number;
                        },
                        .bounds => |collector| {
                            current_x += operands[0].number;
                            current_y += operands[1].number;
                            try collector.flush();
                            collector.setPosition(current_x, current_y);
                        },
                        .structured => {},
                    }
                },
                'm' => if (operand_count >= 6) {
                    switch (mode) {
                        .stream => {
                            const wmode = if (current_font) |f| f.wmode else 0;
                            const new_pos = if (wmode == 1) operands[4].number else operands[5].number;
                            const prev_pos = if (wmode == 1) prev_x else prev_y;
                            if (@abs(new_pos - prev_pos) > font_size * 0.5 and prev_pos != 0) {
                                try writer.writeByte('\n');
                            }
                            prev_x = operands[4].number;
                            prev_y = operands[5].number;
                        },
                        .bounds => |collector| {
                            current_x = operands[4].number;
                            current_y = operands[5].number;
                            try collector.flush();
                            collector.setPosition(current_x, current_y);
                        },
                        .structured => {},
                    }
                },
                '*' => switch (mode) {
                    .stream => try writer.writeByte('\n'),
                    .bounds => |collector| try collector.flush(),
                    .structured => {},
                },
                'j' => if (operand_count >= 1) {
                    switch (mode) {
                        .stream => try writeTextWithFont(operands[0], current_font, writer),
                        .bounds => |collector| try writeTextWithFont(operands[0], current_font, collector),
                        .structured => |extractor| {
                            text_pos = 0;
                            writeTextToBuffer(operands[0], current_font, &text_buf, &text_pos);
                            if (text_pos > 0) try extractor.addText(text_buf[0..text_pos]);
                        },
                    }
                },
                'J' => if (operand_count >= 1) {
                    switch (mode) {
                        .stream => try writeTJArrayWithFont(operands[0], current_font, writer),
                        .bounds => |collector| try writeTJArrayToCollector(operands[0], current_font, collector),
                        .structured => |extractor| {
                            text_pos = 0;
                            writeTJArrayToBuffer(operands[0], current_font, &text_buf, &text_pos);
                            if (text_pos > 0) try extractor.addText(text_buf[0..text_pos]);
                        },
                    }
                },
                else => {},
            },
            '\'' => if (operand_count >= 1) {
                switch (mode) {
                    .stream => {
                        try writer.writeByte('\n');
                        try writeTextWithFont(operands[0], current_font, writer);
                    },
                    .bounds => |collector| {
                        try collector.flush();
                        try writeTextWithFont(operands[0], current_font, collector);
                    },
                    .structured => |extractor| {
                        text_pos = 0;
                        writeTextToBuffer(operands[0], current_font, &text_buf, &text_pos);
                        if (text_pos > 0) try extractor.addText(text_buf[0..text_pos]);
                    },
                }
            },
            '"' => if (operand_count >= 3) {
                switch (mode) {
                    .stream => {
                        try writer.writeByte('\n');
                        try writeTextWithFont(operands[2], current_font, writer);
                    },
                    .bounds => |collector| {
                        try collector.flush();
                        try writeTextWithFont(operands[2], current_font, collector);
                    },
                    .structured => |extractor| {
                        text_pos = 0;
                        writeTextToBuffer(operands[2], current_font, &text_buf, &text_pos);
                        if (text_pos > 0) try extractor.addText(text_buf[0..text_pos]);
                    },
                }
            },
            else => {},
        };

        operand_count = 0;
    }
}

/// Handle Do operator - extract text from Form XObjects
fn handleDoOperator(
    xobject_name: []const u8,
    resources: ?Object.Dict,
    ctx: *const ExtractionContext,
    writer: anytype,
) anyerror!void {
    // Check recursion depth
    if (ctx.depth >= ExtractionContext.MAX_DEPTH) return;

    // Need valid context for XObject resolution
    if (ctx.data.len == 0) return;

    // Get XObject dictionary from resources
    const res = resources orelse return;
    const xobjects_obj = res.get("XObject") orelse return;

    // Resolve XObject dictionary if it's a reference
    const xobjects = switch (xobjects_obj) {
        .dict => |d| d,
        .reference => |ref| blk: {
            const resolved = pagetree.resolveRef(ctx.allocator, ctx.data, ctx.xref_table, ref, @constCast(ctx.object_cache)) catch return;
            break :blk switch (resolved) {
                .dict => |d| d,
                else => return,
            };
        },
        else => return,
    };

    // Look up the specific XObject
    const xobj = xobjects.get(xobject_name) orelse return;
    const xobj_resolved = switch (xobj) {
        .stream => |s| s,
        .reference => |ref| blk: {
            const resolved = pagetree.resolveRef(ctx.allocator, ctx.data, ctx.xref_table, ref, @constCast(ctx.object_cache)) catch return;
            break :blk switch (resolved) {
                .stream => |s| s,
                else => return,
            };
        },
        else => return,
    };

    // Check if it's a Form XObject
    const subtype = xobj_resolved.dict.getName("Subtype") orelse return;
    if (!std.mem.eql(u8, subtype, "Form")) return;

    // Decompress the Form XObject content
    const filter = xobj_resolved.dict.get("Filter");
    const params = xobj_resolved.dict.get("DecodeParms");
    const form_content = decompress.decompressStream(ctx.allocator, xobj_resolved.data, filter, params) catch return;
    defer ctx.allocator.free(form_content);

    // Get Form XObject's own resources (may inherit from parent)
    const form_resources = xobj_resolved.dict.getDict("Resources") orelse resources;

    // Recursively extract text with increased depth
    const child_ctx = ExtractionContext{
        .allocator = ctx.allocator,
        .data = ctx.data,
        .xref_table = ctx.xref_table,
        .object_cache = ctx.object_cache,
        .font_cache = ctx.font_cache,
        .page_num = ctx.page_num,
        .depth = ctx.depth + 1,
    };

    extractContentStream(form_content, .{ .stream = .{
        .resources = form_resources,
        .ctx = &child_ctx,
    } }, ctx.font_cache, ctx.page_num, ctx.allocator, writer) catch {};
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
        try writeTextFallback(data, writer);
    }
}

/// WinAnsi fallback decoding for text without font encoding
fn writeTextFallback(data: []const u8, writer: anytype) !void {
    for (data) |byte| {
        if (byte >= 32 and byte < 127) {
            try writer.writeByte(byte);
        } else if (byte == 0) {
            // CID separator
        } else {
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

/// TJ array handler for SpanCollector (needs position tracking on spacing)
fn writeTJArrayToCollector(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, collector: *interpreter.SpanCollector) !void {
    const arr = switch (operand) {
        .array => |a| a,
        else => return,
    };

    for (arr) |item| {
        switch (item) {
            .string, .hex_string => try writeTextWithFont(item, font, collector),
            .number => |n| {
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

/// Extract MCID from a dictionary operand (for BDC)
fn extractMcidFromDict(operand: interpreter.Operand) ?i32 {
    switch (operand) {
        .array => |arr| {
            var i: usize = 0;
            while (i + 1 < arr.len) : (i += 1) {
                if (arr[i] == .name and std.mem.eql(u8, arr[i].name, "MCID")) {
                    if (arr[i + 1] == .number) {
                        return @intFromFloat(arr[i + 1].number);
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

/// Write text to a fixed buffer (for MCID tracking in structured mode)
fn writeTextToBuffer(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, buf: []u8, pos: *usize) void {
    const data = switch (operand) {
        .string => |s| s,
        .hex_string => |s| s,
        else => return,
    };

    if (font) |enc| {
        var bw = BufferWriter{ .buf = buf, .pos = pos };
        enc.decode(data, &bw) catch {};
    } else {
        for (data) |byte| {
            if (pos.* >= buf.len) break;
            if (byte >= 32 and byte < 127) {
                buf[pos.*] = byte;
                pos.* += 1;
            } else if (byte != 0) {
                const codepoint = encoding.win_ansi_encoding[byte];
                if (codepoint != 0 and codepoint < 128) {
                    buf[pos.*] = @truncate(codepoint);
                    pos.* += 1;
                } else if (codepoint != 0) {
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch continue;
                    for (utf8_buf[0..len]) |c| {
                        if (pos.* >= buf.len) break;
                        buf[pos.*] = c;
                        pos.* += 1;
                    }
                }
            }
        }
    }
}

/// Write TJ array to a fixed buffer (for MCID tracking in structured mode)
fn writeTJArrayToBuffer(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, buf: []u8, pos: *usize) void {
    const arr = switch (operand) {
        .array => |a| a,
        else => return,
    };

    for (arr) |item| {
        switch (item) {
            .string, .hex_string => writeTextToBuffer(item, font, buf, pos),
            .number => |n| {
                if (n < -100 and pos.* < buf.len) {
                    buf[pos.*] = ' ';
                    pos.* += 1;
                }
            },
            else => {},
        }
    }
}

/// Simple buffer writer for font decoding into fixed buffers
const BufferWriter = struct {
    buf: []u8,
    pos: *usize,

    pub fn writeAll(self: *BufferWriter, data: []const u8) !void {
        for (data) |c| {
            if (self.pos.* >= self.buf.len) break;
            self.buf[self.pos.*] = c;
            self.pos.* += 1;
        }
    }

    pub fn writeByte(self: *BufferWriter, byte: u8) !void {
        if (self.pos.* < self.buf.len) {
            self.buf[self.pos.*] = byte;
            self.pos.* += 1;
        }
    }

    pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        _ = fmt;
        _ = args;
        _ = self;
    }
};

/// No-op writer used as a dummy when the writer parameter is unused (structured mode)
const NullWriter = struct {
    pub fn writeAll(_: *NullWriter, _: []const u8) !void {}
    pub fn writeByte(_: *NullWriter, _: u8) !void {}
    pub fn print(_: *NullWriter, comptime _: []const u8, _: anytype) !void {}
};

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

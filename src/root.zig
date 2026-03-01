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
const native_os = builtin.os.tag;

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
const is_windows = native_os == .windows;

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
pub const outline = @import("outline.zig");

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
pub const FullTextMode = enum { accuracy, fast };

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
        encrypted,
    };
};

/// PDF Document
pub const Document = struct {
    /// Memory-mapped file data (zero-copy base)
    data: []const u8,
    /// Whether we own the data (mmap'd or allocated)
    owns_data: bool,
    /// Whether data was allocated (Windows) vs mmap'd (POSIX)
    data_is_allocated: bool = false,

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

        if (comptime is_windows) {
            // Windows: read file into allocated memory (no mmap support)
            const data = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), size);
            errdefer allocator.free(data);
            const bytes_read = try file.readAll(data);
            if (bytes_read != size) {
                return error.UnexpectedEof;
            }
            return openFromMemoryOwnedAlloc(allocator, data, config);
        } else {
            // POSIX: memory map the file
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
    }

    /// Open from owned memory (will be freed on close via munmap)
    fn openFromMemoryOwned(allocator: std.mem.Allocator, data: []align(std.heap.page_size_min) u8, config: ErrorConfig) !*Document {
        if (comptime is_wasm) {
            @compileError("openFromMemoryOwned is not available on WASM. Use openFromMemory instead.");
        }

        const doc = try allocator.create(Document);
        errdefer allocator.destroy(doc);

        doc.* = .{
            .data = data,
            .owns_data = true,
            .data_is_allocated = false,
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

    /// Open from owned allocated memory (Windows - will be freed on close via allocator.free)
    fn openFromMemoryOwnedAlloc(allocator: std.mem.Allocator, data: []align(std.heap.page_size_min) u8, config: ErrorConfig) !*Document {
        const doc = try allocator.create(Document);
        errdefer allocator.destroy(doc);

        doc.* = .{
            .data = data,
            .owns_data = true,
            .data_is_allocated = true,
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

    /// Open a PDF from caller-owned memory without copying.
    /// Caller must keep the memory alive until close().
    pub fn openFromMemoryUnsafe(allocator: std.mem.Allocator, data: []const u8, config: ErrorConfig) !*Document {
        const doc = try allocator.create(Document);
        errdefer allocator.destroy(doc);

        doc.* = .{
            .data = data,
            .owns_data = false,
            .data_is_allocated = false,
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

    /// Backward-compatible alias of openFromMemoryUnsafe.
    pub fn openFromMemory(allocator: std.mem.Allocator, data: []const u8, config: ErrorConfig) !*Document {
        return openFromMemoryUnsafe(allocator, data, config);
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

        // Check for encryption
        if (self.xref_table.trailer.get("Encrypt") != null) {
            if (!self.error_config.continue_on_parse_error) {
                return error.EncryptedPdf;
            }
            try self.errors.append(self.allocator, .{
                .kind = .encrypted,
                .offset = 0,
                .message = "PDF is encrypted; text extraction will produce incorrect results",
            });
            // Still parse pages so page_count works, but extraction will be unreliable
        }

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
            var key_buf: [256]u8 = undefined;
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
                    const r: *const Resolver = @ptrCast(@alignCast(ctx));
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
            const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(@constCast(self.data.ptr)));
            if (self.data_is_allocated) {
                // Windows (always) or future POSIX allocated path
                self.allocator.free(aligned_ptr[0..self.data.len]);
            } else if (comptime !is_windows) {
                // POSIX: memory-mapped file
                std.posix.munmap(aligned_ptr[0..self.data.len]);
            }
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

    /// Check if the document is encrypted
    pub fn isEncrypted(self: *const Document) bool {
        return self.xref_table.trailer.get("Encrypt") != null;
    }

    /// Get number of pages
    pub fn pageCount(self: *const Document) usize {
        return self.pages.items.len;
    }

    /// Free spans returned by extractTextWithBounds, including owned text.
    pub fn freeTextSpans(allocator: std.mem.Allocator, spans: []TextSpan) void {
        if (spans.len == 0) return;
        for (spans) |span| {
            if (span.text.len > 0) {
                allocator.free(@constCast(span.text));
            }
        }
        allocator.free(spans);
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
        const parse_allocator = self.parsing_arena.allocator();
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        // Get content stream (allocated from arena, no need to free)
        const content = pagetree.getPageContents(
            parse_allocator,
            scratch_allocator,
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
            .parse_allocator = parse_allocator,
            .scratch_allocator = scratch_allocator,
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
        const parse_allocator = self.parsing_arena.allocator();
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        const content = pagetree.getPageContents(
            parse_allocator,
            scratch_allocator,
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
            try extractContentStream(content, .{ .bounds = &collector }, &self.font_cache, page_num, scratch_allocator, &nw);
        }
        try collector.flush();

        const spans = try collector.toOwnedSlice();
        collector.deinit();
        return spans;
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

        const parse_allocator = self.parsing_arena.allocator();
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();
        const page = self.pages.items[page_num];

        // Get content stream
        const content = pagetree.getPageContents(
            parse_allocator,
            scratch_allocator,
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
                var extractor = structtree.MarkedContentExtractor.init(scratch_allocator);
                defer extractor.deinit();

                {
                    var nw: NullWriter = .{};
                    extractContentStream(content, .{ .structured = &extractor }, &self.font_cache, page_num, scratch_allocator, &nw) catch
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
                    const structured = try result.toOwnedSlice(allocator);
                    const stream_text = self.extractTextStreamOrder(page_num, allocator) catch return structured;
                    defer allocator.free(stream_text);
                    // If structured covers ≥60% of stream content, trust the structure tree order
                    if (structured.len >= stream_text.len * 6 / 10) return structured;
                    // Otherwise fall back to stream order (more complete for partially-tagged PDFs)
                    allocator.free(structured);
                    return try allocator.dupe(u8, stream_text);
                }
                result.deinit(allocator);
            }
        }

        // For untagged content, prefer stream-order extraction first.
        // This generally tracks MuPDF text extraction more closely on large
        // technical PDFs, while keeping geometric extraction as a fallback.
        const stream_text = self.extractTextStreamOrder(page_num, allocator) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.extractTextGeometric(page_num, allocator);
        };
        if (stream_text.len > 0) {
            return stream_text;
        }

        allocator.free(stream_text);
        return self.extractTextGeometric(page_num, allocator);
    }

    /// Extract text using geometric sorting (fallback when no structure tree)
    /// Simple Y→X sort to match PyMuPDF's sort=True behavior
    fn extractTextGeometric(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        // Keep intermediate span allocations in per-call scratch memory to avoid
        // persistent allocator churn on repeated full-document extraction.
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        const spans = self.extractTextWithBounds(page_num, scratch_allocator) catch |err| {
            // If bounds extraction fails, fall back to stream order
            if (err == error.OutOfMemory) return err;
            return self.extractTextStreamOrder(page_num, allocator);
        };

        if (spans.len == 0) {
            return allocator.alloc(u8, 0);
        }

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

        const parse_allocator = self.parsing_arena.allocator();
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();
        const page = self.pages.items[page_num];
        const content = pagetree.getPageContents(parse_allocator, scratch_allocator, self.data, &self.xref_table, page, &self.object_cache) catch return output.toOwnedSlice(allocator);

        self.ensurePageFonts(page_num);
        try extractTextFromContent(scratch_allocator, content, page_num, &self.font_cache, output.writer(allocator));
        return output.toOwnedSlice(allocator);
    }

    /// Extract text from all pages using structure tree order
    pub fn extractAllTextStructured(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        const num_pages = self.pages.items.len;
        if (num_pages == 0) return allocator.alloc(u8, 0);

        // Parse and cache structure tree once for the full document.
        self.ensureReadingOrder();

        // For untagged documents (no structure entries), use stream-order
        // extraction for full-document accuracy mode. This aligns better with
        // MuPDF-style extraction and avoids extra per-page fallback overhead.
        const has_structure_entries = if (self.cached_reading_order) |cache| cache.count() > 0 else false;
        if (!has_structure_entries) {
            return self.extractAllTextFast(allocator);
        }

        // Pre-load all fonts for smaller docs to reduce per-page overhead.
        if (num_pages <= 100) {
            for (0..num_pages) |i| {
                self.ensurePageFonts(i);
            }
        }

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        // Pre-size buffer: ~2KB average text per page
        try result.ensureTotalCapacity(allocator, num_pages * 2048);

        for (0..num_pages) |page_num| {
            if (page_num > 0) try result.append(allocator, '\x0c'); // Form feed
            // Keep per-page extraction intermediates off the caller allocator.
            {
                var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch_arena.deinit();
                const scratch_allocator = scratch_arena.allocator();

                const page_text = self.extractTextStructured(page_num, scratch_allocator) catch continue;
                try result.appendSlice(allocator, page_text);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Extract text from all pages in fast stream-order mode.
    pub fn extractAllTextFast(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        const num_pages = self.pages.items.len;
        if (num_pages == 0) return allocator.alloc(u8, 0);

        // Pre-load fonts for smaller docs to reduce per-page overhead.
        if (num_pages <= 100) {
            for (0..num_pages) |i| {
                self.ensurePageFonts(i);
            }
        }

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, num_pages * 2048);

        const parse_allocator = self.parsing_arena.allocator();

        for (0..num_pages) |page_num| {
            if (page_num > 0) try result.append(allocator, '\x0c');
            {
                var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch_arena.deinit();
                const scratch_allocator = scratch_arena.allocator();

                const page = self.pages.items[page_num];
                const content = pagetree.getPageContents(
                    parse_allocator,
                    scratch_allocator,
                    self.data,
                    &self.xref_table,
                    page,
                    &self.object_cache,
                ) catch continue;

                if (content.len == 0) continue;
                self.ensurePageFonts(page_num);
                try extractTextFromContent(scratch_allocator, content, page_num, &self.font_cache, result.writer(allocator));
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn extractAllTextWithMode(self: *Document, allocator: std.mem.Allocator, mode: FullTextMode) ![]u8 {
        return switch (mode) {
            .accuracy => self.extractAllTextStructured(allocator),
            .fast => self.extractAllTextFast(allocator),
        };
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
            Document.freeTextSpans(allocator, spans);
            return allocator.alloc(u8, 0);
        }
        defer Document.freeTextSpans(allocator, spans);

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

    // =========================================================================
    // Feature 1: Document Metadata (/Info dict)
    // =========================================================================

    pub const DocumentMetadata = struct {
        title: ?[]const u8 = null,
        author: ?[]const u8 = null,
        subject: ?[]const u8 = null,
        keywords: ?[]const u8 = null,
        creator: ?[]const u8 = null,
        producer: ?[]const u8 = null,
        creation_date: ?[]const u8 = null,
        mod_date: ?[]const u8 = null,
    };

    /// Extract document metadata from the /Info dictionary
    pub fn metadata(self: *Document) DocumentMetadata {
        const info_ref = self.xref_table.trailer.get("Info") orelse return .{};
        const dict = switch (info_ref) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = self.resolve(r) catch return .{};
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return .{},
                };
            },
            else => return .{},
        };
        return .{
            .title = dict.getString("Title"),
            .author = dict.getString("Author"),
            .subject = dict.getString("Subject"),
            .keywords = dict.getString("Keywords"),
            .creator = dict.getString("Creator"),
            .producer = dict.getString("Producer"),
            .creation_date = dict.getString("CreationDate"),
            .mod_date = dict.getString("ModDate"),
        };
    }

    // =========================================================================
    // Feature 2: Document Outline / TOC (/Outlines)
    // =========================================================================

    pub const OutlineItem = outline.OutlineItem;

    /// Extract the document outline (table of contents / bookmarks)
    pub fn getOutline(self: *Document, allocator: std.mem.Allocator) ![]OutlineItem {
        return outline.parseOutline(
            allocator,
            self.parsing_arena.allocator(),
            self.data,
            &self.xref_table,
            &self.object_cache,
            self.pages.items,
        );
    }

    // =========================================================================
    // Feature 3: Page Labels (/PageLabels)
    // =========================================================================

    /// Get the display label for a page (e.g., "i", "ii", "1", "2", "A-1")
    /// Caller must free the returned slice.
    pub fn getPageLabel(self: *Document, allocator: std.mem.Allocator, page_idx: usize) ?[]u8 {
        const arena = self.parsing_arena.allocator();

        // Get catalog
        const root_ref = switch (self.xref_table.trailer.get("Root") orelse return null) {
            .reference => |r| r,
            else => return null,
        };
        const catalog = pagetree.resolveRef(arena, self.data, &self.xref_table, root_ref, &self.object_cache) catch return null;
        const catalog_dict = switch (catalog) {
            .dict => |d| d,
            else => return null,
        };

        // Get /PageLabels number tree
        const pl_obj = catalog_dict.get("PageLabels") orelse return null;
        const pl_dict = switch (pl_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch return null;
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return null,
                };
            },
            else => return null,
        };

        // Get /Nums array
        const nums_arr = blk: {
            const nums_obj = pl_dict.get("Nums") orelse return null;
            break :blk switch (nums_obj) {
                .array => |a| a,
                .reference => |r| inner: {
                    const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch return null;
                    break :inner switch (obj) {
                        .array => |a| a,
                        else => return null,
                    };
                },
                else => return null,
            };
        };

        // Find the applicable range entry for page_idx
        // /Nums is [key1 value1 key2 value2 ...] sorted by key
        var best_start: ?usize = null;
        var best_label_dict: ?Object.Dict = null;

        var i: usize = 0;
        while (i + 1 < nums_arr.len) : (i += 2) {
            const start = switch (nums_arr[i]) {
                .integer => |n| @as(usize, @intCast(n)),
                else => continue,
            };
            if (start > page_idx) break;

            const label_obj = switch (nums_arr[i + 1]) {
                .dict => |d| d,
                .reference => |r| inner: {
                    const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch continue;
                    break :inner switch (obj) {
                        .dict => |d| d,
                        else => continue,
                    };
                },
                else => continue,
            };
            best_start = start;
            best_label_dict = label_obj;
        }

        const range_start = best_start orelse return null;
        const label_dict = best_label_dict orelse return null;

        // /St (start value, default 1), /S (style), /P (prefix)
        const st: usize = if (label_dict.getInt("St")) |v| @intCast(v) else 1;
        const page_number = st + (page_idx - range_start);
        const style = label_dict.getName("S");
        const prefix = label_dict.getString("P");

        // Format the label
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        if (prefix) |p| {
            buf.appendSlice(allocator, p) catch return null;
        }

        if (style) |s| {
            if (s.len > 0) switch (s[0]) {
                'D' => {
                    // Decimal
                    buf.writer(allocator).print("{}", .{page_number}) catch return null;
                },
                'r' => {
                    // Lowercase roman
                    formatRoman(&buf, allocator, page_number, false) catch return null;
                },
                'R' => {
                    // Uppercase roman
                    formatRoman(&buf, allocator, page_number, true) catch return null;
                },
                'a' => {
                    // Lowercase alpha
                    formatAlpha(&buf, allocator, page_number, false) catch return null;
                },
                'A' => {
                    // Uppercase alpha
                    formatAlpha(&buf, allocator, page_number, true) catch return null;
                },
                else => {
                    buf.writer(allocator).print("{}", .{page_number}) catch return null;
                },
            };
        }

        if (buf.items.len == 0) {
            // No style, just return prefix or page number
            if (prefix == null) {
                buf.writer(allocator).print("{}", .{page_idx + 1}) catch return null;
            }
        }

        return buf.toOwnedSlice(allocator) catch null;
    }

    fn formatRoman(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, number: usize, upper: bool) !void {
        if (number == 0 or number > 3999) {
            try buf.writer(allocator).print("{}", .{number});
            return;
        }
        const values = [_]struct { v: u16, s_upper: []const u8, s_lower: []const u8 }{
            .{ .v = 1000, .s_upper = "M", .s_lower = "m" },
            .{ .v = 900, .s_upper = "CM", .s_lower = "cm" },
            .{ .v = 500, .s_upper = "D", .s_lower = "d" },
            .{ .v = 400, .s_upper = "CD", .s_lower = "cd" },
            .{ .v = 100, .s_upper = "C", .s_lower = "c" },
            .{ .v = 90, .s_upper = "XC", .s_lower = "xc" },
            .{ .v = 50, .s_upper = "L", .s_lower = "l" },
            .{ .v = 40, .s_upper = "XL", .s_lower = "xl" },
            .{ .v = 10, .s_upper = "X", .s_lower = "x" },
            .{ .v = 9, .s_upper = "IX", .s_lower = "ix" },
            .{ .v = 5, .s_upper = "V", .s_lower = "v" },
            .{ .v = 4, .s_upper = "IV", .s_lower = "iv" },
            .{ .v = 1, .s_upper = "I", .s_lower = "i" },
        };
        var n = number;
        for (values) |entry| {
            while (n >= entry.v) {
                try buf.appendSlice(allocator, if (upper) entry.s_upper else entry.s_lower);
                n -= entry.v;
            }
        }
    }

    fn formatAlpha(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, number: usize, upper: bool) !void {
        if (number == 0) {
            try buf.writer(allocator).print("{}", .{number});
            return;
        }
        // a=1, b=2, ..., z=26, aa=27, ab=28, ...
        var n = number - 1;
        var chars: [8]u8 = undefined;
        var len: usize = 0;
        while (true) {
            const c: u8 = @intCast(n % 26);
            chars[len] = if (upper) 'A' + c else 'a' + c;
            len += 1;
            if (n < 26) break;
            n = n / 26 - 1;
        }
        // Reverse
        var j: usize = 0;
        while (j < len / 2) : (j += 1) {
            const tmp = chars[j];
            chars[j] = chars[len - 1 - j];
            chars[len - 1 - j] = tmp;
        }
        try buf.appendSlice(allocator, chars[0..len]);
    }

    // =========================================================================
    // Feature 4: Text Search
    // =========================================================================

    pub const SearchResult = struct {
        page: usize,
        offset: usize,
        context: []const u8,
    };

    /// Search for text across all pages. Returns matches with page, offset, and context.
    /// Caller must free the returned slice and each context string.
    pub fn search(self: *Document, allocator: std.mem.Allocator, query: []const u8) ![]SearchResult {
        if (query.len == 0) return allocator.alloc(SearchResult, 0);

        var results: std.ArrayList(SearchResult) = .empty;
        errdefer {
            for (results.items) |r| {
                allocator.free(r.context);
            }
            results.deinit(allocator);
        }

        // Lowercase query for case-insensitive search
        const query_lower = try allocator.alloc(u8, query.len);
        defer allocator.free(query_lower);
        for (query, 0..) |c, idx| {
            query_lower[idx] = asciiToLower(c);
        }

        for (0..self.pages.items.len) |page_idx| {
            const page_text = self.extractTextStructured(page_idx, allocator) catch continue;
            defer allocator.free(page_text);

            if (page_text.len == 0) continue;

            // Lowercase page text for comparison
            const text_lower = try allocator.alloc(u8, page_text.len);
            defer allocator.free(text_lower);
            for (page_text, 0..) |c, idx| {
                text_lower[idx] = asciiToLower(c);
            }

            // Find all occurrences
            var pos: usize = 0;
            while (pos + query_lower.len <= text_lower.len) {
                if (std.mem.indexOf(u8, text_lower[pos..], query_lower)) |match_offset| {
                    const abs_offset = pos + match_offset;

                    // Build context snippet (~50 chars before/after)
                    const ctx_start = if (abs_offset > 50) abs_offset - 50 else 0;
                    const ctx_end = @min(abs_offset + query.len + 50, page_text.len);
                    const context = try allocator.dupe(u8, page_text[ctx_start..ctx_end]);

                    try results.append(allocator, .{
                        .page = page_idx,
                        .offset = abs_offset,
                        .context = context,
                    });

                    pos = abs_offset + query_lower.len;
                } else break;
            }
        }

        return results.toOwnedSlice(allocator);
    }

    pub fn freeSearchResults(allocator: std.mem.Allocator, results: []SearchResult) void {
        for (results) |r| {
            allocator.free(r.context);
        }
        allocator.free(results);
    }

    fn asciiToLower(c: u8) u8 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    // =========================================================================
    // Feature 5: Link/Annotation extraction
    // =========================================================================

    pub const Link = struct {
        rect: [4]f64,
        uri: ?[]const u8,
        dest_page: ?usize,
    };

    /// Extract link annotations from a page.
    /// Caller must free the returned slice.
    pub fn getPageLinks(self: *Document, page_idx: usize, allocator: std.mem.Allocator) ![]Link {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;

        const arena = self.parsing_arena.allocator();
        const page = self.pages.items[page_idx];

        const annots_obj = page.dict.get("Annots") orelse return allocator.alloc(Link, 0);

        const annots_arr = switch (annots_obj) {
            .array => |a| a,
            .reference => |r| blk: {
                const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch
                    return allocator.alloc(Link, 0);
                break :blk switch (obj) {
                    .array => |a| a,
                    else => return allocator.alloc(Link, 0),
                };
            },
            else => return allocator.alloc(Link, 0),
        };

        var links: std.ArrayList(Link) = .empty;
        errdefer {
            for (links.items) |link| {
                if (link.uri) |u| allocator.free(u);
            }
            links.deinit(allocator);
        }

        for (annots_arr) |annot_obj| {
            const annot_dict = switch (annot_obj) {
                .dict => |d| d,
                .reference => |r| blk: {
                    const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch continue;
                    break :blk switch (obj) {
                        .dict => |d| d,
                        else => continue,
                    };
                },
                else => continue,
            };

            // Only process /Link annotations
            const subtype = annot_dict.getName("Subtype") orelse continue;
            if (!std.mem.eql(u8, subtype, "Link")) continue;

            // Parse /Rect
            const rect = parseRect(annot_dict) orelse continue;

            // Try /A (action dict) first
            var uri: ?[]const u8 = null;
            var dest_page: ?usize = null;

            if (annot_dict.get("A")) |action_obj| {
                const action = switch (action_obj) {
                    .dict => |d| d,
                    .reference => |r| blk: {
                        const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch null;
                        break :blk if (obj) |o| switch (o) {
                            .dict => |d| d,
                            else => null,
                        } else null;
                    },
                    else => null,
                };

                if (action) |act| {
                    const action_type = act.getName("S");
                    if (action_type) |s| {
                        if (std.mem.eql(u8, s, "URI")) {
                            if (act.getString("URI")) |u| {
                                uri = try allocator.dupe(u8, u);
                            }
                        } else if (std.mem.eql(u8, s, "GoTo")) {
                            // Internal link
                            if (act.get("D")) |d_obj| {
                                dest_page = self.resolveDestToPage(d_obj);
                            }
                        }
                    }
                }
            }

            // Try /Dest if no /A
            if (uri == null and dest_page == null) {
                if (annot_dict.get("Dest")) |dest_obj| {
                    dest_page = self.resolveDestToPage(dest_obj);
                }
            }

            try links.append(allocator, .{
                .rect = rect,
                .uri = uri,
                .dest_page = dest_page,
            });
        }

        return links.toOwnedSlice(allocator);
    }

    pub fn freeLinks(allocator: std.mem.Allocator, links: []Link) void {
        for (links) |link| {
            if (link.uri) |u| allocator.free(u);
        }
        allocator.free(links);
    }

    fn parseRect(dict: Object.Dict) ?[4]f64 {
        const rect_arr = dict.getArray("Rect") orelse return null;
        if (rect_arr.len < 4) return null;
        return .{
            objToF64(rect_arr[0]) orelse return null,
            objToF64(rect_arr[1]) orelse return null,
            objToF64(rect_arr[2]) orelse return null,
            objToF64(rect_arr[3]) orelse return null,
        };
    }

    fn objToF64(obj: Object) ?f64 {
        return switch (obj) {
            .real => |r| r,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    fn resolveDestToPage(self: *Document, dest_obj: Object) ?usize {
        const arena = self.parsing_arena.allocator();
        // Destination can be an array [page_ref /Fit ...] or a name (named dest)
        const arr = switch (dest_obj) {
            .array => |a| a,
            .reference => |r| blk: {
                const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch return null;
                break :blk switch (obj) {
                    .array => |a| a,
                    else => return null,
                };
            },
            else => return null,
        };
        if (arr.len == 0) return null;

        // First element should be a page reference
        const page_ref = switch (arr[0]) {
            .reference => |r| r,
            else => return null,
        };

        // Match against our page list
        for (self.pages.items, 0..) |p, idx| {
            if (p.ref.eql(page_ref)) return idx;
        }
        return null;
    }

    // =========================================================================
    // Feature 6: Image Detection
    // =========================================================================

    pub const ImageInfo = struct {
        rect: [4]f64,
        width: u32,
        height: u32,
    };

    /// Detect images on a page and report their positions and dimensions.
    /// Caller must free the returned slice.
    pub fn getPageImages(self: *Document, page_idx: usize, allocator: std.mem.Allocator) ![]ImageInfo {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;

        const arena = self.parsing_arena.allocator();
        const page = self.pages.items[page_idx];

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        const content = pagetree.getPageContents(
            arena,
            scratch_allocator,
            self.data,
            &self.xref_table,
            page,
            &self.object_cache,
        ) catch return allocator.alloc(ImageInfo, 0);

        if (content.len == 0) return allocator.alloc(ImageInfo, 0);

        // Parse content stream for Do operators and track CTM
        var images: std.ArrayList(ImageInfo) = .empty;
        errdefer images.deinit(allocator);

        var lexer = interpreter.ContentLexer.init(scratch_allocator, content);
        var operands: [128]interpreter.Operand = undefined;
        var operand_count: usize = 0;

        // Simple CTM tracking (only handles cm and basic state)
        var ctm: [6]f64 = .{ 1, 0, 0, 1, 0, 0 }; // identity

        while (try lexer.next()) |token| {
            if (pushOperand(&operands, &operand_count, token)) continue;

            const op = token.operator;
            if (op.len > 0) {
                if (std.mem.eql(u8, op, "cm") and operand_count >= 6) {
                    // Concatenate matrix
                    const new: [6]f64 = .{
                        operands[0].number, operands[1].number,
                        operands[2].number, operands[3].number,
                        operands[4].number, operands[5].number,
                    };
                    ctm = multiplyMatrix(new, ctm);
                } else if (std.mem.eql(u8, op, "Do") and operand_count >= 1 and operands[0] == .name) {
                    // Check if this XObject is an Image
                    if (self.resolveXObjectImage(page, operands[0].name)) |img_info| {
                        // Transform unit square by CTM to get image rect
                        const w: f64 = @floatFromInt(img_info.width);
                        const h: f64 = @floatFromInt(img_info.height);
                        _ = h;
                        _ = w;
                        try images.append(allocator, .{
                            .rect = .{
                                ctm[4], // x0
                                ctm[5], // y0
                                ctm[4] + ctm[0], // x1 (x0 + scale_x)
                                ctm[5] + ctm[3], // y1 (y0 + scale_y)
                            },
                            .width = img_info.width,
                            .height = img_info.height,
                        });
                    }
                }
            }

            operand_count = 0;
        }

        return images.toOwnedSlice(allocator);
    }

    fn multiplyMatrix(a: [6]f64, b: [6]f64) [6]f64 {
        return .{
            a[0] * b[0] + a[1] * b[2],
            a[0] * b[1] + a[1] * b[3],
            a[2] * b[0] + a[3] * b[2],
            a[2] * b[1] + a[3] * b[3],
            a[4] * b[0] + a[5] * b[2] + b[4],
            a[4] * b[1] + a[5] * b[3] + b[5],
        };
    }

    const XObjectImageInfo = struct { width: u32, height: u32 };

    fn resolveXObjectImage(self: *Document, page: Page, name: []const u8) ?XObjectImageInfo {
        const arena = self.parsing_arena.allocator();
        const resources = page.resources orelse return null;

        const xobjects_obj = resources.get("XObject") orelse return null;
        const xobjects = switch (xobjects_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch return null;
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return null,
                };
            },
            else => return null,
        };

        const xobj_obj = xobjects.get(name) orelse return null;
        const xobj_stream = switch (xobj_obj) {
            .stream => |s| s,
            .reference => |r| blk: {
                const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch return null;
                break :blk switch (obj) {
                    .stream => |s| s,
                    else => return null,
                };
            },
            else => return null,
        };

        const subtype = xobj_stream.dict.getName("Subtype") orelse return null;
        if (!std.mem.eql(u8, subtype, "Image")) return null;

        const width: u32 = if (xobj_stream.dict.getInt("Width")) |w| @intCast(w) else return null;
        const height: u32 = if (xobj_stream.dict.getInt("Height")) |h| @intCast(h) else return null;

        return .{ .width = width, .height = height };
    }

    pub fn freeImages(allocator: std.mem.Allocator, images: []ImageInfo) void {
        allocator.free(images);
    }

    // =========================================================================
    // Feature 7: Form Fields (/AcroForm)
    // =========================================================================

    pub const FieldType = enum { text, button, choice, signature, unknown };

    pub const FormField = struct {
        name: []const u8,
        value: ?[]const u8,
        field_type: FieldType,
        rect: ?[4]f64,
    };

    /// Extract form fields from the document's AcroForm.
    /// Caller must free the returned slice and each name/value string.
    pub fn getFormFields(self: *Document, allocator: std.mem.Allocator) ![]FormField {
        const arena = self.parsing_arena.allocator();

        // Get catalog
        const root_ref = switch (self.xref_table.trailer.get("Root") orelse return allocator.alloc(FormField, 0)) {
            .reference => |r| r,
            else => return allocator.alloc(FormField, 0),
        };
        const catalog = pagetree.resolveRef(arena, self.data, &self.xref_table, root_ref, &self.object_cache) catch
            return allocator.alloc(FormField, 0);
        const catalog_dict = switch (catalog) {
            .dict => |d| d,
            else => return allocator.alloc(FormField, 0),
        };

        // Get /AcroForm dict
        const acroform_obj = catalog_dict.get("AcroForm") orelse return allocator.alloc(FormField, 0);
        const acroform = switch (acroform_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch
                    return allocator.alloc(FormField, 0);
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return allocator.alloc(FormField, 0),
                };
            },
            else => return allocator.alloc(FormField, 0),
        };

        // Get /Fields array
        const fields_obj = acroform.get("Fields") orelse return allocator.alloc(FormField, 0);
        const fields_arr = switch (fields_obj) {
            .array => |a| a,
            .reference => |r| blk: {
                const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch
                    return allocator.alloc(FormField, 0);
                break :blk switch (obj) {
                    .array => |a| a,
                    else => return allocator.alloc(FormField, 0),
                };
            },
            else => return allocator.alloc(FormField, 0),
        };

        var results: std.ArrayList(FormField) = .empty;
        errdefer {
            for (results.items) |f| {
                allocator.free(f.name);
                if (f.value) |v| allocator.free(v);
            }
            results.deinit(allocator);
        }

        // Walk fields (may have /Kids for hierarchical fields)
        for (fields_arr) |field_obj| {
            try self.collectFormFields(allocator, arena, field_obj, "", &results);
        }

        return results.toOwnedSlice(allocator);
    }

    fn collectFormFields(
        self: *Document,
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        field_obj: Object,
        parent_name: []const u8,
        results: *std.ArrayList(FormField),
    ) !void {
        const field_dict = switch (field_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch return;
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return,
                };
            },
            else => return,
        };

        // Build full name: parent.child
        const partial_name = field_dict.getString("T") orelse "";
        const full_name = if (parent_name.len > 0 and partial_name.len > 0) blk: {
            const name = try allocator.alloc(u8, parent_name.len + 1 + partial_name.len);
            @memcpy(name[0..parent_name.len], parent_name);
            name[parent_name.len] = '.';
            @memcpy(name[parent_name.len + 1 ..], partial_name);
            break :blk name;
        } else if (partial_name.len > 0)
            try allocator.dupe(u8, partial_name)
        else
            try allocator.dupe(u8, parent_name);

        // Check for /Kids (hierarchical field)
        if (field_dict.get("Kids")) |kids_obj| {
            const kids_arr = switch (kids_obj) {
                .array => |a| a,
                .reference => |r| blk: {
                    const obj = pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch {
                        allocator.free(full_name);
                        return;
                    };
                    break :blk switch (obj) {
                        .array => |a| a,
                        else => {
                            allocator.free(full_name);
                            return;
                        },
                    };
                },
                else => {
                    allocator.free(full_name);
                    return;
                },
            };

            for (kids_arr) |kid| {
                try self.collectFormFields(allocator, arena, kid, full_name, results);
            }
            allocator.free(full_name);
            return;
        }

        // Leaf field: extract type, value, rect
        const ft_name = field_dict.getName("FT");
        const field_type: FieldType = if (ft_name) |ft|
            if (std.mem.eql(u8, ft, "Tx"))
                .text
            else if (std.mem.eql(u8, ft, "Btn"))
                .button
            else if (std.mem.eql(u8, ft, "Ch"))
                .choice
            else if (std.mem.eql(u8, ft, "Sig"))
                .signature
            else
                .unknown
        else
            .unknown;

        const value = if (field_dict.getString("V")) |v|
            try allocator.dupe(u8, v)
        else
            null;

        const rect = parseRect(field_dict);

        try results.append(allocator, .{
            .name = full_name,
            .value = value,
            .field_type = field_type,
            .rect = rect,
        });
    }

    pub fn freeFormFields(allocator: std.mem.Allocator, fields: []FormField) void {
        for (fields) |f| {
            allocator.free(f.name);
            if (f.value) |v| allocator.free(v);
        }
        allocator.free(fields);
    }
};

/// Decode a PDF string that may be UTF-16BE (BOM-prefixed) into UTF-8.
/// If the string starts with \xFE\xFF it's UTF-16BE; otherwise it's
/// PDFDocEncoding (≈ Latin-1 for the printable range).
/// Caller owns the returned slice.
pub fn decodePdfString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Check for UTF-16BE BOM
    if (raw.len >= 2 and raw[0] == 0xFE and raw[1] == 0xFF) {
        const payload = raw[2..]; // skip BOM
        const n_units = payload.len / 2;

        // Decode UTF-16BE to UTF-8
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, n_units * 3); // worst case

        var i: usize = 0;
        while (i + 1 < payload.len) {
            const hi: u16 = @as(u16, payload[i]) << 8;
            const lo: u16 = payload[i + 1];
            const unit: u16 = hi | lo;
            i += 2;

            var codepoint: u21 = undefined;
            if (unit >= 0xD800 and unit <= 0xDBFF) {
                // High surrogate — need low surrogate
                if (i + 1 < payload.len) {
                    const hi2: u16 = @as(u16, payload[i]) << 8;
                    const lo2: u16 = payload[i + 1];
                    const unit2: u16 = hi2 | lo2;
                    i += 2;
                    if (unit2 >= 0xDC00 and unit2 <= 0xDFFF) {
                        codepoint = 0x10000 + (@as(u21, unit - 0xD800) << 10) + @as(u21, unit2 - 0xDC00);
                    } else {
                        codepoint = 0xFFFD; // replacement
                    }
                } else {
                    codepoint = 0xFFFD;
                }
            } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
                codepoint = 0xFFFD; // unpaired low surrogate
            } else {
                codepoint = unit;
            }

            // Encode as UTF-8
            if (codepoint < 0x80) {
                try result.append(allocator, @intCast(codepoint));
            } else if (codepoint < 0x800) {
                try result.append(allocator, @intCast(0xC0 | (codepoint >> 6)));
                try result.append(allocator, @intCast(0x80 | (codepoint & 0x3F)));
            } else if (codepoint < 0x10000) {
                try result.append(allocator, @intCast(0xE0 | (codepoint >> 12)));
                try result.append(allocator, @intCast(0x80 | ((codepoint >> 6) & 0x3F)));
                try result.append(allocator, @intCast(0x80 | (codepoint & 0x3F)));
            } else {
                try result.append(allocator, @intCast(0xF0 | (codepoint >> 18)));
                try result.append(allocator, @intCast(0x80 | ((codepoint >> 12) & 0x3F)));
                try result.append(allocator, @intCast(0x80 | ((codepoint >> 6) & 0x3F)));
                try result.append(allocator, @intCast(0x80 | (codepoint & 0x3F)));
            }
        }

        return result.toOwnedSlice(allocator);
    }

    // Not UTF-16BE — treat as PDFDocEncoding (Latin-1 compatible for ASCII).
    // For bytes 128-255, encode as UTF-8.
    var needs_encoding = false;
    for (raw) |c| {
        if (c >= 0x80) {
            needs_encoding = true;
            break;
        }
    }

    if (!needs_encoding) {
        return allocator.dupe(u8, raw);
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, raw.len * 2);

    for (raw) |c| {
        if (c < 0x80) {
            try result.append(allocator, c);
        } else {
            // Latin-1 to UTF-8
            try result.append(allocator, 0xC0 | (c >> 6));
            try result.append(allocator, 0x80 | (c & 0x3F));
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Context for text extraction (allows Form XObject recursion)
const ExtractionContext = struct {
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
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
    /// Basic text extraction to writer (supports Form XObjects via Do).
    /// ctx is null when no XObject resolution is needed (e.g. simple text-only paths).
    stream: struct {
        resources: ?Object.Dict,
        ctx: ?*const ExtractionContext,
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
    key_buf: *[256]u8,
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
    // Simple path without Form XObject support - null ctx skips Do handling
    try extractContentStream(content, .{ .stream = .{
        .resources = null,
        .ctx = null,
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
    } }, ctx.font_cache, ctx.page_num, ctx.scratch_allocator, writer);
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
    var operands: [128]interpreter.Operand = undefined;
    var operand_count: usize = 0;

    var current_font: ?*const encoding.FontEncoding = null;
    var prev_x: f64 = 0;
    var prev_y: f64 = 0;
    var current_x: f64 = 0;
    var current_y: f64 = 0;
    var font_size: f64 = 12;
    // Track the font size of the last shown text for newline threshold.
    // Superscripts/subscripts switch to a smaller Tf *before* their Tm, so
    // using raw font_size would make the threshold too small and produce
    // spurious newlines for every super/subscript.
    var last_text_font_size: f64 = 12;

    var key_buf: [256]u8 = undefined;

    // Text buffer for structured mode (MCID tracking).
    // Spans longer than MCID_TEXT_BUF_SIZE bytes are silently truncated.
    const MCID_TEXT_BUF_SIZE = 4096;
    var text_buf: [MCID_TEXT_BUF_SIZE]u8 = undefined;
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
                            const mcid = extractMcidFromOperands(operands[0..operand_count], 1);
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
                            // Use max(font_size, last_text_font_size) so that a small
                            // superscript font doesn't shrink the line-break threshold
                            // below the displacement used for super/subscript positioning.
                            const ref_size = @max(font_size, last_text_font_size);
                            if (@abs(displacement) > ref_size * 0.7 and prev_y != 0) {
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
                            const ref_size = @max(font_size, last_text_font_size);
                            if (@abs(new_pos - prev_pos) > ref_size * 0.7 and prev_pos != 0) {
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
                        .stream => {
                            try writeTextWithFont(operands[0], current_font, writer);
                            last_text_font_size = font_size;
                        },
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
                        .stream => {
                            try writeTJArrayWithFont(operands[0], current_font, writer);
                            last_text_font_size = font_size;
                        },
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
                        last_text_font_size = font_size;
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
                        last_text_font_size = font_size;
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
    maybe_ctx: ?*const ExtractionContext,
    writer: anytype,
) anyerror!void {
    // No context means XObject resolution is unavailable; skip silently
    const ctx = maybe_ctx orelse return;

    // Check recursion depth
    if (ctx.depth >= ExtractionContext.MAX_DEPTH) return;

    // Get XObject dictionary from resources
    const res = resources orelse return;
    const xobjects_obj = res.get("XObject") orelse return;

    // Resolve XObject dictionary if it's a reference
    const xobjects = switch (xobjects_obj) {
        .dict => |d| d,
        .reference => |ref| blk: {
            const resolved = pagetree.resolveRef(ctx.parse_allocator, ctx.data, ctx.xref_table, ref, @constCast(ctx.object_cache)) catch return;
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
            const resolved = pagetree.resolveRef(ctx.parse_allocator, ctx.data, ctx.xref_table, ref, @constCast(ctx.object_cache)) catch return;
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
    const form_content = decompress.decompressStream(ctx.scratch_allocator, xobj_resolved.data, filter, params) catch return;
    defer ctx.scratch_allocator.free(form_content);

    // Get Form XObject's own resources (may inherit from parent)
    const form_resources = xobj_resolved.dict.getDict("Resources") orelse resources;

    // Recursively extract text with increased depth
    const child_ctx = ExtractionContext{
        .parse_allocator = ctx.parse_allocator,
        .scratch_allocator = ctx.scratch_allocator,
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
    } }, ctx.font_cache, ctx.page_num, ctx.scratch_allocator, writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        // Domain errors (corrupt/unsupported stream): skip silently
    };
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

/// Extract MCID from flattened BDC operands.
/// Supports:
/// 1. Array-shaped dictionary tokens
/// 2. Flattened name/value token pairs (... /MCID 12 ...)
fn extractMcidFromOperands(operands: []const interpreter.Operand, property_start: usize) ?i32 {
    if (property_start >= operands.len) return null;

    // First try existing array-based extraction on the property operand.
    if (extractMcidFromDict(operands[property_start])) |mcid| return mcid;

    // Fallback: scan flattened key/value pairs.
    var i = property_start;
    while (i + 1 < operands.len) : (i += 1) {
        if (operands[i] == .name and std.mem.eql(u8, operands[i].name, "MCID")) {
            if (operands[i + 1] == .number) {
                return @intFromFloat(operands[i + 1].number);
            }
        }
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

test "allocated memory path cleanup" {
    // This test exercises the Windows-style allocated memory path
    // to ensure data_is_allocated=true cleanup works correctly.
    // On Windows, openWithConfig uses alignedAlloc instead of mmap.
    const allocator = std.testing.allocator;
    const testpdf = @import("testpdf.zig");

    // Generate test PDF data
    const pdf_data = try testpdf.generateMinimalPdf(allocator, "AllocTest");
    defer allocator.free(pdf_data);

    // Create page-aligned copy (simulates Windows file read path)
    const aligned_data = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), pdf_data.len);
    @memcpy(aligned_data, pdf_data);
    // Note: don't defer free - Document takes ownership

    // Use the allocated memory path (exercises data_is_allocated=true)
    const doc = try Document.openFromMemoryOwnedAlloc(allocator, aligned_data, ErrorConfig.default());
    defer doc.close(); // This must free aligned_data via allocator.free()

    // Verify document parsed correctly
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
}

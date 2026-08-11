//! Markdown Renderer for PDF Text Extraction
//!
//! Converts PDF text spans into Markdown format with semantic detection:
//! - Headings: Based on font size relative to body text
//! - Paragraphs: Based on vertical spacing
//! - Lists: Based on indentation and bullet/number patterns
//! - Tables: Based on column alignment
//! - Bold/Italic: Based on font name patterns
//! - Code blocks: Based on monospace font detection
//!
//! Integrates with structure tree for tagged PDFs.

const std = @import("std");
const layout = @import("layout.zig");
const structtree = @import("structtree.zig");

pub const TextSpan = layout.TextSpan;
pub const LayoutResult = layout.LayoutResult;

/// Configuration options for Markdown rendering
pub const MarkdownOptions = struct {
    /// Detect headings from font size ratio (heading_size / body_size)
    detect_headings: bool = true,
    /// Minimum font size ratio to be considered H1
    h1_ratio: f64 = 1.8,
    /// Minimum font size ratio to be considered H2
    h2_ratio: f64 = 1.5,
    /// Minimum font size ratio to be considered H3
    h3_ratio: f64 = 1.3,
    /// Detect bold/italic from font names
    detect_emphasis: bool = true,
    /// Detect code blocks from monospace fonts
    detect_code: bool = true,
    /// Detect lists from indentation patterns
    detect_lists: bool = true,
    /// Detect tables from column alignment
    detect_tables: bool = true,
    /// Include page breaks as horizontal rules
    page_breaks_as_hr: bool = true,
    /// Wrap lines at this column (0 = no wrap)
    wrap_column: usize = 0,
};

/// A processed text element with semantic information
pub const TextElement = struct {
    /// Element type
    kind: Kind,
    /// Text content
    text: []const u8,
    /// Indentation level (for lists)
    indent_level: u8 = 0,
    /// Font characteristics
    is_bold: bool = false,
    is_italic: bool = false,
    is_monospace: bool = false,
    /// Original span for reference
    span: ?TextSpan = null,

    pub const Kind = enum {
        heading1,
        heading2,
        heading3,
        heading4,
        heading5,
        heading6,
        paragraph,
        list_item_bullet,
        list_item_number,
        table_row,
        code_block,
        code_inline,
        blockquote,
        horizontal_rule,
        line_break,
    };
};

/// Markdown renderer
pub const MarkdownRenderer = struct {
    allocator: std.mem.Allocator,
    options: MarkdownOptions,

    /// Statistics for font size analysis
    body_font_size: f64 = 12.0,
    min_font_size: f64 = 1000.0,
    max_font_size: f64 = 0.0,

    /// Monospace font patterns (case-insensitive matching)
    const monospace_patterns = [_][]const u8{
        "courier",
        "consola",
        "mono",
        "menlo",
        "source code",
        "fira code",
        "jetbrains",
        "inconsolata",
        "roboto mono",
        "ubuntu mono",
        "dejavu sans mono",
        "liberation mono",
        "fixed",
    };

    /// Bold font patterns
    const bold_patterns = [_][]const u8{
        "bold",
        "black",
        "heavy",
        "extrabold",
        "semibold",
        "demibold",
    };

    /// Italic font patterns
    const italic_patterns = [_][]const u8{
        "italic",
        "oblique",
        "slant",
    };

    /// Bullet patterns for list detection
    const bullet_patterns = [_][]const u8{
        "•",
        "●",
        "○",
        "■",
        "□",
        "▪",
        "▫",
        "-",
        "*",
        "–",
        "—",
    };

    pub fn init(allocator: std.mem.Allocator, options: MarkdownOptions) MarkdownRenderer {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Render spans to Markdown
    pub fn render(self: *MarkdownRenderer, spans: []const TextSpan, page_width: f64) ![]u8 {
        if (spans.len == 0) return try self.allocator.alloc(u8, 0);

        // Analyze font sizes to determine body text size
        self.analyzeFontSizes(spans);

        // Analyze layout
        var layout_result = try layout.analyzeLayout(self.allocator, spans, page_width);
        defer layout_result.deinit();

        // Convert to semantic elements
        const elements = try self.spansToElements(layout_result.spans);
        defer self.allocator.free(elements);

        // Render elements to Markdown
        return self.renderElements(elements);
    }

    /// Render from pre-analyzed layout
    pub fn renderFromLayout(self: *MarkdownRenderer, layout_result: *const LayoutResult) ![]u8 {
        if (layout_result.spans.len == 0) return try self.allocator.alloc(u8, 0);

        self.analyzeFontSizes(layout_result.spans);

        const elements = try self.spansToElements(layout_result.spans);
        defer self.allocator.free(elements);

        return self.renderElements(elements);
    }

    /// Analyze font sizes to determine body text size (most common)
    fn analyzeFontSizes(self: *MarkdownRenderer, spans: []const TextSpan) void {
        if (spans.len == 0) return;

        // Use a histogram approach - bucket font sizes
        var size_counts = std.AutoHashMap(i32, usize).init(self.allocator);
        defer size_counts.deinit();

        for (spans) |span| {
            const size_key: i32 = @intFromFloat(span.font_size * 10); // 0.1pt precision
            const entry = size_counts.getOrPut(size_key) catch continue;
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += span.text.len; // Weight by text length

            self.min_font_size = @min(self.min_font_size, span.font_size);
            self.max_font_size = @max(self.max_font_size, span.font_size);
        }

        // Find most common size (body text)
        var max_count: usize = 0;
        var body_size_key: i32 = 120; // Default 12pt

        var it = size_counts.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > max_count) {
                max_count = entry.value_ptr.*;
                body_size_key = entry.key_ptr.*;
            }
        }

        self.body_font_size = @as(f64, @floatFromInt(body_size_key)) / 10.0;
    }

    /// Convert spans to semantic elements
    fn spansToElements(self: *MarkdownRenderer, spans: []const TextSpan) ![]TextElement {
        var elements: std.ArrayList(TextElement) = .empty;
        errdefer elements.deinit(self.allocator);

        if (spans.len == 0) return elements.toOwnedSlice(self.allocator);

        // Sort spans by Y descending (top to bottom in PDF), then X ascending
        const sorted = try self.allocator.alloc(TextSpan, spans.len);
        defer self.allocator.free(sorted);
        @memcpy(sorted, spans);

        const line_threshold: f64 = 3.0;
        std.mem.sort(TextSpan, sorted, line_threshold, struct {
            fn cmp(threshold: f64, a: TextSpan, b: TextSpan) bool {
                const a_row = @as(i64, @intFromFloat(a.y0 / threshold));
                const b_row = @as(i64, @intFromFloat(b.y0 / threshold));
                if (a_row != b_row) return a_row > b_row; // Higher Y first (top of page)
                return a.x0 < b.x0; // Left to right within row
            }
        }.cmp);

        var prev_y: f64 = sorted[0].y0;
        var current_line: std.ArrayList(u8) = .empty;
        defer current_line.deinit(self.allocator);

        var current_kind: TextElement.Kind = .paragraph;
        var current_indent: f64 = 0;
        var line_start_x: f64 = 0;
        var is_first_in_line = true;

        const elem_line_threshold: f64 = 3.0;
        const para_gap_threshold = self.body_font_size * 1.2;

        for (sorted, 0..) |span, i| {
            const y_diff = @abs(span.y0 - prev_y);

            // New line or paragraph?
            if (i > 0 and y_diff > elem_line_threshold) {
                // Flush current line
                if (current_line.items.len > 0) {
                    const text = try self.allocator.dupe(u8, current_line.items);
                    try elements.append(self.allocator, .{
                        .kind = current_kind,
                        .text = text,
                        .indent_level = self.indentLevel(current_indent),
                        .span = sorted[i - 1],
                    });
                    current_line.clearRetainingCapacity();
                }

                // Large gap = paragraph break
                if (y_diff > para_gap_threshold and elements.items.len > 0) {
                    try elements.append(self.allocator, .{
                        .kind = .line_break,
                        .text = "",
                    });
                }

                is_first_in_line = true;
                current_kind = .paragraph;
            }

            // Detect element type
            if (is_first_in_line) {
                line_start_x = span.x0;
                current_indent = span.x0;

                // Check for heading (large font)
                if (self.options.detect_headings) {
                    const ratio = span.font_size / self.body_font_size;
                    if (ratio >= self.options.h1_ratio) {
                        current_kind = .heading1;
                    } else if (ratio >= self.options.h2_ratio) {
                        current_kind = .heading2;
                    } else if (ratio >= self.options.h3_ratio) {
                        current_kind = .heading3;
                    }
                }

                // Check for list (bullet pattern)
                if (self.options.detect_lists and current_kind == .paragraph) {
                    if (self.isBulletText(span.text)) {
                        current_kind = .list_item_bullet;
                    } else if (self.isNumberedItem(span.text)) {
                        current_kind = .list_item_number;
                    }
                }

                // Check for code (monospace font)
                // Font name isn't available in TextSpan, so we'd need extended info
                // For now, detect by indentation pattern typical of code

                is_first_in_line = false;
            }

            // Add space between words on same line
            if (current_line.items.len > 0 and !is_first_in_line) {
                const prev_span = sorted[i - 1];
                const gap = span.x0 - prev_span.x1;
                // Use smaller threshold - typical space is 25-33% of em, kerning is <10%
                const space_threshold = prev_span.font_size * 0.15;
                if (gap > space_threshold) {
                    try current_line.append(self.allocator, ' ');
                }
            }

            // Add text
            try current_line.appendSlice(self.allocator, span.text);
            prev_y = span.y0;
        }

        // Flush final line
        if (current_line.items.len > 0) {
            const text = try self.allocator.dupe(u8, current_line.items);
            try elements.append(self.allocator, .{
                .kind = current_kind,
                .text = text,
                .indent_level = self.indentLevel(current_indent),
                .span = if (sorted.len > 0) sorted[sorted.len - 1] else null,
            });
        }

        return elements.toOwnedSlice(self.allocator);
    }

    /// Render elements to Markdown text
    fn renderElements(self: *MarkdownRenderer, elements: []const TextElement) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);

        var prev_kind: ?TextElement.Kind = null;

        for (elements) |elem| {
            // Add spacing between different element types
            if (prev_kind) |pk| {
                const needs_blank = switch (elem.kind) {
                    .heading1, .heading2, .heading3, .heading4, .heading5, .heading6 => true,
                    .paragraph => pk != .paragraph and pk != .line_break,
                    .list_item_bullet, .list_item_number => pk != .list_item_bullet and pk != .list_item_number,
                    .code_block => true,
                    .line_break => false,
                    else => false,
                };
                if (needs_blank and output.items.len > 0) {
                    try output.append(self.allocator, '\n');
                }
            }

            switch (elem.kind) {
                .heading1 => {
                    try output.appendSlice(self.allocator, "# ");
                    try output.appendSlice(self.allocator, elem.text);
                    try output.append(self.allocator, '\n');
                },
                .heading2 => {
                    try output.appendSlice(self.allocator, "## ");
                    try output.appendSlice(self.allocator, elem.text);
                    try output.append(self.allocator, '\n');
                },
                .heading3 => {
                    try output.appendSlice(self.allocator, "### ");
                    try output.appendSlice(self.allocator, elem.text);
                    try output.append(self.allocator, '\n');
                },
                .heading4 => {
                    try output.appendSlice(self.allocator, "#### ");
                    try output.appendSlice(self.allocator, elem.text);
                    try output.append(self.allocator, '\n');
                },
                .heading5 => {
                    try output.appendSlice(self.allocator, "##### ");
                    try output.appendSlice(self.allocator, elem.text);
                    try output.append(self.allocator, '\n');
                },
                .heading6 => {
                    try output.appendSlice(self.allocator, "###### ");
                    try output.appendSlice(self.allocator, elem.text);
                    try output.append(self.allocator, '\n');
                },
                .paragraph => {
                    try output.appendSlice(self.allocator, elem.text);
                    try output.append(self.allocator, '\n');
                },
                .list_item_bullet => {
                    // Add indentation
                    var indent: u8 = 0;
                    while (indent < elem.indent_level) : (indent += 1) {
                        try output.appendSlice(self.allocator, "  ");
                    }
                    try output.appendSlice(self.allocator, "- ");
                    // Strip bullet character from text
                    const text = self.stripBullet(elem.text);
                    try output.appendSlice(self.allocator, text);
                    try output.append(self.allocator, '\n');
                },
                .list_item_number => {
                    var indent: u8 = 0;
                    while (indent < elem.indent_level) : (indent += 1) {
                        try output.appendSlice(self.allocator, "  ");
                    }
                    // Keep original numbering or normalize
                    const text = self.stripNumberPrefix(elem.text);
                    try output.appendSlice(self.allocator, "1. ");
                    try output.appendSlice(self.allocator, text);
                    try output.append(self.allocator, '\n');
                },
                .table_row => {
                    try output.appendSlice(self.allocator, "| ");
                    try output.appendSlice(self.allocator, elem.text);
                    try output.appendSlice(self.allocator, " |\n");
                },
                .code_block => {
                    try output.appendSlice(self.allocator, "```\n");
                    try output.appendSlice(self.allocator, elem.text);
                    try output.appendSlice(self.allocator, "\n```\n");
                },
                .code_inline => {
                    try output.append(self.allocator, '`');
                    try output.appendSlice(self.allocator, elem.text);
                    try output.append(self.allocator, '`');
                },
                .blockquote => {
                    try output.appendSlice(self.allocator, "> ");
                    try output.appendSlice(self.allocator, elem.text);
                    try output.append(self.allocator, '\n');
                },
                .horizontal_rule => {
                    try output.appendSlice(self.allocator, "\n---\n\n");
                },
                .line_break => {
                    try output.append(self.allocator, '\n');
                },
            }

            prev_kind = elem.kind;
        }

        return output.toOwnedSlice(self.allocator);
    }

    /// Calculate indentation level from X position
    fn indentLevel(self: *MarkdownRenderer, x: f64) u8 {
        _ = self;
        const indent_unit: f64 = 36; // ~0.5 inch
        const level = @as(u8, @intFromFloat(@max(0, x / indent_unit)));
        return @min(level, 6);
    }

    /// Check if text starts with a bullet character
    fn isBulletText(_: *MarkdownRenderer, text: []const u8) bool {
        if (text.len == 0) return false;

        // Check for common bullet patterns
        for (bullet_patterns) |pattern| {
            if (std.mem.startsWith(u8, text, pattern)) {
                return true;
            }
        }

        return false;
    }

    /// Check if text starts with a number pattern (e.g., "1.", "a)", "(i)")
    fn isNumberedItem(_: *MarkdownRenderer, text: []const u8) bool {
        if (text.len < 2) return false;

        var i: usize = 0;

        // Skip leading paren
        if (text[0] == '(') i += 1;

        // Check for digits or letters
        while (i < text.len and i < 5) {
            const c = text[i];
            if ((c >= '0' and c <= '9') or
                (c >= 'a' and c <= 'z') or
                (c >= 'A' and c <= 'Z'))
            {
                i += 1;
            } else {
                break;
            }
        }

        if (i == 0 or i >= text.len) return false;

        // Check for separator (. or ) or :)
        const sep = text[i];
        return sep == '.' or sep == ')' or sep == ':';
    }

    /// Strip bullet character from text
    fn stripBullet(_: *MarkdownRenderer, text: []const u8) []const u8 {
        for (bullet_patterns) |pattern| {
            if (std.mem.startsWith(u8, text, pattern)) {
                var result = text[pattern.len..];
                // Also strip leading whitespace
                while (result.len > 0 and (result[0] == ' ' or result[0] == '\t')) {
                    result = result[1..];
                }
                return result;
            }
        }
        return text;
    }

    /// Strip number prefix from text
    fn stripNumberPrefix(_: *MarkdownRenderer, text: []const u8) []const u8 {
        var i: usize = 0;

        // Skip leading paren
        if (text.len > 0 and text[0] == '(') i += 1;

        // Skip digits/letters
        while (i < text.len and i < 5) {
            const c = text[i];
            if ((c >= '0' and c <= '9') or
                (c >= 'a' and c <= 'z') or
                (c >= 'A' and c <= 'Z'))
            {
                i += 1;
            } else {
                break;
            }
        }

        // Skip separator
        if (i < text.len) {
            const sep = text[i];
            if (sep == '.' or sep == ')' or sep == ':') {
                i += 1;
            }
        }

        // Skip trailing paren
        if (i < text.len and text[i] == ')') i += 1;

        // Skip whitespace
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
            i += 1;
        }

        return text[i..];
    }
};

/// Render spans with structure tree information for semantic accuracy
pub const StructuredMarkdownRenderer = struct {
    allocator: std.mem.Allocator,
    options: MarkdownOptions,
    base_renderer: MarkdownRenderer,

    /// PDF structure type to Markdown element mapping
    const struct_type_map = std.ComptimeStringMap(TextElement.Kind, .{
        .{ "Document", .paragraph },
        .{ "Part", .paragraph },
        .{ "Sect", .paragraph },
        .{ "Div", .paragraph },
        .{ "P", .paragraph },
        .{ "H", .heading1 },
        .{ "H1", .heading1 },
        .{ "H2", .heading2 },
        .{ "H3", .heading3 },
        .{ "H4", .heading4 },
        .{ "H5", .heading5 },
        .{ "H6", .heading6 },
        .{ "L", .list_item_bullet },
        .{ "LI", .list_item_bullet },
        .{ "Lbl", .list_item_bullet },
        .{ "LBody", .paragraph },
        .{ "Table", .table_row },
        .{ "TR", .table_row },
        .{ "TH", .table_row },
        .{ "TD", .table_row },
        .{ "Code", .code_block },
        .{ "BlockQuote", .blockquote },
        .{ "Quote", .blockquote },
        .{ "Figure", .paragraph },
        .{ "Caption", .paragraph },
        .{ "Span", .paragraph },
        .{ "Link", .paragraph },
    });

    pub fn init(allocator: std.mem.Allocator, options: MarkdownOptions) StructuredMarkdownRenderer {
        return .{
            .allocator = allocator,
            .options = options,
            .base_renderer = MarkdownRenderer.init(allocator, options),
        };
    }

    /// Map PDF structure type to Markdown element kind
    pub fn mapStructType(struct_type: []const u8) TextElement.Kind {
        return struct_type_map.get(struct_type) orelse .paragraph;
    }
};

/// Render a single page to Markdown
pub fn renderPageToMarkdown(
    allocator: std.mem.Allocator,
    spans: []const TextSpan,
    page_width: f64,
    options: MarkdownOptions,
) ![]u8 {
    var renderer = MarkdownRenderer.init(allocator, options);
    return renderer.render(spans, page_width);
}

/// Render multiple pages to Markdown with page separators
pub fn renderDocumentToMarkdown(
    allocator: std.mem.Allocator,
    pages: []const []const TextSpan,
    page_widths: []const f64,
    options: MarkdownOptions,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (pages, 0..) |spans, i| {
        if (i > 0 and options.page_breaks_as_hr) {
            try output.appendSlice(allocator, "\n---\n\n");
        }

        const width = if (i < page_widths.len) page_widths[i] else 612; // Default letter width
        const page_md = try renderPageToMarkdown(allocator, spans, width, options);
        defer allocator.free(page_md);

        try output.appendSlice(allocator, page_md);
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "heading detection" {
    const allocator = std.testing.allocator;

    const spans = [_]TextSpan{
        .{ .x0 = 72, .y0 = 700, .x1 = 200, .y1 = 724, .text = "Title", .font_size = 24 },
        .{ .x0 = 72, .y0 = 650, .x1 = 400, .y1 = 662, .text = "Body text here.", .font_size = 12 },
    };

    var renderer = MarkdownRenderer.init(allocator, .{});
    const result = try renderer.render(&spans, 612);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "# Title") != null);
}

test "list detection" {
    const allocator = std.testing.allocator;

    const spans = [_]TextSpan{
        .{ .x0 = 72, .y0 = 700, .x1 = 80, .y1 = 712, .text = "•", .font_size = 12 },
        .{ .x0 = 85, .y0 = 700, .x1 = 200, .y1 = 712, .text = "First item", .font_size = 12 },
        .{ .x0 = 72, .y0 = 680, .x1 = 80, .y1 = 692, .text = "•", .font_size = 12 },
        .{ .x0 = 85, .y0 = 680, .x1 = 200, .y1 = 692, .text = "Second item", .font_size = 12 },
    };

    var renderer = MarkdownRenderer.init(allocator, .{});
    const result = try renderer.render(&spans, 612);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "- ") != null);
}

test "numbered list detection" {
    const allocator = std.testing.allocator;

    var renderer = MarkdownRenderer.init(allocator, .{});

    try std.testing.expect(renderer.isNumberedItem("1. First"));
    try std.testing.expect(renderer.isNumberedItem("2) Second"));
    try std.testing.expect(renderer.isNumberedItem("a. Letter"));
    try std.testing.expect(renderer.isNumberedItem("(i) Roman"));
    try std.testing.expect(!renderer.isNumberedItem("Hello"));
}

test "bullet patterns" {
    const allocator = std.testing.allocator;

    var renderer = MarkdownRenderer.init(allocator, .{});

    try std.testing.expect(renderer.isBulletText("• Item"));
    try std.testing.expect(renderer.isBulletText("- Item"));
    try std.testing.expect(renderer.isBulletText("* Item"));
    try std.testing.expect(!renderer.isBulletText("1. Item"));
}

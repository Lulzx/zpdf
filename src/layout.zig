const std = @import("std");

pub const TextSpan = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    text: []const u8,
    font_size: f64,
    page: u32 = 0,
};

pub const TextWord = struct {
    bounds: TextSpan,
    spans: []const TextSpan,
};

pub const TextLine = struct {
    bounds: TextSpan,
    words: []const TextWord,
    baseline_y: f64,
};

pub const TextColumn = struct {
    bounds: TextSpan,
    lines: []const TextLine,
    index: u32,
};

pub const TextParagraph = struct {
    bounds: TextSpan,
    lines: []const TextLine,
    column_index: u32,
    first_line_indent: f64,
};

pub const LayoutResult = struct {
    spans: []const TextSpan,
    lines: []const TextLine,
    columns: []const TextColumn,
    paragraphs: []const TextParagraph,
    reading_order: []const u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LayoutResult) void {
        self.allocator.free(self.spans);
        for (self.lines) |line| {
            for (line.words) |word| {
                self.allocator.free(word.spans);
            }
            self.allocator.free(line.words);
        }
        self.allocator.free(self.lines);
        for (self.columns) |col| {
            self.allocator.free(col.lines);
        }
        self.allocator.free(self.columns);
        for (self.paragraphs) |para| {
            self.allocator.free(para.lines);
        }
        self.allocator.free(self.paragraphs);
        self.allocator.free(self.reading_order);
    }

    /// Get text in reading order
    /// Uses the sorted spans directly (sorted by Y desc, then X asc)
    pub fn getTextInOrder(self: *const LayoutResult, allocator: std.mem.Allocator) ![]u8 {
        if (self.spans.len == 0) return try allocator.alloc(u8, 0);

        const line_threshold: f64 = 10;

        // Pre-calculate total size needed (worst case: space between every span + newlines)
        var total_len: usize = 0;
        var separator_count: usize = 0;
        var prev_y: f64 = self.spans[0].y0;
        var prev_x1: f64 = self.spans[0].x0;
        var prev_font_size: f64 = self.spans[0].font_size;

        for (self.spans, 0..) |span, i| {
            if (i > 0) {
                if (@abs(span.y0 - prev_y) > line_threshold) {
                    separator_count += 1; // newline
                    prev_y = span.y0;
                } else {
                    // Detect word gaps using font-relative threshold
                    // Typical space width is ~25-33% of em, kerning is <10%
                    const space_width = prev_font_size * 0.15; // 15% of font size
                    const gap = span.x0 - prev_x1;
                    if (gap > space_width) {
                        separator_count += 1; // space
                    }
                }
            }
            total_len += span.text.len;
            prev_x1 = span.x1;
            prev_font_size = span.font_size;
        }

        // Allocate exact size needed
        const result = try allocator.alloc(u8, total_len + separator_count);
        var pos: usize = 0;
        prev_y = self.spans[0].y0;
        prev_x1 = self.spans[0].x0;
        prev_font_size = self.spans[0].font_size;

        for (self.spans, 0..) |span, i| {
            if (i > 0) {
                if (@abs(span.y0 - prev_y) > line_threshold) {
                    result[pos] = '\n';
                    pos += 1;
                    prev_y = span.y0;
                } else {
                    const space_width = prev_font_size * 0.15;
                    const gap = span.x0 - prev_x1;
                    if (gap > space_width) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
            }
            @memcpy(result[pos..][0..span.text.len], span.text);
            pos += span.text.len;
            prev_x1 = span.x1;
            prev_font_size = span.font_size;
        }

        return result[0..pos];
    }
};

/// Simple geometric sort: Y (top to bottom), then X (left to right)
/// Matches PyMuPDF's sort=True behavior
pub fn sortGeometric(allocator: std.mem.Allocator, spans: []const TextSpan) ![]u8 {
    if (spans.len == 0) return try allocator.alloc(u8, 0);

    // Sort by Y descending (top to bottom in PDF coords), then X ascending
    const sorted = try allocator.alloc(TextSpan, spans.len);
    defer allocator.free(sorted);
    @memcpy(sorted, spans);

    const line_threshold: f64 = 3; // Tight threshold to match PyMuPDF

    std.mem.sort(TextSpan, sorted, line_threshold, struct {
        fn cmp(threshold: f64, a: TextSpan, b: TextSpan) bool {
            // Group into rows by Y coordinate
            const a_row = @as(i64, @intFromFloat(a.y0 / threshold));
            const b_row = @as(i64, @intFromFloat(b.y0 / threshold));
            if (a_row != b_row) return a_row > b_row; // Higher Y first (top of page)
            return a.x0 < b.x0; // Left to right within row
        }
    }.cmp);

    // Build output text
    var total_len: usize = 0;
    var separator_count: usize = 0;
    var prev_y: f64 = sorted[0].y0;
    var prev_x1: f64 = sorted[0].x0;
    var prev_font_size: f64 = sorted[0].font_size;

    for (sorted, 0..) |span, i| {
        if (i > 0) {
            if (@abs(span.y0 - prev_y) > line_threshold) {
                separator_count += 1; // newline
                prev_y = span.y0;
            } else {
                const space_width = prev_font_size * 0.2;
                const gap = span.x0 - prev_x1;
                if (gap > space_width) {
                    separator_count += 1; // space
                }
            }
        }
        total_len += span.text.len;
        prev_x1 = span.x1;
        prev_font_size = span.font_size;
    }

    const result = try allocator.alloc(u8, total_len + separator_count);
    var pos: usize = 0;
    prev_y = sorted[0].y0;
    prev_x1 = sorted[0].x0;
    prev_font_size = sorted[0].font_size;

    for (sorted, 0..) |span, i| {
        if (i > 0) {
            if (@abs(span.y0 - prev_y) > line_threshold) {
                result[pos] = '\n';
                pos += 1;
                prev_y = span.y0;
            } else {
                const space_width = prev_font_size * 0.2;
                const gap = span.x0 - prev_x1;
                if (gap > space_width) {
                    result[pos] = ' ';
                    pos += 1;
                }
            }
        }
        @memcpy(result[pos..][0..span.text.len], span.text);
        pos += span.text.len;
        prev_x1 = span.x1;
        prev_font_size = span.font_size;
    }

    return result[0..pos];
}

pub fn analyzeLayout(allocator: std.mem.Allocator, spans: []const TextSpan, page_width: f64) !LayoutResult {
    if (spans.len == 0) {
        return LayoutResult{
            .spans = try allocator.alloc(TextSpan, 0),
            .lines = try allocator.alloc(TextLine, 0),
            .columns = try allocator.alloc(TextColumn, 0),
            .paragraphs = try allocator.alloc(TextParagraph, 0),
            .reading_order = try allocator.alloc(u32, 0),
            .allocator = allocator,
        };
    }

    const line_threshold: f64 = 10;
    const half_page = page_width / 2;
    const column_margin = page_width * 0.05; // 5% margin for column detection

    // Sort all spans by Y (top to bottom), then X (left to right)
    const sorted = try allocator.alloc(TextSpan, spans.len);
    @memcpy(sorted, spans);

    std.mem.sort(TextSpan, sorted, line_threshold, struct {
        fn cmp(threshold: f64, a: TextSpan, b: TextSpan) bool {
            const a_row = @as(i64, @intFromFloat(a.y0 / threshold));
            const b_row = @as(i64, @intFromFloat(b.y0 / threshold));
            if (a_row != b_row) return a_row > b_row;
            return a.x0 < b.x0;
        }
    }.cmp);

    // Analyze column structure: count how many lines have both left and right content
    var left_only: usize = 0;
    var right_only: usize = 0;
    var both_columns: usize = 0;
    var current_y: f64 = sorted[0].y0;
    var has_left = false;
    var has_right = false;

    for (sorted) |span| {
        if (@abs(span.y0 - current_y) > line_threshold) {
            // Commit previous line stats
            if (has_left and has_right) {
                both_columns += 1;
            } else if (has_left) {
                left_only += 1;
            } else if (has_right) {
                right_only += 1;
            }
            current_y = span.y0;
            has_left = false;
            has_right = false;
        }
        const mid_x = (span.x0 + span.x1) / 2;
        if (mid_x < half_page - column_margin) {
            has_left = true;
        } else if (mid_x > half_page + column_margin) {
            has_right = true;
        } else {
            has_left = true; // Center content goes to left
        }
    }
    // Count last line
    if (has_left and has_right) {
        both_columns += 1;
    } else if (has_left) {
        left_only += 1;
    } else if (has_right) {
        right_only += 1;
    }

    const total_lines = left_only + right_only + both_columns;
    const is_two_column = both_columns > total_lines / 3; // >33% of lines have both columns

    var result_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len);

    if (is_two_column) {
        // Two-column layout: output left column first, then right column
        var left_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len / 2);
        defer left_spans.deinit(allocator);
        var right_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len / 2);
        defer right_spans.deinit(allocator);

        for (sorted) |span| {
            const mid_x = (span.x0 + span.x1) / 2;
            if (mid_x < half_page) {
                try left_spans.append(allocator, span);
            } else {
                try right_spans.append(allocator, span);
            }
        }

        // Output: left column first, then right column
        for (left_spans.items) |span| {
            try result_spans.append(allocator, span);
        }
        for (right_spans.items) |span| {
            try result_spans.append(allocator, span);
        }
    } else {
        // Single column: just use sorted order
        for (sorted) |span| {
            try result_spans.append(allocator, span);
        }
    }

    allocator.free(sorted);

    // Build lines from the ordered spans
    var lines = try std.ArrayList(TextLine).initCapacity(allocator, spans.len / 10);
    var current_line_spans = try std.ArrayList(TextSpan).initCapacity(allocator, 20);
    current_y = if (result_spans.items.len > 0) result_spans.items[0].y0 else 0;

    for (result_spans.items) |span| {
        if (@abs(span.y0 - current_y) > line_threshold) {
            if (current_line_spans.items.len > 0) {
                try lines.append(allocator, try makeLine(allocator, current_line_spans.items));
                current_line_spans.clearRetainingCapacity();
            }
            current_y = span.y0;
        }
        try current_line_spans.append(allocator, span);
    }
    if (current_line_spans.items.len > 0) {
        try lines.append(allocator, try makeLine(allocator, current_line_spans.items));
    }
    current_line_spans.deinit(allocator);

    // Build column structure
    var columns = try std.ArrayList(TextColumn).initCapacity(allocator, 1);
    if (lines.items.len > 0) {
        const all_lines = try allocator.dupe(TextLine, lines.items);
        try columns.append(allocator, .{
            .bounds = mergeBounds(all_lines),
            .lines = all_lines,
            .index = 0,
        });
    }

    const order = try allocator.alloc(u32, columns.items.len);
    for (order, 0..) |*o, i| {
        o.* = @intCast(i);
    }

    // Detect paragraphs
    var paragraphs = try std.ArrayList(TextParagraph).initCapacity(allocator, columns.items.len * 3);
    for (columns.items, 0..) |col, col_idx| {
        try detectParagraphs(allocator, col.lines, @intCast(col_idx), &paragraphs);
    }

    const final_spans = try result_spans.toOwnedSlice(allocator);

    return LayoutResult{
        .spans = final_spans,
        .lines = try lines.toOwnedSlice(allocator),
        .columns = try columns.toOwnedSlice(allocator),
        .paragraphs = try paragraphs.toOwnedSlice(allocator),
        .reading_order = order,
        .allocator = allocator,
    };
}

/// Detect paragraphs by analyzing line spacing and indentation
fn detectParagraphs(allocator: std.mem.Allocator, col_lines: []const TextLine, col_idx: u32, paragraphs: *std.ArrayList(TextParagraph)) !void {
    if (col_lines.len == 0) return;

    var para_lines = try std.ArrayList(TextLine).initCapacity(allocator, @min(col_lines.len, 20));
    defer para_lines.deinit(allocator);

    var avg_line_spacing: f64 = 0;
    var avg_left_margin: f64 = 0;

    // Calculate average spacing and margins
    if (col_lines.len > 1) {
        var total_spacing: f64 = 0;
        var total_margin: f64 = 0;
        for (col_lines, 0..) |line, i| {
            total_margin += line.bounds.x0;
            if (i > 0) {
                total_spacing += col_lines[i - 1].bounds.y0 - line.bounds.y0;
            }
        }
        avg_line_spacing = total_spacing / @as(f64, @floatFromInt(col_lines.len - 1));
        avg_left_margin = total_margin / @as(f64, @floatFromInt(col_lines.len));
    }

    const para_gap_threshold = avg_line_spacing * 1.5;
    const indent_threshold: f64 = 15;

    for (col_lines, 0..) |line, i| {
        const is_para_break = blk: {
            if (i == 0) break :blk true;

            // Check for large vertical gap
            const prev_line = col_lines[i - 1];
            const gap = prev_line.bounds.y0 - line.bounds.y0;
            if (gap > para_gap_threshold) break :blk true;

            // Check for indentation (first-line indent)
            const indent = line.bounds.x0 - avg_left_margin;
            if (indent > indent_threshold) break :blk true;

            break :blk false;
        };

        if (is_para_break and para_lines.items.len > 0) {
            // Save current paragraph
            const first_indent = para_lines.items[0].bounds.x0 - avg_left_margin;
            const para_lines_copy = try allocator.alloc(TextLine, para_lines.items.len);
            errdefer allocator.free(para_lines_copy);
            for (para_lines.items, 0..) |para_line, idx| {
                para_lines_copy[idx] = .{
                    .bounds = para_line.bounds,
                    .words = &.{},
                    .baseline_y = para_line.baseline_y,
                };
            }
            try paragraphs.append(allocator, .{
                .bounds = mergeBounds(para_lines.items),
                .lines = para_lines_copy,
                .column_index = col_idx,
                .first_line_indent = first_indent,
            });
            para_lines.clearRetainingCapacity();
        }

        try para_lines.append(allocator, line);
    }

    // Save final paragraph
    if (para_lines.items.len > 0) {
        const first_indent = para_lines.items[0].bounds.x0 - avg_left_margin;
        const para_lines_copy = try allocator.alloc(TextLine, para_lines.items.len);
        errdefer allocator.free(para_lines_copy);
        for (para_lines.items, 0..) |para_line, idx| {
            para_lines_copy[idx] = .{
                .bounds = para_line.bounds,
                .words = &.{},
                .baseline_y = para_line.baseline_y,
            };
        }
        try paragraphs.append(allocator, .{
            .bounds = mergeBounds(para_lines.items),
            .lines = para_lines_copy,
            .column_index = col_idx,
            .first_line_indent = first_indent,
        });
    }
}

fn makeLine(allocator: std.mem.Allocator, spans: []const TextSpan) !TextLine {
    // Estimate words as ~1 per 2-3 spans
    const estimated_words = @max(1, spans.len / 2);
    var words = try std.ArrayList(TextWord).initCapacity(allocator, estimated_words);
    var current_word_spans = try std.ArrayList(TextSpan).initCapacity(allocator, 8);
    const word_gap: f64 = 5;

    var prev_x1: f64 = spans[0].x0;
    for (spans) |span| {
        if (span.x0 - prev_x1 > word_gap and current_word_spans.items.len > 0) {
            try words.append(allocator, try makeWord(allocator, current_word_spans.items));
            current_word_spans.clearRetainingCapacity();
        }
        try current_word_spans.append(allocator, span);
        prev_x1 = span.x1;
    }
    if (current_word_spans.items.len > 0) {
        try words.append(allocator, try makeWord(allocator, current_word_spans.items));
    }
    current_word_spans.deinit(allocator);

    const bounds = mergeSpanBounds(spans);
    return TextLine{
        .bounds = bounds,
        .words = try words.toOwnedSlice(allocator),
        .baseline_y = bounds.y0,
    };
}

fn makeWord(allocator: std.mem.Allocator, spans: []const TextSpan) !TextWord {
    const spans_copy = try allocator.dupe(TextSpan, spans);
    return TextWord{
        .bounds = mergeSpanBounds(spans),
        .spans = spans_copy,
    };
}

fn mergeSpanBounds(spans: []const TextSpan) TextSpan {
    var x0 = spans[0].x0;
    var y0 = spans[0].y0;
    var x1 = spans[0].x1;
    var y1 = spans[0].y1;

    for (spans[1..]) |s| {
        x0 = @min(x0, s.x0);
        y0 = @min(y0, s.y0);
        x1 = @max(x1, s.x1);
        y1 = @max(y1, s.y1);
    }

    return TextSpan{
        .x0 = x0,
        .y0 = y0,
        .x1 = x1,
        .y1 = y1,
        .text = spans[0].text,
        .font_size = spans[0].font_size,
    };
}

fn mergeBounds(lines: []const TextLine) TextSpan {
    var x0 = lines[0].bounds.x0;
    var y0 = lines[0].bounds.y0;
    var x1 = lines[0].bounds.x1;
    var y1 = lines[0].bounds.y1;

    for (lines[1..]) |l| {
        x0 = @min(x0, l.bounds.x0);
        y0 = @min(y0, l.bounds.y0);
        x1 = @max(x1, l.bounds.x1);
        y1 = @max(y1, l.bounds.y1);
    }

    return TextSpan{
        .x0 = x0,
        .y0 = y0,
        .x1 = x1,
        .y1 = y1,
        .text = "",
        .font_size = lines[0].bounds.font_size,
    };
}

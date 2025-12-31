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
            self.allocator.free(line.words);
        }
        self.allocator.free(self.lines);
        for (self.columns) |col| {
            self.allocator.free(col.lines);
        }
        self.allocator.free(self.columns);
        self.allocator.free(self.paragraphs);
        self.allocator.free(self.reading_order);
    }

    /// Get text in reading order
    /// Uses the sorted spans directly (sorted by Y desc, then X asc)
    pub fn getTextInOrder(self: *const LayoutResult, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // Simple approach: use the sorted spans directly
        // Spans are already sorted by Y (descending) then X (ascending)
        var prev_y: f64 = if (self.spans.len > 0) self.spans[0].y0 else 0;
        const line_threshold: f64 = 10;

        for (self.spans) |span| {
            // Check if we've moved to a new line
            if (@abs(span.y0 - prev_y) > line_threshold) {
                try result.append(allocator, '\n');
                prev_y = span.y0;
            }
            try result.appendSlice(allocator, span.text);
        }

        return result.toOwnedSlice(allocator);
    }
};

pub fn analyzeLayout(allocator: std.mem.Allocator, spans: []const TextSpan, page_width: f64) !LayoutResult {
    if (spans.len == 0) {
        return LayoutResult{
            .spans = &.{},
            .lines = &.{},
            .columns = &.{},
            .paragraphs = &.{},
            .reading_order = &.{},
            .allocator = allocator,
        };
    }

    // Sort spans by Y (descending) then X (ascending)
    const sorted = try allocator.alloc(TextSpan, spans.len);
    @memcpy(sorted, spans);

    std.mem.sort(TextSpan, sorted, {}, struct {
        fn cmp(_: void, a: TextSpan, b: TextSpan) bool {
            if (@abs(a.y0 - b.y0) > 5) return a.y0 > b.y0; // Higher Y first
            return a.x0 < b.x0; // Left to right
        }
    }.cmp);

    // Group into lines by Y position
    var lines: std.ArrayList(TextLine) = .empty;
    var current_line_spans: std.ArrayList(TextSpan) = .empty;
    var current_y: f64 = sorted[0].y0;
    const line_threshold: f64 = 10;

    for (sorted) |span| {
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

    // Detect columns
    var columns: std.ArrayList(TextColumn) = .empty;
    const column_gap = page_width * 0.1;
    var left_lines: std.ArrayList(TextLine) = .empty;
    var right_lines: std.ArrayList(TextLine) = .empty;

    for (lines.items) |line| {
        const mid_x = (line.bounds.x0 + line.bounds.x1) / 2;
        if (mid_x < page_width / 2 - column_gap / 2) {
            try left_lines.append(allocator, line);
        } else if (mid_x > page_width / 2 + column_gap / 2) {
            try right_lines.append(allocator, line);
        } else {
            try left_lines.append(allocator, line);
        }
    }

    if (left_lines.items.len > 0) {
        try columns.append(allocator, .{
            .bounds = mergeBounds(left_lines.items),
            .lines = try left_lines.toOwnedSlice(allocator),
            .index = 0,
        });
    }
    if (right_lines.items.len > 0) {
        try columns.append(allocator, .{
            .bounds = mergeBounds(right_lines.items),
            .lines = try right_lines.toOwnedSlice(allocator),
            .index = 1,
        });
    }

    // Reading order: left column first, then right
    var order: std.ArrayList(u32) = .empty;
    for (columns.items, 0..) |_, i| {
        try order.append(allocator, @intCast(i));
    }

    // Detect paragraphs within columns
    var paragraphs: std.ArrayList(TextParagraph) = .empty;
    for (columns.items, 0..) |col, col_idx| {
        try detectParagraphs(allocator, col.lines, @intCast(col_idx), &paragraphs);
    }

    return LayoutResult{
        .spans = sorted,
        .lines = try lines.toOwnedSlice(allocator),
        .columns = try columns.toOwnedSlice(allocator),
        .paragraphs = try paragraphs.toOwnedSlice(allocator),
        .reading_order = try order.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Detect paragraphs by analyzing line spacing and indentation
fn detectParagraphs(allocator: std.mem.Allocator, col_lines: []const TextLine, col_idx: u32, paragraphs: *std.ArrayList(TextParagraph)) !void {
    if (col_lines.len == 0) return;

    var para_lines: std.ArrayList(TextLine) = .empty;
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
            try paragraphs.append(allocator, .{
                .bounds = mergeBounds(para_lines.items),
                .lines = para_lines.items,
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
        try paragraphs.append(allocator, .{
            .bounds = mergeBounds(para_lines.items),
            .lines = para_lines.items,
            .column_index = col_idx,
            .first_line_indent = first_indent,
        });
    }
}

fn makeLine(allocator: std.mem.Allocator, spans: []const TextSpan) !TextLine {
    var words: std.ArrayList(TextWord) = .empty;
    var current_word_spans: std.ArrayList(TextSpan) = .empty;
    const word_gap: f64 = 5;

    var prev_x1: f64 = spans[0].x0;
    for (spans) |span| {
        if (span.x0 - prev_x1 > word_gap and current_word_spans.items.len > 0) {
            try words.append(allocator, makeWord(current_word_spans.items));
            current_word_spans.clearRetainingCapacity();
        }
        try current_word_spans.append(allocator, span);
        prev_x1 = span.x1;
    }
    if (current_word_spans.items.len > 0) {
        try words.append(allocator, makeWord(current_word_spans.items));
    }
    current_word_spans.deinit(allocator);

    const bounds = mergeSpanBounds(spans);
    return TextLine{
        .bounds = bounds,
        .words = try words.toOwnedSlice(allocator),
        .baseline_y = bounds.y0,
    };
}

fn makeWord(spans: []const TextSpan) TextWord {
    return TextWord{
        .bounds = mergeSpanBounds(spans),
        .spans = spans,
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

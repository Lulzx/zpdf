//! Test PDF Generator
//!
//! Creates minimal valid PDFs for testing the parser.
//! These are hand-crafted PDFs that exercise specific features.

const std = @import("std");

/// Generate a minimal PDF with plain text
pub fn generateMinimalPdf(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = pdf.writer(allocator);

    // Header
    try writer.writeAll("%PDF-1.4\n");
    try writer.writeAll("%\xE2\xE3\xCF\xD3\n"); // Binary marker

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n");
    try writer.writeAll("<< /Type /Catalog /Pages 2 0 R >>\n");
    try writer.writeAll("endobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n");
    try writer.writeAll("<< /Type /Pages /Kids [3 0 R] /Count 1 >>\n");
    try writer.writeAll("endobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    // Object 4: Content stream
    const obj4_offset = pdf.items.len;

    // Build content stream
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var cw = content.writer(allocator);

    try cw.writeAll("BT\n");
    try cw.writeAll("/F1 12 Tf\n");
    try cw.writeAll("100 700 Td\n");
    try cw.print("({s}) Tj\n", .{text});
    try cw.writeAll("ET\n");

    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    // Object 5: Font
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\n");
    try writer.writeAll("endobj\n");

    // XRef table
    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n");
    try writer.writeAll("0 6\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    // Trailer
    try writer.writeAll("trailer\n");
    try writer.writeAll("<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n", .{xref_offset});
    try writer.writeAll("%%EOF\n");

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with multiple pages
pub fn generateMultiPagePdf(allocator: std.mem.Allocator, pages_text: []const []const u8) ![]u8 {
    var pdf = std.ArrayList(u8).init(allocator);
    errdefer pdf.deinit();

    const writer = pdf.writer();
    var offsets = std.ArrayList(u64).init(allocator);
    defer offsets.deinit();

    // Header
    try writer.writeAll("%PDF-1.4\n");
    try writer.writeAll("%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    try offsets.append(pdf.items.len);
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages - build kids array dynamically
    try offsets.append(pdf.items.len);
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [");
    for (0..pages_text.len) |i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.print("{} 0 R", .{3 + i * 2}); // Page objects at 3, 5, 7, ...
    }
    try writer.print("] /Count {} >>\nendobj\n", .{pages_text.len});

    // Object 3: Font (shared)
    try offsets.append(pdf.items.len);
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Page objects and content streams
    const base_obj = 4;
    for (pages_text, 0..) |text, i| {
        const page_obj = base_obj + i * 2;
        const content_obj = page_obj + 1;

        // Page object
        try offsets.append(pdf.items.len);
        try writer.print("{} 0 obj\n", .{page_obj});
        try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
        try writer.print("/Contents {} 0 R /Resources << /Font << /F1 3 0 R >> >> >>\n", .{content_obj});
        try writer.writeAll("endobj\n");

        // Content stream
        var content = std.ArrayList(u8).init(allocator);
        defer content.deinit();
        try content.writer().writeAll("BT\n/F1 12 Tf\n100 700 Td\n");
        try content.writer().print("({s}) Tj\n", .{text});
        try content.writer().writeAll("ET\n");

        try offsets.append(pdf.items.len);
        try writer.print("{} 0 obj\n<< /Length {} >>\nstream\n", .{ content_obj, content.items.len });
        try writer.writeAll(content.items);
        try writer.writeAll("\nendstream\nendobj\n");
    }

    // XRef table
    const xref_offset = pdf.items.len;
    const total_objects = offsets.items.len + 1; // +1 for object 0
    try writer.writeAll("xref\n");
    try writer.print("0 {}\n", .{total_objects});
    try writer.writeAll("0000000000 65535 f \n");

    for (offsets.items) |offset| {
        try writer.print("{d:0>10} 00000 n \n", .{offset});
    }

    // Trailer
    try writer.writeAll("trailer\n");
    try writer.print("<< /Size {} /Root 1 0 R >>\n", .{total_objects});
    try writer.print("startxref\n{}\n", .{xref_offset});
    try writer.writeAll("%%EOF\n");

    return pdf.toOwnedSlice();
}

/// Generate a PDF with TJ operator (array-based text)
pub fn generateTJPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf = std.ArrayList(u8).init(allocator);
    errdefer pdf.deinit();

    const writer = pdf.writer();

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Content with TJ operator
    const content = "BT\n/F1 12 Tf\n100 700 Td\n[(Hello) -200 (World)] TJ\nET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice();
}

// ============================================================================
// TESTS
// ============================================================================

test "generate minimal PDF" {
    const pdf_data = try generateMinimalPdf(std.testing.allocator, "Hello World");
    defer std.testing.allocator.free(pdf_data);

    // Verify it starts with PDF header
    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));

    // Verify it ends with %%EOF
    try std.testing.expect(std.mem.endsWith(u8, pdf_data, "%%EOF\n"));

    // Verify it contains our text
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "Hello World") != null);
}

test "generate multi-page PDF" {
    const pages = &[_][]const u8{ "Page One", "Page Two", "Page Three" };
    const pdf_data = try generateMultiPagePdf(std.testing.allocator, pages);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Count 3") != null);
}

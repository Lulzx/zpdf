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
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = pdf.writer(allocator);
    var offsets: std.ArrayList(u64) = .empty;
    defer offsets.deinit(allocator);

    // Header
    try writer.writeAll("%PDF-1.4\n");
    try writer.writeAll("%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    try offsets.append(allocator, pdf.items.len);
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages - build kids array dynamically
    // Object layout: 1=Catalog, 2=Pages, 3=Font, then pairs of (Page, Content)
    // So pages are at 4, 6, 8, ... (4 + i*2)
    try offsets.append(allocator, pdf.items.len);
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [");
    for (0..pages_text.len) |i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.print("{} 0 R", .{4 + i * 2}); // Page objects at 4, 6, 8, ...
    }
    try writer.print("] /Count {} >>\nendobj\n", .{pages_text.len});

    // Object 3: Font (shared)
    try offsets.append(allocator, pdf.items.len);
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Page objects and content streams
    const base_obj = 4;
    for (pages_text, 0..) |text, i| {
        const page_obj = base_obj + i * 2;
        const content_obj = page_obj + 1;

        // Page object
        try offsets.append(allocator, pdf.items.len);
        try writer.print("{} 0 obj\n", .{page_obj});
        try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
        try writer.print("/Contents {} 0 R /Resources << /Font << /F1 3 0 R >> >> >>\n", .{content_obj});
        try writer.writeAll("endobj\n");

        // Content stream
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var cw = content.writer(allocator);
        try cw.writeAll("BT\n/F1 12 Tf\n100 700 Td\n");
        try cw.print("({s}) Tj\n", .{text});
        try cw.writeAll("ET\n");

        try offsets.append(allocator, pdf.items.len);
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

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with TJ operator (array-based text)
pub fn generateTJPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = pdf.writer(allocator);

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

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with a CID font (Type0 composite font with ToUnicode)
/// Uses UTF-16BE encoded text and a ToUnicode CMap for mapping
pub fn generateCIDFontPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Object 4: Content stream with UTF-16BE encoded text
    // "Hello" in UTF-16BE: 0048 0065 006C 006C 006F
    // Plus "中" (U+4E2D) in UTF-16BE: 4E2D
    const content = "BT\n/F1 12 Tf\n100 700 Td\n<00480065006C006C006F20004E2D> Tj\nET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    // Object 5: Type0 Font (Composite font)
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type0 /BaseFont /TestCIDFont\n");
    try writer.writeAll("   /Encoding /Identity-H\n");
    try writer.writeAll("   /DescendantFonts [6 0 R]\n");
    try writer.writeAll("   /ToUnicode 7 0 R >>\n");
    try writer.writeAll("endobj\n");

    // Object 6: CIDFont
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCIDFont\n");
    try writer.writeAll("   /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>\n");
    try writer.writeAll("   /W [0 [500]] >>\n"); // Simple width array
    try writer.writeAll("endobj\n");

    // Object 7: ToUnicode CMap
    const tounicode_cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\/CMapName /TestCMap def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\7 beginbfchar
        \\<0048> <0048>
        \\<0065> <0065>
        \\<006C> <006C>
        \\<006F> <006F>
        \\<0020> <0020>
        \\<0000> <0000>
        \\<4E2D> <4E2D>
        \\endbfchar
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
    ;

    const obj7_offset = pdf.items.len;
    try writer.print("7 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ tounicode_cmap.len, tounicode_cmap });

    // XRef table
    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});

    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF whose leaf page node omits /Type (valid but often rejected).
/// Tests Fix 2: pagetree /Type default inference.
pub fn generatePdfWithoutPageType(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page dict intentionally omits /Type /Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var cw = content.writer(allocator);
    try cw.writeAll("BT\n/F1 12 Tf\n100 700 Td\n");
    try cw.print("({s}) Tj\n", .{text});
    try cw.writeAll("ET\n");

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with an inline image (BI/EI block) surrounded by text.
/// Tests Fix 1: inline image skipping in the content stream lexer.
pub fn generateInlineImagePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Content stream: text, inline image, text
    // The inline image bytes \xAA\xBB are arbitrary binary - they won't form "EI"
    const content =
        "BT\n/F1 12 Tf\n100 700 Td\n(Before) Tj\nET\n" ++
        "BI\n/W 2 /H 2 /CS /G /BPC 8\nID\n\xAA\xBB\xCC\xDD\nEI\n" ++
        "BT\n/F1 12 Tf\n100 650 Td\n(After) Tj\nET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.len});
    try writer.writeAll(content);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with superscript text at a slightly elevated Y position.
/// Tests the superscript/subscript newline-suppression fix: a Tm whose Y
/// shift is smaller than 0.7 * max(current_font, last_text_font) should not
/// emit a newline.
pub fn generateSuperscriptPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Main text at Y=700 (12pt), superscript "2" at Y=707 (7pt), then back to Y=700 (12pt).
    // Y shift = 7, threshold = max(7,12)*0.7 = 8.4 → no newline emitted.
    const content =
        "BT\n" ++
        "/F1 12 Tf\n" ++
        "1 0 0 1 100 700 Tm\n" ++
        "(Hello) Tj\n" ++
        "/F1 7 Tf\n" ++
        "1 0 0 1 110 707 Tm\n" ++
        "(2) Tj\n" ++
        "/F1 12 Tf\n" ++
        "1 0 0 1 120 700 Tm\n" ++
        "( World) Tj\n" ++
        "ET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.len});
    try writer.writeAll(content);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
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

test "generate CID font PDF" {
    const pdf_data = try generateCIDFontPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    // Should have Type0 font
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Subtype /Type0") != null);
    // Should have ToUnicode CMap
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "beginbfchar") != null);
    // Should have Identity-H encoding
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Identity-H") != null);
}

/// Generate a PDF with incremental updates
/// Creates a base PDF, then appends an incremental update that modifies the content
pub fn generateIncrementalPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = pdf.writer(allocator);

    // ===== ORIGINAL PDF =====
    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Object 4: Content (original text: "Original Text")
    const content1 = "BT\n/F1 12 Tf\n100 700 Td\n(Original Text) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content1.len, content1 });

    // Object 5: Font
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

    // Original XRef table
    const xref1_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref1_offset});

    // ===== INCREMENTAL UPDATE =====
    // Replace object 4 with new content

    // New Object 4: Updated content (now says "Updated Text")
    const content2 = "BT\n/F1 12 Tf\n100 700 Td\n(Updated Text) Tj\nET\n";
    const new_obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content2.len, content2 });

    // Incremental XRef table (only updated objects)
    const xref2_offset = pdf.items.len;
    try writer.writeAll("xref\n4 1\n"); // Only object 4 is updated
    try writer.print("{d:0>10} 00000 n \n", .{new_obj4_offset});

    try writer.writeAll("trailer\n");
    try writer.print("<< /Size 6 /Root 1 0 R /Prev {} >>\n", .{xref1_offset});
    try writer.print("startxref\n{}\n%%EOF\n", .{xref2_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a minimal PDF with an /Encrypt entry in the trailer.
/// This doesn't implement real encryption - it just has the /Encrypt key
/// so the parser detects it as encrypted.
pub fn generateEncryptedPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Object 4: Content stream
    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Encrypted) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    // Object 5: Font
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

    // Object 6: Encrypt dictionary (dummy - just enough to be detected)
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Filter /Standard /V 1 /R 2 /O (dummy) /U (dummy) /P -4 >>\nendobj\n");

    // XRef table
    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    // Trailer with /Encrypt reference
    try writer.writeAll("trailer\n");
    try writer.writeAll("<< /Size 7 /Root 1 0 R /Encrypt 6 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

test "generate encrypted PDF" {
    const pdf_data = try generateEncryptedPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    // Should have /Encrypt in trailer
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Encrypt 6 0 R") != null);
}

test "generate incremental PDF" {
    const pdf_data = try generateIncrementalPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    // Should have two %%EOF markers (original + incremental update)
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, pdf_data, pos, "%%EOF")) |idx| {
        count += 1;
        pos = idx + 5;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    // Should have /Prev reference
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Prev") != null);

    // Should contain both texts (though only "Updated Text" should be extracted)
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "Original Text") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "Updated Text") != null);
}

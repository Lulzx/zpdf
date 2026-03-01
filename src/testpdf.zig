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

/// Generate a PDF with metadata in the /Info dictionary
pub fn generateMetadataPdf(allocator: std.mem.Allocator) ![]u8 {
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

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Metadata Test) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Info dictionary
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Title (Test Document) /Author (Test Author) ");
    try writer.writeAll("/Subject (Test Subject) /Keywords (test, pdf, zpdf) ");
    try writer.writeAll("/Creator (TestGenerator) /Producer (zpdf) >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R /Info 6 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with an outline (bookmarks / TOC)
pub fn generateOutlinePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog with /Outlines
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R >>\nendobj\n");

    // Object 2: Pages with 2 pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>\nendobj\n");

    // Page 1
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content1 = "BT\n/F1 12 Tf\n100 700 Td\n(Chapter 1 Content) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content1.len, content1 });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Info
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Title (Outline Test) >>\nendobj\n");

    // Object 7: Outlines root
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /Outlines /First 8 0 R /Last 8 0 R /Count 1 >>\nendobj\n");

    // Object 8: Outline item "Chapter 1" pointing to page 1 (obj 3)
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Title (Chapter 1) /Parent 7 0 R /Dest [3 0 R /Fit] >>\nendobj\n");

    // Page 2
    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 10 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content2 = "BT\n/F1 12 Tf\n100 700 Td\n(Chapter 2 Content) Tj\nET\n";
    const obj10_offset = pdf.items.len;
    try writer.print("10 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content2.len, content2 });

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 11\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj10_offset});

    try writer.writeAll("trailer\n<< /Size 11 /Root 1 0 R /Info 6 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with link annotations
pub fn generateLinkPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page with /Annots array
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> ");
    try writer.writeAll("/Annots [6 0 R] >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Click here) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Link annotation with URI
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Annot /Subtype /Link /Rect [100 690 200 710] ");
    try writer.writeAll("/A << /S /URI /URI (https://example.com) >> >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with form fields (/AcroForm)
pub fn generateFormFieldPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Catalog with AcroForm
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/AcroForm << /Fields [6 0 R 7 0 R] >> >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Form Test) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Text field
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /FT /Tx /T (name) /V (John Doe) ");
    try writer.writeAll("/Rect [100 600 300 620] >>\nendobj\n");

    // Object 7: Button field
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /FT /Btn /T (submit) ");
    try writer.writeAll("/Rect [100 550 200 570] >>\nendobj\n");

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

/// Generate a PDF with page labels
pub fn generatePageLabelPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Catalog with PageLabels: pages 0-1 roman lowercase, pages 2+ decimal
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/PageLabels << /Nums [0 << /S /r >> 2 << /S /D >>] >> >>\nendobj\n");

    // 3 pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 6 0 R 8 0 R] /Count 3 >>\nendobj\n");

    // Page 1
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c1 = "BT\n/F1 12 Tf\n100 700 Td\n(Page i) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c1.len, c1 });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Page 2
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c2 = "BT\n/F1 12 Tf\n100 700 Td\n(Page ii) Tj\nET\n";
    const obj7_offset = pdf.items.len;
    try writer.print("7 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c2.len, c2 });

    // Page 3
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 9 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c3 = "BT\n/F1 12 Tf\n100 700 Td\n(Page 1) Tj\nET\n";
    const obj9_offset = pdf.items.len;
    try writer.print("9 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c3.len, c3 });

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 10\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});

    try writer.writeAll("trailer\n<< /Size 10 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

test "generate metadata PDF" {
    const pdf_data = try generateMetadataPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Title (Test Document)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Info 6 0 R") != null);
}

test "generate outline PDF" {
    const pdf_data = try generateOutlinePdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Outlines 7 0 R") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Title (Chapter 1)") != null);
}

test "generate link PDF" {
    const pdf_data = try generateLinkPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Subtype /Link") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "https://example.com") != null);
}

test "generate form field PDF" {
    const pdf_data = try generateFormFieldPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/AcroForm") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/FT /Tx") != null);
}

test "generate page label PDF" {
    const pdf_data = try generatePageLabelPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/PageLabels") != null);
}

/// Generate a PDF with a nested outline (multiple levels, siblings, GoTo actions)
pub fn generateNestedOutlinePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog with Outlines
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>\nendobj\n");

    // Object 2: Pages (2 pages)
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 10 0 R] /Count 2 >>\nendobj\n");

    // Page 1
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c1 = "BT\n/F1 12 Tf\n100 700 Td\n(Page One) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c1.len, c1 });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Outlines root
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Outlines /First 7 0 R /Last 8 0 R /Count 2 >>\nendobj\n");

    // Object 7: "Part I" — top level, has child 9, next sibling 8, dest = page 1
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Title (Part I) /Parent 6 0 R /Next 8 0 R ");
    try writer.writeAll("/First 9 0 R /Last 9 0 R /Count 1 /Dest [3 0 R /Fit] >>\nendobj\n");

    // Object 8: "Part II" — top level, via /A GoTo action, dest = page 2
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Title (Part II) /Parent 6 0 R ");
    try writer.writeAll("/A << /S /GoTo /D [10 0 R /Fit] >> >>\nendobj\n");

    // Object 9: "Section 1.1" — child of Part I, level 1, dest = page 1
    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /Title (Section 1.1) /Parent 7 0 R /Dest [3 0 R /Fit] >>\nendobj\n");

    // Page 2
    const obj10_offset = pdf.items.len;
    try writer.writeAll("10 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 11 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c2 = "BT\n/F1 12 Tf\n100 700 Td\n(Page Two) Tj\nET\n";
    const obj11_offset = pdf.items.len;
    try writer.print("11 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c2.len, c2 });

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 12\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj10_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj11_offset});

    try writer.writeAll("trailer\n<< /Size 12 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with multiple link annotations: URI, GoTo internal, and a non-link annotation
pub fn generateMultiLinkPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page with 3 annotations: 2 links + 1 highlight (should be ignored)
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> ");
    try writer.writeAll("/Annots [6 0 R 7 0 R 8 0 R] >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Links page) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: URI link
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Annot /Subtype /Link /Rect [10 10 100 30] ");
    try writer.writeAll("/A << /S /URI /URI (https://example.org) >> >>\nendobj\n");

    // Object 7: GoTo internal link to page 1 (obj 3)
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /Annot /Subtype /Link /Rect [10 40 100 60] ");
    try writer.writeAll("/A << /S /GoTo /D [3 0 R /Fit] >> >>\nendobj\n");

    // Object 8: Highlight annotation (NOT a link, should be skipped)
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Type /Annot /Subtype /Highlight /Rect [10 70 100 90] >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 9\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});

    try writer.writeAll("trailer\n<< /Size 9 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with all form field types: text, button, choice, signature
pub fn generateAllFormFieldsPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/AcroForm << /Fields [6 0 R 7 0 R 8 0 R 9 0 R] >> >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(All Fields) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Text field with value
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /FT /Tx /T (email) /V (user@example.com) ");
    try writer.writeAll("/Rect [100 600 300 620] >>\nendobj\n");

    // Button field (no value)
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /FT /Btn /T (ok_button) >>\nendobj\n");

    // Choice field with value
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /FT /Ch /T (country) /V (USA) ");
    try writer.writeAll("/Rect [100 500 300 520] >>\nendobj\n");

    // Signature field (no value)
    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /FT /Sig /T (signature) >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 10\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});

    try writer.writeAll("trailer\n<< /Size 10 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with page labels: uppercase roman, alpha, prefix, custom start
pub fn generateExtendedPageLabelPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Pages 0-1: uppercase roman (I, II)
    // Page 2: alpha lowercase starting at 1 (a)
    // Pages 3+: decimal with prefix "App-" starting at 1 (App-1)
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/PageLabels << /Nums [0 << /S /R >> 2 << /S /a >> 3 << /S /D /P (App-) /St 1 >>] >> >>\nendobj\n");

    // 5 pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 6 0 R 8 0 R 10 0 R 12 0 R] /Count 5 >>\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Generate 5 pages (objects 3,4, 6,7, 8,9, 10,11, 12,13)
    const page_texts = [_][]const u8{ "Page I", "Page II", "Page a", "App Page 1", "App Page 2" };
    var page_offsets: [10]u64 = undefined; // pairs of (page_obj, content_obj)
    for (0..5) |pg| {
        const page_obj_num = 3 + pg * 2;
        const content_obj_num = page_obj_num + 1;
        if (page_obj_num == 5) {
            // Skip obj 5 (font) — already written. Adjust numbering.
            // Actually our numbering is 3,4, 6,7, 8,9, 10,11, 12,13 — no collision with 5.
        }

        page_offsets[pg * 2] = pdf.items.len;
        try writer.print("{} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ", .{page_obj_num});
        try writer.print("/Contents {} 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n", .{content_obj_num});

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var cw = content.writer(allocator);
        try cw.writeAll("BT\n/F1 12 Tf\n100 700 Td\n");
        try cw.print("({s}) Tj\n", .{page_texts[pg]});
        try cw.writeAll("ET\n");

        page_offsets[pg * 2 + 1] = pdf.items.len;
        try writer.print("{} 0 obj\n<< /Length {} >>\nstream\n", .{ content_obj_num, content.items.len });
        try writer.writeAll(content.items);
        try writer.writeAll("\nendstream\nendobj\n");
    }

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 14\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[0]}); // obj 3
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[1]}); // obj 4
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset}); // obj 5
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[2]}); // obj 6
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[3]}); // obj 7
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[4]}); // obj 8
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[5]}); // obj 9
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[6]}); // obj 10
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[7]}); // obj 11
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[8]}); // obj 12
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[9]}); // obj 13

    try writer.writeAll("trailer\n<< /Size 14 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with an XObject image on the page
pub fn generateImagePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page with XObject resource
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 7 0 R >> >> >>\nendobj\n");

    // Content stream: text + cm (scale) + Do image
    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Image below) Tj\nET\n200 0 0 150 100 500 cm\n/Im1 Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: (unused)

    // Object 7: Image XObject (1x1 grayscale pixel)
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /XObject /Subtype /Image /Width 640 /Height 480 ");
    try writer.writeAll("/ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\n");
    try writer.writeAll("stream\n\xFF\nendstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    // obj 6 unused — write dummy
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset}); // placeholder
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});

    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with UTF-16BE encoded metadata and outline title
pub fn generateUtf16BePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = pdf.writer(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Catalog with Outlines
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(UTF16 test) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Outlines root
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count 1 >>\nendobj\n");

    // Object 7: Outline item with UTF-16BE title "Café" = FE FF 0043 0061 0066 00E9
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Title <FEFF00430061006600E9> /Parent 6 0 R /Dest [3 0 R /Fit] >>\nendobj\n");

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

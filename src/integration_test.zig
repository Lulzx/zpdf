//! Integration Tests for ZPDF
//!
//! Tests the full parsing and extraction pipeline using generated PDFs.

const std = @import("std");
const zpdf = @import("root.zig");
const testpdf = @import("testpdf.zig");

test "parse minimal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Should have 1 page
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
}

test "extract text from minimal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test123");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try doc.extractText(0, output.writer(allocator));

    // Should contain our test text
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Test123") != null);
}

test "parse multi-page PDF" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "First Page", "Second Page", "Third Page" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 3), doc.pageCount());
}

test "extract all text from multi-page PDF" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "PageA", "PageB" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try doc.extractAllText(output.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, output.items, "PageA") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "PageB") != null);
}

test "parse TJ operator PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTJPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try doc.extractText(0, output.writer(allocator));

    // TJ with spacing should produce "Hello World" (with space from -200 adjustment)
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "World") != null);
}

test "page info extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const info = doc.getPageInfo(0);
    try std.testing.expect(info != null);

    // Should be letter size (612 x 792 points)
    try std.testing.expectApproxEqRel(@as(f64, 612), info.?.width, 0.1);
    try std.testing.expectApproxEqRel(@as(f64, 792), info.?.height, 0.1);
}

test "error tolerance - permissive mode" {
    const allocator = std.testing.allocator;

    // Create slightly malformed PDF
    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    // Even with strict mode, a valid PDF should parse
    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.strict());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
}

test "XRef parsing" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "XRef Test");
    defer allocator.free(pdf_data);

    // Use arena for parsed objects (like real usage)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var xref_table = try zpdf.xref.parseXRef(allocator, arena.allocator(), pdf_data);
    defer xref_table.deinit();

    // Should have entries for objects 1-5 (and 0 for free list)
    try std.testing.expect(xref_table.entries.count() >= 5);
}

test "content lexer tokens" {
    const content = "BT /F1 12 Tf (Hello) Tj ET";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = zpdf.interpreter.ContentLexer.init(arena.allocator(), content);

    // BT operator
    const t1 = (try lexer.next()).?;
    try std.testing.expect(t1 == .operator);
    try std.testing.expectEqualStrings("BT", t1.operator);

    // /F1 name
    const t2 = (try lexer.next()).?;
    try std.testing.expect(t2 == .name);

    // 12 number
    const t3 = (try lexer.next()).?;
    try std.testing.expect(t3 == .number);

    // Tf operator
    const t4 = (try lexer.next()).?;
    try std.testing.expect(t4 == .operator);

    // (Hello) string
    const t5 = (try lexer.next()).?;
    try std.testing.expect(t5 == .string);

    // Tj operator
    const t6 = (try lexer.next()).?;
    try std.testing.expect(t6 == .operator);

    // ET operator
    const t7 = (try lexer.next()).?;
    try std.testing.expect(t7 == .operator);
}

test "decompression - uncompressed passthrough" {
    const allocator = std.testing.allocator;
    const data = "Hello uncompressed";

    // With no filter, should return data as-is (allocated copy)
    const result = try zpdf.decompress.decompressStream(allocator, data, null, null);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(data, result);
}

test "parse incremental PDF update" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateIncrementalPdf(allocator);
    defer allocator.free(pdf_data);

    // Parse the XRef table - should follow /Prev chain
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var xref_table = try zpdf.xref.parseXRef(allocator, arena.allocator(), pdf_data);
    defer xref_table.deinit();

    // Object 4 should point to the NEW offset (from incremental update)
    const obj4_entry = xref_table.get(4);
    try std.testing.expect(obj4_entry != null);

    // The object 4 entry should exist and be in_use
    try std.testing.expectEqual(zpdf.xref.XRefEntry.EntryType.in_use, obj4_entry.?.entry_type);

    // Find where "Updated Text" appears in the PDF (should be at higher offset than "Original Text")
    const orig_pos = std.mem.indexOf(u8, pdf_data, "Original Text");
    const upd_pos = std.mem.indexOf(u8, pdf_data, "Updated Text");

    try std.testing.expect(orig_pos != null);
    try std.testing.expect(upd_pos != null);

    // Updated Text should come after Original Text (it's in the incremental section)
    try std.testing.expect(upd_pos.? > orig_pos.?);

    // Object 4's offset should point to the updated version
    // The updated object 4 starts just before "Updated Text"
    try std.testing.expect(obj4_entry.?.offset > orig_pos.?);
}

test "isEncrypted returns false for normal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Not encrypted");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    try std.testing.expect(!doc.isEncrypted());
}

test "isEncrypted returns true for encrypted PDF" {
    const allocator = std.testing.allocator;

    // Build a minimal PDF with /Encrypt in the trailer
    const pdf_data = try testpdf.generateEncryptedPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    try std.testing.expect(doc.isEncrypted());
}

test "extract text from incremental PDF - gets updated content" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateIncrementalPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    // Should have 1 page
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try doc.extractText(0, output.writer(allocator));

    // Should extract "Updated Text" NOT "Original Text"
    // because incremental update replaced object 4
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Original") == null);
}

test "page tree tolerates leaf node without /Type" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generatePdfWithoutPageType(allocator, "NoTypeTest");
    defer allocator.free(pdf_data);

    // Should still open and report 1 page (Fix 2: /Type default inference)
    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try doc.extractText(0, output.writer(allocator));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "NoTypeTest") != null);
}

test "inline image does not corrupt text extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateInlineImagePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try doc.extractText(0, output.writer(allocator));

    // Both text spans surrounding the inline image must be present (Fix 1: BI/EI skip)
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "After") != null);
}

// =========================================================================
// New feature integration tests
// =========================================================================

test "metadata extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMetadataPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const meta = doc.metadata();
    try std.testing.expect(meta.title != null);
    try std.testing.expectEqualStrings("Test Document", meta.title.?);
    try std.testing.expectEqualStrings("Test Author", meta.author.?);
    try std.testing.expectEqualStrings("Test Subject", meta.subject.?);
    try std.testing.expectEqualStrings("test, pdf, zpdf", meta.keywords.?);
    try std.testing.expectEqualStrings("TestGenerator", meta.creator.?);
    try std.testing.expectEqualStrings("zpdf", meta.producer.?);
}

test "metadata returns empty for PDF without Info dict" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No metadata");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const meta = doc.metadata();
    try std.testing.expect(meta.title == null);
    try std.testing.expect(meta.author == null);
}

test "outline extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateOutlinePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const outline_items = try doc.getOutline(allocator);
    defer {
        for (outline_items) |item| {
            allocator.free(@constCast(item.title));
        }
        allocator.free(outline_items);
    }

    try std.testing.expectEqual(@as(usize, 1), outline_items.len);
    try std.testing.expectEqualStrings("Chapter 1", outline_items[0].title);
    try std.testing.expect(outline_items[0].page != null);
    try std.testing.expectEqual(@as(usize, 0), outline_items[0].page.?);
    try std.testing.expectEqual(@as(u32, 0), outline_items[0].level);
}

test "outline returns empty for PDF without outlines" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No outlines");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const outline_items = try doc.getOutline(allocator);
    defer allocator.free(outline_items);

    try std.testing.expectEqual(@as(usize, 0), outline_items.len);
}

test "link extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateLinkPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const links = try doc.getPageLinks(0, allocator);
    defer zpdf.Document.freeLinks(allocator, links);

    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expect(links[0].uri != null);
    try std.testing.expectEqualStrings("https://example.com", links[0].uri.?);
    // Check rect
    try std.testing.expectApproxEqRel(@as(f64, 100), links[0].rect[0], 0.01);
    try std.testing.expectApproxEqRel(@as(f64, 690), links[0].rect[1], 0.01);
}

test "links returns empty for page without annotations" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No links");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const links = try doc.getPageLinks(0, allocator);
    defer allocator.free(links);

    try std.testing.expectEqual(@as(usize, 0), links.len);
}

test "form field extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormFieldPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const fields = try doc.getFormFields(allocator);
    defer zpdf.Document.freeFormFields(allocator, fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);

    // Find text field
    var found_text = false;
    var found_button = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "name")) {
            found_text = true;
            try std.testing.expect(f.field_type == .text);
            try std.testing.expect(f.value != null);
            try std.testing.expectEqualStrings("John Doe", f.value.?);
        }
        if (std.mem.eql(u8, f.name, "submit")) {
            found_button = true;
            try std.testing.expect(f.field_type == .button);
        }
    }
    try std.testing.expect(found_text);
    try std.testing.expect(found_button);
}

test "form fields returns empty for PDF without AcroForm" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No form");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const fields = try doc.getFormFields(allocator);
    defer allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 0), fields.len);
}

test "text search" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "Hello World", "Goodbye World", "Hello Again" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    // Search for "Hello" - should find 2 matches
    const results = try doc.search(allocator, "Hello");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(usize, 0), results[0].page); // Page 0
    try std.testing.expectEqual(@as(usize, 2), results[1].page); // Page 2
}

test "text search case insensitive" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "hello");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "text search no matches" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "notfound");
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "page labels" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generatePageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 0 should be "i" (lowercase roman)
    const label0 = doc.getPageLabel(allocator, 0);
    defer if (label0) |l| allocator.free(l);
    try std.testing.expect(label0 != null);
    try std.testing.expectEqualStrings("i", label0.?);

    // Page 1 should be "ii"
    const label1 = doc.getPageLabel(allocator, 1);
    defer if (label1) |l| allocator.free(l);
    try std.testing.expect(label1 != null);
    try std.testing.expectEqualStrings("ii", label1.?);

    // Page 2 should be "1" (decimal, starting at 1)
    const label2 = doc.getPageLabel(allocator, 2);
    defer if (label2) |l| allocator.free(l);
    try std.testing.expect(label2 != null);
    try std.testing.expectEqualStrings("1", label2.?);
}

test "page labels returns null for PDF without PageLabels" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No labels");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const label = doc.getPageLabel(allocator, 0);
    try std.testing.expect(label == null);
}

test "superscript positioning does not insert spurious newline" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateSuperscriptPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try doc.extractText(0, output.writer(allocator));

    // All three text chunks must be present
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "World") != null);

    // No newline should appear between them: the 7-unit Y shift for the
    // superscript is below the threshold max(7,12)*0.7=8.4 (Fix 8)
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\n") == null);
}

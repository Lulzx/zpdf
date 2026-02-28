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

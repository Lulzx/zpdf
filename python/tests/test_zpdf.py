import pytest
import zpdf
from pathlib import Path

# Test files
TEST_DIR = Path(__file__).parent.parent.parent
TEST_PDF = TEST_DIR / "test" / "test.pdf"
TAGGED_PDF = TEST_DIR / "benchmark" / "PDFUA-Ref-2-08_BookChapter.pdf"
ACROBAT_PDF = TEST_DIR / "test" / "acrobat_reference.pdf"


class TestDocumentOpen:
    """Test document opening from various sources."""

    def test_open_file_path_str(self):
        with zpdf.Document(str(TEST_PDF)) as doc:
            assert doc.page_count > 0

    def test_open_file_path_object(self):
        with zpdf.Document(TEST_PDF) as doc:
            assert doc.page_count > 0

    def test_open_bytes(self):
        with open(TEST_PDF, "rb") as f:
            data = f.read()
        with zpdf.Document(data) as doc:
            assert doc.page_count > 0

    def test_open_nonexistent_file(self):
        with pytest.raises(zpdf.InvalidPdfError):
            zpdf.Document("/nonexistent/path.pdf")

    def test_open_invalid_pdf(self, tmp_path):
        invalid = tmp_path / "invalid.pdf"
        invalid.write_text("not a pdf")
        # Invalid PDFs may or may not raise - zpdf is permissive
        # Just verify it doesn't crash
        try:
            with zpdf.Document(str(invalid)) as doc:
                pass  # May succeed with empty pages
        except zpdf.InvalidPdfError:
            pass  # Expected for clearly invalid files


class TestDocumentProperties:
    """Test document properties and metadata."""

    def test_page_count(self):
        with zpdf.Document(TEST_PDF) as doc:
            assert isinstance(doc.page_count, int)
            assert doc.page_count >= 1

    def test_page_info(self):
        with zpdf.Document(TEST_PDF) as doc:
            info = doc.get_page_info(0)
            assert info.width > 0
            assert info.height > 0
            assert isinstance(info.rotation, int)

    def test_page_info_invalid(self):
        with zpdf.Document(TEST_PDF) as doc:
            with pytest.raises(zpdf.PageNotFoundError):
                doc.get_page_info(9999)


class TestTextExtraction:
    """Test text extraction functionality."""

    def test_extract_page(self):
        with zpdf.Document(TEST_PDF) as doc:
            text = doc.extract_page(0)
            assert isinstance(text, str)
            assert len(text) > 0

    def test_extract_all(self):
        with zpdf.Document(TEST_PDF) as doc:
            text = doc.extract_all()
            assert isinstance(text, str)
            assert len(text) > 0

    def test_extract_all_fast_mode(self):
        with zpdf.Document(TEST_PDF) as doc:
            text = doc.extract_all(mode="fast")
            assert isinstance(text, str)

    def test_extract_all_multiple_pages(self):
        if ACROBAT_PDF.exists():
            with zpdf.Document(ACROBAT_PDF) as doc:
                text = doc.extract_all()
                # Should have page separators (form feed)
                assert doc.page_count > 1
                assert isinstance(text, str)

    def test_extract_page_invalid(self):
        with zpdf.Document(TEST_PDF) as doc:
            with pytest.raises(zpdf.PageNotFoundError):
                doc.extract_page(9999)

    def test_extract_page_negative(self):
        with zpdf.Document(TEST_PDF) as doc:
            with pytest.raises(zpdf.PageNotFoundError):
                doc.extract_page(-1)

    def test_extract_empty_page(self):
        # Some PDFs may have empty pages
        with zpdf.Document(TEST_PDF) as doc:
            text = doc.extract_page(0)
            # Just verify it returns a string (may be empty)
            assert isinstance(text, str)

    def test_extract_all_invalid_mode(self):
        with zpdf.Document(TEST_PDF) as doc:
            with pytest.raises(ValueError):
                _ = doc.extract_all(mode="invalid")


class TestTaggedPDF:
    """Test extraction from tagged PDFs (PDF/UA)."""

    @pytest.mark.skipif(not TAGGED_PDF.exists(), reason="Tagged PDF not available")
    def test_extract_tagged_pdf(self):
        with zpdf.Document(TAGGED_PDF) as doc:
            text = doc.extract_all()
            assert isinstance(text, str)
            assert len(text) > 0

    @pytest.mark.skipif(not TAGGED_PDF.exists(), reason="Tagged PDF not available")
    def test_extract_tagged_page(self):
        with zpdf.Document(TAGGED_PDF) as doc:
            for i in range(min(5, doc.page_count)):
                text = doc.extract_page(i)
                assert isinstance(text, str)


class TestIteration:
    """Test document iteration."""

    def test_iteration(self):
        with zpdf.Document(TEST_PDF) as doc:
            pages = list(doc)
            assert len(pages) == doc.page_count
            for text in pages:
                assert isinstance(text, str)

    def test_iteration_empty_after_exhaust(self):
        with zpdf.Document(TEST_PDF) as doc:
            pages1 = list(doc)
            pages2 = list(doc)  # Should start from beginning
            assert len(pages1) == len(pages2)


class TestContextManager:
    """Test context manager behavior."""

    def test_context_manager_closes(self):
        with zpdf.Document(TEST_PDF) as doc:
            _ = doc.page_count
        with pytest.raises(ValueError, match="closed"):
            _ = doc.page_count

    def test_explicit_close(self):
        doc = zpdf.Document(TEST_PDF)
        assert doc.page_count > 0
        doc.close()
        with pytest.raises(ValueError, match="closed"):
            _ = doc.page_count

    def test_double_close_safe(self):
        doc = zpdf.Document(TEST_PDF)
        doc.close()
        doc.close()  # Should not raise


class TestBounds:
    """Test text extraction with bounding boxes."""

    def test_extract_bounds(self):
        with zpdf.Document(TEST_PDF) as doc:
            spans = doc.extract_bounds(0)
            assert isinstance(spans, list)
            if spans:  # May be empty for some PDFs
                span = spans[0]
                assert hasattr(span, 'text')
                assert hasattr(span, 'x0')
                assert hasattr(span, 'y0')
                assert hasattr(span, 'x1')
                assert hasattr(span, 'y1')

    def test_extract_bounds_invalid_page(self):
        with zpdf.Document(TEST_PDF) as doc:
            with pytest.raises(zpdf.PageNotFoundError):
                doc.extract_bounds(9999)


class TestErrorHandling:
    """Test error handling."""

    def test_error_types(self):
        # Verify error types exist
        assert issubclass(zpdf.InvalidPdfError, Exception)
        assert issubclass(zpdf.ExtractionError, Exception)
        assert issubclass(zpdf.PageNotFoundError, Exception)


class TestMemory:
    """Test memory handling."""

    def test_large_document(self):
        if ACROBAT_PDF.exists():
            with zpdf.Document(ACROBAT_PDF) as doc:
                # Extract all pages to test memory handling
                text = doc.extract_all()
                assert len(text) > 0

    def test_repeated_extraction(self):
        with zpdf.Document(TEST_PDF) as doc:
            # Extract same page multiple times
            for _ in range(10):
                text = doc.extract_page(0)
                assert isinstance(text, str)


class TestReadingOrder:
    """Test reading_order=True variant of extract_page."""

    def test_extract_page_reading_order(self):
        with zpdf.Document(TEST_PDF) as doc:
            text = doc.extract_page(0, reading_order=True)
            assert isinstance(text, str)
            assert len(text) > 0

    def test_reading_order_vs_stream_order(self):
        # Both modes must return non-empty strings; content may differ
        with zpdf.Document(TEST_PDF) as doc:
            stream = doc.extract_page(0, reading_order=False)
            ordered = doc.extract_page(0, reading_order=True)
            assert isinstance(stream, str)
            assert isinstance(ordered, str)

    def test_reading_order_invalid_page(self):
        with zpdf.Document(TEST_PDF) as doc:
            with pytest.raises(zpdf.PageNotFoundError):
                doc.extract_page(9999, reading_order=True)

    @pytest.mark.skipif(not TAGGED_PDF.exists(), reason="Tagged PDF not available")
    def test_reading_order_tagged_pdf(self):
        with zpdf.Document(TAGGED_PDF) as doc:
            text = doc.extract_page(0, reading_order=True)
            assert isinstance(text, str)


class TestMarkdown:
    """Test Markdown extraction methods."""

    def test_extract_page_markdown_returns_str(self):
        with zpdf.Document(TEST_PDF) as doc:
            md = doc.extract_page_markdown(0)
            assert isinstance(md, str)

    def test_extract_page_markdown_non_empty(self):
        with zpdf.Document(TEST_PDF) as doc:
            md = doc.extract_page_markdown(0)
            assert len(md) > 0

    def test_extract_page_markdown_invalid_page(self):
        with zpdf.Document(TEST_PDF) as doc:
            with pytest.raises(zpdf.PageNotFoundError):
                doc.extract_page_markdown(9999)

    def test_extract_page_markdown_negative_page(self):
        with zpdf.Document(TEST_PDF) as doc:
            with pytest.raises(zpdf.PageNotFoundError):
                doc.extract_page_markdown(-1)

    def test_extract_all_markdown_returns_str(self):
        with zpdf.Document(TEST_PDF) as doc:
            md = doc.extract_all_markdown()
            assert isinstance(md, str)

    def test_extract_all_markdown_non_empty(self):
        with zpdf.Document(TEST_PDF) as doc:
            md = doc.extract_all_markdown()
            assert len(md) > 0

    @pytest.mark.skipif(not TAGGED_PDF.exists(), reason="Tagged PDF not available")
    def test_extract_all_markdown_tagged(self):
        with zpdf.Document(TAGGED_PDF) as doc:
            md = doc.extract_all_markdown()
            assert isinstance(md, str)
            assert len(md) > 0

    def test_extract_all_markdown_after_close(self):
        doc = zpdf.Document(TEST_PDF)
        doc.close()
        with pytest.raises(ValueError, match="closed"):
            doc.extract_all_markdown()

    def test_extract_page_markdown_after_close(self):
        doc = zpdf.Document(TEST_PDF)
        doc.close()
        with pytest.raises(ValueError, match="closed"):
            doc.extract_page_markdown(0)


class TestTextSpan:
    """Test TextSpan fields and computed properties."""

    def test_span_fields_present(self):
        with zpdf.Document(TEST_PDF) as doc:
            spans = doc.extract_bounds(0)
            if not spans:
                pytest.skip("No spans on page 0")
            s = spans[0]
            assert isinstance(s.x0, float)
            assert isinstance(s.y0, float)
            assert isinstance(s.x1, float)
            assert isinstance(s.y1, float)
            assert isinstance(s.text, str)
            assert isinstance(s.font_size, float)

    def test_span_width_height(self):
        with zpdf.Document(TEST_PDF) as doc:
            spans = doc.extract_bounds(0)
            if not spans:
                pytest.skip("No spans on page 0")
            for s in spans:
                assert s.width == pytest.approx(s.x1 - s.x0)
                assert s.height == pytest.approx(s.y1 - s.y0)

    def test_span_font_size_positive(self):
        with zpdf.Document(TEST_PDF) as doc:
            spans = doc.extract_bounds(0)
            if not spans:
                pytest.skip("No spans on page 0")
            for s in spans:
                assert s.font_size >= 0

    def test_span_repr(self):
        with zpdf.Document(TEST_PDF) as doc:
            spans = doc.extract_bounds(0)
            if not spans:
                pytest.skip("No spans on page 0")
            r = repr(spans[0])
            assert "TextSpan" in r
            assert "text=" in r

    def test_span_text_nonempty(self):
        with zpdf.Document(TEST_PDF) as doc:
            spans = doc.extract_bounds(0)
            if not spans:
                pytest.skip("No spans on page 0")
            # At least some spans should have non-empty text
            assert any(s.text.strip() for s in spans)


class TestDocumentLen:
    """Test __len__ on Document."""

    def test_len_equals_page_count(self):
        with zpdf.Document(TEST_PDF) as doc:
            assert len(doc) == doc.page_count

    def test_len_after_close(self):
        doc = zpdf.Document(TEST_PDF)
        doc.close()
        with pytest.raises(ValueError, match="closed"):
            _ = len(doc)


class TestUnsafeMemoryOpen:
    def test_open_memory_unsafe(self):
        data = TEST_PDF.read_bytes()
        with zpdf.Document.open_memory_unsafe(data) as doc:
            assert doc.page_count > 0


class TestPageInfoRepr:
    """Test PageInfo repr."""

    def test_page_info_repr(self):
        with zpdf.Document(TEST_PDF) as doc:
            info = doc.get_page_info(0)
            r = repr(info)
            assert "PageInfo" in r
            assert "width=" in r
            assert "height=" in r


class TestMultiPageSeparators:
    """Test that multi-page documents include page separators."""

    @pytest.mark.skipif(not ACROBAT_PDF.exists(), reason="Acrobat PDF not available")
    def test_extract_all_has_page_separators(self):
        with zpdf.Document(ACROBAT_PDF) as doc:
            if doc.page_count < 2:
                pytest.skip("Need multi-page document")
            text = doc.extract_all()
            # Form-feed (\x0c) is used as page separator
            assert "\x0c" in text


class TestTaggedPDFSuite:
    """Test extraction on the full benchmark tagged PDF suite."""

    TAGGED_PDFS = [
        "PDFUA-Ref-2-01_Magazine-danish.pdf",
        "PDFUA-Ref-2-02_Invoice.pdf",
        "PDFUA-Ref-2-03_AcademicAbstract.pdf",
        "PDFUA-Ref-2-04_Presentation.pdf",
        "PDFUA-Ref-2-05_BookChapter-german.pdf",
        "PDFUA-Ref-2-06_Brochure.pdf",
        "PDFUA-Ref-2-08_BookChapter.pdf",
    ]
    BENCHMARK_DIR = Path(__file__).parent.parent.parent / "benchmark"

    @pytest.mark.parametrize("filename", TAGGED_PDFS)
    def test_tagged_pdf_extract_all(self, filename):
        path = self.BENCHMARK_DIR / filename
        if not path.exists():
            pytest.skip(f"{filename} not available")
        with zpdf.Document(path) as doc:
            text = doc.extract_all()
            assert isinstance(text, str)

    @pytest.mark.parametrize("filename", TAGGED_PDFS)
    def test_tagged_pdf_markdown(self, filename):
        path = self.BENCHMARK_DIR / filename
        if not path.exists():
            pytest.skip(f"{filename} not available")
        with zpdf.Document(path) as doc:
            md = doc.extract_all_markdown()
            assert isinstance(md, str)


class TestMalformedPDFRobustness:
    """Ensure malformed PDFs do not crash — they should either parse or raise a known error."""

    CORPUS_DIR = Path(__file__).parent.parent.parent / "test" / "Test_Corpus"

    @pytest.mark.skipif(
        not (Path(__file__).parent.parent.parent / "test" / "Test_Corpus").exists(),
        reason="Test_Corpus not available",
    )
    @pytest.mark.parametrize("pdf_path", sorted(
        (Path(__file__).parent.parent.parent / "test" / "Test_Corpus").glob("*.pdf")
    ))
    def test_malformed_no_crash(self, pdf_path):
        try:
            with zpdf.Document(pdf_path) as doc:
                # If we opened it, try extracting text — must not crash
                try:
                    _ = doc.extract_all()
                except (zpdf.ExtractionError, zpdf.PageNotFoundError):
                    pass  # Known errors are fine
        except zpdf.InvalidPdfError:
            pass  # Expected for many malformed files


if __name__ == "__main__":
    pytest.main([__file__, "-v"])

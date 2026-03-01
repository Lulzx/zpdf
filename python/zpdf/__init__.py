from __future__ import annotations
from typing import Iterator, Optional, Union
from pathlib import Path

from ._ffi import ffi, lib
from .exceptions import ZpdfError, InvalidPdfError, PageNotFoundError, ExtractionError

__version__ = "0.1.0"
__all__ = ["Document", "PageInfo", "TextSpan", "ZpdfError", "InvalidPdfError", "PageNotFoundError", "ExtractionError"]


class TextSpan:
    """A text span with bounding box coordinates."""
    __slots__ = ("x0", "y0", "x1", "y1", "text", "font_size")

    def __init__(self, x0: float, y0: float, x1: float, y1: float, text: str, font_size: float):
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
        self.text = text
        self.font_size = font_size

    def __repr__(self):
        return f"TextSpan(x0={self.x0:.1f}, y0={self.y0:.1f}, x1={self.x1:.1f}, y1={self.y1:.1f}, text={self.text!r}, font_size={self.font_size:.1f})"

    @property
    def width(self) -> float:
        return self.x1 - self.x0

    @property
    def height(self) -> float:
        return self.y1 - self.y0


class PageInfo:
    __slots__ = ("width", "height", "rotation")

    def __init__(self, width: float, height: float, rotation: int):
        self.width = width
        self.height = height
        self.rotation = rotation

    def __repr__(self):
        return f"PageInfo(width={self.width}, height={self.height}, rotation={self.rotation})"


class Document:
    __slots__ = ("_handle", "_closed", "_unsafe_buffer")

    def __init__(self, source: Union[str, Path, bytes]):
        self._closed = False
        self._handle = ffi.NULL
        self._unsafe_buffer = None

        if isinstance(source, bytes):
            # Zero-copy path: keep a cffi buffer alive for the document lifetime.
            self._unsafe_buffer = ffi.from_buffer(source)
            self._handle = lib.zpdf_open_memory_unsafe(self._unsafe_buffer, len(source))
        else:
            path = str(source).encode("utf-8")
            self._handle = lib.zpdf_open(path)

        if self._handle == ffi.NULL:
            raise InvalidPdfError(f"Failed to open PDF: {source}")

    def __enter__(self) -> "Document":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()

    def __del__(self):
        if not self._closed:
            self.close()

    def close(self) -> None:
        if not self._closed and self._handle != ffi.NULL:
            lib.zpdf_close(self._handle)
            self._handle = ffi.NULL
            self._unsafe_buffer = None
            self._closed = True

    @classmethod
    def open_memory_unsafe(cls, data: bytes) -> "Document":
        """Open a PDF from an in-memory byte buffer without copying.

        The returned document keeps a reference to the provided buffer and
        reads directly from it.
        """
        return cls(data)

    def _check_open(self) -> None:
        if self._closed:
            raise ValueError("Document is closed")

    @property
    def page_count(self) -> int:
        self._check_open()
        count = lib.zpdf_page_count(self._handle)
        if count < 0:
            raise InvalidPdfError("Failed to get page count")
        return count

    @property
    def is_encrypted(self) -> bool:
        """Check if the PDF is encrypted. Encrypted PDFs cannot be extracted."""
        self._check_open()
        return lib.zpdf_is_encrypted(self._handle)

    def get_page_info(self, page_num: int) -> PageInfo:
        self._check_open()
        width = ffi.new("double*")
        height = ffi.new("double*")
        rotation = ffi.new("int*")

        result = lib.zpdf_get_page_info(self._handle, page_num, width, height, rotation)
        if result != 0:
            raise PageNotFoundError(f"Page {page_num} not found")

        return PageInfo(width[0], height[0], rotation[0])

    def extract_page(self, page_num: int, reading_order: bool = False) -> str:
        """Extract text from a single page.

        Args:
            page_num: Page number (0-indexed)
            reading_order: If True, returns text in visual reading order
                          (left-to-right, top-to-bottom with column detection).
                          If False (default), returns text in PDF stream order.
        """
        self._check_open()
        if page_num < 0 or page_num >= self.page_count:
            raise PageNotFoundError(f"Page {page_num} not found")

        out_len = ffi.new("size_t*")
        if reading_order:
            buf_ptr = lib.zpdf_extract_page_reading_order(self._handle, page_num, out_len)
        else:
            buf_ptr = lib.zpdf_extract_page(self._handle, page_num, out_len)

        if buf_ptr == ffi.NULL:
            if out_len[0] == 0:
                return ""  # Empty page
            raise ExtractionError(f"Failed to extract page {page_num}")

        try:
            data = ffi.buffer(buf_ptr, out_len[0])[:]
            return data.decode("utf-8", errors="replace")
        finally:
            lib.zpdf_free_buffer(buf_ptr, out_len[0])

    def extract_all(self, mode: str = "accuracy") -> str:
        """Extract text from all pages.

        Args:
            mode: Extraction mode.
                - "accuracy" (default): structure-tree order, geometric fallback.
                - "fast": high-throughput stream-order extraction.
        """
        self._check_open()
        out_len = ffi.new("size_t*")
        if mode == "accuracy":
            buf_ptr = lib.zpdf_extract_all_reading_order(self._handle, out_len)
        elif mode == "fast":
            buf_ptr = lib.zpdf_extract_all_fast(self._handle, out_len)
        else:
            raise ValueError("mode must be 'accuracy' or 'fast'")

        if buf_ptr == ffi.NULL:
            if out_len[0] == 0:
                return ""  # Empty document
            raise ExtractionError("Failed to extract text")

        try:
            data = ffi.buffer(buf_ptr, out_len[0])[:]
            return data.decode("utf-8", errors="replace")
        finally:
            lib.zpdf_free_buffer(buf_ptr, out_len[0])

    def extract_bounds(self, page_num: int) -> list[TextSpan]:
        """Extract text spans with bounding boxes from a page."""
        self._check_open()
        if page_num < 0 or page_num >= self.page_count:
            raise PageNotFoundError(f"Page {page_num} not found")

        out_count = ffi.new("size_t*")
        spans_ptr = lib.zpdf_extract_bounds(self._handle, page_num, out_count)

        if spans_ptr == ffi.NULL and out_count[0] == 0:
            return []
        if spans_ptr == ffi.NULL:
            raise ExtractionError(f"Failed to extract bounds for page {page_num}")

        try:
            spans = []
            for i in range(out_count[0]):
                span = spans_ptr[i]
                text = ffi.buffer(span.text, span.text_len)[:].decode("utf-8", errors="replace")
                spans.append(TextSpan(
                    x0=span.x0,
                    y0=span.y0,
                    x1=span.x1,
                    y1=span.y1,
                    text=text,
                    font_size=span.font_size,
                ))
            return spans
        finally:
            lib.zpdf_free_bounds(spans_ptr, out_count[0])

    def extract_page_markdown(self, page_num: int) -> str:
        """Extract text from a single page as Markdown.

        Converts PDF content to Markdown with:
        - Heading detection (based on font size)
        - Paragraph detection (based on spacing)
        - List detection (bullets and numbers)
        - Table detection (column alignment)

        Args:
            page_num: Page number (0-indexed)

        Returns:
            Markdown-formatted text
        """
        self._check_open()
        if page_num < 0 or page_num >= self.page_count:
            raise PageNotFoundError(f"Page {page_num} not found")

        out_len = ffi.new("size_t*")
        buf_ptr = lib.zpdf_extract_page_markdown(self._handle, page_num, out_len)

        if buf_ptr == ffi.NULL:
            if out_len[0] == 0:
                return ""  # Empty page
            raise ExtractionError(f"Failed to extract markdown from page {page_num}")

        try:
            data = ffi.buffer(buf_ptr, out_len[0])[:]
            return data.decode("utf-8", errors="replace")
        finally:
            lib.zpdf_free_buffer(buf_ptr, out_len[0])

    def extract_all_markdown(self) -> str:
        """Extract text from all pages as Markdown.

        Converts entire PDF to Markdown with:
        - Heading detection (based on font size)
        - Paragraph detection (based on spacing)
        - List detection (bullets and numbers)
        - Table detection (column alignment)
        - Page breaks as horizontal rules (---)

        Returns:
            Markdown-formatted text for entire document
        """
        self._check_open()
        out_len = ffi.new("size_t*")

        buf_ptr = lib.zpdf_extract_all_markdown(self._handle, out_len)

        if buf_ptr == ffi.NULL:
            if out_len[0] == 0:
                return ""  # Empty document
            raise ExtractionError("Failed to extract markdown")

        try:
            data = ffi.buffer(buf_ptr, out_len[0])[:]
            return data.decode("utf-8", errors="replace")
        finally:
            lib.zpdf_free_buffer(buf_ptr, out_len[0])

    # =========================================================================
    # Document Metadata
    # =========================================================================

    @property
    def metadata(self) -> dict:
        """Document metadata (title, author, subject, keywords, creator, producer, creation_date, mod_date)."""
        self._check_open()
        meta = ffi.new("CMetadata*")
        result = lib.zpdf_get_metadata(self._handle, meta)
        if result != 0:
            return {}

        def _get_str(ptr, length):
            if length == 0:
                return None
            return ffi.buffer(ptr, length)[:].decode("utf-8", errors="replace")

        out = {}
        for field in ("title", "author", "subject", "keywords", "creator", "producer", "creation_date", "mod_date"):
            val = _get_str(getattr(meta, field), getattr(meta, f"{field}_len"))
            if val is not None:
                out[field] = val
        return out

    # =========================================================================
    # Document Outline / TOC
    # =========================================================================

    @property
    def outline(self) -> list[dict]:
        """Document outline/TOC. Each entry: {"title": str, "page": int or None, "level": int}."""
        self._check_open()
        out_ptr = ffi.new("COutlineItem**")
        count = ffi.new("size_t*")

        result = lib.zpdf_get_outline(self._handle, out_ptr, count)
        if result != 0 or out_ptr[0] == ffi.NULL:
            return []

        try:
            items = []
            for i in range(count[0]):
                item = out_ptr[0][i]
                title = ffi.buffer(item.title, item.title_len)[:].decode("utf-8", errors="replace")
                page = item.page if item.page >= 0 else None
                items.append({"title": title, "page": page, "level": item.level})
            return items
        finally:
            lib.zpdf_free_outline(out_ptr[0], count[0])

    # =========================================================================
    # Text Search
    # =========================================================================

    def search(self, query: str) -> list[dict]:
        """Search for text across all pages.

        Returns list of matches, each with: {"page": int, "offset": int, "context": str}.
        Search is case-insensitive.
        """
        self._check_open()
        query_bytes = query.encode("utf-8")
        out_ptr = ffi.new("CSearchResult**")
        count = ffi.new("size_t*")

        result = lib.zpdf_search(self._handle, query_bytes, len(query_bytes), out_ptr, count)
        if result != 0 or out_ptr[0] == ffi.NULL:
            return []

        try:
            results = []
            for i in range(count[0]):
                r = out_ptr[0][i]
                context = ffi.buffer(r.context, r.context_len)[:].decode("utf-8", errors="replace")
                results.append({"page": r.page, "offset": r.offset, "context": context})
            return results
        finally:
            lib.zpdf_free_search_results(out_ptr[0], count[0])

    # =========================================================================
    # Page Labels
    # =========================================================================

    def get_page_label(self, page_num: int) -> Optional[str]:
        """Get the display label for a page (e.g., 'i', 'ii', '1', '2', 'A-1')."""
        self._check_open()
        out_len = ffi.new("size_t*")
        buf_ptr = lib.zpdf_get_page_label(self._handle, page_num, out_len)
        if buf_ptr == ffi.NULL:
            return None
        try:
            return ffi.buffer(buf_ptr, out_len[0])[:].decode("utf-8", errors="replace")
        finally:
            lib.zpdf_free_buffer(buf_ptr, out_len[0])

    # =========================================================================
    # Links
    # =========================================================================

    def get_links(self, page_num: int) -> list[dict]:
        """Extract link annotations from a page.

        Returns list of links, each with: {"rect": [x0,y0,x1,y1], "uri": str or None, "dest_page": int or None}.
        """
        self._check_open()
        out_ptr = ffi.new("CLink**")
        count = ffi.new("size_t*")

        result = lib.zpdf_get_page_links(self._handle, page_num, out_ptr, count)
        if result != 0 or out_ptr[0] == ffi.NULL:
            return []

        try:
            links = []
            for i in range(count[0]):
                link = out_ptr[0][i]
                uri = None
                if link.uri_len > 0:
                    uri = ffi.buffer(link.uri, link.uri_len)[:].decode("utf-8", errors="replace")
                dest_page = link.dest_page if link.dest_page >= 0 else None
                links.append({
                    "rect": [link.x0, link.y0, link.x1, link.y1],
                    "uri": uri,
                    "dest_page": dest_page,
                })
            return links
        finally:
            lib.zpdf_free_links(out_ptr[0], count[0])

    # =========================================================================
    # Images
    # =========================================================================

    def get_images(self, page_num: int) -> list[dict]:
        """Detect images on a page.

        Returns list of images, each with: {"rect": [x0,y0,x1,y1], "width": int, "height": int}.
        """
        self._check_open()
        out_ptr = ffi.new("CImageInfo**")
        count = ffi.new("size_t*")

        result = lib.zpdf_get_page_images(self._handle, page_num, out_ptr, count)
        if result != 0 or out_ptr[0] == ffi.NULL:
            return []

        try:
            images = []
            for i in range(count[0]):
                img = out_ptr[0][i]
                images.append({
                    "rect": [img.x0, img.y0, img.x1, img.y1],
                    "width": img.width,
                    "height": img.height,
                })
            return images
        finally:
            lib.zpdf_free_images(out_ptr[0], count[0])

    # =========================================================================
    # Form Fields
    # =========================================================================

    @property
    def form_fields(self) -> list[dict]:
        """Extract form fields from the document.

        Returns list of fields, each with:
        {"name": str, "value": str or None, "type": str, "rect": [x0,y0,x1,y1] or None}.
        """
        self._check_open()
        out_ptr = ffi.new("CFormField**")
        count = ffi.new("size_t*")

        result = lib.zpdf_get_form_fields(self._handle, out_ptr, count)
        if result != 0 or out_ptr[0] == ffi.NULL:
            return []

        field_types = {0: "text", 1: "button", 2: "choice", 3: "signature", 4: "unknown"}

        try:
            fields = []
            for i in range(count[0]):
                f = out_ptr[0][i]
                name = ffi.buffer(f.name, f.name_len)[:].decode("utf-8", errors="replace")
                value = None
                if f.value_len > 0:
                    value = ffi.buffer(f.value, f.value_len)[:].decode("utf-8", errors="replace")
                rect = None
                if f.has_rect:
                    rect = [f.x0, f.y0, f.x1, f.y1]
                fields.append({
                    "name": name,
                    "value": value,
                    "type": field_types.get(f.field_type, "unknown"),
                    "rect": rect,
                })
            return fields
        finally:
            lib.zpdf_free_form_fields(out_ptr[0], count[0])

    def __iter__(self) -> Iterator[str]:
        for i in range(self.page_count):
            yield self.extract_page(i)

    def __len__(self) -> int:
        return self.page_count

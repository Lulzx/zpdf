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
    __slots__ = ("_handle", "_closed")

    def __init__(self, source: Union[str, Path, bytes]):
        self._closed = False

        if isinstance(source, bytes):
            self._handle = lib.zpdf_open_memory(source, len(source))
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
            self._closed = True

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

    def extract_all(self, parallel: bool = True, reading_order: bool = False) -> str:
        """Extract text from all pages.

        Args:
            parallel: If True (default), use multi-threaded extraction for speed.
            reading_order: If True, returns text in visual reading order
                          (left-to-right, top-to-bottom with column detection).
                          If False (default), returns text in PDF stream order.
        """
        self._check_open()
        out_len = ffi.new("size_t*")

        if reading_order:
            if parallel:
                buf_ptr = lib.zpdf_extract_all_reading_order_parallel(self._handle, out_len)
            else:
                buf_ptr = lib.zpdf_extract_all_reading_order(self._handle, out_len)
        else:
            if parallel:
                buf_ptr = lib.zpdf_extract_all_parallel(self._handle, out_len)
            else:
                buf_ptr = lib.zpdf_extract_all(self._handle, out_len)

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

    def __iter__(self) -> Iterator[str]:
        for i in range(self.page_count):
            yield self.extract_page(i)

    def __len__(self) -> int:
        return self.page_count

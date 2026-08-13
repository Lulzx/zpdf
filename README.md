# zpdf (alpha stage - early version)

A PDF text extraction library written in Zig.

## Features

- Memory-mapped file reading, zero-copy where possible
- Streaming text extraction with efficient arena allocation
- Multiple decompression filters: FlateDecode, ASCII85, ASCIIHex, LZW, RunLength
- Font encoding support: WinAnsi, MacRoman, ToUnicode CMap
- XRef table and stream parsing (PDF 1.5+)
- Configurable error handling (strict or permissive)
- Structure tree extraction for tagged PDFs (PDF/UA)
- Optional geometric reading order for non-tagged PDFs
- Markdown export for structured PDFs

## Benchmarking

Build with `zig build -Doptimize=ReleaseFast`, then run:

```bash
zig build bench -- document.pdf
```

This runs five zpdf extractions and, when `mutool` is installed, one MuPDF
comparison. Treat the result as a local diagnostic rather than a controlled
cross-tool benchmark: record the zpdf revision, Zig and MuPDF versions,
hardware, input checksum, and run policy when publishing results. Additional
corpus and accuracy tools are documented in [`benchmark/README.md`](benchmark/README.md).
The full methodology uses
[olmOCR-Bench, veraPDF, and PDF.js corpora](docs/benchmark-corpora.md) to keep
ground-truth accuracy separate from compatibility and robustness. Initial
[measured findings](docs/benchmark-findings.md) identify concrete reading-order
and dense-text gaps.

## Requirements

- Zig 0.15.2 or later

## Building

```bash
zig build              # Build library and CLI
zig build test         # Run tests
```

## Usage

### Library

```zig
const std = @import("std");
const zpdf = @import("zpdf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const doc = try zpdf.Document.open(allocator, "file.pdf");
    defer doc.close();

    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const writer = &bw.interface;
    defer writer.flush() catch {};

    for (0..doc.pageCount()) |page_num| {
        try doc.extractText(page_num, writer);
    }
}
```

### CLI

```bash
zpdf extract document.pdf              # Extract all pages (uses structure tree for reading order)
zpdf extract -p 1-10 document.pdf      # Extract pages 1-10
zpdf extract -o out.txt document.pdf   # Output to file
zpdf info document.pdf                 # Show document info
zpdf bench document.pdf                # Run benchmark
```

### Python

```python
import zpdf

with zpdf.Document("file.pdf") as doc:
    print(doc.page_count)

    # Single page
    text = doc.extract_page(0)

    # All pages (structure-tree order when available; otherwise stream order)
    all_text = doc.extract_all()

    # Fast mode (higher throughput, stream-order extraction)
    fast_text = doc.extract_all(mode="fast")

    # Page info
    info = doc.get_page_info(0)
    print(f"{info.width}x{info.height}")

# Zero-copy memory open (unsafe semantics for other language bindings)
with zpdf.Document.open_memory_unsafe(open("file.pdf", "rb").read()) as doc:
    print(doc.page_count)
```

Build the shared library first:
```bash
zig build -Doptimize=ReleaseFast
PYTHONPATH=python python3 examples/basic.py
```

Build an installable, platform-specific wheel from the current Zig library:
```bash
python3 -m pip install build
python3 -m build --wheel python
```

When developing from a checkout, the Python loader prefers `ZPDF_LIB` and
`zig-out/lib` over any packaged library, so tests cannot silently use a stale
binary.

## Project Structure

```
src/
├── root.zig         # Document API and core types
├── main.zig         # CLI entry point
├── capi.zig         # C ABI exports for FFI
├── wapi.zig         # WASM API exports
├── parser.zig       # PDF object parser
├── xref.zig         # XRef table/stream parsing
├── pagetree.zig     # Page tree resolution
├── decompress.zig   # Stream decompression filters
├── encoding.zig     # Font encoding and CMap parsing
├── agl.zig          # Adobe Glyph List mappings
├── cff.zig          # CFF/Type1 font parsing
├── interpreter.zig  # Content stream interpreter
├── structtree.zig   # Structure tree parser (PDF/UA)
├── layout.zig       # Text layout and bounding boxes
├── markdown.zig     # Markdown export
└── simd.zig         # SIMD-accelerated parsing

python/zpdf/         # Python bindings (cffi)
examples/            # Usage examples
```

## Reading Order

The default extraction path prioritizes complete text extraction:

1. **Structure Tree** (preferred): For tagged PDFs, uses marked-content IDs in
   the document's semantic structure. If the structured result contains too
   little of the page's stream text, zpdf keeps the more complete stream-order
   result instead.

2. **Stream Order** (default fallback): Untagged content is extracted in raw PDF
   content-stream order. Python `extract_all(mode="fast")` uses the same order
   while bypassing structure-tree processing.

3. **Geometric Layout** (opt-in): `zpdf extract --reading-order` and Python
   `extract_page(..., reading_order=True)` analyze estimated span positions and
   columns to approximate visual order. This path is experimental.

| Method | Pros | Cons |
|--------|------|------|
| Structure tree | Uses author-provided semantic order | Requires usable tagging and may be incomplete |
| Stream order | Fast and preserves content completeness | May not match visual order |
| Geometric layout | Can approximate visual and column order | Uses estimated bounds and may fail on complex layouts |

## Comparison

| Feature | zpdf | pdfium | MuPDF |
|---------|------|--------|-------|
| **Text Extraction** | | | |
| Stream order | Yes | Yes | Yes |
| Tagged/structure tree API | Yes | Yes | Yes |
| Visual reading order | Experimental | No | Yes |
| Text-span bounds | Estimated | Yes | Yes |
| **Font Support** | | | |
| WinAnsi/MacRoman | Yes | Yes | Yes |
| ToUnicode CMap | Yes | Yes | Yes |
| CID fonts (Type0) | Partial* | Yes | Yes |
| **Compression** | | | |
| FlateDecode, LZW, ASCII85/Hex | Yes | Yes | Yes |
| JBIG2, JPEG2000 | No | Yes | Yes |
| **Other** | | | |
| Encrypted PDFs | No | Yes | Yes |
| Rendering | No | Yes | Yes |

*\*CID fonts: Works when CMap is embedded directly.*

zpdf's span bounds use text positions plus an estimated width; they are not
exact glyph or word bounds. Competitor capabilities refer to their public APIs
and may vary by version.

**Use zpdf when:** Batch processing, tagged PDFs (PDF/UA), simple text extraction, Zig integration.

**Use pdfium when:** Browser integration, full PDF support, proven stability.

**Use MuPDF when:** Complex visual layouts, rendering needed.

## License

CC0 - Public Domain

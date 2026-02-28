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
- Fast stream order fallback for non-tagged PDFs

## Benchmark

Text extraction performance on Apple M4 Pro (reading order):

| Document | Pages | zpdf | MuPDF | Speedup |
|----------|------:|-----:|------:|--------:|
| [Intel SDM](https://cdrdv2.intel.com/v1/dl/getContent/671200) | 5,252 | **582ms** | 2,152ms | 3.7x |
| [Pandas Docs](https://pandas.pydata.org/pandas-docs/version/1.4/pandas.pdf) | 3,743 | **640ms** | 1,130ms | 1.8x |
| [C++ Standard](https://open-std.org/jtc1/sc22/wg21/docs/papers/2023/n4950.pdf) | 2,134 | **438ms** | 1,007ms | 2.3x |
| [PDF Reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf) | 1,310 | **236ms** | 1,481ms | 6.3x |

*Build with `zig build -Doptimize=ReleaseFast` for best performance.*

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

    # All pages (reading order by default)
    all_text = doc.extract_all()

    # Page info
    info = doc.get_page_info(0)
    print(f"{info.width}x{info.height}")
```

Build the shared library first:
```bash
zig build -Doptimize=ReleaseFast
PYTHONPATH=python python3 examples/basic.py
```

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
└── simd.zig         # SIMD-accelerated parsing

python/zpdf/         # Python bindings (cffi)
examples/            # Usage examples
```

## Reading Order

zpdf extracts text in logical reading order using a two-tier approach:

1. **Structure Tree** (preferred): Uses the PDF's semantic structure for tagged/accessible PDFs (PDF/UA). Correctly handles multi-column layouts, sidebars, tables, and captions.

2. **Stream Order** (fallback): When no structure tree exists, extracts text in PDF content stream order. This is fast and works well for most single-column documents.

| Method | Pros | Cons |
|--------|------|------|
| Structure tree | Correct semantic order, handles complex layouts | Only works on tagged PDFs |
| Stream order | Fast, works on any PDF | May not match visual order for complex layouts |

## Comparison

| Feature | zpdf | pdfium | MuPDF |
|---------|------|--------|-------|
| **Text Extraction** | | | |
| Stream order | Yes | Yes | Yes |
| Tagged/structure tree | Yes | No | Yes |
| Visual reading order | No | No | Yes |
| Word bounding boxes | Yes | Yes | Yes |
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

**Use zpdf when:** Batch processing, tagged PDFs (PDF/UA), simple text extraction, Zig integration.

**Use pdfium when:** Browser integration, full PDF support, proven stability.

**Use MuPDF when:** Complex visual layouts, rendering needed.

## License

CC0 - Public Domain

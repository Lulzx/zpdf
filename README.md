# zpdf (alpha stage - early version)

A PDF text extraction library written in Zig.

## Features

- Memory-mapped file reading for efficient large file handling
- Streaming text extraction with efficient arena allocation
- Multiple decompression filters: FlateDecode, ASCII85, ASCIIHex, LZW, RunLength
- Font encoding support: WinAnsi, MacRoman, ToUnicode CMap
- XRef table and stream parsing (PDF 1.5+)
- Configurable error handling (strict or permissive)
- Structure tree extraction for tagged PDFs (PDF/UA)
- Geometric sorting fallback for non-tagged PDFs

## Benchmark

Text extraction performance on Apple M4 Pro:

| Document | Pages | zpdf | pdfium | MuPDF |
|----------|------:|-----:|-------:|------:|
| [Intel SDM](https://cdrdv2.intel.com/v1/dl/getContent/671200) | 5,252 | **227ms** | 3,632ms | 2,331ms |
| [Pandas Docs](https://pandas.pydata.org/pandas-docs/version/1.4/pandas.pdf) | 3,743 | **762ms** | 2,379ms | 1,237ms |
| [C++ Standard](https://open-std.org/jtc1/sc22/wg21/docs/papers/2023/n4950.pdf) | 2,134 | **671ms** | 1,964ms | 1,079ms |
| Acrobat Reference | 651 | **120ms** | - | - |
| US Constitution | 85 | **24ms** | 63ms | 58ms |

*Lower is better. Build with `zig build -Doptimize=ReleaseFast`.*

Peak throughput: **23,137 pages/sec** (Intel SDM)

### Accuracy

Character accuracy vs MuPDF reference (stream order extraction):

| Tool | Char Accuracy | WER |
|------|---------------|-----|
| zpdf | 99.6-99.9% | 1-3% |
| pdfium | 99.2-100% | 0-4% |
| MuPDF | 100% (ref) | 0% |

Build with `zig build -Doptimize=ReleaseFast` for best performance.

Run `PYTHONPATH=python python benchmark/accuracy.py` to reproduce (requires `pypdfium2`).

### veraPDF Corpus (2,907 PDFs)

Batch processing benchmark on [veraPDF test corpus](https://github.com/veraPDF/veraPDF-corpus):

| Tool | Time | PDFs/sec | Speedup |
|------|------|----------|---------|
| zpdf | **0.5s** | **6,013** | **4.7x** |
| PyMuPDF | 2.3s | 1,274 | 1x |

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
    var writer = std.fs.File.stdout().writer(&buf);
    defer writer.interface.flush() catch {};

    for (0..doc.pages.items.len) |page_num| {
        try doc.extractText(page_num, &writer.interface);
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
├── capi.zig         # C ABI exports for FFI
├── parser.zig       # PDF object parser
├── xref.zig         # XRef table/stream parsing
├── pagetree.zig     # Page tree resolution
├── decompress.zig   # Stream decompression filters
├── encoding.zig     # Font encoding and CMap parsing
├── interpreter.zig  # Content stream interpreter
├── structtree.zig   # Structure tree parser (PDF/UA)
├── simd.zig         # SIMD string operations
└── main.zig         # CLI

python/zpdf/         # Python bindings (cffi)
examples/            # Usage examples
```

## Reading Order

zpdf extracts text in logical reading order using a two-tier approach:

1. **Structure Tree** (preferred): Uses the PDF's semantic structure for tagged/accessible PDFs (PDF/UA). Correctly handles multi-column layouts, sidebars, tables, and captions.

2. **Geometric Sorting** (fallback): When no structure tree exists, sorts text by Y-coordinate (top→bottom), then X-coordinate (left→right).

| Method | Pros | Cons |
|--------|------|------|
| Structure tree | Correct semantic order, handles complex layouts | Only works on tagged PDFs |
| Geometric sort | Works on any PDF | May fail on complex layouts |

## Comparison

| Feature | zpdf | pdfium | MuPDF |
|---------|------|--------|-------|
| **Text Extraction** | | | |
| Stream order | Yes | Yes | Yes |
| Tagged/structure tree | Yes | No | Yes |
| Visual reading order | Experimental | No | Yes |
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

WTFPL

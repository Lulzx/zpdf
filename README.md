# zpdf (alpha stage - early version)

A PDF text extraction library written in Zig.

## Features

- Memory-mapped file reading for efficient large file handling
- Streaming text extraction with efficient arena allocation
- Multiple decompression filters: FlateDecode, ASCII85, ASCIIHex, LZW, RunLength
- Font encoding support: WinAnsi, MacRoman, ToUnicode CMap
- XRef table and stream parsing (PDF 1.5+)
- Configurable error handling (strict or permissive)
- Multi-threaded parallel page extraction

## Benchmark

Text extraction performance on Apple M4 Pro (parallel, stream order):

| Document | Pages | zpdf | pdfium | MuPDF |
|----------|------:|-----:|-------:|------:|
| [Intel SDM](https://cdrdv2.intel.com/v1/dl/getContent/671200) | 5,252 | **1,640ms** | 3,632ms | 2,331ms |
| [C++ Standard](https://open-std.org/jtc1/sc22/wg21/docs/papers/2023/n4950.pdf) | 2,134 | 5,835ms | 1,964ms | **1,079ms** |
| [Pandas Docs](https://pandas.pydata.org/pandas-docs/version/1.4/pandas.pdf) | 3,743 | 6,656ms | 2,379ms | **1,237ms** |
| Acrobat Reference | 651 | **958ms** | - | - |
| US Constitution | 85 | 172ms | 63ms | **58ms** |

*Lower is better. zpdf uses parallel extraction by default.*

### Accuracy

All tools achieve ~99%+ character accuracy vs MuPDF reference:

| Tool | Char Accuracy | WER |
|------|---------------|-----|
| zpdf | 99.3-99.9% | 1-8% |
| pdfium | 99.2-100% | 0-4% |
| MuPDF | 100% (ref) | 0% |

Build with `zig build -Doptimize=ReleaseFast` for best performance.

Run `PYTHONPATH=python python benchmark/accuracy.py` to reproduce (requires `pypdfium2`).

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
zpdf extract document.pdf              # Extract all pages to stdout
zpdf extract -p 1-10 document.pdf      # Extract pages 1-10
zpdf extract -o out.txt document.pdf   # Output to file
zpdf extract --reading-order doc.pdf   # Use visual reading order (experimental)
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

    # All pages (parallel by default)
    all_text = doc.extract_all()

    # Reading order extraction (experimental)
    ordered_text = doc.extract_all(reading_order=True)

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
├── simd.zig         # SIMD string operations
└── main.zig         # CLI

python/zpdf/         # Python bindings (cffi)
examples/            # Usage examples
```

## Comparison

| Feature | zpdf | pdfium | MuPDF |
|---------|------|--------|-------|
| **Text Extraction** | | | |
| Stream order | Yes | Yes | Yes |
| Reading order | Experimental | No | Yes |
| Word bounding boxes | Yes | Yes | Yes |
| **Font Support** | | | |
| WinAnsi/MacRoman | Yes | Yes | Yes |
| ToUnicode CMap | Partial* | Yes | Yes |
| CID fonts (Type0) | Partial* | Yes | Yes |
| **Compression** | | | |
| FlateDecode, LZW, ASCII85/Hex | Yes | Yes | Yes |
| JBIG2, JPEG2000 | No | Yes | Yes |
| **Other** | | | |
| Encrypted PDFs | No | Yes | Yes |
| Rendering | No | Yes | Yes |
| Multi-threaded | Yes | No** | No |

*\*ToUnicode/CID: Works when CMap is embedded directly.*
*\*\*pdfium requires multi-process for parallelism (forked before thread support).*

**Use zpdf when:** Batch processing, simple text extraction, Zig integration.

**Use pdfium when:** Browser integration, full PDF support, proven stability.

**Use MuPDF when:** Reading order matters, complex layouts, rendering needed.

## License

WTFPL

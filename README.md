# zpdf

A PDF text extraction library written in Zig.

## Features

- Memory-mapped file reading for efficient large file handling
- Streaming text extraction (no intermediate allocations)
- Multiple decompression filters: FlateDecode, ASCII85, ASCIIHex, LZW, RunLength
- Font encoding support: WinAnsi, MacRoman, ToUnicode CMap
- XRef table and stream parsing (PDF 1.5+)
- Configurable error handling (strict or permissive)
- Multi-threaded parallel page extraction

## Benchmark

Text extraction performance vs MuPDF 1.26 (`mutool convert -F text`) on Apple M4 Pro:

### Sequential

| Document | Pages | Size | zpdf | MuPDF | Speedup |
|----------|-------|------|------|-------|---------|
| [C++ Standard Draft](https://open-std.org/jtc1/sc22/wg21/docs/papers/2023/n4950.pdf) | 2,134 | 8 MB | 250 ms | 968 ms | **3.9x** |
| [Pandas Documentation](https://pandas.pydata.org/pandas-docs/version/1.4/pandas.pdf) | 3,743 | 15 MB | 395 ms | 1,112 ms | **2.8x** |
| [Intel SDM](https://cdrdv2.intel.com/v1/dl/getContent/671200) | 5,252 | 25 MB | 451 ms | 2,099 ms | **4.7x** |

### Parallel (default)

| Document | Pages | Size | zpdf | MuPDF | Speedup |
|----------|-------|------|------|-------|---------|
| C++ Standard Draft | 2,134 | 8 MB | 131 ms | 966 ms | **7.4x** |
| Pandas Documentation | 3,743 | 15 MB | 218 ms | 1,117 ms | **5.1x** |
| Intel SDM | 5,252 | 25 MB | 117 ms | 2,098 ms | **17.9x** |

Peak throughput: **45,000 pages/sec** (Intel SDM, parallel)

Build with `zig build -Doptimize=ReleaseFast` for these results.

### SIMD Acceleration

zpdf uses SIMD-accelerated routines for hot paths:
- Whitespace skipping (content streams are whitespace-heavy)
- Delimiter detection (tokenization)
- Keyword search (`stream`, `endstream`, `startxref`)
- String boundary scanning

Auto-detects: NEON (ARM64), AVX2/SSE4.2 (x86_64), or scalar fallback.

*Note: MuPDF's threading (`-T` flag) is for rendering/rasterization only. Text extraction via `mutool convert -F text` is single-threaded by design. zpdf parallelizes text extraction across pages.*

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
zpdf extract document.pdf           # Extract all pages to stdout
zpdf extract -p 1-10 document.pdf   # Extract pages 1-10
zpdf extract -o out.txt document.pdf # Output to file
zpdf info document.pdf              # Show document info
zpdf bench document.pdf             # Run benchmark
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

## Comparison with MuPDF

| Feature | zpdf | MuPDF |
|---------|------|-------|
| **Text Extraction** | | |
| Reading order / layout analysis | No | Yes |
| Two-column detection | No | Yes |
| Paragraph grouping | No | Yes |
| Word/line bounding boxes | No | Yes |
| **Font Support** | | |
| WinAnsi/MacRoman | Yes | Yes |
| ToUnicode CMap | Yes | Yes |
| CID fonts (Type0) | Partial | Full |
| Embedded fonts | No | Yes |
| **Compression** | | |
| FlateDecode, LZW, ASCII85/Hex | Yes | Yes |
| JBIG2, JPEG2000 | No | Yes |
| **PDF Features** | | |
| Incremental updates | Yes | Yes |
| Encrypted PDFs | No | Yes |
| Forms / Annotations | No | Yes |
| Rendering | No | Yes |

**Use zpdf when:** Speed matters, simple layouts, batch processing raw text.

**Use MuPDF when:** Complex layouts, encrypted PDFs, accurate reading order needed.

## License

MIT

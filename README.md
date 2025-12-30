# ZPDF - Zero-copy PDF Parser in Zig

A PDF text extraction library designed to beat MuPDF on extraction performance.

## Strategy: Why We Can Win

MuPDF is excellent at **rendering**. But for **text extraction**, it has structural inefficiencies:

| MuPDF Approach | ZPDF Approach |
|----------------|---------------|
| Build `fz_stext_page` with per-character quads, colors, fonts | Stream directly to output—no intermediate structure |
| Global `fz_context` with pool allocator | Zero global state, explicit allocations |
| `setjmp`/`longjmp` for errors | Zig error unions—composable, no stack unwinding |
| Single-threaded core | Per-page parallelism (PDF pages are independent) |
| Parse everything upfront | Lazy parsing—only decode what's accessed |

### The Key Insight

MuPDF's text extraction pipeline:

```
PDF → [parse] → [interpret content stream] → [build fz_stext_page] → [serialize to text]
                                                    ↑
                                            HUGE INTERMEDIATE STRUCTURE
                                            (char-by-char with positions)
```

ZPDF's pipeline:

```
PDF → [parse] → [interpret content stream] → [stream directly to output]
                                                    ↑
                                            NO INTERMEDIATE ALLOCATION
```

For a 1000-page PDF with 3000 chars/page, MuPDF allocates ~3M `fz_stext_char` structs just to throw them away. We don't.

## Architecture

```
zpdf/
├── src/
│   ├── root.zig        # Core types: Document, Object, LazyObject
│   ├── simd.zig        # SIMD-accelerated lexing (whitespace, delimiters, keywords)
│   ├── decompress.zig  # Stream decompression (FlateDecode, LZW, ASCII85, etc.)
│   ├── main.zig        # CLI tool (drop-in for `mutool draw -F txt`)
│   └── bench.zig       # Benchmark suite with MuPDF comparison
└── build.zig
```

### Core Design Decisions

1. **Memory-mapped files**: Zero-copy access to PDF data. Objects point into mmap'd region.

2. **Lazy object resolution**: XRef table stores offsets, not parsed objects. Parse on first access.

3. **SIMD lexing**: PDF content streams are 30-50% whitespace. SIMD skips 16-32 bytes at a time.

4. **Streaming extraction**: `TextExtractor` takes a writer, not a buffer. No intermediate allocations.

5. **Caller-controlled errors**: `ErrorConfig` lets you choose strict/permissive parsing.

## Usage

### Library

```zig
const zpdf = @import("zpdf");

pub fn main() !void {
    const doc = try zpdf.Document.open(allocator, "file.pdf");
    defer doc.close();

    const stdout = std.io.getStdOut().writer();
    
    for (0..doc.pages.items.len) |page_num| {
        try doc.extractText(page_num, stdout);
    }
}
```

### CLI

```bash
# Extract all text (like mutool draw -F txt)
zpdf extract document.pdf

# Extract specific pages
zpdf extract -p 1-10 document.pdf

# Output to file
zpdf extract -o output.txt document.pdf

# Benchmark against MuPDF
zpdf bench document.pdf
```

## Building

```bash
zig build              # Build library and CLI
zig build test         # Run unit tests
zig build bench        # Build benchmark tool

# Run benchmarks
zig-out/bin/bench test.pdf
```

## Performance Targets

| Metric | MuPDF | ZPDF Target |
|--------|-------|-------------|
| Open (100 page PDF) | ~5ms | ~2ms |
| Extract (100 pages) | ~50ms | ~15ms |
| Peak memory | ~20MB | ~5MB |
| Parallelism | 1 thread | N threads |

## Implementation Status

- [x] Project structure
- [x] SIMD utilities (whitespace skip, delimiter find, keyword search, substring search)
- [x] Stream decompression (FlateDecode, ASCII85, ASCIIHex, LZW, RunLength)
- [x] Error handling with caller-controlled tolerance
- [x] CLI interface
- [x] Benchmark suite
- [x] XRef table parsing (traditional)
- [x] XRef stream parsing (PDF 1.5+)
- [x] Object parser (recursive descent)
- [x] Page tree resolution
- [x] Content stream interpreter
- [x] Font encoding (WinAnsi, MacRoman, ToUnicode CMap)
- [x] Test PDF generator
- [x] Integration tests
- [ ] Parallel extraction (thread pool)
- [ ] Incremental updates
- [ ] CID font handling improvements
- [ ] Advanced CMap parsing

## Why Zig?

1. **Comptime**: Generate perfect hash tables for PDF keywords at compile time
2. **No hidden allocations**: Every `alloc` is explicit—predictable memory ceiling
3. **SIMD first-class**: `@Vector` works on all targets, no intrinsics mess
4. **Error unions**: Perfect for PDF's "soft errors that shouldn't crash"
5. **C interop**: Can wrap MuPDF for comparison, or be wrapped by C projects
6. **WASM**: `zig build -Dtarget=wasm32-wasi` just works

## Contributing

The highest-impact work right now:

1. **XRef parsing**: Complete `parseXrefTable` and `parseXrefStream`
2. **Object parser**: Recursive descent parser for PDF objects
3. **Font encoding**: Proper ToUnicode CMap parsing
4. **Test corpus**: Gather edge-case PDFs that break other parsers

## License

MIT

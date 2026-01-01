# Benchmarks

Scripts for benchmarking zpdf against other PDF text extraction tools.

## Requirements

- Build zpdf first: `zig build -Doptimize=ReleaseFast`
- Install MuPDF: `brew install mupdf` (macOS) or `apt install mupdf-tools` (Linux)
- Python 3 with tqdm: `pip install tqdm`

## veraPDF Corpus Benchmark

Test against 2,907 PDFs from the [veraPDF test corpus](https://github.com/veraPDF/veraPDF-corpus).

### Setup

```bash
cd benchmark
git clone https://github.com/veraPDF/veraPDF-corpus.git verapdf
```

### Run

```bash
python3 verapdf_bench.py
```

### Expected Results

On Apple M4 Pro:

| Tool | Time | PDFs/sec | Speedup |
|------|------|----------|---------|
| zpdf | ~6s | ~487 | ~5.7x |
| MuPDF | ~34s | ~85 | 1x |

## Accuracy Benchmark

Compare character-level accuracy against MuPDF reference output.

```bash
PYTHONPATH=../python python3 accuracy.py
```

Requires `pypdfium2`: `pip install pypdfium2`

# Benchmarks

Scripts for benchmarking zpdf against other PDF text extraction tools.

The reproducible corpus suite uses three complementary datasets:

- **olmOCR-Bench** for verified, fact-based text and reading-order accuracy.
- **veraPDF corpus** for PDF/A, PDF/UA, and PDF specification robustness.
- **PDF.js test PDFs** for parser regressions and unusual encodings/features.

See [`../docs/benchmark-corpora.md`](../docs/benchmark-corpora.md) for the
methodology, pinned revisions, licensing, installation, and reporting policy.
The first measured results are recorded in
[`../docs/benchmark-findings.md`](../docs/benchmark-findings.md).

Quick start:

```bash
python3 benchmark/setup_corpora.py
zig build -Doptimize=ReleaseFast
python3 -m pip install -e python pypdfium2

# Generate outputs consumed by olmOCR-Bench's official evaluator
python3 benchmark/olmocr_generate.py --tools zpdf-accuracy zpdf-fast mutool pdftotext pdfium

# Compatibility/robustness runs
python3 benchmark/robustness.py verapdf
python3 benchmark/robustness.py pdfjs
```

## Requirements

- Build zpdf first: `zig build -Doptimize=ReleaseFast`
- Install MuPDF: `brew install mupdf` (macOS) or `apt install mupdf-tools` (Linux)
- Python 3 with tqdm: `pip install tqdm`

## Legacy veraPDF Comparison

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

### Reporting Results

Results depend on the repository revision, Zig and MuPDF versions, hardware,
corpus revision, cache state, and run policy. Record those details alongside
the raw command output instead of treating a previous machine's measurements
as expected performance.

## Legacy MuPDF-agreement Benchmark

Compare character-level output similarity against MuPDF output.

```bash
PYTHONPATH=../python python3 accuracy.py
```

This is useful as a regression diagnostic, but it is not ground-truth accuracy:
MuPDF may be wrong and two tools may produce equally valid reading orders. Use
olmOCR-Bench for publishable correctness results.

Requires `pypdfium2`: `pip install pypdfium2`

## Memory Regression Guard

Check repeated full-document extraction for accuracy-mode memory regressions.

```bash
PYTHONPATH=../python python3 memory_guard.py --pdf docs/pdf_reference.pdf
```

If you want this check in pytest as well, run:

```bash
ZPDF_RUN_MEMORY_GUARDS=1 PYTHONPATH=python python3 -m pytest -q python/tests/test_memory_regression.py
```

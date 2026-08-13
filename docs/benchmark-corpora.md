# PDF corpus benchmark methodology

zpdf uses three corpora because no single dataset answers every benchmarking
question. Accuracy, standards coverage, malformed-input handling, and speed are
reported separately. The downloaded files and generated reports are ignored by
git.

## Corpus selection

| Corpus | Pinned revision | Scope | Local payload at selection time | License |
|---|---|---|---:|---|
| [olmOCR-Bench](https://huggingface.co/datasets/allenai/olmOCR-bench) | `54a96a6fb6a2bd3b297e59869491db4d3625b711` | 1,403 single-page PDFs and 7,010 verified tests | 439 MB | ODC-BY-1.0 |
| [veraPDF corpus](https://github.com/veraPDF/veraPDF-corpus) | `49de56cd987929932c9e4fbbbe67d052bf44ef83` | 2,907 PDF/A, PDF/UA, and ISO 32000 test PDFs | 168 MB of PDFs | CC BY 4.0 |
| [PDF.js test PDFs](https://github.com/mozilla/pdf.js/tree/master/test/pdfs) | `5903d58d58e4dd9ce6ffa3834aea8480f06b4ada` | 974 checked-in regression PDFs | 124 MB of PDFs | See PDF.js repository and individual fixture provenance |

PDF.js also contains 459 `.pdf.link` files. They point to external fixtures and
are deliberately excluded from the default run: their availability, licensing,
and aggregate size are not controlled by the PDF.js checkout. The three direct
payloads total approximately 731 MB; allow 1–1.5 GB for Git metadata, working
trees, and generated output.

The revisions live in `benchmark/corpus_manifest.json`. Updating a revision is
an intentional benchmark change and should be called out in published results.

## Why each corpus is used

### olmOCR-Bench: correctness

The current `benchmark/accuracy.py` compares output to MuPDF with edit
similarity. That measures agreement with MuPDF, not objective accuracy.
olmOCR-Bench instead checks human-reviewed facts: text presence and absence,
relative reading order, table relationships, and mathematical expressions.
Its evaluator accepts plain text or Markdown, so it can score zpdf, MuPDF,
Poppler, PDFium, and Tika under the same rules.

zpdf is a born-digital PDF parser and does not perform OCR. Report both:

1. **Born-digital score:** `arxiv_math`, `headers_footers`, `long_tiny_text`,
   `multi_column`, and `table_tests`, with limitations noted for formula/table
   reconstruction.
2. **All-corpus score:** includes `old_scans` and `old_scans_math`, explicitly
   labeled as containing image-only material outside zpdf's supported scope.

Never describe MuPDF output as ground truth. Do not combine accuracy scores with
throughput into a single number.

### veraPDF: standards and robustness

veraPDF files are atomic conformance examples, not transcribed natural-language
ground truth. Use them for open/crash/hang/empty-output rates, performance, and
feature-specific investigation—especially tagged PDF and PDF/UA behavior. Do
not publish character similarity to another extractor as “accuracy.”

### PDF.js: regression robustness

The checked-in PDF.js fixtures cover unusual fonts, encodings, annotations,
damaged files, and historical parser bugs. Use them for the same operational
outcomes as veraPDF. Some fixtures are intentionally empty, image-only, or
invalid, so an empty result is distinct from a parser error and is not
automatically considered a failure.

## Installation

Requirements:

- Git and Git LFS
- Zig 0.15.2 or later
- Python 3.10 or later
- Optional comparison tools: MuPDF (`mutool`), Poppler (`pdftotext`), Apache
  Tika, and `pypdfium2`

Download all pinned corpora:

```bash
python3 benchmark/setup_corpora.py
```

Or download one corpus:

```bash
python3 benchmark/setup_corpora.py olmocr
python3 benchmark/setup_corpora.py verapdf
python3 benchmark/setup_corpora.py pdfjs
```

Build zpdf and install the Python dependencies:

```bash
zig build -Doptimize=ReleaseFast
python3 -m pip install -e python
python3 -m pip install pypdfium2
```

## Accuracy workflow

Generate the candidate directories expected by the official evaluator:

```bash
python3 benchmark/olmocr_generate.py \
  --tools zpdf-accuracy zpdf-fast mutool pdftotext pdfium
```

For a quick smoke test, add `--limit 10`. Generation timings and errors are
written to `benchmark/results/olmocr/generation.jsonl`.

Install the pinned evaluator without installing the GPU pipeline:

```bash
python3 -m venv .venv-olmocr-bench
source .venv-olmocr-bench/bin/activate
python3 -m pip install -e 'benchmark/corpora/olmocr-code[bench]' numpy
python3 -m playwright install chromium
```

`numpy` is listed in olmOCR's `elo` extra rather than its `bench` extra, but
the pinned benchmark entry point imports it for bootstrap confidence intervals.
Chromium is required to render the benchmark's KaTeX formula references.

Then score one or all candidates:

```bash
python3 -m olmocr.bench.benchmark \
  --dir benchmark/corpora/olmocr-bench/bench_data \
  --candidate zpdf-accuracy \
  --test_report benchmark/results/olmocr/zpdf-accuracy.html

python3 -m olmocr.bench.benchmark \
  --dir benchmark/corpora/olmocr-bench/bench_data
```

The generator preserves each PDF's relative category directory and produces
the required `<stem>_pg1_repeat1.md` names. A limited generation is suitable
for extraction smoke testing, but the official evaluator expects output for
every PDF referenced by the selected JSONL file unless its `--force` behavior
is intentionally used.

## Robustness workflow

Run every available extractor:

```bash
python3 benchmark/robustness.py verapdf
python3 benchmark/robustness.py pdfjs
```

Select tools or take a deterministic slice during development:

```bash
python3 benchmark/robustness.py pdfjs \
  --tools zpdf-accuracy zpdf-fast mutool pdftotext pdfium \
  --offset 100 --limit 50 --timeout 15
```

Every extraction occurs in a child process. Native crashes and timeouts are
therefore recorded against one PDF rather than terminating the run. JSON
reports contain the corpus-relative filename, file hash, elapsed time,
character count, status, error, platform, and available tool versions.

Statuses mean:

- `ok`: extraction completed with non-whitespace text;
- `empty`: extraction completed without text;
- `error`: exception, non-zero process exit, native crash, or timeout.

## Reporting checklist

Record the following with any results:

- zpdf Git revision and dirty/clean state;
- corpus revisions from `benchmark/corpus_manifest.json`;
- extractor versions and exact commands;
- operating system, architecture, CPU, and memory;
- warm/cold cache policy and timeout;
- whether results cover all files or a deterministic offset/limit;
- scores per olmOCR category, including a separate born-digital aggregate;
- success, empty, error, and timeout counts for robustness corpora;
- median and percentile latency in addition to aggregate throughput.

The corpora contain adversarial and malformed inputs. Run them on a dedicated
machine or CI worker with ordinary least privilege; do not open their embedded
links or attachments as part of extraction.

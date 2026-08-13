# Corpus benchmark findings

This document records the first reproducible corpus run made on 2026-08-13.
Methodology, setup, and reporting rules are in
[`benchmark-corpora.md`](benchmark-corpora.md). Raw generated output remains
under the git-ignored `benchmark/results/` directory.

## Environment and scope

- zpdf source revision under test: `9a090eb7c1a165f23dadbf0d9e683b2a01b12de2`.
  The benchmark harness and these findings were added in the following commit;
  they do not alter extraction code.
- olmOCR-Bench: `54a96a6fb6a2bd3b297e59869491db4d3625b711`.
- Official evaluator: `f7cfe4c22098b154c76b6ec950d1c0a464eecf8d`.
- Platform: Apple M4 Pro, macOS 26.6, Python 3.13.4, Zig 0.16.0.
- Candidates: zpdf accuracy, zpdf fast, MuPDF `mutool`, Poppler
  `pdftotext`, and PDFium through `pypdfium2`.
- Comparison versions: MuPDF 1.28.1, Poppler 26.08.0, and pypdfium2 4.30.0.
- All 1,403 olmOCR-Bench PDFs were extracted by every candidate in isolated
  child processes. No candidate reported an extraction error.

The numbers below are official olmOCR-Bench fact pass rates. “Baseline” is the
evaluator's output sanity check. Category scores should not be averaged by test
count because the official overall method gives each JSONL group equal weight.

## Measured accuracy

### Multi-column reading order

| Tool | Baseline | Reading-order facts | Official subset average |
|---|---:|---:|---:|
| PDFium | 95.2% | **65.6%** | **80.4%** |
| Poppler | 93.5% | 65.3% | 79.4% |
| MuPDF | 95.2% | 57.9% | 76.6% |
| zpdf accuracy | 91.3% | 51.0% | 71.2% |
| zpdf fast | 91.3% | 51.0% | 71.2% |

The identical zpdf modes are significant. Full-document accuracy mode uses a
structure tree when available, but these untagged pages fall back to stream
order. It does not currently invoke geometric reading order. This corpus gives
us a direct target for improving that fallback.

### Long, tiny text

| Tool | Baseline | Text-presence facts | Official subset average |
|---|---:|---:|---:|
| Poppler | 62.9% | **87.6%** | **75.2%** |
| PDFium | 62.9% | 50.2% | 56.6% |
| MuPDF | 62.9% | 49.8% | 56.3% |
| zpdf accuracy | 56.5% | 32.1% | 44.3% |
| zpdf fast | 56.5% | 32.1% | 44.3% |

This is the largest born-digital gap found so far. Likely investigation areas
are font/CMap coverage, text-show operator completeness, and truncation or
buffer limits. Failures should be clustered by PDF/font feature before changing
layout heuristics, because this category primarily tests text completeness.

### Header and footer exclusion

| Tool | Baseline | Absence facts | Official subset average |
|---|---:|---:|---:|
| zpdf accuracy | 92.7% | **49.3%** | **71.0%** |
| zpdf fast | 92.7% | **49.3%** | **71.0%** |
| MuPDF | 95.0% | 39.9% | 67.4% |
| PDFium | 95.4% | 39.5% | 67.4% |
| Poppler | 94.6% | 28.7% | 61.6% |

zpdf leads this particular benchmark because it omits more tested header/footer
strings. This must be interpreted alongside its lower baseline: some apparent
exclusion wins can come from incomplete extraction rather than intentional
header/footer detection. The result is promising but should not be described as
a dedicated header/footer feature.

### Table relationships

All classic extractors scored 0.1% on table facts. zpdf's baseline was 90.9%; the
other three engines' baseline was 93.5%. The test expects Markdown or HTML table
structure and neighbor relationships, which plain-text output does not encode.
This category becomes meaningful if zpdf gains explicit table reconstruction.

### Old scans

zpdf, MuPDF, and PDFium each scored 13.3% on the fact group and 0% baseline;
their passes were text-absence tests on empty output. Poppler scored 58.7% on
the fact group despite a 0% baseline, suggesting that these files contain or
expose text in a way its pipeline can recover. This subset is outside zpdf's
declared non-OCR scope and is excluded from born-digital comparisons.

### Formula categories

`arxiv_math` and `old_scans_math` are not included in this initial findings
table. The official evaluator renders and geometrically matches thousands of
KaTeX expressions; on this machine a single-candidate all-category invocation
was projected to take roughly 45 minutes. The documented setup supports these
tests, and a controlled long run should publish them separately. Plain-text
extractors are not expected to reproduce LaTeX structure reliably.

## Extraction throughput diagnostic

Summed in-process extraction time over all 1,403 PDFs (child-process startup is
excluded by the adapter's timer):

| Tool | Extraction time | Empty outputs | Errors |
|---|---:|---:|---:|
| Poppler | 20.4 s | 0 | 0 |
| MuPDF | 28.7 s | 175 | 0 |
| zpdf fast | 28.9 s | 192 | 0 |
| zpdf accuracy | 30.4 s | 192 | 0 |
| PDFium | 79.9 s | 178 | 0 |

These are local diagnostics, not controlled throughput claims. Python and
subprocess boundaries differ between tools, the filesystem cache was warm, and
the order was fixed. Empty-output counts are not correctness scores because the
corpus includes scanned pages.

## Full zpdf robustness runs

Both zpdf modes completed every directly hosted robustness fixture without an
exception, native crash, non-zero child exit, or 15-second timeout:

| Corpus | PDFs | Mode | Non-empty | Empty | Errors |
|---|---:|---|---:|---:|---:|
| veraPDF | 2,907 | accuracy | 791 | 2,116 | **0** |
| veraPDF | 2,907 | fast | 791 | 2,116 | **0** |
| PDF.js checked-in | 974 | accuracy | 569 | 405 | **0** |
| PDF.js checked-in | 974 | fast | 569 | 405 | **0** |

The high veraPDF empty count is expected: many atomic conformance fixtures test
metadata, graphics, color spaces, or deliberately invalid structures rather
than extractable text. Likewise, PDF.js contains image, form, rendering, empty,
and malformed fixtures. “Empty” is therefore an observation, not a failed
accuracy assertion. The important initial robustness result is zero process
failures over 3,881 distinct PDFs in each mode.

For comparison, all three other engines also completed veraPDF without a
reported error: MuPDF produced 863 non-empty files, Poppler 838, and PDFium
840. On the more adversarial PDF.js fixtures, strict process-exit accounting
recorded 30 errors for MuPDF, 21 for Poppler, and 22 for PDFium, versus zero for
both zpdf modes. These counts include intentionally invalid PDFs and therefore
measure CLI/API acceptance policy as well as robustness; they do not imply that
zpdf rendered or extracted those files correctly. The per-file JSON reports are
the appropriate starting point for classifying each difference.

## Priorities exposed by the corpus

1. Make geometric layout an explicit benchmark candidate and consider it as the
   untagged fallback for accuracy mode; use `multi_column` as the acceptance set.
2. Cluster `long_tiny_text` failures by font type, encoding, operators, and
   output-length ratio to identify extraction-completeness defects.
3. Preserve the header/footer result while separating genuine artifact removal
   from missing text.
4. Treat table reconstruction and OCR as separate product capabilities rather
   than silently folding their scores into core PDF text extraction.
5. Run formula subsets on a dedicated long-running worker and report them apart
   from ordinary Unicode text extraction.

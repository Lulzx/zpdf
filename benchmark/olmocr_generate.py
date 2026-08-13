#!/usr/bin/env python3
"""Generate candidate outputs for the official olmOCR-Bench evaluator."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from extractors import available_tools, extract_isolated


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_DATA = SCRIPT_DIR / "corpora" / "olmocr-bench" / "bench_data"
DEFAULT_RESULTS = SCRIPT_DIR / "results" / "olmocr"
ALL_TOOLS = ("zpdf-accuracy", "zpdf-fast", "mutool", "pdftotext", "pdfium", "tika")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA)
    parser.add_argument("--results", type=Path, default=DEFAULT_RESULTS)
    parser.add_argument("--tools", nargs="+", choices=ALL_TOOLS, default=list(ALL_TOOLS))
    parser.add_argument("--limit", type=int, help="Process only the first N PDFs (smoke tests)")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    pdf_root = args.data / "pdfs"
    if not pdf_root.is_dir():
        raise SystemExit(f"olmOCR-Bench PDFs not found: {pdf_root}\nRun benchmark/setup_corpora.py olmocr")

    availability = available_tools()
    missing = [tool for tool in args.tools if not availability[tool]]
    if missing:
        raise SystemExit(f"Unavailable tools: {', '.join(missing)}")

    pdfs = sorted(pdf_root.rglob("*.pdf"))
    if args.limit is not None:
        pdfs = pdfs[: args.limit]
    args.results.mkdir(parents=True, exist_ok=True)
    records = []

    for tool in args.tools:
        print(f"\n{tool}: {len(pdfs)} PDFs", flush=True)
        for index, pdf in enumerate(pdfs, 1):
            relative = pdf.relative_to(pdf_root)
            output = args.data / tool / relative.parent / f"{pdf.stem}_pg1_repeat1.md"
            if output.exists() and not args.force:
                continue
            output.parent.mkdir(parents=True, exist_ok=True)
            result = extract_isolated(tool, pdf, args.timeout)
            output.write_text(result.text, encoding="utf-8")
            records.append({
                "tool": tool,
                "pdf": relative.as_posix(),
                "elapsed_ms": round(result.elapsed_ms, 3),
                "characters": len(result.text),
                "error": result.error,
            })
            status = "ERROR" if result.error else f"{len(result.text)} chars"
            print(f"[{index}/{len(pdfs)}] {relative}: {status}", flush=True)

    log = args.results / "generation.jsonl"
    with log.open("a", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(f"\nGenerated outputs under {args.data}")
    print(f"Generation log: {log}")
    print("Run the official evaluator as documented in docs/benchmark-corpora.md.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Measure extraction success, empty output, failures, and speed on PDF corpora."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from extractors import available_tools, extract_isolated


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ROOT = SCRIPT_DIR / "corpora"
DEFAULT_RESULTS = SCRIPT_DIR / "results"
ALL_TOOLS = ("zpdf-accuracy", "zpdf-fast", "mutool", "pdftotext", "pdfium", "tika")


def version(command: list[str]) -> str | None:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        return (result.stdout or result.stderr).strip().splitlines()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        return None


def corpus_path(name: str, root: Path) -> Path:
    return {
        "verapdf": root / "verapdf",
        "pdfjs": root / "pdfjs" / "test" / "pdfs",
    }[name]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", choices=("verapdf", "pdfjs"))
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--results", type=Path, default=DEFAULT_RESULTS)
    parser.add_argument("--tools", nargs="+", choices=ALL_TOOLS, default=list(ALL_TOOLS))
    parser.add_argument("--limit", type=int, help="Process only the first N PDFs")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    root = corpus_path(args.corpus, args.root)
    if not root.is_dir():
        raise SystemExit(f"Corpus not found: {root}\nRun benchmark/setup_corpora.py {args.corpus}")
    availability = available_tools()
    tools = [tool for tool in args.tools if availability[tool]]
    skipped = [tool for tool in args.tools if not availability[tool]]
    if skipped:
        print(f"Skipping unavailable tools: {', '.join(skipped)}")
    if not tools:
        raise SystemExit("None of the requested extractors are available")

    all_pdfs = sorted(root.rglob("*.pdf"))
    pdfs = all_pdfs[args.offset :]
    if args.limit is not None:
        pdfs = pdfs[: args.limit]
    args.results.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = args.results / f"{args.corpus}-{stamp}.json"

    records = []
    for tool in tools:
        print(f"\n{tool}: {len(pdfs)} PDFs", flush=True)
        for index, pdf in enumerate(pdfs, 1):
            result = extract_isolated(tool, pdf, args.timeout)
            record = {
                "tool": tool,
                "pdf": pdf.relative_to(root).as_posix(),
                "bytes": pdf.stat().st_size,
                "sha256": sha256(pdf),
                "elapsed_ms": round(result.elapsed_ms, 3),
                "characters": len(result.text),
                "status": "error" if result.error else ("empty" if not result.text.strip() else "ok"),
                "error": result.error,
            }
            records.append(record)
            print(f"[{index}/{len(pdfs)}] {record['pdf']}: {record['status']}", flush=True)

    summaries = {}
    for tool in tools:
        selected = [record for record in records if record["tool"] == tool]
        summaries[tool] = {
            "total": len(selected),
            "ok": sum(record["status"] == "ok" for record in selected),
            "empty": sum(record["status"] == "empty" for record in selected),
            "error": sum(record["status"] == "error" for record in selected),
            "elapsed_ms": round(sum(record["elapsed_ms"] for record in selected), 3),
        }

    payload = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "corpus": args.corpus,
        "corpus_root": str(root),
        "corpus_pdf_count": len(all_pdfs),
        "sample_offset": args.offset,
        "sample_count": len(pdfs),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "versions": {
            "zig": version(["zig", "version"]),
            "mutool": version(["mutool", "-v"]),
            "pdftotext": version(["pdftotext", "-v"]),
        },
        "summaries": summaries,
        "records": records,
    }
    output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print("\nSummary")
    print(f"{'Tool':<16} {'OK':>7} {'Empty':>7} {'Error':>7} {'Seconds':>10}")
    for tool, summary in summaries.items():
        print(f"{tool:<16} {summary['ok']:>7} {summary['empty']:>7} {summary['error']:>7} {summary['elapsed_ms']/1000:>10.2f}")
    print(f"\nDetailed results: {output}")


if __name__ == "__main__":
    main()

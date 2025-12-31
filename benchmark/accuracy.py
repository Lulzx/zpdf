#!/usr/bin/env python3
"""
ZPDF Correctness Benchmark

Compares text extraction accuracy against MuPDF (reference), Tika (PDFBox), and pdftotext (Poppler).

Usage:
    python benchmark/accuracy.py [pdf_files...]
"""

import subprocess
import sys
import time
import difflib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "python"))
import zpdf


def normalize(text: str) -> str:
    import re
    return re.sub(r'\s+', ' ', text).strip()


def char_accuracy(hyp: str, ref: str, sample_size: int = 15000) -> float:
    if not ref:
        return 1.0 if not hyp else 0.0
    matcher = difflib.SequenceMatcher(None, hyp[:sample_size], ref[:sample_size])
    return matcher.ratio()


def word_error_rate(hyp: str, ref: str, max_words: int = 2000) -> float:
    hyp_words = hyp.split()[:max_words]
    ref_words = ref.split()[:max_words]
    if not ref_words:
        return 0.0 if not hyp_words else 1.0
    matcher = difflib.SequenceMatcher(None, hyp_words, ref_words)
    return 1.0 - matcher.ratio()


def extract_zpdf(pdf_path: str, reading_order: bool = True) -> tuple:
    """Extract text using zpdf.

    Args:
        pdf_path: Path to PDF file
        reading_order: If True (default), use reading order (visual order).
                      If False, use stream order (faster but may not match visual layout).
    """
    start = time.perf_counter()
    doc = zpdf.Document(pdf_path)
    text = doc.extract_all(parallel=True, reading_order=reading_order)
    pages = doc.page_count
    doc.close()
    elapsed = (time.perf_counter() - start) * 1000
    return text, elapsed, pages


def extract_mutool(pdf_path: str) -> tuple:
    start = time.perf_counter()
    result = subprocess.run(
        ["mutool", "convert", "-F", "text", "-o", "-", pdf_path],
        capture_output=True, text=True
    )
    elapsed = (time.perf_counter() - start) * 1000
    return result.stdout, elapsed


def extract_tika(pdf_path: str) -> tuple:
    start = time.perf_counter()
    result = subprocess.run(
        ["tika", "--text", pdf_path],
        capture_output=True, text=True
    )
    elapsed = (time.perf_counter() - start) * 1000
    return result.stdout, elapsed


def extract_pdftotext(pdf_path: str) -> tuple:
    start = time.perf_counter()
    result = subprocess.run(
        ["pdftotext", pdf_path, "-"],
        capture_output=True, text=True
    )
    elapsed = (time.perf_counter() - start) * 1000
    return result.stdout, elapsed


def check_tool(name: str, cmd: list) -> bool:
    try:
        subprocess.run(cmd, capture_output=True)
        return True
    except FileNotFoundError:
        return False


def main():
    if len(sys.argv) > 1:
        pdf_files = [Path(p) for p in sys.argv[1:]]
    else:
        pdf_dir = Path(__file__).parent.parent
        pdf_files = sorted(pdf_dir.glob("*.pdf"))

    if not pdf_files:
        print("No PDF files found")
        sys.exit(1)

    # Check available tools
    has_mutool = check_tool("mutool", ["mutool", "-v"])
    has_tika = check_tool("tika", ["tika", "--version"])
    has_pdftotext = check_tool("pdftotext", ["pdftotext", "-v"])

    if not has_mutool:
        print("mutool (MuPDF) not found - required as reference")
        sys.exit(1)

    print("ZPDF Accuracy Benchmark")
    print()
    print("Reference: MuPDF (mutool)")
    print(f"Tools: zpdf (reading order), zpdf (stream order), mutool{', tika' if has_tika else ''}{', pdftotext' if has_pdftotext else ''}")
    print()

    for pdf in pdf_files:
        print(f"--- {pdf.name} ---")

        try:
            # Extract with all tools
            # zpdf with reading order (default)
            zpdf_ro_text, zpdf_ro_ms, pages = extract_zpdf(str(pdf), reading_order=True)
            # zpdf with stream order (for comparison)
            zpdf_so_text, zpdf_so_ms, _ = extract_zpdf(str(pdf), reading_order=False)
            mutool_text, mutool_ms = extract_mutool(str(pdf))

            tika_text, tika_ms = ("", 0)
            if has_tika:
                tika_text, tika_ms = extract_tika(str(pdf))

            pdftotext_text, pdftotext_ms = ("", 0)
            if has_pdftotext:
                pdftotext_text, pdftotext_ms = extract_pdftotext(str(pdf))

            # Normalize
            zpdf_ro_norm = normalize(zpdf_ro_text)
            zpdf_so_norm = normalize(zpdf_so_text)
            mutool_norm = normalize(mutool_text)
            tika_norm = normalize(tika_text) if has_tika else ""
            pdftotext_norm = normalize(pdftotext_text) if has_pdftotext else ""

            # Compute metrics vs MuPDF reference
            print(f"Pages: {pages}")
            print()
            print(f"{'Tool':<20} {'Char Acc':>10} {'WER':>8} {'Time':>10} {'Speedup':>10}")
            print("-" * 60)

            # zpdf (reading order) - default
            acc = char_accuracy(zpdf_ro_norm, mutool_norm)
            wer = word_error_rate(zpdf_ro_norm, mutool_norm)
            speedup = mutool_ms / zpdf_ro_ms if zpdf_ro_ms > 0 else 0
            print(f"{'zpdf (reading)':<20} {acc:>9.1%} {wer:>7.1%} {zpdf_ro_ms:>8.0f}ms {speedup:>9.1f}x")

            # zpdf (stream order) - for comparison
            acc = char_accuracy(zpdf_so_norm, mutool_norm)
            wer = word_error_rate(zpdf_so_norm, mutool_norm)
            speedup = mutool_ms / zpdf_so_ms if zpdf_so_ms > 0 else 0
            print(f"{'zpdf (stream)':<20} {acc:>9.1%} {wer:>7.1%} {zpdf_so_ms:>8.0f}ms {speedup:>9.1f}x")

            # MuPDF (reference = 100%)
            print(f"{'mutool':<20} {'100.0%':>10} {'0.0%':>8} {mutool_ms:>8.0f}ms {'1.0x':>10}")

            # Tika
            if has_tika:
                acc = char_accuracy(tika_norm, mutool_norm)
                wer = word_error_rate(tika_norm, mutool_norm)
                speedup = mutool_ms / tika_ms if tika_ms > 0 else 0
                print(f"{'tika':<20} {acc:>9.1%} {wer:>7.1%} {tika_ms:>8.0f}ms {speedup:>9.1f}x")

            # pdftotext
            if has_pdftotext:
                acc = char_accuracy(pdftotext_norm, mutool_norm)
                wer = word_error_rate(pdftotext_norm, mutool_norm)
                speedup = mutool_ms / pdftotext_ms if pdftotext_ms > 0 else 0
                print(f"{'pdftotext':<20} {acc:>9.1%} {wer:>7.1%} {pdftotext_ms:>8.0f}ms {speedup:>9.1f}x")

            print()

        except Exception as e:
            print(f"Error: {e}")
            print()


if __name__ == "__main__":
    main()

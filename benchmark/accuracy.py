#!/usr/bin/env python3
"""
ZPDF Correctness Benchmark

Compares text extraction accuracy and speed against:
- MuPDF (mutool) - accuracy reference
- pdfium (pypdfium2) - speed reference (Chrome's PDF engine)
- Tika (PDFBox)
- pdftotext (Poppler)

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

# Try to import pypdfium2 for pdfium comparison
try:
    import pypdfium2 as pdfium
    HAS_PDFIUM = True
except ImportError:
    HAS_PDFIUM = False


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
        reading_order: If True (default), use accuracy mode.
                      If False, use fast mode.
    """
    start = time.perf_counter()
    doc = zpdf.Document(pdf_path)
    mode = "accuracy" if reading_order else "fast"
    text = doc.extract_all(mode=mode)
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


def extract_pdfium(pdf_path: str) -> tuple:
    """Extract text using pdfium (Chrome's PDF engine)."""
    if not HAS_PDFIUM:
        return "", 0

    start = time.perf_counter()
    pdf = pdfium.PdfDocument(pdf_path)
    texts = []
    for page in pdf:
        textpage = page.get_textpage()
        texts.append(textpage.get_text_bounded())
    text = "\f".join(texts)
    elapsed = (time.perf_counter() - start) * 1000
    return text, elapsed, len(pdf)


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

    print("ZPDF Accuracy & Speed Benchmark")
    print()
    print("Reference: MuPDF (mutool) for accuracy")
    tools = ["zpdf", "mutool"]
    if HAS_PDFIUM:
        tools.append("pdfium")
    if has_tika:
        tools.append("tika")
    if has_pdftotext:
        tools.append("pdftotext")
    print(f"Tools: {', '.join(tools)}")
    print()

    for pdf in pdf_files:
        print(f"--- {pdf.name} ---")

        try:
            # Extract with all tools
            zpdf_text, zpdf_ms, pages = extract_zpdf(str(pdf), reading_order=False)
            mutool_text, mutool_ms = extract_mutool(str(pdf))

            pdfium_text, pdfium_ms = ("", 0)
            if HAS_PDFIUM:
                pdfium_text, pdfium_ms, _ = extract_pdfium(str(pdf))

            tika_text, tika_ms = ("", 0)
            if has_tika:
                tika_text, tika_ms = extract_tika(str(pdf))

            pdftotext_text, pdftotext_ms = ("", 0)
            if has_pdftotext:
                pdftotext_text, pdftotext_ms = extract_pdftotext(str(pdf))

            # Normalize
            zpdf_norm = normalize(zpdf_text)
            mutool_norm = normalize(mutool_text)
            pdfium_norm = normalize(pdfium_text) if HAS_PDFIUM else ""
            tika_norm = normalize(tika_text) if has_tika else ""
            pdftotext_norm = normalize(pdftotext_text) if has_pdftotext else ""

            # Compute metrics vs MuPDF reference
            print(f"Pages: {pages}")
            print()
            print(f"{'Tool':<12} {'Char Acc':>10} {'WER':>8} {'Time':>10} {'pages/sec':>12}")
            print("-" * 54)

            # zpdf
            acc = char_accuracy(zpdf_norm, mutool_norm)
            wer = word_error_rate(zpdf_norm, mutool_norm)
            pps = pages / (zpdf_ms / 1000) if zpdf_ms > 0 else 0
            print(f"{'zpdf':<12} {acc:>9.1%} {wer:>7.1%} {zpdf_ms:>8.0f}ms {pps:>10,.0f}")

            # MuPDF (reference = 100%)
            pps = pages / (mutool_ms / 1000) if mutool_ms > 0 else 0
            print(f"{'mutool':<12} {'100.0%':>10} {'0.0%':>8} {mutool_ms:>8.0f}ms {pps:>10,.0f}")

            # pdfium
            if HAS_PDFIUM:
                acc = char_accuracy(pdfium_norm, mutool_norm)
                wer = word_error_rate(pdfium_norm, mutool_norm)
                pps = pages / (pdfium_ms / 1000) if pdfium_ms > 0 else 0
                print(f"{'pdfium':<12} {acc:>9.1%} {wer:>7.1%} {pdfium_ms:>8.0f}ms {pps:>10,.0f}")

            # Tika
            if has_tika:
                acc = char_accuracy(tika_norm, mutool_norm)
                wer = word_error_rate(tika_norm, mutool_norm)
                pps = pages / (tika_ms / 1000) if tika_ms > 0 else 0
                print(f"{'tika':<12} {acc:>9.1%} {wer:>7.1%} {tika_ms:>8.0f}ms {pps:>10,.0f}")

            # pdftotext
            if has_pdftotext:
                acc = char_accuracy(pdftotext_norm, mutool_norm)
                wer = word_error_rate(pdftotext_norm, mutool_norm)
                pps = pages / (pdftotext_ms / 1000) if pdftotext_ms > 0 else 0
                print(f"{'pdftotext':<12} {acc:>9.1%} {wer:>7.1%} {pdftotext_ms:>8.0f}ms {pps:>10,.0f}")

            print()

        except Exception as e:
            print(f"Error: {e}")
            import traceback
            traceback.print_exc()
            print()


if __name__ == "__main__":
    main()

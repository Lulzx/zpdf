#!/usr/bin/env python3
"""Benchmark: zpdf vs PyMuPDF (reading order) on veraPDF corpus"""

import sys
import time
import difflib
from pathlib import Path
from tqdm import tqdm

# Add zpdf Python bindings to path
SCRIPT_DIR = Path(__file__).parent.absolute()
sys.path.insert(0, str(SCRIPT_DIR / "../python"))

try:
    import zpdf
    HAS_ZPDF = True
except ImportError:
    HAS_ZPDF = False
    print("Warning: zpdf Python bindings not available")
    print("Build with: zig build -Doptimize=ReleaseFast")

try:
    import fitz  # PyMuPDF
    HAS_PYMUPDF = True
    # Suppress MuPDF warnings
    fitz.TOOLS.mupdf_warnings(False)
except ImportError:
    HAS_PYMUPDF = False
    print("Warning: PyMuPDF not installed. Run: pip install pymupdf")

CORPUS_DIR = SCRIPT_DIR / "verapdf"

def find_pdfs():
    """Find all PDF files in the corpus."""
    if not CORPUS_DIR.exists():
        return []
    return list(CORPUS_DIR.rglob("*.pdf"))

def extract_zpdf(pdf_path):
    """Extract text using zpdf Python bindings (reading order by default)."""
    if not HAS_ZPDF:
        return ""
    try:
        with zpdf.Document(str(pdf_path)) as doc:
            return doc.extract_all()
    except Exception:
        return ""

def extract_pymupdf(pdf_path):
    """Extract text using PyMuPDF with reading order (sort=True)."""
    if not HAS_PYMUPDF:
        return ""
    try:
        doc = fitz.open(str(pdf_path))
        text_parts = []
        for page in doc:
            text_parts.append(page.get_text("text", sort=True))
        doc.close()
        return "\n".join(text_parts)
    except Exception:
        return ""

def calculate_similarity(text1, text2):
    """Calculate character-level similarity ratio."""
    if not text1 and not text2:
        return 1.0
    if not text1 or not text2:
        return 0.0
    return difflib.SequenceMatcher(None, text1, text2).ratio()

def benchmark_speed(pdfs):
    """Benchmark extraction speed."""
    print("Speed Benchmark")
    print("=" * 40)

    zpdf_time = 0
    pymupdf_time = 0

    # zpdf
    if HAS_ZPDF:
        start = time.time()
        for pdf in tqdm(pdfs, desc="zpdf", unit="pdf"):
            extract_zpdf(pdf)
        zpdf_time = time.time() - start
        print(f"zpdf: {zpdf_time:.2f}s")

    # PyMuPDF
    if HAS_PYMUPDF:
        start = time.time()
        for pdf in tqdm(pdfs, desc="PyMuPDF", unit="pdf"):
            extract_pymupdf(pdf)
        pymupdf_time = time.time() - start
        print(f"PyMuPDF: {pymupdf_time:.2f}s")

    return zpdf_time, pymupdf_time

def benchmark_accuracy(pdfs, sample_size=100):
    """Benchmark accuracy by comparing outputs."""
    if not HAS_ZPDF or not HAS_PYMUPDF:
        print("\nSkipping accuracy benchmark (missing dependencies)")
        return 0.0

    print()
    print("Accuracy Benchmark (vs PyMuPDF reading order)")
    print("=" * 40)

    # Sample if too many PDFs
    if len(pdfs) > sample_size:
        import random
        pdfs = random.sample(pdfs, sample_size)
        print(f"(Sampling {sample_size} PDFs for accuracy)")

    similarities = []
    for pdf in tqdm(pdfs, desc="comparing", unit="pdf"):
        zpdf_text = extract_zpdf(pdf)
        pymupdf_text = extract_pymupdf(pdf)

        if zpdf_text or pymupdf_text:
            sim = calculate_similarity(zpdf_text, pymupdf_text)
            similarities.append(sim)

    if similarities:
        avg_sim = sum(similarities) / len(similarities)
        min_sim = min(similarities)
        max_sim = max(similarities)
        print(f"Character similarity vs PyMuPDF (reading order):")
        print(f"  Average: {avg_sim*100:.1f}%")
        print(f"  Min: {min_sim*100:.1f}%")
        print(f"  Max: {max_sim*100:.1f}%")
        return avg_sim
    return 0.0

def main():
    print("veraPDF Corpus Benchmark")
    print("=" * 40)
    print()

    pdfs = find_pdfs()
    total = len(pdfs)

    if total == 0:
        print("No PDFs found. Clone the corpus first:")
        print("  cd benchmark")
        print("  git clone https://github.com/veraPDF/veraPDF-corpus.git verapdf")
        return

    print(f"Found {total} PDF files")
    print()

    # Speed benchmark
    zpdf_time, pymupdf_time = benchmark_speed(pdfs)

    # Accuracy benchmark
    benchmark_accuracy(pdfs)

    # Summary
    print()
    print("=" * 40)
    print(f"Summary ({total} PDFs)")
    print("=" * 40)
    print()

    print("| Tool | Time | PDFs/sec | Speedup |")
    print("|------|------|----------|---------|")

    if zpdf_time > 0 and pymupdf_time > 0:
        zpdf_rate = total / zpdf_time
        pymupdf_rate = total / pymupdf_time
        speedup = pymupdf_time / zpdf_time
        print(f"| zpdf | {zpdf_time:.1f}s | {zpdf_rate:.0f} | {speedup:.1f}x |")
        print(f"| PyMuPDF | {pymupdf_time:.1f}s | {pymupdf_rate:.0f} | 1x |")
    elif zpdf_time > 0:
        zpdf_rate = total / zpdf_time
        print(f"| zpdf | {zpdf_time:.1f}s | {zpdf_rate:.0f} | - |")
    elif pymupdf_time > 0:
        pymupdf_rate = total / pymupdf_time
        print(f"| PyMuPDF | {pymupdf_time:.1f}s | {pymupdf_rate:.0f} | - |")

if __name__ == "__main__":
    main()

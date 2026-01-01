#!/usr/bin/env python3
"""Benchmark: zpdf vs mutool on veraPDF corpus with accuracy comparison"""

import subprocess
import time
import tempfile
import difflib
from pathlib import Path
from tqdm import tqdm

SCRIPT_DIR = Path(__file__).parent.absolute()
ZPDF = SCRIPT_DIR / "../zig-out/bin/zpdf"
CORPUS_DIR = SCRIPT_DIR / "verapdf"

def find_pdfs():
    """Find all PDF files in the corpus."""
    if not CORPUS_DIR.exists():
        return []
    return list(CORPUS_DIR.rglob("*.pdf"))

def extract_zpdf(pdf_path):
    """Extract text using zpdf."""
    try:
        result = subprocess.run(
            [str(ZPDF), "extract", str(pdf_path)],
            capture_output=True,
            timeout=30
        )
        return result.stdout.decode('utf-8', errors='replace')
    except Exception:
        return ""

def extract_mutool(pdf_path):
    """Extract text using mutool."""
    try:
        with tempfile.NamedTemporaryFile(suffix='.txt', delete=True) as tmp:
            subprocess.run(
                ["mutool", "convert", "-F", "text", "-o", tmp.name, str(pdf_path)],
                capture_output=True,
                timeout=30
            )
            return Path(tmp.name).read_text(errors='replace')
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

    # zpdf
    start = time.time()
    for pdf in tqdm(pdfs, desc="zpdf", unit="pdf"):
        extract_zpdf(pdf)
    zpdf_time = time.time() - start
    print(f"zpdf: {zpdf_time:.2f}s")

    # mutool
    start = time.time()
    for pdf in tqdm(pdfs, desc="mutool", unit="pdf"):
        extract_mutool(pdf)
    mutool_time = time.time() - start
    print(f"mutool: {mutool_time:.2f}s")

    return zpdf_time, mutool_time

def benchmark_accuracy(pdfs, sample_size=100):
    """Benchmark accuracy by comparing outputs."""
    print()
    print("Accuracy Benchmark")
    print("=" * 40)

    # Sample if too many PDFs
    if len(pdfs) > sample_size:
        import random
        pdfs = random.sample(pdfs, sample_size)
        print(f"(Sampling {sample_size} PDFs for accuracy)")

    similarities = []
    for pdf in tqdm(pdfs, desc="comparing", unit="pdf"):
        zpdf_text = extract_zpdf(pdf)
        mutool_text = extract_mutool(pdf)

        if zpdf_text or mutool_text:  # Skip empty outputs
            sim = calculate_similarity(zpdf_text, mutool_text)
            similarities.append(sim)

    if similarities:
        avg_sim = sum(similarities) / len(similarities)
        min_sim = min(similarities)
        max_sim = max(similarities)
        print(f"Character similarity vs MuPDF:")
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
    zpdf_time, mutool_time = benchmark_speed(pdfs)

    # Accuracy benchmark
    benchmark_accuracy(pdfs)

    # Summary
    print()
    print("=" * 40)
    print(f"Summary ({total} PDFs)")
    print("=" * 40)
    print()

    zpdf_rate = total / zpdf_time
    mutool_rate = total / mutool_time
    speedup = mutool_time / zpdf_time

    print("| Tool | Time | PDFs/sec | Speedup |")
    print("|------|------|----------|---------|")
    print(f"| zpdf | {zpdf_time:.1f}s | {zpdf_rate:.0f} | {speedup:.1f}x |")
    print(f"| MuPDF | {mutool_time:.1f}s | {mutool_rate:.0f} | 1x |")

if __name__ == "__main__":
    main()

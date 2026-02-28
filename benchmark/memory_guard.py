#!/usr/bin/env python3
"""
Memory regression guard for repeated full-document extraction.

The guard focuses on detecting accuracy-mode regressions relative to fast mode.
It runs both modes in the same process, tracks RSS growth, and fails if
accuracy tail growth is significantly worse than fast tail growth.
"""

import argparse
import gc
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.absolute()
sys.path.insert(0, str(SCRIPT_DIR / "../python"))

try:
    import psutil
except ImportError:
    print("psutil is required. Install with: pip install psutil")
    sys.exit(2)

try:
    import zpdf
except ImportError:
    print("zpdf Python bindings not available. Build with: zig build")
    sys.exit(2)


def rss_mb(proc: "psutil.Process") -> float:
    return proc.memory_info().rss / (1024 * 1024)


def run_mode(pdf_path: Path, mode: str, iterations: int) -> list[float]:
    proc = psutil.Process()
    samples: list[float] = []
    with zpdf.Document(pdf_path) as doc:
        for _ in range(iterations):
            text = doc.extract_all(mode=mode)
            del text
            gc.collect()
            samples.append(rss_mb(proc))
    return samples


def tail_growth(samples: list[float], warmup: int) -> float:
    warmup_idx = max(0, warmup - 1)
    return samples[-1] - samples[warmup_idx]


def main() -> int:
    parser = argparse.ArgumentParser(description="zpdf memory regression guard")
    parser.add_argument(
        "--pdf",
        type=Path,
        default=SCRIPT_DIR / "docs" / "pdf_reference.pdf",
        help="Path to PDF for the guard run",
    )
    parser.add_argument("--iterations", type=int, default=20, help="Iterations per mode")
    parser.add_argument("--warmup", type=int, default=8, help="Warmup iterations ignored in tail-growth check")
    parser.add_argument(
        "--accuracy-tail-cap-mb",
        type=float,
        default=80.0,
        help="Absolute cap for accuracy tail RSS growth",
    )
    parser.add_argument(
        "--accuracy-extra-over-fast-mb",
        type=float,
        default=20.0,
        help="Allowed extra tail growth for accuracy over fast mode",
    )
    args = parser.parse_args()

    if args.iterations <= 0:
        print("iterations must be > 0")
        return 2
    if args.warmup <= 0 or args.warmup > args.iterations:
        print("warmup must be in range [1, iterations]")
        return 2
    if not args.pdf.exists():
        print(f"PDF not found: {args.pdf}")
        return 2

    print(f"Memory guard PDF: {args.pdf}")
    print(f"Iterations: {args.iterations}, warmup: {args.warmup}")

    accuracy_samples = run_mode(args.pdf, "accuracy", args.iterations)
    fast_samples = run_mode(args.pdf, "fast", args.iterations)

    accuracy_tail = tail_growth(accuracy_samples, args.warmup)
    fast_tail = tail_growth(fast_samples, args.warmup)

    print()
    print("Mode      startMB    endMB    tail_growthMB")
    print("-------------------------------------------")
    print(f"accuracy  {accuracy_samples[0]:7.1f}  {accuracy_samples[-1]:7.1f}  {accuracy_tail:13.1f}")
    print(f"fast      {fast_samples[0]:7.1f}  {fast_samples[-1]:7.1f}  {fast_tail:13.1f}")

    if accuracy_tail > args.accuracy_tail_cap_mb:
        print(
            f"\nFAIL: accuracy tail growth {accuracy_tail:.1f}MB exceeds cap "
            f"{args.accuracy_tail_cap_mb:.1f}MB"
        )
        return 1

    if accuracy_tail > fast_tail + args.accuracy_extra_over_fast_mb:
        print(
            f"\nFAIL: accuracy tail growth {accuracy_tail:.1f}MB exceeds fast "
            f"tail growth {fast_tail:.1f}MB by more than "
            f"{args.accuracy_extra_over_fast_mb:.1f}MB"
        )
        return 1

    print("\nPASS: no accuracy-specific memory regression detected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

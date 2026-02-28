import gc
import os
from pathlib import Path

import pytest
import zpdf

try:
    import psutil
except ImportError:  # pragma: no cover - dependency is optional
    psutil = None


TEST_DIR = Path(__file__).parent.parent.parent
LARGE_PDF = TEST_DIR / "benchmark" / "docs" / "pdf_reference.pdf"
RUN_MEMORY_GUARDS = os.getenv("ZPDF_RUN_MEMORY_GUARDS") == "1"


def _rss_mb(proc: "psutil.Process") -> float:
    return proc.memory_info().rss / (1024 * 1024)


def _run_extract_all_mode(pdf: Path, mode: str, iterations: int) -> list[float]:
    proc = psutil.Process()
    samples: list[float] = []
    with zpdf.Document(pdf) as doc:
        for _ in range(iterations):
            text = doc.extract_all(mode=mode)
            del text
            gc.collect()
            samples.append(_rss_mb(proc))
    return samples


@pytest.mark.skipif(not RUN_MEMORY_GUARDS, reason="Set ZPDF_RUN_MEMORY_GUARDS=1 to run memory guard tests")
@pytest.mark.skipif(psutil is None, reason="psutil not installed")
@pytest.mark.skipif(not LARGE_PDF.exists(), reason="benchmark/docs/pdf_reference.pdf not available")
def test_extract_all_accuracy_memory_guard():
    """Guard against accuracy-mode memory regressions on repeated full extraction."""
    iterations = int(os.getenv("ZPDF_MEMORY_GUARD_ITERS", "20"))
    warmup = int(os.getenv("ZPDF_MEMORY_GUARD_WARMUP", "8"))
    accuracy_tail_cap_mb = float(os.getenv("ZPDF_MEMORY_ACCURACY_TAIL_CAP_MB", "80"))
    accuracy_extra_over_fast_mb = float(os.getenv("ZPDF_MEMORY_ACCURACY_EXTRA_MB", "20"))

    assert iterations > 0
    assert 1 <= warmup <= iterations

    accuracy = _run_extract_all_mode(LARGE_PDF, "accuracy", iterations)
    fast = _run_extract_all_mode(LARGE_PDF, "fast", iterations)

    warmup_idx = warmup - 1
    accuracy_tail = accuracy[-1] - accuracy[warmup_idx]
    fast_tail = fast[-1] - fast[warmup_idx]

    assert accuracy_tail <= accuracy_tail_cap_mb, (
        f"accuracy tail growth too high: {accuracy_tail:.1f}MB "
        f"(cap {accuracy_tail_cap_mb:.1f}MB)"
    )
    assert accuracy_tail <= fast_tail + accuracy_extra_over_fast_mb, (
        f"accuracy tail growth {accuracy_tail:.1f}MB exceeds fast tail growth "
        f"{fast_tail:.1f}MB by more than {accuracy_extra_over_fast_mb:.1f}MB"
    )

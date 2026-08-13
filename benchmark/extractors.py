"""Shared text-extractor adapters for corpus benchmarks."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "python"))


@dataclass
class Extraction:
    text: str
    elapsed_ms: float
    error: str | None = None


def available_tools() -> dict[str, bool]:
    tools = {
        "zpdf-accuracy": True,
        "zpdf-fast": True,
        "mutool": shutil.which("mutool") is not None,
        "pdftotext": shutil.which("pdftotext") is not None,
        "pdfium": True,
        "tika": shutil.which("tika") is not None,
    }
    try:
        import zpdf  # noqa: F401
    except (ImportError, OSError):
        tools["zpdf-accuracy"] = tools["zpdf-fast"] = False
    try:
        import pypdfium2  # noqa: F401
    except ImportError:
        tools["pdfium"] = False
    return tools


def extract(tool: str, pdf: Path, timeout: float = 30.0) -> Extraction:
    start = time.perf_counter()
    try:
        if tool.startswith("zpdf-"):
            import zpdf

            mode = tool.removeprefix("zpdf-")
            with zpdf.Document(str(pdf)) as document:
                text = document.extract_all(mode=mode)
        elif tool == "pdfium":
            import pypdfium2 as pdfium

            document = pdfium.PdfDocument(str(pdf))
            try:
                pages = []
                for page in document:
                    text_page = page.get_textpage()
                    try:
                        pages.append(text_page.get_text_bounded())
                    finally:
                        text_page.close()
                        page.close()
                text = "\f".join(pages)
            finally:
                document.close()
        else:
            commands = {
                "mutool": ["mutool", "convert", "-F", "text", "-o", "-", str(pdf)],
                "pdftotext": ["pdftotext", str(pdf), "-"],
                "tika": ["tika", "--text", str(pdf)],
            }
            result = subprocess.run(
                commands[tool], capture_output=True, timeout=timeout, check=False
            )
            text = result.stdout.decode("utf-8", errors="replace")
            if result.returncode:
                stderr = result.stderr.decode("utf-8", errors="replace").strip()
                raise RuntimeError(stderr or f"exit status {result.returncode}")
        elapsed = (time.perf_counter() - start) * 1000
        return Extraction(text=text, elapsed_ms=elapsed)
    except Exception as exc:  # Corpus files are intentionally adversarial.
        elapsed = (time.perf_counter() - start) * 1000
        return Extraction(text="", elapsed_ms=elapsed, error=f"{type(exc).__name__}: {exc}")


def extract_isolated(tool: str, pdf: Path, timeout: float = 30.0) -> Extraction:
    """Extract in a child process so crashes and hangs become per-file failures."""
    with tempfile.TemporaryDirectory(prefix="zpdf-bench-") as directory:
        temporary = Path(directory)
        text_path = temporary / "output.txt"
        metadata_path = temporary / "metadata.json"
        try:
            child = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "--worker",
                    tool,
                    str(pdf),
                    str(text_path),
                    str(metadata_path),
                    str(timeout),
                ],
                capture_output=True,
                timeout=timeout + 5,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return Extraction(text="", elapsed_ms=timeout * 1000, error=f"Timeout after {timeout}s")

        if metadata_path.exists():
            import json

            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            text = text_path.read_text(encoding="utf-8", errors="replace") if text_path.exists() else ""
            return Extraction(text=text, elapsed_ms=metadata["elapsed_ms"], error=metadata["error"])
        stderr = child.stderr.decode("utf-8", errors="replace").strip()
        detail = stderr.splitlines()[-1] if stderr else f"exit status {child.returncode}"
        return Extraction(text="", elapsed_ms=0, error=f"Worker failed: {detail}")


def _worker(arguments: list[str]) -> int:
    import json

    tool, pdf, text_path, metadata_path, timeout = arguments
    result = extract(tool, Path(pdf), float(timeout))
    Path(text_path).write_text(result.text, encoding="utf-8")
    Path(metadata_path).write_text(
        json.dumps({"elapsed_ms": result.elapsed_ms, "error": result.error}), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 7 and sys.argv[1] == "--worker":
        raise SystemExit(_worker(sys.argv[2:]))
    raise SystemExit("extractors.py is an internal benchmark helper")

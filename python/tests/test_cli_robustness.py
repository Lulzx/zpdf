from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
CLI = REPO_ROOT / "zig-out" / "bin" / "zpdf"
TEST_PDF = REPO_ROOT / "test" / "test.pdf"


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(CLI), *args],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )


@pytest.mark.parametrize("page_range", ["nope", "2,nope", "0", "999999", "1,", "1-2-3"])
def test_invalid_page_ranges_fail_without_allocator_diagnostics(page_range):
    result = _run("extract", "-p", page_range, str(TEST_PDF))
    assert result.returncode != 0
    assert "panic" not in result.stderr.lower()
    assert "leaked" not in result.stderr.lower()
    assert "invalid free" not in result.stderr.lower()


def test_cli_failures_are_nonzero():
    assert _run("info", "/definitely/missing.pdf").returncode != 0
    assert _run("unknown-command").returncode != 0
    assert _run("extract", "--unknown", str(TEST_PDF)).returncode != 0
    assert _run("extract", "--format", "unknown", str(TEST_PDF)).returncode != 0
    assert _run("extract", "--format").returncode != 0
    assert _run("extract", "-p").returncode != 0


def test_json_output_is_valid():
    result = _run("extract", "--json", str(TEST_PDF))
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["page_count"] == 1


@pytest.mark.parametrize("length", [1, 4, 8, 16, 32, 64, 128, 256])
def test_truncated_pdfs_never_crash_or_emit_invalid_success_json(tmp_path, length):
    malformed = tmp_path / f"truncated-{length}.pdf"
    malformed.write_bytes(TEST_PDF.read_bytes()[:length])
    result = _run("extract", "--json", str(malformed))
    assert result.returncode >= 0  # A signal/abort is represented as a negative code.
    assert "panic" not in result.stderr.lower()
    if result.returncode == 0:
        json.loads(result.stdout)

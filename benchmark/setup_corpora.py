#!/usr/bin/env python3
"""Download the pinned PDF corpora used by zpdf benchmarks."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ROOT = SCRIPT_DIR / "corpora"
MANIFEST = json.loads((SCRIPT_DIR / "corpus_manifest.json").read_text())


def run(command: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True, env=env)


def require(command: str) -> None:
    if shutil.which(command) is None:
        raise SystemExit(f"Required command not found: {command}")


def clone_pinned(
    name: str,
    destination: Path,
    sparse_paths: list[str] | None = None,
    partial: bool = True,
    skip_lfs_smudge: bool = False,
) -> None:
    spec = MANIFEST[name]
    if destination.exists():
        if not (destination / ".git").exists():
            raise SystemExit(f"Refusing to replace non-git path: {destination}")
        run(["git", "fetch", "--depth", "1", "origin", spec["revision"]], destination)
    else:
        command = ["git", "clone"]
        if partial:
            command.append("--filter=blob:none")
        command.extend(["--no-checkout", spec["url"], str(destination)])
        environment = None
        if skip_lfs_smudge:
            environment = os.environ.copy()
            environment["GIT_LFS_SKIP_SMUDGE"] = "1"
        run(command, env=environment)

    if sparse_paths:
        run(["git", "sparse-checkout", "init", "--cone"], destination)
        run(["git", "sparse-checkout", "set", *sparse_paths], destination)
    environment = None
    if skip_lfs_smudge:
        environment = os.environ.copy()
        environment["GIT_LFS_SKIP_SMUDGE"] = "1"
    run(["git", "checkout", "--detach", spec["revision"]], destination, environment)


def setup_olmocr(root: Path) -> None:
    if shutil.which("git-lfs") is None:
        try:
            run(["git", "lfs", "version"])
        except subprocess.CalledProcessError:
            raise SystemExit("Git LFS is required for olmOCR-Bench") from None
    destination = root / "olmocr-bench"
    clone_pinned("olmocr_bench", destination, partial=False, skip_lfs_smudge=True)
    run(["git", "lfs", "pull"], destination)

    code = root / "olmocr-code"
    # The score-only entry point imports its optional HTML report renderer,
    # which imports olmocr.data at module load time.
    clone_pinned("olmocr_code", code, ["olmocr/bench", "olmocr/data"])


def setup_verapdf(root: Path) -> None:
    clone_pinned("verapdf", root / "verapdf")


def setup_pdfjs(root: Path) -> None:
    clone_pinned("pdfjs", root / "pdfjs", ["test/pdfs"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpora", nargs="*", choices=("olmocr", "verapdf", "pdfjs"))
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    args = parser.parse_args()

    require("git")
    args.root.mkdir(parents=True, exist_ok=True)
    selected = args.corpora or ["olmocr", "verapdf", "pdfjs"]
    actions = {"olmocr": setup_olmocr, "verapdf": setup_verapdf, "pdfjs": setup_pdfjs}
    for corpus in selected:
        print(f"\nSetting up {corpus}")
        actions[corpus](args.root)

    print(f"\nCorpora are ready in {args.root}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(exc.returncode)

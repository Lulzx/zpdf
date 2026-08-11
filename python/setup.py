"""Platform-wheel support for the Zig shared library."""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from setuptools import Distribution, setup
from setuptools.command.build_py import build_py
from wheel.bdist_wheel import bdist_wheel


def _library_name() -> str:
    if sys.platform == "darwin":
        return "libzpdf.dylib"
    if sys.platform == "win32":
        return "zpdf.dll"
    return "libzpdf.so"


class BinaryDistribution(Distribution):
    """Ensure wheels containing the shared library get a platform tag."""

    def has_ext_modules(self) -> bool:
        return True


class BuildPyWithZig(build_py):
    def run(self) -> None:
        package_root = Path(__file__).resolve().parent
        repo_root = package_root.parent
        library_name = _library_name()
        configured = os.environ.get("ZPDF_LIB")
        if configured:
            source = Path(configured).resolve()
        else:
            if (repo_root / "build.zig").is_file():
                source = repo_root / "zig-out" / "lib" / library_name
                # Always invoke Zig: its cache makes no-op builds cheap and this
                # prevents a wheel from silently packaging stale zig-out output.
                subprocess.run(
                    ["zig", "build", "-Doptimize=ReleaseFast"],
                    cwd=repo_root,
                    check=True,
                )
            else:
                raise RuntimeError(
                    "zpdf source distribution cannot build the native library: "
                    "set ZPDF_LIB to a compatible prebuilt library"
                )

        if not source.is_file():
            if configured:
                raise RuntimeError(f"ZPDF_LIB does not name a file: {source}")
            raise RuntimeError(f"native zpdf library was not produced at {source}")

        super().run()
        destination = Path(self.build_lib) / "zpdf" / library_name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


class PlatformWheel(bdist_wheel):
    """The CFFI ABI wrapper is Python-independent but the library is platform-specific."""

    def finalize_options(self) -> None:
        super().finalize_options()
        self.root_is_pure = False

    def get_tag(self):
        _, _, platform_tag = super().get_tag()
        if sys.platform == "darwin" and platform_tag.endswith("_universal2"):
            platform_tag = platform_tag[: -len("_universal2")] + f"_{platform.machine()}"
        return "py3", "none", platform_tag


setup(
    distclass=BinaryDistribution,
    cmdclass={"build_py": BuildPyWithZig, "bdist_wheel": PlatformWheel},
)

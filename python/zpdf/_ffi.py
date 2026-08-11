import os
import sys
from pathlib import Path
from cffi import FFI

ffi = FFI()

_cdef_path = Path(__file__).parent / "_cdef.h"
with open(_cdef_path) as f:
    ffi.cdef(f.read())

def _find_library():
    candidates = []

    if "ZPDF_LIB" in os.environ:
        configured = Path(os.environ["ZPDF_LIB"])
        if not configured.is_file():
            raise ImportError(f"ZPDF_LIB does not name a file: {configured}")
        return str(configured)

    pkg_dir = Path(__file__).parent
    repo_root = pkg_dir.parent.parent
    lib_dir = repo_root / "zig-out" / "lib"
    if sys.platform == "darwin":
        candidates.append(lib_dir / "libzpdf.dylib")
    elif sys.platform == "win32":
        candidates.append(lib_dir / "zpdf.dll")
    else:
        candidates.append(lib_dir / "libzpdf.so")

    # Installed wheels carry the native library beside this module. Keep this
    # after zig-out so repository checkouts always test the current build.
    if sys.platform == "darwin":
        candidates.append(pkg_dir / "libzpdf.dylib")
    elif sys.platform == "win32":
        candidates.append(pkg_dir / "zpdf.dll")
    else:
        candidates.append(pkg_dir / "libzpdf.so")

    for path in candidates:
        if path.exists():
            return str(path)

    raise ImportError(f"Could not find zpdf library. Searched: {candidates}")

lib = ffi.dlopen(_find_library())

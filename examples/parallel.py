#!/usr/bin/env python3
"""Compare accuracy vs fast extraction speed."""
import sys
import time
sys.path.insert(0, "python")

import zpdf

pdf_path = sys.argv[1] if len(sys.argv) > 1 else "test.pdf"

with zpdf.Document(pdf_path) as doc:
    print(f"Document: {pdf_path} ({doc.page_count} pages)")

    start = time.time()
    text = doc.extract_all(mode="accuracy")
    accuracy_time = time.time() - start

    start = time.time()
    text = doc.extract_all(mode="fast")
    fast_time = time.time() - start

    print(f"Accuracy: {accuracy_time*1000:.1f}ms")
    print(f"Fast:     {fast_time*1000:.1f}ms")
    if fast_time > 0:
        print(f"Speedup:  {accuracy_time/fast_time:.1f}x")

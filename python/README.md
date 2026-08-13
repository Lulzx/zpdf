# zpdf

PDF text extraction powered by Zig.

## Install

```bash
pip install zpdf
```

To build a wheel from a source checkout, run `zig build -Doptimize=ReleaseFast`
at the repository root, then `python -m build --wheel python`. Set `ZPDF_LIB`
to select an explicit compatible shared library for testing or packaging.

## Usage

```python
from zpdf import Document

with Document("paper.pdf") as doc:
    print(doc.page_count)

    # Extract all text (structure-tree order when available, otherwise stream order)
    text = doc.extract_all()

    # Extract single page
    page_text = doc.extract_page(0)

    # Extract as markdown
    md = doc.extract_all_markdown()

    # Get text spans with estimated bounds
    spans = doc.extract_bounds(0)
    for span in spans:
        print(f"{span.text} at ({span.x0}, {span.y0})")
```

### From bytes

```python
with open("doc.pdf", "rb") as f:
    data = f.read()

with Document(data) as doc:
    text = doc.extract_all()
```

The returned bounds use PDF text positions and an estimated text width; they
are not exact glyph or word bounds.

## Benchmarking

See the repository's [`benchmark/README.md`](../benchmark/README.md) for local
performance and accuracy tools. Published comparisons should include the zpdf
revision, dependency versions, hardware, input checksums, and run policy.

## License

CC0-1.0

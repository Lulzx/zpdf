# zpdf

High-performance PDF text extraction powered by Zig. ~4x faster than MuPDF on large documents.

## Install

```bash
pip install zpdf
```

## Usage

```python
from zpdf import Document

with Document("paper.pdf") as doc:
    print(doc.page_count)

    # Extract all text (reading order)
    text = doc.extract_all()

    # Extract single page
    page_text = doc.extract_page(0)

    # Extract as markdown
    md = doc.extract_all_markdown()

    # Get text with bounding boxes
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

## Benchmark

Text extraction on Apple M4 Pro:

| Document | Pages | zpdf | MuPDF | Speedup |
|----------|------:|-----:|------:|--------:|
| Intel SDM | 5,252 | 582ms | 2,152ms | 3.7x |
| Pandas Docs | 3,743 | 640ms | 1,130ms | 1.8x |
| C++ Standard | 2,134 | 438ms | 1,007ms | 2.3x |
| PDF Reference | 1,310 | 236ms | 1,481ms | 6.3x |

## License

CC0-1.0

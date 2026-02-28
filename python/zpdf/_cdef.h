typedef struct ZpdfDocument ZpdfDocument;

ZpdfDocument* zpdf_open(const char* path);
ZpdfDocument* zpdf_open_memory(const uint8_t* data, size_t len);
ZpdfDocument* zpdf_open_memory_unsafe(const uint8_t* data, size_t len);
void zpdf_close(ZpdfDocument* doc);
int zpdf_page_count(ZpdfDocument* doc);
bool zpdf_is_encrypted(ZpdfDocument* doc);
uint8_t* zpdf_extract_page(ZpdfDocument* doc, int page_num, size_t* out_len);
uint8_t* zpdf_extract_all(ZpdfDocument* doc, size_t* out_len);
uint8_t* zpdf_extract_all_fast(ZpdfDocument* doc, size_t* out_len);
uint8_t* zpdf_extract_all_parallel(ZpdfDocument* doc, size_t* out_len);
void zpdf_free_buffer(uint8_t* ptr, size_t len);
int zpdf_get_page_info(ZpdfDocument* doc, int page_num, double* width, double* height, int* rotation);

typedef struct {
    double x0;
    double y0;
    double x1;
    double y1;
    const char* text;
    size_t text_len;
    double font_size;
} CTextSpan;

CTextSpan* zpdf_extract_bounds(ZpdfDocument* doc, int page_num, size_t* out_count);
void zpdf_free_bounds(CTextSpan* ptr, size_t count);

// Reading order extraction (visual order, not stream order)
uint8_t* zpdf_extract_page_reading_order(ZpdfDocument* doc, int page_num, size_t* out_len);
uint8_t* zpdf_extract_all_reading_order(ZpdfDocument* doc, size_t* out_len);
uint8_t* zpdf_extract_all_reading_order_parallel(ZpdfDocument* doc, size_t* out_len);

// Markdown extraction
uint8_t* zpdf_extract_page_markdown(ZpdfDocument* doc, int page_num, size_t* out_len);
uint8_t* zpdf_extract_all_markdown(ZpdfDocument* doc, size_t* out_len);

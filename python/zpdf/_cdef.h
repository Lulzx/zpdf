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

// Metadata
typedef struct {
    const char* title; size_t title_len;
    const char* author; size_t author_len;
    const char* subject; size_t subject_len;
    const char* keywords; size_t keywords_len;
    const char* creator; size_t creator_len;
    const char* producer; size_t producer_len;
    const char* creation_date; size_t creation_date_len;
    const char* mod_date; size_t mod_date_len;
} CMetadata;

int zpdf_get_metadata(ZpdfDocument* doc, CMetadata* out);

// Outline
typedef struct {
    const char* title; size_t title_len;
    int page;
    int level;
} COutlineItem;

int zpdf_get_outline(ZpdfDocument* doc, COutlineItem** out, size_t* count);
void zpdf_free_outline(COutlineItem* items, size_t count);

// Search
typedef struct {
    int page;
    size_t offset;
    const char* context; size_t context_len;
} CSearchResult;

int zpdf_search(ZpdfDocument* doc, const char* query, size_t query_len,
                CSearchResult** out, size_t* count);
void zpdf_free_search_results(CSearchResult* results, size_t count);

// Page labels
uint8_t* zpdf_get_page_label(ZpdfDocument* doc, int page_num, size_t* out_len);

// Links
typedef struct {
    double x0;
    double y0;
    double x1;
    double y1;
    const char* uri; size_t uri_len;
    int dest_page;
} CLink;

int zpdf_get_page_links(ZpdfDocument* doc, int page_num, CLink** out, size_t* count);
void zpdf_free_links(CLink* links, size_t count);

// Images
typedef struct {
    double x0;
    double y0;
    double x1;
    double y1;
    uint32_t width;
    uint32_t height;
} CImageInfo;

int zpdf_get_page_images(ZpdfDocument* doc, int page_num, CImageInfo** out, size_t* count);
void zpdf_free_images(CImageInfo* images, size_t count);

// Form fields
typedef struct {
    const char* name; size_t name_len;
    const char* value; size_t value_len;
    int field_type;
    bool has_rect;
    double x0;
    double y0;
    double x1;
    double y1;
} CFormField;

int zpdf_get_form_fields(ZpdfDocument* doc, CFormField** out, size_t* count);
void zpdf_free_form_fields(CFormField* fields, size_t count);

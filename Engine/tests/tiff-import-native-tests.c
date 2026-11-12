/* Independent TIFF fixtures and public-facade import checks. libtiff writes
 * the source fixtures; only the adapter opens them as editable images. */
#include "glims_engine.h"
#include <tiffio.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int checks, failures;
#define CHECK(c, ...) do { checks++; if (c) printf("ok   "); else { failures++; printf("FAIL "); } \
    printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

typedef struct { uint32_t width, height, flags; const char *name; unsigned char color[3]; } Page;

static int write_fixture(const char *path, const char *mode, const Page *pages, int count)
{
    TIFF *tif = TIFFOpen(path, mode);
    if (!tif) return 0;
    int ok = 1;
    for (int i = 0; i < count && ok; i++) {
        const Page *p = &pages[i];
        ok = TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, p->width) &&
             TIFFSetField(tif, TIFFTAG_IMAGELENGTH, p->height) &&
             TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, 8) &&
             TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, 3) &&
             TIFFSetField(tif, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG) &&
             TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB) &&
             TIFFSetField(tif, TIFFTAG_COMPRESSION, COMPRESSION_NONE) &&
             TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP, p->height) &&
             TIFFSetField(tif, TIFFTAG_SUBFILETYPE, p->flags) &&
             TIFFSetField(tif, TIFFTAG_PAGENAME, p->name);
        unsigned char *row = malloc(p->width * 3);
        if (!row) { ok = 0; break; }
        for (uint32_t x = 0; x < p->width; x++) memcpy(row + x * 3, p->color, 3);
        for (uint32_t y = 0; y < p->height && ok; y++)
            ok = TIFFWriteScanline(tif, row, y, 0) >= 0;
        free(row);
        if (ok) ok = TIFFWriteDirectory(tif);
    }
    TIFFClose(tif);
    return ok;
}

static unsigned char *read_file(const char *path, size_t *length)
{
    *length = 0;
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END)) { fclose(f); return NULL; }
    long end = ftell(f);
    if (end <= 0 || end > 1024 * 1024 || fseek(f, 0, SEEK_SET)) { fclose(f); return NULL; }
    unsigned char *bytes = malloc((size_t)end);
    if (!bytes || fread(bytes, 1, (size_t)end, f) != (size_t)end) {
        free(bytes); fclose(f); return NULL;
    }
    fclose(f); *length = (size_t)end; return bytes;
}

static void check_layers(GlimsImageID image, const Page *expected, int count, const char *label)
{
    GlimsLayerInfo rows[8]; int32_t n = 0;
    CHECK(api->image_layers(engine, image, rows, 8, &n) == GLIMS_STATUS_OK && n == count,
          "%s retains exactly %d ordinary layers (got %d)", label, count, n);
    for (int i = 0; i < count; i++) {
        const Page *p = &expected[i];
        GlimsLayerInfo *row = NULL;
        for (int k = 0; k < n && k < 8; k++) if (!strcmp(rows[k].name, p->name)) row = &rows[k];
        CHECK(row && row->bounds.width == (int32_t)p->width && row->bounds.height == (int32_t)p->height,
              "%s keeps %s and its original dimensions", label, p->name);
        if (!row) continue;
        GlimsPixelBuffer pixels = {0}; int exact = 0;
        if (api->layer_select(engine, image, row->id) == GLIMS_STATUS_OK &&
            api->image_copy_pixels(engine, image, false, &pixels, NULL) == GLIMS_STATUS_OK &&
            pixels.byte_count == (size_t)p->width * p->height * 4) {
            exact = 1;
            const unsigned char *b = pixels.pixels;
            for (size_t j = 0; j < pixels.byte_count; j += 4)
                if (memcmp(b + j, p->color, 3) || b[j + 3] != 255) { exact = 0; break; }
        }
        CHECK(exact, "%s preserves every literal pixel of %s", label, p->name);
        api->free_pixels(pixels.pixels);
    }
}

static void exercise(const char *work, const char *label, const char *mode,
                     const Page *source, int source_count, const Page *expected, int count)
{
    char path[4096]; snprintf(path, sizeof path, "%s/%s.tif", work, label);
    CHECK(write_fixture(path, mode, source, source_count), "%s independent TIFF fixture writes", label);
    size_t before_length = 0; unsigned char *before = read_file(path, &before_length);
    CHECK(before != NULL, "%s source bytes are captured", label);
    GlimsImageID image = 0; char *error = NULL;
    GlimsStatus status = api->image_open(engine, path, &image, &error);
    CHECK(status == GLIMS_STATUS_OK && image > 0, "%s opens through the native loader: %s", label, error ? error : "ok");
    api->free_string(error);
    if (status == GLIMS_STATUS_OK && image) {
        GlimsImageInfo info = {0}; uint32_t w = 0, h = 0;
        for (int i = 0; i < count; i++) { if (expected[i].width > w) w = expected[i].width; if (expected[i].height > h) h = expected[i].height; }
        CHECK(api->image_info(engine, image, &info) == GLIMS_STATUS_OK && info.width == (int32_t)w && info.height == (int32_t)h,
              "%s canvas uses ordinary pages only: %dx%d", label, info.width, info.height);
        check_layers(image, expected, count, label);
        GlimsUndoInfo undo = {0};
        CHECK(api->image_undo_info(engine, image, &undo) == GLIMS_STATUS_OK && undo.undo_count == 0,
              "%s import adds no editing Undo step", label);
        api->image_close(engine, image);
    }
    /* Open as Layers must use the same source policy, as one insertion. */
    GlimsImageID destination = 0;
    if (api->image_new(engine, 64, 64, &destination, NULL) == GLIMS_STATUS_OK) {
        GlimsUndoInfo undo = {0}, after = {0};
        api->image_undo_info(engine, destination, &undo);
        GlimsItemID ids[8]; int32_t inserted = 0;
        status = api->image_open_layers(engine, destination, path, ids, 8, &inserted, NULL);
        CHECK(status == GLIMS_STATUS_OK && inserted == count,
              "%s Open as Layers inserts %d ordinary pages (got %d)", label, count, inserted);
        CHECK(api->image_undo_info(engine, destination, &after) == GLIMS_STATUS_OK && after.undo_count == undo.undo_count + 1,
              "%s layer import is one Undo", label);
        GlimsImageInfo info = {0};
        CHECK(api->image_undo(engine, destination) == GLIMS_STATUS_OK &&
              api->image_info(engine, destination, &info) == GLIMS_STATUS_OK && info.layer_count == 1,
              "%s Undo removes the whole inserted stack", label);
        api->image_close(engine, destination);
    } else CHECK(0, "%s destination image creates", label);
    size_t after_length = 0; unsigned char *after = read_file(path, &after_length);
    CHECK(before && after && before_length == after_length && !memcmp(before, after, before_length),
          "%s opening and importing never modify the original file", label);
    free(before); free(after);
}

int main(int argc, char **argv)
{
    if (argc != 3) { fprintf(stderr, "usage: %s ADAPTER WORK_DIR\n", argv[0]); return 2; }
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    GlimsEngineGetAPIFunction get_api = (GlimsEngineGetAPIFunction)dlsym(library, "glims_engine_get_api");
    api = get_api ? get_api(GLIMS_ENGINE_API_VERSION) : NULL;
    if (!api) return 2;
    GlimsEngineConfig config = {0}; config.struct_size = sizeof config;
    config.user_directory = argv[2]; config.cache_directory = argv[2];
    char *error = NULL;
    if (api->start(&config, &engine, &error) != GLIMS_STATUS_OK) {
        fprintf(stderr, "engine start: %s\n", error ? error : "failed"); return 2;
    }
    const Page main = {64, 64, 0, "Main", {23, 145, 219}};
    const Page thumb = {256, 256, FILETYPE_REDUCEDIMAGE, "Thumbnail", {233, 77, 41}};
    const Page small = {17, 13, FILETYPE_PAGE, "Small page", {18, 198, 33}};
    const Page combined = {21, 19, FILETYPE_PAGE | FILETYPE_REDUCEDIMAGE, "Page with reduced flag", {155, 22, 201}};
    const Page reduced_pair[] = {main, thumb}, ordinary[] = {main, small};
    const Page mixed[] = {main, thumb, small}, first[] = {thumb, main}, flags[] = {main, combined};
    exercise(argv[2], "thumbnail-classic-le", "wl", reduced_pair, 2, &main, 1);
    exercise(argv[2], "thumbnail-classic-be", "wb", reduced_pair, 2, &main, 1);
    exercise(argv[2], "thumbnail-bigtiff", "w8", reduced_pair, 2, &main, 1);
    exercise(argv[2], "ordinary-pages", "w", ordinary, 2, ordinary, 2);
    exercise(argv[2], "mixed-pages", "w", mixed, 3, ordinary, 2);
    exercise(argv[2], "first-thumbnail", "w", first, 2, &main, 1);
    exercise(argv[2], "combined-flags", "w", flags, 2, flags, 2);
    exercise(argv[2], "all-reduced", "w", &thumb, 1, &thumb, 1);
    api->stop(engine);
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}

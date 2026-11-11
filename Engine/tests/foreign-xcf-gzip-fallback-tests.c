/* Standalone public-facade oracle. Usage: LIBRARY PRIVATE_WORK_DIR.
 * No adapter or Core object is rebuilt or replaced by this fixture. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <zlib.h>

/* PNG chunks and gzip members generated independently with Python's struct,
 * zlib and gzip modules from these literal, opaque 3x2 RGBA scanlines. */
static const uint8_t rgba[] = {
  12, 31, 80, 255, 206, 21, 64, 255, 46, 188, 49, 255,
  237, 104, 22, 255, 51, 106, 217, 255, 154, 5, 184, 255,
};
static const uint8_t png[] = {
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x9d, 0x74, 0x66, 0x1a, 0x00, 0x00, 0x00,
  0x23, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xe0, 0x91, 0x0f, 0xf8,
  0x7f, 0x4e, 0xd4, 0xe1, 0xbf, 0xde, 0x1e, 0xc3, 0xff, 0x0c, 0x6f, 0x33,
  0xc4, 0xfe, 0x1b, 0x67, 0xdd, 0xfc, 0x3f, 0x8b, 0x75, 0xc7, 0x7f, 0x00,
  0x96, 0xfb, 0x0c, 0xec, 0x56, 0x09, 0x84, 0x5b, 0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};
static const uint8_t png_gzip[] = {
  0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xeb, 0x0c,
  0xf0, 0x73, 0xe7, 0xe5, 0x92, 0xe2, 0x62, 0x60, 0x60, 0xe0, 0xf5, 0xf4,
  0x70, 0x09, 0x02, 0xd2, 0xcc, 0x40, 0xcc, 0xc4, 0xc1, 0x06, 0x24, 0xe7,
  0x96, 0xa4, 0x49, 0x01, 0x29, 0x65, 0x4f, 0x17, 0xc7, 0x90, 0x8a, 0x39,
  0xc9, 0x0f, 0x26, 0xf2, 0xff, 0xa8, 0xf7, 0xbb, 0xf2, 0x70, 0xff, 0x3d,
  0xb9, 0xc3, 0xff, 0x79, 0xf2, 0x8d, 0x8f, 0xfc, 0x93, 0x4e, 0xbf, 0xfb,
  0xc7, 0xbe, 0xbb, 0xf4, 0x78, 0x3d, 0xc3, 0xb4, 0xdf, 0x3c, 0x6f, 0xc2,
  0x38, 0x5b, 0xa2, 0x81, 0xca, 0x19, 0x3c, 0x5d, 0xfd, 0x5c, 0xd6, 0x39,
  0x25, 0x34, 0x01, 0x00, 0xfa, 0x1d, 0xc5, 0xa8, 0x5c, 0x00, 0x00, 0x00,
};
static const uint8_t empty_gzip[] = {
  0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x03, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

static unsigned checks, failures;
#define CHECK(condition, message) do { \
  ++checks; \
  printf ("%s %s\n", (condition) ? "ok  " : (++failures, "FAIL"), (message)); \
  fflush (stdout); \
} while (0)

static bool
write_bytes (const char *path, const uint8_t *bytes, size_t size)
{
  FILE *out = fopen (path, "wbx");
  if (!out) return false;
  bool written = fwrite (bytes, 1, size, out) == size;
  return fclose (out) == 0 && written;
}

static bool
prefix_empty_member (const char *source, const char *destination)
{
  FILE *in = fopen (source, "rb");
  if (!in) return false;
  FILE *out = fopen (destination, "wbx");
  if (!out) { fclose (in); return false; }
  bool ok = fwrite (empty_gzip, 1, sizeof empty_gzip, out) == sizeof empty_gzip;
  uint8_t bytes[8192];
  size_t count;
  while (ok && (count = fread (bytes, 1, sizeof bytes, in)) != 0)
    ok = fwrite (bytes, 1, count, out) == count;
  ok = ok && !ferror (in);
  fclose (in);
  return fclose (out) == 0 && ok;
}

static bool
gzip_file (const char *source, const char *destination)
{
  FILE *in = fopen (source, "rb");
  if (!in) return false;
  gzFile out = gzopen (destination, "wbx");
  if (!out) { fclose (in); return false; }
  bool ok = true;
  uint8_t bytes[8192];
  size_t count;
  while (ok && (count = fread (bytes, 1, sizeof bytes, in)) != 0)
    ok = gzwrite (out, bytes, (unsigned) count) == (int) count;
  ok = ok && !ferror (in);
  fclose (in);
  return gzclose (out) == Z_OK && ok;
}

static bool
open_pixels (const GlimsEngineAPI *api, GlimsEngine *engine, const char *path, GlimsImageID *image)
{
  char *error = NULL;
  GlimsStatus status = api->image_open (engine, path, image, &error);
  bool opened = status == GLIMS_STATUS_OK && !error && *image > 0;
  if (error) { fprintf (stderr, "OBS open %s: %s\n", path, error); api->free_string (error); }
  if (!opened) return false;
  GlimsPixelBuffer pixels = {0};
  error = NULL;
  status = api->image_copy_pixels (engine, *image, true, &pixels, &error);
  bool matches = status == GLIMS_STATUS_OK && !error && pixels.pixels &&
      pixels.bounds.x == 0 && pixels.bounds.y == 0 && pixels.bounds.width == 3 && pixels.bounds.height == 2 &&
      pixels.byte_count == sizeof rgba && !memcmp (pixels.pixels, rgba, sizeof rgba);
  if (error) { fprintf (stderr, "OBS copy %s: %s\n", path, error); api->free_string (error); }
  api->free_pixels (pixels.pixels);
  return matches;
}

int
main (int argc, char **argv)
{
  if (argc != 3) return 2;
  enum { USER, CACHE, PLAIN, PNG_GZIP, PNG_PAIR, XCF, XCF_GZIP, XCF_PAIR, PATH_COUNT };
  static const char *const names[] = {
    "user", "cache", "oracle.png", "single.png.gz", "empty-first.png.gz",
    "oracle.xcf", "single.xcf.gz", "empty-first.xcf.gz",
  };
  char path[PATH_COUNT][4096];
  for (unsigned i = 0; i < PATH_COUNT; ++i) {
    int length = snprintf (path[i], sizeof path[i], "%s/%s", argv[2], names[i]);
    if (length < 0 || (size_t) length >= sizeof path[i]) return 2;
  }
  void *library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf (stderr, "dlopen: %s\n", dlerror ()); return 2; }
  GlimsEngineGetAPIFunction get_api = (GlimsEngineGetAPIFunction) dlsym (library, "glims_engine_get_api");
  const GlimsEngineAPI *api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  if (!api || api->struct_size < sizeof *api) return 2;
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = path[USER], .cache_directory = path[CACHE] };
  GlimsEngine *engine = NULL;
  char *error = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "start: %s\n", error ? error : "no detail");
    if (error) api->free_string (error);
    return 2;
  }
  GlimsImageID images[5] = {0};
  bool closed = true;
  bool png_ready = write_bytes (path[PLAIN], png, sizeof png) && write_bytes (path[PNG_GZIP], png_gzip, sizeof png_gzip)
      && prefix_empty_member (path[PNG_GZIP], path[PNG_PAIR]);
  CHECK (png_ready, "write independent PNG, single member and empty-first member fixtures");
  if (!png_ready) goto done;
  bool plain_matches = open_pixels (api, engine, path[PLAIN], &images[0]);
  CHECK (plain_matches, "plain PNG opens with the literal 3x2 RGBA oracle");
  CHECK (open_pixels (api, engine, path[PNG_GZIP], &images[1]), "native gzip PNG fallback matches the plain PNG oracle");
  CHECK (open_pixels (api, engine, path[PNG_PAIR], &images[2]), "empty-first gzip PNG still opens with the exact plain PNG pixels");

  bool xcf_ready = plain_matches && api->image_save_copy (engine, images[0], path[XCF], &error) == GLIMS_STATUS_OK && !error
      && gzip_file (path[XCF], path[XCF_GZIP]) && prefix_empty_member (path[XCF_GZIP], path[XCF_PAIR]);
  CHECK (xcf_ready, "native XCF save and independent gzip writer produce the single and empty-first XCF controls");
  if (error) { fprintf (stderr, "OBS XCF setup: %s\n", error); api->free_string (error); error = NULL; }
  if (!xcf_ready) goto done;
  CHECK (open_pixels (api, engine, path[XCF_GZIP], &images[3]), "single-member gzip XCF contains a valid native image with the exact pixels");
  GlimsStatus rejected = api->image_open (engine, path[XCF_PAIR], &images[4], &error);
  CHECK (rejected != GLIMS_STATUS_OK && images[4] == 0 && error && *error,
         "empty-first gzip XCF refuses multiple members without publishing an image");
  if (error) { fprintf (stderr, "OBS empty-first XCF: %s\n", error); api->free_string (error); }

done:
  for (unsigned i = 0; i < sizeof images / sizeof images[0]; ++i) {
    GlimsImageInfo info = {0};
    if (images[i] && (api->image_close (engine, images[i]) != GLIMS_STATUS_OK ||
                     api->image_info (engine, images[i], &info) != GLIMS_STATUS_NOT_FOUND))
      closed = false;
  }
  CHECK (closed, "all published fixture images close");
  api->stop (engine);
  dlclose (library);
  printf ("%s: %u checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

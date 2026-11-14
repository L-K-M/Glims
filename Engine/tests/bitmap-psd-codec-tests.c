#include "bitmap-psd-codec.h"
#include <stdio.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(condition, label) do { \
  bool passed = (condition); checks++; if (!passed) failures++; \
  printf("%s %s\n", passed ? "ok" : "FAIL", label); \
} while (0)

typedef struct {
  uint32_t width, height;
  unsigned reads, writes;
  bool fail_read, fail_write, invalid_pixel;
  uint8_t bytes[32768];
  size_t length;
} Fixture;

static bool
read_pixels (void *context, uint32_t y, uint32_t x, uint32_t count, uint8_t *samples)
{
  Fixture *f = context;
  f->reads++;
  if (f->fail_read || y >= f->height || x > f->width || count > f->width - x ||
      count > GLIMS_BITMAP_PSD_CHUNK_PIXELS) return false;
  for (uint32_t i = 0; i < count; i++)
    samples[i] = ((x + i + y) % 3u == 0) ? 0 : 255;
  if (f->invalid_pixel && y == f->height - 1 && x + count == f->width)
    samples[count - 1] = 127;
  return true;
}

static bool
write_bytes (void *context, const uint8_t *bytes, size_t length)
{
  Fixture *f = context;
  f->writes++;
  if (f->fail_write || length > sizeof f->bytes - f->length) return false;
  memcpy (f->bytes + f->length, bytes, length);
  f->length += length;
  return true;
}

int
main (void)
{
  GlimsBitmapPsdSpec spec = {9, 2};
  uint64_t size = 99;
  CHECK (glims_bitmap_psd_size (&spec, &size) == GLIMS_BITMAP_PSD_OK && size == 44,
         "odd-width size includes row padding");
  GlimsBitmapPsdSpec invalid[] = {{0,1}, {1,0}, {30001,1}, {1,30001}};
  for (size_t i = 0; i < sizeof invalid / sizeof invalid[0]; i++)
    {
      size = 99;
      CHECK (glims_bitmap_psd_size (&invalid[i], &size) == GLIMS_BITMAP_PSD_INVALID && size == 0,
             "invalid dimensions clear size");
    }
  CHECK (glims_bitmap_psd_size (NULL, &size) == GLIMS_BITMAP_PSD_INVALID && size == 0,
         "null spec is refused");
  CHECK (glims_bitmap_psd_size (&spec, NULL) == GLIMS_BITMAP_PSD_INVALID, "null size is refused");
  spec = (GlimsBitmapPsdSpec) {30000, 30000};
  CHECK (glims_bitmap_psd_size (&spec, &size) == GLIMS_BITMAP_PSD_OK && size == UINT64_C(112500040),
         "maximum PSD dimensions have a bounded size");

  spec = (GlimsBitmapPsdSpec) {9, 2};
  Fixture f = {.width = 9, .height = 2};
  CHECK (glims_bitmap_psd_write (&spec, read_pixels, &f, write_bytes, &f) == GLIMS_BITMAP_PSD_OK,
         "binary image serializes");
  const uint8_t expected[] = {
    '8','B','P','S', 0,1, 0,0,0,0,0,0, 0,1,
    0,0,0,2, 0,0,0,9, 0,1, 0,0,
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,
    0x92,0x00, 0x24,0x80
  };
  CHECK (f.length == sizeof expected && !memcmp (f.bytes, expected, sizeof expected),
         "literal PSD header, black-bit polarity and row padding are exact");

  f = (Fixture) {.width = 8, .height = 2};
  spec = (GlimsBitmapPsdSpec) {8, 2};
  CHECK (glims_bitmap_psd_size (&spec, &size) == GLIMS_BITMAP_PSD_OK && size == 42 &&
         glims_bitmap_psd_write (&spec, read_pixels, &f, write_bytes, &f) == GLIMS_BITMAP_PSD_OK &&
         f.length == 42 && f.bytes[40] == 0x92 && f.bytes[41] == 0x24,
         "one-byte bitmap rows are contiguous without word padding");

  f = (Fixture) {.width = 5001, .height = 2};
  spec = (GlimsBitmapPsdSpec) {5001, 2};
  CHECK (glims_bitmap_psd_write (&spec, read_pixels, &f, write_bytes, &f) == GLIMS_BITMAP_PSD_OK &&
         f.reads == 4 && f.length == 40u + 626u * 2u, "wide rows are streamed in bounded chunks");
  bool pixels_match = true;
  for (uint32_t y = 0; y < spec.height; y++)
    for (uint32_t x = 0; x < spec.width; x++)
      {
        bool bit = (f.bytes[40u + y * 626u + x / 8u] & (0x80u >> (x % 8u))) != 0;
        if (bit != ((x + y) % 3u == 0)) pixels_match = false;
      }
  CHECK (pixels_match && (f.bytes[40u + 625u] & 0x7f) == 0 &&
         (f.bytes[40u + 1251u] & 0x7f) == 0, "chunk boundaries and row padding preserve pixels");

  f = (Fixture) {.width = 9, .height = 2, .invalid_pixel = true}; spec = (GlimsBitmapPsdSpec) {9, 2};
  CHECK (glims_bitmap_psd_write (&spec, read_pixels, &f, write_bytes, &f) == GLIMS_BITMAP_PSD_INVALID_PIXEL &&
         f.reads == 2 && f.writes == 2, "nonbinary pixels refuse before writing their row");
  f = (Fixture) {.width = 9, .height = 2, .fail_read = true};
  CHECK (glims_bitmap_psd_write (&spec, read_pixels, &f, write_bytes, &f) == GLIMS_BITMAP_PSD_READ_FAILED &&
         f.reads == 1 && f.writes == 1, "read failure stops the stream");
  f = (Fixture) {.width = 9, .height = 2, .fail_write = true};
  CHECK (glims_bitmap_psd_write (&spec, read_pixels, &f, write_bytes, &f) == GLIMS_BITMAP_PSD_WRITE_FAILED &&
         f.reads == 0 && f.writes == 1, "header write failure stops before reading pixels");
  f = (Fixture) {.width = 9, .height = 2};
  CHECK (glims_bitmap_psd_write (&spec, NULL, &f, write_bytes, &f) == GLIMS_BITMAP_PSD_INVALID &&
         f.writes == 0, "missing source fails before output");
  CHECK (glims_bitmap_psd_write (&spec, read_pixels, &f, NULL, &f) == GLIMS_BITMAP_PSD_INVALID &&
         f.reads == 0, "missing sink fails before reading");
  printf ("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}

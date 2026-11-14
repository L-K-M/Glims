#include "bitmap-psd-codec.h"

/* PSD v1 header followed by empty color-mode, resource and layer sections,
 * then raw compression. Width and height are filled after validation. */
static void
write_be32 (uint8_t *bytes, uint32_t value)
{
  bytes[0] = (uint8_t) (value >> 24);
  bytes[1] = (uint8_t) (value >> 16);
  bytes[2] = (uint8_t) (value >> 8);
  bytes[3] = (uint8_t) value;
}

GlimsBitmapPsdStatus
glims_bitmap_psd_size (const GlimsBitmapPsdSpec *spec, uint64_t *size)
{
  if (!size) return GLIMS_BITMAP_PSD_INVALID;
  *size = 0;
  if (!spec || !spec->width || !spec->height ||
      spec->width > GLIMS_BITMAP_PSD_MAX_DIMENSION ||
      spec->height > GLIMS_BITMAP_PSD_MAX_DIMENSION)
    return GLIMS_BITMAP_PSD_INVALID;
  *size = 40u + ((uint64_t) spec->width + 7u) / 8u * spec->height;
  return GLIMS_BITMAP_PSD_OK;
}

GlimsBitmapPsdStatus
glims_bitmap_psd_write (const GlimsBitmapPsdSpec *spec,
                        GlimsBitmapPsdRead read, void *read_context,
                        GlimsBitmapPsdWrite write, void *write_context)
{
  uint64_t size;
  if (!read || !write || glims_bitmap_psd_size (spec, &size) != GLIMS_BITMAP_PSD_OK)
    return GLIMS_BITMAP_PSD_INVALID;
  (void) size;
  uint8_t header[40] = { '8', 'B', 'P', 'S', 0, 1 };
  header[13] = 1; /* one channel */
  write_be32 (header + 14, spec->height);
  write_be32 (header + 18, spec->width);
  header[23] = 1; /* one bit per channel; mode and compression are zero */
  if (!write (write_context, header, sizeof header)) return GLIMS_BITMAP_PSD_WRITE_FAILED;

  uint8_t samples[GLIMS_BITMAP_PSD_CHUNK_PIXELS];
  uint8_t packed[GLIMS_BITMAP_PSD_CHUNK_PIXELS / 8];
  for (uint32_t y = 0; y < spec->height; y++)
    for (uint32_t x = 0; x < spec->width; )
      {
        uint32_t count = spec->width - x;
        if (count > GLIMS_BITMAP_PSD_CHUNK_PIXELS) count = GLIMS_BITMAP_PSD_CHUNK_PIXELS;
        if (!read (read_context, y, x, count, samples)) return GLIMS_BITMAP_PSD_READ_FAILED;
        size_t bytes = (count + 7u) / 8u;
        for (size_t i = 0; i < bytes; i++) packed[i] = 0;
        for (uint32_t i = 0; i < count; i++)
          {
            if (samples[i] != 0 && samples[i] != 255) return GLIMS_BITMAP_PSD_INVALID_PIXEL;
            if (samples[i] == 0) packed[i / 8u] |= (uint8_t) (0x80u >> (i % 8u));
          }
        if (!write (write_context, packed, bytes)) return GLIMS_BITMAP_PSD_WRITE_FAILED;
        x += count;
      }
  return GLIMS_BITMAP_PSD_OK;
}

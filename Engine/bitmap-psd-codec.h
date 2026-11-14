/* Private streaming serializer for a flat, monochrome Photoshop Bitmap PSD.
 * This codec does not convert color, mutate images or publish files. */
#ifndef GLIMS_BITMAP_PSD_CODEC_H
#define GLIMS_BITMAP_PSD_CODEC_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_BITMAP_PSD_MAX_DIMENSION 30000u
#define GLIMS_BITMAP_PSD_CHUNK_PIXELS 4096u

typedef struct {
  uint32_t width, height;
} GlimsBitmapPsdSpec;

typedef enum {
  GLIMS_BITMAP_PSD_OK,
  GLIMS_BITMAP_PSD_INVALID,
  GLIMS_BITMAP_PSD_INVALID_PIXEL,
  GLIMS_BITMAP_PSD_READ_FAILED,
  GLIMS_BITMAP_PSD_WRITE_FAILED
} GlimsBitmapPsdStatus;

/* The source supplies opaque binary luminance: 0 is black, 255 is white.
 * Requests stay within one row and are at most CHUNK_PIXELS long. Samples
 * are borrowed for the callback only. Any other pixel value is refused. */
typedef bool (*GlimsBitmapPsdRead) (void *context, uint32_t y, uint32_t x,
                                   uint32_t count, uint8_t *samples);
/* Return true only if all borrowed bytes were accepted. The caller must not
 * publish a partial stream if a later callback fails. */
typedef bool (*GlimsBitmapPsdWrite) (void *context, const uint8_t *bytes, size_t size);

/* Clears *size on failure. The complete PSD v1 output is bounded by the
 * documented 30000-pixel dimensions and is calculated without allocation. */
GlimsBitmapPsdStatus glims_bitmap_psd_size (const GlimsBitmapPsdSpec *spec, uint64_t *size);
/* Writes one channel, depth 1, Bitmap mode 0, raw compression, no metadata
 * or layer records. Black is bit 1; white and unused row-padding bits are 0.
 * Preflights the spec and callbacks before writing. The spec stays immutable
 * throughout callbacks; no pointers are retained. */
GlimsBitmapPsdStatus glims_bitmap_psd_write (const GlimsBitmapPsdSpec *spec,
                                            GlimsBitmapPsdRead read, void *read_context,
                                            GlimsBitmapPsdWrite write, void *write_context);
#endif

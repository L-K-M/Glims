/* Private, allocation-free reader for the explicit preserving CMYK import
 * subset. This is structural parsing, not full ICC usability validation. */
#ifndef GLIMS_CMYK_PSD_READER_H
#define GLIMS_CMYK_PSD_READER_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "cmyk-psd-codec.h"

typedef enum {
  GLIMS_CMYK_PSD_INPUT_OK,
  GLIMS_CMYK_PSD_INPUT_NOT_PSD,
  GLIMS_CMYK_PSD_INPUT_OTHER_MODE,
  GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,
  GLIMS_CMYK_PSD_INPUT_MALFORMED,
  GLIMS_CMYK_PSD_INPUT_READ_FAILED,
  GLIMS_CMYK_PSD_INPUT_EMIT_FAILED
} GlimsCmykPsdInputStatus;

typedef struct {
  uint32_t width, height;
  uint16_t depth, compression; /* 0 = RAW, 1 = PackBits/RLE */
  uint64_t icc_offset, pixel_offset, file_size, row_lengths_offset;
  uint32_t icc_size;
} GlimsCmykPsdInput;

/* Exact bounded reads from one immutable snapshot. Return true only when all
 * requested bytes have been initialized. No pointer is retained. */
typedef bool (*GlimsCmykPsdReadAt) (void *context, uint64_t offset,
                                   void *bytes, size_t count);
/* C/M/Y/K order; host-endian unsigned samples, zero full ink, maximum paper.
 * Borrowed aligned scratch; at most CHUNK_SAMPLES, within one row. Returning
 * false stops immediately; callers must discard any unpublished partial image. */
typedef bool (*GlimsCmykPsdEmit) (void *context, uint32_t channel,
                                 uint32_t y, uint32_t x, uint32_t count,
                                 const void *samples);

/* PSD v1 RAW or RLE, four U8/U16 CMYK channels, no color-mode data or layer section,
 * exactly one ICC resource and no other resources. Complete section bounds,
 * structural ICC header and exact final pixel length are checked. RLE checks
 * every row's declared extent and all packets before returning a layout.
 * Expanded samples are also capped at MAX_FILE bytes. No-op packets are
 * permitted, including at row end; other trailing bytes refuse. Nonempty
 * resource names and arbitrary present padding bytes are permitted. Full ICC
 * validation is the native caller's responsibility before image allocation.
 * Clears *out on every failure, no allocation or pixel callback. Borrowed input
 * remains immutable during inspection and any subsequent decode. */
GlimsCmykPsdInputStatus glims_cmyk_psd_inspect (
    GlimsCmykPsdReadAt read_at, void *context, uint64_t size,
    GlimsCmykPsdInput *out);

/* Re-inspects the immutable input and requires its layout to equal the supplied
 * inspected values before emitting. Emits endian-decoded samples only; no
 * inversion, ICC conversion, transfer curve or precision conversion. Invalid
 * arguments/layout, unsupported input and failed reads/emits never report OK.
 * A read/emit failure after earlier callbacks can leave partial private output.
 * No callback is made after the first failure. Scratch space is bounded. */
GlimsCmykPsdInputStatus glims_cmyk_psd_decode (
    GlimsCmykPsdReadAt read_at, void *read_context,
    const GlimsCmykPsdInput *input,
    GlimsCmykPsdEmit emit, void *emit_context);
#endif

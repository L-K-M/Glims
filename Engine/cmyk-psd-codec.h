/* Private flat PSD serializer. No image mutation, path handling, color
 * conversion or full ICC validation. The caller validates the source profile
 * and commits output atomically only after the complete stream succeeds. */
#ifndef GLIMS_CMYK_PSD_CODEC_H
#define GLIMS_CMYK_PSD_CODEC_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_CMYK_PSD_MAX_DIMENSION 30000u
#define GLIMS_CMYK_PSD_MAX_PROFILE (4u * 1024u * 1024u)
#define GLIMS_CMYK_PSD_MAX_FILE UINT64_C(2147483647)
#define GLIMS_CMYK_PSD_CHUNK_SAMPLES 4096u

typedef struct {
  uint32_t width, height;
  uint16_t depth; /* Exactly 8 or 16. */
  const uint8_t *icc;
  size_t icc_size;
} GlimsCmykPsdSpec;

typedef enum {
  GLIMS_CMYK_PSD_OK,
  GLIMS_CMYK_PSD_INVALID,
  GLIMS_CMYK_PSD_READ_FAILED,
  GLIMS_CMYK_PSD_WRITE_FAILED
} GlimsCmykPsdStatus;

/* Source order is Cyan, Magenta, Yellow, Black (0..3). Samples are native
 * unsigned integers in host byte order, 0=full ink and maximum=paper. Every
 * request stays within one row and contains at most CHUNK_SAMPLES samples.
 * Initialize every requested sample before returning true: contiguous bytes
 * at depth8, contiguous native uint16_t values at depth16. The destination is
 * aligned for uint16_t and owned only during this call. */
typedef bool (*GlimsCmykPsdRead) (void *context, uint32_t channel,
                                 uint32_t y, uint32_t x, uint32_t count,
                                 void *samples);
/* Return true only if every byte was accepted. Buffer is borrowed only for
 * this call. Partial output on later failure must not replace the destination. */
typedef bool (*GlimsCmykPsdWrite) (void *context, const uint8_t *bytes, size_t size);

/* Clears *size on failure. Structural ICC validation: bounded bytes, matching
 * declared length, acsp/CMYK signatures and input/output/colorspace class.
 * No allocation or callbacks. The total serialized file must fit MAX_FILE. */
GlimsCmykPsdStatus glims_cmyk_psd_size (const GlimsCmykPsdSpec *spec, uint64_t *size);
/* PSD v1, four planar integer channels, CMYK mode4, RAW compression0, exact
 * ICC resource1039 with even padding, no color-mode data or layer records.
 * Preflight invalid specs/callbacks before emitting anything. On any callback
 * failure, stop immediately with its distinct error. All scratch is bounded.
 * The specification and ICC bytes must remain alive and immutable throughout
 * the call, including inside either callback. No pointers are retained. */
GlimsCmykPsdStatus glims_cmyk_psd_write (const GlimsCmykPsdSpec *spec,
                                      GlimsCmykPsdRead read, void *read_context,
                                      GlimsCmykPsdWrite write, void *write_context);
#endif

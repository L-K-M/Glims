/* Private bounded streaming PSD v1 Duotone serializer. */
#ifndef GLIMS_DUOTONE_PSD_CODEC_H
#define GLIMS_DUOTONE_PSD_CODEC_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_DUOTONE_PSD_MAX_DIMENSION 30000u
#define GLIMS_DUOTONE_PSD_MAX_METADATA (16u * 1024u * 1024u)
#define GLIMS_DUOTONE_PSD_CHUNK_PIXELS 4096u
#define GLIMS_DUOTONE_PSD_METADATA_CHUNK (64u * 1024u)

typedef struct {
  uint32_t width, height, depth;
  const uint8_t *metadata;
  size_t metadata_size;
} GlimsDuotonePsdSpec;
typedef enum {
  GLIMS_DUOTONE_PSD_OK,
  GLIMS_DUOTONE_PSD_INVALID,
  GLIMS_DUOTONE_PSD_READ_FAILED,
  GLIMS_DUOTONE_PSD_WRITE_FAILED
} GlimsDuotonePsdStatus;

/* Supplies one row fragment of 8-bit samples or big-endian 16-bit samples.
 * Pixels must already be opaque and converted by the caller. Samples and
 * written bytes are borrowed only during their respective callbacks. */
typedef bool (*GlimsDuotonePsdRead) (void *context, uint32_t y, uint32_t x,
                                     uint32_t count, uint8_t *samples);
typedef bool (*GlimsDuotonePsdWrite) (void *context, const uint8_t *bytes, size_t size);
/* Clears *size on failure. PSD v1 dimensions are <=30000 and complete output
 * is kept below 2 GiB. Metadata is opaque, nonempty and at most 16 MiB. */
GlimsDuotonePsdStatus glims_duotone_psd_size (const GlimsDuotonePsdSpec *spec, uint64_t *size);
/* Writes one grayscale channel, Duotone mode, no layers/resources, raw image
 * data and the exact uninterpreted metadata block. The spec and metadata must
 * remain immutable until return. A partial stream must never be published. */
GlimsDuotonePsdStatus glims_duotone_psd_write (const GlimsDuotonePsdSpec *spec,
                                               GlimsDuotonePsdRead read, void *read_context,
                                               GlimsDuotonePsdWrite write, void *write_context);
#endif

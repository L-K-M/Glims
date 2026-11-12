#include "cmyk-psd-reader.h"

#include <string.h>

typedef struct {
  GlimsCmykPsdReadAt read_at;
  void *context;
  uint64_t size;
} PsdInput;

static uint16_t
read_be16 (const uint8_t *bytes)
{
  return (uint16_t) (((uint16_t) bytes[0] << 8) | bytes[1]);
}

static uint32_t
read_be32 (const uint8_t *bytes)
{
  return ((uint32_t) bytes[0] << 24) | ((uint32_t) bytes[1] << 16) |
         ((uint32_t) bytes[2] << 8) | bytes[3];
}

static bool
contains (uint64_t end, uint64_t offset, uint64_t length)
{
  return offset <= end && length <= end - offset;
}

static GlimsCmykPsdInputStatus
read_bytes (const PsdInput *input, uint64_t offset, void *bytes, size_t count)
{
  if (!contains (input->size, offset, count))
    return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  if (!input->read_at (input->context, offset, bytes, count))
    return GLIMS_CMYK_PSD_INPUT_READ_FAILED;
  return GLIMS_CMYK_PSD_INPUT_OK;
}

static GlimsCmykPsdInputStatus
read_u32 (const PsdInput *input, uint64_t *offset, uint32_t *value)
{
  uint8_t bytes[4];
  GlimsCmykPsdInputStatus status = read_bytes (input, *offset, bytes, sizeof bytes);
  if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
  *offset += sizeof bytes;
  *value = read_be32 (bytes);
  return GLIMS_CMYK_PSD_INPUT_OK;
}

static GlimsCmykPsdInputStatus
inspect_resources (const PsdInput *input, uint64_t start, uint32_t length,
                   GlimsCmykPsdInput *layout)
{
  uint64_t offset = start;
  uint64_t end;
  bool found = false;

  if (!contains (input->size, start, length))
    return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  end = start + length;

  while (offset < end)
    {
      uint8_t resource[7]; /* Signature, ID and Pascal-name length. */
      uint8_t bytes[4];
      uint8_t icc[128];
      uint64_t name_size, data_offset, padded_size;
      uint32_t data_size;
      GlimsCmykPsdInputStatus status;

      if (!contains (end, offset, sizeof resource))
        return GLIMS_CMYK_PSD_INPUT_MALFORMED;
      status = read_bytes (input, offset, resource, sizeof resource);
      if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
      if (memcmp (resource, "8BIM", 4) != 0)
        return GLIMS_CMYK_PSD_INPUT_MALFORMED;

      offset += 6;
      name_size = UINT64_C(1) + resource[6];
      name_size += name_size & 1;
      if (!contains (end, offset, name_size))
        return GLIMS_CMYK_PSD_INPUT_MALFORMED;
      offset += name_size;
      if (!contains (end, offset, sizeof bytes))
        return GLIMS_CMYK_PSD_INPUT_MALFORMED;
      status = read_bytes (input, offset, bytes, sizeof bytes);
      if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
      data_size = read_be32 (bytes);
      data_offset = offset + sizeof bytes;
      padded_size = (uint64_t) data_size + (data_size & 1u);
      if (!contains (end, data_offset, padded_size))
        return GLIMS_CMYK_PSD_INPUT_MALFORMED;

      /* Validate this complete record's bounds before refusing its type. No
       * unknown metadata or second profile can be silently discarded. */
      if (read_be16 (resource + 4) != 1039 || found)
        return GLIMS_CMYK_PSD_INPUT_UNSUPPORTED;
      if (data_size < sizeof icc)
        return GLIMS_CMYK_PSD_INPUT_MALFORMED;
      if (data_size > GLIMS_CMYK_PSD_MAX_PROFILE)
        return GLIMS_CMYK_PSD_INPUT_UNSUPPORTED;
      status = read_bytes (input, data_offset, icc, sizeof icc);
      if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
      if (read_be32 (icc) != data_size ||
          memcmp (icc + 16, "CMYK", 4) != 0 ||
          memcmp (icc + 36, "acsp", 4) != 0 ||
          (memcmp (icc + 12, "scnr", 4) != 0 &&
           memcmp (icc + 12, "prtr", 4) != 0 &&
           memcmp (icc + 12, "spac", 4) != 0))
        return GLIMS_CMYK_PSD_INPUT_MALFORMED;

      layout->icc_offset = data_offset;
      layout->icc_size = data_size;
      found = true;
      offset = data_offset + padded_size;
    }

  return found ? GLIMS_CMYK_PSD_INPUT_OK : GLIMS_CMYK_PSD_INPUT_UNSUPPORTED;
}

GlimsCmykPsdInputStatus
glims_cmyk_psd_inspect (GlimsCmykPsdReadAt read_at, void *context,
                      uint64_t size, GlimsCmykPsdInput *out)
{
  PsdInput input = { read_at, context, size };
  GlimsCmykPsdInput layout = { 0 };
  uint8_t header[26];
  uint8_t compression[2];
  uint64_t offset, pixel_bytes;
  uint32_t length;
  size_t signature_size = size < 4 ? (size_t) size : 4;
  GlimsCmykPsdInputStatus status;

  if (out) memset (out, 0, sizeof *out);
  if (!out || !read_at) return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  if (size > GLIMS_CMYK_PSD_MAX_FILE)
    return GLIMS_CMYK_PSD_INPUT_UNSUPPORTED;
  if (!signature_size) return GLIMS_CMYK_PSD_INPUT_NOT_PSD;
  status = read_bytes (&input, 0, header, signature_size);
  if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
  if (memcmp (header, "8BPS", signature_size) != 0)
    return GLIMS_CMYK_PSD_INPUT_NOT_PSD;
  if (size < sizeof header) return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  status = read_bytes (&input, 4, header + 4, sizeof header - 4);
  if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;

  if (read_be16 (header + 4) != 1)
    return GLIMS_CMYK_PSD_INPUT_UNSUPPORTED;
  for (size_t i = 6; i < 12; i++)
    if (header[i] != 0) return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  if (read_be16 (header + 24) != 4)
    return GLIMS_CMYK_PSD_INPUT_OTHER_MODE;

  layout.height = read_be32 (header + 14);
  layout.width = read_be32 (header + 18);
  layout.depth = read_be16 (header + 22);
  layout.file_size = size;
  if (!layout.width || !layout.height)
    return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  if (layout.width > GLIMS_CMYK_PSD_MAX_DIMENSION ||
      layout.height > GLIMS_CMYK_PSD_MAX_DIMENSION ||
      read_be16 (header + 12) != 4 ||
      (layout.depth != 8 && layout.depth != 16))
    return GLIMS_CMYK_PSD_INPUT_UNSUPPORTED;

  offset = sizeof header;
  status = read_u32 (&input, &offset, &length);
  if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
  if (!contains (size, offset, length))
    return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  if (length) return GLIMS_CMYK_PSD_INPUT_UNSUPPORTED;

  status = read_u32 (&input, &offset, &length);
  if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
  status = inspect_resources (&input, offset, length, &layout);
  if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
  offset += length; /* The complete resource span has been checked. */

  status = read_u32 (&input, &offset, &length);
  if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
  if (!contains (size, offset, length))
    return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  if (length) return GLIMS_CMYK_PSD_INPUT_UNSUPPORTED;
  status = read_bytes (&input, offset, compression, sizeof compression);
  if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
  if (read_be16 (compression) != 0)
    return GLIMS_CMYK_PSD_INPUT_UNSUPPORTED;
  offset += sizeof compression;

  /* Validated dimensions are at most 30,000 and the depth at most 16, so
   * this widened product cannot overflow uint64_t. No row padding exists. */
  pixel_bytes = (uint64_t) layout.width * layout.height * 4 * (layout.depth / 8);
  if (!contains (size, offset, pixel_bytes) || size - offset != pixel_bytes)
    return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  layout.pixel_offset = offset;
  memcpy (out, &layout, sizeof layout);
  return GLIMS_CMYK_PSD_INPUT_OK;
}

static bool
same_layout (const GlimsCmykPsdInput *a, const GlimsCmykPsdInput *b)
{
  /* Do not compare structure padding supplied by a caller. */
  return a->width == b->width && a->height == b->height && a->depth == b->depth &&
         a->icc_offset == b->icc_offset && a->pixel_offset == b->pixel_offset &&
         a->file_size == b->file_size && a->icc_size == b->icc_size;
}

GlimsCmykPsdInputStatus
glims_cmyk_psd_decode (GlimsCmykPsdReadAt read_at, void *read_context,
                     const GlimsCmykPsdInput *input,
                     GlimsCmykPsdEmit emit, void *emit_context)
{
  GlimsCmykPsdInput supplied, checked;
  uint16_t samples[GLIMS_CMYK_PSD_CHUNK_SAMPLES];
  uint8_t *bytes = (uint8_t *) samples;
  uint64_t offset;
  GlimsCmykPsdInputStatus status;

  if (!read_at || !input || !emit) return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  memcpy (&supplied, input, sizeof supplied);
  status = glims_cmyk_psd_inspect (read_at, read_context, supplied.file_size, &checked);
  if (status != GLIMS_CMYK_PSD_INPUT_OK) return status;
  if (!same_layout (&supplied, &checked)) return GLIMS_CMYK_PSD_INPUT_MALFORMED;
  offset = checked.pixel_offset;

  for (uint32_t channel = 0; channel < 4; channel++)
    for (uint32_t y = 0; y < checked.height; y++)
      for (uint32_t x = 0; x < checked.width; )
        {
          uint32_t count = checked.width - x;
          size_t byte_count;
          if (count > GLIMS_CMYK_PSD_CHUNK_SAMPLES)
            count = GLIMS_CMYK_PSD_CHUNK_SAMPLES;
          byte_count = (size_t) count * (checked.depth / 8);
          if (!read_at (read_context, offset, bytes, byte_count))
            return GLIMS_CMYK_PSD_INPUT_READ_FAILED;
          if (checked.depth == 16)
            for (uint32_t i = 0; i < count; i++)
              samples[i] = read_be16 (bytes + 2 * i);
          if (!emit (emit_context, channel, y, x, count, samples))
            return GLIMS_CMYK_PSD_INPUT_EMIT_FAILED;
          offset += byte_count;
          x += count;
        }

  return GLIMS_CMYK_PSD_INPUT_OK;
}

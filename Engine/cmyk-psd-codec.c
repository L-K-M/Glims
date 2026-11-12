/* Private flat PSD serializer. Implementation only. */
#include "cmyk-psd-codec.h"

#include <string.h>

#ifndef UINT32_MAX
#define UINT32_MAX 0xFFFFFFFFu
#endif
#ifndef UINT64_MAX
#define UINT64_MAX 0xFFFFFFFFFFFFFFFFULL
#endif

static void write_u16_be(uint8_t *p, uint16_t v)
{
  p[0] = (uint8_t)((v >> 8) & 0xFF);
  p[1] = (uint8_t)(v & 0xFF);
}

static void write_u32_be(uint8_t *p, uint32_t v)
{
  p[0] = (uint8_t)((v >> 24) & 0xFF);
  p[1] = (uint8_t)((v >> 16) & 0xFF);
  p[2] = (uint8_t)((v >> 8) & 0xFF);
  p[3] = (uint8_t)(v & 0xFF);
}

static bool u32_mul_overflow(uint32_t a, uint32_t b, uint32_t *out)
{
  if (a == 0 || b == 0) {
    if (out) *out = 0;
    return false;
  }
  if (a > UINT32_MAX / b) return true;
  if (out) *out = a * b;
  return false;
}

static bool u64_add_overflow(uint64_t a, uint64_t b, uint64_t *out)
{
  if (b > UINT64_MAX - a) return true;
  if (out) *out = a + b;
  return false;
}

static bool validate_icc_structural(const GlimsCmykPsdSpec *spec)
{
  if (spec->icc == NULL) return false;
  if (spec->icc_size == 0) return false;
  if (spec->icc_size < 128) return false;
  if (spec->icc_size > GLIMS_CMYK_PSD_MAX_PROFILE) return false;

  const uint8_t *icc = spec->icc;
  size_t sz = spec->icc_size;

  /* declared length at 0 big-endian */
  uint32_t declared = ((uint32_t)icc[0] << 24) |
                      ((uint32_t)icc[1] << 16) |
                      ((uint32_t)icc[2] << 8)  |
                      ((uint32_t)icc[3]);
  if ((size_t)declared != sz) return false;

  /* device class at 12: scnr, prtr, spac */
  uint32_t cls = ((uint32_t)icc[12] << 24) |
                 ((uint32_t)icc[13] << 16) |
                 ((uint32_t)icc[14] << 8)  |
                 ((uint32_t)icc[15]);
  if (cls != 0x73636E72u /* scnr */ &&
      cls != 0x70727472u /* prtr */ &&
      cls != 0x73706163u /* spac */) {
    return false;
  }

  /* color space at 16: CMYK */
  uint32_t pcs = ((uint32_t)icc[16] << 24) |
                 ((uint32_t)icc[17] << 16) |
                 ((uint32_t)icc[18] << 8)  |
                 ((uint32_t)icc[19]);
  if (pcs != 0x434D594Bu /* 'CMYK' */) return false;

  /* signature at 36: acsp */
  uint32_t sig = ((uint32_t)icc[36] << 24) |
                 ((uint32_t)icc[37] << 16) |
                 ((uint32_t)icc[38] << 8)  |
                 ((uint32_t)icc[39]);
  if (sig != 0x61637370u /* 'acsp' */) return false;

  return true;
}

static bool validate_spec_common(const GlimsCmykPsdSpec *spec)
{
  if (spec == NULL) return false;
  if (spec->width == 0 || spec->height == 0) return false;
  if (spec->width > GLIMS_CMYK_PSD_MAX_DIMENSION) return false;
  if (spec->height > GLIMS_CMYK_PSD_MAX_DIMENSION) return false;
  if (spec->depth != 8 && spec->depth != 16) return false;
  if (spec->icc == NULL || spec->icc_size == 0) return false;
  if (!validate_icc_structural(spec)) return false;
  return true;
}

static bool compute_size_total(const GlimsCmykPsdSpec *spec, uint64_t *size_out)
{
  uint32_t bytespersample = (uint32_t)(spec->depth / 8);
  if (bytespersample != 1 && bytespersample != 2) return false;

  uint64_t icc_sz = (uint64_t)spec->icc_size;
  uint64_t oddpad = (icc_sz % 2ULL);

  /* data per channel bytes = width*height*bytespersample */
  uint32_t ch_bytes_u32;
  if (u32_mul_overflow(spec->width, spec->height, &ch_bytes_u32)) return false;
  if (u32_mul_overflow(ch_bytes_u32, bytespersample, &ch_bytes_u32)) return false;
  uint64_t ch_bytes = (uint64_t)ch_bytes_u32;

  /* Total = 52 + ICC + oddpad + 4*ch_bytes (4 rows/planes of C,M,Y,K) */
  uint64_t total = 52ULL;
  if (u64_add_overflow(total, icc_sz, &total)) return false;
  if (u64_add_overflow(total, oddpad, &total)) return false;
  /* 4 * ch_bytes */
  uint64_t four_ch = 0;
  if (ch_bytes > UINT64_MAX / 4ULL) return false;
  four_ch = ch_bytes * 4ULL;
  if (u64_add_overflow(total, four_ch, &total)) return false;

  if (total > (uint64_t)GLIMS_CMYK_PSD_MAX_FILE) return false;
  if (size_out) *size_out = total;
  return true;
}

GlimsCmykPsdStatus glims_cmyk_psd_size (const GlimsCmykPsdSpec *spec, uint64_t *size)
{
  if (size == NULL) return GLIMS_CMYK_PSD_INVALID;
  *size = 0;
  if (!validate_spec_common(spec)) {
    *size = 0;
    return GLIMS_CMYK_PSD_INVALID;
  }
  uint64_t total = 0;
  if (!compute_size_total(spec, &total)) {
    *size = 0;
    return GLIMS_CMYK_PSD_INVALID;
  }
  *size = total;
  return GLIMS_CMYK_PSD_OK;
}

static bool write_all(GlimsCmykPsdWrite write, void *write_context, const uint8_t *bytes, size_t size)
{
  if (write == NULL) return false;
  if (size == 0) return true;
  if (!write(write_context, bytes, size)) return false;
  return true;
}

GlimsCmykPsdStatus glims_cmyk_psd_write (const GlimsCmykPsdSpec *spec,
                                      GlimsCmykPsdRead read, void *read_context,
                                      GlimsCmykPsdWrite write, void *write_context)
{
  if (write == NULL) return GLIMS_CMYK_PSD_INVALID;
  if (read == NULL) return GLIMS_CMYK_PSD_INVALID;
  if (!validate_spec_common(spec)) {
    return GLIMS_CMYK_PSD_INVALID;
  }

  uint64_t total_check = 0;
  if (!compute_size_total(spec, &total_check)) {
    return GLIMS_CMYK_PSD_INVALID;
  }

  uint32_t bytespersample = (uint32_t)(spec->depth / 8);
  uint64_t icc_sz = (uint64_t)spec->icc_size;
  uint64_t oddpad = (icc_sz % 2ULL);

  /* Scratch bounded < 16KiB */
  uint8_t hdr[26];
  /* 0: signature */
  hdr[0] = '8'; hdr[1] = 'B'; hdr[2] = 'P'; hdr[3] = 'S';
  /* 4: version */
  write_u16_be(hdr + 4, 1);
  /* 6-11 reserved zero */
  memset(hdr + 6, 0, 6);
  /* 12: channels */
  write_u16_be(hdr + 12, 4);
  /* 14: height */
  write_u32_be(hdr + 14, spec->height);
  /* 18: width */
  write_u32_be(hdr + 18, spec->width);
  /* 22: depth */
  write_u16_be(hdr + 22, (uint16_t)spec->depth);
  /* 24: color mode CMYK */
  write_u16_be(hdr + 24, 4);

  if (!write_all(write, write_context, hdr, sizeof(hdr))) return GLIMS_CMYK_PSD_WRITE_FAILED;

  /* color mode data length u32 zero */
  {
    uint8_t tmp[4]; write_u32_be(tmp, 0); if (!write_all(write, write_context, tmp, 4)) return GLIMS_CMYK_PSD_WRITE_FAILED;
  }
  /* resource section length */
  {
    uint64_t res_len_u64 = 12ULL + icc_sz + oddpad;
    /* must fit u32 */
    if (res_len_u64 > 0xFFFFFFFFULL) return GLIMS_CMYK_PSD_INVALID;
    uint32_t res_len = (uint32_t)res_len_u64;
    uint8_t tmp[4]; write_u32_be(tmp, res_len); if (!write_all(write, write_context, tmp, 4)) return GLIMS_CMYK_PSD_WRITE_FAILED;
  }
  /* resource: 8BIM, id 1039, empty Pascal name (2 zero) */
  {
    uint8_t tmp[12];
    tmp[0]='8'; tmp[1]='B'; tmp[2]='I'; tmp[3]='M';
    write_u16_be(tmp+4, 1039);
    tmp[6]=0; tmp[7]=0; /* empty Pascal name */
    /* size */
    if (icc_sz > 0xFFFFFFFFULL) return GLIMS_CMYK_PSD_INVALID;
    write_u32_be(tmp+8, (uint32_t)icc_sz);
    if (!write_all(write, write_context, tmp, 12)) return GLIMS_CMYK_PSD_WRITE_FAILED;
  }
  /* ICC bytes */
  if (!write_all(write, write_context, spec->icc, spec->icc_size)) return GLIMS_CMYK_PSD_WRITE_FAILED;
  if (oddpad) {
    uint8_t pad = 0;
    if (!write_all(write, write_context, &pad, 1)) return GLIMS_CMYK_PSD_WRITE_FAILED;
  }
  /* layer and mask section length 0 */
  {
    uint8_t tmp[4]; write_u32_be(tmp, 0); if (!write_all(write, write_context, tmp, 4)) return GLIMS_CMYK_PSD_WRITE_FAILED;
  }
  /* compression 0 */
  {
    uint8_t tmp[2]; write_u16_be(tmp, 0); if (!write_all(write, write_context, tmp, 2)) return GLIMS_CMYK_PSD_WRITE_FAILED;
  }

  /* Planar C,M,Y,K rows */
  uint32_t channels[4] = {0,1,2,3};
  for (int c = 0; c < 4; c++) {
    uint32_t ch = channels[c];
    for (uint32_t y = 0; y < spec->height; y++) {
      uint32_t x = 0;
      while (x < spec->width) {
        uint32_t remaining = spec->width - x;
        uint32_t count = remaining;
        if (count > GLIMS_CMYK_PSD_CHUNK_SAMPLES) count = GLIMS_CMYK_PSD_CHUNK_SAMPLES;
        uint16_t samples[GLIMS_CMYK_PSD_CHUNK_SAMPLES];
        uint8_t *bytes = (uint8_t *)(void *)samples;
        if (!read(read_context, ch, y, x, count, samples)) {
          return GLIMS_CMYK_PSD_READ_FAILED;
        }
        if (bytespersample == 1) {
          /* write U8 as-is */
          if (!write_all(write, write_context, bytes, (size_t)count)) {
            return GLIMS_CMYK_PSD_WRITE_FAILED;
          }
        } else { /* 16 */
          /* host-order uint16 -> big-endian, no change to numeric values */
          for (uint32_t i = 0; i < count; i++) {
            uint16_t value = samples[i];
            write_u16_be(bytes + i * 2, value);
          }
          if (!write_all(write, write_context, bytes, (size_t)count * 2)) {
            return GLIMS_CMYK_PSD_WRITE_FAILED;
          }
        }
        x += count;
      }
    }
  }

  return GLIMS_CMYK_PSD_OK;
}

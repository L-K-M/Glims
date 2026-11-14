#include "duotone-psd-codec.h"

static void
be32 (uint8_t *out, uint32_t value)
{
  out[0] = (uint8_t) (value >> 24); out[1] = (uint8_t) (value >> 16);
  out[2] = (uint8_t) (value >> 8); out[3] = (uint8_t) value;
}

GlimsDuotonePsdStatus
glims_duotone_psd_size (const GlimsDuotonePsdSpec *spec, uint64_t *size)
{
  if (!size) return GLIMS_DUOTONE_PSD_INVALID;
  *size = 0;
  if (!spec || !spec->width || !spec->height || spec->width > GLIMS_DUOTONE_PSD_MAX_DIMENSION ||
      spec->height > GLIMS_DUOTONE_PSD_MAX_DIMENSION || (spec->depth != 8 && spec->depth != 16) ||
      !spec->metadata || !spec->metadata_size || spec->metadata_size > GLIMS_DUOTONE_PSD_MAX_METADATA)
    return GLIMS_DUOTONE_PSD_INVALID;
  uint64_t total = 40u + (uint64_t) spec->metadata_size +
                   (uint64_t) spec->width * spec->height * (spec->depth / 8u);
  if (total >= UINT64_C(2147483648)) return GLIMS_DUOTONE_PSD_INVALID;
  *size = total;
  return GLIMS_DUOTONE_PSD_OK;
}

GlimsDuotonePsdStatus
glims_duotone_psd_write (const GlimsDuotonePsdSpec *spec,
                         GlimsDuotonePsdRead read, void *read_context,
                         GlimsDuotonePsdWrite write, void *write_context)
{
  uint64_t size;
  if (!read || !write || glims_duotone_psd_size (spec, &size) != GLIMS_DUOTONE_PSD_OK)
    return GLIMS_DUOTONE_PSD_INVALID;
  (void) size;
  uint8_t header[30] = { '8','B','P','S', 0,1 };
  header[13]=1;
  be32 (header+14, spec->height); be32 (header+18, spec->width);
  header[23]=(uint8_t)spec->depth; header[25]=8;
  be32 (header+26, (uint32_t)spec->metadata_size);
  if (!write (write_context, header, sizeof header)) return GLIMS_DUOTONE_PSD_WRITE_FAILED;
  for (size_t offset=0; offset<spec->metadata_size; )
    {
      size_t count=spec->metadata_size-offset;
      if (count>GLIMS_DUOTONE_PSD_METADATA_CHUNK) count=GLIMS_DUOTONE_PSD_METADATA_CHUNK;
      if (!write (write_context,spec->metadata+offset,count)) return GLIMS_DUOTONE_PSD_WRITE_FAILED;
      offset+=count;
    }
  const uint8_t footer[10]={0}; /* resource and layer lengths, raw compression */
  if (!write (write_context,footer,sizeof footer)) return GLIMS_DUOTONE_PSD_WRITE_FAILED;
  uint8_t samples[GLIMS_DUOTONE_PSD_CHUNK_PIXELS*2u];
  for (uint32_t y=0;y<spec->height;y++)
    for (uint32_t x=0;x<spec->width; )
      {
        uint32_t count=spec->width-x;
        if (count>GLIMS_DUOTONE_PSD_CHUNK_PIXELS) count=GLIMS_DUOTONE_PSD_CHUNK_PIXELS;
        if (!read (read_context,y,x,count,samples)) return GLIMS_DUOTONE_PSD_READ_FAILED;
        if (!write (write_context,samples,(size_t)count*(spec->depth/8u))) return GLIMS_DUOTONE_PSD_WRITE_FAILED;
        x+=count;
      }
  return GLIMS_DUOTONE_PSD_OK;
}

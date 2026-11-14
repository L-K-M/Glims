#include "duotone-preview-table.h"
#include <string.h>

static uint16_t
read_u16 (const uint8_t *p)
{
  return (uint16_t) (((uint16_t) p[0] << 8) | p[1]);
}

bool
glims_duotone_preview_table_parse (const uint8_t *bytes, size_t length,
                                  GlimsDuotonePreviewTable *out)
{
  if (!bytes || !out || length < 6 || read_u16 (bytes) != 1) return false;
  unsigned count = read_u16 (bytes + 2);
  if (count > GLIMS_DUOTONE_PREVIEW_MAX_COLORS) return false;
  size_t samples_offset = 4 + (size_t) count * 10;
  if (length < samples_offset + 2 ||
      read_u16 (bytes + samples_offset) != GLIMS_DUOTONE_PREVIEW_SAMPLES ||
      length != samples_offset + 2 + GLIMS_DUOTONE_PREVIEW_SAMPLES * 3)
    return false;

  GlimsDuotonePreviewTable value = {0};
  value.color_count = count;
  for (unsigned i = 0; i < count; i++)
    {
      const uint8_t *color = bytes + 4 + i * 10;
      value.colors[i].space = read_u16 (color);
      for (unsigned j = 0; j < 4; j++)
        value.colors[i].components[j] = read_u16 (color + 2 + j * 2);
    }
  memcpy (value.lab, bytes + samples_offset + 2, sizeof value.lab);
  *out = value;
  return true;
}

#include "duotone-options.h"
#include <string.h>

/* Offsets are for the documented version-1 .ADO settings file. */
enum { COUNT = 2, COLORS = 4, NAMES = 44, CURVES = 300 };

static uint16_t
read_u16 (const uint8_t *p)
{
  return (uint16_t) (((uint16_t) p[0] << 8) | p[1]);
}

static void
write_u16 (uint8_t *p, uint16_t value)
{
  p[0] = (uint8_t) (value >> 8);
  p[1] = (uint8_t) value;
}

static bool
valid_curve (const uint8_t *p)
{
  for (unsigned i = 0; i < GLIMS_DUOTONE_OPTIONS_CURVE_POINTS; i++)
    {
      uint16_t value = read_u16 (p + i * 2);
      if (value > 1000 && !(value == UINT16_MAX && i > 0 && i < 12))
        return false;
    }
  return true;
}

bool
glims_duotone_options_parse (const uint8_t *bytes, size_t length, GlimsDuotoneOptions *out)
{
  if (!bytes || !out || length != GLIMS_DUOTONE_OPTIONS_SIZE || read_u16 (bytes) != 1)
    return false;
  unsigned count = read_u16 (bytes + COUNT);
  if (count < 1 || count > GLIMS_DUOTONE_OPTIONS_MAX_INKS)
    return false;
  for (unsigned i = 0; i < count; i++)
    if (bytes[NAMES + i * 64] > GLIMS_DUOTONE_OPTIONS_NAME_CAPACITY ||
        !valid_curve (bytes + CURVES + i * 28))
      return false;
  GlimsDuotoneOptions copy;
  memcpy (copy.bytes, bytes, sizeof copy.bytes);
  *out = copy;
  return true;
}

unsigned
glims_duotone_options_count (const GlimsDuotoneOptions *options)
{
  return options ? read_u16 (options->bytes + COUNT) : 0;
}

static bool
active_ink (const GlimsDuotoneOptions *options, unsigned ink)
{
  unsigned count = glims_duotone_options_count (options);
  return count >= 1 && count <= GLIMS_DUOTONE_OPTIONS_MAX_INKS && ink < count;
}

bool
glims_duotone_options_name (const GlimsDuotoneOptions *options, unsigned ink,
                           const uint8_t **bytes, size_t *length)
{
  if (!active_ink (options, ink) || !bytes || !length) return false;
  const uint8_t *name = options->bytes + NAMES + ink * 64;
  if (*name > GLIMS_DUOTONE_OPTIONS_NAME_CAPACITY) return false;
  *bytes = name + 1;
  *length = *name;
  return true;
}

bool
glims_duotone_options_color (const GlimsDuotoneOptions *options, unsigned ink,
                            GlimsDuotoneInkColor *color)
{
  if (!active_ink (options, ink) || !color) return false;
  const uint8_t *p = options->bytes + COLORS + ink * 10;
  GlimsDuotoneInkColor value;
  value.space = read_u16 (p);
  for (unsigned i = 0; i < 4; i++) value.components[i] = read_u16 (p + 2 + i * 2);
  *color = value;
  return true;
}

bool
glims_duotone_options_curve (const GlimsDuotoneOptions *options, unsigned ink,
                            int16_t points[GLIMS_DUOTONE_OPTIONS_CURVE_POINTS])
{
  if (!active_ink (options, ink) || !points) return false;
  const uint8_t *p = options->bytes + CURVES + ink * 28;
  if (!valid_curve (p)) return false;
  for (unsigned i = 0; i < GLIMS_DUOTONE_OPTIONS_CURVE_POINTS; i++)
    {
      uint16_t value = read_u16 (p + i * 2);
      points[i] = value == UINT16_MAX ? -1 : (int16_t) value;
    }
  return true;
}

bool
glims_duotone_options_set_name (GlimsDuotoneOptions *options, unsigned ink,
                               const uint8_t *bytes, size_t length)
{
  if (!active_ink (options, ink) || length > GLIMS_DUOTONE_OPTIONS_NAME_CAPACITY ||
      (length && !bytes)) return false;
  uint8_t copy[GLIMS_DUOTONE_OPTIONS_NAME_CAPACITY];
  if (length) memcpy (copy, bytes, length);
  uint8_t *name = options->bytes + NAMES + ink * 64;
  memset (name, 0, 64);
  name[0] = (uint8_t) length;
  if (length) memcpy (name + 1, copy, length);
  return true;
}

bool
glims_duotone_options_set_color (GlimsDuotoneOptions *options, unsigned ink,
                                const GlimsDuotoneInkColor *color)
{
  if (!active_ink (options, ink) || !color) return false;
  GlimsDuotoneInkColor copy = *color;
  uint8_t *p = options->bytes + COLORS + ink * 10;
  write_u16 (p, copy.space);
  for (unsigned i = 0; i < 4; i++) write_u16 (p + 2 + i * 2, copy.components[i]);
  return true;
}

bool
glims_duotone_options_set_curve (GlimsDuotoneOptions *options, unsigned ink,
                                const int16_t points[GLIMS_DUOTONE_OPTIONS_CURVE_POINTS])
{
  if (!active_ink (options, ink) || !points) return false;
  int16_t copy[GLIMS_DUOTONE_OPTIONS_CURVE_POINTS];
  memcpy (copy, points, sizeof copy);
  for (unsigned i = 0; i < GLIMS_DUOTONE_OPTIONS_CURVE_POINTS; i++)
    if (copy[i] < -1 || copy[i] > 1000 || (copy[i] == -1 && (i == 0 || i == 12)))
      return false;
  uint8_t *p = options->bytes + CURVES + ink * 28;
  for (unsigned i = 0; i < GLIMS_DUOTONE_OPTIONS_CURVE_POINTS; i++)
    write_u16 (p + i * 2, copy[i] == -1 ? UINT16_MAX : (uint16_t) copy[i]);
  return true;
}

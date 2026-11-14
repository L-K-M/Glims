#include "duotone-options.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(condition, label) do { \
  bool ok = !!(condition); checks++; if (!ok) failures++; \
  printf("%s %s\n", ok ? "ok" : "FAIL", label); \
} while (0)

static void put16 (uint8_t *p, uint16_t value)
{ p[0] = (uint8_t) (value >> 8); p[1] = (uint8_t) value; }

static void make_options (uint8_t bytes[GLIMS_DUOTONE_OPTIONS_SIZE])
{
  memset (bytes, 0, GLIMS_DUOTONE_OPTIONS_SIZE);
  put16 (bytes, 1); put16 (bytes + 2, 2);
  put16 (bytes + 4, 2); put16 (bytes + 6, 65535); put16 (bytes + 12, 1234);
  bytes[44] = 5; memcpy (bytes + 45, "Black", 5);
  bytes[108] = 4; memcpy (bytes + 109, "Blue", 4);
  for (unsigned ink = 0; ink < 4; ink++)
    {
      uint8_t *curve = bytes + 300 + ink * 28;
      for (unsigned i = 1; i < 12; i++) put16 (curve + i * 2, UINT16_MAX);
      put16 (curve + 24, 1000);
      put16 (curve + 26, (uint16_t) (0x100 + ink));
    }
  put16 (bytes + 412, 20);
  for (unsigned i = 414; i < GLIMS_DUOTONE_OPTIONS_SIZE; i++) bytes[i] = (uint8_t) i;
}

static bool same_except (const uint8_t *a, const uint8_t *b, size_t start, size_t length)
{
  for (size_t i = 0; i < GLIMS_DUOTONE_OPTIONS_SIZE; i++)
    if ((i < start || i >= start + length) && a[i] != b[i]) return false;
  return true;
}

static void test_fixture (const char *path)
{
  FILE *f = fopen (path, "rb");
  CHECK (f != NULL, "open real Photoshop fixture");
  if (!f) return;
  uint8_t header[30], block[GLIMS_DUOTONE_OPTIONS_SIZE];
  bool read_ok = fread (header, 1, sizeof header, f) == sizeof header &&
    !memcmp (header, "8BPS", 4) && header[26] == 0 && header[27] == 0 &&
    header[28] == 2 && header[29] == 12 &&
    fread (block, 1, sizeof block, f) == sizeof block;
  fclose (f);
  CHECK (read_ok, "fixture contains a 524-byte color-mode block");
  if (!read_ok) return;
  GlimsDuotoneOptions options;
  bool parsed = glims_duotone_options_parse (block, sizeof block, &options);
  CHECK (parsed && !memcmp (block, options.bytes, sizeof block),
         "fixture matches the documented settings layout without byte changes");
  if (!parsed) return;
  const uint8_t *name = NULL; size_t length = 0;
  CHECK (glims_duotone_options_count (&options) == 2 &&
         glims_duotone_options_name (&options, 1, &name, &length) &&
         length == 15 && !memcmp (name, "PANTONE 327 CVC", length), "fixture second ink name");
  int16_t curve[GLIMS_DUOTONE_OPTIONS_CURVE_POINTS] = {0};
  CHECK (glims_duotone_options_curve (&options, 1, curve) &&
         curve[0] == 0 && curve[6] == 350 && curve[9] == 700 && curve[12] == 1000,
         "fixture transfer curve values");
}

int main (int argc, char **argv)
{
  if (argc != 2) return 2;
  uint8_t bytes[GLIMS_DUOTONE_OPTIONS_SIZE], original[GLIMS_DUOTONE_OPTIONS_SIZE];
  make_options (bytes); memcpy (original, bytes, sizeof bytes);
  GlimsDuotoneOptions options, before;
  memset (&options, 0xa5, sizeof options);
  bool parsed = glims_duotone_options_parse (bytes, sizeof bytes, &options);
  CHECK (parsed && !memcmp (options.bytes, bytes, sizeof bytes), "parse and preserve every byte");
  if (!parsed) return 1;
  CHECK (glims_duotone_options_count (&options) == 2 && glims_duotone_options_count (NULL) == 0,
         "count active plates");
  const uint8_t *name = NULL; size_t length = 0;
  bool have_name = glims_duotone_options_name (&options, 0, &name, &length);
  CHECK (have_name && length == 5 && !memcmp (name, "Black", 5), "read Pascal name bytes");
  if (!have_name || !name) return 1;
  GlimsDuotoneInkColor color = {0};
  CHECK (glims_duotone_options_color (&options, 0, &color) && color.space == 2 &&
         color.components[0] == 65535 && color.components[3] == 1234, "read big-endian ink color");
  int16_t curve[GLIMS_DUOTONE_OPTIONS_CURVE_POINTS] = {0};
  CHECK (glims_duotone_options_curve (&options, 0, curve) && curve[0] == 0 &&
         curve[1] == -1 && curve[12] == 1000, "read signed curve values");

  before = options;
  CHECK (glims_duotone_options_set_name (&options, 0, name + 1, 4) &&
         glims_duotone_options_name (&options, 0, &name, &length) && length == 4 &&
         !memcmp (name, "lack", 4) && same_except (before.bytes, options.bytes, 44, 64),
         "overlapping name update preserves other fields");
  before = options; color.space = 7; color.components[0] = 42;
  CHECK (glims_duotone_options_set_color (&options, 1, &color) &&
         glims_duotone_options_color (&options, 1, &color) && color.space == 7 &&
         color.components[0] == 42 && same_except (before.bytes, options.bytes, 14, 10),
         "color update preserves every other byte");
  before = options; curve[3] = 377;
  CHECK (glims_duotone_options_set_curve (&options, 0, curve) &&
         glims_duotone_options_curve (&options, 0, curve) && curve[3] == 377 &&
         same_except (before.bytes, options.bytes, 300, 26), "curve update preserves override and overprints");
  before = options; curve[0] = -1;
  CHECK (!glims_duotone_options_set_curve (&options, 0, curve) &&
         !memcmp (&before, &options, sizeof options), "invalid endpoint refuses without mutation");
  curve[0] = 0; curve[1] = -2;
  CHECK (!glims_duotone_options_set_curve (&options, 0, curve) &&
         !memcmp (&before, &options, sizeof options), "invalid interior point refuses without mutation");
  curve[1] = 1001;
  CHECK (!glims_duotone_options_set_curve (&options, 0, curve) &&
         !memcmp (&before, &options, sizeof options), "out-of-range point refuses without mutation");
  CHECK (!glims_duotone_options_set_name (&options, 0, bytes, 64) &&
         !glims_duotone_options_set_name (&options, 0, NULL, 1) &&
         !glims_duotone_options_set_color (&options, 2, &color) &&
         !glims_duotone_options_curve (&options, 2, curve) &&
         !memcmp (&before, &options, sizeof options), "invalid and inactive edits refuse without mutation");
  CHECK (glims_duotone_options_set_name (&options, 0, NULL, 0) &&
         glims_duotone_options_name (&options, 0, &name, &length) && length == 0,
         "empty ink name is supported");

  before = options;
  for (size_t n = 0; n < sizeof bytes; n++)
    CHECK (!glims_duotone_options_parse (bytes, n, &options) && !memcmp (&before, &options, sizeof options),
           "truncated options refuse without mutation");
  CHECK (!glims_duotone_options_parse (bytes, sizeof bytes + 1, &options) &&
         !glims_duotone_options_parse (NULL, sizeof bytes, &options) &&
         !glims_duotone_options_parse (bytes, sizeof bytes, NULL), "invalid input arguments refuse");
  bytes[1] = 2;
  CHECK (!glims_duotone_options_parse (bytes, sizeof bytes, &options), "unknown version refuses");
  memcpy (bytes, original, sizeof bytes); put16 (bytes + 2, 0);
  CHECK (!glims_duotone_options_parse (bytes, sizeof bytes, &options), "zero plates refuse");
  put16 (bytes + 2, 5);
  CHECK (!glims_duotone_options_parse (bytes, sizeof bytes, &options), "too many plates refuse");
  memcpy (bytes, original, sizeof bytes); bytes[108] = 64;
  CHECK (!glims_duotone_options_parse (bytes, sizeof bytes, &options), "overlong active name refuses");
  memcpy (bytes, original, sizeof bytes); put16 (bytes + 300, UINT16_MAX);
  CHECK (!glims_duotone_options_parse (bytes, sizeof bytes, &options), "missing curve endpoint refuses");
  memcpy (bytes, original, sizeof bytes); put16 (bytes + 302, 1001);
  CHECK (!glims_duotone_options_parse (bytes, sizeof bytes, &options), "invalid active curve refuses");
  memcpy (bytes, original, sizeof bytes); bytes[172] = 255; put16 (bytes + 356, 0xfffe);
  CHECK (glims_duotone_options_parse (bytes, sizeof bytes, &options) &&
         !memcmp (bytes, options.bytes, sizeof bytes), "undefined inactive data is preserved");
  CHECK (glims_duotone_options_parse (options.bytes, sizeof options.bytes, &options) &&
         !memcmp (bytes, options.bytes, sizeof bytes), "parse supports input overlapping output");
  test_fixture (argv[1]);
  printf ("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}

#include "duotone-preview-table.h"
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
static uint16_t get16 (const uint8_t *p)
{ return (uint16_t) (((uint16_t) p[0] << 8) | p[1]); }
static uint32_t get32 (const uint8_t *p)
{ return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | p[3]; }

static size_t make_table (uint8_t *bytes, unsigned count)
{
  size_t offset = 4 + count * 10;
  memset (bytes, 0, 4 + 4 * 10 + 2 + 256 * 3);
  put16 (bytes, 1); put16 (bytes + 2, (uint16_t) count);
  for (unsigned i = 0; i < count; i++)
    {
      put16 (bytes + 4 + 10 * i, (uint16_t) (7 + i));
      for (unsigned j = 0; j < 4; j++) put16 (bytes + 6 + 10 * i + 2 * j, (uint16_t) (i * 100 + j));
    }
  put16 (bytes + offset, 256); offset += 2;
  for (unsigned i = 0; i < 256; i++)
    { bytes[offset + 3 * i] = (uint8_t) i; bytes[offset + 3 * i + 1] = (uint8_t) (255 - i); bytes[offset + 3 * i + 2] = 128; }
  return offset + 256 * 3;
}

static void test_fixture (const char *path)
{
  FILE *f = fopen (path, "rb");
  CHECK (f != NULL, "open real Photoshop fixture");
  if (!f) return;
  if (fseek (f, 0, SEEK_END) || ftell (f) < 30 || ftell (f) > 10000000) { fclose (f); CHECK (false, "fixture size"); return; }
  size_t size = (size_t) ftell (f); rewind (f);
  uint8_t *file = malloc (size);
  if (!file) { fclose (f); CHECK (false, "fixture allocation"); return; }
  bool loaded = fread (file, 1, size, f) == size; fclose (f);
  if (!loaded || memcmp (file, "8BPS", 4)) { free (file); CHECK (false, "fixture header"); return; }
  size_t mode = get32 (file + 26);
  if (mode > size - 30 || size - 30 - mode < 4) { free (file); CHECK (false, "fixture mode range"); return; }
  size_t p = 30 + mode, resources = get32 (file + p); p += 4;
  if (resources > size - p) { free (file); CHECK (false, "fixture resource range"); return; }
  size_t end = p + resources, found = 0; GlimsDuotonePreviewTable table = {0};
  while (p < end)
    {
      if (end - p < 12 || memcmp (file + p, "8BIM", 4)) break;
      unsigned id = get16 (file + p + 4), name = file[p + 6];
      size_t name_bytes = (1u + name + 1u) & ~(size_t) 1u;
      if (name_bytes > end - p - 6 || end - p - 6 - name_bytes < 4) break;
      size_t length_pos = p + 6 + name_bytes, length = get32 (file + length_pos);
      size_t body = length_pos + 4;
      if (length > end - body || (length & 1u && length == end - body)) break;
      if (id == 1066)
        {
          found++;
          CHECK (glims_duotone_preview_table_parse (file + body, length, &table), "real resource 1066 parses");
        }
      p = body + length + (length & 1u);
    }
  CHECK (p == end && found == 1, "fixture contains exactly one bounded 1066 resource");
  if (found == 1)
    {
      CHECK (table.color_count == 2 && table.colors[0].space == 7 &&
             table.colors[0].components[0] == 953 && table.colors[1].components[1] == 58936,
             "fixture alternate color words match the file");
      CHECK (table.lab[0][0] == 4 && table.lab[0][1] == 125 && table.lab[0][2] == 128 &&
             table.lab[255][0] == 255 && table.lab[255][1] == 128 && table.lab[255][2] == 128,
             "fixture Lab table endpoints match the file");
    }
  free (file);
}

int main (int argc, char **argv)
{
  if (argc != 2) return 2;
  uint8_t bytes[4 + 4 * 10 + 2 + 256 * 3 + 1];
  GlimsDuotonePreviewTable table, before;
  for (unsigned count = 0; count <= 4; count++)
    {
      size_t size = make_table (bytes, count);
      memset (&table, 0xa5, sizeof table);
      bool parsed = glims_duotone_preview_table_parse (bytes, size, &table);
      CHECK (parsed && table.color_count == count && table.lab[0][0] == 0 &&
             table.lab[255][0] == 255 && table.lab[255][1] == 0,
             "parse supported color count and all sample endpoints");
      if (parsed && count)
        CHECK (table.colors[count - 1].space == 7 + count - 1 &&
               table.colors[count - 1].components[3] == (count - 1) * 100 + 3,
               "alternate color words are big-endian");
    }
  size_t size = make_table (bytes, 2);
  memset (&before, 0xa5, sizeof before); memcpy (&table, &before, sizeof table);
  for (size_t n = 0; n < size; n++)
    CHECK (!glims_duotone_preview_table_parse (bytes, n, &table) &&
           !memcmp (&before, &table, sizeof table), "truncation refuses without changing output");
  CHECK (!glims_duotone_preview_table_parse (bytes, size + 1, &table) &&
         !glims_duotone_preview_table_parse (NULL, size, &table) &&
         !glims_duotone_preview_table_parse (bytes, size, NULL), "invalid arguments and trailing bytes refuse");
  bytes[1] = 2;
  CHECK (!glims_duotone_preview_table_parse (bytes, size, &table), "unknown version refuses");
  size = make_table (bytes, 2); put16 (bytes + 2, 5);
  CHECK (!glims_duotone_preview_table_parse (bytes, size, &table), "more than four colors refuse");
  size = make_table (bytes, 2); put16 (bytes + 24, 255);
  CHECK (!glims_duotone_preview_table_parse (bytes, size, &table), "unsupported sample count refuses");
  CHECK (!memcmp (&before, &table, sizeof table), "invalid tables leave output intact");
  size = make_table (bytes, 2);
  union { GlimsDuotonePreviewTable table; uint8_t bytes[1024]; } alias;
  memcpy (alias.bytes, bytes, size);
  CHECK (glims_duotone_preview_table_parse (alias.bytes, size, &alias.table) &&
         alias.table.color_count == 2 && alias.table.lab[255][0] == 255,
         "input may overlap output");
  test_fixture (argv[1]);
  printf ("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}

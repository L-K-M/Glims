/* Standalone checks for Engine/tiff-import.c. Fixtures are generated and
 * read back through libtiff only; the utility under test sees nothing but
 * paths, GFile and GError. Prints one "ok"/"FAIL" line per check and exits
 * nonzero on any failure.
 *
 *   cc -I Engine -o tiff-import-tests Engine/tiff-import.c \
 *      Engine/tests/tiff-import-tests.c $(pkg-config --cflags --libs \
 *      glib-2.0 gio-2.0 libtiff-4)
 */
#include "tiff-import.h"

#include <glib.h>
#include <glib/gstdio.h>
#include <stdio.h>
#include <string.h>
#include <tiffio.h>
#include <unistd.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

static unsigned checks, failures;
#define CHECK(condition, message) do { \
  ++checks; \
  printf ("%s %s\n", (condition) ? "ok  " : (++failures, "FAIL"), (message)); \
  fflush (stdout); \
} while (0)

typedef struct
{
  guint32     width, height;
  int         subfiletype; /* NewSubfileType value; -1 leaves the tag out */
  unsigned    seed;        /* pixel pattern seed */
  int         orientation; /* 0 leaves the tag out */
  gboolean    icc;
  const char *pagename;    /* NULL leaves the tag out */
  gboolean    lzw;
} FixturePage;

static const guint8 fake_icc[] = {
  'g', 'l', 'i', 'm', 's', '-', 'i', 'c', 'c', 0xde, 0xad, 0xbe, 0xef, 0, 1, 2
};

static guint8
pixel (const FixturePage *page, guint32 x, guint32 y, unsigned s)
{
  return (guint8) (page->seed + x * 13 + y * 17 + s * 19);
}

static gboolean
write_fixture (const char *path, const char *mode,
               const FixturePage *pages, unsigned n_pages)
{
  TIFF *tif = TIFFOpen (path, mode);
  if (!tif) return FALSE;
  gboolean ok = TRUE;
  for (unsigned i = 0; ok && i < n_pages; i++)
    {
      const FixturePage *p = pages + i;
      TIFFSetField (tif, TIFFTAG_IMAGEWIDTH, p->width);
      TIFFSetField (tif, TIFFTAG_IMAGELENGTH, p->height);
      TIFFSetField (tif, TIFFTAG_BITSPERSAMPLE, 8);
      TIFFSetField (tif, TIFFTAG_SAMPLESPERPIXEL, 3);
      TIFFSetField (tif, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB);
      TIFFSetField (tif, TIFFTAG_COMPRESSION,
                    p->lzw ? COMPRESSION_LZW : COMPRESSION_NONE);
      TIFFSetField (tif, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
      TIFFSetField (tif, TIFFTAG_ROWSPERSTRIP, p->height);
      if (p->orientation)
        TIFFSetField (tif, TIFFTAG_ORIENTATION, p->orientation);
      if (p->subfiletype >= 0)
        TIFFSetField (tif, TIFFTAG_SUBFILETYPE, (uint32_t) p->subfiletype);
      if (p->icc)
        TIFFSetField (tif, TIFFTAG_ICCPROFILE,
                      (uint32_t) sizeof fake_icc, fake_icc);
      if (p->pagename)
        TIFFSetField (tif, TIFFTAG_PAGENAME, p->pagename);

      g_autofree guint8 *row = g_malloc (p->width * 3);
      for (guint32 y = 0; ok && y < p->height; y++)
        {
          for (guint32 x = 0; x < p->width; x++)
            for (unsigned s = 0; s < 3; s++)
              row[x * 3 + s] = pixel (p, x, y, s);
          ok = TIFFWriteScanline (tif, row, y, 0) >= 0;
        }
      ok = ok && TIFFWriteDirectory (tif);
    }
  TIFFClose (tif);
  return ok;
}

static unsigned
count_directories (TIFF *tif)
{
  unsigned n = 0;
  while (TIFFSetDirectory (tif, n)) n++;
  return n;
}

/* Verify the current directory of tif against a fixture page: dimensions,
 * pixel bytes row by row, and the tags the page declared. */
static void
check_page (TIFF *tif, const FixturePage *page, GString *text)
{
  uint32_t w = 0, h = 0;
  TIFFGetField (tif, TIFFTAG_IMAGEWIDTH, &w);
  TIFFGetField (tif, TIFFTAG_IMAGELENGTH, &h);
  g_autofree gchar *label = g_strdup (text->str);
  g_string_printf (text, "%s: dims %ux%u", label, w, h);
  CHECK (w == page->width && h == page->height, text->str);

  gboolean pixels_match = w == page->width && h == page->height;
  if (pixels_match)
    {
      g_autofree guint8 *row = g_malloc (w * 3);
      for (guint32 y = 0; pixels_match && y < h; y++)
        {
          if (TIFFReadScanline (tif, row, y, 0) < 0)
            {
              pixels_match = FALSE;
              break;
            }
          for (guint32 x = 0; pixels_match && x < w; x++)
            for (unsigned s = 0; s < 3; s++)
              pixels_match = row[x * 3 + s] == pixel (page, x, y, s);
        }
    }
  g_string_printf (text, "%s: pixels", label);
  CHECK (pixels_match, text->str);

  int subfiletype = -1;
  uint32_t file_type = 0;
  if (TIFFGetField (tif, TIFFTAG_SUBFILETYPE, &file_type))
    subfiletype = (int) file_type;
  g_string_printf (text, "%s: NewSubfileType %d", label, subfiletype);
  CHECK (subfiletype == page->subfiletype, text->str);

  if (page->orientation)
    {
      uint16_t orientation = 0;
      TIFFGetField (tif, TIFFTAG_ORIENTATION, &orientation);
      g_string_printf (text, "%s: orientation %u", label, orientation);
      CHECK (orientation == page->orientation, text->str);
    }
  if (page->icc)
    {
      uint32_t size = 0;
      void *data = NULL;
      gboolean match = TIFFGetField (tif, TIFFTAG_ICCPROFILE, &size, &data) &&
          size == sizeof fake_icc && !memcmp (data, fake_icc, size);
      g_string_printf (text, "%s: ICC profile bytes", label);
      CHECK (match, text->str);
    }
  if (page->pagename)
    {
      char *name = NULL;
      gboolean match = TIFFGetField (tif, TIFFTAG_PAGENAME, &name) &&
          name && !strcmp (name, page->pagename);
      g_string_printf (text, "%s: page name", label);
      CHECK (match, text->str);
    }
}

/* Verify that path holds exactly the expected directories, in order. */
static void
check_file (const char *path, const FixturePage *expected, unsigned n_expected,
            gboolean want_bigtiff, const char *label)
{
  g_autoptr(GString) text = g_string_new (label);
  TIFF *tif = TIFFOpen (path, "r");
  g_string_printf (text, "%s: opens", label);
  CHECK (tif != NULL, text->str);
  if (!tif) return;
  unsigned n = count_directories (tif);
  g_string_printf (text, "%s: %u directories", label, n);
  CHECK (n == n_expected, text->str);
  g_string_printf (text, "%s: BigTIFF %d", label, TIFFIsBigTIFF (tif) ? 1 : 0);
  CHECK (TIFFIsBigTIFF (tif) == want_bigtiff, text->str);
  for (unsigned i = 0; i < n && i < n_expected; i++)
    {
      TIFFSetDirectory (tif, i);
      g_string_printf (text, "%s: dir %u", label, i);
      check_page (tif, expected + i, text);
    }
  TIFFClose (tif);
}

static GByteArray *
file_bytes (const char *path)
{
  gchar *contents = NULL;
  gsize length = 0;
  if (!g_file_get_contents (path, &contents, &length, NULL))
    return g_byte_array_new ();
  return g_byte_array_new_take ((guint8 *) contents, length);
}

static gboolean
file_bytes_unchanged (const char *path, const GByteArray *before)
{
  gchar *contents = NULL;
  gsize length = 0;
  gboolean same;
  if (!g_file_get_contents (path, &contents, &length, NULL))
    return FALSE;
  same = length == before->len && !memcmp (contents, before->data, length);
  g_free (contents);
  return same;
}

static unsigned
staging_dir_count (void)
{
  unsigned n = 0;
  GDir *entries = g_dir_open (g_get_tmp_dir (), 0, NULL);
  if (!entries) return 0;
  for (const char *name; (name = g_dir_read_name (entries)); )
    if (g_str_has_prefix (name, "glims-tiff-")) n++;
  g_dir_close (entries);
  return n;
}

static guint16
rd16 (const char *p, gboolean little)
{
  return little ? (guint8) p[0] | ((guint8) p[1] << 8)
                : ((guint8) p[0] << 8) | (guint8) p[1];
}

static guint32
rd32 (const char *p, gboolean little)
{
  return little ? (guint8) p[0] | ((guint8) p[1] << 8) |
                  ((guint8) p[2] << 16) | ((guint32) (guint8) p[3] << 24)
                : ((guint32) (guint8) p[0] << 24) | ((guint8) p[1] << 16) |
                  ((guint8) p[2] << 8) | (guint8) p[3];
}

static void
wr32 (char *p, guint32 v, gboolean little)
{
  if (little)
    {
      p[0] = (char) v; p[1] = (char) (v >> 8);
      p[2] = (char) (v >> 16); p[3] = (char) (v >> 24);
    }
  else
    {
      p[0] = (char) (v >> 24); p[1] = (char) (v >> 16);
      p[2] = (char) (v >> 8); p[3] = (char) v;
    }
}

/* Patch a classic TIFF's directory-1 "next IFD" field to point back at
 * directory 0's offset, forming a loop. */
static void
patch_cycle (const char *path)
{
  gchar *contents = NULL;
  gsize length = 0;
  if (!g_file_get_contents (path, &contents, &length, NULL)) return;
  gboolean little = contents[0] == 'I';
  guint32 dir0 = rd32 (contents + 4, little);
  if (dir0 + 2 <= length)
    {
      guint16 count0 = rd16 (contents + dir0, little);
      guint32 dir1 = rd32 (contents + dir0 + 2 + count0 * 12, little);
      if (dir1 + 2 <= length)
        {
          guint16 count1 = rd16 (contents + dir1, little);
          char *next1 = contents + dir1 + 2 + count1 * 12;
          if (next1 + 4 <= contents + length) wr32 (next1, dir0, little);
        }
    }
  g_file_set_contents (path, contents, length, NULL);
  g_free (contents);
}

/* Run prepare on path and check the staged/not-staged outcome only. */
static gboolean
run_prepare (const char *path, gboolean expect_staged, const char *label)
{
  g_autoptr(GFile) source = g_file_new_for_path (path);
  GFile *prepared = NULL;
  g_autoptr(GError) error = NULL;
  gboolean ok = glims_tiff_import_prepare (source, &prepared, &error);
  g_autoptr(GString) text = g_string_new (NULL);
  g_string_printf (text, "%s: prepare returns", label);
  gboolean result = ok;
  CHECK (result, text->str);
  g_string_printf (text, "%s: staged %d", label, prepared != NULL);
  result = result && (prepared != NULL) == expect_staged;
  CHECK (result, text->str);
  glims_tiff_import_prepared_cleanup (prepared);
  g_clear_object (&prepared);
  return result;
}

static void
case_passthrough (const char *dir)
{
  g_autofree gchar *path = g_build_filename (dir, "plain.bin", NULL);
  g_file_set_contents (path, "this is not a tiff file", 22, NULL);
  run_prepare (path, FALSE, "non-tiff");

  g_autofree gchar *missing = g_build_filename (dir, "missing.tif", NULL);
  run_prepare (missing, FALSE, "missing file");

  g_autoptr(GFile) remote = g_file_new_for_uri ("https://example.invalid/a.tif");
  GFile *prepared = NULL;
  g_autoptr(GError) error = NULL;
  gboolean ok = glims_tiff_import_prepare (remote, &prepared, &error);
  CHECK (ok && prepared == NULL, "remote file passes through");
  g_clear_object (&prepared);

  /* Two ordinary pages, the second smaller and untagged: nothing staged. */
  g_autofree gchar *multi = g_build_filename (dir, "pages.tif", NULL);
  FixturePage pages[] = {
    { 64, 64, FILETYPE_PAGE, 11, 0, FALSE, NULL, FALSE },
    { 32, 32, -1,            29, 0, FALSE, NULL, FALSE },
  };
  CHECK (write_fixture (multi, "w", pages, 2), "ordinary multipage: fixture");
  run_prepare (multi, FALSE, "ordinary multipage");
  check_file (multi, pages, 2, FALSE, "ordinary multipage intact");
}

/* One staged case: fixture pages in, expected surviving pages out. */
static void
case_staged (const char *dir, const char *name, const char *mode,
             const FixturePage *pages, unsigned n_pages,
             const FixturePage *expected, unsigned n_expected,
             gboolean want_bigtiff, const char *label)
{
  g_autofree gchar *path = g_build_filename (dir, name, NULL);
  g_autoptr(GString) text = g_string_new (NULL);
  g_string_printf (text, "%s: fixture", label);
  gboolean ok = write_fixture (path, mode, pages, n_pages);
  CHECK (ok, text->str);
  if (!ok) return;

  GByteArray *before = file_bytes (path);
  unsigned staged_dirs_before = staging_dir_count ();
  g_autoptr(GFile) source = g_file_new_for_path (path);
  GFile *prepared = NULL;
  g_autoptr(GError) error = NULL;
  ok = glims_tiff_import_prepare (source, &prepared, &error);

  g_string_printf (text, "%s: prepare returns", label);
  CHECK (ok, text->str);
  g_string_printf (text, "%s: prepared returned%s", label,
                   error ? " with error" : "");
  CHECK (prepared != NULL && error == NULL, text->str);
  if (!prepared) { g_byte_array_free (before, TRUE); return; }

  g_autofree gchar *prepared_path = g_file_get_path (prepared);
  g_autofree gchar *base = g_path_get_basename (prepared_path);
  g_string_printf (text, "%s: basename kept as %s", label, base);
  CHECK (!strcmp (base, name) && strcmp (prepared_path, path), text->str);
  g_string_printf (text, "%s: source byte-for-byte unchanged", label);
  CHECK (file_bytes_unchanged (path, before), text->str);
  check_file (prepared_path, expected, n_expected, want_bigtiff, label);

  glims_tiff_import_prepared_cleanup (prepared);
  g_clear_object (&prepared);
  g_string_printf (text, "%s: staged file removed by cleanup", label);
  CHECK (g_access (prepared_path, F_OK) != 0, text->str);
  g_string_printf (text, "%s: staging dirs back to %u", label,
                   staged_dirs_before);
  CHECK (staging_dir_count () == staged_dirs_before, text->str);
  g_string_printf (text, "%s: source still intact after cleanup", label);
  CHECK (file_bytes_unchanged (path, before), text->str);
  g_byte_array_free (before, TRUE);
}

static void
case_thumbnails (const char *dir)
{
  /* The reported shape: a 256 px tagged thumbnail outlives a 64 px page. */
  FixturePage repro[] = {
    { 64, 64, -1, 7, ORIENTATION_BOTLEFT, TRUE, "cover", FALSE },
    { 256, 256, FILETYPE_REDUCEDIMAGE, 41, 0, FALSE, NULL, FALSE },
  };
  FixturePage repro_out[] = { repro[0] };
  case_staged (dir, "thumb.tif", "w", repro, 2, repro_out, 1, FALSE,
               "main+marked thumbnail");

  FixturePage mixed[] = {
    { 64, 64, FILETYPE_PAGE, 7, 0, FALSE, NULL, FALSE },
    { 256, 256, FILETYPE_REDUCEDIMAGE, 41, 0, FALSE, NULL, FALSE },
    { 24, 24, -1, 97, 0, TRUE, "small page", TRUE },
  };
  FixturePage mixed_out[] = { mixed[0], mixed[2] };
  case_staged (dir, "mixed.tif", "w", mixed, 3, mixed_out, 2, FALSE,
               "main+marked+ordinary");

  FixturePage first[] = {
    { 32, 32, FILETYPE_REDUCEDIMAGE, 41, 0, FALSE, NULL, FALSE },
    { 64, 64, -1, 7, 0, FALSE, NULL, FALSE },
  };
  FixturePage first_out[] = { first[1] };
  case_staged (dir, "firstmarked.tif", "w", first, 2, first_out, 1, FALSE,
               "marked first directory");

  /* The first-directory unlink rewrites the header offset: same case in
   * big-endian and in BigTIFF's 8-byte link fields. */
  case_staged (dir, "firstmarked-be.tif", "wb", first, 2, first_out, 1,
               FALSE, "marked first directory be");
  case_staged (dir, "firstmarked-big.tif", "w8", first, 2, first_out, 1,
               TRUE, "marked first directory bigtiff");

  /* Non-adjacent unlinks: reduced, main, reduced. */
  FixturePage twice[] = {
    { 32, 32, FILETYPE_REDUCEDIMAGE, 41, 0, FALSE, NULL, FALSE },
    { 64, 64, -1, 7, 0, FALSE, NULL, FALSE },
    { 16, 16, FILETYPE_REDUCEDIMAGE, 53, 0, FALSE, NULL, FALSE },
  };
  FixturePage twice_out[] = { twice[1] };
  case_staged (dir, "twice.tif", "w", twice, 3, twice_out, 1, FALSE,
               "two marked directories");

  /* FILETYPE_PAGE|FILETYPE_REDUCEDIMAGE is not exactly reduced: kept. */
  g_autofree gchar *combo = g_build_filename (dir, "combo.tif", NULL);
  FixturePage combo_pages[] = {
    { 64, 64, -1, 7, 0, FALSE, NULL, FALSE },
    { 32, 32, FILETYPE_PAGE | FILETYPE_REDUCEDIMAGE, 59, 0, FALSE, NULL, FALSE },
  };
  CHECK (write_fixture (combo, "w", combo_pages, 2), "combo: fixture");
  run_prepare (combo, FALSE, "combo alone passes through");

  FixturePage combo2[] = {
    { 64, 64, -1, 7, 0, FALSE, NULL, FALSE },
    { 32, 32, FILETYPE_PAGE | FILETYPE_REDUCEDIMAGE, 59, 0, FALSE, NULL, FALSE },
    { 256, 256, FILETYPE_REDUCEDIMAGE, 41, 0, FALSE, NULL, FALSE },
  };
  FixturePage combo2_out[] = { combo2[0], combo2[1] };
  case_staged (dir, "combo2.tif", "w", combo2, 3, combo2_out, 2, FALSE,
               "combo preserved beside unlinks");

  /* A chain of only reduced directories is left untouched. */
  g_autofree gchar *allred = g_build_filename (dir, "allred.tif", NULL);
  FixturePage allred_pages[] = {
    { 64, 64, FILETYPE_REDUCEDIMAGE, 7, 0, FALSE, NULL, FALSE },
    { 32, 32, FILETYPE_REDUCEDIMAGE, 41, 0, FALSE, NULL, FALSE },
  };
  CHECK (write_fixture (allred, "w", allred_pages, 2), "all reduced: fixture");
  run_prepare (allred, FALSE, "all reduced passes through");
  check_file (allred, allred_pages, 2, FALSE, "all reduced intact");

  /* Byte orders and BigTIFF take the same path. */
  const struct { const char *mode; const char *name; gboolean big; } orders[] = {
    { "w",   "le.tif",    FALSE },
    { "wb",  "be.tif",    FALSE },
    { "w8",  "big.tif",   TRUE  },
    { "w8b", "bigbe.tif", TRUE  },
  };
  for (unsigned i = 0; i < G_N_ELEMENTS (orders); i++)
    {
      FixturePage two[] = {
        { 64, 64, -1, 7, 0, FALSE, NULL, FALSE },
        { 48, 48, FILETYPE_REDUCEDIMAGE, 41, 0, FALSE, NULL, FALSE },
      };
      FixturePage two_out[] = { two[0] };
      case_staged (dir, orders[i].name, orders[i].mode, two, 2, two_out, 1,
                   orders[i].big, orders[i].name);
    }
}

static void
case_malformed (const char *dir)
{
  /* A file cut inside the first directory's reach is refused. */
  g_autofree gchar *trunc = g_build_filename (dir, "truncated.tif", NULL);
  FixturePage one[] = { { 64, 64, -1, 7, 0, FALSE, NULL, FALSE } };
  CHECK (write_fixture (trunc, "w", one, 1), "truncated: fixture");
  CHECK (truncate (trunc, 16) == 0, "truncated: truncated");
  g_autoptr(GFile) source = g_file_new_for_path (trunc);
  GFile *prepared = NULL;
  g_autoptr(GError) error = NULL;
  gboolean ok = glims_tiff_import_prepare (source, &prepared, &error);
  CHECK (!ok && error != NULL && prepared == NULL, "truncated: refused");
  g_clear_object (&prepared);

  /* A directory chain pointing back at itself is refused. */
  g_autofree gchar *cycle = g_build_filename (dir, "cycle.tif", NULL);
  FixturePage two[] = {
    { 64, 64, -1, 7, 0, FALSE, NULL, FALSE },
    { 32, 32, FILETYPE_PAGE, 29, 0, FALSE, NULL, FALSE },
  };
  CHECK (write_fixture (cycle, "w", two, 2), "cycle: fixture");
  patch_cycle (cycle);
  g_autoptr(GFile) source2 = g_file_new_for_path (cycle);
  GFile *prepared2 = NULL;
  g_autoptr(GError) error2 = NULL;
  ok = glims_tiff_import_prepare (source2, &prepared2, &error2);
  CHECK (!ok && error2 != NULL && prepared2 == NULL, "cycle: refused");
  g_clear_object (&prepared2);

  /* More directories than the walk bound is refused. */
  g_autofree gchar *many = g_build_filename (dir, "many.tif", NULL);
  TIFF *tif = TIFFOpen (many, "w");
  CHECK (tif != NULL, "many dirs: fixture opens");
  if (tif)
    {
      for (unsigned i = 0; i < 4100; i++)
        {
          TIFFSetField (tif, TIFFTAG_IMAGEWIDTH, 1);
          TIFFSetField (tif, TIFFTAG_IMAGELENGTH, 1);
          TIFFSetField (tif, TIFFTAG_BITSPERSAMPLE, 8);
          TIFFSetField (tif, TIFFTAG_SAMPLESPERPIXEL, 3);
          TIFFSetField (tif, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB);
          TIFFSetField (tif, TIFFTAG_COMPRESSION, COMPRESSION_NONE);
          TIFFSetField (tif, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
          TIFFSetField (tif, TIFFTAG_ROWSPERSTRIP, 1);
          TIFFSetField (tif, TIFFTAG_SUBFILETYPE, (uint32_t) FILETYPE_PAGE);
          guint8 row[3] = { 7, 8, 9 };
          TIFFWriteScanline (tif, row, 0, 0);
          TIFFWriteDirectory (tif);
        }
      TIFFClose (tif);
      g_autoptr(GFile) source3 = g_file_new_for_path (many);
      GFile *prepared3 = NULL;
      g_autoptr(GError) error3 = NULL;
      ok = glims_tiff_import_prepare (source3, &prepared3, &error3);
      CHECK (!ok && error3 != NULL && prepared3 == NULL,
             "many dirs: refused over bound");
      g_clear_object (&prepared3);
    }
}

static void
case_cleanup_guards (const char *dir)
{
  glims_tiff_import_prepared_cleanup (NULL);
  CHECK (TRUE, "cleanup of NULL is a no-op");

  /* A file outside a staging directory is not removed. */
  g_autofree gchar *path = g_build_filename (dir, "not-staged.tif", NULL);
  g_file_set_contents (path, "x", 1, NULL);
  g_autoptr(GFile) outside = g_file_new_for_path (path);
  glims_tiff_import_prepared_cleanup (outside);
  CHECK (g_access (path, F_OK) == 0, "cleanup refuses foreign files");
}

int
main (int argc, char **argv)
{
  const char *root = argc > 1 ? argv[1] : "/tmp/glims-tiff-staging";
  g_autofree gchar *dir = g_build_filename (root, "fixtures-XXXXXX", NULL);
  if (!g_mkdtemp (dir)) { fprintf (stderr, "no fixture dir\n"); return 2; }

  case_passthrough (dir);
  case_thumbnails (dir);
  case_malformed (dir);
  case_cleanup_guards (dir);

  printf ("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}

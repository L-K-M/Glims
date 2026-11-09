/*
 * Standalone facade-only tests for image_render_to_profile (facade slot
 * 132), in the style of Engine/tests/resource-duplicate-tests.c: the
 * adapter is loaded with dlopen() exactly as the app does, and only the
 * public facade in glims_engine.h is used — no GIMP/GLib types, no
 * private struct layouts, no engine object files.
 *
 *   display-render-tests LIBRARY WORK_DIR FIXTURES_DIR
 *
 * LIBRARY is a caller-provided already-built adapter (never rebuilt or
 * replaced by this harness); WORK_DIR is a throwaway directory the
 * script points HOME/XDG_CACHE_HOME/GIMP3_DIRECTORY at; FIXTURES_DIR is
 * Engine/tests/fixtures, read-only, supplying linear-rgb.icc (RGB,
 * sRGB primaries, linear TRC — an independent nonidentity destination
 * oracle) and gray.icc (non-RGB destination refusal).
 *
 * Oracles are computed independently of the production transform:
 *   - the piecewise sRGB EOTF in this file for sRGB -> linear-rgb,
 *   - direct premultiplication arithmetic for the alpha cases,
 *   - input pixels for the identity case (image assigned the same ICC as
 *     the destination).
 * The old image_render is regression-checked against the same direct
 * premultiplication arithmetic on an sRGB image. Guard bytes around the
 * written rows, stride handling, refusals (malformed/non-RGB/zero ICC,
 * overflow, stride), NOT_FOUND, and read-only invariants (dirty flag,
 * undo counts unchanged by renders) are checked too.
 *
 * Prints one line per check and exits non-zero if any check fails.
 * NOT RUN by this slice's allowed checks; scripts/test-display-render.py
 * compiles and runs it against a caller-provided library.
 */
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "glims_engine.h"

static const GlimsEngineAPI *api;
static GlimsEngine          *engine;
static int                   failures;

#define CHECK(condition, ...)                     \
  do {                                            \
    if (condition) {                              \
      printf ("ok    ");                          \
    } else {                                      \
      printf ("FAIL  ");                          \
      failures++;                                 \
    }                                             \
    printf (__VA_ARGS__);                         \
    printf ("\n");                                \
    fflush (stdout);                              \
  } while (0)

static char *
read_file (const char *dir, const char *name, size_t *length)
{
  char  path[4096];
  FILE *f;
  long  size;
  char *data;

  snprintf (path, sizeof path, "%s/%s", dir, name);
  f = fopen (path, "rb");
  if (! f)
    return NULL;
  fseek (f, 0, SEEK_END);
  size = ftell (f);
  fseek (f, 0, SEEK_SET);
  if (size <= 0)
    {
      fclose (f);
      return NULL;
    }
  data = malloc ((size_t) size);
  if (! data || fread (data, 1, (size_t) size, f) != (size_t) size)
    {
      free (data);
      fclose (f);
      return NULL;
    }
  fclose (f);
  *length = (size_t) size;
  return data;
}

static void
take_error (char *error)
{
  if (error)
    api->free_string (error);
}

/* The standard piecewise sRGB EOTF, independent of any production code. */
static double
srgb_decode (double c)
{
  return c <= 0.04045 ? c / 12.92 : pow ((c + 0.055) / 1.055, 2.4);
}

/* Direct premultiply oracle: premultiplied u8 of a straight u8 pixel. */
static int
expect_premul (int c, int a)
{
  return (int) lround (c * (double) a / 255.0);
}

/* Test image: 4 x 2, straight RGBA. */
#define TW 4
#define TH 2
static const uint8_t test_pixels[TW * TH * 4] = {
  200, 100,  50, 255,   10,  20, 240, 255,   128, 128, 128, 128,   255,   0,   0,   0,
    1,   2,   3, 255,  255, 255, 255,  64,     0,   0,   0,   1,   77,  88,  99, 200
};

static GlimsImageID
make_test_image (void)
{
  GlimsImageID image = 0;
  char        *error = NULL;
  GlimsStatus  status = api->image_from_pixels (engine, TW, TH, test_pixels,
                                                sizeof test_pixels, &image, &error);
  CHECK (status == GLIMS_STATUS_OK && image != 0, "image_from_pixels (%s)",
         status == GLIMS_STATUS_OK ? "ok" : (error ? error : "failed"));
  take_error (error);
  return image;
}

int
main (int argc, char **argv)
{
  void            *library;
  GlimsEngineGetAPIFunction get_api;
  GlimsEngineConfig config = { 0 };
  char            *error = NULL;
  char             user_dir[4096], cache_dir[4096];
  char            *linear_icc, *gray_icc;
  size_t           linear_len = 0, gray_len = 0;
  GlimsImageID     image;
  GlimsImageInfo   info_before, info_after;
  GlimsUndoInfo    undo_before, undo_after;
  uint8_t          out[TW * TH * 4 + 64];
  uint8_t          guard_out[TH * 16];
  GlimsRect        full = { 0, 0, TW, TH };
  int              i;

  if (argc != 4)
    {
      fprintf (stderr, "usage: %s LIBRARY WORK_DIR FIXTURES_DIR\n", argv[0]);
      return 2;
    }

  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (! library)
    {
      fprintf (stderr, "dlopen: %s\n", dlerror ());
      return 2;
    }
  get_api = (GlimsEngineGetAPIFunction) dlsym (library, "glims_engine_get_api");
  if (! get_api)
    {
      fprintf (stderr, "dlsym: %s\n", dlerror ());
      return 2;
    }
  api = get_api (GLIMS_ENGINE_API_VERSION);
  if (! api || api->struct_size < sizeof (GlimsEngineAPI) ||
      ! api->image_render_to_profile)
    {
      fprintf (stderr, "the library does not serve slot 132\n");
      return 2;
    }

  snprintf (user_dir, sizeof user_dir, "%s/user", argv[2]);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", argv[2]);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "start: %s\n", error ? error : "unknown");
      take_error (error);
      return 2;
    }

  linear_icc = read_file (argv[3], "linear-rgb.icc", &linear_len);
  gray_icc   = read_file (argv[3], "gray.icc", &gray_len);
  CHECK (linear_icc && linear_len > 0, "linear-rgb.icc fixture loads");
  CHECK (gray_icc && gray_len > 0, "gray.icc fixture loads");
  if (! linear_icc || ! gray_icc)
    goto done;

  image = make_test_image ();
  if (! image)
    goto done;

  api->image_info (engine, image, &info_before);
  api->image_undo_info (engine, image, &undo_before);

  /* --- Old renderer regression: sRGB premultiplied u8, guard bytes --- */
  /* (renders and refusals must not change dirty/history state: checked
   *   against info_before/undo_before right after the refusal block) */
  memset (guard_out, 0xAA, sizeof guard_out);
  {
    GlimsStatus status = api->image_render (engine, image, 1.0, full, guard_out, 16);
    int ok = status == GLIMS_STATUS_OK;
    for (i = 0; ok && i < TH; i++)
      {
        int p;
        for (p = 0; p < TW; p++)
          {
            const uint8_t *src = test_pixels + (i * TW + p) * 4;
            const uint8_t *dst = guard_out + i * 16 + p * 4;
            ok = abs (dst[0] - expect_premul (src[0], src[3])) <= 1 &&
                 abs (dst[1] - expect_premul (src[1], src[3])) <= 1 &&
                 abs (dst[2] - expect_premul (src[2], src[3])) <= 1 &&
                 dst[3] == src[3];
          }
        /* stride 16, width 4: bytes 16..31 of each row are guard bytes */
        ok = ok && guard_out[i * 16 + TW * 4] == 0xAA &&
             guard_out[i * 16 + 15] == 0xAA;
      }
    CHECK (ok, "image_render still returns premultiplied sRGB u8, stride respected, guards intact");
  }

  /* --- Slot 132: sRGB image -> linear-rgb destination, independent
   *     EOTF oracle, premultiplied, stride + guard bytes --- */
  memset (guard_out, 0xAA, sizeof guard_out);
  {
    GlimsStatus status = api->image_render_to_profile (engine, image, 1.0, full,
                                                       (const uint8_t *) linear_icc, linear_len,
                                                       guard_out, 16, &error);
    int ok = status == GLIMS_STATUS_OK;
    take_error (error); error = NULL;
    for (i = 0; ok && i < TH; i++)
      {
        int p;
        for (p = 0; p < TW; p++)
          {
            const uint8_t *src = test_pixels + (i * TW + p) * 4;
            const uint8_t *dst = guard_out + i * 16 + p * 4;
            double a = src[3] / 255.0;
            int er = (int) lround (srgb_decode (src[0] / 255.0) * 255.0 * a);
            int eg = (int) lround (srgb_decode (src[1] / 255.0) * 255.0 * a);
            int eb = (int) lround (srgb_decode (src[2] / 255.0) * 255.0 * a);
            /* linear TRC destination: premultiplied straight-then-quantized
             * value within LUT rounding tolerance */
            ok = abs (dst[0] - er) <= 2 && abs (dst[1] - eg) <= 2 &&
                 abs (dst[2] - eb) <= 2 && dst[3] == src[3];
          }
        ok = ok && guard_out[i * 16 + TW * 4] == 0xAA &&
             guard_out[i * 16 + 15] == 0xAA;
      }
    CHECK (ok, "render_to_profile(linear-rgb) matches independent sRGB-EOTF+premultiply oracle");
  }

  /* --- Refusals --- */
  {
    GlimsStatus s;
    s = api->image_render_to_profile (engine, image, 1.0, full, NULL, linear_len, out, TW * 4, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT, "NULL ICC refused INVALID_ARGUMENT (got %d)", (int) s);
    s = api->image_render_to_profile (engine, image, 1.0, full,
                                       (const uint8_t *) linear_icc, 0, out, TW * 4, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT, "zero-length ICC refused INVALID_ARGUMENT (got %d)", (int) s);
    {
      static const char junk[] = "Glims: this is not an ICC profile at all........";
      s = api->image_render_to_profile (engine, image, 1.0, full,
                                         (const uint8_t *) junk, sizeof junk - 1, out, TW * 4, &error);
      CHECK (s == GLIMS_STATUS_FAILED && error != NULL,
             "malformed ICC refused FAILED with error (got %d)", (int) s);
      take_error (error); error = NULL;
    }
    s = api->image_render_to_profile (engine, image, 1.0, full,
                                       (const uint8_t *) gray_icc, gray_len, out, TW * 4, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_UNSUPPORTED, "non-RGB (gray) ICC refused UNSUPPORTED (got %d)", (int) s);
    s = api->image_render_to_profile (engine, image, 1.0,
                                       (GlimsRect) { 0, 0, 0x40000000, 1 },
                                       (const uint8_t *) linear_icc, linear_len, out, 16, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT, "overflowing area refused INVALID_ARGUMENT (got %d)", (int) s);
    s = api->image_render_to_profile (engine, image, 1.0, full,
                                       (const uint8_t *) linear_icc, linear_len, out, 3, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT, "stride < width*4 refused INVALID_ARGUMENT (got %d)", (int) s);
    s = api->image_render_to_profile (engine, 424242, 1.0, full,
                                       (const uint8_t *) linear_icc, linear_len, out, TW * 4, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_NOT_FOUND, "unknown image NOT_FOUND (got %d)", (int) s);
    s = api->image_render_to_profile (engine, image, 0.0, full,
                                       (const uint8_t *) linear_icc, linear_len, out, TW * 4, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT, "scale 0 refused INVALID_ARGUMENT (got %d)", (int) s);
  }

  /* Renders and refusals so far must have changed nothing. */
  api->image_info (engine, image, &info_after);
  api->image_undo_info (engine, image, &undo_after);
  CHECK (info_after.dirty == info_before.dirty &&
         undo_after.undo_count == undo_before.undo_count &&
         undo_after.redo_count == undo_before.redo_count,
         "dirty flag and undo/redo counts unchanged by renders and refusals");

  /* --- Identity case: image assigned linear-rgb.icc, destination the
   *     same ICC: output must equal the input premultiplied --- */
  {
    char path[4096];
    GlimsStatus s;
    snprintf (path, sizeof path, "%s/linear-rgb.icc", argv[3]);
    s = api->image_assign_profile (engine, image, path, &error);
    CHECK (s == GLIMS_STATUS_OK, "image_assign_profile(linear-rgb.icc) (got %d %s)", (int) s,
           error ? error : "");
    take_error (error); error = NULL;

    memset (out, 0, sizeof out);
    s = api->image_render_to_profile (engine, image, 1.0, full,
                                      (const uint8_t *) linear_icc, linear_len,
                                      out, TW * 4, &error);
    take_error (error); error = NULL;
    {
      int ok = s == GLIMS_STATUS_OK;
      for (i = 0; ok && i < TW * TH; i++)
        {
          const uint8_t *src = test_pixels + i * 4;
          const uint8_t *dst = out + i * 4;
          ok = abs (dst[0] - expect_premul (src[0], src[3])) <= 1 &&
               abs (dst[1] - expect_premul (src[1], src[3])) <= 1 &&
               abs (dst[2] - expect_premul (src[2], src[3])) <= 1 &&
               dst[3] == src[3];
        }
      CHECK (ok, "identity destination returns input premultiplied within rounding (incl. alpha 0/partial)");
    }

    /* The assignment itself is an undo step, so re-baseline here; the
     * renders after this point must not change state again. */
    api->image_info (engine, image, &info_before);
    api->image_undo_info (engine, image, &undo_before);
  }

  /* --- Gray source: convert to grayscale, render to RGB destination --- */
  {
    GlimsImageID gray_image;
    GlimsStatus  s;
    uint8_t      gray_out[2 * 2 * 4];
    gray_image = make_test_image ();
    s = api->image_convert_mode (engine, gray_image, GLIMS_COLOR_MODE_GRAYSCALE, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_OK, "convert to grayscale (got %d)", (int) s);
    s = api->image_render_to_profile (engine, gray_image, 1.0, (GlimsRect) { 0, 0, 2, 2 },
                                      (const uint8_t *) linear_icc, linear_len,
                                      gray_out, 2 * 4, &error);
    take_error (error); error = NULL;
    {
      int ok = s == GLIMS_STATUS_OK;
      for (i = 0; ok && i < 4; i++)
        ok = abs (gray_out[i * 4 + 0] - gray_out[i * 4 + 1]) <= 2 &&
             abs (gray_out[i * 4 + 1] - gray_out[i * 4 + 2]) <= 2;
      CHECK (ok, "grayscale source renders to RGB destination with equal channels (got %d)", (int) s);
    }
    api->image_close (engine, gray_image);
  }

  /* --- Read-only invariants: the remaining renders changed no state --- */
  api->image_info (engine, image, &info_after);
  api->image_undo_info (engine, image, &undo_after);
  CHECK (info_after.dirty == info_before.dirty &&
         undo_after.undo_count == undo_before.undo_count &&
         undo_after.redo_count == undo_before.redo_count,
         "dirty flag and undo/redo counts unchanged by profile-destination renders");

  api->image_close (engine, image);

done:
  api->stop (engine);
  free (linear_icc);
  free (gray_icc);

  if (failures)
    printf ("%d check(s) FAILED\n", failures);
  else
    printf ("all checks passed\n");
  return failures ? 1 : 0;
}

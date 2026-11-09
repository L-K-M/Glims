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
/* Independent 3x3 algebra, indexed by both dimensions so no pointer
 * arithmetic crosses a row-array object's bounds. */
static void
inverse3 (const double m[3][3], double out[3][3])
{
  double d = m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])
           - m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])
           + m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]);
  out[0][0]=(m[1][1]*m[2][2]-m[1][2]*m[2][1])/d;
  out[0][1]=(m[0][2]*m[2][1]-m[0][1]*m[2][2])/d;
  out[0][2]=(m[0][1]*m[1][2]-m[0][2]*m[1][1])/d;
  out[1][0]=(m[1][2]*m[2][0]-m[1][0]*m[2][2])/d;
  out[1][1]=(m[0][0]*m[2][2]-m[0][2]*m[2][0])/d;
  out[1][2]=(m[0][2]*m[1][0]-m[0][0]*m[1][2])/d;
  out[2][0]=(m[1][0]*m[2][1]-m[1][1]*m[2][0])/d;
  out[2][1]=(m[0][1]*m[2][0]-m[0][0]*m[2][1])/d;
  out[2][2]=(m[0][0]*m[1][1]-m[0][1]*m[1][0])/d;
}

static void
rgb_xyz_matrix (const double p[3][2], double wx, double wy, double out[3][3])
{
  double inv[3][3], w[3] = {wx/wy, 1, (1-wx-wy)/wy}, scale[3];
  for (int col=0; col<3; col++) {
    out[0][col]=p[col][0]/p[col][1]; out[1][col]=1;
    out[2][col]=(1-p[col][0]-p[col][1])/p[col][1];
  }
  inverse3 (out, inv);
  for (int row=0; row<3; row++)
    scale[row]=inv[row][0]*w[0]+inv[row][1]*w[1]+inv[row][2]*w[2];
  for (int row=0; row<3; row++) for (int col=0; col<3; col++) out[row][col]*=scale[col];
}

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
  uint8_t          guard_out[TH * 32];
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
    GlimsStatus status = api->image_render (engine, image, 1.0, full, guard_out, 32);
    int ok = status == GLIMS_STATUS_OK;
    for (i = 0; ok && i < TH; i++)
      {
        int p;
        for (p = 0; p < TW; p++)
          {
            const uint8_t *src = test_pixels + (i * TW + p) * 4;
            const uint8_t *dst = guard_out + i * 32 + p * 4;
            ok = abs (dst[0] - expect_premul (src[0], src[3])) <= 1 &&
                 abs (dst[1] - expect_premul (src[1], src[3])) <= 1 &&
                 abs (dst[2] - expect_premul (src[2], src[3])) <= 1 &&
                 dst[3] == src[3];
          }
        /* stride 32, width 4: bytes 16..31 are row padding. */
        for (int padding = TW * 4; padding < 32; padding++)
          ok = ok && guard_out[i * 32 + padding] == 0xAA;
      }
    CHECK (ok, "image_render still returns premultiplied sRGB u8, stride respected, guards intact");
  }

  /* --- Slot 132: sRGB image -> linear-rgb destination, independent
   *     EOTF oracle, premultiplied, stride + guard bytes --- */
  memset (guard_out, 0xAA, sizeof guard_out);
  {
    GlimsStatus status = api->image_render_to_profile (engine, image, 1.0, full,
                                                       (const uint8_t *) linear_icc, linear_len,
                                                       guard_out, 32, &error);
    int ok = status == GLIMS_STATUS_OK;
    take_error (error); error = NULL;
    for (i = 0; ok && i < TH; i++)
      {
        int p;
        for (p = 0; p < TW; p++)
          {
            const uint8_t *src = test_pixels + (i * TW + p) * 4;
            const uint8_t *dst = guard_out + i * 32 + p * 4;
            double a = src[3] / 255.0;
            int er = (int) lround (srgb_decode (src[0] / 255.0) * 255.0 * a);
            int eg = (int) lround (srgb_decode (src[1] / 255.0) * 255.0 * a);
            int eb = (int) lround (srgb_decode (src[2] / 255.0) * 255.0 * a);
            /* linear TRC destination: premultiplied straight-then-quantized
             * value within LUT rounding tolerance */
            ok = abs (dst[0] - er) <= 2 && abs (dst[1] - eg) <= 2 &&
                 abs (dst[2] - eb) <= 2 && dst[3] == src[3];
          }
        for (int padding = TW * 4; padding < 32; padding++)
          ok = ok && guard_out[i * 32 + padding] == 0xAA;
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
    s = api->image_render_to_profile (engine, image, 1e-300, (GlimsRect) { 1, 0, 2, 2 },
                                       (const uint8_t *) linear_icc, linear_len, out, 8, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT, "underflow-scale refused before GEGL sampling (got %d)", (int) s);
    s = api->image_render (engine, image, 1e-300, (GlimsRect) { 1, 0, 2, 2 }, out, 8);
    CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT, "legacy renderer also refuses underflow-scale (got %d)", (int) s);
    s = api->image_render_to_profile (engine, image, 0.5, (GlimsRect) { 67108864, 0, 1, 1 },
                                       (const uint8_t *) linear_icc, linear_len, out, 4, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT, "unsafe divided coordinates refuse before GEGL sampling (got %d)", (int) s);

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

  /* --- Wide-gamut pixel regression (public facade only) --- */
  {
    /* Independent matrix math from literal xyY primaries + D65 white.
     * D65 source/destination => PCS chromatic adaptation cancels. */
    static const double wp[3][2] = {{0.708,0.292},{0.170,0.797},{0.131,0.046}};
    static const double sp[3][2] = {{0.64,0.33},{0.30,0.60},{0.15,0.06}};
    static const double D65x=0.3127, D65y=0.3290;
    /* 4x2 straight RGBA u8: saturated wide primaries (outside sRGB), mixed
     * in-gamut color, alpha 0/partial/opaque and nonzero-channel mixtures. */
    static const uint8_t wpix[TW*TH*4] = {
      255,0,0,255,  0,255,0,255,  0,0,255,255,  153,51,26,128,
      255,255,255,255, 77,88,99,200, 40,200,30,0, 12,34,56,1
    };
    char *wide_icc = NULL; size_t wide_len = 0;
    GlimsImageID wimg = 0; char wpath[4096];
    GlimsStatus ws; GlimsImageInfo wi; GlimsUndoInfo wu;
    uint8_t wout[TH*32]; GlimsRect wf = {0,0,TW,TH};
    double Mw[3][3], Ms[3][3], Mi[3][3], Mws[3][3];
    int ci, cj, ck;

    wide_icc = read_file (argv[3], "wide-linear-rgb.icc", &wide_len);
    CHECK (wide_icc && wide_len > 0, "wide-linear-rgb.icc fixture loads");
    if (! wide_icc)
      goto wide_done;

    rgb_xyz_matrix (wp, D65x, D65y, Mw);
    rgb_xyz_matrix (sp, D65x, D65y, Ms);
    inverse3 (Ms, Mi);
    for (ci=0; ci<3; ci++) for (cj=0; cj<3; cj++) {
      Mws[ci][cj]=0;
      for (ck=0; ck<3; ck++) Mws[ci][cj]+=Mi[ci][ck]*Mw[ck][cj];
    }
    /* Sensitivity: saturated wide red primary leaves linear sRGB gamut
     * (R>1, G<0, B<0), so a forced sRGB-u8 intermediate clips unrecoverably. */
    CHECK (Mws[0][0] > 1.02 && Mws[1][0] < -0.02 && Mws[2][0] < -0.01,
           "wide red maps outside linear sRGB gamut (independent matrix)");
    CHECK (Mws[0][1] < -0.02 && Mws[1][1] > 1.02,
           "wide green maps outside linear sRGB gamut (independent matrix)");
    CHECK (Mws[0][2] < -0.02 && Mws[2][2] > 1.02,
           "wide blue maps outside linear sRGB gamut (independent matrix)");

    ws = api->image_from_pixels (engine, TW, TH, wpix, sizeof wpix, &wimg, &error);
    CHECK (ws == GLIMS_STATUS_OK && wimg != 0, "wide image_from_pixels (%s)", error ? error : "ok");
    take_error (error); error = NULL;
    snprintf (wpath, sizeof wpath, "%s/wide-linear-rgb.icc", argv[3]);
    ws = api->image_assign_profile (engine, wimg, wpath, &error);
    CHECK (ws == GLIMS_STATUS_OK, "image_assign_profile(wide-linear-rgb.icc) (%s)", error ? error : "ok");
    take_error (error); error = NULL;
    api->image_info (engine, wimg, &wi);
    api->image_undo_info (engine, wimg, &wu);

    /* Wide -> same wide: direct premultiplied bytes (no conversion). */
    memset (wout, 0xA5, sizeof wout);
    ws = api->image_render_to_profile (engine, wimg, 1.0, wf,
                                       (const uint8_t *) wide_icc, wide_len,
                                       wout, 32, &error);
    take_error (error); error = NULL;
    /* Negative control, enabled only by the runtime owner: intentionally
     * lose gamut through the real legacy sRGB-u8 path, then convert those
     * clipped bytes back to wide RGB. Only this identity case is replaced. */
    if (getenv ("GLIMS_DISPLAY_TEST_SRGB_INTERMEDIATE")) {
      uint8_t clipped[TW*TH*4], straight[TW*TH*4];
      GlimsImageID intermediate=0;
      ws=api->image_render (engine, wimg, 1.0, wf, clipped, TW*4);
      if (ws==GLIMS_STATUS_OK) {
        for (int p=0; p<TW*TH; p++) {
          unsigned a=clipped[p*4+3]; straight[p*4+3]=(uint8_t)a;
          for (int c=0; c<3; c++)
            straight[p*4+c]=a ? (uint8_t) fmin(255, lround(clipped[p*4+c]*255.0/a)) : 0;
        }
        ws=api->image_from_pixels (engine, TW, TH, straight, sizeof straight, &intermediate, &error);
        take_error (error); error=NULL;
        if (ws==GLIMS_STATUS_OK) {
          ws=api->image_render_to_profile (engine, intermediate, 1.0, wf,
                                          (const uint8_t *)wide_icc, wide_len, wout, 32, &error);
          take_error (error); error=NULL;
        }
      }
      if (intermediate) api->image_close (engine, intermediate);
    }
    {
      int ok = ws == GLIMS_STATUS_OK;
      for (i = 0; ok && i < TH; i++) {
        int p;
        for (p = 0; p < TW; p++) {
          const uint8_t *s = wpix + (i*TW+p)*4; uint8_t *d = wout + i*32 + p*4;
          ok = ok && abs(d[0]-expect_premul(s[0],s[3]))<=1 && abs(d[1]-expect_premul(s[1],s[3]))<=1 &&
               abs(d[2]-expect_premul(s[2],s[3]))<=1 && d[3]==s[3];
        }
        for (int pad = TW*4; pad < 32; pad++) ok = ok && wout[i*32+pad] == 0xA5;
      }
      CHECK (ok, "wide->wide render returns direct premultiplied input, stride/guards intact");
    }
    {
      GlimsImageInfo wa; GlimsUndoInfo wb;
      api->image_info (engine, wimg, &wa); api->image_undo_info (engine, wimg, &wb);
      CHECK (wa.dirty == wi.dirty && wb.undo_count == wu.undo_count && wb.redo_count == wu.redo_count,
             "wide->wide render preserves post-assign dirty/undo state");
    }

    /* Wide -> linear-rgb.icc (sRGB primaries, D65, linear TRC):
     * expected from inv(M_srgb)*M_wide, clamp to u8 contract, premultiply.
     * ICC coefficient quantization/rounding tolerance: <=2 u8 (well below
     * clipping loss; wide red/green/blue clip to a channel at 0 or 255). */
    memset (wout, 0xA5, sizeof wout);
    ws = api->image_render_to_profile (engine, wimg, 1.0, wf,
                                       (const uint8_t *) linear_icc, linear_len,
                                       wout, 32, &error);
    take_error (error); error = NULL;
    {
      int ok = ws == GLIMS_STATUS_OK;
      for (i = 0; ok && i < TH; i++) {
        int p;
        for (p = 0; p < TW; p++) {
          const uint8_t *s = wpix + (i*TW+p)*4; uint8_t *d = wout + i*32 + p*4;
          double a=s[3]/255.0, rgb[3]={s[0]/255.0,s[1]/255.0,s[2]/255.0}, o[3]; int er[3]; int c;
          for(c=0;c<3;c++) o[c]=Mws[c][0]*rgb[0]+Mws[c][1]*rgb[1]+Mws[c][2]*rgb[2];
          for(c=0;c<3;c++){ double v=o[c]; if(v<0) v=0; if(v>1) v=1; er[c]=(int)lround(v*255.0*a); }
          ok = ok && abs(d[0]-er[0])<=2 && abs(d[1]-er[1])<=2 && abs(d[2]-er[2])<=2 && d[3]==s[3];
        }
        for (int pad = TW*4; pad < 32; pad++) ok = ok && wout[i*32+pad] == 0xA5;
      }
      CHECK (ok, "wide->linear-sRGB render matches independent xyY matrix oracle (tol<=2), guards intact");
    }
    /* The narrow destination legitimately clips saturated primaries. This
     * check distinguishes a nonidentity mapping from relabelled wide bytes;
     * gamut preservation itself is proved by the wide->wide identity case. */
    {
      int ok = ws == GLIMS_STATUS_OK;
      /* wide red/green/blue (rows 0, pixels 0-2): identity premul would keep
       * the saturated channel at 255 with others 0; correct output clamps the
       * independent matrix result (still saturated primary, other channels 0). */
      ok = ok && wout[0*32+0*4+0] >= 253 && wout[0*32+0*4+1] <= 2  && wout[0*32+0*4+2] <= 2;
      ok = ok && wout[0*32+1*4+0] <= 2   && wout[0*32+1*4+1] >= 253 && wout[0*32+1*4+2] <= 2;
      ok = ok && wout[0*32+2*4+0] <= 2   && wout[0*32+2*4+1] <= 2  && wout[0*32+2*4+2] >= 253;
      /* mixed wide sample (153,51,26,128, index 3): matrix maps it to a
       * different color in linear sRGB primaries, so output differs materially
       * from identity premultiplication of the wide-encoded bytes. */
      {
        const uint8_t *s = wpix + 3*4; const uint8_t *d = wout + 3*4;
        int idr=expect_premul(s[0],s[3]), idg=expect_premul(s[1],s[3]), idb=expect_premul(s[2],s[3]);
        ok = ok && (abs(d[0]-idr)>4 || abs(d[1]-idg)>4 || abs(d[2]-idb)>4);
      }
      CHECK (ok, "wide-to-narrow mapping differs from relabelled identity for mixed samples");
    }
    {
      GlimsImageInfo wa; GlimsUndoInfo wb;
      api->image_info (engine, wimg, &wa); api->image_undo_info (engine, wimg, &wb);
      CHECK (wa.dirty == wi.dirty && wb.undo_count == wu.undo_count && wb.redo_count == wu.redo_count,
             "wide renders preserve post-assign dirty/undo state (read-only)");
    }

    api->image_close (engine, wimg);
  wide_done:
    free (wide_icc);
  }

  /* A narrow request spans two full 256-row chunks and one cached pixel.
   * Warm the old final pixel, mutate the projection, then read the entire
   * column through both APIs: no stale final-row cache and no tall-stack call. */
  {
    uint8_t white[513 * 4], column[513 * 4];
    GlimsImageID narrow = 0;
    memset (white, 255, sizeof white);
    GlimsStatus s = api->image_from_pixels (engine, 1, 513, white, sizeof white, &narrow, &error);
    take_error (error); error = NULL;
    CHECK (s == GLIMS_STATUS_OK && narrow != 0, "narrow-column fixture creates");
    if (s == GLIMS_STATUS_OK && narrow != 0)
      {
        GlimsLayerInfo layer;
        int32_t count = 0;
        s = api->image_layers (engine, narrow, &layer, 1, &count);
        CHECK (s == GLIMS_STATUS_OK && count == 1, "narrow-column fixture owns one layer");
        if (s == GLIMS_STATUS_OK && count == 1)
          {
            s = api->image_render (engine, narrow, 1.0, (GlimsRect) { 0, 512, 1, 1 }, column, 4);
            CHECK (s == GLIMS_STATUS_OK && column[3] == 255, "final column pixel is cached before mutation");
            GlimsLayerChange change = { 0 };
            change.struct_size = sizeof change;
            change.properties = GLIMS_LAYER_OPACITY;
            change.opacity = 0;
            s = api->layer_change (engine, narrow, layer.id, &change, &error);
            take_error (error); error = NULL;
            CHECK (s == GLIMS_STATUS_OK, "narrow-column projection mutation succeeds");
            memset (column, 0xAA, sizeof column);
            s = api->image_render_to_profile (engine, narrow, 1.0, (GlimsRect) { 0, 0, 1, 513 },
                                              (const uint8_t *) linear_icc, linear_len, column, 4, &error);
            take_error (error); error = NULL;
            int ok = s == GLIMS_STATUS_OK;
            for (int p = 0; ok && p < 513 * 4; p++) ok = column[p] == 0;
            CHECK (ok, "profile narrow-column chunks include fresh transparent final pixel");
            memset (column, 0xAA, sizeof column);
            s = api->image_render (engine, narrow, 1.0, (GlimsRect) { 0, 0, 1, 513 }, column, 4);
            ok = s == GLIMS_STATUS_OK;
            for (int p = 0; ok && p < 513 * 4; p++) ok = column[p] == 0;
            CHECK (ok, "legacy narrow-column chunks include fresh transparent final pixel");
          }
        api->image_close (engine, narrow);
      }
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

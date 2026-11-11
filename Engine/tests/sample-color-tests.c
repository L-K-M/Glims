/* Native contract fixture for facade slot174, image_sample_color.
 *
 * Test-only harness. The subject is the public API only:
 * api->image_sample_color. The expected values come from an independent
 * native oracle run on the engine thread through glims_engine_call:
 * GimpPickable reads on the image projection (gimp_pickable_flush +
 * gimp_pickable_get_pixel_at / gimp_pickable_get_color_at) converted to
 * straight nonlinear sRGB doubles. The oracle never calls
 * glims_image_sample_color or glims_projection_prepare_read.
 *
 * Seeded content comes from the facade fill over a known fractional
 * 32-bit-float image, with partial alpha, plus gray, indexed and
 * high-precision linear/nonlinear conversions. Refusals (outside canvas,
 * unknown image, NULL out, stopped-engine dispatch) must zero the output
 * and clear the optional error pointer. Native NaN/infinity/alpha-out-of-
 * range pixels are injected through a small fixture-side native buffer
 * write; FAILED is required only when the independent projection retains
 * invalid components. Native sanitization is reported as unreachable coverage. A locally generated Display-P3
 * ICC (LittleCMS, already linked by the engine) exercises extended finite
 * out-of-gamut RGB against the sRGB oracle.
 *
 * All native engine objects are touched only on the engine thread.
 */
#include "engine-private.h"
#include "core/gimp.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#include "core/gimpprojection.h"
#include <lcms2.h>
#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

/* Slot174 is the tail slot right after slot173's stroke_continue_v2. */
G_STATIC_ASSERT (offsetof (GlimsEngineAPI, image_sample_color) ==
                 offsetof (GlimsEngineAPI, stroke_continue_v2) +
                 sizeof (((GlimsEngineAPI *) 0)->stroke_continue_v2));

#define W 16
#define H 12
#define LAYER_BYTES (W * H * 4 * sizeof (gdouble))

static const GlimsEngineAPI *api;
static int failures;
static guint checks;
static const gchar *work_dir;
static gchar p3_profile_path[4096];

#define CHECK(c, text) do { \
  gboolean ok_ = (c); checks++; \
  printf ("%s sample-color: %s\n", ok_ ? "ok  " : "FAIL", text); \
  if (!ok_) failures++; fflush (stdout); \
} while (0)
#define NEED(c, text) do { \
  gboolean need_ok_ = (c); CHECK (need_ok_, text); \
  if (!need_ok_) goto cleanup; \
} while (0)

static void
clear_error (char **error)
{
  if (*error && *error != (char *) 0x1) api->free_string (*error);
  *error = NULL;
}

typedef struct {
  GlimsEngine *engine;
  GlimsImageID id;
  GimpImage *image;   /* borrowed from the adapter */
  GimpLayer *layer;   /* borrowed from the image */
  GlimsItemID layer_id;
} Fixture;

/* ---- Fixture seeding through the facade ------------------------------- */

static gboolean
fixture_open (GlimsEngine *engine, Fixture *f)
{
  memset (f, 0, sizeof *f);
  f->engine = engine;
  if (api->image_new (engine, W, H, &f->id, NULL) != GLIMS_STATUS_OK)
    return FALSE;
  GlimsOpenImage *open = glims_lookup_image (engine, f->id);
  if (! open) return FALSE;
  f->image = open->image;
  /* The facade's initial white Background would make the projection opaque.
   * Remove it during fixture setup so partial-alpha tests observe the layer. */
  GList *initial = gimp_image_get_layer_list (f->image);
  for (GList *item = initial; item; item = item->next)
    gimp_image_remove_layer (f->image, item->data, FALSE, NULL);
  g_list_free (initial);
  f->layer = gimp_layer_new (f->image, W, H,
                             gimp_image_get_layer_format (f->image, TRUE),
                             "sample target", 1.0, GIMP_LAYER_MODE_NORMAL);
  if (! f->layer) return FALSE;
  if (! gimp_image_add_layer (f->image, f->layer, NULL, 0, FALSE))
    {
      g_object_unref (f->layer);
      f->layer = NULL;
      return FALSE;
    }
  f->layer_id = gimp_item_get_id (GIMP_ITEM (f->layer));
  return api->layer_select (engine, f->id, f->layer_id) == GLIMS_STATUS_OK;
}

static void
fixture_close (Fixture *f)
{
  if (f->id) api->image_close (f->engine, f->id);
  f->id = 0;
  f->image = NULL;
  f->layer = NULL;
}

static GlimsStatus
facade_fill (Fixture *f, GlimsColor color, double opacity, char **error)
{
  GlimsFillSettings settings = {
    .struct_size = sizeof settings,
    .mode = GLIMS_FILL_SELECTION,
    .color = color,
    .opacity = opacity,
    .threshold = 0.0,
    .sample_merged = FALSE,
    .antialias = FALSE
  };
  return api->fill (f->engine, f->id, (GlimsPoint) {0, 0}, &settings, error);
}

/* ---- Independent native oracle (never the facade read path) ----------- */

static gboolean
oracle_pickable_pixel (GimpImage *image, gint x, gint y, gdouble rgba[4])
{
  GimpPickable *pickable = GIMP_PICKABLE (gimp_image_get_projection (image));
  gimp_pickable_flush (pickable);
  return gimp_pickable_get_pixel_at (pickable, x, y,
                                      babl_format ("R'G'B'A double"), rgba);
}

static gboolean
oracle_pickable_color (GimpImage *image, gint x, gint y, gdouble rgba[4])
{
  GimpPickable *pickable = GIMP_PICKABLE (gimp_image_get_projection (image));
  gimp_pickable_flush (pickable);
  GeglColor *color = gimp_pickable_get_color_at (pickable, x, y);
  if (! color) return FALSE;
  gegl_color_get_pixel (color, babl_format ("R'G'B'A double"), rgba);
  g_object_unref (color);
  return TRUE;
}

static gboolean
doubles_match (const gdouble a[4], const gdouble b[4], gdouble eps)
{
  for (gint i = 0; i < 4; i++)
    if (! isfinite (a[i]) || ! isfinite (b[i]) ||
        fabs (a[i] - b[i]) > eps * (1.0 + fabs (b[i])))
      return FALSE;
  return TRUE;
}

static gboolean
sampled_matches_oracles (GimpImage *image, gint x, gint y,
                         const GlimsSampledColor *sampled, gdouble eps,
                         gdouble pixel_rgba[4], gdouble color_rgba[4])
{
  if (! oracle_pickable_pixel (image, x, y, pixel_rgba)) return FALSE;
  if (! oracle_pickable_color (image, x, y, color_rgba)) return FALSE;
  const gdouble got[4] = {sampled->red, sampled->green, sampled->blue, sampled->alpha};
  return doubles_match (got, pixel_rgba, eps) && doubles_match (got, color_rgba, eps);
}

/* Fixture-side inspection of the stored (straight) layer pixel. */
static gboolean
layer_pixel_straight (Fixture *f, gint x, gint y, gdouble rgba[4])
{
  gegl_buffer_get (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->layer)),
                   GEGL_RECTANGLE (x, y, 1, 1), 1.0,
                   babl_format ("R'G'B'A double"), rgba,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  return TRUE;
}

static void
read_region (GeglBuffer *buffer, gint x, gint y, gint w, gint h, gdouble *dest)
{
  gegl_buffer_get (buffer, GEGL_RECTANGLE (x, y, w, h), 1.0,
                   babl_format ("R'G'B'A double"), dest,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
}

static gboolean
out_is_zero (const GlimsSampledColor *out)
{
  return out->red == 0.0 && out->green == 0.0 && out->blue == 0.0 && out->alpha == 0.0;
}

/* ---- Suites, each run on the engine thread ----------------------------- */

/* Known fractional float-RGB seed via facade fill, partial alpha,
 * >8-bit fractions and straight (not premultiplied) components. */
static GlimsStatus
float_rgb_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0};
  char *error = NULL;
  GlimsSampledColor sampled = {0};
  gdouble pixel_rgba[4] = {0}, color_rgba[4] = {0}, stored[4] = {0};
  const GlimsColor seed = {0.1, 0.7, 0.35, 1.0};

  NEED (fixture_open (engine, &f), "float RGB fixture opens");
  NEED (api->image_convert_precision (engine, f.id, GLIMS_COLOR_COMPONENT_FLOAT,
                                      GLIMS_COLOR_TRC_NONLINEAR, &error) == GLIMS_STATUS_OK,
        "convert to 32-bit float nonlinear");
  clear_error (&error);
  GlimsColorInfo info = {0};
  NEED (api->image_color_info (engine, f.id, &info) == GLIMS_STATUS_OK &&
        info.component == GLIMS_COLOR_COMPONENT_FLOAT && info.mode == GLIMS_COLOR_MODE_RGB,
        "color info reports float RGB");
  /* The foreground context is opaque; fill opacity supplies partial alpha. */
  NEED (facade_fill (&f, seed, 0.5, &error) == GLIMS_STATUS_OK, "facade fill seeds the layer");
  clear_error (&error);

  NEED (layer_pixel_straight (&f, 3, 4, stored), "stored layer pixel readable natively");
  CHECK (doubles_match ((gdouble[4]) {stored[0], stored[1], stored[2], stored[3]},
                        (gdouble[4]) {seed.red, seed.green, seed.blue, 0.5}, 1e-5),
         "facade fill landed the requested fractional color");
  CHECK (stored[3] > 0.001 && stored[3] < 0.999, "facade fill produced partial alpha");

  NEED (api->image_sample_color (engine, f.id, 3, 4, &sampled, &error) == GLIMS_STATUS_OK,
        "slot174 samples the seeded float pixel");
  clear_error (&error);
  CHECK (sampled_matches_oracles (f.image, 3, 4, &sampled, 1e-9, pixel_rgba, color_rgba),
         "sampled color matches both native GimpPickable/GeglColor oracles");
  CHECK (isfinite (sampled.red) && isfinite (sampled.green) &&
         isfinite (sampled.blue) && sampled.alpha >= 0.0 && sampled.alpha <= 1.0,
         "sampled components finite, alpha in 0..1");
  /* >8-bit fraction: 0.1/0.7/0.35 are not representable as k/255. */
  gboolean fractional = FALSE;
  const gdouble c[3] = {sampled.red, sampled.green, sampled.blue};
  for (gint i = 0; i < 3; i++)
    if (fabs (c[i] * 255.0 - round (c[i] * 255.0)) > 0.1) fractional = TRUE;
  CHECK (fractional, "at least one channel is a >8-bit fraction (not u8-quantized)");
  /* Straight alpha: with partial alpha a, premultiplied storage would
   * report rgb*a; straight storage reports rgb itself. */
  if (stored[3] > 0.001 && stored[3] < 0.999)
    {
      gdouble premult[3] = {stored[0] * stored[3], stored[1] * stored[3], stored[2] * stored[3]};
      const gdouble got[3] = {sampled.red, sampled.green, sampled.blue};
      gboolean straight = fabs (got[0] - stored[0]) < 1e-6 &&
                          fabs (got[1] - stored[1]) < 1e-6 &&
                          fabs (got[2] - stored[2]) < 1e-6 &&
                          fabs (sampled.alpha - stored[3]) < 1e-6;
      gboolean would_be_premult = fabs (got[0] - premult[0]) > 0.1 ||
                                  fabs (got[1] - premult[1]) > 0.1 ||
                                  fabs (got[2] - premult[2]) > 0.1;
      CHECK (straight && would_be_premult,
             "components are straight alpha, not premultiplied");
    }

cleanup:
  clear_error (&error);
  fixture_close (&f);
  return GLIMS_STATUS_OK;
}

/* Fresh 1x1 reads after a subsequent fill/mutation (hot-tile path). */
static GlimsStatus
mutation_freshness_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0};
  char *error = NULL;
  GlimsSampledColor first = {0}, second = {0};
  gdouble pixel_rgba[4] = {0}, color_rgba[4] = {0};

  NEED (fixture_open (engine, &f), "freshness fixture opens");
  NEED (api->image_convert_precision (engine, f.id, GLIMS_COLOR_COMPONENT_FLOAT,
                                      GLIMS_COLOR_TRC_NONLINEAR, &error) == GLIMS_STATUS_OK,
        "convert to float");
  clear_error (&error);
  NEED (facade_fill (&f, (GlimsColor) {0.2, 0.4, 0.6, 1.0}, 1.0, &error) == GLIMS_STATUS_OK,
        "first fill");
  clear_error (&error);
  NEED (api->image_sample_color (engine, f.id, 5, 5, &first, &error) == GLIMS_STATUS_OK,
        "first sample");
  clear_error (&error);
  CHECK (sampled_matches_oracles (f.image, 5, 5, &first, 1e-9, pixel_rgba, color_rgba),
         "first sample matches oracles");

  NEED (facade_fill (&f, (GlimsColor) {0.9, 0.15, 0.45, 0.75}, 1.0, &error) == GLIMS_STATUS_OK,
        "second fill mutates the image");
  clear_error (&error);
  NEED (api->image_sample_color (engine, f.id, 5, 5, &second, &error) == GLIMS_STATUS_OK,
        "fresh 1x1 sample after mutation");
  clear_error (&error);
  CHECK (sampled_matches_oracles (f.image, 5, 5, &second, 1e-9, pixel_rgba, color_rgba),
         "post-mutation sample matches oracles");
  CHECK (fabs (second.red - first.red) > 0.5,
         "post-mutation sample is fresh, not the pre-edit hot tile");

cleanup:
  clear_error (&error);
  fixture_close (&f);
  return GLIMS_STATUS_OK;
}

/* High-precision linear and nonlinear TRC variants. */
static GlimsStatus
precision_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  static const struct { uint32_t component, trc; const gchar *name; } cases[] = {
    {GLIMS_COLOR_COMPONENT_FLOAT,  GLIMS_COLOR_TRC_LINEAR,    "float linear"},
    {GLIMS_COLOR_COMPONENT_FLOAT,  GLIMS_COLOR_TRC_NONLINEAR, "float nonlinear"},
    {GLIMS_COLOR_COMPONENT_U32,    GLIMS_COLOR_TRC_NONLINEAR, "u32 nonlinear"},
    {GLIMS_COLOR_COMPONENT_DOUBLE, GLIMS_COLOR_TRC_LINEAR,    "double linear"},
  };
  for (guint i = 0; i < G_N_ELEMENTS (cases); i++)
    {
      Fixture f = {0};
      char *error = NULL;
      GlimsSampledColor sampled = {0};
      gdouble pixel_rgba[4] = {0}, color_rgba[4] = {0};
      if (! fixture_open (engine, &f)) { CHECK (FALSE, "precision fixture opens"); continue; }
      GlimsStatus s = api->image_convert_precision (engine, f.id, cases[i].component,
                                                    cases[i].trc, &error);
      CHECK (s == GLIMS_STATUS_OK, cases[i].name);
      clear_error (&error);
      if (s == GLIMS_STATUS_OK)
        {
          GlimsColorInfo info = {0};
          CHECK (api->image_color_info (engine, f.id, &info) == GLIMS_STATUS_OK &&
                 info.component == cases[i].component && info.trc == cases[i].trc,
                 "color info reports the requested precision");
          CHECK (facade_fill (&f, (GlimsColor) {0.3, 0.55, 0.8, 1.0}, 1.0, &error) == GLIMS_STATUS_OK,
                 "fill in the converted precision");
          clear_error (&error);
          CHECK (api->image_sample_color (engine, f.id, 2, 2, &sampled, &error) == GLIMS_STATUS_OK &&
                 sampled_matches_oracles (f.image, 2, 2, &sampled, 1e-6, pixel_rgba, color_rgba),
                 "sample matches oracles in the converted precision");
          clear_error (&error);
        }
      fixture_close (&f);
    }
  return GLIMS_STATUS_OK;
}

/* Grayscale and indexed modes. */
static GlimsStatus
mode_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0};
  char *error = NULL;
  GlimsSampledColor sampled = {0};
  gdouble pixel_rgba[4] = {0}, color_rgba[4] = {0};

  NEED (fixture_open (engine, &f), "mode fixture opens");
  NEED (api->image_convert_precision (engine, f.id, GLIMS_COLOR_COMPONENT_FLOAT,
                                      GLIMS_COLOR_TRC_NONLINEAR, &error) == GLIMS_STATUS_OK,
        "float RGB base");
  clear_error (&error);

  NEED (api->image_convert_mode (engine, f.id, GLIMS_COLOR_MODE_GRAYSCALE, &error) == GLIMS_STATUS_OK,
        "convert to grayscale");
  clear_error (&error);
  GlimsColorInfo info = {0};
  NEED (api->image_color_info (engine, f.id, &info) == GLIMS_STATUS_OK &&
        info.mode == GLIMS_COLOR_MODE_GRAYSCALE, "color info reports grayscale");
  NEED (facade_fill (&f, (GlimsColor) {0.4, 0.4, 0.4, 1.0}, 1.0, &error) == GLIMS_STATUS_OK,
        "fill gray");
  clear_error (&error);
  NEED (api->image_sample_color (engine, f.id, 7, 3, &sampled, &error) == GLIMS_STATUS_OK,
        "sample gray pixel");
  clear_error (&error);
  CHECK (sampled_matches_oracles (f.image, 7, 3, &sampled, 1e-9, pixel_rgba, color_rgba),
         "gray sample matches oracles");
  CHECK (fabs (sampled.red - sampled.green) < 1e-6 && fabs (sampled.green - sampled.blue) < 1e-6,
         "gray sample has equal RGB channels");

  NEED (api->image_convert_mode (engine, f.id, GLIMS_COLOR_MODE_RGB, &error) == GLIMS_STATUS_OK,
        "back to RGB");
  clear_error (&error);
  NEED (api->image_convert_precision (engine, f.id, GLIMS_COLOR_COMPONENT_U8,
                                      GLIMS_COLOR_TRC_NONLINEAR, &error) == GLIMS_STATUS_OK,
        "indexed conversion starts from supported u8 nonlinear precision");
  clear_error (&error);
  GlimsIndexedSettings indexed = {
    .struct_size = sizeof indexed,
    .palette = GLIMS_INDEXED_PALETTE_GENERATED,
    .max_colors = 16,
    .remove_unused = FALSE,
    .dither = GLIMS_INDEXED_DITHER_NONE,
    .dither_alpha = FALSE,
    .dither_text = FALSE,
    .preservation = GLIMS_INDEXED_PRESERVE_EDITABLE
  };
  NEED (api->image_convert_indexed (engine, f.id, &indexed, NULL, 0, &error) == GLIMS_STATUS_OK,
        "convert to indexed");
  clear_error (&error);
  NEED (api->image_color_info (engine, f.id, &info) == GLIMS_STATUS_OK &&
        info.mode == GLIMS_COLOR_MODE_INDEXED, "color info reports indexed");
  NEED (facade_fill (&f, (GlimsColor) {0.65, 0.25, 0.85, 1.0}, 1.0, &error) == GLIMS_STATUS_OK,
        "fill indexed");
  clear_error (&error);
  NEED (api->image_sample_color (engine, f.id, 7, 3, &sampled, &error) == GLIMS_STATUS_OK,
        "sample indexed pixel");
  clear_error (&error);
  CHECK (sampled_matches_oracles (f.image, 7, 3, &sampled, 1e-9, pixel_rgba, color_rgba),
         "indexed sample matches oracles");

cleanup:
  clear_error (&error);
  fixture_close (&f);
  return GLIMS_STATUS_OK;
}

/* A read must not change native pixels, profile, selection, Undo or the
 * dirty flag. */
static GlimsStatus
purity_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0};
  char *error = NULL;
  gchar *profile_before_digest = NULL;
  gdouble layer_before[W * H * 4], layer_after[W * H * 4];
  gdouble proj_before[W * H * 4], proj_after[W * H * 4];
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  GlimsImageInfo image_before = {0}, image_after = {0};
  GlimsColorInfo color_before = {0}, color_after = {0};
  bool sel_empty_before = true, sel_empty_after = true;
  GlimsRect sel_before = {0}, sel_after = {0};
  GlimsSampledColor sampled = {0};

  NEED (fixture_open (engine, &f), "purity fixture opens");
  NEED (api->image_convert_precision (engine, f.id, GLIMS_COLOR_COMPONENT_FLOAT,
                                      GLIMS_COLOR_TRC_NONLINEAR, &error) == GLIMS_STATUS_OK,
        "float base");
  clear_error (&error);
  NEED (facade_fill (&f, (GlimsColor) {0.25, 0.5, 0.75, 0.5}, 1.0, &error) == GLIMS_STATUS_OK,
        "seed fill");
  clear_error (&error);
  GlimsPoint corners[2] = {{2, 2}, {9, 8}};
  NEED (api->select_shape (engine, f.id, GLIMS_SHAPE_RECTANGLE, corners, 2, NULL) == GLIMS_STATUS_OK,
        "rectangle selection active");

  NEED (api->image_assign_profile (engine, f.id, p3_profile_path, &error) == GLIMS_STATUS_OK,
        "purity control has a real embedded ICC");
  clear_error (&error);
  GimpColorProfile *profile_before = gimp_image_get_color_profile (f.image);
  gsize profile_before_size = 0;
  const guint8 *profile_bytes = profile_before
    ? gimp_color_profile_get_icc_profile (profile_before, &profile_before_size) : NULL;
  NEED (profile_bytes && profile_before_size, "embedded profile bytes captured");
  profile_before_digest = g_compute_checksum_for_data (G_CHECKSUM_SHA256,
                                                       profile_bytes, profile_before_size);
  /* A clean control detects an accidental dirty transition; starting dirty
   * would let that bug pass. Keep the existing nonempty Undo stack. */
  gimp_image_clean_all (f.image);
  /* Snapshot everything a read could plausibly touch. */
  read_region (gimp_drawable_get_buffer (GIMP_DRAWABLE (f.layer)), 0, 0, W, H, layer_before);
  GimpPickable *pickable = GIMP_PICKABLE (gimp_image_get_projection (f.image));
  gimp_pickable_flush (pickable);
  read_region (gimp_pickable_get_buffer (pickable), 0, 0, W, H, proj_before);
  NEED (api->image_undo_info (engine, f.id, &undo_before) == GLIMS_STATUS_OK &&
        api->image_info (engine, f.id, &image_before) == GLIMS_STATUS_OK &&
        api->image_color_info (engine, f.id, &color_before) == GLIMS_STATUS_OK &&
        api->selection_bounds (engine, f.id, &sel_empty_before, &sel_before) == GLIMS_STATUS_OK,
        "facade state snapshot");
  NEED (!image_before.dirty && undo_before.undo_count > 0,
        "purity control starts clean with real undo history");

  NEED (api->image_sample_color (engine, f.id, 4, 4, &sampled, &error) == GLIMS_STATUS_OK,
        "sample inside the selection succeeds");
  clear_error (&error);
  CHECK (api->image_sample_color (engine, f.id, 0, 0, &sampled, NULL) == GLIMS_STATUS_OK,
         "sample with NULL error pointer succeeds");

  read_region (gimp_drawable_get_buffer (GIMP_DRAWABLE (f.layer)), 0, 0, W, H, layer_after);
  gimp_pickable_flush (pickable);
  read_region (gimp_pickable_get_buffer (pickable), 0, 0, W, H, proj_after);
  CHECK (api->image_undo_info (engine, f.id, &undo_after) == GLIMS_STATUS_OK &&
         api->image_info (engine, f.id, &image_after) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, f.id, &color_after) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, f.id, &sel_empty_after, &sel_after) == GLIMS_STATUS_OK,
         "facade state re-readable after sampling");
  CHECK (! memcmp (layer_before, layer_after, LAYER_BYTES) &&
         ! memcmp (proj_before, proj_after, LAYER_BYTES),
         "sampling leaves native layer and projection pixels unchanged");
  CHECK (! memcmp (&undo_before, &undo_after, sizeof undo_before),
         "sampling leaves Undo counts and labels unchanged");
  CHECK (image_before.dirty == image_after.dirty &&
         image_before.width == image_after.width && image_before.height == image_after.height,
         "sampling leaves the dirty flag and size unchanged");
  CHECK (! memcmp (&color_before, &color_after, sizeof color_before),
         "sampling leaves the color state/profile unchanged");
  GimpColorProfile *profile_after = gimp_image_get_color_profile (f.image);
  gsize profile_after_size = 0;
  const guint8 *after_bytes = profile_after
    ? gimp_color_profile_get_icc_profile (profile_after, &profile_after_size) : NULL;
  gchar *profile_after_digest = after_bytes
    ? g_compute_checksum_for_data (G_CHECKSUM_SHA256, after_bytes, profile_after_size) : NULL;
  CHECK (profile_before_size == profile_after_size && profile_after_digest &&
         !g_strcmp0 (profile_before_digest, profile_after_digest),
         "sampling leaves the native embedded ICC bytes unchanged");
  g_free (profile_after_digest);
  CHECK (sel_empty_before == sel_empty_after && ! memcmp (&sel_before, &sel_after, sizeof sel_before),
         "sampling leaves the selection unchanged");

cleanup:
  g_free (profile_before_digest);
  clear_error (&error);
  fixture_close (&f);
  return GLIMS_STATUS_OK;
}

/* A read is allowed during an edit: an active stroke makes mutations BUSY
 * but the sample read still succeeds and matches the oracle. */
static GlimsStatus
during_edit_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0};
  char *error = NULL;
  GlimsStrokeID stroke = 0;
  GlimsSampledColor sampled = {0};
  gdouble pixel_rgba[4] = {0}, color_rgba[4] = {0};
  const GlimsBrushSettings pencil = {
    .struct_size = sizeof (GlimsBrushSettings), .tool = GLIMS_PAINT_PENCIL,
    .size = 7.5, .opacity = 0.79, .red = 0.91, .green = 0.16, .blue = 0.31,
    .pressure_size = FALSE, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1
  };
  GlimsStrokeSampleV2 sample = {
    .struct_size = sizeof sample, .flags = 0,
    .x = 4, .y = 4, .pressure = 0.7, .xtilt = 0, .ytilt = 0, .time_ms = 0,
    .reserved = 0, .rotation_turns = 0, .tangential_pressure = 0
  };
  GlimsStrokePacketV2 packet = {
    .struct_size = sizeof packet, .sample_stride = sizeof sample,
    .samples = &sample, .count = 1, .byte_count = sizeof sample
  };

  NEED (fixture_open (engine, &f), "edit fixture opens");
  NEED (facade_fill (&f, (GlimsColor) {0.5, 0.5, 0.5, 1.0}, 1.0, &error) == GLIMS_STATUS_OK,
        "seed fill before the stroke");
  clear_error (&error);
  NEED (api->stroke_begin_v2 (engine, f.id, f.layer_id, 0, &pencil, &packet,
                              &stroke, &error) == GLIMS_STATUS_OK && stroke != 0,
        "stroke begins (edit in progress)");
  clear_error (&error);
  CHECK (api->image_convert_precision (engine, f.id, GLIMS_COLOR_COMPONENT_FLOAT,
                                       GLIMS_COLOR_TRC_NONLINEAR, &error) == GLIMS_STATUS_BUSY,
         "precision mutation is BUSY while the stroke is active");
  clear_error (&error);
  NEED (api->image_sample_color (engine, f.id, 4, 4, &sampled, &error) == GLIMS_STATUS_OK,
        "slot174 read is allowed during the edit");
  clear_error (&error);
  CHECK (sampled_matches_oracles (f.image, 4, 4, &sampled, 1e-9, pixel_rgba, color_rgba),
         "during-edit sample matches oracles");
  NEED (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "stroke ends");
  stroke = 0;

cleanup:
  if (stroke) api->stroke_end (engine, stroke);
  clear_error (&error);
  fixture_close (&f);
  return GLIMS_STATUS_OK;
}

/* Refusals: outside canvas, unknown image, NULL out, stopped-engine
 * dispatch. Every failure zeroes the output and clears the error pointer. */
static GlimsStatus
refusal_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0};
  char *error = NULL;
  GlimsSampledColor out;
  const gint bad_coords[][2] = {
    {-1, 0}, {0, -1}, {W, 0}, {0, H}, {W + 100, 3}, {3, H + 100},
    {INT32_MIN, 5}, {5, INT32_MAX}
  };

  NEED (fixture_open (engine, &f), "refusal fixture opens");
  NEED (facade_fill (&f, (GlimsColor) {0.2, 0.4, 0.6, 1.0}, 1.0, &error) == GLIMS_STATUS_OK,
        "positive refusal control has nonzero color");
  clear_error (&error);

  for (guint i = 0; i < G_N_ELEMENTS (bad_coords); i++)
    {
      out = (GlimsSampledColor) {9, 9, 9, 9};
      error = (char *) 0x1;
      GlimsStatus s = api->image_sample_color (engine, f.id,
                                               bad_coords[i][0], bad_coords[i][1],
                                               &out, &error);
      CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT && out_is_zero (&out) && error == NULL,
             "outside-canvas coordinate refused with zeroed output and cleared error");
    }

  out = (GlimsSampledColor) {9, 9, 9, 9};
  error = (char *) 0x1;
  CHECK (api->image_sample_color (engine, 987654321, 0, 0, &out, &error) == GLIMS_STATUS_NOT_FOUND &&
         out_is_zero (&out) && error == NULL,
         "unknown image refused NOT_FOUND with zeroed output and cleared error");

  error = (char *) 0x1;
  CHECK (api->image_sample_color (engine, f.id, 0, 0, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         error == NULL,
         "NULL out refused INVALID_ARGUMENT with cleared error");

  out = (GlimsSampledColor) {9, 9, 9, 9};
  error = (char *) 0x1;
  CHECK (api->image_sample_color (NULL, f.id, 0, 0, &out, &error) == GLIMS_STATUS_NOT_RUNNING &&
         out_is_zero (&out) && error == NULL,
         "stopped-engine dispatch refused NOT_RUNNING with zeroed output and cleared error");

  out = (GlimsSampledColor) {9, 9, 9, 9};
  CHECK (api->image_sample_color (engine, f.id, 1, 1, &out, NULL) == GLIMS_STATUS_OK &&
         ! out_is_zero (&out),
         "valid sample with NULL error pointer still returns the color");

cleanup:
  clear_error (&error);
  fixture_close (&f);
  return GLIMS_STATUS_OK;
}

/* Native NaN / +inf / alpha>1 fixture writes: test refusal only if an
 * independent projection read confirms the invalid component survives. */
static GlimsStatus
nonfinite_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0};
  char *error = NULL;
  GlimsSampledColor out;
  const gfloat nan_pixel[4] = {(gfloat) NAN, 0.5f, 0.5f, 1.0f};
  const gfloat inf_pixel[4] = {(gfloat) INFINITY, 0.5f, 0.5f, 1.0f};
  const gfloat bad_alpha[4] = {0.5f, 0.5f, 0.5f, 2.0f};
  const struct { gint x, y; const gfloat *pixel; const gchar *name; } cases[] = {
    {5, 5, nan_pixel, "NaN component"},
    {6, 6, inf_pixel, "infinite component"},
    {7, 7, bad_alpha, "alpha above 1"}
  };

  NEED (fixture_open (engine, &f), "nonfinite fixture opens");
  NEED (api->image_convert_precision (engine, f.id, GLIMS_COLOR_COMPONENT_FLOAT,
                                      GLIMS_COLOR_TRC_NONLINEAR, &error) == GLIMS_STATUS_OK,
        "float base");
  clear_error (&error);
  NEED (facade_fill (&f, (GlimsColor) {0.2, 0.6, 0.4, 1.0}, 1.0, &error) == GLIMS_STATUS_OK,
        "valid seed fill");
  clear_error (&error);

  GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (f.layer));
  for (guint i = 0; i < G_N_ELEMENTS (cases); i++)
    {
      gegl_buffer_set (buffer, GEGL_RECTANGLE (cases[i].x, cases[i].y, 1, 1), 0,
                       babl_format ("R'G'B'A float"), cases[i].pixel, GEGL_AUTO_ROWSTRIDE);
      gimp_drawable_update (GIMP_DRAWABLE (f.layer), cases[i].x, cases[i].y, 1, 1);
      out = (GlimsSampledColor) {9, 9, 9, 9};
      error = (char *) 0x1;
      GlimsStatus s = api->image_sample_color (engine, f.id, cases[i].x, cases[i].y,
                                               &out, &error);
      /* Check reachability independently AFTER the subject, so this oracle
       * cannot prime its projection read. Some core pipelines sanitize an
       * invalid layer value before it reaches the projection. */
      gdouble native[4] = {0};
      gboolean observed = oracle_pickable_pixel (f.image, cases[i].x, cases[i].y, native);
      NEED (observed, "native invalid-pixel projection is independently readable");
      gboolean invalid = !isfinite (native[0]) || !isfinite (native[1]) ||
                         !isfinite (native[2]) || !isfinite (native[3]) ||
                         native[3] < 0 || native[3] > 1;
      if (invalid)
        CHECK (s == GLIMS_STATUS_FAILED && out_is_zero (&out) && error != (char *) 0x1,
               cases[i].name);
      else
        {
          printf ("NOTE sample-color: %s sanitized by native projection; "
                  "nonfinite-refusal branch not exercised\n", cases[i].name);
          const gdouble got[4] = {out.red, out.green, out.blue, out.alpha};
          CHECK (s == GLIMS_STATUS_OK && error == NULL && doubles_match (got, native, 1e-9),
                 "native-sanitized sample agrees with the independent projection");
        }
      clear_error (&error);
      /* Repair the raw fixture pixel directly; painting over NaN need not
       * replace it in every native composite implementation. */
      const gfloat finite[4] = {0.2f, 0.6f, 0.4f, 1.0f};
      gegl_buffer_set (buffer, GEGL_RECTANGLE (cases[i].x, cases[i].y, 1, 1), 0,
                       babl_format ("R'G'B'A float"), finite, GEGL_AUTO_ROWSTRIDE);
      gimp_drawable_update (GIMP_DRAWABLE (f.layer), cases[i].x, cases[i].y, 1, 1);
    }

  /* Recovery: a fresh facade fill restores a finite, samplable pixel. */
  NEED (facade_fill (&f, (GlimsColor) {0.2, 0.6, 0.4, 1.0}, 1.0, &error) == GLIMS_STATUS_OK,
        "fill restores finite pixels");
  clear_error (&error);
  out = (GlimsSampledColor) {0};
  NEED (api->image_sample_color (engine, f.id, 5, 5, &out, &error) == GLIMS_STATUS_OK &&
        isfinite (out.red) && isfinite (out.green) && isfinite (out.blue),
        "sample succeeds again after the fixture-side repair");
  clear_error (&error);

cleanup:
  clear_error (&error);
  fixture_close (&f);
  return GLIMS_STATUS_OK;
}

/* Wide gamut: a locally generated Display-P3 ICC assigned without pixel
 * conversion puts saturated content outside the sRGB gamut; the sample
 * must report extended finite RGB, matching the native sRGB oracle. */
static gboolean
write_p3_profile (const gchar *path)
{
  cmsCIExyY white = {0.3127, 0.3290, 1.0};
  cmsCIExyYTRIPLE primaries = {
    {0.680, 0.320, 1.0}, {0.265, 0.690, 1.0}, {0.150, 0.060, 1.0}
  };
  /* Display P3 primaries with the sRGB transfer curve (parametric type 4). */
  cmsFloat64Number params[5] = {2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045};
  cmsToneCurve *curve = cmsBuildParametricToneCurve (NULL, 4, params);
  if (! curve) return FALSE;
  cmsToneCurve *curves[3] = {curve, curve, curve};
  cmsHPROFILE profile = cmsCreateRGBProfile (&white, &primaries, curves);
  cmsFreeToneCurve (curve);
  if (! profile) return FALSE;
  gboolean ok = cmsSaveProfileToFile (profile, path);
  cmsCloseProfile (profile);
  return ok;
}

static GlimsStatus
wide_profile_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0};
  char *error = NULL;
  GlimsSampledColor sampled = {0};
  gdouble pixel_rgba[4] = {0}, color_rgba[4] = {0};

  NEED (fixture_open (engine, &f), "wide fixture opens");
  NEED (api->image_convert_precision (engine, f.id, GLIMS_COLOR_COMPONENT_FLOAT,
                                      GLIMS_COLOR_TRC_NONLINEAR, &error) == GLIMS_STATUS_OK,
        "P3 fixture uses float storage before assigning its profile");
  clear_error (&error);
  NEED (facade_fill (&f, (GlimsColor) {1.0, 0.0, 0.0, 1.0}, 1.0, &error) == GLIMS_STATUS_OK,
        "seed numeric red in the original sRGB working space");
  clear_error (&error);
  /* Assign after fill: identical numeric pixels now mean P3 red. Filling
   * after assignment would convert the facade's sRGB red into P3 instead. */
  NEED (api->image_assign_profile (engine, f.id, p3_profile_path, &error) == GLIMS_STATUS_OK,
        "locally generated Display-P3 ICC assigned");
  clear_error (&error);
  GlimsColorInfo info = {0};
  NEED (api->image_color_info (engine, f.id, &info) == GLIMS_STATUS_OK &&
        info.profile_embedded && info.profile_label[0] != '\0',
        "color info reports the assigned profile");
  NEED (api->image_sample_color (engine, f.id, 2, 2, &sampled, &error) == GLIMS_STATUS_OK,
        "sample the P3-composited pixel");
  clear_error (&error);
  CHECK (sampled_matches_oracles (f.image, 2, 2, &sampled, 1e-6, pixel_rgba, color_rgba),
         "wide-gamut sample matches both native sRGB oracles");
  CHECK (isfinite (sampled.red) && isfinite (sampled.green) && isfinite (sampled.blue),
         "wide-gamut sample stays finite");
  CHECK (sampled.red < -1e-3 || sampled.red > 1.0 + 1e-3 ||
         sampled.green < -1e-3 || sampled.green > 1.0 + 1e-3 ||
         sampled.blue < -1e-3 || sampled.blue > 1.0 + 1e-3,
         "P3 red reports extended RGB outside 0..1 (not clamped)");

cleanup:
  clear_error (&error);
  fixture_close (&f);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  /* image_assign_profile requires an absolute ICC path. */
  work_dir = g_path_is_absolute (argv[1])
    ? g_strdup (argv[1])
    : g_build_filename (g_get_current_dir (), argv[1], NULL);
  g_snprintf (p3_profile_path, sizeof p3_profile_path, "%s/display-p3-local.icc", work_dir);
  gchar *user = g_build_filename (work_dir, "user", NULL);
  gchar *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config,
                               .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL;
  char *error = NULL;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (! api || api->struct_size < sizeof (GlimsEngineAPI) || ! api->image_sample_color)
    return 2;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "%s\n", error ? error : "engine startup failed");
      clear_error (&error);
      g_free (user); g_free (cache);
      return 2;
    }

  CHECK (write_p3_profile (p3_profile_path), "local Display-P3 ICC generated with the linked LittleCMS");

  CHECK (glims_engine_call (engine, float_rgb_suite, NULL) == GLIMS_STATUS_OK,
         "float RGB / partial-alpha / >8-bit / straight-alpha suite ran on the engine thread");
  CHECK (glims_engine_call (engine, mutation_freshness_suite, NULL) == GLIMS_STATUS_OK,
         "fresh 1x1 after fill/mutation suite ran on the engine thread");
  CHECK (glims_engine_call (engine, precision_suite, NULL) == GLIMS_STATUS_OK,
         "high-precision linear/nonlinear suite ran on the engine thread");
  CHECK (glims_engine_call (engine, mode_suite, NULL) == GLIMS_STATUS_OK,
         "gray/indexed suite ran on the engine thread");
  CHECK (glims_engine_call (engine, purity_suite, NULL) == GLIMS_STATUS_OK,
         "read-purity suite ran on the engine thread");
  CHECK (glims_engine_call (engine, during_edit_suite, NULL) == GLIMS_STATUS_OK,
         "read-during-edit suite ran on the engine thread");
  CHECK (glims_engine_call (engine, refusal_suite, NULL) == GLIMS_STATUS_OK,
         "refusal suite ran on the engine thread");
  CHECK (glims_engine_call (engine, nonfinite_suite, NULL) == GLIMS_STATUS_OK,
         "native NaN/infinity refusal suite ran on the engine thread");
  CHECK (glims_engine_call (engine, wide_profile_suite, NULL) == GLIMS_STATUS_OK,
         "wide-profile P3-vs-sRGB suite ran on the engine thread");

  api->stop (engine);
  g_free (user); g_free (cache);
  printf ("%s: %u sample-color checks, %d failures\n",
          failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

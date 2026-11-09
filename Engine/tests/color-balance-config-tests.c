/* Core-only fixtures. Never free borrowed selected-layer lists or compensate
 * for native Undo/XCF config-setter retention with extra unrefs. */
#include "engine-private.h"
#include "color-balance-config.h"
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpfilter.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#include "operations/operations-types.h"
#include "operations/gimpcolorbalanceconfig.h"
#include "operations/gimpoperationpointfilter.h"
#include "operations/gimpoperationsettings.h"
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

#define SIDE 6
#define VALUES (SIDE * SIDE * 4)
int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static const gchar *work_dir;
static int failures;
#define CHECK(c, text) do { gboolean ok_ = (c); printf ("%s %s\n", ok_ ? "ok  " : "FAIL", text); if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, text) do { gboolean need_ = (c); CHECK (need_, text); if (!need_) goto cleanup; } while (0)

typedef struct {
  GlimsEngine *engine;
  GlimsImageID id;
  GimpImage *image;             /* borrowed while id is open */
  GimpLayer *layer;             /* borrowed from image */
} Fixture;

static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }
static GlimsItemID layer_id (Fixture *f) { return gimp_item_get_id (GIMP_ITEM (f->layer)); }

static GlimsColorBalanceRange
range3 (double cyan_red, double magenta_green, double yellow_blue)
{
  GlimsColorBalanceRange r = { cyan_red, magenta_green, yellow_blue };
  return r;
}

static GlimsColorBalanceSettings
cb_settings (uint32_t preserve,
             GlimsColorBalanceRange shadows,
             GlimsColorBalanceRange midtones,
             GlimsColorBalanceRange highlights)
{
  GlimsColorBalanceSettings s;
  memset (&s, 0, sizeof s);
  s.struct_size = sizeof s;
  s.preserve_luminosity = preserve;
  s.shadows = shadows;
  s.midtones = midtones;
  s.highlights = highlights;
  return s;
}

static GlimsColorBalanceSettings
cb_zero (uint32_t preserve)
{
  return cb_settings (preserve, range3 (0, 0, 0), range3 (0, 0, 0), range3 (0, 0, 0));
}

static gboolean
range_equal (const GlimsColorBalanceRange *a, const GlimsColorBalanceRange *b)
{
  return a->cyan_red == b->cyan_red && a->magenta_green == b->magenta_green &&
         a->yellow_blue == b->yellow_blue;
}

static gboolean
settings_equal (const GlimsColorBalanceSettings *a, const GlimsColorBalanceSettings *b)
{
  return a->preserve_luminosity == b->preserve_luminosity &&
         range_equal (&a->shadows, &b->shadows) &&
         range_equal (&a->midtones, &b->midtones) &&
         range_equal (&a->highlights, &b->highlights);
}

static void
source_patch (gfloat *p, double r, double g, double b, double a)
{
  p[0] = (gfloat) r; p[1] = (gfloat) g; p[2] = (gfloat) b; p[3] = (gfloat) a;
}

static gboolean
fixture_open (GlimsEngine *engine, Fixture *f)
{
  memset (f, 0, sizeof *f); f->engine = engine;
  /* Native Color Balance prepare uses "R'G'B'A float", nonlinear sRGB. */
  GimpImage *image = gimp_create_image (engine->gimp, SIDE, SIDE, GIMP_RGB,
                                        GIMP_PRECISION_FLOAT_NON_LINEAR, FALSE);
  if (!image) return FALSE;
  if (glims_adopt_image (engine, image, &f->id) != GLIMS_STATUS_OK) {
    g_object_unref (image); return FALSE;
  }
  f->image = image;
  f->layer = gimp_layer_new (image, SIDE, SIDE,
                             gimp_image_get_layer_format (image, TRUE),
                             "sRGB float target", 1.0, GIMP_LAYER_MODE_NORMAL);
  if (!f->layer) return FALSE;
  if (!gimp_image_add_layer (image, f->layer, NULL, 0, FALSE)) {
    g_object_unref (f->layer); f->layer = NULL; return FALSE;
  }

  gfloat pixels[VALUES];
  memset (pixels, 0, sizeof pixels);
  for (guint i = 0; i < VALUES; i += 4) {
    /* Contract source patches: grayscale .125/.5/.875, .9/.1/.3 clamp, .333
     * transition, nonopaque/.0/1 alpha; remainder deterministic. */
    switch (i / 4) {
      case 0: source_patch (&pixels[i], 0.125, 0.125, 0.125, 0.37); break;
      case 1: source_patch (&pixels[i], 0.5, 0.5, 0.5, 0.37); break;
      case 2: source_patch (&pixels[i], 0.875, 0.875, 0.875, 0.37); break;
      case 3: source_patch (&pixels[i], 0.9, 0.1, 0.3, 0.37); break;
      case 4: source_patch (&pixels[i], 0.333, 0.333, 0.333, 0.37); break;
      case 5: source_patch (&pixels[i], 0.2, 0.6, 0.1, 0.0); break;
      case 6: source_patch (&pixels[i], 0.2, 0.6, 0.1, 1.0); break;
      case 7: source_patch (&pixels[i], 0.0, 0.0, 0.0, 0.5); break;
      case 8: source_patch (&pixels[i], 1.0, 1.0, 1.0, 0.5); break;
      default:
        source_patch (&pixels[i],
                      ((i / 4) % 7) / 6.0,
                      ((i / 4 + 2) % 7) / 6.0,
                      ((i / 4 + 4) % 7) / 6.0,
                      (i / 4 % 2) ? 0.25 : 0.75);
        break;
    }
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->layer)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                   babl_format ("R'G'B'A float"), pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->layer), 0, 0, SIDE, SIDE);
  gimp_image_clean_all (image);
  return TRUE;
}

static void
fixture_close (Fixture *f)
{
  if (f->id) api->image_close (f->engine, f->id);
  f->id = 0; f->layer = NULL; f->image = NULL;
}

static gboolean
read_pixels (Fixture *f, gboolean effects, gfloat pixels[VALUES])
{
  GeglBuffer *buffer;
  if (effects) {
    gimp_pickable_flush (GIMP_PICKABLE (f->layer));
    buffer = gimp_drawable_get_buffer_with_effects (GIMP_DRAWABLE (f->layer)); /* owned */
  } else {
    buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (f->layer));
  }
  if (!buffer) return FALSE;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 1.0,
                   babl_format ("R'G'B'A float"), pixels, GEGL_AUTO_ROWSTRIDE,
                   GEGL_ABYSS_NONE);
  if (effects) g_object_unref (buffer);
  return TRUE;
}

static gboolean
close_pixels (const gfloat *a, const gfloat *b)
{
  for (guint i = 0; i < VALUES; i++)
    if (!isfinite (b[i]) || fabs ((double) a[i] - (double) b[i]) > 2e-4)
      return FALSE;
  return TRUE;
}

static gboolean
history_equal (Fixture *f, const GlimsUndoInfo *before)
{
  GlimsUndoInfo after = {0};
  return api->image_undo_info (f->engine, f->id, &after) == GLIMS_STATUS_OK &&
         !memcmp (before, &after, sizeof after);
}

static GlimsStatus
begin (Fixture *f, GlimsFilterID *filter, char **error)
{
  return api->filter_begin (f->engine, f->id, layer_id (f), "gimp:color-balance",
                            filter, error);
}

static GlimsFilter *
session (Fixture *f, GlimsFilterID id)
{
  return g_hash_table_lookup (f->engine->filters, GINT_TO_POINTER (id));
}

static GObject *
node_config (GeglNode *node)
{
  GeglOperation *operation = gegl_node_get_gegl_operation (node); /* borrowed */
  return operation && GIMP_IS_OPERATION_POINT_FILTER (operation)
         ? GIMP_OPERATION_POINT_FILTER (operation)->config : NULL;
}

static gboolean
settings_are (Fixture *f, GlimsFilterID id, const GlimsColorBalanceSettings *expected)
{
  GlimsColorBalanceSettings actual = cb_zero (1);
  actual.struct_size = sizeof actual;
  return api->filter_color_balance_get (f->engine, id, &actual, NULL) == GLIMS_STATUS_OK &&
         settings_equal (&actual, expected);
}

static void
notified (GObject *object, GParamSpec *spec, gpointer data)
{
  (void) object; (void) spec; (*(guint *) data)++;
}

/* Independent standard HSL (babl HSL.c contract) and Color Balance formula.
 * No GIMP/GEGL/babl calls as oracle; this is arithmetic-only. */
static double
clamp01 (double x) { return x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x); }

static void
rgb_to_hsl (double r, double g, double b, double *h, double *s, double *l)
{
  double maxv = fmax (r, fmax (g, b));
  double minv = fmin (r, fmin (g, b));
  double delta = maxv - minv;
  *l = (maxv + minv) / 2.0;
  if (delta == 0.0) { *h = 0.0; *s = 0.0; return; }
  *s = *l <= 0.5 ? delta / (maxv + minv) : delta / (2.0 - maxv - minv);
  if (r == maxv) *h = (g - b) / delta;
  else if (g == maxv) *h = 2.0 + (b - r) / delta;
  else *h = 4.0 + (r - g) / delta;
  *h /= 6.0;
  if (*h < 0.0) *h += 1.0;
}

static double
hsl_value (double n1, double n2, double hue)
{
  double h6 = hue * 6.0;
  if (h6 > 6.0) h6 -= 6.0;
  else if (h6 < 0.0) h6 += 6.0;
  if (h6 < 1.0) return n1 + (n2 - n1) * h6;
  if (h6 < 3.0) return n2;
  if (h6 < 4.0) return n1 + (n2 - n1) * (4.0 - h6);
  return n1;
}

static void
hsl_to_rgb (double h, double s, double l, double *r, double *g, double *b)
{
  if (s == 0.0) { *r = *g = *b = l; return; }
  double m2 = l <= 0.5 ? l * (1.0 + s) : l + s - l * s;
  double m1 = 2.0 * l - m2;
  *r = hsl_value (m1, m2, h + 1.0 / 3.0);
  *g = hsl_value (m1, m2, h);
  *b = hsl_value (m1, m2, h - 1.0 / 3.0);
}

static void
cb_formula_rgb (double in_r, double in_g, double in_b,
                const GlimsColorBalanceSettings *s,
                double *out_r, double *out_g, double *out_b)
{
  double h, sat, l;
  rgb_to_hsl (in_r, in_g, in_b, &h, &sat, &l);
  double S = clamp01 ((l - 0.333) / -0.25 + 0.5);
  double M = clamp01 ((l - 0.333) / 0.25 + 0.5) * clamp01 ((l + 0.333 - 1.0) / -0.25 + 0.5);
  double H = clamp01 ((l + 0.333 - 1.0) / 0.25 + 0.5);
  double r = in_r + 0.7 * (S * s->shadows.cyan_red + M * s->midtones.cyan_red + H * s->highlights.cyan_red);
  double g = in_g + 0.7 * (S * s->shadows.magenta_green + M * s->midtones.magenta_green + H * s->highlights.magenta_green);
  double b = in_b + 0.7 * (S * s->shadows.yellow_blue + M * s->midtones.yellow_blue + H * s->highlights.yellow_blue);
  r = clamp01 (r); g = clamp01 (g); b = clamp01 (b);
  if (s->preserve_luminosity) {
    double oh, os, ol;
    rgb_to_hsl (r, g, b, &oh, &os, &ol);
    hsl_to_rgb (oh, os, l, &r, &g, &b);
  }
  *out_r = r; *out_g = g; *out_b = b;
}

static gboolean
formula_matches (const gfloat *source, const gfloat *actual,
                 const GlimsColorBalanceSettings *s)
{
  for (guint i = 0; i < VALUES; i += 4) {
    double er, eg, eb;
    cb_formula_rgb (source[i], source[i + 1], source[i + 2], s, &er, &eg, &eb);
    if (!isfinite (actual[i]) || fabs ((double) actual[i] - er) > 2e-4) return FALSE;
    if (!isfinite (actual[i + 1]) || fabs ((double) actual[i + 1] - eg) > 2e-4) return FALSE;
    if (!isfinite (actual[i + 2]) || fabs ((double) actual[i + 2] - eb) > 2e-4) return FALSE;
    if (!isfinite (actual[i + 3]) || fabs ((double) actual[i + 3] - (double) source[i + 3]) > 2e-4)
      return FALSE;
  }
  return TRUE;
}

static gboolean
patch_matches (const gfloat *actual, guint pixel_index,
               double er, double eg, double eb, double ea)
{
  guint i = pixel_index * 4;
  return fabs ((double) actual[i] - er) <= 2e-4 &&
         fabs ((double) actual[i + 1] - eg) <= 2e-4 &&
         fabs ((double) actual[i + 2] - eb) <= 2e-4 &&
         fabs ((double) actual[i + 3] - ea) <= 2e-4;
}

static gboolean
apply_and_read (Fixture *f, GlimsFilterID filter,
                const GlimsColorBalanceSettings *s, gfloat actual[VALUES],
                char **error)
{
  gfloat source[VALUES];
  return read_pixels (f, FALSE, source) &&
         api->filter_color_balance_set (f->engine, filter, s, error) == GLIMS_STATUS_OK &&
         settings_are (f, filter, s) && read_pixels (f, TRUE, actual) &&
         formula_matches (source, actual, s);
}

static GlimsStatus
formula_and_lifetime (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  gfloat raw[VALUES], actual[VALUES], current[VALUES]; GlimsUndoInfo history = {0};
  GWeakRef old_weak, last_weak; gboolean old_init = FALSE, last_init = FALSE;
  NEED (fixture_open (engine, &f) && read_pixels (&f, FALSE, raw),
        "real nonlinear FLOAT sRGB fixture opens with nonopaque/zero/one alpha");
  NEED (api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK &&
        begin (&f, &filter, &error) == GLIMS_STATUS_OK,
        "default Color Balance preview begins without a native Undo");
  GlimsColorBalanceSettings defaults = cb_zero (1);
  NEED (settings_are (&f, filter, &defaults) && read_pixels (&f, TRUE, actual),
        "default all-zero preserve-TRUE settings and preview can be read");
  CHECK (formula_matches (raw, actual, &defaults), "default zero settings are an independent sRGB identity");

  GlimsFilter *s = session (&f, filter);
  NEED (s && node_config (s->operation), "preview owns a real native point-filter configuration");
  g_weak_ref_init (&old_weak, node_config (s->operation)); old_init = TRUE;
  GlimsColorBalanceSettings first = cb_settings (1, range3 (0.2, -0.1, 0.05),
                                                 range3 (0, 0, 0), range3 (0, 0, 0));
  NEED (api->filter_color_balance_set (engine, filter, &first, &error) == GLIMS_STATUS_OK,
        "first immutable replacement succeeds before any Undo");
  GObject *held = g_weak_ref_get (&old_weak);
  CHECK (held == NULL, "replaced adapter-only default config finalizes before native Undo/XCF");
  g_clear_object (&held);

  /* Oracle patches from contract/report crosschecked with independent formula
   * and actual native preview. */
  GlimsColorBalanceSettings shadow = cb_settings (0, range3 (0.2, -0.1, 0.05),
                                                  range3 (0, 0, 0), range3 (0, 0, 0));
  NEED (apply_and_read (&f, filter, &shadow, actual, &error), "shadow correction applies");
  CHECK (patch_matches (actual, 0, 0.265, 0.055, 0.16, 0.37), "shadow preserve-OFF oracle matches (.125 gray)");
  shadow.preserve_luminosity = 1;
  NEED (apply_and_read (&f, filter, &shadow, actual, &error), "shadow preserve-ON applies");
  CHECK (patch_matches (actual, 0, 0.20703125, 0.04296875, 0.125, 0.37), "shadow preserve-ON oracle restores L");

  GlimsColorBalanceSettings mid = cb_settings (0, range3 (0, 0, 0), range3 (0.2, -0.1, 0.05), range3 (0, 0, 0));
  NEED (apply_and_read (&f, filter, &mid, actual, &error), "midtone correction applies");
  CHECK (patch_matches (actual, 1, 0.64, 0.43, 0.535, 0.37), "midtone preserve-OFF oracle matches (.5 gray)");
  CHECK (patch_matches (actual, 3, 1.0, 0.03, 0.335, 0.37), "midtone clamp before preserve oracle (.9/.1/.3 OFF)");
  mid.preserve_luminosity = 1;
  NEED (apply_and_read (&f, filter, &mid, actual, &error), "midtone preserve-ON clamp applies");
  CHECK (patch_matches (actual, 1, 0.6129032258, 0.3870967742, 0.5, 0.37), "midtone preserve-ON oracle matches (.5 gray)");
  CHECK (patch_matches (actual, 3, 1.0, 0.0, 0.3144329897, 0.37), "midtone clamp before preserve oracle (.9/.1/.3 ON)");

  GlimsColorBalanceSettings high = cb_settings (0, range3 (0, 0, 0), range3 (0, 0, 0), range3 (0.2, -0.1, 0.05));
  NEED (apply_and_read (&f, filter, &high, actual, &error), "highlight correction applies");
  CHECK (patch_matches (actual, 2, 1.0, 0.805, 0.91, 0.37), "highlight preserve-OFF oracle matches (.875 gray)");
  high.preserve_luminosity = 1;
  NEED (apply_and_read (&f, filter, &high, actual, &error), "highlight preserve-ON applies");
  CHECK (patch_matches (actual, 2, 1.0, 0.75, 0.8846153846, 0.37), "highlight preserve-ON oracle matches (.875 gray)");

  GlimsColorBalanceSettings transition = cb_settings (0, range3 (0.2, -0.1, 0.05),
                                                      range3 (-0.1, 0.2, -0.05), range3 (0, 0, 0));
  NEED (apply_and_read (&f, filter, &transition, actual, &error), "transition simultaneous S/M applies");
  CHECK (patch_matches (actual, 4, 0.368, 0.368, 0.333, 0.37), "transition oracle has S=.5 M=.5 H=0");
  CHECK (formula_matches (raw, actual, &transition), "transition formula matches all pixels and alpha");

  /* Whole nine sequential updates retain unmodified ranges. */
  GlimsColorBalanceSettings whole = cb_zero (1);
  whole.shadows = range3 (0.1, 0, 0);
  NEED (api->filter_color_balance_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK, "seq update 1 shadows CR");
  whole.midtones = range3 (0, -0.1, 0);
  NEED (api->filter_color_balance_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK, "seq update 2 midtones MG retains shadows");
  whole.highlights = range3 (0, 0, 0.05);
  NEED (api->filter_color_balance_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK, "seq update 3 highlights YB retains prior");
  whole.preserve_luminosity = 0;
  NEED (api->filter_color_balance_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK, "seq update 4 preserve OFF retains ranges");
  whole.shadows.magenta_green = 0.2;
  NEED (api->filter_color_balance_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK, "seq update 5 shadows MG retains others");
  whole.midtones.yellow_blue = -0.2;
  NEED (api->filter_color_balance_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK, "seq update 6 midtones YB retains others");
  whole.highlights.cyan_red = 0.3;
  NEED (api->filter_color_balance_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK, "seq update 7 highlights CR retains others");
  whole.shadows.yellow_blue = -0.05;
  NEED (api->filter_color_balance_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK, "seq update 8 shadows YB retains others");
  whole.midtones.cyan_red = 0.05;
  NEED (api->filter_color_balance_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK &&
        settings_are (&f, filter, &whole), "seq update 9 Get retains every unmodified range");
  NEED (read_pixels (&f, TRUE, actual), "sequential whole-value preview reads");
  CHECK (formula_matches (raw, actual, &whole), "sequential whole-value preview matches formula");

  /* Native cursor set to HIGHLIGHTS for getter/copy-cursor invariant. */
  s = session (&f, filter);
  GimpColorBalanceConfig *cfg = GIMP_COLOR_BALANCE_CONFIG (node_config (s->operation));
  NEED (cfg != NULL, "native config available before cursor mutation");
  g_object_set (cfg, "range", GIMP_TRANSFER_HIGHLIGHTS, NULL);
  CHECK (settings_are (&f, filter, &whole) && cfg->range == GIMP_TRANSFER_HIGHLIGHTS,
         "Get reads all ranges without changing the HIGHLIGHTS cursor");
  GlimsColorBalanceSettings after_cursor = whole;
  after_cursor.highlights.magenta_green = -0.15;
  NEED (api->filter_color_balance_set (engine, filter, &after_cursor, &error) == GLIMS_STATUS_OK,
        "Set while cursor is HIGHLIGHTS duplicates privately");
  CHECK (settings_are (&f, filter, &after_cursor) &&
         GIMP_COLOR_BALANCE_CONFIG (node_config (s->operation))->range == GIMP_TRANSFER_HIGHLIGHTS,
         "Set preserves all values and the original HIGHLIGHTS cursor");

  /* A nonzero baseline would turn zero requests into real edits. */
  GlimsColorBalanceSettings zero = cb_zero (after_cursor.preserve_luminosity);
  NEED (api->filter_color_balance_set (engine, filter, &zero, &error) == GLIMS_STATUS_OK,
        "all-positive-zero no-op baseline is installed");
  GObject *same = node_config (s->operation);
  GWeakRef same_weak; g_weak_ref_init (&same_weak, same);
  guint notifications = 0;
  gulong signal = g_signal_connect (gegl_node_get_gegl_operation (s->operation),
                                    "notify::config", G_CALLBACK (notified), &notifications);
  GlimsUndoInfo noop_history = {0};
  CHECK (api->image_undo_info (engine, f.id, &noop_history) == GLIMS_STATUS_OK,
         "no-op history baseline captured");
  for (guint i = 0; i < 10; i++) {
    GlimsColorBalanceSettings signed_zero = zero;
    double *fields[9] = {
      &signed_zero.shadows.cyan_red, &signed_zero.shadows.magenta_green, &signed_zero.shadows.yellow_blue,
      &signed_zero.midtones.cyan_red, &signed_zero.midtones.magenta_green, &signed_zero.midtones.yellow_blue,
      &signed_zero.highlights.cyan_red, &signed_zero.highlights.magenta_green, &signed_zero.highlights.yellow_blue
    };
    if (i < 9) *fields[i] = -0.0;
    else for (guint j = 0; j < 9; j++) *fields[j] = -0.0;
    gboolean changed = TRUE;
    CHECK (api->filter_color_balance_set (engine, filter, &signed_zero, &error) == GLIMS_STATUS_OK &&
           glims_color_balance_config_set (s->operation, &signed_zero, &changed, NULL) == GLIMS_STATUS_OK &&
           !changed && node_config (s->operation) == same && notifications == 0 &&
           GIMP_COLOR_BALANCE_CONFIG (same)->range == GIMP_TRANSFER_HIGHLIGHTS &&
           history_equal (&f, &noop_history),
           "signed zero in each/all nine fields is a pointer/cursor/notify/history no-op");
    clear_error (&error);
  }
  g_signal_handler_disconnect (gegl_node_get_gegl_operation (s->operation), signal);
  held = g_weak_ref_get (&same_weak);
  CHECK (held == same, "no-op weak ref still resolves to same config");
  g_clear_object (&held);
  g_weak_ref_clear (&same_weak);
  NEED (api->filter_color_balance_set (engine, filter, &after_cursor, &error) == GLIMS_STATUS_OK,
        "nonzero whole-value baseline is restored before invalid requests");
  same = node_config (s->operation);

  NEED (read_pixels (&f, TRUE, actual), "invalid baseline preview captured");
  GlimsColorBalanceSettings bad = after_cursor;
  bad.shadows.cyan_red = NAN;
  CHECK (api->filter_color_balance_set (engine, filter, &bad, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         node_config (s->operation) == same && settings_are (&f, filter, &after_cursor),
         "NaN refuses atomically without replacing config or changing values");
  clear_error (&error);
  bad = after_cursor; bad.midtones.magenta_green = INFINITY;
  CHECK (api->filter_color_balance_set (engine, filter, &bad, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "+Inf refuses");
  clear_error (&error);
  bad = after_cursor; bad.highlights.yellow_blue = -INFINITY;
  CHECK (api->filter_color_balance_set (engine, filter, &bad, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "-Inf refuses");
  clear_error (&error);
  bad = after_cursor; bad.shadows.cyan_red = -1.0001;
  CHECK (api->filter_color_balance_set (engine, filter, &bad, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "below range refuses");
  clear_error (&error);
  bad = after_cursor; bad.midtones.yellow_blue = 1.0001;
  CHECK (api->filter_color_balance_set (engine, filter, &bad, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "above range refuses");
  clear_error (&error);
  bad = after_cursor; bad.preserve_luminosity = 2;
  CHECK (api->filter_color_balance_set (engine, filter, &bad, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "preserve 2 refuses");
  clear_error (&error);
  bad = after_cursor; bad.preserve_luminosity = UINT_MAX;
  CHECK (api->filter_color_balance_set (engine, filter, &bad, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         settings_are (&f, filter, &after_cursor), "preserve UINT_MAX refuses and values unchanged");
  clear_error (&error);
  const double invalid_values[] = { NAN, INFINITY, -INFINITY, -1.01, 1.01 };
  for (guint field = 0; field < 9; field++) {
    for (guint value = 0; value < G_N_ELEMENTS (invalid_values); value++) {
      GlimsColorBalanceSettings fbad = after_cursor;
      double *vals[9] = {
        &fbad.shadows.cyan_red, &fbad.shadows.magenta_green, &fbad.shadows.yellow_blue,
        &fbad.midtones.cyan_red, &fbad.midtones.magenta_green, &fbad.midtones.yellow_blue,
        &fbad.highlights.cyan_red, &fbad.highlights.magenta_green, &fbad.highlights.yellow_blue
      };
      *vals[field] = invalid_values[value];
      CHECK (api->filter_color_balance_set (engine, filter, &fbad, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
             node_config (s->operation) == same && settings_are (&f, filter, &after_cursor),
             "each field rejects NaN/infinities/both range violations atomically");
      clear_error (&error);
    }
  }
  CHECK (read_pixels (&f, TRUE, current) && !memcmp (actual, current, sizeof actual) &&
         history_equal (&f, &noop_history), "invalid sets preserve exact preview pixels/history/config");

  g_weak_ref_init (&last_weak, node_config (s->operation)); last_init = TRUE;
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "numeric preview aborts"); filter = 0;
  held = g_weak_ref_get (&last_weak);
  CHECK (held == NULL, "aborted adapter-only config finalizes without native Undo/XCF");
  g_clear_object (&held);
  CHECK (read_pixels (&f, FALSE, current) && !memcmp (raw, current, sizeof raw) &&
         history_equal (&f, &history), "Abort leaves every stored float and history byte unchanged");

cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (old_init) g_weak_ref_clear (&old_weak);
  if (last_init) g_weak_ref_clear (&last_weak);
  clear_error (&error); fixture_close (&f); return GLIMS_STATUS_OK;
}

static gboolean
effect_rows (Fixture *f, GlimsEffectInfo *rows, int32_t capacity, int32_t *count)
{
  return api->drawable_effects (f->engine, f->id, layer_id (f), rows, capacity, count) == GLIMS_STATUS_OK;
}

static GObject *
effect_config (Fixture *f, GlimsEffectID id)
{
  GimpDrawableFilter *effect = glims_lookup_effect (f->engine, GIMP_DRAWABLE (f->layer), id);
  return effect ? node_config (gimp_drawable_filter_get_operation (effect)) : NULL;
}

static gboolean
config_values_are (GObject *object, const GlimsColorBalanceSettings *expected)
{
  if (!object || !GIMP_IS_COLOR_BALANCE_CONFIG (object)) return FALSE;
  GimpColorBalanceConfig *c = GIMP_COLOR_BALANCE_CONFIG (object);
  return c->preserve_luminosity == (gboolean) expected->preserve_luminosity &&
         c->cyan_red[GIMP_TRANSFER_SHADOWS] == expected->shadows.cyan_red &&
         c->magenta_green[GIMP_TRANSFER_SHADOWS] == expected->shadows.magenta_green &&
         c->yellow_blue[GIMP_TRANSFER_SHADOWS] == expected->shadows.yellow_blue &&
         c->cyan_red[GIMP_TRANSFER_MIDTONES] == expected->midtones.cyan_red &&
         c->magenta_green[GIMP_TRANSFER_MIDTONES] == expected->midtones.magenta_green &&
         c->yellow_blue[GIMP_TRANSFER_MIDTONES] == expected->midtones.yellow_blue &&
         c->cyan_red[GIMP_TRANSFER_HIGHLIGHTS] == expected->highlights.cyan_red &&
         c->magenta_green[GIMP_TRANSFER_HIGHLIGHTS] == expected->highlights.magenta_green &&
         c->yellow_blue[GIMP_TRANSFER_HIGHLIGHTS] == expected->highlights.yellow_blue;
}

static gboolean
effect_pair_values (Fixture *f, GlimsEffectID id, const GlimsColorBalanceSettings *expected)
{
  return config_values_are (effect_config (f, id), expected);
}

typedef struct {
  double opacity, base_opacity;
  int index, active, mode, blend, composite_space, composite_mode, clip, region, base_clip, base_region, base_mode;
} EffectState;

static EffectState effect_state (Fixture *f, GimpDrawableFilter *effect);

static gboolean
effect_state_equal (const EffectState *a, const EffectState *b)
{
  return a->opacity == b->opacity && a->base_opacity == b->base_opacity &&
         a->index == b->index && a->active == b->active && a->mode == b->mode &&
         a->blend == b->blend && a->composite_space == b->composite_space &&
         a->composite_mode == b->composite_mode && a->clip == b->clip &&
         a->region == b->region && a->base_clip == b->base_clip &&
         a->base_region == b->base_region && a->base_mode == b->base_mode;
}

static gboolean
xcf_roundtrip (Fixture *f, const char *filename, const GlimsColorBalanceSettings *expected)
{
  gboolean result = FALSE; gchar *path = g_build_filename (work_dir, filename, NULL);
  char *error = NULL; GlimsImageID opened = 0; GlimsFilterID edit = 0;
  gfloat before[VALUES], after[VALUES];
  GlimsEffectInfo before_rows[8] = {{0}};
  EffectState before_states[8]; int32_t before_count = 0;
  if (!effect_rows (f, before_rows, 8, &before_count) || before_count > 8) goto cleanup;
  for (int i = 0; i < before_count; i++) {
    GimpDrawableFilter *effect = glims_lookup_effect (f->engine, GIMP_DRAWABLE (f->layer), before_rows[i].id);
    if (!effect) goto cleanup;
    before_states[i] = effect_state (f, effect);
  }
  if (!read_pixels (f, TRUE, before) ||
      api->image_save (f->engine, f->id, path, &error) != GLIMS_STATUS_OK ||
      api->image_open (f->engine, path, &opened, &error) != GLIMS_STATUS_OK)
    goto cleanup;
  GlimsOpenImage *open = glims_lookup_image (f->engine, opened);
  GlimsLayerInfo layers[2] = {{0}}; int32_t count = 0; GlimsEffectInfo effects[8] = {{0}};
  if (!open || api->image_layers (f->engine, opened, layers, 2, &count) != GLIMS_STATUS_OK || count != 1)
    goto cleanup;
  Fixture reopened = { .engine = f->engine, .id = opened, .image = open->image,
                        .layer = GIMP_LAYER (glims_lookup_drawable (open, layers[0].id)) };
  if (!reopened.layer || !read_pixels (&reopened, TRUE, after) || !close_pixels (before, after) ||
      !effect_rows (&reopened, effects, 8, &count)) {
    fprintf (stderr, "XCF diagnostic: reopened layer=%p pixel_equal=%d\n", (void *) reopened.layer, close_pixels (before, after));
    goto cleanup;
  }
  if (count != before_count) goto cleanup;
  GlimsEffectID selected = 0;
  for (int i = 0; i < count && i < 8; i++) {
    GimpDrawableFilter *effect = glims_lookup_effect (f->engine, GIMP_DRAWABLE (f->layer), before_rows[i].id);
    GimpDrawableFilter *loaded = glims_lookup_effect (f->engine, GIMP_DRAWABLE (reopened.layer), effects[i].id);
    if (!effect || !loaded || strcmp (before_rows[i].operation, effects[i].operation)) goto cleanup;
    EffectState loaded_state = effect_state (&reopened, loaded);
    /* All four supported upstream loaders intentionally replace these three
     * stored fields with AUTO (xcf-load.c, PROP_*_SPACE/COMPOSITE_MODE).
     * They are not writable through GlimsEffectChange. Keep live edit/Undo
     * comparisons strict above; this roundtrip checks the native file contract,
     * not preservation of these currently unsupported native-only settings.
     * Original strict RED evidence is retained in the completion report. */
    EffectState file_state = before_states[i];
    file_state.blend = GIMP_LAYER_COLOR_SPACE_AUTO;
    file_state.composite_space = GIMP_LAYER_COLOR_SPACE_AUTO;
    file_state.composite_mode = GIMP_LAYER_COMPOSITE_AUTO;
    if (!effect_state_equal (&file_state, &loaded_state)) {
      const EffectState *a = &file_state, *b = &loaded_state;
      fprintf (stderr, "XCF diagnostic effect%d %s: opacity %.9g/%.9g base_opacity %.9g/%.9g index %d/%d active %d/%d mode %d/%d blend %d/%d cs %d/%d cm %d/%d clip %d/%d region %d/%d baseclip %d/%d baseregion %d/%d basemode %d/%d\n", i, effects[i].operation,
               a->opacity,b->opacity,a->base_opacity,b->base_opacity,a->index,b->index,a->active,b->active,a->mode,b->mode,a->blend,b->blend,a->composite_space,b->composite_space,a->composite_mode,b->composite_mode,a->clip,b->clip,a->region,b->region,a->base_clip,b->base_clip,a->base_region,b->base_region,a->base_mode,b->base_mode);
      goto cleanup;
    }
    if (!strcmp (effects[i].operation, "gimp:color-balance")) selected = effects[i].id;
  }
  if (!selected ||
      api->filter_edit_begin (f->engine, opened, layers[0].id, selected, &edit, &error) != GLIMS_STATUS_OK)
    goto cleanup;
  result = settings_are (&reopened, edit, expected);
cleanup:
  if (edit) api->filter_abort (f->engine, edit);
  if (opened) api->image_close (f->engine, opened);
  if (error) fprintf (stderr, "XCF: %s\n", error);
  clear_error (&error); g_free (path); return result;
}

static GlimsStatus
new_effect (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  GlimsUndoInfo before = {0}, after = {0}; GlimsEffectInfo rows[2] = {{0}}; int32_t count = 0;
  gfloat raw[VALUES], preview[VALUES], actual[VALUES];
  NEED (fixture_open (engine, &f) && read_pixels (&f, FALSE, raw) &&
        api->image_undo_info (engine, f.id, &before) == GLIMS_STATUS_OK,
        "new-effect fixture captures raw pixels and actual history");
  GlimsColorBalanceSettings settings = cb_settings (0, range3 (0.2, -0.1, 0.05),
                                                     range3 (-0.1, 0.2, -0.05),
                                                     range3 (0, 0, 0.1));
  settings.preserve_luminosity = 1;
  NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK &&
        api->filter_color_balance_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
        read_pixels (&f, TRUE, preview), "new effect preview accepts a nondefault whole value");
  CHECK (formula_matches (raw, preview, &settings), "accepted new-effect preview matches independent formula");
  NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "new effect Apply succeeds"); filter = 0;
  CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK &&
         after.undo_count == before.undo_count + 1, "new effect Apply adds exactly one Undo step");
  CHECK (read_pixels (&f, FALSE, actual) && !memcmp (raw, actual, sizeof raw), "ND Apply does not alter stored source floats");
  NEED (effect_rows (&f, rows, 2, &count) && count == 1 && effect_pair_values (&f, rows[0].id, &settings),
        "committed effect has the exact whole value");
  CHECK (read_pixels (&f, TRUE, actual) && close_pixels (preview, actual), "Apply displays the accepted preview");
  NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "new effect undoes once");
  CHECK (effect_rows (&f, rows, 2, &count) && count == 0 && read_pixels (&f, TRUE, actual) && close_pixels (raw, actual),
         "one Undo removes the effect and restores original RGBA");
  NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "new effect redoes once");
  CHECK (effect_rows (&f, rows, 2, &count) && count == 1 && effect_pair_values (&f, rows[0].id, &settings) &&
         read_pixels (&f, TRUE, actual) && close_pixels (preview, actual),
         "Redo restores exact settings and accepted colors");
  CHECK (xcf_roundtrip (&f, "cb-new.xcf", &settings), "XCF fresh reopen preserves actual Color Balance and pixels");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f); return GLIMS_STATUS_OK;
}

static EffectState
effect_state (Fixture *f, GimpDrawableFilter *effect)
{
  EffectState state; memset (&state, 0, sizeof state);
  if (!effect) { state.index = INT_MIN; return state; }
  state.opacity = gimp_drawable_filter_get_opacity (effect);
  state.index = gimp_container_get_child_index (gimp_drawable_get_filters (GIMP_DRAWABLE (f->layer)), GIMP_OBJECT (effect));
  state.active = gimp_filter_get_active (GIMP_FILTER (effect));
  state.mode = gimp_drawable_filter_get_paint_mode (effect);
  state.blend = gimp_drawable_filter_get_blend_space (effect);
  state.composite_space = gimp_drawable_filter_get_composite_space (effect);
  state.composite_mode = gimp_drawable_filter_get_composite_mode (effect);
  state.clip = gimp_drawable_filter_get_clip (effect); state.region = gimp_drawable_filter_get_region (effect);
  GObject *config = node_config (gimp_drawable_filter_get_operation (effect));
  if (!config || !GIMP_IS_OPERATION_SETTINGS (config)) { state.base_clip = INT_MIN; return state; }
  GimpOperationSettings *base = GIMP_OPERATION_SETTINGS (config);
  state.base_opacity = base->opacity; state.base_clip = base->clip;
  state.base_region = base->region; state.base_mode = base->mode;
  return state;
}

static gboolean
native_base_equal (GObject *a, GObject *b)
{
  if (!a || !b || !GIMP_IS_OPERATION_SETTINGS (a) || !GIMP_IS_OPERATION_SETTINGS (b)) return FALSE;
  GimpOperationSettings *x = GIMP_OPERATION_SETTINGS (a), *y = GIMP_OPERATION_SETTINGS (b);
  return x->opacity == y->opacity && x->clip == y->clip && x->region == y->region && x->mode == y->mode;
}

static GlimsStatus
existing_effect (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  for (guint disabled = 0; disabled < 2; disabled++) {
    Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
    GObject *saved_a = NULL, *saved_b = NULL;
    GlimsEffectInfo rows[4] = {{0}}; int32_t count = 0; GlimsUndoInfo before = {0}, after = {0};
    gfloat original[VALUES], accepted[VALUES], actual[VALUES];
    NEED (fixture_open (engine, &f) && begin (&f, &filter, &error) == GLIMS_STATUS_OK,
          "existing-effect fixture begins with a unique unsnapshotted config");
    GlimsFilter *s = session (&f, filter);
    NEED (s && node_config (s->operation), "unique config exists before base-field fixture seeding");
    GObject *seed = node_config (s->operation);
    GObjectClass *klass = G_OBJECT_GET_CLASS (seed);
    NEED (GIMP_IS_OPERATION_SETTINGS (seed) &&
          g_object_class_find_property (klass, "gimp-opacity") &&
          g_object_class_find_property (klass, "gimp-clip") &&
          g_object_class_find_property (klass, "gimp-region") &&
          g_object_class_find_property (klass, "gimp-mode"),
          "native inherited base properties are registered with actual prefixed names");
    g_object_set (seed, "gimp-opacity", 0.625, "gimp-clip", GIMP_TRANSFORM_RESIZE_CLIP,
                  "gimp-region", GIMP_FILTER_REGION_DRAWABLE, "gimp-mode", GIMP_LAYER_MODE_MULTIPLY, NULL);
    GlimsColorBalanceSettings A = cb_settings (1, range3 (0.1, -0.2, 0.05), range3 (0, 0, 0), range3 (0, 0, 0));
    GlimsColorBalanceSettings B = cb_settings (0, range3 (0.1, -0.2, 0.05), range3 (-0.3, 0.25, 0), range3 (0, 0, 0));
    GlimsColorBalanceSettings C = cb_settings (1, range3 (0.1, -0.2, 0.05), range3 (-0.3, 0.25, 0), range3 (0.4, -0.35, 0.1));
    NEED (api->filter_color_balance_set (engine, filter, &A, &error) == GLIMS_STATUS_OK, "initial immutable A replacement succeeds");
    GimpOperationSettings *base = GIMP_OPERATION_SETTINGS (node_config (s->operation));
    NEED (base->opacity == 0.625 && base->clip == GIMP_TRANSFORM_RESIZE_CLIP &&
          base->region == GIMP_FILTER_REGION_DRAWABLE && base->mode == GIMP_LAYER_MODE_MULTIPLY,
          "first immutable duplicate preserves independently seeded native base fields");
    NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "initial immutable A config commits"); filter = 0;
    NEED (effect_rows (&f, rows, 4, &count) && count == 1, "one real committed CB effect is present");
    GlimsEffectID effect_id = rows[0].id;
    NEED (api->filter_begin (engine, f.id, layer_id (&f), "gegl:invert-linear", &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK,
          "second real effect gives CB a meaningful stack position"); filter = 0;
    GimpDrawableFilter *effect = glims_lookup_effect (engine, GIMP_DRAWABLE (f.layer), effect_id);
    NEED (effect != NULL, "committed original effect resolves by captured ID");
    gimp_filter_set_active (GIMP_FILTER (effect), !disabled);
    gimp_drawable_filter_set_opacity (effect, 0.75);
    gimp_drawable_filter_set_mode (effect, GIMP_LAYER_MODE_MULTIPLY, GIMP_LAYER_COLOR_SPACE_RGB_LINEAR,
                                   GIMP_LAYER_COLOR_SPACE_RGB_LINEAR, GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP);
    gimp_drawable_filter_set_clip (effect, FALSE);
    gimp_drawable_filter_set_region (effect, GIMP_FILTER_REGION_DRAWABLE);
    gimp_drawable_update (GIMP_DRAWABLE (f.layer), 0, 0, -1, -1);
    EffectState state = effect_state (&f, effect);
    saved_a = g_object_ref (node_config (gimp_drawable_filter_get_operation (effect)));
    NEED (read_pixels (&f, TRUE, original) && api->image_undo_info (engine, f.id, &before) == GLIMS_STATUS_OK &&
          api->filter_edit_begin (engine, f.id, layer_id (&f), effect_id, &filter, &error) == GLIMS_STATUS_OK,
          "captured original begins an edit shadow");
    NEED (api->filter_color_balance_set (engine, filter, &B, &error) == GLIMS_STATUS_OK, "shadow changes A to B");
    saved_b = g_object_ref (node_config (session (&f, filter)->operation));
    NEED (api->filter_color_balance_set (engine, filter, &C, &error) == GLIMS_STATUS_OK, "shadow changes B to C");
    CHECK (effect_pair_values (&f, effect_id, &A) &&
           native_base_equal (saved_a, node_config (gimp_drawable_filter_get_operation (effect))),
           "B and C replacements never mutate installed A config or native base fields");
    CHECK (config_values_are (saved_a, &A) && config_values_are (saved_b, &B),
           "all nine/preserve values in original A and earlier B stay immutable");
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "existing-effect Cancel drops only the shadow"); filter = 0;
    EffectState current = effect_state (&f, effect);
    CHECK (effect_state_equal (&state, &current) && effect_pair_values (&f, effect_id, &A) &&
           history_equal (&f, &before) && read_pixels (&f, TRUE, actual) && close_pixels (original, actual),
           "Cancel preserves enabled state, stack, blend/base, pixels and history");
    NEED (api->filter_edit_begin (engine, f.id, layer_id (&f), effect_id, &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_color_balance_set (engine, filter, &B, &error) == GLIMS_STATUS_OK &&
          api->filter_color_balance_set (engine, filter, &C, &error) == GLIMS_STATUS_OK &&
          api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "existing shadow A to B to C Applies"); filter = 0;
    current = effect_state (&f, effect);
    CHECK (effect_state_equal (&state, &current) && effect_pair_values (&f, effect_id, &C),
           "Apply retains original effect ID/order/enabled/blend/base settings and installs C");
    CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
           "existing-effect Apply adds exactly one additional Undo");
    NEED (read_pixels (&f, TRUE, accepted), "accepted C pixels can be captured");
    if (!disabled) CHECK (!close_pixels (original, accepted), "enabled existing-effect edit really changes visible pixels");
    NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "existing-effect Apply undoes once");
    current = effect_state (&f, effect);
    CHECK (effect_state_equal (&state, &current) && effect_pair_values (&f, effect_id, &A) &&
           read_pixels (&f, TRUE, actual) && close_pixels (original, actual),
           "Undo restores exact A settings, original state and pixels");
    NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "existing-effect edit redoes once");
    current = effect_state (&f, effect);
    CHECK (effect_state_equal (&state, &current) && effect_pair_values (&f, effect_id, &C) &&
           read_pixels (&f, TRUE, actual) && close_pixels (accepted, actual),
           "Redo restores C settings/state/pixels");
    CHECK (config_values_are (saved_a, &A) && config_values_are (saved_b, &B),
           "all nine/preserve witness values stay immutable across native Undo/Redo");
    CHECK (xcf_roundtrip (&f, disabled ? "cb-existing-disabled.xcf" : "cb-existing-enabled.xcf", &C),
           "XCF preserves all-nine/preserve config, base/order/active/pixels with native AUTO composite normalization");
cleanup:
    if (filter) api->filter_abort (engine, filter);
    g_clear_object (&saved_a); g_clear_object (&saved_b); clear_error (&error); fixture_close (&f);
  }
  return GLIMS_STATUS_OK;
}

static gboolean
block_history (Fixture *f, guint mode)
{
  if (mode == 0) return gimp_image_undo_disable (f->image);
  if (mode == 1) return gimp_image_undo_freeze (f->image);
  return gimp_image_undo_group_start (f->image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "CB history guard");
}

static void
unblock_history (Fixture *f, guint mode)
{
  if (mode == 0) gimp_image_undo_enable (f->image);
  else if (mode == 1) gimp_image_undo_thaw (f->image);
  else gimp_image_undo_group_end (f->image);
}

static void
refuses_begin (Fixture *f, GlimsStatus expected, const char *description)
{
  GlimsFilterID filter = 123456; char *error = NULL; GlimsUndoInfo history = {0};
  gfloat before[VALUES], after[VALUES];
  gboolean captured = read_pixels (f, FALSE, before) &&
                      api->image_undo_info (f->engine, f->id, &history) == GLIMS_STATUS_OK;
  CHECK (captured, "refusal captures real raw pixels/history before request");
  if (!captured) return;
  guint sessions_before = g_hash_table_size (f->engine->filters);
  GlimsStatus status = begin (f, &filter, &error);
  CHECK (status == expected && filter == 0, description);
  CHECK (read_pixels (f, FALSE, after) && !memcmp (before, after, sizeof before) &&
         history_equal (f, &history) && g_hash_table_size (f->engine->filters) == sessions_before,
         "refused Begin has no raw pixel/history/session mutation");
  if (status == GLIMS_STATUS_OK && filter) api->filter_abort (f->engine, filter);
  clear_error (&error);
}

static GlimsStatus
history_guards (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  for (guint mode = 0; mode < 3; mode++) {
    Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL; gboolean blocked = FALSE;
    GlimsUndoInfo history = {0}, after = {0}; gfloat raw[VALUES], actual[VALUES];
    NEED (fixture_open (engine, &f), "history guard opens an independent image");
    blocked = block_history (&f, mode);
    NEED (blocked, "history disables/freezes/opens an outer group before Begin");
    refuses_begin (&f, GLIMS_STATUS_BUSY, "disabled/frozen/grouped Undo refuses new CB Begin");
    unblock_history (&f, mode); blocked = FALSE;
    GlimsColorBalanceSettings settings = cb_settings (0, range3 (0.2, -0.3, 0), range3 (0, 0, 0), range3 (0, 0, 0));
    NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_color_balance_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK,
          "valid preview opens before commit history becomes unavailable");
    blocked = block_history (&f, mode); NEED (blocked, "history changes while preview is open");
    NEED (read_pixels (&f, FALSE, raw) &&
          api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK,
          "blocked-commit baseline is captured after the external history transition");
    CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_BUSY && session (&f, filter),
           "blocked commit returns BUSY and retains the same session"); clear_error (&error);
    CHECK (read_pixels (&f, FALSE, actual) && !memcmp (raw, actual, sizeof raw) && history_equal (&f, &history),
           "blocked commit leaves raw pixels/history unchanged");
    if (mode == 1) {
      unblock_history (&f, mode); blocked = FALSE;
      NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK,
            "thaw permits retry on the same preview"); filter = 0;
      CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK &&
             after.undo_count == history.undo_count + 1, "thaw-and-retry commits one Undo");
    } else {
      NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "Abort remains allowed while Undo is unavailable");
      filter = 0;
      CHECK (history_equal (&f, &history), "blocked-session Abort adds no history");
    }
cleanup:
    if (filter) api->filter_abort (engine, filter);
    if (blocked) unblock_history (&f, mode);
    clear_error (&error); fixture_close (&f);
  }
  return GLIMS_STATUS_OK;
}

static GlimsStatus
refusals (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; GlimsStrokeID stroke = 0; char *error = NULL;
  NEED (fixture_open (engine, &f), "refusal fixture opens");
  GlimsColorBalanceSettings settings = cb_settings (1, range3 (0.25, 0.1, 0), range3 (0, 0, 0), range3 (0, 0, 0));
  GlimsColorBalanceSettings output = cb_settings (1, range3 (7, 8, 9), range3 (7, 8, 9), range3 (7, 8, 9));
  GlimsColorBalanceSettings zero_output = cb_zero (0);
  CHECK (api->filter_color_balance_get (engine, INT_MAX, &output, &error) == GLIMS_STATUS_NOT_FOUND &&
         settings_equal (&output, &zero_output) && output.struct_size == sizeof output,
         "stale Get reports NOT_FOUND and resets every owned field without changing size");
  clear_error (&error);
  CHECK (api->filter_color_balance_set (engine, INT_MAX, &settings, &error) == GLIMS_STATUS_NOT_FOUND, "stale Set refuses");
  clear_error (&error);
  CHECK (api->filter_color_balance_get (engine, INT_MAX, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "NULL Get output refuses before lookup");
  clear_error (&error);

  engine->busy++; refuses_begin (&f, GLIMS_STATUS_BUSY, "exclusive native work refuses Begin"); engine->busy--;
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), TRUE, FALSE);
  refuses_begin (&f, GLIMS_STATUS_LOCKED, "effective pixel lock refuses Begin");
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), FALSE, FALSE);

  NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK, "typed-write refusal preview opens");
  GlimsFilter *s = session (&f, filter); GObject *config = node_config (s->operation);
  gfloat raw[VALUES], after[VALUES]; GlimsUndoInfo history = {0};
  NEED (read_pixels (&f, FALSE, raw) && api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK,
        "typed refusals capture actual raw/history baseline");
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), TRUE, FALSE);
  CHECK (api->filter_color_balance_set (engine, filter, &settings, &error) == GLIMS_STATUS_LOCKED &&
         node_config (s->operation) == config, "locked Set preserves the installed config");
  clear_error (&error);
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), FALSE, FALSE);
  engine->busy++;
  GlimsStatus status = api->filter_color_balance_set (engine, filter, &settings, &error);
  engine->busy--;
  CHECK (status == GLIMS_STATUS_BUSY && node_config (s->operation) == config, "busy Set preserves the installed config");
  clear_error (&error);

  GlimsColorBalanceSettings small = cb_zero (1); small.struct_size = sizeof small - 1;
  GlimsColorBalanceSettings expected_default = cb_zero (1);
  CHECK (api->filter_color_balance_set (engine, filter, &small, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->filter_color_balance_set (engine, filter, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         settings_are (&f, filter, &expected_default),
         "undersized and NULL settings refuse without changing settings");
  clear_error (&error);
  CHECK (read_pixels (&f, FALSE, after) && !memcmp (raw, after, sizeof raw) && history_equal (&f, &history),
         "typed write refusals preserve raw pixels/history");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "refusal preview aborts"); filter = 0;

  NEED (api->filter_begin (engine, f.id, layer_id (&f), "gegl:invert-linear", &filter, &error) == GLIMS_STATUS_OK,
        "wrong-operation preview starts independently");
  CHECK (api->filter_color_balance_get (engine, filter, &output, &error) == GLIMS_STATUS_UNSUPPORTED &&
         api->filter_color_balance_set (engine, filter, &settings, NULL) == GLIMS_STATUS_UNSUPPORTED,
         "typed get/set refuse a real non-CB operation");
  clear_error (&error);
  refuses_begin (&f, GLIMS_STATUS_BUSY, "another active preview refuses CB Begin");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "wrong-operation preview aborts"); filter = 0;

  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PAINTBRUSH,
                               .size = 3, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint point = {2, 2, 1, 0, 0, 0};
  NEED (api->stroke_begin (engine, f.id, layer_id (&f), &brush, &point, &stroke, &error) == GLIMS_STATUS_OK,
        "real stroke starts for admission regression");
  refuses_begin (&f, GLIMS_STATUS_BUSY, "active native stroke refuses CB Begin");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (stroke) api->stroke_end (engine, stroke);
  if (f.layer) gimp_item_set_lock_content (GIMP_ITEM (f.layer), FALSE, FALSE);
  clear_error (&error); fixture_close (&f); return GLIMS_STATUS_OK;
}

typedef struct { Fixture f; GlimsItemID target; } PublicFixture;
static GlimsStatus public_setup (GlimsEngine *engine, gpointer data) {
  PublicFixture *p = data;
  if (!fixture_open (engine, &p->f)) return GLIMS_STATUS_FAILED;
  p->target = layer_id (&p->f); return GLIMS_STATUS_OK;
}
static GlimsStatus public_cleanup (GlimsEngine *engine, gpointer data) {
  (void) engine; PublicFixture *p = data; fixture_close (&p->f); return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  work_dir = argv[1]; api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api ||
      !api->filter_color_balance_get || !api->filter_color_balance_set) return 2;
  char *error = NULL; GlimsColorBalanceSettings output = cb_settings (1, range3 (7, 8, 9), range3 (7, 8, 9), range3 (7, 8, 9));
  GlimsColorBalanceSettings zero_output = cb_zero (0);
  struct { GlimsColorBalanceSettings value; guint64 tail; } stopped;
  memset (&stopped, 0xA5, sizeof stopped); stopped.value.struct_size = sizeof stopped;
  guint64 stopped_tail = stopped.tail;
  CHECK (api->filter_color_balance_get (NULL, 1, &stopped.value, &error) == GLIMS_STATUS_NOT_RUNNING &&
         settings_equal (&stopped.value, &zero_output) && stopped.value.struct_size == sizeof stopped &&
         stopped.tail == stopped_tail,
         "nonrunning slot150 resets all owned fields while preserving size/future tail");
  clear_error (&error);

  gchar *user = g_build_filename (work_dir, "user", NULL), *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed");
    clear_error (&error); g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, formula_and_lifetime, NULL) == GLIMS_STATUS_OK,
         "formula/lifetime fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, new_effect, NULL) == GLIMS_STATUS_OK,
         "new effect/Undo/XCF fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, existing_effect, NULL) == GLIMS_STATUS_OK,
         "immutable existing-effect fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, history_guards, NULL) == GLIMS_STATUS_OK,
         "history guard fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, refusals, NULL) == GLIMS_STATUS_OK,
         "admission/refusal fixtures run on the engine worker");

  PublicFixture public = {0}; GlimsFilterID filter = 0;
  if (glims_engine_call (engine, public_setup, &public) == GLIMS_STATUS_OK) {
    CHECK (api->filter_begin (engine, public.f.id, public.target, "gimp:color-balance", &filter, &error) == GLIMS_STATUS_OK &&
           filter > 0, "public host-thread preview starts");
    clear_error (&error);
    if (filter) {
      GlimsColorBalanceSettings settings = cb_settings (0, range3 (0.375, -0.625, 0.1),
                                                        range3 (-0.2, 0.2, -0.1),
                                                        range3 (0.05, 0, -0.05));
      output = cb_zero (1);
      CHECK (api->filter_color_balance_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
             api->filter_color_balance_get (engine, filter, &output, NULL) == GLIMS_STATUS_OK &&
             settings_equal (&output, &settings),
             "public host-thread slots150/151 marshal the exact complete value");
      clear_error (&error);
      struct { GlimsColorBalanceSettings value; guint64 tail; } sized, before;
      memset (&sized, 0xA5, sizeof sized); sized.value.struct_size = sizeof sized.value - 1; before = sized;
      CHECK (api->filter_color_balance_get (engine, filter, &sized.value, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
             !memcmp (&sized, &before, sizeof sized),
             "undersized Get leaves all caller sentinel bytes untouched");
      clear_error (&error);
      memset (&sized, 0xA5, sizeof sized); sized.value.struct_size = sizeof sized; before = sized;
      CHECK (api->filter_color_balance_get (engine, filter, &sized.value, &error) == GLIMS_STATUS_OK &&
             sized.tail == before.tail && settings_equal (&sized.value, &settings),
             "valid extensible Get does not overwrite a future caller tail");
      clear_error (&error);
      CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "public preview aborts");
    }
  } else CHECK (FALSE, "public fixture setup succeeds");
  glims_engine_call (engine, public_cleanup, &public);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}

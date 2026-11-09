/* Core-only fixtures. Never free borrowed selected-layer lists or compensate
 * for native Undo/XCF config-setter retention with extra unrefs. */
#include "engine-private.h"
#include "hue-saturation-config.h"
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
#include "operations/gimphuesaturationconfig.h"
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

static GlimsHueSaturationRange
range3 (double hue, double saturation, double lightness)
{
  GlimsHueSaturationRange r = { hue, saturation, lightness };
  return r;
}

static GlimsHueSaturationSettings
hs_settings (double overlap,
             GlimsHueSaturationRange master,
             GlimsHueSaturationRange red,
             GlimsHueSaturationRange yellow)
{
  GlimsHueSaturationSettings s;
  memset (&s, 0, sizeof s);
  s.struct_size = sizeof s;
  s.overlap = overlap;
  s.master = master;
  s.red = red;
  s.yellow = yellow;
  return s;
}

static GlimsHueSaturationSettings
hs_zero (void)
{
  return hs_settings (0.0, range3 (0, 0, 0), range3 (0, 0, 0), range3 (0, 0, 0));
}

static GlimsHueSaturationSettings
hs_rich (double overlap, double v)
{
  GlimsHueSaturationSettings s = hs_zero ();
  s.overlap = overlap;
  s.master = range3 (v, -0.08, 0.03);
  s.red = range3 (0.03, v, -0.04);
  s.yellow = range3 (-0.04, 0.07, v);
  s.green = range3 (0.05, -0.06, 0.02);
  s.cyan = range3 (-0.08, 0.04, -0.03);
  s.blue = range3 (0.09, -0.03, 0.06);
  s.magenta = range3 (-0.07, 0.05, -0.02);
  return s;
}

static gboolean
range_equal (const GlimsHueSaturationRange *a, const GlimsHueSaturationRange *b)
{
  return a->hue == b->hue && a->saturation == b->saturation && a->lightness == b->lightness;
}

static gboolean
settings_equal (const GlimsHueSaturationSettings *a, const GlimsHueSaturationSettings *b)
{
  return a->overlap == b->overlap && range_equal (&a->master, &b->master) &&
         range_equal (&a->red, &b->red) && range_equal (&a->yellow, &b->yellow) &&
         range_equal (&a->green, &b->green) && range_equal (&a->cyan, &b->cyan) &&
         range_equal (&a->blue, &b->blue) && range_equal (&a->magenta, &b->magenta);
}

/* Explicit pointers to named members; no pointer arithmetic across structs. */
static void
settings_fields (GlimsHueSaturationSettings *s, double *p[22])
{
  double *fields[] = {
    &s->overlap,
    &s->master.hue, &s->master.saturation, &s->master.lightness,
    &s->red.hue, &s->red.saturation, &s->red.lightness,
    &s->yellow.hue, &s->yellow.saturation, &s->yellow.lightness,
    &s->green.hue, &s->green.saturation, &s->green.lightness,
    &s->cyan.hue, &s->cyan.saturation, &s->cyan.lightness,
    &s->blue.hue, &s->blue.saturation, &s->blue.lightness,
    &s->magenta.hue, &s->magenta.saturation, &s->magenta.lightness
  };
  memcpy (p, fields, sizeof fields);
}

static void
source_patch (gfloat *p, double r, double g, double b, double a)
{
  p[0] = (gfloat) r; p[1] = (gfloat) g; p[2] = (gfloat) b; p[3] = (gfloat) a;
}

typedef struct {
  const char *name;
  double input[4], expected_hsla[4], expected_rgba[4];
  GlimsHueSaturationSettings settings;
} NumericCase;

/* Independent literal cases from hue-saturation-derived-oracles.json; no
 * native mapping helper is used to calculate expectations at runtime. */
static const NumericCase numeric_cases[] = {
  { "identity",
    { 0.75, 0.25, 0.25, 0.37 }, { 0, 0.5, 0.5, 0.37 },
    { 0.75, 0.25, 0.25, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0 } },
  { "master hue +60 degrees",
    { 1, 0, 0, 0.37 }, { 0.16666666669999999, 1, 0.5, 0.37 },
    { 1, 1, 0, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .master = { 0.33333333333333331, 0, 0 } } },
  { "master hue -60 degrees",
    { 1, 0, 0, 0.37 }, { 0.83333333330000003, 1, 0.5, 0.37 },
    { 1, 0, 1, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .master = { -0.33333333333333331, 0, 0 } } },
  { "only red hue +60 degrees",
    { 1, 0, 0, 0.37 }, { 0.16666666669999999, 1, 0.5, 0.37 },
    { 1, 1, 0, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .red = { 0.33333333333333331, 0, 0 } } },
  { "only yellow hue +60 degrees",
    { 1, 1, 0, 0.37 }, { 0.33333333329999998, 1, 0.5, 0.37 },
    { 0, 1, 0, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .yellow = { 0.33333333333333331, 0, 0 } } },
  { "only green hue +60 degrees",
    { 0, 1, 0, 0.37 }, { 0.5, 1, 0.5, 0.37 },
    { 0, 1, 1, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .green = { 0.33333333333333331, 0, 0 } } },
  { "only cyan hue +60 degrees",
    { 0, 1, 1, 0.37 }, { 0.66666666669999997, 1, 0.5, 0.37 },
    { 0, 0, 1, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .cyan = { 0.33333333333333331, 0, 0 } } },
  { "only blue hue +60 degrees",
    { 0, 0, 1, 0.37 }, { 0.83333333330000003, 1, 0.5, 0.37 },
    { 1, 0, 1, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .blue = { 0.33333333333333331, 0, 0 } } },
  { "only magenta hue +60 degrees",
    { 1, 0, 1, 0.37 }, { 1, 1, 0.5, 0.37 },
    { 1, 0, 0, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .magenta = { 0.33333333333333331, 0, 0 } } },
  { "additive saturation master+.2 red+.3",
    { 0.625, 0.375, 0.375, 0.37 }, { 0, 0.375, 0.5, 0.37 },
    { 0.6875, 0.3125, 0.3125, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .master = { 0, 0.20000000000000001, 0 }, .red = { 0, 0.29999999999999999, 0 } } },
  { "positive lightness sums before map",
    { 0.375, 0.125, 0.125, 0.37 }, { 0, 0.5, 0.625, 0.37 },
    { 0.8125, 0.4375, 0.4375, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .master = { 0, 0, 0.20000000000000001 }, .red = { 0, 0, 0.29999999999999999 } } },
  { "negative lightness sums before map",
    { 0.375, 0.125, 0.125, 0.37 }, { 0, 0.5, 0.125, 0.37 },
    { 0.1875, 0.0625, 0.0625, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .master = { 0, 0, -0.20000000000000001 }, .red = { 0, 0, -0.29999999999999999 } } },
  { "gray uses master lightness only",
    { 0.25, 0.25, 0.25, 0.37 }, { 0, 0, 0.40000000000000002, 0.37 },
    { 0.40000000000000002, 0.40000000000000002, 0.40000000000000002, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .master = { 0, 0, 0.20000000000000001 }, .red = { 0, 0, 0.29999999999999999 } } },
  { "classification precedes changed hue",
    { 1, 0, 0, 0.37 }, { 0.16666666669999999, 0, 0.5, 0.37 },
    { 0.5, 0.5, 0.5, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .master = { 0.33333333333333331, 0, 0 }, .red = { 0, -1, 0 } } },
  { "boundary no-overlap chooses yellow",
    { 1, 0.5, 0, 0.37 }, { 0.83333333330000003, 1, 0.5, 0.37 },
    { 1, 0, 1, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .red = { 0.5, 0, 0 }, .yellow = { -0.5, 0, 0 } } },
  { "boundary overlap interpolates hue before wrap",
    { 1, 0.5, 0, 0.37 }, { 0.083333333300000006, 1, 0.5, 0.37 },
    { 1, 0.5, 0, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 1, .red = { 0.5, 0, 0 }, .yellow = { -0.5, 0, 0 } } },
  { "quarter-sector no overlap",
    { 1, 0.25, 0, 0.37 }, { 0.29166666670000002, 1, 0.5, 0.37 },
    { 0.25, 1, 0, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .red = { 0.5, 0, 0 }, .yellow = { -0.5, 0, 0 } } },
  { "quarter-sector overlap weights75/25",
    { 1, 0.25, 0, 0.37 }, { 0.16666666669999999, 1, 0.5, 0.37 },
    { 1, 1, 0, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 1, .red = { 0.5, 0, 0 }, .yellow = { -0.5, 0, 0 } } },
  { "magenta-red wraparound interpolation",
    { 1, 0, 0.5, 0.37 }, { 0.91666666669999997, 1, 0.5, 0.37 },
    { 1, 0, 0.5, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 1, .red = { 1, 0, 0 }, .magenta = { -1, 0, 0 } } },
  { "saturation clamps neighbors before blend",
    { 0.875, 0.5, 0.125, 0.37 }, { 0.083333333300000006, 0.875, 0.5, 0.37 },
    { 0.9375, 0.5, 0.0625, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 1, .master = { 0, 0.5, 0 }, .red = { 0, 0.5, 0 }, .yellow = { 0, -0.5, 0 } } },
  { "lightness maps each neighbor before blend",
    { 0.375, 0.25, 0.125, 0.37 }, { 0.083333333300000006, 0.5, 0.375, 0.37 },
    { 0.5625, 0.375, 0.1875, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 1, .red = { 0, 0, -0.5 }, .yellow = { 0, 0, 0.5 } } },
  { "combined lightness can exceed1 before downstream handling",
    { 0.75, 0.25, 0.25, 0.37 }, { 0, 0.5, 1.3, 0.37 },
    { 1.1499999999999999, 1.45, 1.45, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .master = { 0, 0, 0.80000000000000004 }, .red = { 0, 0, 0.80000000000000004 } } },
  { "master and local +180 sum to360",
    { 1, 0, 0, 0.37 }, { 1, 1, 0.5, 0.37 },
    { 1, 0, 0, 0.37 },
    { .struct_size = sizeof (GlimsHueSaturationSettings), .overlap = 0, .master = { 1, 0, 0 }, .red = { 1, 0, 0 } } },
};

static gboolean
fixture_open (GlimsEngine *engine, Fixture *f)
{
  memset (f, 0, sizeof *f); f->engine = engine;
  /* The drawable is nonlinear sRGB FLOAT; the native operation prepares HSLA. */
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
    guint patch = i / 4;
    if (patch < G_N_ELEMENTS (numeric_cases)) {
      const double *q = numeric_cases[patch].input;
      source_patch (&pixels[i], q[0], q[1], q[2], q[3]);
    } else {
      source_patch (&pixels[i], 0.25, 0.5, 0.75, patch % 2 ? 1.0 : 0.0);
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
  return api->filter_begin (f->engine, f->id, layer_id (f), "gimp:hue-saturation",
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
settings_are (Fixture *f, GlimsFilterID id, const GlimsHueSaturationSettings *expected)
{
  GlimsHueSaturationSettings actual = hs_zero ();
  actual.struct_size = sizeof actual;
  return api->filter_hue_saturation_get (f->engine, id, &actual, NULL) == GLIMS_STATUS_OK &&
         settings_equal (&actual, expected);
}

static void
notified (GObject *object, GParamSpec *spec, gpointer data)
{
  (void) object; (void) spec; (*(guint *) data)++;
}

/* Independent standard HSL (babl HSL.c contract) and Hue-Saturation formula.
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

static const GlimsHueSaturationRange *
local_range (const GlimsHueSaturationSettings *s, int sector)
{
  switch (sector % 6) {
    case 0: return &s->red; case 1: return &s->yellow;
    case 2: return &s->green; case 3: return &s->cyan;
    case 4: return &s->blue; default: return &s->magenta;
  }
}

static double
map_light (double l, double correction)
{
  return correction < 0 ? l * (1 + correction) : l + correction * (1 - l);
}

/* Independent standard HSL plus circular sector centers at 0,60,...300deg.
 * Blend per-neighbor saturation clamps and lightness maps, never RGB colors. */
static void
hs_formula_rgb (double r, double g, double b, const GlimsHueSaturationSettings *s,
                double *out_r, double *out_g, double *out_b)
{
  double h, sat, l;
  rgb_to_hsl (r, g, b, &h, &sat, &l);
  double turns = h * 6.0, half = s->overlap / 2.0, weight = 0;
  int first = (int) floor (turns + 0.5), second = first;
  if (half > 0) {
    int left = (int) floor (turns);
    double boundary = left + 0.5;
    if (turns >= boundary - half && turns < boundary + half) {
      first = left; second = left + 1;
      weight = (turns - boundary + half) / (2.0 * half);
    }
  }
  const GlimsHueSaturationRange *a = local_range (s, first);
  const GlimsHueSaturationRange *b_range = local_range (s, second);
  if (sat <= 0 && weight == 0) {
    l = map_light (l, s->master.lightness);
  } else {
    h += (s->master.hue + a->hue * (1 - weight) + b_range->hue * weight) / 2;
    if (h < 0) h += 1; else if (h > 1) h -= 1;
    double sa = clamp01 (sat * (1 + s->master.saturation + a->saturation));
    double sb = clamp01 (sat * (1 + s->master.saturation + b_range->saturation));
    sat = sa * (1 - weight) + sb * weight;
    l = map_light (l, s->master.lightness + a->lightness) * (1 - weight) +
        map_light (l, s->master.lightness + b_range->lightness) * weight;
  }
  hsl_to_rgb (h, sat, l, out_r, out_g, out_b);
}

static gboolean
formula_matches (const gfloat *source, const gfloat *actual,
                 const GlimsHueSaturationSettings *s)
{
  for (guint i = 0; i < VALUES; i += 4) {
    double er, eg, eb;
    hs_formula_rgb (source[i], source[i + 1], source[i + 2], s, &er, &eg, &eb);
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

static GlimsStatus
formula_and_lifetime (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  gfloat raw[VALUES], actual[VALUES], current[VALUES]; GlimsUndoInfo history = {0};
  GWeakRef old_weak, last_weak; gboolean old_init = FALSE, last_init = FALSE;
  GObject *held = NULL;
  GeglNode *probe = gegl_node_new_child (NULL, "operation", "gimp:hue-saturation", NULL);
  GlimsHueSaturationSettings defaults = hs_zero (), prepared = hs_rich (0.7, 0.1);
  CHECK (probe && glims_hue_saturation_config_prepare (probe, &error) == GLIMS_STATUS_OK &&
         glims_hue_saturation_config_get (probe, &prepared, &error) == GLIMS_STATUS_OK &&
         settings_equal (&prepared, &defaults), "private prepare seeds all22 defaults before any Apply");
  g_clear_object (&probe); clear_error (&error);
  NEED (fixture_open (engine, &f) && read_pixels (&f, FALSE, raw) &&
        api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK &&
        begin (&f, &filter, &error) == GLIMS_STATUS_OK,
        "real nonlinear FLOAT preview opens with explicit sRGB patches and nonopaque alpha");
  NEED (settings_are (&f, filter, &defaults) && read_pixels (&f, TRUE, actual),
        "first public preview exposes all22 zero defaults");
  CHECK (formula_matches (raw, actual, &defaults), "default preview is independent nonlinear RGB identity");
  GlimsFilter *s = session (&f, filter);
  NEED (s && node_config (s->operation), "preview owns a real native point-filter config");
  g_weak_ref_init (&old_weak, node_config (s->operation)); old_init = TRUE;
  GlimsHueSaturationSettings first = hs_rich (0.2, 0.15);
  NEED (api->filter_hue_saturation_set (engine, filter, &first, &error) == GLIMS_STATUS_OK,
        "first immutable replacement succeeds before any native Undo");
  held = g_weak_ref_get (&old_weak);
  CHECK (!held, "replaced adapter-only default config finalizes before native Undo/XCF");
  g_clear_object (&held);

  for (guint i = 0; i < G_N_ELEMENTS (numeric_cases); i++) {
    const NumericCase *c = &numeric_cases[i];
    double er, eg, eb;
    hsl_to_rgb (c->expected_hsla[0], c->expected_hsla[1], c->expected_hsla[2], &er, &eg, &eb);
    CHECK (fabs (er-c->expected_rgba[0]) < 1e-8 && fabs (eg-c->expected_rgba[1]) < 1e-8 &&
           fabs (eb-c->expected_rgba[2]) < 1e-8, "literal HSLA and RGB expectations agree under independent HSL conversion");
    if (c->expected_hsla[2] > 1) continue; /* Raw extended L is tested below, before drawable blending. */
    NEED (api->filter_hue_saturation_set (engine, filter, &c->settings, &error) == GLIMS_STATUS_OK &&
          settings_are (&f, filter, &c->settings) && read_pixels (&f, TRUE, actual), c->name);
    gboolean match = patch_matches (actual, i, c->expected_rgba[0], c->expected_rgba[1],
                                     c->expected_rgba[2], c->expected_rgba[3]);
    if (!match) fprintf (stderr, "oracle %s: actual %.9g %.9g %.9g %.9g expected %.9g %.9g %.9g %.9g\n",
                        c->name, actual[i*4], actual[i*4+1], actual[i*4+2], actual[i*4+3],
                        c->expected_rgba[0], c->expected_rgba[1], c->expected_rgba[2], c->expected_rgba[3]);
    CHECK (match, c->name);
  }

  GlimsHueSaturationSettings whole = hs_zero ();
  double *fields[22]; settings_fields (&whole, fields);
  for (guint i = 0; i < 22; i++) {
    *fields[i] = i == 0 ? 0.35 : (i % 2 ? 1 : -1) * (0.01 + i * 0.005);
    CHECK (api->filter_hue_saturation_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK &&
           settings_are (&f, filter, &whole), "each sequential field update retains every other range and overlap");
    clear_error (&error);
  }
  NEED (read_pixels (&f, TRUE, actual), "whole22 sequential preview reads");
  CHECK (formula_matches (raw, actual, &whole), "all22 simultaneous corrections match independent HSL/alpha arithmetic");
  GimpHueSaturationConfig *cfg = GIMP_HUE_SATURATION_CONFIG (node_config (s->operation));
  g_object_set (cfg, "range", GIMP_HUE_RANGE_BLUE, NULL);
  CHECK (settings_are (&f, filter, &whole) && cfg->range == GIMP_HUE_RANGE_BLUE,
         "whole Get does not move the live BLUE cursor");
  GlimsHueSaturationSettings next = whole; next.magenta.saturation = 0.31;
  gboolean changed = FALSE;
  NEED (glims_hue_saturation_config_set (s->operation, &next, &changed, &error) == GLIMS_STATUS_OK && changed,
        "private whole Set duplicates the config");
  CHECK (GIMP_HUE_SATURATION_CONFIG (node_config (s->operation))->range == GIMP_HUE_RANGE_BLUE &&
         settings_are (&f, filter, &next), "private Set retains live BLUE cursor and all other fields");
  next.cyan.lightness = 0.19;
  NEED (api->filter_hue_saturation_set (engine, filter, &next, &error) == GLIMS_STATUS_OK,
        "public Set applies a further whole value");
  CHECK (GIMP_HUE_SATURATION_CONFIG (node_config (s->operation))->range == GIMP_HUE_RANGE_BLUE &&
         settings_are (&f, filter, &next), "public Set also preserves BLUE cursor");

  GlimsHueSaturationSettings zero = hs_zero ();
  NEED (api->filter_hue_saturation_set (engine, filter, &zero, &error) == GLIMS_STATUS_OK,
        "all-positive-zero baseline is installed before signed-zero no-op checks");
  GObject *same = node_config (s->operation);
  guint notifications = 0;
  gulong signal = g_signal_connect (gegl_node_get_gegl_operation (s->operation), "notify::config",
                                    G_CALLBACK (notified), &notifications);
  GlimsUndoInfo no_history = {0};
  NEED (api->image_undo_info (engine, f.id, &no_history) == GLIMS_STATUS_OK, "signed-zero history baseline reads");
  for (guint i = 0; i <= 22; i++) {
    GlimsHueSaturationSettings z = zero; settings_fields (&z, fields);
    if (i < 22) *fields[i] = -0.0;
    else for (guint j = 0; j < 22; j++) *fields[j] = -0.0;
    changed = TRUE;
    CHECK (api->filter_hue_saturation_set (engine, filter, &z, &error) == GLIMS_STATUS_OK &&
           glims_hue_saturation_config_set (s->operation, &z, &changed, NULL) == GLIMS_STATUS_OK && !changed &&
           node_config (s->operation) == same && notifications == 0 &&
           GIMP_HUE_SATURATION_CONFIG (same)->range == GIMP_HUE_RANGE_BLUE && history_equal (&f, &no_history),
           "each/all signed zeros preserve config identity, notifications and history");
    clear_error (&error);
  }
  g_signal_handler_disconnect (gegl_node_get_gegl_operation (s->operation), signal);
  NEED (api->filter_hue_saturation_set (engine, filter, &next, &error) == GLIMS_STATUS_OK &&
        read_pixels (&f, TRUE, actual), "invalid-request baseline is installed");
  same = node_config (s->operation);
  const double invalid[] = { NAN, INFINITY, -INFINITY, -1.01, 1.01 };
  for (guint i = 0; i < 22; i++) {
    for (guint v = 0; v < G_N_ELEMENTS (invalid); v++) {
      GlimsHueSaturationSettings bad = next; settings_fields (&bad, fields);
      *fields[i] = i == 0 && v == 3 ? -0.01 : invalid[v];
      gboolean untouched = api->filter_hue_saturation_set (engine, filter, &bad, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
                           node_config (s->operation) == same && settings_are (&f, filter, &next) &&
                           read_pixels (&f, TRUE, current) && !memcmp (actual, current, sizeof actual) &&
                           history_equal (&f, &no_history);
      CHECK (untouched, "each22 field rejects NaN/Inf/both bound violations without config/pixel/history mutation");
      clear_error (&error);
    }
  }
  g_weak_ref_init (&last_weak, node_config (s->operation)); last_init = TRUE;
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "numeric preview aborts"); filter = 0;
  held = g_weak_ref_get (&last_weak);
  CHECK (!held, "aborted adapter-only config finalizes before native Undo/XCF");
  g_clear_object (&held);
  CHECK (read_pixels (&f, FALSE, current) && !memcmp (raw, current, sizeof raw) && history_equal (&f, &history),
         "Abort preserves exact source floats and native history");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (old_init) g_weak_ref_clear (&old_weak);
  if (last_init) g_weak_ref_clear (&last_weak);
  g_clear_object (&held); clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
extended_lightness (GlimsEngine *engine, gpointer unused)
{
  (void) engine; (void) unused;
  char *error = NULL;
  const Babl *format = babl_format_with_space ("HSLA float", NULL);
  GeglRectangle rect = {0, 0, 2, 1};
  gfloat input[8] = {0, 0.5, 0.5, 0.37, 0, 0.5, 0.5, 0.37}, output[8] = {0};
  GeglBuffer *buffer = gegl_buffer_new (&rect, format);
  GeglNode *graph = gegl_node_new ();
  GeglNode *source = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", buffer, NULL);
  GeglNode *operation = gegl_node_new_child (graph, "operation", "gimp:hue-saturation", NULL);
  GlimsHueSaturationSettings s = hs_zero (); s.master.lightness = 0.8; s.red.lightness = 0.8;
  gboolean changed = FALSE;
  NEED (buffer && source && operation, "standalone HSLA-float graph is constructed");
  gegl_buffer_set (buffer, &rect, 0, format, input, GEGL_AUTO_ROWSTRIDE);
  NEED (glims_hue_saturation_config_prepare (operation, &error) == GLIMS_STATUS_OK &&
        glims_hue_saturation_config_set (operation, &s, &changed, &error) == GLIMS_STATUS_OK && changed,
        "valid master/local +.8 lightness is admitted without a sum clamp");
  gegl_node_link (source, operation);
  gegl_node_blit (operation, 1.0, &rect, format, output, GEGL_AUTO_ROWSTRIDE, GEGL_BLIT_DEFAULT);
  CHECK (fabs (output[0]) < 2e-5 && fabs (output[1] - 0.5) < 2e-5 &&
         fabs (output[2] - 1.3) < 2e-5 && fabs (output[3] - 0.37) < 2e-5 &&
         fabs (output[6] - 1.3) < 2e-5,
         "native raw HSLA L is 1.3 before downstream drawable/babl handling; alpha unchanged");
cleanup:
  clear_error (&error); g_clear_object (&graph); g_clear_object (&buffer);
  return GLIMS_STATUS_OK;
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
config_values_are (GObject *object, const GlimsHueSaturationSettings *expected)
{
  if (!object || !GIMP_IS_HUE_SATURATION_CONFIG (object)) return FALSE;
  GimpHueSaturationConfig *c = GIMP_HUE_SATURATION_CONFIG (object);
  GlimsHueSaturationSettings actual = hs_zero ();
  actual.overlap = c->overlap;
#define READ_RANGE(own, native) do { actual.own = range3 (c->hue[native], c->saturation[native], c->lightness[native]); } while (0)
  READ_RANGE (master, GIMP_HUE_RANGE_ALL); READ_RANGE (red, GIMP_HUE_RANGE_RED);
  READ_RANGE (yellow, GIMP_HUE_RANGE_YELLOW); READ_RANGE (green, GIMP_HUE_RANGE_GREEN);
  READ_RANGE (cyan, GIMP_HUE_RANGE_CYAN); READ_RANGE (blue, GIMP_HUE_RANGE_BLUE);
  READ_RANGE (magenta, GIMP_HUE_RANGE_MAGENTA);
#undef READ_RANGE
  return settings_equal (&actual, expected);
}

static gboolean
effect_pair_values (Fixture *f, GlimsEffectID id, const GlimsHueSaturationSettings *expected)
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
xcf_roundtrip (Fixture *f, const char *filename, const GlimsHueSaturationSettings *expected)
{
  gboolean result = FALSE; gchar *path = g_build_filename (work_dir, filename, NULL);
  char *error = NULL; GlimsImageID opened = 0; GlimsFilterID edit = 0;
  gfloat before[VALUES] = {0}, after[VALUES] = {0};
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
     * This is the previously verified Color Balance XCF fixture contract. */
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
    if (!strcmp (effects[i].operation, "gimp:hue-saturation")) selected = effects[i].id;
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
  GlimsHueSaturationSettings settings = hs_rich (0.4, 0.12);
  NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK &&
        api->filter_hue_saturation_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
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
  CHECK (xcf_roundtrip (&f, "hs-new.xcf", &settings), "XCF fresh reopen preserves actual Hue-Saturation and pixels");
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
    GlimsHueSaturationSettings A = hs_rich (0.2, 0.1), B = A, C;
    B.red.saturation = -0.3; B.blue.hue = 0.2; B.overlap = 0.45;
    C = B; C.yellow.lightness = 0.2; C.magenta.saturation = -0.2; C.overlap = 0.7;
    NEED (api->filter_hue_saturation_set (engine, filter, &A, &error) == GLIMS_STATUS_OK, "initial immutable A replacement succeeds");
    GimpOperationSettings *base = GIMP_OPERATION_SETTINGS (node_config (s->operation));
    NEED (base->opacity == 0.625 && base->clip == GIMP_TRANSFORM_RESIZE_CLIP &&
          base->region == GIMP_FILTER_REGION_DRAWABLE && base->mode == GIMP_LAYER_MODE_MULTIPLY,
          "first immutable duplicate preserves independently seeded native base fields");
    NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "initial immutable A config commits"); filter = 0;
    NEED (effect_rows (&f, rows, 4, &count) && count == 1, "one real committed HSL effect is present");
    GlimsEffectID effect_id = rows[0].id;
    NEED (api->filter_begin (engine, f.id, layer_id (&f), "gegl:invert-linear", &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK,
          "second real effect gives HSL a meaningful stack position"); filter = 0;
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
    NEED (api->filter_hue_saturation_set (engine, filter, &B, &error) == GLIMS_STATUS_OK, "shadow changes A to B");
    saved_b = g_object_ref (node_config (session (&f, filter)->operation));
    NEED (api->filter_hue_saturation_set (engine, filter, &C, &error) == GLIMS_STATUS_OK, "shadow changes B to C");
    CHECK (effect_pair_values (&f, effect_id, &A) &&
           native_base_equal (saved_a, node_config (gimp_drawable_filter_get_operation (effect))),
           "B and C replacements never mutate installed A config or native base fields");
    CHECK (config_values_are (saved_a, &A) && config_values_are (saved_b, &B),
           "all21/overlap values in original A and earlier B stay immutable");
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "existing-effect Cancel drops only the shadow"); filter = 0;
    EffectState current = effect_state (&f, effect);
    CHECK (effect_state_equal (&state, &current) && effect_pair_values (&f, effect_id, &A) &&
           history_equal (&f, &before) && read_pixels (&f, TRUE, actual) && close_pixels (original, actual),
           "Cancel preserves enabled state, stack, blend/base, pixels and history");
    NEED (api->filter_edit_begin (engine, f.id, layer_id (&f), effect_id, &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_hue_saturation_set (engine, filter, &B, &error) == GLIMS_STATUS_OK &&
          api->filter_hue_saturation_set (engine, filter, &C, &error) == GLIMS_STATUS_OK &&
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
           "all21/overlap witness values stay immutable across native Undo/Redo");
    CHECK (xcf_roundtrip (&f, disabled ? "hs-existing-disabled.xcf" : "hs-existing-enabled.xcf", &C),
           "XCF preserves all21/overlap config, base/order/active/pixels with native AUTO composite normalization");
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
  return gimp_image_undo_group_start (f->image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "HSL history guard");
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
    GlimsUndoInfo history = {0}, after = {0};
    gfloat raw[VALUES], actual[VALUES], preview[VALUES], preview_after[VALUES];
    NEED (fixture_open (engine, &f), "history guard opens an independent image");
    blocked = block_history (&f, mode);
    NEED (blocked, "history disables/freezes/opens an outer group before Begin");
    refuses_begin (&f, GLIMS_STATUS_BUSY, "disabled/frozen/grouped Undo refuses new HSL Begin");
    unblock_history (&f, mode); blocked = FALSE;
    GlimsHueSaturationSettings settings = hs_settings (0, range3 (0.2, -0.3, 0), range3 (0, 0, 0), range3 (0, 0, 0));
    NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_hue_saturation_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK,
          "valid preview opens before commit history becomes unavailable");
    blocked = block_history (&f, mode); NEED (blocked, "history changes while preview is open");
    GlimsFilter *same = session (&f, filter);
    GObject *config = same ? node_config (same->operation) : NULL;
    NEED (same && config && read_pixels (&f, FALSE, raw) && read_pixels (&f, TRUE, preview) &&
          api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK,
          "blocked-commit baseline is captured after the external history transition");
    CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_BUSY && session (&f, filter) == same &&
           node_config (same->operation) == config,
           "blocked commit returns BUSY and retains the same session"); clear_error (&error);
    CHECK (read_pixels (&f, FALSE, actual) && !memcmp (raw, actual, sizeof raw) && history_equal (&f, &history) &&
           read_pixels (&f, TRUE, preview_after) && !memcmp (preview, preview_after, sizeof preview),
           "blocked commit leaves raw pixels, preview, config and history unchanged");
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
  GlimsHueSaturationSettings settings = hs_settings (1, range3 (0.25, 0.1, 0), range3 (0, 0, 0), range3 (0, 0, 0));
  GlimsHueSaturationSettings output = hs_settings (1, range3 (7, 8, 9), range3 (7, 8, 9), range3 (7, 8, 9));
  GlimsHueSaturationSettings zero_output = hs_zero ();
  CHECK (api->filter_hue_saturation_get (engine, INT_MAX, &output, &error) == GLIMS_STATUS_NOT_FOUND &&
         settings_equal (&output, &zero_output) && output.struct_size == sizeof output,
         "stale Get reports NOT_FOUND and resets every owned field without changing size");
  clear_error (&error);
  CHECK (api->filter_hue_saturation_set (engine, INT_MAX, &settings, &error) == GLIMS_STATUS_NOT_FOUND, "stale Set refuses");
  clear_error (&error);
  CHECK (api->filter_hue_saturation_get (engine, INT_MAX, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
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
  CHECK (api->filter_hue_saturation_set (engine, filter, &settings, &error) == GLIMS_STATUS_LOCKED &&
         node_config (s->operation) == config, "locked Set preserves the installed config");
  clear_error (&error);
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), FALSE, FALSE);
  engine->busy++;
  GlimsStatus status = api->filter_hue_saturation_set (engine, filter, &settings, &error);
  engine->busy--;
  CHECK (status == GLIMS_STATUS_BUSY && node_config (s->operation) == config, "busy Set preserves the installed config");
  clear_error (&error);

  GlimsHueSaturationSettings small = hs_zero (); small.struct_size = sizeof small - 1;
  GlimsHueSaturationSettings expected_default = hs_zero ();
  CHECK (api->filter_hue_saturation_set (engine, filter, &small, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->filter_hue_saturation_set (engine, filter, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         settings_are (&f, filter, &expected_default),
         "undersized and NULL settings refuse without changing settings");
  clear_error (&error);
  CHECK (read_pixels (&f, FALSE, after) && !memcmp (raw, after, sizeof raw) && history_equal (&f, &history),
         "typed write refusals preserve raw pixels/history");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "refusal preview aborts"); filter = 0;

  NEED (api->filter_begin (engine, f.id, layer_id (&f), "gegl:invert-linear", &filter, &error) == GLIMS_STATUS_OK,
        "wrong-operation preview starts independently");
  CHECK (api->filter_hue_saturation_get (engine, filter, &output, &error) == GLIMS_STATUS_UNSUPPORTED &&
         api->filter_hue_saturation_set (engine, filter, &settings, NULL) == GLIMS_STATUS_UNSUPPORTED,
         "typed get/set refuse a real non-HSL operation");
  clear_error (&error);
  refuses_begin (&f, GLIMS_STATUS_BUSY, "another active preview refuses HSL Begin");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "wrong-operation preview aborts"); filter = 0;

  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PAINTBRUSH,
                               .size = 3, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint point = {2, 2, 1, 0, 0, 0};
  NEED (api->stroke_begin (engine, f.id, layer_id (&f), &brush, &point, &stroke, &error) == GLIMS_STATUS_OK,
        "real stroke starts for admission regression");
  refuses_begin (&f, GLIMS_STATUS_BUSY, "active native stroke refuses HSL Begin");
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
      !api->filter_hue_saturation_get || !api->filter_hue_saturation_set) return 2;
  char *error = NULL; GlimsHueSaturationSettings output = hs_settings (1, range3 (7, 8, 9), range3 (7, 8, 9), range3 (7, 8, 9));
  GlimsHueSaturationSettings zero_output = hs_zero ();
  struct { GlimsHueSaturationSettings value; guint64 tail; } stopped;
  memset (&stopped, 0xA5, sizeof stopped); stopped.value.struct_size = sizeof stopped;
  guint64 stopped_tail = stopped.tail;
  CHECK (api->filter_hue_saturation_get (NULL, 1, &stopped.value, &error) == GLIMS_STATUS_NOT_RUNNING &&
         settings_equal (&stopped.value, &zero_output) && stopped.value.struct_size == sizeof stopped &&
         stopped.tail == stopped_tail,
         "nonrunning slot152 resets all owned fields while preserving size/future tail");
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
  CHECK (glims_engine_call (engine, extended_lightness, NULL) == GLIMS_STATUS_OK,
         "extended raw-HSLA oracle runs on the engine worker");
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
    CHECK (api->filter_begin (engine, public.f.id, public.target, "gimp:hue-saturation", &filter, &error) == GLIMS_STATUS_OK &&
           filter > 0, "public host-thread preview starts");
    clear_error (&error);
    if (filter) {
      GlimsHueSaturationSettings settings = hs_rich (0.65, -0.125);
      output = hs_zero ();
      CHECK (api->filter_hue_saturation_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
             api->filter_hue_saturation_get (engine, filter, &output, NULL) == GLIMS_STATUS_OK &&
             settings_equal (&output, &settings),
             "public host-thread slots152/153 marshal the exact complete value");
      clear_error (&error);
      struct { GlimsHueSaturationSettings value; guint64 tail; } sized, before;
      memset (&sized, 0xA5, sizeof sized); sized.value.struct_size = sizeof sized.value - 1; before = sized;
      CHECK (api->filter_hue_saturation_get (engine, filter, &sized.value, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
             !memcmp (&sized, &before, sizeof sized),
             "undersized Get leaves all caller sentinel bytes untouched");
      clear_error (&error);
      memset (&sized, 0xA5, sizeof sized); sized.value.struct_size = sizeof sized; before = sized;
      CHECK (api->filter_hue_saturation_get (engine, filter, &sized.value, &error) == GLIMS_STATUS_OK &&
             sized.tail == before.tail && settings_equal (&sized.value, &settings),
             "valid extensible Get does not overwrite a future caller tail");
      clear_error (&error);
      before = sized;
      CHECK (api->filter_hue_saturation_set (engine, filter, &sized.value, &error) == GLIMS_STATUS_OK &&
             !memcmp (&sized, &before, sizeof sized),
             "extensible Set ignores and preserves a future caller tail");
      clear_error (&error);
      CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "public preview aborts");
    }
  } else CHECK (FALSE, "public fixture setup succeeds");
  glims_engine_call (engine, public_cleanup, &public);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}

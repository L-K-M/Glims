/* Core-only fixtures. Never free borrowed selected-layer lists or compensate
 * for native Undo/XCF config-setter retention with extra unrefs. */
#include "engine-private.h"
#include "levels-config.h"
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
#include "operations/gimplevelsconfig.h"
#include "operations/gimpoperationpointfilter.h"
#include "operations/gimpoperationsettings.h"
#include "libgimpconfig/gimpconfig.h"
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

static GlimsLevelsChannel
channel5 (double low, double high, double gamma, double out_low, double out_high)
{
  return (GlimsLevelsChannel) {low, high, gamma, out_low, out_high};
}

static GlimsLevelsSettings
lv_identity (void)
{
  GlimsLevelsSettings s = { .struct_size = sizeof s, .trc = GLIMS_COLOR_TRC_LINEAR };
  s.value = s.red = s.green = s.blue = s.alpha = channel5 (0, 1, 1, 0, 1);
  return s;
}

static GlimsLevelsSettings
lv_empty (void)
{
  /* Error outputs are all-zero, deliberately not valid identity settings. */
  GlimsLevelsSettings s = { .struct_size = sizeof s };
  return s;
}

static GlimsLevelsSettings
lv_rich (uint32_t trc, double v)
{
  GlimsLevelsSettings s = lv_identity ();
  s.trc = trc; s.clamp_input = 1; s.clamp_output = 1;
  s.value = channel5 (0.02, 0.98, 1 + v, 0.01, 0.99);
  s.red = channel5 (0.01, 0.95, 1.1, 0.03, 0.97);
  s.green = channel5 (0.03, 0.99, 0.9, 0.02, 0.94);
  s.blue = channel5 (0.04, 0.96, 1.2, 0.01, 0.93);
  s.alpha = channel5 (0.01, 0.99, 0.95, 0.03, 0.97);
  return s;
}

static void
settings_fields (GlimsLevelsSettings *s, double *fields[25])
{
  GlimsLevelsChannel *channels[] = { &s->value, &s->red, &s->green, &s->blue, &s->alpha };
  for (guint i = 0; i < 5; i++) {
    fields[i*5] = &channels[i]->low_input;
    fields[i*5+1] = &channels[i]->high_input;
    fields[i*5+2] = &channels[i]->gamma;
    fields[i*5+3] = &channels[i]->low_output;
    fields[i*5+4] = &channels[i]->high_output;
  }
}

static GlimsLevelsSettings
lv_filled (double value)
{
  GlimsLevelsSettings s = lv_empty (); double *fields[25];
  settings_fields (&s, fields);
  for (guint i = 0; i < 25; i++) *fields[i] = value;
  s.trc = UINT32_MAX; s.clamp_input = 7; s.clamp_output = 7;
  return s;
}

static gboolean
channel_equal (const GlimsLevelsChannel *a, const GlimsLevelsChannel *b)
{
  return a->low_input == b->low_input && a->high_input == b->high_input &&
         a->gamma == b->gamma && a->low_output == b->low_output && a->high_output == b->high_output;
}

static gboolean
settings_equal (const GlimsLevelsSettings *a, const GlimsLevelsSettings *b)
{
  return a->trc == b->trc && a->clamp_input == b->clamp_input && a->clamp_output == b->clamp_output &&
         channel_equal (&a->value, &b->value) && channel_equal (&a->red, &b->red) &&
         channel_equal (&a->green, &b->green) && channel_equal (&a->blue, &b->blue) &&
         channel_equal (&a->alpha, &b->alpha);
}

static uint32_t
own_trc (GimpTRCType trc)
{
  switch (trc) {
    case GIMP_TRC_LINEAR: return GLIMS_COLOR_TRC_LINEAR;
    case GIMP_TRC_NON_LINEAR: return GLIMS_COLOR_TRC_NONLINEAR;
    case GIMP_TRC_PERCEPTUAL: return GLIMS_COLOR_TRC_PERCEPTUAL;
    default: return GLIMS_COLOR_TRC_UNKNOWN;
  }
}

static GlimsLevelsSettings
native_values (GimpLevelsConfig *c)
{
  GlimsLevelsSettings s = lv_empty ();
  s.trc = own_trc (c->trc); s.clamp_input = (uint32_t) c->clamp_input;
  s.clamp_output = (uint32_t) c->clamp_output;
#define READ_CHANNEL(own, native) do { s.own = channel5 (c->low_input[native], c->high_input[native], c->gamma[native], c->low_output[native], c->high_output[native]); } while (0)
  READ_CHANNEL (value, GIMP_HISTOGRAM_VALUE); READ_CHANNEL (red, GIMP_HISTOGRAM_RED);
  READ_CHANNEL (green, GIMP_HISTOGRAM_GREEN); READ_CHANNEL (blue, GIMP_HISTOGRAM_BLUE);
  READ_CHANNEL (alpha, GIMP_HISTOGRAM_ALPHA);
#undef READ_CHANNEL
  return s;
}

typedef struct {
  const char *name;
  gfloat input[4], expected[4];
  GlimsLevelsSettings settings;
} RawCase;

/* Fixed arithmetic-only literals from levels-derived-oracles.json. No native
 * partial helper or copied Levels mapping implementation computes an oracle. */
static const RawCase raw_cases[] = {
  { "identity", { 0.25, 0.5, 0.75, 0.25 },
    { 0.25, 0.5, 0.75, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0, 1, 1, 0, 1 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "Value gamma2 skips alpha", { 0.25, 0.5, 0.75, 0.25 },
    { 0.5, 0.70710678118699999, 0.86602540378399995, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0, 1, 2, 0, 1 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "red output mapping precedes Value gamma", { 0.25, 0.25, 0.25, 0.25 },
    { 0.59160797831, 0.5, 0.5, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0, 1, 2, 0, 1 }, .red = { 0, 1, 1, 0.20000000000000001, 0.80000000000000004 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "inverted input endpoints", { 0.25, 0.5, 0.75, 0.25 },
    { 1, 0.5, 0, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0.75, 0.25, 1, 0, 1 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "equal input subtracts low; no threshold", { 0.25, 0.5, 0.75, 0.25 },
    { -0.25, 0, 0.25, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0.5, 0.5, 1, 0, 1 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "equal input with clamp", { 0.25, 0.5, 0.75, 0.25 },
    { 0, 0, 0.25, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 1, .clamp_output = 0, .value = { 0.5, 0.5, 1, 0, 1 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "inverted output endpoints", { 0.25, 0.5, 0.75, 0.25 },
    { 0.75, 0.5, 0.25, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0, 1, 1, 1, 0 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "equal output is constant", { 0.25, 0.5, 0.75, 0.25 },
    { 0.40000000000000002, 0.40000000000000002, 0.40000000000000002, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0, 1, 1, 0.40000000000000002, 0.40000000000000002 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "unclamped extrapolation", { 0, 0.5, 1, 0.25 },
    { -0.10000000000000001, 0.5, 1.1000000000000001, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0.25, 0.75, 1, 0.20000000000000001, 0.80000000000000004 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "input clamp before output map", { 0, 0.5, 1, 0.25 },
    { 0.20000000000000001, 0.5, 0.80000000000000004, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 1, .clamp_output = 0, .value = { 0.25, 0.75, 1, 0.20000000000000001, 0.80000000000000004 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "output clamp after output map", { 0, 0.5, 1, 0.25 },
    { 0, 0.5, 1, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 1, .value = { 0.25, 0.75, 1, 0.20000000000000001, 0.80000000000000004 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
  { "alpha gamma2 is independent", { 0.25, 0.5, 0.75, 0.25 },
    { 0.25, 0.5, 0.75, 0.5 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0, 1, 1, 0, 1 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 2, 0, 1 } } },
  { "gamma skips nonpositive normalized input", { 0, 0.25, 0.75, 0.25 },
    { -0.5, -0.25, 0.5, 0.25 },
    { .struct_size = sizeof (GlimsLevelsSettings), .trc = GLIMS_COLOR_TRC_LINEAR, .clamp_input = 0, .clamp_output = 0, .value = { 0.5, 0.5, 2, 0, 1 }, .red = { 0, 1, 1, 0, 1 }, .green = { 0, 1, 1, 0, 1 }, .blue = { 0, 1, 1, 0, 1 }, .alpha = { 0, 1, 1, 0, 1 } } },
};

static gboolean
fixture_open (GlimsEngine *engine, Fixture *f)
{
  memset (f, 0, sizeof *f); f->engine = engine;
  GimpImage *image = gimp_create_image (engine->gimp, SIDE, SIDE, GIMP_RGB,
                                        GIMP_PRECISION_FLOAT_LINEAR, FALSE);
  if (!image) return FALSE;
  if (glims_adopt_image (engine, image, &f->id) != GLIMS_STATUS_OK) {
    g_object_unref (image); return FALSE;
  }
  f->image = image;
  f->layer = gimp_layer_new (image, SIDE, SIDE, gimp_image_get_layer_format (image, TRUE),
                             "linear FLOAT target", 1.0, GIMP_LAYER_MODE_NORMAL);
  if (!f->layer) return FALSE;
  if (!gimp_image_add_layer (image, f->layer, NULL, 0, FALSE)) {
    g_object_unref (f->layer); f->layer = NULL; return FALSE;
  }
  gfloat pixels[VALUES];
  for (guint i = 0; i < VALUES; i += 4) {
    pixels[i] = 0.25; pixels[i+1] = 0.5; pixels[i+2] = 0.75; pixels[i+3] = 0.25;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->layer)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                   babl_format ("RGBA float"), pixels, GEGL_AUTO_ROWSTRIDE);
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
                   babl_format ("RGBA float"), pixels, GEGL_AUTO_ROWSTRIDE,
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
  return api->filter_begin (f->engine, f->id, layer_id (f), "gimp:levels",
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
settings_are (Fixture *f, GlimsFilterID id, const GlimsLevelsSettings *expected)
{
  GlimsLevelsSettings actual = lv_identity ();
  actual.struct_size = sizeof actual;
  return api->filter_levels_get (f->engine, id, &actual, NULL) == GLIMS_STATUS_OK &&
         settings_equal (&actual, expected);
}

static void
notified (GObject *object, GParamSpec *spec, gpointer data)
{
  (void) object; (void) spec; (*(guint *) data)++;
}


static GimpOperationPointFilter *
point_for (GeglNode *node)
{
  GeglOperation *operation = node ? gegl_node_get_gegl_operation (node) : NULL;
  return operation && GIMP_IS_OPERATION_POINT_FILTER (operation)
         ? GIMP_OPERATION_POINT_FILTER (operation) : NULL;
}

static gboolean
binding_shape (GimpOperationPointFilter *point)
{
  if (!point || !point->config || !GIMP_IS_LEVELS_CONFIG (point->config) ||
      point->trc != GIMP_LEVELS_CONFIG (point->config)->trc) return FALSE;
#if GIMP_CHECK_VERSION (3, 2, 0)
  GBinding *binding = point->trc_binding;
  if (!binding || (g_binding_get_flags (binding) & ~G_BINDING_SYNC_CREATE) ||
      g_strcmp0 (g_binding_get_source_property (binding), "trc") ||
      g_strcmp0 (g_binding_get_target_property (binding), "trc")) return FALSE;
  GObject *source = g_binding_dup_source (binding), *target = g_binding_dup_target (binding);
  gboolean same = source == point->config && target == G_OBJECT (point);
  g_clear_object (&source); g_clear_object (&target);
  return same;
#else
  return TRUE; /* No binding field exists in the3.0 native header. */
#endif
}

#if GIMP_CHECK_VERSION (3, 2, 0)
static void
retire_binding (GimpOperationPointFilter *point)
{
  /* bind_property returns transfer-none. Unbind consumes the binding-owned
   * initial ref; never follow it with a compensating g_object_unref. */
  GBinding *old = point->trc_binding;
  point->trc_binding = NULL;
  if (old) g_binding_unbind (old);
}
#endif

static gboolean
raw_result (const GlimsLevelsSettings *settings, const gfloat input[4],
            const Babl *format, gfloat output[8], char **error)
{
  gboolean result = FALSE, changed = FALSE;
  GeglRectangle rect = {0, 0, 2, 1};
  GeglBuffer *buffer = gegl_buffer_new (&rect, format);
  GeglNode *graph = gegl_node_new ();
  GeglNode *source = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", buffer, NULL);
  GeglNode *operation = gegl_node_new_child (graph, "operation", "gimp:levels", NULL);
  gfloat pixels[8]; memcpy (pixels, input, 4*sizeof (gfloat)); memcpy (pixels+4, input, 4*sizeof (gfloat));
  if (!buffer || !source || !operation) goto cleanup;
  gegl_buffer_set (buffer, &rect, 0, format, pixels, GEGL_AUTO_ROWSTRIDE);
  gegl_node_link (source, operation);
  if (glims_levels_config_prepare (operation, error) != GLIMS_STATUS_OK ||
      glims_levels_config_set (operation, settings, &changed, error) != GLIMS_STATUS_OK ||
      !binding_shape (point_for (operation))) goto cleanup;
  gegl_node_blit (operation, 1.0, &rect, format, output, GEGL_AUTO_ROWSTRIDE, GEGL_BLIT_DEFAULT);
  result = TRUE;
cleanup:
  g_clear_object (&graph); g_clear_object (&buffer);
  return result;
}

static gboolean
rgba_matches (const gfloat *actual, const gfloat expected[4])
{
  for (guint i = 0; i < 4; i++)
    if (!isfinite (actual[i]) || fabs ((double) actual[i]-expected[i]) > 2e-4) return FALSE;
  return TRUE;
}

static GlimsStatus
raw_oracles (GlimsEngine *engine, gpointer unused)
{
  (void) engine; (void) unused;
  char *error = NULL;
  const Babl *linear = babl_format ("RGBA float");
  for (guint i = 0; i < G_N_ELEMENTS (raw_cases); i++) {
    gfloat result[8] = {0};
    NEED (raw_result (&raw_cases[i].settings, raw_cases[i].input, linear, result, &error),
          "raw Levels graph accepts a literal-case full settings value");
    gboolean equal = rgba_matches (result, raw_cases[i].expected) && rgba_matches (result+4, raw_cases[i].expected);
    if (!equal) fprintf (stderr, "Levels raw %s: actual %.9g %.9g %.9g %.9g expected %.9g %.9g %.9g %.9g\n",
                         raw_cases[i].name, result[0],result[1],result[2],result[3],
                         raw_cases[i].expected[0],raw_cases[i].expected[1],raw_cases[i].expected[2],raw_cases[i].expected[3]);
    CHECK (equal, raw_cases[i].name);
  }
  const Babl *spaces[] = {babl_space ("sRGB"), babl_space_with_trc (babl_space ("sRGB"), babl_trc ("linear"))};
  const uint32_t modes[] = {GLIMS_COLOR_TRC_LINEAR, GLIMS_COLOR_TRC_NONLINEAR, GLIMS_COLOR_TRC_PERCEPTUAL};
  /* Independent piecewise sRGB arithmetic, before any native execution:
   * ordinary sRGB: encode(decode(.5)^2); linear-profile perceptual:
   * decode(encode(.5)^2). Nonlinear follows the actual source profile TRC. */
  const double expected[2][3] = {{0.23696682464454982, 0.25, 0.25},
                                 {0.25, 0.25, 0.25371586881499225}};
  const gfloat input[4] = {0.5,0.5,0.5,0.25};
  for (guint space = 0; space < 2; space++) {
    NEED (spaces[space] != NULL, "known sRGB-primary TRC space exists");
    const Babl *format = babl_format_with_space ("R'G'B'A float", spaces[space]);
    for (guint mode = 0; mode < 3; mode++) {
      GlimsLevelsSettings s = lv_identity (); s.value.gamma = 0.5; s.trc = modes[mode];
      gfloat result[8] = {0}, oracle[4] = {(gfloat) expected[space][mode],(gfloat) expected[space][mode],(gfloat) expected[space][mode],0.25};
      NEED (raw_result (&s, input, format, result, &error), "TRC graph uses the actual source space and full pair");
      CHECK (rgba_matches (result, oracle) && rgba_matches (result+4, oracle),
             "LINEAR/NONLINEAR/PERCEPTUAL obey independent source-space/TRC oracles and preserve alpha");
    }
  }
cleanup:
  clear_error (&error); return GLIMS_STATUS_OK;
}

static GlimsStatus
values_and_lifetime (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  GWeakRef old_weak, last_weak; gboolean old_init = FALSE, last_init = FALSE;
  GObject *held = NULL;
  gfloat raw[VALUES], preview[VALUES], actual[VALUES]; GlimsUndoInfo history = {0};
  GlimsLevelsSettings identity = lv_identity (), out = lv_filled (7);
  GeglNode *probe = gegl_node_new_child (NULL, "operation", "gimp:levels", NULL);
  CHECK (probe && glims_levels_config_prepare (probe, &error) == GLIMS_STATUS_OK &&
         glims_levels_config_get (probe, &out, &error) == GLIMS_STATUS_OK && settings_equal (&out, &identity) &&
         binding_shape (point_for (probe)) && point_for (probe)->trc == GIMP_TRC_LINEAR,
         "private Prepare installs identity25/LINEAR/clamps-off before any Apply on every version");
  g_clear_object (&probe); clear_error (&error);
  NEED (fixture_open (engine, &f) && read_pixels (&f, FALSE, raw) &&
        api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK && begin (&f, &filter, &error) == GLIMS_STATUS_OK,
        "real linear FLOAT preview begins after exact raw/history baseline");
  NEED (settings_are (&f, filter, &identity) && read_pixels (&f, TRUE, actual), "public initial whole settings and preview read");
  CHECK (close_pixels (raw, actual), "default LINEAR Levels preview is identity with nonopaque alpha");
  GlimsFilter *s = session (&f, filter);
  NEED (s && node_config (s->operation), "preview has an actual native config");
  g_weak_ref_init (&old_weak, node_config (s->operation)); old_init = TRUE;
  GlimsLevelsSettings rich = lv_rich (GLIMS_COLOR_TRC_LINEAR, 0.15);
  NEED (api->filter_levels_set (engine, filter, &rich, &error) == GLIMS_STATUS_OK, "first immutable Levels replacement applies");
  held = g_weak_ref_get (&old_weak); CHECK (!held, "old adapter-only default finalizes before native Undo/XCF"); g_clear_object (&held);

  GlimsLevelsSettings whole = identity; double *fields[25]; settings_fields (&whole, fields);
  for (guint i = 0; i < 25; i++) {
    *fields[i] = i%5 == 2 ? 0.75 + i*0.01 : 0.02 + i*0.01;
    CHECK (api->filter_levels_set (engine, filter, &whole, &error) == GLIMS_STATUS_OK && settings_are (&f, filter, &whole),
           "each25 sequential named-field write retains every other channel"); clear_error (&error);
  }
  for (guint i = 0; i < 25; i++) {
    for (guint boundary = 0; boundary < 2; boundary++) {
      GlimsLevelsSettings value = rich; settings_fields (&value, fields);
      *fields[i] = i%5 == 2 ? (boundary ? 10 : 0.1) : (boundary ? 1 : 0);
      CHECK (api->filter_levels_set (engine, filter, &value, &error) == GLIMS_STATUS_OK && settings_are (&f, filter, &value),
             "every25 field accepts both exact own-domain boundaries"); clear_error (&error);
    }
  }
  GlimsLevelsSettings equal = identity; equal.value = channel5 (0.5,0.5,1,0.4,0.4);
  CHECK (api->filter_levels_set (engine, filter, &equal, &error) == GLIMS_STATUS_OK && settings_are (&f, filter, &equal),
         "equal input and output endpoints remain valid without threshold/sorting"); clear_error (&error);
  GlimsLevelsSettings inverted = identity; inverted.value = channel5 (0.75,0.25,1,1,0);
  CHECK (api->filter_levels_set (engine, filter, &inverted, &error) == GLIMS_STATUS_OK && settings_are (&f, filter, &inverted),
         "inverted input and output endpoints remain valid without sorting"); clear_error (&error);
  NEED (api->filter_levels_set (engine, filter, &rich, &error) == GLIMS_STATUS_OK, "cursor fixture restores a full nondefault value");
  GimpLevelsConfig *cfg = GIMP_LEVELS_CONFIG (node_config (s->operation));
  g_object_set (cfg, "channel", GIMP_HISTOGRAM_BLUE, NULL);
  CHECK (settings_are (&f, filter, &rich) && cfg->channel == GIMP_HISTOGRAM_BLUE, "whole Get never moves live BLUE cursor");
  GlimsLevelsSettings next = rich; next.alpha.gamma = 0.7; next.trc = GLIMS_COLOR_TRC_NONLINEAR;
  gboolean changed = FALSE;
  NEED (glims_levels_config_set (s->operation, &next, &changed, &error) == GLIMS_STATUS_OK && changed,
        "private Set changes a complete value including TRC");
  CHECK (GIMP_LEVELS_CONFIG (node_config (s->operation))->channel == GIMP_HISTOGRAM_BLUE &&
         binding_shape (point_for (s->operation)) && settings_are (&f, filter, &next), "private Set preserves cursor and synchronizes operation/config TRC");
  next.blue.gamma = 1.8; next.trc = GLIMS_COLOR_TRC_PERCEPTUAL;
  NEED (api->filter_levels_set (engine, filter, &next, &error) == GLIMS_STATUS_OK, "public Set changes another channel/TRC");
  CHECK (GIMP_LEVELS_CONFIG (node_config (s->operation))->channel == GIMP_HISTOGRAM_BLUE &&
         binding_shape (point_for (s->operation)) && settings_are (&f, filter, &next), "public Set also preserves cursor/TRC coupling");

  GlimsLevelsSettings zeros = identity; settings_fields (&zeros, fields);
  for (guint i = 0; i < 25; i++) if (i%5 != 2) *fields[i] = 0;
  NEED (api->filter_levels_set (engine, filter, &zeros, &error) == GLIMS_STATUS_OK, "signed-zero baseline has all20 endpoints0 and valid gamma1");
  GObject *same = node_config (s->operation); guint notifications = 0;
  gulong signal = g_signal_connect (gegl_node_get_gegl_operation (s->operation), "notify::config", G_CALLBACK (notified), &notifications);
  for (guint i = 0; i <= 25; i++) {
    if (i < 25 && i%5 == 2) continue; /* gamma0 is invalid, not a no-op. */
    GlimsLevelsSettings value = zeros; settings_fields (&value, fields);
    if (i < 25) *fields[i] = -0.0;
    else for (guint j = 0; j < 25; j++) if (j%5 != 2) *fields[j] = -0.0;
    changed = TRUE;
    CHECK (api->filter_levels_set (engine, filter, &value, &error) == GLIMS_STATUS_OK &&
           glims_levels_config_set (s->operation, &value, &changed, NULL) == GLIMS_STATUS_OK && !changed &&
           node_config (s->operation) == same && notifications == 0 && history_equal (&f, &history),
           "each/all valid signed-zero endpoints are config/notify/history no-ops"); clear_error (&error);
  }
  g_signal_handler_disconnect (gegl_node_get_gegl_operation (s->operation), signal);
  NEED (api->filter_levels_set (engine, filter, &rich, &error) == GLIMS_STATUS_OK && read_pixels (&f, TRUE, preview), "invalid-request baseline reads");
  same = node_config (s->operation);
  const double invalid[] = {NAN, INFINITY, -INFINITY, -0.01, 1.01};
  for (guint i = 0; i < 25; i++) {
    for (guint bad = 0; bad < 5; bad++) {
      GlimsLevelsSettings value = rich; settings_fields (&value, fields);
      *fields[i] = i%5 == 2 && bad >= 3 ? (bad == 3 ? 0.09 : 10.01) : invalid[bad];
      CHECK (api->filter_levels_set (engine, filter, &value, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
             node_config (s->operation) == same && settings_are (&f, filter, &rich) &&
             read_pixels (&f, TRUE, actual) && !memcmp (preview, actual, sizeof preview) && history_equal (&f, &history),
             "each25 field rejects NaN/Inf/both own-domain violations atomically"); clear_error (&error);
    }
    if (i%5 == 2) {
      GlimsLevelsSettings value = rich; settings_fields (&value, fields); *fields[i] = -0.0;
      CHECK (api->filter_levels_set (engine, filter, &value, &error) == GLIMS_STATUS_INVALID_ARGUMENT && node_config (s->operation) == same,
             "negative-zero gamma is invalid, never treated as a no-op"); clear_error (&error);
    }
  }
  for (guint flag = 0; flag < 2; flag++) for (guint bad = 0; bad < 2; bad++) {
    GlimsLevelsSettings value = rich; uint32_t invalid_flag = bad ? UINT32_MAX : 2;
    if (flag) value.clamp_output = invalid_flag; else value.clamp_input = invalid_flag;
    CHECK (api->filter_levels_set (engine, filter, &value, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
           node_config (s->operation) == same && settings_are (&f, filter, &rich), "both clamp flags reject nonboolean values without replacement"); clear_error (&error);
  }
  const uint32_t bad_trcs[] = {GLIMS_COLOR_TRC_UNKNOWN,4,UINT32_MAX};
  for (guint i = 0; i < G_N_ELEMENTS (bad_trcs); i++) {
    GlimsLevelsSettings value = rich; value.trc = bad_trcs[i];
    CHECK (api->filter_levels_set (engine, filter, &value, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
           node_config (s->operation) == same && settings_are (&f, filter, &rich), "unknown owned TRC refuses without repairing live state"); clear_error (&error);
  }
  CHECK (read_pixels (&f, TRUE, actual) && !memcmp (preview, actual, sizeof preview) && history_equal (&f, &history), "flag/TRC failures preserve exact preview and history");
  g_weak_ref_init (&last_weak, node_config (s->operation)); last_init = TRUE;
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "Levels preview aborts"); filter = 0;
  held = g_weak_ref_get (&last_weak); CHECK (!held, "aborted adapter-only config finalizes before any native Undo/XCF"); g_clear_object (&held);
  CHECK (read_pixels (&f, FALSE, actual) && !memcmp (raw, actual, sizeof raw) && history_equal (&f, &history), "Abort leaves source floats and history exact");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (old_init) g_weak_ref_clear (&old_weak);
  if (last_init) g_weak_ref_clear (&last_weak);
  g_clear_object (&held); clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
binding_admission (GlimsEngine *engine, gpointer unused)
{
  (void) engine; (void) unused;
  char *error = NULL; GObject *witness = NULL;
  GeglNode *source = gegl_node_new_child (NULL, "operation", "gimp:levels", NULL);
  GeglNode *dest = gegl_node_new_child (NULL, "operation", "gimp:levels", NULL);
#if GIMP_CHECK_VERSION (3, 2, 0)
  GWeakRef old_binding; gboolean weak_init = FALSE;
#endif
  NEED (source && dest && glims_levels_config_prepare (source, &error) == GLIMS_STATUS_OK &&
        glims_levels_config_prepare (dest, &error) == GLIMS_STATUS_OK, "private clone nodes prepare explicit LINEAR defaults");
  GimpOperationPointFilter *src = point_for (source), *dst = point_for (dest);
  NEED (binding_shape (src) && binding_shape (dst), "normal one-way bindings/synchronized3.0 state are admitted");
  GObject *seed = node_config (source);
  NEED (seed && GIMP_IS_OPERATION_SETTINGS (seed), "clone source has actual inherited settings");
  g_object_set (seed, "gimp-opacity", 0.625, "gimp-clip", GIMP_TRANSFORM_RESIZE_CLIP,
                "gimp-region", GIMP_FILTER_REGION_DRAWABLE, "gimp-mode", GIMP_LAYER_MODE_MULTIPLY, NULL);
  GlimsLevelsSettings A = lv_rich (GLIMS_COLOR_TRC_NONLINEAR, 0.12), B = lv_rich (GLIMS_COLOR_TRC_PERCEPTUAL, 0.25), output = lv_empty ();
  gboolean changed = FALSE;
  NEED (glims_levels_config_set (source, &A, &changed, &error) == GLIMS_STATUS_OK && changed &&
        glims_levels_config_copy (dest, source, &error) == GLIMS_STATUS_OK, "private clone copies complete25/TRC/flags");
  witness = g_object_ref (node_config (source));
  GimpOperationSettings *base = GIMP_OPERATION_SETTINGS (witness);
  CHECK (base->opacity == 0.625 && base->clip == GIMP_TRANSFORM_RESIZE_CLIP && base->region == GIMP_FILTER_REGION_DRAWABLE &&
         base->mode == GIMP_LAYER_MODE_MULTIPLY, "first replacement preserves independently seeded config base fields");
  NEED (glims_levels_config_get (dest, &output, &error) == GLIMS_STATUS_OK && settings_equal (&output, &A), "copied value reads independently of a native cursor");
#if GIMP_CHECK_VERSION (3, 2, 0)
  g_weak_ref_init (&old_binding, dst->trc_binding); weak_init = TRUE;
#endif
  NEED (glims_levels_config_set (dest, &B, &changed, &error) == GLIMS_STATUS_OK && changed, "clone Set installs private replacement");
  GlimsLevelsSettings old = native_values (GIMP_LEVELS_CONFIG (witness));
  GimpOperationSettings *new_base = GIMP_OPERATION_SETTINGS (node_config (dest));
  CHECK (settings_equal (&old, &A) && node_config (source) == witness &&
         new_base->opacity == base->opacity && new_base->clip == base->clip && new_base->region == base->region && new_base->mode == base->mode,
         "old shared config remains immutable and all native base fields survive a private clone edit");
#if GIMP_CHECK_VERSION (3, 2, 0)
  GObject *held = g_weak_ref_get (&old_binding); CHECK (!held, "retired clone binding finalizes with no persistent adapter extra ref"); g_clear_object (&held);
#endif
  /* A deliberate old-source edit proves its retired link cannot drive dest. */
  g_object_set (witness, "trc", GIMP_TRC_LINEAR, NULL);
  CHECK (dst->trc == GIMP_TRC_PERCEPTUAL && binding_shape (dst), "retired source TRC cannot redirect the replacement operation");
  g_object_set (witness, "trc", GIMP_TRC_NON_LINEAR, NULL);
  output = lv_empty ();
  CHECK (glims_levels_config_get (dest, &output, &error) == GLIMS_STATUS_OK && settings_equal (&output, &B), "replacement full value stays authoritative after old-source notifications");
  clear_error (&error);
  /* A direct op write desynchronizes the one-way pair on every version. */
  g_object_set (dst, "trc", GIMP_TRC_LINEAR, NULL);
  output = lv_filled (7); changed = TRUE;
  CHECK (glims_levels_config_get (dest, &output, &error) == GLIMS_STATUS_UNSUPPORTED && settings_equal (&output, &(GlimsLevelsSettings){0}),
         "legacy operation/config TRC mismatch refuses and zeroes every owned output"); clear_error (&error);
  CHECK (glims_levels_config_set (dest, &B, &changed, &error) == GLIMS_STATUS_UNSUPPORTED && !changed && dst->trc == GIMP_TRC_LINEAR &&
         GIMP_LEVELS_CONFIG (dst->config)->trc == GIMP_TRC_PERCEPTUAL,
         "mismatched Set refuses without silently normalizing either live TRC"); clear_error (&error);
  GObject *source_before = src->config;
  CHECK (glims_levels_config_copy (source, dest, &error) == GLIMS_STATUS_UNSUPPORTED && src->config == source_before,
         "mismatched copy refuses without replacing destination config"); clear_error (&error);
  g_object_set (dst, "trc", GIMP_TRC_PERCEPTUAL, NULL);
#if GIMP_CHECK_VERSION (3, 2, 0)
  for (guint mode = 0; mode < 3; mode++) {
    GeglNode *bad_node = gegl_node_new_child (NULL, "operation", "gimp:levels", NULL);
    GimpLevelsConfig *other = g_object_new (GIMP_TYPE_LEVELS_CONFIG, NULL);
    GimpOperationPointFilter *bad_point = NULL;
    gboolean ready = bad_node && other && glims_levels_config_prepare (bad_node, &error) == GLIMS_STATUS_OK;
    CHECK (ready, "bad-binding fixture prepares actual typed endpoints");
    if (ready) {
      bad_point = point_for (bad_node); retire_binding (bad_point);
      GObject *from = mode == 0 ? G_OBJECT (other) : bad_point->config;
      GObject *to = mode == 1 ? G_OBJECT (other) : G_OBJECT (bad_point);
      bad_point->trc_binding = g_object_bind_property (from, "trc", to, "trc", mode == 2 ? G_BINDING_BIDIRECTIONAL : G_BINDING_DEFAULT);
      ready = bad_point->trc_binding != NULL;
      CHECK (ready, "compatible enum properties construct a deliberate wrong source/target/flags binding");
      if (ready) {
        GObject *before = bad_point->config; GimpTRCType before_trc = bad_point->trc;
        GlimsLevelsSettings identity = lv_identity (); output = lv_filled (7); changed = TRUE;
        CHECK (glims_levels_config_get (bad_node, &output, &error) == GLIMS_STATUS_UNSUPPORTED && settings_equal (&output, &(GlimsLevelsSettings){0}),
               "wrong source/target/flags Get refuses with all owned outputs zero"); clear_error (&error);
        CHECK (glims_levels_config_set (bad_node, &identity, &changed, &error) == GLIMS_STATUS_UNSUPPORTED && !changed &&
               bad_point->config == before && bad_point->trc == before_trc, "bad binding Set is quiet and does not replace/normalize"); clear_error (&error);
        CHECK (glims_levels_config_copy (source, bad_node, &error) == GLIMS_STATUS_UNSUPPORTED && src->config == source_before,
               "bad source binding copy leaves a valid destination untouched"); clear_error (&error);
      }
    }
    if (bad_point && bad_point->trc_binding) retire_binding (bad_point);
    g_clear_object (&bad_node); g_clear_object (&other); clear_error (&error);
  }
  retire_binding (dst);
  dst->trc_binding = g_object_bind_property (dst->config, "trc", dst, "trc", G_BINDING_SYNC_CREATE);
  output = lv_empty ();
  CHECK (binding_shape (dst) && glims_levels_config_get (dest, &output, &error) == GLIMS_STATUS_OK && settings_equal (&output, &B),
         "native one-way SYNC_CREATE is admitted alongside the adapter staged DEFAULT binding");
#endif
cleanup:
#if GIMP_CHECK_VERSION (3, 2, 0)
  if (weak_init) g_weak_ref_clear (&old_binding);
#endif
  g_clear_object (&dest); g_clear_object (&source); g_clear_object (&witness); clear_error (&error);
  return GLIMS_STATUS_OK;
}


/* Keep an owned node witness so an unexpected old-code Commit success cannot
 * turn the regression's diagnostic/cleanup into a use-after-free. */
static GlimsStatus
bypass_refusals (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  for (guint direct_commit = 0; direct_commit < 3; direct_commit++) {
    Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
    GeglNode *held_node = NULL; GimpOperationPointFilter *point = NULL;
    GimpTRCType restore_trc = GIMP_TRC_LINEAR;
    gfloat raw[VALUES], after[VALUES], preview[VALUES], after_preview[VALUES];
    GlimsUndoInfo history = {0};
    NEED (fixture_open (engine, &f) && begin (&f, &filter, &error) == GLIMS_STATUS_OK,
          "TRC bypass regression opens an independent new Levels preview");
    GlimsLevelsSettings settings = lv_identity (); settings.value.gamma = 0.5;
    NEED (api->filter_levels_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK,
          "nonidentity Levels settings make TRC changes visibly meaningful");
    GlimsFilter *same = session (&f, filter);
    NEED (same && same->operation, "bypass fixture resolves the actual session");
    held_node = g_object_ref (same->operation); point = point_for (held_node);
    NEED (point && point->config && GIMP_IS_LEVELS_CONFIG (point->config), "bypass fixture owns a live typed node witness");
    restore_trc = point->trc;
    GObject *config = point->config;
    if (direct_commit == 1) g_object_set (point, "trc", GIMP_TRC_NON_LINEAR, NULL);
    NEED (read_pixels (&f, FALSE, raw) && read_pixels (&f, TRUE, preview) &&
          api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK,
          "bypass refusal baseline records actual raw/preview/history after deliberate mismatch");
    if (direct_commit != 1) {
      GlimsFilterValue value = { .kind = GLIMS_FILTER_VALUE_ENUM };
      strcpy (value.string, "non-linear");
      GlimsStatus write_status = direct_commit == 2
          ? api->filter_set_double (engine, filter, "trc", (double) GIMP_TRC_NON_LINEAR)
          : api->filter_set_property (engine, filter, "trc", &value);
      CHECK (write_status == (direct_commit == 2 ? GLIMS_STATUS_INVALID_ARGUMENT : GLIMS_STATUS_UNSUPPORTED),
             direct_commit == 2 ? "legacy numeric Levels TRC rejects unsupported double-to-enum conversion"
                                : "generic Levels TRC write refuses; complete typed settings own TRC changes");
      CHECK (point->config == config && point->trc == restore_trc &&
             GIMP_LEVELS_CONFIG (config)->trc == restore_trc && settings_are (&f, filter, &settings) &&
             read_pixels (&f, TRUE, after_preview) && !memcmp (preview, after_preview, sizeof preview) &&
             read_pixels (&f, FALSE, after) && !memcmp (raw, after, sizeof raw) && history_equal (&f, &history),
             "generic TRC refusal preserves config/op, visible pixels, source and history");
    } else {
      CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_UNSUPPORTED && session (&f, filter) == same,
             "a NEW mismatched Levels preview cannot commit and remains available to Abort"); clear_error (&error);
      CHECK (point->config == config && point->trc == GIMP_TRC_NON_LINEAR &&
             GIMP_LEVELS_CONFIG (config)->trc == restore_trc && history_equal (&f, &history) &&
             read_pixels (&f, FALSE, after) && !memcmp (raw, after, sizeof raw) &&
             read_pixels (&f, TRUE, after_preview) && !memcmp (preview, after_preview, sizeof preview),
             "mismatched new Commit adds no Undo and changes neither source nor existing preview");
    }
    g_object_set (point, "trc", restore_trc, NULL);
    if (session (&f, filter)) {
      NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "restored mismatched/generic preview still aborts"); filter = 0;
    }
cleanup:
    if (point) g_object_set (point, "trc", restore_trc, NULL);
    if (filter && session (&f, filter)) api->filter_abort (engine, filter);
    g_clear_object (&held_node); clear_error (&error); fixture_close (&f);
  }
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
config_values_are (GObject *object, const GlimsLevelsSettings *expected)
{
  if (!object || !GIMP_IS_LEVELS_CONFIG (object)) return FALSE;
  GimpLevelsConfig *c = GIMP_LEVELS_CONFIG (object);
  GlimsLevelsSettings actual = native_values (c);
  return settings_equal (&actual, expected);
}

static gboolean
effect_pair_values (Fixture *f, GlimsEffectID id, const GlimsLevelsSettings *expected)
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
xcf_roundtrip (Fixture *f, const char *filename, const GlimsLevelsSettings *expected)
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
    if (!strcmp (effects[i].operation, "gimp:levels")) selected = effects[i].id;
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
  GlimsLevelsSettings settings = lv_identity (); settings.value.gamma = 2;
  NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK &&
        api->filter_levels_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
        read_pixels (&f, TRUE, preview), "new effect preview accepts a nondefault whole value");
  CHECK (fabs (preview[0]-0.5) < 2e-4 && fabs (preview[1]-0.707106781187) < 2e-4 &&
         fabs (preview[2]-0.866025403784) < 2e-4 && fabs (preview[3]-0.25) < 2e-4,
         "public LINEAR Value gamma2 preview matches independent literals and skips alpha");
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
  CHECK (xcf_roundtrip (&f, "levels-new.xcf", &settings), "XCF fresh reopen preserves actual Levels and pixels");
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
    GlimsLevelsSettings A = lv_rich (GLIMS_COLOR_TRC_LINEAR, 0.1), B = A, C;
    B.red.gamma = 1.7; B.blue.low_output = 0.2; B.trc = GLIMS_COLOR_TRC_PERCEPTUAL;
    C = B; C.value.gamma = 0.7; C.alpha.low_output = 0.05; C.trc = GLIMS_COLOR_TRC_NONLINEAR;
    NEED (api->filter_levels_set (engine, filter, &A, &error) == GLIMS_STATUS_OK, "initial immutable A replacement succeeds");
    GimpOperationSettings *base = GIMP_OPERATION_SETTINGS (node_config (s->operation));
    NEED (base->opacity == 0.625 && base->clip == GIMP_TRANSFORM_RESIZE_CLIP &&
          base->region == GIMP_FILTER_REGION_DRAWABLE && base->mode == GIMP_LAYER_MODE_MULTIPLY,
          "first immutable duplicate preserves independently seeded native base fields");
    NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "initial immutable A config commits"); filter = 0;
    NEED (effect_rows (&f, rows, 4, &count) && count == 1, "one real committed Levels effect is present");
    GlimsEffectID effect_id = rows[0].id;
    NEED (api->filter_begin (engine, f.id, layer_id (&f), "gegl:invert-linear", &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK,
          "second real effect gives Levels a meaningful stack position"); filter = 0;
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
    NEED (api->filter_levels_set (engine, filter, &B, &error) == GLIMS_STATUS_OK, "shadow changes A to B");
    saved_b = g_object_ref (node_config (session (&f, filter)->operation));
    NEED (api->filter_levels_set (engine, filter, &C, &error) == GLIMS_STATUS_OK, "shadow changes B to C");
    CHECK (effect_pair_values (&f, effect_id, &A) &&
           native_base_equal (saved_a, node_config (gimp_drawable_filter_get_operation (effect))),
           "B and C replacements never mutate installed A config or native base fields");
    CHECK (config_values_are (saved_a, &A) && config_values_are (saved_b, &B),
           "all25/TRC/clamps values in original A and earlier B stay immutable");
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "existing-effect Cancel drops only the shadow"); filter = 0;
    EffectState current = effect_state (&f, effect);
    CHECK (effect_state_equal (&state, &current) && effect_pair_values (&f, effect_id, &A) &&
           history_equal (&f, &before) && read_pixels (&f, TRUE, actual) && close_pixels (original, actual),
           "Cancel preserves enabled state, stack, blend/base, pixels and history");
    NEED (api->filter_edit_begin (engine, f.id, layer_id (&f), effect_id, &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_levels_set (engine, filter, &B, &error) == GLIMS_STATUS_OK &&
          api->filter_levels_set (engine, filter, &C, &error) == GLIMS_STATUS_OK &&
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
           "all25/TRC/clamps witness values stay immutable across native Undo/Redo");
    CHECK (xcf_roundtrip (&f, disabled ? "levels-existing-disabled.xcf" : "levels-existing-enabled.xcf", &C),
           "XCF preserves all25/TRC/clamps config, base/order/active/pixels with native AUTO composite normalization");
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
  return gimp_image_undo_group_start (f->image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "Levels history guard");
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
    refuses_begin (&f, GLIMS_STATUS_BUSY, "disabled/frozen/grouped Undo refuses new Levels Begin");
    unblock_history (&f, mode); blocked = FALSE;
    GlimsLevelsSettings settings = lv_rich (GLIMS_COLOR_TRC_LINEAR, 0.15);
    NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_levels_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK,
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
  GlimsLevelsSettings settings = lv_rich (GLIMS_COLOR_TRC_LINEAR, 0.15);
  GlimsLevelsSettings output = lv_filled (7);
  GlimsLevelsSettings zero_output = lv_empty ();
  CHECK (api->filter_levels_get (engine, INT_MAX, &output, &error) == GLIMS_STATUS_NOT_FOUND &&
         settings_equal (&output, &zero_output) && output.struct_size == sizeof output,
         "stale Get reports NOT_FOUND and resets every owned field without changing size");
  clear_error (&error);
  CHECK (api->filter_levels_set (engine, INT_MAX, &settings, &error) == GLIMS_STATUS_NOT_FOUND, "stale Set refuses");
  clear_error (&error);
  CHECK (api->filter_levels_get (engine, INT_MAX, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
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
  CHECK (api->filter_levels_set (engine, filter, &settings, &error) == GLIMS_STATUS_LOCKED &&
         node_config (s->operation) == config, "locked Set preserves the installed config");
  clear_error (&error);
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), FALSE, FALSE);
  engine->busy++;
  GlimsStatus status = api->filter_levels_set (engine, filter, &settings, &error);
  engine->busy--;
  CHECK (status == GLIMS_STATUS_BUSY && node_config (s->operation) == config, "busy Set preserves the installed config");
  clear_error (&error);

  GlimsLevelsSettings small = lv_identity (); small.struct_size = sizeof small - 1;
  GlimsLevelsSettings expected_default = lv_identity ();
  CHECK (api->filter_levels_set (engine, filter, &small, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->filter_levels_set (engine, filter, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         settings_are (&f, filter, &expected_default),
         "undersized and NULL settings refuse without changing settings");
  clear_error (&error);
  CHECK (read_pixels (&f, FALSE, after) && !memcmp (raw, after, sizeof raw) && history_equal (&f, &history),
         "typed write refusals preserve raw pixels/history");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "refusal preview aborts"); filter = 0;

  NEED (api->filter_begin (engine, f.id, layer_id (&f), "gegl:invert-linear", &filter, &error) == GLIMS_STATUS_OK,
        "wrong-operation preview starts independently");
  CHECK (api->filter_levels_get (engine, filter, &output, &error) == GLIMS_STATUS_UNSUPPORTED &&
         api->filter_levels_set (engine, filter, &settings, NULL) == GLIMS_STATUS_UNSUPPORTED,
         "typed get/set refuse a real non-Levels operation");
  clear_error (&error);
  refuses_begin (&f, GLIMS_STATUS_BUSY, "another active preview refuses Levels Begin");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "wrong-operation preview aborts"); filter = 0;

  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PAINTBRUSH,
                               .size = 3, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint point = {2, 2, 1, 0, 0, 0};
  NEED (api->stroke_begin (engine, f.id, layer_id (&f), &brush, &point, &stroke, &error) == GLIMS_STATUS_OK,
        "real stroke starts for admission regression");
  refuses_begin (&f, GLIMS_STATUS_BUSY, "active native stroke refuses Levels Begin");
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
      !api->filter_levels_get || !api->filter_levels_set) return 2;
  char *error = NULL; GlimsLevelsSettings output = lv_filled (7);
  GlimsLevelsSettings zero_output = lv_empty ();
  struct { GlimsLevelsSettings value; guint64 tail; } stopped;
  memset (&stopped, 0xA5, sizeof stopped); stopped.value.struct_size = sizeof stopped;
  guint64 stopped_tail = stopped.tail;
  CHECK (api->filter_levels_get (NULL, 1, &stopped.value, &error) == GLIMS_STATUS_NOT_RUNNING &&
         settings_equal (&stopped.value, &zero_output) && stopped.value.struct_size == sizeof stopped &&
         stopped.tail == stopped_tail,
         "nonrunning slot154 resets all owned fields while preserving size/future tail");
  clear_error (&error);

  gchar *user = g_build_filename (work_dir, "user", NULL), *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed");
    clear_error (&error); g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, raw_oracles, NULL) == GLIMS_STATUS_OK,
         "13 raw literals and TRC fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, values_and_lifetime, NULL) == GLIMS_STATUS_OK,
         "whole-value/validation/lifetime fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, binding_admission, NULL) == GLIMS_STATUS_OK,
         "versioned binding/TRC fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, bypass_refusals, NULL) == GLIMS_STATUS_OK,
         "generic/new-commit TRC bypass regressions run on the engine worker");
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
    CHECK (api->filter_begin (engine, public.f.id, public.target, "gimp:levels", &filter, &error) == GLIMS_STATUS_OK &&
           filter > 0, "public host-thread preview starts");
    clear_error (&error);
    if (filter) {
      GlimsLevelsSettings settings = lv_rich (GLIMS_COLOR_TRC_NONLINEAR, 0.125);
      output = lv_empty ();
      CHECK (api->filter_levels_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
             api->filter_levels_get (engine, filter, &output, NULL) == GLIMS_STATUS_OK &&
             settings_equal (&output, &settings),
             "public host-thread slots154/155 marshal the exact complete value");
      clear_error (&error);
      struct { GlimsLevelsSettings value; guint64 tail; } sized, before;
      memset (&sized, 0xA5, sizeof sized); sized.value.struct_size = sizeof sized.value - 1; before = sized;
      CHECK (api->filter_levels_get (engine, filter, &sized.value, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
             !memcmp (&sized, &before, sizeof sized),
             "undersized Get leaves all caller sentinel bytes untouched");
      clear_error (&error);
      memset (&sized, 0xA5, sizeof sized); sized.value.struct_size = sizeof sized; before = sized;
      CHECK (api->filter_levels_get (engine, filter, &sized.value, &error) == GLIMS_STATUS_OK &&
             sized.tail == before.tail && settings_equal (&sized.value, &settings),
             "valid extensible Get does not overwrite a future caller tail");
      clear_error (&error);
      before = sized;
      CHECK (api->filter_levels_set (engine, filter, &sized.value, &error) == GLIMS_STATUS_OK &&
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

/* Public color-property coverage. Expectations come from independent same-op
 * GEGL nodes and GLib default GValues, never the adapter's property helpers.
 * All native objects are accessed only on the engine worker. */
#include "engine-private.h"
#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
#include "core/gimp.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "gegl/gimp-gegl-utils.h"
#endif
#include <math.h>
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

#define SIDE 8
#define VALUES (SIDE * SIDE * 4)
static const GlimsEngineAPI *api;
static guint checks, failures;
static const GlimsColor requested = {0.2, 0.7, 0.35, 0.25};
static const gchar *peers[] = {"hue", "saturation", "lightness"};
static const gdouble peer_values[] = {0.125, 0.625, -0.25};
#define CHECK(c, op, text) do { gboolean ok_ = (c); checks++; \
  printf ("%s %s: %s\n", ok_ ? "ok  " : "FAIL", op, text); \
  if (!ok_) failures++; fflush (stdout); } while (0)

typedef struct {
  const gchar *name;
  GlimsEngine *engine;
  GlimsImageID image;
  GlimsItemID target;
  GimpLayer *layer;                 /* borrowed while image is open */
  GeglNode *graph, *node;            /* graph owns node */
  GeglBuffer *input;                /* owned independent source */
  GlimsColor declared, initial, changed, after_peers;
  gdouble changed_scalars[3];
  gfloat original[VALUES], defaults[VALUES], colored[VALUES], scalar_pixels[VALUES];
  GlimsUndoInfo history;
} Case;

typedef struct {
  Case *test;
  const gfloat *expected;
  gboolean exact_history;
  gint undo_delta;
} Verification;

static gboolean
color_close (GlimsColor a, GlimsColor b)
{
  return isfinite (a.red) && isfinite (a.green) && isfinite (a.blue) && isfinite (a.alpha) &&
    fabs (a.red - b.red) < 1e-6 && fabs (a.green - b.green) < 1e-6 &&
    fabs (a.blue - b.blue) < 1e-6 && fabs (a.alpha - b.alpha) < 1e-6;
}

static gboolean
value_color (const GValue *value, GlimsColor *out)
{
  GeglColor *color = g_value_get_object (value); /* borrowed from GValue */
  gdouble rgba[4];
  if (!color || !GEGL_IS_COLOR (color)) return FALSE;
  gegl_color_get_pixel (color, babl_format ("R'G'B'A double"), rgba);
  *out = (GlimsColor) {rgba[0], rgba[1], rgba[2], rgba[3]};
  return color_close (*out, *out);
}

static gboolean
node_color (GeglNode *node, GlimsColor *out)
{
  GValue value = G_VALUE_INIT;
  g_value_init (&value, GEGL_TYPE_COLOR);
  gegl_node_get_property (node, "color", &value);
  gboolean ok = value_color (&value, out);
  g_value_unset (&value);
  return ok;
}

static void
set_node_color (GeglNode *node)
{
  GeglColor *color = gegl_color_new (NULL);
  const gdouble rgba[] = {requested.red, requested.green, requested.blue, requested.alpha};
  gegl_color_set_pixel (color, babl_format ("R'G'B'A double"), rgba);
  GValue value = G_VALUE_INIT;
  g_value_init (&value, GEGL_TYPE_COLOR);
  g_value_set_object (&value, color);
  gegl_node_set_property (node, "color", &value);
  g_value_unset (&value);
  g_object_unref (color);
}

static void
render_node (Case *test, gfloat *pixels)
{
  gegl_node_blit (test->node, 1.0, GEGL_RECTANGLE (0, 0, SIDE, SIDE),
                  babl_format ("RGBA float"), pixels, GEGL_AUTO_ROWSTRIDE, GEGL_BLIT_DEFAULT);
}

static gboolean
pixels_close (const gfloat *a, const gfloat *b)
{
  for (guint i = 0; i < VALUES; i++)
    if (!isfinite (a[i]) || !isfinite (b[i]) || fabs (a[i] - b[i]) > 2e-5) return FALSE;
  return TRUE;
}

static GlimsStatus
prepare (GlimsEngine *engine, gpointer data)
{
  Case *test = data;
  test->engine = engine;
  GimpImage *image = gimp_create_image (engine->gimp, SIDE, SIDE, GIMP_RGB,
                                       GIMP_PRECISION_FLOAT_LINEAR, FALSE);
  if (!image) return GLIMS_STATUS_FAILED;
  if (glims_adopt_image (engine, image, &test->image) != GLIMS_STATUS_OK) {
    g_object_unref (image); return GLIMS_STATUS_FAILED;
  }
  test->layer = gimp_layer_new (image, SIDE, SIDE, gimp_image_get_layer_format (image, TRUE),
                                "Color property target", 1.0, GIMP_LAYER_MODE_NORMAL);
  if (!test->layer) return GLIMS_STATUS_FAILED;
  if (!gimp_image_add_layer (image, test->layer, NULL, 0, FALSE)) {
    g_object_unref (test->layer); test->layer = NULL; return GLIMS_STATUS_FAILED;
  }
  test->target = gimp_item_get_id (GIMP_ITEM (test->layer));
  for (guint i = 0; i < VALUES; i += 4) {
    test->original[i] = 0.1f + (i / 4 % SIDE) * 0.07f;
    test->original[i + 1] = 0.2f + (i / 4 / SIDE) * 0.06f;
    test->original[i + 2] = 0.65f;
    test->original[i + 3] = (i / 4 % 3 == 0) ? 0.25f : (i / 4 % 3 == 1 ? 0.625f : 1.0f);
  }
  GeglBuffer *target = gimp_drawable_get_buffer (GIMP_DRAWABLE (test->layer)); /* borrowed */
  gegl_buffer_set (target, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("RGBA float"),
                   test->original, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (test->layer), 0, 0, SIDE, SIDE);
  gimp_image_clean_all (image);
  if (api->image_undo_info (engine, test->image, &test->history) != GLIMS_STATUS_OK) return GLIMS_STATUS_FAILED;

  test->input = gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE), gegl_buffer_get_format (target));
  gegl_buffer_set (test->input, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("RGBA float"),
                   test->original, GEGL_AUTO_ROWSTRIDE);
  test->graph = gegl_node_new ();
  GeglNode *source = gegl_node_new_child (test->graph, "operation", "gegl:buffer-source", "buffer", test->input, NULL);
  test->node = gegl_node_new_child (test->graph, "operation", test->name, NULL);
  if (!test->node || !source) return GLIMS_STATUS_FAILED;
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  gboolean connected = gegl_node_connect_to (source, "output", test->node, "input");
  G_GNUC_END_IGNORE_DEPRECATIONS
  if (!connected) return GLIMS_STATUS_FAILED;
  GParamSpec *spec = gegl_node_find_property (test->node, "color"); /* borrowed */
  if (!spec || !GIMP_IS_PARAM_SPEC_COLOR (spec) || G_PARAM_SPEC_VALUE_TYPE (spec) != GEGL_TYPE_COLOR)
    return GLIMS_STATUS_FAILED;
  GValue declared = G_VALUE_INIT;
  g_value_init (&declared, G_PARAM_SPEC_VALUE_TYPE (spec));
  g_param_value_set_default (spec, &declared);
  gboolean ok = value_color (&declared, &test->declared);
  g_value_unset (&declared);
  if (!ok) return GLIMS_STATUS_FAILED;

  if (!strcmp (test->name, "gimp:offset")) {
    GParamSpec *type = gegl_node_find_property (test->node, "type");
    if (!type || !G_IS_PARAM_SPEC_ENUM (type)) return GLIMS_STATUS_FAILED;
    GEnumClass *klass = g_type_class_ref (G_PARAM_SPEC_VALUE_TYPE (type));
    GEnumValue *fill = g_enum_get_value_by_nick (klass, "color");
    gboolean found = fill != NULL;
    if (fill) gegl_node_set (test->node, "type", fill->value, "x", 2, "y", 1, NULL);
    g_type_class_unref (klass);
    if (!found) return GLIMS_STATUS_FAILED;
  }
  /* Rendering first prepares Colorize's real input-space HSL format. */
  render_node (test, test->defaults);
  if (!node_color (test->node, &test->initial)) return GLIMS_STATUS_FAILED;
  set_node_color (test->node);
  render_node (test, test->colored);
  if (!node_color (test->node, &test->changed)) return GLIMS_STATUS_FAILED;
  if (!strcmp (test->name, "gimp:colorize")) {
    for (guint i = 0; i < G_N_ELEMENTS (peers); i++)
      gegl_node_get (test->node, peers[i], &test->changed_scalars[i], NULL);
    for (guint i = 0; i < G_N_ELEMENTS (peers); i++)
      gegl_node_set (test->node, peers[i], peer_values[i], NULL);
    render_node (test, test->scalar_pixels);
    if (!node_color (test->node, &test->after_peers) ||
        !pixels_close (test->scalar_pixels, test->scalar_pixels)) return GLIMS_STATUS_FAILED;
  }
  if (!pixels_close (test->defaults, test->defaults) ||
      !pixels_close (test->colored, test->colored)) return GLIMS_STATUS_FAILED;
  return GLIMS_STATUS_OK;
}

static GlimsStatus
verify (GlimsEngine *engine, gpointer data)
{
  Verification *request = data; Case *test = request->test;
  gfloat actual[VALUES], raw[VALUES]; GlimsUndoInfo history = {0};
  GimpDrawable *drawable = GIMP_DRAWABLE (test->layer);
  gimp_pickable_flush (GIMP_PICKABLE (drawable));
  GeglBuffer *buffer = gimp_drawable_get_buffer_with_effects (drawable); /* owned */
  if (!buffer) return GLIMS_STATUS_FAILED;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 1.0, babl_format ("RGBA float"),
                   actual, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  g_object_unref (buffer);
  gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, SIDE, SIDE),
                   1.0, babl_format ("RGBA float"), raw, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  if (api->image_undo_info (engine, test->image, &history) != GLIMS_STATUS_OK) return GLIMS_STATUS_FAILED;
  return pixels_close (actual, request->expected) && !memcmp (raw, test->original, sizeof raw) &&
    (request->exact_history ? !memcmp (&history, &test->history, sizeof history) :
     history.undo_count == test->history.undo_count + request->undo_delta) ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static gboolean
matches (Case *test, const gfloat *expected, gboolean exact_history, gint undo_delta)
{
  Verification request = {test, expected, exact_history, undo_delta};
  return glims_engine_call (test->engine, verify, &request) == GLIMS_STATUS_OK;
}

static GlimsStatus
release_case (GlimsEngine *engine, gpointer data)
{
  Case *test = data;
  g_clear_object (&test->graph); test->node = NULL;
  g_clear_object (&test->input);
  GlimsStatus status = test->image ? api->image_close (engine, test->image) : GLIMS_STATUS_OK;
  test->image = 0; test->layer = NULL;
  return status;
}

static gboolean
property_metadata (GlimsEngine *engine, const gchar *name, GlimsFilterProperty *color)
{
  gint32 count = 0, received = 0;
  if (api->filter_operation_properties (engine, name, NULL, 0, &count) != GLIMS_STATUS_OK || count <= 0 || count > 128)
    return FALSE;
  GlimsFilterProperty *properties = g_new0 (GlimsFilterProperty, count);
  gboolean ok = api->filter_operation_properties (engine, name, properties, count, &received) == GLIMS_STATUS_OK && received == count;
  gboolean found = FALSE;
  if (ok) for (gint32 i = 0; i < count; i++) {
    if (!strcmp (properties[i].name, "color")) { *color = properties[i]; found = TRUE; }
  }
  g_free (properties);
  return ok && found;
}

static gboolean
configure_offset (Case *test, GlimsFilterID filter)
{
  if (strcmp (test->name, "gimp:offset")) return TRUE;
  GlimsFilterValue type = {.kind = GLIMS_FILTER_VALUE_ENUM, .string = "color"};
  GlimsFilterValue x = {.kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 2};
  GlimsFilterValue y = {.kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 1};
  return api->filter_set_property (test->engine, filter, "type", &type) == GLIMS_STATUS_OK &&
    api->filter_set_property (test->engine, filter, "x", &x) == GLIMS_STATUS_OK &&
    api->filter_set_property (test->engine, filter, "y", &y) == GLIMS_STATUS_OK;
}

static gboolean
public_color (Case *test, GlimsFilterID filter, GlimsColor expected)
{
  GlimsFilterValue value = {0};
  return api->filter_get_property (test->engine, filter, "color", &value) == GLIMS_STATUS_OK &&
    value.kind == GLIMS_FILTER_VALUE_COLOR && color_close (value.color, expected);
}

static void
exercise (GlimsEngine *engine, const gchar *name)
{
  Case test = {.name = name}; GlimsFilterID filter = 0; char *error = NULL;
  GlimsFilterValue value = {.kind = GLIMS_FILTER_VALUE_COLOR, .color = requested};
  GlimsFilterProperty metadata = {0};
  gboolean ready = glims_engine_call (engine, prepare, &test) == GLIMS_STATUS_OK;
  CHECK (ready, name, "independent float fixture has real GIMP color paramspec, native defaults and prepared GEGL graph");
  if (!ready) goto cleanup;
  gboolean colorize = !strcmp (name, "gimp:colorize");
  CHECK (!pixels_close (test.defaults, test.colored) && !pixels_close (test.original, test.colored) &&
    (!colorize || (test.changed.alpha == 1.0 && test.changed.alpha != requested.alpha &&
                   !pixels_close (test.colored, test.scalar_pixels))), name,
    "native color and scalar reference changes are nondegenerate; Colorize reconstructs opaque color from HSL");
#if GIMP_CHECK_VERSION (3, 2, 0)
  if (!strcmp (name, "gimp:offset")) {
    GError *reason = NULL;
    gboolean allowed = gimp_gegl_op_nde_allowed (name, &reason);
    if (!allowed) {
      /* 3.2.0's native gate predates the Offset transform exception.
       * Keep that engine policy; do not enable a hidden operation to test it. */
      gint32 count = 777;
      CHECK (reason != NULL && api->filter_operation_properties (engine, name, NULL, 0, &count) == GLIMS_STATUS_INVALID_ARGUMENT,
             name, "native NDE refusal also gates public form metadata");
      filter = 777;
      GlimsStatus refused = api->filter_begin (engine, test.image, test.target, name, &filter, &error);
      CHECK (refused == GLIMS_STATUS_INVALID_ARGUMENT && filter == 0,
             name, "native-gated Offset refuses public Begin without a live session");
      CHECK (matches (&test, test.original, TRUE, 0), name,
             "native-gated Offset leaves raw/projected pixels and history unchanged");
      g_clear_error (&reason);
      goto cleanup;
    }
    g_clear_error (&reason);
  }
#endif
  gboolean listed = property_metadata (engine, name, &metadata);
  CHECK (listed, name, "public property catalog contains the real color row");
  CHECK (listed && metadata.kind == GLIMS_FILTER_VALUE_COLOR && color_close (metadata.default_color, test.declared),
         name, "public COLOR metadata default equals independent native paramspec default GValue");
  gboolean begun = api->filter_begin (engine, test.image, test.target, name, &filter, &error) == GLIMS_STATUS_OK && filter > 0;
  if (error) { fprintf (stderr, "%s Begin: %s\n", name, error); api->free_string (error); error = NULL; }
  CHECK (begun, name, "public preview begins on the original explicit pixel layer");
  if (!begun) goto cleanup;
  if (!strcmp (name, "gimp:offset")) {
    gboolean configured = configure_offset (&test, filter);
    CHECK (configured, name, "public enum and integer peers select color-fill Offset with nonzero displacement");
    if (!configured) goto cleanup;
  }
  CHECK (matches (&test, test.defaults, TRUE, 0), name, "default native preview equals independent graph without stored-pixel or history changes");
  CHECK (public_color (&test, filter, test.initial), name, "public COLOR Get equals native current operation color, separately from declared default");
  GlimsStatus status = api->filter_set_property (engine, filter, "color", &value);
  CHECK (status == GLIMS_STATUS_OK, name, "public COLOR Set accepts an explicit finite sRGB color");
  if (status != GLIMS_STATUS_OK) {
    printf ("NOT RUN %s: color-write readbacks, coupling and Apply/Undo require accepted COLOR Set\n", name);
    goto cleanup;
  }
  CHECK (public_color (&test, filter, test.changed), name, "post-Set color equals direct operation readback, not an echo of caller RGBA");
  if (colorize) {
    gboolean coupled = TRUE;
    for (guint i = 0; i < G_N_ELEMENTS (peers); i++) {
      GlimsFilterValue scalar = {0};
      coupled = api->filter_get_property (engine, filter, peers[i], &scalar) == GLIMS_STATUS_OK &&
        scalar.kind == GLIMS_FILTER_VALUE_NUMBER && fabs (scalar.number - test.changed_scalars[i]) < 1e-6 && coupled;
    }
    CHECK (coupled, name, "color Set recalculates all three public HSL scalar peers exactly as native Colorize");
  }
  CHECK (matches (&test, test.colored, TRUE, 0), name, "color-write preview equals independently rendered native graph and changes no history or raw pixels");
  if (colorize) {
    gboolean changed = TRUE;
    for (guint i = 0; i < G_N_ELEMENTS (peers); i++) {
      GlimsFilterValue scalar = {.kind = GLIMS_FILTER_VALUE_NUMBER, .number = peer_values[i]};
      changed = api->filter_set_property (engine, filter, peers[i], &scalar) == GLIMS_STATUS_OK && changed;
    }
    CHECK (changed, name, "ordinary public hue, saturation and lightness setters remain accepted");
    CHECK (public_color (&test, filter, test.after_peers), name, "scalar peer edits recalculate public color instead of retaining stale setter RGBA");
    CHECK (matches (&test, test.scalar_pixels, TRUE, 0), name, "coupled scalar preview matches fresh direct native rendering");
  }
  status = api->filter_abort (engine, filter);
  CHECK (status == GLIMS_STATUS_OK, name, "Cancel aborts the accepted color preview");
  if (status != GLIMS_STATUS_OK) goto cleanup;
  filter = 0;
  CHECK (matches (&test, test.original, TRUE, 0), name, "Cancel restores exact raw/projected pixels and the original history");
  begun = api->filter_begin (engine, test.image, test.target, name, &filter, &error) == GLIMS_STATUS_OK && filter > 0;
  if (error) { api->free_string (error); error = NULL; }
  gboolean configured = begun && configure_offset (&test, filter) &&
    matches (&test, test.defaults, TRUE, 0) &&
    api->filter_set_property (engine, filter, "color", &value) == GLIMS_STATUS_OK;
  CHECK (configured, name, "fresh public preview independently reinstalls the same color for Apply");
  if (!configured) goto cleanup;
  status = api->filter_commit (engine, filter, &error);
  if (error) { api->free_string (error); error = NULL; }
  CHECK (status == GLIMS_STATUS_OK, name, "Apply commits the accepted color operation");
  if (status != GLIMS_STATUS_OK) goto cleanup;
  filter = 0;
  CHECK (matches (&test, test.colored, FALSE, 1), name, "Apply matches the independent rendered graph and adds exactly one native Undo");
  CHECK (api->image_undo (engine, test.image) == GLIMS_STATUS_OK && matches (&test, test.original, FALSE, 0),
         name, "one Undo restores the original rendered and raw pixels");
  CHECK (api->image_redo (engine, test.image) == GLIMS_STATUS_OK && matches (&test, test.colored, FALSE, 1),
         name, "one Redo restores the independent color result");
cleanup:
  if (error) api->free_string (error);
  if (filter) CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, name, "unfinished preview aborts during owned cleanup");
  CHECK (glims_engine_call (engine, release_case, &test) == GLIMS_STATUS_OK, name, "owned native image and independent graph release before shutdown");
}

int main (int argc, char **argv);
int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api || !api->filter_operation_properties ||
      !api->filter_get_property || !api->filter_set_property) return 2;
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed");
    if (error) api->free_string (error);
    g_free (user); g_free (cache); return 2;
  }
  exercise (engine, "gimp:colorize");
  exercise (engine, "gimp:offset");
  exercise (engine, "gimp:semi-flatten");
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %u checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

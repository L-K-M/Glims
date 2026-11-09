/* Core-only fixtures. Never free borrowed selected-layer lists or compensate
 * for native Undo/XCF config-setter retention with extra unrefs. */
#include "engine-private.h"
#include "filter-config.h"
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
#include "operations/gimpoperationpointfilter.h"
#include "operations/gimpoperationsettings.h"
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

#define SIDE 8
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
static GlimsBrightnessContrastSettings pair (double b, double c) {
  GlimsBrightnessContrastSettings result = { .struct_size = sizeof result, .brightness = b, .contrast = c };
  return result;
}

static gboolean
fixture_open (GlimsEngine *engine, Fixture *f)
{
  memset (f, 0, sizeof *f); f->engine = engine;
  GimpImage *image = gimp_create_image (engine->gimp, SIDE, SIDE, GIMP_RGB, GIMP_PRECISION_FLOAT_LINEAR, FALSE);
  if (!image) return FALSE;
  if (glims_adopt_image (engine, image, &f->id) != GLIMS_STATUS_OK) { g_object_unref (image); return FALSE; }
  f->image = image;
  f->layer = gimp_layer_new (image, SIDE, SIDE, gimp_image_get_layer_format (image, TRUE),
                              "Linear float target", 1.0, GIMP_LAYER_MODE_NORMAL);
  if (!f->layer) return FALSE;
  if (!gimp_image_add_layer (image, f->layer, NULL, 0, FALSE)) {
    g_object_unref (f->layer); f->layer = NULL; return FALSE;
  }
  gfloat pixels[VALUES];
  for (guint i = 0; i < VALUES; i += 4) {
    pixels[i] = (i / 4 % 5) * 0.25f;
    pixels[i + 1] = 0.25f; pixels[i + 2] = 0.75f;
    pixels[i + 3] = 0.2f + (i / 4 % 4) * 0.2f;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->layer)), GEGL_RECTANGLE (0, 0, SIDE, SIDE),
                   0, babl_format ("RGBA float"), pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->layer), 0, 0, SIDE, SIDE);
  gimp_image_clean_all (image);
  return TRUE;
}

static void fixture_close (Fixture *f) {
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
  } else buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (f->layer));
  if (!buffer) return FALSE;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 1.0, babl_format ("RGBA float"),
                   pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  if (effects) g_object_unref (buffer);
  return TRUE;
}

static gboolean close_pixels (const gfloat *a, const gfloat *b) {
  for (guint i = 0; i < VALUES; i++) if (!isfinite (b[i]) || fabs (a[i] - b[i]) > 2e-5) return FALSE;
  return TRUE;
}

/* Independent arithmetic from the byte-identical native process body:
 * app/operations/gimpoperationbrightnesscontrast.c:86-140, all four refs.
 * Native source and readback are straight, LINEAR RGBA float; no u8 oracle. */
static gboolean formula_matches (const gfloat *source, const gfloat *actual, double brightness, double contrast) {
  double slope = tan ((contrast + 1.0) * G_PI / 4.0), b = brightness / 2.0;
  for (guint i = 0; i < VALUES; i++) {
    double x = source[i], expected;
    if (i % 4 == 3) expected = x;
    else { double z = b < 0 ? x * (1 + b) : x + (1 - x) * b; expected = (z - 0.5) * slope + 0.5; }
    if (!isfinite (actual[i]) || fabs (actual[i] - expected) > 2e-5) return FALSE;
  }
  return TRUE;
}

static gboolean history_equal (Fixture *f, const GlimsUndoInfo *before) {
  GlimsUndoInfo after = {0};
  return api->image_undo_info (f->engine, f->id, &after) == GLIMS_STATUS_OK && !memcmp (before, &after, sizeof after);
}

static GlimsStatus begin (Fixture *f, GlimsFilterID *filter, char **error) {
  return api->filter_begin (f->engine, f->id, layer_id (f), "gimp:brightness-contrast", filter, error);
}

static GlimsFilter *session (Fixture *f, GlimsFilterID id) {
  return g_hash_table_lookup (f->engine->filters, GINT_TO_POINTER (id));
}

static GObject *node_config (GeglNode *node) {
  GeglOperation *operation = gegl_node_get_gegl_operation (node); /* borrowed */
  return operation && GIMP_IS_OPERATION_POINT_FILTER (operation) ? GIMP_OPERATION_POINT_FILTER (operation)->config : NULL;
}

static gboolean config_pair_is (GObject *config, double b, double c) {
  if (!config) return FALSE;
  double actual_b, actual_c;
  g_object_get (config, "brightness", &actual_b, "contrast", &actual_c, NULL);
  return actual_b == b && actual_c == c;
}

static gboolean settings_are (Fixture *f, GlimsFilterID id, double b, double c) {
  GlimsBrightnessContrastSettings settings = pair (7, 9);
  return api->filter_brightness_contrast_get (f->engine, id, &settings, NULL) == GLIMS_STATUS_OK &&
         settings.brightness == b && settings.contrast == c;
}

static void notified (GObject *object, GParamSpec *spec, gpointer data) {
  (void) object; (void) spec; (*(guint *) data)++;
}

static GlimsStatus
formula_and_lifetime (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  gfloat raw[VALUES], actual[VALUES], current[VALUES]; GlimsUndoInfo history = {0};
  GWeakRef old_weak, last_weak; gboolean old_init = FALSE, last_init = FALSE;
  NEED (fixture_open (engine, &f) && read_pixels (&f, FALSE, raw), "real LINEAR FLOAT RGBA fixture opens with nonopaque alpha");
  NEED (api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK && begin (&f, &filter, &error) == GLIMS_STATUS_OK,
        "default BC preview begins without a native Undo");
  NEED (settings_are (&f, filter, 0, 0) && read_pixels (&f, TRUE, actual), "default paired settings and preview can be read");
  CHECK (formula_matches (raw, actual, 0, 0), "default 0/0 is an independent linear-RGBA identity");
  GlimsFilter *s = session (&f, filter);
  NEED (s && node_config (s->operation), "preview owns a real native point-filter configuration");
  g_weak_ref_init (&old_weak, node_config (s->operation)); old_init = TRUE;
  GlimsBrightnessContrastSettings first = pair (0.2, -0.1);
  NEED (api->filter_brightness_contrast_set (engine, filter, &first, &error) == GLIMS_STATUS_OK, "first immutable replacement succeeds before any Undo");
  GObject *held = g_weak_ref_get (&old_weak);
  CHECK (held == NULL, "replaced adapter-only default config finalizes before any native Undo/XCF");
  g_clear_object (&held);
  GlimsBrightnessContrastSettings endpoint = pair (-1, 1);
  NEED (api->filter_brightness_contrast_set (engine, filter, &endpoint, &error) == GLIMS_STATUS_OK &&
        settings_are (&f, filter, -1, 1), "both normalized endpoint bounds are accepted without clamping");
  const double cases[][2] = {{-1, 0}, {1, 0}, {0, -1}, {0, 0.5}, {0.35, -0.25}};
  for (guint i = 0; i < G_N_ELEMENTS (cases); i++) {
    GlimsBrightnessContrastSettings settings = pair (cases[i][0], cases[i][1]);
    NEED (api->filter_brightness_contrast_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
          settings_are (&f, filter, settings.brightness, settings.contrast) && read_pixels (&f, TRUE, actual),
          "complete normalized pair updates and reads back exactly");
    CHECK (formula_matches (raw, actual, settings.brightness, settings.contrast), "native preview matches independent B-then-C formula and unchanged nonopaque alpha");
  }
  guint notifications = 0; GObject *same = node_config (s->operation);
  gulong signal = g_signal_connect (gegl_node_get_gegl_operation (s->operation), "notify::config", G_CALLBACK (notified), &notifications);
  GlimsBrightnessContrastSettings settings = pair (0.35, -0.25);
  CHECK (api->filter_brightness_contrast_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
         node_config (s->operation) == same && notifications == 0, "same-pair Set neither replaces config nor emits config notify");
  g_signal_handler_disconnect (gegl_node_get_gegl_operation (s->operation), signal);
  const double bad[][2] = {{NAN, 0}, {0, NAN}, {INFINITY, 0}, {0, -INFINITY}, {-1.01, 0}, {0, 1.01}, {0.8, NAN}};
  NEED (read_pixels (&f, TRUE, actual), "invalid-pair baseline preview is captured");
  for (guint i = 0; i < G_N_ELEMENTS (bad); i++) {
    settings = pair (bad[i][0], bad[i][1]);
    CHECK (api->filter_brightness_contrast_set (engine, filter, &settings, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
           node_config (s->operation) == same && settings_are (&f, filter, 0.35, -0.25), "invalid full pair refuses atomically without replacing either component");
    clear_error (&error);
    CHECK (read_pixels (&f, TRUE, current) && !memcmp (actual, current, sizeof actual) && history_equal (&f, &history), "invalid pair preserves exact preview pixels/history");
  }
  g_weak_ref_init (&last_weak, same); last_init = TRUE;
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "numeric preview aborts"); filter = 0;
  held = g_weak_ref_get (&last_weak);
  CHECK (held == NULL, "aborted adapter-only config finalizes without native Undo/XCF"); g_clear_object (&held);
  CHECK (read_pixels (&f, FALSE, current) && !memcmp (raw, current, sizeof raw) && history_equal (&f, &history), "Abort leaves every stored float and history byte unchanged");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (old_init) g_weak_ref_clear (&old_weak);
  if (last_init) g_weak_ref_clear (&last_weak);
  clear_error (&error); fixture_close (&f); return GLIMS_STATUS_OK;
}

static gboolean effect_rows (Fixture *f, GlimsEffectInfo *rows, int32_t capacity, int32_t *count) {
  return api->drawable_effects (f->engine, f->id, layer_id (f), rows, capacity, count) == GLIMS_STATUS_OK;
}

static gboolean effect_pair_is (Fixture *f, GlimsEffectID id, double b, double c) {
  GimpDrawableFilter *effect = glims_lookup_effect (f->engine, GIMP_DRAWABLE (f->layer), id);
  return effect && config_pair_is (node_config (gimp_drawable_filter_get_operation (effect)), b, c);
}

static gboolean
xcf_roundtrip (Fixture *f, const char *filename, double b, double c)
{
  gboolean result = FALSE; gchar *path = g_build_filename (work_dir, filename, NULL); char *error = NULL;
  GlimsImageID opened = 0; GlimsFilterID edit = 0; gfloat before[VALUES], after[VALUES];
  if (!read_pixels (f, TRUE, before) || api->image_save (f->engine, f->id, path, &error) != GLIMS_STATUS_OK ||
      api->image_open (f->engine, path, &opened, &error) != GLIMS_STATUS_OK) goto cleanup;
  GlimsOpenImage *open = glims_lookup_image (f->engine, opened);
  GlimsLayerInfo layers[2] = {{0}}; int32_t count = 0; GlimsEffectInfo effects[4] = {{0}};
  if (!open || api->image_layers (f->engine, opened, layers, 2, &count) != GLIMS_STATUS_OK || count != 1) goto cleanup;
  Fixture reopened = { .engine = f->engine, .id = opened, .image = open->image,
                        .layer = GIMP_LAYER (glims_lookup_drawable (open, layers[0].id)) };
  if (!reopened.layer || !read_pixels (&reopened, TRUE, after) || !close_pixels (before, after) ||
      !effect_rows (&reopened, effects, 4, &count)) goto cleanup;
  GlimsEffectID selected = 0;
  for (int i = 0; i < count && i < 4; i++) if (!strcmp (effects[i].operation, "gimp:brightness-contrast")) selected = effects[i].id;
  if (!selected || api->filter_edit_begin (f->engine, opened, layers[0].id, selected, &edit, &error) != GLIMS_STATUS_OK) goto cleanup;
  result = settings_are (&reopened, edit, b, c);
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
  NEED (fixture_open (engine, &f) && read_pixels (&f, FALSE, raw) && api->image_undo_info (engine, f.id, &before) == GLIMS_STATUS_OK,
        "new-effect fixture captures raw pixels and actual history");
  GlimsBrightnessContrastSettings settings = pair (-0.5, 0.2);
  NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK && api->filter_brightness_contrast_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
        read_pixels (&f, TRUE, preview), "new effect preview accepts a nondefault pair");
  CHECK (formula_matches (raw, preview, -0.5, 0.2), "accepted new-effect preview has independently expected colors/alpha");
  NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "new effect Apply succeeds"); filter = 0;
  CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
         "new effect Apply adds exactly one Undo step");
  CHECK (read_pixels (&f, FALSE, actual) && !memcmp (raw, actual, sizeof raw), "ND Apply does not alter stored source floats");
  NEED (effect_rows (&f, rows, 2, &count) && count == 1 && effect_pair_is (&f, rows[0].id, -0.5, 0.2), "committed effect has the exact pair");
  CHECK (read_pixels (&f, TRUE, actual) && close_pixels (preview, actual), "Apply displays the accepted preview");
  NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "new effect undoes once");
  CHECK (effect_rows (&f, rows, 2, &count) && count == 0 && read_pixels (&f, TRUE, actual) && close_pixels (raw, actual), "one Undo removes the effect and restores original RGBA");
  NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "new effect redoes once");
  CHECK (effect_rows (&f, rows, 2, &count) && count == 1 && effect_pair_is (&f, rows[0].id, -0.5, 0.2) &&
         read_pixels (&f, TRUE, actual) && close_pixels (preview, actual), "Redo restores exact settings and accepted colors");
  CHECK (xcf_roundtrip (&f, "new-config.xcf", -0.5, 0.2), "XCF fresh reopen preserves actual paired config and float effect pixels");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f); return GLIMS_STATUS_OK;
}

typedef struct {
  double opacity, base_opacity;
  int index, active, mode, blend, composite_space, composite_mode, clip, region, base_clip, base_region, base_mode;
} EffectState;

static EffectState effect_state (Fixture *f, GimpDrawableFilter *effect) {
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
  state.base_opacity = base->opacity; state.base_clip = base->clip; state.base_region = base->region; state.base_mode = base->mode;
  return state;
}

static GlimsStatus
existing_effect (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  for (guint disabled = 0; disabled < 2; disabled++) {
    Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL; GObject *saved_a = NULL, *saved_b = NULL;
    GlimsEffectInfo rows[4] = {{0}}; int32_t count = 0; GlimsUndoInfo before = {0}, after = {0};
    gfloat original[VALUES], accepted[VALUES], actual[VALUES];
    NEED (fixture_open (engine, &f) && begin (&f, &filter, &error) == GLIMS_STATUS_OK, "existing-effect fixture begins with a unique unsnapshotted config");
    GlimsFilter *s = session (&f, filter);
    NEED (s && node_config (s->operation), "unique config exists before base-field fixture seeding");
    /* Seed the real base fields before any Undo/snapshot. Their registered
     * properties are gimp-{opacity,clip,region,mode}, not unprefixed names
     * (gimpoperationsettings.c:74-104). BC overrides only iface->equal;
     * duplicate -> default copy -> gimp_config_sync(flags=0) copies these
     * inherited read/write properties (gimpconfig-iface.c:202,275-279). */
    NEED (GIMP_IS_OPERATION_SETTINGS (node_config (s->operation)), "config has the actual native operation-settings base");
    GObject *seed = node_config (s->operation);
    GObjectClass *klass = G_OBJECT_GET_CLASS (seed);
    NEED (g_object_class_find_property (klass, "gimp-opacity") && g_object_class_find_property (klass, "gimp-clip") &&
          g_object_class_find_property (klass, "gimp-region") && g_object_class_find_property (klass, "gimp-mode"),
          "native inherited base properties are registered with their actual prefixed names");
    g_object_set (seed, "gimp-opacity", 0.625, "gimp-clip", GIMP_TRANSFORM_RESIZE_CLIP,
                  "gimp-region", GIMP_FILTER_REGION_DRAWABLE, "gimp-mode", GIMP_LAYER_MODE_MULTIPLY, NULL);
    GlimsBrightnessContrastSettings a = pair (0.1, -0.2), b = pair (-0.3, 0.25), c = pair (0.4, -0.35);
    NEED (api->filter_brightness_contrast_set (engine, filter, &a, &error) == GLIMS_STATUS_OK, "initial immutable A replacement succeeds");
    GimpOperationSettings *base = GIMP_OPERATION_SETTINGS (node_config (s->operation));
    NEED (base->opacity == 0.625 && base->clip == GIMP_TRANSFORM_RESIZE_CLIP &&
          base->region == GIMP_FILTER_REGION_DRAWABLE && base->mode == GIMP_LAYER_MODE_MULTIPLY,
          "first immutable duplicate preserves independently seeded native base fields");
    NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "initial immutable A config commits"); filter = 0;
    NEED (effect_rows (&f, rows, 4, &count) && count == 1, "one real committed BC effect is present");
    GlimsEffectID effect_id = rows[0].id;
    NEED (api->filter_begin (engine, f.id, layer_id (&f), "gegl:invert-linear", &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "second real effect gives BC a meaningful stack position"); filter = 0;
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
    NEED (api->filter_brightness_contrast_set (engine, filter, &b, &error) == GLIMS_STATUS_OK, "shadow changes A to B");
    saved_b = g_object_ref (node_config (session (&f, filter)->operation));
    NEED (api->filter_brightness_contrast_set (engine, filter, &c, &error) == GLIMS_STATUS_OK, "shadow changes B to C");
    CHECK (config_pair_is (saved_a, a.brightness, a.contrast) && config_pair_is (saved_b, b.brightness, b.contrast), "B and C replacements never mutate installed A or earlier B configs");
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "existing-effect Cancel drops only the shadow"); filter = 0;
    EffectState current = effect_state (&f, effect);
    CHECK (!memcmp (&state, &current, sizeof state) && effect_pair_is (&f, effect_id, a.brightness, a.contrast) && history_equal (&f, &before) &&
           read_pixels (&f, TRUE, actual) && close_pixels (original, actual), "Cancel preserves enabled/disabled state, stack position, blend/base fields, pixels and history");
    NEED (api->filter_edit_begin (engine, f.id, layer_id (&f), effect_id, &filter, &error) == GLIMS_STATUS_OK &&
          api->filter_brightness_contrast_set (engine, filter, &b, &error) == GLIMS_STATUS_OK &&
          api->filter_brightness_contrast_set (engine, filter, &c, &error) == GLIMS_STATUS_OK &&
          api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "existing shadow A to B to C Applies"); filter = 0;
    current = effect_state (&f, effect);
    CHECK (!memcmp (&state, &current, sizeof state) && effect_pair_is (&f, effect_id, c.brightness, c.contrast), "Apply retains original effect ID/order/enabled/blend/base settings and installs C");
    CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1, "existing-effect Apply adds exactly one additional Undo");
    NEED (read_pixels (&f, TRUE, accepted), "accepted C pixels can be captured");
    if (!disabled) CHECK (!close_pixels (original, accepted), "enabled existing-effect edit really changes visible pixels");
    NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "existing-effect Apply undoes once");
    current = effect_state (&f, effect);
    CHECK (!memcmp (&state, &current, sizeof state) && effect_pair_is (&f, effect_id, a.brightness, a.contrast) &&
           read_pixels (&f, TRUE, actual) && close_pixels (original, actual), "Undo restores exact A settings, original state and pixels");
    NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "existing-effect edit redoes once");
    current = effect_state (&f, effect);
    CHECK (!memcmp (&state, &current, sizeof state) && effect_pair_is (&f, effect_id, c.brightness, c.contrast) &&
           read_pixels (&f, TRUE, actual) && close_pixels (accepted, actual), "Redo restores C settings/state/pixels");
    CHECK (config_pair_is (saved_a, a.brightness, a.contrast) && config_pair_is (saved_b, b.brightness, b.contrast), "old configs remain immutable across native Undo/Redo");
    CHECK (xcf_roundtrip (&f, disabled ? "existing-disabled.xcf" : "existing-enabled.xcf", c.brightness, c.contrast), "existing config and rendered pixels survive fresh XCF reopen");
cleanup:
    if (filter) api->filter_abort (engine, filter);
    /* Native Undo/XCF setters can retain additional refs. These are only
     * our explicit witness refs; no post-history finalization assertion. */
    g_clear_object (&saved_a); g_clear_object (&saved_b); clear_error (&error); fixture_close (&f);
  }
  return GLIMS_STATUS_OK;
}

static gboolean block_history (Fixture *f, guint mode) {
  if (mode == 0) return gimp_image_undo_disable (f->image);
  if (mode == 1) return gimp_image_undo_freeze (f->image);
  return gimp_image_undo_group_start (f->image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "BC history guard");
}
static void unblock_history (Fixture *f, guint mode) {
  if (mode == 0) gimp_image_undo_enable (f->image);
  else if (mode == 1) gimp_image_undo_thaw (f->image);
  else gimp_image_undo_group_end (f->image);
}

static void refuses_begin (Fixture *f, GlimsStatus expected, const char *description) {
  GlimsFilterID filter = 123456; char *error = NULL; GlimsUndoInfo history = {0}; gfloat before[VALUES], after[VALUES];
  gboolean captured = read_pixels (f, FALSE, before) && api->image_undo_info (f->engine, f->id, &history) == GLIMS_STATUS_OK;
  CHECK (captured, "refusal captures real raw pixels/history before request"); if (!captured) return;
  guint sessions_before = g_hash_table_size (f->engine->filters);
  GlimsStatus status = begin (f, &filter, &error);
  CHECK (status == expected && filter == 0, description);
  CHECK (read_pixels (f, FALSE, after) && !memcmp (before, after, sizeof before) && history_equal (f, &history) &&
         g_hash_table_size (f->engine->filters) == sessions_before, "refused Begin has no raw pixel/history/session mutation");
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
    blocked = block_history (&f, mode); NEED (blocked, "history disables/freezes/opens an outer group before Begin");
    refuses_begin (&f, GLIMS_STATUS_BUSY, "disabled/frozen/grouped Undo refuses new BC Begin");
    unblock_history (&f, mode); blocked = FALSE;
    GlimsBrightnessContrastSettings settings = pair (0.2, -0.3);
    NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK && api->filter_brightness_contrast_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK,
          "valid preview opens before commit history becomes unavailable");
    blocked = block_history (&f, mode); NEED (blocked, "history changes while preview is open");
    NEED (read_pixels (&f, FALSE, raw) && api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK, "blocked-commit baseline is captured after the external history transition");
    CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_BUSY && session (&f, filter), "blocked commit returns BUSY and retains the same session"); clear_error (&error);
    CHECK (read_pixels (&f, FALSE, actual) && !memcmp (raw, actual, sizeof raw) && history_equal (&f, &history), "blocked commit leaves raw pixels/history unchanged");
    if (mode == 1) {
      unblock_history (&f, mode); blocked = FALSE;
      NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "thaw permits retry on the same preview"); filter = 0;
      CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK && after.undo_count == history.undo_count + 1, "thaw-and-retry commits one Undo");
    } else {
      NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "Abort remains allowed while Undo is unavailable"); filter = 0;
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
  GlimsBrightnessContrastSettings settings = pair (0.25, 0.1), output = pair (9, 8);
  CHECK (api->filter_brightness_contrast_get (engine, INT_MAX, &output, &error) == GLIMS_STATUS_NOT_FOUND && output.brightness == 0 && output.contrast == 0, "stale Get reports NOT_FOUND and resets valid sized fields"); clear_error (&error);
  CHECK (api->filter_brightness_contrast_set (engine, INT_MAX, &settings, &error) == GLIMS_STATUS_NOT_FOUND, "stale Set refuses"); clear_error (&error);
  CHECK (api->filter_brightness_contrast_get (engine, INT_MAX, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "NULL Get output refuses before lookup"); clear_error (&error);
  engine->busy++; refuses_begin (&f, GLIMS_STATUS_BUSY, "exclusive native work refuses Begin"); engine->busy--;
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), TRUE, FALSE);
  refuses_begin (&f, GLIMS_STATUS_LOCKED, "effective pixel lock refuses Begin");
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), FALSE, FALSE);
  NEED (begin (&f, &filter, &error) == GLIMS_STATUS_OK, "typed-write refusal preview opens");
  GlimsFilter *s = session (&f, filter); GObject *config = node_config (s->operation);
  gfloat raw[VALUES], after[VALUES]; GlimsUndoInfo history = {0};
  NEED (read_pixels (&f, FALSE, raw) && api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK, "typed refusals capture actual raw/history baseline");
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), TRUE, FALSE);
  CHECK (api->filter_brightness_contrast_set (engine, filter, &settings, &error) == GLIMS_STATUS_LOCKED && node_config (s->operation) == config, "locked Set preserves the installed config"); clear_error (&error);
  gimp_item_set_lock_content (GIMP_ITEM (f.layer), FALSE, FALSE);
  engine->busy++;
  GlimsStatus status = api->filter_brightness_contrast_set (engine, filter, &settings, &error);
  engine->busy--;
  CHECK (status == GLIMS_STATUS_BUSY && node_config (s->operation) == config, "busy Set preserves the installed config"); clear_error (&error);
  GlimsBrightnessContrastSettings small = pair (0.7, 0.6); small.struct_size = sizeof small - 1;
  CHECK (api->filter_brightness_contrast_set (engine, filter, &small, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->filter_brightness_contrast_set (engine, filter, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         settings_are (&f, filter, 0, 0), "undersized and NULL pairs refuse without changing either setting"); clear_error (&error);
  CHECK (read_pixels (&f, FALSE, after) && !memcmp (raw, after, sizeof raw) && history_equal (&f, &history), "typed write refusals preserve raw pixels/history");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "refusal preview aborts"); filter = 0;
  NEED (api->filter_begin (engine, f.id, layer_id (&f), "gegl:invert-linear", &filter, &error) == GLIMS_STATUS_OK, "wrong-operation preview starts independently");
  CHECK (api->filter_brightness_contrast_get (engine, filter, &output, &error) == GLIMS_STATUS_UNSUPPORTED &&
         api->filter_brightness_contrast_set (engine, filter, &settings, NULL) == GLIMS_STATUS_UNSUPPORTED, "typed get/set refuse a real non-BC operation"); clear_error (&error);
  refuses_begin (&f, GLIMS_STATUS_BUSY, "another active preview refuses BC Begin");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "wrong-operation preview aborts"); filter = 0;
  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PAINTBRUSH, .size = 3, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint point = {2, 2, 1, 0, 0, 0};
  NEED (api->stroke_begin (engine, f.id, layer_id (&f), &brush, &point, &stroke, &error) == GLIMS_STATUS_OK, "real stroke starts for admission regression");
  refuses_begin (&f, GLIMS_STATUS_BUSY, "active native stroke refuses BC Begin");
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
  if (!api || api->struct_size < sizeof *api || !api->filter_brightness_contrast_get || !api->filter_brightness_contrast_set) return 2;
  char *error = NULL; GlimsBrightnessContrastSettings output = pair (7, 8);
  CHECK (api->filter_brightness_contrast_get (NULL, 1, &output, &error) == GLIMS_STATUS_NOT_RUNNING && output.brightness == 0 && output.contrast == 0,
         "public slot148 resets valid sized output for a nonrunning engine"); clear_error (&error);
  gchar *user = g_build_filename (work_dir, "user", NULL), *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed"); clear_error (&error); g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, formula_and_lifetime, NULL) == GLIMS_STATUS_OK, "formula/lifetime fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, new_effect, NULL) == GLIMS_STATUS_OK, "new effect/Undo/XCF fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, existing_effect, NULL) == GLIMS_STATUS_OK, "immutable existing-effect fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, history_guards, NULL) == GLIMS_STATUS_OK, "history guard fixtures run on the engine worker");
  CHECK (glims_engine_call (engine, refusals, NULL) == GLIMS_STATUS_OK, "admission/refusal fixtures run on the engine worker");
  PublicFixture public = {0}; GlimsFilterID filter = 0;
  if (glims_engine_call (engine, public_setup, &public) == GLIMS_STATUS_OK) {
    CHECK (api->filter_begin (engine, public.f.id, public.target, "gimp:brightness-contrast", &filter, &error) == GLIMS_STATUS_OK && filter > 0, "public host-thread preview starts"); clear_error (&error);
    if (filter) {
      GlimsBrightnessContrastSettings settings = pair (0.375, -0.625); output = pair (3, 4);
      CHECK (api->filter_brightness_contrast_set (engine, filter, &settings, &error) == GLIMS_STATUS_OK &&
             api->filter_brightness_contrast_get (engine, filter, &output, NULL) == GLIMS_STATUS_OK &&
             output.brightness == 0.375 && output.contrast == -0.625, "public host-thread slots148/149 marshal the exact complete pair"); clear_error (&error);
      struct { GlimsBrightnessContrastSettings value; guint64 tail; } sized, before;
      memset (&sized, 0xA5, sizeof sized); sized.value.struct_size = sizeof sized.value - 1; before = sized;
      CHECK (api->filter_brightness_contrast_get (engine, filter, &sized.value, &error) == GLIMS_STATUS_INVALID_ARGUMENT && !memcmp (&sized, &before, sizeof sized), "undersized Get leaves all caller sentinel bytes untouched"); clear_error (&error);
      sized.value.struct_size = sizeof sized;
      CHECK (api->filter_brightness_contrast_get (engine, filter, &sized.value, &error) == GLIMS_STATUS_OK && sized.tail == before.tail,
             "valid extensible Get does not overwrite a future caller tail"); clear_error (&error);
      CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "public preview aborts");
    }
  } else CHECK (FALSE, "public fixture setup succeeds");
  glims_engine_call (engine, public_cleanup, &public);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}

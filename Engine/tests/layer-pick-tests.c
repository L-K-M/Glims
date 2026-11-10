/* Source-only slot167 acceptance fixture. The literal hits are independent
 * of the facade. Core refs: GIMP3.2.8 7addd2b77efb798bbdc4d2fb082e786a48478ced;
 * GIMP3.0.8 6ac8031c9555667e080fef0324fca9f28a02e5ab,
 * app/core/gimpimage-pick-item.c + gimplayer.c + gimpgrouplayer.c.
 * Old166 objects may link this new-header harness: no new helper symbol is
 * referenced, and unavailable tail memory is never read. Root executes it. */
#include "engine-private.h"

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-pick-item.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimplayermask.h"
#include "core/gimpobject.h"
#include "core/gimppickable.h"

int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static gboolean available;
static int checks, failures;
#define CHECK(c, ...) do { gboolean ok_ = (c); checks++; \
  printf ("%s ", ok_ ? "ok  " : "FAIL"); printf (__VA_ARGS__); printf ("\n"); \
  if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, ...) do { gboolean need_ = (c); CHECK (need_, __VA_ARGS__); \
  if (!need_) goto cleanup; } while (0)

/* The compile-only driver must explicitly select a reviewed engine/source
 * profile. A version alone never infers a threshold for future Core builds. */
#if !defined (GLIMS_PICK_EXPECTED_MAJOR) || !defined (GLIMS_PICK_EXPECTED_MINOR) || \
    !defined (GLIMS_PICK_EXPECTED_MICRO) || !defined (GLIMS_PICK_EXPECTED_LOW_THRESHOLD)
#error "Build this harness with a reviewed engine/source profile via test-layer-pick.py"
#endif
_Static_assert (GIMP_MAJOR_VERSION == GLIMS_PICK_EXPECTED_MAJOR &&
                GIMP_MINOR_VERSION == GLIMS_PICK_EXPECTED_MINOR &&
                GIMP_MICRO_VERSION == GLIMS_PICK_EXPECTED_MICRO,
                "producer headers differ from the explicit reviewed engine profile");
_Static_assert (GLIMS_PICK_EXPECTED_LOW_THRESHOLD == 0 ||
                GLIMS_PICK_EXPECTED_LOW_THRESHOLD == 1,
                "invalid explicit native pick threshold profile");

_Static_assert (offsetof (GlimsEngineAPI, image_pick_layer) ==
                offsetof (GlimsEngineAPI, image_restore_layer_sources) +
                sizeof (((GlimsEngineAPI *) 0)->image_restore_layer_sources),
                "slot167 must follow the unchanged166 prefix");

typedef struct {
  GlimsImageID image;
  GlimsItemID expected;
  gchar *before;
} PublicProbe;

static gint item_id (gpointer item) { return item ? gimp_item_get_id (GIMP_ITEM (item)) : 0; }

/* Capture actual native storage, without quantizing float-alpha boundaries. */
static gboolean
append_buffer (GString *state, GimpDrawable *drawable)
{
  GeglBuffer *buffer = gimp_drawable_get_buffer (drawable); /* Borrowed. */
  const GeglRectangle *extent;
  const Babl *format;
  guint8 *pixels;
  gsize length;
  if (!buffer) return FALSE;
  extent = gegl_buffer_get_extent (buffer);
  format = gegl_buffer_get_format (buffer);
  if (extent->width <= 0 || extent->height <= 0) return FALSE;
  length = (gsize) extent->width * extent->height * babl_format_get_bytes_per_pixel (format);
  pixels = g_malloc (length);
  gegl_buffer_get (buffer, extent, 1, format, pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  g_string_append_printf (state, "buffer:%s:%d:%d:%d:%d;", babl_get_name (format),
                          extent->x, extent->y, extent->width, extent->height);
  g_string_append_len (state, (const gchar *) pixels, length);
  g_free (pixels);
  return TRUE;
}

static gchar *
fingerprint (GlimsEngine *engine, GlimsImageID id)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsImageInfo info = {0};
  GlimsUndoInfo undo = {0};
  GlimsHistoryInfo history = {0};
  GlimsFloatingState floating = { .struct_size = sizeof floating };
  GlimsHistoryRow *rows = NULL;
  GList *layers = NULL, *channels = NULL, *it;
  GString *state = g_string_new (NULL);
  gchar *digest = NULL;
  guint8 composite[32 * 24 * 4];
  if (!open || api->image_info (engine, id, &info) != GLIMS_STATUS_OK ||
      api->image_undo_info (engine, id, &undo) != GLIMS_STATUS_OK ||
      api->image_history (engine, id, NULL, 0, &history) != GLIMS_STATUS_OK ||
      api->image_floating_selection (engine, id, &floating) != GLIMS_STATUS_OK || history.count < 0)
    goto done;
  rows = history.count ? g_new0 (GlimsHistoryRow, history.count) : NULL;
  if (history.count && api->image_history (engine, id, rows, history.count, &history) != GLIMS_STATUS_OK) goto done;
  g_string_append_printf (state, "image:%d:%d:%d:%d:%s;undo:%d:%d:%s:%s;",
    info.width, info.height, info.layer_count, info.dirty, info.precision,
    undo.undo_count, undo.redo_count, undo.next_undo, undo.next_redo);
  g_string_append_printf (state, "history:%" G_GUINT64_FORMAT ":%d:%d;float:%d:%d:%d:%u;",
    (guint64) history.revision, history.count, history.current_position,
    floating.active, floating.floating, floating.target, floating.target_kind);
  for (gint i = 0; i < history.count; i++)
    g_string_append_printf (state, "undo:%d:%s;", rows[i].position, rows[i].name);
  for (it = gimp_image_get_selected_layers (open->image); it; it = it->next)
    g_string_append_printf (state, "selected:%d;", item_id (it->data)); /* Borrowed nodes. */
  for (it = gimp_image_get_selected_channels (open->image); it; it = it->next)
    g_string_append_printf (state, "channel-target:%d;", item_id (it->data));
  if (!append_buffer (state, GIMP_DRAWABLE (gimp_image_get_mask (open->image)))) goto done;
  layers = gimp_image_get_layer_list (open->image);
  for (it = layers; it; it = it->next)
    {
      GimpLayer *layer = it->data;
      GimpItem *item = GIMP_ITEM (layer);
      GimpLayer *parent = gimp_layer_get_parent (layer);
      GlimsMaskState mask = {0};
      GimpLayerMask *native_mask = gimp_layer_get_mask (layer);
      gint x, y;
      gimp_item_get_offset (item, &x, &y);
      g_string_append_printf (state, "layer:%d:%s:%s:%d:%d:%d:%d:%d:%d:%.17g:%d:%d:%d:%d;",
        item_id (item), G_OBJECT_TYPE_NAME (layer), gimp_object_get_name (layer),
        item_id (parent), gimp_item_get_index (item), x, y,
        gimp_item_get_width (item), gimp_item_get_height (item), gimp_layer_get_opacity (layer),
        gimp_item_get_visible (item), gimp_item_get_lock_content (item),
        gimp_item_get_lock_position (item), gimp_layer_get_lock_alpha (layer));
      /* Group projections are derived caches; leaf bytes and full composite
       * cover their content without depending on cache-validation timing. */
      if (!GIMP_IS_GROUP_LAYER (layer) && !append_buffer (state, GIMP_DRAWABLE (layer))) goto done;
      if (api->layer_mask (engine, id, item_id (layer), &mask) != GLIMS_STATUS_OK) goto done;
      g_string_append_printf (state, "mask:%d:%d:%d:%d;", mask.mask, mask.enabled, mask.editing, mask.showing);
      if (native_mask && !append_buffer (state, GIMP_DRAWABLE (native_mask))) goto done;
    }
  channels = gimp_image_get_channel_list (open->image);
  for (it = channels; it; it = it->next)
    {
      g_string_append_printf (state, "channel:%d:%s;", item_id (it->data), gimp_object_get_name (it->data));
      if (!append_buffer (state, GIMP_DRAWABLE (it->data))) goto done;
    }
  if (api->image_render (engine, id, 1, (GlimsRect) {0, 0, 32, 24}, composite, 32 * 4) != GLIMS_STATUS_OK) goto done;
  g_string_append_len (state, (const gchar *) composite, sizeof composite);
  digest = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guchar *) state->str, state->len);
done:
  g_free (rows); g_list_free (layers); g_list_free (channels); g_string_free (state, TRUE);
  return digest;
}

static gboolean
same_state (GlimsEngine *engine, GlimsImageID id, const gchar *before)
{
  gchar *after = fingerprint (engine, id);
  gboolean equal = before && after && !strcmp (before, after);
  g_free (after); return equal;
}

static GimpLayer *
add_group (GimpImage *image)
{
  GimpLayer *group = gimp_group_layer_new (image);
  if (!group) return NULL;
  if (!gimp_image_add_layer (image, group, NULL, 0, FALSE))
    { g_object_unref (group); return NULL; }
  return group; /* Image-owned. */
}

static GimpLayer *
add_layer (GimpImage *image, const char *name, gint width, gint height,
            gint x, gint y, GimpLayer *parent, gint index, guint seed)
{
  GimpLayer *layer = gimp_layer_new (image, width, height, gimp_image_get_layer_format (image, TRUE),
                                    name, 1.0, GIMP_LAYER_MODE_NORMAL);
  gfloat *pixels;
  if (!layer) return NULL;
  gimp_item_set_offset (GIMP_ITEM (layer), x, y);
  if (!gimp_image_add_layer (image, layer, parent, index, FALSE)) { g_object_unref (layer); return NULL; }
  pixels = g_new (gfloat, (gsize) width * height * 4);
  for (gint i = 0; i < width * height; i++)
    {
      pixels[4 * i] = (gfloat) ((i * 7 + seed) % 101) / 100;
      pixels[4 * i + 1] = (gfloat) ((i * 13 + seed) % 97) / 100;
      pixels[4 * i + 2] = (gfloat) ((i * 19 + seed) % 89) / 100;
      pixels[4 * i + 3] = 1;
    }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)), GEGL_RECTANGLE (0, 0, width, height),
                   0, babl_format ("RGBA float"), pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, width, height);
  g_free (pixels); return layer; /* Image-owned. */
}

static void
alpha_pixel (GimpLayer *layer, gint x, gint y, gfloat alpha)
{
  gfloat pixel[4] = {0.2f, 0.4f, 0.7f, alpha};
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)), GEGL_RECTANGLE (x, y, 1, 1),
                   0, babl_format ("RGBA float"), pixel, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (layer), x, y, 1, 1);
}

static void
sample (GlimsEngine *engine, GlimsImageID id, GlimsPoint point, gint ix, gint iy,
         GlimsItemID literal, const char *label)
{
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *reference = gimp_image_pick_layer (image, ix, iy, NULL);
  gchar *before;
  GlimsItemID hit = -777;
  GlimsStatus status;
  CHECK (item_id (reference) == literal, "literal Core pick: %s", label);
  if (!available) return; /* Explicit baseline admission failure in main. */
  before = fingerprint (engine, id);
  CHECK (before != NULL, "capture full native state: %s", label);
  status = api->image_pick_layer (engine, id, point, &hit);
  CHECK (status == GLIMS_STATUS_OK && hit == literal && hit == item_id (reference), "facade matches literal/Core: %s", label);
  CHECK (same_state (engine, id, before), "pick preserves complete native state: %s", label);
  g_free (before);
}

static void
refusal (GlimsEngine *engine, GlimsImageID current, GlimsImageID requested,
          GlimsPoint point, GlimsStatus expected, const char *label)
{
  gchar *before = fingerprint (engine, current);
  GlimsItemID hit = -999;
  GlimsStatus status = api->image_pick_layer (engine, requested, point, &hit);
  CHECK (status == expected && hit == 0, "refusal resets out: %s", label);
  CHECK (same_state (engine, current, before), "refusal preserves native state: %s", label);
  g_free (before);
}

static GlimsStatus
exercise (GlimsEngine *engine, gpointer data)
{
  PublicProbe *probe = data;
  GlimsImageID id = 0, stale = 0;
  GlimsItemID mask_id = 0, floating_id = 0;
  GlimsStatus status = GLIMS_STATUS_FAILED;
  GimpImage *image;
  GimpLayer *background, *group, *empty, *bottom, *child, *top;
  GList *list, *selected;
  char *error = NULL;
  gfloat mask_pixels[25];
  gdouble expected_masked_quarter = 0;
  guint8 float_pixels[16] = {220,20,40,255, 10,190,70,255, 90,50,210,0, 60,140,30,255};
  NEED (api->image_new (engine, 32, 24, &id, &error) == GLIMS_STATUS_OK, "create owned pick image");
  NEED (api->image_convert_precision (engine, id, GLIMS_COLOR_COMPONENT_FLOAT, GLIMS_COLOR_TRC_LINEAR, &error) == GLIMS_STATUS_OK,
        "float precision makes exact quarter-alpha representable");
  image = glims_lookup_image (engine, id)->image;
  list = gimp_image_get_layer_list (image); background = list ? list->data : NULL; g_list_free (list);
  NEED (background != NULL, "new image has its known opaque background");
  gimp_item_set_visible (GIMP_ITEM (background), FALSE, FALSE);
  group = add_group (image); empty = add_group (image);
  NEED (group && empty, "attach real populated/empty group containers");
  bottom = add_layer (image, "Offset bottom", 8, 8, 1, 1, NULL, 2, 17);
  child = add_layer (image, "Visible group child", 6, 6, 4, 3, group, 0, 47);
  top = add_layer (image, "Top alpha texture", 5, 5, 5, 4, NULL, 0, 83);
  NEED (bottom && child && top, "attach three asymmetric float RGBA layers with different offsets");
  list = gimp_image_get_layer_list (image);
  CHECK (g_list_find (list, group) && g_list_find (list, child), "Core pick traversal includes both group and content child");
  g_list_free (list);
  alpha_pixel (top, 1, 1, 0);
  alpha_pixel (top, 2, 1, 0.25f);
  alpha_pixel (top, 3, 1, nextafterf (0.25f, 1.0f));
  alpha_pixel (top, 4, 1, nextafterf (0.25f, 0.0f));
  /* Float values strictly on opposite sides of master's reviewed0.001.
   * Do not assert exact equality between a stored float and double0.001. */
  alpha_pixel (top, 1, 2, 0.0005f);
  alpha_pixel (top, 2, 2, 0.002f);
  /* Literal unmasked controls share this fresh fixture with the later mask
   * cases; they do not claim fresh-process isolation or a cache root cause. */
  {
    gfloat raw_quarter[4] = {0};
    gegl_buffer_get (gimp_drawable_get_buffer (GIMP_DRAWABLE (top)), GEGL_RECTANGLE (2, 1, 1, 1),
                     1, babl_format ("RGBA float"), raw_quarter, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    CHECK (gimp_layer_get_mask (top) == NULL && raw_quarter[3] == 0.25f,
           "unmasked native float storage contains the literal exact quarter alpha");
  }
  sample (engine, id, (GlimsPoint) {7, 5}, 7, 5,
          GLIMS_PICK_EXPECTED_LOW_THRESHOLD ? item_id (top) : item_id (child),
          "unmasked exact quarter follows the explicitly reviewed native threshold");
  sample (engine, id, (GlimsPoint) {8, 5}, 8, 5, item_id (top),
          "unmasked next float above quarter passes both reviewed thresholds");
  sample (engine, id, (GlimsPoint) {9, 5}, 9, 5,
          GLIMS_PICK_EXPECTED_LOW_THRESHOLD ? item_id (top) : item_id (child),
          "unmasked next float below quarter follows the explicitly reviewed native threshold");
  NEED (api->layer_mask_add (engine, id, item_id (top), GLIMS_MASK_WHITE, FALSE, &mask_id, &error) == GLIMS_STATUS_OK,
        "attach top's real applied mask");
  for (gint i = 0; i < 25; i++) mask_pixels[i] = 1;
  mask_pixels[0] = 0;
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (gimp_layer_get_mask (top))), GEGL_RECTANGLE (0, 0, 5, 5),
                   0, babl_format ("Y float"), mask_pixels, GEGL_AUTO_ROWSTRIDE);
  /* Finish the direct mask seed's native notification before observing it.
   * This setup order is not a diagnosis of the earlier one-run outlier. */
  gimp_drawable_update (GIMP_DRAWABLE (gimp_layer_get_mask (top)), 0, 0, 5, 5);
  gimp_image_flush (image);
  {
    /* Preserve the first layer sample before measuring the mask separately.
     * Core converts the mask to Y double, then multiplies it by the alpha;
     * a converted white mask is not guaranteed to be bit-exact 1.0. */
    gdouble first_quarter = gimp_pickable_get_opacity_at (GIMP_PICKABLE (top), 2, 1);
    gdouble converted_mask = gimp_pickable_get_opacity_at (GIMP_PICKABLE (gimp_layer_get_mask (top)), 2, 1);
    expected_masked_quarter = 0.25 * converted_mask;
    CHECK (isfinite (converted_mask) && converted_mask > 0 && first_quarter == expected_masked_quarter,
           "masked quarter equals literal alpha times the independently converted native mask");
  }
  CHECK (gimp_pickable_get_opacity_at (GIMP_PICKABLE (top), 3, 1) > 0.25, "next float above quarter is stored above quarter");
  CHECK (gimp_pickable_get_opacity_at (GIMP_PICKABLE (top), 4, 1) < 0.25, "next float below quarter is stored below quarter");
  CHECK (gimp_pickable_get_opacity_at (GIMP_PICKABLE (top), 1, 2) < 0.001,
         "independent lower float is strictly below reviewed master threshold");
  CHECK (gimp_pickable_get_opacity_at (GIMP_PICKABLE (top), 2, 2) > 0.001,
         "independent upper float is strictly above reviewed master threshold");
  selected = g_list_prepend (NULL, bottom); gimp_image_set_selected_layers (image, selected); g_list_free (selected);
  gimp_image_flush (image); gimp_image_clean_all (image);
  {
    struct { gint x, y; GlimsItemID expected; const char *label; } cases[] = {
      {5, 6, item_id (top), "top opaque pixel"}, {6, 5, item_id (child), "transparent top hole selects child, not group"},
      {7, 5, expected_masked_quarter > (GLIMS_PICK_EXPECTED_LOW_THRESHOLD ? 0.001 : 0.25)
             ? item_id (top) : item_id (child),
       "masked quarter product follows the explicitly reviewed native threshold"},
      {8, 5, item_id (top), "next float above quarter passes both reviewed thresholds"},
      {9, 5, GLIMS_PICK_EXPECTED_LOW_THRESHOLD ? item_id (top) : item_id (child),
       "next float below quarter follows the explicitly reviewed native threshold"},
      {6, 6, item_id (child), "float below0.001 falls through on all reviewed engines"},
      {7, 6, GLIMS_PICK_EXPECTED_LOW_THRESHOLD ? item_id (top) : item_id (child),
       "float above0.001 but below quarter distinguishes reviewed native profiles"},
      {5, 4, item_id (child), "applied zero mask falls through"},
      {15, 15, 0, "no hit outside content with background hidden"}, {0, 0, 0, "empty group's bounds are not content"}
    };
    for (guint i = 0; i < G_N_ELEMENTS (cases); i++)
      sample (engine, id, (GlimsPoint) {cases[i].x, cases[i].y}, cases[i].x, cases[i].y, cases[i].expected, cases[i].label);
  }
  gimp_layer_set_apply_mask (top, FALSE, FALSE);
  sample (engine, id, (GlimsPoint) {5, 4}, 5, 4, item_id (top), "unapplied mask stops hiding the top pixel");
  gimp_layer_set_apply_mask (top, TRUE, FALSE);
  gimp_item_set_visible (GIMP_ITEM (top), FALSE, FALSE);
  sample (engine, id, (GlimsPoint) {8, 5}, 8, 5, item_id (child), "hidden top layer falls through");
  gimp_item_set_visible (GIMP_ITEM (top), TRUE, FALSE);
  gimp_item_set_visible (GIMP_ITEM (group), FALSE, FALSE);
  sample (engine, id, (GlimsPoint) {6, 5}, 6, 5, item_id (bottom), "hidden parent hides its child");
  gimp_item_set_visible (GIMP_ITEM (group), TRUE, FALSE);
  sample (engine, id, (GlimsPoint) {6, 5}, 6, 5, item_id (child), "visible group selects its content child");
  gimp_layer_set_opacity (top, 0, FALSE);
  sample (engine, id, (GlimsPoint) {5, 6}, 5, 6, item_id (top), "Core samples alpha, not layer opacity scalar");
  gimp_layer_set_opacity (top, 1, FALSE);
  gimp_layer_set_apply_mask (top, FALSE, FALSE); gimp_item_set_offset (GIMP_ITEM (top), -1, -1);
  sample (engine, id, (GlimsPoint) {-0.75, -1.75}, 0, -1, item_id (top), "negative fractions truncate toward zero, not floor");
  sample (engine, id, (GlimsPoint) {-1000.75, -1000.75}, -1000, -1000, 0, "ordinary finite off-canvas coordinates remain legal");
  gimp_item_set_offset (GIMP_ITEM (top), 5, 4); gimp_layer_set_apply_mask (top, TRUE, FALSE);
  sample (engine, id, (GlimsPoint) {5.9, 6.9}, 5, 6, item_id (top), "positive fractions use native integer samples");

  {
    GlimsSelectOptions selection = { .struct_size = sizeof selection, .operation = GLIMS_SELECT_REPLACE };
    GlimsRect bounds = {0};
    bool empty_selection = true;
    /* Paste Into centers on selection intersected with its target, rather
     * than treating payload bounds.x/y as an absolute placement request. */
    NEED (api->select_shape (engine, id, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) {{2, 2}, {4, 4}}, 2, &selection) == GLIMS_STATUS_OK,
          "create the literal 2x2 selection required by Paste Into");
    NEED (api->selection_bounds (engine, id, &empty_selection, &bounds) == GLIMS_STATUS_OK &&
          !empty_selection && bounds.x == 2 && bounds.y == 2 && bounds.width == 2 && bounds.height == 2,
          "selection/target intersection centers the float at the literal (2,2)");
  }
  NEED (api->image_paste_into (engine, id, item_id (bottom), (GlimsRect) {2, 2, 2, 2}, float_pixels, sizeof float_pixels,
                              &floating_id, &error) == GLIMS_STATUS_OK && floating_id > 0, "attach live float for read-only picking");
  {
    GlimsFloatingState state = { .struct_size = sizeof state };
    GimpLayer *floating = gimp_image_get_floating_selection (image);
    gint x = G_MAXINT, y = G_MAXINT;
    if (floating) gimp_item_get_offset (GIMP_ITEM (floating), &x, &y);
    CHECK (api->image_floating_selection (engine, id, &state) == GLIMS_STATUS_OK && state.active &&
           state.floating == floating_id && state.target == item_id (bottom) && x == 2 && y == 2,
           "float has the literal captured image/attachment identity and (2,2) placement");
  }
  sample (engine, id, (GlimsPoint) {2, 2}, 2, 2, floating_id, "live float opaque pixel is a hit");
  sample (engine, id, (GlimsPoint) {2, 3}, 2, 3, item_id (bottom), "live float transparent hole falls through without anchoring");
  sample (engine, id, (GlimsPoint) {8, 5}, 8, 5, item_id (top), "other layer hit never resolves or retargets the float");

  if (available)
    {
      GlimsPoint invalid[] = {{NAN, 1}, {1, NAN}, {INFINITY, 1}, {1, -INFINITY},
        {DBL_MAX, 1}, {1, -DBL_MAX}, {(gdouble) G_MAXINT + 1, 1}, {1, (gdouble) G_MININT - 1}};
      gchar *before;
      GlimsItemID hit;
      for (guint i = 0; i < G_N_ELEMENTS (invalid); i++)
        refusal (engine, id, id, invalid[i], GLIMS_STATUS_INVALID_ARGUMENT, "nonfinite or out-of-integer coordinate");
      refusal (engine, id, G_MAXINT, (GlimsPoint) {2, 2}, GLIMS_STATUS_NOT_FOUND, "unknown image cannot fall back to current");
      NEED (api->image_new (engine, 2, 2, &stale, &error) == GLIMS_STATUS_OK, "create image whose id will become stale");
      NEED (api->image_close (engine, stale) == GLIMS_STATUS_OK, "close the stale-image fixture");
      refusal (engine, id, stale, (GlimsPoint) {2, 2}, GLIMS_STATUS_NOT_FOUND, "closed image id");
      stale = 0;
      before = fingerprint (engine, id);
      CHECK (api->image_pick_layer (engine, id, (GlimsPoint) {2, 2}, NULL) == GLIMS_STATUS_INVALID_ARGUMENT, "NULL output is invalid");
      CHECK (same_state (engine, id, before), "NULL output changes no native state");
      g_free (before);
      before = fingerprint (engine, id); hit = -999;
      engine->busy++;
      status = api->image_pick_layer (engine, id, (GlimsPoint) {2, 2}, &hit);
      engine->busy--;
      CHECK (status == GLIMS_STATUS_BUSY && hit == 0, "busy refusal zeroes output before Core sampling");
      CHECK (same_state (engine, id, before), "busy refusal changes no native state");
      g_free (before);
      refusal (engine, id, id, (GlimsPoint) {G_MININT, 2}, GLIMS_STATUS_INVALID_ARGUMENT, "x minus positive native layer offset would overflow");
      refusal (engine, id, id, (GlimsPoint) {2, G_MININT}, GLIMS_STATUS_INVALID_ARGUMENT, "y minus positive native layer offset would overflow");
      gimp_item_set_offset (GIMP_ITEM (top), -1, -1);
      refusal (engine, id, id, (GlimsPoint) {G_MAXINT, 2}, GLIMS_STATUS_INVALID_ARGUMENT, "x minus negative native layer offset would overflow");
      gimp_item_set_offset (GIMP_ITEM (top), 5, 4);
      CHECK (engine->busy == 0, "all read/refusal paths balance the busy fence");
    }
  else printf ("NOTE slot167 unavailable: facade/refusal/caller cases NOT RUN; literal Core cases above are not facade PASS evidence\n");
  probe->before = fingerprint (engine, id);
  NEED (probe->before != NULL, "capture public-caller state before leaving engine worker");
  probe->image = id; probe->expected = floating_id; id = 0;
  status = GLIMS_STATUS_OK;
cleanup:
  if (error) { fprintf (stderr, "pick fixture: %s\n", error); api->free_string (error); }
  if (stale) api->image_close (engine, stale);
  if (id) api->image_close (engine, id);
  return status;
}

static GlimsStatus
finish (GlimsEngine *engine, gpointer data)
{
  PublicProbe *probe = data;
  GlimsStatus status = GLIMS_STATUS_OK;
  if (probe->image)
    {
      if (available) CHECK (same_state (engine, probe->image, probe->before), "external caller queries preserve full native image state");
      status = api->image_close (engine, probe->image);
      CHECK (status == GLIMS_STATUS_OK, "close the owned native image with live float/mask/group references");
      probe->image = 0;
    }
  g_clear_pointer (&probe->before, g_free);
  return status;
}

int
main (int argc, char **argv)
{
  GlimsEngine *engine = NULL;
  PublicProbe probe = {0};
  GlimsEngineConfig config = { .struct_size = sizeof config };
  gchar *user, *cache;
  char *error = NULL;
  GlimsStatus status;
  if (argc != 2) return 2;
  printf ("NOTE explicit reviewed native pick profile %d.%d.%d threshold %s\n",
          GLIMS_PICK_EXPECTED_MAJOR, GLIMS_PICK_EXPECTED_MINOR, GLIMS_PICK_EXPECTED_MICRO,
          GLIMS_PICK_EXPECTED_LOW_THRESHOLD ? "0.001" : "0.25");
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  CHECK (api && api->struct_size >= offsetof (GlimsEngineAPI, image_restore_layer_sources) +
         sizeof api->image_restore_layer_sources, "producer exposes the required immutable166 prefix");
  if (failures) return 2;
  /* The short circuit must happen BEFORE reading the appended pointer. */
  available = api->struct_size >= offsetof (GlimsEngineAPI, image_pick_layer) + sizeof api->image_pick_layer &&
              api->image_pick_layer != NULL;
  CHECK (available, "slot167 image_pick_layer is present (166 baseline admission RED)");
  user = g_build_filename (argv[1], "user", NULL); cache = g_build_filename (argv[1], "cache", NULL);
  config.user_directory = user; config.cache_directory = cache;
  status = api->start (&config, &engine, &error);
  CHECK (status == GLIMS_STATUS_OK && engine, "start isolated native engine");
  if (status == GLIMS_STATUS_OK && engine)
    {
      CHECK (glims_engine_call (engine, exercise, &probe) == GLIMS_STATUS_OK, "focused fixtures run on the engine thread");
      if (available && probe.image)
        {
          GlimsItemID hit = -999;
          CHECK (api->image_pick_layer (engine, probe.image, (GlimsPoint) {2, 2}, &hit) == GLIMS_STATUS_OK && hit == probe.expected,
                 "external caller marshals a pick onto the engine thread");
          hit = -999;
          CHECK (api->image_pick_layer (NULL, probe.image, (GlimsPoint) {2, 2}, &hit) == GLIMS_STATUS_NOT_RUNNING && hit == 0,
                 "NULL engine dispatch refuses and zeroes output");
        }
      CHECK (glims_engine_call (engine, finish, &probe) == GLIMS_STATUS_OK, "counted source fixture cleanup finishes on engine thread");
      api->stop (engine);
    }
  if (error) { fprintf (stderr, "%s\n", error); api->free_string (error); }
  g_free (user); g_free (cache);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures ? 1 : 0;
}

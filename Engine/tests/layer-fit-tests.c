/* Core fixtures run on the engine worker. Public slot156 tests below call
 * the blocking facade from the host thread. No selected-list ownership. */
#include "engine-private.h"
#include "layer-fit.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimplayermask.h"
#include "text/gimptext.h"
#include "text/gimptextlayer.h"
#include <limits.h>
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static int failures, checks;
#define CHECK(c, text) do { gboolean ok_ = (c); checks++; \
  printf ("%s %s\n", ok_ ? "ok  " : "FAIL", text); \
  if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, text) do { gboolean needed_ = (c); CHECK (needed_, text); \
  if (!needed_) goto cleanup; } while (0)

typedef struct { gint x, y, width, height, channels; guint8 *bytes; } Raw;
static GlimsItemID item_id (gpointer item) { return gimp_item_get_id (GIMP_ITEM (item)); }
static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }
static void raw_clear (Raw *raw) { g_clear_pointer (&raw->bytes, g_free); }

static Raw
read_raw (GimpDrawable *drawable, gboolean mask)
{
  GimpItem *item = GIMP_ITEM (drawable);
  Raw raw = { .width = gimp_item_get_width (item), .height = gimp_item_get_height (item),
              .channels = mask ? 1 : 4 };
  gimp_item_get_offset (item, &raw.x, &raw.y);
  raw.bytes = g_malloc0 ((gsize) raw.width * raw.height * raw.channels);
  /* A 2x1 validating read avoids GEGL's stale single-pixel shortcut while
   * comparing precisely the same one logical pixel for 1x1 drawables. */
  if (raw.width == 1 && raw.height == 1) {
    guint8 pair[8] = {0};
    gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, 2, 1),
                     1, babl_format (mask ? "Y u8" : "R'G'B'A u8"), pair,
                     GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    memcpy (raw.bytes, pair, raw.channels);
  } else {
    gegl_buffer_get (gimp_drawable_get_buffer (drawable),
                     GEGL_RECTANGLE (0, 0, raw.width, raw.height), 1,
                     babl_format (mask ? "Y u8" : "R'G'B'A u8"), raw.bytes,
                     GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  }
  return raw;
}

static void
append_raw (GString *state, GimpDrawable *drawable, gboolean mask)
{
  Raw raw = read_raw (drawable, mask);
  g_string_append_printf (state, "raw:%d,%d,%d,%d,%d;", raw.x, raw.y,
                          raw.width, raw.height, raw.channels);
  g_string_append_len (state, (const gchar *) raw.bytes,
                       (gssize) raw.width * raw.height * raw.channels);
  raw_clear (&raw);
}

/* All leaf pixels (including untouched nested leaves), masks, topology,
 * properties and ordered native selection. History mode also covers the
 * native clean mark and the complete zero-initialized undo-info struct. */
static gchar *
fingerprint (GlimsEngine *engine, GlimsImageID id, gboolean history)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsUndoInfo undo = {0};
  if (!open || api->image_undo_info (engine, id, &undo) != GLIMS_STATUS_OK) return NULL;
  GString *state = g_string_new (NULL);
  g_string_append_printf (state, "image:%d,%d;", gimp_image_get_width (open->image),
                          gimp_image_get_height (open->image));
  if (history) {
    g_string_append_printf (state, "dirty:%d;", gimp_image_is_dirty (open->image));
    g_string_append_len (state, (const gchar *) &undo, sizeof undo);
  }
  GList *rows = gimp_image_get_layer_list (open->image); /* Owned nodes. */
  for (GList *it = rows; it; it = it->next) {
    GimpLayer *layer = it->data, *parent = gimp_layer_get_parent (layer);
    GimpItem *item = GIMP_ITEM (layer);
    const gchar *name = gimp_object_get_name (layer);
    gint x, y; gimp_item_get_offset (item, &x, &y);
    g_string_append_printf (state, "layer:%d,%d,%d,%s:%zu:%s:%d,%d,%d,%d,%.17g,%d,%d,%d,%d;",
      item_id (layer), parent ? item_id (parent) : 0, gimp_item_get_index (item),
      G_OBJECT_TYPE_NAME (item), strlen (name), name, x, y,
      gimp_item_get_width (item), gimp_item_get_height (item), gimp_layer_get_opacity (layer),
      gimp_item_get_visible (item), gimp_item_get_lock_content (item),
      gimp_item_get_lock_position (item), gimp_layer_get_lock_alpha (layer));
    /* Group projections are derived caches; every real child is separately
     * compared. Their parent/index/bounds above are still authoritative. */
    if (!GIMP_IS_GROUP_LAYER (layer)) append_raw (state, GIMP_DRAWABLE (layer), FALSE);
    GimpLayerMask *mask = gimp_layer_get_mask (layer);
    GlimsMaskState mask_state = {0};
    if (api->layer_mask (engine, id, item_id (layer), &mask_state) != GLIMS_STATUS_OK) {
      g_list_free (rows); g_string_free (state, TRUE); return NULL;
    }
    g_string_append_len (state, (const gchar *) &mask_state, sizeof mask_state);
    if (mask) append_raw (state, GIMP_DRAWABLE (mask), TRUE);
    GlimsLayerSourceInfo source = { .struct_size = sizeof source };
    if (api->layer_source_info (engine, id, item_id (layer), &source, NULL) != GLIMS_STATUS_OK) {
      g_list_free (rows); g_string_free (state, TRUE); return NULL;
    }
    g_string_append_printf (state, "source:%u,%d,%d;", source.source_kind,
                            source.is_rasterized, source.has_source);
  }
  g_list_free (rows);
  for (GList *it = gimp_image_get_selected_layers (open->image); it; it = it->next)
    g_string_append_printf (state, "selected:%d;", item_id (it->data)); /* Borrowed. */
  append_raw (state, GIMP_DRAWABLE (gimp_image_get_mask (open->image)), TRUE);
  gchar *hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256,
                          (const guchar *) state->str, state->len);
  g_string_free (state, TRUE);
  return hash;
}

static GimpLayer *
add_layer (GimpImage *image, GimpLayer *parent, const gchar *name,
           gint width, gint height, gint x, gint y, guint seed)
{
  GimpLayer *layer = gimp_layer_new (image, width, height,
                       gimp_image_get_layer_format (image, TRUE), name, 1.0, GIMP_LAYER_MODE_NORMAL);
  if (!layer) return NULL;
  gimp_item_set_offset (GIMP_ITEM (layer), x, y);
  if (!gimp_image_add_layer (image, layer, parent, 0, FALSE)) {
    g_object_unref (layer); return NULL;
  }
  guint8 *pixels = g_malloc ((gsize) width * height * 4);
  for (gint iy = 0; iy < height; iy++) for (gint ix = 0; ix < width; ix++) {
    guint8 *p = pixels + ((gsize) iy * width + ix) * 4;
    p[0] = 20 + (ix * 17 + seed) % 220; p[1] = 10 + (iy * 29 + seed) % 230;
    p[2] = 30 + (ix * 3 + iy * 5 + seed) % 210; p[3] = 255;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)),
                   GEGL_RECTANGLE (0, 0, width, height), 0, babl_format ("R'G'B'A u8"),
                   pixels, GEGL_AUTO_ROWSTRIDE);
  g_free (pixels); gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, width, height);
  return layer; /* Image owns it. */
}

static gboolean
selection_is (GimpImage *image, GimpLayer **layers, guint count)
{
  GList *selected = gimp_image_get_selected_layers (image); /* BORROWED */
  for (guint i = 0; i < count; i++, selected = selected->next)
    if (!selected || selected->data != layers[i]) return FALSE;
  return selected == NULL;
}

static gboolean
select_exact (GimpImage *image, GimpLayer **layers, guint count)
{
  GList *list = NULL;
  for (guint i = 0; i < count; i++) list = g_list_append (list, layers[i]);
  gimp_image_set_selected_layers (image, list); g_list_free (list);
  return selection_is (image, layers, count);
}

static gboolean
fitted_pixels (GimpDrawable *drawable, const Raw *before, gboolean mask,
               gint width, gint height)
{
  Raw after = read_raw (drawable, mask);
  gboolean same = after.x == 0 && after.y == 0 && after.width == width && after.height == height;
  for (gint y = 0; same && y < height; y++) for (gint x = 0; same && x < width; x++) {
    gint sx = x - before->x, sy = y - before->y;
    const guint8 zero[4] = {0};
    const guint8 *expected = zero;
    if (sx >= 0 && sy >= 0 && sx < before->width && sy < before->height)
      expected = before->bytes + ((gsize) sy * before->width + sx) * before->channels;
    same = !memcmp (after.bytes + ((gsize) y * width + x) * after.channels,
                     expected, after.channels);
  }
  raw_clear (&after); return same;
}

static void
refuses (GlimsEngine *engine, GlimsImageID image, const GlimsItemID *ids,
         size_t count, GlimsStatus expected, const gchar *label)
{
  char *error = NULL; gchar *before = fingerprint (engine, image, TRUE);
  GlimsStatus status = glims_image_fit_layers_to_image (engine, image, ids, count, &error);
  gchar *after = fingerprint (engine, image, TRUE);
  if (status != expected) fprintf (stderr, "status %d expected %d: %s\n", status, expected, error ? error : "");
  CHECK (status == expected, label);
  CHECK (before && after && !strcmp (before, after), "refusal preserves all native bounds/pixels/masks/tree/selection/dirty/history");
  clear_error (&error); g_free (before); g_free (after);
}

static GlimsStatus
geometry_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; GlimsItemID mask_id = 0; char *error = NULL;
  gchar *original = NULL, *fitted = NULL, *state = NULL;
  Raw a_raw = {0}, b_raw = {0}, mask_raw = {0};
  guint8 before_composite[32 * 24 * 4], after_composite[32 * 24 * 4];
  NEED (api->image_new (engine, 32, 24, &id, &error) == GLIMS_STATUS_OK, "geometry image starts");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *a = add_layer (image, NULL, "Outside left", 13, 11, -4, 5, 1);
  GimpLayer *b = add_layer (image, NULL, "Inside offset", 9, 7, 17, 2, 73);
  GimpLayer *group = gimp_group_layer_new (image);
  NEED (a && b && group && gimp_image_add_layer (image, group, NULL, 0, FALSE), "offset targets and actual group attach");
  GimpLayer *third = add_layer (image, group, "Untouched nested leaf", 6, 5, 22, 16, 41);
  NEED (third != NULL, "untouched leaf has a real parent and independent patterned pixels");
  NEED (api->layer_mask_add (engine, id, item_id (a), GLIMS_MASK_WHITE, FALSE, &mask_id, &error) == GLIMS_STATUS_OK,
        "nonuniform-mask fixture attaches a native mask");
  GimpLayerMask *mask = gimp_layer_get_mask (a);
  NEED (mask && item_id (mask) == mask_id, "mask is the exact layer-owned native object");
  guint8 values[13 * 11];
  for (guint i = 0; i < sizeof values; i++) values[i] = (i * 37 + 23) % 256;
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (mask)), GEGL_RECTANGLE (0, 0, 13, 11),
                   0, babl_format ("Y u8"), values, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (mask), 0, 0, 13, 11);
  GimpLayer *selected[] = { b, third, a };
  NEED (select_exact (image, selected, 3), "actual selected order differs from captured A,B order");
  GlimsSelectOptions options = { .struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE };
  GlimsPoint corners[] = { {3, 4}, {20, 19} };
  NEED (api->select_shape (engine, id, GLIMS_SHAPE_RECTANGLE, corners, 2, &options) == GLIMS_STATUS_OK,
        "nonempty selection-mask witness exists before resize");
  a_raw = read_raw (GIMP_DRAWABLE (a), FALSE); b_raw = read_raw (GIMP_DRAWABLE (b), FALSE);
  mask_raw = read_raw (GIMP_DRAWABLE (mask), TRUE);
  NEED (a_raw.bytes[3] == 255 && a_raw.bytes[0] == 21 && b_raw.bytes[0] == 93 &&
        mask_raw.bytes[0] == 23 && mask_raw.bytes[1] == 60,
        "independent literal seed pixels and alternating mask values are real");
  NEED (api->image_render (engine, id, 1, (GlimsRect) {0, 0, 32, 24}, before_composite, 32 * 4) == GLIMS_STATUS_OK,
        "image-cropped original composite is captured");
  gimp_image_clean_all (image);
  original = fingerprint (engine, id, FALSE);
  GlimsUndoInfo before = {0}, after = {0};
  NEED (original && api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK, "native original facts and history captured");
  GlimsItemID ids[] = { item_id (a), item_id (b) };
  NEED (glims_image_fit_layers_to_image (engine, id, ids, 2, &error) == GLIMS_STATUS_OK, "two captured targets fit as one batch");
  CHECK (fitted_pixels (GIMP_DRAWABLE (a), &a_raw, FALSE, 32, 24), "partly off-canvas A is cropped and padded transparently at exact image coordinates");
  CHECK (fitted_pixels (GIMP_DRAWABLE (b), &b_raw, FALSE, 32, 24), "offset B preserves every old in-canvas pixel and has transparent new area");
  /* Native layer resize forwards TRANSPARENT to its one-channel mask;
   * that means black zero outside the old mask, not white. */
  CHECK (fitted_pixels (GIMP_DRAWABLE (mask), &mask_raw, TRUE, 32, 24), "mask resizes with A, preserves values and pads black zero");
  CHECK (selection_is (image, selected, 3), "native selection still has its exact pre-request order");
  CHECK (api->image_render (engine, id, 1, (GlimsRect) {0, 0, 32, 24}, after_composite, 32 * 4) == GLIMS_STATUS_OK &&
         !memcmp (before_composite, after_composite, sizeof before_composite), "fitting preserves the whole in-canvas composite");
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
         "both resizes produce exactly one native Undo step");
  fitted = fingerprint (engine, id, FALSE);
  NEED (fitted != NULL, "fitted state captured");
  for (guint cycle = 0; cycle < 2; cycle++) {
    NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "one Undo restores the whole batch");
    state = fingerprint (engine, id, FALSE);
    CHECK (state && !strcmp (state, original) && !gimp_image_is_dirty (image),
           "Undo restores exact raw pixels/masks/bounds/tree/selection and clean mark");
    g_clear_pointer (&state, g_free);
    NEED (api->image_redo (engine, id) == GLIMS_STATUS_OK, "one Redo reapplies the whole batch");
    state = fingerprint (engine, id, FALSE);
    CHECK (state && !strcmp (state, fitted), "Redo restores exact fitted facts including untouched nested leaf");
    g_clear_pointer (&state, g_free);
  }
  gimp_image_clean_all (image); g_clear_pointer (&original, g_free);
  original = fingerprint (engine, id, TRUE);
  NEED (glims_image_fit_layers_to_image (engine, id, ids, 2, &error) == GLIMS_STATUS_OK, "all-already-fit request succeeds");
  state = fingerprint (engine, id, TRUE);
  CHECK (original && state && !strcmp (original, state), "all-no-op batch changes no pixels/dirty/history or native selection");
  g_clear_pointer (&state, g_free);
  GimpLayer *changed = add_layer (image, NULL, "Mixed changed member", 4, 3, 8, 9, 17);
  NEED (changed != NULL, "mixed no-op fixture adds a genuinely small member");
  GlimsItemID mixed[] = { item_id (a), item_id (changed) };
  NEED (api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        glims_image_fit_layers_to_image (engine, id, mixed, 2, &error) == GLIMS_STATUS_OK, "mixed unchanged and changed batch succeeds");
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
         "mixed no-op/changed request still adds exactly one step");
cleanup:
  raw_clear (&a_raw); raw_clear (&b_raw); raw_clear (&mask_raw);
  g_free (original); g_free (fitted); g_free (state); clear_error (&error);
  if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
nesting_and_alpha_case (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; char *error = NULL;
  gchar *original = NULL, *fitted = NULL, *state = NULL;
  Raw child_raw = {0}, root_raw = {0}, sibling_raw = {0}, sibling_after = {0};
  guint8 before_pixels[16 * 12 * 4], after_pixels[16 * 12 * 4];
  NEED (api->image_new (engine, 16, 12, &id, &error) == GLIMS_STATUS_OK, "nested fit image starts");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *group = gimp_group_layer_new (image);
  NEED (group && gimp_image_add_layer (image, group, NULL, 0, FALSE), "resized target's actual group attaches");
  GimpLayer *child = add_layer (image, group, "Nested resized target", 8, 7, -3, 2, 12);
  GimpLayer *sibling = add_layer (image, group, "Unchanged nested sibling", 5, 4, 10, 6, 24);
  GimpLayer *root = add_layer (image, NULL, "Root resized target", 6, 5, 7, -2, 48);
  NEED (child && sibling && root, "nested target, same-parent sibling and root target attach");
  GimpLayer *selected[] = { root, sibling, child };
  NEED (select_exact (image, selected, 3), "nested native selection differs from captured child/root vector");
  gint child_index = gimp_item_get_index (GIMP_ITEM (child)), sibling_index = gimp_item_get_index (GIMP_ITEM (sibling));
  gint root_index = gimp_item_get_index (GIMP_ITEM (root)), group_index = gimp_item_get_index (GIMP_ITEM (group));
  gimp_layer_set_lock_alpha (child, TRUE, FALSE); gimp_layer_set_lock_alpha (root, TRUE, FALSE);
  child_raw = read_raw (GIMP_DRAWABLE (child), FALSE); root_raw = read_raw (GIMP_DRAWABLE (root), FALSE);
  sibling_raw = read_raw (GIMP_DRAWABLE (sibling), FALSE);
  NEED (child_raw.x == -3 && child_raw.y == 2 && root_raw.x == 7 && root_raw.y == -2 &&
        sibling_raw.x == 10 && sibling_raw.y == 6, "nested fixture offsets are actual image coordinates");
  NEED (api->image_render (engine, id, 1, (GlimsRect) {0, 0, 16, 12}, before_pixels, 16 * 4) == GLIMS_STATUS_OK,
        "nested original image composite captured");
  gimp_image_clean_all (image); original = fingerprint (engine, id, FALSE);
  GlimsUndoInfo before = {0}, after = {0}; GlimsItemID ids[] = { item_id (child), item_id (root) };
  NEED (original && api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        glims_image_fit_layers_to_image (engine, id, ids, 2, &error) == GLIMS_STATUS_OK,
        "nested and root targets succeed with alpha-only locks enabled");
  CHECK (fitted_pixels (GIMP_DRAWABLE (child), &child_raw, FALSE, 16, 12) &&
         fitted_pixels (GIMP_DRAWABLE (root), &root_raw, FALSE, 16, 12),
         "both targets fit in world coordinates with exact cropping/transparent padding");
  sibling_after = read_raw (GIMP_DRAWABLE (sibling), FALSE);
  CHECK (sibling_after.x == sibling_raw.x && sibling_after.y == sibling_raw.y &&
         sibling_after.width == sibling_raw.width && sibling_after.height == sibling_raw.height &&
         !memcmp (sibling_after.bytes, sibling_raw.bytes, (gsize) sibling_raw.width * sibling_raw.height * 4),
         "same-group sibling bounds and every pixel remain unchanged");
  CHECK (gimp_layer_get_parent (child) == group && gimp_layer_get_parent (sibling) == group &&
         gimp_layer_get_parent (root) == NULL && gimp_layer_get_parent (group) == NULL &&
         gimp_item_get_index (GIMP_ITEM (child)) == child_index && gimp_item_get_index (GIMP_ITEM (sibling)) == sibling_index &&
         gimp_item_get_index (GIMP_ITEM (root)) == root_index && gimp_item_get_index (GIMP_ITEM (group)) == group_index &&
         selection_is (image, selected, 3) && gimp_layer_get_lock_alpha (child) && gimp_layer_get_lock_alpha (root),
         "parents/index order, native selected order and alpha locks survive fitting");
  CHECK (api->image_render (engine, id, 1, (GlimsRect) {0, 0, 16, 12}, after_pixels, 16 * 4) == GLIMS_STATUS_OK &&
         !memcmp (before_pixels, after_pixels, sizeof before_pixels), "nested group resizing preserves the in-canvas composite");
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
         "nested/root fit is one native Undo");
  fitted = fingerprint (engine, id, FALSE);
  NEED (fitted && api->image_undo (engine, id) == GLIMS_STATUS_OK, "nested fit undoes in one step");
  state = fingerprint (engine, id, FALSE);
  CHECK (state && !strcmp (state, original) && !gimp_image_is_dirty (image),
         "Undo restores group/child bounds, all raw pixels, topology, selection and clean mark");
  g_clear_pointer (&state, g_free);
  NEED (api->image_redo (engine, id) == GLIMS_STATUS_OK, "nested fit redoes in one step");
  state = fingerprint (engine, id, FALSE);
  CHECK (state && !strcmp (state, fitted), "Redo restores exact nested fitted state");
cleanup:
  raw_clear (&child_raw); raw_clear (&root_raw); raw_clear (&sibling_raw); raw_clear (&sibling_after);
  g_free (original); g_free (fitted); g_free (state); clear_error (&error); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
capacity_case (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; char *error = NULL; gchar *before = NULL, *after = NULL;
  GlimsItemID ids[256]; GimpLayer *layers[256];
  NEED (api->image_new (engine, 1, 1, &id, &error) == GLIMS_STATUS_OK, "256-count fixture creates a 1x1 native image");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GList *rows = gimp_image_get_layer_list (image);
  gboolean one_base = rows && !rows->next;
  layers[0] = one_base ? rows->data : NULL; g_list_free (rows);
  NEED (one_base && layers[0], "capacity fixture starts with exactly one attached background");
  ids[0] = item_id (layers[0]); guint i;
  for (i = 1; i < G_N_ELEMENTS (ids); i++) {
    gchar name[32]; g_snprintf (name, sizeof name, "Capacity layer %u", i);
    layers[i] = add_layer (image, NULL, name, 1, 1, 0, 0, i);
    if (!layers[i]) break;
    ids[i] = item_id (layers[i]);
  }
  NEED (i == G_N_ELEMENTS (ids), "all256 distinct image-sized pixel sources attach");
  rows = gimp_image_get_layer_list (image); guint count = g_list_length (rows); g_list_free (rows);
  GimpLayer *selected[] = { layers[255], layers[0], layers[127] };
  NEED (count == 256 && select_exact (image, selected, 3), "actual tree has256 layers and independent native selection order");
  gimp_image_clean_all (image); before = fingerprint (engine, id, TRUE);
  NEED (before && glims_image_fit_layers_to_image (engine, id, ids, G_N_ELEMENTS (ids), &error) == GLIMS_STATUS_OK,
        "maximum256-member already-fit batch succeeds");
  after = fingerprint (engine, id, TRUE);
  CHECK (after && !strcmp (before, after) && selection_is (image, selected, 3) && !gimp_image_is_dirty (image),
         "maximum no-op batch preserves every pixel/bounds/tree/selection and adds no dirty/history");
cleanup:
  g_free (before); g_free (after); clear_error (&error); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
refusal_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0, foreign = 0; char *error = NULL;
  GlimsStrokeID stroke = 0; GlimsFilterID filter = 0;
  NEED (api->image_new (engine, 32, 24, &id, &error) == GLIMS_STATUS_OK &&
        api->image_new (engine, 32, 24, &foreign, &error) == GLIMS_STATUS_OK, "refusal images start");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *a = add_layer (image, NULL, "First must never resize", 9, 8, 3, 4, 1);
  GimpLayer *b = add_layer (image, NULL, "Second admission", 7, 6, 8, 2, 2);
  GimpLayer *other = add_layer (glims_lookup_image (engine, foreign)->image, NULL, "Foreign", 4, 3, 1, 2, 3);
  NEED (a && b && other, "small valid and foreign sources attach");
  GimpLayer *selected[] = { b, a };
  NEED (select_exact (image, selected, 2), "refusal fixture selection is ordered independently");
  gimp_image_clean_all (image);
  GlimsItemID valid[] = { item_id (a), item_id (b) };
  GlimsItemID bad[] = { item_id (a), 0 };
  refuses (engine, id, NULL, 1, GLIMS_STATUS_INVALID_ARGUMENT, "NULL source vector refuses");
  refuses (engine, id, valid, 0, GLIMS_STATUS_INVALID_ARGUMENT, "empty source vector refuses");
  refuses (engine, id, valid, 257, GLIMS_STATUS_INVALID_ARGUMENT, "over-limit count refuses before reading beyond supplied storage");
  refuses (engine, id, bad, 2, GLIMS_STATUS_INVALID_ARGUMENT, "later zero refuses before resizing first");
  bad[1] = -1; refuses (engine, id, bad, 2, GLIMS_STATUS_INVALID_ARGUMENT, "later negative ID refuses atomically");
  bad[1] = item_id (a); refuses (engine, id, bad, 2, GLIMS_STATUS_INVALID_ARGUMENT, "duplicate source refuses atomically");
  bad[1] = INT_MAX; refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "later unknown ID refuses atomically");
  bad[1] = item_id (other); refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "later foreign ID refuses atomically");
  NEED (api->image_close (engine, foreign) == GLIMS_STATUS_OK, "foreign source dies with its image"); foreign = 0;
  refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "dead later source refuses atomically");
  GimpLayer *detached = add_layer (image, NULL, "Detached via Undo", 3, 3, 2, 2, 4);
  NEED (detached != NULL, "detached fixture attaches first");
  bad[1] = item_id (detached); gimp_image_remove_layer (image, detached, TRUE, NULL);
  NEED (gimp_item_get_by_id (engine->gimp, bad[1]) && !gimp_item_is_attached (GIMP_ITEM (detached)), "stale layer genuinely survives detached in Undo");
  refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "live but detached later ID refuses atomically");
  bad[1] = item_id (gimp_image_get_mask (image));
  refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "actual selection-channel ID is not a layer");
  gimp_item_set_lock_content (GIMP_ITEM (b), TRUE, FALSE);
  refuses (engine, id, valid, 2, GLIMS_STATUS_LOCKED, "locked second layer pixels refuse without changing first");
  gimp_item_set_lock_content (GIMP_ITEM (b), FALSE, FALSE);
  gimp_item_set_lock_position (GIMP_ITEM (b), TRUE, FALSE);
  refuses (engine, id, valid, 2, GLIMS_STATUS_LOCKED, "locked second layer position refuses atomically");
  gimp_item_set_lock_position (GIMP_ITEM (b), FALSE, FALSE);
  GimpLayer *group = gimp_group_layer_new (image);
  NEED (group && gimp_image_add_layer (image, group, NULL, 0, FALSE), "real group attaches");
  GimpLayer *child = add_layer (image, group, "Ancestor locked child", 6, 5, 2, 3, 5);
  NEED (child != NULL, "child belongs to lockable parent");
  bad[1] = item_id (child); gimp_item_set_lock_content (GIMP_ITEM (group), TRUE, FALSE);
  refuses (engine, id, bad, 2, GLIMS_STATUS_LOCKED, "ancestor pixel lock refuses whole captured vector");
  gimp_item_set_lock_content (GIMP_ITEM (group), FALSE, FALSE);
  gimp_item_set_lock_position (GIMP_ITEM (group), TRUE, FALSE);
  refuses (engine, id, bad, 2, GLIMS_STATUS_LOCKED, "ancestor position lock refuses whole vector");
  gimp_item_set_lock_position (GIMP_ITEM (group), FALSE, FALSE);
  bad[1] = item_id (group); refuses (engine, id, bad, 2, GLIMS_STATUS_UNSUPPORTED, "group after valid layer refuses without implicit resizing");
  engine->busy++; refuses (engine, id, valid, 2, GLIMS_STATUS_BUSY, "engine busy refuses"); engine->busy--;
  NEED (gimp_image_undo_freeze (image), "native Undo freeze succeeds");
  refuses (engine, id, valid, 2, GLIMS_STATUS_BUSY, "frozen Undo refuses"); gimp_image_undo_thaw (image);
  NEED (gimp_image_undo_disable (image), "native Undo disable succeeds");
  refuses (engine, id, valid, 2, GLIMS_STATUS_BUSY, "disabled Undo refuses"); gimp_image_undo_enable (image);
  NEED (gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_ITEM_RESIZE, "Outer fixture"), "native outer Undo group starts");
  refuses (engine, id, valid, 2, GLIMS_STATUS_BUSY, "preexisting outer group refuses"); gimp_image_undo_group_end (image);
  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PAINTBRUSH,
    .size = 4, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint point = { 10, 4, 1, 0, 0, 0 };
  NEED (api->stroke_begin (engine, id, item_id (b), &brush, &point, &stroke, &error) == GLIMS_STATUS_OK, "real stroke is active");
  refuses (engine, id, valid, 2, GLIMS_STATUS_BUSY, "active stroke refuses whole resize batch");
  NEED (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "active stroke ends"); stroke = 0;
  NEED (api->filter_begin (engine, id, item_id (b), "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK, "real filter preview is active");
  refuses (engine, id, valid, 2, GLIMS_STATUS_BUSY, "active preview refuses whole resize batch");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "preview aborts"); filter = 0;
  GlimsSelectOptions options = { .struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE };
  GlimsPoint corners[] = { {8, 2}, {12, 6} }; GlimsItemID floating = 0;
  NEED (api->select_shape (engine, id, GLIMS_SHAPE_RECTANGLE, corners, 2, &options) == GLIMS_STATUS_OK &&
        api->selection_float (engine, id, item_id (b), GLIMS_FLOAT_COPY, &floating, &error) == GLIMS_STATUS_OK && floating > 0,
        "real floating selection attaches over target pixels");
  refuses (engine, id, valid, 2, GLIMS_STATUS_BUSY, "unresolved floating selection refuses");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (stroke) api->stroke_end (engine, stroke);
  clear_error (&error); if (foreign) api->image_close (engine, foreign); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
structured_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; char *error = NULL; gchar *original = NULL, *state = NULL;
  NEED (api->image_new (engine, 32, 24, &id, &error) == GLIMS_STATUS_OK, "text fixture image starts");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *a = add_layer (image, NULL, "First ordinary source", 5, 4, 2, 3, 8);
  GimpText *text = g_object_new (GIMP_TYPE_TEXT, "text", "Fit", "font",
                    gimp_context_get_font (gimp_get_user_context (engine->gimp)), "font-size", 9.0, NULL);
  GimpLayer *layer = gimp_text_layer_new (image, text); g_object_unref (text);
  NEED (a && layer && gimp_image_add_layer (image, layer, NULL, 0, FALSE), "genuine editable text attaches");
  GlimsItemID ids[] = { item_id (a), item_id (layer) };
  refuses (engine, id, ids, 2, GLIMS_STATUS_UNSUPPORTED, "later genuine text source refuses before touching ordinary source");
  NEED (api->layer_command (engine, id, item_id (layer), GLIMS_LAYER_RASTERIZE, NULL, &error) == GLIMS_STATUS_OK,
        "explicit native rasterization creates pixel-behaving retained text");
  GlimsLayerSourceInfo source = { .struct_size = sizeof source };
  NEED (api->layer_source_info (engine, id, item_id (layer), &source, NULL) == GLIMS_STATUS_OK &&
        source.source_kind == GLIMS_LAYER_TEXT && source.is_rasterized && source.has_source,
        "rasterized text has actual retained structured source before resize");
  gimp_image_clean_all (image); original = fingerprint (engine, id, FALSE);
  GlimsUndoInfo before = {0}, after = {0};
  NEED (original && api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        glims_image_fit_layers_to_image (engine, id, ids, 2, &error) == GLIMS_STATUS_OK,
        "rasterized text and ordinary source fit together");
  CHECK (glims_layer_kind (layer) == GLIMS_LAYER_PIXEL &&
         api->layer_source_info (engine, id, item_id (layer), &source, NULL) == GLIMS_STATUS_OK &&
         source.source_kind == GLIMS_LAYER_TEXT && source.is_rasterized && source.has_source &&
         gimp_item_get_width (GIMP_ITEM (layer)) == 32 && gimp_item_get_height (GIMP_ITEM (layer)) == 24,
         "fit preserves rasterized subclass and retained source while changing pixel bounds");
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
         "rasterized subclass batch is still exactly one Undo");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "rasterized text fit undoes");
  state = fingerprint (engine, id, FALSE);
  CHECK (state && !strcmp (state, original) && !gimp_image_is_dirty (image), "Undo restores rasterized text and ordinary source exactly");
cleanup:
  g_free (original); g_free (state); clear_error (&error); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

typedef struct { GlimsImageID image; GlimsItemID layer; gchar *digest; } PublicFixture;
static GlimsStatus public_setup (GlimsEngine *engine, gpointer data)
{
  PublicFixture *fixture = data;
  GimpImage *image = glims_lookup_image (engine, fixture->image)->image;
  GimpLayer *layer = add_layer (image, NULL, "Public captured target", 6, 5, 3, 2, 7);
  if (!layer) return GLIMS_STATUS_FAILED;
  fixture->layer = item_id (layer); gimp_image_clean_all (image);
  fixture->digest = fingerprint (engine, fixture->image, TRUE);
  return fixture->digest ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}
static GlimsStatus public_snapshot (GlimsEngine *engine, gpointer data)
{
  PublicFixture *fixture = data;
  fixture->digest = fingerprint (engine, fixture->image, TRUE);
  return fixture->digest ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}
static void
public_cases (GlimsEngine *engine)
{
  PublicFixture original = {0}, after = {0}; char *error = NULL;
  NEED (api->image_new (engine, 32, 24, &original.image, &error) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, public_setup, &original) == GLIMS_STATUS_OK, "public host-thread fixture is initialized on worker");
  after.image = original.image;
  GlimsItemID bad[] = { original.layer, INT_MAX };
  CHECK (api->image_fit_layers_to_image (engine, original.image, &original.layer, -1, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "public signed -1 count refuses"); clear_error (&error);
  CHECK (api->image_fit_layers_to_image (engine, original.image, NULL, 1, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "public NULL vector refuses"); clear_error (&error);
  CHECK (api->image_fit_layers_to_image (engine, original.image, &original.layer, 0, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "public zero count refuses"); clear_error (&error);
  CHECK (api->image_fit_layers_to_image (engine, original.image, &original.layer, 257, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "public257 count refuses before vector access"); clear_error (&error);
  CHECK (api->image_fit_layers_to_image (engine, original.image, bad, 2, &error) == GLIMS_STATUS_NOT_FOUND, "public later invalid ID refuses"); clear_error (&error);
  CHECK (api->image_fit_layers_to_image (engine, INT_MAX, &original.layer, 1, &error) == GLIMS_STATUS_NOT_FOUND, "public stale image refuses"); clear_error (&error);
  NEED (glims_engine_call (engine, public_snapshot, &after) == GLIMS_STATUS_OK, "public refusals have a fresh native snapshot");
  CHECK (!strcmp (original.digest, after.digest), "all public refusals are quiet before successful marshal");
  GlimsUndoInfo before = {0}, next = {0};
  NEED (api->image_undo_info (engine, original.image, &before) == GLIMS_STATUS_OK &&
        api->image_fit_layers_to_image (engine, original.image, &original.layer, 1, &error) == GLIMS_STATUS_OK,
        "public slot156 host-thread blocking marshal performs an actual resize");
  GlimsLayerInfo rows[2] = {{0}}; int32_t count = 0;
  NEED (api->image_layers (engine, original.image, rows, 2, &count) == GLIMS_STATUS_OK && count == 2, "public resized tree has expected actual layer count");
  CHECK (rows[0].id == original.layer && rows[0].bounds.x == 0 && rows[0].bounds.y == 0 && rows[0].bounds.width == 32 && rows[0].bounds.height == 24,
         "public target reports exact fitted image bounds");
  CHECK (api->image_undo_info (engine, original.image, &next) == GLIMS_STATUS_OK && next.undo_count == before.undo_count + 1,
         "public successful resize records one Undo");
  NEED (api->image_undo (engine, original.image) == GLIMS_STATUS_OK, "public resize undoes");
cleanup:
  clear_error (&error); if (original.image) api->image_close (engine, original.image);
  g_free (original.digest); g_free (after.digest);
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof (GlimsEngineAPI) || !api->image_fit_layers_to_image ||
      api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "matching slot156 engine startup failed");
    if (api && error) api->free_string (error); g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, geometry_cases, NULL) == GLIMS_STATUS_OK, "geometry fixtures execute on worker");
  CHECK (glims_engine_call (engine, nesting_and_alpha_case, NULL) == GLIMS_STATUS_OK, "nested/alpha-lock fixture executes on worker");
  CHECK (glims_engine_call (engine, capacity_case, NULL) == GLIMS_STATUS_OK, "maximum-count fixture executes on worker");
  CHECK (glims_engine_call (engine, refusal_cases, NULL) == GLIMS_STATUS_OK, "refusal fixtures execute on worker");
  CHECK (glims_engine_call (engine, structured_cases, NULL) == GLIMS_STATUS_OK, "structured-source fixtures execute on worker");
  public_cases (engine);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

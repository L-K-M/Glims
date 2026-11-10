/* Source-only batch Restore fixtures, authored without compiling/running.
 * Native text pixels captured before rasterization are the independent
 * regeneration oracle. Root builds/runs against an immutable slot166 producer
 * with throwaway directories; this source is not runtime evidence. */
#include "engine-private.h"
#include "layer-restore.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayermask.h"
#include "text/gimptext.h"
#include "text/gimptextlayer.h"
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static int checks, failures;
#define CHECK(c, label) do { gboolean ok_ = (c); checks++; \
  printf ("%s %s\n", ok_ ? "ok  " : "FAIL", label); \
  if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, label) do { gboolean ok_needed_ = (c); CHECK (ok_needed_, label); \
  if (!ok_needed_) goto cleanup; } while (0)

static GlimsItemID item_id (gpointer item) { return gimp_item_get_id (GIMP_ITEM (item)); }
static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }

static GimpLayer *
add_text (GlimsEngine *engine, GimpImage *image, GimpLayer *parent,
          const gchar *words, gint x, gint y)
{
  GimpText *text = g_object_new (GIMP_TYPE_TEXT, "text", words, "font",
    gimp_context_get_font (gimp_get_user_context (engine->gimp)), "font-size", 9.0, NULL);
  GimpLayer *layer = gimp_text_layer_new (image, text);
  g_object_unref (text);
  if (!layer) return NULL;
  gimp_item_set_offset (GIMP_ITEM (layer), x, y);
  if (!gimp_image_add_layer (image, layer, parent, 0, FALSE))
    {
      g_object_unref (layer); return NULL;
    }
  return layer; /* Image-owned. */
}

static gboolean
select_exact (GimpImage *image, GimpLayer *first, GimpLayer *second)
{
  GList *layers = g_list_append (NULL, first);
  layers = g_list_append (layers, second);
  gimp_image_set_selected_layers (image, layers);
  g_list_free (layers);
  layers = gimp_image_get_selected_layers (image); /* Borrowed nodes. */
  return layers && layers->data == first && layers->next &&
         layers->next->data == second && !layers->next->next;
}

static void
append_pixels (GString *state, GimpDrawable *drawable, gboolean mask)
{
  gint width = gimp_item_get_width (GIMP_ITEM (drawable));
  gint height = gimp_item_get_height (GIMP_ITEM (drawable));
  gint channels = mask ? 1 : 4;
  guint8 *pixels = g_malloc0 ((gsize) width * height * channels);
  const Babl *format = babl_format (mask ? "Y u8" : "R'G'B'A u8");
  if (width == 1 && height == 1)
    {
      guint8 pair[8] = {0};
      /* A multi-pixel read validates the native tile behind the one pixel. */
      gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, 2, 1),
                       1, format, pair, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      memcpy (pixels, pair, channels);
    }
  else
    gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, width, height),
                     1, format, pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  /* The drawable buffer is borrowed; only our pixel allocation is owned. */
  g_string_append_len (state, (const gchar *) pixels, (gssize) width * height * channels);
  g_free (pixels);
}

/* Native content/geometry/masks/topology/ordered selection and retained text.
 * Refusals include source behavior, complete history and clean state. */
static gchar *
fingerprint (GlimsEngine *engine, GlimsImageID id, gboolean source_state, gboolean history)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return NULL;
  GimpImage *image = open->image;
  GString *state = g_string_new (NULL);
  if (history)
    {
      GlimsUndoInfo undo = {0};
      if (api->image_undo_info (engine, id, &undo) != GLIMS_STATUS_OK)
        { g_string_free (state, TRUE); return NULL; }
      g_string_append_len (state, (const gchar *) &undo, sizeof undo);
      g_string_append_printf (state, "dirty:%d;undo-enabled:%d;group:%d;",
                              gimp_image_is_dirty (image), gimp_image_undo_is_enabled (image),
                              gimp_image_get_undo_group_count (image));
      GlimsHistoryInfo hinfo = {0};
      if (api->image_history (engine, id, NULL, 0, &hinfo) != GLIMS_STATUS_OK || hinfo.count < 0)
        { g_string_free (state, TRUE); return NULL; }
      GlimsHistoryRow *hrows = g_new0 (GlimsHistoryRow, hinfo.count);
      int32_t capacity = hinfo.count;
      if (api->image_history (engine, id, hrows, capacity, &hinfo) != GLIMS_STATUS_OK || hinfo.count > capacity)
        { g_free (hrows); g_string_free (state, TRUE); return NULL; }
      g_string_append_printf (state, "history:%" G_GUINT64_FORMAT ":%d:%d;",
                              (guint64) hinfo.revision, hinfo.count, hinfo.current_position);
      for (int32_t i = 0; i < hinfo.count; i++)
        g_string_append_printf (state, "history-row:%d:%zu:%s;", hrows[i].position,
                                strlen (hrows[i].name), hrows[i].name);
      g_free (hrows);
    }
  GList *layers = gimp_image_get_layer_list (image); /* Owned list nodes. */
  for (GList *it = layers; it; it = it->next)
    {
      GimpLayer *layer = it->data;
      GimpItem *item = GIMP_ITEM (layer);
      GimpLayer *parent = gimp_layer_get_parent (layer);
      gint x, y;
      gimp_item_get_offset (item, &x, &y);
      g_string_append_printf (state, "%d:%s:%d:%d:%d:%d:%d:%d:%s:%.17g:%d:%d:%d:%d;",
        item_id (layer), G_OBJECT_TYPE_NAME (layer), parent ? item_id (parent) : 0,
        gimp_item_get_index (item), x, y, gimp_item_get_width (item), gimp_item_get_height (item),
        gimp_object_get_name (layer), gimp_layer_get_opacity (layer), gimp_item_get_visible (item),
        gimp_item_get_lock_content (item), gimp_item_get_lock_position (item),
        gimp_layer_get_lock_alpha (layer));
      if (!GIMP_IS_GROUP_LAYER (layer)) append_pixels (state, GIMP_DRAWABLE (layer), FALSE);
      if (GIMP_IS_TEXT_LAYER (layer))
        {
          GimpText *text = gimp_text_layer_get_text (GIMP_TEXT_LAYER (layer));
          gchar *words = NULL;
          if (text) g_object_get (text, "text", &words, NULL);
          g_string_append_printf (state, "source:%p:%s;", (void *) text, words ? words : "");
          g_free (words);
          if (source_state)
            g_string_append_printf (state, "editable:%d;", gimp_item_is_text_layer (item));
        }
      GimpLayerMask *mask = gimp_layer_get_mask (layer);
      GlimsMaskState mask_state = {0};
      if (api->layer_mask (engine, id, item_id (layer), &mask_state) != GLIMS_STATUS_OK)
        { g_list_free (layers); g_string_free (state, TRUE); return NULL; }
      g_string_append_len (state, (const gchar *) &mask_state, sizeof mask_state);
      if (mask) append_pixels (state, GIMP_DRAWABLE (mask), TRUE);
    }
  g_list_free (layers);
  for (GList *it = gimp_image_get_selected_layers (image); it; it = it->next)
    g_string_append_printf (state, "selected:%d;", item_id (it->data)); /* Borrowed. */
  for (GList *it = gimp_image_get_selected_channels (image); it; it = it->next)
    g_string_append_printf (state, "selected-channel:%d;", item_id (it->data)); /* Borrowed. */
  append_pixels (state, GIMP_DRAWABLE (gimp_image_get_mask (image)), TRUE);
  guint8 composite[32 * 24 * 4];
  if (api->image_render (engine, id, 1, (GlimsRect) {0, 0, 32, 24}, composite, 32 * 4) != GLIMS_STATUS_OK)
    { g_string_free (state, TRUE); return NULL; }
  g_string_append_len (state, (const gchar *) composite, sizeof composite);
  gchar *digest = g_compute_checksum_for_data (G_CHECKSUM_SHA256,
                                               (const guchar *) state->str, state->len);
  g_string_free (state, TRUE);
  return digest;
}

static gboolean
matches (GlimsEngine *engine, GlimsImageID image, const gchar *before,
         gboolean source_state, gboolean history)
{
  gchar *after = fingerprint (engine, image, source_state, history);
  gboolean same = before && after && !strcmp (before, after);
  g_free (after); return same;
}

static void
refuses (GlimsEngine *engine, GlimsImageID image, const GlimsItemID *ids,
         size_t count, GlimsStatus expected, const gchar *label)
{
  gchar *before = fingerprint (engine, image, TRUE, TRUE);
  char *error = NULL;
  GlimsStatus status = glims_image_restore_layer_sources (engine, image, ids, count, &error);
  if (status != expected)
    fprintf (stderr, "status %d expected %d: %s\n", status, expected, error ? error : "");
  CHECK (status == expected, label);
  CHECK (matches (engine, image, before, TRUE, TRUE),
         "refusal preserves raw/composite/mask pixels, sources, tree, selection, history and clean state");
  g_free (before); clear_error (&error);
}

/* Direct pixel damage after native rasterization; source text is untouched. */
static void
damage (GimpLayer *layer, guint seed)
{
  gint width = gimp_item_get_width (GIMP_ITEM (layer));
  gint height = gimp_item_get_height (GIMP_ITEM (layer));
  guint8 *bytes = g_malloc ((gsize) width * height * 4);
  for (gint y = 0; y < height; y++) for (gint x = 0; x < width; x++)
    {
      guint8 *p = bytes + ((gsize) y * width + x) * 4;
      p[0] = 30 + (x * 17 + seed) % 200;
      p[1] = 20 + (y * 23 + seed) % 210;
      p[2] = 40 + (x * 7 + y * 11 + seed) % 190;
      p[3] = 110 + (x * 3 + y * 5 + seed) % 140;
    }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)),
                   GEGL_RECTANGLE (0, 0, width, height), 0,
                   babl_format ("R'G'B'A u8"), bytes, GEGL_AUTO_ROWSTRIDE);
  g_free (bytes);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, width, height);
}

static GlimsStatus
success_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; GlimsItemID mask_id = 0; char *error = NULL;
  gchar *expected = NULL, *damaged = NULL, *restored = NULL, *noop = NULL, *mixed = NULL;
  NEED (api->image_new (engine, 32, 24, &id, &error) == GLIMS_STATUS_OK, "batch Restore image starts");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *group = gimp_group_layer_new (image);
  NEED (group && gimp_image_add_layer (image, group, NULL, 0, FALSE), "real parent group attaches");
  GimpLayer *a = add_text (engine, image, group, "A", -2, 3);
  GimpLayer *b = add_text (engine, image, NULL, "B2", 13, 8);
  NEED (a && b && gimp_item_is_text_layer (GIMP_ITEM (a)) && gimp_item_is_text_layer (GIMP_ITEM (b)),
        "nested and root sources begin as genuine independently rendered native text");
  NEED (select_exact (image, b, a), "native selected order differs from captured restore order");
  GlimsItemID ids[] = { item_id (a), item_id (b) };
  NEED (api->layer_mask_add (engine, id, ids[0], GLIMS_MASK_WHITE, FALSE, &mask_id, &error) == GLIMS_STATUS_OK,
        "source target receives a real attached mask");
  GimpLayerMask *mask = gimp_layer_get_mask (a);
  gint mw = gimp_item_get_width (GIMP_ITEM (mask)), mh = gimp_item_get_height (GIMP_ITEM (mask));
  guint8 *mask_bytes = g_malloc ((gsize) mw * mh);
  for (gint i = 0; i < mw * mh; i++) mask_bytes[i] = (guint8) (37 + i * 53);
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (mask)), GEGL_RECTANGLE (0, 0, mw, mh),
                   0, babl_format ("Y u8"), mask_bytes, GEGL_AUTO_ROWSTRIDE);
  g_free (mask_bytes); gimp_drawable_update (GIMP_DRAWABLE (mask), 0, 0, mw, mh);
  gimp_layer_set_lock_alpha (a, TRUE, FALSE);
  GimpText *a_source = gimp_text_layer_get_text (GIMP_TEXT_LAYER (a));
  GimpText *b_source = gimp_text_layer_get_text (GIMP_TEXT_LAYER (b));
  /* Expected pixels and mask geometry come from actual native text rendering
   * before the sources are rasterized, never from the batch implementation. */
  expected = fingerprint (engine, id, TRUE, FALSE);
  NEED (expected && glims_layer_rasterize (image, a, &error) == GLIMS_STATUS_OK &&
        glims_layer_rasterize (image, b, &error) == GLIMS_STATUS_OK,
        "both retained sources are explicitly rasterized before destructive pixel edits");
  damage (a, 13); damage (b, 79); gimp_image_flush (image); gimp_image_clean_all (image);
  damaged = fingerprint (engine, id, TRUE, FALSE);
  CHECK (damaged && strcmp (damaged, expected) && !gimp_item_is_text_layer (GIMP_ITEM (a)) &&
         !gimp_item_is_text_layer (GIMP_ITEM (b)),
         "asymmetric pixel damage differs from the independent source render while text remains retained");
  GlimsUndoInfo before = {0}, after = {0};
  NEED (api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        glims_image_restore_layer_sources (engine, id, ids, 2, &error) == GLIMS_STATUS_OK,
        "ordered two-source Restore succeeds under an alpha-only lock");
  CHECK (gimp_item_is_text_layer (GIMP_ITEM (a)) && gimp_item_is_text_layer (GIMP_ITEM (b)) &&
         gimp_text_layer_get_text (GIMP_TEXT_LAYER (a)) == a_source &&
         gimp_text_layer_get_text (GIMP_TEXT_LAYER (b)) == b_source,
         "actual editable predicates return and both original text objects remain retained");
  CHECK (matches (engine, id, expected, TRUE, FALSE),
         "Restore exactly regenerates the independent text pixels, this fixture's unchanged-extent mask, IDs/tree and selected order");
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1 &&
         engine->busy == 0 && !gimp_image_get_undo_group_count (image),
         "multiple regenerations share exactly one balanced Undo group and release busy");
  restored = fingerprint (engine, id, TRUE, FALSE);
  noop = fingerprint (engine, id, TRUE, TRUE);
  CHECK (glims_image_restore_layer_sources (engine, id, ids, 2, &error) == GLIMS_STATUS_OK &&
         matches (engine, id, noop, TRUE, TRUE), "all-editable retained vector is a full history/dirty/content no-op");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "batch Restore undoes in one step");
  CHECK (matches (engine, id, damaged, TRUE, FALSE) && !gimp_image_is_dirty (image),
         "one Undo restores exact damaged raster pixels and the original clean mark");
  NEED (api->image_redo (engine, id) == GLIMS_STATUS_OK, "batch Restore redoes in one step");
  CHECK (matches (engine, id, restored, TRUE, FALSE),
         "one Redo regenerates both exact text sources again without changing identity or selection");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK &&
        glims_layer_restore_source (image, a, &error) == GLIMS_STATUS_OK,
        "mixed vector starts with an editable no-op and one damaged raster source");
  mixed = fingerprint (engine, id, TRUE, FALSE);
  NEED (mixed && api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        glims_image_restore_layer_sources (engine, id, ids, 2, &error) == GLIMS_STATUS_OK,
        "mixed no-op/changed Restore succeeds");
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1 &&
         matches (engine, id, expected, TRUE, FALSE),
         "mixed Restore adds one Undo and reaches the independent native text render");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "mixed Restore undoes");
  CHECK (matches (engine, id, mixed, TRUE, FALSE), "mixed Undo changes only the member that needed regeneration");
  gimp_item_set_lock_content (GIMP_ITEM (a), TRUE, FALSE);
  refuses (engine, id, ids, 2, GLIMS_STATUS_LOCKED,
           "locked editable no-op member refuses before a later damaged source can change");
  gimp_item_set_lock_content (GIMP_ITEM (a), FALSE, FALSE);
cleanup:
  g_free (expected); g_free (damaged); g_free (restored); g_free (noop); g_free (mixed);
  clear_error (&error); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
refusal_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0, foreign = 0; char *error = NULL;
  GlimsFilterID filter = 0; GlimsStrokeID stroke = 0; GlimsItemID mask_id = 0;
  NEED (api->image_new (engine, 32, 24, &id, &error) == GLIMS_STATUS_OK &&
        api->image_new (engine, 32, 24, &foreign, &error) == GLIMS_STATUS_OK, "refusal images start");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *a = add_text (engine, image, NULL, "First", 2, 3);
  GimpLayer *b = add_text (engine, image, NULL, "Last", 11, 8);
  GimpLayer *other = add_text (engine, glims_lookup_image (engine, foreign)->image, NULL, "Foreign", 1, 2);
  NEED (a && b && other && select_exact (image, b, a), "valid, foreign and selected text fixtures attach");
  GlimsItemID ids[] = { item_id (a), item_id (b) }, bad[] = { item_id (a), 0 };
  NEED (glims_layer_rasterize (image, a, &error) == GLIMS_STATUS_OK &&
        glims_layer_rasterize (image, b, &error) == GLIMS_STATUS_OK,
        "refusal targets are genuinely rasterized retained sources");
  damage (a, 23); damage (b, 91); gimp_image_flush (image);
  refuses (engine, id, NULL, 1, GLIMS_STATUS_INVALID_ARGUMENT, "NULL vector refuses");
  refuses (engine, id, ids, 0, GLIMS_STATUS_INVALID_ARGUMENT, "zero count refuses");
  refuses (engine, id, ids, 257, GLIMS_STATUS_INVALID_ARGUMENT, "257 count refuses before reading short supplied storage");
  refuses (engine, id, bad, 2, GLIMS_STATUS_INVALID_ARGUMENT, "invalid last zero leaves first damaged source untouched");
  bad[1] = -1; refuses (engine, id, bad, 2, GLIMS_STATUS_INVALID_ARGUMENT, "negative last ID refuses");
  bad[1] = ids[0]; refuses (engine, id, bad, 2, GLIMS_STATUS_INVALID_ARGUMENT, "duplicate ID refuses");
  bad[1] = INT_MAX; refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "unknown last ID refuses");
  bad[1] = item_id (other); refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "foreign last ID refuses");
  NEED (api->image_close (engine, foreign) == GLIMS_STATUS_OK, "foreign image closes"); foreign = 0;
  refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "dead foreign last ID refuses");
  GimpLayer *detached = add_text (engine, image, NULL, "Detached", 1, 1);
  NEED (detached != NULL, "detached source fixture attaches first");
  bad[1] = item_id (detached); gimp_image_remove_layer (image, detached, TRUE, NULL);
  NEED (gimp_item_get_by_id (engine->gimp, bad[1]) && !gimp_item_is_attached (GIMP_ITEM (detached)),
        "detached source survives as an actual Undo-owned object");
  refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "detached last ID refuses");
  bad[1] = item_id (gimp_image_get_mask (image));
  refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "selection-channel ID refuses as non-layer");
  NEED (api->layer_mask_add (engine, id, ids[1], GLIMS_MASK_WHITE, FALSE, &mask_id, &error) == GLIMS_STATUS_OK,
        "real mask ID exists for non-layer admission");
  bad[1] = mask_id;
  refuses (engine, id, bad, 2, GLIMS_STATUS_NOT_FOUND, "actual layer-mask last ID refuses before restoring first source");
  GList *rows = gimp_image_get_layer_list (image);
  GimpLayer *plain = NULL;
  for (GList *it = rows; it; it = it->next)
    if (!GIMP_IS_TEXT_LAYER (it->data)) { plain = it->data; break; }
  g_list_free (rows);
  NEED (plain != NULL, "ordinary background pixels exist");
  bad[1] = item_id (plain); refuses (engine, id, bad, 2, GLIMS_STATUS_UNSUPPORTED, "ordinary pixels refuse without touching first text");
  GimpLayer *group = gimp_group_layer_new (image);
  NEED (group && gimp_image_add_layer (image, group, NULL, 0, FALSE), "group attaches");
  bad[1] = item_id (group); refuses (engine, id, bad, 2, GLIMS_STATUS_UNSUPPORTED, "group refuses without flattening");
  GimpLayer *missing = add_text (engine, image, NULL, "Discarded source", 3, 4);
  NEED (missing != NULL, "missing-source structured subclass attaches");
  gimp_text_layer_set_text (GIMP_TEXT_LAYER (missing), NULL);
  NEED (!gimp_text_layer_get_text (GIMP_TEXT_LAYER (missing)), "last structured member genuinely has no retained source");
  bad[1] = item_id (missing); refuses (engine, id, bad, 2, GLIMS_STATUS_UNSUPPORTED, "missing source refuses rather than becoming a successful no-op");
  gimp_item_set_lock_content (GIMP_ITEM (b), TRUE, FALSE);
  refuses (engine, id, ids, 2, GLIMS_STATUS_LOCKED, "last content lock refuses");
  gimp_item_set_lock_content (GIMP_ITEM (b), FALSE, FALSE);
  gimp_item_set_lock_position (GIMP_ITEM (b), TRUE, FALSE);
  refuses (engine, id, ids, 2, GLIMS_STATUS_LOCKED, "last position lock refuses");
  gimp_item_set_lock_position (GIMP_ITEM (b), FALSE, FALSE);
  GimpLayer *child = add_text (engine, image, group, "Nested", 4, 5);
  NEED (child != NULL, "nested text belongs to real group");
  bad[1] = item_id (child); gimp_item_set_lock_content (GIMP_ITEM (group), TRUE, FALSE);
  refuses (engine, id, bad, 2, GLIMS_STATUS_LOCKED, "inherited content lock refuses");
  gimp_item_set_lock_content (GIMP_ITEM (group), FALSE, FALSE);
  gimp_item_set_lock_position (GIMP_ITEM (group), TRUE, FALSE);
  refuses (engine, id, bad, 2, GLIMS_STATUS_LOCKED, "inherited position lock refuses");
  gimp_item_set_lock_position (GIMP_ITEM (group), FALSE, FALSE);
  engine->busy++; refuses (engine, id, ids, 2, GLIMS_STATUS_BUSY, "busy engine refuses"); engine->busy--;
  NEED (gimp_image_undo_freeze (image), "Undo freezes");
  refuses (engine, id, ids, 2, GLIMS_STATUS_BUSY, "frozen Undo refuses"); gimp_image_undo_thaw (image);
  NEED (gimp_image_undo_disable (image), "Undo disables");
  refuses (engine, id, ids, 2, GLIMS_STATUS_BUSY, "disabled Undo refuses"); gimp_image_undo_enable (image);
  NEED (gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_DRAWABLE_MOD, "Existing edit"), "outer Undo fixture starts");
  refuses (engine, id, ids, 2, GLIMS_STATUS_BUSY, "open Undo group refuses"); gimp_image_undo_group_end (image);
  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PAINTBRUSH,
    .size = 4, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint point = { 10, 4, 1, 0, 0, 0 };
  NEED (api->stroke_begin (engine, id, item_id (plain), &brush, &point, &stroke, &error) == GLIMS_STATUS_OK,
        "real stroke is active on another drawable");
  refuses (engine, id, ids, 2, GLIMS_STATUS_BUSY, "active stroke refuses the whole Restore vector");
  NEED (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "stroke ends"); stroke = 0;
  NEED (api->filter_begin (engine, id, item_id (plain), "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK,
        "real preview is active on another drawable");
  refuses (engine, id, ids, 2, GLIMS_STATUS_BUSY, "active preview refuses batch");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "preview aborts"); filter = 0;
  GlimsSelectOptions options = { .struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE };
  GlimsPoint points[] = { {2, 2}, {8, 9} }; GlimsItemID floating = 0;
  NEED (api->select_shape (engine, id, GLIMS_SHAPE_RECTANGLE, points, 2, &options) == GLIMS_STATUS_OK &&
        api->selection_float (engine, id, item_id (plain), GLIMS_FLOAT_COPY, &floating, &error) == GLIMS_STATUS_OK && floating,
        "real floating selection attaches");
  refuses (engine, id, ids, 2, GLIMS_STATUS_BUSY, "floating selection refuses the entire batch");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (stroke) api->stroke_end (engine, stroke);
  clear_error (&error); if (foreign) api->image_close (engine, foreign); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

typedef struct {
  GlimsImageID image;
  GlimsItemID ids[256];
  gchar *expected;
} PublicFixture;

static GlimsStatus
public_setup (GlimsEngine *engine, gpointer data)
{
  PublicFixture *fixture = data;
  GimpImage *image = glims_lookup_image (engine, fixture->image)->image;
  GimpLayer *first = NULL, *second = NULL;
  /* No per-member printed checks: this is one upper-bound vector fixture. */
  for (guint i = 0; i < G_N_ELEMENTS (fixture->ids); i++)
    {
      GimpLayer *layer = add_text (engine, image, NULL,
                                  i == 0 ? "Host A" : i == 1 ? "Host B" : "q",
                                  (gint) (i % 23), (gint) (i % 13));
      if (!layer) return GLIMS_STATUS_FAILED;
      fixture->ids[i] = item_id (layer);
      if (i == 0) first = layer;
      if (i == 1) second = layer;
    }
  if (!first || !second || !select_exact (image, second, first)) return GLIMS_STATUS_FAILED;
  fixture->expected = fingerprint (engine, fixture->image, TRUE, FALSE);
  if (!fixture->expected || glims_layer_rasterize (image, first, NULL) != GLIMS_STATUS_OK ||
      glims_layer_rasterize (image, second, NULL) != GLIMS_STATUS_OK) return GLIMS_STATUS_FAILED;
  damage (first, 29); damage (second, 101);
  gimp_image_flush (image); gimp_image_clean_all (image);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
public_matches (GlimsEngine *engine, gpointer data)
{
  PublicFixture *fixture = data;
  return matches (engine, fixture->image, fixture->expected, TRUE, FALSE)
    ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static void
public_cases (GlimsEngine *engine)
{
  PublicFixture fixture = {0}; char *error = NULL;
  NEED (api->image_new (engine, 32, 24, &fixture.image, &error) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, public_setup, &fixture) == GLIMS_STATUS_OK,
        "host-thread fixture prepares 256 retained sources and two independently damaged targets on engine worker");
  CHECK (api->image_restore_layer_sources (engine, fixture.image, fixture.ids, -1, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "public signed negative count refuses before size_t conversion"); clear_error (&error);
  CHECK (api->image_restore_layer_sources (engine, fixture.image, NULL, 1, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "public NULL vector refuses"); clear_error (&error);
  CHECK (api->image_restore_layer_sources (engine, fixture.image, fixture.ids, 0, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "public zero count refuses"); clear_error (&error);
  CHECK (api->image_restore_layer_sources (engine, fixture.image, fixture.ids, 257, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "public over-limit count refuses before vector access"); clear_error (&error);
  CHECK (api->image_restore_layer_sources (engine, INT_MAX, fixture.ids, 2, &error) == GLIMS_STATUS_NOT_FOUND,
         "public stale image refuses"); clear_error (&error);
  CHECK (api->image_restore_layer_sources (NULL, fixture.image, fixture.ids, 2, &error) == GLIMS_STATUS_NOT_RUNNING
         && error == NULL, "public NULL engine refuses with initialized error output"); clear_error (&error);
  GlimsUndoInfo before = {0}, after = {0};
  NEED (api->image_undo_info (engine, fixture.image, &before) == GLIMS_STATUS_OK &&
        api->image_restore_layer_sources (engine, fixture.image, fixture.ids, 2, &error) == GLIMS_STATUS_OK,
        "public slot166 restores the captured damaged vector synchronously from host thread");
  GlimsLayerSourceInfo a = { .struct_size = sizeof a }, b = { .struct_size = sizeof b };
  CHECK (api->layer_source_info (engine, fixture.image, fixture.ids[0], &a, &error) == GLIMS_STATUS_OK &&
         api->layer_source_info (engine, fixture.image, fixture.ids[1], &b, &error) == GLIMS_STATUS_OK &&
         a.source_kind == GLIMS_LAYER_TEXT && b.source_kind == GLIMS_LAYER_TEXT &&
         a.has_source && b.has_source && !a.is_rasterized && !b.is_rasterized &&
         api->image_undo_info (engine, fixture.image, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
         "public facade reports two retained editable sources and exactly one Undo");
  CHECK (glims_engine_call (engine, public_matches, &fixture) == GLIMS_STATUS_OK,
         "public marshal reaches independent original text pixels/tree/source/ordered-selection oracle");
  before = after;
  CHECK (api->image_restore_layer_sources (engine, fixture.image, fixture.ids, 1, &error) == GLIMS_STATUS_OK &&
         api->image_undo_info (engine, fixture.image, &after) == GLIMS_STATUS_OK &&
         memcmp (&before, &after, sizeof before) == 0,
         "public lower boundary of one already-editable retained source is a no-op");
  CHECK (api->image_restore_layer_sources (engine, fixture.image, fixture.ids, 256, &error) == GLIMS_STATUS_OK &&
         api->image_undo_info (engine, fixture.image, &after) == GLIMS_STATUS_OK &&
         memcmp (&before, &after, sizeof before) == 0 &&
         glims_engine_call (engine, public_matches, &fixture) == GLIMS_STATUS_OK,
         "public upper boundary admits all 256 distinct editable sources with unchanged history and native content");
cleanup:
  clear_error (&error); g_free (fixture.expected); if (fixture.image) api->image_close (engine, fixture.image);
}

static void modern_cases (GlimsEngine *engine, const gchar *work);

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof (GlimsEngineAPI, image_restore_layer_sources) + sizeof api->image_restore_layer_sources ||
      !api->image_restore_layer_sources || api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "%s\n", error ? error : "matching slot166 producer startup failed");
      if (api && error) api->free_string (error); g_free (user); g_free (cache); return 2;
    }
  CHECK (glims_engine_call (engine, success_cases, NULL) == GLIMS_STATUS_OK, "Restore success fixtures execute on engine worker");
  CHECK (glims_engine_call (engine, refusal_cases, NULL) == GLIMS_STATUS_OK, "Restore refusal fixtures execute on engine worker");
  public_cases (engine);
  modern_cases (engine, argv[1]);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

/* Additional modern-source oracles. Everything above retains the original
 * 109 assertions; only the declaration/call adds this separate source phase. */
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplink.h"
#include "core/gimplinklayer.h"
#include "core/gimprasterizable.h"
#include "path/gimpvectorlayer.h"

static gchar *
modern_pixels (GimpLayer *layer, gboolean offsets)
{
  GString *state = g_string_new (NULL);
  gint x = 0, y = 0;
  if (offsets) gimp_item_get_offset (GIMP_ITEM (layer), &x, &y);
  g_string_append_printf (state, "%d,%d,%d,%d;", x, y,
                          gimp_item_get_width (GIMP_ITEM (layer)),
                          gimp_item_get_height (GIMP_ITEM (layer)));
  append_pixels (state, GIMP_DRAWABLE (layer), FALSE);
  gchar *digest = g_compute_checksum_for_data (G_CHECKSUM_SHA256,
                                               (const guchar *) state->str, state->len);
  g_string_free (state, TRUE);
  return digest;
}

static gboolean
modern_pixels_match (GimpLayer *layer, const gchar *expected, gboolean offsets)
{
  gchar *actual = modern_pixels (layer, offsets);
  gboolean equal = actual && expected && !strcmp (actual, expected);
  g_free (actual); return equal;
}

/* Compare the retained link input separately from its displayed drawable.
 * The independent single-Core reference proves Redo reloads that input before
 * drawable-mod Undo reinstalls the previous restored drawable and mask. */
static gboolean
modern_retained_pixels_match (GimpLayer *layer, const gchar *expected)
{
  GeglBuffer *buffer = gimp_link_get_buffer (gimp_link_layer_get_link (GIMP_LINK_LAYER (layer)));
  if (!buffer) return FALSE;
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  if (extent->x || extent->y || extent->width <= 0 || extent->height <= 0) return FALSE;
  GString *state = g_string_new (NULL);
  g_string_append_printf (state, "0,0,%d,%d;", extent->width, extent->height);
  gsize length = (gsize) extent->width * extent->height * 4;
  guint8 *pixels = g_malloc (length);
  gegl_buffer_get (buffer, extent, 1, babl_format ("R'G'B'A u8"), pixels,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  g_string_append_len (state, (const gchar *) pixels, length);
  gchar *actual = g_compute_checksum_for_data (G_CHECKSUM_SHA256,
                                               (const guchar *) state->str, state->len);
  gboolean equal = actual && expected && !strcmp (actual, expected);
  g_free (actual); g_free (pixels); g_string_free (state, TRUE); return equal;
}

/* Topology excludes legitimate regeneration geometry/name changes. */
static gchar *
modern_topology (GimpImage *image)
{
  GString *state = g_string_new (NULL);
  GList *rows = gimp_image_get_layer_list (image); /* Owned nodes. */
  for (GList *it = rows; it; it = it->next)
    {
      GimpLayer *layer = it->data, *parent = gimp_layer_get_parent (layer);
      GimpLayerMask *mask = gimp_layer_get_mask (layer);
      g_string_append_printf (state, "%d,%d,%d,%d;", item_id (layer),
                              parent ? item_id (parent) : 0, gimp_item_get_index (GIMP_ITEM (layer)),
                              mask ? item_id (mask) : 0);
    }
  g_list_free (rows);
  for (GList *it = gimp_image_get_selected_layers (image); it; it = it->next)
    g_string_append_printf (state, "selected:%d;", item_id (it->data)); /* Borrowed. */
  for (GList *it = gimp_image_get_selected_channels (image); it; it = it->next)
    g_string_append_printf (state, "channel:%d;", item_id (it->data)); /* Borrowed. */
  gchar *digest = g_compute_checksum_for_string (G_CHECKSUM_SHA256, state->str, state->len);
  g_string_free (state, TRUE); return digest;
}

static gboolean
modern_topology_matches (GimpImage *image, const gchar *expected)
{
  gchar *actual = modern_topology (image);
  gboolean equal = actual && expected && !strcmp (actual, expected);
  g_free (actual); return equal;
}

static gboolean
modern_source_states (GlimsEngine *engine, GlimsImageID image,
                      const GlimsItemID ids[3], gboolean text, gboolean link, gboolean vector)
{
  const uint32_t kinds[] = { GLIMS_LAYER_TEXT, GLIMS_LAYER_LINK, GLIMS_LAYER_VECTOR };
  const gboolean rasterized[] = { text, link, vector };
  for (guint i = 0; i < 3; i++)
    {
      GlimsLayerSourceInfo info = { .struct_size = sizeof info };
      if (api->layer_source_info (engine, image, ids[i], &info, NULL) != GLIMS_STATUS_OK ||
          info.source_kind != kinds[i] || !info.has_source || info.is_rasterized != rasterized[i])
        return FALSE;
    }
  return TRUE;
}

static gboolean
modern_source_identity (GimpLayer *link, GimpLayer *vector, GlimsItemID path, const gchar *filename)
{
  GimpPath *retained_path = gimp_vector_layer_get_path (GIMP_VECTOR_LAYER (vector));
  GimpLink *retained_link = gimp_link_layer_get_link (GIMP_LINK_LAYER (link));
  GFile *file = retained_link ? gimp_link_get_file (retained_link, NULL, NULL) : NULL;
  GFile *expected = g_file_new_for_path (filename);
  gboolean equal = retained_path && item_id (retained_path) == path && file && g_file_equal (file, expected);
  g_object_unref (expected); return equal;
}

/* Export a known asymmetric opaque pattern, then load that PNG independently
 * as a normal image. The expected digest never comes from Restore or a link. */
static GlimsStatus
modern_export_reference (GlimsEngine *engine, const gchar *filename, gint width, gint height,
                          guint seed, GlimsImageID *scratch, GlimsImageID *reference,
                          gchar **expected, char **error)
{
  GlimsStatus status = api->image_new (engine, width, height, scratch, error);
  if (status != GLIMS_STATUS_OK) return status;
  GimpImage *image = glims_lookup_image (engine, *scratch)->image;
  GList *rows = gimp_image_get_layer_list (image);
  GimpLayer *layer = rows ? rows->data : NULL;
  g_list_free (rows);
  if (!layer) return GLIMS_STATUS_FAILED;
  guint8 *bytes = g_malloc ((gsize) width * height * 4);
  for (gint y = 0; y < height; y++) for (gint x = 0; x < width; x++)
    {
      guint8 *pixel = bytes + ((gsize) y * width + x) * 4;
      pixel[0] = 20 + (x * 17 + y * 3 + seed) % 210;
      pixel[1] = 30 + (x * 5 + y * 23 + seed) % 200;
      pixel[2] = 40 + (x * 11 + y * 7 + seed) % 190; pixel[3] = 255;
    }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)),
                   GEGL_RECTANGLE (0, 0, width, height), 0, babl_format ("R'G'B'A u8"),
                   bytes, GEGL_AUTO_ROWSTRIDE);
  g_free (bytes); gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, width, height);
  gimp_image_flush (image);
  status = api->image_export (engine, *scratch, filename, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = api->image_close (engine, *scratch);
  if (status != GLIMS_STATUS_OK) return status;
  *scratch = 0;
  status = api->image_open (engine, filename, reference, error);
  if (status != GLIMS_STATUS_OK) return status;
  image = glims_lookup_image (engine, *reference)->image;
  rows = gimp_image_get_layer_list (image); layer = rows ? rows->data : NULL;
  g_list_free (rows);
  if (!layer) return GLIMS_STATUS_FAILED;
  g_free (*expected); *expected = modern_pixels (layer, FALSE);
  status = api->image_close (engine, *reference);
  if (status == GLIMS_STATUS_OK) *reference = 0;
  return *expected ? status : GLIMS_STATUS_FAILED;
}

static GlimsStatus
modern_sources_worker (GlimsEngine *engine, gpointer work)
{
  /* Only this pre-admission entry may be retried by the host. Returning BUSY
   * lets an already-running monitor loader's outer loop actually unwind. */
  if (engine->busy) return GLIMS_STATUS_BUSY;
  GlimsImageID id = 0, scratch = 0, reference = 0;
  GlimsStrokeID stroke = 0;
  GlimsItemID path = 0, vector_id = 0, link_id = 0, mask_id = 0;
  char *error = NULL;
  gchar *file = g_build_filename (work, "batch-restore-current.png", NULL);
  gchar *link_v1 = NULL, *link_v2 = NULL, *link_v3 = NULL;
  gchar *text_source = NULL, *vector_source = NULL, *topology = NULL;
  gchar *damaged_text = NULL, *damaged_link = NULL, *damaged_vector = NULL, *noop = NULL;
  gchar *mixed_text = NULL, *mixed_link = NULL, *mixed_vector = NULL;
  gchar *changed_text = NULL, *changed_link = NULL, *changed_vector = NULL, *missing_damage = NULL;
  gchar *painted_link = NULL;
  NEED (modern_export_reference (engine, file, 17, 9, 13, &scratch, &reference, &link_v1, &error) == GLIMS_STATUS_OK,
        "modern link source PNG has an independent normal-image pixel oracle");
  NEED (api->image_new (engine, 32, 24, &id, &error) == GLIMS_STATUS_OK, "mixed modern source image starts");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *group = gimp_group_layer_new (image);
  NEED (group && gimp_image_add_layer (image, group, NULL, 0, FALSE), "modern source fixture has a real parent group");
  GimpLayer *text = add_text (engine, image, group, "T", 2, 3);
  GlimsSubpath subpath = { .count = 4, .closed = TRUE };
  GlimsPathPoint points[] = {
    { {3, 3}, {3, 3}, {3, 3} }, { {12, 3}, {12, 3}, {12, 3} },
    { {12, 10}, {12, 10}, {12, 10} }, { {3, 10}, {3, 10}, {3, 10} }
  };
  NEED (text && api->path_set (engine, id, 0, "Retained shape", &subpath, 1, points, 4, &path, &error) == GLIMS_STATUS_OK &&
        api->path_to_vector_layer (engine, id, path, "Retained vector", &vector_id, &error) == GLIMS_STATUS_OK && vector_id,
        "installed modern engine creates a genuine vector from the explicit closed native path");
  NEED (api->image_place_link (engine, id, file, &link_id, &error) == GLIMS_STATUS_OK && link_id,
        "installed modern engine creates a genuine monitored linked layer from the known PNG");
  GimpLayer *link = GIMP_LAYER (gimp_item_get_by_id (engine->gimp, link_id));
  GimpLayer *vector = GIMP_LAYER (gimp_item_get_by_id (engine->gimp, vector_id));
  GlimsItemID ids[] = { item_id (text), link_id, vector_id };
  NEED (api->layer_mask_add (engine, id, link_id, GLIMS_MASK_WHITE, FALSE, &mask_id, &error) == GLIMS_STATUS_OK,
        "linked source owns a real mask before regeneration geometry changes");
  GList *selected = g_list_append (NULL, vector);
  selected = g_list_append (selected, text); selected = g_list_append (selected, link);
  gimp_image_set_selected_layers (image, selected); g_list_free (selected);
  GList *actual = gimp_image_get_selected_layers (image); /* Borrowed. */
  CHECK (actual && actual->data == vector && actual->next && actual->next->data == text &&
         actual->next->next && actual->next->next->data == link && !actual->next->next->next,
         "modern native selected order intentionally differs from captured text/link/vector order");
  CHECK (modern_source_states (engine, id, ids, FALSE, FALSE, FALSE) &&
         modern_source_identity (link, vector, path, file) && modern_pixels_match (link, link_v1, FALSE),
         "actual native source predicates, retained path/file and independent linked PNG pixels are established");
  topology = modern_topology (image);
  text_source = modern_pixels (text, FALSE); vector_source = modern_pixels (vector, FALSE);
  NEED (text_source && vector_source && topology && gimp_item_get_width (GIMP_ITEM (vector)) > 0 &&
        gimp_item_get_height (GIMP_ITEM (vector)) > 0 &&
        glims_layer_rasterize (image, text, &error) == GLIMS_STATUS_OK &&
        glims_layer_rasterize (image, link, &error) == GLIMS_STATUS_OK &&
        glims_layer_rasterize (image, vector, &error) == GLIMS_STATUS_OK,
        "all three real structured sources rasterize while their original native pixel oracles remain independent");
  damage (text, 31); damage (link, 79); damage (vector, 113); gimp_image_flush (image); gimp_image_clean_all (image);
  damaged_text = modern_pixels (text, TRUE); damaged_link = modern_pixels (link, TRUE);
  damaged_vector = modern_pixels (vector, TRUE);
  CHECK (modern_source_states (engine, id, ids, TRUE, TRUE, TRUE) &&
         !modern_pixels_match (text, text_source, FALSE) && !modern_pixels_match (link, link_v1, FALSE) &&
         !modern_pixels_match (vector, vector_source, FALSE),
         "every mixed member has demonstrably damaged pixels and an actual retained raster source");
  GlimsUndoInfo before = {0}, after = {0};
  NEED (api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        api->image_restore_layer_sources (engine, id, ids, 3, &error) == GLIMS_STATUS_OK,
        "one captured text/link/vector batch restores all modern sources");
  CHECK (modern_source_states (engine, id, ids, FALSE, FALSE, FALSE) && modern_source_identity (link, vector, path, file),
         "modern Restore returns real editability and retains the same path/file association");
  CHECK (modern_pixels_match (text, text_source, FALSE) && modern_pixels_match (vector, vector_source, FALSE) &&
         modern_pixels_match (link, link_v1, FALSE) && modern_topology_matches (image, topology),
         "mixed Restore regenerates each independent native source and preserves IDs/tree/mask attachment/ordered selection");
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1 &&
         engine->busy == 0 && !gimp_image_get_undo_group_count (image),
         "mixed modern regeneration shares exactly one balanced Undo and releases busy");
  noop = fingerprint (engine, id, TRUE, TRUE);
  CHECK (api->image_restore_layer_sources (engine, id, ids, 3, &error) == GLIMS_STATUS_OK &&
         matches (engine, id, noop, TRUE, TRUE), "all three editable modern sources form a full native history/dirty no-op");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "modern mixed Restore undoes once");
  CHECK (modern_pixels_match (text, damaged_text, TRUE) && modern_pixels_match (link, damaged_link, TRUE) &&
         modern_pixels_match (vector, damaged_vector, TRUE) && modern_topology_matches (image, topology) &&
         modern_source_states (engine, id, ids, TRUE, TRUE, TRUE) &&
         !gimp_image_is_dirty (image), "one modern Undo returns exact damaged buffers, source states, selection and clean mark");
  NEED (api->image_redo (engine, id) == GLIMS_STATUS_OK, "modern mixed Restore redoes once");
  CHECK (modern_pixels_match (text, text_source, FALSE) && modern_pixels_match (vector, vector_source, FALSE) &&
         modern_pixels_match (link, link_v1, FALSE) && modern_source_states (engine, id, ids, FALSE, FALSE, FALSE),
         "unchanged-file Redo regenerates all three independently established native sources");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK &&
        glims_layer_restore_source (image, text, &error) == GLIMS_STATUS_OK,
        "modern mixed-no-op fixture leaves text editable and link/vector damaged");
  mixed_text = modern_pixels (text, TRUE); mixed_link = modern_pixels (link, TRUE);
  mixed_vector = modern_pixels (vector, TRUE);
  NEED (api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        api->image_restore_layer_sources (engine, id, ids, 3, &error) == GLIMS_STATUS_OK,
        "editable text plus two rasterized modern members restores as one batch");
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1 &&
         modern_pixels_match (text, text_source, FALSE) && modern_pixels_match (vector, vector_source, FALSE) &&
         modern_pixels_match (link, link_v1, FALSE), "mixed modern no-op/changed members add only one Undo and regenerate exact source pixels");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "mixed modern no-op batch undoes once");
  CHECK (modern_pixels_match (text, mixed_text, TRUE) && modern_pixels_match (link, mixed_link, TRUE) &&
         modern_pixels_match (vector, mixed_vector, TRUE) && modern_topology_matches (image, topology) &&
         modern_source_states (engine, id, ids, FALSE, TRUE, TRUE),
         "mixed modern Undo changes only members that needed restoration");

  /* The link is frozen here. Rewrite the actual file to new dimensions and
   * independently open it, rather than assuming retained bytes are current. */
  changed_text = modern_pixels (text, TRUE); changed_link = modern_pixels (link, TRUE);
  changed_vector = modern_pixels (vector, TRUE);
  NEED (modern_export_reference (engine, file, 11, 7, 83, &scratch, &reference, &link_v2, &error) == GLIMS_STATUS_OK,
        "a changed-size second PNG is independently loaded while the target link stays rasterized");
  NEED (api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        api->image_restore_layer_sources (engine, id, ids, 3, &error) == GLIMS_STATUS_OK,
        "captured mixed Restore reloads the current changed external file");
  GimpLayerMask *mask = gimp_layer_get_mask (link);
  CHECK (modern_pixels_match (link, link_v2, FALSE) && !modern_pixels_match (link, link_v1, FALSE) &&
         gimp_item_get_width (GIMP_ITEM (link)) == 11 && gimp_item_get_height (GIMP_ITEM (link)) == 7,
         "restored link uses current second-file bytes and dimensions, not the retained first-file snapshot");
  CHECK (mask && item_id (mask) == mask_id && gimp_item_get_width (GIMP_ITEM (mask)) == 11 &&
         gimp_item_get_height (GIMP_ITEM (mask)) == 7 && modern_topology_matches (image, topology),
         "native link regeneration preserves attachment/ordered topology while legitimately resizing its mask");
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1 &&
         modern_source_states (engine, id, ids, FALSE, FALSE, FALSE) && modern_source_identity (link, vector, path, file),
         "changed-file regeneration remains one Undo with actual retained editable source identities");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "changed-file modern Restore undoes once");
  CHECK (modern_pixels_match (text, changed_text, TRUE) && modern_pixels_match (link, changed_link, TRUE) &&
         modern_pixels_match (vector, changed_vector, TRUE) && modern_source_states (engine, id, ids, FALSE, TRUE, TRUE),
         "changed-file Undo restores exact previous damaged buffers/offsets and mixed raster states");
  NEED (modern_export_reference (engine, file, 13, 8, 151, &scratch, &reference, &link_v3, &error) == GLIMS_STATUS_OK,
        "the frozen link's file changes a third time before Redo");
  NEED (api->image_redo (engine, id) == GLIMS_STATUS_OK, "changed-file modern Restore redoes once");
  CHECK (modern_pixels_match (link, link_v2, FALSE) && !modern_pixels_match (link, link_v3, FALSE) &&
         modern_retained_pixels_match (link, link_v3) &&
         gimp_item_get_width (GIMP_ITEM (link)) == 11 && gimp_item_get_height (GIMP_ITEM (link)) == 7 &&
         mask && item_id (mask) == mask_id && gimp_item_get_width (GIMP_ITEM (mask)) == 11 &&
         gimp_item_get_height (GIMP_ITEM (mask)) == 7 &&
         modern_source_states (engine, id, ids, FALSE, FALSE, FALSE) && modern_topology_matches (image, topology),
         "native Redo retains current third-file input but restores saved second-file drawable/mask, matching direct Core Undo ordering");

  /* A real paint stroke stops monitoring without setting the generic
   * rasterizable flag. This exercises the existing alternate link Restore
   * path without manufacturing private flags or incomplete GObjects. */
  gint link_x, link_y;
  gimp_item_get_offset (GIMP_ITEM (link), &link_x, &link_y);
  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PENCIL,
    .size = 3, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint first = { link_x + 2, link_y + 2, 1, 0, 0, 0 };
  GlimsStrokePoint last = { link_x + 9, link_y + 4, 1, 0, 0, 16 };
  NEED (api->stroke_begin (engine, id, link_id, &brush, &first, &stroke, &error) == GLIMS_STATUS_OK &&
        api->stroke_continue (engine, stroke, &last, 1) == GLIMS_STATUS_OK &&
        api->stroke_end (engine, stroke) == GLIMS_STATUS_OK,
        "a real native stroke edits the monitored link without explicit rasterization"); stroke = 0;
  painted_link = modern_pixels (link, TRUE);
  g_free (topology); topology = modern_topology (image);
  CHECK (modern_source_states (engine, id, ids, FALSE, TRUE, FALSE) &&
         !gimp_rasterizable_is_rasterized (GIMP_RASTERIZABLE (link)) &&
         !modern_pixels_match (link, link_v3, FALSE),
         "painted link genuinely stops monitoring with generic flag false and changed native pixels");
  NEED (api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        api->image_restore_layer_sources (engine, id, ids, 3, &error) == GLIMS_STATUS_OK,
        "mixed batch restores the actual unmonitored flag-false link path");
  CHECK (modern_pixels_match (link, link_v3, FALSE) && modern_source_states (engine, id, ids, FALSE, FALSE, FALSE) &&
         modern_topology_matches (image, topology) && api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK &&
         after.undo_count == before.undo_count + 1,
         "painted-link Restore regenerates current file in one Undo while preserving post-stroke ordered topology");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "painted-link mixed Restore undoes once");
  CHECK (modern_pixels_match (link, painted_link, TRUE) && modern_source_states (engine, id, ids, FALSE, TRUE, FALSE) &&
         !gimp_rasterizable_is_rasterized (GIMP_RASTERIZABLE (link)),
         "painted-link Undo returns exact painted pixels and actual unmonitored flag-false state");
  NEED (api->image_redo (engine, id) == GLIMS_STATUS_OK, "painted-link mixed Restore redoes once");
  CHECK (modern_pixels_match (link, link_v3, FALSE) && modern_source_states (engine, id, ids, FALSE, FALSE, FALSE) &&
         modern_source_identity (link, vector, path, file) && modern_topology_matches (image, topology),
         "painted-link Redo restores the current source and its real monitored/editable state");

  NEED (glims_layer_rasterize (image, link, &error) == GLIMS_STATUS_OK, "missing-file fixture freezes the genuine retained link");
  damage (link, 197); gimp_image_flush (image);
  missing_damage = modern_pixels (link, TRUE);
  NEED (remove (file) == 0, "the retained link file is genuinely removed before Restore");
  NEED (api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK &&
        api->image_restore_layer_sources (engine, id, ids, 3, &error) == GLIMS_STATUS_OK,
        "missing-file mixed Restore uses native retained-buffer semantics without a fabricated file preflight");
  CHECK (modern_pixels_match (link, link_v3, FALSE) && modern_source_states (engine, id, ids, FALSE, FALSE, FALSE) &&
         modern_source_identity (link, vector, path, file) && modern_topology_matches (image, topology) &&
         api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
         "missing-file Restore remonitors the retained source, restores last loaded native bytes and adds one Undo");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "missing-file mixed Restore undoes once");
  CHECK (modern_pixels_match (link, missing_damage, TRUE) && modern_pixels_match (text, text_source, FALSE) &&
         modern_pixels_match (vector, vector_source, FALSE) && modern_topology_matches (image, topology) &&
         modern_source_states (engine, id, ids, FALSE, TRUE, FALSE),
         "missing-file Undo restores exact damaged link pixels and its retained raster state");
  NEED (api->image_redo (engine, id) == GLIMS_STATUS_OK, "missing-file mixed Restore redoes once");
  CHECK (modern_pixels_match (link, link_v3, FALSE) && modern_source_states (engine, id, ids, FALSE, FALSE, FALSE),
         "missing-file Redo uses the surviving native source buffer again");
  g_free (noop); noop = fingerprint (engine, id, TRUE, TRUE);
  CHECK (api->image_restore_layer_sources (engine, id, ids, 3, &error) == GLIMS_STATUS_OK &&
         matches (engine, id, noop, TRUE, TRUE), "already-editable modern no-op does not stat a missing file or change history/dirty state");
cleanup:
  if (error) fprintf (stderr, "modern source fixture: %s\n", error);
  clear_error (&error);
  if (stroke) api->stroke_end (engine, stroke);
  if (reference) api->image_close (engine, reference);
  if (scratch) api->image_close (engine, scratch);
  if (id) CHECK (api->image_close (engine, id) == GLIMS_STATUS_OK, "modern fixture closes its monitored/Undo-owned image");
  remove (file); g_free (file);
  g_free (link_v1); g_free (link_v2); g_free (link_v3); g_free (text_source); g_free (vector_source);
  g_free (topology); g_free (damaged_text); g_free (damaged_link); g_free (damaged_vector); g_free (noop);
  g_free (mixed_text); g_free (mixed_link); g_free (mixed_vector);
  g_free (changed_text); g_free (changed_link); g_free (changed_vector); g_free (missing_damage);
  g_free (painted_link);
  return GLIMS_STATUS_OK;
}
#else
static GlimsStatus
legacy_source_capabilities (GlimsEngine *engine, gpointer work)
{
  (void) work;
  if (engine->busy) return GLIMS_STATUS_BUSY;
  GlimsImageID id = 0; GlimsItemID path = 0, vector = 0, link = 0; char *error = NULL;
  gchar *before = NULL;
  GlimsSubpath subpath = { .count = 4, .closed = TRUE };
  GlimsPathPoint points[] = {
    { {3, 3}, {3, 3}, {3, 3} }, { {12, 3}, {12, 3}, {12, 3} },
    { {12, 10}, {12, 10}, {12, 10} }, { {3, 10}, {3, 10}, {3, 10} }
  };
  NEED (api->image_new (engine, 32, 24, &id, &error) == GLIMS_STATUS_OK &&
        api->path_set (engine, id, 0, "Legacy path", &subpath, 1, points, 4, &path, &error) == GLIMS_STATUS_OK,
        "legacy source capability fixture has a real path and image");
  before = fingerprint (engine, id, TRUE, TRUE);
  CHECK (api->path_to_vector_layer (engine, id, path, "Vector", &vector, &error) == GLIMS_STATUS_UNSUPPORTED &&
         vector == 0 && matches (engine, id, before, TRUE, TRUE),
         "legacy engine explicitly refuses vector capability without changing native image/history"); clear_error (&error);
  CHECK (api->image_place_link (engine, id, "not-loaded-on-legacy.png", &link, &error) == GLIMS_STATUS_UNSUPPORTED &&
         link == 0 && matches (engine, id, before, TRUE, TRUE),
         "legacy engine explicitly refuses linked capability rather than treating modern scenarios as passed");
cleanup:
  clear_error (&error); g_free (before); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}
#endif

static void
modern_cases (GlimsEngine *engine, const gchar *work)
{
  gint major = 0, minor = 0;
  gboolean parsed = sscanf (api->engine_version (engine), "%d.%d", &major, &minor) == 2;
#if GIMP_CHECK_VERSION (3, 2, 0)
  CHECK (parsed && (major > 3 || (major == 3 && minor >= 2)), "modern fixture headers match the loaded engine capability family");
  if (!parsed || (major == 3 && minor < 2) || major < 3) return;
#else
  CHECK (parsed && major == 3 && minor < 2, "legacy fixture headers match the loaded engine capability family");
  if (!parsed || major != 3 || minor >= 2) return;
#endif
  GlimsStatus status;
  gint64 end = g_get_monotonic_time () + 10 * G_TIME_SPAN_SECOND;
  do
    {
#if GIMP_CHECK_VERSION (3, 2, 0)
      status = glims_engine_call (engine, modern_sources_worker, (gpointer) work);
#else
      status = glims_engine_call (engine, legacy_source_capabilities, (gpointer) work);
#endif
      if (status == GLIMS_STATUS_BUSY) g_usleep (10000);
    }
  while (status == GLIMS_STATUS_BUSY && g_get_monotonic_time () < end);
  CHECK (status == GLIMS_STATUS_OK, "additional source fixtures execute on the engine worker after any prior loader drains");
}

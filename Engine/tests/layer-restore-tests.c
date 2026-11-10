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
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

/* Private Core fixtures; every native access runs on glims_engine_call's worker.
 * Public slot146 calls at the end deliberately originate on the host thread. */
#include "engine-private.h"
#include "layer-delete.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpdrawable-filters.h"
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
static int failures;
static const gchar *diagnostic_dir;
static gchar *last_description;
#define CHECK(c, message) do { gboolean check_ok_ = (c); printf ("%s %s\n", check_ok_ ? "ok  " : "FAIL", message); if (!check_ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, message) do { gboolean need_ok_ = (c); CHECK (need_ok_, message); if (!need_ok_) goto cleanup; } while (0)

static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }
static GlimsItemID item_id (gpointer item) { return gimp_item_get_id (GIMP_ITEM (item)); }

static GimpLayer *
only_layer (GimpImage *image)
{
  GList *rows = gimp_image_get_layer_list (image);
  GimpLayer *layer = rows && !rows->next ? rows->data : NULL;
  g_list_free (rows);
  return layer; /* Borrowed; the image owns it. */
}

static GimpLayer *
add_layer (GimpImage *image, GimpLayer *parent, const char *name, guint color)
{
  GimpLayer *layer = gimp_layer_new (image, 8, 8, gimp_image_get_layer_format (image, TRUE),
                                    name, 1.0, GIMP_LAYER_MODE_NORMAL);
  guint8 pixels[8 * 8 * 4];
  for (guint i = 0; i < sizeof pixels; i += 4) {
    pixels[i] = color == 0 ? 255 : 0;
    pixels[i + 1] = color == 1 ? 255 : 0;
    pixels[i + 2] = color == 2 ? 255 : 0;
    pixels[i + 3] = 255;
  }
  if (!layer) return NULL;
  if (!gimp_image_add_layer (image, layer, parent, 0, FALSE)) {
    g_object_unref (layer);
    return NULL;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)), GEGL_RECTANGLE (0, 0, 8, 8),
                   0, babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, 8, 8);
  return layer; /* Image owns the floating construction reference. */
}

static gboolean
select_exact (GimpImage *image, GimpLayer **layers, guint count)
{
  GList *list = NULL;
  for (guint i = 0; i < count; i++) list = g_list_append (list, layers[i]);
  gimp_image_set_selected_layers (image, list);
  g_list_free (list);
  GList *selected = gimp_image_get_selected_layers (image); /* BORROWED */
  for (guint i = 0; i < count; i++, selected = selected->next)
    if (!selected || selected->data != layers[i]) return FALSE;
  return selected == NULL;
}

static gboolean
selection_is (GimpImage *image, const GlimsItemID *ids, guint count)
{
  GList *selected = gimp_image_get_selected_layers (image); /* BORROWED */
  for (guint i = 0; i < count; i++, selected = selected->next)
    if (!selected || item_id (selected->data) != ids[i]) return FALSE;
  return selected == NULL;
}

static void
append_pixels (GString *state, GimpDrawable *drawable, GString *description)
{
  gint w = gimp_item_get_width (GIMP_ITEM (drawable)), h = gimp_item_get_height (GIMP_ITEM (drawable));
  g_string_append_printf (state, "pixels:%d,%d;", w, h);
  if (w > 0 && h > 0) {
    gsize size = (gsize) w * h * 4;
    guint8 *bytes = g_malloc (size);
    if (w == 1 && h == 1) {
      /* GEGL's 1x1 fast path can reuse a hot tile without consulting the
       * validate handler. Force the ordinary tiled path, then compare
       * exactly the same logical pixel, including its alpha and RGB. */
      guint8 pair[8] = {0};
      gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, 2, 1),
                       1, babl_format ("R'G'B'A u8"), pair, 8, GEGL_ABYSS_NONE);
      memcpy (bytes, pair, 4);
    } else {
      gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, w, h),
                       1, babl_format ("R'G'B'A u8"), bytes, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    }
    g_string_append_len (state, (const gchar *) bytes, size);
    gchar *hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, bytes, size);
    g_string_append_printf (description, " pixels=%dx%d hash=%s first=%u,%u,%u,%u\n",
                            w, h, hash, bytes[0], bytes[1], bytes[2], bytes[3]);
    g_free (hash);
    g_free (bytes);
  }
}

static void
save_diagnostic (guint sequence, const gchar *stage)
{
  gchar *name = g_strdup_printf ("delete-%u-%s.txt", sequence, stage);
  gchar *path = g_build_filename (diagnostic_dir, name, NULL);
  if (!g_file_set_contents (path, last_description ? last_description : "snapshot failed\n", -1, NULL))
    fprintf (stderr, "could not write diagnostic %s\n", path);
  g_free (path); g_free (name);
}

/* All pixels, IDs, topology, properties, masks, effects, selection, Artist and
 * image facts. Refusal fingerprints additionally include the complete UndoInfo.
 * Undo/Redo comparisons omit history itself because the redo stack must differ. */
static gchar *
fingerprint (GlimsEngine *engine, GlimsImageID id, gboolean history)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsImageInfo info = {0}; GlimsUndoInfo undo = {0};
  if (!open || api->image_info (engine, id, &info) != GLIMS_STATUS_OK ||
      api->image_undo_info (engine, id, &undo) != GLIMS_STATUS_OK) return NULL;
  GString *state = g_string_new (NULL);
  GString *description = g_string_new (NULL);
  if (history) {
    g_string_append_len (state, (const gchar *) &info, sizeof info);
    g_string_append_len (state, (const gchar *) &undo, sizeof undo);
  }
  GList *rows = gimp_image_get_layer_list (open->image);
  for (GList *it = rows; it; it = it->next) {
    GimpLayer *layer = it->data, *parent = gimp_layer_get_parent (layer);
    GimpItem *item = GIMP_ITEM (layer); gint x, y;
    GlimsMaskState mask = {0}; GlimsEffectInfo effects[8] = {{0}}; int32_t n = 0;
    gimp_item_get_offset (item, &x, &y);
    g_string_append_printf (state, "%d/%d/%d:%s:%d,%d:%.17g:%d,%d,%d,%d;",
      item_id (layer), parent ? item_id (parent) : 0, gimp_item_get_index (item),
      gimp_object_get_name (layer), x, y, gimp_layer_get_opacity (layer),
      gimp_item_get_visible (item), gimp_item_get_lock_content (item),
      gimp_item_get_lock_position (item), gimp_layer_get_lock_alpha (layer));
    g_string_append_printf (description, "id=%d parent=%d index=%d type=%s name=%s offset=%d,%d opacity=%.17g visible=%d locks=%d,%d,%d",
      item_id (item), parent ? item_id (parent) : 0, gimp_item_get_index (item), G_OBJECT_TYPE_NAME (item),
      gimp_object_get_name (item), x, y, gimp_layer_get_opacity (layer), gimp_item_get_visible (item),
      gimp_item_get_lock_content (item), gimp_item_get_lock_position (item), gimp_layer_get_lock_alpha (layer));
    append_pixels (state, GIMP_DRAWABLE (layer), description);
    if (api->layer_mask (engine, id, item_id (layer), &mask) != GLIMS_STATUS_OK ||
        api->drawable_effects (engine, id, item_id (layer), effects, 8, &n) != GLIMS_STATUS_OK || n < 0 || n > 8) {
      g_list_free (rows); g_string_free (state, TRUE); g_string_free (description, TRUE); return NULL;
    }
    g_string_append_len (state, (const gchar *) &mask, sizeof mask);
    g_string_append_len (state, (const gchar *) &n, sizeof n);
    g_string_append_len (state, (const gchar *) effects, (gsize) n * sizeof *effects);
    g_string_append_printf (description, " mask=%d enabled=%d editing=%d showing=%d effects=%d\n",
                            mask.mask, mask.enabled, mask.editing, mask.showing, n);
    if (gimp_layer_get_mask (layer)) append_pixels (state, GIMP_DRAWABLE (gimp_layer_get_mask (layer)), description);
  }
  g_list_free (rows);
  g_string_append (description, "selection=");
  for (GList *it = gimp_image_get_selected_layers (open->image); it; it = it->next) {
    g_string_append_printf (state, "selected:%d;", item_id (it->data));
    g_string_append_printf (description, "%d,", item_id (it->data));
  }
  g_string_append_printf (description, " dirty=%d\nselection mask", gimp_image_is_dirty (open->image));
  append_pixels (state, GIMP_DRAWABLE (gimp_image_get_mask (open->image)), description);
  char **values = NULL; int32_t count = 0;
  if (api->image_metadata_values (engine, id, "Exif.Image.Artist", &values, &count, NULL) != GLIMS_STATUS_OK) {
    g_string_free (state, TRUE); g_string_free (description, TRUE); return NULL;
  }
  for (int32_t i = 0; i < count; i++) {
    g_string_append_len (state, values[i], strlen (values[i]) + 1);
    g_string_append_printf (description, "Artist[%d]=%s\n", i, values[i]);
  }
  api->free_metadata_strings (values);
  gchar *hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guchar *) state->str, state->len);
  g_string_free (state, TRUE);
  g_free (last_description); last_description = g_string_free (description, FALSE);
  return hash;
}

static void
refuses (GlimsEngine *engine, GlimsImageID image, const GlimsItemID *ids, size_t count,
         GlimsStatus expected, const char *label)
{
  gchar *before = fingerprint (engine, image, TRUE), *after;
  char *error = NULL;
  GlimsStatus result = glims_image_delete_layers (engine, image, ids, count, &error);
  after = fingerprint (engine, image, TRUE);
  CHECK (result == expected, label);
  CHECK (before && after && !strcmp (before, after), "refusal preserves captured native facts, topology, pixels, selection and history");
  clear_error (&error); g_free (before); g_free (after);
}

static gboolean
delete_cycle (GlimsEngine *engine, GlimsImageID id, const GlimsItemID *sources, guint count,
              const GlimsItemID *selected_after, guint selected_count, guint remaining,
              gboolean expect_empty_groups)
{
  static guint next_sequence;
  guint sequence = ++next_sequence;
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GlimsUndoInfo before = {0}, after = {0}; char *error = NULL;
  gimp_image_clean_all (image);
  gchar *original = fingerprint (engine, id, FALSE), *deleted = NULL;
  save_diagnostic (sequence, "before");
  gboolean ok = original && api->image_undo_info (engine, id, &before) == GLIMS_STATUS_OK;
  if (ok) ok = glims_image_delete_layers (engine, id, sources, count, &error) == GLIMS_STATUS_OK;
  CHECK (ok, "valid explicit batch deletes successfully");
  if (!ok) goto done;
  GList *rows = gimp_image_get_layer_list (image);
  CHECK (g_list_length (rows) == remaining && selection_is (image, selected_after, selected_count),
         "independent expected remaining count and ordered survivor selection match");
  for (guint i = 0; i < count; i++) {
    GimpItem *item = gimp_item_get_by_id (engine->gimp, sources[i]);
    CHECK (item && !gimp_item_is_attached (item), "each captured source ID is detached and retained by Undo");
  }
  g_list_free (rows);
  CHECK (api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
         "the whole batch adds exactly one native Undo step");
  deleted = fingerprint (engine, id, FALSE);
  save_diagnostic (sequence, "deleted");
  for (guint cycle = 0; cycle < 2; cycle++) {
    gchar *state;
    ok = api->image_undo (engine, id) == GLIMS_STATUS_OK;
    state = fingerprint (engine, id, FALSE);
    gchar *stage = g_strdup_printf ("undo-%u", cycle);
    save_diagnostic (sequence, stage); g_free (stage);
    CHECK (ok && state && !strcmp (original, state) && !gimp_image_is_dirty (image),
           "one Undo restores exact original IDs, parents, indices, every pixel, ordered selection and clean mark");
    g_free (state);
    if (!ok) break;
    ok = api->image_redo (engine, id) == GLIMS_STATUS_OK;
    if (expect_empty_groups) {
      /* This MUST precede the validating fingerprint read below: exercise
       * the public production thumbnail path against cold group caches. */
      GList *groups = gimp_image_get_layer_list (image); guint seen = 0;
      for (GList *it = groups; it; it = it->next) if (GIMP_IS_GROUP_LAYER (it->data)) {
        guint8 pixel[4] = { 0x66, 0x66, 0x66, 0x66 }; int32_t width = 0, height = 0;
        GlimsStatus status = api->drawable_thumbnail (engine, id, item_id (it->data), 8,
                                                     pixel, sizeof pixel, &width, &height);
        CHECK (status == GLIMS_STATUS_OK && width == 1 && height == 1 &&
               pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 0,
               "public empty-group thumbnail is 1x1 transparent before any tiled fingerprint read");
        if (status != GLIMS_STATUS_OK || width != 1 || height != 1 || pixel[0] || pixel[1] || pixel[2] || pixel[3])
          fprintf (stderr, "empty group %d public thumbnail status=%d size=%dx%d RGBA=%u,%u,%u,%u\n",
                   item_id (it->data), status, width, height, pixel[0], pixel[1], pixel[2], pixel[3]);
        seen++;
      }
      CHECK (seen == 2, "both independently known empty parent groups were checked");
      g_list_free (groups);
    }
    state = fingerprint (engine, id, FALSE);
    stage = g_strdup_printf ("redo-%u", cycle);
    save_diagnostic (sequence, stage); g_free (stage);
    CHECK (ok, "native Redo itself returns OK");
    CHECK (selection_is (image, selected_after, selected_count), "Redo preserves the independently expected survivor selection");
    CHECK (ok && deleted && state && !strcmp (deleted, state) && selection_is (image, selected_after, selected_count),
           "one Redo repeats the exact deletion and complete after-selection");
    g_free (state);
    if (!ok) break;
  }
done:
  clear_error (&error); g_free (original); g_free (deleted);
  return ok;
}

static GlimsStatus
ordinary_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; char *error = NULL; GimpImage *image;
  NEED (api->image_new (engine, 16, 16, &id, &error) == GLIMS_STATUS_OK, "ordinary fixture creates a native image");
  image = glims_lookup_image (engine, id)->image;
  GimpLayer *base = only_layer (image);
  NEED (base != NULL, "ordinary fixture has exactly one native background");
  GimpLayer *a = add_layer (image, NULL, "Red locked", 0), *c = add_layer (image, NULL, "Blue locked", 2);
  GimpLayer *d = add_layer (image, NULL, "Green survivor", 1);
  NEED (a && c && d, "independent red, blue and green sources are attached");
  guint8 red[4] = {0}, blue[4] = {0};
  gegl_buffer_get (gimp_drawable_get_buffer (GIMP_DRAWABLE (a)), GEGL_RECTANGLE (0, 0, 1, 1), 1, babl_format ("R'G'B'A u8"), red, 4, GEGL_ABYSS_NONE);
  gegl_buffer_get (gimp_drawable_get_buffer (GIMP_DRAWABLE (c)), GEGL_RECTANGLE (0, 0, 1, 1), 1, babl_format ("R'G'B'A u8"), blue, 4, GEGL_ABYSS_NONE);
  NEED (red[0] == 255 && red[1] == 0 && red[2] == 0 && red[3] == 255 && blue[0] == 0 && blue[1] == 0 && blue[2] == 255 && blue[3] == 255,
        "source pixels have independently expected opaque red and blue values");
  const char *artist[] = { "Batch deletion sentinel" };
  NEED (api->image_metadata_edit (engine, id, "Exif.Image.Artist", GLIMS_METADATA_SET, artist, 1, &error) == GLIMS_STATUS_OK,
        "unrelated native metadata fixture is installed");
  GlimsFilterID filter = 0;
  NEED (api->filter_begin (engine, id, item_id (d), "gegl:brightness-contrast", &filter, &error) == GLIMS_STATUS_OK &&
        api->filter_set_double (engine, filter, "brightness", 0.25) == GLIMS_STATUS_OK &&
        api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "surviving sibling owns a real committed effect");
  gimp_item_set_lock_content (GIMP_ITEM (a), TRUE, FALSE);
  gimp_item_set_lock_position (GIMP_ITEM (a), TRUE, FALSE); gimp_layer_set_lock_alpha (a, TRUE, FALSE);
  gimp_item_set_lock_position (GIMP_ITEM (c), TRUE, FALSE);
  gimp_item_set_lock_content (GIMP_ITEM (d), TRUE, FALSE);
  GimpLayer *selection[] = { c, d, a, base };
  NEED (select_exact (image, selection, 4), "selected input order deliberately differs from the captured source vector");
  GlimsItemID sources[] = { item_id (a), item_id (c) }, survivors[] = { item_id (d), item_id (base) };
  NEED (delete_cycle (engine, id, sources, 2, survivors, 2, 2, FALSE), "locked sources delete while sibling state and metadata survive Undo/Redo");
  NEED (api->image_undo (engine, id) == GLIMS_STATUS_OK, "restore sources for an entirely unselected-source request");
  GimpLayer *unrelated_selection[] = { d, base };
  NEED (select_exact (image, unrelated_selection, 2), "only surviving siblings are selected before the captured request");
  NEED (delete_cycle (engine, id, sources, 2, survivors, 2, 2, FALSE), "captured sources are deleted even when neither is currently selected");
  GimpLayer *effect_selection[] = { d };
  NEED (select_exact (image, effect_selection, 1), "committed-effect layer is selected");
  GlimsItemID effect_source[] = { item_id (d) }, effect_survivor[] = { item_id (base) };
  NEED (delete_cycle (engine, id, effect_source, 1, effect_survivor, 1, 1, FALSE), "a locked plain layer with a committed effect remains deletable");
cleanup:
  clear_error (&error); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
nested_and_empty (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; char *error = NULL;
  NEED (api->image_new (engine, 16, 16, &id, &error) == GLIMS_STATUS_OK, "nested fixture creates an image");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *outer = gimp_group_layer_new (image), *inner = gimp_group_layer_new (image);
  NEED (gimp_image_add_layer (image, outer, NULL, 0, FALSE) && gimp_image_add_layer (image, inner, outer, 0, FALSE), "nested actual parent groups are attached");
  GimpLayer *a = add_layer (image, outer, "Outer red", 0), *b = add_layer (image, inner, "Inner blue", 2);
  NEED (a && b, "plain leaves belong to distinct explicit parents");
  GimpLayer *selection[] = { b, a };
  NEED (select_exact (image, selection, 2), "all selected leaves will be removed");
  GlimsItemID sources[] = { item_id (a), item_id (b) }, fallback[] = { item_id (outer) };
  NEED (delete_cycle (engine, id, sources, 2, fallback, 1, 3, TRUE), "first surviving flat row is the group, never an unrelated active-parent sentinel");
  NEED (api->image_close (engine, id) == GLIMS_STATUS_OK, "nested fixture closes"); id = 0;
  NEED (api->image_new (engine, 16, 16, &id, &error) == GLIMS_STATUS_OK, "delete-all fixture creates one plain layer");
  image = glims_lookup_image (engine, id)->image;
  GimpLayer *base = only_layer (image);
  NEED (base != NULL, "delete-all fixture has exactly one native background");
  GlimsItemID only[] = { item_id (base) };
  NEED (select_exact (image, NULL, 0), "delete-all begins with a genuinely empty native selection");
  NEED (delete_cycle (engine, id, only, 1, NULL, 0, 0, FALSE), "delete all produces a truly empty image and round-trips empty selection");
cleanup:
  clear_error (&error); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
refusal_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0, foreign = 0; char *error = NULL;
  NEED (api->image_new (engine, 16, 16, &id, &error) == GLIMS_STATUS_OK && api->image_new (engine, 16, 16, &foreign, &error) == GLIMS_STATUS_OK,
        "refusal fixtures create two independent images");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *a = add_layer (image, NULL, "Refusal red", 0), *b = add_layer (image, NULL, "Stroke blue", 2);
  NEED (a && b, "refusal layers attach");
  GlimsItemID valid[] = { item_id (a) }, duplicate[] = { item_id (a), item_id (a) }, zero[] = { item_id (a), 0 }, negative[] = { -1 };
  GlimsItemID later_bad[] = { item_id (a), INT_MAX };
  refuses (engine, id, valid, 0, GLIMS_STATUS_INVALID_ARGUMENT, "zero count refuses");
  refuses (engine, id, valid, 257, GLIMS_STATUS_INVALID_ARGUMENT, "oversized count refuses before reading a one-item vector");
  refuses (engine, id, NULL, 1, GLIMS_STATUS_INVALID_ARGUMENT, "NULL vector refuses");
  refuses (engine, id, duplicate, 2, GLIMS_STATUS_INVALID_ARGUMENT, "duplicate IDs refuse before deleting the first source");
  refuses (engine, id, zero, 2, GLIMS_STATUS_INVALID_ARGUMENT, "later zero ID refuses atomically");
  refuses (engine, id, negative, 1, GLIMS_STATUS_INVALID_ARGUMENT, "negative ID refuses");
  refuses (engine, id, later_bad, 2, GLIMS_STATUS_NOT_FOUND, "later nonexistent ID refuses without deleting earlier valid source");
  GimpLayer *detached = add_layer (image, NULL, "Detached retained layer", 1);
  NEED (detached != NULL, "detached-layer fixture first attaches normally");
  GlimsItemID stale[] = { item_id (a), item_id (detached) };
  gimp_image_remove_layer (image, detached, TRUE, NULL);
  NEED (gimp_item_get_by_id (engine->gimp, stale[1]) && !gimp_item_is_attached (GIMP_ITEM (detached)),
        "Undo genuinely retains a detached same-image native layer");
  refuses (engine, id, stale, 2, GLIMS_STATUS_NOT_FOUND, "later detached but still live ID refuses atomically");
  GimpLayer *foreign_layer = only_layer (glims_lookup_image (engine, foreign)->image);
  NEED (foreign_layer != NULL, "foreign fixture has one actual background layer");
  GlimsItemID foreign_ids[] = { item_id (a), item_id (foreign_layer) };
  refuses (engine, id, foreign_ids, 2, GLIMS_STATUS_NOT_FOUND, "later foreign ID refuses atomically");
  NEED (api->image_close (engine, foreign) == GLIMS_STATUS_OK, "foreign fixture closes to produce a genuinely dead ID"); foreign = 0;
  refuses (engine, id, foreign_ids + 1, 1, GLIMS_STATUS_NOT_FOUND, "dead ID refuses");
  GlimsItemID nonlayer[] = { item_id (a), item_id (gimp_image_get_mask (image)) };
  refuses (engine, id, nonlayer, 2, GLIMS_STATUS_NOT_FOUND, "actual native selection-channel ID refuses after a valid source");
  GimpLayer *group = gimp_group_layer_new (image);
  NEED (gimp_image_add_layer (image, group, NULL, 0, FALSE), "actual group fixture attaches");
  GlimsItemID groups[] = { item_id (a), item_id (group) };
  refuses (engine, id, groups, 2, GLIMS_STATUS_UNSUPPORTED, "a later group refuses the whole vector");
  GimpText *text = g_object_new (GIMP_TYPE_TEXT, "text", "T", "font", gimp_context_get_font (gimp_get_user_context (engine->gimp)), "font-size", 8.0, NULL);
  GimpLayer *structured = gimp_text_layer_new (image, text); g_object_unref (text);
  NEED (structured && gimp_image_add_layer (image, structured, NULL, 0, FALSE), "genuine editable text fixture attaches");
  GlimsItemID texts[] = { item_id (a), item_id (structured) };
  refuses (engine, id, texts, 2, GLIMS_STATUS_UNSUPPORTED, "later editable text subclass refuses without rasterization");
  engine->busy++; refuses (engine, id, valid, 1, GLIMS_STATUS_BUSY, "global engine busy refuses"); engine->busy--;
  gimp_image_undo_freeze (image); refuses (engine, id, valid, 1, GLIMS_STATUS_BUSY, "frozen Undo refuses"); gimp_image_undo_thaw (image);
  gimp_image_undo_disable (image); refuses (engine, id, valid, 1, GLIMS_STATUS_BUSY, "disabled Undo refuses"); gimp_image_undo_enable (image);
  NEED (gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "Outer fixture"), "real outer Undo group starts");
  refuses (engine, id, valid, 1, GLIMS_STATUS_BUSY, "existing outer Undo group refuses"); gimp_image_undo_group_end (image);
  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PAINTBRUSH, .size = 4, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint point = { 2, 2, 1, 0, 0, 0 }; GlimsStrokeID stroke = 0;
  NEED (api->stroke_begin (engine, id, item_id (b), &brush, &point, &stroke, &error) == GLIMS_STATUS_OK, "real native stroke starts");
  refuses (engine, id, valid, 1, GLIMS_STATUS_BUSY, "active stroke refuses");
  NEED (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "stroke fixture ends");
  GlimsFilterID filter = 0;
  NEED (api->filter_begin (engine, id, item_id (b), "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK, "real native filter preview starts");
  refuses (engine, id, valid, 1, GLIMS_STATUS_BUSY, "active preview refuses");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "filter fixture aborts");
  GlimsSelectOptions options = { .struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE };
  GlimsPoint corners[] = { {0, 0}, {4, 4} };
  NEED (api->select_shape (engine, id, GLIMS_SHAPE_RECTANGLE, corners, 2, &options) == GLIMS_STATUS_OK,
        "a real rectangular selection is created");
  GlimsItemID floating = 0;
  NEED (api->selection_float (engine, id, item_id (b), GLIMS_FLOAT_COPY, &floating, &error) == GLIMS_STATUS_OK && floating > 0,
        "real floating selection attaches to the plain blue layer");
  refuses (engine, id, valid, 1, GLIMS_STATUS_BUSY, "unresolved floating selection refuses");
cleanup:
  clear_error (&error); if (foreign) api->image_close (engine, foreign); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
mask_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; char *error = NULL; GlimsItemID mask = 0;
  GeglNode *node = NULL;
  GimpDrawableFilter *filter = NULL;
  NEED (api->image_new (engine, 16, 16, &id, &error) == GLIMS_STATUS_OK, "mask fixture creates an image");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *a = add_layer (image, NULL, "Masked red", 0);
  NEED (a && api->layer_mask_add (engine, id, item_id (a), GLIMS_MASK_WHITE, FALSE, &mask, &error) == GLIMS_STATUS_OK,
        "ordinary native mask attaches");
  GlimsItemID source[] = { item_id (a) };
  node = gegl_node_new_child (NULL, "operation", "gegl:brightness-contrast", NULL);
  filter = gimp_drawable_filter_new (GIMP_DRAWABLE (gimp_layer_get_mask (a)), "Mask fixture", node, NULL);
  NEED (filter != NULL, "real mask filter constructs");
  gimp_drawable_filter_apply (filter, NULL);
  NEED (gimp_container_get_n_children (gimp_drawable_get_filters (GIMP_DRAWABLE (gimp_layer_get_mask (a)))) > 0,
         "mask filter is genuinely in the native drawable stack");
  refuses (engine, id, source, 1, GLIMS_STATUS_UNSUPPORTED, "mask with a live ND filter refuses atomically");
  gimp_drawable_filter_abort (filter); g_clear_object (&filter); g_clear_object (&node);
  GList *rows = gimp_image_get_layer_list (image); GimpLayer *base = g_list_last (rows)->data; g_list_free (rows);
  GimpLayer *selected[] = { a }; NEED (select_exact (image, selected, 1), "masked layer is explicitly selected");
  GlimsItemID survivor[] = { item_id (base) };
  NEED (delete_cycle (engine, id, source, 1, survivor, 1, 1, FALSE), "ordinary mask without live effects deletes and restores exactly");
cleanup:
  if (filter) { gimp_drawable_filter_abort (filter); g_object_unref (filter); }
  g_clear_object (&node);
  clear_error (&error); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

typedef struct { GlimsImageID image; gchar *digest; } ReadSnapshot;

static GlimsStatus
capacity_case (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; char *error = NULL;
  GlimsItemID sources[256]; GimpLayer *first = NULL, *last = NULL;
  NEED (api->image_new (engine, 16, 16, &id, &error) == GLIMS_STATUS_OK,
        "256-source boundary fixture creates an image");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *base = only_layer (image);
  NEED (base != NULL, "boundary fixture has exactly one native background");
  GlimsItemID survivor[] = { item_id (base) };
  for (guint i = 0; i < G_N_ELEMENTS (sources); i++) {
    gchar *name = g_strdup_printf ("Boundary %03u", i);
    GimpLayer *layer = add_layer (image, NULL, name, i % 3);
    g_free (name);
    NEED (layer != NULL, "boundary source attaches as a genuine plain layer");
    sources[i] = item_id (layer);
    if (!i) first = layer;
    last = layer;
  }
  GimpLayer *selection[] = { first, last };
  NEED (select_exact (image, selection, 2), "boundary selection order is independently captured");
  NEED (delete_cycle (engine, id, sources, G_N_ELEMENTS (sources), survivor, 1, 1, FALSE),
        "exactly 256 captured sources delete as one reversible native operation");
cleanup:
  clear_error (&error); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
undo_purge_lifetime (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsImageID id = 0; char *error = NULL;
  GWeakRef source; gboolean weak_initialized = FALSE;
  NEED (api->image_new (engine, 8, 8, &id, &error) == GLIMS_STATUS_OK,
        "Undo-purge lifetime fixture creates one layer");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *layer = only_layer (image);
  NEED (layer != NULL, "lifetime fixture has exactly one source");
  GlimsItemID captured = item_id (layer);
  g_weak_ref_init (&source, G_OBJECT (layer)); weak_initialized = TRUE;
  /* The borrowed pointer above adds no strong ownership. */
  NEED (glims_image_delete_layers (engine, id, &captured, 1, &error) == GLIMS_STATUS_OK,
        "source is detached by the real private batch deletion");
  GObject *retained = g_weak_ref_get (&source);
  CHECK (retained && !gimp_item_is_attached (GIMP_ITEM (retained)),
         "Undo retains the detached source before its history is purged");
  g_clear_object (&retained);
  gimp_image_undo_free (image);
  retained = g_weak_ref_get (&source);
  CHECK (retained == NULL && gimp_item_get_by_id (engine->gimp, captured) == NULL,
         "purging Undo finalizes the source and unregisters its ID while the image stays open");
  g_clear_object (&retained);
  GlimsUndoInfo undo = {0};
  CHECK (api->image_undo_info (engine, id, &undo) == GLIMS_STATUS_OK && undo.undo_count == 0 && undo.redo_count == 0,
         "the lifetime assertion runs after actual native Undo and Redo stacks are empty");
cleanup:
  if (weak_initialized) g_weak_ref_clear (&source);
  clear_error (&error); if (id) api->image_close (engine, id);
  return GLIMS_STATUS_OK;
}

static GlimsStatus snapshot_job (GlimsEngine *engine, gpointer data)
{
  ReadSnapshot *out = data; out->digest = fingerprint (engine, out->image, TRUE);
  return out->digest ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static void
public_cases (GlimsEngine *engine)
{
  GlimsImageID image = 0; char *error = NULL; GlimsLayerInfo row = {0}; int32_t count = 0;
  ReadSnapshot before = { 0, NULL }, after = { 0, NULL };
  NEED (api->image_new (engine, 16, 16, &image, &error) == GLIMS_STATUS_OK &&
        api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK && count == 1, "public marshal fixture contains one layer");
  before.image = after.image = image;
  NEED (glims_engine_call (engine, snapshot_job, &before) == GLIMS_STATUS_OK, "public baseline is read on the engine thread");
  CHECK (api->image_delete_layers (engine, image, &row.id, -1, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "slot146 rejects signed negative count before converting to size_t"); clear_error (&error);
  NEED (glims_engine_call (engine, snapshot_job, &after) == GLIMS_STATUS_OK, "negative-count result can be inspected");
  CHECK (!strcmp (before.digest, after.digest), "public negative-count refusal preserves the whole native image"); g_clear_pointer (&after.digest, g_free);
  GlimsItemID bad[] = { row.id, INT_MAX };
  CHECK (api->image_delete_layers (engine, image, bad, 2, &error) == GLIMS_STATUS_NOT_FOUND, "slot146 validates a later invalid ID before mutation"); clear_error (&error);
  NEED (glims_engine_call (engine, snapshot_job, &after) == GLIMS_STATUS_OK, "later-ID result can be inspected");
  CHECK (!strcmp (before.digest, after.digest), "public later-ID refusal does not partially delete the first layer");
  NEED (api->image_delete_layers (engine, image, &row.id, 1, &error) == GLIMS_STATUS_OK, "slot146 host-thread blocking marshal performs a successful deletion");
  CHECK (api->image_layers (engine, image, NULL, 0, &count) == GLIMS_STATUS_OK && count == 0, "public successful deletion yields an empty tree");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK && count == 1,
         "public successful batch is one-step undoable");
cleanup:
  clear_error (&error); if (image) api->image_close (engine, image);
  g_free (before.digest); g_free (after.digest);
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  diagnostic_dir = argv[1];
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof (GlimsEngineAPI) || !api->image_delete_layers || api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "matching slot146 engine startup failed");
    if (error && api) api->free_string (error); g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, ordinary_cases, NULL) == GLIMS_STATUS_OK, "ordinary fixture executes on the worker");
  CHECK (glims_engine_call (engine, nested_and_empty, NULL) == GLIMS_STATUS_OK, "nested/empty fixtures execute on the worker");
  CHECK (glims_engine_call (engine, refusal_cases, NULL) == GLIMS_STATUS_OK, "refusal fixtures execute on the worker");
  CHECK (glims_engine_call (engine, mask_cases, NULL) == GLIMS_STATUS_OK, "mask fixtures execute on the worker");
  CHECK (glims_engine_call (engine, capacity_case, NULL) == GLIMS_STATUS_OK, "maximum-count fixture executes on the worker");
  CHECK (glims_engine_call (engine, undo_purge_lifetime, NULL) == GLIMS_STATUS_OK, "Undo-purge lifetime fixture executes on the worker");
  public_cases (engine);
  api->stop (engine); g_free (user); g_free (cache);
  g_free (last_description);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}

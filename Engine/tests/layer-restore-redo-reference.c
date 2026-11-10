/* Standalone source-only diagnostic. Compare a one-member batch with direct
 * native rasterizable Restore under the same changing-file Undo chronology.
 * It never executes or changes the frozen 163-check fixture. */
#include "engine-private.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayermask.h"
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplink.h"
#include "core/gimplinklayer.h"
#include "core/gimprasterizable.h"

int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static gint checks, failures;
#define CHECK(c, label) do { gboolean ok_ = (c); checks++; \
  printf ("%s %s\n", ok_ ? "ok  " : "FAIL", label); \
  if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, label) do { gboolean needed_ = (c); CHECK (needed_, label); \
  if (!needed_) goto cleanup; } while (0)

typedef struct { gint x, y, width, height; gchar hash[65]; } BufferState;
typedef struct {
  BufferState drawable, retained, mask;
  gint x, y, mask_x, mask_y, undos, redos, layers;
  gboolean editable, rasterized, has_source, generic_flag, has_mask, dirty, selected;
} State;

static gboolean
buffer_state (GeglBuffer *buffer, BufferState *out)
{
  if (!buffer) return FALSE;
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  if (extent->width <= 0 || extent->height <= 0) return FALSE;
  *out = (BufferState) { .x = extent->x, .y = extent->y,
                         .width = extent->width, .height = extent->height };
  gsize length = (gsize) extent->width * extent->height * 4;
  guint8 *bytes = g_malloc (length);
  gegl_buffer_get (buffer, extent, 1, babl_format ("R'G'B'A u8"), bytes,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  gchar *hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, bytes, length);
  g_strlcpy (out->hash, hash, sizeof out->hash);
  g_free (hash); g_free (bytes); return TRUE;
}

static gboolean
buffer_equal (const BufferState *a, const BufferState *b)
{
  return a->x == b->x && a->y == b->y && a->width == b->width &&
         a->height == b->height && !strcmp (a->hash, b->hash);
}

static gboolean
read_state (GlimsEngine *engine, GlimsImageID image_id, GlimsItemID layer_id,
             GlimsItemID mask_id, State *out)
{
  GlimsOpenImage *open = glims_lookup_image (engine, image_id);
  GimpItem *item = open ? gimp_item_get_by_id (engine->gimp, layer_id) : NULL;
  if (!GIMP_IS_LINK_LAYER (item) || !gimp_item_is_attached (item) ||
      gimp_item_get_image (item) != open->image) return FALSE;
  GimpLayer *layer = GIMP_LAYER (item);
  GimpLink *link = gimp_link_layer_get_link (GIMP_LINK_LAYER (layer));
  GlimsLayerSourceInfo info = { .struct_size = sizeof info };
  GlimsUndoInfo undo = {0};
  *out = (State) {0};
  if (!link || api->layer_source_info (engine, image_id, layer_id, &info, NULL) != GLIMS_STATUS_OK ||
      info.source_kind != GLIMS_LAYER_LINK || api->image_undo_info (engine, image_id, &undo) != GLIMS_STATUS_OK ||
      !buffer_state (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)), &out->drawable) ||
      !buffer_state (gimp_link_get_buffer (link), &out->retained)) return FALSE;
  GimpLayerMask *mask = gimp_layer_get_mask (layer);
  if (!mask || gimp_item_get_id (GIMP_ITEM (mask)) != mask_id ||
      !buffer_state (gimp_drawable_get_buffer (GIMP_DRAWABLE (mask)), &out->mask)) return FALSE;
  gimp_item_get_offset (item, &out->x, &out->y);
  gimp_item_get_offset (GIMP_ITEM (mask), &out->mask_x, &out->mask_y);
  out->editable = gimp_item_is_link_layer (item);
  out->rasterized = info.is_rasterized; out->has_source = info.has_source;
  out->generic_flag = gimp_rasterizable_is_rasterized (GIMP_RASTERIZABLE (layer));
  out->has_mask = TRUE; out->dirty = gimp_image_is_dirty (open->image) != 0;
  out->undos = undo.undo_count; out->redos = undo.redo_count;
  GList *rows = gimp_image_get_layer_list (open->image);
  out->layers = g_list_length (rows); g_list_free (rows);
  GList *selected = gimp_image_get_selected_layers (open->image); /* Borrowed. */
  out->selected = selected && selected->data == layer && !selected->next;
  return TRUE;
}

static gboolean
state_equal (const State *a, const State *b)
{
  return buffer_equal (&a->drawable, &b->drawable) && buffer_equal (&a->retained, &b->retained) &&
         buffer_equal (&a->mask, &b->mask) && a->x == b->x && a->y == b->y &&
         a->mask_x == b->mask_x && a->mask_y == b->mask_y && a->undos == b->undos && a->redos == b->redos &&
         a->layers == b->layers && a->editable == b->editable && a->rasterized == b->rasterized &&
         a->has_source == b->has_source && a->generic_flag == b->generic_flag &&
         a->has_mask == b->has_mask && a->dirty == b->dirty && a->selected == b->selected;
}

static void
print_state (const gchar *label, const State *state)
{
  printf ("STATE %s drawable=%dx%d@%d,%d:%s source=%dx%d:%s mask=%dx%d:%s "
          "editable=%d rasterized=%d generic=%d source-retained=%d undo=%d redo=%d selected=%d\n",
          label, state->drawable.width, state->drawable.height, state->x, state->y, state->drawable.hash,
          state->retained.width, state->retained.height, state->retained.hash,
          state->mask.width, state->mask.height, state->mask.hash, state->editable, state->rasterized,
          state->generic_flag, state->has_source, state->undos, state->redos, state->selected);
  fflush (stdout);
}

static GlimsStatus
write_png (GlimsEngine *engine, const gchar *file, gint width, gint height, guint seed,
            GlimsImageID *scratch, GlimsImageID *opened, BufferState *expected, char **error)
{
  GlimsStatus status = api->image_new (engine, width, height, scratch, error);
  if (status != GLIMS_STATUS_OK) return status;
  GimpImage *image = glims_lookup_image (engine, *scratch)->image;
  GList *rows = gimp_image_get_layer_list (image);
  GimpLayer *layer = rows ? rows->data : NULL; g_list_free (rows);
  if (!layer) return GLIMS_STATUS_FAILED;
  guint8 *bytes = g_malloc ((gsize) width * height * 4);
  for (gint y = 0; y < height; y++) for (gint x = 0; x < width; x++)
    {
      guint8 *p = bytes + ((gsize) y * width + x) * 4;
      p[0] = 20 + (x * 17 + y * 3 + seed) % 210;
      p[1] = 30 + (x * 5 + y * 23 + seed) % 200;
      p[2] = 40 + (x * 11 + y * 7 + seed) % 190; p[3] = 255;
    }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)), GEGL_RECTANGLE (0, 0, width, height),
                   0, babl_format ("R'G'B'A u8"), bytes, GEGL_AUTO_ROWSTRIDE);
  g_free (bytes); gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, width, height);
  status = api->image_export (engine, *scratch, file, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = api->image_close (engine, *scratch);
  if (status != GLIMS_STATUS_OK) return status;
  *scratch = 0;
  status = api->image_open (engine, file, opened, error);
  if (status != GLIMS_STATUS_OK) return status;
  image = glims_lookup_image (engine, *opened)->image;
  rows = gimp_image_get_layer_list (image); layer = rows ? rows->data : NULL; g_list_free (rows);
  if (!layer || !buffer_state (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)), expected)) return GLIMS_STATUS_FAILED;
  status = api->image_close (engine, *opened);
  if (status == GLIMS_STATUS_OK) *opened = 0;
  return status;
}

static GlimsStatus
reference_worker (GlimsEngine *engine, gpointer work)
{
  if (engine->busy) return GLIMS_STATUS_BUSY;
  GlimsImageID images[2] = {0}, scratch = 0, opened = 0;
  GlimsItemID layers[2] = {0}, masks[2] = {0};
  GimpLayer *native[2] = {0};
  BufferState v1 = {0}, v2 = {0}, v3 = {0};
  State initial[2] = {0}, damaged[2] = {0}, restored[2] = {0}, undone[2] = {0}, redone[2] = {0};
  gchar *file = g_build_filename (work, "batch-restore-redo-reference.png", NULL);
  char *error = NULL;
  NEED (write_png (engine, file, 17, 9, 13, &scratch, &opened, &v1, &error) == GLIMS_STATUS_OK,
        "reference V1 PNG is independently seeded with asymmetric opaque pixels");
  for (guint i = 0; i < 2; i++)
    {
      NEED (api->image_new (engine, 32, 24, &images[i], &error) == GLIMS_STATUS_OK &&
            api->image_place_link (engine, images[i], file, &layers[i], &error) == GLIMS_STATUS_OK && layers[i] &&
            api->layer_mask_add (engine, images[i], layers[i], GLIMS_MASK_WHITE, FALSE, &masks[i], &error) == GLIMS_STATUS_OK,
            "separate batch/reference images own real linked layers and masks");
      native[i] = GIMP_LAYER (gimp_item_get_by_id (engine->gimp, layers[i]));
      NEED (read_state (engine, images[i], layers[i], masks[i], &initial[i]), "initial linked native state can be read independently");
      print_state (i == 0 ? "batch V1" : "direct V1", &initial[i]);
    }
  CHECK (state_equal (&initial[0], &initial[1]) && buffer_equal (&initial[0].drawable, &v1),
         "batch and direct reference begin with identical real source/drawable/mask state");
  for (guint i = 0; i < 2; i++)
    {
      gimp_rasterizable_rasterize (GIMP_RASTERIZABLE (native[i]), TRUE);
      GeglColor *color = gegl_color_new ("rgba(0.8,0.1,0.6,0.7)");
      gegl_buffer_set_color (gimp_drawable_get_buffer (GIMP_DRAWABLE (native[i])), NULL, color);
      g_object_unref (color); gimp_drawable_update (GIMP_DRAWABLE (native[i]), 0, 0, 17, 9);
      gimp_image_clean_all (glims_lookup_image (engine, images[i])->image);
      NEED (read_state (engine, images[i], layers[i], masks[i], &damaged[i]), "damaged raster state is captured independently");
      print_state (i == 0 ? "batch damaged" : "direct damaged", &damaged[i]);
    }
  CHECK (state_equal (&damaged[0], &damaged[1]) && damaged[0].generic_flag && damaged[0].rasterized &&
         !buffer_equal (&damaged[0].drawable, &v1), "both fixtures have identical demonstrably damaged retained raster sources");
  NEED (write_png (engine, file, 11, 7, 83, &scratch, &opened, &v2, &error) == GLIMS_STATUS_OK,
        "reference V2 current file has different bytes and dimensions");
  NEED (api->image_restore_layer_sources (engine, images[0], &layers[0], 1, &error) == GLIMS_STATUS_OK,
        "batch reference side restores V2 through slot166");
  /* Authentic native expected generator: no batch helper is called here. */
  engine->busy++;
  gimp_rasterizable_restore (GIMP_RASTERIZABLE (native[1]));
  engine->busy--;
  for (guint i = 0; i < 2; i++)
    {
      NEED (read_state (engine, images[i], layers[i], masks[i], &restored[i]), "V2 restored native state is captured");
      print_state (i == 0 ? "batch V2 Restore" : "direct V2 Restore", &restored[i]);
    }
  CHECK (state_equal (&restored[0], &restored[1]) && buffer_equal (&restored[1].drawable, &v2) &&
         buffer_equal (&restored[1].retained, &v2), "batch V2 source/drawable state exactly matches direct native restoration");
  CHECK (restored[0].undos == damaged[0].undos + 1 && restored[1].undos == damaged[1].undos + 1 &&
         engine->busy == 0 && !gimp_image_get_undo_group_count (glims_lookup_image (engine, images[0])->image) &&
         !gimp_image_get_undo_group_count (glims_lookup_image (engine, images[1])->image),
         "batch and direct native restoration each add one balanced Undo");
  for (guint i = 0; i < 2; i++)
    {
      NEED (api->image_undo (engine, images[i]) == GLIMS_STATUS_OK &&
            read_state (engine, images[i], layers[i], masks[i], &undone[i]), "each independent native restore undoes once");
      print_state (i == 0 ? "batch Undo" : "direct Undo", &undone[i]);
    }
  CHECK (state_equal (&undone[0], &undone[1]) && buffer_equal (&undone[0].drawable, &damaged[0].drawable) &&
         undone[0].rasterized && undone[0].generic_flag, "Undo exactly agrees with native reference and restores damaged drawable");
  NEED (write_png (engine, file, 13, 8, 151, &scratch, &opened, &v3, &error) == GLIMS_STATUS_OK,
        "reference V3 file changes again while both links are frozen");
  for (guint i = 0; i < 2; i++)
    {
      NEED (api->image_redo (engine, images[i]) == GLIMS_STATUS_OK &&
            read_state (engine, images[i], layers[i], masks[i], &redone[i]), "each independent native restore redoes once");
      print_state (i == 0 ? "batch V3 Redo" : "direct V3 Redo", &redone[i]);
    }
  CHECK (buffer_equal (&redone[1].retained, &v3), "direct native Redo reloads V3 into the retained link buffer");
  CHECK (buffer_equal (&redone[1].drawable, &restored[1].drawable),
         "direct native Redo subsequently reinstalls the stored V2 drawable through drawable-mod Undo");
  CHECK (state_equal (&redone[0], &redone[1]),
         "batch Redo exactly matches independent native drawable/source/mask geometry and editable flags");
cleanup:
  if (error) fprintf (stderr, "reference diagnostic: %s\n", error);
  if (error) api->free_string (error);
  if (scratch) api->image_close (engine, scratch);
  if (opened) api->image_close (engine, opened);
  for (guint i = 0; i < 2; i++) if (images[i])
    CHECK (api->image_close (engine, images[i]) == GLIMS_STATUS_OK, "diagnostic closes its owned linked/masked native image");
  remove (file); g_free (file);
  return GLIMS_STATUS_OK;
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
    { if (error && api) api->free_string (error); g_free (user); g_free (cache); return 2; }
  GlimsStatus status;
  gint64 end = g_get_monotonic_time () + 10 * G_TIME_SPAN_SECOND;
  do {
    status = glims_engine_call (engine, reference_worker, argv[1]);
    if (status == GLIMS_STATUS_BUSY) g_usleep (10000);
  } while (status == GLIMS_STATUS_BUSY && g_get_monotonic_time () < end);
  CHECK (status == GLIMS_STATUS_OK, "independent native Redo diagnostic executes on engine worker");
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}
#else
int main (int argc, char **argv);
int main (int argc, char **argv)
{
  (void) argc; (void) argv;
  fprintf (stderr, "The direct linked Redo diagnostic requires GIMP 3.2 or later.\n");
  return 2;
}
#endif

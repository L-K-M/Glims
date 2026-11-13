/* Private U8 carrier acceptance, independent of document adoption/rendering. */
#include "lab-layer-storage.h"
#include "plate-storage.h"
#include <stdio.h>
#include <string.h>
#include <cairo.h>
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpobject.h"
#include "core/gimpviewable.h"
#include "core/gimpundostack.h"
#include "file/file-open.h"
#include "file/file-save.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
#include "plug-in/gimppluginprocedure.h"
#include "libgimpcolor/gimpcolor.h"
#if GIMP_CHECK_VERSION(3, 2, 0)
#include "path/gimppath.h"
#else
#include "vectors/gimppath.h"
#endif

#define WIDTH 3
#define HEIGHT 2
#define PIXELS (WIDTH * HEIGHT)
static unsigned checks, failures;
static const GlimsEngineAPI *api;
#define CHECK(value, message) do { gboolean ok_ = !!(value); checks++; \
  if (!ok_) failures++; printf("%s %s\n", ok_ ? "ok" : "FAIL", message); \
  fflush(stdout); } while (0)

static GlimsLabLayerMap
make_map (guint count)
{
  GlimsLabLayerMap map = { .width = WIDTH, .height = HEIGHT, .count = count,
    .mode = GLIMS_LAB_LAYER_MAP_MODE_LAB,
    .storage = GLIMS_LAB_LAYER_MAP_STORAGE_U8,
    .encoding = GLIMS_LAB_LAYER_MAP_ENCODING_LAB_D50 };
  for (guint i = 0; i < count && i < GLIMS_LAB_LAYER_LIMIT; i++)
    for (guint j = 0; j < 5; j++)
      {
        guint32 number = 1 + 5 * i + j;
        guint8 *uuid = ((guint8 *) &map.entries[i]) + 16 * j;
        uuid[0] = 0xa7; uuid[12] = number >> 24; uuid[13] = number >> 16;
        uuid[14] = number >> 8; uuid[15] = number;
      }
  return map;
}

static GimpImage *
create (GlimsEngine *engine, guint count)
{
  GlimsLabLayerMap map = make_map (count);
  char *error = NULL;
  GimpImage *image = glims_lab_layer_storage_create (engine, &map, &error);
  CHECK (image != NULL && error == NULL, "factory creates canonical carrier");
  if (error) { printf ("factory error: %s\n", error); api->free_string (error); }
  return image;
}

static gboolean
scalar_plane (GimpLayer *plane)
{
  if (!plane || !GIMP_IS_LAYER (plane)) return FALSE;
  const Babl *format = gimp_drawable_get_format (GIMP_DRAWABLE (plane));
  return format && babl_format_get_bytes_per_pixel (format) == 1 &&
    babl_format_get_n_components (format) == 1 &&
    gimp_item_get_width (GIMP_ITEM (plane)) == WIDTH &&
    gimp_item_get_height (GIMP_ITEM (plane)) == HEIGHT;
}

static gboolean
read_plane (GimpLayer *plane, guint8 bytes[PIXELS])
{
  if (!scalar_plane (plane)) { CHECK (FALSE, "fixture read requires scalar U8 plane and expected dimensions"); return FALSE; }
  GimpDrawable *drawable = GIMP_DRAWABLE (plane);
  gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT),
    1, gimp_drawable_get_format (drawable), bytes, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  return TRUE;
}

static gboolean
write_plane (GimpLayer *plane, const guint8 bytes[PIXELS])
{
  if (!scalar_plane (plane)) { CHECK (FALSE, "fixture write requires scalar U8 plane and expected dimensions"); return FALSE; }
  GimpDrawable *drawable = GIMP_DRAWABLE (plane);
  gegl_buffer_set (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT),
    0, gimp_drawable_get_format (drawable), bytes, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (drawable, 0, 0, WIDTH, HEIGHT);
  return TRUE;
}

static void
attach_uuid (GimpItem *item, const guint8 uuid[16])
{
  /* Malformed controls need no history. Some upstream versions end an Undo
   * group for UNDOABLE item metadata even when push_undo is FALSE. */
  GimpParasite *p = gimp_parasite_new (GLIMS_PLATE_UUID_PARASITE,
    GIMP_PARASITE_PERSISTENT, 16, uuid);
  gimp_item_parasite_attach (item, p, FALSE);
  gimp_parasite_free (p);
}

static void
check_invalid (GimpImage *image, const char *message)
{
  GlimsLabLayerStorage storage;
  memset (&storage, 0xa5, sizeof storage);
  CHECK (glims_lab_layer_storage_read (image, &storage) == GLIMS_LAB_LAYER_STORAGE_INVALID,
         message);
  const guint8 *bytes = (const guint8 *) &storage;
  gboolean zero = TRUE;
  for (gsize i = 0; i < sizeof storage; i++) if (bytes[i]) { zero = FALSE; break; }
  CHECK (zero, "invalid read clears all borrowed pointers and map bytes");
}

static gboolean
add_mask (GimpLayer *layer)
{
  GError *error = NULL;
  GimpLayerMask *mask = gimp_layer_create_mask (layer, GIMP_ADD_MASK_WHITE, NULL);
#if GIMP_CHECK_VERSION(3, 2, 0)
  gboolean added = mask && gimp_layer_add_mask (layer, mask, FALSE, FALSE, &error);
#else
  gboolean added = mask && gimp_layer_add_mask (layer, mask, FALSE, &error);
#endif
  if (!added && mask) g_object_unref (mask);
  if (error) g_clear_error (&error);
  return added;
}

static gboolean
add_effect (GimpLayer *layer)
{
  GeglNode *operation = gegl_node_new_child (NULL, "operation", "gegl:brightness-contrast",
                                             "brightness", .125, NULL);
  GimpDrawableFilter *filter = operation ? gimp_drawable_filter_new (GIMP_DRAWABLE (layer),
    "Unsupported carrier effect", operation, NULL) : NULL;
  gboolean committed = FALSE;
  if (filter)
    {
      gimp_drawable_filter_apply (filter, NULL);
      committed = gimp_drawable_filter_commit (filter, TRUE, NULL, FALSE);
      if (committed) gimp_drawable_filter_set_temporary (filter, FALSE);
      else gimp_drawable_filter_abort (filter);
    }
  g_clear_object (&filter); g_clear_object (&operation);
  return committed;
}

static gboolean
save_xcf (Gimp *gimp, GimpImage *image, const char *path)
{
  GError *error = NULL;
  GFile *file = g_file_new_for_path (path);
  GimpPlugInProcedure *proc = gimp_plug_in_manager_file_procedure_find (
    gimp->plug_in_manager, GIMP_FILE_PROCEDURE_GROUP_SAVE, file, &error);
  GimpPDBStatusType status = proc ? file_save (gimp, image, NULL, file, proc,
    GIMP_RUN_NONINTERACTIVE, TRUE, FALSE, FALSE, &error) : GIMP_PDB_EXECUTION_ERROR;
  if (error) { printf ("save error: %s\n", error->message); g_clear_error (&error); }
  g_object_unref (file);
  return status == GIMP_PDB_SUCCESS;
}

static GimpImage *
open_xcf (Gimp *gimp, const char *path)
{
  GError *error = NULL;
  GimpPDBStatusType status;
  const gchar *mime = NULL;
  GFile *file = g_file_new_for_path (path);
#if GIMP_CHECK_VERSION(3, 2, 0)
  gboolean handles_vector = FALSE;
  GimpImage *image = file_open_image (gimp, gimp_get_user_context (gimp), NULL, file,
    0, 0, FALSE, FALSE, NULL, GIMP_RUN_NONINTERACTIVE, &handles_vector, &status, &mime, &error);
#else
  GimpImage *image = file_open_image (gimp, gimp_get_user_context (gimp), NULL, file,
    0, 0, FALSE, NULL, GIMP_RUN_NONINTERACTIVE, &status, &mime, &error);
#endif
  CHECK (image != NULL && status == GIMP_PDB_SUCCESS, "XCF reopens successfully");
  if (error) { printf ("open error: %s\n", error->message); g_clear_error (&error); }
  g_object_unref (file);
  return image;
}

static gboolean
matches (GimpImage *image, const GlimsLabLayerMap *map, const guint8 samples[2][4][PIXELS],
         gboolean reversed)
{
  GlimsLabLayerStorage storage;
  if (glims_lab_layer_storage_read (image, &storage) != GLIMS_LAB_LAYER_STORAGE_VALID ||
      memcmp (&storage.map, map, sizeof *map)) return FALSE;
  for (guint i = 0; i < 2; i++)
    {
      guint index = reversed ? 1 - i : i;
      if (storage.layers[i].map_index != index) return FALSE;
      for (guint p = 0; p < 4; p++)
        {
          guint8 actual[PIXELS];
          if (!read_plane (storage.layers[i].planes[p], actual) ||
              memcmp (actual, samples[index][p], PIXELS)) return FALSE;
        }
    }
  return TRUE;
}

static void
valid_cases (GlimsEngine *engine, const char *work)
{
  GimpImage *image = create (engine, 2);
  if (!image) return;
  GlimsLabLayerStorage storage;
  gboolean valid = glims_lab_layer_storage_read (image, &storage) == GLIMS_LAB_LAYER_STORAGE_VALID;
  CHECK (valid, "canonical factory carrier validates");
  if (!valid) { g_object_unref (image); return; }
  GlimsLabLayerMap expected = make_map (2);
  CHECK (!memcmp (&storage.map, &expected, sizeof expected), "factory retains exact map identities");
  CHECK (gimp_undo_stack_get_depth (gimp_image_get_undo_stack (image)) == 0 &&
         gimp_undo_stack_get_depth (gimp_image_get_redo_stack (image)) == 0,
         "fresh carrier has no user Undo or Redo");
  for (guint i = 0; i < 2; i++)
    for (guint p = 0; p < 4; p++)
      {
        guint8 actual[PIXELS], initial[PIXELS];
        memset (initial, p == 0 ? 255 : p == 3 ? 0 : 128, sizeof initial);
        CHECK (read_plane (storage.layers[i].planes[p], actual) && !memcmp (initial, actual, PIXELS),
               "initial planes are neutral white with zero alpha");
      }
  guint8 samples[2][4][PIXELS];
  for (guint i = 0; i < 2; i++) for (guint p = 0; p < 4; p++)
    {
      for (guint x = 0; x < PIXELS; x++) samples[i][p][x] = (17 + 91 * i + 43 * p + 53 * x) & 255;
      if (p == 3) { samples[i][p][0] = 0; samples[i][p][1] = 128; samples[i][p][2] = 255; }
      write_plane (storage.layers[i].planes[p], samples[i][p]);
    }
  CHECK (matches (image, &expected, samples, FALSE), "all raw axis and alpha bytes round trip");
  GlimsPlateStorage legacy;
  CHECK (glims_plate_storage_read (image, &legacy) == GLIMS_PLATE_STORAGE_INVALID,
         "legacy v1 reader refuses a v2 carrier");
  GimpImage *copy = gimp_image_duplicate (image);
  CHECK (copy && matches (copy, &expected, samples, FALSE), "internal duplicate retains map and raw planes");
  if (copy)
    {
      GlimsLabLayerStorage copied;
      guint8 copy_samples[2][4][PIXELS]; memcpy (copy_samples, samples, sizeof copy_samples);
      if (glims_lab_layer_storage_read (copy, &copied) == GLIMS_LAB_LAYER_STORAGE_VALID)
        for (guint p = 0; p < 4; p++)
          {
            guint8 altered[PIXELS]; memset (altered, 202 + p, PIXELS);
            write_plane (copied.layers[0].planes[p], altered);
            memcpy (copy_samples[0][p], altered, PIXELS);
            CHECK (matches (copy, &expected, copy_samples, FALSE),
                   "duplicate write changes exactly the chosen plane, preserving other copy samples");
            CHECK (matches (image, &expected, samples, FALSE), "mutating each duplicate plane leaves source unchanged");
          }
      g_object_unref (copy);
    }
  GimpLayer *first = storage.layers[0].group;
  CHECK (gimp_image_reorder_item (image, GIMP_ITEM (first), NULL, 1, TRUE, "Reorder Lab"),
         "logical group can be reordered");
  CHECK (matches (image, &expected, samples, TRUE), "native root order changes output order without changing UUID map");
  CHECK (gimp_image_undo (image) && matches (image, &expected, samples, FALSE), "reorder Undo restores native order");
  CHECK (gimp_image_redo (image) && matches (image, &expected, samples, TRUE), "reorder Redo restores native order");
  gimp_item_set_visible (GIMP_ITEM (first), FALSE, TRUE);
  gimp_layer_set_opacity (first, .375, TRUE);
  CHECK (matches (image, &expected, samples, TRUE), "logical visibility and opacity preserve raw storage");
  gchar *path = g_build_filename (work, "layered-lab-u8.xcf", NULL);
  gboolean saved = save_xcf (engine->gimp, image, path);
  CHECK (saved, "actual carrier saves as XCF");
  if (saved)
    {
      GimpImage *opened = open_xcf (engine->gimp, path);
      if (opened)
        {
          CHECK (matches (opened, &expected, samples, TRUE), "XCF retains every UUID, axis, alpha and root order");
          GlimsLabLayerStorage reopened;
          if (glims_lab_layer_storage_read (opened, &reopened) == GLIMS_LAB_LAYER_STORAGE_VALID)
            CHECK (!gimp_item_get_visible (GIMP_ITEM (reopened.layers[1].group)) &&
                   gimp_layer_get_opacity (reopened.layers[1].group) == .375,
                   "XCF preserves logical visibility and opacity");
          g_object_unref (opened);
        }
    }
  CHECK (matches (image, &expected, samples, TRUE), "XCF work preserves source bytes");
  gimp_image_remove_layer (image, first, TRUE, NULL);
  check_invalid (image, "removing a group without its map update refuses");
  CHECK (gimp_image_undo (image) && matches (image, &expected, samples, TRUE),
         "group removal Undo restores original identities and all samples");
  CHECK (gimp_image_redo (image), "group removal can redo");
  check_invalid (image, "group removal Redo does not authorize stale map entries");
  CHECK (gimp_image_undo (image) && matches (image, &expected, samples, TRUE),
         "second removal Undo returns a valid carrier");
  g_free (path);
  g_object_unref (image);
  image = create (engine, 0);
  if (image)
    {
      CHECK (glims_lab_layer_storage_read (image, &storage) == GLIMS_LAB_LAYER_STORAGE_VALID &&
             storage.map.count == 0, "empty transparent stack validates");
      path = g_build_filename (work, "empty-layered-lab.xcf", NULL);
      saved = save_xcf (engine->gimp, image, path);
      CHECK (saved, "empty stack saves");
      if (saved)
        {
          GimpImage *opened = open_xcf (engine->gimp, path);
          if (opened)
            {
              CHECK (glims_lab_layer_storage_read (opened, &storage) == GLIMS_LAB_LAYER_STORAGE_VALID &&
                     storage.map.count == 0, "empty stack survives XCF");
              g_object_unref (opened);
            }
        }
      g_free (path);
      g_object_unref (image);
    }
  image = create (engine, GLIMS_LAB_LAYER_LIMIT);
  if (image)
    {
      gint64 begin = g_get_monotonic_time ();
      CHECK (glims_lab_layer_storage_read (image, &storage) == GLIMS_LAB_LAYER_STORAGE_VALID &&
             storage.map.count == GLIMS_LAB_LAYER_LIMIT, "maximum logical stack validates with unique roles");
      printf ("maximum-stack-read-us=%" G_GINT64_FORMAT "\n", g_get_monotonic_time () - begin);
      g_object_unref (image);
    }
}

static void
invalid_cases (GlimsEngine *engine)
{
  for (guint test = 0; test < 28; test++)
    {
      GimpImage *image = create (engine, 2);
      if (!image) return;
      GlimsLabLayerStorage s;
      if (glims_lab_layer_storage_read (image, &s) != GLIMS_LAB_LAYER_STORAGE_VALID)
        { CHECK (FALSE, "invalid control needs valid baseline"); g_object_unref (image); return; }
      GimpItem *child = GIMP_ITEM (s.layers[0].planes[0]);
      switch (test)
        {
        case 0: gimp_image_parasite_detach (image, GLIMS_PLATE_MAP_PARASITE, FALSE); break;
        case 1: gimp_item_parasite_detach (child, GLIMS_PLATE_UUID_PARASITE, FALSE); break;
        case 2: attach_uuid (child, s.map.entries[0].a); break;
        case 3: attach_uuid (child, s.map.entries[1].l); break;
        case 4: gimp_item_set_offset (child, 1, 0); break;
        case 5: gimp_item_set_visible (child, FALSE, FALSE); break;
        case 6: gimp_layer_set_opacity (GIMP_LAYER (child), .5, FALSE); break;
        case 7: gimp_layer_set_mode (GIMP_LAYER (child), GIMP_LAYER_MODE_MULTIPLY, FALSE); break;
        case 8: gimp_item_set_lock_content (child, TRUE, FALSE); break;
        case 9: gimp_layer_add_alpha (GIMP_LAYER (child)); break;
        case 10: gimp_image_remove_layer (image, GIMP_LAYER (child), FALSE, NULL); break;
        case 11: gimp_item_parasite_detach (GIMP_ITEM (s.layers[0].group), GLIMS_PLATE_UUID_PARASITE, FALSE); break;
        case 12: gimp_layer_set_mode (s.layers[0].group, GIMP_LAYER_MODE_PASS_THROUGH, FALSE); break;
        case 13: gimp_item_set_lock_position (GIMP_ITEM (s.layers[0].group), TRUE, FALSE); break;
        case 14:
          {
            guint8 bytes[GLIMS_LAB_LAYER_MAP_MAX_SIZE]; size_t length = 0;
            CHECK (glims_lab_layer_map_encode (&s.map, bytes, sizeof bytes, &length), "encode malformed-version control");
            bytes[8] = 99;
            GimpParasite *p = gimp_parasite_new (GLIMS_PLATE_MAP_PARASITE, GIMP_PARASITE_PERSISTENT, length, bytes);
            gimp_image_parasite_attach (image, p, FALSE); gimp_parasite_free (p); break;
          }
        case 15:
          {
            GeglColor *color = gegl_color_new ("black");
            GimpChannel *extra = gimp_channel_new (image, WIDTH, HEIGHT, "unsupported channel", color);
            g_object_unref (color);
            CHECK (extra && gimp_image_add_channel (image, extra, NULL, 0, FALSE), "insert extra-channel control");
            break;
          }
        case 16:
          {
            GimpParasite *p = gimp_parasite_new (GLIMS_PLATE_PROFILE_PARASITE,
              GIMP_PARASITE_PERSISTENT, 1, "x");
            gimp_image_parasite_attach (image, p, FALSE); gimp_parasite_free (p); break;
          }
        case 17:
          CHECK (add_mask (GIMP_LAYER (child)), "add unsupported child-mask control");
          break;
        case 18: gimp_layer_set_lock_alpha (GIMP_LAYER (child), TRUE, FALSE); break;
        case 19:
          {
            GimpLayer *extra = gimp_layer_new (image, WIDTH, HEIGHT,
              gimp_image_get_layer_format (image, FALSE), "extra", 1, GIMP_LAYER_MODE_NORMAL);
            CHECK (extra && gimp_image_add_layer (image, extra, s.layers[0].group, 4, FALSE),
                   "insert fifth child control");
            break;
          }
        case 20:
          {
            GimpLayer *extra = gimp_layer_new (image, WIDTH, HEIGHT,
              gimp_image_get_layer_format (image, FALSE), "extra root", 1, GIMP_LAYER_MODE_NORMAL);
            CHECK (extra && gimp_image_add_layer (image, extra, NULL, 0, FALSE),
                   "insert unsupported ordinary root layer");
            break;
          }
        case 21:
          {
            GimpParasite *p = gimp_parasite_new (GLIMS_PLATE_UUID_PARASITE, 0, 16, s.map.entries[0].l);
            gimp_item_parasite_attach (child, p, FALSE); gimp_parasite_free (p); break;
          }
        case 22:
          CHECK (add_mask (s.layers[0].group), "add unsupported group-mask control");
          break;
        case 23: CHECK (add_effect (GIMP_LAYER (child)), "commit unsupported child effect"); break;
        case 24: CHECK (add_effect (s.layers[0].group), "commit unsupported group effect"); break;
        case 25:
          gimp_layer_set_composite_space (GIMP_LAYER (child), GIMP_LAYER_COLOR_SPACE_RGB_LINEAR, FALSE);
          CHECK (gimp_layer_get_composite_space (GIMP_LAYER (child)) == GIMP_LAYER_COLOR_SPACE_RGB_LINEAR,
                 "explicit composite-space control differs from AUTO");
          break;
        case 26:
          {
            GimpColorProfile *profile = gimp_color_profile_new_d65_gray_srgb_trc ();
            GError *error = NULL;
            CHECK (profile && gimp_image_set_color_profile (image, profile, &error), "attach explicit native gray ICC control");
            if (error) g_clear_error (&error);
            g_clear_object (&profile);
            break;
          }
        case 27:
          {
            GimpPath *path = gimp_path_new (image, "orphan identity");
            CHECK (path && gimp_image_add_path (image, path, NULL, 0, FALSE), "insert path-identity control");
            if (path) attach_uuid (GIMP_ITEM (path), s.map.entries[0].l);
            break;
          }
        }
      gchar *message = g_strdup_printf ("malformed carrier control %u refuses", test);
      check_invalid (image, message); g_free (message); g_object_unref (image);
    }
  GimpImage *ordinary = gimp_create_image (engine->gimp, WIDTH, HEIGHT, GIMP_GRAY, GIMP_PRECISION_U8_LINEAR, FALSE);
  GlimsLabLayerStorage s;
  CHECK (glims_lab_layer_storage_read (ordinary, &s) == GLIMS_LAB_LAYER_STORAGE_NONE,
         "unmarked ordinary Gray image is distinguished from damaged carrier");
  GimpPath *path = gimp_path_new (ordinary, "orphan identity");
  CHECK (path && gimp_image_add_path (ordinary, path, NULL, 0, FALSE), "insert ordinary path-identity control");
  GlimsLabLayerMap map = make_map (1);
  if (path) attach_uuid (GIMP_ITEM (path), map.entries[0].l);
  check_invalid (ordinary, "reserved UUID on ordinary path refuses without a map");
  g_object_unref (ordinary);
}

static GlimsStatus
run (GlimsEngine *engine, gpointer work)
{
  valid_cases (engine, work);
  invalid_cases (engine);
  return GLIMS_STATUS_OK;
}

int main (int argc, char **argv)
{
  if (argc != 2) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api) return 2;
  gchar *user = g_build_filename (argv[1], "user", NULL);
  gchar *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus status = api->start (&config, &engine, &error);
  g_free (user); g_free (cache);
  if (status != GLIMS_STATUS_OK || !engine)
    { fprintf (stderr, "start failed: %s\n", error ? error : "unknown"); api->free_string (error); return 2; }
  api->free_string (error);
  status = glims_engine_call (engine, run, argv[1]);
  api->stop (engine);
  printf ("checks=%u failures=%u\n", checks, failures);
  return status == GLIMS_STATUS_OK && failures == 0 ? 0 : 1;
}

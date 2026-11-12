/* Public mapped Lab XCF persistence. Raw expectations are literal native sample
 * bits, not an RGB conversion or the result of the Lab codec. This deliberately
 * includes finite float values outside the renderable gamut/range: storage
 * fidelity and document admission are distinct from successful preview. */
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpobject.h"
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define W 32
#define H 8
#define PIXELS (W * H)
static const GlimsEngineAPI *api;
static guint checks, failures;
#define CHECK(c, message) do { gboolean pass = !!(c); checks++; \
  printf("%s %s\n", pass ? "ok" : "FAIL", message); \
  if (!pass) failures++; fflush(stdout); } while (0)

typedef union {
  guint8 u8[PIXELS];
  guint16 u16[PIXELS];
  guint32 bits[PIXELS];
  gfloat f32[PIXELS];
} RawPlane;
typedef struct {
  RawPlane raw[3];
  guint8 map[GLIMS_PLATE_MAP_MAX_SIZE];
  guint32 map_size;
  guint8 uuid[3][16];
  gchar names[3][128];
  GlimsItemID ids[3];
  gboolean visible[3];
} Snapshot;
typedef struct {
  GlimsImageID id;
  guint component, storage;
  gsize bytes;
  RawPlane seed[3];
  Snapshot before, actual;
  const gchar *saved_path;
  gboolean source_destroyed;
} Scene;

static const Babl *
format_for (guint storage)
{
  if (storage == GLIMS_PLATE_STORAGE_U8) return babl_format ("Y u8");
  if (storage == GLIMS_PLATE_STORAGE_U16) return babl_format ("Y u16");
  return babl_format ("Y float");
}

static void
literal_samples (Scene *s)
{
  static const guint8 u8[3][8] = {
    { 0, 1, 8, 64, 128, 192, 254, 255 },
    { 0, 1, 64, 127, 128, 129, 254, 255 },
    { 255, 192, 129, 128, 127, 64, 1, 0 }
  };
  static const guint16 u16[3][8] = {
    { 0, 1, 257, 16384, 32768, 49152, 65280, 65535 },
    { 0, 1, 32639, 32768, 32896, 33153, 65280, 65535 },
    { 65535, 65280, 33153, 32896, 32768, 32639, 1, 0 }
  };
  static const guint32 physical_float[3][12] = {
    { 0xc0a00000, 0x00000000, 0x80000000, 0x41000000, 0x42480000, 0x42c80000,
      0x42dc0000, 0x00000001, 0x80000001, 0x7f7fffff, 0xff7fffff, 0x00800000 },
    { 0xc3200000, 0xc3000000, 0xbf800000, 0x80000000, 0x00000000, 0x3f800000,
      0x42fe0000, 0x43200000, 0x00000001, 0x80000001, 0x7f7fffff, 0xff7fffff },
    { 0x43200000, 0x42fe0000, 0x3f800000, 0x00000000, 0x80000000, 0xbf800000,
      0xc3000000, 0xc3200000, 0x80000001, 0x00000001, 0xff7fffff, 0x7f7fffff }
  };
  for (guint c = 0; c < 3; c++) for (guint p = 0; p < PIXELS; p++)
    {
      if (s->storage == GLIMS_PLATE_STORAGE_U8) s->seed[c].u8[p] = u8[c][p % 8];
      else if (s->storage == GLIMS_PLATE_STORAGE_U16) s->seed[c].u16[p] = u16[c][p % 8];
      else memcpy ((guint8 *) &s->seed[c] + p * 4, &physical_float[c][p % 12], 4);
    }
}

static gboolean
lookup (GlimsEngine *engine, Scene *s, GlimsOpenImage **open, GlimsPlateStorage *storage)
{
  *open = glims_lookup_image (engine, s->id);
  return *open && (*open)->component_document && (*open)->component_mode == GLIMS_PLATE_MODE_LAB &&
         glims_plate_storage_read_open (*open, storage) &&
         storage->map.mode == GLIMS_PLATE_MODE_LAB && storage->map.encoding == GLIMS_PLATE_ENCODING_LAB_D50 &&
         storage->map.storage == s->storage && storage->map.count == 3 &&
         storage->map.width == W && storage->map.height == H &&
         !storage->profile && !storage->profile_size &&
         gimp_container_get_n_children (gimp_image_get_layers ((*open)->image)) == 0;
}

static GlimsStatus
capture (GlimsEngine *engine, gpointer data)
{
  Scene *s = data;
  GlimsOpenImage *open;
  GlimsPlateStorage storage;
  Snapshot *out = &s->actual;
  memset (out, 0, sizeof *out);
  if (!lookup (engine, s, &open, &storage)) return GLIMS_STATUS_FAILED;
  const GimpParasite *map = gimp_image_parasite_find (open->image, GLIMS_PLATE_MAP_PARASITE);
  const guint8 *map_bytes = map ? gimp_parasite_get_data (map, &out->map_size) : NULL;
  if (!map_bytes || !out->map_size || out->map_size > sizeof out->map) return GLIMS_STATUS_FAILED;
  memcpy (out->map, map_bytes, out->map_size);
  for (guint c = 0; c < 3; c++)
    {
      GimpChannel *found = NULL;
      guint matches = 0;
      GList *channels = gimp_image_get_channel_list (open->image);
      for (GList *it = channels; it; it = it->next)
        {
          const GimpParasite *tag = gimp_item_parasite_find (GIMP_ITEM (it->data), GLIMS_PLATE_UUID_PARASITE);
          guint32 size = 0;
          const guint8 *uuid = tag ? gimp_parasite_get_data (tag, &size) : NULL;
          if (uuid && size == 16 && !memcmp (uuid, storage.map.entries[c].uuid, 16))
            { found = it->data; matches++; }
        }
      g_list_free (channels);
      if (matches != 1 || found != storage.planes[c]) return GLIMS_STATUS_FAILED;
      GimpDrawable *d = GIMP_DRAWABLE (found);
      GimpItem *item = GIMP_ITEM (found);
      if (gimp_drawable_get_format (d) != format_for (s->storage)) return GLIMS_STATUS_FAILED;
      gegl_buffer_get (gimp_drawable_get_buffer (d), GEGL_RECTANGLE (0, 0, W, H), 1,
                       format_for (s->storage), &out->raw[c], GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      memcpy (out->uuid[c], storage.map.entries[c].uuid, 16);
      const gchar *name = gimp_object_get_name (item);
      if (!name || strlen (name) >= sizeof out->names[c]) return GLIMS_STATUS_FAILED;
      g_strlcpy (out->names[c], name, sizeof out->names[c]);
      out->ids[c] = gimp_item_get_id (item);
      out->visible[c] = storage.visible[c];
    }
  if (s->saved_path)
    {
      GFile *expected = g_file_new_for_path (s->saved_path);
      GFile *actual = gimp_image_get_file (open->image);
      gboolean native_path = actual && g_file_equal (actual, expected);
      g_object_unref (expected);
      CHECK (native_path, "mapped XCF is the native saved file identity");
    }
  return GLIMS_STATUS_OK;
}

static gboolean
same_raw (const Scene *s, const RawPlane a[3], const RawPlane b[3])
{
  for (guint c = 0; c < 3; c++) if (memcmp (&a[c], &b[c], s->bytes)) return FALSE;
  return TRUE;
}

static gboolean
same_persistent (const Scene *s, const Snapshot *a, const Snapshot *b)
{
  return same_raw (s, a->raw, b->raw) && a->map_size == b->map_size &&
         !memcmp (a->map, b->map, a->map_size) && !memcmp (a->uuid, b->uuid, sizeof a->uuid) &&
         !memcmp (a->names, b->names, sizeof a->names) && !memcmp (a->visible, b->visible, sizeof a->visible);
}

static GlimsStatus
seed (GlimsEngine *engine, gpointer data)
{
  Scene *s = data;
  GlimsOpenImage *open;
  GlimsPlateStorage storage;
  if (!lookup (engine, s, &open, &storage)) return GLIMS_STATUS_FAILED;
  for (guint c = 0; c < 3; c++)
    {
      GimpDrawable *d = GIMP_DRAWABLE (storage.planes[c]);
      gegl_buffer_set (gimp_drawable_get_buffer (d), GEGL_RECTANGLE (0, 0, W, H), 0,
                       format_for (s->storage), &s->seed[c], GEGL_AUTO_ROWSTRIDE);
      gimp_drawable_update (d, 0, 0, W, H);
      gchar *name = g_strdup_printf ("Unrelated Lab plane name %u", 3 - c);
      gboolean renamed = gimp_item_rename (GIMP_ITEM (d), name, NULL);
      g_free (name);
      if (!renamed) return GLIMS_STATUS_FAILED;
    }
  if (!gimp_image_reorder_item (open->image, GIMP_ITEM (storage.planes[2]), NULL, 0, FALSE, NULL))
    return GLIMS_STATUS_FAILED;
  gimp_image_undo_free (open->image);
  if (capture (engine, s) != GLIMS_STATUS_OK || !same_raw (s, s->seed, s->actual.raw))
    return GLIMS_STATUS_FAILED;
  s->before = s->actual;
  return GLIMS_STATUS_OK;
}

static GlimsStatus
close_source (GlimsEngine *engine, gpointer data)
{
  Scene *s = data;
  GlimsOpenImage *open = glims_lookup_image (engine, s->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GWeakRef image;
  g_weak_ref_init (&image, G_OBJECT (open->image));
  GlimsStatus status = api->image_close (engine, s->id);
  GObject *remaining = g_weak_ref_get (&image);
  s->source_destroyed = remaining == NULL;
  g_clear_object (&remaining);
  g_weak_ref_clear (&image);
  return status;
}

int
main (int argc, char **argv)
{
  if (argc != 2) { fprintf (stderr, "usage: %s WORK\n", argv[0]); return 2; }
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof (GlimsEngineAPI, image_new_lab) + sizeof api->image_new_lab ||
      !api->image_new_lab) return 2;
  gchar *user = g_build_filename (argv[1], "user", NULL);
  gchar *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL;
  char *error = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    { fprintf (stderr, "start: %s\n", error ? error : "failed"); api->free_string (error); g_free (user); g_free (cache); return 2; }
  api->free_string (error); error = NULL;
  const guint components[] = { GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16, GLIMS_COLOR_COMPONENT_FLOAT };
  for (guint i = 0; i < G_N_ELEMENTS (components); i++)
    {
      Scene s = { .component = components[i], .storage = i + 1, .bytes = PIXELS * (i == 0 ? 1 : i == 1 ? 2 : 4) };
      GlimsStatus status = api->image_new_lab (engine, W, H, s.component, &s.id, &error);
      CHECK (status == GLIMS_STATUS_OK && s.id, "public factory creates mapped Lab for XCF persistence");
      api->free_string (error); error = NULL;
      if (!s.id) continue;
      literal_samples (&s);
      gboolean seeded = glims_engine_call (engine, seed, &s) == GLIMS_STATUS_OK;
      CHECK (seeded, "literal samples are exact after fixture renaming and native reordering");
      gchar *path = g_strdup_printf ("%s/mapped-lab-%u.xcf", argv[1], s.storage);
      if (seeded)
        {
          status = api->image_save (engine, s.id, path, &error);
          CHECK (status == GLIMS_STATUS_OK, "public save writes the mapped Lab XCF");
          if (error) fprintf (stderr, "save storage=%u: %s\n", s.storage, error);
          api->free_string (error); error = NULL;
          if (status == GLIMS_STATUS_OK)
            {
              s.saved_path = path;
              CHECK (glims_engine_call (engine, capture, &s) == GLIMS_STATUS_OK && same_persistent (&s, &s.before, &s.actual),
                     "save preserves exact sample bits, UUID mapping, names and visibility");
              GlimsImageID original = s.id;
              gboolean closed = glims_engine_call (engine, close_source, &s) == GLIMS_STATUS_OK;
              CHECK (closed && s.source_destroyed, "original adopted native image is destroyed before reopening");
              if (closed)
                {
                  s.id = 0;
                  status = api->image_open (engine, path, &s.id, &error);
                  CHECK (status == GLIMS_STATUS_OK && s.id && s.id != original, "public open loads a new native Lab image from the saved file");
                  if (error) fprintf (stderr, "open storage=%u: %s\n", s.storage, error);
                  api->free_string (error); error = NULL;
                  if (s.id)
                    {
                      GlimsColorInfo color = {0};
                      GlimsImageInfo dimensions = {0};
                      CHECK (api->image_color_info (engine, s.id, &color) == GLIMS_STATUS_OK &&
                             color.mode == GLIMS_COLOR_MODE_LAB && color.component == s.component,
                             "reopened facade mode remains Lab6 with the original native precision");
                      CHECK (api->image_info (engine, s.id, &dimensions) == GLIMS_STATUS_OK && dimensions.width == W && dimensions.height == H,
                             "reopened Lab canvas dimensions are exact");
                      gboolean captured = glims_engine_call (engine, capture, &s) == GLIMS_STATUS_OK;
                      CHECK (captured && same_persistent (&s, &s.before, &s.actual),
                             "XCF roundtrip preserves exact raw samples and durable ordered UUIDs without RGB conversion");
                      gboolean new_runtime_ids = captured;
                      for (guint c = 0; c < 3; c++) new_runtime_ids &= s.before.ids[c] != s.actual.ids[c];
                      CHECK (new_runtime_ids, "new runtime channel IDs still resolve to the same persisted identities");
                    }
                }
            }
        }
      if (s.id) CHECK (api->image_close (engine, s.id) == GLIMS_STATUS_OK, "roundtrip document closes");
      g_free (path);
      printf ("ROUNDTRIP storage=%u raw-bytes-per-plane=%zu\n", s.storage, s.bytes);
    }
  api->stop (engine);
  g_free (user); g_free (cache);
  printf ("%u mapped Lab roundtrip checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}

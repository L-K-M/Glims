/* Independent slot189 read-only native ink identity fixture.
 * Native callbacks seed/capture source state only; all tested identity queries
 * use the public facade. Expected UUID bytes come from native parasites, not the query. */
#include "engine-private.h"
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#include <float.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 8
#define H 2
#define PIXELS (W * H)
#define PLANES 4
#define MAX_BYTES (PIXELS * sizeof(float))

static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c, msg) do { gboolean pass = !!(c); checks++; \
  printf("%s %s\n", pass ? "ok" : "FAIL", msg); \
  if (!pass) failures++; fflush(stdout); } while (0)

typedef struct {
  GlimsImageID id;
  GlimsItemID ids[PLANES];
  uint32_t component, mode;
  size_t bytes, sample_size;
  gboolean masked;
  float mask[PIXELS];
  guint8 seed[PLANES][MAX_BYTES];
} Scene;

typedef struct {
  Scene *scene;
  guint8 raw[PLANES][MAX_BYTES];
  float mask[PIXELS];
  GBytes *map, *profile, *uuid[PLANES], *visibility[PLANES];
  char names[PLANES][256];
  GlimsItemID selected[PLANES];
  guint selected_count;
  gboolean locks[PLANES], dirty;
  int undo, redo, layers;
  GimpPrecision precision;
  guint64 revision;
  GFile *files[4];
} Snapshot;

static GBytes *parasite_bytes(const GimpParasite *p) {
  guint32 size = 0;
  const void *data = p ? gimp_parasite_get_data(p, &size) : NULL;
  return data ? g_bytes_new(data, size) : NULL;
}
static gboolean bytes_equal(GBytes *a, GBytes *b) {
  return (!a || !b) ? a == b : g_bytes_equal(a, b);
}
static void release_snapshot(Snapshot *s) {
  g_clear_pointer(&s->map, g_bytes_unref);
  g_clear_pointer(&s->profile, g_bytes_unref);
  for (unsigned p = 0; p < PLANES; p++) {
    g_clear_pointer(&s->uuid[p], g_bytes_unref);
    g_clear_pointer(&s->visibility[p], g_bytes_unref);
    g_clear_object(&s->files[p]);
  }
}

static GlimsStatus capture_native(GlimsEngine *engine, gpointer data) {
  Snapshot *s = data;
  Scene *scene = s->scene;
  GlimsOpenImage *open = glims_lookup_image(engine, scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image = open->image;
  GlimsPlateStorage storage;
  gboolean valid = glims_plate_storage_read_open(open, &storage);
  for (unsigned p = 0; p < PLANES; p++) {
    if (!scene->ids[p]) {
      if (!valid || storage.map.count != PLANES) return GLIMS_STATUS_FAILED;
      scene->ids[p] = gimp_item_get_id(GIMP_ITEM(storage.planes[p]));
    }
    GimpItem *item = gimp_item_get_by_id(engine->gimp, scene->ids[p]);
    if (!item || !GIMP_IS_CHANNEL(item) || gimp_item_get_image(item) != image)
      return GLIMS_STATUS_FAILED;
    GimpDrawable *drawable = GIMP_DRAWABLE(item);
    if ((size_t)babl_format_get_bytes_per_pixel(gimp_drawable_get_format(drawable)) != scene->sample_size ||
        babl_format_get_n_components(gimp_drawable_get_format(drawable)) != 1) return GLIMS_STATUS_FAILED;
    gegl_buffer_get(gimp_drawable_get_buffer(drawable), GEGL_RECTANGLE(0, 0, W, H),
                    1, gimp_drawable_get_format(drawable), s->raw[p],
                    GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    g_strlcpy(s->names[p], gimp_object_get_name(item), sizeof s->names[p]);
    s->uuid[p] = parasite_bytes(gimp_item_parasite_find(item, GLIMS_PLATE_UUID_PARASITE));
    s->visibility[p] = parasite_bytes(gimp_item_parasite_find(item, GLIMS_PLATE_VISIBLE_PARASITE));
    s->locks[p] = gimp_item_get_lock_content(item);
  }
  s->map = parasite_bytes(gimp_image_parasite_find(image, GLIMS_PLATE_MAP_PARASITE));
  s->profile = parasite_bytes(gimp_image_parasite_find(image, GLIMS_PLATE_PROFILE_PARASITE));
  gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(gimp_image_get_mask(image))),
                  GEGL_RECTANGLE(0, 0, W, H), 1, babl_format("Y float"), s->mask,
                  GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  s->selected_count = 0;
  for (GList *it = gimp_image_get_selected_channels(image); it; it = it->next) {
    if (s->selected_count == PLANES) return GLIMS_STATUS_FAILED;
    s->selected[s->selected_count++] = gimp_item_get_id(GIMP_ITEM(it->data));
  }
  s->undo = gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image));
  s->redo = gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image));
  s->revision = open->history_revision;
  s->dirty = gimp_image_is_dirty(image);
  s->layers = gimp_container_get_n_children(gimp_image_get_layers(image));
  s->precision = gimp_image_get_precision(image);
  s->files[0] = gimp_image_get_file(image);
  s->files[1] = gimp_image_get_imported_file(image);
  s->files[2] = gimp_image_get_exported_file(image);
  s->files[3] = gimp_image_get_save_a_copy_file(image);
  for (unsigned i = 0; i < 4; i++) if (s->files[i]) g_object_ref(s->files[i]);
  return GLIMS_STATUS_OK;
}
static gboolean capture(GlimsEngine *engine, Scene *scene, Snapshot *s) {
  memset(s, 0, sizeof *s); s->scene = scene;
  gboolean ok = glims_engine_call(engine, capture_native, s) == GLIMS_STATUS_OK;
  CHECK(ok, "capture independent raw planes, metadata and native history");
  return ok;
}
static gboolean same_metadata(const Snapshot *a, const Snapshot *b) {
  if (!bytes_equal(a->map, b->map) || !bytes_equal(a->profile, b->profile) ||
      memcmp(a->mask, b->mask, sizeof a->mask) ||
      a->layers != b->layers || a->precision != b->precision || a->selected_count != b->selected_count ||
      memcmp(a->selected, b->selected, sizeof a->selected)) return FALSE;
  for (unsigned p = 0; p < PLANES; p++) {
    if (!bytes_equal(a->uuid[p], b->uuid[p]) ||
        !bytes_equal(a->visibility[p], b->visibility[p]) ||
        strcmp(a->names[p], b->names[p]) || a->locks[p] != b->locks[p]) return FALSE;
    if ((!a->files[p] || !b->files[p]) ? a->files[p] != b->files[p]
                                      : !g_file_equal(a->files[p], b->files[p])) return FALSE;
  }
  return TRUE;
}
static gboolean same_pixels(const Scene *s, const Snapshot *a, const Snapshot *b) {
  for (unsigned p = 0; p < PLANES; p++)
    if (memcmp(a->raw[p], b->raw[p], s->bytes)) return FALSE;
  return TRUE;
}
static gboolean same_history(const Snapshot *a, const Snapshot *b) {
  return a->undo == b->undo && a->redo == b->redo &&
         a->revision == b->revision && a->dirty == b->dirty;
}

static void initialize_samples(Scene *s) {
  memset(s->seed, 0, sizeof s->seed);
  for (unsigned p = 0; p < PLANES; p++) for (unsigned i = 0; i < PIXELS; i++) {
    if (s->sample_size == 1) {
      const guint8 values[] = {64, 128, 192, 32};
      s->seed[p][i] = values[p];
    } else if (s->sample_size == 2) {
      const guint16 values[] = {16384, 32768, 49152, 8192};
      memcpy(s->seed[p] + i * 2, &values[p], 2);
    } else {
      const float values[] = {.25f, .5f, .75f, .125f};
      memcpy(s->seed[p] + i * 4, &values[p], 4);
    }
  }
}

static GlimsStatus prepare_native(GlimsEngine *engine, gpointer data) {
  Scene *s = data;
  GlimsOpenImage *open = glims_lookup_image(engine, s->id);
  GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open, &storage) || storage.map.count != PLANES)
    return GLIMS_STATUS_FAILED;
  GimpImage *image = open->image;
  if (gimp_container_get_n_children(gimp_image_get_layers(image)) != 0)
    return GLIMS_STATUS_FAILED;
  initialize_samples(s);
  for (unsigned p = 0; p < PLANES; p++) {
    GimpDrawable *drawable = GIMP_DRAWABLE(storage.planes[p]);
    if ((size_t)babl_format_get_bytes_per_pixel(gimp_drawable_get_format(drawable)) != s->sample_size ||
        babl_format_get_n_components(gimp_drawable_get_format(drawable)) != 1)
      return GLIMS_STATUS_FAILED;
    s->ids[p] = gimp_item_get_id(GIMP_ITEM(drawable));
    gimp_item_set_lock_content(GIMP_ITEM(drawable), FALSE, FALSE);
    gegl_buffer_set(gimp_drawable_get_buffer(drawable), GEGL_RECTANGLE(0, 0, W, H),
                    0, gimp_drawable_get_format(drawable), s->seed[p], GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(drawable, 0, 0, W, H);
    gchar *name = g_strdup_printf("Unrelated display name %u", PLANES - p);
    gboolean renamed = gimp_item_rename(GIMP_ITEM(drawable), name, NULL);
    g_free(name);
    if (!renamed) return GLIMS_STATUS_FAILED;
    guint8 visible = p == 3 ? 0 : 1;
    GimpParasite *tag = gimp_parasite_new(GLIMS_PLATE_VISIBLE_PARASITE, GIMP_PARASITE_PERSISTENT, 1, &visible);
    gimp_item_parasite_attach(GIMP_ITEM(drawable), tag, FALSE);
    gimp_parasite_free(tag);
  }
  GList *selected = g_list_append(NULL, storage.planes[0]);
  gimp_image_set_selected_channels(image, selected);
  g_list_free(selected);
  float requested[PIXELS];
  const float coverage[] = {0.f, .25f, .5f, 1.f};
  for (unsigned i = 0; i < PIXELS; i++) requested[i] = s->masked ? coverage[i % 4] : 0.f;
  GimpDrawable *mask = GIMP_DRAWABLE(gimp_image_get_mask(image));
  gegl_buffer_set(gimp_drawable_get_buffer(mask), GEGL_RECTANGLE(0, 0, W, H), 0,
                  babl_format("Y float"), requested, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(mask, 0, 0, W, H);
  gboolean empty = gimp_channel_is_empty(GIMP_CHANNEL(mask));
  if (empty == s->masked) return GLIMS_STATUS_FAILED;
  gegl_buffer_get(gimp_drawable_get_buffer(mask), GEGL_RECTANGLE(0, 0, W, H), 1,
                  babl_format("Y float"), s->mask, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  GFile *file = g_file_new_for_uri("file:///ink-channel-identity-fixture-source.xcf");
  gimp_image_set_file(image, file);
  gimp_image_set_imported_file(image, file);
  gimp_image_set_exported_file(image, file);
  gimp_image_set_save_a_copy_file(image, file);
  g_object_unref(file);
  gimp_image_undo_free(image);
  gimp_image_clean_all(image);
  return GLIMS_STATUS_OK;
}

static gboolean create_scene(GlimsEngine *engine, Scene *scene, uint32_t mode,
                              uint32_t component, const guint8 *icc, gsize length) {
  memset(scene, 0, sizeof *scene);
  scene->mode = mode; scene->component = component; scene->masked = TRUE;
  scene->sample_size = component == GLIMS_COLOR_COMPONENT_U8 ? 1 :
                       component == GLIMS_COLOR_COMPONENT_U16 ? 2 : 4;
  scene->bytes = PIXELS * scene->sample_size;
  char *error = NULL;
  GlimsStatus status = mode == GLIMS_PLATE_MODE_CMYK
    ? api->image_new_cmyk(engine, W, H, component, icc, length, &scene->id, &error)
    : api->image_new_multichannel(engine, W, H, component, PLANES, &scene->id, &error);
  CHECK(status == GLIMS_STATUS_OK && scene->id, "create native ink image");
  if (error) { fprintf(stderr, "%s\n", error); api->free_string(error); }
  if (status != GLIMS_STATUS_OK || !scene->id) return FALSE;
  gboolean prepared = glims_engine_call(engine, prepare_native, scene) == GLIMS_STATUS_OK;
  CHECK(prepared, "seed distinct raw planes, fractional selection and source identity");
  return prepared;
}

static void close_scene(GlimsEngine *engine, Scene *scene) {
  if (scene->id) CHECK(api->image_close(engine, scene->id) == GLIMS_STATUS_OK, "close fixture image");
  scene->id = 0;
}

static gboolean payload_zero(const GlimsInkChannelIdentity *identity) {
  const guint8 *bytes = (const guint8 *)identity;
  for (size_t i = sizeof identity->struct_size; i < sizeof *identity; i++)
    if (bytes[i]) return FALSE;
  return TRUE;
}

typedef struct {
  GlimsInkChannelIdentity identity;
  guint8 tail[20];
} ExtendedIdentity;

static void init_output(ExtendedIdentity *out) {
  memset(out, 0xa5, sizeof *out);
  out->identity.struct_size = sizeof *out;
}

static gboolean tail_preserved(const ExtendedIdentity *out) {
  const guint8 *bytes = (const guint8 *)out;
  for (size_t i = sizeof out->identity; i < sizeof *out; i++)
    if (bytes[i] != 0xa5) return FALSE;
  return out->identity.struct_size == sizeof *out;
}

static void refusal(GlimsEngine *engine, GlimsImageID image, GlimsItemID channel,
                    GlimsStatus expected, const char *message) {
  ExtendedIdentity out;
  init_output(&out);
  CHECK(api->image_ink_channel_identity(engine, image, channel, &out.identity) == expected, message);
  CHECK(payload_zero(&out.identity) && tail_preserved(&out),
        "refusal clears known payload, preserves caller size and extension bytes");
}

static gboolean query_set(GlimsEngine *engine, Scene *scene, const Snapshot *facts,
                           GlimsInkChannelIdentity rows[PLANES]) {
  gboolean success = TRUE;
  const uint32_t roles[] = {GLIMS_INK_ROLE_CYAN, GLIMS_INK_ROLE_MAGENTA,
                            GLIMS_INK_ROLE_YELLOW, GLIMS_INK_ROLE_BLACK};
  for (unsigned i = 0; i < PLANES; i++) {
    ExtendedIdentity out;
    init_output(&out);
    GlimsStatus status = api->image_ink_channel_identity(engine, scene->id, scene->ids[i], &out.identity);
    CHECK(status == GLIMS_STATUS_OK, "query selected and unselected native inks");
    CHECK(tail_preserved(&out), "successful query preserves caller size and extension tail");
    if (status != GLIMS_STATUS_OK) { success = FALSE; continue; }
    CHECK(out.identity.color_mode == (scene->mode == GLIMS_PLATE_MODE_CMYK
                                       ? GLIMS_COLOR_MODE_CMYK : GLIMS_COLOR_MODE_MULTICHANNEL),
          "query returns facade-owned image color mode");
    CHECK(out.identity.ordinal == i && out.identity.count == PLANES,
          "ordinal follows canonical persisted map, with complete count");
    CHECK(out.identity.role == (scene->mode == GLIMS_PLATE_MODE_CMYK ? roles[i] : GLIMS_INK_ROLE_UNSPECIFIED),
          "CMYK role follows canonical order; spot names do not imply CMYK roles");
    gsize length = 0;
    const guint8 *uuid = facts->uuid[i] ? g_bytes_get_data(facts->uuid[i], &length) : NULL;
    CHECK(uuid && length == 16 && !memcmp(out.identity.uuid, uuid, 16),
          "public UUID equals independently read native parasite bytes");
    guint8 nonzero = 0;
    for (unsigned b = 0; b < 16; b++) nonzero |= out.identity.uuid[b];
    CHECK(nonzero != 0, "UUID is nonzero");
    rows[i] = out.identity;
    rows[i].struct_size = sizeof rows[i];
  }
  return success;
}

typedef struct {
  Scene *scene;
  GlimsItemID mask;
  GlimsInkChannelIdentity identity;
  GlimsStatus query_status;
  unsigned damage;
} Probe;

static GlimsStatus mask_id_native(GlimsEngine *engine, gpointer data) {
  Probe *probe = data;
  GlimsOpenImage *open = glims_lookup_image(engine, probe->scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  probe->mask = gimp_item_get_id(GIMP_ITEM(gimp_image_get_mask(open->image)));
  return GLIMS_STATUS_OK;
}

static GlimsStatus busy_query_native(GlimsEngine *engine, gpointer data) {
  Probe *probe = data;
  probe->identity.struct_size = sizeof probe->identity;
  engine->busy++;
  probe->query_status = api->image_ink_channel_identity(engine, probe->scene->id,
                                                       probe->scene->ids[2], &probe->identity);
  engine->busy--;
  return GLIMS_STATUS_OK;
}

static GlimsStatus reorder_native(GlimsEngine *engine, gpointer data) {
  Scene *scene = data;
  GlimsOpenImage *open = glims_lookup_image(engine, scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpItem *item = gimp_item_get_by_id(engine->gimp, scene->ids[3]);
  if (!item || !gimp_image_reorder_item(open->image, item, NULL, 0, FALSE, NULL))
    return GLIMS_STATUS_FAILED;
  GList *channels = gimp_image_get_channel_list(open->image);
  gboolean first = channels && channels->data == item;
  g_list_free(channels);
  return first ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static GlimsStatus damage_native(GlimsEngine *engine, gpointer data) {
  Probe *probe = data;
  GlimsOpenImage *open = glims_lookup_image(engine, probe->scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (probe->damage == 0) {
    gimp_image_parasite_detach(open->image, GLIMS_PLATE_MAP_PARASITE, FALSE);
  } else if (probe->damage == 1) {
    GimpItem *a = gimp_item_get_by_id(engine->gimp, probe->scene->ids[0]);
    GimpItem *b = gimp_item_get_by_id(engine->gimp, probe->scene->ids[1]);
    const GimpParasite *uuid = gimp_item_parasite_find(a, GLIMS_PLATE_UUID_PARASITE);
    if (!uuid) return GLIMS_STATUS_FAILED;
    gimp_item_parasite_attach(b, uuid, FALSE);
  } else {
    const GimpParasite *profile = gimp_image_parasite_find(open->image, GLIMS_PLATE_PROFILE_PARASITE);
    guint32 size = 0;
    const guint8 *data = profile ? gimp_parasite_get_data(profile, &size) : NULL;
    if (!data || size < 128) return GLIMS_STATUS_FAILED;
    guint8 *changed = g_memdup2(data, size);
    changed[36] ^= 1;
    GimpParasite *bad = gimp_parasite_new(GLIMS_PLATE_PROFILE_PARASITE,
                                        GIMP_PARASITE_PERSISTENT, size, changed);
    gimp_image_parasite_attach(open->image, bad, FALSE);
    gimp_parasite_free(bad); g_free(changed);
  }
  return GLIMS_STATUS_OK;
}

static void unchanged(GlimsEngine *engine, Scene *scene, const Snapshot *before, const char *message) {
  Snapshot after = {0};
  if (capture(engine, scene, &after))
    CHECK(same_pixels(scene, before, &after) && same_metadata(before, &after) && same_history(before, &after), message);
  release_snapshot(&after);
}

static void run_case(GlimsEngine *engine, Scene *scene, const guint8 *icc, gsize length, const char *work) {
  Snapshot before = {0}, reordered = {0}, reopened_facts = {0};
  Scene other = {0};
  GlimsInkChannelIdentity original[PLANES] = {{0}}, current[PLANES] = {{0}};
  GlimsImageID rgb = 0;
  char *error = NULL, *path = NULL;
  if (!capture(engine, scene, &before) || !query_set(engine, scene, &before, original)) goto cleanup;
  unchanged(engine, scene, &before, "identity queries preserve fractional mask, selection, pixels, metadata, history and file identity");

  for (guint32 capacity = 0; capacity < sizeof(GlimsInkChannelIdentity); capacity++) {
    ExtendedIdentity out, copy;
    init_output(&out); out.identity.struct_size = capacity; copy = out;
    CHECK(api->image_ink_channel_identity(engine, scene->id, scene->ids[0], &out.identity) == GLIMS_STATUS_INVALID_ARGUMENT,
          "every short caller size is refused");
    CHECK(!memcmp(&out, &copy, sizeof out), "short output and surrounding canaries remain byte-exact");
  }
  CHECK(api->image_ink_channel_identity(engine, scene->id, scene->ids[0], NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
        "NULL output is refused");
  refusal(engine, -1, scene->ids[0], GLIMS_STATUS_NOT_FOUND, "invalid image is refused");
  refusal(engine, scene->id, 0, GLIMS_STATUS_NOT_FOUND, "implicit ink target is refused");
  refusal(engine, scene->id, -1, GLIMS_STATUS_NOT_FOUND, "stale/nonexistent ink ID is refused");
  refusal(NULL, scene->id, scene->ids[0], GLIMS_STATUS_NOT_RUNNING, "missing engine refuses and clears payload");
  Probe probe = {.scene = scene};
  CHECK(glims_engine_call(engine, mask_id_native, &probe) == GLIMS_STATUS_OK && probe.mask,
        "capture real selection-mask runtime ID");
  refusal(engine, scene->id, probe.mask, GLIMS_STATUS_NOT_FOUND, "selection mask is not an ink plane");
  CHECK(glims_engine_call(engine, busy_query_native, &probe) == GLIMS_STATUS_OK && probe.query_status == GLIMS_STATUS_OK,
        "read-only identity query remains available under native busy ownership");
  CHECK(!memcmp(&probe.identity, &original[2], sizeof probe.identity), "busy query returns identical identity");

  if (create_scene(engine, &other, scene->mode, scene->component, icc, length)) {
    GlimsInkChannelIdentity foreign = {.struct_size = sizeof foreign};
    CHECK(api->image_ink_channel_identity(engine, other.id, other.ids[0], &foreign) == GLIMS_STATUS_OK,
          "second document identity is readable");
    CHECK(memcmp(original[0].uuid, foreign.uuid, 16) != 0, "independently created documents have different UUIDs");
    refusal(engine, scene->id, other.ids[0], GLIMS_STATUS_NOT_FOUND, "foreign document ink ID is refused");
  }
  GlimsStatus created = api->image_new(engine, W, H, &rgb, &error);
  CHECK(created == GLIMS_STATUS_OK && rgb, "create ordinary RGB document");
  api->free_string(error); error = NULL;
  if (created == GLIMS_STATUS_OK && rgb)
    refusal(engine, rgb, scene->ids[0], GLIMS_STATUS_UNSUPPORTED, "ordinary RGB cannot claim ink identity");
  unchanged(engine, scene, &before, "successful busy reads and all refusals leave source unchanged");

  GlimsChannelChange change = {.struct_size = sizeof change, .properties = GLIMS_CHANNEL_NAME};
  g_strlcpy(change.name, "A name that is not a process color", sizeof change.name);
  CHECK(api->channel_change(engine, scene->id, scene->ids[0], &change, &error) == GLIMS_STATUS_OK,
        "rename through public native channel operation");
  api->free_string(error); error = NULL;
  CHECK(glims_engine_call(engine, reorder_native, scene) == GLIMS_STATUS_OK,
        "reorder native channel container while retaining persisted map");
  if (capture(engine, scene, &reordered) && query_set(engine, scene, &reordered, current))
    CHECK(!memcmp(original, current, sizeof original), "rename and container reorder preserve UUID, ordinal and CMYK role");
  unchanged(engine, scene, &reordered, "queries of renamed/reordered inks do not mutate source");

  path = g_strdup_printf("%s/identity-%u-%u.xcf", work, scene->mode, scene->component);
  CHECK(api->image_save(engine, scene->id, path, &error) == GLIMS_STATUS_OK, "save component identity in native XCF");
  api->free_string(error); error = NULL;
  GlimsItemID old_ids[PLANES]; memcpy(old_ids, scene->ids, sizeof old_ids);
  close_scene(engine, scene);
  memset(scene->ids, 0, sizeof scene->ids);
  CHECK(api->image_open(engine, path, &scene->id, &error) == GLIMS_STATUS_OK && scene->id,
        "reopen saved native component XCF");
  if (error) { fprintf(stderr, "%s\n", error); api->free_string(error); error = NULL; }
  if (scene->id && capture(engine, scene, &reopened_facts) && query_set(engine, scene, &reopened_facts, current)) {
    CHECK(!memcmp(original, current, sizeof original), "XCF reopening preserves every durable identity field");
    for (unsigned i = 0; i < PLANES; i++)
      CHECK(scene->ids[i] != old_ids[i], "reopened plane has a new runtime ID");
    CHECK(same_pixels(scene, &reordered, &reopened_facts) && bytes_equal(reordered.map, reopened_facts.map) &&
          bytes_equal(reordered.profile, reopened_facts.profile), "XCF preserves raw pixels, canonical map and exact profile");
    unchanged(engine, scene, &reopened_facts, "reopened identity reads preserve source state");
  }
cleanup:
  api->free_string(error); g_free(path);
  if (rgb) CHECK(api->image_close(engine, rgb) == GLIMS_STATUS_OK, "close RGB fixture image");
  close_scene(engine, &other);
  release_snapshot(&before); release_snapshot(&reordered); release_snapshot(&reopened_facts);
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s PRIVATE_WORK EXTERNAL_CMYK_ICC\n", argv[0]); return 2; }
  gchar *icc = NULL; gsize length = 0;
  if (!g_file_get_contents(argv[2], &icc, &length, NULL) || length < 128 || length > 4u * 1024u * 1024u) {
    fprintf(stderr, "External bounded CMYK profile unavailable\n"); g_free(icc); return 2;
  }
  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_ink_channel_identity) + sizeof api->image_ink_channel_identity ||
      !api->image_ink_channel_identity) {
    fprintf(stderr, "Adapter lacks slot189\n"); g_free(icc); return 2;
  }
  gchar *user = g_build_filename(argv[1], "user", NULL), *cache = g_build_filename(argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus status = api->start(&config, &engine, &error);
  g_free(user); g_free(cache);
  if (status != GLIMS_STATUS_OK || !engine) {
    fprintf(stderr, "Engine start failed: %s\n", error ? error : "unknown"); api->free_string(error); g_free(icc); return 2;
  }
  api->free_string(error);
  const uint32_t components[] = {GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16, GLIMS_COLOR_COMPONENT_FLOAT};
  for (uint32_t mode = GLIMS_PLATE_MODE_MULTICHANNEL; mode <= GLIMS_PLATE_MODE_CMYK; mode++)
    for (unsigned i = 0; i < G_N_ELEMENTS(components); i++) {
      Scene scene = {0};
      printf("CASE mode=%u component=%u\n", mode, components[i]);
      if (create_scene(engine, &scene, mode, components[i], (guint8 *)icc, length))
        run_case(engine, &scene, (guint8 *)icc, length, argv[1]);
      close_scene(engine, &scene);
    }
  for (unsigned damage = 0; damage < 3; damage++) {
    Scene scene = {0};
    if (create_scene(engine, &scene, GLIMS_PLATE_MODE_CMYK, GLIMS_COLOR_COMPONENT_U8, (guint8 *)icc, length)) {
      Probe probe = {.scene = &scene, .damage = damage};
      CHECK(glims_engine_call(engine, damage_native, &probe) == GLIMS_STATUS_OK,
            "prepare malformed map, duplicate UUID or damaged ICC");
      Snapshot before = {0};
      if (capture(engine, &scene, &before)) {
        refusal(engine, scene.id, scene.ids[0], GLIMS_STATUS_UNSUPPORTED, "malformed component storage is refused");
        unchanged(engine, &scene, &before, "malformed-storage refusal does not repair or edit the source");
      }
      release_snapshot(&before);
    }
    close_scene(engine, &scene);
  }
  api->stop(engine); g_free(icc);
  printf("checks=%u failures=%u\n", checks, failures);
  return failures ? 1 : 0;
}


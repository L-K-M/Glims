/* Independent slot191 read-only Lab axis metadata fixture.
 * Native callbacks seed/capture source state only; all tested metadata queries
 * use the public facade. Expected UUID/name/selection values come from native
 * parasites, display names and native selected-channel lists, never the query. */
#include "engine-private.h"
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplist.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#include <float.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define W 8
#define H 2
#define PIXELS (W * H)
#define AXES 3
#define MAX_BYTES (PIXELS * sizeof(float))

static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c, msg) do { gboolean pass = !!(c); checks++; \
  printf("%s %s\n", pass ? "ok" : "FAIL", msg); \
  if (!pass) failures++; fflush(stdout); } while (0)

typedef struct {
  GlimsImageID id;
  GlimsItemID ids[AXES];
  uint32_t component;
  size_t bytes, sample_size;
  float mask[PIXELS];
  guint8 seed[AXES][MAX_BYTES];
} Scene;

typedef struct {
  Scene *scene;
  guint8 raw[AXES][MAX_BYTES];
  float mask[PIXELS];
  GBytes *map, *profile, *uuid[AXES], *visibility[AXES];
  char *names[AXES]; /* full native source names, not truncated oracle capture */
  uint32_t selected[AXES];
  GlimsItemID order[AXES], selection[AXES];
  guint selected_count;
  gboolean native_visible[AXES], locked[AXES];
  int undo, redo, layers;
  GimpPrecision precision;
  guint64 revision;
  guint component_mode;
  gboolean dirty;
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
  if (!s) return;
  g_clear_pointer(&s->map, g_bytes_unref);
  g_clear_pointer(&s->profile, g_bytes_unref);
  for (unsigned i = 0; i < AXES; i++) {
    g_clear_pointer(&s->uuid[i], g_bytes_unref);
    g_clear_pointer(&s->visibility[i], g_bytes_unref);
    g_free(s->names[i]); s->names[i] = NULL;
    g_clear_object(&s->files[i]);
  }
  g_clear_object(&s->files[3]);
}

static GlimsStatus capture_native(GlimsEngine *engine, gpointer data) {
  Snapshot *s = data;
  Scene *scene = s->scene;
  GlimsOpenImage *open = glims_lookup_image(engine, scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image = open->image;
  GlimsPlateStorage storage;
  gboolean valid = glims_plate_storage_read_open(open, &storage);
  for (unsigned a = 0; a < AXES; a++) {
    if (!scene->ids[a]) {
      if (!valid || storage.map.count != AXES) return GLIMS_STATUS_FAILED;
      scene->ids[a] = gimp_item_get_id(GIMP_ITEM(storage.planes[a]));
    }
    GimpItem *item = gimp_item_get_by_id(engine->gimp, scene->ids[a]);
    if (!item || !GIMP_IS_CHANNEL(item) || gimp_item_get_image(item) != image)
      return GLIMS_STATUS_FAILED;
    GimpDrawable *drawable = GIMP_DRAWABLE(item);
    if ((size_t)babl_format_get_bytes_per_pixel(gimp_drawable_get_format(drawable)) != scene->sample_size ||
        babl_format_get_n_components(gimp_drawable_get_format(drawable)) != 1) return GLIMS_STATUS_FAILED;
    gegl_buffer_get(gimp_drawable_get_buffer(drawable), GEGL_RECTANGLE(0, 0, W, H),
                    1, gimp_drawable_get_format(drawable), s->raw[a],
                    GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    s->names[a] = g_strdup(gimp_object_get_name(item)); /* full native name */
    s->uuid[a] = parasite_bytes(gimp_item_parasite_find(item, GLIMS_PLATE_UUID_PARASITE));
    s->visibility[a] = parasite_bytes(gimp_item_parasite_find(item, GLIMS_PLATE_VISIBLE_PARASITE));
    s->native_visible[a] = gimp_item_get_visible(item);
    s->locked[a] = gimp_item_get_lock_content(item);
  }
  s->map = parasite_bytes(gimp_image_parasite_find(image, GLIMS_PLATE_MAP_PARASITE));
  s->profile = parasite_bytes(gimp_image_parasite_find(image, GLIMS_PLATE_PROFILE_PARASITE));
  GList *order = gimp_image_get_channel_list(image);
  guint index = 0;
  for (GList *it = order; it && index < AXES; it = it->next)
    s->order[index++] = gimp_item_get_id(GIMP_ITEM(it->data));
  g_list_free(order);
  if (index != AXES) return GLIMS_STATUS_FAILED;
  gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(gimp_image_get_mask(image))),
                  GEGL_RECTANGLE(0, 0, W, H), 1, babl_format("Y float"), s->mask,
                  GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  for (unsigned a = 0; a < AXES; a++) s->selected[a] = 0;
  for (GList *it = gimp_image_get_selected_channels(image); it; it = it->next) {
    GlimsItemID sid = gimp_item_get_id(GIMP_ITEM(it->data));
    if (s->selected_count >= AXES) return GLIMS_STATUS_FAILED;
    s->selection[s->selected_count++] = sid;
    for (unsigned a = 0; a < AXES; a++)
      if (sid == scene->ids[a]) s->selected[a] = 1;
  }
  s->undo = gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image));
  s->redo = gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image));
  s->revision = open->history_revision;
  s->component_mode = open->component_mode;
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
  CHECK(ok, "capture independent raw axes, metadata and native history");
  return ok;
}
static gboolean same_pixels(const Scene *scene, const Snapshot *a, const Snapshot *b) {
  for (unsigned i = 0; i < AXES; i++)
    if (memcmp(a->raw[i], b->raw[i], scene->bytes)) return FALSE;
  return TRUE;
}
static gboolean same_metadata(const Snapshot *a, const Snapshot *b) {
  if (!bytes_equal(a->map, b->map) || !bytes_equal(a->profile, b->profile) ||
      memcmp(a->mask, b->mask, sizeof a->mask) ||
      memcmp(a->order, b->order, sizeof a->order) ||
      a->selected_count != b->selected_count ||
      memcmp(a->selection, b->selection, sizeof a->selection) ||
      memcmp(a->native_visible, b->native_visible, sizeof a->native_visible) ||
      memcmp(a->locked, b->locked, sizeof a->locked) ||
      a->component_mode != b->component_mode ||
      a->layers != b->layers || a->precision != b->precision ||
      memcmp(a->selected, b->selected, sizeof a->selected)) return FALSE;
  for (unsigned i = 0; i < AXES; i++) {
    if (!bytes_equal(a->uuid[i], b->uuid[i]) ||
        !bytes_equal(a->visibility[i], b->visibility[i])) return FALSE;
    if ((!a->names[i] || !b->names[i]) ? a->names[i] != b->names[i] : strcmp(a->names[i], b->names[i]))
      return FALSE;
  }
  for (unsigned i = 0; i < 4; i++)
    if ((!a->files[i] || !b->files[i]) ? a->files[i] != b->files[i]
                                      : !g_file_equal(a->files[i], b->files[i])) return FALSE;
  return TRUE;
}
static gboolean same_history(const Snapshot *a, const Snapshot *b) {
  return a->undo == b->undo && a->redo == b->redo && a->revision == b->revision && a->dirty == b->dirty;
}
static void unchanged(GlimsEngine *engine, Scene *scene, const Snapshot *before, const char *message) {
  Snapshot *after = g_new0(Snapshot, 1);
  if (capture(engine, scene, after))
    CHECK(same_pixels(scene, before, after) && same_metadata(before, after) && same_history(before, after), message);
  release_snapshot(after); g_free(after);
}

static void seed_values(Scene *s) {
  memset(s->seed, 0, sizeof s->seed);
  for (unsigned a = 0; a < AXES; a++) for (unsigned i = 0; i < PIXELS; i++) {
    if (s->component == GLIMS_COLOR_COMPONENT_U8) {
      s->seed[a][i] = (guint8)(30 + a * 70 + i);
    } else if (s->component == GLIMS_COLOR_COMPONENT_U16) {
      guint16 v = (guint16)(1000 + a * 12000 + i * 17);
      memcpy(s->seed[a] + i * 2, &v, 2);
    } else {
      float v = (0.1f + 0.2f * a + 0.01f * i);
      memcpy(s->seed[a] + i * 4, &v, 4);
      if (a == 2 && i == 5) {
        const uint32_t qnan = UINT32_C(0x7fc12345);
        memcpy(s->seed[a] + i * 4, &qnan, sizeof qnan);
      }
    }
  }
}

static GlimsStatus prepare_native(GlimsEngine *engine, gpointer data) {
  Scene *s = data;
  GlimsOpenImage *open = glims_lookup_image(engine, s->id);
  GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open, &storage) || storage.map.count != AXES)
    return GLIMS_STATUS_FAILED;
  seed_values(s);
  for (unsigned a = 0; a < AXES; a++) {
    GimpDrawable *drawable = GIMP_DRAWABLE(storage.planes[a]);
    if ((size_t)babl_format_get_bytes_per_pixel(gimp_drawable_get_format(drawable)) != s->sample_size ||
        babl_format_get_n_components(gimp_drawable_get_format(drawable)) != 1) return GLIMS_STATUS_FAILED;
    s->ids[a] = gimp_item_get_id(GIMP_ITEM(drawable));
    gegl_buffer_set(gimp_drawable_get_buffer(drawable), GEGL_RECTANGLE(0, 0, W, H), 0,
                    gimp_drawable_get_format(drawable), s->seed[a], GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(drawable, 0, 0, W, H);
  }
  /* fractional mask */
  const float coverage[] = {0.f, .25f, .5f, 1.f};
  float requested[PIXELS];
  for (unsigned i = 0; i < PIXELS; i++) requested[i] = coverage[i % 4];
  GimpDrawable *mask = GIMP_DRAWABLE(gimp_image_get_mask(open->image));
  gegl_buffer_set(gimp_drawable_get_buffer(mask), GEGL_RECTANGLE(0, 0, W, H), 0,
                  babl_format("Y float"), requested, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(mask, 0, 0, W, H);
  gegl_buffer_get(gimp_drawable_get_buffer(mask), GEGL_RECTANGLE(0, 0, W, H), 1,
                  babl_format("Y float"), s->mask, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  if (gimp_channel_is_empty(GIMP_CHANNEL(mask))) return GLIMS_STATUS_FAILED;
  /* select axis B explicitly */
  GList *selected = g_list_append(NULL, storage.planes[2]);
  gimp_image_set_selected_channels(open->image, selected);
  g_list_free(selected);
  GFile *file = g_file_new_for_uri("file:///lab-axis-state-fixture.xcf");
  gimp_image_set_file(open->image, file);
  gimp_image_set_imported_file(open->image, file);
  gimp_image_set_exported_file(open->image, file);
  gimp_image_set_save_a_copy_file(open->image, file);
  g_object_unref(file);
  gimp_image_undo_free(open->image);
  gimp_image_clean_all(open->image);
  return GLIMS_STATUS_OK;
}

static gboolean create_lab(GlimsEngine *engine, Scene *scene, uint32_t component) {
  memset(scene, 0, sizeof *scene);
  scene->component = component;
  scene->sample_size = component == GLIMS_COLOR_COMPONENT_U8 ? 1 :
                       component == GLIMS_COLOR_COMPONENT_U16 ? 2 : 4;
  scene->bytes = PIXELS * scene->sample_size;
  char *error = NULL;
  GlimsStatus status = api->image_new_lab(engine, W, H, component, &scene->id, &error);
  CHECK(status == GLIMS_STATUS_OK && scene->id, "create native Lab image");
  if (error) { fprintf(stderr, "%s\n", error); api->free_string(error); }
  if (status != GLIMS_STATUS_OK || !scene->id) return FALSE;
  GlimsLabAxes fresh = { .struct_size = sizeof fresh };
  CHECK(api->image_lab_axes(engine, scene->id, &fresh) == GLIMS_STATUS_OK &&
        fresh.count == AXES && fresh.component == component,
        "fresh Lab factory metadata reports facade precision and three axes");
  gboolean prepared = glims_engine_call(engine, prepare_native, scene) == GLIMS_STATUS_OK;
  CHECK(prepared, "seed raw axes, fractional mask and axis selection");
  return prepared;
}
static void close_scene(GlimsEngine *engine, Scene *scene) {
  if (scene->id) CHECK(api->image_close(engine, scene->id) == GLIMS_STATUS_OK, "close fixture image");
  scene->id = 0;
}

static gboolean payload_zero(const GlimsLabAxes *out) {
  const guint8 *bytes = (const guint8 *)out;
  for (size_t i = sizeof out->struct_size; i < sizeof *out; i++)
    if (bytes[i]) return FALSE;
  return out->count == 0;
}
typedef struct { GlimsLabAxes axes; guint8 tail[32]; } ExtAxes;
static void init_out(ExtAxes *out) { memset(out, 0xA5, sizeof *out); out->axes.struct_size = sizeof *out; }
static gboolean tail_ok(const ExtAxes *out) {
  const guint8 *b = (const guint8 *)out;
  for (size_t i = sizeof out->axes; i < sizeof *out; i++) if (b[i] != 0xA5) return FALSE;
  return out->axes.struct_size == sizeof *out;
}

/* Independent UTF-8 code-point walk. Literal boundary tests below additionally
 * assert exact byte lengths, so this oracle cannot hide an off-by-one prefix. */
static void trunc_expect(const char *src, char expected[256]) {
  memset(expected, 0, 256);
  size_t length = 0;
  if (!g_utf8_validate(src, -1, NULL)) return;
  for (const char *next = src; *next;) {
    const char *end = g_utf8_next_char(next);
    if ((size_t)(end - src) > 255) break;
    length = (size_t)(end - src);
    next = end;
  }
  memcpy(expected, src, length);
}

static void refusal(GlimsEngine *engine, GlimsImageID image, GlimsStatus expected, const char *msg) {
  ExtAxes out; init_out(&out);
  CHECK(api->image_lab_axes(engine, image, &out.axes) == expected, msg);
  CHECK(payload_zero(&out.axes) && tail_ok(&out),
        "refusal clears known payload, preserves caller size and extension tail");
}

static gboolean query_and_check(GlimsEngine *engine, Scene *scene, const Snapshot *facts,
                                GlimsLabAxes *rows) {
  ExtAxes out; init_out(&out);
  GlimsStatus st = api->image_lab_axes(engine, scene->id, &out.axes);
  CHECK(st == GLIMS_STATUS_OK, "query Lab axes metadata");
  CHECK(tail_ok(&out), "successful query preserves caller size and extension tail");
  if (st != GLIMS_STATUS_OK) return FALSE;
  CHECK(out.axes.count == 3 && out.axes.component == scene->component,
        "success reports count 3 and facade component");
  for (unsigned a = 0; a < AXES; a++) {
    const GlimsLabAxisInfo *ax = &out.axes.axes[a];
    CHECK(ax->id == scene->ids[a], "axis id matches canonical map/native plane");
    CHECK(ax->role == a, "canonical map order roles L,a,b regardless of names/list");
    CHECK(ax->selected == facts->selected[a], "selected flag reflects native selection");
    gsize ulen = 0;
    const guint8 *uuid = facts->uuid[a] ? g_bytes_get_data(facts->uuid[a], &ulen) : NULL;
    CHECK(uuid && ulen == 16 && !memcmp(ax->uuid, uuid, 16),
          "UUID equals independently read native parasite bytes");
    guint8 nonzero = 0;
    for (unsigned i = 0; i < 16; i++) nonzero |= ax->uuid[i];
    CHECK(nonzero != 0, "axis UUID is nonzero");
    for (unsigned previous = 0; previous < a; previous++)
      CHECK(memcmp(ax->uuid, out.axes.axes[previous].uuid, 16) != 0, "axis UUIDs are distinct");
    char expected[256]; trunc_expect(facts->names[a] ? facts->names[a] : "", expected);
    CHECK(memcmp(ax->name, expected, 256) == 0, "name is UTF-8 truncated at character boundary to 255 bytes");
  }
  if (rows) { *rows = out.axes; rows->struct_size = sizeof *rows; }
  return TRUE;
}

typedef struct { Scene *scene; uint32_t mode; GlimsItemID ids[AXES]; } Damage;
static GlimsStatus damage_native(GlimsEngine *engine, gpointer data) {
  Damage *d = data;
  GlimsOpenImage *open = glims_lookup_image(engine, d->scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (d->mode == 0) { /* missing map */
    gimp_image_parasite_detach(open->image, GLIMS_PLATE_MAP_PARASITE, FALSE);
    return GLIMS_STATUS_OK;
  }
  if (d->mode == 1) { /* duplicate UUID */
    GimpItem *a = gimp_item_get_by_id(engine->gimp, d->ids[0]);
    GimpItem *b = gimp_item_get_by_id(engine->gimp, d->ids[1]);
    const GimpParasite *u = a ? gimp_item_parasite_find(a, GLIMS_PLATE_UUID_PARASITE) : NULL;
    if (!u || !b) return GLIMS_STATUS_FAILED;
    gimp_item_parasite_attach(b, u, FALSE);
    return GLIMS_STATUS_OK;
  }
  GimpItem *item = gimp_item_get_by_id(engine->gimp, d->ids[1]);
  if (!item) return GLIMS_STATUS_FAILED;
  if (d->mode == 2) {
    const guint8 hidden = 0;
    GimpParasite *p = gimp_parasite_new(GLIMS_PLATE_VISIBLE_PARASITE,
      GIMP_PARASITE_PERSISTENT, 1, &hidden);
    gimp_item_parasite_attach(item, p, FALSE);
    gimp_parasite_free(p);
  } else if (d->mode == 3) {
    gimp_item_parasite_detach(item, GLIMS_PLATE_UUID_PARASITE, FALSE);
  } else {
    /* Version 0 is invalid. Copy the actual map; no invented wire struct. */
    const GimpParasite *p = gimp_image_parasite_find(open->image, GLIMS_PLATE_MAP_PARASITE);
    guint32 size = 0;
    const guint8 *bytes = p ? gimp_parasite_get_data(p, &size) : NULL;
    if (!bytes || size < 12 || size > GLIMS_PLATE_MAP_MAX_SIZE) return GLIMS_STATUS_FAILED;
    guint8 *bad = g_memdup2(bytes, size);
    memset(bad + 8, 0, 4);
    GimpParasite *damaged = gimp_parasite_new(GLIMS_PLATE_MAP_PARASITE,
      GIMP_PARASITE_PERSISTENT, size, bad);
    gimp_image_parasite_attach(open->image, damaged, FALSE);
    gimp_parasite_free(damaged);
    g_free(bad);
  }
  return GLIMS_STATUS_OK;
}

typedef struct { Scene *scene; GlimsLabAxes out; GlimsStatus st; GlimsItemID ids[AXES]; } Probe;
static GlimsStatus busy_query_native(GlimsEngine *engine, gpointer data) {
  Probe *p = data;
  memset(&p->out, 0, sizeof p->out); p->out.struct_size = sizeof p->out;
  engine->busy++;
  p->st = api->image_lab_axes(engine, p->scene->id, &p->out);
  engine->busy--;
  return GLIMS_STATUS_OK;
}
/* Exact literal source strings: duplicate display names deliberately exercise
 * identity independent of GimpList's normal user-facing name uniquification. */
typedef struct { Scene *scene; const char *name; gboolean reorder; } NameProbe;
static GlimsStatus names_native(GlimsEngine *engine, gpointer data) {
  NameProbe *p = data;
  GlimsOpenImage *open = glims_lookup_image(engine, p->scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpContainer *channels = gimp_image_get_channels(open->image);
  if (!GIMP_IS_LIST(channels)) return GLIMS_STATUS_FAILED;
  GimpList *list = GIMP_LIST(channels);
  gboolean unique = list->unique_names;
  list->unique_names = FALSE;
  gboolean renamed = TRUE;
  for (unsigned a = 0; a < AXES; a++) {
    GimpItem *item = gimp_item_get_by_id(engine->gimp, p->scene->ids[a]);
    if (!item) { renamed = FALSE; break; }
    gimp_object_set_name(GIMP_OBJECT(item), p->name);
    if (strcmp(gimp_object_get_name(item), p->name)) renamed = FALSE;
  }
  list->unique_names = unique;
  if (!renamed) return GLIMS_STATUS_FAILED;
  if (p->reorder) {
    GimpItem *top = gimp_item_get_by_id(engine->gimp, p->scene->ids[2]);
    if (!top || !gimp_image_reorder_item(open->image, top, NULL, 0, FALSE, NULL))
      return GLIMS_STATUS_FAILED;
    GList *ordered = gimp_image_get_channel_list(open->image);
    gboolean moved = ordered && ordered->data == top;
    g_list_free(ordered);
    if (!moved) return GLIMS_STATUS_FAILED;
  }
  return GLIMS_STATUS_OK;
}
static GlimsStatus mismatch_cache_native(GlimsEngine *engine, gpointer data) {
  Scene *s = data;
  GlimsOpenImage *open = glims_lookup_image(engine, s->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  open->component_mode = GLIMS_PLATE_MODE_MULTICHANNEL; /* distinct from adopted Lab */
  return GLIMS_STATUS_OK;
}
static GlimsStatus restore_cache_native(GlimsEngine *engine, gpointer data) {
  Scene *s = data;
  GlimsOpenImage *open = glims_lookup_image(engine, s->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  open->component_mode = GLIMS_PLATE_MODE_LAB;
  return GLIMS_STATUS_OK;
}

static void run_case(GlimsEngine *engine, uint32_t component) {
  Scene scene = {0};
  if (!create_lab(engine, &scene, component)) { close_scene(engine, &scene); return; }
  Snapshot *before = g_new0(Snapshot, 1);
  GlimsLabAxes original = {0};
  if (!capture(engine, &scene, before) || !query_and_check(engine, &scene, before, &original))
    goto cleanup;
  for (unsigned a = 0; a < AXES; a++)
    CHECK(!memcmp(before->raw[a], scene.seed[a], scene.bytes),
          "independent raw snapshot contains exact seeded samples (including float NaN payload)");
  unchanged(engine, &scene, before, "Lab axes query preserves mask, selection, pixels, metadata, history and file identity");

  /* short/NULL output ABI */
  for (guint32 cap = 0; cap < sizeof(GlimsLabAxes); cap++) {
    ExtAxes out, copy; init_out(&out); out.axes.struct_size = cap; copy = out;
    CHECK(api->image_lab_axes(engine, scene.id, &out.axes) == GLIMS_STATUS_INVALID_ARGUMENT,
          "every short caller size is refused");
    CHECK(!memcmp(&out, &copy, sizeof out), "short output and surrounding canaries remain byte-exact");
  }
  CHECK(api->image_lab_axes(engine, scene.id, NULL) == GLIMS_STATUS_INVALID_ARGUMENT, "NULL output refused");
  /* Guard pages make accidental known-size reads/writes observable without
   * risking any unrelated memory. Map/protect failures fail the fixture. */
  {
    long ps = sysconf(_SC_PAGESIZE);
    CHECK(ps > (long)sizeof(GlimsLabAxes), "guard-page size can contain complete output");
    if (ps > (long)sizeof(GlimsLabAxes)) {
      guint8 *pages = mmap(NULL, (size_t)ps * 2, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANON, -1, 0);
      CHECK(pages != MAP_FAILED, "allocate ABI guard pages");
      if (pages != MAP_FAILED) {
        int protected = mprotect(pages + ps, (size_t)ps, PROT_NONE);
        CHECK(protected == 0, "protect ABI guard page");
        if (protected == 0) {
          guint8 *guard = pages + ps - sizeof(uint32_t);
          GlimsLabAxes *short_out = (GlimsLabAxes *)guard;
          const uint32_t capacities[] = {0, 4, sizeof(GlimsLabAxes) - 1};
          for (unsigned i = 0; i < G_N_ELEMENTS(capacities); i++) {
            memcpy(guard, &capacities[i], sizeof(uint32_t));
            CHECK(api->image_lab_axes(engine, scene.id, short_out) == GLIMS_STATUS_INVALID_ARGUMENT,
                  "short output with only struct_size readable is refused");
            CHECK(!memcmp(guard, &capacities[i], sizeof(uint32_t)),
                  "short output header remains byte-exact at guard page");
          }
          GlimsLabAxes *edge = (GlimsLabAxes *)(pages + ps - sizeof(GlimsLabAxes));
          memset(edge, 0xA5, sizeof *edge);
          edge->struct_size = sizeof *edge;
          CHECK(api->image_lab_axes(engine, scene.id, edge) == GLIMS_STATUS_OK,
                "valid known-size output ending at guard page succeeds");
        }
        munmap(pages, (size_t)ps * 2);
      }
    }
  }
  /* future-capacity ABI */
  {
    size_t bigsz = sizeof(GlimsLabAxes) + 32;
    guint8 *mem = g_malloc(bigsz); memset(mem, 0xA5, bigsz);
    GlimsLabAxes *big = (GlimsLabAxes *)mem; big->struct_size = (uint32_t)bigsz;
    CHECK(api->image_lab_axes(engine, scene.id, big) == GLIMS_STATUS_OK, "future-capacity query succeeds");
    CHECK(big->struct_size == (uint32_t)bigsz, "success preserves future struct_size");
    gboolean tail = TRUE; for (size_t i = sizeof(GlimsLabAxes); i < bigsz; i++) if (mem[i] != 0xA5) tail = FALSE;
    CHECK(tail, "success leaves extension tail A5");
    memset(mem, 0xA5, bigsz); big->struct_size = (uint32_t)bigsz;
    CHECK(api->image_lab_axes(engine, -1, big) == GLIMS_STATUS_NOT_FOUND, "future-capacity error returns NOT_FOUND");
    CHECK(big->struct_size == (uint32_t)bigsz, "error preserves future struct_size");
    tail = TRUE; for (size_t i = sizeof(GlimsLabAxes); i < bigsz; i++) if (mem[i] != 0xA5) tail = FALSE;
    CHECK(tail && payload_zero(big), "error leaves extension tail A5 and zero known payload");
    g_free(mem);
  }

  refusal(engine, -1, GLIMS_STATUS_NOT_FOUND, "unknown image sentinel refused");
  refusal(engine, 0, GLIMS_STATUS_NOT_FOUND, "zero image id refused");
  refusal(NULL, scene.id, GLIMS_STATUS_NOT_RUNNING, "NULL engine refused");
  /* stopping engine */
  {
    ExtAxes out; init_out(&out);
    /* No concurrent fixture calls. Change admission under the lock, but never
     * hold that lock across the public call (the transport acquires it). */
    g_mutex_lock(&engine->lock);
    engine->stopping = TRUE;
    g_mutex_unlock(&engine->lock);
    GlimsStatus st = api->image_lab_axes(engine, scene.id, &out.axes);
    g_mutex_lock(&engine->lock);
    engine->stopping = FALSE;
    g_mutex_unlock(&engine->lock);
    CHECK(st == GLIMS_STATUS_NOT_RUNNING, "stopping engine refused safely");
    CHECK(payload_zero(&out.axes) && tail_ok(&out), "stopping refusal clears/preserves ABI");
  }

  /* busy */
  {
    Probe p = {.scene = &scene};
    CHECK(glims_engine_call(engine, busy_query_native, &p) == GLIMS_STATUS_OK && p.st == GLIMS_STATUS_OK,
          "read-only query allowed while busy");
    CHECK(!memcmp(&p.out, &original, sizeof original), "busy query returns identical metadata");
  }

  unchanged(engine, &scene, before, "ABI, busy and NOT_RUNNING probes preserve all source state");

  /* Literal UTF-8 boundaries including complete multibyte character exactly
   * at byte 255, and a partial character that must be excluded entirely. */
  {
    const unsigned prefix[] = {255, 254, 252, 251, 252, 253};
    const char *suffix[] = {"Z", "\xE2\x82\xAC", "\xE2\x82\xAC" "Z",
                            "\xF0\x9F\x8E\xA8" "Z", "\xF0\x9F\x8E\xA8",
                            "\xC3\xA9" "Z"};
    const size_t literal_length[] = {255, 254, 255, 255, 252, 255};
    for (unsigned n = 0; n < G_N_ELEMENTS(prefix); n++) {
      char name[272]; memset(name, 'A' + n, prefix[n]);
      strcpy(name + prefix[n], suffix[n]);
      NameProbe p = { .scene = &scene, .name = name, .reorder = n == 0 };
      CHECK(glims_engine_call(engine, names_native, &p) == GLIMS_STATUS_OK,
            "set exact duplicate names and reorder native channels");
      Snapshot *re = g_new0(Snapshot, 1);
      if (capture(engine, &scene, re)) {
        GlimsLabAxes cur = {0};
        CHECK(!strcmp(re->names[0], name) && !strcmp(re->names[1], name) &&
              !strcmp(re->names[2], name), "source actually contains duplicate full display names");
        if (query_and_check(engine, &scene, re, &cur)) {
          for (unsigned a = 0; a < AXES; a++) {
            CHECK(cur.axes[a].id == original.axes[a].id &&
                  !memcmp(cur.axes[a].uuid, original.axes[a].uuid, 16) &&
                  cur.axes[a].role == a && cur.axes[a].selected == original.axes[a].selected,
                  "reorder/rename preserve canonical IDs, UUIDs, roles and selection");
            CHECK(strnlen(cur.axes[a].name, sizeof cur.axes[a].name) == literal_length[n] &&
                  !memcmp(cur.axes[a].name, name, literal_length[n]) &&
                  g_utf8_validate(cur.axes[a].name, -1, NULL),
                  "literal UTF-8 prefix length and bytes match independent boundary expectation");
          }
        }
        unchanged(engine, &scene, re, "duplicate-name metadata query leaves source unchanged");
      }
      release_snapshot(re); g_free(re);
    }
    /* Deliberately bypass native UI's sanitization; invalid display bytes
     * cannot be returned through the facade's owned UTF-8 contract. */
    const char *invalid[] = {"Bad\xC3\x28", "Bad\xE2\x82", "Bad\xC0\xAF"};
    for (unsigned n = 0; n < G_N_ELEMENTS(invalid); n++) {
      NameProbe p = { .scene = &scene, .name = invalid[n] };
      CHECK(glims_engine_call(engine, names_native, &p) == GLIMS_STATUS_OK,
            "install malformed native UTF-8 display bytes");
      Snapshot *bad_name = g_new0(Snapshot, 1);
      if (capture(engine, &scene, bad_name)) {
        refusal(engine, scene.id, GLIMS_STATUS_UNSUPPORTED, "malformed native UTF-8 refuses metadata");
        unchanged(engine, &scene, bad_name, "UTF-8 refusal leaves malformed source bytes untouched");
      }
      release_snapshot(bad_name); g_free(bad_name);
    }
    NameProbe restore = { .scene = &scene, .name = "Duplicate axis" };
    CHECK(glims_engine_call(engine, names_native, &restore) == GLIMS_STATUS_OK,
          "restore valid duplicate display names");
    release_snapshot(before);
    CHECK(capture(engine, &scene, before), "capture new baseline after intentional name and order mutations");
  }

  /* cache-mode mismatch refusal, restore to close cleanly */
  {
    Snapshot *mid = g_new0(Snapshot, 1);
    CHECK(glims_engine_call(engine, mismatch_cache_native, &scene) == GLIMS_STATUS_OK,
          "set distinct native flags/cache mode mismatch");
    if (capture(engine, &scene, mid)) {
      refusal(engine, scene.id, GLIMS_STATUS_UNSUPPORTED, "native flags/cache mode mismatch refused");
      unchanged(engine, &scene, mid, "cache mismatch refusal leaves source unchanged");
    }
    CHECK(glims_engine_call(engine, restore_cache_native, &scene) == GLIMS_STATUS_OK, "restore fixture state");
    release_snapshot(mid); g_free(mid);
  }

  /* bad metadata cases */
  for (uint32_t dmg = 0; dmg < 5; dmg++) {
    Scene bad = {0};
    if (create_lab(engine, &bad, component)) {
      Damage d = {.scene = &bad, .mode = dmg};
      memcpy(d.ids, bad.ids, sizeof bad.ids);
      Snapshot *bs = g_new0(Snapshot, 1);
      CHECK(glims_engine_call(engine, damage_native, &d) == GLIMS_STATUS_OK,
            dmg == 0 ? "detach map metadata" : dmg == 1 ? "duplicate UUID metadata" :
            dmg == 2 ? "hide Lab axis with persistent visibility tag" :
            dmg == 3 ? "remove axis UUID metadata" : "corrupt map version bytes");
      if (capture(engine, &bad, bs)) {
        refusal(engine, bad.id, GLIMS_STATUS_UNSUPPORTED, "bad metadata refused as UNSUPPORTED");
        unchanged(engine, &bad, bs, "bad metadata refusal does not repair or edit source");
      }
      release_snapshot(bs); g_free(bs);
    }
    close_scene(engine, &bad);
  }

  /* ordinary RGB, multichannel, CMYK refusals */
  {
    char *error = NULL; GlimsImageID rgb = 0;
    CHECK(api->image_new(engine, W, H, &rgb, &error) == GLIMS_STATUS_OK && rgb, "create ordinary RGB");
    api->free_string(error); error = NULL;
    if (rgb) { refusal(engine, rgb, GLIMS_STATUS_UNSUPPORTED, "ordinary RGB refused"); api->image_close(engine, rgb); }
    GlimsImageID mc = 0;
    CHECK(api->image_new_multichannel(engine, W, H, component, 4, &mc, &error) == GLIMS_STATUS_OK && mc, "create multichannel");
    api->free_string(error); error = NULL;
    if (mc) { refusal(engine, mc, GLIMS_STATUS_UNSUPPORTED, "multichannel refused"); api->image_close(engine, mc); }
  }
  unchanged(engine, &scene, before, "all refusals and successful queries leave Lab source unchanged");

cleanup:
  release_snapshot(before); g_free(before);
  /* closed image */
  { GlimsImageID closed = scene.id; close_scene(engine, &scene); refusal(engine, closed, GLIMS_STATUS_NOT_FOUND, "closed image refused"); }
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s WORK [CMYK_PROFILE]\n", argv[0]); return 2; }
  const char *cmyk_path = (argc >= 3) ? argv[2] : getenv("GLIMS_TEST_CMYK_PROFILE");
  if (!cmyk_path) cmyk_path = "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc";
  gchar *icc = NULL; gsize icc_len = 0;
  gboolean has_cmyk = g_file_get_contents(cmyk_path, &icc, &icc_len, NULL) && icc_len >= 128 && icc_len <= 4u*1024u*1024u;
  if (!has_cmyk) {
    fprintf(stderr, "FAIL: CMYK profile required but missing/unreadable: %s\n", cmyk_path);
    g_free(icc);
    return 2;
  }
  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_lab_axes) + sizeof api->image_lab_axes || !api->image_lab_axes) {
    fprintf(stderr, "Adapter lacks slot191 image_lab_axes\n"); g_free(icc); return 2;
  }
  gchar *user = g_build_filename(argv[1], "user", NULL), *cache = g_build_filename(argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus st = api->start(&config, &engine, &error);
  g_free(user); g_free(cache);
  if (st != GLIMS_STATUS_OK || !engine) {
    fprintf(stderr, "Engine start failed: %s\n", error ? error : "unknown"); api->free_string(error); g_free(icc); return 2;
  }
  api->free_string(error);

  const uint32_t comps[] = {GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16, GLIMS_COLOR_COMPONENT_FLOAT};
  for (unsigned i = 0; i < G_N_ELEMENTS(comps); i++) {
    printf("CASE component=%u\n", comps[i]);
    run_case(engine, comps[i]);
  }
  /* CMYK refusal coverage with real external profile (read in place, no repo bytes) */
  {
    char *error = NULL; GlimsImageID cmyk = 0;
    CHECK(api->image_new_cmyk(engine, W, H, GLIMS_COLOR_COMPONENT_U8, (const guint8 *)icc, icc_len, &cmyk, &error) == GLIMS_STATUS_OK && cmyk,
          "create CMYK with external profile for refusal coverage");
    api->free_string(error);
    if (cmyk) { refusal(engine, cmyk, GLIMS_STATUS_UNSUPPORTED, "CMYK refused by image_lab_axes"); api->image_close(engine, cmyk); }
  }

  api->stop(engine); g_free(icc);
  printf("checks=%u failures=%u\n", checks, failures);
  return failures ? 1 : 0;
}

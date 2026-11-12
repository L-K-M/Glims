/* Independent public ink Curves snapshot acceptance fixture for slots 199-201.
 * Native callbacks seed/capture source state only; tested operations use the
 * public facade. Expected values are hand-computed literals and never call the
 * production numeric kernel. */
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
#define CURVE_SAMPLES GLIMS_CURVE_SAMPLE_COUNT

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
        babl_format_get_n_components(gimp_drawable_get_format(drawable)) != 1)
      return GLIMS_STATUS_FAILED;
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
      a->layers != b->layers || a->precision != b->precision ||
      a->selected_count != b->selected_count ||
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
static gboolean same_preview_metadata(const Snapshot *source, const Snapshot *copy) {
  if (!bytes_equal(source->map, copy->map) || !bytes_equal(source->profile, copy->profile) ||
      memcmp(source->mask, copy->mask, sizeof source->mask) ||
      source->layers != copy->layers || source->precision != copy->precision ||
      source->selected_count != copy->selected_count) return FALSE;
  for (unsigned p = 0; p < PLANES; p++) {
    if (!bytes_equal(source->uuid[p], copy->uuid[p]) ||
        !bytes_equal(source->visibility[p], copy->visibility[p]) ||
        strcmp(source->names[p], copy->names[p]) || source->locks[p] != copy->locks[p] ||
        copy->files[p]) return FALSE;
  }
  for (unsigned i = 0; i < source->selected_count; i++) {
    unsigned p = 0;
    while (p < PLANES && source->scene->ids[p] != source->selected[i]) p++;
    if (p == PLANES || copy->selected[i] != copy->scene->ids[p]) return FALSE;
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
      /* Varied U16 seed including subsegment-relevant values for the
       * hand-computed nonmonotone LUT case: 0, 257, 16384, 32768, 49152... */
      const guint16 values[PIXELS] = {
        16384, 24576, 32768, 40960, 49152, 8192, 12288, 57344,
        0, 257, 514, 65535, 21845, 43690, 32000, 33000
      };
      guint16 v = values[(p * 5u + i) % PIXELS];
      memcpy(s->seed[p] + i * 2, &v, 2);
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
  gegl_buffer_get(gimp_drawable_get_buffer(mask), GEGL_RECTANGLE(0, 0, W, H), 1,
                  babl_format("Y float"), s->mask, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  GFile *file = g_file_new_for_uri("file:///ink-curves-snapshot-fixture-source.xcf");
  gimp_image_set_file(image, file);
  gimp_image_set_imported_file(image, file);
  gimp_image_set_exported_file(image, file);
  gimp_image_set_save_a_copy_file(image, file);
  g_object_unref(file);
  gimp_image_undo_free(image);
  gimp_image_clean_all(image);
  return GLIMS_STATUS_OK;
}

/* Curve builders (hand-computed, never using production kernel). */
static void fill_constant_curves(GlimsInkCurvesSettings *s, double y) {
  s->struct_size = sizeof *s;
  for (unsigned i = 0; i < CURVE_SAMPLES; i++) s->samples[i] = y;
}
static void fill_identity_curves(GlimsInkCurvesSettings *s) {
  s->struct_size = sizeof *s;
  for (unsigned i = 0; i < CURVE_SAMPLES; i++)
    s->samples[i] = (double)i / (double)(CURVE_SAMPLES - 1);
}
/* Dyadic alternating values form a nonmonotone table. The separate U16
 * case states exact rounded outputs from rational arithmetic, not this table's
 * runtime interpolation or the production numeric kernel. */
static void fill_nonmonotone_curves(GlimsInkCurvesSettings *s) {
  s->struct_size = sizeof *s;
  for (unsigned i = 0; i < CURVE_SAMPLES; i++) s->samples[i] = i % 2 ? .75 : .25;
}

static GlimsStatus begin(GlimsEngine *e, Scene *s, uint64_t *token) {
  char *error = NULL;
  GlimsStatus status = api->image_ink_snapshot_begin(e, s->id, s->ids[0], token, &error);
  api->free_string(error); return status;
}
static GlimsStatus preview_curves(GlimsEngine *e, GlimsImageID id, uint64_t token,
                                  const GlimsInkCurvesSettings *settings, GlimsImageID *copy) {
  char *error = NULL;
  GlimsStatus status = api->image_ink_snapshot_curves(e, id, token, settings, copy, &error);
  api->free_string(error); return status;
}
static GlimsStatus preview_levels(GlimsEngine *e, GlimsImageID id, uint64_t token,
                                  const GlimsInkLevelsSettings *settings, GlimsImageID *copy) {
  char *error = NULL;
  GlimsStatus status = api->image_ink_snapshot_levels(e, id, token, settings, copy, &error);
  api->free_string(error); return status;
}
static GlimsStatus apply_curves(GlimsEngine *e, Scene *s, uint64_t token,
                                const GlimsInkCurvesSettings *settings) {
  char *error = NULL;
  GlimsStatus status = api->image_ink_snapshot_apply_curves(e, s->id, token, settings, &error);
  api->free_string(error); return status;
}
static GlimsStatus direct_curves(GlimsEngine *e, Scene *s, const GlimsInkCurvesSettings *settings) {
  char *error = NULL;
  GlimsStatus status = api->image_curves_ink(e, s->id, s->ids[0], settings, &error);
  api->free_string(error); return status;
}

static gboolean create_scene(GlimsEngine *e, Scene *s, uint32_t mode, uint32_t component,
                             const guint8 *icc, size_t length) {
  memset(s, 0, sizeof *s); s->mode = mode; s->component = component;
  s->sample_size = component == GLIMS_COLOR_COMPONENT_U8 ? 1 :
                   component == GLIMS_COLOR_COMPONENT_U16 ? 2 : 4;
  s->bytes = PIXELS * s->sample_size;
  char *error = NULL;
  GlimsStatus status = mode == GLIMS_PLATE_MODE_CMYK
    ? api->image_new_cmyk(e, W, H, component, icc, length, &s->id, &error)
    : api->image_new_multichannel(e, W, H, component, PLANES, &s->id, &error);
  CHECK(status == GLIMS_STATUS_OK && s->id, "create public ink image");
  api->free_string(error);
  if (status != GLIMS_STATUS_OK || !s->id) return FALSE;
  gboolean prepared = glims_engine_call(e, prepare_native, s) == GLIMS_STATUS_OK;
  CHECK(prepared, "seed native intensities, names/visibility/selection, clean history and file identity");
  return prepared;
}
static void close_scene(GlimsEngine *e, Scene *s) {
  if (s->id) CHECK(api->image_close(e, s->id) == GLIMS_STATUS_OK, "close owned ink image");
  s->id = 0;
}
static Scene copy_scene(const Scene *source, GlimsImageID id) {
  Scene copy = *source; copy.id = id; memset(copy.ids, 0, sizeof copy.ids); return copy;
}
static void source_unchanged(GlimsEngine *e, Scene *s, const Snapshot *before, const char *label) {
  Snapshot after = {0};
  if (capture(e, s, &after)) CHECK(same_pixels(s, before, &after) && same_metadata(before, &after) && same_history(before, &after), label);
  release_snapshot(&after);
}
static void expired(GlimsEngine *e, Scene *s, uint64_t token) {
  GlimsImageID copy = -1; GlimsInkCurvesSettings c = {0}; fill_constant_curves(&c, .5);
  CHECK(preview_curves(e, s->id, token, &c, &copy) == GLIMS_STATUS_NOT_FOUND && copy == 0,
        "expired token refuses preview and clears output");
  CHECK(apply_curves(e, s, token, &c) == GLIMS_STATUS_NOT_FOUND, "expired token refuses Apply");
  CHECK(api->image_ink_snapshot_end(e, s->id, token) == GLIMS_STATUS_NOT_FOUND, "expired End reports NOT_FOUND");
}
static void render_copy(GlimsEngine *e, GlimsImageID id) {
  guint8 rgba[PIXELS * 4];
  CHECK(api->image_render(e, id, 1, (GlimsRect){0,0,W,H}, rgba, W * 4) == GLIMS_STATUS_OK,
        "owned preview renders through public facade");
}

/* Literal encodings of .5; every other plane must retain its original bytes. */
static gboolean oracle_constant_half(const Scene *s, const Snapshot *after) {
  for (unsigned p = 0; p < PLANES; p++) for (unsigned i = 0; i < PIXELS; i++) {
    guint8 expected[sizeof(float)] = {0};
    memcpy(expected, s->seed[p] + i * s->sample_size, s->sample_size);
    if (p == 0) {
      if (s->sample_size == 1) expected[0] = 128;
      else if (s->sample_size == 2) { guint16 value = 32768; memcpy(expected, &value, 2); }
      else { float value = .5f; memcpy(expected, &value, 4); }
    }
    if (memcmp(expected, after->raw[p] + i * s->sample_size, s->sample_size)) return FALSE;
  }
  return TRUE;
}

static const GlimsInkLevelsSettings levels_const75 = {
  .struct_size = sizeof(GlimsInkLevelsSettings),
  .value = {0, 1, 1, .75, .75}, .clamp_input = 0, .clamp_output = 0
};

typedef enum { TARGET_PIXEL, OTHER_PIXEL, HIDDEN_PIXEL, SELECTION, ACTIVE_TARGET,
               VISIBILITY, NAME, MAP_COLOR, DAMAGE_MAP } Mutation;
typedef struct { Scene *scene; Mutation kind; } MutationRequest;

static GlimsStatus mutate_native(GlimsEngine *e, gpointer data) {
  MutationRequest *m = data; Scene *s = m->scene;
  GlimsOpenImage *open = glims_lookup_image(e, s->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image = open->image;
  if (m->kind == DAMAGE_MAP) {
    gimp_image_parasite_detach(image, GLIMS_PLATE_MAP_PARASITE, FALSE);
    return GLIMS_STATUS_OK;
  }
  GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open(open, &storage)) return GLIMS_STATUS_FAILED;
  if (m->kind <= HIDDEN_PIXEL) {
    unsigned p = m->kind == TARGET_PIXEL ? 0 : m->kind == OTHER_PIXEL ? 1 : 3;
    GimpDrawable *d = GIMP_DRAWABLE(storage.planes[p]);
    float value = .875f;
    gegl_buffer_set(gimp_drawable_get_buffer(d), GEGL_RECTANGLE(0,0,1,1), 0,
                    babl_format("Y float"), &value, GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d, 0, 0, 1, 1);
  } else if (m->kind == SELECTION) {
    float mask[PIXELS]; for (unsigned i=0;i<PIXELS;i++) mask[i]=.5f;
    GimpDrawable *d = GIMP_DRAWABLE(gimp_image_get_mask(image));
    gegl_buffer_set(gimp_drawable_get_buffer(d), GEGL_RECTANGLE(0,0,W,H), 0,
                    babl_format("Y float"), mask, GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d, 0, 0, W, H);
  } else if (m->kind == ACTIVE_TARGET) {
    GList *selected = g_list_append(NULL, storage.planes[1]);
    gimp_image_set_selected_channels(image, selected);
    g_list_free(selected);
  } else if (m->kind == VISIBILITY) {
    guint8 hidden = 0;
    GimpParasite *p = gimp_parasite_new(GLIMS_PLATE_VISIBLE_PARASITE, GIMP_PARASITE_PERSISTENT, 1, &hidden);
    gimp_item_parasite_attach(GIMP_ITEM(storage.planes[0]), p, FALSE); gimp_parasite_free(p);
  } else if (m->kind == NAME) {
    if (!gimp_item_rename(GIMP_ITEM(storage.planes[0]), "Changed display label", NULL)) return GLIMS_STATUS_FAILED;
  } else if (m->kind == MAP_COLOR) {
    guint8 bytes[GLIMS_PLATE_MAP_MAX_SIZE]; size_t length = 0;
    storage.map.entries[0].ink_rgb[0] = storage.map.entries[0].ink_rgb[0] == .125 ? .75 : .125;
    if (!glims_plate_map_encode(&storage.map, bytes, sizeof bytes, &length)) return GLIMS_STATUS_FAILED;
    GimpParasite *p = gimp_parasite_new(GLIMS_PLATE_MAP_PARASITE, GIMP_PARASITE_PERSISTENT, length, bytes);
    gimp_image_parasite_attach(image, p, FALSE); gimp_parasite_free(p);
  } else return GLIMS_STATUS_INVALID_ARGUMENT;
  return GLIMS_STATUS_OK;
}
static GlimsStatus mutate(GlimsEngine *e, Scene *s, Mutation kind) {
  MutationRequest request = {s, kind};
  return glims_engine_call(e, mutate_native, &request);
}

typedef struct { Scene *scene; gboolean lock; } LockRequest;
static GlimsStatus lock_target_native(GlimsEngine *engine, gpointer data) {
  LockRequest *request = data;
  GlimsOpenImage *open = glims_lookup_image(engine, request->scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpItem *item = gimp_item_get_by_id(engine->gimp, request->scene->ids[0]);
  if (!item || gimp_item_get_image(item) != open->image) return GLIMS_STATUS_NOT_FOUND;
  gimp_item_set_lock_content(item, request->lock, FALSE);
  return GLIMS_STATUS_OK;
}
static void lock_target_native_req(GlimsEngine *engine, Scene *scene, gboolean lock) {
  LockRequest request = {scene, lock};
  CHECK(glims_engine_call(engine, lock_target_native, &request) == GLIMS_STATUS_OK,
        "set fixture target lock");
}

static gboolean target_plane_all_constant(const Scene *s, const Snapshot *snap, double normalized) {
  for (unsigned i = 0; i < PIXELS; i++) {
    if (s->sample_size == 1) {
      guint8 v = (guint8)lrint(normalized * 255.0);
      if (snap->raw[0][i] != v) return FALSE;
    } else if (s->sample_size == 2) {
      guint16 v = (guint16)lrint(normalized * 65535.0);
      guint16 got; memcpy(&got, snap->raw[0] + i*2, 2);
      if (got != v) return FALSE;
    } else {
      float v = (float)normalized, got; memcpy(&got, snap->raw[0] + i*4, 4);
      if (memcmp(&got, &v, 4)) return FALSE;
    }
  }
  return TRUE;
}
static gboolean other_planes_unchanged(const Scene *s, const Snapshot *a, const Snapshot *b) {
  for (unsigned p = 1; p < PLANES; p++)
    if (memcmp(a->raw[p], b->raw[p], s->bytes)) return FALSE;
  return TRUE;
}

/* Critical cache alternation case on float seeds (.25 for plane 0). */
static void cache_alternation_case(GlimsEngine *e, uint32_t mode, const guint8 *icc, size_t length) {
  Scene s = {0}; uint64_t token = 0;
  GlimsImageID pL1=0,pC1=0,pL2=0,pC2=0;
  GlimsInkCurvesSettings c5 = {0}; fill_constant_curves(&c5, .5);
  Snapshot orig={0}, sL1={0}, sC1={0}, sL2={0}, sC2={0};
  if (!create_scene(e, &s, mode, GLIMS_COLOR_COMPONENT_FLOAT, icc, length)) goto done;
  if (!capture(e, &s, &orig)) goto done;
  CHECK(begin(e, &s, &token) == GLIMS_STATUS_OK && token, "cache case: begin snapshot");
  CHECK(preview_levels(e, s.id, token, &levels_const75, &pL1) == GLIMS_STATUS_OK && pL1, "cache case: Levels .75");
  CHECK(preview_curves(e, s.id, token, &c5, &pC1) == GLIMS_STATUS_OK && pC1 && pC1 != pL1, "cache case: Curves .5 distinct handle");
  CHECK(preview_levels(e, s.id, token, &levels_const75, &pL2) == GLIMS_STATUS_OK && pL2 && pL2 != pL1, "cache case: Levels .75 again distinct handle");
  CHECK(preview_curves(e, s.id, token, &c5, &pC2) == GLIMS_STATUS_OK && pC2 && pC2 != pC1, "cache case: Curves .5 again distinct handle");
  if (pL1&&pC1&&pL2&&pC2) {
    Scene a=copy_scene(&s,pL1), b=copy_scene(&s,pC1), c=copy_scene(&s,pL2), d=copy_scene(&s,pC2);
    if (capture(e,&a,&sL1)&&capture(e,&b,&sC1)&&capture(e,&c,&sL2)&&capture(e,&d,&sC2)) {
      /* Levels const .75: target .25->.75, others unchanged. Curves const .5: .25->.5. */
      gboolean ok = target_plane_all_constant(&s,&sL1,.75) && target_plane_all_constant(&s,&sL2,.75) &&
                    target_plane_all_constant(&s,&sC1,.5)  && target_plane_all_constant(&s,&sC2,.5) &&
                    other_planes_unchanged(&s,&orig,&sL1) && other_planes_unchanged(&s,&orig,&sC1) &&
                    other_planes_unchanged(&s,&orig,&sL2) && other_planes_unchanged(&s,&orig,&sC2);
      CHECK(ok, "cache alternation preserves literal target samples for Levels .75 and Curves .5 with independent handles");
    }
  }
  CHECK(api->image_ink_snapshot_end(e, s.id, token) == GLIMS_STATUS_OK, "cache case: end snapshot");
  token = 0;
  source_unchanged(e, &s, &orig, "cache alternation leaves source unchanged");
done:
  if (token) (void)api->image_ink_snapshot_end(e, s.id, token);
  if (pL1) api->image_close(e,pL1);
  if (pC1) api->image_close(e,pC1);
  if (pL2) api->image_close(e,pL2);
  if (pC2) api->image_close(e,pC2);
  release_snapshot(&orig); release_snapshot(&sL1); release_snapshot(&sC1); release_snapshot(&sL2); release_snapshot(&sC2);
  close_scene(e,&s);
}

static void direct_curves_case(GlimsEngine *e, uint32_t mode, const guint8 *icc, size_t length) {
  Scene s={0}; Snapshot before={0}, after={0}, undone={0};
  GlimsInkCurvesSettings c5={0}; fill_constant_curves(&c5,.5);
  if (!create_scene(e,&s,mode,GLIMS_COLOR_COMPONENT_FLOAT,icc,length)) goto done;
  if (!capture(e,&s,&before)) goto done;
  CHECK(direct_curves(e,&s,&c5)==GLIMS_STATUS_OK, "direct image_curves_ink succeeds");
  if (capture(e,&s,&after)) {
    CHECK(target_plane_all_constant(&s,&after,.5) && other_planes_unchanged(&s,&before,&after),
          "direct image_curves_ink applies literal constant mapping");
    CHECK(same_metadata(&before,&after) && after.undo == before.undo + 1,
          "direct image_curves_ink creates one Undo and preserves metadata");
    CHECK(api->image_undo(e,s.id)==GLIMS_STATUS_OK, "direct curves: undo");
    if (capture(e,&s,&undone)) CHECK(same_pixels(&s,&before,&undone), "direct curves: undo restores exact pixels");
    release_snapshot(&undone);
  }
done:
  release_snapshot(&before); release_snapshot(&after); close_scene(e,&s);
}


static void nonmonotone_u16_case(GlimsEngine *e, uint32_t mode, const guint8 *icc, size_t length) {
  Scene s={0}; Snapshot before={0}, after={0};
  uint64_t token=0; GlimsImageID copy=0;
  GlimsInkCurvesSettings nm={0}; fill_nonmonotone_curves(&nm);
  if (!create_scene(e,&s,mode,GLIMS_COLOR_COMPONENT_U16,icc,length)) goto done;
  if (!capture(e,&s,&before)) goto done;
  CHECK(begin(e,&s,&token)==GLIMS_STATUS_OK && token, "nonmonotone u16: begin");
  CHECK(preview_curves(e,s.id,token,&nm,&copy)==GLIMS_STATUS_OK && copy, "nonmonotone u16: preview");
  if (copy) {
    Scene sc=copy_scene(&s,copy);
    if (capture(e,&sc,&after)) {
      /* Exact rational interpolation of the alternating 1/4,3/4 table at
       * each native input/65535, followed by half-up integer encoding. */
      const guint16 expected[PIXELS] = {24544, 28624, 32704, 36784, 40864, 20464, 22504, 44944, 16384, 49151, 16384, 49151, 49151, 16384, 33214, 29644};
      gboolean ok = other_planes_unchanged(&s, &before, &after);
      for (unsigned i = 0; i < PIXELS; i++) {
        guint16 got;
        memcpy(&got, after.raw[0] + i * 2, 2);
        if (got != expected[i]) ok = FALSE;
      }
      CHECK(ok, "nonmonotone LUT produces hand-computed U16 subsegment results (no U8 quantization), other planes unchanged");
    }
  }
  source_unchanged(e,&s,&before,"nonmonotone preview preserves source");
done:
  if (copy) api->image_close(e,copy);
  if (token) api->image_ink_snapshot_end(e,s.id,token);
  release_snapshot(&before); release_snapshot(&after); close_scene(e,&s);
}

static void masked_apply_case(GlimsEngine *engine, uint32_t mode, const guint8 *icc, size_t length) {
  Scene scene = {0}; Snapshot original = {0}, applied = {0}, restored = {0};
  uint64_t token = 0;
  GlimsInkCurvesSettings curve = {0}; fill_constant_curves(&curve, .5);
  if (!create_scene(engine, &scene, mode, GLIMS_COLOR_COMPONENT_FLOAT, icc, length)) goto done;
  scene.masked = TRUE;
  CHECK(glims_engine_call(engine, prepare_native, &scene) == GLIMS_STATUS_OK, "prepare masked Apply scene");
  if (!capture(engine, &scene, &original)) goto done;
  CHECK(begin(engine, &scene, &token) == GLIMS_STATUS_OK && token, "begin masked Apply");
  CHECK(apply_curves(engine, &scene, token, &curve) == GLIMS_STATUS_OK, "commit masked Curves");
  expired(engine, &scene, token); token = 0;
  if (capture(engine, &scene, &applied)) {
    const float expected[] = {.25f, .3125f, .375f, .5f};
    gboolean exact = other_planes_unchanged(&scene, &original, &applied);
    for (unsigned i = 0; i < PIXELS; i++)
      if (memcmp(applied.raw[0] + i * sizeof(float), &expected[i % 4], sizeof(float))) exact = FALSE;
    CHECK(exact && same_metadata(&original, &applied), "masked Apply blends once and retains every other plane and metadata field");
    CHECK(applied.undo == original.undo + 1 && applied.redo == 0, "masked Apply is one Undo");
    CHECK(api->image_undo(engine, scene.id) == GLIMS_STATUS_OK, "undo masked Curves");
    if (capture(engine, &scene, &restored)) CHECK(same_pixels(&scene, &original, &restored) && same_metadata(&original, &restored), "masked Undo is byte-exact");
    release_snapshot(&restored);
    CHECK(api->image_redo(engine, scene.id) == GLIMS_STATUS_OK, "redo masked Curves");
    if (capture(engine, &scene, &restored)) CHECK(same_pixels(&scene, &applied, &restored) && same_metadata(&applied, &restored), "masked Redo is byte-exact");
  }
done:
  if (token) (void)api->image_ink_snapshot_end(engine, scene.id, token);
  release_snapshot(&original); release_snapshot(&applied); release_snapshot(&restored); close_scene(engine, &scene);
}

static GlimsStatus seed_extended_native(GlimsEngine *engine, gpointer data) {
  Scene *scene = data;
  GlimsOpenImage *open = glims_lookup_image(engine, scene->id);
  GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open, &storage)) return GLIMS_STATUS_FAILED;
  const guint32 words[PIXELS] = {0x80000000u, 1u, 0x80000001u, 0x3f800001u,
    0x7f7fffffu, 0xff7fffffu, 0xbf000000u, 0x40000000u, 0x3e800000u, 0x3f000000u,
    0x3f800000u, 0u, 0x00800000u, 0x80800000u, 2u, 0x3f7fffffu};
  GimpDrawable *drawable = GIMP_DRAWABLE(storage.planes[0]);
  memcpy(scene->seed[0], words, sizeof words);
  gegl_buffer_set(gimp_drawable_get_buffer(drawable), GEGL_RECTANGLE(0, 0, W, H), 0,
                  gimp_drawable_get_format(drawable), words, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(drawable, 0, 0, W, H);
  return GLIMS_STATUS_OK;
}

static void extended_identity_case(GlimsEngine *engine, uint32_t mode, const guint8 *icc, size_t length) {
  Scene scene = {0}; Snapshot original = {0}, preview = {0};
  uint64_t token = 0; GlimsImageID copy = 0;
  GlimsInkCurvesSettings identity = {0}; fill_identity_curves(&identity);
  if (!create_scene(engine, &scene, mode, GLIMS_COLOR_COMPONENT_FLOAT, icc, length)) goto done;
  CHECK(glims_engine_call(engine, seed_extended_native, &scene) == GLIMS_STATUS_OK, "seed finite extended float and negative-zero encodings");
  if (!capture(engine, &scene, &original)) goto done;
  CHECK(!memcmp(original.raw[0], scene.seed[0], scene.bytes), "native source retains literal extended float encodings");
  CHECK(begin(engine, &scene, &token) == GLIMS_STATUS_OK && token, "begin extended identity");
  CHECK(preview_curves(engine, scene.id, token, &identity, &copy) == GLIMS_STATUS_OK && copy, "preview extended identity");
  if (copy) {
    Scene copied = copy_scene(&scene, copy);
    if (capture(engine, &copied, &preview))
      CHECK(same_pixels(&scene, &original, &preview) && same_preview_metadata(&original, &preview), "identity preview preserves extended values, signed zero and subnormals exactly");
  }
  source_unchanged(engine, &scene, &original, "extended preview preserves source");
  CHECK(apply_curves(engine, &scene, token, &identity) == GLIMS_STATUS_OK, "extended identity Apply succeeds");
  expired(engine, &scene, token); token = 0;
  source_unchanged(engine, &scene, &original, "extended identity Apply adds no Undo and changes no source bytes");
done:
  if (copy) CHECK(api->image_close(engine, copy) == GLIMS_STATUS_OK, "close extended preview");
  if (token) (void)api->image_ink_snapshot_end(engine, scene.id, token);
  release_snapshot(&original); release_snapshot(&preview); close_scene(engine, &scene);
}

static void stale_cases(GlimsEngine *e, const guint8 *icc, size_t length) {
  const char *labels[] = {"target pixels", "other visible ink pixels", "hidden ink pixels", "selection mask",
                          "active ink target", "ink visibility", "ink name", "valid map display color", "damaged map"};
  GlimsInkCurvesSettings c_id={0}; fill_identity_curves(&c_id);
  GlimsInkCurvesSettings c_half={0}; fill_constant_curves(&c_half,.5);
  for (unsigned kind = TARGET_PIXEL; kind <= DAMAGE_MAP; kind++) {
    Scene s = {0}; Snapshot modified = {0}; uint64_t token = 0;
    if (!create_scene(e, &s, GLIMS_PLATE_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_FLOAT, icc, length)) goto done;
    CHECK(begin(e, &s, &token) == GLIMS_STATUS_OK && token, "begin stale-state fixture");
    CHECK(mutate(e, &s, (Mutation)kind) == GLIMS_STATUS_OK, labels[kind]);
    if (!capture(e, &s, &modified)) goto done;
    CHECK(apply_curves(e, &s, token, &c_id) != GLIMS_STATUS_OK, "stale source refuses identity Apply");
    source_unchanged(e, &s, &modified, "stale identity refusal preserves user's newer state");
    CHECK(apply_curves(e, &s, token, &c_half) != GLIMS_STATUS_OK, "stale source refuses changed Apply");
    source_unchanged(e, &s, &modified, "stale changed refusal publishes nothing");
    CHECK(api->image_ink_snapshot_end(e, s.id, token) == GLIMS_STATUS_OK, "stale/damaged metadata retains cancelable baseline");
    token = 0;
  done:
    if (token) (void)api->image_ink_snapshot_end(e, s.id, token);
    release_snapshot(&modified); close_scene(e, &s);
  }
}

static void lock_case(GlimsEngine *e, const guint8 *icc, size_t length) {
  Scene s={0}; Snapshot before={0}; uint64_t token=0;
  GlimsInkCurvesSettings c_half={0}; fill_constant_curves(&c_half,.5);
  if (!create_scene(e,&s,GLIMS_PLATE_MODE_MULTICHANNEL,GLIMS_COLOR_COMPONENT_FLOAT,icc,length)) goto done;
  if (!capture(e,&s,&before)) goto done;
  CHECK(begin(e,&s,&token)==GLIMS_STATUS_OK && token, "begin locked-target fixture");
  lock_target_native_req(e,&s,TRUE);
  CHECK(apply_curves(e,&s,token,&c_half)==GLIMS_STATUS_LOCKED, "locked target refuses Apply and retains token");
  lock_target_native_req(e,&s,FALSE);
  source_unchanged(e,&s,&before,"locked refusal published nothing; unlocked source still matches baseline until apply/cancel");
  CHECK(api->image_ink_snapshot_end(e,s.id,token)==GLIMS_STATUS_OK, "locked refusal keeps token cancelable");
  token=0;
done:
  if (token) (void)api->image_ink_snapshot_end(e,s.id,token);
  release_snapshot(&before); close_scene(e,&s);
}

static void close_case(GlimsEngine *e, const guint8 *icc, size_t length) {
  Scene s = {0}; GlimsImageID copy = 0; uint64_t token = 0;
  GlimsInkCurvesSettings c_half={0}; fill_constant_curves(&c_half,.5);
  if (!create_scene(e, &s, GLIMS_PLATE_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_FLOAT, icc, length)) goto done;
  CHECK(begin(e, &s, &token) == GLIMS_STATUS_OK && token, "begin source-close fixture");
  CHECK(preview_curves(e, s.id, token, &c_half, &copy) == GLIMS_STATUS_OK && copy, "create preview before source close");
  CHECK(mutate(e, &s, DAMAGE_MAP) == GLIMS_STATUS_OK, "damage metadata before source Close");
  {
    GlimsImageID old = s.id;
    close_scene(e, &s);
    GlimsImageID rejected = -1;
    CHECK(preview_curves(e, old, token, &c_half, &rejected) == GLIMS_STATUS_NOT_FOUND && rejected == 0,
          "source close invalidates baseline and clears preview output");
    CHECK(api->image_ink_snapshot_end(e, old, token) == GLIMS_STATUS_NOT_FOUND, "source-close token is expired");
  }
  if (copy) render_copy(e, copy);
done:
  if (copy) CHECK(api->image_close(e, copy) == GLIMS_STATUS_OK, "returned preview survives owner close and closes independently");
  close_scene(e, &s);
}

static GlimsStatus public_count_native(GlimsEngine *e, gpointer data) {
  *(guint *)data = g_hash_table_size(e->images); return GLIMS_STATUS_OK;
}
static guint public_count(GlimsEngine *e) {
  guint count = 0;
  CHECK(glims_engine_call(e, public_count_native, &count) == GLIMS_STATUS_OK, "read public image count");
  return count;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s PRIVATE_WORK EXTERNAL_CMYK_ICC\n", argv[0]); return 2; }
  gchar *icc = NULL; gsize length = 0;
  if (!g_file_get_contents(argv[2], &icc, &length, NULL) || length < 128 || length > 4u * 1024u * 1024u) {
    fprintf(stderr, "External bounded CMYK profile unavailable\n"); g_free(icc); return 2;
  }

  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_ink_snapshot_apply_curves) + sizeof api->image_ink_snapshot_apply_curves ||
      !api->image_ink_snapshot_begin || !api->image_ink_snapshot_curves || !api->image_ink_snapshot_apply_curves ||
      !api->image_ink_snapshot_end || !api->image_curves_ink || !api->image_ink_snapshot_levels) {
    fprintf(stderr, "Adapter lacks required Curves snapshot slots\n"); g_free(icc); return 2;
  }
  gchar *user = g_build_filename(argv[1], "user", NULL), *cache = g_build_filename(argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus status = api->start(&config, &engine, &error);
  g_free(user); g_free(cache);
  if (status != GLIMS_STATUS_OK || !engine) {
    fprintf(stderr, "Engine start: %s\n", error ? error : "failed"); api->free_string(error); g_free(icc); return 2;
  }
  api->free_string(error);
  guint initial_count = public_count(engine);

  /* CMYK and Multichannel U8/U16/FLOAT core cases. */
  const uint32_t components[] = {GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16, GLIMS_COLOR_COMPONENT_FLOAT};
  for (uint32_t mode = GLIMS_PLATE_MODE_MULTICHANNEL; mode <= GLIMS_PLATE_MODE_CMYK; mode++)
    for (unsigned i = 0; i < G_N_ELEMENTS(components); i++) {
      Scene scene = {0};
      printf("CASE mode=%u component=%u\n", mode, components[i]);
      if (create_scene(engine, &scene, mode, components[i], (guint8 *)icc, length)) {
        /* Core preview/apply/cancel/undo/redo/ownership/invalid/foreign/error cases */
        Snapshot original={0}, a1={0}, a2={0}, a3={0}, applied={0}, restored={0};
        uint64_t token=0, next=0; GlimsImageID pa=0,pb=0,pc=0,pident=0; Scene other={0};
        GlimsInkCurvesSettings c_half={0}, c_id={0}, bad={0};
        fill_constant_curves(&c_half,.5); fill_identity_curves(&c_id);
        if (capture(engine,&scene,&original)) {
          CHECK(begin(engine,&scene,&token)==GLIMS_STATUS_OK && token, "begin snapshot returns token");
          next = UINT64_MAX;
          CHECK(begin(engine,&scene,&next)!=GLIMS_STATUS_OK && next==0, "second Begin refuses and clears token");
          CHECK(preview_curves(engine,scene.id,token,&c_half,&pa)==GLIMS_STATUS_OK && pa, "preview returns owned image");
          CHECK(preview_curves(engine,scene.id,token,&c_half,&pb)==GLIMS_STATUS_OK && pb && pb!=pa, "repeat preview returns distinct image");
          if (pa && pb) {
            Scene sa=copy_scene(&scene,pa), sb=copy_scene(&scene,pb);
            if (capture(engine,&sa,&a1)&&capture(engine,&sb,&a2)) {
              CHECK(oracle_constant_half(&scene,&a1), "constant .5 LUT maps selected plane as specified (incl .25->128/32768/.5 seeds)");
              CHECK(same_pixels(&scene,&a1,&a2), "repeated previews own distinct results and do not accumulate");
              CHECK(other_planes_unchanged(&scene,&original,&a1), "unrelated native planes unchanged by preview");
              CHECK(same_preview_metadata(&original,&a1), "preview preserves profile/map/UUID/name/visibility/mask/locks and corresponding selected plane, with no source file identity");
              CHECK(!a1.files[0]&&!a1.files[1]&&!a1.files[2]&&!a1.files[3], "returned preview has no source file identity");
            }
            render_copy(engine,pa); render_copy(engine,pb);
            /* edit preview and recompute */
            char *err=NULL; GlimsStatus st = api->image_edit_ink(engine,pa,sa.ids[0],GLIMS_INK_EDIT_FILL,1,1,&err);
            CHECK(st==GLIMS_STATUS_OK,"returned preview is independently editable"); api->free_string(err);
            CHECK(preview_curves(engine,scene.id,token,&c_half,&pc)==GLIMS_STATUS_OK && pc, "recompute after editing earlier preview");
            if (pc) { Scene sc2=copy_scene(&scene,pc); if(capture(engine,&sc2,&a3)) CHECK(oracle_constant_half(&scene,&a3),"edited preview cannot mutate frozen baseline"); release_snapshot(&a3); }
          }
          source_unchanged(engine,&scene,&original,"previews/renders preserve source");

          CHECK(preview_curves(engine,scene.id,token,&c_id,&pident)==GLIMS_STATUS_OK && pident, "identity preview");
          if (pident) { Scene si=copy_scene(&scene,pident); Snapshot idr={0}; if(capture(engine,&si,&idr)) CHECK(same_pixels(&scene,&original,&idr),"canonical identity is exact no-op preview"); release_snapshot(&idr); api->image_close(engine,pident); pident=0; }

          bad=c_half; bad.struct_size=sizeof(uint32_t); pident=-1;
          CHECK(preview_curves(engine,scene.id,token,&bad,&pident)!=GLIMS_STATUS_OK && pident==0, "invalid struct size clears returned copy");
          bad=c_half; bad.samples[255]=NAN; pident=-1;
          CHECK(preview_curves(engine,scene.id,token,&bad,&pident)!=GLIMS_STATUS_OK && pident==0, "invalid sample settings clear returned copy");
          pident=-1; CHECK(preview_curves(engine,scene.id,token,NULL,&pident)!=GLIMS_STATUS_OK && pident==0, "NULL settings clear returned copy");
          CHECK(apply_curves(engine,&scene,token,&bad)!=GLIMS_STATUS_OK, "invalid Apply settings refuse");
          pident=-1; CHECK(preview_curves(engine,scene.id,0,&c_half,&pident)!=GLIMS_STATUS_OK && pident==0, "zero token refuses/clears");

          if (create_scene(engine,&other,scene.mode,scene.component,(guint8*)icc,length)) {
            Snapshot foreign={0}; gboolean cap=capture(engine,&other,&foreign);
            GlimsImageID rej=-1;
            CHECK(preview_curves(engine,other.id,token,&c_half,&rej)==GLIMS_STATUS_NOT_FOUND && rej==0, "wrong/foreign token refuses preview");
            CHECK(apply_curves(engine,&other,token,&c_id)==GLIMS_STATUS_NOT_FOUND, "foreign token refuses Apply");
            CHECK(api->image_ink_snapshot_end(engine,other.id,token)==GLIMS_STATUS_NOT_FOUND, "foreign token refuses End");
            if (cap) source_unchanged(engine,&other,&foreign,"foreign requests preserve foreign image");
            release_snapshot(&foreign);
          }
          close_scene(engine,&other);
          source_unchanged(engine,&scene,&original,"invalid/foreign preserve source");

          CHECK(api->image_ink_snapshot_end(engine,scene.id,token)==GLIMS_STATUS_OK, "Cancel no Undo");
          source_unchanged(engine,&scene,&original,"Cancel leaves source unchanged");
          expired(engine,&scene,token);
          { uint64_t prev=token; token=0; CHECK(begin(engine,&scene,&token)==GLIMS_STATUS_OK && token && token!=prev, "new token after cancel"); }
          CHECK(apply_curves(engine,&scene,token,&c_half)==GLIMS_STATUS_OK, "Apply consumes token");
          expired(engine,&scene,token); token=0;
          if (capture(engine,&scene,&applied)) {
            CHECK(oracle_constant_half(&scene,&applied), "Apply produces expected literal result");
            CHECK(same_metadata(&original,&applied) && applied.undo==original.undo+1 && applied.redo==0, "Apply is one Undo and preserves metadata");
            CHECK(api->image_undo(engine,scene.id)==GLIMS_STATUS_OK, "Undo after Apply");
            if(capture(engine,&scene,&restored)) CHECK(same_pixels(&scene,&original,&restored)&&same_metadata(&original,&restored), "Undo exact"); release_snapshot(&restored);
            CHECK(api->image_redo(engine,scene.id)==GLIMS_STATUS_OK, "Redo after Undo");
            if(capture(engine,&scene,&restored)) CHECK(same_pixels(&scene,&applied,&restored)&&same_metadata(&applied,&restored), "Redo exact"); release_snapshot(&restored);
          }
          release_snapshot(&applied);
          if (capture(engine,&scene,&applied)) {
            CHECK(begin(engine,&scene,&token)==GLIMS_STATUS_OK && token, "begin identity apply");
            CHECK(apply_curves(engine,&scene,token,&c_id)==GLIMS_STATUS_OK, "identity Apply succeeds");
            source_unchanged(engine,&scene,&applied,"identity Apply is exact no-op, no Undo/history change");
            expired(engine,&scene,token); token=0;
          }
        }
        if (token) (void)api->image_ink_snapshot_end(engine,scene.id,token);
        if (pa) api->image_close(engine,pa); if (pb) api->image_close(engine,pb); if (pc) api->image_close(engine,pc);
        release_snapshot(&original); release_snapshot(&a1); release_snapshot(&a2); release_snapshot(&applied); release_snapshot(&restored);
      }
      close_scene(engine, &scene);
    }

  /* Mask coverage float case: 0/.25/.5/1 on .25 input gives .25/.3125/.375/.5 */
  for (uint32_t mode = GLIMS_PLATE_MODE_MULTICHANNEL; mode <= GLIMS_PLATE_MODE_CMYK; mode++) {
    Scene s={0}; Snapshot original={0}, changed={0}, rendered={0}; uint64_t token=0; GlimsImageID result=0;
    GlimsInkCurvesSettings c_half={0}; fill_constant_curves(&c_half,.5);
    if (!create_scene(engine,&s,mode,GLIMS_COLOR_COMPONENT_FLOAT,(guint8*)icc,length)) { close_scene(engine,&s); continue; }
    s.masked=TRUE;
    CHECK(glims_engine_call(engine, prepare_native, &s) == GLIMS_STATUS_OK, "seed exact fractional selection");
    if (capture(engine,&s,&original)) {
      CHECK(begin(engine,&s,&token)==GLIMS_STATUS_OK && token, "soft mask: begin");
      /* change live selection after begin */
      CHECK(mutate(engine, &s, SELECTION) == GLIMS_STATUS_OK,
            "change live selection after snapshot capture");
      capture(engine,&s,&changed);
      CHECK(preview_curves(engine,s.id,token,&c_half,&result)==GLIMS_STATUS_OK && result, "soft mask: preview uses captured mask");
      if (result) {
        Scene sc=copy_scene(&s,result);
        if (capture(engine,&sc,&rendered)) {
          const float expected_masked[] = {.25f,.3125f,.375f,.5f};
          gboolean ok = TRUE;
          for (unsigned i=0;i<PIXELS;i++) {
            float got; memcpy(&got, rendered.raw[0]+i*4,4);
            float exp = expected_masked[i%4];
            if (memcmp(&got,&exp,4)) ok = FALSE;
          }
          for (unsigned p=1;p<PLANES;p++) if (memcmp(rendered.raw[p], original.raw[p], s.bytes)) ok = FALSE;
          CHECK(ok && same_preview_metadata(&original, &rendered), "mask coverage 0/.25/.5/1 on .25 float gives .25/.3125/.375/.5 and preserves other planes and captured metadata");
        }
      }
      CHECK(apply_curves(engine,&s,token,&c_half)!=GLIMS_STATUS_OK, "changed selection refuses Apply");
      source_unchanged(engine,&s,&changed,"refused Apply preserves changed state");
    }
    if (result) api->image_close(engine,result);
    if (token) api->image_ink_snapshot_end(engine,s.id,token);
    release_snapshot(&original); release_snapshot(&changed); release_snapshot(&rendered); close_scene(engine,&s);
  }

  masked_apply_case(engine, GLIMS_PLATE_MODE_MULTICHANNEL, (guint8 *)icc, length);
  masked_apply_case(engine, GLIMS_PLATE_MODE_CMYK, (guint8 *)icc, length);
  extended_identity_case(engine, GLIMS_PLATE_MODE_MULTICHANNEL, (guint8 *)icc, length);
  extended_identity_case(engine, GLIMS_PLATE_MODE_CMYK, (guint8 *)icc, length);
  stale_cases(engine,(guint8*)icc,length);
  lock_case(engine,(guint8*)icc,length);
  close_case(engine,(guint8*)icc,length);
  cache_alternation_case(engine,GLIMS_PLATE_MODE_MULTICHANNEL,(guint8*)icc,length);
  cache_alternation_case(engine,GLIMS_PLATE_MODE_CMYK,(guint8*)icc,length);
  direct_curves_case(engine,GLIMS_PLATE_MODE_MULTICHANNEL,(guint8*)icc,length);
  direct_curves_case(engine,GLIMS_PLATE_MODE_CMYK,(guint8*)icc,length);
  nonmonotone_u16_case(engine,GLIMS_PLATE_MODE_MULTICHANNEL,(guint8*)icc,length);
  nonmonotone_u16_case(engine,GLIMS_PLATE_MODE_CMYK,(guint8*)icc,length);

  CHECK(public_count(engine) == initial_count, "all publicly owned fixture images are closed");
  api->stop(engine); g_free(icc);
  printf("final checks=%u failures=%u\n", checks, failures);
  return failures ? 1 : 0;
}

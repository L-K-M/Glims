/* Independent slot184 Levels-on-ink regression oracle. Production Levels/scalar
 * code is not read or called to compute expectations. Native writes below only
 * prepare fixtures; every tested edit uses the public facade. */
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
  gboolean extreme;
  int nonfinite; /* 0 none, 1 affected NaN, 2 affected +Inf, 3 masked-out NaN */
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
  for (unsigned p = 0; p < PLANES; p++) {
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
  const float values[] = {-.5f, 0.f, .25f, 1.5f, .5f, 1.f, 2.f, -2.f};
  memset(s->seed, 0, sizeof s->seed);
  for (unsigned p = 0; p < PLANES; p++) for (unsigned i = 0; i < PIXELS; i++) {
    if (s->component == GLIMS_COLOR_COMPONENT_U8) {
      guint8 v = (guint8)(i * 17 + p * 51);
      memcpy(s->seed[p] + i, &v, 1);
    } else if (s->component == GLIMS_COLOR_COMPONENT_U16) {
      guint16 v = (guint16)(i * 4369 + p * 2113);
      memcpy(s->seed[p] + i * 2, &v, 2);
    } else {
      float v = values[i % G_N_ELEMENTS(values)] + p * .0625f;
      memcpy(s->seed[p] + i * 4, &v, 4);
    }
  }
  if (s->nonfinite) {
    guint32 bits = s->nonfinite == 2 ? 0x7f800000u : 0x7fc12345u;
    unsigned i = s->nonfinite == 3 ? 0 : PIXELS - 1;
    memcpy(s->seed[0] + i * sizeof(float), &bits, sizeof bits);
  }
  if (s->extreme) {
    const float extremes[] = {FLT_MAX, -FLT_MAX, 0x1p60f, -0x1p60f};
    for (unsigned i = 0; i < G_N_ELEMENTS(extremes); i++)
      memcpy(s->seed[0] + (i * 4 + 2) * sizeof(float), &extremes[i], sizeof(float));
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
  GFile *file = g_file_new_for_uri("file:///component-levels-fixture-source.xcf");
  gimp_image_set_file(image, file);
  gimp_image_set_imported_file(image, file);
  gimp_image_set_exported_file(image, file);
  gimp_image_set_save_a_copy_file(image, file);
  g_object_unref(file);
  gimp_image_undo_free(image);
  gimp_image_clean_all(image);
  return GLIMS_STATUS_OK;
}

/* Explicit independent reference families. Integer affine cases stay in raw
 * units; gamma2 uses sqrtl, never the producer's general pow mapping. */
typedef enum { REF_IDENTITY, REF_REVERSE, REF_HALF, REF_STRETCH_CLAMP,
               REF_SQRT, REF_EQUAL_CLAMP } ReferenceMap;
static void levels_oracle(const Scene *s, const Snapshot *before,
                          guint8 expected[PLANES][MAX_BYTES], ReferenceMap reference) {
  memcpy(expected, before->raw, sizeof before->raw);
  if (reference == REF_IDENTITY) return;
  const long double scale = s->sample_size == 1 ? 255 : s->sample_size == 2 ? 65535 : 1;
  for (unsigned i = 0; i < PIXELS; i++) {
    const long double m = s->masked ? s->mask[i] : 1;
    if (m == 0) continue;
    long double original;
    if (s->sample_size == 1) original = before->raw[0][i];
    else if (s->sample_size == 2) {
      guint16 v; memcpy(&v, before->raw[0] + i * 2, 2); original = v;
    } else { float v; memcpy(&v, before->raw[0] + i * 4, 4); original = v; }
    long double target = original, result;
    switch (reference) {
      case REF_REVERSE:
        /* Halfway between I and 1-I is exactly .5, including extreme float. */
        result = original * (1 - 2 * m) + m * scale;
        break;
      case REF_HALF:
        result = original * (1 - m / 2);
        break;
      case REF_STRETCH_CLAMP:
        target = fminl(scale, fmaxl(0, 2 * original - scale / 2));
        result = m == 1 ? target : original + m * (target - original);
        break;
      case REF_SQRT:
        target = original > 0 ? sqrtl(original / scale) * scale : original;
        result = m == 1 ? target : original + m * (target - original);
        /* Literal known float seed: .25 -> .5, or .375 at half selection. */
        if (scale == 1 && original == .25L && (m == 1 || m == .5L))
          result = m == 1 ? .5L : .375L;
        break;
      case REF_EQUAL_CLAMP:
        target = fminl(scale, fmaxl(0, original - scale / 2));
        result = m == 1 ? target : original + m * (target - original);
        break;
      case REF_IDENTITY: result = original; break;
    }
    if (s->sample_size == 1) {
      expected[0][i] = (guint8)floorl(fminl(scale, fmaxl(0, result)) + .5L);
    } else if (s->sample_size == 2) {
      guint16 v = (guint16)floorl(fminl(scale, fmaxl(0, result)) + .5L);
      memcpy(expected[0] + i * 2, &v, 2);
    } else {
      /* Clamp flags apply to the mapped proposal before selection, never
       * again to the final blend with an extended original. */
      float v = (float)result; memcpy(expected[0] + i * 4, &v, 4);
    }
  }
}

static double sample_value(const Scene *s, const guint8 *raw, unsigned i) {
  if (s->sample_size == 1) return raw[i];
  if (s->sample_size == 2) { guint16 v; memcpy(&v, raw + i * 2, 2); return v; }
  float v; memcpy(&v, raw + i * 4, 4); return v;
}

static void exercise(GlimsEngine *engine, Scene *s, const GlimsInkLevelsSettings *settings,
                     ReferenceMap reference, gboolean refuse, const char *label) {
  Snapshot before = {0}, after = {0}, restored = {0};
  guint8 expected[PLANES][MAX_BYTES];
  char *error = NULL;
  printf("CASE mode=%u component=%u mask=%d invalid=%d %s\n",
         s->mode, s->component, s->masked, s->nonfinite, label); fflush(stdout);
  gboolean prepared = glims_engine_call(engine, prepare_native, s) == GLIMS_STATUS_OK;
  CHECK(prepared, "fixture seeds real scalar planes and initial mask");
  if (!prepared || !capture(engine, s, &before)) goto done;
  GlimsStatus result = api->image_levels_ink(engine, s->id, s->ids[0], settings, &error);
  CHECK(refuse ? result != GLIMS_STATUS_OK : result == GLIMS_STATUS_OK, label);
  if (error) printf("DIAGNOSTIC %s\n", error);
  if (!capture(engine, s, &after)) goto done;
  CHECK(same_metadata(&before, &after), "edit preserves UUID/map/profile/name/visibility/selection/file identity");
  if (refuse) {
    CHECK(same_pixels(s, &before, &after) && same_history(&before, &after),
          "refusal is atomic for every plane, dirty state and Undo/Redo");
    goto done;
  }
  levels_oracle(s, &before, expected, reference);
  gboolean exact = TRUE, changed = FALSE;
  for (unsigned p = 0; p < PLANES; p++) {
    exact &= memcmp(expected[p], after.raw[p], s->bytes) == 0;
    changed |= memcmp(expected[p], before.raw[p], s->bytes) != 0;
    for (unsigned i = 0; i < PIXELS; i++)
      if (memcmp(expected[p] + i * s->sample_size, after.raw[p] + i * s->sample_size, s->sample_size))
        printf("MISMATCH mode=%u component=%u plane=%u index=%u before=%.17g mask=%.17g expected=%.17g actual=%.17g\n",
               s->mode, s->component, p, i, sample_value(s, before.raw[p], i),
               s->masked ? s->mask[i] : 1.0,
               sample_value(s, expected[p], i), sample_value(s, after.raw[p], i));
  }
  CHECK(exact, "all raw output bytes match independent Levels oracle and rounding");
  if (reference == REF_SQRT && s->sample_size == sizeof(float)) {
    float original, actual;
    memcpy(&original, before.raw[0] + 2 * sizeof(float), sizeof original);
    memcpy(&actual, after.raw[0] + 2 * sizeof(float), sizeof actual);
    CHECK(original == .25f && (!s->masked || s->mask[2] == .5f) &&
          actual == (s->masked ? .375f : .5f),
          "literal .25 intensity maps to .5, or .375 through half selection");
  }
  if (!changed) {
    CHECK(same_history(&before, &after), "byte-identical Levels edit adds no history or dirty-state change");
  } else if (result == GLIMS_STATUS_OK) {
    CHECK(after.undo == before.undo + 1 && after.redo == 0, "changed Levels edit creates exactly one Undo");
    CHECK(api->image_undo(engine, s->id) == GLIMS_STATUS_OK, "Undo succeeds");
    if (capture(engine, s, &restored))
      CHECK(same_pixels(s, &before, &restored) && same_metadata(&before, &restored),
            "Undo restores every exact sample and source metadata");
    release_snapshot(&restored);
    CHECK(api->image_redo(engine, s->id) == GLIMS_STATUS_OK, "Redo succeeds");
    if (capture(engine, s, &restored))
      CHECK(same_pixels(s, &after, &restored) && same_metadata(&after, &restored),
            "Redo restores every exact edited sample and source metadata");
  }
done:
  api->free_string(error);
  release_snapshot(&before); release_snapshot(&after); release_snapshot(&restored);
}

typedef struct { Scene *scene; unsigned selection; gboolean locked, damage; } Control;
static GlimsStatus control_native(GlimsEngine *engine, gpointer data) {
  Control *c = data;
  GlimsOpenImage *open = glims_lookup_image(engine, c->scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GList *selected = NULL;
  for (unsigned i = 0; i < c->selection; i++) {
    GimpItem *item = gimp_item_get_by_id(engine->gimp, c->scene->ids[i]);
    if (!item) { g_list_free(selected); return GLIMS_STATUS_FAILED; }
    selected = g_list_append(selected, item);
  }
  gimp_image_set_selected_channels(open->image, selected); g_list_free(selected);
  if (g_list_length(gimp_image_get_selected_channels(open->image)) != c->selection)
    return GLIMS_STATUS_FAILED;
  GimpItem *target = gimp_item_get_by_id(engine->gimp, c->scene->ids[0]);
  gimp_item_set_lock_content(target, c->locked, FALSE);
  if (c->damage) gimp_image_parasite_detach(open->image, GLIMS_PLATE_MAP_PARASITE, FALSE);
  return GLIMS_STATUS_OK;
}

typedef struct { Scene *scene; GlimsItemID target; const GlimsInkLevelsSettings *settings; gboolean busy; char *error; } Request;
static GlimsStatus request_native(GlimsEngine *engine, gpointer data) {
  Request *r = data;
  if (r->busy) engine->busy++;
  GlimsStatus result = api->image_levels_ink(engine, r->scene->id, r->target, r->settings, &r->error);
  if (r->busy) engine->busy--;
  return result;
}
static void refusal(GlimsEngine *engine, Request request, const char *label) {
  Snapshot before = {0}, after = {0};
  if (!capture(engine, request.scene, &before)) goto done;
  CHECK(glims_engine_call(engine, request_native, &request) != GLIMS_STATUS_OK, label);
  if (capture(engine, request.scene, &after))
    CHECK(same_pixels(request.scene, &before, &after) && same_metadata(&before, &after) &&
          same_history(&before, &after), "refused Levels request preserves every native sample/identity/history field");
done:
  api->free_string(request.error);
  release_snapshot(&before); release_snapshot(&after);
}

static gboolean create_scene(GlimsEngine *engine, Scene *s, uint32_t mode, uint32_t component,
                             const guint8 *icc, size_t icc_length) {
  memset(s, 0, sizeof *s);
  s->mode = mode; s->component = component;
  s->sample_size = component == GLIMS_COLOR_COMPONENT_U8 ? 1 :
                   component == GLIMS_COLOR_COMPONENT_U16 ? 2 : 4;
  s->bytes = PIXELS * s->sample_size;
  char *error = NULL;
  GlimsStatus result = mode == GLIMS_PLATE_MODE_CMYK
    ? api->image_new_cmyk(engine, W, H, component, icc, icc_length, &s->id, &error)
    : api->image_new_multichannel(engine, W, H, component, PLANES, &s->id, &error);
  CHECK(result == GLIMS_STATUS_OK && s->id, "create public component document");
  api->free_string(error);
  return result == GLIMS_STATUS_OK && s->id;
}

static void admissions(GlimsEngine *engine, Scene *s, const guint8 *icc, size_t length) {
  CHECK(glims_engine_call(engine, prepare_native, s) == GLIMS_STATUS_OK, "prepare admission fixture");
  GlimsInkLevelsSettings valid = {.struct_size = sizeof valid,
    .value = {0.0, 1.0, 1.0, 0.0, 1.0}, .clamp_input = 0, .clamp_output = 0};
  Request r = {s, s->ids[0], &valid, FALSE, NULL};
  r.target = 0; refusal(engine, r, "zero explicit target refuses");
  r.target = s->ids[1]; refusal(engine, r, "explicit target differs from sole selection and refuses");
  r.target = s->ids[0];
  refusal(engine, (Request){s, s->ids[0], NULL, FALSE, NULL}, "NULL settings refuses");

  GlimsInkLevelsSettings short_st = {.struct_size = sizeof(uint32_t), .value = valid.value, .clamp_input = 0, .clamp_output = 0};
  refusal(engine, (Request){s, s->ids[0], &short_st, FALSE, NULL}, "short struct_size refuses");

  GlimsInkLevelsSettings bad = valid;
  bad.clamp_input = 2; refusal(engine, (Request){s, s->ids[0], &bad, FALSE, NULL}, "clamp_input flag 2 refuses");
  bad = valid; bad.clamp_output = 2; refusal(engine, (Request){s, s->ids[0], &bad, FALSE, NULL}, "clamp_output flag 2 refuses");

  bad = valid; bad.value.low_input = -0.1; refusal(engine, (Request){s, s->ids[0], &bad, FALSE, NULL}, "out-of-range low_input refuses");
  bad = valid; bad.value.high_input = 1.1; refusal(engine, (Request){s, s->ids[0], &bad, FALSE, NULL}, "out-of-range high_input refuses");
  bad = valid; bad.value.low_output = NAN; refusal(engine, (Request){s, s->ids[0], &bad, FALSE, NULL}, "NaN low_output refuses");
  bad = valid; bad.value.high_output = INFINITY; refusal(engine, (Request){s, s->ids[0], &bad, FALSE, NULL}, "infinite high_output refuses");
  bad = valid; bad.value.gamma = 0.09; refusal(engine, (Request){s, s->ids[0], &bad, FALSE, NULL}, "gamma below 0.1 refuses");
  bad = valid; bad.value.gamma = 10.01; refusal(engine, (Request){s, s->ids[0], &bad, FALSE, NULL}, "gamma above 10 refuses");
  bad = valid; bad.value.gamma = NAN; refusal(engine, (Request){s, s->ids[0], &bad, FALSE, NULL}, "nonfinite gamma refuses");

  r.busy = TRUE; refusal(engine, r, "busy engine refuses levels ink edit"); r.busy = FALSE;

  Control c = {s, 0, FALSE, FALSE};
  CHECK(glims_engine_call(engine, control_native, &c) == GLIMS_STATUS_OK, "clear native channel selection");
  refusal(engine, r, "no selected ink refuses");
  c.selection = 2;
  CHECK(glims_engine_call(engine, control_native, &c) == GLIMS_STATUS_OK, "select multiple native inks");
  refusal(engine, r, "multiple selected inks refuse");
  c.selection = 1; c.locked = TRUE;
  CHECK(glims_engine_call(engine, control_native, &c) == GLIMS_STATUS_OK, "lock target content");
  refusal(engine, r, "locked ink refuses");
  c.locked = FALSE;
  CHECK(glims_engine_call(engine, control_native, &c) == GLIMS_STATUS_OK, "restore unlocked sole selection");

  Scene foreign;
  if (create_scene(engine, &foreign, s->mode, s->component, icc, length)) {
    CHECK(glims_engine_call(engine, prepare_native, &foreign) == GLIMS_STATUS_OK, "prepare foreign image");
    Snapshot before = {0}, after = {0};
    gboolean captured = capture(engine, &foreign, &before);
    refusal(engine, (Request){s, foreign.ids[0], &valid, FALSE, NULL}, "foreign-image target refuses");
    if (captured && capture(engine, &foreign, &after))
      CHECK(same_pixels(&foreign, &before, &after) && same_metadata(&before, &after) &&
            same_history(&before, &after), "foreign image also stays unchanged");
    release_snapshot(&before); release_snapshot(&after);
    CHECK(api->image_close(engine, foreign.id) == GLIMS_STATUS_OK, "close foreign image");
    refusal(engine, (Request){s, foreign.ids[0], &valid, FALSE, NULL}, "expired target ID refuses");
  }

  c.damage = TRUE;
  CHECK(glims_engine_call(engine, control_native, &c) == GLIMS_STATUS_OK, "remove map only for corrupt-storage refusal fixture");
  refusal(engine, r, "damaged component map refuses before any write");
}

static void ordinary_refusal(GlimsEngine *engine) {
  GlimsImageID id = 0;
  guint8 before[PIXELS * 4], after[PIXELS * 4];
  GlimsUndoInfo u0 = {0}, u1 = {0};
  char *error = NULL;
  GlimsInkLevelsSettings valid = {.struct_size = sizeof valid, .value = {0,1,1,0,1}, .clamp_input = 0, .clamp_output = 0};
  GlimsStatus st = api->image_new(engine, W, H, &id, &error);
  CHECK(st == GLIMS_STATUS_OK && id, "create ordinary RGB refusal fixture");
  api->free_string(error); error = NULL;
  if (st != GLIMS_STATUS_OK || !id) return;
  gboolean captured = api->image_render(engine, id, 1, (GlimsRect){0, 0, W, H}, before, W * 4) == GLIMS_STATUS_OK &&
                      api->image_undo_info(engine, id, &u0) == GLIMS_STATUS_OK;
  CHECK(captured, "capture ordinary image and history");
  GlimsLayerInfo layer = {0}; int32_t count = 0;
  CHECK(api->image_layers(engine, id, &layer, 1, &count) == GLIMS_STATUS_OK && count > 0,
        "obtain explicit ordinary drawable target");
  CHECK(api->image_levels_ink(engine, id, layer.id, &valid, &error) != GLIMS_STATUS_OK,
        "ordinary RGB drawable cannot stand in for ink");
  gboolean read_back = api->image_render(engine, id, 1, (GlimsRect){0, 0, W, H}, after, W * 4) == GLIMS_STATUS_OK &&
                       api->image_undo_info(engine, id, &u1) == GLIMS_STATUS_OK;
  CHECK(captured && read_back && !memcmp(before, after, sizeof before) &&
        u0.undo_count == u1.undo_count && u0.redo_count == u1.redo_count,
        "ordinary-mode refusal preserves pixels and history");
  api->free_string(error);
  CHECK(api->image_close(engine, id) == GLIMS_STATUS_OK, "close ordinary fixture");
}

/* Cancellation test: event callback only schedules idle source, worker thread calls API. */
typedef struct {
  GlimsEngine *engine;
  GlimsImageID image;
  GlimsItemID channel;
  gint armed, paused, release, timed_out;
  double pause_value;
  GlimsStatus status;
  char *error;
} CancelState;

static gboolean pause_at_checkpoint(gpointer data) {
  CancelState *s = data;
  gint64 deadline = g_get_monotonic_time() + 10 * G_TIME_SPAN_SECOND;
  g_atomic_int_set(&s->paused, 1);
  while (!g_atomic_int_get(&s->release)) {
    g_mutex_lock(&s->engine->lock);
    gboolean stopping = s->engine->stopping;
    g_mutex_unlock(&s->engine->lock);
    if (stopping) break;
    if (g_get_monotonic_time() > deadline) { g_atomic_int_set(&s->timed_out, 1); break; }
    g_main_context_iteration(NULL, FALSE);
    g_usleep(1000);
  }
  return G_SOURCE_REMOVE;
}

static void cancel_event(void *data, const GlimsEvent *event) {
  CancelState *s = data;
  if (event->kind == GLIMS_EVENT_PROGRESS && event->active && event->value >= s->pause_value &&
      g_atomic_int_compare_and_exchange(&s->armed, 1, 0))
    g_idle_add_full(G_PRIORITY_HIGH, pause_at_checkpoint, s, NULL);
}

static gpointer cancel_worker(gpointer data) {
  CancelState *s = data;
  GlimsInkLevelsSettings st = {.struct_size = sizeof st,
    .value = {0.0, 1.0, 1.0, 0.0, 0.0}, .clamp_input = 0, .clamp_output = 0}; /* visible change if applied */
  s->status = api->image_levels_ink(s->engine, s->image, s->channel, &st, &s->error);
  return NULL;
}

static gboolean await_pause(CancelState *s) {
  gint64 deadline = g_get_monotonic_time() + 10 * G_TIME_SPAN_SECOND;
  while (!g_atomic_int_get(&s->paused) && g_get_monotonic_time() < deadline) g_usleep(1000);
  return g_atomic_int_get(&s->paused);
}

static void cancellation_case(GlimsEngine *engine, Scene *scene, CancelState *st,
                              double pause_value, const char *label) {
  Snapshot before = {0}, during = {0}, after = {0};
  st->engine = engine; st->image = scene->id; st->channel = scene->ids[0];
  st->pause_value = pause_value; st->status = GLIMS_STATUS_FAILED; st->error = NULL;
  g_atomic_int_set(&st->paused, 0); g_atomic_int_set(&st->release, 0);
  g_atomic_int_set(&st->timed_out, 0); g_atomic_int_set(&st->armed, 1);
  if (!capture(engine, scene, &before)) goto done;
  GThread *worker = g_thread_new("levels-cancel", cancel_worker, st);
  gboolean paused = await_pause(st);
  CHECK(paused, label);
  if (paused) {
    if (capture(engine, scene, &during))
      CHECK(same_pixels(scene, &before, &during) && same_metadata(&before, &during) &&
            same_history(&before, &during), "live state is unchanged after staging before publication");
    CHECK(api->procedure_cancel(engine) == GLIMS_STATUS_OK, "procedure_cancel reaches active Levels edit");
  }
  g_atomic_int_set(&st->release, 1);
  g_thread_join(worker);
  CHECK(!g_atomic_int_get(&st->timed_out) && st->status == GLIMS_STATUS_CANCELLED,
        "controlled prepublication cancellation must return CANCELLED without timeout");
  if (capture(engine, scene, &after))
    CHECK(same_pixels(scene, &before, &after) && same_metadata(&before, &after) &&
          same_history(&before, &after), "cancel preserves all raw samples, metadata, dirty state and Undo");
  CHECK(api->procedure_cancel(engine) == GLIMS_STATUS_NOT_FOUND, "cancelled Levels progress owner is cleared");
done:
  g_atomic_int_set(&st->armed, 0); g_atomic_int_set(&st->release, 1);
  api->free_string(st->error); st->error = NULL;
  release_snapshot(&before); release_snapshot(&during); release_snapshot(&after);
}

/* Reopen XCF and verify exact persisted state by remapping new IDs by UUID. */
typedef struct {
  Scene *scene;
  guint8 raw[PLANES][MAX_BYTES];
  GBytes *map, *profile, *uuid[PLANES], *visibility[PLANES];
  char names[PLANES][256];
  int layers;
} ReopenSnap;

static GlimsStatus capture_reopen_native(GlimsEngine *engine, gpointer data) {
  ReopenSnap *r = data;
  Scene *scene = r->scene;
  GlimsOpenImage *open = glims_lookup_image(engine, scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image = open->image;
  GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open(open, &storage) || storage.map.count != PLANES)
    return GLIMS_STATUS_FAILED;
  for (unsigned p = 0; p < PLANES; p++) {
    gboolean found = FALSE;
    for (unsigned q = 0; q < PLANES; q++) {
      const GimpParasite *tag = gimp_item_parasite_find(GIMP_ITEM(storage.planes[q]), GLIMS_PLATE_UUID_PARASITE);
      guint32 tag_size = 0;
      const void *tag_bytes = tag ? gimp_parasite_get_data(tag, &tag_size) : NULL;
      if (tag_bytes && tag_size == 16 &&
          memcmp(tag_bytes, storage.map.entries[p].uuid, 16) == 0) {
        GimpDrawable *drawable = GIMP_DRAWABLE(storage.planes[q]);
        gegl_buffer_get(gimp_drawable_get_buffer(drawable), GEGL_RECTANGLE(0, 0, W, H),
                        1, gimp_drawable_get_format(drawable), r->raw[p],
                        GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        g_strlcpy(r->names[p], gimp_object_get_name(GIMP_ITEM(drawable)), sizeof r->names[p]);
        r->uuid[p] = parasite_bytes(gimp_item_parasite_find(GIMP_ITEM(drawable), GLIMS_PLATE_UUID_PARASITE));
        r->visibility[p] = parasite_bytes(gimp_item_parasite_find(GIMP_ITEM(drawable), GLIMS_PLATE_VISIBLE_PARASITE));
        found = TRUE;
        break;
      }
    }
    if (!found) return GLIMS_STATUS_FAILED;
  }
  r->map = parasite_bytes(gimp_image_parasite_find(image, GLIMS_PLATE_MAP_PARASITE));
  r->profile = parasite_bytes(gimp_image_parasite_find(image, GLIMS_PLATE_PROFILE_PARASITE));
  r->layers = gimp_container_get_n_children(gimp_image_get_layers(image));
  return GLIMS_STATUS_OK;
}
static void release_reopen(ReopenSnap *r) {
  g_clear_pointer(&r->map, g_bytes_unref);
  g_clear_pointer(&r->profile, g_bytes_unref);
  for (unsigned p = 0; p < PLANES; p++) {
    g_clear_pointer(&r->uuid[p], g_bytes_unref);
    g_clear_pointer(&r->visibility[p], g_bytes_unref);
  }
}

static void reopen_check(GlimsEngine *engine, Scene *scene, const char *work, const char *label) {
  Snapshot edited = {0};
  char *error = NULL;
  gchar *path = g_build_filename(work, label, NULL);
  if (!capture(engine, scene, &edited)) goto done;
  GlimsStatus saved = api->image_save(engine, scene->id, path, &error);
  CHECK(saved == GLIMS_STATUS_OK, "save edited component Levels fixture to XCF");
  if (saved != GLIMS_STATUS_OK) goto done;
  api->free_string(error); error = NULL;
  GlimsStatus closed = api->image_close(engine, scene->id);
  CHECK(closed == GLIMS_STATUS_OK, "close edited Levels fixture");
  if (closed != GLIMS_STATUS_OK) goto done;
  scene->id = 0;
  CHECK(api->image_open(engine, path, &scene->id, &error) == GLIMS_STATUS_OK && scene->id, "reopen edited Levels fixture XCF");
  api->free_string(error); error = NULL;
  if (scene->id) {
    ReopenSnap r = {0}; r.scene = scene;
    gboolean ok = glims_engine_call(engine, capture_reopen_native, &r) == GLIMS_STATUS_OK;
    CHECK(ok, "remap reopened Levels fixture by UUID and capture exact state");
    if (ok) {
      gboolean raw_eq = TRUE, meta_eq = bytes_equal(edited.map, r.map) && bytes_equal(edited.profile, r.profile) && edited.layers == r.layers;
      for (unsigned p = 0; p < PLANES; p++) {
        raw_eq &= memcmp(edited.raw[p], r.raw[p], scene->bytes) == 0;
        meta_eq &= bytes_equal(edited.uuid[p], r.uuid[p]) && bytes_equal(edited.visibility[p], r.visibility[p]) &&
                   strcmp(edited.names[p], r.names[p]) == 0;
      }
      CHECK(raw_eq && meta_eq, "reopened Levels XCF preserves exact raw bytes, map, profile, names and visibility by UUID order");
    }
    release_reopen(&r);
    /* reopen makes a fresh image id/session state - not asserting old ID/undo/dirty/file identity */
  }
done:
  g_free(path);
  api->free_string(error);
  error = NULL;
  release_snapshot(&edited);
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s PRIVATE_WORK EXTERNAL_CMYK_ICC\n", argv[0]); return 2; }
  gchar *icc = NULL; gsize length = 0;
  if (!g_file_get_contents(argv[2], &icc, &length, NULL) || length < 128 || length > 4u * 1024u * 1024u) {
    fprintf(stderr, "External bounded CMYK profile could not be read.\n"); g_free(icc); return 2;
  }
  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_levels_ink) + sizeof api->image_levels_ink ||
      !api->image_levels_ink || !api->image_new_cmyk || !api->image_new_multichannel) {
    fprintf(stderr, "Adapter lacks slot184.\n"); g_free(icc); return 2;
  }
  gchar *user = g_build_filename(argv[1], "user", NULL), *cache = g_build_filename(argv[1], "cache", NULL);
  char *error = NULL;
  CancelState cancel_state = {0};
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache,
    .on_event = cancel_event, .event_context = &cancel_state};
  GlimsEngine *engine = NULL;
  GlimsStatus result = api->start(&config, &engine, &error);
  g_free(user); g_free(cache);
  if (result != GLIMS_STATUS_OK || !engine) {
    fprintf(stderr, "Engine start: %s\n", error ? error : "failed");
    api->free_string(error); g_free(icc); return 2;
  }
  api->free_string(error);

  cancel_state.engine = engine;
  Scene cancel_scene;
  if (create_scene(engine, &cancel_scene, GLIMS_PLATE_MODE_MULTICHANNEL,
                   GLIMS_COLOR_COMPONENT_U16, (guint8 *)icc, length)) {
    gboolean prepared = glims_engine_call(engine, prepare_native, &cancel_scene) == GLIMS_STATUS_OK;
    CHECK(prepared, "prepare cancellation scene");
    if (prepared) cancellation_case(engine, &cancel_scene, &cancel_state, 1.0,
        "public progress callback pauses after complete staging before publication");
    CHECK(api->image_close(engine, cancel_scene.id) == GLIMS_STATUS_OK, "close cancellation scene");
  }

  const uint32_t components[] = {GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16, GLIMS_COLOR_COMPONENT_FLOAT};
  for (uint32_t mode = GLIMS_PLATE_MODE_MULTICHANNEL; mode <= GLIMS_PLATE_MODE_CMYK; mode++)
    for (unsigned c = 0; c < G_N_ELEMENTS(components); c++) {
      Scene scene;
      if (!create_scene(engine, &scene, mode, components[c], (guint8 *)icc, length)) continue;

      /* Identity: gamma1 affine identity with clamps off -> no change. */
      GlimsInkLevelsSettings identity = {.struct_size = sizeof identity, .value = {0,1,1,0,1}, .clamp_input = 0, .clamp_output = 0};
      scene.masked = FALSE;
      exercise(engine, &scene, &identity, REF_IDENTITY, FALSE, "identity gamma1 affine produces no-op without Undo");

      for (unsigned mask = 0; mask < 2; mask++) {
        scene.masked = mask;
        /* Gamma 1 affine cases with literal/rational expected behavior. */
        GlimsInkLevelsSettings inv_out = {.struct_size = sizeof inv_out, .value = {0,1,1,1,0}, .clamp_input = 0, .clamp_output = 0};
        exercise(engine, &scene, &inv_out, REF_REVERSE, FALSE, "gamma1 output reversal inverts levels through mask once");
        GlimsInkLevelsSettings darken = {.struct_size = sizeof darken, .value = {0,1,1,0,0.5}, .clamp_input = 0, .clamp_output = 0};
        exercise(engine, &scene, &darken, REF_HALF, FALSE, "gamma1 affine maps to output endpoints");
        GlimsInkLevelsSettings shift = {.struct_size = sizeof shift, .value = {0.25,0.75,1,0,1}, .clamp_input = 1, .clamp_output = 0};
        exercise(engine, &scene, &shift, REF_STRETCH_CLAMP, FALSE, "gamma1 input normalization with clamp");
      }

      /* Gamma 2 independent oracle: sqrt via source/MAX in oracle; float .25 -> .5 */
      scene.masked = FALSE;
      GlimsInkLevelsSettings gamma2 = {.struct_size = sizeof gamma2, .value = {0,1,2,0,1}, .clamp_input = 0, .clamp_output = 0};
      exercise(engine, &scene, &gamma2, REF_SQRT, FALSE, "gamma2 uses independent sqrt oracle");
      scene.masked = TRUE;
      exercise(engine, &scene, &gamma2, REF_SQRT, FALSE, "gamma2 square-root target blends selection exactly once");

      /* Equal input endpoints subtract low_input */
      scene.masked = FALSE;
      GlimsInkLevelsSettings equal_in = {.struct_size = sizeof equal_in, .value = {0.5,0.5,1,0,1}, .clamp_input = 1, .clamp_output = 1};
      exercise(engine, &scene, &equal_in, REF_EQUAL_CLAMP, FALSE, "equal input endpoints subtract low_input");
      scene.masked = TRUE;
      exercise(engine, &scene, &equal_in, REF_EQUAL_CLAMP, FALSE,
               "clamp proposal before blending; extended original is not clipped a second time");

      /* Unchanged other planes / metadata / single undo exactness checked in exercise. */
      scene.masked = TRUE;
      if (components[c] == GLIMS_COLOR_COMPONENT_FLOAT) {
        scene.nonfinite = 1; exercise(engine, &scene, &identity, REF_IDENTITY, TRUE, "affected NaN refuses atomically");
        scene.nonfinite = 2; exercise(engine, &scene, &identity, REF_IDENTITY, TRUE, "affected infinity refuses atomically");
        scene.nonfinite = 3; exercise(engine, &scene, &gamma2, REF_SQRT, FALSE, "masked-out NaN remains byte-exact while finite samples edit");
        scene.nonfinite = 0;
        scene.extreme = TRUE;
        exercise(engine, &scene, &identity, REF_IDENTITY, FALSE, "extreme finite float unchanged by identity");
        scene.extreme = FALSE;
      }

      admissions(engine, &scene, (guint8 *)icc, length);
      CHECK(api->image_close(engine, scene.id) == GLIMS_STATUS_OK, "close deliberately damaged admission scene");
      scene.id = 0;

      /* Reopen edited XCF */
      if (create_scene(engine, &scene, mode, components[c], (guint8 *)icc, length)) {
        CHECK(glims_engine_call(engine, prepare_native, &scene) == GLIMS_STATUS_OK, "prepare reopen scene");
        GlimsInkLevelsSettings edit = {.struct_size = sizeof edit, .value = {0,1,1,1,0}, .clamp_input = 0, .clamp_output = 0};
        char *e2 = NULL;
        CHECK(api->image_levels_ink(engine, scene.id, scene.ids[0], &edit, &e2) == GLIMS_STATUS_OK, "apply edit before reopen check");
        api->free_string(e2);
        gchar *name = g_strdup_printf("levels-%u-%u.xcf", mode, components[c]);
        reopen_check(engine, &scene, argv[1], name);
        g_free(name);
        if (scene.id) CHECK(api->image_close(engine, scene.id) == GLIMS_STATUS_OK, "close reopened/remaining Levels image");
      }
    }

  ordinary_refusal(engine);
  api->stop(engine); g_free(icc);
  printf("checks=%u failures=%u\n", checks, failures);
  return failures ? 1 : 0;
}

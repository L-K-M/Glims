/* Independent slot183 regression oracle. Production edit/scalar code is not
 * read or called to compute expectations. Native writes below only prepare
 * fixtures; every tested edit uses the public facade. */
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
  int nonfinite; /* 0 none, 1 affected NaN, 2 affected +Inf, 3 masked-out NaN. */
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
  /* Resolve known IDs directly, so even a deliberately damaged map can be
   * checked for atomic refusal without depending on the producer resolver. */
  for (unsigned p = 0; p < PLANES; p++) {
    GimpItem *item = gimp_item_get_by_id(engine->gimp, scene->ids[p]);
    if (!item || !GIMP_IS_CHANNEL(item) || gimp_item_get_image(item) != image)
      return GLIMS_STATUS_FAILED;
    GimpDrawable *drawable = GIMP_DRAWABLE(item);
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
      a->layers != b->layers || a->selected_count != b->selected_count ||
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
    /* Affected invalid input occurs after earlier finite affected samples. */
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
  /* Capture actual native mask quantization before the edit, not its output. */
  gegl_buffer_get(gimp_drawable_get_buffer(mask), GEGL_RECTANGLE(0, 0, W, H), 1,
                  babl_format("Y float"), s->mask, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  if (s->extreme)
    for (unsigned i = 2; i < PIXELS; i += 4)
      if (s->mask[i] != .5f) return GLIMS_STATUS_FAILED;
  GFile *file = g_file_new_for_uri("file:///component-edit-fixture-source.xcf");
  gimp_image_set_file(image, file);
  gimp_image_set_imported_file(image, file);
  gimp_image_set_exported_file(image, file);
  gimp_image_set_save_a_copy_file(image, file);
  g_object_unref(file);
  gimp_image_undo_free(image);
  gimp_image_clean_all(image);
  return GLIMS_STATUS_OK;
}

/* Independent arithmetic: integer-domain math avoids introducing division
 * error at exact half ties. Mask input is captured before the operation. */
static void expected_pixels(const Scene *s, const Snapshot *before, guint8 expected[PLANES][MAX_BYTES],
                            uint32_t operation, double intensity, double opacity) {
  memcpy(expected, before->raw, sizeof before->raw);
  for (unsigned i = 0; i < PIXELS; i++) {
    long double m = s->masked ? s->mask[i] : 1;
    if (m == 0 || opacity == 0) continue; /* Preserve all original bits. */
    long double original, maximum = 1;
    if (s->sample_size == 1) { original = before->raw[0][i]; maximum = 255; }
    else if (s->sample_size == 2) {
      guint16 v; memcpy(&v, before->raw[0] + i * 2, 2); original = v; maximum = 65535;
    } else { float v; memcpy(&v, before->raw[0] + i * 4, 4); original = v; }
    long double target = operation == GLIMS_INK_EDIT_INVERT ? maximum - original :
                         operation == GLIMS_INK_EDIT_CLEAR ? maximum : intensity * maximum;
    long double result = original + m * opacity * (target - original);
    /* Literal mathematical oracle: halfway between I and 1-I is exactly
     * 0.5 even when I is +/-FLT_MAX or +/-2^60. Neither double nor this
     * platform's long double may evaluate the naive subtraction reliably. */
    if (s->extreme && i % 4 == 2 && operation == GLIMS_INK_EDIT_INVERT &&
        m == .5L && opacity == 1) result = .5L;
    if (s->sample_size == 1) expected[0][i] = (guint8)floorl(result + .5L);
    else if (s->sample_size == 2) {
      guint16 v = (guint16)floorl(result + .5L); memcpy(expected[0] + i * 2, &v, 2);
    } else { float v = (float)result; memcpy(expected[0] + i * 4, &v, 4); }
  }
}
static double sample_value(const Scene *s, const guint8 *raw, unsigned i) {
  if (s->sample_size == 1) return raw[i];
  if (s->sample_size == 2) {
    guint16 v; memcpy(&v, raw + i * 2, 2); return v;
  }
  float v; memcpy(&v, raw + i * 4, 4); return v;
}
static void exercise(GlimsEngine *engine, Scene *s, uint32_t operation,
                     double intensity, double opacity, gboolean refuse, const char *label) {
  Snapshot before = {0}, after = {0}, restored = {0};
  guint8 expected[PLANES][MAX_BYTES];
  char *error = NULL;
  printf("CASE mode=%u component=%u mask=%d invalid=%d %s\n",
         s->mode, s->component, s->masked, s->nonfinite, label); fflush(stdout);
  gboolean prepared = glims_engine_call(engine, prepare_native, s) == GLIMS_STATUS_OK;
  CHECK(prepared, "fixture seeds real scalar planes and initial mask");
  if (!prepared || !capture(engine, s, &before)) goto done;
  GlimsStatus result = api->image_edit_ink(engine, s->id, s->ids[0], operation, intensity, opacity, &error);
  CHECK(refuse ? result != GLIMS_STATUS_OK : result == GLIMS_STATUS_OK, label);
  if (error) printf("DIAGNOSTIC %s\n", error);
  if (!capture(engine, s, &after)) goto done;
  CHECK(same_metadata(&before, &after), "edit preserves UUID/map/profile/name/visibility/selection/file identity");
  if (refuse) {
    CHECK(same_pixels(s, &before, &after) && same_history(&before, &after),
          "refusal is atomic for every plane, dirty state and Undo/Redo");
    goto done;
  }
  expected_pixels(s, &before, expected, operation, intensity, opacity);
  gboolean exact = TRUE, changed = FALSE;
  for (unsigned p = 0; p < PLANES; p++) {
    exact &= memcmp(expected[p], after.raw[p], s->bytes) == 0;
    changed |= memcmp(expected[p], before.raw[p], s->bytes) != 0;
    for (unsigned i = 0; i < PIXELS; i++)
      if (memcmp(expected[p] + i * s->sample_size,
                 after.raw[p] + i * s->sample_size, s->sample_size))
        printf("MISMATCH mode=%u component=%u plane=%u index=%u before=%.17g mask=%.17g operation=%u intensity=%.17g opacity=%.17g expected=%.17g actual=%.17g\n",
               s->mode, s->component, p, i, sample_value(s, before.raw[p], i),
               s->masked ? s->mask[i] : 1.0, operation, intensity, opacity,
               sample_value(s, expected[p], i), sample_value(s, after.raw[p], i));
  }
  CHECK(exact, "all raw output bytes match independent single-selection blend and rounding");
  if (!changed) {
    CHECK(same_history(&before, &after), "byte-identical edit adds no history or dirty-state change");
  } else if (result == GLIMS_STATUS_OK) {
    CHECK(after.undo == before.undo + 1 && after.redo == 0, "changed edit creates exactly one Undo");
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

static void already_paper(GlimsEngine *engine, Scene *scene) {
  Snapshot before = {0}, after = {0};
  char *error = NULL;
  if (!capture(engine, scene, &before)) goto done;
  CHECK(api->image_edit_ink(engine, scene->id, scene->ids[0], GLIMS_INK_EDIT_CLEAR,
                           1, 1, &error) == GLIMS_STATUS_OK,
        "Clear on an already-paper plane succeeds");
  if (capture(engine, scene, &after))
    CHECK(same_pixels(scene, &before, &after) && same_metadata(&before, &after) &&
          same_history(&before, &after), "nonzero-opacity byte-identical Clear adds no Undo");
done:
  api->free_string(error);
  release_snapshot(&before); release_snapshot(&after);
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
typedef struct {
  Scene *scene; GlimsItemID target; uint32_t operation; double intensity, opacity; gboolean busy;
  char *error;
} Request;
static GlimsStatus request_native(GlimsEngine *engine, gpointer data) {
  Request *r = data;
  if (r->busy) engine->busy++;
  GlimsStatus result = api->image_edit_ink(engine, r->scene->id, r->target,
                                         r->operation, r->intensity, r->opacity, &r->error);
  if (r->busy) engine->busy--;
  return result;
}
static void refusal(GlimsEngine *engine, Request request, const char *label) {
  Snapshot before = {0}, after = {0};
  if (!capture(engine, request.scene, &before)) goto done;
  CHECK(glims_engine_call(engine, request_native, &request) != GLIMS_STATUS_OK, label);
  if (capture(engine, request.scene, &after))
    CHECK(same_pixels(request.scene, &before, &after) && same_metadata(&before, &after) &&
          same_history(&before, &after), "refused request preserves every native sample/identity/history field");
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
  Request r = {s, s->ids[0], GLIMS_INK_EDIT_FILL, .25, .5, FALSE, NULL};
  r.target = 0; refusal(engine, r, "zero explicit target refuses");
  r.target = s->ids[1]; refusal(engine, r, "explicit target differs from sole selection and refuses");
  r.target = s->ids[0]; r.operation = 999; refusal(engine, r, "unknown operation refuses");
  r.operation = GLIMS_INK_EDIT_FILL;
  const double invalid[] = {-1, 2, NAN, INFINITY};
  for (unsigned i = 0; i < G_N_ELEMENTS(invalid); i++) {
    r.intensity = invalid[i]; refusal(engine, r, "invalid Fill intensity refuses");
  }
  r.intensity = .25;
  for (unsigned i = 0; i < G_N_ELEMENTS(invalid); i++) {
    r.opacity = invalid[i]; refusal(engine, r, "invalid Fill opacity refuses");
  }
  r.opacity = .5; r.operation = GLIMS_INK_EDIT_CLEAR;
  refusal(engine, r, "noncanonical Clear parameters refuse");
  r.operation = GLIMS_INK_EDIT_INVERT; refusal(engine, r, "noncanonical Invert parameters refuse");
  r.operation = GLIMS_INK_EDIT_FILL; r.busy = TRUE;
  refusal(engine, r, "busy engine refuses ink edit"); r.busy = FALSE;
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
    r.target = foreign.ids[0]; refusal(engine, r, "foreign-image target refuses");
    if (captured && capture(engine, &foreign, &after))
      CHECK(same_pixels(&foreign, &before, &after) && same_metadata(&before, &after) &&
            same_history(&before, &after), "foreign image also stays unchanged");
    release_snapshot(&before); release_snapshot(&after);
    CHECK(api->image_close(engine, foreign.id) == GLIMS_STATUS_OK, "close foreign image");
    refusal(engine, r, "expired target ID refuses");
  }
  r.target = s->ids[0]; c.damage = TRUE;
  CHECK(glims_engine_call(engine, control_native, &c) == GLIMS_STATUS_OK, "remove map only for corrupt-storage refusal fixture");
  refusal(engine, r, "damaged component map refuses before any write");
}

static void ordinary_refusal(GlimsEngine *engine) {
  GlimsImageID id = 0;
  guint8 before[PIXELS * 4], after[PIXELS * 4];
  GlimsUndoInfo u0 = {0}, u1 = {0};
  char *error = NULL;
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
  CHECK(api->image_edit_ink(engine, id, layer.id, GLIMS_INK_EDIT_FILL, .25, 1, &error) != GLIMS_STATUS_OK,
        "ordinary RGB drawable cannot stand in for ink");
  gboolean read_back = api->image_render(engine, id, 1, (GlimsRect){0, 0, W, H}, after, W * 4) == GLIMS_STATUS_OK &&
                       api->image_undo_info(engine, id, &u1) == GLIMS_STATUS_OK;
  CHECK(captured && read_back && !memcmp(before, after, sizeof before) &&
        u0.undo_count == u1.undo_count && u0.redo_count == u1.redo_count,
        "ordinary-mode refusal preserves pixels and history");
  api->free_string(error);
  CHECK(api->image_close(engine, id) == GLIMS_STATUS_OK, "close ordinary fixture");
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s PRIVATE_WORK EXTERNAL_CMYK_ICC\n", argv[0]); return 2; }
  gchar *icc = NULL; gsize length = 0;
  if (!g_file_get_contents(argv[2], &icc, &length, NULL) || length < 128 || length > 4u * 1024u * 1024u) {
    fprintf(stderr, "External bounded CMYK profile could not be read.\n"); g_free(icc); return 2;
  }
  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_edit_ink) + sizeof api->image_edit_ink ||
      !api->image_edit_ink || !api->image_new_cmyk || !api->image_new_multichannel) {
    fprintf(stderr, "Adapter lacks slot183.\n"); g_free(icc); return 2;
  }
  gchar *user = g_build_filename(argv[1], "user", NULL), *cache = g_build_filename(argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus result = api->start(&config, &engine, &error);
  g_free(user); g_free(cache);
  if (result != GLIMS_STATUS_OK || !engine) {
    fprintf(stderr, "Engine start: %s\n", error ? error : "failed");
    api->free_string(error); g_free(icc); return 2;
  }
  api->free_string(error);
  const uint32_t components[] = {GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16, GLIMS_COLOR_COMPONENT_FLOAT};
  for (uint32_t mode = GLIMS_PLATE_MODE_MULTICHANNEL; mode <= GLIMS_PLATE_MODE_CMYK; mode++)
    for (unsigned c = 0; c < G_N_ELEMENTS(components); c++) {
      Scene scene;
      if (!create_scene(engine, &scene, mode, components[c], (guint8 *)icc, length)) continue;
      for (unsigned mask = 0; mask < 2; mask++) {
        scene.masked = mask;
        exercise(engine, &scene, GLIMS_INK_EDIT_FILL, .25, .5, FALSE, "Fill blends opacity and selection once");
        exercise(engine, &scene, GLIMS_INK_EDIT_CLEAR, 1, 1, FALSE, "Clear approaches paper through selection once");
        if (!mask) already_paper(engine, &scene);
        exercise(engine, &scene, GLIMS_INK_EDIT_INVERT, 0, 1, FALSE, "Invert uses pre-edit intensity and selection once");
        exercise(engine, &scene, GLIMS_INK_EDIT_FILL, .25, 0, FALSE, "zero opacity is an exact history no-op");
      }
      scene.masked = FALSE;
      exercise(engine, &scene, GLIMS_INK_EDIT_FILL, 1, .5, FALSE, "integer half ties round upward and floats remain unclipped");
      if (scene.component == GLIMS_COLOR_COMPONENT_FLOAT) {
        scene.masked = TRUE;
        scene.nonfinite = 1; exercise(engine, &scene, GLIMS_INK_EDIT_FILL, .25, 1, TRUE, "affected NaN refuses atomically");
        scene.nonfinite = 2; exercise(engine, &scene, GLIMS_INK_EDIT_CLEAR, 1, 1, TRUE, "affected infinity refuses atomically");
        scene.nonfinite = 3; exercise(engine, &scene, GLIMS_INK_EDIT_INVERT, 0, 1, FALSE, "masked-out NaN remains byte-exact while finite samples edit");
        scene.nonfinite = 1; exercise(engine, &scene, GLIMS_INK_EDIT_FILL, .25, 0, FALSE, "zero opacity remains no-op with nonfinite source");
        scene.nonfinite = 0;
        scene.extreme = TRUE;
        exercise(engine, &scene, GLIMS_INK_EDIT_INVERT, 0, 1, FALSE,
                 "half-selection Invert of +/-FLT_MAX and +/-2^60 is literally 0.5");
        scene.extreme = FALSE;
      }
      scene.masked = FALSE;
      admissions(engine, &scene, (guint8 *)icc, length);
      CHECK(api->image_close(engine, scene.id) == GLIMS_STATUS_OK, "close component fixture including deliberately damaged map");
    }
  ordinary_refusal(engine);
  api->stop(engine); g_free(icc);
  printf("checks=%u failures=%u\n", checks, failures);
  return failures ? 1 : 0;
}

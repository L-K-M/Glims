/* Bounded tests-only ink stroke capture fixture.
 * Public writes through facade slots208/209 and V2 input; private native
 * callbacks only seed/read/control independent component-plane state. */
#include "engine-private.h"
#include "plate-storage.h"
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpcontext.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplist.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#include <float.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define W 24
#define H 16
#define N 4
#define PIXELS (W * H)
#define MAX_BYTES (PIXELS * 4)
#define TARGET 2

static const GlimsEngineAPI *api;
static unsigned checks, failures;
static GlimsResourceID captured_brush;
static const char *cmyk_profile_path;

#define CHECK(c, msg) do { \
  gboolean pass_ = !!(c); checks++; \
  printf("%s %s\n", pass_ ? "ok" : "FAIL", msg); \
  if (!pass_) failures++; fflush(stdout); } while (0)


typedef struct {
  GlimsImageID id;
  GlimsItemID ids[N];
  GlimsInkChannelIdentity identity[N];
  guint8 uuids[N][16];
  uint32_t mode, component, role[N];
  size_t bytes, sample_size;
  guint8 before[N][MAX_BYTES];
  guint8 after[N][MAX_BYTES];
} Scene;

typedef struct {
  Scene *scene;
  guint8 raw[N][MAX_BYTES];
  int undo, redo;
  guint64 revision;
  gboolean dirty;
} Snapshot;

static void free_facts(GlimsStrokeCaptureFacts *facts) {
  if (!facts) return;
  api->free_string(facts->brush_name);
  api->free_string(facts->brush_collection);
  api->free_string(facts->fingerprint);
  memset(facts, 0, sizeof *facts);
  facts->struct_size = sizeof *facts;
}
static gboolean valid_facts(const GlimsStrokeCaptureFacts *facts) {
  if (!facts || !facts->fingerprint || strlen(facts->fingerprint) != 64) return FALSE;
  for (unsigned i = 0; i < 64; i++)
    if (!strchr("0123456789abcdef", facts->fingerprint[i])) return FALSE;
  return facts->brush_name && *facts->brush_name;
}
static GlimsStrokeSampleV2 sample(double x, double y, unsigned time, double pressure) {
  return (GlimsStrokeSampleV2){.struct_size = sizeof(GlimsStrokeSampleV2),
    .x = x, .y = y, .pressure = pressure, .xtilt = 0, .ytilt = 0, .time_ms = time};
}
static GlimsStrokePacketV2 packet(const GlimsStrokeSampleV2 *samples, size_t count) {
  return (GlimsStrokePacketV2){.struct_size = sizeof(GlimsStrokePacketV2),
    .sample_stride = sizeof(GlimsStrokeSampleV2), .samples = samples,
    .count = count, .byte_count = count * sizeof(GlimsStrokeSampleV2)};
}

static GlimsStatus capture_native(GlimsEngine *engine, gpointer data) {
  Snapshot *s = data; Scene *scene = s->scene;
  GlimsOpenImage *open = glims_lookup_image(engine, scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image = open->image;
  for (unsigned p = 0; p < N; p++) {
    GimpItem *item = gimp_item_get_by_id(engine->gimp, scene->ids[p]);
    if (!item || !GIMP_IS_CHANNEL(item) || gimp_item_get_image(item) != image)
      return GLIMS_STATUS_FAILED;
    GimpDrawable *drawable = GIMP_DRAWABLE(item);
    gegl_buffer_get(gimp_drawable_get_buffer(drawable), GEGL_RECTANGLE(0, 0, W, H),
                    1, gimp_drawable_get_format(drawable), s->raw[p],
                    GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  }
  s->undo = gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image));
  s->redo = gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image));
  s->revision = open->history_revision;
  s->dirty = gimp_image_is_dirty(image);
  return GLIMS_STATUS_OK;
}
static gboolean take_snapshot(GlimsEngine *engine, Scene *scene, Snapshot *out) {
  memset(out, 0, sizeof *out); out->scene = scene;
  GlimsStatus st = glims_engine_call(engine, capture_native, out);
  CHECK(st == GLIMS_STATUS_OK, "capture independent native plane/history snapshot");
  return st == GLIMS_STATUS_OK;
}
typedef struct { GlimsImageID image; GWeakRef mask; } MaskLifetime;
static GlimsStatus watch_mask_native(GlimsEngine *engine, gpointer data) {
  MaskLifetime *watch = data;
  GlimsOpenImage *open = glims_lookup_image(engine, watch->image);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  g_weak_ref_set(&watch->mask, gimp_drawable_get_buffer(
    GIMP_DRAWABLE(gimp_image_get_mask(open->image))));
  return GLIMS_STATUS_OK;
}
static gboolean same_pixels(const Scene *scene, const Snapshot *a, const Snapshot *b) {
  for (unsigned p = 0; p < N; p++)
    if (memcmp(a->raw[p], b->raw[p], scene->bytes)) return FALSE;
  return TRUE;
}
static gboolean same_history(const Snapshot *a, const Snapshot *b) {
  return a->undo == b->undo && a->redo == b->redo && a->revision == b->revision && a->dirty == b->dirty;
}

static double sample_value(const Scene *s, const guint8 *raw, unsigned pixel) {
  if (s->sample_size == 1) return raw[pixel] / 255.0;
  if (s->sample_size == 2) { guint16 v; memcpy(&v, raw + 2*pixel, 2); return v / 65535.0; }
  float v; memcpy(&v, raw + 4*pixel, 4); return (double)v;
}
static void set_sample(Scene *s, guint8 *raw, unsigned pixel, double value) {
  if (s->sample_size == 1) { guint8 v = (guint8)(value * 255.0 + 0.5); memcpy(raw + pixel, &v, 1); }
  else if (s->sample_size == 2) { guint16 v = (guint16)(value * 65535.0 + 0.5); memcpy(raw + 2*pixel, &v, 2); }
  else { float v = (float)value; memcpy(raw + 4*pixel, &v, 4); }
}

typedef struct { Scene *scene; gboolean half; } SeedArgs;
static GlimsStatus seed_scene_native(GlimsEngine *engine, gpointer data) {
  SeedArgs *a = data; Scene *s = a->scene;
  GlimsOpenImage *open = glims_lookup_image(engine, s->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open(open, &storage) || storage.map.count != N)
    return GLIMS_STATUS_FAILED;
  float mask[PIXELS];
  for (unsigned i = 0; i < PIXELS; i++) mask[i] = a->half ? 0.5f : 1.0f;
  GimpDrawable *sel = GIMP_DRAWABLE(gimp_image_get_mask(open->image));
  gegl_buffer_set(gimp_drawable_get_buffer(sel), GEGL_RECTANGLE(0, 0, W, H), 0,
                  babl_format("Y float"), mask, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(sel, 0, 0, W, H);
  for (unsigned p = 0; p < N; p++) {
    GimpDrawable *d = GIMP_DRAWABLE(storage.planes[p]);
    s->ids[p] = gimp_item_get_id(GIMP_ITEM(d));
    for (unsigned i = 0; i < PIXELS; i++) {
      /* selected non-first plane paper 1.0, others known nonuniform bytes */
      double value;
      if (p == TARGET) value = 1.0;
      else value = ((double)((i * (7 + p * 3) + p * 19) % 97)) / 97.0;
      set_sample(s, s->before[p], i, value);
    }
    gegl_buffer_set(gimp_drawable_get_buffer(d), GEGL_RECTANGLE(0, 0, W, H), 0,
                    gimp_drawable_get_format(d), s->before[p], GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d, 0, 0, W, H);
  }
  GList *selected = g_list_append(NULL, storage.planes[TARGET]);
  gimp_image_set_selected_channels(open->image, selected); g_list_free(selected);
  gimp_image_undo_free(open->image); gimp_image_clean_all(open->image);
  return GLIMS_STATUS_OK;
}

static gboolean read_cmyk_profile(guint8 **icc, gsize *len, char **error) {
  const char *path = cmyk_profile_path ? cmyk_profile_path : "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc";
  if (!path || !*path) { if (error) *error = g_strdup("CMYK profile path is empty"); return FALSE; }
  if (!g_file_get_contents(path, (gchar **)icc, len, NULL) || !*icc || *len < 128 || *len > 4u*1024u*1024u) {
    if (error) *error = g_strdup_printf("explicit CMYK profile missing or invalid (128..4MiB): %s", path);
    g_free(*icc); *icc = NULL; *len = 0; return FALSE;
  }
  return TRUE;
}

static GlimsStatus choose_capture_brush_native(GlimsEngine *engine, gpointer unused) {
  (void)unused;
  GimpContainer *factory = gimp_data_factory_get_container(engine->gimp->brush_factory);
  GimpObject *object = gimp_container_get_child_by_name(factory, "2. Hardness 025");
  if (!GIMP_IS_BRUSH(object)) return GLIMS_STATUS_FAILED;
  captured_brush = gimp_data_get_id(GIMP_DATA(object));
  gimp_context_set_brush(gimp_get_user_context(engine->gimp), GIMP_BRUSH(object));
  return captured_brush > 0 ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static gboolean create_scene(GlimsEngine *engine, Scene *s, uint32_t mode, uint32_t component, gboolean half) {
  memset(s, 0, sizeof *s);
  s->mode = mode; s->component = component;
  s->sample_size = component == GLIMS_COLOR_COMPONENT_U8 ? 1 : component == GLIMS_COLOR_COMPONENT_U16 ? 2 : 4;
  s->bytes = PIXELS * s->sample_size;
  char *error = NULL;
  GlimsStatus st;
  if (mode == GLIMS_COLOR_MODE_CMYK) {
    guint8 *icc = NULL; gsize len = 0;
    if (!read_cmyk_profile(&icc, &len, &error)) {
      CHECK(FALSE, "CMYK profile load for scene"); if (error) fprintf(stderr, "CMYK profile: %s\n", error);
      g_free(error); return FALSE;
    }
    st = api->image_new_cmyk(engine, W, H, component, icc, len, &s->id, &error);
    g_free(icc);
  } else {
    st = api->image_new_multichannel(engine, W, H, component, N, &s->id, &error);
  }
  CHECK(st == GLIMS_STATUS_OK && s->id, "create real component ink document");
  if (st != GLIMS_STATUS_OK || !s->id) { if (error) fprintf(stderr, "create: %s\n", error); api->free_string(error); return FALSE; }
  api->free_string(error);
  SeedArgs args = {.scene = s, .half = half};
  st = glims_engine_call(engine, seed_scene_native, &args);
  CHECK(st == GLIMS_STATUS_OK, "seed authoritative scalar planes and selection");
  if (st != GLIMS_STATUS_OK) { api->image_close(engine, s->id); s->id = 0; return FALSE; }
  /* capture identities via facade after seeding */
  for (unsigned p = 0; p < N; p++) {
    s->identity[p].struct_size = sizeof s->identity[p];
    st = api->image_ink_channel_identity(engine, s->id, s->ids[p], &s->identity[p]);
    CHECK(st == GLIMS_STATUS_OK, "read ink channel identity");
    if (st != GLIMS_STATUS_OK) {
      api->image_close(engine, s->id); s->id = 0; return FALSE;
    }
    memcpy(s->uuids[p], s->identity[p].uuid, 16);
    s->role[p] = s->identity[p].role;
  }
  return TRUE;
}
static void close_scene(GlimsEngine *engine, Scene *s) {
  if (!s) return;
  if (s->id) CHECK(api->image_close(engine, s->id) == GLIMS_STATUS_OK, "close scene");
  s->id = 0;
}

static GlimsInkStrokeTarget make_target(const Scene *s) {
  GlimsInkStrokeTarget t = {.struct_size = sizeof t, .channel = s->ids[TARGET],
    .color_mode = s->mode, .role = s->role[TARGET]};
  memcpy(t.uuid, s->uuids[TARGET], 16);
  return t;
}
static GlimsBrushSettings brush_for_tool(uint32_t tool) {
  GlimsBrushSettings b = {.struct_size = sizeof b, .tool = tool, .size = 11.0,
    .opacity = 0.5, .red = 0.0, .green = 0.0, .blue = 0.0,
    .pressure_size = FALSE, .hardness = 1.0, .rate = 100.0, .flow = 100.0, .exposure = -1.0};
  return b;
}
/* Forward declarations for case helpers will be added below as needed. */
static void run_matrix_and_guards(GlimsEngine *engine, const char *workdir); 

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: %s WORKDIR\n", argv[0]); return 2; }
  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api) { fprintf(stderr, "engine API unavailable\n"); return 2; }
  cmyk_profile_path = g_getenv("GLIMS_TEST_CMYK_PROFILE");
  if (!cmyk_profile_path || !*cmyk_profile_path)
    cmyk_profile_path = "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc";

  size_t need = offsetof(GlimsEngineAPI, stroke_cancel_ink) + sizeof(api->stroke_cancel_ink);
  gboolean has_slots = api->struct_size >= need &&
                       api->stroke_begin_ink_with_capture_facts != NULL &&
                       api->stroke_cancel_ink != NULL;
  CHECK(has_slots, "producer exposes slot208/209 after bounded API prefix check");
  if (!has_slots) {
    printf("checks=%u failures=%u\n", checks, failures);
    return 1;
  }

  /* verify CMYK profile explicitly now (required, not skip) */
  guint8 *icc = NULL; gsize icc_len = 0; char *err = NULL;
  if (!read_cmyk_profile(&icc, &icc_len, &err)) {
    CHECK(FALSE, "bounded CMYK profile available (GLIMS_TEST_CMYK_PROFILE or default Generic CMYK Profile.icc)");
    if (err) fprintf(stderr, "CMYK profile error: %s\n", err);
    g_free(err);
    printf("checks=%u failures=%u\n", checks, failures);
    return 1;
  }
  g_free(icc);
  CHECK(icc_len >= 128 && icc_len <= 4u*1024u*1024u, "CMYK profile size bounded 128..4MiB");

  gchar *user = g_build_filename(argv[1], "user", NULL);
  gchar *cache = g_build_filename(argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL;
  err = NULL;
  GlimsStatus st = api->start(&config, &engine, &err);
  g_free(user); g_free(cache);
  if (st != GLIMS_STATUS_OK || !engine) {
    CHECK(FALSE, "engine starts with private work directories");
    if (err) fprintf(stderr, "start: %s\n", err);
    api->free_string(err);
    printf("checks=%u failures=%u\n", checks, failures);
    return 1;
  }
  api->free_string(err);
  CHECK(glims_engine_call(engine, choose_capture_brush_native, NULL) == GLIMS_STATUS_OK && captured_brush > 0,
        "select stock generated mask brush 2. Hardness 025 from native factory");

  if (captured_brush > 0) run_matrix_and_guards(engine, argv[1]);
  else CHECK(FALSE, "capture brush available; dependent cases skipped");

  api->stop(engine);
  printf("checks=%u failures=%u\n", checks, failures);
  return failures ? 1 : 0;
}

typedef struct { GlimsItemID id; uint32_t role; guint8 uuid[16]; } MutateArgs;
static GlimsStatus mutate_select_wrong_native(GlimsEngine *engine, gpointer data) {
  MutateArgs *a = data; GlimsOpenImage *open = NULL; /* not used */
  (void)open; GimpItem *item = gimp_item_get_by_id(engine->gimp, a->id);
  if (!item) return GLIMS_STATUS_FAILED;
  GimpImage *image = gimp_item_get_image(item);
  GList *sel = g_list_append(NULL, item);
  gimp_image_set_selected_channels(image, sel);
  g_list_free(sel);
  return GLIMS_STATUS_OK;
}
static GlimsStatus select_target_native(GlimsEngine *engine, gpointer data) {
  MutateArgs *a = data; GimpItem *item = gimp_item_get_by_id(engine->gimp, a->id);
  if (!item) return GLIMS_STATUS_FAILED;
  GimpImage *image = gimp_item_get_image(item);
  GList *sel = g_list_append(NULL, item);
  gimp_image_set_selected_channels(image, sel);
  g_list_free(sel);
  return GLIMS_STATUS_OK;
}

static gboolean approx_equal(Scene *s, double got, double expected) {
  if (s->sample_size == 1) return fabs(got - expected) <= 1.0 / 255.0 + 1e-12;
  if (s->sample_size == 2) return fabs(got - expected) <= 1.0 / 65535.0 + 1e-12;
  return fabs(got - expected) <= 1e-6;
}

static void run_capture_boundary_checks(GlimsEngine *engine) {
  Scene scene = {0};
  if (!create_scene(engine, &scene, GLIMS_COLOR_MODE_MULTICHANNEL,
                    GLIMS_COLOR_COMPONENT_U8, FALSE)) return;
  GlimsInkStrokeTarget target = make_target(&scene);
  GlimsBrushSettings brush = brush_for_tool(GLIMS_PAINT_PENCIL);
  GlimsStrokeSampleV2 first = sample(12.5, 8.5, 1, 1.0);
  GlimsStrokePacketV2 input = packet(&first, 1);
  GlimsStrokeID stroke = 123;
  char *error = NULL;
  guint8 output[sizeof(GlimsStrokeCaptureFacts) + 18], before[sizeof output];
  uint32_t short_size = sizeof(GlimsStrokeCaptureFacts) - 1;
  memset(output, 0xa5, sizeof output);
  memcpy(output + 1, &short_size, sizeof short_size);
  memcpy(before, output, sizeof before);
  GlimsStatus status = api->stroke_begin_ink_with_capture_facts(engine, scene.id,
    captured_brush, &target, &brush, &input, NULL, &stroke,
    (GlimsStrokeCaptureFacts *)(output + 1), &error);
  CHECK(status == GLIMS_STATUS_INVALID_ARGUMENT && stroke == 0,
        "short unaligned facts capacity refuses before painting");
  CHECK(memcmp(output, before, sizeof output) == 0,
        "short facts output and canaries remain byte-identical");
  api->free_string(error); error = NULL;

  guint8 target_bytes[sizeof target + 1], brush_bytes[sizeof brush + 1];
  guint8 packet_bytes[sizeof input + 1];
  memcpy(target_bytes + 1, &target, sizeof target);
  memcpy(brush_bytes + 1, &brush, sizeof brush);
  memcpy(packet_bytes + 1, &input, sizeof input);
  uint32_t extended_size = sizeof(GlimsStrokeCaptureFacts) + 16;
  memcpy(output + 1, &extended_size, sizeof extended_size);
  status = api->stroke_begin_ink_with_capture_facts(engine, scene.id,
    captured_brush, (GlimsInkStrokeTarget *)(target_bytes + 1),
    (GlimsBrushSettings *)(brush_bytes + 1), (GlimsStrokePacketV2 *)(packet_bytes + 1),
    NULL, &stroke, (GlimsStrokeCaptureFacts *)(output + 1), &error);
  CHECK(status == GLIMS_STATUS_OK && stroke > 0,
        "unaligned target settings packet and extended facts are accepted");
  GlimsStrokeCaptureFacts facts;
  memcpy(&facts, output + 1, sizeof facts);
  CHECK(facts.struct_size == extended_size && valid_facts(&facts),
        "extended facts preserve caller capacity and transfer owned strings");
  gboolean guards_intact = output[0] == 0xa5;
  for (size_t i = 1 + sizeof facts; i < sizeof output; i++)
    guards_intact = guards_intact && output[i] == 0xa5;
  CHECK(guards_intact, "extended facts preserve unknown tail and surrounding canaries");
  api->free_string(error); error = NULL;
  free_facts(&facts);
  if (status == GLIMS_STATUS_OK && stroke > 0)
    CHECK(api->stroke_cancel_ink(engine, stroke) == GLIMS_STATUS_OK,
          "cancel unaligned-input witness");

  memset(output, 0xa5, sizeof output);
  memcpy(output + 1, &extended_size, sizeof extended_size);
  stroke = 123;
  status = api->stroke_begin_ink_with_capture_facts(NULL, scene.id, captured_brush,
    &target, &brush, &input, NULL, &stroke, (GlimsStrokeCaptureFacts *)(output + 1), &error);
  memcpy(&facts, output + 1, sizeof facts);
  CHECK(status == GLIMS_STATUS_NOT_RUNNING && stroke == 0 &&
        facts.struct_size == extended_size && !facts.brush_name &&
        !facts.brush_collection && !facts.fingerprint,
        "not-running refusal clears accepted known facts and stroke output");
  guards_intact = output[0] == 0xa5;
  for (size_t i = 1 + sizeof facts; i < sizeof output; i++)
    guards_intact = guards_intact && output[i] == 0xa5;
  CHECK(guards_intact, "not-running refusal preserves unknown facts tail");
  api->free_string(error);
  free_facts(&facts);
  close_scene(engine, &scene);
}

static void run_one_case(GlimsEngine *engine, uint32_t mode, uint32_t component, uint32_t tool, const char *label, const char *workdir) {
  (void)workdir;
  Scene legacy = {0}, typed = {0}, replay = {0};
  Snapshot b0 = {0}, b1 = {0}, b2 = {0}, l_after = {0}, t_after = {0}, r_after = {0};
  Snapshot undo_l = {0}, undo_t = {0}, undo_r = {0}, redo_l = {0}, redo_t = {0}, redo_r = {0};
  gboolean legacy_ready = FALSE, typed_ready = FALSE;
  char *error = NULL;
  if (!create_scene(engine, &legacy, mode, component, FALSE)) return;
  if (!create_scene(engine, &typed, mode, component, FALSE)) { close_scene(engine, &legacy); return; }
  if (!create_scene(engine, &replay, mode, component, FALSE)) { close_scene(engine, &legacy); close_scene(engine, &typed); return; }
  if (!take_snapshot(engine, &legacy, &b0) || !take_snapshot(engine, &typed, &b1) ||
      !take_snapshot(engine, &replay, &b2)) {
    close_scene(engine, &replay); close_scene(engine, &typed); close_scene(engine, &legacy); return;
  }
  if (!(same_pixels(&legacy, &b0, &b1) && same_pixels(&legacy, &b0, &b2))) {
    CHECK(FALSE, "independent seeded scenes start byte-identical for fair comparison");
  }

  GlimsBrushSettings bs = brush_for_tool(tool);
  GlimsStrokeID sid = 0;
  GlimsStatus st;
  /* legacy path uses V2 explicit brush for same trace contract */
  GlimsStrokeSampleV2 s1 = sample(12.5, 8.5, 100, 1.0), s2 = sample(13.5, 8.5, 110, 1.0);
  GlimsStrokePacketV2 p1 = packet(&s1, 1), p2 = packet(&s2, 1);
  st = api->stroke_begin_v2(engine, legacy.id, legacy.ids[TARGET], captured_brush, &bs, &p1, &sid, &error);
  if (st != GLIMS_STATUS_OK) { printf("legacy begin status=%d err=%s\n", st, error ? error : ""); }
  CHECK(st == GLIMS_STATUS_OK && sid > 0, "legacy V2 begin on selected ink with explicit brush");
  api->free_string(error); error = NULL;
  if (st == GLIMS_STATUS_OK && sid > 0) {
    st = api->stroke_continue_v2(engine, sid, &p2, &error);
    CHECK(st == GLIMS_STATUS_OK, "legacy V2 continuation");
    api->free_string(error); error = NULL;
    st = api->stroke_end(engine, sid);
    CHECK(st == GLIMS_STATUS_OK, "legacy V2 end");
    if (st == GLIMS_STATUS_OK) legacy_ready = take_snapshot(engine, &legacy, &l_after);
  }

  GlimsInkStrokeTarget target = make_target(&typed);
  GlimsStrokeCaptureFacts facts = {.struct_size = sizeof facts};
  sid = 0;
  st = api->stroke_begin_ink_with_capture_facts(engine, typed.id, captured_brush, &target, &bs, &p1, NULL, &sid, &facts, &error);
  if (st != GLIMS_STATUS_OK) { printf("typed begin status=%d err=%s\n", st, error ? error : ""); }
  CHECK(st == GLIMS_STATUS_OK && sid > 0, "typed ink capture begin (resource 0/explicit allowed per case)"); /* explicit brush passed */
  /* try again with resource 0 for live/default facts if explicit-only contract requires? we used explicit; also do zero path in guards */
  api->free_string(error); error = NULL;
  CHECK(valid_facts(&facts), "typed capture facts nonempty with 64 lowercase hex fingerprint");
  if (st == GLIMS_STATUS_OK && sid > 0) {
    st = api->stroke_continue_v2(engine, sid, &p2, &error);
    CHECK(st == GLIMS_STATUS_OK, "typed ink continuation");
    api->free_string(error); error = NULL;
    st = api->stroke_end(engine, sid);
    CHECK(st == GLIMS_STATUS_OK, "typed ink end");
    if (st == GLIMS_STATUS_OK) typed_ready = take_snapshot(engine, &typed, &t_after);
  }
  /* compare legacy vs typed */
  if (legacy_ready && typed_ready) {
    CHECK(same_pixels(&legacy, &l_after, &t_after), "typed capture matches legacy raw plane bytes");
    CHECK(l_after.undo == b0.undo + 1 && t_after.undo == b1.undo + 1, "both paths produce one Undo step");
  }
  /* exact undo/redo typed */
  if (typed_ready) {
    CHECK(api->image_undo(engine, typed.id) == GLIMS_STATUS_OK, "typed undo");
    CHECK(take_snapshot(engine, &typed, &undo_t), "typed undo snapshot");
    CHECK(same_pixels(&typed, &b1, &undo_t), "typed undo restores exact baseline bytes");
    CHECK(api->image_redo(engine, typed.id) == GLIMS_STATUS_OK, "typed redo");
    CHECK(take_snapshot(engine, &typed, &redo_t), "typed redo snapshot");
    CHECK(same_pixels(&typed, &t_after, &redo_t), "typed redo restores exact edited bytes");
  }
  if (legacy_ready) {
    CHECK(api->image_undo(engine, legacy.id) == GLIMS_STATUS_OK, "legacy undo");
    CHECK(take_snapshot(engine, &legacy, &undo_l), "legacy undo snapshot");
    CHECK(same_pixels(&legacy, &b0, &undo_l), "legacy undo restores exact baseline bytes");
    CHECK(api->image_redo(engine, legacy.id) == GLIMS_STATUS_OK, "legacy redo");
    CHECK(take_snapshot(engine, &legacy, &redo_l), "legacy redo snapshot");
    CHECK(same_pixels(&legacy, &l_after, &redo_l), "legacy redo restores exact edited bytes");
  }

  /* guarded replay */
  if (typed_ready && valid_facts(&facts)) {
    CHECK(api->image_undo(engine, typed.id) == GLIMS_STATUS_OK, "Undo before expected-facts replay");
    GlimsInkStrokeTarget rt = make_target(&typed);
    GlimsStrokeCaptureFacts rf = {.struct_size = sizeof rf};
    sid = 0;
    st = api->stroke_begin_ink_with_capture_facts(engine, typed.id, captured_brush, &rt, &bs, &p1, facts.fingerprint, &sid, &rf, &error);
    CHECK(st == GLIMS_STATUS_OK && sid > 0, "guarded replay begin with explicit brush+fingerprint");
    api->free_string(error); error = NULL;
    free_facts(&rf);
    if (st == GLIMS_STATUS_OK && sid > 0) {
      st = api->stroke_continue_v2(engine, sid, &p2, &error); CHECK(st == GLIMS_STATUS_OK, "replay continuation"); api->free_string(error); error = NULL;
      st = api->stroke_end(engine, sid); CHECK(st == GLIMS_STATUS_OK, "replay end");
      CHECK(take_snapshot(engine, &typed, &r_after), "replay after snapshot");
      CHECK(same_pixels(&typed, &t_after, &r_after), "replay byte pixels match typed result");
      CHECK(r_after.undo == b1.undo + 1, "replay creates one Undo");
      CHECK(api->image_undo(engine, typed.id) == GLIMS_STATUS_OK, "replay undo");
      CHECK(take_snapshot(engine, &typed, &undo_r), "replay undo snapshot");
      CHECK(same_pixels(&typed, &b1, &undo_r), "replay undo restores baseline");
      CHECK(api->image_redo(engine, typed.id) == GLIMS_STATUS_OK, "replay redo");
      CHECK(take_snapshot(engine, &typed, &redo_r), "replay redo snapshot");
      CHECK(same_pixels(&typed, &r_after, &redo_r), "replay redo restores result");
    }
  }
  /* pencil center oracle: intensity 0, opacity .5, paper 1 -> .5 */
  if (tool == GLIMS_PAINT_PENCIL && typed_ready) {
    unsigned center = (H/2) * W + (W/2);
    double got = sample_value(&typed, t_after.raw[TARGET], center);
    CHECK(approx_equal(&typed, got, 0.5), "pencil center oracle approx .5 from paper 1 intensity 0 opacity .5");
  }

  printf("CASE matrix mode=%u comp=%u tool=%u %s done\n", mode, component, tool, label);
  free_facts(&facts);
  close_scene(engine, &replay); close_scene(engine, &typed); close_scene(engine, &legacy);
}

static void run_matrix_and_guards(GlimsEngine *engine, const char *workdir) {
  run_capture_boundary_checks(engine);
  /* 12 cases matrix */
  run_one_case(engine, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_U8, GLIMS_PAINT_PAINTBRUSH, "cmyk-u8-brush", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_U8, GLIMS_PAINT_PENCIL, "cmyk-u8-pencil", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_U16, GLIMS_PAINT_PAINTBRUSH, "cmyk-u16-brush", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_U16, GLIMS_PAINT_PENCIL, "cmyk-u16-pencil", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_FLOAT, GLIMS_PAINT_PAINTBRUSH, "cmyk-f32-brush", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_FLOAT, GLIMS_PAINT_PENCIL, "cmyk-f32-pencil", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_U8, GLIMS_PAINT_PAINTBRUSH, "mc-u8-brush", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_U8, GLIMS_PAINT_PENCIL, "mc-u8-pencil", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_U16, GLIMS_PAINT_PAINTBRUSH, "mc-u16-brush", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_U16, GLIMS_PAINT_PENCIL, "mc-u16-pencil", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_FLOAT, GLIMS_PAINT_PAINTBRUSH, "mc-f32-brush", workdir);
  run_one_case(engine, GLIMS_COLOR_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_FLOAT, GLIMS_PAINT_PENCIL, "mc-f32-pencil", workdir);

  /* Representative half-selection oracle (.75) */
  {
    Scene s = {0};
    if (create_scene(engine, &s, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_U8, TRUE)) {
      Snapshot before = {0}, after = {0}; take_snapshot(engine, &s, &before);
      GlimsBrushSettings bs = brush_for_tool(GLIMS_PAINT_PENCIL);
      GlimsStrokeSampleV2 s1 = sample(W/2.0 + 0.5, H/2.0 + 0.5, 1, 1.0), s2 = sample(W/2.0 + 1.5, H/2.0 + 0.5, 2, 1.0);
      GlimsStrokePacketV2 p1 = packet(&s1, 1), p2 = packet(&s2, 1);
      GlimsInkStrokeTarget t = make_target(&s);
      GlimsStrokeCaptureFacts f = {.struct_size = sizeof f}; GlimsStrokeID sid = 0; char *e = NULL;
      GlimsStatus st = api->stroke_begin_ink_with_capture_facts(engine, s.id, captured_brush, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st == GLIMS_STATUS_OK && sid > 0, "half-selection typed begin"); api->free_string(e);
      if (st == GLIMS_STATUS_OK && sid > 0) {
        e = NULL; st = api->stroke_continue_v2(engine, sid, &p2, &e); CHECK(st == GLIMS_STATUS_OK, "half-selection continue"); api->free_string(e);
        st = api->stroke_end(engine, sid); CHECK(st == GLIMS_STATUS_OK, "half-selection end");
        take_snapshot(engine, &s, &after);
        unsigned center = (H/2) * W + (W/2);
        double got = sample_value(&s, after.raw[TARGET], center);
        /* paper 1, mask .5, opacity .5, intensity 0 => 1 + .5*.5*(0-1)=.75 once */
        CHECK(approx_equal(&s, got, 0.75), "representative half-selection oracle approx .75");
      }
      free_facts(&f);
      close_scene(engine, &s);
    }
  }

  /* Guard refusals and default-resource-0 capture */
  {
    Scene s = {0};
    if (create_scene(engine, &s, GLIMS_COLOR_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_U8, FALSE)) {
      Snapshot before = {0}; take_snapshot(engine, &s, &before);
      GlimsBrushSettings bs = brush_for_tool(GLIMS_PAINT_PENCIL);
      GlimsStrokeSampleV2 s1 = sample(12.5, 8.5, 1, 1.0); GlimsStrokePacketV2 p1 = packet(&s1, 1);
      GlimsInkStrokeTarget t = make_target(&s); GlimsStrokeID sid = 123; GlimsStrokeCaptureFacts f = {.struct_size = sizeof f}; char *e = NULL;

      /* bad mode */
      t.color_mode = GLIMS_COLOR_MODE_RGB;
      GlimsStatus st = api->stroke_begin_ink_with_capture_facts(engine, s.id, captured_brush, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st != GLIMS_STATUS_OK && sid == 0 && !f.brush_name && !f.fingerprint, "bad target mode refused before paint, zero result/empty facts"); api->free_string(e); e=NULL; free_facts(&f);
      t = make_target(&s); sid = 123; f.struct_size = sizeof f;

      /* bad role */
      t.role = (s.role[TARGET] == GLIMS_INK_ROLE_CYAN ? GLIMS_INK_ROLE_MAGENTA : GLIMS_INK_ROLE_CYAN);
      st = api->stroke_begin_ink_with_capture_facts(engine, s.id, captured_brush, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st != GLIMS_STATUS_OK && sid == 0 && !f.brush_name && !f.fingerprint, "bad target role refused before paint"); api->free_string(e); e=NULL; free_facts(&f);
      t = make_target(&s); sid = 123; f.struct_size = sizeof f;

      /* bad UUID */
      t.uuid[0] ^= 0xff;
      st = api->stroke_begin_ink_with_capture_facts(engine, s.id, captured_brush, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st != GLIMS_STATUS_OK && sid == 0 && !f.brush_name && !f.fingerprint, "bad target UUID refused before paint"); api->free_string(e); e=NULL; free_facts(&f);
      t = make_target(&s); sid = 123; f.struct_size = sizeof f;

      /* not sole-selected target */
      MutateArgs m = {.id = s.ids[0]};
      CHECK(glims_engine_call(engine, mutate_select_wrong_native, &m) == GLIMS_STATUS_OK, "mutate selection to wrong plane");
      st = api->stroke_begin_ink_with_capture_facts(engine, s.id, captured_brush, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st != GLIMS_STATUS_OK && sid == 0 && !f.brush_name && !f.fingerprint, "not sole-selected target refused before paint"); api->free_string(e); e=NULL; free_facts(&f);
      m.id = s.ids[TARGET];
      CHECK(glims_engine_call(engine, select_target_native, &m) == GLIMS_STATUS_OK, "restore selected target");
      t = make_target(&s); sid = 123; f.struct_size = sizeof f;

      /* changed fingerprint refusal */
      st = api->stroke_begin_ink_with_capture_facts(engine, s.id, captured_brush, &t, &bs, &p1, "0000000000000000000000000000000000000000000000000000000000000000", &sid, &f, &e);
      CHECK(st != GLIMS_STATUS_OK && sid == 0 && !f.brush_name && !f.fingerprint, "changed/expected fingerprint mismatch refused before paint"); api->free_string(e); e=NULL; free_facts(&f);

      Snapshot after = {0}; take_snapshot(engine, &s, &after);
      CHECK(same_pixels(&s, &before, &after) && same_history(&before, &after), "all guard refusals left no pixels/Undo");

      /* default resource 0 capture facts if practical */
      sid = 0; f.struct_size = sizeof f;
      st = api->stroke_begin_ink_with_capture_facts(engine, s.id, 0, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st == GLIMS_STATUS_OK && sid > 0 && valid_facts(&f),
            "resource zero captures the known eligible current brush");
      if (st == GLIMS_STATUS_OK && sid > 0)
        CHECK(api->stroke_cancel_ink(engine, sid) == GLIMS_STATUS_OK, "cancel inherited-brush witness");
      api->free_string(e); free_facts(&f);
      close_scene(engine, &s);
    }
  }

  /* Typed cancel, expired cancel, invalid continue batch, end after selection change, save busy, image close with active stroke */
  {
    Scene s = {0};
    if (create_scene(engine, &s, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_FLOAT, FALSE)) {
      Snapshot before = {0}, during = {0}, after = {0};
      take_snapshot(engine, &s, &before);
      GlimsBrushSettings bs = brush_for_tool(GLIMS_PAINT_PAINTBRUSH);
      GlimsStrokeSampleV2 s1 = sample(12.5, 8.5, 1, 1.0); GlimsStrokePacketV2 p1 = packet(&s1, 1);
      GlimsInkStrokeTarget t = make_target(&s); GlimsStrokeCaptureFacts f = {.struct_size = sizeof f}; GlimsStrokeID sid = 0; char *e = NULL;
      GlimsStatus st = api->stroke_begin_ink_with_capture_facts(engine, s.id, captured_brush, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st == GLIMS_STATUS_OK && sid > 0, "begin for cancel/busy/close cases"); api->free_string(e); free_facts(&f);
      if (st == GLIMS_STATUS_OK && sid > 0) {
        GlimsStrokeSampleV2 s2 = sample(13.5, 8.5, 2, 1.0); GlimsStrokePacketV2 p2 = packet(&s2, 1);
        e = NULL; st = api->stroke_continue_v2(engine, sid, &p2, &e); CHECK(st == GLIMS_STATUS_OK, "tentative continuation for cancel case"); api->free_string(e);
        take_snapshot(engine, &s, &during);
        CHECK(!same_pixels(&s, &before, &during), "cancel witness has tentative pixels");

        /* invalid continue V2: valid first sample in packet but late NaN, whole batch rejected, no mutation, handle still valid */
        GlimsStrokeSampleV2 badpair[2] = { sample(14.5, 8.5, 3, 1.0), sample(15.5, 8.5, 4, 1.0) };
        badpair[1].x = NAN;
        GlimsStrokePacketV2 badp = packet(badpair, 2);
        Snapshot before_bad = {0}; take_snapshot(engine, &s, &before_bad);
        e = NULL; st = api->stroke_continue_v2(engine, sid, &badp, &e);
        CHECK(st == GLIMS_STATUS_INVALID_ARGUMENT, "invalid continue V2 with late NaN rejected"); api->free_string(e);
        take_snapshot(engine, &s, &after);
        CHECK(same_pixels(&s, &before_bad, &after), "invalid continue batch caused no mutation of tentative pixels");

        /* live save/save_copy BUSY */
        char *path = g_build_filename(workdir, "busy-save.xcf", NULL);
        char *copy = g_build_filename(workdir, "busy-copy.xcf", NULL);
        CHECK(g_file_set_contents(path, "sentinel", 8, NULL), "create save destination sentinel");
        CHECK(!g_file_test(copy, G_FILE_TEST_EXISTS), "save_copy destination initially absent");
        e = NULL; GlimsStatus sv = api->image_save(engine, s.id, path, &e); api->free_string(e); e=NULL;
        GlimsStatus sc = api->image_save_copy(engine, s.id, copy, &e); api->free_string(e);
        CHECK(sv == GLIMS_STATUS_BUSY && sc == GLIMS_STATUS_BUSY, "live typed save/save_copy refused BUSY");
        gchar *contents = NULL; gsize len = 0;
        gboolean read_sentinel = g_file_get_contents(path, &contents, &len, NULL);
        CHECK(read_sentinel, "read save destination after BUSY refusal");
        CHECK(read_sentinel && len == 8 && memcmp(contents, "sentinel", 8) == 0,
              "save BUSY preserved destination bytes");
        g_free(contents);
        CHECK(!g_file_test(copy, G_FILE_TEST_EXISTS), "save_copy BUSY created no destination");
        g_free(path); g_free(copy);

        /* typed cancel restores exact baseline and history */
        st = api->stroke_cancel_ink(engine, sid);
        CHECK(st == GLIMS_STATUS_OK, "typed cancel succeeds");
        take_snapshot(engine, &s, &after);
        CHECK(same_pixels(&s, &before, &after) && same_history(&before, &after), "typed cancel restores exact baseline and history, no Undo");
        st = api->stroke_cancel_ink(engine, sid);
        CHECK(st == GLIMS_STATUS_NOT_FOUND, "expired cancelled handle is NOT_FOUND");
      }
      close_scene(engine, &s);
    }
  }

  /* end after selected-channel change rollback + selection restored */
  {
    Scene s = {0};
    if (create_scene(engine, &s, GLIMS_COLOR_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_U8, FALSE)) {
      Snapshot before = {0}, after = {0}; take_snapshot(engine, &s, &before);
      GlimsBrushSettings bs = brush_for_tool(GLIMS_PAINT_PENCIL);
      GlimsStrokeSampleV2 s1 = sample(12.5, 8.5, 1, 1.0), s2 = sample(13.5, 8.5, 2, 1.0);
      GlimsStrokePacketV2 p1 = packet(&s1, 1), p2 = packet(&s2, 1);
      GlimsInkStrokeTarget t = make_target(&s); GlimsStrokeCaptureFacts f = {.struct_size = sizeof f}; GlimsStrokeID sid = 0; char *e = NULL;
      GlimsStatus st = api->stroke_begin_ink_with_capture_facts(engine, s.id, captured_brush, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st == GLIMS_STATUS_OK && sid > 0, "begin for selection-change rollback"); api->free_string(e); free_facts(&f);
      if (st == GLIMS_STATUS_OK && sid > 0) {
        e=NULL; st = api->stroke_continue_v2(engine, sid, &p2, &e); CHECK(st == GLIMS_STATUS_OK, "continue before selection change"); api->free_string(e);
        MutateArgs m = {.id = s.ids[0]};
        CHECK(glims_engine_call(engine, mutate_select_wrong_native, &m) == GLIMS_STATUS_OK, "change selected channel during stroke");
        st = api->stroke_end(engine, sid);
        CHECK(st != GLIMS_STATUS_OK, "end after selected-channel change refuses/rolls back");
        /* restore selection as fixture cleanup regardless; contract requires restore selection as fixture cleanup */
        m.id = s.ids[TARGET]; glims_engine_call(engine, select_target_native, &m);
        take_snapshot(engine, &s, &after);
        CHECK(same_pixels(&s, &before, &after) && same_history(&before, &after), "selection-change rollback restored baseline/history");
        st = api->stroke_cancel_ink(engine, sid);
        CHECK(st == GLIMS_STATUS_NOT_FOUND, "failed End retires the typed stroke handle");
      }
      close_scene(engine, &s);
    }
  }

  /* Closing a live stroke must release its retained selection buffer too. */
  {
    Scene s = {0};
    if (create_scene(engine, &s, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_U8, FALSE)) {
      GlimsBrushSettings bs = brush_for_tool(GLIMS_PAINT_PENCIL);
      GlimsStrokeSampleV2 s1 = sample(12.5, 8.5, 1, 1.0); GlimsStrokePacketV2 p1 = packet(&s1, 1);
      GlimsInkStrokeTarget t = make_target(&s); GlimsStrokeCaptureFacts f = {.struct_size = sizeof f}; GlimsStrokeID sid = 0; char *e = NULL;
      GlimsStatus st = api->stroke_begin_ink_with_capture_facts(engine, s.id, captured_brush, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st == GLIMS_STATUS_OK && sid > 0, "begin for image-close cleanup"); api->free_string(e); free_facts(&f);
      if (st == GLIMS_STATUS_OK && sid > 0) {
        MaskLifetime watch = {.image = s.id};
        g_weak_ref_init(&watch.mask, NULL);
        CHECK(glims_engine_call(engine, watch_mask_native, &watch) == GLIMS_STATUS_OK,
              "watch live selection buffer without retaining it");
        CHECK(api->image_close(engine, s.id) == GLIMS_STATUS_OK, "close image with active typed stroke");
        s.id = 0;
        CHECK(api->stroke_cancel_ink(engine, sid) == GLIMS_STATUS_NOT_FOUND, "closed image retires typed ink stroke handle");
        GObject *remaining = g_weak_ref_get(&watch.mask);
        CHECK(remaining == NULL, "closing a live stroke releases its selection buffer");
        g_clear_object(&remaining);
        g_weak_ref_clear(&watch.mask);
      } else {
        close_scene(engine, &s);
      }
    }
    /* fresh stroke accepted after close */
    Scene s2 = {0};
    if (create_scene(engine, &s2, GLIMS_COLOR_MODE_CMYK, GLIMS_COLOR_COMPONENT_U8, FALSE)) {
      GlimsBrushSettings bs = brush_for_tool(GLIMS_PAINT_PENCIL);
      GlimsStrokeSampleV2 s1 = sample(12.5, 8.5, 1, 1.0); GlimsStrokePacketV2 p1 = packet(&s1, 1);
      GlimsInkStrokeTarget t = make_target(&s2); GlimsStrokeCaptureFacts f = {.struct_size = sizeof f}; GlimsStrokeID sid = 0; char *e = NULL;
      GlimsStatus st = api->stroke_begin_ink_with_capture_facts(engine, s2.id, captured_brush, &t, &bs, &p1, NULL, &sid, &f, &e);
      CHECK(st == GLIMS_STATUS_OK && sid > 0, "fresh typed stroke accepted after prior close cleanup"); api->free_string(e);
      if (st == GLIMS_STATUS_OK && sid > 0) CHECK(api->stroke_cancel_ink(engine, sid) == GLIMS_STATUS_OK, "cleanup fresh stroke");
      free_facts(&f);
      close_scene(engine, &s2);
    }
  }

}

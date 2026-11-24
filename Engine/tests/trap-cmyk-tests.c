/* Independent slot 266 Trap regression oracle. Production kernel/engine
 * code is not read or called to compute expectations: expected planes are
 * derived from docs/trap.md here. Native writes below only prepare
 * fixtures; every tested trap uses the public facade. */
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

/* The default build is a 16 x 4 canvas. scripts/test-trap-cmyk.py also
 * builds a 2100 x 140 canvas with diagonal stripes, so trap disks cross
 * the engine's 2048-column and 128-row tile seams in every row. */
#ifdef TRAP_TEST_W
#define W TRAP_TEST_W
#define H TRAP_TEST_H
#else
#define W 16
#define H 4
#endif
#ifdef TRAP_TEST_DIAGONAL
#define PHASE(x, y) (((x) + (y)) % 16u)
#else
#define PHASE(x, y) (x)
#endif
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
  uint32_t component;
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
  char names[PLANES][256], undo_name[128];
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
  GList *selected = gimp_image_get_selected_channels(image);
  s->selected_count = g_list_length(selected);
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
  GimpObject *top = s->undo
    ? gimp_container_get_child_by_index (gimp_image_get_undo_stack(image)->undos, s->undo - 1)
    : NULL;
  const char *undo_name = top ? gimp_object_get_name(top) : NULL;
  g_strlcpy(s->undo_name, undo_name ? undo_name : "", sizeof s->undo_name);
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
      a->layers != b->layers || a->selected_count != b->selected_count) return FALSE;
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

/* The fixture: columns 0..3 are full yellow ink on paper, 4..7 full cyan,
 * column 8 a black stripe, 9..15 paper. Intensity 0 is ink, the maximum
 * is paper. */
static void initialize_samples(Scene *s) {
  memset(s->seed, 0, sizeof s->seed);
  for (unsigned i = 0; i < PIXELS; i++) {
    unsigned phase = PHASE(i % W, i / W);
    double ink = phase < 4 ? 2 : phase < 8 ? 0 : phase == 8 ? 3 : -1; /* yellow, cyan, black */
    for (unsigned p = 0; p < PLANES; p++) {
      double intensity;
      if (ink < 0) intensity = 1;
      else if (ink == 2) intensity = p == 2 ? 0 : 1;
      else if (ink == 0) intensity = p == 0 ? 0 : 1;
      else intensity = p == 3 ? 0 : 1;
      if (s->component == GLIMS_COLOR_COMPONENT_U8) {
        guint8 v = (guint8) (intensity * 255);
        memcpy(s->seed[p] + i, &v, 1);
      } else if (s->component == GLIMS_COLOR_COMPONENT_U16) {
        guint16 v = (guint16) (intensity * 65535);
        memcpy(s->seed[p] + i * 2, &v, 2);
      } else {
        float v = (float) intensity;
        memcpy(s->seed[p] + i * 4, &v, 4);
      }
    }
  }
}
static GlimsStatus prepare_native(GlimsEngine *engine, gpointer data) {
  Scene *s = data;
  GlimsOpenImage *open = glims_lookup_image(engine, s->id);
  GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open, &storage) ||
      storage.map.mode != GLIMS_PLATE_MODE_CMYK || storage.map.count != PLANES)
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
  }
  static float requested[PIXELS];
  for (unsigned i = 0; i < PIXELS; i++) {
    unsigned x = i % W;
    requested[i] = s->masked && x >= 4 && x < 8 ? .5f : 0.f;
  }
  GimpDrawable *mask = GIMP_DRAWABLE(gimp_image_get_mask(image));
  gegl_buffer_set(gimp_drawable_get_buffer(mask), GEGL_RECTANGLE(0, 0, W, H), 0,
                  babl_format("Y float"), requested, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(mask, 0, 0, W, H);
  gboolean empty = gimp_channel_is_empty(GIMP_CHANNEL(mask));
  if (empty == s->masked) return GLIMS_STATUS_FAILED;
  /* Capture actual native mask quantization before the edit, not its output. */
  gegl_buffer_get(gimp_drawable_get_buffer(mask), GEGL_RECTANGLE(0, 0, W, H), 1,
                  babl_format("Y float"), s->mask, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  GFile *file = g_file_new_for_uri("file:///trap-fixture-source.xcf");
  gimp_image_set_file(image, file);
  gimp_image_set_imported_file(image, file);
  gimp_image_set_exported_file(image, file);
  gimp_image_set_save_a_copy_file(image, file);
  g_object_unref(file);
  gimp_image_undo_free(image);
  gimp_image_clean_all(image);
  return GLIMS_STATUS_OK;
}

static double sample_intensity(const Scene *s, const guint8 *raw, unsigned i) {
  if (s->sample_size == 1) return raw[i];
  if (s->sample_size == 2) {
    guint16 v; memcpy(&v, raw + i * 2, 2); return v;
  }
  float v; memcpy(&v, raw + i * 4, 4); return v;
}

/* Independent arithmetic from docs/trap.md: darkness orders coverages, the
 * disk keeps only strictly lighter neighbours, and the C, M and Y planes
 * take the greatest coverage (least intensity) among them. */
static void expected_pixels(const Scene *s, const Snapshot *before, int width,
                            guint8 expected[PLANES][MAX_BYTES]) {
  static double coverage[PIXELS][PLANES], darkness[PIXELS];
  double maximum = s->sample_size == 1 ? 255 : s->sample_size == 2 ? 65535 : 1;
  memcpy(expected, before->raw, sizeof before->raw);
  for (unsigned i = 0; i < PIXELS; i++) {
    for (unsigned p = 0; p < PLANES; p++)
      coverage[i][p] = (maximum - sample_intensity(s, before->raw[p], i)) / maximum;
    double k = 1 - coverage[i][3];
    double r = (1 - coverage[i][0]) * k, g = (1 - coverage[i][1]) * k,
           b = (1 - coverage[i][2]) * k;
    darkness[i] = 1 - (0.2126 * r + 0.7152 * g + 0.0722 * b);
  }
  for (unsigned y = 0; y < H; y++)
    for (unsigned x = 0; x < W; x++) {
      unsigned i = y * W + x;
      double proposal[3];
      for (unsigned p = 0; p < 3; p++)
        proposal[p] = sample_intensity(s, before->raw[p], i);
      for (int dy = -width; dy <= width; dy++)
        for (int dx = -width; dx <= width; dx++) {
          if ((dx == 0 && dy == 0) || dx * dx + dy * dy > width * width)
            continue;
          int qx = (int) x + dx, qy = (int) y + dy;
          if (qx < 0 || qy < 0 || qx >= W || qy >= H) continue;
          unsigned q = (unsigned) qy * W + (unsigned) qx;
          if (darkness[q] >= darkness[i] - 1.0 / 512) continue;
          for (unsigned p = 0; p < 3; p++) {
            double qi = sample_intensity(s, before->raw[p], q);
            if (qi < proposal[p]) proposal[p] = qi;
          }
        }
      double m = s->masked ? s->mask[i] : 1;
      for (unsigned p = 0; p < 3; p++) {
        double original = sample_intensity(s, before->raw[p], i);
        if (s->sample_size == 4) {
          float v = m == 1 ? (float) proposal[p] :
                    (float) (original + m * (proposal[p] - original));
          memcpy(expected[p] + i * 4, &v, 4);
        } else {
          double blended = original + m * (proposal[p] - original);
          if (blended < 0) blended = 0;
          if (blended > maximum) blended = maximum;
          blended = floor(blended + .5);
          if (s->sample_size == 1) {
            guint8 v = (guint8) blended;
            memcpy(expected[p] + i, &v, 1);
          } else {
            guint16 v = (guint16) blended;
            memcpy(expected[p] + i * 2, &v, 2);
          }
        }
      }
    }
}

static void exercise(GlimsEngine *engine, Scene *s, int width, const char *label) {
  /* Static: the seam build's snapshots are several MiB each. */
  static Snapshot before, after, restored, second;
  memset(&before, 0, sizeof before); memset(&after, 0, sizeof after);
  memset(&restored, 0, sizeof restored); memset(&second, 0, sizeof second);
  static guint8 expected[PLANES][MAX_BYTES];
  char *error = NULL;
  GlimsTrapSettings settings = { .struct_size = sizeof settings, .width = width };
  printf("CASE component=%u mask=%d width=%d %s\n",
         s->component, s->masked, width, label); fflush(stdout);
  gboolean prepared = glims_engine_call(engine, prepare_native, s) == GLIMS_STATUS_OK;
  CHECK(prepared, "fixture seeds real CMYK planes and mask");
  if (!prepared || !capture(engine, s, &before)) goto done;
  GlimsStatus result = api->image_trap(engine, s->id, &settings, &error);
  CHECK(result == GLIMS_STATUS_OK, label);
  if (error) printf("DIAGNOSTIC %s\n", error);
  api->free_string(error); error = NULL;
  if (!capture(engine, s, &after)) goto done;
  CHECK(same_metadata(&before, &after),
        "trap preserves UUID/map/profile/name/visibility/selection/file identity");
  expected_pixels(s, &before, width, expected);
  gboolean exact = TRUE;
  unsigned mismatches = 0;
  for (unsigned p = 0; p < PLANES; p++)
    for (unsigned i = 0; i < PIXELS; i++)
      if (memcmp(expected[p] + i * s->sample_size,
                 after.raw[p] + i * s->sample_size, s->sample_size)) {
        exact = FALSE;
        /* The seam build has over a million samples: name the first few. */
        if (++mismatches <= 16)
          printf("MISMATCH component=%u mask=%d plane=%u index=%u before=%.17g mask=%.17g expected=%.17g actual=%.17g\n",
                 s->component, s->masked, p, i, sample_intensity(s, before.raw[p], i),
                 s->masked ? s->mask[i] : 1.0,
                 sample_intensity(s, expected[p], i), sample_intensity(s, after.raw[p], i));
      }
  if (mismatches > 16) printf("MISMATCH %u more samples differ\n", mismatches - 16);
  CHECK(exact, "all raw C/M/Y bytes match the independent disk oracle");
  CHECK(!memcmp(before.raw[3], after.raw[3], s->bytes), "K never changes");
  CHECK(after.undo == before.undo + 1 && after.redo == 0, "changed trap creates exactly one Undo");
  CHECK(!strcmp(after.undo_name, "Trap"), "the Undo step is named Trap");
  CHECK(api->image_undo(engine, s->id) == GLIMS_STATUS_OK, "Undo succeeds");
  if (capture(engine, s, &restored))
    CHECK(same_pixels(s, &before, &restored) && same_metadata(&before, &restored),
          "Undo restores every exact sample and source metadata");
  release_snapshot(&restored); memset(&restored, 0, sizeof restored);
  CHECK(api->image_redo(engine, s->id) == GLIMS_STATUS_OK, "Redo succeeds");
  if (capture(engine, s, &restored))
    CHECK(same_pixels(s, &after, &restored) && same_metadata(&after, &restored),
          "Redo restores every exact edited sample");
  /* Fully covered: a second trap finds no remaining lighter neighbour and
   * adds no Undo. A partial selection would blend one step further. */
  if (!s->masked) {
    result = api->image_trap(engine, s->id, &settings, &error);
    CHECK(result == GLIMS_STATUS_OK, "second trap succeeds");
    if (capture(engine, s, &second))
      CHECK(same_pixels(s, &after, &second) &&
            after.undo == second.undo && after.redo == second.redo,
            "byte-identical second trap adds no Undo");
  }
done:
  api->free_string(error);
  release_snapshot(&before); release_snapshot(&after);
  release_snapshot(&restored); release_snapshot(&second);
}

typedef struct { Scene *scene; gboolean locked; } Control;
static GlimsStatus control_native(GlimsEngine *engine, gpointer data) {
  Control *c = data;
  GlimsOpenImage *open = glims_lookup_image(engine, c->scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpItem *target = gimp_item_get_by_id(engine->gimp, c->scene->ids[0]);
  if (!target) return GLIMS_STATUS_FAILED;
  gimp_item_set_lock_content(target, c->locked, FALSE);
  return GLIMS_STATUS_OK;
}

static GlimsStatus trap_status(GlimsEngine *engine, GlimsImageID id,
                               GlimsTrapSettings *settings, char **error) {
  GlimsStatus result = api->image_trap(engine, id, settings, error);
  api->free_string(*error); *error = NULL;
  return result;
}

static void refusals(GlimsEngine *engine, Scene *s) {
  static Snapshot before, after;
  memset(&before, 0, sizeof before); memset(&after, 0, sizeof after);
  char *error = NULL;
  GlimsTrapSettings settings = { .struct_size = sizeof settings, .width = 1 };
  CHECK(glims_engine_call(engine, prepare_native, s) == GLIMS_STATUS_OK, "prepare refusal fixture");
  if (!capture(engine, s, &before)) {
    release_snapshot(&before);
    return;
  }
  settings.width = 0;
  CHECK(trap_status(engine, s->id, &settings, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
        "width 0 refuses INVALID_ARGUMENT");
  settings.width = 17;
  CHECK(trap_status(engine, s->id, &settings, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
        "width 17 refuses INVALID_ARGUMENT");
  settings.width = 1;
  settings.struct_size = sizeof settings.width;
  CHECK(trap_status(engine, s->id, &settings, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
        "short settings struct refuses INVALID_ARGUMENT");
  settings.struct_size = sizeof settings;
  CHECK(trap_status(engine, s->id + 1000000, &settings, &error) == GLIMS_STATUS_NOT_FOUND,
        "unknown image refuses NOT_FOUND");
  CHECK(api->image_trap(engine, s->id, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
        "NULL settings refuse INVALID_ARGUMENT");
  api->free_string(error); error = NULL;
  if (capture(engine, s, &after))
    CHECK(same_pixels(s, &before, &after) && same_metadata(&before, &after) &&
          same_history(&before, &after), "argument refusals change nothing");
  release_snapshot(&after); memset(&after, 0, sizeof after);
  /* A pixel-locked C plane refuses LOCKED without any mutation. */
  Control lock = { s, TRUE };
  CHECK(glims_engine_call(engine, control_native, &lock) == GLIMS_STATUS_OK,
        "lock the C plane natively");
  CHECK(trap_status(engine, s->id, &settings, &error) == GLIMS_STATUS_LOCKED,
        "pixel-locked C plane refuses LOCKED");
  lock.locked = FALSE;
  CHECK(glims_engine_call(engine, control_native, &lock) == GLIMS_STATUS_OK,
        "unlock the C plane natively");
  if (capture(engine, s, &after))
    CHECK(same_pixels(s, &before, &after) && same_metadata(&before, &after) &&
          same_history(&before, &after), "lock refusal changes nothing");
  release_snapshot(&after); memset(&after, 0, sizeof after);
  release_snapshot(&before);
}

/* An ordinary layered RGB image refuses UNSUPPORTED, changing nothing. */
static void ordinary_refusal(GlimsEngine *engine) {
  GlimsImageID id = 0;
  static guint8 before[PIXELS * 4], after[PIXELS * 4];
  GlimsUndoInfo u0 = {0}, u1 = {0};
  char *error = NULL;
  GlimsTrapSettings settings = { .struct_size = sizeof settings, .width = 2 };
  GlimsStatus st = api->image_new(engine, W, H, &id, &error);
  CHECK(st == GLIMS_STATUS_OK && id, "create ordinary RGB refusal fixture");
  api->free_string(error); error = NULL;
  if (st != GLIMS_STATUS_OK || !id) return;
  gboolean captured = api->image_render(engine, id, 1, (GlimsRect){0, 0, W, H}, before, W * 4) == GLIMS_STATUS_OK &&
                      api->image_undo_info(engine, id, &u0) == GLIMS_STATUS_OK;
  CHECK(captured, "capture ordinary image and history");
  CHECK(api->image_trap(engine, id, &settings, &error) == GLIMS_STATUS_UNSUPPORTED,
        "ordinary RGB image refuses UNSUPPORTED");
  api->free_string(error); error = NULL;
  gboolean read_back = api->image_render(engine, id, 1, (GlimsRect){0, 0, W, H}, after, W * 4) == GLIMS_STATUS_OK &&
                       api->image_undo_info(engine, id, &u1) == GLIMS_STATUS_OK;
  CHECK(read_back && !memcmp(before, after, sizeof before) &&
        u0.undo_count == u1.undo_count && u0.redo_count == u1.redo_count,
        "ordinary-mode refusal preserves pixels and history");
  CHECK(api->image_close(engine, id) == GLIMS_STATUS_OK, "close ordinary fixture");
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s PRIVATE_WORK EXTERNAL_CMYK_ICC\n", argv[0]); return 2; }
  gchar *icc = NULL; gsize length = 0;
  if (!g_file_get_contents(argv[2], &icc, &length, NULL) || length < 128 || length > 4u * 1024u * 1024u) {
    fprintf(stderr, "External bounded CMYK profile could not be read.\n"); g_free(icc); return 2;
  }
  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_trap) + sizeof api->image_trap ||
      !api->image_trap || !api->image_new_cmyk || !api->image_new) {
    fprintf(stderr, "Adapter lacks slot 266.\n"); g_free(icc); return 2;
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
  const uint32_t components[] = {GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16,
                                 GLIMS_COLOR_COMPONENT_FLOAT};
  for (unsigned c = 0; c < G_N_ELEMENTS(components); c++) {
    static Scene scene;
    memset(&scene, 0, sizeof scene);
    scene.component = components[c];
    scene.sample_size = components[c] == GLIMS_COLOR_COMPONENT_U8 ? 1 :
                        components[c] == GLIMS_COLOR_COMPONENT_U16 ? 2 : 4;
    scene.bytes = PIXELS * scene.sample_size;
    GlimsStatus created = api->image_new_cmyk(engine, W, H, scene.component,
                                            (const guint8 *) icc, length, &scene.id, &error);
    CHECK(created == GLIMS_STATUS_OK && scene.id, "create public CMYK document");
    api->free_string(error); error = NULL;
    if (created != GLIMS_STATUS_OK || !scene.id) continue;
    scene.masked = FALSE;
    exercise(engine, &scene, 2, "yellow spreads under cyan and under black; K is untouched");
    exercise(engine, &scene, 1, "width 1 spreads a single pixel ring");
#ifdef TRAP_TEST_DIAGONAL
    exercise(engine, &scene, 16, "width 16 reaches across the tile seams");
#endif
    scene.masked = TRUE;
    exercise(engine, &scene, 1, "selection blends the trapped coverage once");
    scene.masked = FALSE;
    refusals(engine, &scene);
    CHECK(api->image_close(engine, scene.id) == GLIMS_STATUS_OK, "close CMYK fixture");
  }
  ordinary_refusal(engine);
  api->stop(engine); g_free(icc);
  printf("checks=%u failures=%u\n", checks, failures);
  return failures ? 1 : 0;
}

/* Independent public ink-snapshot ownership and transaction fixture.
 * Native callbacks seed/capture source state only; all tested snapshot operations
 * use the public facade. Expectations never call the production Levels kernel. */
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
  GFile *file = g_file_new_for_uri("file:///ink-snapshot-fixture-source.xcf");
  gimp_image_set_file(image, file);
  gimp_image_set_imported_file(image, file);
  gimp_image_set_exported_file(image, file);
  gimp_image_set_save_a_copy_file(image, file);
  g_object_unref(file);
  gimp_image_undo_free(image);
  gimp_image_clean_all(image);
  return GLIMS_STATUS_OK;
}

static const GlimsInkLevelsSettings gamma2 = {
  .struct_size = sizeof(GlimsInkLevelsSettings), .value = {0,1,2,0,1}
};
static const GlimsInkLevelsSettings identity = {
  .struct_size = sizeof(GlimsInkLevelsSettings), .value = {0,1,1,0,1}
};
static GlimsStatus begin(GlimsEngine *e, Scene *s, uint64_t *token) {
  char *error = NULL;
  GlimsStatus status = api->image_ink_snapshot_begin(e, s->id, s->ids[0], token, &error);
  api->free_string(error); return status;
}
static GlimsStatus preview(GlimsEngine *e, GlimsImageID id, uint64_t token,
                           const GlimsInkLevelsSettings *settings, GlimsImageID *copy) {
  char *error = NULL;
  GlimsStatus status = api->image_ink_snapshot_levels(e, id, token, settings, copy, &error);
  api->free_string(error); return status;
}
static GlimsStatus apply(GlimsEngine *e, Scene *s, uint64_t token,
                         const GlimsInkLevelsSettings *settings) {
  char *error = NULL;
  GlimsStatus status = api->image_ink_snapshot_apply(e, s->id, token, settings, &error);
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
  CHECK(prepared, "seed exact native intensities, hidden ink, clean history and file identity");
  return prepared;
}
static void close_scene(GlimsEngine *e, Scene *s) {
  if (s->id) CHECK(api->image_close(e, s->id) == GLIMS_STATUS_OK, "close owned ink image");
  s->id = 0;
}
static gboolean unchanged(const Scene *s, const Snapshot *a, const Snapshot *b) {
  return same_pixels(s, a, b) && same_metadata(a, b) && same_history(a, b);
}
static void source_unchanged(GlimsEngine *e, Scene *s, const Snapshot *before, const char *label) {
  Snapshot after = {0};
  if (capture(e, s, &after)) CHECK(unchanged(s, before, &after), label);
  release_snapshot(&after);
}
static void render(GlimsEngine *e, GlimsImageID id) {
  guint8 rgba[PIXELS * 4];
  CHECK(api->image_render(e, id, 1, (GlimsRect){0,0,W,H}, rgba, W * 4) == GLIMS_STATUS_OK,
        "owned preview renders through public facade");
}
static gboolean gamma_oracle(Scene *s, const Snapshot *before, const Snapshot *after) {
  for (unsigned p = 0; p < PLANES; p++) for (unsigned i = 0; i < PIXELS; i++) {
    guint8 expected[sizeof(float)] = {0};
    const guint8 *prior = before->raw[p] + i * s->sample_size;
    memcpy(expected, prior, s->sample_size);
    if (p == 0) {
      /* Literal seeds and independently rounded square roots:
       * sqrt(64/255)*255 ->128; sqrt(16384/65535)*65535 ->32768;
       * sqrt(.25) is exactly .5 in the native float representation. */
      if (s->sample_size == 1) expected[0] = 128;
      else if (s->sample_size == 2) { guint16 v = 32768; memcpy(expected, &v, 2); }
      else { float v = .5f; memcpy(expected, &v, 4); }
    }
    if (memcmp(expected, after->raw[p] + i * s->sample_size, s->sample_size)) return FALSE;
  }
  return TRUE;
}
static Scene copy_scene(const Scene *source, GlimsImageID id) {
  Scene copy = *source; copy.id = id;
  memset(copy.ids, 0, sizeof copy.ids); /* A public duplicate has different native item IDs. */
  return copy;
}
static void expired(GlimsEngine *e, Scene *s, uint64_t token) {
  GlimsImageID copy = -1;
  CHECK(preview(e, s->id, token, &gamma2, &copy) == GLIMS_STATUS_NOT_FOUND && copy == 0,
        "expired token refuses preview and clears output");
  CHECK(apply(e, s, token, &identity) == GLIMS_STATUS_NOT_FOUND,
        "expired token refuses even identity Apply");
  CHECK(api->image_ink_snapshot_end(e, s->id, token) == GLIMS_STATUS_NOT_FOUND,
        "expired End reports NOT_FOUND");
}
static GlimsStatus public_count_native(GlimsEngine *e, gpointer data) {
  *(guint *)data = g_hash_table_size(e->images); return GLIMS_STATUS_OK;
}
static guint public_count(GlimsEngine *e) {
  guint count = 0;
  CHECK(glims_engine_call(e, public_count_native, &count) == GLIMS_STATUS_OK, "read public image count");
  return count;
}

static void core_case(GlimsEngine *e, Scene *s, const guint8 *icc, size_t length) {
  Snapshot original = {0}, first = {0}, second = {0}, third = {0}, applied = {0}, restored = {0};
  uint64_t token = 0, next = 0;
  GlimsImageID a = 0, b = 0, c = 0;
  Scene other = {0};
  if (!capture(e, s, &original)) goto done;
  guint count = public_count(e);
  if (begin(e, s, &token) != GLIMS_STATUS_OK || !token) {
    CHECK(FALSE, "begin snapshot returns opaque token"); goto done;
  }
  CHECK(TRUE, "begin snapshot returns opaque token");
  CHECK(public_count(e) == count, "private baseline is not a publicly adopted image");
  next = UINT64_MAX;
  CHECK(begin(e, s, &next) != GLIMS_STATUS_OK && next == 0, "second Begin refuses and clears token");
  CHECK(preview(e, s->id, token, &gamma2, &a) == GLIMS_STATUS_OK && a,
        "first preview returns owned image");
  CHECK(preview(e, s->id, token, &gamma2, &b) == GLIMS_STATUS_OK && b && b != a,
        "repeat preview returns separate owned image");
  if (!a || !b) goto done;
  Scene sa = copy_scene(s, a), sb = copy_scene(s, b);
  if (!capture(e, &sa, &first) || !capture(e, &sb, &second)) goto done;
  CHECK(gamma_oracle(s, &original, &first), "preview raw bytes match independent literal gamma2 oracle");
  CHECK(same_pixels(s, &first, &second), "repeat preview does not accumulate");
  CHECK(!first.files[0] && !first.files[1] && !first.files[2] && !first.files[3],
        "returned preview has no source file identity");
  render(e, a); render(e, b);
  source_unchanged(e, s, &original, "preview and renders preserve every source byte and identity/history field");

  char *error = NULL;
  CHECK(api->image_edit_ink(e, a, sa.ids[0], GLIMS_INK_EDIT_FILL, 1, 1, &error) == GLIMS_STATUS_OK,
        "returned preview is independently editable");
  api->free_string(error);
  CHECK(preview(e, s->id, token, &gamma2, &c) == GLIMS_STATUS_OK && c,
        "recompute after editing an earlier returned image");
  if (c) {
    Scene sc = copy_scene(s, c);
    if (capture(e, &sc, &third)) CHECK(gamma_oracle(s, &original, &third),
                                      "returned image edits cannot mutate frozen baseline");
  }
  source_unchanged(e, s, &original, "editing a returned preview preserves live source");

  GlimsImageID alternate = 0;
  CHECK(preview(e, s->id, token, &identity, &alternate) == GLIMS_STATUS_OK && alternate,
        "changed settings replace cached calculation");
  if (alternate) {
    Scene sa = copy_scene(s, alternate); Snapshot identity_result = {0};
    if (capture(e, &sa, &identity_result)) CHECK(same_pixels(s, &original, &identity_result),
                                               "identity after gamma reads original frozen pixels");
    release_snapshot(&identity_result);
    CHECK(api->image_close(e, alternate) == GLIMS_STATUS_OK, "close alternate preview");
  }

  GlimsInkLevelsSettings bad = gamma2;
  GlimsImageID rejected = -1;
  bad.struct_size = sizeof(uint32_t);
  CHECK(preview(e, s->id, token, &bad, &rejected) != GLIMS_STATUS_OK && rejected == 0,
        "short settings refuse and clear preview output");
  bad = gamma2; bad.value.gamma = NAN; rejected = -1;
  CHECK(preview(e, s->id, token, &bad, &rejected) != GLIMS_STATUS_OK && rejected == 0,
        "nonfinite settings refuse and clear preview output");
  CHECK(apply(e, s, token, &bad) != GLIMS_STATUS_OK, "invalid Apply settings refuse");
  rejected = -1;
  CHECK(preview(e, s->id, token, NULL, &rejected) != GLIMS_STATUS_OK && rejected == 0,
        "NULL settings refuse and clear preview output");
  rejected = -1;
  CHECK(preview(e, s->id, 0, &gamma2, &rejected) != GLIMS_STATUS_OK && rejected == 0,
        "zero token refuses and clears output");
  if (create_scene(e, &other, s->mode, s->component, icc, length)) {
    Snapshot foreign = {0};
    gboolean captured = capture(e, &other, &foreign);
    rejected = -1;
    CHECK(preview(e, other.id, token, &gamma2, &rejected) == GLIMS_STATUS_NOT_FOUND && rejected == 0,
          "foreign existing image cannot use token");
    CHECK(apply(e, &other, token, &identity) == GLIMS_STATUS_NOT_FOUND,
          "foreign existing image cannot Apply token");
    CHECK(api->image_ink_snapshot_end(e, other.id, token) == GLIMS_STATUS_NOT_FOUND,
          "foreign existing image cannot End token");
    if (captured) source_unchanged(e, &other, &foreign, "foreign-token requests also preserve the foreign image");
    release_snapshot(&foreign);
  }
  close_scene(e, &other);
  source_unchanged(e, s, &original, "invalid and foreign requests preserve source");
  CHECK(api->image_ink_snapshot_end(e, s->id, token) == GLIMS_STATUS_OK, "Cancel releases baseline");
  source_unchanged(e, s, &original, "Cancel preserves source including clean dirty state and file identities");
  expired(e, s, token);
  uint64_t previous = token; token = 0;
  CHECK(begin(e, s, &token) == GLIMS_STATUS_OK && token && token != previous, "new token never reuses expired identity");
  CHECK(apply(e, s, token, &gamma2) == GLIMS_STATUS_OK, "Apply commits frozen settings");
  expired(e, s, token); token = 0;
  if (capture(e, s, &applied)) {
    CHECK(same_pixels(s, &second, &applied) && gamma_oracle(s, &original, &applied),
          "Apply exactly matches unmodified preview raw bytes");
    CHECK(same_metadata(&original, &applied) && applied.undo == original.undo + 1 && applied.redo == 0,
          "Apply preserves metadata and creates exactly one Undo");
    CHECK(api->image_undo(e, s->id) == GLIMS_STATUS_OK, "Undo applied snapshot");
    if (capture(e, s, &restored)) CHECK(same_pixels(s, &original, &restored) && same_metadata(&original, &restored),
                                      "Undo restores exact original planes and metadata");
    release_snapshot(&restored);
    CHECK(api->image_redo(e, s->id) == GLIMS_STATUS_OK, "Redo applied snapshot");
    if (capture(e, s, &restored)) CHECK(same_pixels(s, &applied, &restored) && same_metadata(&applied, &restored),
                                      "Redo restores exact applied planes and metadata");
    release_snapshot(&restored);
  }
  release_snapshot(&applied);
  if (!capture(e, s, &applied)) goto done;
  CHECK(begin(e, s, &token) == GLIMS_STATUS_OK && token, "begin identity snapshot");
  CHECK(apply(e, s, token, &identity) == GLIMS_STATUS_OK, "identity Apply succeeds");
  source_unchanged(e, s, &applied, "identity Apply creates no history or dirty change");
  expired(e, s, token); token = 0;
done:
  if (token) (void) api->image_ink_snapshot_end(e, s->id, token);
  if (a) CHECK(api->image_close(e, a) == GLIMS_STATUS_OK, "close preview A");
  if (b) CHECK(api->image_close(e, b) == GLIMS_STATUS_OK, "close preview B");
  if (c) CHECK(api->image_close(e, c) == GLIMS_STATUS_OK, "close preview C");
  close_scene(e, &other);
  release_snapshot(&original); release_snapshot(&first); release_snapshot(&second);
  release_snapshot(&third); release_snapshot(&applied); release_snapshot(&restored);
}

typedef enum { TARGET_PIXEL, OTHER_PIXEL, HIDDEN_PIXEL, SELECTION, ACTIVE_TARGET,
               VISIBILITY, NAME, MAP_COLOR, DAMAGE_MAP } Mutation;
typedef struct { Scene *scene; Mutation kind; } MutationRequest;
static GlimsStatus mutate_native(GlimsEngine *e, gpointer data) {
  MutationRequest *m = data; Scene *s = m->scene;
  GlimsOpenImage *open = glims_lookup_image(e, s->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image = open->image;
  if (m->kind == DAMAGE_MAP) {
    gimp_image_parasite_detach(image, GLIMS_PLATE_MAP_PARASITE, FALSE); return GLIMS_STATUS_OK;
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
    float mask[PIXELS] = {.5f};
    GimpDrawable *d = GIMP_DRAWABLE(gimp_image_get_mask(image));
    gegl_buffer_set(gimp_drawable_get_buffer(d), GEGL_RECTANGLE(0,0,W,H), 0,
                    babl_format("Y float"), mask, GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d, 0, 0, W, H);
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
  if (kind == ACTIVE_TARGET) {
    char *error = NULL;
    GlimsStatus status = api->channel_command(e, s->id, s->ids[1], GLIMS_CHANNEL_SELECT, NULL, &error);
    api->free_string(error); return status;
  }
  MutationRequest request = {s, kind};
  return glims_engine_call(e, mutate_native, &request);
}
static void soft_selection_case(GlimsEngine *e, uint32_t mode, const guint8 *icc, size_t length) {
  Scene s = {0}; Snapshot original = {0}, changed = {0}, rendered = {0};
  uint64_t token = 0; GlimsImageID result = 0;
  if (!create_scene(e, &s, mode, GLIMS_COLOR_COMPONENT_FLOAT, icc, length)) goto done;
  s.masked = TRUE;
  CHECK(glims_engine_call(e, prepare_native, &s) == GLIMS_STATUS_OK, "seed exact fractional selection coverage");
  if (!capture(e, &s, &original)) goto done;
  CHECK(begin(e, &s, &token) == GLIMS_STATUS_OK && token, "capture nonempty soft selection");
  if (!token) goto done;
  CHECK(mutate(e, &s, SELECTION) == GLIMS_STATUS_OK, "change live selection after Begin");
  if (!capture(e, &s, &changed)) goto done;
  CHECK(preview(e, s.id, token, &gamma2, &result) == GLIMS_STATUS_OK && result,
        "preview uses captured soft selection after live selection changes");
  if (result) {
    Scene copy = copy_scene(&s, result);
    if (capture(e, &copy, &rendered)) {
      const float expected[] = {.25f, .3125f, .375f, .5f};
      gboolean exact = TRUE;
      for (unsigned i = 0; i < PIXELS; i++)
        if (memcmp(rendered.raw[0] + i * sizeof(float), &expected[i % 4], sizeof(float))) exact = FALSE;
      for (unsigned p = 1; p < PLANES; p++)
        if (memcmp(rendered.raw[p], original.raw[p], s.bytes)) exact = FALSE;
      CHECK(exact, "fractional selection blends gamma exactly once, preserving every other ink");
      CHECK(memcmp(rendered.mask, original.mask, sizeof original.mask) == 0,
            "preview retains frozen selection bytes");
    }
  }
  CHECK(apply(e, &s, token, &gamma2) != GLIMS_STATUS_OK, "changed soft selection refuses Apply");
  source_unchanged(e, &s, &changed, "refused Apply preserves changed selection, pixels and history");
done:
  if (result) CHECK(api->image_close(e, result) == GLIMS_STATUS_OK, "close soft-selection preview");
  if (token) CHECK(api->image_ink_snapshot_end(e, s.id, token) == GLIMS_STATUS_OK, "release stale soft-selection token");
  release_snapshot(&original); release_snapshot(&changed); release_snapshot(&rendered);
  close_scene(e, &s);
}

static void stale_cases(GlimsEngine *e, const guint8 *icc, size_t length) {
  const char *labels[] = {"target pixels", "other visible ink pixels", "hidden ink pixels", "selection mask",
                          "active ink target", "ink visibility", "ink name", "valid map display color", "damaged map"};
  for (unsigned kind = TARGET_PIXEL; kind <= DAMAGE_MAP; kind++) {
    Scene s = {0}; Snapshot modified = {0}; uint64_t token = 0;
    if (!create_scene(e, &s, GLIMS_PLATE_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_FLOAT, icc, length)) goto done;
    CHECK(begin(e, &s, &token) == GLIMS_STATUS_OK && token, "begin stale-state fixture");
    CHECK(mutate(e, &s, (Mutation)kind) == GLIMS_STATUS_OK, labels[kind]);
    if (!capture(e, &s, &modified)) goto done;
    CHECK(apply(e, &s, token, &identity) != GLIMS_STATUS_OK, "stale source refuses identity Apply");
    source_unchanged(e, &s, &modified, "stale identity refusal preserves the user's newer state");
    CHECK(apply(e, &s, token, &gamma2) != GLIMS_STATUS_OK, "stale source refuses changed Apply");
    source_unchanged(e, &s, &modified, "stale changed refusal publishes nothing");
    CHECK(api->image_ink_snapshot_end(e, s.id, token) == GLIMS_STATUS_OK,
          "stale or damaged metadata retains cancelable baseline");
    token = 0;
  done:
    if (token) (void)api->image_ink_snapshot_end(e, s.id, token);
    release_snapshot(&modified); close_scene(e, &s);
  }
}

static void close_case(GlimsEngine *e, const guint8 *icc, size_t length) {
  Scene s = {0}; GlimsImageID copy = 0; uint64_t token = 0;
  if (!create_scene(e, &s, GLIMS_PLATE_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_FLOAT, icc, length)) goto done;
  CHECK(begin(e, &s, &token) == GLIMS_STATUS_OK && token, "begin source-close fixture");
  CHECK(preview(e, s.id, token, &gamma2, &copy) == GLIMS_STATUS_OK && copy, "create preview before source close");
  CHECK(mutate(e, &s, DAMAGE_MAP) == GLIMS_STATUS_OK, "damage metadata before source Close");
  GlimsImageID old = s.id;
  close_scene(e, &s);
  GlimsImageID rejected = -1;
  CHECK(preview(e, old, token, &gamma2, &rejected) == GLIMS_STATUS_NOT_FOUND && rejected == 0,
        "source close invalidates baseline and clears preview output");
  CHECK(api->image_ink_snapshot_end(e, old, token) == GLIMS_STATUS_NOT_FOUND, "source-close token is expired");
  if (copy) render(e, copy);
 done:
  if (copy) CHECK(api->image_close(e, copy) == GLIMS_STATUS_OK, "returned preview survives owner close and closes independently");
  close_scene(e, &s);
}

typedef struct {
  GlimsEngine *engine; Scene *scene; uint64_t token;
  gint armed, paused, release, timed_out;
  GlimsStatus status;
} Checkpoint;
static gboolean pause_checkpoint(gpointer data) {
  Checkpoint *p = data;
  gint64 deadline = g_get_monotonic_time() + 10 * G_TIME_SPAN_SECOND;
  g_atomic_int_set(&p->paused, 1);
  while (!g_atomic_int_get(&p->release)) {
    g_mutex_lock(&p->engine->lock); gboolean stopping = p->engine->stopping; g_mutex_unlock(&p->engine->lock);
    if (stopping) break;
    if (g_get_monotonic_time() >= deadline) { g_atomic_int_set(&p->timed_out, 1); break; }
    g_main_context_iteration(NULL, FALSE); g_usleep(1000);
  }
  return G_SOURCE_REMOVE;
}
static void checkpoint_event(void *data, const GlimsEvent *event) {
  Checkpoint *p = data;
  if (event->kind == GLIMS_EVENT_PROGRESS && event->active && event->value >= 1 &&
      g_atomic_int_compare_and_exchange(&p->armed, 1, 0))
    g_idle_add_full(G_PRIORITY_HIGH, pause_checkpoint, p, NULL);
}
static gpointer apply_worker(gpointer data) {
  Checkpoint *p = data;
  p->status = apply(p->engine, p->scene, p->token, &gamma2);
  return NULL;
}
static void checkpoint_cases(GlimsEngine *e, Checkpoint *p, const guint8 *icc, size_t length) {
  for (unsigned retarget = 0; retarget < 2; retarget++) {
    Scene s = {0}; Snapshot before = {0}, expected = {0};
    if (!create_scene(e, &s, GLIMS_PLATE_MODE_MULTICHANNEL, GLIMS_COLOR_COMPONENT_FLOAT, icc, length)) goto done;
    uint64_t token = 0;
    CHECK(begin(e, &s, &token) == GLIMS_STATUS_OK && token, "begin final-checkpoint fixture");
    if (!token || !capture(e, &s, &before)) goto done;
    p->engine = e; p->scene = &s; p->token = token; p->status = GLIMS_STATUS_FAILED;
    g_atomic_int_set(&p->paused, 0); g_atomic_int_set(&p->release, 0);
    g_atomic_int_set(&p->timed_out, 0); g_atomic_int_set(&p->armed, 1);
    GThread *worker = g_thread_new("ink-snapshot-apply", apply_worker, p);
    gint64 deadline = g_get_monotonic_time() + 10 * G_TIME_SPAN_SECOND;
    while (!g_atomic_int_get(&p->paused) && g_get_monotonic_time() < deadline) g_usleep(1000);
    gboolean paused = g_atomic_int_get(&p->paused);
    CHECK(paused, "public progress pauses at final staging checkpoint");
    if (paused) {
      source_unchanged(e, &s, &before, "no source publication at final staging checkpoint");
      CHECK(api->image_ink_snapshot_end(e, s.id, token) == GLIMS_STATUS_BUSY,
            "End cannot free baseline while Apply owns it");
      if (retarget) CHECK(mutate(e, &s, ACTIVE_TARGET) == GLIMS_STATUS_OK, "public target selection remains available during staging");
      else CHECK(api->procedure_cancel(e) == GLIMS_STATUS_OK, "Cancel reaches active snapshot Apply");
      (void)capture(e, &s, &expected);
    }
    g_atomic_int_set(&p->armed, 0); g_atomic_int_set(&p->release, 1);
    g_thread_join(worker);
    CHECK(!g_atomic_int_get(&p->timed_out), "final checkpoint did not time out");
    CHECK(retarget ? p->status != GLIMS_STATUS_OK : p->status == GLIMS_STATUS_CANCELLED,
          retarget ? "retarget at final checkpoint refuses publication" : "Cancel returns CANCELLED");
    if (paused) source_unchanged(e, &s, &expected, "cancel/retarget preserves latest source state with no Undo");
    if (!retarget) {
      GlimsImageID copy = 0;
      CHECK(preview(e, s.id, token, &gamma2, &copy) == GLIMS_STATUS_OK && copy,
            "cancelled Apply leaves baseline usable for another preview");
      if (copy) CHECK(api->image_close(e, copy) == GLIMS_STATUS_OK, "close preview after cancelled Apply");
    }
    CHECK(api->image_ink_snapshot_end(e, s.id, token) == GLIMS_STATUS_OK,
          "cancelled or retargeted Apply leaves token cancelable");
    CHECK(api->procedure_cancel(e) == GLIMS_STATUS_NOT_FOUND, "snapshot Apply releases progress ownership");
  done:
    g_atomic_int_set(&p->armed, 0); g_atomic_int_set(&p->release, 1);
    release_snapshot(&before); release_snapshot(&expected); close_scene(e, &s);
  }
  p->scene = NULL;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s PRIVATE_WORK EXTERNAL_CMYK_ICC\n", argv[0]); return 2; }
  gchar *icc = NULL; gsize length = 0;
  if (!g_file_get_contents(argv[2], &icc, &length, NULL) || length < 128 || length > 4u * 1024u * 1024u) {
    fprintf(stderr, "External bounded CMYK profile unavailable\n"); g_free(icc); return 2;
  }
  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_ink_snapshot_end) + sizeof api->image_ink_snapshot_end ||
      !api->image_ink_snapshot_begin || !api->image_ink_snapshot_levels || !api->image_ink_snapshot_apply || !api->image_ink_snapshot_end) {
    fprintf(stderr, "Adapter lacks slots185-188\n"); g_free(icc); return 2;
  }
  gchar *user = g_build_filename(argv[1], "user", NULL), *cache = g_build_filename(argv[1], "cache", NULL);
  Checkpoint checkpoint = {0};
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache,
    .on_event = checkpoint_event, .event_context = &checkpoint};
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus status = api->start(&config, &engine, &error);
  g_free(user); g_free(cache);
  if (status != GLIMS_STATUS_OK || !engine) {
    fprintf(stderr, "Engine start: %s\n", error ? error : "failed"); api->free_string(error); g_free(icc); return 2;
  }
  api->free_string(error); checkpoint.engine = engine;
  guint initial_count = public_count(engine);
  const uint32_t components[] = {GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16, GLIMS_COLOR_COMPONENT_FLOAT};
  for (uint32_t mode = GLIMS_PLATE_MODE_MULTICHANNEL; mode <= GLIMS_PLATE_MODE_CMYK; mode++)
    for (unsigned i = 0; i < G_N_ELEMENTS(components); i++) {
      Scene scene = {0};
      printf("CASE mode=%u component=%u\n", mode, components[i]);
      if (create_scene(engine, &scene, mode, components[i], (guint8 *)icc, length))
        core_case(engine, &scene, (guint8 *)icc, length);
      close_scene(engine, &scene);
    }
  stale_cases(engine, (guint8 *)icc, length);
  soft_selection_case(engine, GLIMS_PLATE_MODE_MULTICHANNEL, (guint8 *)icc, length);
  soft_selection_case(engine, GLIMS_PLATE_MODE_CMYK, (guint8 *)icc, length);
  close_case(engine, (guint8 *)icc, length);
  checkpoint_cases(engine, &checkpoint, (guint8 *)icc, length);
  CHECK(public_count(engine) == initial_count, "all publicly owned fixture images are closed");
  api->stop(engine); g_free(icc);
  printf("checks=%u failures=%u\n", checks, failures);
  return failures ? 1 : 0;
}

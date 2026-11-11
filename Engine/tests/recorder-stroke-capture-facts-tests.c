/* Native slot171 fixture. Private Core calls only seed/read the images and
 * identify the stock brushes. Capture and replay go through the facade. */
#include "engine-private.h"
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

int main (int argc, char **argv);

G_STATIC_ASSERT (offsetof (GlimsEngineAPI, stroke_begin_with_capture_facts) ==
                 offsetof (GlimsEngineAPI, filter_begin_oilify_with_sources) +
                 sizeof (((GlimsEngineAPI *) 0)->filter_begin_oilify_with_sources));

static const GlimsEngineAPI *api;
static guint checks, failures;

#define CHECK(condition, title) do { \
  gboolean passed_ = (condition); \
  checks++; \
  printf ("%s %s\n", passed_ ? "ok  " : "FAIL", title); \
  if (!passed_) failures++; \
  fflush (stdout); \
} while (0)
#define NEED(condition, title) do { \
  gboolean ready_ = (condition); CHECK (ready_, title); \
  if (!ready_) goto cleanup; \
} while (0)

#define WIDTH 56
#define HEIGHT 40
#define BYTES (WIDTH * HEIGHT * 4)

typedef struct {
  GlimsImageID image;
  GlimsItemID layer;
} Scene;

typedef struct {
  const Scene *scene;
  guint8 raw[BYTES], merged[BYTES];
  GlimsUndoInfo undo;
} Snapshot;

typedef struct {
  GlimsResourceID id;
  gchar *name, *collection;
  gboolean internal;
} BrushIdentity;

typedef struct {
  GlimsStrokeCaptureFacts facts;
  guint8 tail[16];
} FactsWithTail;

static gchar sentinel[] = "caller sentinel";
static const GlimsBrushSettings pencil = {
  .struct_size = sizeof (GlimsBrushSettings), .tool = GLIMS_PAINT_PENCIL,
  .size = 8.5, .opacity = .79, .red = .91, .green = .16, .blue = .31,
  .pressure_size = false, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1
};
static const GlimsStrokePoint trace[] = {
  { 9.5, 10.5, .38, 0, 0, 100 }, { 13.5, 12.5, .91, 0, 0, 108 },
  { 17.5, 16.5, .56, 0, 0, 117 }, { 22.5, 15.5, .72, 0, 0, 125 },
  { 29.5, 21.5, .48, 0, 0, 139 }, { 33.5, 25.5, 1, 0, 0, 146 },
  { 40.5, 24.5, .32, 0, 0, 158 }, { 46.5, 29.5, .85, 0, 0, 173 }
};

static gboolean
has_slot (void)
{
  return api->struct_size >= offsetof (GlimsEngineAPI, stroke_begin_with_capture_facts) +
                             sizeof api->stroke_begin_with_capture_facts &&
         api->stroke_begin_with_capture_facts;
}

static gboolean
identify (GimpBrush *brush, BrushIdentity *out)
{
  if (!brush || gimp_brush_get_pixmap (brush)) return FALSE;
  GimpData *data = GIMP_DATA (brush);
  gint id = gimp_data_get_id (data);
  if (id <= 0) return FALSE;
  out->id = (GlimsResourceID) id;
  gimp_data_get_identifiers (data, &out->name, &out->collection, &out->internal);
  return out->name && *out->name;
}

static GlimsStatus
discover_brushes (GlimsEngine *engine, gpointer data)
{
  BrushIdentity *rows = data;
  GimpBrush *inherited = gimp_context_get_brush (gimp_get_user_context (engine->gimp));
  GimpContainer *factory = gimp_data_factory_get_container (engine->gimp->brush_factory);
  GimpObject *installed = gimp_container_get_child_by_name (factory, "2. Block 01");
  if (installed == (GimpObject *) inherited)
    installed = gimp_container_get_child_by_name (factory, "2. Hardness 025");
  if (!GIMP_IS_BRUSH (installed) || !gimp_data_get_file (GIMP_DATA (installed)) ||
      !identify (inherited, &rows[0]) || !identify (GIMP_BRUSH (installed), &rows[1]) ||
      rows[0].id == rows[1].id || rows[1].internal || !rows[1].collection || !*rows[1].collection)
    return GLIMS_STATUS_FAILED;
  return GLIMS_STATUS_OK;
}

static GlimsStatus
seed_image (GlimsEngine *engine, gpointer data)
{
  Scene *scene = data;
  GlimsStatus status = api->image_new (engine, WIDTH, HEIGHT, &scene->image, NULL);
  if (status != GLIMS_STATUS_OK) return status;
  GlimsOpenImage *open = glims_lookup_image (engine, scene->image);
  if (!open) return GLIMS_STATUS_FAILED;
  GimpImage *image = open->image;
  GimpLayer *layer = gimp_layer_new (image, WIDTH, HEIGHT, gimp_image_get_layer_format (image, TRUE),
      "Recorder RGBA", 1.0, GIMP_LAYER_MODE_NORMAL);
  if (!layer) return GLIMS_STATUS_FAILED;
  if (!gimp_image_add_layer (image, layer, NULL, 0, FALSE)) {
    g_object_unref (layer);
    return GLIMS_STATUS_FAILED;
  }
  guint8 pixels[BYTES];
  for (guint y = 0; y < HEIGHT; y++) for (guint x = 0; x < WIDTH; x++) {
    gsize i = (y * WIDTH + x) * 4;
    pixels[i] = (guint8) (33 + (x * 5 + y * 3) % 199);
    pixels[i + 1] = (guint8) (29 + (x + y * 9) % 197);
    pixels[i + 2] = (guint8) (37 + (x * 11 + y) % 187);
    pixels[i + 3] = (guint8) (83 + (x * 7 + y * 5) % 120);
  }
  GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)); /* Borrowed. */
  gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT), 0,
                   babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, WIDTH, HEIGHT);
  gimp_image_clean_all (image);
  gimp_image_flush (image);
  scene->layer = gimp_item_get_id (GIMP_ITEM (layer));
  return GLIMS_STATUS_OK;
}

static GlimsStatus
read_raw (GlimsEngine *engine, gpointer data)
{
  Snapshot *snapshot = data;
  GlimsOpenImage *open = glims_lookup_image (engine, snapshot->scene->image);
  GimpDrawable *drawable = open ? glims_lookup_drawable (open, snapshot->scene->layer) : NULL;
  if (!drawable || G_OBJECT_TYPE (drawable) != GIMP_TYPE_LAYER ||
      !gimp_drawable_has_alpha (drawable) || !gimp_drawable_is_rgb (drawable))
    return GLIMS_STATUS_FAILED;
  GeglBuffer *buffer = gimp_drawable_get_buffer (drawable); /* Borrowed. */
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT), 1,
                   babl_format ("R'G'B'A u8"), snapshot->raw, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  return GLIMS_STATUS_OK;
}

static gboolean
read_image (GlimsEngine *engine, const Scene *scene, Snapshot *snapshot)
{
  snapshot->scene = scene;
  return glims_engine_call (engine, read_raw, snapshot) == GLIMS_STATUS_OK &&
         api->image_render (engine, scene->image, 1, (GlimsRect) {0, 0, WIDTH, HEIGHT},
                            snapshot->merged, WIDTH * 4) == GLIMS_STATUS_OK &&
         api->image_undo_info (engine, scene->image, &snapshot->undo) == GLIMS_STATUS_OK;
}

static gboolean
same_pixels (const Snapshot *a, const Snapshot *b)
{
  return !memcmp (a->raw, b->raw, BYTES) && !memcmp (a->merged, b->merged, BYTES);
}

static gboolean
same_image (const Snapshot *a, const Snapshot *b)
{
  return same_pixels (a, b) && a->undo.undo_count == b->undo.undo_count &&
         a->undo.redo_count == b->undo.redo_count && !strcmp (a->undo.next_undo, b->undo.next_undo) &&
         !strcmp (a->undo.next_redo, b->undo.next_redo);
}

static gboolean
changed_once (const Snapshot *before, const Snapshot *after)
{
  return memcmp (before->raw, after->raw, BYTES) && memcmp (before->merged, after->merged, BYTES) &&
         after->undo.undo_count == before->undo.undo_count + 1 && after->undo.redo_count == 0;
}

static gboolean
finish_trace (GlimsEngine *engine, GlimsStrokeID *stroke)
{
  if (*stroke <= 0) return FALSE;
  GlimsStatus continued = api->stroke_continue (engine, *stroke, trace + 1, G_N_ELEMENTS (trace) - 1);
  GlimsStatus ended = api->stroke_end (engine, *stroke);
  if (ended == GLIMS_STATUS_OK) *stroke = 0;
  return continued == GLIMS_STATUS_OK && ended == GLIMS_STATUS_OK;
}

static void
free_facts (GlimsStrokeCaptureFacts *facts)
{
  if (facts->brush_name && facts->brush_name != sentinel) api->free_string (facts->brush_name);
  if (facts->brush_collection && facts->brush_collection != sentinel) api->free_string (facts->brush_collection);
  if (facts->fingerprint && facts->fingerprint != sentinel) api->free_string (facts->fingerprint);
}

static void
free_error (char *error)
{
  if (error && error != sentinel) api->free_string (error);
}

static gboolean
valid_digest (const char *value)
{
  if (!value || strlen (value) != 64) return FALSE;
  for (gsize i = 0; i < 64; i++)
    if (!g_ascii_isdigit (value[i]) && (value[i] < 'a' || value[i] > 'f')) return FALSE;
  return TRUE;
}

static gboolean
matches_identity (const GlimsStrokeCaptureFacts *facts, const BrushIdentity *brush)
{
  return facts->brush_name && !strcmp (facts->brush_name, brush->name) &&
         !g_strcmp0 (facts->brush_collection, brush->collection) &&
         facts->brush_internal == (brush->internal != FALSE) && valid_digest (facts->fingerprint);
}

static gboolean
tail_intact (const FactsWithTail *box, uint32_t size)
{
  if (box->facts.struct_size != size) return FALSE;
  for (gsize i = 0; i < sizeof box->tail; i++) if (box->tail[i] != 0xa5) return FALSE;
  return TRUE;
}

static FactsWithTail
fact_box (uint32_t size, gboolean set_canaries)
{
  FactsWithTail box = { .facts = { .struct_size = size } };
  memset (box.tail, 0xa5, sizeof box.tail);
  if (set_canaries) {
    box.facts.brush_internal = true;
    box.facts.brush_name = box.facts.brush_collection = box.facts.fingerprint = sentinel;
  }
  return box;
}

static gboolean
facts_empty (const GlimsStrokeCaptureFacts *facts)
{
  return !facts->brush_internal && !facts->brush_name && !facts->brush_collection && !facts->fingerprint;
}

static gboolean
refused_before_paint (GlimsEngine *engine, const Scene *scene, const Snapshot *before,
                      GlimsResourceID brush, const GlimsBrushSettings *settings,
                      const char *expected, GlimsStatus wanted)
{
  FactsWithTail box = fact_box (sizeof box, TRUE);
  GlimsStrokeID stroke = -7;
  char *error = sentinel;
  GlimsStatus status = api->stroke_begin_with_capture_facts (engine, scene->image, scene->layer,
      brush, settings, trace, expected, &stroke, &box.facts, &error);
  Snapshot after;
  gboolean valid = status == wanted && stroke == 0 && error != sentinel && facts_empty (&box.facts) &&
      tail_intact (&box, sizeof box) && read_image (engine, scene, &after) && same_image (before, &after);
  if (stroke > 0) api->stroke_end (engine, stroke);
  free_error (error);
  free_facts (&box.facts);
  return valid;
}

static void
stroke_case (GlimsEngine *engine, const BrushIdentity *brush, gboolean inherited, gboolean available,
             char digest[65])
{
  Scene reference = {0}, captured = {0}, replayed = {0};
  Snapshot original, painted, actual;
  GlimsStrokeID stroke = 0;
  char *error = NULL;
  FactsWithTail capture = fact_box (sizeof capture, FALSE), replay = fact_box (sizeof replay, FALSE);
  GlimsResourceID requested = inherited ? 0 : brush->id;
  printf ("OBS %s brush=%s\n", inherited ? "inherited" : "installed", brush->name);

  NEED (glims_engine_call (engine, seed_image, &reference) == GLIMS_STATUS_OK &&
        read_image (engine, &reference, &original), "independent V1 RGBA fixture opens with raw and merged baseline");
  GlimsStatus status = inherited
      ? api->stroke_begin (engine, reference.image, reference.layer, &pencil, trace, &stroke, &error)
      : api->stroke_begin_with_brush_resource (engine, reference.image, reference.layer, requested,
                                               &pencil, trace, &stroke, &error);
  NEED (status == GLIMS_STATUS_OK && !error && finish_trace (engine, &stroke),
        "ordinary V1 Pencil begins, continues and ends with the expected brush");
  NEED (read_image (engine, &reference, &painted) && changed_once (&original, &painted),
        "independent V1 changes both raw and merged pixels in one Undo");
  if (!available) goto cleanup;

  NEED (glims_engine_call (engine, seed_image, &captured) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &replayed) == GLIMS_STATUS_OK &&
        read_image (engine, &captured, &actual) && same_image (&original, &actual) &&
        read_image (engine, &replayed, &actual) && same_image (&original, &actual),
        "capture and replay are separately seeded to the exact V1 starting state");
  NEED (api->stroke_begin_with_capture_facts (engine, captured.image, captured.layer, requested,
          &pencil, trace, NULL, &stroke, &capture.facts, &error) == GLIMS_STATUS_OK && stroke > 0 && !error,
        "live capture returns a native Pencil stroke");
  NEED (finish_trace (engine, &stroke), "live capture uses ordinary V1 continuation and end");
  NEED (matches_identity (&capture.facts, brush) && tail_intact (&capture, sizeof capture),
        "owned facts outlive the stroke with the actual name, collection, role and 64 lowercase hex digits");
  memcpy (digest, capture.facts.fingerprint, 65);
  CHECK (read_image (engine, &captured, &actual) && same_image (&painted, &actual),
         "capture preserves the ordinary V1 raw, merged and Undo result");
  GlimsResourceID resolved = 0;
  NEED (api->resource_resolve (engine, GLIMS_RESOURCE_BRUSH, capture.facts.brush_name,
          capture.facts.brush_collection, capture.facts.brush_internal, &resolved, &error) == GLIMS_STATUS_OK &&
        resolved == brush->id && !error, "the owned identity resolves the actual native brush explicitly");

  if (!inherited) {
    GlimsBrushSettings altered = pencil;
    altered.size += 4;
    char wrong[65];
    memcpy (wrong, digest, sizeof wrong);
    wrong[0] = wrong[0] == '0' ? '1' : '0';
    NEED (refused_before_paint (engine, &replayed, &original, resolved, &altered, digest, GLIMS_STATUS_FAILED),
          "changed Pencil size refuses before pixels or history can change");
    NEED (refused_before_paint (engine, &replayed, &original, resolved, &pencil, wrong, GLIMS_STATUS_FAILED),
          "wrong well-formed fingerprint refuses before pixels or history can change");
    NEED (refused_before_paint (engine, &replayed, &original, 0, &pencil, digest, GLIMS_STATUS_INVALID_ARGUMENT),
          "guarded replay cannot inherit an implicit brush");
  }
  NEED (api->stroke_begin_with_capture_facts (engine, replayed.image, replayed.layer, resolved,
          &pencil, trace, digest, &stroke, &replay.facts, &error) == GLIMS_STATUS_OK && stroke > 0 && !error,
        "guarded replay admits the explicit identity with the captured fingerprint");
  NEED (finish_trace (engine, &stroke), "guarded replay drives the same ordinary V1 trace");
  CHECK (matches_identity (&replay.facts, brush) && !strcmp (replay.facts.fingerprint, digest) &&
         tail_intact (&replay, sizeof replay), "guarded replay owns the same identity and fingerprint");
  CHECK (read_image (engine, &replayed, &actual) && same_image (&painted, &actual),
         "guarded replay matches independent V1 raw, merged and one-Undo bytes");
  CHECK (api->image_undo (engine, replayed.image) == GLIMS_STATUS_OK &&
         read_image (engine, &replayed, &actual) && same_pixels (&original, &actual) &&
         actual.undo.undo_count == original.undo.undo_count && actual.undo.redo_count == 1,
         "one replay Undo restores the original raw and merged image");
  CHECK (api->image_redo (engine, replayed.image) == GLIMS_STATUS_OK &&
         read_image (engine, &replayed, &actual) && same_image (&painted, &actual),
         "one replay Redo restores the independent V1 image and history");
cleanup:
  if (error && error != sentinel) fprintf (stderr, "OBS stroke facts: %s\n", error);
  if (stroke > 0) api->stroke_end (engine, stroke);
  free_error (error);
  free_facts (&capture.facts);
  free_facts (&replay.facts);
  if (reference.image) CHECK (api->image_close (engine, reference.image) == GLIMS_STATUS_OK, "V1 reference closes");
  if (captured.image) CHECK (api->image_close (engine, captured.image) == GLIMS_STATUS_OK, "live capture image closes");
  if (replayed.image) CHECK (api->image_close (engine, replayed.image) == GLIMS_STATUS_OK, "guarded replay image closes");
}

static void
unsupported_case (GlimsEngine *engine, GlimsResourceID brush, const char *fingerprint)
{
  Scene scene = {0};
  Snapshot before, after;
  GlimsStrokeID stroke = 0;
  char *error = NULL;
  GlimsBrushSettings settings = pencil;
  FactsWithTail box = fact_box (sizeof box, FALSE);
  NEED (glims_engine_call (engine, seed_image, &scene) == GLIMS_STATUS_OK && read_image (engine, &scene, &before),
        "unsupported capture control opens an ordinary RGBA target");
  if (fingerprint) {
    GlimsComponentState components = {0};
    NEED (api->image_set_components (engine, scene.image, GLIMS_COMPONENT_RED, 0, 0, 0, NULL) == GLIMS_STATUS_OK &&
          api->image_components (engine, scene.image, &components) == GLIMS_STATUS_OK &&
          (components.supported & GLIMS_COMPONENT_RED) && !(components.active & GLIMS_COMPONENT_RED) &&
          read_image (engine, &scene, &after) && same_image (&before, &after),
          "disabling the Red component changes neither stored pixels nor Undo");
    NEED (refused_before_paint (engine, &scene, &before, brush, &settings, fingerprint, GLIMS_STATUS_FAILED),
          "disabled Red refuses guarded replay before pixels or history change");
  } else {
    settings.tool = GLIMS_PAINT_PAINTBRUSH;
  }
  NEED (api->stroke_begin_with_capture_facts (engine, scene.image, scene.layer, brush,
          &settings, trace, NULL, &stroke, &box.facts, &error) == GLIMS_STATUS_OK && stroke > 0 && !error,
        fingerprint ? "unguarded Pencil still paints with disabled Red"
                    : "ordinary live Paintbrush is admitted without an expected fingerprint");
  CHECK (facts_empty (&box.facts) && tail_intact (&box, sizeof box),
         "unsupported live configuration yields nil facts and preserves the future tail");
  NEED (finish_trace (engine, &stroke), "unsupported live stroke still uses V1 continuation and end");
  CHECK (read_image (engine, &scene, &after) && changed_once (&before, &after),
         "unsupported live capture still paints raw and merged pixels in one Undo");
cleanup:
  if (stroke > 0) api->stroke_end (engine, stroke);
  free_error (error);
  free_facts (&box.facts);
  if (scene.image) CHECK (api->image_close (engine, scene.image) == GLIMS_STATUS_OK, "unsupported live image closes");
}

static void
output_cases (GlimsEngine *engine, gboolean stopped)
{
  const uint32_t size = stopped ? sizeof (FactsWithTail)
      : offsetof (GlimsStrokeCaptureFacts, fingerprint) + sizeof (char *) - 1;
  FactsWithTail box = fact_box (size, TRUE);
  GlimsStrokeID stroke = -7;
  char *error = sentinel;
  GlimsStatus status = api->stroke_begin_with_capture_facts (engine, 1, 1, 0,
      &pencil, trace, NULL, &stroke, &box.facts, &error);
  CHECK (status == (stopped ? GLIMS_STATUS_NOT_RUNNING : GLIMS_STATUS_INVALID_ARGUMENT) &&
         stroke == 0 && !error && !box.facts.brush_internal && !box.facts.brush_name &&
         !box.facts.brush_collection && box.facts.fingerprint == (stopped ? NULL : sentinel),
         stopped ? "stopped dispatch clears stroke, error and every known facts field"
                 : "short output clears only complete known fields before refusing");
  CHECK (tail_intact (&box, size), stopped ? "stopped output preserves size and future tail"
                                        : "short output preserves size, partial field and future tail");
  if (engine && stroke > 0) api->stroke_end (engine, stroke);
  free_error (error);
  free_facts (&box.facts);
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof (GlimsEngineAPI, stroke_begin_with_capture_facts)) return 2;
  gboolean available = has_slot ();
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL;
  char *error = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed");
    free_error (error);
    g_free (user); g_free (cache);
    return 2;
  }
  BrushIdentity brushes[2] = {0};
  GlimsStatus discovered = glims_engine_call (engine, discover_brushes, brushes);
  CHECK (discovered == GLIMS_STATUS_OK, "native context supplies its actual default and a distinct installed monochrome brush");
  CHECK (available, "slot171 stroke capture facts are present");
  if (discovered == GLIMS_STATUS_OK) {
    char digests[2][65] = {{0}};
    stroke_case (engine, &brushes[0], TRUE, available, digests[0]);
    stroke_case (engine, &brushes[1], FALSE, available, digests[1]);
    if (available) {
      CHECK (digests[0][0] && digests[1][0] && strcmp (digests[0], digests[1]),
             "distinct stock brushes produce distinct configuration fingerprints");
      unsupported_case (engine, brushes[1].id, NULL);
      if (valid_digest (digests[1])) unsupported_case (engine, brushes[1].id, digests[1]);
    }
  }
  if (available) output_cases (engine, FALSE);
  else printf ("OBS slot171-dependent cases NOT RUN on the short producer table\n");
  api->stop (engine);
  if (available) output_cases (NULL, TRUE);
  for (gsize i = 0; i < G_N_ELEMENTS (brushes); i++) {
    g_free (brushes[i].name);
    g_free (brushes[i].collection);
  }
  g_free (user); g_free (cache);
  printf ("%s: %u checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

/* Private Core fixtures; no GUI and no dependency on unexported dylib symbols.
 * Run native work on glims_engine_call; exercise public slot147 from main too. */
#include "engine-private.h"
#include "filter-input.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#include "text/gimptext.h"
#include "text/gimptextlayer.h"
#include "gegl-buffer-backend.h"
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

#define SIDE 32
#define BYTES (SIDE * SIDE * 4)
int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static int failures;
static const gchar *work_dir;
#define CHECK(c, text) do { gboolean check_ok_ = (c); printf ("%s %s\n", check_ok_ ? "ok  " : "FAIL", text); if (!check_ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, text) do { gboolean need_ok_ = (c); CHECK (need_ok_, text); if (!need_ok_) goto cleanup; } while (0)
typedef struct {
  GlimsEngine *engine;
  GlimsImageID id;
  GimpImage *image;             /* Borrowed from the adapter. */
  GimpLayer *target, *source;   /* Borrowed from the image. */
} Fixture;

static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }
static GlimsItemID item_id (gpointer item) { return gimp_item_get_id (GIMP_ITEM (item)); }

static void
write_pixels (GimpLayer *layer, gboolean target, gboolean ramp)
{
  guint8 pixels[BYTES];
  for (guint y = 0; y < SIDE; y++) for (guint x = 0; x < SIDE; x++) {
    guint i = (y * SIDE + x) * 4;
    if (target) {
      pixels[i] = 48 + x * 3; pixels[i + 1] = 64 + y * 2;
      pixels[i + 2] = 112; pixels[i + 3] = (x & 1) ? 128 : 192;
    } else {
      pixels[i] = pixels[i + 1] = pixels[i + 2] = ramp ? x * 255 / (SIDE - 1) : 128;
      pixels[i + 3] = 255;
    }
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"),
                   pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, SIDE, SIDE);
}

static GimpLayer *
add_layer (GimpImage *image, const char *name, gboolean target, gboolean ramp)
{
  GimpLayer *layer = gimp_layer_new (image, SIDE, SIDE, gimp_image_get_layer_format (image, TRUE),
                                    name, 1.0, GIMP_LAYER_MODE_NORMAL);
  if (!layer) return NULL;
  if (!gimp_image_add_layer (image, layer, NULL, 0, FALSE)) { g_object_unref (layer); return NULL; }
  write_pixels (layer, target, ramp);
  return layer;
}

static gboolean
fixture_open (GlimsEngine *engine, Fixture *f, gboolean ramp)
{
  memset (f, 0, sizeof *f); f->engine = engine;
  if (api->image_new (engine, SIDE, SIDE, &f->id, NULL) != GLIMS_STATUS_OK) return FALSE;
  f->image = glims_lookup_image (engine, f->id)->image;
  f->source = add_layer (f->image, "Height source", FALSE, ramp);
  f->target = add_layer (f->image, "RGBA target", TRUE, FALSE);
  if (!f->source || !f->target) return FALSE;
  gimp_item_set_visible (GIMP_ITEM (f->source), FALSE, FALSE);
  gimp_image_clean_all (f->image);
  return TRUE;
}

static void fixture_close (Fixture *f) {
  if (f->id) api->image_close (f->engine, f->id);
  f->id = 0;
}

static gboolean
read_pixels (GimpLayer *layer, gboolean effects, guint8 pixels[BYTES])
{
  GeglBuffer *buffer;
  if (effects) {
    gimp_pickable_flush (GIMP_PICKABLE (layer));
    buffer = gimp_drawable_get_buffer_with_effects (GIMP_DRAWABLE (layer)); /* OWNED */
  } else buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (layer));
  if (!buffer) return FALSE;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 1, babl_format ("R'G'B'A u8"),
                   pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  if (effects) g_object_unref (buffer);
  return TRUE;
}

static gboolean
interior_identity (const guint8 *before, const guint8 *after)
{
  for (guint y = 2; y < SIDE - 2; y++) for (guint x = 2; x < SIDE - 2; x++)
    for (guint c = 0; c < 4; c++) {
      guint i = (y * SIDE + x) * 4 + c;
      if (ABS ((int) before[i] - (int) after[i]) > 1) return FALSE;
    }
  return TRUE;
}

static gboolean
alpha_same (const guint8 *a, const guint8 *b)
{
  for (guint i = 3; i < BYTES; i += 4) if (a[i] != b[i]) return FALSE;
  return TRUE;
}

static gboolean
undo_equal (GlimsEngine *engine, GlimsImageID id, const GlimsUndoInfo *before)
{
  GlimsUndoInfo after = {0};
  return api->image_undo_info (engine, id, &after) == GLIMS_STATUS_OK && !memcmp (before, &after, sizeof after);
}

static GlimsStatus
begin (Fixture *f, GlimsItemID source, GlimsFilterID *filter, char **error)
{
  GlimsStatus status = glims_filter_begin_with_source (f->engine, f->id, item_id (f->target),
                                                      "gegl:bump-map", source, filter, error);
  if (status == GLIMS_STATUS_OK) {
    GlimsFilterValue depth = { .kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 32 };
    GlimsFilterValue compensate = { .kind = GLIMS_FILTER_VALUE_BOOL, .boolean = TRUE };
    if (api->filter_set_property (f->engine, *filter, "depth", &depth) != GLIMS_STATUS_OK ||
        api->filter_set_property (f->engine, *filter, "compensate", &compensate) != GLIMS_STATUS_OK)
      return GLIMS_STATUS_FAILED;
  }
  return status;
}

static GlimsStatus
flat_and_commit (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  guint8 original[BYTES], preview[BYTES], source[BYTES], current[BYTES], committed[BYTES];
  GlimsUndoInfo before = {0}, after = {0}; int32_t effects = -1;
  NEED (fixture_open (engine, &f, FALSE), "flat fixture contains real alpha target and constant height source");
  NEED (read_pixels (f.target, FALSE, original) && read_pixels (f.source, FALSE, source) &&
        api->image_undo_info (engine, f.id, &before) == GLIMS_STATUS_OK, "flat fixture captures raw pixels and history");
  CHECK (original[3] == 192 && original[7] == 128 && source[0] == 128 && source[3] == 255,
         "independent fixture alpha and constant height values are installed");
  gimp_item_set_lock_content (GIMP_ITEM (f.source), TRUE, FALSE);
  NEED (begin (&f, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK, "read-only locked source is accepted");
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (filter));
  gboolean merge = FALSE;
  g_object_get (session->filter, "to-be-merged", &merge, NULL);
  CHECK (!session->non_destructive && session->aux_source && merge,
         "aux preview owns a source and uses native merge-only mode");
  NEED (read_pixels (f.target, TRUE, preview), "flat preview renders through native effects");
  /* bump-map.c: nx=ny=0 -> shade=sin(elevation)=compensation.
   * One u8 level allows the native float/format round-trip, not shading. */
  CHECK (interior_identity (original, preview), "flat compensated map preserves independently known interior RGBA within one u8 level");
  CHECK (alpha_same (original, preview), "height shading preserves every target alpha byte");
  CHECK (read_pixels (f.source, FALSE, current) && !memcmp (source, current, BYTES) && undo_equal (engine, f.id, &before),
         "begin and preview leave original source bytes and history unchanged");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "flat preview aborts"); filter = 0;
  CHECK (read_pixels (f.target, FALSE, current) && !memcmp (original, current, BYTES) && undo_equal (engine, f.id, &before),
         "abort leaves every stored target byte and history unchanged");
  write_pixels (f.source, FALSE, TRUE);
  NEED (read_pixels (f.source, FALSE, source), "height ramp captures its own raw baseline");
  NEED (begin (&f, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK && read_pixels (f.target, TRUE, preview),
        "contrasting ramp preview starts and renders");
  gboolean changed = FALSE;
  for (guint y = 2; y < SIDE - 2; y++) for (guint x = 2; x < SIDE - 2; x++) {
    guint i = (y * SIDE + x) * 4;
    if (ABS ((int) original[i] - (int) preview[i]) > 1) changed = TRUE;
  }
  CHECK (changed, "height ramp changes interior target colors, so an absent aux input cannot pass");
  CHECK (alpha_same (original, preview), "ramp changes illumination without changing alpha");
  NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "ramp preview commits"); filter = 0;
  NEED (read_pixels (f.target, FALSE, committed), "committed raw pixels can be captured");
  CHECK (interior_identity (preview, committed), "merged pixels match the accepted native preview within one u8 level");
  CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
         "one aux commit adds exactly one native Undo step");
  CHECK (api->drawable_effects (engine, f.id, item_id (f.target), NULL, 0, &effects) == GLIMS_STATUS_OK && effects == 0,
         "commit leaves no persisted auxiliary ND effect");
  CHECK (read_pixels (f.source, FALSE, current) && !memcmp (source, current, BYTES), "commit does not alter original height-source pixels");
  NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "committed bump map undoes");
  CHECK (read_pixels (f.target, FALSE, current) && !memcmp (original, current, BYTES), "one Undo restores every original target byte exactly");
  NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "committed bump map redoes");
  CHECK (read_pixels (f.target, FALSE, current) && !memcmp (committed, current, BYTES), "one Redo restores every committed target byte exactly");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
snapshot_independence (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  guint8 before[BYTES], expected[BYTES], after[BYTES];
  GWeakRef source_weak, node_weak, buffer_weak; gboolean weak_initialized = FALSE;
  NEED (fixture_open (engine, &f, TRUE) && read_pixels (f.target, FALSE, before), "COW fixture installs a real ramp and captures target");
  NEED (api->filter_begin (engine, f.id, item_id (f.source), "gegl:brightness-contrast", &filter, &error) == GLIMS_STATUS_OK &&
        api->filter_set_double (engine, filter, "brightness", 0.125) == GLIMS_STATUS_OK &&
        api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "source owns a real committed brightness effect"); filter = 0;
  guint8 source_effects[BYTES], source_raw[BYTES], copied_height[BYTES];
  NEED (read_pixels (f.source, TRUE, source_effects) && read_pixels (f.source, FALSE, source_raw),
        "effect-bearing source pixels can be independently captured before Begin");
  CHECK (memcmp (source_effects, source_raw, BYTES) != 0, "source effect genuinely changes the height map");
  NEED (begin (&f, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK && read_pixels (f.target, TRUE, expected),
        "COW preview captures the original ramp");
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (filter));
  GeglBuffer *snapshot = NULL;
  gegl_node_get (session->aux_source, "buffer", &snapshot, NULL); /* OWNED get */
  NEED (snapshot != NULL, "aux node exposes its owned snapshot buffer");
  CHECK (snapshot != gimp_drawable_get_buffer (GIMP_DRAWABLE (f.source)), "snapshot is a distinct buffer object");
  gegl_buffer_get (snapshot, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 1, babl_format ("R'G'B'A u8"),
                   copied_height, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  CHECK (!memcmp (source_effects, copied_height, BYTES), "aux snapshot contains the source's committed effects, not just its raw pixels");
  g_weak_ref_init (&source_weak, G_OBJECT (f.source));
  g_weak_ref_init (&node_weak, G_OBJECT (session->aux_source));
  g_weak_ref_init (&buffer_weak, G_OBJECT (snapshot)); weak_initialized = TRUE;
  g_object_unref (snapshot); /* No test-owned strong buffer/node probe remains. */
  write_pixels (f.source, FALSE, FALSE); /* Deliberately bypass facade's active-preview gate. */
  CHECK (read_pixels (f.target, TRUE, after) && !memcmp (expected, after, BYTES), "editing original source after Begin cannot alter preview");
  gimp_image_remove_layer (f.image, f.source, FALSE, NULL); f.source = NULL;
  gimp_image_undo_free (f.image);
  GObject *probe = g_weak_ref_get (&source_weak);
  CHECK (probe == NULL, "deleting and purging original source finalizes it while preview stays active"); g_clear_object (&probe);
  CHECK (read_pixels (f.target, TRUE, after) && !memcmp (expected, after, BYTES), "preview survives complete source deletion and history purge");
  GlimsFilterID old_filter = filter;
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "COW preview aborts"); filter = 0;
  probe = g_weak_ref_get (&node_weak); CHECK (probe == NULL, "abort releases the owned auxiliary node"); g_clear_object (&probe);
  probe = g_weak_ref_get (&buffer_weak); CHECK (probe == NULL, "abort releases the detached snapshot buffer"); g_clear_object (&probe);
  CHECK (api->filter_abort (engine, old_filter) == GLIMS_STATUS_NOT_FOUND, "repeated abort reports a finished session");
  CHECK (read_pixels (f.target, FALSE, after) && !memcmp (before, after, BYTES), "COW abort preserves stored target pixels");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (weak_initialized) { g_weak_ref_clear (&source_weak); g_weak_ref_clear (&node_weak); g_weak_ref_clear (&buffer_weak); }
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
existing_effects_and_cycles (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  guint8 raw[BYTES], baseline[BYTES], preview[BYTES], after[BYTES];
  NEED (fixture_open (engine, &f, FALSE), "effect-order fixture opens");
  NEED (api->filter_begin (engine, f.id, item_id (f.target), "gegl:brightness-contrast", &filter, &error) == GLIMS_STATUS_OK &&
        api->filter_set_double (engine, filter, "brightness", 0.125) == GLIMS_STATUS_OK &&
        api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "one genuine committed target effect is installed"); filter = 0;
  GlimsEffectInfo effect = {0}, current = {0}; int32_t count = 0;
  NEED (api->drawable_effects (engine, f.id, item_id (f.target), &effect, 1, &count) == GLIMS_STATUS_OK && count == 1 &&
        read_pixels (f.target, FALSE, raw) && read_pixels (f.target, TRUE, baseline), "committed effect and rendered baseline are captured");
  NEED (begin (&f, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK && read_pixels (f.target, TRUE, preview), "flat auxiliary preview overlays the existing effect");
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (filter));
  GimpContainer *stack = gimp_drawable_get_filters (GIMP_DRAWABLE (f.target));
  CHECK (gimp_container_get_child_by_index (stack, gimp_container_get_n_children (stack) - 1) == GIMP_OBJECT (session->filter),
         "merged preview is at the bottom under the committed effect");
  CHECK (interior_identity (baseline, preview), "flat compensated preview does not apply the existing brightness effect twice");
  NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "auxiliary preview merges under existing effect"); filter = 0;
  CHECK (read_pixels (f.target, TRUE, after) && interior_identity (baseline, after), "committed output still applies the existing effect exactly once");
  CHECK (api->drawable_effects (engine, f.id, item_id (f.target), &current, 1, &count) == GLIMS_STATUS_OK && count == 1 &&
         !memcmp (&effect, &current, sizeof effect), "existing effect identity and properties remain intact with no extra ND aux effect");
  for (guint ancestor = 0; ancestor < 2; ancestor++) {
    GlimsItemID source = item_id (f.target);
    if (ancestor) {
      GimpLayer *group = gimp_group_layer_new (f.image);
      NEED (gimp_image_add_layer (f.image, group, NULL, 0, FALSE), "real ancestor group attaches");
      NEED (api->reparent_layer (engine, f.id, item_id (f.target), item_id (group), 0, &error) == GLIMS_STATUS_OK, "target becomes a real descendant of source group");
      source = item_id (group);
    }
    GlimsUndoInfo history = {0};
    NEED (read_pixels (f.target, FALSE, raw) && api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK,
          "self/ancestor setup captures its post-fixture state");
    NEED (begin (&f, source, &filter, &error) == GLIMS_STATUS_OK && read_pixels (f.target, TRUE, preview),
          "self or ancestor-source preview completes without a live graph cycle");
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "self/ancestor preview aborts"); filter = 0;
    CHECK (read_pixels (f.target, FALSE, after) && !memcmp (raw, after, BYTES) && undo_equal (engine, f.id, &history),
           "self/ancestor abort restores exact stored pixels and adds no history");
  }
cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

/* Fingerprint independent target/source pixels plus image/Undo facts around
 * refused requests; caller deliberately changes only its fixture beforehand. */
static gchar *
fingerprint (Fixture *f)
{
  guint8 pixels[BYTES]; GlimsImageInfo info = {0}; GlimsUndoInfo undo = {0};
  GString *bytes = g_string_new (NULL);
  if (!read_pixels (f->target, FALSE, pixels) || api->image_info (f->engine, f->id, &info) != GLIMS_STATUS_OK ||
      api->image_undo_info (f->engine, f->id, &undo) != GLIMS_STATUS_OK) { g_string_free (bytes, TRUE); return NULL; }
  g_string_append_len (bytes, (const gchar *) pixels, BYTES);
  if (!read_pixels (f->source, FALSE, pixels)) { g_string_free (bytes, TRUE); return NULL; }
  g_string_append_len (bytes, (const gchar *) pixels, BYTES);
  g_string_append_len (bytes, (const gchar *) &info, sizeof info);
  g_string_append_len (bytes, (const gchar *) &undo, sizeof undo);
  gchar *hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guchar *) bytes->str, bytes->len);
  g_string_free (bytes, TRUE); return hash;
}

static void
refuses (Fixture *f, GlimsImageID image, GlimsItemID target, const char *operation,
         GlimsItemID source, GlimsStatus expected, const char *label)
{
  gchar *before = fingerprint (f); char *error = NULL; GlimsFilterID out = 0x12345678;
  guint sessions = g_hash_table_size (f->engine->filters);
  GlimsStatus status = glims_filter_begin_with_source (f->engine, image, target, operation, source, &out, &error);
  gchar *after = fingerprint (f);
  CHECK (status == expected && out == 0, label);
  CHECK (before && after && !strcmp (before, after) && sessions == g_hash_table_size (f->engine->filters),
         "refusal preserves captured pixels/history/image facts and creates no session");
  if (status == GLIMS_STATUS_OK && out) api->filter_abort (f->engine, out);
  clear_error (&error); g_free (before); g_free (after);
}

static GlimsStatus
refusal_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}, other = {0}; char *error = NULL; GlimsFilterID filter = 0;
  GlimsImageID indexed_id = 0;
  NEED (fixture_open (engine, &f, FALSE) && fixture_open (engine, &other, FALSE), "refusal fixtures open independent images");
  GlimsItemID target = item_id (f.target), source = item_id (f.source);
  refuses (&f, f.id, 0, "gegl:bump-map", source, GLIMS_STATUS_INVALID_ARGUMENT, "implicit target zero is refused and output reset");
  refuses (&f, f.id, target, "gegl:bump-map", 0, GLIMS_STATUS_INVALID_ARGUMENT, "implicit source zero is refused");
  refuses (&f, f.id, -1, "gegl:bump-map", source, GLIMS_STATUS_INVALID_ARGUMENT, "negative target is refused");
  refuses (&f, f.id, target, NULL, source, GLIMS_STATUS_INVALID_ARGUMENT, "NULL operation is refused");
  refuses (&f, f.id, target, "gegl:gaussian-blur", source, GLIMS_STATUS_UNSUPPORTED, "an operation without the admitted aux contract is refused");
  refuses (&f, INT_MAX, target, "gegl:bump-map", source, GLIMS_STATUS_NOT_FOUND, "unknown image is refused");
  refuses (&f, f.id, INT_MAX, "gegl:bump-map", source, GLIMS_STATUS_NOT_FOUND, "unknown target is refused");
  refuses (&f, f.id, target, "gegl:bump-map", INT_MAX, GLIMS_STATUS_NOT_FOUND, "unknown source is refused");
  refuses (&f, f.id, target, "gegl:bump-map", item_id (other.source), GLIMS_STATUS_NOT_FOUND, "foreign source is refused");
  refuses (&f, f.id, item_id (other.target), "gegl:bump-map", source, GLIMS_STATUS_NOT_FOUND, "foreign target is refused");
  CHECK (glims_filter_begin_with_source (engine, f.id, target, "gegl:bump-map", source, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "NULL output pointer is refused without creating a preview"); clear_error (&error);
  GimpLayer *stale = add_layer (f.image, "Detached source", FALSE, FALSE);
  NEED (stale != NULL, "stale source fixture attaches"); GlimsItemID stale_id = item_id (stale);
  gimp_image_remove_layer (f.image, stale, TRUE, NULL);
  refuses (&f, f.id, target, "gegl:bump-map", stale_id, GLIMS_STATUS_NOT_FOUND, "detached but Undo-retained source is refused");
  GimpLayer *group = gimp_group_layer_new (f.image);
  NEED (gimp_image_add_layer (f.image, group, NULL, 0, FALSE), "group target fixture attaches");
  refuses (&f, f.id, item_id (group), "gegl:bump-map", source, GLIMS_STATUS_UNSUPPORTED, "group merge target is refused");
  refuses (&f, f.id, item_id (gimp_image_get_mask (f.image)), "gegl:bump-map", source, GLIMS_STATUS_UNSUPPORTED, "actual nonlayer merge target is refused");
  GimpText *text = g_object_new (GIMP_TYPE_TEXT, "text", "T", "font", gimp_context_get_font (gimp_get_user_context (engine->gimp)), "font-size", 8.0, NULL);
  GimpLayer *editable = gimp_text_layer_new (f.image, text); g_object_unref (text);
  NEED (editable && gimp_image_add_layer (f.image, editable, NULL, 0, FALSE), "genuine editable text target attaches");
  refuses (&f, f.id, item_id (editable), "gegl:bump-map", source, GLIMS_STATUS_UNSUPPORTED, "editable target is refused without implicit rasterization");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), TRUE, FALSE);
  refuses (&f, f.id, target, "gegl:bump-map", source, GLIMS_STATUS_LOCKED, "effective target pixel lock refuses");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), FALSE, FALSE);
  engine->busy++; refuses (&f, f.id, target, "gegl:bump-map", source, GLIMS_STATUS_BUSY, "global exclusive work refuses"); engine->busy--;
  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PAINTBRUSH, .size = 4, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint point = {2, 2, 1, 0, 0, 0}; GlimsStrokeID stroke = 0;
  NEED (api->stroke_begin (engine, f.id, target, &brush, &point, &stroke, &error) == GLIMS_STATUS_OK, "real stroke fixture starts");
  refuses (&f, f.id, target, "gegl:bump-map", source, GLIMS_STATUS_BUSY, "active stroke refuses");
  NEED (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "stroke fixture ends");
  NEED (api->filter_begin (engine, f.id, target, "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK, "real preview fixture starts");
  refuses (&f, f.id, target, "gegl:bump-map", source, GLIMS_STATUS_BUSY, "another live filter refuses");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "preview fixture aborts"); filter = 0;
  GlimsSelectOptions options = { .struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE };
  GlimsPoint corners[] = {{0, 0}, {8, 8}}; GlimsItemID floating = 0;
  NEED (api->select_shape (engine, f.id, GLIMS_SHAPE_RECTANGLE, corners, 2, &options) == GLIMS_STATUS_OK &&
        api->selection_float (engine, f.id, target, GLIMS_FLOAT_COPY, &floating, &error) == GLIMS_STATUS_OK,
        "a genuine floating selection attaches");
  refuses (&f, f.id, target, "gegl:bump-map", source, GLIMS_STATUS_BUSY, "unresolved floating selection refuses");
  GimpImage *indexed = gimp_create_image (engine->gimp, SIDE, SIDE, GIMP_INDEXED, GIMP_PRECISION_U8_NON_LINEAR, FALSE);
  NEED (indexed && glims_adopt_image (engine, indexed, &indexed_id) == GLIMS_STATUS_OK, "real indexed image fixture is adopted");
  GlimsImageInfo indexed_before = {0}, indexed_after = {0}; GlimsUndoInfo undo_before = {0}, undo_after = {0};
  NEED (api->image_info (engine, indexed_id, &indexed_before) == GLIMS_STATUS_OK &&
        api->image_undo_info (engine, indexed_id, &undo_before) == GLIMS_STATUS_OK, "indexed refusal captures its own native facts/history");
  refuses (&f, indexed_id, target, "gegl:bump-map", source, GLIMS_STATUS_UNSUPPORTED, "indexed image refuses before attempting a snapshot");
  CHECK (api->image_info (engine, indexed_id, &indexed_after) == GLIMS_STATUS_OK &&
         api->image_undo_info (engine, indexed_id, &undo_after) == GLIMS_STATUS_OK &&
         !memcmp (&indexed_before, &indexed_after, sizeof indexed_before) && !memcmp (&undo_before, &undo_after, sizeof undo_before),
         "indexed refusal preserves its actual native image facts/history");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (indexed_id) api->image_close (engine, indexed_id);
  clear_error (&error); fixture_close (&other); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
history_guards (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  for (guint mode = 0; mode < 3; mode++) {
    Fixture f = {0}; char *error = NULL; GlimsFilterID filter = 0;
    gboolean blocked = FALSE;
    NEED (fixture_open (engine, &f, TRUE), "history-guard fixture starts with a real ramp");
    if (mode == 0) { gimp_image_undo_disable (f.image); blocked = TRUE; }
    else if (mode == 1) { gimp_image_undo_freeze (f.image); blocked = TRUE; }
    else {
      blocked = gimp_image_undo_group_start (f.image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "History guard fixture");
      NEED (blocked, "outer Undo group starts before Begin");
    }
    refuses (&f, f.id, item_id (f.target), "gegl:bump-map", item_id (f.source), GLIMS_STATUS_BUSY,
             "disabled/frozen/grouped history refuses Begin with zero output and no session");
    if (mode == 0) gimp_image_undo_enable (f.image);
    else if (mode == 1) gimp_image_undo_thaw (f.image);
    else gimp_image_undo_group_end (f.image);
    blocked = FALSE;
    NEED (begin (&f, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK,
          "valid preview begins before the history state changes");
    guint8 stored[BYTES], after[BYTES]; GlimsUndoInfo history = {0};
    NEED (read_pixels (f.target, FALSE, stored), "pre-commit stored pixels are captured");
    if (mode == 0) { gimp_image_undo_disable (f.image); blocked = TRUE; }
    else if (mode == 1) { gimp_image_undo_freeze (f.image); blocked = TRUE; }
    else {
      blocked = gimp_image_undo_group_start (f.image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "History guard fixture");
      NEED (blocked, "outer Undo group starts after the preview");
    }
    NEED (api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK,
          "blocked commit captures its actual native history state");
    CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_BUSY &&
           g_hash_table_contains (engine->filters, GINT_TO_POINTER (filter)),
           "history becoming unavailable refuses Commit and retains the cancellable session");
    clear_error (&error);
    CHECK (read_pixels (f.target, FALSE, after) && !memcmp (stored, after, BYTES) && undo_equal (engine, f.id, &history),
           "refused Commit neither merges pixels nor changes blocked history");
    if (mode == 1) {
      gimp_image_undo_thaw (f.image); blocked = FALSE;
      NEED (api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK,
            "thawing captures the enabled pre-retry history");
      NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK,
            "same retained preview can commit after history becomes ready"); filter = 0;
      GlimsUndoInfo committed = {0};
      CHECK (read_pixels (f.target, FALSE, after) && memcmp (stored, after, BYTES) &&
             api->image_undo_info (engine, f.id, &committed) == GLIMS_STATUS_OK && committed.undo_count == history.undo_count + 1,
             "retry merges the ramp with exactly one Undo, without replaying a failed merge");
      NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "retried commit is undoable");
      CHECK (read_pixels (f.target, FALSE, after) && !memcmp (stored, after, BYTES),
             "one Undo restores the exact pixels from before the refused Commit");
    } else {
      GlimsFilterID finished = filter;
      NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
            "Abort remains allowed while history is disabled or grouped"); filter = 0;
      CHECK (!g_hash_table_contains (engine->filters, GINT_TO_POINTER (finished)) &&
             read_pixels (f.target, FALSE, after) && !memcmp (stored, after, BYTES) && undo_equal (engine, f.id, &history),
             "cancellation removes the session without touching stored pixels/history");
    }
cleanup:
    if (filter) api->filter_abort (engine, filter);
    if (blocked) {
      if (mode == 0) gimp_image_undo_enable (f.image);
      else if (mode == 1) gimp_image_undo_thaw (f.image);
      else gimp_image_undo_group_end (f.image);
    }
    clear_error (&error); fixture_close (&f);
  }
  return GLIMS_STATUS_OK;
}

static GlimsStatus
extra_source_types (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  for (guint kind = 0; kind < 3; kind++) {
    Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL; gchar *before = NULL, *after = NULL;
    GimpDrawable *input = NULL; GeglBuffer *raw = NULL; guint8 *pixels = NULL;
    GlimsItemID source = 0; guint8 preview[BYTES]; GlimsUndoInfo history = {0};
    NEED (fixture_open (engine, &f, FALSE), "advertised-source fixture opens");
    if (kind == 0) {
      NEED (api->layer_mask_add (engine, f.id, item_id (f.source), GLIMS_MASK_WHITE, FALSE, &source, &error) == GLIMS_STATUS_OK,
            "attached layer-mask input is created");
    } else if (kind == 1) {
      NEED (api->select_command (engine, f.id, GLIMS_SELECT_ALL, 0, &error) == GLIMS_STATUS_OK &&
            api->channel_from_selection (engine, f.id, "Saved height channel", &source, &error) == GLIMS_STATUS_OK,
            "saved-channel input is genuinely attached");
    } else {
      GimpText *text = g_object_new (GIMP_TYPE_TEXT, "text", "T", "font", gimp_context_get_font (gimp_get_user_context (engine->gimp)), "font-size", 8.0, NULL);
      GimpLayer *layer = gimp_text_layer_new (f.image, text); g_object_unref (text);
      NEED (layer && gimp_image_add_layer (f.image, layer, NULL, 0, FALSE), "editable text input attaches without rasterization"); source = item_id (layer);
    }
    input = glims_lookup_drawable (glims_lookup_image (engine, f.id), source);
    NEED (input != NULL, "source resolves as an attached drawable");
    raw = gimp_drawable_get_buffer (input); NEED (raw != NULL, "advertised source has native pixel storage"); g_object_ref (raw);
    GeglRectangle extent = *gegl_buffer_get_extent (raw);
    gsize bytes = (gsize) extent.width * extent.height * 4; pixels = g_malloc (bytes);
    gegl_buffer_get (raw, &extent, 1, babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    before = g_compute_checksum_for_data (G_CHECKSUM_SHA256, pixels, bytes);
    NEED (api->image_undo_info (engine, f.id, &history) == GLIMS_STATUS_OK && begin (&f, source, &filter, &error) == GLIMS_STATUS_OK &&
          read_pixels (f.target, TRUE, preview), "mask/channel/text source preview is accepted and renders");
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "advertised-source preview aborts"); filter = 0;
    GeglBuffer *current = gimp_drawable_get_buffer (input);
    NEED (current && gegl_rectangle_equal (&extent, gegl_buffer_get_extent (current)), "reading the source preserves native pixel geometry");
    gegl_buffer_get (current, &extent, 1, babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    after = g_compute_checksum_for_data (G_CHECKSUM_SHA256, pixels, bytes);
    CHECK (!strcmp (before, after) && undo_equal (engine, f.id, &history), "source bytes and history are unchanged by preview/abort");
    if (kind == 2) {
      GlimsLayerSourceInfo info = { .struct_size = sizeof info };
      CHECK (api->layer_source_info (engine, f.id, source, &info, NULL) == GLIMS_STATUS_OK &&
             info.source_kind == GLIMS_LAYER_TEXT && !info.is_rasterized && info.has_source, "reading editable text retains its editable source flags");
    }
cleanup:
    if (filter) api->filter_abort (engine, filter);
    g_free (pixels); g_clear_object (&raw); g_free (before); g_free (after); clear_error (&error); fixture_close (&f);
  }
  return GLIMS_STATUS_OK;
}

static gboolean retained_text (Fixture *f) {
  GlimsLayerSourceInfo info = { .struct_size = sizeof info };
  return api->layer_source_info (f->engine, f->id, item_id (f->target), &info, NULL) == GLIMS_STATUS_OK &&
         info.source_kind == GLIMS_LAYER_TEXT && info.is_rasterized && info.has_source;
}

static GlimsStatus
rasterized_target (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL; guint8 original[BYTES], committed[BYTES], actual[BYTES];
  NEED (fixture_open (engine, &f, TRUE), "rasterized-target fixture opens with a ramp");
  GimpText *text = g_object_new (GIMP_TYPE_TEXT, "text", "T", "font", gimp_context_get_font (gimp_get_user_context (engine->gimp)), "font-size", 8.0, NULL);
  GimpLayer *layer = gimp_text_layer_new (f.image, text); g_object_unref (text);
  NEED (layer && gimp_image_add_layer (f.image, layer, NULL, 0, FALSE), "real text target attaches"); f.target = layer;
  NEED (api->layer_command (engine, f.id, item_id (layer), GLIMS_LAYER_RASTERIZE, NULL, &error) == GLIMS_STATUS_OK && retained_text (&f),
        "explicit rasterization retains the text source in a pixel-behaving target");
  write_pixels (layer, TRUE, FALSE);
  NEED (read_pixels (layer, FALSE, original) && begin (&f, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
        api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "already-rasterized retained text accepts a merged aux commit"); filter = 0;
  CHECK (read_pixels (layer, FALSE, committed) && memcmp (original, committed, BYTES) && retained_text (&f), "merge changes actual pixels and preserves rasterized/retained flags");
  NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "rasterized-target aux commit undoes in one step");
  CHECK (read_pixels (layer, FALSE, actual) && !memcmp (original, actual, BYTES) && retained_text (&f), "Undo restores exact pixels without reviving or discarding text source");
  NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "rasterized-target aux commit redoes");
  CHECK (read_pixels (layer, FALSE, actual) && !memcmp (committed, actual, BYTES) && retained_text (&f), "Redo restores merged pixels and retained text flags");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f); return GLIMS_STATUS_OK;
}

static GlimsStatus
source_offset (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL; guint8 first[BYTES], moved[BYTES], raw[BYTES];
  NEED (fixture_open (engine, &f, TRUE) && read_pixels (f.target, FALSE, raw) &&
        begin (&f, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK && read_pixels (f.target, TRUE, first), "offset fixture renders an unshifted nontrivial ramp");
  CHECK (memcmp (raw, first, BYTES) != 0, "offset comparison starts from a visible ramp response");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "unshifted preview aborts"); filter = 0;
  GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (f.source)); GeglRectangle extent = *gegl_buffer_get_extent (buffer);
  gimp_item_set_offset (GIMP_ITEM (f.source), 7, -3);
  CHECK (gegl_rectangle_equal (&extent, gegl_buffer_get_extent (buffer)), "ordinary layer move leaves native buffer coordinates unchanged");
  NEED (begin (&f, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK && read_pixels (f.target, TRUE, moved), "offset source remains accepted");
  CHECK (!memcmp (first, moved, BYTES), "item offset adds no hidden height-map translation to native buffer coordinates");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f); return GLIMS_STATUS_OK;
}

static gpointer
forbid_sparse_pixels (GeglTileSource *source, GeglTileCommand command, gint x, gint y, gint z, gpointer data)
{
  if (command == GEGL_TILE_GET || command == GEGL_TILE_SET || command == GEGL_TILE_COPY) {
    fprintf (stderr, "FAIL sparse budget fixture attempted pixel materialization (command %d)\n", command);
    fflush (NULL); _Exit (3); /* Fail safely before a regression can allocate the logical image. */
  }
  return gegl_tile_handler_source_command (GEGL_TILE_HANDLER (source), command, x, y, z, data);
}

static GlimsStatus
snapshot_budget (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GimpLayer *large = NULL; GeglBuffer *buffer = NULL; GeglTileHandler *guard = NULL;
  gboolean attached = FALSE, guarded = FALSE; char *error = NULL; gchar *before = NULL, *after = NULL; GlimsFilterID filter = -123;
  NEED (fixture_open (engine, &f, FALSE), "sparse budget fixture opens a tiny target image");
  /* Native layer construction creates an unfilled sparse GeglBuffer; no fill, copy or read of this layer is requested. */
  large = gimp_layer_new (f.image, 32768, 4097, gimp_image_get_layer_format (f.image, TRUE), "Sparse over-budget source", 1, GIMP_LAYER_MODE_NORMAL);
  NEED (large != NULL, "unfilled sparse virtual source constructs"); buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (large));
  guard = g_object_new (GEGL_TYPE_TILE_HANDLER, NULL); GEGL_TILE_SOURCE (guard)->command = forbid_sparse_pixels;
  gegl_buffer_add_handler (buffer, guard); guarded = TRUE;
  gimp_item_set_visible (GIMP_ITEM (large), FALSE, FALSE);
  attached = gimp_image_add_layer (f.image, large, NULL, 0, FALSE); NEED (attached, "huge logical source is hidden and attached without pixel access");
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  CHECK ((guint64) extent->width * extent->height * babl_format_get_bytes_per_pixel (gegl_buffer_get_format (buffer)) > GLIMS_MAX_PIXEL_BUFFER_BYTES,
         "actual native logical byte count exceeds 512 MiB");
  before = fingerprint (&f);
  GlimsStatus status = glims_filter_begin_with_source (engine, f.id, item_id (f.target), "gegl:bump-map", item_id (large), &filter, &error);
  CHECK (status == GLIMS_STATUS_FAILED && filter == 0 && error && strstr (error, "512"), "512 MiB cap refuses with zero output before any sparse pixel materialization");
  after = fingerprint (&f);
  CHECK (before && after && !strcmp (before, after) && g_hash_table_size (engine->filters) == 0, "budget refusal preserves tiny target/source facts and history with no session");
cleanup:
  if (filter > 0) api->filter_abort (engine, filter);
  if (guarded) gegl_buffer_remove_handler (buffer, guard);
  g_clear_object (&guard); if (large && !attached) g_object_unref (large);
  g_free (before); g_free (after); clear_error (&error); fixture_close (&f); return GLIMS_STATUS_OK;
}

static GlimsStatus
merged_xcf (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; GlimsImageID reopened = 0; char *error = NULL;
  gchar *path = g_build_filename (work_dir, "merged-bump-map.xcf", NULL); guint8 pixels[BYTES], actual[BYTES], projection[BYTES], saved_projection[BYTES];
  NEED (fixture_open (engine, &f, TRUE) && begin (&f, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
        api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "XCF fixture commits a real ramp into target pixels"); filter = 0;
  NEED (read_pixels (f.target, FALSE, pixels) && api->image_render (engine, f.id, 1, (GlimsRect) {0, 0, SIDE, SIDE}, projection, SIDE * 4) == GLIMS_STATUS_OK &&
        api->image_save (engine, f.id, path, &error) == GLIMS_STATUS_OK && api->image_open (engine, path, &reopened, &error) == GLIMS_STATUS_OK,
        "merged snapshot result saves and reopens through the native XCF facade");
  GlimsLayerInfo rows[8] = {{0}}; int32_t count = 0; GlimsItemID target = 0;
  NEED (api->image_layers (engine, reopened, rows, 8, &count) == GLIMS_STATUS_OK && count > 0 && count <= 8, "reopened native layer list is complete");
  for (gint i = 0; i < count; i++) if (!strcmp (rows[i].name, "RGBA target")) target = rows[i].id;
  NEED (target > 0, "reopened target is found by its exact fixture name, not old session IDs");
  GimpDrawable *drawable = glims_lookup_drawable (glims_lookup_image (engine, reopened), target); int32_t effects = -1;
  CHECK (drawable && GIMP_IS_LAYER (drawable) && read_pixels (GIMP_LAYER (drawable), FALSE, actual) && !memcmp (pixels, actual, BYTES), "XCF preserves every merged target RGBA byte exactly");
  CHECK (api->drawable_effects (engine, reopened, target, NULL, 0, &effects) == GLIMS_STATUS_OK && effects == 0, "reopened target contains no phantom aux-dependent effect");
  CHECK (api->image_render (engine, reopened, 1, (GlimsRect) {0, 0, SIDE, SIDE}, saved_projection, SIDE * 4) == GLIMS_STATUS_OK &&
         !memcmp (projection, saved_projection, BYTES), "XCF projection matches the committed image exactly");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (reopened) api->image_close (engine, reopened);
  g_free (path); clear_error (&error); fixture_close (&f); return GLIMS_STATUS_OK;
}

static GlimsStatus
precision_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  for (guint gray = 0; gray < 2; gray++) {
    Fixture f = { .engine = engine }; GeglNode *node = NULL; GeglBuffer *copy = NULL; char *error = NULL;
    GimpImage *image = gimp_create_image (engine->gimp, SIDE, SIDE, gray ? GIMP_GRAY : GIMP_RGB, GIMP_PRECISION_FLOAT_LINEAR, FALSE);
    NEED (image && glims_adopt_image (engine, image, &f.id) == GLIMS_STATUS_OK, "native linear-float precision image is adopted");
    f.image = image; f.source = add_layer (image, "Float source", FALSE, FALSE);
    NEED (f.source != NULL, "native-format float source attaches");
    gfloat values[SIDE * SIDE * 4];
    for (guint i = 0; i < G_N_ELEMENTS (values); i += 4) {
      values[i] = 0.234567f; values[i + 1] = 0.456789f; values[i + 2] = 0.678901f; values[i + 3] = 0.432109f;
    }
    GeglBuffer *raw = gimp_drawable_get_buffer (GIMP_DRAWABLE (f.source));
    gegl_buffer_set (raw, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("RGBA float"), values, GEGL_AUTO_ROWSTRIDE);
    NEED (glims_filter_input_snapshot (engine, glims_lookup_image (engine, f.id), item_id (f.source), &node, &error) == GLIMS_STATUS_OK,
          "snapshot helper accepts native RGB/gray float source");
    gegl_node_get (node, "buffer", &copy, NULL);
    NEED (copy != NULL, "float snapshot node owns a buffer");
    CHECK (gegl_buffer_get_format (copy) == gegl_buffer_get_format (raw), "snapshot retains the exact native Babl format and color space");
    gfloat expected[8], actual[8];
    gegl_buffer_get (raw, GEGL_RECTANGLE (0, 0, 2, 1), 1, babl_format ("RGBA float"), expected, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    gegl_buffer_get (copy, GEGL_RECTANGLE (0, 0, 2, 1), 1, babl_format ("RGBA float"), actual, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    CHECK (!memcmp (expected, actual, sizeof actual) && fabs (actual[3] - 0.432109f) < 1e-7,
           "native RGB/gray float snapshot preserves non-u8 precision and alpha");
cleanup:
    g_clear_object (&copy); g_clear_object (&node); clear_error (&error); fixture_close (&f);
  }
  return GLIMS_STATUS_OK;
}

typedef struct { Fixture fixture; } PublicFixture;
static GlimsStatus public_setup (GlimsEngine *engine, gpointer data) {
  PublicFixture *p = data; return fixture_open (engine, &p->fixture, FALSE) ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}
static GlimsStatus public_cleanup (GlimsEngine *engine, gpointer data) {
  (void) engine; PublicFixture *p = data; fixture_close (&p->fixture); return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  work_dir = argv[1];
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL; GlimsFilterID filter = 0x12345678;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof (GlimsEngineAPI) || !api->filter_begin_with_source) return 2;
  CHECK (api->filter_begin_with_source (NULL, 1, 1, "gegl:bump-map", 2, &filter, &error) == GLIMS_STATUS_NOT_RUNNING && filter == 0,
         "public slot147 resets output even with a nonrunning engine"); clear_error (&error);
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed"); clear_error (&error); g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, flat_and_commit, NULL) == GLIMS_STATUS_OK, "flat/ramp suite executes on engine thread");
  CHECK (glims_engine_call (engine, snapshot_independence, NULL) == GLIMS_STATUS_OK, "COW/lifetime suite executes on engine thread");
  CHECK (glims_engine_call (engine, existing_effects_and_cycles, NULL) == GLIMS_STATUS_OK, "effect-order/self/group suite executes on engine thread");
  CHECK (glims_engine_call (engine, refusal_cases, NULL) == GLIMS_STATUS_OK, "refusal suite executes on engine thread");
  CHECK (glims_engine_call (engine, history_guards, NULL) == GLIMS_STATUS_OK, "Begin/Commit history guards execute on engine thread");
  CHECK (glims_engine_call (engine, precision_cases, NULL) == GLIMS_STATUS_OK, "native precision suite executes on engine thread");
  CHECK (glims_engine_call (engine, extra_source_types, NULL) == GLIMS_STATUS_OK, "advertised read-input types execute on the engine thread");
  CHECK (glims_engine_call (engine, rasterized_target, NULL) == GLIMS_STATUS_OK, "retained rasterized target executes on the engine thread");
  CHECK (glims_engine_call (engine, source_offset, NULL) == GLIMS_STATUS_OK, "source buffer-coordinate policy executes on the engine thread");
  CHECK (glims_engine_call (engine, snapshot_budget, NULL) == GLIMS_STATUS_OK, "guarded sparse budget fixture executes on the engine thread");
  CHECK (glims_engine_call (engine, merged_xcf, NULL) == GLIMS_STATUS_OK, "merged XCF fixture executes on the engine thread");
  PublicFixture public = {0};
  if (glims_engine_call (engine, public_setup, &public) == GLIMS_STATUS_OK) {
    /* Host-thread RPC only: no direct native object access here. */
    GlimsLayerInfo rows[4] = {{0}}; int32_t count = 0;
    CHECK (api->image_layers (engine, public.fixture.id, rows, 4, &count) == GLIMS_STATUS_OK && count == 3,
           "public slot147 fixture exposes exact target/source/background order");
    if (count == 3) {
      filter = 0;
      CHECK (api->filter_begin_with_source (engine, public.fixture.id, rows[0].id, "gegl:bump-map", rows[1].id, &filter, &error) == GLIMS_STATUS_OK && filter > 0,
             "public slot147 host-thread marshaler begins a valid snapshot preview");
      if (filter) CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "public snapshot preview aborts through the existing API");
      clear_error (&error);
    }
  } else CHECK (FALSE, "public slot147 fixture setup succeeds");
  glims_engine_call (engine, public_cleanup, &public);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}

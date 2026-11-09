/*
 * Conformance tests for facade slot 130, adjustment_layer_new, through the
 * public facade header only.
 *
 *   glims-adjustment-layer-tests LIBRARY WORK_DIR
 *
 * The existing adapter is loaded with dlopen() exactly as the app does:
 * nothing is linked against it, no Engine/ private header is included, no
 * DYLD shim is used. One line per check; the summary reports the honest
 * failure count and the exit status is non-zero when any check failed.
 */
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "glims_engine.h"

#define IMG_W    16
#define IMG_H    16
#define MAX_ROWS 8

static const GlimsEngineAPI *api;
static GlimsEngine          *engine;
static int                   checks, failures, skips;

#define CHECK(condition, ...)                 \
  do {                                        \
    checks++;                                 \
    if (condition) printf ("ok    ");        \
    else { printf ("FAIL  "); failures++; }   \
    printf (__VA_ARGS__);                     \
    printf ("\n");                            \
    fflush (stdout);                          \
  } while (0)

/* An honest skip is reported but never counted as a pass or a failure. */
#define SKIP(...)                             \
  do {                                        \
    skips++;                                  \
    printf ("skip  ");                        \
    printf (__VA_ARGS__);                     \
    printf ("\n");                            \
    fflush (stdout);                          \
  } while (0)

/* State snapshot: composite, layer ids/order, undo/redo, dirty, selected
 * layers and the native engine version, compared exactly. */
typedef struct {
  uint8_t        pixels[IMG_W * IMG_H * 4];
  GlimsLayerInfo layers[MAX_ROWS];
  int32_t        layer_count;
  GlimsUndoInfo  undo;
  GlimsImageInfo info;
  GlimsItemID    selected[MAX_ROWS];
  int32_t        selected_count;
  char           engine_version[32];
} Snapshot;

static void
snapshot_take (GlimsImageID image, Snapshot *s)
{
  memset (s, 0, sizeof *s);
  api->image_render (engine, image, 1.0, (GlimsRect) { 0, 0, IMG_W, IMG_H }, s->pixels, IMG_W * 4);
  api->image_layers (engine, image, s->layers, MAX_ROWS, &s->layer_count);
  api->image_undo_info (engine, image, &s->undo);
  api->image_info (engine, image, &s->info);
  api->image_selected_layers (engine, image, s->selected, MAX_ROWS, &s->selected_count);
  snprintf (s->engine_version, sizeof s->engine_version, "%s", api->engine_version (engine));
}

static bool
row_same (const GlimsLayerInfo *a, const GlimsLayerInfo *b)
{
  return a->id == b->id && a->parent == b->parent && a->depth == b->depth && a->kind == b->kind &&
         strcmp (a->name, b->name) == 0 && strcmp (a->mode, b->mode) == 0 &&
         a->visible == b->visible && a->has_mask == b->has_mask && a->selected == b->selected &&
         a->opacity == b->opacity && a->bounds.x == b->bounds.x && a->bounds.y == b->bounds.y &&
         a->bounds.width == b->bounds.width && a->bounds.height == b->bounds.height &&
         a->filter_count == b->filter_count;
}

static bool
snapshot_same (const Snapshot *a, const Snapshot *b)
{
  int32_t i;

  if (memcmp (a->pixels, b->pixels, sizeof a->pixels) != 0 || a->layer_count != b->layer_count)
    return false;
  for (i = 0; i < a->layer_count; i++)
    if (! row_same (&a->layers[i], &b->layers[i])) return false;
  if (a->undo.undo_count != b->undo.undo_count || a->undo.redo_count != b->undo.redo_count ||
      strcmp (a->undo.next_undo, b->undo.next_undo) != 0 ||
      strcmp (a->undo.next_redo, b->undo.next_redo) != 0)
    return false;
  if (a->info.width != b->info.width || a->info.height != b->info.height ||
      a->info.layer_count != b->info.layer_count || a->info.dirty != b->info.dirty ||
      strcmp (a->info.precision, b->info.precision) != 0)
    return false;
  if (a->selected_count != b->selected_count) return false;
  for (i = 0; i < a->selected_count; i++)
    if (a->selected[i] != b->selected[i]) return false;
  return strcmp (a->engine_version, b->engine_version) == 0;
}

static GlimsItemID
first_layer (GlimsImageID image)
{
  GlimsLayerInfo row;
  int32_t        count = 0;

  if (api->image_layers (engine, image, &row, 1, &count) != GLIMS_STATUS_OK || count < 1)
    return 0;
  return row.id;
}

/* Every composite pixel within `tol` of (r, g, b) and fully opaque. */
static bool
composite_is (GlimsImageID image, int r, int g, int b, int tol)
{
  uint8_t px[IMG_W * IMG_H * 4];
  size_t  i;

  if (api->image_render (engine, image, 1.0, (GlimsRect) { 0, 0, IMG_W, IMG_H }, px, IMG_W * 4) != GLIMS_STATUS_OK)
    return false;
  for (i = 0; i < sizeof px; i += 4)
    if (abs (px[i] - r) > tol || abs (px[i + 1] - g) > tol || abs (px[i + 2] - b) > tol || px[i + 3] != 255)
      return false;
  return true;
}

static GlimsImageID
new_white_image (void)
{
  GlimsFillSettings fill = { .struct_size = sizeof fill, .mode = GLIMS_FILL_SELECTION,
                             .color = { 1, 1, 1, 1 }, .opacity = 1 };
  GlimsImageID      image = 0;

  if (api->image_new (engine, IMG_W, IMG_H, &image, NULL) != GLIMS_STATUS_OK)
    return 0;
  api->fill (engine, image, (GlimsPoint) { 1, 1 }, &fill, NULL);
  return image;
}

static int32_t
undo_depth (GlimsImageID image)
{
  GlimsUndoInfo info;

  return api->image_undo_info (engine, image, &info) == GLIMS_STATUS_OK ? info.undo_count : -1;
}

/* One refused adjustment_layer_new: the status must match, both outputs
 * reset to 0, and the whole snapshot exactly unchanged. */
static void
expect_refusal (GlimsImageID image, GlimsItemID parent, int32_t index,
                const char *operation, const char *name, GlimsStatus want, const char *label)
{
  Snapshot      before, after;
  GlimsItemID   layer = -1;
  GlimsEffectID effect = -1;
  GlimsStatus   status;
  char         *error = NULL;

  snapshot_take (image, &before);
  status = api->adjustment_layer_new (engine, image, parent, index, operation, name, &layer, &effect, &error);
  snapshot_take (image, &after);
  CHECK (status == want && layer == 0 && effect == 0 && snapshot_same (&before, &after),
         "%s: status %d, outputs reset, state exactly unchanged [%s]",
         label, (int) want, error ? error : "");
  api->free_string (error);
}

/* Positive: white background + gegl:invert-gamma, undo/redo, XCF reopen. */
static void
test_positive_invert (const char *work)
{
  GlimsImageID   image, bg, layer = 0, reopened = 0;
  GlimsEffectID  effect = 0;
  GlimsLayerInfo rows[MAX_ROWS];
  GlimsEffectInfo effects[4];
  GlimsEffectChange change;
  GlimsUndoInfo  undo;
  Snapshot       base;
  int32_t        n = 0, count = 0, depth;
  char          *error = NULL, xcf[1024];
  GlimsStatus    status;

  image = new_white_image ();
  CHECK (image != 0 && composite_is (image, 255, 255, 255, 1), "a white background layer");
  bg = first_layer (image);
  snapshot_take (image, &base);
  depth = undo_depth (image);

  status = api->adjustment_layer_new (engine, image, 0, 0, "gegl:invert-gamma", "Invert", &layer, &effect, &error);
  CHECK (status == GLIMS_STATUS_OK && layer > 0 && effect > 0, "adjustment_layer_new creates group and effect%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  CHECK (api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 &&
         rows[0].id == layer && rows[0].kind == GLIMS_LAYER_GROUP &&
         strcmp (rows[0].mode, "pass-through") == 0 && rows[0].parent == 0 && rows[0].depth == 0 &&
         rows[0].filter_count == 1 && strcmp (rows[0].name, "Invert") == 0 && rows[1].id == bg,
         "an empty pass-through group with one filter sits on top, named");
  CHECK (api->drawable_effects (engine, image, layer, effects, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && effects[0].id == effect && strcmp (effects[0].operation, "gegl:invert-gamma") == 0 &&
         effects[0].enabled, "the effect is readable via drawable_effects with the returned id");
  CHECK (composite_is (image, 0, 0, 0, 1), "invert-gamma over white composites full black");

  change = (GlimsEffectChange) { .struct_size = sizeof change, .properties = GLIMS_EFFECT_ENABLED, .enabled = false };
  CHECK (api->effect_change (engine, image, layer, effect, &change, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == depth + 2 && composite_is (image, 255, 255, 255, 1),
         "a hidden effect leaves the background unchanged (white)");
  change.enabled = true;
  CHECK (api->effect_change (engine, image, layer, effect, &change, NULL) == GLIMS_STATUS_OK &&
         composite_is (image, 0, 0, 0, 1), "re-enabled: full black again");

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 1 &&
         rows[0].id == bg && composite_is (image, 255, 255, 255, 1),
         "one undo removes the whole group and its effect, back to white");
  CHECK (api->image_undo_info (engine, image, &undo) == GLIMS_STATUS_OK &&
         undo.undo_count == base.undo.undo_count && strcmp (undo.next_undo, base.undo.next_undo) == 0 &&
         undo.redo_count == 1, "history clean: the undo stack is exactly the pre-creation one");
  CHECK (api->drawable_effects (engine, image, layer, effects, 4, &count) == GLIMS_STATUS_NOT_FOUND,
         "the undone group's id is stale for the effect read");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 &&
         rows[0].id == layer &&
         api->drawable_effects (engine, image, layer, effects, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && effects[0].id == effect && composite_is (image, 0, 0, 0, 1),
         "redo restores the same layer and effect ids, black again");

  snprintf (xcf, sizeof xcf, "%s/adjustment.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_close (engine, image) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK && reopened != 0,
         "the image with the adjustment group saves and reopens as XCF");
  if (reopened)
    {
      CHECK (api->image_layers (engine, reopened, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 &&
             rows[0].kind == GLIMS_LAYER_GROUP && strcmp (rows[0].mode, "pass-through") == 0 &&
             rows[0].filter_count == 1 &&
             api->drawable_effects (engine, reopened, rows[0].id, effects, 4, &count) == GLIMS_STATUS_OK &&
             count == 1 && strcmp (effects[0].operation, "gegl:invert-gamma") == 0 &&
             composite_is (reopened, 0, 0, 0, 1),
             "reopened: pass-through group, one invert-gamma effect, black composite");
      CHECK (api->image_close (engine, reopened) == GLIMS_STATUS_OK &&
             api->image_close (engine, reopened) == GLIMS_STATUS_NOT_FOUND,
             "the reopened image closes cleanly; closing twice is reported");
    }
}

/* Generic filter edit on a layer: preview, abort, commit, one undo. */
static void
test_filter_edit_lifecycle (void)
{
  GlimsImageID        image, bg;
  GlimsFilterID       filter = 0;
  GlimsFilterProperty *props;
  GlimsLayerInfo      rows[MAX_ROWS];
  Snapshot            during, after;
  GlimsItemID         layer = -1;
  GlimsEffectID       effect = -1;
  double              brightness_min = 0;
  int32_t             n = 0, pn = 0, i, depth;
  bool                found = false;
  char               *error = NULL;

  image = new_white_image ();
  if (! image) { CHECK (false, "no image for the filter edit test"); return; }
  bg = first_layer (image);

  CHECK (api->filter_operation_properties (engine, "gegl:brightness-contrast", NULL, 0, &pn) == GLIMS_STATUS_OK &&
         pn > 0, "gegl:brightness-contrast exposes %d editable properties", pn);
  props = calloc ((size_t) pn, sizeof *props);
  if (props && api->filter_operation_properties (engine, "gegl:brightness-contrast", props, pn, &pn) == GLIMS_STATUS_OK)
    for (i = 0; i < pn; i++)
      if (strcmp (props[i].name, "brightness") == 0 && props[i].kind == GLIMS_FILTER_VALUE_NUMBER)
        { brightness_min = props[i].min; found = true; }
  CHECK (found, "the parametric brightness property is discovered with its bounds");
  free (props);

  depth = undo_depth (image);
  CHECK (api->filter_begin (engine, image, bg, "gegl:brightness-contrast", &filter, &error) == GLIMS_STATUS_OK &&
         filter != 0, "the generic filter session opens%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  snapshot_take (image, &during);
  CHECK (api->adjustment_layer_new (engine, image, 0, 0, "gegl:invert-gamma", NULL, &layer, &effect, NULL) ==
         GLIMS_STATUS_BUSY && layer == 0 && effect == 0,
         "an open filter preview refuses adjustment_layer_new with BUSY, outputs reset");
  snapshot_take (image, &after);
  CHECK (snapshot_same (&during, &after), "the refused call during the preview changed nothing");

  CHECK (api->filter_set_double (engine, filter, "brightness", brightness_min) == GLIMS_STATUS_OK &&
         ! composite_is (image, 255, 255, 255, 1), "setting brightness to its bound previews a darker composite");
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK && undo_depth (image) == depth &&
         composite_is (image, 255, 255, 255, 1), "abort leaves no undo and restores the white preview");
  CHECK (api->filter_begin (engine, image, bg, "gegl:brightness-contrast", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, filter, "brightness", brightness_min) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, filter, NULL) == GLIMS_STATUS_OK && undo_depth (image) == depth + 1 &&
         ! composite_is (image, 255, 255, 255, 1), "commit applies the edit as exactly one undo step");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == depth &&
         composite_is (image, 255, 255, 255, 1), "one undo removes the committed filter edit, white again");
  CHECK (api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 1,
         "the filter edit never touched the layer tree");
  api->image_close (engine, image);
}

/* Refusals: invalid/nonexistent/aux op, bad parent, bad index, busy states. */
static void
test_refusals (void)
{
  GlimsImageID        image, bg, dead = 0, floating = 0;
  GlimsOperationInfo *ops;
  GlimsFloatingState  fs = { .struct_size = sizeof fs };
  GlimsStrokeID       stroke = 0;
  GlimsFilterID       filter = 0;
  GlimsBrushSettings  brush = { .struct_size = sizeof brush, .size = 4, .opacity = 1, .tool = GLIMS_PAINT_PAINTBRUSH };
  GlimsStrokePoint    point = { 4, 4, 1.0, 0, 0, 0 };
  int32_t             total = 0, i;
  bool                have_displace = false;

  image = new_white_image ();
  if (! image) { CHECK (false, "no image for the refusal test"); return; }
  bg = first_layer (image);

  expect_refusal (image, 0, 0, NULL, NULL, GLIMS_STATUS_INVALID_ARGUMENT, "a NULL operation");
  expect_refusal (image, 0, 0, "", NULL, GLIMS_STATUS_INVALID_ARGUMENT, "an empty operation");
  expect_refusal (image, 0, 0, "gegl:no-such-operation", NULL, GLIMS_STATUS_UNSUPPORTED, "a nonexistent operation");
  expect_refusal (image, 0, 0, "gegl:invert-gamma", "", GLIMS_STATUS_INVALID_ARGUMENT, "an empty name");
  expect_refusal (image, bg, 0, "gegl:invert-gamma", NULL, GLIMS_STATUS_INVALID_ARGUMENT, "a non-group parent layer");
  expect_refusal (image, 424242, 0, "gegl:invert-gamma", NULL, GLIMS_STATUS_NOT_FOUND, "a parent id outside the image");
  expect_refusal (image, 0, -1, "gegl:invert-gamma", NULL, GLIMS_STATUS_INVALID_ARGUMENT, "a negative index");
  expect_refusal (image, 0, 99, "gegl:invert-gamma", NULL, GLIMS_STATUS_INVALID_ARGUMENT, "an out-of-range index");

  CHECK (api->create_group (engine, image, 0, 0, "Dead", &dead, NULL) == GLIMS_STATUS_OK && dead > 0 &&
         api->layer_command (engine, image, dead, GLIMS_LAYER_DELETE, NULL, NULL) == GLIMS_STATUS_OK,
         "a group can be created and deleted again");
  expect_refusal (image, dead, 0, "gegl:invert-gamma", NULL, GLIMS_STATUS_NOT_FOUND, "a dead parent id");

  /* An auxiliary-input operation is refused, when this engine offers it. */
  if (api->filter_operations (engine, NULL, 0, &total) == GLIMS_STATUS_OK && total > 0)
    {
      ops = calloc ((size_t) total, sizeof *ops);
      if (ops && api->filter_operations (engine, ops, total, &total) == GLIMS_STATUS_OK)
        for (i = 0; i < total; i++)
          if (strcmp (ops[i].name, "gegl:displace") == 0)
            {
              have_displace = true;
              if (ops[i].support == GLIMS_FILTER_OP_AUX_INPUT)
                expect_refusal (image, 0, 0, "gegl:displace", NULL, GLIMS_STATUS_UNSUPPORTED,
                                "an aux-input operation (gegl:displace)");
              else
                SKIP ("gegl:displace is offered as support %u, not an aux case on this engine", ops[i].support);
            }
      free (ops);
    }
  if (! have_displace)
    SKIP ("gegl:displace is not in this engine's operation list; aux refusal untested");

  CHECK (api->select_command (engine, image, GLIMS_SELECT_ALL, 0, NULL) == GLIMS_STATUS_OK &&
         api->selection_float (engine, image, bg, GLIMS_FLOAT_COPY, &floating, NULL) == GLIMS_STATUS_OK &&
         floating != 0 && api->image_floating_selection (engine, image, &fs) == GLIMS_STATUS_OK && fs.active,
         "a floating selection is active");
  expect_refusal (image, 0, 0, "gegl:invert-gamma", NULL, GLIMS_STATUS_BUSY, "an active floating selection");
  CHECK (api->floating_command (engine, image, floating, GLIMS_FLOATING_DISCARD, NULL, NULL) == GLIMS_STATUS_OK &&
         api->image_floating_selection (engine, image, &fs) == GLIMS_STATUS_OK && ! fs.active,
         "the floating selection is resolved again");

  CHECK (api->stroke_begin (engine, image, bg, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK && stroke != 0,
         "a stroke is open");
  expect_refusal (image, 0, 0, "gegl:invert-gamma", NULL, GLIMS_STATUS_BUSY, "a busy stroke");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "the stroke ends");

  CHECK (api->filter_begin (engine, image, bg, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK && filter != 0,
         "a filter preview is open");
  expect_refusal (image, 0, 0, "gegl:invert-gamma", NULL, GLIMS_STATUS_BUSY, "an open preview");
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "the preview is aborted");

  CHECK (api->image_close (engine, image) == GLIMS_STATUS_OK &&
         api->image_close (engine, image) == GLIMS_STATUS_NOT_FOUND,
         "the refusal-test image closes cleanly; closing twice is reported");
}

/* Nested placement: exact order, one undo, selection restored on undo. */
static void
test_nested_placement (void)
{
  GlimsImageID   image, bg, outer = 0, nested = 0, toplevel = 0;
  GlimsEffectID  neffect = 0, teffect = 0;
  GlimsLayerInfo rows[MAX_ROWS];
  GlimsItemID    sel_before[MAX_ROWS], sel_after[MAX_ROWS];
  int32_t        n = 0, sb = 0, sa = 0;

  image = new_white_image ();
  if (! image) { CHECK (false, "no image for the nested test"); return; }
  bg = first_layer (image);
  CHECK (api->create_group (engine, image, 0, 0, "Outer", &outer, NULL) == GLIMS_STATUS_OK && outer > 0,
         "an outer group is created");
  CHECK (api->image_selected_layers (engine, image, sel_before, MAX_ROWS, &sb) == GLIMS_STATUS_OK &&
         sb == 1 && sel_before[0] == outer, "the new group is selected");

  CHECK (api->adjustment_layer_new (engine, image, outer, 0, "gegl:invert-gamma", NULL, &nested, &neffect, NULL) ==
         GLIMS_STATUS_OK && nested > 0 && neffect > 0, "a nested adjustment layer is created (NULL name)");
  CHECK (api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 3 &&
         rows[0].id == outer && rows[0].depth == 0 && rows[1].id == nested && rows[1].parent == outer &&
         rows[1].depth == 1 && rows[1].kind == GLIMS_LAYER_GROUP && rows[1].filter_count == 1 &&
         rows[1].name[0] != '\0' && rows[2].id == bg && ! composite_is (image, 255, 255, 255, 1),
         "exact depth-first order outer, nested, background; composite no longer white");
  CHECK (api->adjustment_layer_new (engine, image, 0, 1, "gegl:brightness-contrast", "Top", &toplevel, &teffect, NULL) ==
         GLIMS_STATUS_OK && api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 4 &&
         rows[0].id == outer && rows[1].id == nested && rows[2].id == toplevel && rows[2].parent == 0 &&
         rows[2].depth == 0 && rows[3].id == bg,
         "a top-level placement at index 1 lands exactly between outer and background");

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 3 &&
         rows[0].id == outer && rows[1].id == nested && rows[2].id == bg,
         "one undo removes only the top-level placement, exact order restored");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 &&
         rows[0].id == outer && rows[1].id == bg && composite_is (image, 255, 255, 255, 1) &&
         api->image_selected_layers (engine, image, sel_after, MAX_ROWS, &sa) == GLIMS_STATUS_OK &&
         sa == sb && memcmp (sel_before, sel_after, (size_t) sa * sizeof (GlimsItemID)) == 0,
         "one more undo removes the nested group; the selection is exactly as before");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 4 &&
         rows[1].id == nested && rows[2].id == toplevel,
         "two redos restore both placements with their ids in order");
  CHECK (api->image_close (engine, image) == GLIMS_STATUS_OK, "the nested-test image closes");
}

int
main (int argc, char **argv)
{
  GlimsEngineGetAPIFunction get_api;
  GlimsEngineConfig config = { 0 };
  char user_dir[1024], cache_dir[1024];
  char *error = NULL;
  void *library;

  if (argc != 3)
    {
      fprintf (stderr, "usage: %s LIBRARY WORK_DIR\n", argv[0]);
      return 2;
    }

  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (! library)
    {
      fprintf (stderr, "dlopen: %s\n", dlerror ());
      return 1;
    }
  get_api = (GlimsEngineGetAPIFunction) dlsym (library, "glims_engine_get_api");
  api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  CHECK (api && api->api_version == GLIMS_ENGINE_API_VERSION,
         "library serves facade api_version %u explicitly", GLIMS_ENGINE_API_VERSION);
  CHECK (api && api->struct_size >= sizeof (GlimsEngineAPI),
         "library struct_size %u covers sizeof (GlimsEngineAPI) %zu explicitly",
         api ? api->struct_size : 0, sizeof (GlimsEngineAPI));
  CHECK (api && api->adjustment_layer_new != NULL, "slot 130 adjustment_layer_new is present");
  if (! api || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI) || ! api->adjustment_layer_new)
    return 1;
  CHECK (get_api (GLIMS_ENGINE_API_VERSION + 1) == NULL, "an unknown facade version is refused");

  snprintf (user_dir, sizeof user_dir, "%s/user", argv[2]);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", argv[2]);
  mkdir (user_dir, 0755);
  mkdir (cache_dir, 0755);

  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  config.on_event        = NULL;
  CHECK (api->start (&config, &engine, &error) == GLIMS_STATUS_OK, "engine starts%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  if (! engine)
    return 1;
  printf ("      engine %s\n", api->engine_version (engine));

  test_positive_invert (argv[2]);
  test_filter_edit_lifecycle ();
  test_refusals ();
  test_nested_placement ();

  api->stop (engine);
  printf ("adjustment-layer-tests: %d checks, %d failures, %d skips\n", checks, failures, skips);
  return failures ? 1 : 0;
}

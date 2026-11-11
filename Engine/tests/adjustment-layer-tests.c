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
  bool           valid;
} Snapshot;

static void
snapshot_take (GlimsImageID image, Snapshot *s)
{
  memset (s, 0, sizeof *s);
  const char *version = api->engine_version (engine);
  s->valid = version &&
    api->image_render (engine, image, 1.0, (GlimsRect) { 0, 0, IMG_W, IMG_H }, s->pixels, IMG_W * 4) == GLIMS_STATUS_OK &&
    api->image_layers (engine, image, s->layers, MAX_ROWS, &s->layer_count) == GLIMS_STATUS_OK &&
    s->layer_count >= 0 && s->layer_count <= MAX_ROWS &&
    api->image_undo_info (engine, image, &s->undo) == GLIMS_STATUS_OK &&
    api->image_info (engine, image, &s->info) == GLIMS_STATUS_OK &&
    api->image_selected_layers (engine, image, s->selected, MAX_ROWS, &s->selected_count) == GLIMS_STATUS_OK &&
    s->selected_count >= 0 && s->selected_count <= MAX_ROWS;
  if (version) snprintf (s->engine_version, sizeof s->engine_version, "%s", version);
  CHECK (s->valid, "all snapshot reads succeed within their fixed capacities");
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

  if (!a->valid || !b->valid || a->layer_count < 0 || a->layer_count > MAX_ROWS ||
      b->layer_count < 0 || b->layer_count > MAX_ROWS ||
      a->selected_count < 0 || a->selected_count > MAX_ROWS ||
      b->selected_count < 0 || b->selected_count > MAX_ROWS) return false;
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
  GlimsImageID      image = 0;

  if (api->image_new (engine, IMG_W, IMG_H, &image, NULL) != GLIMS_STATUS_OK)
    return 0;
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
         label, (int) status, error ? error : "");
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
  if (!image) return;
  bg = first_layer (image);
  snapshot_take (image, &base);
  CHECK (!base.info.dirty && base.undo.undo_count == 0, "the creation baseline is clean with empty history");
  depth = undo_depth (image);

  status = api->adjustment_layer_new (engine, image, 0, 0, "gegl:invert-gamma", "Invert", &layer, &effect, &error);
  CHECK (status == GLIMS_STATUS_OK && layer > 0 && effect > 0, "adjustment_layer_new creates group and effect%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  if (status != GLIMS_STATUS_OK) { api->image_close (engine, image); return; }

  CHECK (api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 &&
         rows[0].id == layer && rows[0].kind == GLIMS_LAYER_GROUP &&
         strcmp (rows[0].mode, "pass-through") == 0 && rows[0].parent == 0 && rows[0].depth == 0 &&
         rows[0].filter_count == 1 && strcmp (rows[0].name, "Invert") == 0 && rows[1].id == bg,
         "an empty pass-through group with one filter sits on top, named");
  CHECK (api->drawable_effects (engine, image, layer, effects, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && effects[0].id == effect && strcmp (effects[0].operation, "gegl:invert-gamma") == 0 &&
         effects[0].enabled, "the effect is readable via drawable_effects with the returned id");
  CHECK (composite_is (image, 0, 0, 0, 1), "invert-gamma over white composites full black");


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

  change = (GlimsEffectChange) { .struct_size = sizeof change, .properties = GLIMS_EFFECT_ENABLED, .enabled = false };
  CHECK (api->effect_change (engine, image, layer, effect, &change, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == depth + 2 && composite_is (image, 255, 255, 255, 1),
         "a hidden effect leaves the background unchanged (white)");
  change.enabled = true;
  CHECK (api->effect_change (engine, image, layer, effect, &change, NULL) == GLIMS_STATUS_OK &&
         composite_is (image, 0, 0, 0, 1), "re-enabled: full black again");


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
  GlimsImageID        image;
  GlimsItemID         target = 0;
  GlimsEffectID       target_effect = 0;
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
  GlimsStatus created = api->adjustment_layer_new (engine, image, 0, 0,
      "gegl:brightness-contrast", "Editable Adjustment", &target, &target_effect, NULL);
  CHECK (created == GLIMS_STATUS_OK && target > 0 && target_effect > 0, "an adjustment group is ready for effect editing");
  if (created != GLIMS_STATUS_OK) { api->image_close (engine, image); return; }

  CHECK (api->filter_operation_properties (engine, "gegl:brightness-contrast", NULL, 0, &pn) == GLIMS_STATUS_OK &&
         pn > 0, "gegl:brightness-contrast exposes %d editable properties", pn);
  if (pn <= 0 || pn > 4096) { api->image_close (engine, image); return; }
  int32_t capacity = pn;
  props = calloc ((size_t) capacity, sizeof *props);
  if (props && api->filter_operation_properties (engine, "gegl:brightness-contrast", props, capacity, &pn) == GLIMS_STATUS_OK
      && pn >= 0 && pn <= capacity)
    for (i = 0; i < pn; i++)
      if (strcmp (props[i].name, "brightness") == 0 && props[i].kind == GLIMS_FILTER_VALUE_NUMBER)
        { brightness_min = props[i].min; found = true; }
  CHECK (found, "the parametric brightness property is discovered with its bounds");
  free (props);
  if (!found) { api->image_close (engine, image); return; }

  depth = undo_depth (image);
  CHECK (api->filter_edit_begin (engine, image, target, target_effect, &filter, &error) == GLIMS_STATUS_OK &&
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
  CHECK (api->filter_edit_begin (engine, image, target, target_effect, &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, filter, "brightness", brightness_min) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, filter, NULL) == GLIMS_STATUS_OK && undo_depth (image) == depth + 1 &&
         ! composite_is (image, 255, 255, 255, 1), "commit applies the edit as exactly one undo step");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == depth &&
         composite_is (image, 255, 255, 255, 1), "one undo removes the committed filter edit, white again");
  CHECK (api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 && rows[0].id == target,
         "the effect edit preserves the adjustment group and background");
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

/* ---- Tonal operations: gimp:levels, gimp:curves, gimp:color-balance,
 * gimp:hue-saturation, admitted as adjustment layers. Each carries an
 * owned-config get/set pair on the live filter session; the shape of the
 * lifecycle is shared, so one driver walks a per-operation vtable. */
#define BASE_R 180
#define BASE_G 90
#define BASE_B 40

typedef struct {
  const char *operation;
  /* Typed get verifies the factory default; typed set installs a visibly
   * non-neutral config; typed get reads the committed value back. */
  bool (*is_neutral)   (GlimsFilterID filter);
  bool (*apply_change) (GlimsFilterID filter);
  bool (*is_changed)   (GlimsFilterID filter);
} TonalOp;

static GlimsImageID
new_colored_image (void)
{
  uint8_t      px[IMG_W * IMG_H * 4];
  GlimsImageID image = 0;
  size_t       i;

  for (i = 0; i < sizeof px; i += 4)
    {
      px[i] = BASE_R; px[i + 1] = BASE_G; px[i + 2] = BASE_B; px[i + 3] = 255;
    }
  if (api->image_from_pixels (engine, IMG_W, IMG_H, px, sizeof px, &image, NULL) != GLIMS_STATUS_OK)
    return 0;
  return image;
}

/* The selected drawable's raw stored pixels still read as the flat base
 * color: the effect never merged into the layer beneath the group. */
static bool
base_pixels_intact (GlimsImageID image, GlimsItemID base)
{
  GlimsPixelBuffer buffer;
  bool             ok = false;
  size_t           i;

  memset (&buffer, 0, sizeof buffer);
  if (api->layer_select (engine, image, base) != GLIMS_STATUS_OK ||
      api->image_copy_pixels (engine, image, false, &buffer, NULL) != GLIMS_STATUS_OK)
    return false;
  if (buffer.pixels && buffer.byte_count == IMG_W * IMG_H * 4 &&
      buffer.bounds.width == IMG_W && buffer.bounds.height == IMG_H)
    {
      ok = true;
      for (i = 0; i < buffer.byte_count; i += 4)
        if (abs (buffer.pixels[i] - BASE_R) > 2 || abs (buffer.pixels[i + 1] - BASE_G) > 2 ||
            abs (buffer.pixels[i + 2] - BASE_B) > 2 || buffer.pixels[i + 3] != 255)
          ok = false;
    }
  api->free_pixels (buffer.pixels);
  return ok;
}

static bool
composite_base (GlimsImageID image)
{
  return composite_is (image, BASE_R, BASE_G, BASE_B, 2);
}

static bool
composite_changed (GlimsImageID image)
{
  uint8_t px[IMG_W * IMG_H * 4];
  bool changed = false;

  /* A render failure or lost opacity is not evidence of a tonal edit. */
  if (api->image_render (engine, image, 1.0, (GlimsRect) { 0, 0, IMG_W, IMG_H },
                         px, IMG_W * 4) != GLIMS_STATUS_OK)
    return false;
  for (size_t i = 0; i < sizeof px; i += 4)
    {
      if (px[i + 3] != 255) return false;
      changed |= abs (px[i] - BASE_R) > 2 || abs (px[i + 1] - BASE_G) > 2 ||
                 abs (px[i + 2] - BASE_B) > 2;
    }
  return changed;
}

/* gimp:levels */

static bool
levels_channel_neutral (const GlimsLevelsChannel *c)
{
  return c->low_input == 0 && c->high_input == 1 && c->gamma == 1 &&
         c->low_output == 0 && c->high_output == 1;
}

static bool
levels_is_neutral (GlimsFilterID filter)
{
  GlimsLevelsSettings s = { .struct_size = sizeof s };

  return api->filter_levels_get (engine, filter, &s, NULL) == GLIMS_STATUS_OK &&
         s.trc == GLIMS_COLOR_TRC_LINEAR && ! s.clamp_input && ! s.clamp_output &&
         levels_channel_neutral (&s.value) && levels_channel_neutral (&s.red) &&
         levels_channel_neutral (&s.green) && levels_channel_neutral (&s.blue) &&
         levels_channel_neutral (&s.alpha);
}

static bool
levels_apply_change (GlimsFilterID filter)
{
  GlimsLevelsSettings s = { .struct_size = sizeof s };

  if (api->filter_levels_get (engine, filter, &s, NULL) != GLIMS_STATUS_OK)
    return false;
  s.value.gamma = 2.0;
  return api->filter_levels_set (engine, filter, &s, NULL) == GLIMS_STATUS_OK;
}

static bool
levels_is_changed (GlimsFilterID filter)
{
  GlimsLevelsSettings s = { .struct_size = sizeof s };

  return api->filter_levels_get (engine, filter, &s, NULL) == GLIMS_STATUS_OK &&
         s.value.gamma == 2.0;
}

/* gimp:curves */

static const GlimsCurvePoint CURVE_DARKEN[2] = {
  { 0, 0, GLIMS_CURVE_POINT_SMOOTH },
  { 1, 0.5, GLIMS_CURVE_POINT_SMOOTH }
};

static bool
curves_is_neutral (GlimsFilterID filter)
{
  GlimsCurvesSnapshot s;
  bool                ok;

  memset (&s, 0, sizeof s);
  s.struct_size = sizeof s;
  ok = api->filter_curves_get (engine, filter, &s, NULL) == GLIMS_STATUS_OK &&
       s.trc == GLIMS_COLOR_TRC_PERCEPTUAL && s.value.kind == GLIMS_CURVE_KIND_SMOOTH &&
       s.value.point_count == 2 && s.value.points &&
       s.value.points[0].x == 0 && s.value.points[0].y == 0 &&
       s.value.points[1].x == 1 && s.value.points[1].y == 1;
  api->free_curves_snapshot (&s);
  return ok;
}

static bool
curves_apply_change (GlimsFilterID filter)
{
  GlimsCurveEdit      edit = { .struct_size = sizeof edit,
                               .channel = GLIMS_CURVE_CHANNEL_VALUE,
                               .mode = GLIMS_CURVE_EDIT_SMOOTH_POINTS,
                               .point_count = 2, .points = CURVE_DARKEN };
  GlimsCurvesSnapshot out;
  bool                ok;

  memset (&out, 0, sizeof out);
  out.struct_size = sizeof out;
  ok = api->filter_curves_edit (engine, filter, &edit, &out, NULL) == GLIMS_STATUS_OK;
  api->free_curves_snapshot (&out);
  return ok;
}

static bool
curves_is_changed (GlimsFilterID filter)
{
  GlimsCurvesSnapshot s;
  bool                ok;

  memset (&s, 0, sizeof s);
  s.struct_size = sizeof s;
  ok = api->filter_curves_get (engine, filter, &s, NULL) == GLIMS_STATUS_OK &&
       s.value.point_count == 2 && s.value.points &&
       s.value.points[1].x == 1 && s.value.points[1].y == 0.5;
  api->free_curves_snapshot (&s);
  return ok;
}

/* gimp:color-balance */

static bool
balance_range_zero (const GlimsColorBalanceRange *r)
{
  return r->cyan_red == 0 && r->magenta_green == 0 && r->yellow_blue == 0;
}

static bool
balance_is_neutral (GlimsFilterID filter)
{
  GlimsColorBalanceSettings s = { .struct_size = sizeof s };

  return api->filter_color_balance_get (engine, filter, &s, NULL) == GLIMS_STATUS_OK &&
         s.preserve_luminosity == 1 && balance_range_zero (&s.shadows) &&
         balance_range_zero (&s.midtones) && balance_range_zero (&s.highlights);
}

static bool
balance_apply_change (GlimsFilterID filter)
{
  GlimsColorBalanceSettings s = { .struct_size = sizeof s };

  if (api->filter_color_balance_get (engine, filter, &s, NULL) != GLIMS_STATUS_OK)
    return false;
  s.midtones.cyan_red = 0.5;
  return api->filter_color_balance_set (engine, filter, &s, NULL) == GLIMS_STATUS_OK;
}

static bool
balance_is_changed (GlimsFilterID filter)
{
  GlimsColorBalanceSettings s = { .struct_size = sizeof s };

  return api->filter_color_balance_get (engine, filter, &s, NULL) == GLIMS_STATUS_OK &&
         s.midtones.cyan_red == 0.5;
}

/* gimp:hue-saturation */

static bool
hue_range_zero (const GlimsHueSaturationRange *r)
{
  return r->hue == 0 && r->saturation == 0 && r->lightness == 0;
}

static bool
hue_is_neutral (GlimsFilterID filter)
{
  GlimsHueSaturationSettings s = { .struct_size = sizeof s };

  return api->filter_hue_saturation_get (engine, filter, &s, NULL) == GLIMS_STATUS_OK &&
         s.overlap == 0 && hue_range_zero (&s.master) && hue_range_zero (&s.red) &&
         hue_range_zero (&s.yellow) && hue_range_zero (&s.green) && hue_range_zero (&s.cyan) &&
         hue_range_zero (&s.blue) && hue_range_zero (&s.magenta);
}

static bool
hue_apply_change (GlimsFilterID filter)
{
  GlimsHueSaturationSettings s = { .struct_size = sizeof s };

  if (api->filter_hue_saturation_get (engine, filter, &s, NULL) != GLIMS_STATUS_OK)
    return false;
  s.master.saturation = -1.0;
  return api->filter_hue_saturation_set (engine, filter, &s, NULL) == GLIMS_STATUS_OK;
}

static bool
hue_is_changed (GlimsFilterID filter)
{
  GlimsHueSaturationSettings s = { .struct_size = sizeof s };

  return api->filter_hue_saturation_get (engine, filter, &s, NULL) == GLIMS_STATUS_OK &&
         s.master.saturation == -1.0;
}

static const TonalOp TONAL_OPS[4] = {
  { "gimp:levels",          levels_is_neutral,  levels_apply_change,  levels_is_changed  },
  { "gimp:curves",          curves_is_neutral,  curves_apply_change,  curves_is_changed  },
  { "gimp:color-balance",   balance_is_neutral, balance_apply_change, balance_is_changed },
  { "gimp:hue-saturation",  hue_is_neutral,     hue_apply_change,     hue_is_changed     }
};

/* The shared lifecycle on an RGB image: neutral pass-through group, one
 * creation undo, typed get/set preview without touching base pixels,
 * abort with no undo, one-step commit, undo/redo, XCF round trip that
 * stays re-editable. */
static void
test_tonal_adjustment (const TonalOp *op, const char *work)
{
  GlimsImageID    image, reopened = 0;
  GlimsItemID     bg = 0, layer = 0;
  GlimsEffectID   effect = 0;
  GlimsFilterID   filter = 0;
  GlimsLayerInfo  rows[MAX_ROWS];
  GlimsEffectInfo effects[4];
  uint8_t         changed_px[IMG_W * IMG_H * 4] = { 0 };
  uint8_t         committed_px[IMG_W * IMG_H * 4] = { 0 };
  int32_t         n = 0, count = 0, depth;
  bool            ok;
  char           *error = NULL, xcf[1024];

  image = new_colored_image ();
  CHECK (image != 0 && composite_base (image), "%s: a colored opaque base", op->operation);
  if (! image) return;
  bg = first_layer (image);
  depth = undo_depth (image);

  ok = api->adjustment_layer_new (engine, image, 0, 0, op->operation, "Tonal",
                                  &layer, &effect, &error) == GLIMS_STATUS_OK && layer > 0 && effect > 0;
  CHECK (ok, "%s: admitted as an adjustment layer%s%s", op->operation,
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  if (! ok) { api->image_close (engine, image); return; }

  CHECK (api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 &&
         rows[0].id == layer && rows[0].kind == GLIMS_LAYER_GROUP &&
         strcmp (rows[0].mode, "pass-through") == 0 && rows[0].parent == 0 && rows[0].depth == 0 &&
         rows[0].filter_count == 1 && rows[1].id == bg,
         "%s: a pass-through group with one filter above the base", op->operation);
  CHECK (api->drawable_effects (engine, image, layer, effects, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && effects[0].id == effect && strcmp (effects[0].operation, op->operation) == 0 &&
         effects[0].enabled, "%s: the committed effect reads back under the returned id", op->operation);
  CHECK (composite_base (image) && undo_depth (image) == depth + 1,
         "%s: the default config is neutral and exactly one undo covers creation", op->operation);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == depth &&
         api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 1 &&
         rows[0].id == bg && composite_base (image),
         "%s: one undo removes the group and restores the base", op->operation);
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == depth + 1 &&
         api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 &&
         rows[0].id == layer &&
         api->drawable_effects (engine, image, layer, effects, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && effects[0].id == effect,
         "%s: redo restores the same group and effect ids", op->operation);

  CHECK (api->filter_edit_begin (engine, image, layer, effect, &filter, &error) == GLIMS_STATUS_OK &&
         filter != 0, "%s: the committed effect opens for editing%s%s", op->operation,
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  if (! filter) { api->image_close (engine, image); return; }

  CHECK (op->is_neutral (filter), "%s: the typed get reports the factory-neutral config", op->operation);
  CHECK (op->apply_change (filter) && composite_changed (image),
         "%s: the typed set previews a changed composite", op->operation);
  CHECK (base_pixels_intact (image, bg), "%s: the preview left the base layer's pixels untouched", op->operation);
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK && undo_depth (image) == depth + 1 &&
         composite_base (image), "%s: abort restores the composite and adds no undo", op->operation);

  CHECK (api->filter_edit_begin (engine, image, layer, effect, &filter, NULL) == GLIMS_STATUS_OK &&
         filter != 0 && op->apply_change (filter) &&
         api->filter_commit (engine, filter, NULL) == GLIMS_STATUS_OK && undo_depth (image) == depth + 2 &&
         composite_changed (image) &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 0, 0, IMG_W, IMG_H },
                            committed_px, IMG_W * 4) == GLIMS_STATUS_OK,
         "%s: commit applies the config as exactly one undo step", op->operation);
  CHECK (base_pixels_intact (image, bg), "%s: the committed effect leaves base pixels untouched", op->operation);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == depth + 1 &&
         composite_base (image), "%s: one undo restores the neutral composite", op->operation);
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == depth + 2 &&
         composite_changed (image) &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 0, 0, IMG_W, IMG_H },
                            changed_px, IMG_W * 4) == GLIMS_STATUS_OK &&
         memcmp (changed_px, committed_px, sizeof changed_px) == 0,
         "%s: redo restores the exact committed composite", op->operation);

  snprintf (xcf, sizeof xcf, "%s/%s-adjustment.xcf", work, op->operation + 5);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_close (engine, image) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK && reopened != 0,
         "%s: the image with its adjustment saves and reopens as XCF", op->operation);
  if (! reopened) return;

  CHECK (api->image_layers (engine, reopened, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 &&
         rows[0].kind == GLIMS_LAYER_GROUP && strcmp (rows[0].mode, "pass-through") == 0 &&
         rows[0].filter_count == 1 &&
         api->drawable_effects (engine, reopened, rows[0].id, effects, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && strcmp (effects[0].operation, op->operation) == 0,
         "%s: reopen keeps the pass-through group and the operation", op->operation);
  {
    uint8_t px[IMG_W * IMG_H * 4];

    CHECK (api->image_render (engine, reopened, 1.0, (GlimsRect) { 0, 0, IMG_W, IMG_H },
                              px, IMG_W * 4) == GLIMS_STATUS_OK &&
           memcmp (px, changed_px, sizeof px) == 0,
           "%s: reopen keeps the adjusted composite output", op->operation);
    CHECK (api->filter_edit_begin (engine, reopened, rows[0].id, effects[0].id, &filter, NULL) == GLIMS_STATUS_OK &&
           filter != 0 && op->is_changed (filter) &&
           api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
           "%s: the reloaded config reads back and remains re-editable", op->operation);
  }
  api->image_close (engine, reopened);
}

/* The adapter gates creation on the image base type: indexed is refused
 * for every operation, grayscale is admitted like RGB — no per-operation
 * color-only carve-out exists in adjustment.c. Each creation must stay
 * neutral and collapse into one undo step on a gray image too. */
static void
test_tonal_grayscale (const TonalOp *op)
{
  GlimsImageID   image;
  GlimsItemID    layer = 0;
  GlimsEffectID  effect = 0;
  GlimsLayerInfo rows[MAX_ROWS];
  uint8_t        before_px[IMG_W * IMG_H * 4] = { 0 }, after_px[IMG_W * IMG_H * 4] = { 0 };
  int32_t        n = 0;
  char          *error = NULL;

  image = new_colored_image ();
  if (! image) { CHECK (false, "%s: no image for the grayscale check", op->operation); return; }
  CHECK (api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_GRAYSCALE, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 0, 0, IMG_W, IMG_H },
                            before_px, IMG_W * 4) == GLIMS_STATUS_OK,
         "%s: the fixture converts to grayscale", op->operation);
  CHECK (api->adjustment_layer_new (engine, image, 0, 0, op->operation, NULL,
                                    &layer, &effect, &error) == GLIMS_STATUS_OK && layer > 0 && effect > 0,
         "%s: grayscale admits the adjustment layer%s%s", op->operation,
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  if (! layer) { api->image_close (engine, image); return; }
  CHECK (api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 2 &&
         rows[0].id == layer && rows[0].kind == GLIMS_LAYER_GROUP &&
         strcmp (rows[0].mode, "pass-through") == 0 && rows[0].filter_count == 1 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 0, 0, IMG_W, IMG_H },
                            after_px, IMG_W * 4) == GLIMS_STATUS_OK &&
         memcmp (before_px, after_px, sizeof before_px) == 0,
         "%s: the grayscale adjustment group is pass-through and neutral", op->operation);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, MAX_ROWS, &n) == GLIMS_STATUS_OK && n == 1,
         "%s: one undo removes the grayscale adjustment", op->operation);
  api->image_close (engine, image);
}

int
main (int argc, char **argv)
{
  GlimsEngineGetAPIFunction get_api;
  GlimsEngineConfig config = { 0 };
  char user_dir[1024], cache_dir[1024];
  char *error = NULL;
  void *library;
  int32_t i;

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
  if (!api || api->api_version != GLIMS_ENGINE_API_VERSION || api->struct_size < sizeof (GlimsEngineAPI))
    { dlclose (library); return 1; }
  CHECK (api->adjustment_layer_new != NULL, "slot 130 adjustment_layer_new is present");
  if (!api->adjustment_layer_new) { dlclose (library); return 1; }
  GlimsItemID absent_layer = 123;
  GlimsEffectID absent_effect = 456;
  CHECK (api->adjustment_layer_new (NULL, 0, 0, 0, "gegl:invert-gamma", NULL,
      &absent_layer, &absent_effect, NULL) == GLIMS_STATUS_NOT_RUNNING && absent_layer == 0 && absent_effect == 0,
      "no running engine resets both prefilled outputs before dispatch");
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
  GlimsImageID indexed = new_white_image ();
  GlimsIndexedSettings quantize = { .struct_size = sizeof quantize,
      .palette = GLIMS_INDEXED_PALETTE_GENERATED, .max_colors = 256,
      .dither = GLIMS_INDEXED_DITHER_NONE, .preservation = GLIMS_INDEXED_PRESERVE_EDITABLE };
  CHECK (indexed && api->image_convert_indexed (engine, indexed, &quantize, NULL, 0, NULL) == GLIMS_STATUS_OK,
         "an indexed-image refusal fixture is quantized");
  if (indexed) {
    expect_refusal (indexed, 0, 0, "gegl:invert-gamma", NULL, GLIMS_STATUS_UNSUPPORTED,
                    "indexed images require RGB or grayscale before adjustment creation");
    for (i = 0; i < (int32_t) (sizeof TONAL_OPS / sizeof TONAL_OPS[0]); i++)
      expect_refusal (indexed, 0, 0, TONAL_OPS[i].operation, NULL, GLIMS_STATUS_UNSUPPORTED,
                      TONAL_OPS[i].operation);
    api->image_close (engine, indexed);
  }
  test_nested_placement ();
  for (i = 0; i < (int32_t) (sizeof TONAL_OPS / sizeof TONAL_OPS[0]); i++)
    {
      test_tonal_adjustment (&TONAL_OPS[i], argv[2]);
      test_tonal_grayscale (&TONAL_OPS[i]);
    }

  api->stop (engine);
  printf ("adjustment-layer-tests: %d checks, %d failures, %d skips\n", checks, failures, skips);
  return failures ? 1 : 0;
}

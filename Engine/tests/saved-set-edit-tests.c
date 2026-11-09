/*
 * saved-set-edit-tests.c — deterministic standalone harness for the EDIT
 * facade slot 135: image_item_set_edit, one undoable CREATE/REPLACE/RENAME/
 * REMOVE of one fixed saved set addressed by its current identity token.
 *
 *   saved-set-edit-tests WORK_DIR
 *
 * Test-only file. Same linkage pattern as saved-set-undo-tests.c: it links
 * the adapter objects and GIMP's gimp-console objects directly (no dlopen,
 * no libgimp), includes Engine/engine-private.h, and runs the whole body on
 * the engine thread through one glims_engine_call(). Fixture sets are
 * created ONLY through the engine-internal glims_item_sets_create (the
 * existing pattern); EVERY assertion about editing goes through the facade
 * slot under test (api->image_item_set_edit), with slots 133/134 only to
 * read back tokens/members. No private struct layout is mirrored.
 *
 * Asserted semantics:
 *   - CREATE/REPLACE/RENAME/REMOVE work for ALL THREE kinds (layer,
 *     channel, path) through the token-addressed slot; each successful
 *     mutating call is exactly one undo step, nukes redo and dirties the
 *     image; Undo/Redo restore the previous stored-set state (a restored
 *     set gets a fresh token, the old one stays expired).
 *   - outToken is zeroed before dispatch and on every failure; CREATE/
 *     REPLACE/RENAME success returns the resulting set's token (fresh
 *     after a mutation, the current one after a no-op); REMOVE returns 0.
 *   - No-ops (identical REPLACE, same-name RENAME) return OK with the
 *     current token and zero undo/redo/dirty delta.
 *   - Strict field relevance: CREATE with token != 0, REPLACE with a name,
 *     RENAME with members, REMOVE with extras, unknown op/kind, negative
 *     count, NULL members with count > 0 are all INVALID_ARGUMENT and
 *     change nothing.
 *   - Names: NULL/empty/over-255-byte/invalid-UTF-8/control-character
 *     names are INVALID_ARGUMENT and change nothing.
 *   - Members: id 0 or negative, stale, foreign-image, detached,
 *     wrong-kind or duplicated ids are INVALID_ARGUMENT; 0 never means
 *     the current selection.
 *   - Stale/expired/foreign tokens are NOT_FOUND and never retargeted: a
 *     set recreated under the same name gets a fresh token and the old
 *     token still refuses.
 *   - The write gate: BUSY while a stroke holds the image (outToken 0,
 *     quiet), FAILED while the undo stack is frozen (quiet), NOT_FOUND for
 *     an unknown or closed image, NOT_RUNNING for a NULL engine with
 *     outToken reset to 0.
 *   - Token exhaustion is preflighted before ANY mutation: with the
 *     engine's counter at UINT64_MAX, CREATE/REPLACE refuse FAILED with
 *     zero delta and no set is created.
 *   - Persistence: an XCF save/reopen keeps the sets; the reopened image
 *     lists them with fresh per-runtime tokens and edits them by token.
 */
#include "engine-private.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "core/core-enums.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpitemlist.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimppath.h"
#else
#include "vectors/gimppath.h"
#endif

int main (int argc, char **argv);

#define MAX_ROWS 32

typedef struct
{
  GimpImage   *image;
  GlimsImageID image_id;
  const char  *work;

  GimpLayer *a, *b, *c;
  GimpChannel *chan;
  GimpPath  *path;

  int failures;
} Probe;

static const GlimsEngineAPI *api;
static GlimsEngine *engine_global;

#define CHECK(condition, ...)                     \
  do {                                            \
    if (condition) {                              \
      printf ("ok    ");                          \
    } else {                                      \
      printf ("FAIL  ");                          \
      probe->failures++;                          \
    }                                             \
    printf (__VA_ARGS__);                         \
    printf ("\n");                                \
    fflush (stdout);                              \
  } while (0)

#define FIXTURE(condition, ...)                   \
  do {                                            \
    if (! (condition)) {                          \
      printf ("FIXTURE-FAIL  ");                  \
      printf (__VA_ARGS__);                       \
      printf ("\n");                              \
      fflush (stdout);                            \
      probe->failures++;                          \
      return GLIMS_STATUS_FAILED;                 \
    }                                             \
  } while (0)

typedef struct
{
  gint undo;
  gint redo;
  gint dirty;
} EngineState;

static EngineState
capture_state (GimpImage *image)
{
  EngineState state;

  state.undo  = gimp_undo_stack_get_depth (gimp_image_get_undo_stack (image));
  state.redo  = gimp_undo_stack_get_depth (gimp_image_get_redo_stack (image));
  state.dirty = gimp_image_is_dirty (image);

  return state;
}

static void
check_delta (Probe *probe, EngineState before, EngineState after,
             gint d_undo, gint d_redo, const char *phase, const char *op)
{
  CHECK (after.undo - before.undo == d_undo && after.redo - before.redo == d_redo,
         "[%s] %s: undo %d->%d, redo %d->%d (expected delta %d/%d)",
         phase, op, before.undo, after.undo, before.redo, after.redo, d_undo, d_redo);
}

static void
check_quiet (Probe *probe, EngineState before, EngineState after,
             const char *phase, const char *op)
{
  CHECK (after.undo == before.undo && after.redo == before.redo && after.dirty == before.dirty,
         "[%s] %s: no undo/redo/dirty change (undo %d->%d, redo %d->%d, dirty %d->%d)",
         phase, op, before.undo, after.undo, before.redo, after.redo, before.dirty, after.dirty);
}

/* ---- facade calls under test ------------------------------------------- */

static GlimsStatus
edit_set (GlimsImageID image, uint32_t op, uint32_t kind, uint64_t token,
          const char *name, const GlimsItemID *members, int32_t count,
          uint64_t *outToken, char **error)
{
  return api->image_item_set_edit (engine_global, image, op, kind, token, name,
                                   members, count, outToken, error);
}

static GlimsStatus
list_sets (GlimsImageID image, GlimsItemSetInfo *rows, int32_t capacity, int32_t *count)
{
  return api->image_item_sets (engine_global, image, rows, capacity, count);
}

static GlimsStatus
members_of (GlimsImageID image, uint64_t token, GlimsItemID *out, int32_t capacity, int32_t *count)
{
  return api->image_item_set_members (engine_global, image, token, out, capacity, count);
}

static int
find_row (const GlimsItemSetInfo *rows, int32_t count, const char *name)
{
  for (int32_t i = 0; i < count; i++)
    if (strcmp (rows[i].display_name, name) == 0)
      return i;
  return -1;
}

/* Token of the row with `name` in the last list, or 0. */
static uint64_t
token_of_row (const GlimsItemSetInfo *rows, int32_t count, const char *name)
{
  int idx = find_row (rows, count, name);
  return idx >= 0 ? rows[idx].token : 0;
}

static GlimsBrushSettings
brush_for (double size)
{
  GlimsBrushSettings brush = { .struct_size = sizeof (GlimsBrushSettings), .size = size,
                               .opacity = 1.0, .tool = GLIMS_PAINT_PAINTBRUSH,
                               .hardness = -1.0, .rate = -1.0, .flow = -1.0, .exposure = -1.0 };
  return brush;
}

/* ---- fixture builders --------------------------------------------------- */

static GimpLayer *
add_layer (GimpImage *image, const char *name)
{
  GimpLayer *layer = gimp_layer_new (image, 64, 64,
                                     gimp_image_get_layer_format (image, TRUE),
                                     name, GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL);

  if (! layer)
    return NULL;
  if (! gimp_image_add_layer (image, layer, NULL, -1, TRUE))
    {
      g_object_unref (layer);
      return NULL;
    }
  return layer;
}

static GimpChannel *
add_channel (GimpImage *image, const char *name)
{
  GimpChannel *channel = GIMP_CHANNEL (gimp_item_duplicate (GIMP_ITEM (gimp_image_get_mask (image)),
                                                            GIMP_TYPE_CHANNEL));

  gimp_item_set_visible (GIMP_ITEM (channel), FALSE, FALSE);
  gimp_object_set_name (GIMP_OBJECT (channel), name);
  if (! gimp_image_add_channel (image, channel, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE))
    {
      g_object_unref (channel);
      return NULL;
    }
  return channel;
}

static GimpPath *
add_path (GimpImage *image, const char *name)
{
  GimpPath *path = gimp_path_new (image, name);

  if (! gimp_image_add_path (image, path, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE))
    {
      g_object_unref (path);
      return NULL;
    }
  return path;
}

static void
free_error (char **error)
{
  if (*error)
    {
      api->free_string (*error);
      *error = NULL;
    }
}

static GlimsStatus
run_all (GlimsEngine *engine, gpointer data)
{
  Probe *probe = data;
  GimpImage *image;
  GlimsItemSetInfo rows[MAX_ROWS];
  GlimsItemID ids[8];
  int32_t count = -1;
  char *error = NULL;
  GlimsStatus status;
  EngineState s0, s1;
  uint64_t token = 0, out = 0, old = 0, empty_token = 0;
  char path[1024];
  GlimsItemID members_ab[2], members_c[1], members_ch[1], members_p[1];

  engine_global = engine;

  status = api->image_new (engine, 64, 64, &probe->image_id, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "image_new: %s", error ? error : "?");
  free_error (&error);
  image = probe->image = glims_lookup_image (engine, probe->image_id)->image;

  probe->a = add_layer (image, "e-a");
  probe->b = add_layer (image, "e-b");
  probe->c = add_layer (image, "e-c");
  probe->chan = add_channel (image, "e-chan");
  probe->path = add_path (image, "e-path");
  FIXTURE (probe->a && probe->b && probe->c && probe->chan && probe->path, "fixture items built");
  gimp_image_flush (image);

  members_ab[0] = gimp_item_get_id (GIMP_ITEM (probe->a));
  members_ab[1] = gimp_item_get_id (GIMP_ITEM (probe->b));
  members_c[0]  = gimp_item_get_id (GIMP_ITEM (probe->c));
  members_ch[0] = gimp_item_get_id (GIMP_ITEM (probe->chan));
  members_p[0]  = gimp_item_get_id (GIMP_ITEM (probe->path));

  /* Clean savepoint for the dirty assertions. */
  snprintf (path, sizeof path, "%s/edit-clean.xcf", probe->work);
  status = api->image_save (engine, probe->image_id, path, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "save clean baseline: %s", error ? error : "?");
  free_error (&error);
  CHECK (! gimp_image_is_dirty (image), "[setup] savepoint starts clean");

  /* ---------- Phase A: CREATE, all three kinds, via the facade ---------- */

  s0 = capture_state (image);
  out = 77;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                     "e-layers", members_ab, 2, &out, &error);
  CHECK (status == GLIMS_STATUS_OK && out != 0, "[create layer] CREATE e-layers {A,B}: %s (token %llu)",
         error ? error : "ok", (unsigned long long) out);
  free_error (&error);
  token = out;
  s1 = capture_state (image);
  check_delta (probe, s0, s1, 1, -s0.redo, "create layer", "CREATE");
  CHECK (gimp_image_is_dirty (image), "[create layer] dirty after CREATE");
  count = -1;
  status = list_sets (probe->image_id, rows, MAX_ROWS, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 1 && token_of_row (rows, count, "e-layers") == token,
         "[create layer] slot 133 lists e-layers with the returned token");
  count = -1;
  status = members_of (probe->image_id, token, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 2 && ids[0] == members_ab[0] && ids[1] == members_ab[1],
         "[create layer] slot 134 resolves the new token to {A,B}");

  /* Channel and path kinds through the same slot. */
  s0 = capture_state (image);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_CHANNEL, 0,
                     "e-chan-set", members_ch, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_OK && out != 0 && out != token,
         "[create channel] CREATE e-chan-set: %s (token %llu)", error ? error : "ok",
         (unsigned long long) out);
  free_error (&error);
  check_delta (probe, s0, capture_state (image), 1, -s0.redo, "create channel", "CREATE");
  {
    uint64_t token_ch = out;
    count = -1;
    status = members_of (probe->image_id, token_ch, ids, 8, &count);
    CHECK (status == GLIMS_STATUS_OK && count == 1 && ids[0] == members_ch[0],
           "[create channel] channel token resolves its member");
    s0 = capture_state (image);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_PATH, 0,
                       "e-path-set", members_p, 1, &out, &error);
    CHECK (status == GLIMS_STATUS_OK && out != 0, "[create path] CREATE e-path-set: %s",
           error ? error : "ok");
    free_error (&error);
    check_delta (probe, s0, capture_state (image), 1, -s0.redo, "create path", "CREATE");
    count = -1;
    status = members_of (probe->image_id, out, ids, 8, &count);
    CHECK (status == GLIMS_STATUS_OK && count == 1 && ids[0] == members_p[0],
           "[create path] path token resolves its member");
  }

  /* Empty set: explicit members NULL, count 0. */
  s0 = capture_state (image);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                     "e-empty", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_OK && out != 0, "[create empty] CREATE e-empty (count 0): %s",
         error ? error : "ok");
  free_error (&error);
  check_delta (probe, s0, capture_state (image), 1, -s0.redo, "create empty", "CREATE");
  empty_token = out;
  count = -1;
  status = members_of (probe->image_id, empty_token, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 0, "[create empty] empty set resolves to count 0");

  /* ---------- Phase B: CREATE Undo/Redo expire and re-mint tokens -------- */

  s0 = capture_state (image);
  CHECK (api->image_undo (engine, probe->image_id) == GLIMS_STATUS_OK, "[undo] ran");
  s1 = capture_state (image);
  check_delta (probe, s0, s1, -1, 1, "undo", "image_undo");
  count = -1;
  status = list_sets (probe->image_id, rows, MAX_ROWS, &count);
  CHECK (status == GLIMS_STATUS_OK && find_row (rows, count, "e-empty") < 0,
         "[undo] e-empty gone after Undo");
  out = 77;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                     empty_token, NULL, NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && out == 0,
         "[stale] edit with the undone set's token NOT_FOUND, outToken 0");
  free_error (&error);
  s0 = capture_state (image);
  CHECK (api->image_redo (engine, probe->image_id) == GLIMS_STATUS_OK, "[redo] ran");
  count = -1;
  status = list_sets (probe->image_id, rows, MAX_ROWS, &count);
  {
    uint64_t redone = token_of_row (rows, count, "e-empty");
    CHECK (status == GLIMS_STATUS_OK && redone != 0 && redone != empty_token,
           "[redo] e-empty restored under a fresh token (%llu)", (unsigned long long) redone);
  }

  /* ---------- Phase C: REPLACE + no-op + Undo ---------------------------- */

  s0 = capture_state (image);
  out = 0;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REPLACE, GLIMS_ITEM_SET_LAYER,
                     token, NULL, members_c, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_OK && out != 0 && out != token,
         "[replace] REPLACE e-layers {C}: fresh token %llu (old %llu)",
         (unsigned long long) out, (unsigned long long) token);
  free_error (&error);
  old = token;
  token = out;
  check_delta (probe, s0, capture_state (image), 1, -s0.redo, "replace", "REPLACE");
  count = -1;
  status = members_of (probe->image_id, token, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 1 && ids[0] == members_c[0],
         "[replace] new token resolves {C}");
  out = 77;
  count = -1;
  status = members_of (probe->image_id, old, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && count == 0,
         "[replace] old token expired, NOT_FOUND, never retargeted");

  s0 = capture_state (image);
  out = 0;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REPLACE, GLIMS_ITEM_SET_LAYER,
                     token, NULL, members_c, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_OK && out == token, "[replace noop] identical REPLACE: OK, current token %llu",
         (unsigned long long) out);
  free_error (&error);
  check_quiet (probe, s0, capture_state (image), "replace noop", "identical REPLACE");

  s0 = capture_state (image);
  CHECK (api->image_undo (engine, probe->image_id) == GLIMS_STATUS_OK, "[replace undo] ran");
  count = -1;
  status = members_of (probe->image_id, token, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_NOT_FOUND, "[replace undo] replaced-away token expired");
  count = -1;
  status = list_sets (probe->image_id, rows, MAX_ROWS, &count);
  {
    uint64_t back = token_of_row (rows, count, "e-layers");
    CHECK (back != 0 && back != token, "[replace undo] e-layers restored under fresh token %llu",
           (unsigned long long) back);
    if (back)
      {
        count = -1;
        status = members_of (probe->image_id, back, ids, 8, &count);
        CHECK (status == GLIMS_STATUS_OK && count == 2, "[replace undo] original members restored");
        token = back;
      }
  }

  /* ---------- Phase D: RENAME + no-op + conflict ------------------------- */

  s0 = capture_state (image);
  out = 0;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_RENAME, GLIMS_ITEM_SET_LAYER,
                     token, "e-renamed", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_OK && out != 0 && out != token,
         "[rename] RENAME e-layers -> e-renamed: fresh token %llu", (unsigned long long) out);
  free_error (&error);
  old = token;
  token = out;
  check_delta (probe, s0, capture_state (image), 1, -s0.redo, "rename", "RENAME");
  count = -1;
  status = list_sets (probe->image_id, rows, MAX_ROWS, &count);
  CHECK (status == GLIMS_STATUS_OK && find_row (rows, count, "e-renamed") >= 0 &&
         find_row (rows, count, "e-layers") < 0, "[rename] list shows e-renamed, not e-layers");

  s0 = capture_state (image);
  out = 0;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_RENAME, GLIMS_ITEM_SET_LAYER,
                     token, "e-renamed", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_OK && out == token, "[rename noop] same-name RENAME: OK, current token");
  free_error (&error);
  check_quiet (probe, s0, capture_state (image), "rename noop", "same-name RENAME");

  s0 = capture_state (image);
  out = 77;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_RENAME, GLIMS_ITEM_SET_LAYER,
                     token, "e-empty", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0,
         "[rename conflict] RENAME onto existing name refused, token not retargeted");
  free_error (&error);
  check_quiet (probe, s0, capture_state (image), "rename conflict", "rename onto e-empty");
  out = 77;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REPLACE, GLIMS_ITEM_SET_LAYER,
                     old, NULL, members_c, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && out == 0, "[rename stale] pre-rename token refused");
  free_error (&error);

  /* ---------- Phase E: REMOVE + same-name recreation non-retarget -------- */

  s0 = capture_state (image);
  out = 77;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                     token, NULL, NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_OK && out == 0, "[remove] REMOVE e-renamed: OK, outToken 0");
  free_error (&error);
  old = token;
  check_delta (probe, s0, capture_state (image), 1, -s0.redo, "remove", "REMOVE");
  count = -1;
  status = list_sets (probe->image_id, rows, MAX_ROWS, &count);
  CHECK (find_row (rows, count, "e-renamed") < 0, "[remove] set gone from the list");
  out = 77;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                     old, NULL, NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && out == 0, "[remove stale] expired token NOT_FOUND");
  free_error (&error);

  /* Recreate the same name: fresh token, old token never retargeted. */
  s0 = capture_state (image);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                     "e-renamed", members_ab, 2, &out, &error);
  CHECK (status == GLIMS_STATUS_OK && out != 0 && out != old,
         "[recreate] same-name CREATE gets a fresh token %llu (old %llu)",
         (unsigned long long) out, (unsigned long long) old);
  free_error (&error);
  token = out;
  out = 77;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REPLACE, GLIMS_ITEM_SET_LAYER,
                     old, NULL, members_c, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && out == 0,
         "[recreate non-retarget] old token still refuses against the same-named set");
  free_error (&error);

  /* ---------- Phase F: invalid requests, all quiet ----------------------- */

  s0 = capture_state (image);
  out = 77;
  status = edit_set (probe->image_id, 0, GLIMS_ITEM_SET_LAYER, 0, "x", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[invalid op] op 0 refused");
  free_error (&error);
  status = edit_set (probe->image_id, 5, GLIMS_ITEM_SET_LAYER, 0, "x", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[invalid op] op 5 refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, 0, 0, "x", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[invalid kind] kind 0 refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, 4, 0, "x", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[invalid kind] kind 4 refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                     "x", NULL, -1, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[invalid count] negative count refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                     "x", NULL, 2, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[invalid members] NULL members, count 2 refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 42,
                     "x", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[field] CREATE with token != 0 refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REPLACE, GLIMS_ITEM_SET_LAYER,
                     token, "x", members_c, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[field] REPLACE with a name refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_RENAME, GLIMS_ITEM_SET_LAYER,
                     token, "y", members_c, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[field] RENAME with members refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                     token, "x", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[field] REMOVE with a name refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                     token, NULL, members_c, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[field] REMOVE with members refused");
  free_error (&error);
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REPLACE, GLIMS_ITEM_SET_LAYER,
                     0, NULL, members_c, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[field] REPLACE with token 0 refused");
  free_error (&error);
  check_quiet (probe, s0, capture_state (image), "invalid phase", "all refused requests");

  /* Names. */
  s0 = capture_state (image);
  {
    char long_name[300];
    memset (long_name, 'a', 256);
    long_name[256] = '\0';
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       NULL, NULL, 0, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[name] NULL name refused");
    free_error (&error);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "", NULL, 0, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[name] empty name refused");
    free_error (&error);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       long_name, NULL, 0, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[name] 256-byte name refused");
    free_error (&error);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "\xff\xfe", NULL, 0, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[name] invalid UTF-8 refused");
    free_error (&error);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "a\x01""b", NULL, 0, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[name] control character refused");
    free_error (&error);
    /* 255 bytes of valid multi-byte UTF-8 is accepted. */
    {
      char ok_name[256];
      int i;
      for (i = 0; i < 127; i++)
        memcpy (ok_name + 2 * i, "\xc3\xa9", 2);
      ok_name[254] = 'x';
      ok_name[255] = '\0';
      status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                         ok_name, NULL, 0, &out, &error);
      CHECK (status == GLIMS_STATUS_OK && out != 0, "[name] 255-byte UTF-8 name accepted");
      free_error (&error);
      status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                         out, NULL, NULL, 0, &out, &error);
      CHECK (status == GLIMS_STATUS_OK, "[name] cleanup remove of the 255-byte set");
      free_error (&error);
    }
    check_quiet (probe, s0, capture_state (image), "names phase", "only accepted name mutated");
  }

  /* Members. */
  s0 = capture_state (image);
  {
    GlimsItemID zero[1] = { 0 };
    GlimsItemID neg[1] = { -5 };
    GlimsItemID stale[1] = { 999999 };
    GlimsItemID dup[2] = { members_c[0], members_c[0] };
    GlimsItemID wrong_kind[1] = { members_ab[0] };  /* layer in a channel set */
    GimpLayer *temp = gimp_layer_new (image, 8, 8, gimp_image_get_layer_format (image, TRUE),
                                      "e-temp", GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL);
    GlimsItemID detached[1] = { gimp_item_get_id (GIMP_ITEM (temp)) };

    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "e-bad", zero, 1, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[member] id 0 refused (no implicit selection)");
    free_error (&error);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "e-bad", neg, 1, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[member] negative id refused");
    free_error (&error);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "e-bad", stale, 1, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[member] stale id refused");
    free_error (&error);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "e-bad", dup, 2, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[member] duplicate id refused");
    free_error (&error);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_CHANNEL, 0,
                       "e-bad", wrong_kind, 1, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[member] wrong-kind member refused");
    free_error (&error);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "e-bad", detached, 1, &out, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[member] detached member refused");
    free_error (&error);
    g_object_unref (temp);

    /* Foreign member: a layer of a second image. */
    {
      GlimsImageID id2 = 0;
      GimpImage *image2;
      GimpLayer *foreign;
      GlimsItemID foreign_id[1];

      status = api->image_new (engine, 32, 32, &id2, &error);
      FIXTURE (status == GLIMS_STATUS_OK, "second image created");
      free_error (&error);
      image2 = glims_lookup_image (engine, id2)->image;
      foreign = add_layer (image2, "e-foreign");
      FIXTURE (foreign != NULL, "foreign layer built");
      foreign_id[0] = gimp_item_get_id (GIMP_ITEM (foreign));
      status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                         "e-bad", foreign_id, 1, &out, &error);
      CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "[member] foreign-image member refused");
      free_error (&error);
      /* Foreign token: the second image's own set token refused here. */
      {
        GimpItem *fm[1] = { GIMP_ITEM (foreign) };
        uint64_t foreign_token = 0;
        status = glims_item_sets_create (image2, GIMP_TYPE_LAYER, "e-foreign-set", fm, 1, &error);
        FIXTURE (status == GLIMS_STATUS_OK, "foreign fixture set created");
        free_error (&error);
        count = -1;
        status = list_sets (id2, rows, MAX_ROWS, &count);
        FIXTURE (status == GLIMS_STATUS_OK && count == 1, "foreign image lists its set");
        foreign_token = rows[0].token;
        out = 77;
        status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                           foreign_token, NULL, NULL, 0, &out, &error);
        CHECK (status == GLIMS_STATUS_NOT_FOUND && out == 0,
               "[token] another image's token refused on this image");
        free_error (&error);
      }
      CHECK (api->image_close (engine, id2) == GLIMS_STATUS_OK, "[teardown] second image closed");
    }
    check_quiet (probe, s0, capture_state (image), "members phase", "all refused requests");
  }

  /* Unknown image; NULL engine resets outToken. */
  out = 77;
  status = edit_set (9999, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                     "x", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && out == 0, "[unknown image] NOT_FOUND, outToken 0");
  free_error (&error);
  out = 77;
  status = api->image_item_set_edit (NULL, probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE,
                                     GLIMS_ITEM_SET_LAYER, 0, "x", NULL, 0, &out, &error);
  CHECK (status == GLIMS_STATUS_NOT_RUNNING && out == 0, "[null engine] NOT_RUNNING, outToken reset to 0");
  free_error (&error);

  /* ---------- Phase G: busy gate while a stroke holds the image ---------- */

  {
    GlimsBrushSettings brush = brush_for (9.0);
    GlimsStrokePoint first = { 8, 8, 1.0, 0.0, 0.0, 0 };
    GlimsStrokeID stroke = 0;

    status = api->stroke_begin (engine, probe->image_id,
                                gimp_item_get_id (GIMP_ITEM (probe->a)),
                                &brush, &first, &stroke, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "stroke begins: %s", error ? error : "?");
    free_error (&error);

    s0 = capture_state (image);
    out = 77;
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "e-busy", members_c, 1, &out, &error);
    CHECK (status == GLIMS_STATUS_BUSY && out == 0, "[busy] CREATE refuses BUSY while a stroke is open");
    free_error (&error);
    check_quiet (probe, s0, capture_state (image), "busy", "CREATE under stroke");
    out = 77;
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                       token, NULL, NULL, 0, &out, &error);
    CHECK (status == GLIMS_STATUS_BUSY && out == 0, "[busy] REMOVE refuses BUSY too");
    free_error (&error);

    status = api->stroke_end (engine, stroke);
    CHECK (status == GLIMS_STATUS_OK, "[busy] stroke ends");
  }

  /* ---------- Phase H: frozen undo stack refuses before mutation --------- */

  s0 = capture_state (image);
  gimp_image_undo_freeze (image);
  out = 77;
  status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                     "e-frozen", members_c, 1, &out, &error);
  CHECK (status == GLIMS_STATUS_FAILED && out == 0, "[frozen] CREATE while frozen refused");
  free_error (&error);
  check_quiet (probe, s0, capture_state (image), "frozen", "frozen CREATE");
  count = -1;
  status = list_sets (probe->image_id, rows, MAX_ROWS, &count);
  CHECK (find_row (rows, count, "e-frozen") < 0, "[frozen] no set created");
  gimp_image_undo_thaw (image);

  /* ---------- Phase I: token exhaustion preflight before any mutation ----- */

  {
    guint64 saved = engine->next_item_set_token;
    engine->next_item_set_token = G_MAXUINT64;
    s0 = capture_state (image);
    out = 77;
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "e-exhaust", members_c, 1, &out, &error);
    CHECK (status == GLIMS_STATUS_FAILED && out == 0, "[exhaustion] CREATE refuses at UINT64_MAX");
    free_error (&error);
    check_quiet (probe, s0, capture_state (image), "exhaustion", "exhausted CREATE");
    count = -1;
    status = list_sets (probe->image_id, rows, MAX_ROWS, &count);
    CHECK (find_row (rows, count, "e-exhaust") < 0, "[exhaustion] nothing mutated");
    out = 77;
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REPLACE, GLIMS_ITEM_SET_LAYER,
                       token, NULL, members_ab, 2, &out, &error);
    CHECK (status == GLIMS_STATUS_FAILED && out == 0, "[exhaustion] REPLACE refuses too (fresh token needed)");
    free_error (&error);
    check_quiet (probe, s0, capture_state (image), "exhaustion", "exhausted REPLACE");
    engine->next_item_set_token = saved;
    s0 = capture_state (image);
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_CREATE, GLIMS_ITEM_SET_LAYER, 0,
                       "e-after-exhaust", NULL, 0, &out, &error);
    CHECK (status == GLIMS_STATUS_OK && out != 0, "[exhaustion] CREATE works again after restore");
    free_error (&error);
    check_delta (probe, s0, capture_state (image), 1, -s0.redo, "exhaustion", "CREATE after restore");
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                       out, NULL, NULL, 0, &out, &error);
    CHECK (status == GLIMS_STATUS_OK && out == 0, "[exhaustion] cleanup remove");
    free_error (&error);
  }

  /* ---------- Phase J: persistence across XCF save/reopen ---------------- */

  {
    GlimsImageID id3 = 0;
    GimpImage *image3;

    snprintf (path, sizeof path, "%s/edit-persist.xcf", probe->work);
    status = api->image_save (engine, probe->image_id, path, &error);
    CHECK (status == GLIMS_STATUS_OK, "[persist] save: %s", error ? error : "?");
    free_error (&error);
    status = api->image_close (engine, probe->image_id);
    CHECK (status == GLIMS_STATUS_OK, "[persist] original closed");
    out = 77;
    status = edit_set (probe->image_id, GLIMS_ITEM_SET_EDIT_REMOVE, GLIMS_ITEM_SET_LAYER,
                       token, NULL, NULL, 0, &out, &error);
    CHECK (status == GLIMS_STATUS_NOT_FOUND && out == 0, "[close] edit on a closed image NOT_FOUND");
    free_error (&error);

    status = api->image_open (engine, path, &id3, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "[persist] reopen: %s", error ? error : "?");
    free_error (&error);
    image3 = glims_lookup_image (engine, id3)->image;
    count = -1;
    status = list_sets (id3, rows, MAX_ROWS, &count);
    {
      int idx = find_row (rows, count, "e-renamed");
      CHECK (status == GLIMS_STATUS_OK && idx >= 0 && rows[idx].token != 0,
             "[persist] reopened image lists e-renamed with a fresh runtime token");
      if (idx >= 0)
        {
          uint64_t t3 = rows[idx].token;
          count = -1;
          status = members_of (id3, t3, ids, 8, &count);
          CHECK (status == GLIMS_STATUS_OK && count == 2, "[persist] members survive the round trip");
          s0 = capture_state (image3);
          out = 0;
          status = edit_set (id3, GLIMS_ITEM_SET_EDIT_RENAME, GLIMS_ITEM_SET_LAYER,
                             t3, "e-persist-renamed", NULL, 0, &out, &error);
          CHECK (status == GLIMS_STATUS_OK && out != 0 && out != t3,
                 "[persist] reopened set editable by its new token (fresh %llu)",
                 (unsigned long long) out);
          free_error (&error);
          check_delta (probe, s0, capture_state (image3), 1, -s0.redo, "persist", "RENAME after reopen");
        }
    }
    /* Close with sets still stored — must not crash. */
    CHECK (api->image_close (engine, id3) == GLIMS_STATUS_OK,
           "[teardown] reopened image closed with sets stored");
  }

  probe->image = NULL;

  return probe->failures > 0 ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngineConfig config;
  GlimsEngine *engine = NULL;
  Probe probe;
  char *error = NULL;
  char work[1024], home_dir[1024], user_dir[1024], cache_dir[1024];
  GlimsStatus status;

  if (argc != 2)
    {
      fprintf (stderr, "usage: %s WORK_DIR\n", argv[0]);
      return 2;
    }

  snprintf (work, sizeof work, "%s", argv[1]);
  snprintf (home_dir, sizeof home_dir, "%s/home", work);
  snprintf (user_dir, sizeof user_dir, "%s/user", work);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", work);
  if ((mkdir (work, 0755) < 0 && errno != EEXIST) ||
      (mkdir (home_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (user_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (cache_dir, 0755) < 0 && errno != EEXIST))
    {
      fprintf (stderr, "cannot create work dirs under %s: %s\n", work, strerror (errno));
      return 1;
    }

  memset (&probe, 0, sizeof probe);
  probe.work = work;
  memset (&config, 0, sizeof config);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  config.on_event        = NULL;

  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (api == NULL || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI))
    {
      fprintf (stderr, "glims_engine_get_api(%u) did not serve the facade\n",
               (unsigned) GLIMS_ENGINE_API_VERSION);
      return 1;
    }

  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "engine start failed: %s\n", error != NULL ? error : "unknown error");
      if (error != NULL)
        api->free_string (error);
      return 1;
    }
  if (error != NULL)
    {
      api->free_string (error);
      error = NULL;
    }

  printf ("saved-set-edit-tests: engine %s, work %s\n",
          api->engine_version (engine), work);

  status = glims_engine_call (engine, run_all, &probe);

  api->stop (engine);
  printf ("%s: %d failure%s\n", probe.failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          probe.failures, probe.failures == 1 ? "" : "s");
  return (status == GLIMS_STATUS_OK && probe.failures == 0) ? 0 : 1;
}

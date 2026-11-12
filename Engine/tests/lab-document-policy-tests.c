/* Public Lab admission plus private witnesses. No editing API may reinterpret
 * physical Lab axes as ink intensities or as the GRAY carrier's pixels. */
#include "facade-policy.h"
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include <stdio.h>
#include <string.h>

static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c,s) do { gboolean ok = !!(c); checks++; \
  printf("%s %s\n", ok ? "ok" : "FAIL", s); if (!ok) failures++; fflush(stdout); } while (0)

typedef struct {
  GlimsImageID id;
  GlimsItemID channels[3];
  guint8 bytes[3][24]; /* 4x3 U16 samples */
  GlimsPlateMap map;
  GlimsUndoInfo undo;
  guint32 replacement_mode;
} Witness;

static GlimsStatus
snapshot (GlimsEngine *engine, gpointer data)
{
  Witness *w = data;
  GlimsOpenImage *open = glims_lookup_image (engine, w->id);
  GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open (open, &storage) ||
      storage.map.count != 3 || storage.map.storage != GLIMS_PLATE_STORAGE_U16 ||
      storage.map.width != 4 || storage.map.height != 3)
    return GLIMS_STATUS_FAILED;
  w->map = storage.map;
  for (guint i = 0; i < 3; i++)
    {
      GimpDrawable *drawable = GIMP_DRAWABLE (storage.planes[i]);
      w->channels[i] = gimp_item_get_id (GIMP_ITEM (drawable));
      gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, 4, 3),
                       1.0, gimp_drawable_get_format (drawable), w->bytes[i],
                       GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    }
  return glims_image_undo_info (engine, w->id, &w->undo);
}

static gboolean
equal (const Witness *a, const Witness *b)
{
  return !memcmp (a->bytes, b->bytes, sizeof a->bytes) &&
         !memcmp (&a->map, &b->map, sizeof a->map) &&
         !memcmp (a->channels, b->channels, sizeof a->channels) &&
         a->undo.undo_count == b->undo.undo_count && a->undo.redo_count == b->undo.redo_count;
}

static GlimsStatus
replace_map (GlimsEngine *engine, gpointer data)
{
  Witness *w = data;
  GlimsOpenImage *open = glims_lookup_image (engine, w->id);
  GlimsPlateMap map = w->map;
  guint8 bytes[GLIMS_PLATE_MAP_MAX_SIZE];
  size_t size = 0;
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  map.mode = w->replacement_mode;
  map.encoding = map.mode == GLIMS_PLATE_MODE_LAB ? GLIMS_PLATE_ENCODING_LAB_D50
                                                 : GLIMS_PLATE_ENCODING_INTENSITY;
  if (!glims_plate_map_encode (&map, bytes, sizeof bytes, &size))
    return GLIMS_STATUS_FAILED;
  GimpParasite *parasite = gimp_parasite_new (GLIMS_PLATE_MAP_PARASITE,
                                            GIMP_PARASITE_PERSISTENT, size, bytes);
  gimp_image_parasite_attach (open->image, parasite, FALSE);
  gimp_parasite_free (parasite);
  return GLIMS_STATUS_OK;
}

static GlimsStatus callback (GlimsEngine *engine, gpointer data)
{ (void) engine; (*(unsigned *) data)++; return GLIMS_STATUS_OK; }

static gboolean
allowed (GlimsFacadeOperation op)
{
  switch (op)
    {
    case GLIMS_FACADE_OP_image_info: case GLIMS_FACADE_OP_image_layers:
    case GLIMS_FACADE_OP_image_color_info: case GLIMS_FACADE_OP_image_render:
    case GLIMS_FACADE_OP_image_lab_axes:
    case GLIMS_FACADE_OP_image_fill_lab: case GLIMS_FACADE_OP_channel_command:
    case GLIMS_FACADE_OP_stroke_begin_lab:
    case GLIMS_FACADE_OP_image_render_to_profile: case GLIMS_FACADE_OP_image_save:
    case GLIMS_FACADE_OP_image_save_copy: case GLIMS_FACADE_OP_image_undo_info:
    case GLIMS_FACADE_OP_image_history: case GLIMS_FACADE_OP_image_undo:
    case GLIMS_FACADE_OP_image_redo: case GLIMS_FACADE_OP_image_history_move:
    case GLIMS_FACADE_OP_selection_bounds: case GLIMS_FACADE_OP_selection_outline:
    case GLIMS_FACADE_OP_paths: case GLIMS_FACADE_OP_image_quick_mask:
    case GLIMS_FACADE_OP_image_guides: case GLIMS_FACADE_OP_image_grid:
    case GLIMS_FACADE_OP_image_floating_selection: case GLIMS_FACADE_OP_image_selected_layers:
    case GLIMS_FACADE_OP_image_selected_items: return TRUE;
    default: return FALSE;
    }
}

static void
matrix (GlimsEngine *engine, GlimsImageID id, gboolean damaged)
{
  for (unsigned i = 0; i < GLIMS_FACADE_OPERATION_COUNT; i++)
    {
      if (glims_facade_target_kind (i) != GLIMS_FACADE_TARGET_IMAGE) continue;
      unsigned reached = 0;
      gboolean invoked = TRUE;
      gboolean cleanup = i == GLIMS_FACADE_OP_image_close ||
                          i == GLIMS_FACADE_OP_image_ink_snapshot_end;
      gboolean want = cleanup || (!damaged && allowed (i));
      GlimsStatus status = glims_facade_call_reporting_admission (engine, i,
        (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, id, { 0, 0 } },
        callback, &reached, NULL, &invoked);
      CHECK (status == (want ? GLIMS_STATUS_OK : GLIMS_STATUS_UNSUPPORTED) &&
             reached == want && invoked == want, glims_facade_operation_name (i));
    }
}

static void clear_error (char **error)
{ api->free_string (*error); *error = NULL; }

typedef struct { GlimsImageID id; gboolean lab; } Mark;
static GlimsStatus
mark_lab (GlimsEngine *engine, gpointer data)
{
  Mark *mark = data;
  GlimsOpenImage *open = glims_lookup_image (engine, mark->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  open->component_document = mark->lab;
  open->component_mode = mark->lab ? GLIMS_PLATE_MODE_LAB : 0;
  return GLIMS_STATUS_OK;
}

/* Genuine live sessions are established on ordinary documents, then only the
 * cached admission classification changes. This proves cleanup and retained
 * source checks even when persistent metadata is missing or corrupted. */
static void
live_strokes (GlimsEngine *engine, GlimsImageID source, GlimsImageID dest)
{
  GlimsLayerInfo layers[1]; int32_t count = 0;
  CHECK (api->image_layers (engine, source, layers, 1, &count) == GLIMS_STATUS_OK && count == 1,
         "ordinary source layer resolves for live-state transition");
  if (count != 1) return;
  GlimsItemID source_item = layers[0].id;
  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_PENCIL,
    .size = 3, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStrokePoint point = { 1, 1, 1, 0, 0, 10 };
  GlimsStrokeID stroke = 0; char *error = NULL;
  CHECK (api->stroke_begin (engine, source, source_item, &brush, &point, &stroke, &error) == GLIMS_STATUS_OK && stroke,
         "ordinary destination stroke starts before classification change");
  clear_error (&error);
  Mark mark = { source, TRUE };
  if (stroke)
    {
      CHECK (glims_engine_call (engine, mark_lab, &mark) == GLIMS_STATUS_OK, "mark live destination Lab on engine thread");
      CHECK (api->stroke_continue (engine, stroke, &point, 1) == GLIMS_STATUS_UNSUPPORTED,
             "live Lab destination refuses continuation despite damaged metadata");
      CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "live Lab destination still permits cleanup");
      mark.lab = FALSE; glims_engine_call (engine, mark_lab, &mark);
    }
  brush.tool = GLIMS_PAINT_CLONE; brush.source_drawable = source_item;
  brush.source_x = 1; brush.source_y = 1; point.time_ms = 100; stroke = 0;
  count = 0;
  CHECK (api->image_layers (engine, dest, layers, 1, &count) == GLIMS_STATUS_OK && count == 1,
         "ordinary Clone destination resolves an explicit drawable");
  if (count != 1) return;
  CHECK (api->stroke_begin (engine, dest, layers[0].id, &brush, &point, &stroke, &error) == GLIMS_STATUS_OK && stroke,
         "cross-image Clone starts before source classification change");
  clear_error (&error);
  if (stroke)
    {
      mark.lab = TRUE; glims_engine_call (engine, mark_lab, &mark);
      CHECK (api->stroke_continue (engine, stroke, &point, 1) == GLIMS_STATUS_UNSUPPORTED,
             "live Clone refuses retained Lab source, not only destination");
      CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "retained Lab source permits stroke cleanup");
      mark.lab = FALSE; glims_engine_call (engine, mark_lab, &mark);
    }
}

int main (int argc, char **argv)
{
  if (argc != 2) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  gchar *user = g_build_filename (argv[1], "user", NULL);
  gchar *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL;
  if (!api || api->start (&config, &engine, &error) != GLIMS_STATUS_OK) return 2;
  Witness before = { 0 }, after = { 0 };
  GlimsImageID ordinary = 0, second = 0, invalid = 123;
  CHECK (api->image_new_lab (engine, 0, 3, GLIMS_COLOR_COMPONENT_U16, &invalid, &error) == GLIMS_STATUS_INVALID_ARGUMENT && !invalid,
         "invalid dimensions do not publish an image"); clear_error (&error);
  invalid = 123;
  CHECK (api->image_new_lab (engine, 4, 3, UINT32_MAX, &invalid, &error) == GLIMS_STATUS_INVALID_ARGUMENT && !invalid,
         "unknown precision does not publish an image"); clear_error (&error);
  CHECK (api->image_new_lab (engine, 4, 3, GLIMS_COLOR_COMPONENT_U16, &before.id, &error) == GLIMS_STATUS_OK && before.id,
         "public Lab creation succeeds"); clear_error (&error);
  if (!before.id) goto done;
  CHECK (glims_engine_call (engine, snapshot, &before) == GLIMS_STATUS_OK, "capture native Lab identity, bytes and history");
  GlimsColorInfo color = { 0 };
  CHECK (api->image_color_info (engine, before.id, &color) == GLIMS_STATUS_OK &&
         color.mode == GLIMS_COLOR_MODE_LAB && color.component == GLIMS_COLOR_COMPONENT_U16 &&
         !color.profile_embedded && !strcmp (color.profile_label, "D50 Lab"), "Lab reports its own mode and fixed D50 profile");
  matrix (engine, before.id, FALSE);
  CHECK (api->image_edit_ink (engine, before.id, before.channels[0], GLIMS_INK_EDIT_INVERT, 0, 1, &error) == GLIMS_STATUS_UNSUPPORTED,
         "physical Lightness cannot be inverted as ink"); clear_error (&error);
  GlimsInkLevelsSettings levels = { .struct_size = sizeof levels,
    .value = { .high_input = 1, .gamma = 1, .high_output = 1 } };
  CHECK (api->image_levels_ink (engine, before.id, before.channels[1], &levels, &error) == GLIMS_STATUS_UNSUPPORTED,
         "physical chroma cannot use ink Levels"); clear_error (&error);
  uint64_t token = 99;
  CHECK (api->image_ink_snapshot_begin (engine, before.id, before.channels[0], &token, &error) == GLIMS_STATUS_UNSUPPORTED && !token,
         "Lab snapshot refusal clears token"); clear_error (&error);
  GlimsInkChannelIdentity identity; memset (&identity, 0x5a, sizeof identity); identity.struct_size = sizeof identity;
  GlimsInkChannelIdentity empty = { .struct_size = sizeof identity };
  CHECK (api->image_ink_channel_identity (engine, before.id, before.channels[0], &identity) == GLIMS_STATUS_UNSUPPORTED &&
         !memcmp (&identity, &empty, sizeof identity), "Lab has no misleading ink role or ink UUID response");
  CHECK (api->procedure_run (engine, 0, "unused-global-procedure", 0, &error) == GLIMS_STATUS_UNSUPPORTED,
         "global PDB execution cannot bypass an open Lab document"); clear_error (&error);
  CHECK (api->image_new (engine, 4, 3, &ordinary, &error) == GLIMS_STATUS_OK, "ordinary witness opens alongside Lab"); clear_error (&error);
  GlimsFilterID filter = 99;
  CHECK (api->filter_begin_with_source (engine, ordinary, 0, "gegl:bump-map", before.channels[0], &filter, &error) == GLIMS_STATUS_UNSUPPORTED && !filter,
         "ordinary destination cannot borrow Lab axis as filter source"); clear_error (&error);
  GlimsBrushSettings brush = { .struct_size = sizeof brush, .tool = GLIMS_PAINT_CLONE, .size = 3, .opacity = 1,
    .hardness = -1, .rate = -1, .flow = -1, .exposure = -1, .source_drawable = before.channels[0] };
  GlimsStrokePoint point = { 1, 1, 1, 0, 0, 10 }; GlimsStrokeID stroke = 0;
  CHECK (api->stroke_begin (engine, ordinary, 0, &brush, &point, &stroke, &error) == GLIMS_STATUS_UNSUPPORTED && !stroke,
         "ordinary destination cannot clone a Lab axis"); clear_error (&error);
  after.id = before.id;
  CHECK (glims_engine_call (engine, snapshot, &after) == GLIMS_STATUS_OK && equal (&before, &after),
         "all refusal paths leave native bytes, IDs, map and history unchanged");
  CHECK (api->image_clear (engine, ordinary, NULL, &error) == GLIMS_STATUS_OK,
         "ordinary edits remain usable while Lab is open"); clear_error (&error);
  CHECK (api->image_new (engine, 4, 3, &second, &error) == GLIMS_STATUS_OK, "second ordinary stroke witness opens"); clear_error (&error);
  if (ordinary && second) live_strokes (engine, ordinary, second);
  before.replacement_mode = GLIMS_PLATE_MODE_MULTICHANNEL;
  CHECK (glims_engine_call (engine, replace_map, &before) == GLIMS_STATUS_OK, "replace persisted mode with structurally valid Multichannel metadata");
  matrix (engine, before.id, TRUE);
  CHECK (api->image_edit_ink (engine, before.id, before.channels[0], GLIMS_INK_EDIT_INVERT, 0, 1, &error) == GLIMS_STATUS_UNSUPPORTED,
         "mode replacement cannot evade the adopted Lab boundary"); clear_error (&error);
  CHECK (api->image_close (engine, before.id) == GLIMS_STATUS_OK, "damaged Lab document still closes"); before.id = 0;
done:
  if (before.id) api->image_close (engine, before.id);
  if (ordinary) api->image_close (engine, ordinary);
  if (second) api->image_close (engine, second);
  clear_error (&error); api->stop (engine); g_free (user); g_free (cache);
  printf ("%u Lab admission checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}

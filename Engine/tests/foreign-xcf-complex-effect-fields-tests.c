/* Pinned native complex foreign-XCF oracle. Expected state comes from a real
 * independently configured source. The fixed-shape byte walker below is test
 * code; it neither includes nor calls the production decoder or binding. */
#include "engine-private.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpdrawablefiltermask.h"
#include "core/gimpfilter.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimplayermask.h"
#include "core/gimplist.h"
#include "core/gimppickable.h"
#include "core/gimpviewable.h"
#include "gegl/gimp-babl.h"
#include "file/file-save.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
#include "plug-in/gimppluginprocedure.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wdeclaration-after-statement"
#if GIMP_MAJOR_VERSION != 3 || GIMP_MINOR_VERSION != 2 || GIMP_MICRO_VERSION != 8
#error This independent complex XCF oracle is specified only for GIMP 3.2.8
#endif
G_STATIC_ASSERT (GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR == 2);
G_STATIC_ASSERT (GIMP_LAYER_COMPOSITE_CLIP_TO_LAYER == 3);
int main (int argc, char **argv);

#define W 8
#define H 6
#define N (W * H)
#define MAX_FILE (4u * 1024u * 1024u)
#define GROUP_NAME "Complex group"
#define CHILD_NAME "Complex alpha child"
#define BACKGROUND_NAME "Complex background"
#define CHANNEL_NAME "Complex saved channel"
#define MASK_NAME CHILD_NAME " mask"
#define ICON "gimp-gegl"

typedef struct { const gchar *name, *operation; gdouble black, exposure; } FxSpec;
static const FxSpec fx_specs[4] = {
  { "Complex child Exposure 79afc1", "gegl:exposure", .03125, .75 },
  { "Complex child Invert 27e8b4", "gegl:invert-linear", 0, 0 },
  { "Complex mask Exposure 619f2c", "gegl:exposure", 0, -.5 },
  { "Complex channel Invert 03adc7", "gegl:invert-linear", 0, 0 }
};
static const GlimsEngineAPI *api;
static const gchar *work_dir;
static guint checks, failures;
#define CHECK(condition, title) do { gboolean ok_ = (condition); checks++; \
  printf ("%s %s\n", ok_ ? "ok  " : "FAIL", title); if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(condition, title) do { gboolean needed_ = (condition); CHECK (needed_, title); \
  if (!needed_) goto cleanup; } while (0)

typedef struct {
  GlimsEngine *engine;
  GlimsImageID id;
  GimpImage *image;
  GimpLayer *group, *child, *background;
  GimpLayerMask *mask;
  GimpChannel *channel;
  GimpDrawableFilter *fx[4]; /* Borrowed from their image-owned drawables. */
  gfloat child_input[N * 4], background_input[N * 4], mask_input[N], channel_input[N];
} Fixture;

typedef struct { guint32 tattoo, width, height, path[2], depth; gint x, y; gboolean visible; } ItemState;
typedef struct {
  gint mode, blend, composite, combination, region;
  gdouble opacity, black, exposure;
  gboolean active, clip;
  gboolean mask_visible;
  gint mask_x, mask_y;
  guint32 mask_tattoo;
  gfloat mask_raw[N];
} FxState;
typedef struct {
  ItemState layers[3], mask, channel;
  gboolean apply_mask, edit_mask, show_mask;
  FxState fx[4];
  gfloat raw_background[N * 4], raw_child[N * 4], raw_group[N * 4], raw_mask[N], raw_channel[N];
  gfloat child_result[N * 4], mask_result[N], channel_result[N], group_result[N * 4], composite[N * 4];
  GlimsUndoInfo undo;
} Snapshot;
typedef struct {
  GFile *file, *imported, *exported, *copy;
  GimpPlugInProcedure *procedure;
  gboolean dirty, export_dirty;
  gint64 dirty_time;
  GlimsUndoInfo undo;
} FileState;

static void
clear_error (char **error)
{
  if (*error) api->free_string (*error);
  *error = NULL;
}

static gboolean
finite_values (const gfloat *values, guint count)
{
  for (guint i = 0; i < count; i++) if (!isfinite (values[i])) return FALSE;
  return TRUE;
}

static gdouble
delta (const gfloat *a, const gfloat *b, guint count)
{
  gdouble result = 0;
  for (guint i = 0; i < count; i++) {
    if (!isfinite (a[i]) || !isfinite (b[i])) return INFINITY;
    result = MAX (result, fabs (a[i] - b[i]));
  }
  return result;
}

static gboolean
drawable_pixels (GimpDrawable *drawable, gboolean effects, gboolean gray, gfloat *out)
{
  gimp_pickable_flush (GIMP_PICKABLE (drawable));
  GeglBuffer *buffer = effects ? gimp_drawable_get_buffer_with_effects (drawable) : gimp_drawable_get_buffer (drawable);
  if (!buffer) return FALSE;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, W, H), 1,
      babl_format (gray ? "Y float" : "RGBA float"), out, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  if (effects) g_object_unref (buffer);
  return finite_values (out, gray ? N : N * 4);
}

static gboolean
image_pixels (GimpImage *image, gfloat out[N * 4])
{
  gimp_pickable_flush (GIMP_PICKABLE (image));
  GeglBuffer *buffer = gimp_pickable_get_buffer (GIMP_PICKABLE (image));
  if (!buffer) return FALSE;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, W, H), 1, babl_format ("RGBA float"),
                   out, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  return finite_values (out, N * 4);
}

static gboolean
item_state (GimpItem *item, ItemState *state, gboolean path)
{
  state->tattoo = gimp_item_get_tattoo (item);
  state->width = gimp_item_get_width (item); state->height = gimp_item_get_height (item);
  gimp_item_get_offset (item, &state->x, &state->y); state->visible = gimp_item_get_visible (item);
  if (state->width != W || state->height != H) return FALSE;
  if (!path) return TRUE;
  GList *indices = gimp_item_get_path (item);
  state->depth = g_list_length (indices);
  if (state->depth > 2) { g_list_free (indices); return FALSE; }
  guint i = 0;
  for (GList *it = indices; it; it = it->next, i++) state->path[i] = GPOINTER_TO_UINT (it->data);
  g_list_free (indices);
  return TRUE;
}

static gboolean
collect_effects (GimpDrawable *drawable, guint first, guint count, GimpDrawableFilter **out)
{
  GimpContainer *filters = gimp_drawable_get_filters (drawable);
  if (!GIMP_IS_LIST (filters)) return FALSE;
  guint found = 0;
  for (GList *it = GIMP_LIST (filters)->queue->head; it; it = it->next) {
    if (!GIMP_IS_DRAWABLE_FILTER (it->data) || gimp_drawable_filter_get_temporary (it->data)) continue;
    if (found >= count) return FALSE;
    GimpDrawableFilter *filter = it->data;
    GeglNode *node = gimp_drawable_filter_get_operation (filter);
    const FxSpec *spec = &fx_specs[first + found];
    if (gimp_drawable_filter_get_drawable (filter) != drawable || !node ||
        g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (filter)), spec->name) ||
        g_strcmp0 (gegl_node_get_operation (node), spec->operation) ||
        g_strcmp0 (gimp_viewable_get_icon_name (GIMP_VIEWABLE (filter)), ICON)) return FALSE;
    out[first + found++] = filter;
  }
  return found == count;
}

static gboolean
resolve_fixture (Fixture *fixture)
{
  GList *layers = gimp_image_get_layer_list (fixture->image), *channels = gimp_image_get_channel_list (fixture->image);
  gboolean ok = gimp_image_get_width (fixture->image) == W && gimp_image_get_height (fixture->image) == H &&
      gimp_image_get_base_type (fixture->image) == GIMP_RGB && gimp_image_get_precision (fixture->image) == GIMP_PRECISION_FLOAT_LINEAR &&
      g_list_length (layers) == 3 && g_list_length (channels) == 1;
  if (!ok) goto done;
  fixture->group = layers->data; fixture->child = layers->next->data; fixture->background = layers->next->next->data;
  fixture->channel = channels->data; fixture->mask = gimp_layer_get_mask (fixture->child);
  ok = G_OBJECT_TYPE (fixture->group) == GIMP_TYPE_GROUP_LAYER &&
      G_OBJECT_TYPE (fixture->child) == GIMP_TYPE_LAYER && G_OBJECT_TYPE (fixture->background) == GIMP_TYPE_LAYER &&
      gimp_layer_get_parent (fixture->child) == fixture->group && !gimp_layer_get_parent (fixture->group) &&
      !gimp_layer_get_parent (fixture->background) && fixture->mask &&
      gimp_layer_mask_get_layer (fixture->mask) == fixture->child &&
      gimp_item_get_image (GIMP_ITEM (fixture->mask)) == fixture->image &&
      gimp_item_get_image (GIMP_ITEM (fixture->channel)) == fixture->image &&
      !g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (fixture->group)), GROUP_NAME) &&
      !g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (fixture->child)), CHILD_NAME) &&
      !g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (fixture->background)), BACKGROUND_NAME) &&
      !g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (fixture->mask)), MASK_NAME) &&
      !g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (fixture->channel)), CHANNEL_NAME) &&
      collect_effects (GIMP_DRAWABLE (fixture->group), 0, 0, fixture->fx) &&
      collect_effects (GIMP_DRAWABLE (fixture->background), 0, 0, fixture->fx) &&
      collect_effects (GIMP_DRAWABLE (fixture->child), 0, 2, fixture->fx) &&
      collect_effects (GIMP_DRAWABLE (fixture->mask), 2, 1, fixture->fx) &&
      collect_effects (GIMP_DRAWABLE (fixture->channel), 3, 1, fixture->fx) &&
      gimp_container_get_n_children (gimp_image_get_paths (fixture->image)) == 0 &&
      gimp_channel_is_empty (gimp_image_get_mask (fixture->image));
done:
  g_list_free (layers); g_list_free (channels);
  return ok;
}

static gboolean
capture (Fixture *fixture, Snapshot *state)
{
  memset (state, 0, sizeof *state);
  if (!resolve_fixture (fixture) || !item_state (GIMP_ITEM (fixture->group), &state->layers[0], TRUE) ||
      !item_state (GIMP_ITEM (fixture->child), &state->layers[1], TRUE) ||
      !item_state (GIMP_ITEM (fixture->background), &state->layers[2], TRUE) ||
      !item_state (GIMP_ITEM (fixture->mask), &state->mask, FALSE) ||
      !item_state (GIMP_ITEM (fixture->channel), &state->channel, FALSE)) return FALSE;
  if (state->layers[0].depth != 1 || state->layers[0].path[0] != 0 ||
      state->layers[1].depth != 2 || state->layers[1].path[0] != 0 || state->layers[1].path[1] != 0 ||
      state->layers[2].depth != 1 || state->layers[2].path[0] != 1) return FALSE;
  for (guint i = 0; i < 4; i++) {
    GimpDrawableFilter *filter = fixture->fx[i];
    GimpDrawableFilterMask *mask = gimp_drawable_filter_get_mask (filter);
    gchar *mask_name = g_strdup_printf ("%s mask", fx_specs[i].name);
    gboolean name_matches = mask && !g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (mask)), mask_name);
    g_free (mask_name);
    if (!name_matches || G_OBJECT_TYPE (mask) != GIMP_TYPE_DRAWABLE_FILTER_MASK ||
        gimp_drawable_filter_mask_get_filter (mask) != filter || gimp_item_get_image (GIMP_ITEM (mask)) != fixture->image ||
        gimp_item_get_width (GIMP_ITEM (mask)) != W || gimp_item_get_height (GIMP_ITEM (mask)) != H) return FALSE;
    FxState *fx = &state->fx[i];
    fx->mode = gimp_drawable_filter_get_paint_mode (filter); fx->blend = gimp_drawable_filter_get_blend_space (filter);
    fx->composite = gimp_drawable_filter_get_composite_space (filter); fx->combination = gimp_drawable_filter_get_composite_mode (filter);
    fx->opacity = gimp_drawable_filter_get_opacity (filter); fx->active = gimp_filter_get_active (GIMP_FILTER (filter));
    fx->clip = gimp_drawable_filter_get_clip (filter); fx->region = gimp_drawable_filter_get_region (filter);
    fx->mask_tattoo = gimp_item_get_tattoo (GIMP_ITEM (mask));
    fx->mask_visible = gimp_item_get_visible (GIMP_ITEM (mask));
    gimp_item_get_offset (GIMP_ITEM (mask), &fx->mask_x, &fx->mask_y);
    if (i == 0 || i == 2) gegl_node_get (gimp_drawable_filter_get_operation (filter),
        "black-level", &fx->black, "exposure", &fx->exposure, NULL);
    if (!drawable_pixels (GIMP_DRAWABLE (mask), FALSE, TRUE, fx->mask_raw)) return FALSE;
  }
  state->apply_mask = gimp_layer_get_apply_mask (fixture->child);
  state->edit_mask = gimp_layer_get_edit_mask (fixture->child);
  state->show_mask = gimp_layer_get_show_mask (fixture->child);
  return drawable_pixels (GIMP_DRAWABLE (fixture->background), FALSE, FALSE, state->raw_background) &&
      drawable_pixels (GIMP_DRAWABLE (fixture->child), FALSE, FALSE, state->raw_child) &&
      drawable_pixels (GIMP_DRAWABLE (fixture->group), FALSE, FALSE, state->raw_group) &&
      drawable_pixels (GIMP_DRAWABLE (fixture->mask), FALSE, TRUE, state->raw_mask) &&
      drawable_pixels (GIMP_DRAWABLE (fixture->channel), FALSE, TRUE, state->raw_channel) &&
      drawable_pixels (GIMP_DRAWABLE (fixture->child), TRUE, FALSE, state->child_result) &&
      drawable_pixels (GIMP_DRAWABLE (fixture->mask), TRUE, TRUE, state->mask_result) &&
      drawable_pixels (GIMP_DRAWABLE (fixture->channel), TRUE, TRUE, state->channel_result) &&
      drawable_pixels (GIMP_DRAWABLE (fixture->group), TRUE, FALSE, state->group_result) &&
      image_pixels (fixture->image, state->composite) &&
      api->image_undo_info (fixture->engine, fixture->id, &state->undo) == GLIMS_STATUS_OK;
}

static void
set_fields (GimpDrawableFilter *filter, gboolean explicit)
{
  gimp_drawable_filter_set_mode (filter, GIMP_LAYER_MODE_MULTIPLY,
      explicit ? GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR : GIMP_LAYER_COLOR_SPACE_AUTO,
      explicit ? GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR : GIMP_LAYER_COLOR_SPACE_AUTO,
      explicit ? GIMP_LAYER_COMPOSITE_CLIP_TO_LAYER : GIMP_LAYER_COMPOSITE_AUTO);
}

static gboolean
create_effect (GimpDrawable *drawable, guint index)
{
  const FxSpec *spec = &fx_specs[index];
  GeglNode *node = gegl_node_new ();
  gegl_node_set (node, "operation", spec->operation, NULL);
  if (index == 0 || index == 2) gegl_node_set (node, "black-level", spec->black, "exposure", spec->exposure, NULL);
  GimpDrawableFilter *filter = gimp_drawable_filter_new (drawable, spec->name, node, ICON);
  gboolean committed = FALSE;
  if (filter) {
    gimp_drawable_filter_set_temporary (filter, FALSE); gimp_drawable_filter_set_opacity (filter, .625);
    gimp_drawable_filter_set_clip (filter, TRUE); gimp_drawable_filter_set_region (filter, GIMP_FILTER_REGION_DRAWABLE);
    set_fields (filter, TRUE); gimp_drawable_filter_apply (filter, NULL); gimp_drawable_filter_layer_mask_freeze (filter);
    committed = gimp_drawable_filter_commit (filter, TRUE, NULL, FALSE);
    if (!committed) gimp_drawable_filter_abort (filter);
  }
  g_clear_object (&filter); g_object_unref (node);
  return committed;
}

static gboolean
create_source (GlimsEngine *engine, Fixture *fixture)
{
  fixture->engine = engine;
  fixture->image = gimp_create_image (engine->gimp, W, H, GIMP_RGB, GIMP_PRECISION_FLOAT_LINEAR, FALSE);
  if (!fixture->image) return FALSE;
  if (glims_adopt_image (engine, fixture->image, &fixture->id) != GLIMS_STATUS_OK) { g_clear_object (&fixture->image); return FALSE; }
  fixture->background = gimp_layer_new (fixture->image, W, H, gimp_image_get_layer_format (fixture->image, TRUE), BACKGROUND_NAME, 1, GIMP_LAYER_MODE_NORMAL);
  if (!fixture->background) return FALSE;
  if (!gimp_image_add_layer (fixture->image, fixture->background, NULL, 0, FALSE)) { g_clear_object (&fixture->background); return FALSE; }
  fixture->group = gimp_group_layer_new (fixture->image);
  if (!fixture->group) return FALSE;
  gimp_object_set_name (GIMP_OBJECT (fixture->group), GROUP_NAME);
  if (!gimp_image_add_layer (fixture->image, fixture->group, NULL, 0, FALSE)) { g_clear_object (&fixture->group); return FALSE; }
  fixture->child = gimp_layer_new (fixture->image, W, H, gimp_image_get_layer_format (fixture->image, TRUE), CHILD_NAME, 1, GIMP_LAYER_MODE_NORMAL);
  if (!fixture->child) return FALSE;
  if (!gimp_image_add_layer (fixture->image, fixture->child, fixture->group, 0, FALSE)) { g_clear_object (&fixture->child); return FALSE; }
  GeglColor *color = gegl_color_new ("black");
  fixture->mask = gimp_layer_mask_new (fixture->image, W, H, MASK_NAME, color);
  fixture->channel = gimp_channel_new (fixture->image, W, H, CHANNEL_NAME, color);
  g_object_unref (color);
  if (!fixture->mask || !fixture->channel) { g_clear_object (&fixture->mask); g_clear_object (&fixture->channel); return FALSE; }
  for (guint p = 0; p < N; p++) {
    fixture->child_input[p * 4] = (gfloat) (1 + p % 7) / 16;
    fixture->child_input[p * 4 + 1] = (gfloat) (2 + p * 3 % 11) / 16;
    fixture->child_input[p * 4 + 2] = (gfloat) (1 + p * 5 % 13) / 16;
    fixture->child_input[p * 4 + 3] = (gfloat) (1 + p % 4) / 4;
    fixture->background_input[p * 4] = .125f; fixture->background_input[p * 4 + 1] = .25f;
    fixture->background_input[p * 4 + 2] = .375f; fixture->background_input[p * 4 + 3] = 1;
    fixture->mask_input[p] = (gfloat) (1 + (p * 3 + p / W) % 8) / 8;
    fixture->channel_input[p] = (gfloat) (1 + (p * 5 + p / W) % 15) / 16;
  }
  GimpDrawable *drawables[] = {GIMP_DRAWABLE (fixture->background), GIMP_DRAWABLE (fixture->child), GIMP_DRAWABLE (fixture->mask), GIMP_DRAWABLE (fixture->channel)};
  const gfloat *pixels[] = {fixture->background_input, fixture->child_input, fixture->mask_input, fixture->channel_input};
  for (guint i = 0; i < 4; i++) {
    gegl_buffer_set (gimp_drawable_get_buffer (drawables[i]), GEGL_RECTANGLE (0, 0, W, H), 0,
        babl_format (i < 2 ? "RGBA float" : "Y float"), pixels[i], GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update (drawables[i], 0, 0, W, H);
  }
  GError *error = NULL;
  gboolean added = gimp_layer_add_mask (fixture->child, fixture->mask, FALSE, FALSE, &error) != NULL;
  if (error) { fprintf (stderr, "OBS mask attach: %s\n", error->message); g_clear_error (&error); }
  if (!added) { g_clear_object (&fixture->mask); g_clear_object (&fixture->channel); return FALSE; }
  if (!gimp_image_add_channel (fixture->image, fixture->channel, NULL, 0, FALSE)) { g_clear_object (&fixture->channel); return FALSE; }
  gimp_item_set_visible (GIMP_ITEM (fixture->channel), FALSE, FALSE);
  /* Head insertion means inverse creation order yields Exposure then Invert. */
  if (!create_effect (GIMP_DRAWABLE (fixture->child), 1) || !create_effect (GIMP_DRAWABLE (fixture->child), 0) ||
      !create_effect (GIMP_DRAWABLE (fixture->mask), 2) || !create_effect (GIMP_DRAWABLE (fixture->channel), 3)) return FALSE;
  gimp_image_clean_all (fixture->image);
  return resolve_fixture (fixture);
}

static gboolean
native_save (Fixture *fixture, const gchar *path)
{
  GError *error = NULL;
  GFile *file = g_file_new_for_path (path);
  GimpPlugInProcedure *procedure = gimp_plug_in_manager_file_procedure_find (
      fixture->engine->gimp->plug_in_manager, GIMP_FILE_PROCEDURE_GROUP_SAVE, file, &error);
  GimpPDBStatusType status = GIMP_PDB_EXECUTION_ERROR;
  if (procedure) {
    fixture->engine->busy++;
    status = file_save (fixture->engine->gimp, fixture->image, NULL, file, procedure,
        GIMP_RUN_NONINTERACTIVE, TRUE, FALSE, FALSE, &error);
    fixture->engine->busy--;
  }
  if (error) fprintf (stderr, "OBS native save: %s\n", error->message);
  g_clear_error (&error); g_object_unref (file);
  return status == GIMP_PDB_SUCCESS;
}

static gboolean
file_state (Fixture *fixture, FileState *state)
{
  g_set_object (&state->file, gimp_image_get_file (fixture->image));
  g_set_object (&state->imported, gimp_image_get_imported_file (fixture->image));
  g_set_object (&state->exported, gimp_image_get_exported_file (fixture->image));
  g_set_object (&state->copy, gimp_image_get_save_a_copy_file (fixture->image));
  state->procedure = gimp_image_get_save_proc (fixture->image);
  state->dirty = gimp_image_is_dirty (fixture->image); state->export_dirty = gimp_image_is_export_dirty (fixture->image);
  state->dirty_time = gimp_image_get_dirty_time (fixture->image);
  return api->image_undo_info (fixture->engine, fixture->id, &state->undo) == GLIMS_STATUS_OK;
}

static gboolean
file_state_same (Fixture *fixture, const FileState *state)
{
  GlimsUndoInfo undo = {0};
  return state->file == gimp_image_get_file (fixture->image) && state->imported == gimp_image_get_imported_file (fixture->image) &&
      state->exported == gimp_image_get_exported_file (fixture->image) && state->copy == gimp_image_get_save_a_copy_file (fixture->image) &&
      state->procedure == gimp_image_get_save_proc (fixture->image) && state->dirty == gimp_image_is_dirty (fixture->image) &&
      state->export_dirty == gimp_image_is_export_dirty (fixture->image) && state->dirty_time == gimp_image_get_dirty_time (fixture->image) &&
      api->image_undo_info (fixture->engine, fixture->id, &undo) == GLIMS_STATUS_OK && !memcmp (&undo, &state->undo, sizeof undo);
}

static void
file_state_clear (FileState *state)
{
  g_clear_object (&state->file); g_clear_object (&state->imported); g_clear_object (&state->exported); g_clear_object (&state->copy);
}

static gboolean
fx_same (const FxState *a, const FxState *b)
{
  /* A saved channel is converted to a new effect-mask object on load.
   * Its tattoo is observed separately; ownership, geometry and pixels are
   * mandatory capture predicates and compare below, not numeric identity. */
  return a->mode == b->mode && a->blend == b->blend && a->composite == b->composite && a->combination == b->combination &&
      a->region == b->region && a->opacity == b->opacity && a->black == b->black && a->exposure == b->exposure &&
      a->active == b->active && a->clip == b->clip && a->mask_visible == b->mask_visible &&
      a->mask_x == b->mask_x && a->mask_y == b->mask_y && !memcmp (a->mask_raw, b->mask_raw, sizeof a->mask_raw);
}

static gboolean
raw_same (const Snapshot *a, const Snapshot *b)
{
  return !memcmp (a->raw_background, b->raw_background, sizeof a->raw_background) &&
      !memcmp (a->raw_child, b->raw_child, sizeof a->raw_child) && !memcmp (a->raw_group, b->raw_group, sizeof a->raw_group) &&
      !memcmp (a->raw_mask, b->raw_mask, sizeof a->raw_mask) && !memcmp (a->raw_channel, b->raw_channel, sizeof a->raw_channel);
}

static gboolean
rendered_same (const Snapshot *a, const Snapshot *b)
{
  return !memcmp (a->child_result, b->child_result, sizeof a->child_result) &&
      !memcmp (a->mask_result, b->mask_result, sizeof a->mask_result) &&
      !memcmp (a->channel_result, b->channel_result, sizeof a->channel_result) &&
      !memcmp (a->group_result, b->group_result, sizeof a->group_result) && !memcmp (a->composite, b->composite, sizeof a->composite);
}

static gboolean
metadata_same (const Snapshot *a, const Snapshot *b)
{
  if (memcmp (a->layers, b->layers, sizeof a->layers) || memcmp (&a->mask, &b->mask, sizeof a->mask) ||
      memcmp (&a->channel, &b->channel, sizeof a->channel) || a->apply_mask != b->apply_mask ||
      a->edit_mask != b->edit_mask || a->show_mask != b->show_mask) return FALSE;
  for (guint i = 0; i < 4; i++) if (!fx_same (&a->fx[i], &b->fx[i])) return FALSE;
  return TRUE;
}

static gboolean
all_explicit (const Snapshot *state)
{
  for (guint i = 0; i < 4; i++) {
    const FxState *fx = &state->fx[i];
    if (fx->mode != GIMP_LAYER_MODE_MULTIPLY || fx->blend != 2 || fx->composite != 2 || fx->combination != 3 ||
        fx->opacity != .625 || !fx->active || !fx->clip || fx->region != GIMP_FILTER_REGION_DRAWABLE ||
        fx->black != fx_specs[i].black || fx->exposure != fx_specs[i].exposure) return FALSE;
  }
  return TRUE;
}

/* This walker accepts only the single fixture shape above. Its offsets come
 * from XCF tables, never from a sentinel search or the production decoder. */
typedef struct { const guint8 *bytes; gsize size, pos, end; } Cursor;
typedef struct {
  gsize fields[4][3];
  guint32 values[4][3];
  gsize effects[4], layers[3], layer_mask, channel;
  gsize anchors[64], starts[64], ends[64];
  guint n_anchors, n_ranges;
} Layout;

static gboolean
word (Cursor *cursor, guint32 *value)
{
  guint32 encoded;
  if (cursor->pos > cursor->end || cursor->end - cursor->pos < 4) return FALSE;
  memcpy (&encoded, cursor->bytes + cursor->pos, 4);
  *value = GUINT32_FROM_BE (encoded); cursor->pos += 4;
  return TRUE;
}

static gboolean
address (Cursor *cursor, gsize *value)
{
  guint64 encoded;
  if (cursor->pos > cursor->end || cursor->end - cursor->pos < 8) return FALSE;
  memcpy (&encoded, cursor->bytes + cursor->pos, 8);
  encoded = GUINT64_FROM_BE (encoded);
  if (encoded >= cursor->size && encoded) return FALSE;
  *value = (gsize) encoded; cursor->pos += 8;
  return TRUE;
}

static gboolean
text_is (Cursor *cursor, const gchar *expected)
{
  guint32 count;
  if (!word (cursor, &count) || count > 512 || count > cursor->end - cursor->pos) return FALSE;
  if (!expected) return count == 0;
  if (count != strlen (expected) + 1 || memcmp (cursor->bytes + cursor->pos, expected, count)) return FALSE;
  cursor->pos += count;
  return TRUE;
}

static gfloat
as_float (guint32 bits)
{
  gfloat value;
  memcpy (&value, &bits, sizeof value);
  return value;
}

static gboolean
anchor (Layout *layout, gsize offset)
{
  if (!offset || layout->n_anchors == G_N_ELEMENTS (layout->anchors)) return FALSE;
  for (guint i = 0; i < layout->n_anchors; i++) if (layout->anchors[i] == offset) return FALSE;
  layout->anchors[layout->n_anchors++] = offset;
  return TRUE;
}

static gboolean
metadata_range (Layout *layout, gsize start, gsize end)
{
  if (end <= start || layout->n_ranges == G_N_ELEMENTS (layout->starts)) return FALSE;
  for (guint i = 0; i < layout->n_ranges; i++)
    if (start < layout->ends[i] && end > layout->starts[i]) return FALSE;
  layout->starts[layout->n_ranges] = start; layout->ends[layout->n_ranges++] = end;
  return TRUE;
}

static gboolean
skip_properties (Cursor *cursor)
{
  for (guint i = 0; i < 256; i++) {
    guint32 property, size;
    if (!word (cursor, &property) || !word (cursor, &size)) return FALSE;
    if (!property) return !size;
    if (size > cursor->end - cursor->pos) return FALSE;
    cursor->pos += size;
  }
  return FALSE;
}

static gboolean
item_properties (Cursor *cursor, const ItemState *expected, gint layer_kind)
{
  gboolean seen[64] = {FALSE};
  for (guint i = 0; i < 256; i++) {
    guint32 property, size, value;
    if (!word (cursor, &property) || !word (cursor, &size)) return FALSE;
    if (!property) return !size && seen[20] && seen[8] &&
        (layer_kind < 0 || seen[15]) && seen[29] == (layer_kind == 1) &&
        seen[30] == (layer_kind >= 0 && expected->depth == 2);
    if (property >= G_N_ELEMENTS (seen) || seen[property] || size > cursor->end - cursor->pos) return FALSE;
    seen[property] = TRUE;
    Cursor payload = *cursor; payload.end = payload.pos + size;
    switch (property) {
    case 4: case 5: case 26: case 47: case 48: case 49: return FALSE;
    case 8:
      if (size != 4 || !word (&payload, &value) || value != (guint32) expected->visible) return FALSE;
      break;
    case 15:
      if (layer_kind < 0 || size != 8 || !word (&payload, &value) || (gint32) value != expected->x ||
          !word (&payload, &value) || (gint32) value != expected->y) return FALSE;
      break;
    case 20:
      if (size != 4 || !word (&payload, &value) || value != expected->tattoo) return FALSE;
      break;
    case 29:
      if (layer_kind != 1 || size) return FALSE;
      break;
    case 30:
      if (layer_kind < 0 || expected->depth != 2 || size != 8 ||
          !word (&payload, &value) || value != expected->path[0] ||
          !word (&payload, &value) || value != expected->path[1]) return FALSE;
      break;
    default: break;
    }
    cursor->pos += size;
  }
  return FALSE;
}

/* For 8x6 buffers there is one hierarchy level and one tile. We validate
 * dimensions, bytes-per-pixel and table termination, but never decode pixels. */
static gboolean
hierarchy (Cursor cursor, Layout *layout, gsize offset, gboolean gray)
{
  guint32 value;
  gsize level, tile, zero;
  cursor.pos = offset;
  if (!anchor (layout, offset) || !word (&cursor, &value) || value != W ||
      !word (&cursor, &value) || value != H || !word (&cursor, &value) || value != (gray ? 4u : 16u) ||
      !address (&cursor, &level) || !level || !address (&cursor, &zero) || zero ||
      level != cursor.pos || !metadata_range (layout, offset, cursor.pos)) return FALSE;
  cursor.pos = level;
  if (!anchor (layout, level) || !word (&cursor, &value) || value != W ||
      !word (&cursor, &value) || value != H || !address (&cursor, &tile) || !tile ||
      !address (&cursor, &zero) || zero || tile != cursor.pos ||
      !metadata_range (layout, level, cursor.pos) || !anchor (layout, tile)) return FALSE;
  return TRUE;
}

static gboolean channel_record (Cursor cursor, Layout *layout, gsize offset,
                                const gchar *name, const ItemState *expected,
                                gint effect_index, const Snapshot *source);

static gboolean
effect_record (Cursor cursor, Layout *layout, gsize offset, guint index, const Snapshot *source)
{
  static const guint32 prefix[] = {8, 33, 7, 37, 36, 35, 46, 44};
  const FxSpec *spec = &fx_specs[index];
  gsize mask;
  cursor.pos = offset; layout->effects[index] = offset;
  if (!anchor (layout, offset) || !text_is (&cursor, spec->name) || !text_is (&cursor, ICON) ||
      !text_is (&cursor, spec->operation) || !text_is (&cursor, gegl_operation_get_op_version (spec->operation))) return FALSE;
  for (guint i = 0; i < G_N_ELEMENTS (prefix); i++) {
    guint32 property, size, value;
    if (!word (&cursor, &property) || property != prefix[i] || !word (&cursor, &size) || size != 4) return FALSE;
    gsize payload = cursor.pos;
    if (!word (&cursor, &value) || (i == 0 && value != 1) || (i == 1 && as_float (value) != .625f) ||
        (i == 2 && value != GIMP_LAYER_MODE_MULTIPLY) || (i == 6 && value != 1) ||
        (i == 7 && value != GIMP_FILTER_REGION_DRAWABLE)) return FALSE;
    if (i >= 3 && i <= 5) { layout->fields[index][i - 3] = payload; layout->values[index][i - 3] = value; }
  }
  guint args = 0;
  gboolean ended = FALSE;
  for (guint i = 0; i < 3; i++) {
    guint32 property, size, type, bits;
    if (!word (&cursor, &property) || !word (&cursor, &size)) return FALSE;
    if (!property) { if (size) return FALSE; ended = TRUE; break; }
    if (property != 45 || size > cursor.end - cursor.pos || (index != 0 && index != 2)) return FALSE;
    Cursor payload = cursor; payload.end = payload.pos + size;
    if (!(args & 1) && text_is (&payload, "black-level")) {
      if (!word (&payload, &type) || type != 3 || !word (&payload, &bits) || as_float (bits) != (gfloat) spec->black) return FALSE;
      args |= 1;
    } else {
      payload = cursor; payload.end = payload.pos + size;
      if ((args & 2) || !text_is (&payload, "exposure") || !word (&payload, &type) || type != 3 ||
          !word (&payload, &bits) || as_float (bits) != (gfloat) spec->exposure) return FALSE;
      args |= 2;
    }
    if (payload.pos != payload.end) return FALSE;
    cursor.pos += size;
  }
  if (!ended || args != ((index == 0 || index == 2) ? 3u : 0u) || !address (&cursor, &mask) ||
      mask != cursor.pos || !metadata_range (layout, offset, cursor.pos)) return FALSE;
  gchar *name = g_strdup_printf ("%s mask", spec->name);
  ItemState mask_state = {.tattoo = source->fx[index].mask_tattoo, .width = W, .height = H,
      .x = source->fx[index].mask_x, .y = source->fx[index].mask_y, .visible = source->fx[index].mask_visible};
  gboolean ok = channel_record (cursor, layout, mask, name, &mask_state, -1, source);
  g_free (name);
  return ok;
}

static gboolean
channel_record (Cursor cursor, Layout *layout, gsize offset, const gchar *name,
                const ItemState *expected, gint effect_index, const Snapshot *source)
{
  guint32 value;
  gsize buffer, effect = 0, zero;
  cursor.pos = offset;
  if (!anchor (layout, offset) || !word (&cursor, &value) || value != W || !word (&cursor, &value) || value != H ||
      !text_is (&cursor, name) || !item_properties (&cursor, expected, -1) ||
      !address (&cursor, &buffer) || !buffer) return FALSE;
  if (effect_index >= 0 && (!address (&cursor, &effect) || !effect)) return FALSE;
  if (!address (&cursor, &zero) || zero || buffer != cursor.pos ||
      !metadata_range (layout, offset, cursor.pos) || !hierarchy (cursor, layout, buffer, TRUE)) return FALSE;
  return effect_index < 0 || effect_record (cursor, layout, effect, (guint) effect_index, source);
}

static gboolean
layer_record (Cursor cursor, Layout *layout, gsize offset, guint index, const Snapshot *source)
{
  static const gchar *names[] = {GROUP_NAME, CHILD_NAME, BACKGROUND_NAME};
  guint32 value;
  gsize buffer, mask, effects[2] = {0}, zero;
  cursor.pos = offset; layout->layers[index] = offset;
  if (!anchor (layout, offset) || !word (&cursor, &value) || value != W || !word (&cursor, &value) || value != H ||
      !word (&cursor, &value) || value != 1 || !text_is (&cursor, names[index]) ||
      !item_properties (&cursor, &source->layers[index], index == 0 ? 1 : 0) ||
      !address (&cursor, &buffer) || !buffer || !address (&cursor, &mask) || (mask != 0) != (index == 1)) return FALSE;
  if (index == 1 && (!address (&cursor, &effects[0]) || !effects[0] ||
                    !address (&cursor, &effects[1]) || !effects[1])) return FALSE;
  if (!address (&cursor, &zero) || zero || buffer != cursor.pos ||
      !metadata_range (layout, offset, cursor.pos) || !hierarchy (cursor, layout, buffer, FALSE)) return FALSE;
  if (index != 1) return TRUE;
  layout->layer_mask = mask;
  return channel_record (cursor, layout, mask, MASK_NAME, &source->mask, 2, source) &&
      effect_record (cursor, layout, effects[0], 0, source) && effect_record (cursor, layout, effects[1], 1, source);
}

static guint
occurrences (const guint8 *bytes, gsize size, const gchar *needle)
{
  gsize length = strlen (needle) + 1;
  guint count = 0;
  if (length <= size) for (gsize i = 0; i <= size - length; i++) if (!memcmp (bytes + i, needle, length)) count++;
  return count;
}

static gboolean
no_glims_namespace (const guint8 *bytes, gsize size)
{
  for (gsize i = 0; i + 5 <= size; i++)
    if (g_ascii_tolower (bytes[i]) == 'g' && g_ascii_tolower (bytes[i + 1]) == 'l' &&
        g_ascii_tolower (bytes[i + 2]) == 'i' && g_ascii_tolower (bytes[i + 3]) == 'm' &&
        g_ascii_tolower (bytes[i + 4]) == 's') return FALSE;
  return TRUE;
}

static gboolean
walk_file (const guint8 *bytes, gsize size, const Snapshot *source, Layout *layout)
{
  Cursor cursor = {bytes, size, 14, size};
  guint32 value;
  gsize layers[3], channel, zero;
  memset (layout, 0, sizeof *layout);
  if (size < 30 || size > MAX_FILE || memcmp (bytes, "gimp xcf v026\0", 14) ||
      !word (&cursor, &value) || value != W || !word (&cursor, &value) || value != H ||
      !word (&cursor, &value) || value != 0 || !word (&cursor, &value) || value != 600 || !skip_properties (&cursor)) return FALSE;
  for (guint i = 0; i < 3; i++) if (!address (&cursor, &layers[i]) || !layers[i]) return FALSE;
  if (!address (&cursor, &zero) || zero || !address (&cursor, &channel) || !channel ||
      !address (&cursor, &zero) || zero || !address (&cursor, &zero) || zero ||
      !metadata_range (layout, 0, cursor.pos)) return FALSE;
  for (guint i = 0; i < 4; i++)
    /* Each sentinel also occurs in the effect-mask name, with a non-NUL suffix.
     * Requiring the complete NUL-terminated name to occur once excludes that. */
    if (occurrences (bytes, size, fx_specs[i].name) != 1) return FALSE;
  for (guint i = 0; i < 3; i++) if (!layer_record (cursor, layout, layers[i], i, source)) return FALSE;
  layout->channel = channel;
  if (!channel_record (cursor, layout, channel, CHANNEL_NAME, &source->channel, 3, source)) return FALSE;
  for (guint i = 0; i < layout->n_anchors; i++)
    for (guint j = 0; j < layout->n_ranges; j++)
      if (layout->anchors[i] > layout->starts[j] && layout->anchors[i] < layout->ends[j]) return FALSE;
  return TRUE;
}

static gboolean
read_file (const gchar *path, gchar **bytes, gsize *size)
{
  GError *error = NULL;
  gboolean ok = g_file_get_contents (path, bytes, size, &error) && *size <= MAX_FILE;
  if (!ok) fprintf (stderr, "OBS file read: %s\n", error ? error->message : "size limit");
  g_clear_error (&error);
  return ok;
}

static gboolean
write_file (const gchar *path, const gchar *bytes, gsize size)
{
  GError *error = NULL;
  gboolean ok = g_file_set_contents (path, bytes, (gssize) size, &error);
  if (!ok) fprintf (stderr, "OBS file write: %s\n", error ? error->message : "unknown error");
  g_clear_error (&error);
  return ok;
}

static gboolean
public_tree (Fixture *fixture)
{
  GlimsLayerInfo layers[4] = {{0}};
  GlimsChannelInfo channels[2] = {{0}};
  gint32 layer_count = -1, channel_count = -1;
  return api->image_layers (fixture->engine, fixture->id, layers, 4, &layer_count) == GLIMS_STATUS_OK && layer_count == 3 &&
      api->image_channels (fixture->engine, fixture->id, channels, 2, &channel_count) == GLIMS_STATUS_OK && channel_count == 1 &&
      layers[0].kind == GLIMS_LAYER_GROUP && !layers[0].parent && layers[0].depth == 0 &&
      layers[1].kind == GLIMS_LAYER_PIXEL && layers[1].parent == layers[0].id && layers[1].depth == 1 && layers[1].has_mask &&
      layers[2].kind == GLIMS_LAYER_PIXEL && !layers[2].parent && layers[2].depth == 0 &&
      !strcmp (layers[0].name, GROUP_NAME) && !strcmp (layers[1].name, CHILD_NAME) && !strcmp (layers[2].name, BACKGROUND_NAME) &&
      !strcmp (channels[0].name, CHANNEL_NAME) && !channels[0].quick_mask && !channels[0].visible &&
      layers[0].filter_count == 0 && layers[1].filter_count == 2 && layers[2].filter_count == 0;
}

static gboolean
clean_open (Fixture *fixture, const gchar *path)
{
  GlimsUndoInfo undo = {0};
  GFile *expected = g_file_new_for_path (path), *actual = gimp_image_get_file (fixture->image);
  gboolean same_file = actual && g_file_equal (expected, actual);
  g_object_unref (expected);
  return same_file && !gimp_image_is_dirty (fixture->image) &&
      !gimp_image_parasite_find (fixture->image, "glims-effect-state-v1") &&
      api->image_undo_info (fixture->engine, fixture->id, &undo) == GLIMS_STATUS_OK && !undo.undo_count && !undo.redo_count;
}

static void
append_hash (GString *json, const gchar *name, const gfloat *values, gsize size, gboolean comma)
{
  gchar *hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guint8 *) values, size);
  g_string_append_printf (json, "    \"%s\": \"%s\"%s\n", name, hash, comma ? "," : "");
  g_free (hash);
}

static gboolean
write_manifest (const gchar *path, const gchar *native_hash, const gchar *foreign_hash,
                const Layout *layout, const Snapshot *source)
{
  GString *json = g_string_new ("{\n  \"engine\": \"3.2.8\", \"xcf_version\": 26,\n");
  g_string_append_printf (json, "  \"native_sha256\": \"%s\",\n  \"foreign_sha256\": \"%s\",\n  \"patches\": [\n", native_hash, foreign_hash);
  for (guint i = 0; i < 4; i++) for (guint j = 0; j < 3; j++)
    g_string_append_printf (json, "    {\"effect\": %u, \"property\": %u, \"offset\": %zu, \"before\": %u, \"after\": %u}%s\n",
        i, (guint32[]) {37, 36, 35}[j], layout->fields[i][j], layout->values[i][j], (guint32[]) {2, 2, 3}[j],
        i == 3 && j == 2 ? "" : ",");
  g_string_append (json, "  ],\n  \"source_items\": [\n");
  const ItemState *items[] = {&source->layers[0], &source->layers[1], &source->layers[2], &source->mask, &source->channel};
  const gchar *names[] = {GROUP_NAME, CHILD_NAME, BACKGROUND_NAME, MASK_NAME, CHANNEL_NAME};
  for (guint i = 0; i < G_N_ELEMENTS (items); i++) {
    const ItemState *item = items[i];
    g_string_append_printf (json, "    {\"name\": \"%s\", \"tattoo\": %u, \"width\": %u, \"height\": %u, \"offset\": [%d,%d], \"path\": [",
        names[i], item->tattoo, item->width, item->height, item->x, item->y);
    for (guint j = 0; j < item->depth; j++) g_string_append_printf (json, "%s%u", j ? "," : "", item->path[j]);
    g_string_append_printf (json, "]}%s\n", i == G_N_ELEMENTS (items) - 1 ? "" : ",");
  }
  g_string_append (json, "  ],\n  \"source_effects\": [\n");
  for (guint i = 0; i < 4; i++) {
    const FxState *fx = &source->fx[i];
    g_string_append_printf (json, "    {\"name\": \"%s\", \"operation\": \"%s\", \"mode\": %d, \"opacity\": %.17g, \"spaces\": [%d,%d,%d], \"black\": %.17g, \"exposure\": %.17g, \"mask_tattoo\": %u}%s\n",
        fx_specs[i].name, fx_specs[i].operation, fx->mode, fx->opacity, fx->blend, fx->composite, fx->combination,
        fx->black, fx->exposure, fx->mask_tattoo, i == 3 ? "" : ",");
  }
  g_string_append (json, "  ],\n  \"source_float_sha256\": {\n");
  append_hash (json, "raw_background", source->raw_background, sizeof source->raw_background, TRUE);
  append_hash (json, "raw_child", source->raw_child, sizeof source->raw_child, TRUE);
  append_hash (json, "raw_group", source->raw_group, sizeof source->raw_group, TRUE);
  append_hash (json, "raw_layer_mask", source->raw_mask, sizeof source->raw_mask, TRUE);
  append_hash (json, "raw_saved_channel", source->raw_channel, sizeof source->raw_channel, TRUE);
  append_hash (json, "rendered_child", source->child_result, sizeof source->child_result, TRUE);
  append_hash (json, "rendered_layer_mask", source->mask_result, sizeof source->mask_result, TRUE);
  append_hash (json, "rendered_saved_channel", source->channel_result, sizeof source->channel_result, TRUE);
  append_hash (json, "rendered_group", source->group_result, sizeof source->group_result, TRUE);
  append_hash (json, "image_composite", source->composite, sizeof source->composite, TRUE);
  for (guint i = 0; i < 4; i++) {
    gchar *name = g_strdup_printf ("raw_effect_mask_%u", i);
    append_hash (json, name, source->fx[i].mask_raw, sizeof source->fx[i].mask_raw, i != 3);
    g_free (name);
  }
  g_string_append (json, "  }\n}\n");
  gboolean ok = write_file (path, json->str, json->len);
  g_string_free (json, TRUE);
  return ok;
}

static gboolean
bytes_unchanged (const gchar *path, const gchar *expected, gsize expected_size)
{
  gchar *actual = NULL;
  gsize size = 0;
  gboolean ok = read_file (path, &actual, &size) && size == expected_size && !memcmp (actual, expected, size);
  g_free (actual);
  return ok;
}

static gboolean
source_same (const Snapshot *a, const Snapshot *b)
{
  if (!metadata_same (a, b) || !raw_same (a, b) || !rendered_same (a, b) || memcmp (&a->undo, &b->undo, sizeof a->undo)) return FALSE;
  for (guint i = 0; i < 4; i++) if (a->fx[i].mask_tattoo != b->fx[i].mask_tattoo) return FALSE;
  return TRUE;
}

static GlimsStatus
regression (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture source = {0}, loaded = {0};
  Snapshot before = {0}, after_save = {0}, observed = {0}, automatic = {0};
  FileState saved_state = {0};
  GlimsImageID opened = 0;
  gchar *native_path = g_build_filename (work_dir, "complex-native-unpatched.xcf", NULL);
  gchar *foreign_path = g_build_filename (work_dir, "complex-foreign-explicit.xcf", NULL);
  gchar *manifest_path = g_build_filename (work_dir, "complex-oracle.json", NULL);
  gchar *original = NULL, *patched = NULL, *native_hash = NULL, *foreign_hash = NULL;
  gsize size = 0;
  Layout layout = {0}, encoded = {0};
  gfloat swapped[N * 4];
  char *error = NULL;
  NEED (!strcmp (api->engine_version (engine), "3.2.8"), "complex oracle runs only on pinned GIMP 3.2.8");
  NEED (gegl_has_operation ("gegl:exposure") && gegl_has_operation ("gegl:invert-linear"),
        "both independent non-Curves GEGL operations are installed");
  NEED (create_source (engine, &source), "native source creates exact group child background layer-mask and saved-channel shape with four effects");
  NEED (capture (&source, &before), "source captures native tree owners ordered effects all raw planes effect masks rendered planes and image composite before file I/O");
  CHECK (public_tree (&source), "public source tree independently exposes group nesting two child effects one layer mask and one saved channel");
  CHECK (all_explicit (&before), "all four source effects own literal non-AUTO 2 2 3 settings with exact mode opacity operation config active clip and region");
  CHECK (!memcmp (before.raw_child, source.child_input, sizeof source.child_input) &&
      !memcmp (before.raw_background, source.background_input, sizeof source.background_input) &&
      !memcmp (before.raw_mask, source.mask_input, sizeof source.mask_input) &&
      !memcmp (before.raw_channel, source.channel_input, sizeof source.channel_input),
      "native raw source pixels exactly equal independently generated textured partial-alpha and fractional-mask inputs");
  CHECK (before.apply_mask && !before.edit_mask && !before.show_mask,
        "fractional layer mask is applied without edit or show-mask state");
  NEED (gimp_container_reorder (gimp_drawable_get_filters (GIMP_DRAWABLE (source.child)), GIMP_OBJECT (source.fx[0]), 1) &&
      drawable_pixels (GIMP_DRAWABLE (source.child), TRUE, FALSE, swapped), "native reordered child effects yield a finite counter-oracle");
  gdouble order_delta = delta (before.child_result, swapped, N * 4);
  printf ("OBS reversed_child_effects_delta=%.9g\n", order_delta);
  CHECK (isfinite (order_delta) && order_delta > 1e-4, "child Exposure and Invert order is independently noncommuting");
  NEED (gimp_container_reorder (gimp_drawable_get_filters (GIMP_DRAWABLE (source.child)), GIMP_OBJECT (source.fx[0]), 0) &&
      capture (&source, &observed) && source_same (&before, &observed), "restoring child stack order restores exact source state without adding history");
  for (guint i = 0; i < 4; i++) set_fields (source.fx[i], FALSE);
  NEED (capture (&source, &automatic), "AUTO control captures all finite source planes independently of XCF I/O");
  printf ("OBS AUTO_delta_child=%.9g mask=%.9g channel=%.9g composite=%.9g\n",
      delta (before.child_result, automatic.child_result, N * 4), delta (before.mask_result, automatic.mask_result, N),
      delta (before.channel_result, automatic.channel_result, N), delta (before.composite, automatic.composite, N * 4));
  CHECK (delta (before.child_result, automatic.child_result, N * 4) > 1e-4 &&
      delta (before.mask_result, automatic.mask_result, N) > 1e-4 &&
      delta (before.channel_result, automatic.channel_result, N) > 1e-4 &&
      delta (before.composite, automatic.composite, N * 4) > 1e-4,
      "explicit fields visibly affect child layer-mask saved-channel and image planes rather than only getters");
  for (guint i = 0; i < 4; i++) set_fields (source.fx[i], TRUE);
  NEED (capture (&source, &observed) && source_same (&before, &observed),
        "restoring explicit fields restores exact pre-save float bytes metadata and native history");
  CHECK (!gimp_image_parasite_find (source.image, "glims-effect-state-v1"), "source has no Glims preservation carrier before direct native save");
  NEED (native_save (&source, native_path), "complex source saves through direct native file_save with no Glims preservation hook");
  NEED (capture (&source, &after_save) && file_state (&source, &saved_state), "post-save source file savepoint history and all native planes are captured");
  CHECK (source_same (&before, &after_save), "direct native save preserves every source tree effect setting raw rendered and history oracle");
  NEED (read_file (native_path, &original, &size), "bounded original native XCF is retained as a separate byte oracle");
  NEED (no_glims_namespace ((const guint8 *) original, size), "original native XCF has no Glims namespace anywhere in its bytes");
  NEED (walk_file ((const guint8 *) original, size, &after_save, &layout),
        "independent v26 fixed-shape walker validates three flat layers nested path layer mask saved channel all four named operations configs masks and metadata offsets");
  gboolean patch_locations = TRUE;
  for (guint i = 0; i < 4; i++)
    if (layout.fields[i][0] + 12 != layout.fields[i][1] || layout.fields[i][1] + 12 != layout.fields[i][2]) patch_locations = FALSE;
  CHECK (patch_locations, "each of four effects exposes only the ordered four-byte 37 36 35 payloads for patching");
  patched = g_memdup2 (original, size);
  for (guint i = 0; i < 4; i++) for (guint j = 0; j < 3; j++) {
    guint32 value = GUINT32_TO_BE (((guint32[]) {2, 2, 3})[j]);
    memcpy (patched + layout.fields[i][j], &value, 4);
    printf ("OBS effect=%u property=%u payload_offset=%zu before=0x%08x after=%u\n",
        i, ((guint32[]) {37, 36, 35})[j], layout.fields[i][j], layout.values[i][j], ((guint32[]) {2, 2, 3})[j]);
  }
  guint changed = 0;
  gboolean only_payloads = TRUE;
  for (gsize p = 0; p < size; p++) {
    if (original[p] == patched[p]) continue;
    gboolean allowed = FALSE;
    for (guint i = 0; i < 4; i++) for (guint j = 0; j < 3; j++)
      if (p >= layout.fields[i][j] && p - layout.fields[i][j] < 4) allowed = TRUE;
    changed++; if (!allowed) only_payloads = FALSE;
  }
  printf ("OBS patched_bytes_changed=%u eligible_payload_bytes=48\n", changed);
  CHECK (only_payloads && changed <= 48, "patch changes only allowed bytes within twelve four-byte fields and leaves all other file bytes exact");
  NEED (walk_file ((const guint8 *) patched, size, &after_save, &encoded) &&
      !memcmp (layout.fields, encoded.fields, sizeof layout.fields) &&
      !memcmp (layout.layers, encoded.layers, sizeof layout.layers) && !memcmp (layout.effects, encoded.effects, sizeof layout.effects) &&
      layout.layer_mask == encoded.layer_mask && layout.channel == encoded.channel,
      "patched bytes revalidate identical fixed structure config order masks tree and eligible payload addresses");
  gboolean encoded_explicit = TRUE;
  for (guint i = 0; i < 4; i++) for (guint j = 0; j < 3; j++)
    if (encoded.values[i][j] != ((guint32[]) {2, 2, 3})[j]) encoded_explicit = FALSE;
  CHECK (encoded_explicit, "all twelve foreign-file field words are literal valid 2 2 3 integers");
  NEED (write_file (foreign_path, patched, size) && bytes_unchanged (foreign_path, patched, size),
        "patched foreign XCF is preserved on disk separately and exactly matches its byte oracle");
  native_hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guint8 *) original, size);
  foreign_hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guint8 *) patched, size);
  printf ("OBS native_sha256=%s foreign_sha256=%s xcf_version=26 effects=4\n", native_hash, foreign_hash);
  NEED (write_manifest (manifest_path, native_hash, foreign_hash, &layout, &after_save),
        "oracle manifest records original and patched hashes twelve patch locations source identities getters and complete float-plane hashes");
  NEED (api->image_open (engine, foreign_path, &opened, &error) == GLIMS_STATUS_OK,
        "public image_open accepts the complex foreign file without a Glims carrier");
  GlimsOpenImage *loaded_open = glims_lookup_image (engine, opened);
  loaded.engine = engine; loaded.id = opened; loaded.image = loaded_open ? loaded_open->image : NULL;
  NEED (loaded.image && capture (&loaded, &observed), "public reopen retains mandatory exact native group tree layer-mask and saved-channel owners with four ordered genuine effects and finite planes");
  CHECK (public_tree (&loaded), "public reopen exposes exact group child background saved-channel and effect counts");
  CHECK (all_explicit (&observed), "all four reopened native effects preserve every explicit field and independent operation config");
  CHECK (metadata_same (&after_save, &observed), "reopen preserves layer layer-mask and channel tattoos paths geometry mask state effect order settings ownership and effect-mask pixels");
  CHECK (raw_same (&after_save, &observed), "all five reopened native raw float planes exactly equal the independent pre-save source");
  CHECK (!memcmp (after_save.child_result, observed.child_result, sizeof observed.child_result), "child two-effect rendered float bytes match the independent pre-save oracle");
  CHECK (!memcmp (after_save.mask_result, observed.mask_result, sizeof observed.mask_result), "layer-mask Exposure rendered float bytes match the independent pre-save oracle");
  CHECK (!memcmp (after_save.channel_result, observed.channel_result, sizeof observed.channel_result), "saved-channel Invert rendered float bytes match the independent pre-save oracle");
  CHECK (!memcmp (after_save.group_result, observed.group_result, sizeof observed.group_result), "group rendered float bytes match the independent pre-save oracle");
  CHECK (!memcmp (after_save.composite, observed.composite, sizeof observed.composite), "complete native image composite float bytes match the independent pre-save oracle");
  for (guint i = 0; i < 4; i++)
    printf ("OBS loaded_effect=%u fields=%d,%d,%d source_mask_tattoo=%u loaded_mask_tattoo=%u\n", i,
        observed.fx[i].blend, observed.fx[i].composite, observed.fx[i].combination,
        after_save.fx[i].mask_tattoo, observed.fx[i].mask_tattoo);
  printf ("OBS loaded_delta_child=%.9g mask=%.9g channel=%.9g group=%.9g image=%.9g\n",
      delta (after_save.child_result, observed.child_result, N * 4), delta (after_save.mask_result, observed.mask_result, N),
      delta (after_save.channel_result, observed.channel_result, N), delta (after_save.group_result, observed.group_result, N * 4),
      delta (after_save.composite, observed.composite, N * 4));
  CHECK (clean_open (&loaded, foreign_path), "complex foreign reopen is clean with empty native Undo Redo correct file association and no carrier");
  CHECK (capture (&source, &observed) && source_same (&after_save, &observed) && file_state_same (&source, &saved_state),
        "opening another image preserves original native source all identities bytes getters history file associations and savepoint");
  CHECK (bytes_unchanged (native_path, original, size), "public open preserves the entire original unpatched native file and its hash");
  CHECK (bytes_unchanged (foreign_path, patched, size), "public open preserves the entire validated foreign file and its hash");
cleanup:
  if (error) fprintf (stderr, "OBS public open: %s\n", error);
  if (opened) api->image_close (engine, opened);
  if (source.id) api->image_close (engine, source.id);
  file_state_clear (&saved_state); clear_error (&error);
  g_free (native_path); g_free (foreign_path); g_free (manifest_path);
  g_free (original); g_free (patched); g_free (native_hash); g_free (foreign_hash);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  work_dir = argv[1];
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api) return 2;
  gchar *user = g_build_filename (work_dir, "user", NULL), *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngine *engine = NULL;
  char *error = NULL;
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed"); clear_error (&error);
    g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, regression, NULL) == GLIMS_STATUS_OK, "complex foreign oracle runs on the real engine worker");
  api->stop (engine);
  g_free (user); g_free (cache);
  printf ("%s: %u checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

/*
 * Paths: listing an image's paths, reading and replacing their Bézier
 * subpaths, renaming, showing, selecting and deleting them, turning a
 * path into a selection, filling it onto a drawable or drawing it as a
 * line, and on engines that have them turning it into a vector layer;
 * each change one undo step. Runs on the engine thread.
 *
 * GIMP's path tool and Paths dialog do the same with the same engine
 * functions (app/tools/gimppathtool.c, app/display/gimptoolpath.c;
 * app/actions/paths-commands.c; app/pdb/path-cmds.c for strokes from
 * control points). Glims sends a whole path per edit: a subpath is a list
 * of anchors, each with the handle before and after it, which is how GIMP
 * stores a Bézier stroke (control, anchor, control per anchor).
 *
 * Filling goes through the core's own gimp_item_fill with GimpFillOptions
 * (app/core/gimpitem.c, app/path/gimppath.c gimp_path_fill,
 * app/core/gimpdrawable-fill.c), as the Fill Path menu actions do
 * (app/actions/items-commands.c); vector layers come from
 * gimp_vector_layer_new (app/path/gimpvectorlayer.c), as Paths > New
 * Vector Layer does (app/actions/paths-commands.c
 * path_to_vector_layer_cmd_callback).
 */
/* Before engine-private.h: with cairo.h already included, core-types.h
 * types GimpBezierDesc as cairo_path_t, so its num_data is readable. */
#include <cairo.h>

#include "engine-private.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#include "libgimpbase/gimpbase.h"

#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpfilloptions.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpimage-undo-push.h"
#include "core/gimpitem.h"
#include "core/gimpscanconvert.h"
#include "gegl/gimp-gegl-apply-operation.h"
#include "operations/layer-modes/gimp-layer-modes.h"
#include "core/gimplayer.h"
#include "core/gimpstrokeoptions.h"

/* GIMP 3.2 moved app/vectors to app/path; the files kept their names. */
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimprasterizable.h"
#include "path/gimpanchor.h"
#include "path/gimpbezierstroke.h"
#include "path/gimppath.h"
#include "path/gimpstroke.h"
#include "path/gimpvectorlayer.h"
#else
#include "vectors/gimpanchor.h"
#include "vectors/gimpbezierstroke.h"
#include "vectors/gimppath.h"
#include "vectors/gimpstroke.h"
#endif

#include "gimp-intl.h"

/* More points than any path a person draws; it keeps the coordinate
 * buffers' sizes far from overflowing. */
#define MAX_PATH_POINTS 1000000

/* The widest line path_stroke draws; GIMP's own Stroke dialog limit. */
#define MAX_LINE_WIDTH 2000.0

static GimpImage *
writable_image (GlimsEngine  *engine,
                GlimsImageID  id,
                GlimsStatus  *status)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);

  *status = GLIMS_STATUS_OK;
  if (! open)
    *status = GLIMS_STATUS_NOT_FOUND;
  else if (engine->busy > 0)
    *status = GLIMS_STATUS_BUSY;

  return *status == GLIMS_STATUS_OK ? open->image : NULL;
}

/* The path `id` of `image`, or NULL. */
static GimpPath *
find_path (GimpImage   *image,
           GlimsItemID  id)
{
  GimpItem *item = gimp_item_get_by_id (image->gimp, id);

  /* A deleted path keeps its id while the undo stack holds it. */
  if (! GIMP_IS_PATH (item) || gimp_item_get_image (item) != image || ! gimp_item_is_attached (item))
    return NULL;

  return GIMP_PATH (item);
}

static GlimsPoint
point_of (const GimpAnchor *anchor)
{
  return (GlimsPoint) { anchor->position.x, anchor->position.y };
}

/* ---- Listing and reading ----------------------------------------------- */

GlimsStatus
glims_paths (GlimsEngine   *engine,
             GlimsImageID   id,
             GlimsPathInfo *rows,
             int32_t        capacity,
             int32_t       *count)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GList          *paths, *selected, *iter;
  int32_t         n = 0;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (capacity < 0 || (capacity > 0 && ! rows))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  paths    = gimp_image_get_path_list (open->image);
  selected = gimp_image_get_selected_paths (open->image);

  for (iter = paths; iter; iter = iter->next, n++)
    {
      GimpItem      *item = iter->data;
      GlimsPathInfo *row;

      if (n >= capacity)
        continue;

      row = &rows[n];
      memset (row, 0, sizeof *row);
      row->id       = gimp_item_get_id (item);
      row->visible  = gimp_item_get_visible (item) ? true : false;
      row->selected = g_list_find (selected, item) ? true : false;
      g_strlcpy (row->name, gimp_object_get_name (item) ? gimp_object_get_name (item) : "",
                 sizeof row->name);
    }
  g_list_free (paths);

  if (count)
    *count = n;

  return GLIMS_STATUS_OK;
}

/* Each anchor with the controls next to it in the stroke's list; GIMP
 * keeps them as control, anchor, control, but a missing control reads as
 * a handle on its anchor rather than failing. */
static int32_t
read_stroke (GimpStroke     *stroke,
             GlimsPathPoint *points,
             int32_t         capacity,
             int32_t         first,
             gboolean       *closed)
{
  GArray *anchors = gimp_stroke_control_points_get (stroke, closed);
  int32_t n = 0;
  guint   i;

  for (i = 0; i < anchors->len; i++)
    {
      const GimpAnchor *anchor = &g_array_index (anchors, GimpAnchor, i);
      const GimpAnchor *before = i > 0 ? &g_array_index (anchors, GimpAnchor, i - 1) : NULL;
      const GimpAnchor *after  = i + 1 < anchors->len ? &g_array_index (anchors, GimpAnchor, i + 1) : NULL;
      GlimsPathPoint   *point;

      if (anchor->type != GIMP_ANCHOR_ANCHOR)
        continue;

      if (points && first + n < capacity)
        {
          point = &points[first + n];
          point->anchor = point_of (anchor);
          point->in     = before && before->type == GIMP_ANCHOR_CONTROL ? point_of (before) : point->anchor;
          point->out    = after && after->type == GIMP_ANCHOR_CONTROL ? point_of (after) : point->anchor;
        }
      n++;
    }
  g_array_free (anchors, TRUE);

  return n;
}

GlimsStatus
glims_path_get (GlimsEngine    *engine,
                GlimsImageID    id,
                GlimsItemID     path_id,
                GlimsSubpath   *subpaths,
                int32_t         subpath_capacity,
                int32_t        *subpath_count,
                GlimsPathPoint *points,
                int32_t         point_capacity,
                int32_t        *point_count)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpPath       *path;
  GimpStroke     *stroke = NULL;
  int32_t         n_subpaths = 0, n_points = 0;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (subpath_capacity < 0 || point_capacity < 0 ||
      (subpath_capacity > 0 && ! subpaths) || (point_capacity > 0 && ! points))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  path = find_path (open->image, path_id);
  if (! path)
    return GLIMS_STATUS_NOT_FOUND;

  while ((stroke = gimp_path_stroke_get_next (path, stroke)))
    {
      gboolean closed = FALSE;
      int32_t  count  = read_stroke (stroke, points, point_capacity, n_points, &closed);

      if (count == 0)
        continue;

      if (subpaths && n_subpaths < subpath_capacity)
        subpaths[n_subpaths] = (GlimsSubpath) { .count = count, .closed = closed ? true : false };
      n_subpaths++;
      n_points += count;
    }

  if (subpath_count)
    *subpath_count = n_subpaths;
  if (point_count)
    *point_count = n_points;

  return GLIMS_STATUS_OK;
}

/* ---- Writing ----------------------------------------------------------- */

static gboolean
finite_point (GlimsPoint point)
{
  return isfinite (point.x) && isfinite (point.y);
}

static gboolean
valid_geometry (const GlimsSubpath   *subpaths,
                int32_t               subpath_count,
                const GlimsPathPoint *points,
                int32_t               point_count)
{
  int64_t total = 0;
  int32_t i;

  if (subpath_count < 0 || point_count < 0 || point_count > MAX_PATH_POINTS ||
      (subpath_count > 0 && ! subpaths) || (point_count > 0 && ! points))
    return FALSE;

  for (i = 0; i < subpath_count; i++)
    {
      if (subpaths[i].count < 1)
        return FALSE;
      total += subpaths[i].count;
    }
  if (total != point_count)
    return FALSE;

  for (i = 0; i < point_count; i++)
    if (! finite_point (points[i].in) || ! finite_point (points[i].anchor) ||
        ! finite_point (points[i].out))
      return FALSE;

  return TRUE;
}

/* A Bézier stroke from `count` points: control, anchor, control each. */
static GimpStroke *
make_stroke (const GlimsPathPoint *points,
             int32_t               count,
             gboolean              closed)
{
  GimpCoords  defaults = GIMP_COORDS_DEFAULT_VALUES;
  GimpCoords *coords   = g_new (GimpCoords, (gsize) count * 3);
  GimpStroke *stroke;
  int32_t     i;

  for (i = 0; i < count; i++)
    {
      const GlimsPoint corners[3] = { points[i].in, points[i].anchor, points[i].out };
      gint             k;

      for (k = 0; k < 3; k++)
        {
          coords[i * 3 + k]   = defaults;
          coords[i * 3 + k].x = corners[k].x;
          coords[i * 3 + k].y = corners[k].y;
        }
    }

  stroke = gimp_bezier_stroke_new_from_coords (coords, count * 3, closed);
  g_free (coords);

  return stroke;
}

/* Replaces every stroke of `path`; the caller records the undo step. */
static void
replace_strokes (GimpPath             *path,
                 const GlimsSubpath   *subpaths,
                 int32_t               subpath_count,
                 const GlimsPathPoint *points)
{
  GimpStroke *stroke;
  int32_t     first = 0, i;

  gimp_path_freeze (path);

  while ((stroke = gimp_path_stroke_get_next (path, NULL)))
    gimp_path_stroke_remove (path, stroke);

  for (i = 0; i < subpath_count; i++)
    {
      stroke = make_stroke (points + first, subpaths[i].count, subpaths[i].closed);
      gimp_path_stroke_add (path, stroke);
      g_object_unref (stroke);
      first += subpaths[i].count;
    }

  gimp_path_thaw (path);
}

GlimsStatus
glims_path_set (GlimsEngine          *engine,
                GlimsImageID          id,
                GlimsItemID           path_id,
                const char           *name,
                const GlimsSubpath   *subpaths,
                int32_t               subpath_count,
                const GlimsPathPoint *points,
                int32_t               point_count,
                GlimsItemID          *result,
                char                **error)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpPath    *path;

  if (! image)
    return status;
  if (! valid_geometry (subpaths, subpath_count, points, point_count) ||
      (name && (! *name || ! g_utf8_validate (name, -1, NULL))))
    {
      glims_fail (error, NULL, "The path is not valid.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (path_id == 0)
    {
      /* Built before it is added, so adding it is the only undo step. */
      path = gimp_path_new (image, name ? name : _("Path"));
      replace_strokes (path, subpaths, subpath_count, points);
      if (! gimp_image_add_path (image, path, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE))
        {
          g_object_unref (path);
          return glims_fail (error, NULL, "The path could not be added.");
        }
    }
  else
    {
      path = find_path (image, path_id);
      if (! path)
        return GLIMS_STATUS_NOT_FOUND;

      gimp_image_undo_push_path_mod (image, _("Edit Path"), path);
      replace_strokes (path, subpaths, subpath_count, points);
    }

  gimp_image_flush (image);

  if (result)
    *result = gimp_item_get_id (GIMP_ITEM (path));

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_path_change (GlimsEngine           *engine,
                   GlimsImageID           id,
                   GlimsItemID            path_id,
                   const GlimsPathChange *change,
                   char                 **error)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpPath    *path;
  GError      *gerror = NULL;

  if (! image)
    return status;
  if (! change || change->struct_size < sizeof (GlimsPathChange) ||
      change->visible < -1 || change->visible > 1 ||
      (change->name && (! *change->name || ! g_utf8_validate (change->name, -1, NULL))))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  path = find_path (image, path_id);
  if (! path)
    return GLIMS_STATUS_NOT_FOUND;

  if (change->name && g_strcmp0 (change->name, gimp_object_get_name (path)) != 0 &&
      ! gimp_item_rename (GIMP_ITEM (path), change->name, &gerror))
    return glims_fail (error, gerror, "The path could not be renamed.");

  if (change->visible >= 0)
    gimp_item_set_visible (GIMP_ITEM (path), change->visible == 1, TRUE);

  if (change->select)
    {
      GList *list = g_list_prepend (NULL, path);

      gimp_image_set_selected_paths (image, list);
      g_list_free (list);
    }

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_path_delete (GlimsEngine  *engine,
                   GlimsImageID  id,
                   GlimsItemID   path_id)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpPath    *path;

  if (! image)
    return status;

  path = find_path (image, path_id);
  if (! path)
    return GLIMS_STATUS_NOT_FOUND;

  gimp_image_remove_path (image, path, TRUE, NULL);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

/* ---- Using a path ------------------------------------------------------ */

GlimsStatus
glims_path_to_selection (GlimsEngine              *engine,
                         GlimsImageID              id,
                         GlimsItemID               path_id,
                         const GlimsSelectOptions *options)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpPath    *path;
  gdouble      feather;

  if (! image)
    return status;
  /* Only the fields every version of the struct has are read. */
  if (! options || options->struct_size < offsetof (GlimsSelectOptions, corner_radius) ||
      options->operation > GLIMS_SELECT_INTERSECT ||
      ! isfinite (options->feather) || options->feather < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  path = find_path (image, path_id);
  if (! path)
    return GLIMS_STATUS_NOT_FOUND;

  feather = options->feather;
  gimp_item_to_selection (GIMP_ITEM (path), glims_channel_op (options->operation),
                          options->antialias, feather > 0, feather, feather);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_path_stroke (GlimsEngine             *engine,
                   GlimsImageID             id,
                   GlimsItemID              path_id,
                   GlimsItemID              layer_id,
                   const GlimsLineSettings *settings,
                   char                   **error)
{
  GlimsStatus        status;
  GimpImage         *image = writable_image (engine, id, &status);
  GimpPath          *path;
  GimpItem          *layer;
  GimpContext       *context;
  GimpStrokeOptions *options;
  GeglColor         *color;
  GList             *drawables;
  GError            *gerror = NULL;
  gboolean           done;
  const GlimsColor  *c;

  if (! image)
    return status;
  if (! settings || settings->struct_size < sizeof (GlimsLineSettings))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  c = &settings->color;
  if (! isfinite (settings->width) || settings->width <= 0 || settings->width > MAX_LINE_WIDTH ||
      ! isfinite (c->red) || ! isfinite (c->green) || ! isfinite (c->blue) || ! isfinite (c->alpha))
    {
      glims_fail (error, NULL, "The line settings are not valid.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  path = find_path (image, path_id);
  if (! path)
    return GLIMS_STATUS_NOT_FOUND;

  if (layer_id == 0)
    {
      GList *selected = gimp_image_get_selected_layers (image);

      layer = selected ? selected->data : NULL;
    }
  else
    {
      layer = gimp_item_get_by_id (image->gimp, layer_id);
      if (! GIMP_IS_LAYER (layer) || gimp_item_get_image (layer) != image || ! gimp_item_is_attached (layer))
        layer = NULL;
    }
  if (! layer)
    return glims_fail (error, NULL, "Select a layer first.");
  if (gimp_viewable_get_children (GIMP_VIEWABLE (layer)))
    return glims_fail (error, NULL, "A path cannot be drawn on a layer group.");
  if (gimp_item_is_content_locked (layer, NULL))
    return glims_fail (error, NULL, "The layer's pixels are locked.");

  /* The user's settings with the color pinned, as edit.c's fills do. */
  context = gimp_context_new (engine->gimp, "Glims stroke", gimp_get_user_context (engine->gimp));
  color   = gegl_color_new (NULL);
  gegl_color_set_rgba_with_space (color, CLAMP (c->red, 0.0, 1.0), CLAMP (c->green, 0.0, 1.0),
                                  CLAMP (c->blue, 0.0, 1.0), CLAMP (c->alpha, 0.0, 1.0), NULL);
  gimp_context_set_foreground (context, color);
  g_object_unref (color);

  options = gimp_stroke_options_new (engine->gimp, NULL, FALSE);
  g_object_set (options,
                "method", GIMP_STROKE_LINE,
                "width",  settings->width,
                "unit",   gimp_unit_pixel (),
                NULL);
  gimp_context_set_opacity (GIMP_CONTEXT (options), 1.0);
  gimp_context_set_paint_mode (GIMP_CONTEXT (options), GIMP_LAYER_MODE_NORMAL);
  gimp_fill_options_set_antialias (GIMP_FILL_OPTIONS (options), settings->antialias);

  if (! gimp_fill_options_set_by_fill_type (GIMP_FILL_OPTIONS (options), context,
                                            GIMP_FILL_FOREGROUND, &gerror))
    {
      g_object_unref (options);
      g_object_unref (context);
      return glims_fail (error, gerror, "The line could not be set up.");
    }

  drawables = g_list_prepend (NULL, layer);
  done = gimp_item_stroke (GIMP_ITEM (path), drawables, context, options, NULL, TRUE, NULL, &gerror);
  g_list_free (drawables);
  g_object_unref (options);
  g_object_unref (context);

  if (! done)
    return glims_fail (error, gerror, "The path could not be drawn.");

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

/* ---- Filling a path, and vector layers ---------------------------------- */

/* The open image behind `id`, ready for an edit: not busy with a plug-in,
 * an open stroke or a filter session. */
static GlimsOpenImage *
editable_open_image (GlimsEngine  *engine,
                     GlimsImageID  id,
                     GlimsStatus  *status,
                     char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);

  *status = GLIMS_STATUS_OK;
  if (! open)
    *status = GLIMS_STATUS_NOT_FOUND;
  else if (engine->busy > 0)
    *status = GLIMS_STATUS_BUSY;
  else
    *status = glims_edit_ready (engine, open, error);

  return *status == GLIMS_STATUS_OK ? open : NULL;
}

/* The drawable `id` of `open`, or with 0 the image's selected drawable
 * (the layer's mask while mask editing is on, or a selected channel), as
 * GIMP's own fill actions take it. Groups have no pixels to fill and
 * locked drawables are refused before anything changes. */
static GimpDrawable *
fill_target (GlimsOpenImage *open,
             GlimsItemID     id,
             GlimsStatus    *status,
             char          **error)
{
  GimpDrawable *drawable;

  if (id == 0)
    {
      GList *selected = gimp_image_get_selected_drawables (open->image);

      drawable = selected ? selected->data : NULL;
      g_list_free (selected);
      if (! drawable)
        {
          *status = glims_fail (error, NULL, "Select a layer first.");
          return NULL;
        }
    }
  else
    {
      drawable = glims_lookup_drawable (open, id);
      if (! drawable)
        {
          *status = GLIMS_STATUS_NOT_FOUND;
          return NULL;
        }
    }

  if (GIMP_IS_GROUP_LAYER (drawable))
    {
      *status = glims_fail (error, NULL, "A path cannot be filled onto a layer group.");
      return NULL;
    }

  *status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (*status != GLIMS_STATUS_OK)
    return NULL;

  return drawable;
}

GlimsStatus
glims_path_fill (GlimsEngine                 *engine,
                 GlimsImageID                 id,
                 GlimsItemID                  path_id,
                 GlimsItemID                  drawable_id,
                 const GlimsPathFillSettings *settings,
                 char                       **error)
{
  GlimsStatus       status;
  GlimsOpenImage   *open = editable_open_image (engine, id, &status, error);
  GimpImage        *image;
  GimpPath         *path;
  GimpDrawable     *drawable;
  GimpContext      *context;
  GimpFillOptions  *options;
  GeglColor        *color;
  GList            *drawables;
  GError           *gerror = NULL;
  gboolean          done;
  const GlimsColor *c;

  if (! open)
    return status;
  if (! settings || settings->struct_size < sizeof (GlimsPathFillSettings))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  c = &settings->color;
  if (! isfinite (settings->opacity) || settings->opacity < 0.0 || settings->opacity > 1.0 ||
      ! isfinite (c->red) || ! isfinite (c->green) || ! isfinite (c->blue) || ! isfinite (c->alpha))
    {
      glims_fail (error, NULL, "The fill settings are not valid.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  image = open->image;
  path  = find_path (image, path_id);
  if (! path)
    return GLIMS_STATUS_NOT_FOUND;

  drawable = fill_target (open, drawable_id, &status, error);
  if (! drawable)
    return status;

  /* The core refuses a path without fillable geometry only after opening
   * its undo group (gimp_path_fill, then gimp_drawable_fill_path); check
   * the same conditions here, so a failed fill leaves no undo step. */
  {
    const GimpBezierDesc *bezier = gimp_path_get_bezier (path);

    if (! gimp_path_stroke_get_next (path, NULL) || ! bezier || bezier->num_data <= 4)
      return glims_fail (error, NULL, "Not enough points to fill");
  }

  /* The user's settings with the color pinned, as edit.c's fills do; the
   * shared user context itself is never touched. */
  context = gimp_context_new (engine->gimp, "Glims path fill", gimp_get_user_context (engine->gimp));
  color   = gegl_color_new (NULL);
  gegl_color_set_rgba_with_space (color, CLAMP (c->red, 0.0, 1.0), CLAMP (c->green, 0.0, 1.0),
                                  CLAMP (c->blue, 0.0, 1.0), CLAMP (c->alpha, 0.0, 1.0), NULL);
  gimp_context_set_foreground (context, color);
  g_object_unref (color);

  options = gimp_fill_options_new (engine->gimp, NULL, FALSE);
  gimp_context_set_opacity (GIMP_CONTEXT (options), settings->opacity);
  gimp_context_set_paint_mode (GIMP_CONTEXT (options), GIMP_LAYER_MODE_NORMAL);
  gimp_fill_options_set_antialias (options, settings->antialias);

  if (! gimp_fill_options_set_by_fill_type (options, context, GIMP_FILL_FOREGROUND, &gerror))
    {
      g_object_unref (options);
      g_object_unref (context);
      return glims_fail (error, gerror, "The fill could not be set up.");
    }

  /* One undo group ("Fill Path") around the core fill, as GIMP's own
   * Fill commands do (app/actions/items-commands.c items_fill_callback).
   * The core clips to the selection and applies the drawable's mask,
   * active components and pixel locks (gimp_drawable_fill_scan_convert,
   * gimp_drawable_real_apply_buffer). */
  drawables = g_list_prepend (NULL, drawable);
  done = gimp_item_fill (GIMP_ITEM (path), drawables, options, TRUE, NULL, &gerror);
  g_list_free (drawables);
  g_object_unref (options);
  g_object_unref (context);

  if (! done)
    return glims_fail (error, gerror, "The path could not be filled.");

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_path_to_vector_layer (GlimsEngine  *engine,
                            GlimsImageID  id,
                            GlimsItemID   path_id,
                            const char   *name,
                            GlimsItemID  *layer,
                            char        **error)
{
  GlimsStatus     status;
  GlimsOpenImage *open = editable_open_image (engine, id, &status, error);
  GimpPath       *path;

  if (layer)
    *layer = 0;
  if (! open)
    return status;
  if (name && (! *name || ! g_utf8_validate (name, -1, NULL)))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  path = find_path (open->image, path_id);
  if (! path)
    return GLIMS_STATUS_NOT_FOUND;

#if GIMP_CHECK_VERSION (3, 2, 0)
  {
    GimpContext     *context;
    GimpVectorLayer *vector;

    /* A temporary context inheriting the user's settings; the shared
     * user context is never touched. The vector options pull their fill
     * and stroke colors from it (gimp_vector_layer_options_new). */
    context = gimp_context_new (engine->gimp, "Glims vector layer",
                                gimp_get_user_context (engine->gimp));
    vector  = gimp_vector_layer_new (open->image, path, context);
    g_object_unref (context);

    if (! vector)
      return glims_fail (error, NULL, "The vector layer could not be created.");
    /* Name before adding, without another undo step. Refresh in 3.2.0
     * otherwise replaces it with the path name; an explicit name opts
     * out of the core's automatic rename policy on every engine. */
    if (name)
      {
        gimp_rasterizable_set_auto_rename (GIMP_RASTERIZABLE (vector), FALSE);
        gimp_object_set_name (GIMP_OBJECT (vector), name);
      }

    /* Above the selected layer, selected and rendered, one undo step, as
     * Paths > New Vector Layer does (app/actions/paths-commands.c
     * path_to_vector_layer_cmd_callback); gimp_image_add_layer also adds
     * the vector layer's path to the image when it is not attached yet
     * and refreshes the layer. The layer's options hold a reference to
     * the same path object, not a clone. */
    if (! gimp_image_add_layer (open->image, GIMP_LAYER (vector), GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE))
      {
        g_object_unref (vector);
        return glims_fail (error, NULL, "The vector layer could not be added.");
      }

    gimp_vector_layer_refresh (vector);
    gimp_image_flush (open->image);

    if (layer)
      *layer = gimp_item_get_id (GIMP_ITEM (vector));

    return GLIMS_STATUS_OK;
  }
#else
  /* Vector layers arrived in GIMP 3.2; on an older engine this must not
   * degrade to a raster copy, as link layers do not (Engine/place.c). */
  if (error)
    *error = strdup ("This engine has no vector layers; they arrived in GIMP 3.2.");
  return GLIMS_STATUS_UNSUPPORTED;
#endif
}

/* The Line tool (slot 244). The line and its arrowheads form one closed
 * outline, filled once: GIMP's scan converter fills with the even-odd
 * rule (app/core/gimpscanconvert.c), so separate overlapping shapes
 * would cancel where they cross. */

#define MAX_DRAW_LINE_WIDTH 1000.0

typedef struct
{
  double length;  /* tip to base along the line, image pixels */
  double half;    /* half the base width, at least half the line */
  double joint;   /* tip to where the line's edges meet the base */
  double reach;   /* tip to the arrowhead's farthest point along the line */
} LineArrow;

static LineArrow
line_arrow (const GlimsLineDrawSettings *settings)
{
  double    half_line = settings->width / 2.0;
  LineArrow arrow;

  arrow.length = settings->arrow_length / 100.0 * settings->width;
  arrow.half   = MAX (settings->arrow_width / 100.0 * settings->width / 2.0, half_line);
  /* The base runs from each wing to the notch, which concavity moves
   * toward the tip (positive) or away from it; the line's edge meets it
   * where the base crosses the edge's offset from the axis. */
  arrow.joint = arrow.length - settings->arrow_concavity / 100.0 * arrow.length *
                (1.0 - half_line / arrow.half);
  arrow.reach = MAX (arrow.length, arrow.joint);

  return arrow;
}

static void
line_arrow_scale (LineArrow *arrow,
                  double     factor)
{
  arrow->length *= factor;
  arrow->joint  *= factor;
  arrow->reach  *= factor;
}

static gboolean
line_settings_valid (const GlimsLineDrawSettings *s)
{
  const GlimsColor *c = &s->color;

  return isfinite (s->width) && s->width > 0 && s->width <= MAX_DRAW_LINE_WIDTH &&
         isfinite (c->red) && isfinite (c->green) && isfinite (c->blue) && isfinite (c->alpha) &&
         isfinite (s->opacity) && s->opacity >= 0 && s->opacity <= 1 &&
         (s->arrowheads & ~(uint32_t) (GLIMS_LINE_ARROW_START | GLIMS_LINE_ARROW_END)) == 0 &&
         (s->arrowheads == 0 ||
          (isfinite (s->arrow_width) && s->arrow_width >= 10 && s->arrow_width <= 1000 &&
           isfinite (s->arrow_length) && s->arrow_length >= 10 && s->arrow_length <= 5000 &&
           isfinite (s->arrow_concavity) && s->arrow_concavity >= -50 && s->arrow_concavity <= 50));
}

/* The outline: down the line's left edge from start to end, then back
 * up its right edge. Returns the number of points (at most 10). */
static guint
line_outline (GlimsPoint                   start,
              GlimsPoint                   end,
              const GlimsLineDrawSettings *settings,
              GimpVector2                 *points)
{
  double    dx = end.x - start.x, dy = end.y - start.y;
  double    length = hypot (dx, dy);
  double    ux = dx / length, uy = dy / length;
  double    nx = -uy, ny = ux;
  double    half = settings->width / 2.0;
  gboolean  head = (settings->arrowheads & GLIMS_LINE_ARROW_START) != 0;
  gboolean  tail = (settings->arrowheads & GLIMS_LINE_ARROW_END) != 0;
  LineArrow arrow = line_arrow (settings);
  LineArrow first = arrow, last = arrow;
  double    reach = (head ? arrow.reach : 0) + (tail ? arrow.reach : 0);
  guint     n = 0;

  if (reach > length)
    {
      line_arrow_scale (&first, length / reach);
      line_arrow_scale (&last, length / reach);
    }

#define AT(along, across) \
  (points[n++] = (GimpVector2) { start.x + ux * (along) + nx * (across), \
                                 start.y + uy * (along) + ny * (across) })

  if (head)
    {
      AT (0, 0);
      AT (first.length, first.half);
      AT (first.joint, half);
    }
  else
    AT (0, half);

  if (tail)
    {
      AT (length - last.joint, half);
      AT (length - last.length, last.half);
      AT (length, 0);
      AT (length - last.length, -last.half);
      AT (length - last.joint, -half);
    }
  else
    {
      AT (length, half);
      AT (length, -half);
    }

  if (head)
    {
      AT (first.joint, -half);
      AT (first.length, -first.half);
    }
  else
    AT (0, -half);

#undef AT

  return n;
}

/* The part of `drawable` the outline can touch, in drawable
 * coordinates: its bounds widened by a pixel for antialiasing, within
 * the selection. FALSE when that is empty. */
static gboolean
line_area (GimpDrawable      *drawable,
           const GimpVector2 *points,
           guint              count,
           GeglRectangle     *area)
{
  double x1 = points[0].x, y1 = points[0].y, x2 = x1, y2 = y1;
  gint   off_x, off_y, mx, my, mw, mh;

  for (guint i = 1; i < count; i++)
    {
      x1 = MIN (x1, points[i].x);
      y1 = MIN (y1, points[i].y);
      x2 = MAX (x2, points[i].x);
      y2 = MAX (y2, points[i].y);
    }

  if (! gimp_item_mask_intersect (GIMP_ITEM (drawable), &mx, &my, &mw, &mh))
    return FALSE;

  gimp_item_get_offset (GIMP_ITEM (drawable), &off_x, &off_y);
  return gimp_rectangle_intersect (mx, my, mw, mh,
                                   (gint) floor (x1) - 1 - off_x, (gint) floor (y1) - 1 - off_y,
                                   (gint) (ceil (x2) - floor (x1)) + 2, (gint) (ceil (y2) - floor (y1)) + 2,
                                   &area->x, &area->y, &area->width, &area->height);
}

/* gimp_drawable_fill_scan_convert (app/core/gimpdrawable-fill.c, the
 * same in all four engine sets) limited to `area`, which it computes as
 * the whole selection or layer: a short line on a large layer then
 * composites and stores for undo only the pixels it can touch. */
static void
line_fill (GimpDrawable        *drawable,
           GimpFillOptions     *options,
           GimpScanConvert     *scan,
           const GeglRectangle *area)
{
  GimpContext *context = GIMP_CONTEXT (options);
  GeglBuffer  *mask, *buffer;
  gint         off_x, off_y;

  mask = gegl_buffer_new (GEGL_RECTANGLE (0, 0, area->width, area->height), babl_format ("Y u8"));
  gimp_item_get_offset (GIMP_ITEM (drawable), &off_x, &off_y);
  gimp_scan_convert_render (scan, mask, area->x + off_x, area->y + off_y,
                            gimp_fill_options_get_antialias (options));

  buffer = gimp_fill_options_create_buffer (options, drawable,
                                            GEGL_RECTANGLE (0, 0, area->width, area->height),
                                            -area->x, -area->y);
  gimp_gegl_apply_opacity (buffer, NULL, NULL, buffer, mask, 0, 0, 1.0);
  g_object_unref (mask);

  gimp_drawable_apply_buffer (drawable, buffer, GEGL_RECTANGLE (0, 0, area->width, area->height),
                              TRUE, C_("undo-type", "Line"),
                              gimp_context_get_opacity (context),
                              gimp_context_get_paint_mode (context),
                              GIMP_LAYER_COLOR_SPACE_AUTO, GIMP_LAYER_COLOR_SPACE_AUTO,
                              gimp_layer_mode_get_paint_composite_mode (gimp_context_get_paint_mode (context)),
                              NULL, area->x, area->y);
  g_object_unref (buffer);

  gimp_drawable_update (drawable, area->x, area->y, area->width, area->height);
}

GlimsStatus
glims_layer_draw_line (GlimsEngine                 *engine,
                       GlimsImageID                 id,
                       GlimsItemID                  layer_id,
                       GlimsPoint                   start,
                       GlimsPoint                   end,
                       const GlimsLineDrawSettings *settings,
                       char                       **error)
{
  GlimsOpenImage   *open = glims_lookup_image (engine, id);
  GlimsStatus       status;
  GimpImage        *image;
  GimpItem         *layer;
  GimpContext      *context;
  GimpFillOptions  *options;
  GeglColor        *color;
  GimpScanConvert  *scan;
  GimpVector2       points[10];
  guint             count;
  GeglRectangle     area;
  GError           *gerror = NULL;
  const GlimsColor *c;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! settings || settings->struct_size < sizeof (GlimsLineDrawSettings) || ! line_settings_valid (settings))
    {
      glims_fail (error, NULL, "The line settings are not valid.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (! isfinite (start.x) || ! isfinite (start.y) || ! isfinite (end.x) || ! isfinite (end.y) ||
      fabs (start.x) > GIMP_MAX_IMAGE_SIZE * 4.0 || fabs (start.y) > GIMP_MAX_IMAGE_SIZE * 4.0 ||
      fabs (end.x) > GIMP_MAX_IMAGE_SIZE * 4.0 || fabs (end.y) > GIMP_MAX_IMAGE_SIZE * 4.0 ||
      hypot (end.x - start.x, end.y - start.y) < 1e-6)
    {
      glims_fail (error, NULL, "A line needs two different points.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  if (open->component_layout != GLIMS_COMPONENT_LAYOUT_ORDINARY)
    {
      glims_fail (error, NULL, "The Line tool is available for ordinary layered images only.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  image = open->image;
  if (layer_id == 0)
    {
      GList *selected = gimp_image_get_selected_layers (image);

      layer = selected ? selected->data : NULL;
    }
  else
    {
      layer = gimp_item_get_by_id (image->gimp, layer_id);
      if (! GIMP_IS_LAYER (layer) || gimp_item_get_image (layer) != image || ! gimp_item_is_attached (layer))
        layer = NULL;
    }
  if (! layer)
    return glims_fail (error, NULL, "Select a layer first.");
  if (gimp_viewable_get_children (GIMP_VIEWABLE (layer)))
    return glims_fail (error, NULL, "A line cannot be drawn on a layer group.");
  if (gimp_item_is_content_locked (layer, NULL))
    return glims_fail (error, NULL, "The layer's pixels are locked.");

  /* The user's settings with the color, opacity and mode pinned, as
   * glims_path_stroke does. */
  context = gimp_context_new (engine->gimp, "Glims line", gimp_get_user_context (engine->gimp));
  color   = gegl_color_new (NULL);
  c       = &settings->color;
  gegl_color_set_rgba_with_space (color, CLAMP (c->red, 0.0, 1.0), CLAMP (c->green, 0.0, 1.0),
                                  CLAMP (c->blue, 0.0, 1.0), CLAMP (c->alpha, 0.0, 1.0), NULL);
  gimp_context_set_foreground (context, color);
  g_object_unref (color);

  options = gimp_fill_options_new (engine->gimp, NULL, FALSE);
  gimp_context_set_opacity (GIMP_CONTEXT (options), settings->opacity);
  gimp_context_set_paint_mode (GIMP_CONTEXT (options), GIMP_LAYER_MODE_NORMAL);
  gimp_fill_options_set_antialias (options, settings->antialias);
  if (! gimp_fill_options_set_by_fill_type (options, context, GIMP_FILL_FOREGROUND, &gerror))
    {
      g_object_unref (options);
      g_object_unref (context);
      return glims_fail (error, gerror, "The line could not be set up.");
    }

  count = line_outline (start, end, settings, points);
  if (line_area (GIMP_DRAWABLE (layer), points, count, &area))
    {
      scan = gimp_scan_convert_new ();
      gimp_scan_convert_add_polyline (scan, count, points, TRUE);
      line_fill (GIMP_DRAWABLE (layer), options, scan, &area);
      gimp_scan_convert_free (scan);
      gimp_image_flush (image);
    }

  g_object_unref (options);
  g_object_unref (context);

  return GLIMS_STATUS_OK;
}

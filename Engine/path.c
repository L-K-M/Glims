/*
 * Paths: listing an image's paths, reading and replacing their Bézier
 * subpaths, renaming, showing, selecting and deleting them, and turning a
 * path into a selection or a drawn line, each change one undo step. Runs
 * on the engine thread.
 *
 * GIMP's path tool and Paths dialog do the same with the same engine
 * functions (app/tools/gimppathtool.c, app/display/gimptoolpath.c;
 * app/actions/paths-commands.c; app/pdb/path-cmds.c for strokes from
 * control points). Glims sends a whole path per edit: a subpath is a list
 * of anchors, each with the handle before and after it, which is how GIMP
 * stores a Bézier stroke (control, anchor, control per anchor).
 */
#include "engine-private.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#include "libgimpbase/gimpbase.h"

#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "core/gimpfilloptions.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpimage-undo-push.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpstrokeoptions.h"

/* GIMP 3.2 moved app/vectors to app/path; the files kept their names. */
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimpanchor.h"
#include "path/gimpbezierstroke.h"
#include "path/gimppath.h"
#include "path/gimpstroke.h"
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

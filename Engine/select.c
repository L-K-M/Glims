/*
 * Selections: the shapes, color selections and Select menu commands of
 * GIMP's selection tools and actions, each one undo step, and the outline
 * a canvas draws as marching ants. Runs on the engine thread.
 *
 * GIMP's tools call the same engine functions (app/tools/
 * gimprectangleselecttool.c, gimpellipseselecttool.c, gimpfreeselecttool.c,
 * gimpfuzzyselecttool.c, gimpbycolorselecttool.c; app/actions/
 * select-commands.c); the defaults below are those of GIMP's dialogs
 * (app/config/gimpdialogconfig.c).
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpboundary.h"
#include "core/gimpchannel.h"
#include "core/gimpchannel-select.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimppickable.h"
#include "core/gimpprojection.h"

#include "libgimpmath/gimpmath.h"

#include "gimp-intl.h"

static GimpChannelOps
channel_op (uint32_t operation)
{
  switch (operation)
    {
    case GLIMS_SELECT_ADD:       return GIMP_CHANNEL_OP_ADD;
    case GLIMS_SELECT_SUBTRACT:  return GIMP_CHANNEL_OP_SUBTRACT;
    case GLIMS_SELECT_INTERSECT: return GIMP_CHANNEL_OP_INTERSECT;
    default:                     return GIMP_CHANNEL_OP_REPLACE;
    }
}

/* The caller's options with what its struct_size lacks at defaults. */
static gboolean
read_options (const GlimsSelectOptions *options,
              GlimsSelectOptions       *out)
{
  memset (out, 0, sizeof (*out));
  out->antialias = TRUE;
  out->threshold = 15.0 / 255.0;   /* GIMP's default threshold */
  out->contiguous = TRUE;

  if (! options)
    return TRUE;
  if (options->struct_size < offsetof (GlimsSelectOptions, antialias) ||
      options->operation > GLIMS_SELECT_INTERSECT)
    return FALSE;

  memcpy (out, options, MIN (options->struct_size, sizeof (*out)));
  out->struct_size = sizeof (*out);
  out->feather     = MAX (out->feather, 0.0);
  out->threshold   = CLAMP (out->threshold, 0.0, 1.0);

  return TRUE;
}

/* Works around an engine bug (GIMP 3.2.8 and master): after a selection
 * that filled the mask (Select All, Invert of nothing), combining a new
 * shape updates the mask's cached bounds but keeps its "full" flag
 * (gimp_channel_combine_end in app/core/gimpchannel-combine.c). Grow,
 * Shrink, Border and Feather then do nothing, and Invert clears the
 * selection, because they trust that flag (gimp_channel_is_full).
 * Dropping the cache after each change makes the engine recompute both. */
static void
forget_mask_state (GimpChannel *mask)
{
  gimp_drawable_invalidate_boundary (GIMP_DRAWABLE (mask));
}

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

GlimsStatus
glims_select_shape (GlimsEngine              *engine,
                    GlimsImageID              id,
                    uint32_t                  shape,
                    const GlimsPoint         *points,
                    size_t                    count,
                    const GlimsSelectOptions *options)
{
  GlimsSelectOptions settings;
  GlimsStatus        status;
  GimpImage         *image = writable_image (engine, id, &status);
  GimpChannel       *mask;
  GimpChannelOps     op;
  gboolean           feather;
  gint               x, y, w, h;

  if (! image)
    return status;
  if (! points || ! read_options (options, &settings))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  mask    = gimp_image_get_mask (image);
  op      = channel_op (settings.operation);
  feather = settings.feather > 0.0;

  switch (shape)
    {
    case GLIMS_SHAPE_RECTANGLE:
    case GLIMS_SHAPE_ELLIPSE:
      if (count != 2)
        return GLIMS_STATUS_INVALID_ARGUMENT;

      /* Two opposite corners, in either order, snapped to whole pixels as
       * GIMP's rectangle tools do. */
      x = (gint) floor (MIN (points[0].x, points[1].x));
      y = (gint) floor (MIN (points[0].y, points[1].y));
      w = (gint) ceil (MAX (points[0].x, points[1].x)) - x;
      h = (gint) ceil (MAX (points[0].y, points[1].y)) - y;
      if (w < 1 || h < 1)
        return GLIMS_STATUS_INVALID_ARGUMENT;

      if (shape == GLIMS_SHAPE_ELLIPSE)
        gimp_channel_select_ellipse (mask, x, y, w, h, op, settings.antialias,
                                     feather, settings.feather, settings.feather, TRUE);
      else if (settings.corner_radius > 0.0)
        gimp_channel_select_round_rect (mask, x, y, w, h,
                                        settings.corner_radius, settings.corner_radius,
                                        op, settings.antialias,
                                        feather, settings.feather, settings.feather, TRUE);
      else
        gimp_channel_select_rectangle (mask, x, y, w, h, op,
                                       feather, settings.feather, settings.feather, TRUE);
      break;

    case GLIMS_SHAPE_POLYGON:
      {
        GimpVector2 *vectors;
        size_t       i;

        if (count < 3)
          return GLIMS_STATUS_INVALID_ARGUMENT;

        vectors = g_new (GimpVector2, count);
        for (i = 0; i < count; i++)
          vectors[i] = (GimpVector2) { points[i].x, points[i].y };

        gimp_channel_select_polygon (mask, C_("undo-type", "Free Select"), (gint) count, vectors,
                                     op, settings.antialias,
                                     feather, settings.feather, settings.feather, TRUE);
        g_free (vectors);
      }
      break;

    default:
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  forget_mask_state (mask);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

/* The active layer, as GIMP's fuzzy and by-color tools use it. */
static GimpDrawable *
active_drawable (GimpImage *image)
{
  GList        *drawables = gimp_image_get_selected_drawables (image);
  GimpDrawable *drawable  = drawables ? drawables->data : NULL;

  g_list_free (drawables);

  return drawable;
}

GlimsStatus
glims_select_color (GlimsEngine              *engine,
                    GlimsImageID              id,
                    GlimsPoint                point,
                    const GlimsSelectOptions *options,
                    char                    **error)
{
  GlimsSelectOptions settings;
  GlimsStatus        status;
  GimpImage         *image = writable_image (engine, id, &status);
  GimpDrawable      *drawable;
  GimpChannel       *mask;
  gboolean           feather;

  if (! image)
    return status;
  if (! read_options (options, &settings))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  drawable = active_drawable (image);
  if (! drawable)
    return glims_fail (error, NULL, "Select a layer first.");

  mask    = gimp_image_get_mask (image);
  feather = settings.feather > 0.0;

  if (settings.contiguous)
    {
      gint x = (gint) floor (point.x);
      gint y = (gint) floor (point.y);

      /* The point is in image coordinates; GIMP's fuzzy tool converts it
       * to the drawable's unless it samples the whole image. */
      if (! settings.sample_merged)
        {
          gint offset_x, offset_y;

          gimp_item_get_offset (GIMP_ITEM (drawable), &offset_x, &offset_y);
          x -= offset_x;
          y -= offset_y;
        }

      gimp_channel_select_fuzzy (mask, drawable, settings.sample_merged, x, y,
                                 (gfloat) settings.threshold, TRUE,
                                 GIMP_SELECT_CRITERION_COMPOSITE, FALSE,
                                 channel_op (settings.operation), settings.antialias,
                                 feather, settings.feather, settings.feather);
    }
  else
    {
      GimpPickable *pickable;
      GeglColor    *color;
      GList        *drawables;
      gint          x = (gint) floor (point.x);
      gint          y = (gint) floor (point.y);

      if (settings.sample_merged)
        {
          pickable = GIMP_PICKABLE (image);
        }
      else
        {
          gint offset_x, offset_y;

          gimp_item_get_offset (GIMP_ITEM (drawable), &offset_x, &offset_y);
          pickable = GIMP_PICKABLE (drawable);
          x -= offset_x;
          y -= offset_y;
        }

      gimp_pickable_flush (pickable);
      color = gimp_pickable_get_color_at (pickable, x, y);
      if (! color)
        return glims_fail (error, NULL, "The point is outside the layer.");

      drawables = g_list_prepend (NULL, drawable);
      gimp_channel_select_by_color (mask, drawables, settings.sample_merged, color,
                                    (gfloat) settings.threshold, TRUE,
                                    GIMP_SELECT_CRITERION_COMPOSITE,
                                    channel_op (settings.operation), settings.antialias,
                                    feather, settings.feather, settings.feather);
      g_list_free (drawables);
      g_object_unref (color);
    }

  forget_mask_state (mask);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_select_command (GlimsEngine  *engine,
                      GlimsImageID  id,
                      uint32_t      command,
                      double        radius,
                      char        **error)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpChannel *mask;
  gint         pixels = (gint) floor (MAX (radius, 0.0) + 0.5);

  if (! image)
    return status;

  mask = gimp_image_get_mask (image);
  forget_mask_state (mask);

  switch (command)
    {
    case GLIMS_SELECT_ALL:
      gimp_channel_all (mask, TRUE);
      break;
    case GLIMS_SELECT_NONE:
      gimp_channel_clear (mask, NULL, TRUE);
      break;
    case GLIMS_SELECT_INVERT:
      gimp_channel_invert (mask, TRUE);
      break;
    case GLIMS_SELECT_SHARPEN:
      gimp_channel_sharpen (mask, TRUE);
      break;

    case GLIMS_SELECT_FEATHER:
    case GLIMS_SELECT_GROW:
    case GLIMS_SELECT_SHRINK:
    case GLIMS_SELECT_BORDER:
      if (! (radius > 0.0))
        return GLIMS_STATUS_INVALID_ARGUMENT;
      if (gimp_channel_is_empty (mask))
        return glims_fail (error, NULL, "There is no selection to change.");

      if (command == GLIMS_SELECT_FEATHER)
        gimp_channel_feather (mask, radius, radius, TRUE, TRUE);
      else if (command == GLIMS_SELECT_GROW)
        gimp_channel_grow (mask, pixels, pixels, TRUE);
      else if (command == GLIMS_SELECT_SHRINK)
        gimp_channel_shrink (mask, pixels, pixels, FALSE, TRUE);
      else
        gimp_channel_border (mask, pixels, pixels, GIMP_CHANNEL_BORDER_STYLE_SMOOTH, FALSE, TRUE);
      break;

    case GLIMS_SELECT_FROM_ALPHA:
      {
        GimpDrawable *drawable = active_drawable (image);

        if (! drawable)
          return glims_fail (error, NULL, "Select a layer first.");
        gimp_channel_select_alpha (mask, drawable, GIMP_CHANNEL_OP_REPLACE, FALSE, 0.0, 0.0);
      }
      break;

    default:
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  forget_mask_state (mask);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_selection_bounds (GlimsEngine  *engine,
                        GlimsImageID  id,
                        bool         *empty,
                        GlimsRect    *bounds)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpChannel    *mask;
  gint            x, y, w, h;
  gboolean        selected;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! empty || ! bounds)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  mask     = gimp_image_get_mask (open->image);
  selected = ! gimp_channel_is_empty (mask) && gimp_item_bounds (GIMP_ITEM (mask), &x, &y, &w, &h);

  *empty  = ! selected;
  *bounds = selected ? (GlimsRect) { x, y, w, h } : (GlimsRect) { 0, 0, 0, 0 };

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_selection_outline (GlimsEngine  *engine,
                         GlimsImageID  id,
                         GlimsSegment *segments,
                         int32_t       capacity,
                         int32_t      *count)
{
  GlimsOpenImage     *open = glims_lookup_image (engine, id);
  const GimpBoundSeg *segs_in  = NULL;
  const GimpBoundSeg *segs_out = NULL;
  gint                n_in = 0, n_out = 0;
  gint                i;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! count || capacity < 0 || (capacity > 0 && ! segments))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* The selection's own boundary, cached by the engine until it changes;
   * GIMP's display draws the same segments
   * (app/display/gimpdisplayshell-selection.c). */
  if (! gimp_channel_boundary (gimp_image_get_mask (open->image),
                               &segs_in, &segs_out, &n_in, &n_out, 0, 0, 0, 0))
    n_in = 0;

  for (i = 0; i < n_in && i < capacity; i++)
    segments[i] = (GlimsSegment) { segs_in[i].x1, segs_in[i].y1, segs_in[i].x2, segs_in[i].y2 };

  *count = n_in;

  return GLIMS_STATUS_OK;
}

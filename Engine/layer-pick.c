/* Read-only layer picking through GIMP's own hit test.
 * Source: GIMP3.2.8 7addd2b77efb798bbdc4d2fb082e786a48478ced and
 * GIMP3.0.8 6ac8031c9555667e080fef0324fca9f28a02e5ab,
 * app/tools/gimpmovetool.c + app/core/gimpimage-pick-item.c. */
#include "engine-private.h"

#include <limits.h>
#include <math.h>

#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimpimage-pick-item.h"
#include "core/gimplayer.h"

GlimsStatus
glims_image_pick_layer (GlimsEngine *engine,
                        GlimsImageID image,
                        GlimsPoint   point,
                        GlimsItemID *out)
{
  GlimsOpenImage *open;
  GimpLayer      *hit;
  GList          *layers;
  GList          *iter;
  gdouble         tx, ty;
  gint            ix;
  gint            iy;

  if (out)
    *out = 0;

  if (! out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (! engine)
    return GLIMS_STATUS_NOT_RUNNING;

  if (! isfinite (point.x) || ! isfinite (point.y))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Discard fractions in floating point, then check BEFORE any cast.
   * This matches Move's toward-zero conversion wherever it is defined. */
  tx = trunc (point.x);
  ty = trunc (point.y);
  if (tx < G_MININT || tx > G_MAXINT || ty < G_MININT || ty > G_MAXINT)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  ix = (gint) tx;
  iy = (gint) ty;

  open = glims_lookup_image (engine, image);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  /* A pick is a read-only query, but refuse while another long engine
   * operation holds the image busy. The Core pick itself may read/render
   * buffers, so mark the engine busy around it for reentrancy without
   * imposing stroke/filter/preview edit gating. */
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  engine->busy++;
  /* Core subtracts each offset using gint before checking its pixel bounds.
   * Validate that arithmetic, including groups/children in the exact same
   * traversal, using wider integers. This never approximates a hit or clips
   * coordinates to the canvas. The list nodes are owned, its layers borrowed. */
  layers = gimp_image_get_layer_list (open->image);
  for (iter = layers; iter; iter = iter->next)
    {
      gint off_x, off_y;
      gint64 local_x, local_y;
      gimp_item_get_offset (GIMP_ITEM (iter->data), &off_x, &off_y);
      local_x = (gint64) ix - off_x;
      local_y = (gint64) iy - off_y;
      if (local_x < G_MININT || local_x > G_MAXINT ||
          local_y < G_MININT || local_y > G_MAXINT)
        {
          g_list_free (layers);
          engine->busy--;
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
    }
  g_list_free (layers);
  hit = gimp_image_pick_layer (open->image, ix, iy, NULL);
  if (hit)
    {
      gint native_id = gimp_item_get_id (GIMP_ITEM (hit));
      if (native_id <= 0)
        {
          engine->busy--;
          return GLIMS_STATUS_FAILED;
        }
      *out = native_id;
    }
  engine->busy--;
  return GLIMS_STATUS_OK;
}

/*
 * Image > Adjust's one-click commands: Auto Levels (GIMP's White
 * Balance stretch), Equalize, Desaturate, and the Layer > Transparency
 * alpha format changes. Runs on the engine thread.
 *
 * The upstream actions live in GTK code Glims does not link
 * (app/actions/drawable-commands.c drawable_equalize_cmd_callback and
 * drawable_levels_stretch_cmd_callback,
 * app/actions/layers-commands.c layers_alpha_add_cmd_callback and
 * layers_alpha_remove_cmd_callback, and the gimp:desaturate filter in
 * app/actions/filters-actions.c). Each one iterates the image's selected
 * drawables; Glims resolves the same active paint target through
 * gimp_image_get_selected_drawables, which is the selected layer, its
 * mask while mask editing is on, or a selected channel. The core
 * functions they call are unmodified:
 * gimp_drawable_levels_stretch, gimp_drawable_equalize,
 * gimp_drawable_apply_operation with gimp:desaturate,
 * gimp_layer_add_alpha and gimp_layer_remove_alpha.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-equalize.h"
#include "core/gimpdrawable-levels.h"
#include "core/gimpdrawable-operation.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayermask.h"

#include "libgimpbase/gimpbaseenums.h"

#include "gimp-intl.h"

/* The active paint target, as GIMP's own tools and drawable actions
 * resolve it: the selected layer, its mask while mask editing is on, or
 * a selected channel. Glims edits one active target, so the first
 * selected drawable wins, matching the document's active layer; the
 * document refuses several selected channels before the facade is
 * reached. */
static GimpDrawable *
active_drawable (GimpImage    *image,
                 GlimsStatus  *status,
                 char        **error)
{
  GList        *selected = gimp_image_get_selected_drawables (image);
  GimpDrawable *drawable  = selected ? selected->data : NULL;

  g_list_free (selected);

  *status = GLIMS_STATUS_FAILED;
  if (! drawable)
    glims_fail (error, NULL, "Select a layer first.");

  return drawable;
}

/* A context carrying the caller's background color, for
 * gimp_layer_remove_alpha, which composites on the context background
 * (core/gimplayer.c). The color is pinned, never the user's live one. */
static GimpContext *
background_context (Gimp             *gimp,
                    const GlimsColor *background)
{
  GimpContext *context = gimp_context_new (gimp, "Glims adjustment",
                                           gimp_get_user_context (gimp));
  GeglColor   *color   = gegl_color_new (NULL);

  gegl_color_set_rgba_with_space (color,
                                  CLAMP (background->red,   0.0, 1.0),
                                  CLAMP (background->green, 0.0, 1.0),
                                  CLAMP (background->blue,  0.0, 1.0),
                                  CLAMP (background->alpha, 0.0, 1.0),
                                  NULL);
  gimp_context_set_background (context, color);
  g_object_unref (color);

  return context;
}

GlimsStatus
glims_adjustment_apply (GlimsEngine    *engine,
                        GlimsImageID    id,
                        uint32_t        adjustment,
                        const GlimsColor *background,
                        char          **error)
{
  GlimsStatus    status;
  GlimsOpenImage *open;
  GimpImage     *image;
  GimpDrawable  *drawable;
  gboolean      needs_layer;
  gboolean      needs_rgb;
  gboolean      needs_selection;

  switch (adjustment)
    {
    case GLIMS_ADJUSTMENT_AUTO_LEVELS:
    case GLIMS_ADJUSTMENT_EQUALIZE:
    case GLIMS_ADJUSTMENT_DESATURATE:
    case GLIMS_ADJUSTMENT_ADD_ALPHA:
    case GLIMS_ADJUSTMENT_REMOVE_ALPHA:
      break;
    default:
      return glims_fail (error, NULL, "Unknown adjustment.");
    }

  if (adjustment == GLIMS_ADJUSTMENT_REMOVE_ALPHA && ! background)
    return glims_fail (error, NULL, "Removing transparency needs a background color.");

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  image = open->image;

  drawable = active_drawable (image, &status, error);
  if (! drawable)
    return status;

  if (GIMP_IS_GROUP_LAYER (drawable))
    return glims_fail (error, NULL, "A layer group cannot take this adjustment.");

  needs_layer = adjustment == GLIMS_ADJUSTMENT_ADD_ALPHA ||
                adjustment == GLIMS_ADJUSTMENT_REMOVE_ALPHA;
  needs_rgb   = adjustment == GLIMS_ADJUSTMENT_AUTO_LEVELS ||
                adjustment == GLIMS_ADJUSTMENT_DESATURATE;
  needs_selection = adjustment == GLIMS_ADJUSTMENT_AUTO_LEVELS ||
                    adjustment == GLIMS_ADJUSTMENT_EQUALIZE ||
                    adjustment == GLIMS_ADJUSTMENT_DESATURATE;

  if ((needs_layer || needs_rgb) && ! GIMP_IS_LAYER (drawable))
    return glims_fail (error, NULL,
                       "This adjustment works on a layer; stop editing the mask or channel first.");

  if (GIMP_IS_LAYER (drawable))
    switch (glims_layer_kind (GIMP_LAYER (drawable)))
      {
      case GLIMS_LAYER_PIXEL:
        break;
      case GLIMS_LAYER_GROUP:
        return glims_fail (error, NULL, "A layer group cannot take this adjustment.");
      default:
        return glims_fail (error, NULL,
                           "Rasterize the text, link or vector layer before this adjustment.");
      }

  status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  if (needs_rgb && ! gimp_drawable_is_rgb (drawable))
    return glims_fail (error, NULL,
                       adjustment == GLIMS_ADJUSTMENT_AUTO_LEVELS
                       ? "Auto Levels operates only on RGB color layers."
                       : "Desaturate operates only on RGB color layers.");


  if (adjustment == GLIMS_ADJUSTMENT_ADD_ALPHA &&
      gimp_drawable_has_alpha (drawable))
    return glims_fail (error, NULL, "The layer already has an alpha channel.");

  if (adjustment == GLIMS_ADJUSTMENT_REMOVE_ALPHA &&
      ! gimp_drawable_has_alpha (drawable))
    return glims_fail (error, NULL, "The layer has no alpha channel to remove.");

  if (needs_selection &&
      ! gimp_item_mask_intersect (GIMP_ITEM (drawable), NULL, NULL, NULL, NULL))
    return glims_fail (error, NULL, "The selection does not overlap the layer.");

  switch (adjustment)
    {
    case GLIMS_ADJUSTMENT_AUTO_LEVELS:
      gimp_drawable_levels_stretch (drawable, NULL);
      break;

    case GLIMS_ADJUSTMENT_EQUALIZE:
      /* mask_only TRUE: the histogram and the operation both respect the
       * selection, as drawable_equalize_cmd_callback does. */
      gimp_drawable_equalize (drawable, TRUE);
      break;

    case GLIMS_ADJUSTMENT_DESATURATE:
      {
        GeglNode *node = gegl_node_new_child (NULL,
                                              "operation", "gimp:desaturate",
                                              "mode",      (gint) GIMP_DESATURATE_LIGHTNESS,
                                              NULL);

        gimp_drawable_apply_operation (drawable, NULL,
                                       C_("undo-type", "Desaturate"), node);
        g_object_unref (node);
      }
      break;

    case GLIMS_ADJUSTMENT_ADD_ALPHA:
      gimp_layer_add_alpha (GIMP_LAYER (drawable));
      break;

    case GLIMS_ADJUSTMENT_REMOVE_ALPHA:
      {
        GimpContext *context = background_context (engine->gimp, background);

        gimp_layer_remove_alpha (GIMP_LAYER (drawable), context);
        g_object_unref (context);
      }
      break;
    }

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

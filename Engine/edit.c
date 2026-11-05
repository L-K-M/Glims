/*
 * Editing commands: bucket fill and gradient, the Layer menu (new,
 * duplicate, delete, arrange, merge down, flatten, properties), layer
 * selection, moving a layer and cropping the image. Runs on the engine
 * thread.
 *
 * Fill and gradient follow GIMP's PDB procedures, which drive the same
 * engine calls without its GTK tools (app/pdb/drawable-edit-cmds.c); the
 * layer commands follow app/actions/layers-commands.c.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimp-gradients.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-bucket-fill.h"
#include "core/gimpdrawable-edit.h"
#include "core/gimpdrawable-gradient.h"
#include "core/gimpfilloptions.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-crop.h"
#include "core/gimpimage-merge.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"

#include "gimp-intl.h"

/* The image, if it may be changed now. */
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

/* The layer `id` of `image`, or with 0 the first selected layer. */
static GimpLayer *
find_layer (GimpImage   *image,
            GlimsItemID  id)
{
  GimpItem *item;

  if (id == 0)
    {
      GList     *selected = gimp_image_get_selected_layers (image);
      GimpLayer *layer    = selected ? selected->data : NULL;

      return layer;
    }

  item = gimp_item_get_by_id (image->gimp, id);
  if (! GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image)
    return NULL;

  return GIMP_LAYER (item);
}

/* A paint layer (not a group) to fill, or NULL with `error` set. */
static GimpLayer *
paintable_layer (GimpImage    *image,
                 char        **error)
{
  GimpLayer *layer = find_layer (image, 0);

  if (! layer)
    glims_fail (error, NULL, "Select a layer first.");
  else if (GIMP_IS_GROUP_LAYER (layer))
    {
      glims_fail (error, NULL, "Groups cannot be filled.");
      layer = NULL;
    }

  return layer;
}

static GeglColor *
make_color (const GlimsColor *color)
{
  GeglColor *gegl_color = gegl_color_new (NULL);

  gegl_color_set_rgba_with_space (gegl_color,
                                  CLAMP (color->red, 0.0, 1.0), CLAMP (color->green, 0.0, 1.0),
                                  CLAMP (color->blue, 0.0, 1.0), CLAMP (color->alpha, 0.0, 1.0),
                                  NULL);
  return gegl_color;
}

/* A context for one command: the user's settings with the colors pinned. */
static GimpContext *
command_context (Gimp             *gimp,
                 const GlimsColor *foreground,
                 const GlimsColor *background)
{
  GimpContext *context = gimp_context_new (gimp, "Glims command", gimp_get_user_context (gimp));

  if (foreground)
    {
      GeglColor *color = make_color (foreground);

      gimp_context_set_foreground (context, color);
      g_object_unref (color);
    }
  if (background)
    {
      GeglColor *color = make_color (background);

      gimp_context_set_background (context, color);
      g_object_unref (color);
    }

  return context;
}

/* ---- Fill and gradient ------------------------------------------------- */

GlimsStatus
glims_fill (GlimsEngine             *engine,
            GlimsImageID             id,
            GlimsPoint               point,
            const GlimsFillSettings *settings,
            char                   **error)
{
  GlimsStatus      status;
  GimpImage       *image = writable_image (engine, id, &status);
  GimpLayer       *layer;
  GimpContext     *context;
  GimpFillOptions *options;
  GError          *gerror = NULL;

  if (! image)
    return status;
  if (! settings || settings->struct_size < sizeof (GlimsFillSettings) ||
      (settings->mode != GLIMS_FILL_SIMILAR_COLORS && settings->mode != GLIMS_FILL_SELECTION))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  layer = paintable_layer (image, error);
  if (! layer)
    return GLIMS_STATUS_FAILED;

  context = command_context (engine->gimp, &settings->color, NULL);
  options = gimp_fill_options_new (engine->gimp, NULL, FALSE);
  gimp_context_set_opacity (GIMP_CONTEXT (options), CLAMP (settings->opacity, 0.0, 1.0));
  gimp_context_set_paint_mode (GIMP_CONTEXT (options), GIMP_LAYER_MODE_NORMAL);
  gimp_fill_options_set_antialias (options, settings->antialias);

  if (! gimp_fill_options_set_by_fill_type (options, context, GIMP_FILL_FOREGROUND, &gerror))
    {
      g_object_unref (options);
      g_object_unref (context);
      return glims_fail (error, gerror, "The fill could not be set up.");
    }

  if (settings->mode == GLIMS_FILL_SELECTION)
    {
      gimp_drawable_edit_fill (GIMP_DRAWABLE (layer), options, NULL);
    }
  else
    {
      gdouble x = point.x;
      gdouble y = point.y;

      /* The seed is in the layer's coordinates unless the composite image
       * is sampled, as in GIMP's bucket fill tool. */
      if (! settings->sample_merged)
        {
          gint offset_x, offset_y;

          gimp_item_get_offset (GIMP_ITEM (layer), &offset_x, &offset_y);
          x -= offset_x;
          y -= offset_y;
        }

      gimp_drawable_bucket_fill (GIMP_DRAWABLE (layer), options, TRUE,
                                 GIMP_SELECT_CRITERION_COMPOSITE,
                                 CLAMP (settings->threshold, 0.0, 1.0),
                                 settings->sample_merged, FALSE, x, y);
    }

  g_object_unref (options);
  g_object_unref (context);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_gradient (GlimsEngine                 *engine,
                GlimsImageID                 id,
                GlimsPoint                   from,
                GlimsPoint                   to,
                const GlimsGradientSettings *settings,
                char                       **error)
{
  GlimsStatus       status;
  GimpImage        *image = writable_image (engine, id, &status);
  GimpLayer        *layer;
  GimpContext      *context;
  GimpGradientType  shape;
  gint              offset_x, offset_y;

  if (! image)
    return status;
  if (! settings || settings->struct_size < sizeof (GlimsGradientSettings))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  switch (settings->shape)
    {
    case GLIMS_GRADIENT_LINEAR:   shape = GIMP_GRADIENT_LINEAR;   break;
    case GLIMS_GRADIENT_BILINEAR: shape = GIMP_GRADIENT_BILINEAR; break;
    case GLIMS_GRADIENT_RADIAL:   shape = GIMP_GRADIENT_RADIAL;   break;
    default:                      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (from.x == to.x && from.y == to.y)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  layer = paintable_layer (image, error);
  if (! layer)
    return GLIMS_STATUS_FAILED;

  /* "FG to BG (RGB)" reads the context's colors when it is drawn. */
  context = command_context (engine->gimp, &settings->from, &settings->to);
  gimp_item_get_offset (GIMP_ITEM (layer), &offset_x, &offset_y);

  gimp_drawable_gradient (GIMP_DRAWABLE (layer), context,
                          gimp_gradients_get_fg_bg_rgb (engine->gimp),
                          GEGL_DISTANCE_METRIC_EUCLIDEAN,
                          GIMP_LAYER_MODE_NORMAL, shape,
                          CLAMP (settings->opacity, 0.0, 1.0),
                          0.0,                                   /* offset */
                          GIMP_REPEAT_NONE, FALSE,
                          GIMP_GRADIENT_BLEND_RGB_PERCEPTUAL,
                          FALSE, 3, 0.2,                         /* supersampling off */
                          TRUE,                                  /* dither */
                          from.x - offset_x, from.y - offset_y,
                          to.x - offset_x, to.y - offset_y,
                          NULL);

  g_object_unref (context);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

/* ---- Layers ------------------------------------------------------------ */

GlimsStatus
glims_layer_select (GlimsEngine  *engine,
                    GlimsImageID  id,
                    GlimsItemID   layer_id)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpLayer      *layer;
  GList          *layers;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  layer = find_layer (open->image, layer_id);
  if (! layer || layer_id == 0)
    return GLIMS_STATUS_NOT_FOUND;

  /* Plug-ins, fills and filters act on the engine's selected layers. */
  layers = g_list_prepend (NULL, layer);
  gimp_image_set_selected_layers (open->image, layers);
  g_list_free (layers);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_command (GlimsEngine  *engine,
                     GlimsImageID  id,
                     GlimsItemID   layer_id,
                     uint32_t      command,
                     GlimsItemID  *result,
                     char        **error)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpLayer   *layer;
  GimpLayer   *created = NULL;
  GError      *gerror  = NULL;

  if (! image)
    return status;

  layer = find_layer (image, layer_id);
  if (! layer && command != GLIMS_LAYER_NEW && command != GLIMS_LAYER_FLATTEN)
    return glims_fail (error, NULL, "Select a layer first.");

  switch (command)
    {
    case GLIMS_LAYER_NEW:
      /* A transparent, image-sized layer above the selected one, as GIMP's
       * New Layer with its defaults. */
      created = gimp_layer_new (image, gimp_image_get_width (image), gimp_image_get_height (image),
                                gimp_image_get_layer_format (image, TRUE),
                                _("Layer"), GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL);
      gimp_image_add_layer (image, created, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE);
      break;

    case GLIMS_LAYER_DUPLICATE:
      created = GIMP_LAYER (gimp_item_duplicate (GIMP_ITEM (layer), G_TYPE_FROM_INSTANCE (layer)));
      gimp_image_add_layer (image, created, gimp_layer_get_parent (layer),
                            gimp_item_get_index (GIMP_ITEM (layer)), TRUE);
      break;

    case GLIMS_LAYER_DELETE:
      gimp_image_remove_layer (image, layer, TRUE, NULL);
      break;

    case GLIMS_LAYER_RAISE:
      if (! gimp_image_raise_item (image, GIMP_ITEM (layer), &gerror))
        return glims_fail (error, gerror, "The layer is already at the top.");
      break;
    case GLIMS_LAYER_LOWER:
      if (! gimp_image_lower_item (image, GIMP_ITEM (layer), &gerror))
        return glims_fail (error, gerror, "The layer is already at the bottom.");
      break;
    case GLIMS_LAYER_TO_TOP:
      gimp_image_raise_item_to_top (image, GIMP_ITEM (layer));
      break;
    case GLIMS_LAYER_TO_BOTTOM:
      gimp_image_lower_item_to_bottom (image, GIMP_ITEM (layer));
      break;

    case GLIMS_LAYER_MERGE_DOWN:
      {
        GList *layers = g_list_prepend (NULL, layer);
#if GIMP_CHECK_VERSION (3, 2, 0)
        GList *merged = gimp_image_merge_down (image, layers, gimp_get_user_context (engine->gimp),
                                               GIMP_EXPAND_AS_NECESSARY, NULL, NULL, &gerror);
#else
        /* GIMP 3.0 has no "blink item" for its interface to flash. */
        GList *merged = gimp_image_merge_down (image, layers, gimp_get_user_context (engine->gimp),
                                               GIMP_EXPAND_AS_NECESSARY, NULL, &gerror);
#endif

        g_list_free (layers);
        if (! merged)
          return glims_fail (error, gerror, "There is no layer below to merge with.");
        created = merged->data;
        g_list_free (merged);
      }
      break;

    case GLIMS_LAYER_FLATTEN:
      created = gimp_image_flatten (image, gimp_get_user_context (engine->gimp), NULL, &gerror);
      if (! created)
        return glims_fail (error, gerror, "There are no visible layers to flatten.");
      break;

    default:
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (result)
    *result = created ? gimp_item_get_id (GIMP_ITEM (created)) : 0;

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_change (GlimsEngine            *engine,
                    GlimsImageID            id,
                    GlimsItemID             layer_id,
                    const GlimsLayerChange *change,
                    char                  **error)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpLayer   *layer;
  GError      *gerror = NULL;

  if (! image)
    return status;
  if (! change || change->struct_size < sizeof (GlimsLayerChange))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  layer = find_layer (image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;

  if (change->properties & GLIMS_LAYER_MODE)
    {
      GEnumClass *modes = g_type_class_ref (GIMP_TYPE_LAYER_MODE);
      GEnumValue *mode  = g_enum_get_value_by_nick (modes, change->mode);

      g_type_class_unref (modes);
      if (! mode)
        return glims_fail (error, NULL, "The engine has no such blend mode.");
      gimp_layer_set_mode (layer, mode->value, TRUE);
    }
  if ((change->properties & GLIMS_LAYER_NAME) &&
      ! gimp_item_rename (GIMP_ITEM (layer), change->name, &gerror))
    return glims_fail (error, gerror, "The layer could not be renamed.");
  if (change->properties & GLIMS_LAYER_VISIBLE)
    gimp_item_set_visible (GIMP_ITEM (layer), change->visible, TRUE);
  if (change->properties & GLIMS_LAYER_OPACITY)
    gimp_layer_set_opacity (layer, CLAMP (change->opacity, 0.0, 1.0), TRUE);

  /* Read right after these property changes, the composite can still show
   * the old state: always on GIMP 3.0.8, now and then on 3.2.8 and master
   * (seen in the conformance tests). Redrawing the layer's area makes the
   * next render current. */
  if (change->properties & (GLIMS_LAYER_VISIBLE | GLIMS_LAYER_OPACITY | GLIMS_LAYER_MODE))
    gimp_drawable_update_all (GIMP_DRAWABLE (layer));

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_move (GlimsEngine  *engine,
                  GlimsImageID  id,
                  GlimsItemID   layer_id,
                  double        dx,
                  double        dy)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpLayer   *layer;

  if (! image)
    return status;

  layer = find_layer (image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;

  gimp_item_translate (GIMP_ITEM (layer), dx, dy, TRUE);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_crop (GlimsEngine  *engine,
                  GlimsImageID  id,
                  GlimsRect     rect,
                  char        **error)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GeglRectangle bounds;

  if (! image)
    return status;

  bounds = (GeglRectangle) { 0, 0, gimp_image_get_width (image), gimp_image_get_height (image) };
  if (! gegl_rectangle_intersect (&bounds, &bounds, GEGL_RECTANGLE (rect.x, rect.y, rect.width, rect.height)) ||
      bounds.width < 1 || bounds.height < 1)
    return glims_fail (error, NULL, "The crop rectangle is outside the image.");

  /* GIMP's crop tool with "Delete cropped pixels" on, its default. */
  gimp_image_crop (image, gimp_get_user_context (engine->gimp), GIMP_FILL_TRANSPARENT,
                   bounds.x, bounds.y, bounds.width, bounds.height, TRUE);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

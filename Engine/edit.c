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

#include <math.h>
#include <string.h>

#include "libgimpmath/gimpmath.h"

#include "core/gimp.h"
#include "operations/layer-modes/gimp-layer-modes.h"
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
#include "core/gimpimage-flip.h"
#include "core/gimpimage-resize.h"
#include "core/gimpimage-rotate.h"
#include "core/gimpimage-scale.h"
#include "core/gimpimage-merge.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#include "core/gimppickable-auto-shrink.h"
#include "core/gimppattern.h"

#include "config/gimpcoreconfig.h"

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
  if (! GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image || ! gimp_item_is_attached (item))
    return NULL;

  return GIMP_LAYER (item);
}

/* The drawable to fill or draw on, or NULL with `error` set. The
 * image's selected drawable is the layer's mask while mask editing is
 * on, or a selected channel (gimp_image_get_selected_drawables), as in
 * GIMP's own tools; a mask's content lock check delegates to its layer
 * and the groups around it. */
static GimpDrawable *
paintable_drawable (GimpImage    *image,
                    GlimsStatus  *status,
                    char        **error)
{
  GList         *selected = gimp_image_get_selected_drawables (image);
  GimpDrawable  *drawable = selected ? selected->data : NULL;

  *status = GLIMS_STATUS_FAILED;
  if (! drawable)
    glims_fail (error, NULL, "Select a layer first.");
  else if (GIMP_IS_GROUP_LAYER (drawable))
    {
      glims_fail (error, NULL, "Groups cannot be filled.");
      drawable = NULL;
    }
  else if ((*status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error)) != GLIMS_STATUS_OK)
    drawable = NULL;

  g_list_free (selected);
  return drawable;
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
  GimpDrawable    *drawable;
  GimpContext     *context;
  GimpFillOptions *options;
  GError          *gerror = NULL;

  if (! image)
    return status;
  if (! settings || settings->struct_size < sizeof (GlimsFillSettings) ||
      (settings->mode != GLIMS_FILL_SIMILAR_COLORS && settings->mode != GLIMS_FILL_SELECTION))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  drawable = paintable_drawable (image, &status, error);
  if (! drawable)
    return status;

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
      gimp_drawable_edit_fill (drawable, options, NULL);
    }
  else
    {
      gdouble x = point.x;
      gdouble y = point.y;

      /* The seed is in the drawable's coordinates unless the composite
       * image is sampled, as in GIMP's bucket fill tool. A mask shares
       * its layer's offset. */
      if (! settings->sample_merged)
        {
          gint offset_x, offset_y;

          gimp_item_get_offset (GIMP_ITEM (drawable), &offset_x, &offset_y);
          x -= offset_x;
          y -= offset_y;
        }

      gimp_drawable_bucket_fill (drawable, options, TRUE,
                                 GIMP_SELECT_CRITERION_COMPOSITE,
                                 CLAMP (settings->threshold, 0.0, 1.0),
                                 settings->sample_merged, FALSE, x, y);
    }

  g_object_unref (options);
  g_object_unref (context);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

/* Filling with a pattern: the same two native calls as glims_fill, with
 * the fill options set to the pattern type and the pattern pinned on a
 * private per-call context. */
GlimsStatus
glims_fill_pattern (GlimsEngine                    *engine,
                    GlimsImageID                   id,
                    GlimsResourceID                pattern_id,
                    GlimsPoint                     seed,
                    const GlimsPatternFillSettings *settings,
                    char                         **error)
{
  GlimsOpenImage  *open;
  GimpImage       *image;
  GimpPattern     *pattern;
  GimpDrawable    *drawable;
  GimpContext     *context;
  GimpFillOptions *options;
  GlimsStatus      status;
  GError          *gerror = NULL;

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  /* Refuse before anything is validated further or mutated: an active
   * stroke, filter preview or plug-in call leaves pixels and history
   * alone. */
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  image = open->image;

  if (! settings || settings->struct_size < sizeof (GlimsPatternFillSettings) ||
      (settings->mode != GLIMS_FILL_SIMILAR_COLORS && settings->mode != GLIMS_FILL_SELECTION) ||
      ! isfinite (seed.x) || ! isfinite (seed.y) ||
      ! isfinite (settings->opacity) || settings->opacity < 0.0 || settings->opacity > 1.0 ||
      ! isfinite (settings->threshold) || settings->threshold < 0.0 || settings->threshold > 1.0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* The handle is re-resolved against this engine's own pattern factory
   * on every call; the full UInt64 is range-checked inside before any
   * native narrowing. */
  status = glims_lookup_pattern (engine, pattern_id, &pattern);
  if (status != GLIMS_STATUS_OK)
    {
      if (status == GLIMS_STATUS_INVALID_ARGUMENT && error)
        *error = strdup ("This handle cannot name a resource.");
      return status;
    }

  drawable = paintable_drawable (image, &status, error);
  if (! drawable)
    return status;

  /* A private context carrying the pattern for this call only. The
   * PATTERN property is marked defined BEFORE the pattern is set:
   * gimp_context_set_pattern walks up to the first context that defines
   * the property, and with the bit clear that could be the shared user
   * context, which one fill must never change. */
  context = gimp_context_new (engine->gimp, "Glims pattern fill", gimp_get_user_context (engine->gimp));
  gimp_context_define_property (context, GIMP_CONTEXT_PROP_PATTERN, TRUE);
  gimp_context_set_pattern (context, pattern);

  options = gimp_fill_options_new (engine->gimp, NULL, FALSE);
  gimp_context_set_opacity (GIMP_CONTEXT (options), settings->opacity);
  gimp_context_set_paint_mode (GIMP_CONTEXT (options), GIMP_LAYER_MODE_NORMAL);
  gimp_fill_options_set_antialias (options, settings->antialias);

  if (! gimp_fill_options_set_by_fill_type (options, context, GIMP_FILL_PATTERN, &gerror))
    {
      g_object_unref (options);
      g_object_unref (context);
      return glims_fail (error, gerror, "The pattern fill could not be set up.");
    }

  if (settings->mode == GLIMS_FILL_SELECTION)
    {
      gimp_drawable_edit_fill (drawable, options, NULL);
    }
  else
    {
      gdouble x = seed.x;
      gdouble y = seed.y;

      /* The seed is in the drawable's coordinates unless the composite
       * image is sampled, as in glims_fill and GIMP's bucket fill tool.
       * A mask shares its layer's offset. */
      if (! settings->sample_merged)
        {
          gint offset_x, offset_y;

          gimp_item_get_offset (GIMP_ITEM (drawable), &offset_x, &offset_y);
          x -= offset_x;
          y -= offset_y;
        }

      gimp_drawable_bucket_fill (drawable, options, TRUE,
                                 GIMP_SELECT_CRITERION_COMPOSITE,
                                 settings->threshold,
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
  GimpDrawable     *drawable;
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

  drawable = paintable_drawable (image, &status, error);
  if (! drawable)
    return status;

  /* "FG to BG (RGB)" reads the context's colors when it is drawn. */
  context = command_context (engine->gimp, &settings->from, &settings->to);
  gimp_item_get_offset (GIMP_ITEM (drawable), &offset_x, &offset_y);

  gimp_drawable_gradient (drawable, context,
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

/* A gradient endpoint color: every component finite and inside 0 ... 1
 * and the alpha exactly 1 — the engine's FG/BG context is opaque, so a
 * caller's alpha can never reach the pixels and a value below 1 is
 * refused instead of silently ignored (transparent stop types, such as
 * FG-to-transparent, come from the resource itself). */
static gboolean
gradient_color_usable (const GlimsColor *color)
{
  gdouble rgb[3] = { color->red, color->green, color->blue };
  gint    i;

  if (color->alpha != 1.0)
    return FALSE;
  for (i = 0; i < 3; i++)
    if (! isfinite (rgb[i]) || rgb[i] < 0.0 || rgb[i] > 1.0)
      return FALSE;

  return TRUE;
}

GlimsStatus
glims_gradient_resource (GlimsEngine                           *engine,
                         GlimsImageID                           id,
                         GlimsResourceID                        resource_id,
                         GlimsPoint                             from,
                         GlimsPoint                             to,
                         const GlimsResourceGradientSettings   *settings,
                         char                                 **error)
{
  GlimsOpenImage              *open = glims_lookup_image (engine, id);
  GimpDrawable                *drawable;
  GimpGradient                *gradient;
  GimpContext                 *context;
  GimpGradientType             shape;
  GimpGradientBlendColorSpace  blend_space;
  GlimsStatus                  status;
  gint                         offset_x, offset_y;

  /* Everything that can refuse runs before the mutation: argument
   * validation, the handle's admission, the readiness gate and the
   * paintable drawable with its locks. gimp_drawable_gradient returns
   * void, so nothing invalid may reach it. */
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! settings || settings->struct_size < sizeof (GlimsResourceGradientSettings))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  switch (settings->shape)
    {
    case GLIMS_GRADIENT_LINEAR:   shape = GIMP_GRADIENT_LINEAR;   break;
    case GLIMS_GRADIENT_BILINEAR: shape = GIMP_GRADIENT_BILINEAR; break;
    case GLIMS_GRADIENT_RADIAL:   shape = GIMP_GRADIENT_RADIAL;   break;
    default:                      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  switch (settings->blend_space)
    {
    case GLIMS_GRADIENT_BLEND_RGB_PERCEPTUAL: blend_space = GIMP_GRADIENT_BLEND_RGB_PERCEPTUAL; break;
    case GLIMS_GRADIENT_BLEND_RGB_LINEAR:     blend_space = GIMP_GRADIENT_BLEND_RGB_LINEAR;     break;
    case GLIMS_GRADIENT_BLEND_CIE_LAB:        blend_space = GIMP_GRADIENT_BLEND_CIE_LAB;        break;
    default:                                  return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (! isfinite (from.x) || ! isfinite (from.y) ||
      ! isfinite (to.x)   || ! isfinite (to.y)   ||
      (from.x == to.x && from.y == to.y))
    {
      glims_fail (error, NULL, "A gradient needs two distinct, finite endpoints.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (! gradient_color_usable (&settings->foreground) ||
      ! gradient_color_usable (&settings->background))
    {
      glims_fail (error, NULL, "The gradient colors need finite components inside 0...1 "
                               "and alpha 1: the engine's gradient colors are opaque.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (! isfinite (settings->opacity) || settings->opacity < 0.0 || settings->opacity > 1.0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_lookup_gradient (engine, resource_id, &gradient);
  if (status == GLIMS_STATUS_INVALID_ARGUMENT)
    {
      if (error)
        *error = strdup ("This handle cannot name a resource.");
      return status;
    }
  if (status != GLIMS_STATUS_OK)
    return status;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  drawable = paintable_drawable (open->image, &status, error);
  if (! drawable)
    return status;

  /* The native gradient sampler's RGB_LINEAR case falls through and
   * overwrites linear endpoint components with encoded sRGB in every
   * supported engine. Its later readback also differs between tags.
   * Refuse instead of presenting those pixels as linear-light blending. */
  if (settings->blend_space == GLIMS_GRADIENT_BLEND_RGB_LINEAR)
    {
      glims_fail (error, NULL, "This engine cannot render resource gradients in linear-light RGB. "
                               "Choose perceptual RGB or Lab blending.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* A per-call context with the endpoint colors defined and set before
   * the draw: FG/BG stop types in the resource read these, nothing
   * shared (the user context) is read or changed, and the resource's
   * own segments are never mutated. The colors are explicit sRGB. */
  context = command_context (engine->gimp, &settings->foreground, &settings->background);
  gimp_item_get_offset (GIMP_ITEM (drawable), &offset_x, &offset_y);

  gimp_drawable_gradient (drawable, context, gradient,
                          GEGL_DISTANCE_METRIC_EUCLIDEAN,
                          GIMP_LAYER_MODE_NORMAL, shape,
                          settings->opacity,
                          0.0,                                   /* offset */
                          GIMP_REPEAT_NONE, settings->reverse,
                          blend_space,
                          FALSE, 3, 0.2,                         /* supersampling off */
                          TRUE,                                  /* dither */
                          from.x - offset_x, from.y - offset_y,
                          to.x - offset_x, to.y - offset_y,
                          NULL);

  g_object_unref (context);
  gimp_image_flush (open->image);

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
    {
      /* The resize commands name their layer: an explicit id that is
       * gone is NOT_FOUND, while layer 0 asks for a pick first. */
      if (layer_id != 0 &&
          (command == GLIMS_LAYER_FIT_TO_IMAGE || command == GLIMS_LAYER_TRIM_TO_CONTENT ||
           command == GLIMS_LAYER_RASTERIZE || command == GLIMS_LAYER_RESTORE_SOURCE))
        return GLIMS_STATUS_NOT_FOUND;
      return glims_fail (error, NULL, "Select a layer first.");
    }

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

    case GLIMS_LAYER_FIT_TO_IMAGE:
    case GLIMS_LAYER_TRIM_TO_CONTENT:
      {
        gint x, y, width, height;

        status = glims_edit_ready (engine, glims_lookup_image (engine, id), error);
        if (status != GLIMS_STATUS_OK) return status;
        status = glims_check_item_locks (GIMP_ITEM (layer),
                                         GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
        if (status != GLIMS_STATUS_OK) return status;

        switch (glims_layer_kind (layer))
          {
          case GLIMS_LAYER_PIXEL:
            /* Rasterized text, link and vector instances report PIXEL
             * here too: their current content is pixels. */
            break;
          case GLIMS_LAYER_GROUP:
            glims_fail (error, NULL,
                        "A layer group cannot be resized this way; size the layers inside it.");
            return GLIMS_STATUS_UNSUPPORTED;
          default:
            /* Resizing genuine text, link and vector layers re-renders
             * their source into pixels. Refuse rather than rasterize
             * silently. */
            glims_fail (error, NULL,
                        "Rasterize the text, link or vector layer before resizing it.");
            return GLIMS_STATUS_UNSUPPORTED;
          }

        gimp_item_get_offset (GIMP_ITEM (layer), &x, &y);
        width  = gimp_item_get_width (GIMP_ITEM (layer));
        height = gimp_item_get_height (GIMP_ITEM (layer));

        if (command == GLIMS_LAYER_FIT_TO_IMAGE)
          {
            /* Layer to Image Size (app/actions/layers-commands.c
             * layers_resize_to_image_cmd_callback): the layer keeps its
             * content's position and grows transparent around it —
             * core/gimplayer.c gimp_layer_resize_to_image resizes to the
             * image bounds passing the old offsets, so the result sits
             * at 0,0. Its mask resizes with it (gimp_layer_resize). */
            if (x == 0 && y == 0 &&
                width == gimp_image_get_width (image) && height == gimp_image_get_height (image))
              break; /* already exactly the image bounds: no undo */
            gimp_layer_resize_to_image (layer, gimp_get_user_context (engine->gimp),
                                        GIMP_FILL_TRANSPARENT);
          }
        else
          {
            gint content_x, content_y, content_width, content_height;

            /* Crop to content (layers_crop_to_content_cmd_callback):
             * the native transparent/uniform-background shrink. Only a
             * SHRINK answer resizes; EMPTY and UNSHRINKABLE leave pixels,
             * bounds and history untouched — a no-op without undo. */
            switch (gimp_pickable_auto_shrink (GIMP_PICKABLE (layer), 0, 0,
                                               width, height,
                                               &content_x, &content_y,
                                               &content_width, &content_height))
              {
              case GIMP_AUTO_SHRINK_SHRINK:
                gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_ITEM_RESIZE,
                                             C_("undo-type", "Trim Layer to Content"));
                gimp_item_resize (GIMP_ITEM (layer), gimp_get_user_context (engine->gimp),
                                  GIMP_FILL_TRANSPARENT,
                                  content_width, content_height, -content_x, -content_y);
                gimp_image_undo_group_end (image);
                break;
              case GIMP_AUTO_SHRINK_EMPTY:
              case GIMP_AUTO_SHRINK_UNSHRINKABLE:
                break;
              }
          }
      }
      break;

    case GLIMS_LAYER_RASTERIZE:
      /* Explicit rasterize (layer-source.c): a genuine editable text,
       * link or vector layer becomes pixel-behaving and keeps its
       * source, one undo step; an already rasterized instance is a
       * no-op. The same readiness and inherited pixel/position locks as
       * the resize commands gate it. */
      status = glims_edit_ready (engine, glims_lookup_image (engine, id), error);
      if (status != GLIMS_STATUS_OK) return status;
      status = glims_check_item_locks (GIMP_ITEM (layer),
                                       GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
      if (status != GLIMS_STATUS_OK) return status;
      status = glims_layer_rasterize (image, layer, error);
      if (status != GLIMS_STATUS_OK) return status;
      break;

    case GLIMS_LAYER_RESTORE_SOURCE:
      /* Restore the retained source (layer-source.c): a rasterized
       * text, link or vector layer with its source still attached is
       * regenerated from that source as one undo step, discarding the
       * pixel edits; an already editable instance is a no-op. The same
       * readiness and inherited pixel/position locks as RASTERIZE gate
       * it. */
      status = glims_edit_ready (engine, glims_lookup_image (engine, id), error);
      if (status != GLIMS_STATUS_OK) return status;
      status = glims_check_item_locks (GIMP_ITEM (layer),
                                       GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
      if (status != GLIMS_STATUS_OK) return status;
      status = glims_layer_restore_source (image, layer, error);
      if (status != GLIMS_STATUS_OK) return status;
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
      GEnumClass           *modes = g_type_class_ref (GIMP_TYPE_LAYER_MODE);
      GEnumValue           *mode  = g_enum_get_value_by_nick (modes, change->mode);
      /* Some modes (behind, erase, merge, split) are for painting only, and
       * pass-through is for groups only; gimp_layer_set_mode asserts on a
       * mode outside the layer's context (a group's or a layer's) and
       * changes nothing. */
      GimpLayerModeContext  context = gimp_viewable_get_children (GIMP_VIEWABLE (layer))
        ? GIMP_LAYER_MODE_CONTEXT_GROUP : GIMP_LAYER_MODE_CONTEXT_LAYER;

      g_type_class_unref (modes);
      if (! mode)
        return glims_fail (error, NULL, "The engine has no such blend mode.");
      if (! (gimp_layer_mode_get_context (mode->value) & context))
        {
          glims_fail (error, NULL, context == GIMP_LAYER_MODE_CONTEXT_GROUP
                                   ? "That blend mode does not apply to layer groups."
                                   : "That blend mode is for painting, not for layers.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
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

  status = glims_check_item_locks (GIMP_ITEM (layer), GLIMS_LOCK_POSITION, NULL);
  if (status != GLIMS_STATUS_OK) return status;
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

/* ---- Transforms ---------------------------------------------------------- */

static gboolean
rotation_or_flip (uint32_t             transform,
                  GimpRotationType    *rotation,
                  GimpOrientationType *flip)
{
  *rotation = -1;
  *flip     = GIMP_ORIENTATION_UNKNOWN;

  switch (transform)
    {
    case GLIMS_TRANSFORM_ROTATE_90:       *rotation = GIMP_ROTATE_DEGREES90;  return TRUE;
    case GLIMS_TRANSFORM_ROTATE_180:      *rotation = GIMP_ROTATE_DEGREES180; return TRUE;
    case GLIMS_TRANSFORM_ROTATE_270:      *rotation = GIMP_ROTATE_DEGREES270; return TRUE;
    case GLIMS_TRANSFORM_FLIP_HORIZONTAL: *flip = GIMP_ORIENTATION_HORIZONTAL; return TRUE;
    case GLIMS_TRANSFORM_FLIP_VERTICAL:   *flip = GIMP_ORIENTATION_VERTICAL;   return TRUE;
    default:                              return FALSE;
    }
}

GlimsStatus
glims_image_transform (GlimsEngine  *engine,
                       GlimsImageID  id,
                       uint32_t      transform)
{
  GlimsStatus          status;
  GimpImage           *image = writable_image (engine, id, &status);
  GimpContext         *context;
  GimpRotationType     rotation;
  GimpOrientationType  flip;

  if (! image)
    return status;
  if (! rotation_or_flip (transform, &rotation, &flip))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* The whole image with every layer, channel and path, as Image >
   * Transform does (app/actions/image-commands.c). */
  context = gimp_get_user_context (engine->gimp);
  if (flip != GIMP_ORIENTATION_UNKNOWN)
    gimp_image_flip (image, context, flip, NULL);
  else
    gimp_image_rotate (image, context, rotation, NULL);

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_transform (GlimsEngine  *engine,
                       GlimsImageID  id,
                       GlimsItemID   layer_id,
                       uint32_t      transform)
{
  GlimsStatus          status;
  GimpImage           *image = writable_image (engine, id, &status);
  GimpLayer           *layer;
  GimpRotationType     rotation;
  GimpOrientationType  flip;
  gint                 x, y, width, height;

  if (! image)
    return status;
  if (! rotation_or_flip (transform, &rotation, &flip))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  layer = find_layer (image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;

  /* Around the layer's own center, unclipped, as Layer > Transform does
   * (app/actions/drawable-commands.c). */
  status = glims_check_item_locks (GIMP_ITEM (layer), GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, NULL);
  if (status != GLIMS_STATUS_OK) return status;
  gimp_item_get_offset (GIMP_ITEM (layer), &x, &y);
  width  = gimp_item_get_width (GIMP_ITEM (layer));
  height = gimp_item_get_height (GIMP_ITEM (layer));

  if (flip == GIMP_ORIENTATION_HORIZONTAL)
    gimp_item_flip (GIMP_ITEM (layer), gimp_get_user_context (engine->gimp), flip, x + width / 2.0, FALSE);
  else if (flip == GIMP_ORIENTATION_VERTICAL)
    gimp_item_flip (GIMP_ITEM (layer), gimp_get_user_context (engine->gimp), flip, y + height / 2.0, FALSE);
  else
    gimp_item_rotate (GIMP_ITEM (layer), gimp_get_user_context (engine->gimp), rotation,
                      x + width / 2.0, y + height / 2.0, FALSE);

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_scale (GlimsEngine  *engine,
                   GlimsImageID  id,
                   int32_t       width,
                   int32_t       height,
                   char        **error)
{
  GlimsStatus status;
  GimpImage  *image = writable_image (engine, id, &status);

  if (! image)
    return status;
  if (width < 1 || height < 1 || width > GIMP_MAX_IMAGE_SIZE || height > GIMP_MAX_IMAGE_SIZE)
    return glims_fail (error, NULL, "The new size must be between 1 and 524288 pixels.");

  /* With the interpolation the engine's preferences name. */
  gimp_image_scale (image, width, height, engine->gimp->config->interpolation_type, NULL);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_transform_matrix (GlimsEngine       *engine,
                              GlimsImageID       id,
                              GlimsItemID        layer_id,
                              const GlimsMatrix *matrix,
                              uint32_t           interpolation,
                              char             **error)
{
  GlimsStatus            status;
  GimpImage             *image = writable_image (engine, id, &status);
  GimpLayer             *layer;
  GimpMatrix3            transform;
  GimpInterpolationType  type;
  gint                   row, column;

  if (! image)
    return status;
  if (! matrix)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  for (row = 0; row < 3; row++)
    for (column = 0; column < 3; column++)
      {
        if (! isfinite (matrix->m[row][column]))
          {
            glims_fail (error, NULL, "The transform is not a finite matrix.");
            return GLIMS_STATUS_INVALID_ARGUMENT;
          }
        transform.coeff[row][column] = matrix->m[row][column];
      }

  /* A matrix that maps the layer onto a line or a point has nothing to
   * invert, and the engine's transform needs its inverse. */
  if (fabs (gimp_matrix3_determinant (&transform)) < 1e-9)
    {
      glims_fail (error, NULL, "The transform would flatten the layer.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  switch (interpolation)
    {
    case GLIMS_INTERPOLATION_DEFAULT: type = engine->gimp->config->interpolation_type; break;
    case GLIMS_INTERPOLATION_NONE:    type = GIMP_INTERPOLATION_NONE;   break;
    case GLIMS_INTERPOLATION_LINEAR:  type = GIMP_INTERPOLATION_LINEAR; break;
    case GLIMS_INTERPOLATION_CUBIC:   type = GIMP_INTERPOLATION_CUBIC;  break;
    case GLIMS_INTERPOLATION_NOHALO:  type = GIMP_INTERPOLATION_NOHALO; break;
    case GLIMS_INTERPOLATION_LOHALO:  type = GIMP_INTERPOLATION_LOHALO; break;
    default:                          return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  layer = find_layer (image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;

  status = glims_check_item_locks (GIMP_ITEM (layer), GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
  if (status != GLIMS_STATUS_OK) return status;
  /* Forward, grown to the result, as the unified transform tool commits
   * a layer (app/tools/gimptransformgridtool.c). gimp_item_transform opens
   * its own undo group. */
  gimp_item_transform (GIMP_ITEM (layer), gimp_get_user_context (engine->gimp), &transform,
                       GIMP_TRANSFORM_FORWARD, type, GIMP_TRANSFORM_RESIZE_ADJUST, NULL);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_resize_canvas (GlimsEngine      *engine,
                           GlimsImageID      id,
                           int32_t           width,
                           int32_t           height,
                           int32_t           offset_x,
                           int32_t           offset_y,
                           const GlimsColor *fill,
                           char            **error)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpContext *context;

  if (! image)
    return status;
  if (! fill)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (width < 1 || height < 1 || width > GIMP_MAX_IMAGE_SIZE || height > GIMP_MAX_IMAGE_SIZE)
    return glims_fail (error, NULL, "The new size must be between 1 and 524288 pixels.");

  /* Image-sized layers (a background) grow with the canvas and fill the new
   * area with `fill`; other layers keep their size, as in classic editors.
   * GIMP's Canvas Size dialog offers the same choice. */
  context = command_context (engine->gimp, NULL, fill);
  gimp_image_resize_with_layers (image, context, GIMP_FILL_BACKGROUND, width, height,
                                 offset_x, offset_y, GIMP_ITEM_SET_IMAGE_SIZED, FALSE, NULL);
  g_object_unref (context);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

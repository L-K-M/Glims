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
#include "lab-layer-storage.h"
#include "lab-layer-duplicate.h"
#include "lab-layer-create.h"

#include <math.h>
#include <string.h>
#include <cairo.h>

#include "libgimpmath/gimpmath.h"

#include "core/gimp.h"
#include "operations/layer-modes/gimp-layer-modes.h"
#include "core/gimp-gradients.h"
#include "core/gimpcontext.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpdrawable-bucket-fill.h"
#include "core/gimpdrawable-edit.h"
#include "core/gimpdrawable-gradient.h"
#include "core/gimpfilloptions.h"
#include "core/gimpfilter.h"
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
#include "core/gimplayermask.h"
#include "core/gimplayer-new.h"
#include "core/gimp-transform-resize.h"
#include "core/gimp-transform-utils.h"
#include "core/gimppickable.h"
#include "core/gimppickable-auto-shrink.h"
#include "core/gimppattern.h"
#include "core/gimpprojectable.h"
#include "gegl/gimp-gegl-nodes.h"
#include "gegl/gimptilehandlervalidate.h"

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

static gboolean
layered_lab_contains_root (const GlimsLabLayerStorage *storage, GimpLayer *layer)
{
  for (guint i = 0; i < storage->map.count; i++)
    if (storage->layers[i].group == layer) return TRUE;
  return FALSE;
}

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
  if (open->component_layout == GLIMS_COMPONENT_LAYOUT_LAYERED_LAB)
    {
      g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
      if (!storage) return GLIMS_STATUS_FAILED;
      if (glims_lab_layer_storage_read (open->image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID ||
          !layered_lab_contains_root (storage, layer)) return GLIMS_STATUS_UNSUPPORTED;
    }

  /* Plug-ins, fills and filters act on the engine's selected layers. */
  layers = g_list_prepend (NULL, layer);
  gimp_image_set_selected_layers (open->image, layers);
  g_list_free (layers);

  return GLIMS_STATUS_OK;
}

/* ---- Multi-layer selection --------------------------------------------- */

/* The image's selected layer ids in the engine's own order — the order
 * glims_image_select_layers last set, active layer first. The list
 * gimp_image_get_selected_layers returns is the item tree's own
 * selected_items: borrowed, never freed here (the owned-list variant
 * gimp_image_get_selected_drawables is deliberately not used). A plain
 * read, so no readiness gate beyond the image existing. */
GlimsStatus
glims_image_selected_layers (GlimsEngine  *engine,
                             GlimsImageID  id,
                             GlimsItemID  *ids,
                             int32_t       capacity,
                             int32_t      *count)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GList          *selected;
  GList          *iter;
  int32_t         fill, n;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  selected = gimp_image_get_selected_layers (open->image);
  *count = (int32_t) g_list_length (selected);
  fill   = ids ? capacity : 0;
  for (iter = selected, n = 0; iter && n < fill; iter = iter->next, n++)
    ids[n] = gimp_item_get_id (GIMP_ITEM (iter->data));

  return GLIMS_STATUS_OK;
}

/* Selects exactly `layers`, in the given order, as the image's whole
 * selected-layer list. Transient: no undo, no dirty, no pixel or mask-data
 * change; the core emits "selected-layers-changed" (the facade's
 * LAYERS_CHANGED) only when the selection actually changes. Same
 * readiness as glims_layer_select: the image must exist, and there is
 * no BUSY gate. */
GlimsStatus
glims_image_select_layers (GlimsEngine       *engine,
                           GlimsImageID       id,
                           const GlimsItemID *layers,
                           size_t             count,
                           char             **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpImage      *image;
  GimpLayer     **resolved = NULL;
  GHashTable     *seen = NULL;
  GList          *list = NULL;
  GList          *selected;
  GimpLayer      *floating;
  size_t          i;
  gboolean        applied;
  GlimsStatus     status = GLIMS_STATUS_OK;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  image = open->image;

  g_autofree GlimsLabLayerStorage *layered = NULL;
  if (open->component_layout == GLIMS_COMPONENT_LAYOUT_LAYERED_LAB)
    {
      layered = g_try_new0 (GlimsLabLayerStorage, 1);
      if (!layered) return GLIMS_STATUS_FAILED;
      if (glims_lab_layer_storage_read (image, layered) != GLIMS_LAB_LAYER_STORAGE_VALID)
        return GLIMS_STATUS_UNSUPPORTED;
    }

  if (count > 0 && ! layers)
    {
      glims_fail (error, NULL, "A NULL layer list needs count 0.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (count > 0)
    {
      GList *available = gimp_image_get_layer_list (image);
      size_t available_count = g_list_length (available);
      g_list_free (available);
      if (count > available_count)
        {
          glims_fail (error, NULL, "The requested selection contains more ids than the image has layers.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
    }

  /* Validate the ENTIRE input before any mutation: duplicates, id 0,
   * stale/foreign/detached ids and non-layer items (masks, channels,
   * paths) are all refused here, leaving the selection untouched.
   * Groups are layers and pass. */
  if (count > 0)
    {
      resolved = g_new (GimpLayer *, count);
      seen     = g_hash_table_new (g_direct_hash, g_direct_equal);
      for (i = 0; i < count && status == GLIMS_STATUS_OK; i++)
        {
          GlimsItemID item_id = layers[i];
          GimpItem   *item;

          if (item_id == 0)
            {
              glims_fail (error, NULL, "The layer list contains the id 0, which names no layer.");
              status = GLIMS_STATUS_INVALID_ARGUMENT;
            }
          else if (g_hash_table_contains (seen, GINT_TO_POINTER (item_id)))
            {
              glims_fail (error, NULL, "The layer list repeats an id.");
              status = GLIMS_STATUS_INVALID_ARGUMENT;
            }
          else
            {
              item = gimp_item_get_by_id (image->gimp, item_id);
              if (! item || gimp_item_get_image (item) != image || ! gimp_item_is_attached (item))
                {
                  glims_fail (error, NULL, "A requested layer is missing or belongs to another image.");
                  status = GLIMS_STATUS_NOT_FOUND;
                }
              else if (! GIMP_IS_LAYER (item))
                {
                  glims_fail (error, NULL, "The id names a mask, channel or path, not a layer.");
                  status = GLIMS_STATUS_INVALID_ARGUMENT;
                }
              else if (layered && !layered_lab_contains_root (layered, GIMP_LAYER (item)))
                {
                  glims_fail (error, NULL, "Only logical Lab layer roots can be selected.");
                  status = GLIMS_STATUS_UNSUPPORTED;
                }
              else
                {
                  g_hash_table_add (seen, GINT_TO_POINTER (item_id));
                  resolved[i] = GIMP_LAYER (item);
                }
            }
        }
      if (status != GLIMS_STATUS_OK)
        {
          g_free (resolved);
          g_hash_table_destroy (seen);
          return status;
        }
    }

  /* While a floating selection is active the native setter silently
   * ignores every request that is not exactly [floating selection].
   * Refuse those explicitly — the floating selection is never anchored
   * here — and let the identical [FS] list through: with the FS active
   * that already is the selection, so the native call is a no-op. An
   * empty request is refused the same way, since the core does not
   * permit clearing the selection under a floating selection. */
  floating = gimp_image_get_floating_selection (image);
  if (floating && ! (count == 1 && resolved[0] == floating))
    {
      g_free (resolved);
      if (seen)
        g_hash_table_destroy (seen);
      return glims_fail (error, NULL,
                        "A floating selection is active; resolve it before changing the layer selection.");
    }

  /* g_list_append keeps the caller's order; the first id becomes the
   * active layer. */
  for (i = count; i > 0; i--)
    list = g_list_prepend (list, resolved[i - 1]);

  /* Core compares membership, ignoring order. Clear only for a genuine
   * reorder of the same members so the next setter can change the primary
   * layer. The floating-selection gate above excludes an invalid clear.
   * Both changes are transient and queue their normal selection events. */
  selected = gimp_image_get_selected_layers (image);
  if (count > 1 && g_list_length (selected) == count)
    {
      GList *iter;
      gboolean same_members = TRUE;
      gboolean same_order = TRUE;
      for (iter = selected, i = 0; iter; iter = iter->next, i++)
        {
          if (! g_hash_table_contains (seen, GINT_TO_POINTER (gimp_item_get_id (iter->data))))
            same_members = FALSE;
          if (iter->data != resolved[i])
            same_order = FALSE;
        }
      if (same_members && ! same_order)
        gimp_image_set_selected_layers (image, NULL);
    }
  gimp_image_set_selected_layers (image, list);

  /* The native call copies the passed list (the item tree takes the
   * copy as its selected_items), so the adapter's own list is freed
   * exactly once here. */
  g_list_free (list);

  /* Postcondition: a changed selection stores the passed order, so the
   * read-back must be the exact list in the exact order (the borrowed
   * selected list is not freed). A mismatch means the core silently
   * refused — report it rather than returning success. */
  applied  = TRUE;
  selected = gimp_image_get_selected_layers (image);
  if (g_list_length (selected) != count)
    applied = FALSE;
  else
    {
      GList *iter;

      for (iter = selected, i = 0; iter; iter = iter->next, i++)
        if (iter->data != resolved[i])
          {
            applied = FALSE;
            break;
          }
    }

  g_free (resolved);
  if (seen)
    g_hash_table_destroy (seen);
  if (! applied)
    return glims_fail (error, NULL, "The engine did not apply the requested layer selection.");

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

  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (open && open->component_layout == GLIMS_COMPONENT_LAYOUT_LAYERED_LAB)
    {
      /* Never let a generic layer command mutate the physical scalar tree. */
      if (result) *result = 0;
      if (command != GLIMS_LAYER_DUPLICATE && command != GLIMS_LAYER_NEW)
        return GLIMS_STATUS_UNSUPPORTED;
      if (!layer_id && g_list_length (gimp_image_get_selected_layers (image)) != 1)
        {
          if (command != GLIMS_LAYER_NEW || gimp_image_get_selected_layers (image))
            return GLIMS_STATUS_UNSUPPORTED;
        }
      layer = find_layer (image, layer_id);
      if (!layer && (layer_id || command != GLIMS_LAYER_NEW)) return GLIMS_STATUS_NOT_FOUND;
      if (command == GLIMS_LAYER_NEW)
        {
          g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
          if (!storage) return GLIMS_STATUS_FAILED;
          if (glims_lab_layer_storage_read (image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
            return GLIMS_STATUS_UNSUPPORTED;
          guint position = 0;
          if (layer)
            {
              for (; position < storage->map.count; position++)
                if (storage->layers[position].group == layer) break;
              if (position == storage->map.count) return GLIMS_STATUS_UNSUPPORTED;
            }
          status = glims_lab_layer_create (engine, image, position, NULL, &created, error);
        }
      else
        status = glims_lab_layer_duplicate (engine, image, layer, &created, error);
      if (status == GLIMS_STATUS_OK)
        {
          if (result) *result = gimp_item_get_id (GIMP_ITEM (created));
          gimp_image_flush (image);
        }
      return status;
    }

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
      /* A link restore thaws the layer, which reloads its file through a
       * load plug-in's nested main loop — hold busy for the duration, as
       * the open, place and procedure paths do. */
      engine->busy++;
      status = glims_layer_restore_source (image, layer, error);
      engine->busy--;
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

  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (open->component_layout == GLIMS_COMPONENT_LAYOUT_LAYERED_LAB)
    {
      g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
      if (!storage) return GLIMS_STATUS_FAILED;
      if (glims_lab_layer_storage_read (image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID ||
          !layered_lab_contains_root (storage, layer)) return GLIMS_STATUS_UNSUPPORTED;
      /* Rename is a separate operation so an invalid name or a failed
       * native rename cannot partially apply visibility or opacity changes. */
      if (change->properties == GLIMS_LAYER_NAME)
        {
          if (!memchr (change->name, '\0', sizeof change->name) || !change->name[0] ||
              !g_utf8_validate (change->name, -1, NULL))
            return GLIMS_STATUS_INVALID_ARGUMENT;
          status = glims_edit_ready (engine, open, error);
          if (status != GLIMS_STATUS_OK) return status;
          if (!gimp_item_rename (GIMP_ITEM (layer), change->name, &gerror))
            return glims_fail (error, gerror, "The layer could not be renamed.");
          gimp_image_flush (image);
          return GLIMS_STATUS_OK;
        }
      if (!change->properties || (change->properties & ~(GLIMS_LAYER_VISIBLE | GLIMS_LAYER_OPACITY)) ||
          ((change->properties & GLIMS_LAYER_OPACITY) &&
           (!isfinite (change->opacity) || change->opacity < 0 || change->opacity > 1)))
        return GLIMS_STATUS_INVALID_ARGUMENT;
      status = glims_edit_ready (engine, open, error);
      if (status != GLIMS_STATUS_OK) return status;
      if (!gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_ITEM_PROPERTIES, "Lab Layer Properties"))
        return GLIMS_STATUS_FAILED;
      if ((change->properties & GLIMS_LAYER_VISIBLE) &&
          !gimp_item_set_visible (GIMP_ITEM (layer), change->visible, TRUE))
        {
          gimp_image_undo_group_end (image);
          return glims_fail (error, NULL, "The layer visibility could not be changed.");
        }
      if (change->properties & GLIMS_LAYER_OPACITY)
        gimp_layer_set_opacity (layer, change->opacity, TRUE);
      gimp_image_undo_group_end (image);
      gimp_drawable_update_all (GIMP_DRAWABLE (layer));
      gimp_image_flush (image);
      return GLIMS_STATUS_OK;
    }

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

static GlimsStatus
invalid_transform (char **error, const char *message)
{
  glims_fail (error, NULL, message);
  return GLIMS_STATUS_INVALID_ARGUMENT;
}

/* An unclipped effect can change its extent when its input size changes.
 * Its old margins do not bound a future render, so do not guess. Ordinary
 * Glims effects are clipped; imported unbounded effects need an explicit
 * merge or disable before this pixel transform. */
static GlimsStatus
check_transform_effect_bounds (GimpDrawable *drawable, char **error)
{
  GimpContainer *filters = gimp_drawable_get_filters (drawable);
  for (gint i = 0; i < gimp_container_get_n_children (filters); i++)
    {
      GimpObject *filter = gimp_container_get_child_by_index (filters, i);
      if (GIMP_IS_DRAWABLE_FILTER (filter) && gimp_filter_get_active (GIMP_FILTER (filter)) &&
          ! gimp_drawable_filter_get_clip (GIMP_DRAWABLE_FILTER (filter)))
        return invalid_transform (error,
          "Merge or disable effects that extend beyond layer bounds before transforming this layer.");
    }
  return GLIMS_STATUS_OK;
}

static GlimsStatus
admit_transform_storage (GimpDrawable *drawable, gint64 left, gint64 top,
                          gint64 right, gint64 bottom, guint64 *remaining, char **error)
{
  const gint64 limit = 2 * GIMP_MAX_IMAGE_SIZE;
  guint64 pixels;
  gint bpp;
  if (left < -limit || top < -limit || right > limit || bottom > limit ||
      right <= left || bottom <= top || right - left > GIMP_MAX_IMAGE_SIZE ||
      bottom - top > GIMP_MAX_IMAGE_SIZE)
    return invalid_transform (error, "The transformed layer or its group would exceed the supported size or coordinates.");
  pixels = (guint64) (right - left) * (guint64) (bottom - top);
  bpp = babl_format_get_bytes_per_pixel (gimp_drawable_get_format_with_alpha (drawable));
  if (bpp < 1 || pixels > *remaining / (guint64) bpp)
    return invalid_transform (error, "Transformed layers and masks would exceed the 512 MiB output limit. Reduce the size or transform layers separately.");
  *remaining -= pixels * (guint64) bpp;
  return GLIMS_STATUS_OK;
}

/* Native projective sampling clips at near-Z. Normalize the homogeneous
 * representation so equivalent H, 2H and -3H use the same near plane.
 * Keep affine W=1 unchanged, including its existing rounding behavior. */
static GlimsStatus
normalize_transform (GimpLayer *layer, GimpMatrix3 *matrix, char **error)
{
  gint x, y;
  gdouble cx, cy, w, determinant;
  GimpMatrix3 inverse;
  gimp_item_get_offset (GIMP_ITEM (layer), &x, &y);
  cx = x + gimp_item_get_width (GIMP_ITEM (layer)) / 2.0;
  cy = y + gimp_item_get_height (GIMP_ITEM (layer)) / 2.0;
  w = matrix->coeff[2][0] * cx + matrix->coeff[2][1] * cy + matrix->coeff[2][2];
  if (! isfinite (w) || w == 0)
    return invalid_transform (error, "The transform crosses a perspective horizon. Move its corners closer together.");
  for (gint row = 0; row < 3; row++)
    for (gint column = 0; column < 3; column++)
      {
        matrix->coeff[row][column] /= w;
        if (! isfinite (matrix->coeff[row][column]))
          return invalid_transform (error, "The normalized transform is not finite.");
      }
  determinant = gimp_matrix3_determinant (matrix);
  if (! isfinite (determinant) || fabs (determinant) < 1e-9)
    return invalid_transform (error, "The transform would flatten the layer or exceed its numeric range.");
  inverse = *matrix;
  gimp_matrix3_invert (&inverse);
  for (gint row = 0; row < 3; row++)
    for (gint column = 0; column < 3; column++)
      if (! isfinite (inverse.coeff[row][column]))
        return invalid_transform (error, "The inverse transform is not finite.");
  return GLIMS_STATUS_OK;
}

/* Bound every destination before native integer casts or mutation. The
 * aggregate budget counts output storage for all layers and attached masks;
 * it is not a promise about total GEGL working memory or Undo retention. */
static GlimsStatus
preflight_transformed_drawable (GimpDrawable *drawable, const GimpMatrix3 *matrix,
                                guint64 *remaining, GeglRectangle *result, char **error)
{
  GimpItem *item = GIMP_ITEM (drawable);
  gint x, y, left, top, right, bottom;
  const gint width = gimp_item_get_width (item), height = gimp_item_get_height (item);
  const gdouble coordinate_limit = 2.0 * GIMP_MAX_IMAGE_SIZE;
  GlimsStatus status = glims_check_item_locks (item, GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = check_transform_effect_bounds (drawable, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (width < 1 || height < 1)
    return invalid_transform (error, "The layer has no transformable pixel area.");
  gimp_item_get_offset (item, &x, &y);
  /* Native boundary and sampling code also stores the source far edges
   * in gint before applying H, even when the destination is small. */
  if ((gint64) x + width > G_MAXINT || (gint64) y + height > G_MAXINT)
    return invalid_transform (error, "Move the source layer within the supported coordinates before transforming it.");
  for (gint corner = 0; corner < 4; corner++)
    {
      const gdouble px = (gdouble) x + (corner & 1 ? width : 0);
      const gdouble py = (gdouble) y + (corner & 2 ? height : 0);
      const gdouble w = matrix->coeff[2][0] * px + matrix->coeff[2][1] * py + matrix->coeff[2][2];
      gdouble out_x, out_y;
      if (! isfinite (w) || w <= GIMP_TRANSFORM_NEAR_Z + 1e-9)
        return invalid_transform (error, "The transform crosses a perspective horizon. Move its corners closer together.");
      out_x = (matrix->coeff[0][0] * px + matrix->coeff[0][1] * py + matrix->coeff[0][2]) / w;
      out_y = (matrix->coeff[1][0] * px + matrix->coeff[1][1] * py + matrix->coeff[1][2]) / w;
      if (! isfinite (out_x) || ! isfinite (out_y) ||
          fabs (out_x) > coordinate_limit || fabs (out_y) > coordinate_limit)
        return invalid_transform (error, "The transformed layer would exceed the supported coordinates.");
    }
  /* With a positive W throughout the rectangle, extrema occur at corners.
   * Their checked range makes native epsilon-aware integer rounding safe. */
  if (! gimp_transform_resize_boundary (matrix, GIMP_TRANSFORM_RESIZE_ADJUST,
                                        x, y, (gdouble) x + width, (gdouble) y + height,
                                        &left, &top, &right, &bottom) ||
      right <= left || bottom <= top || right - left > GIMP_MAX_IMAGE_SIZE ||
      bottom - top > GIMP_MAX_IMAGE_SIZE)
    return invalid_transform (error, "The transformed layer would exceed 524288 pixels per side.");
  if (result) *result = (GeglRectangle) { left, top, right - left, bottom - top };
  return admit_transform_storage (drawable, left, top, right, bottom, remaining, error);
}

static GlimsStatus
preflight_transform_tree (GimpImage *image, GimpLayer *layer,
                          const GimpMatrix3 *matrix, char **error)
{
  GList *layers = gimp_image_get_layer_list (image);
  guint64 remaining = GLIMS_MAX_PIXEL_BUFFER_BYTES;
  GlimsStatus status = GLIMS_STATUS_OK;
  GeglRectangle changed = { 0 };
  for (GList *node = layers; node; node = node->next)
    {
      GimpLayer *candidate = node->data;
      GimpLayerMask *mask;
      if (candidate != layer && ! gimp_viewable_is_ancestor (GIMP_VIEWABLE (layer), GIMP_VIEWABLE (candidate)))
        continue;
      status = preflight_transformed_drawable (GIMP_DRAWABLE (candidate), matrix, &remaining,
                                               candidate == layer ? &changed : NULL, error);
      if (status != GLIMS_STATUS_OK) break;
      mask = gimp_layer_get_mask (candidate);
      if (mask)
        {
          status = preflight_transformed_drawable (GIMP_DRAWABLE (mask), matrix, &remaining, NULL, error);
          if (status != GLIMS_STATUS_OK) break;
        }
    }
  g_list_free (layers);
  if (status != GLIMS_STATUS_OK) return status;

  /* A small child can grow every containing group. Union the old parent
   * rectangle with the changed branch rather than subtracting old pixels:
   * this conservatively covers intermediate as well as final bounds.
   * Charge actual old effect/projection overhang separately from the item
   * envelope that sizes parent masks. Future unbounded effects are refused. */
  for (GimpLayer *parent = gimp_layer_get_parent (layer); parent;
       parent = gimp_layer_get_parent (parent))
    {
      GimpDrawable *drawable = GIMP_DRAWABLE (parent);
      GimpItem *item = GIMP_ITEM (parent);
      GimpLayerMask *mask = gimp_layer_get_mask (parent);
      gint x, y;
      gint64 left, top, right, bottom;
      GeglRectangle projection;
      status = check_transform_effect_bounds (drawable, error);
      if (status != GLIMS_STATUS_OK) return status;
      gimp_item_get_offset (item, &x, &y);
      left = MIN ((gint64) x, changed.x);
      top = MIN ((gint64) y, changed.y);
      right = MAX ((gint64) x + gimp_item_get_width (item), (gint64) changed.x + changed.width);
      bottom = MAX ((gint64) y + gimp_item_get_height (item), (gint64) changed.y + changed.height);
      /* Bound before converting the envelope to native rectangle fields. */
      if (right - left > GIMP_MAX_IMAGE_SIZE || bottom - top > GIMP_MAX_IMAGE_SIZE ||
          left < -2 * GIMP_MAX_IMAGE_SIZE || top < -2 * GIMP_MAX_IMAGE_SIZE ||
          right > 2 * GIMP_MAX_IMAGE_SIZE || bottom > 2 * GIMP_MAX_IMAGE_SIZE)
        return invalid_transform (error, "The transform would grow a containing group beyond the supported size or coordinates.");
      changed = (GeglRectangle) { left, top, right - left, bottom - top };
      if (mask)
        {
          status = admit_transform_storage (GIMP_DRAWABLE (mask), left, top, right, bottom, &remaining, error);
          if (status != GLIMS_STATUS_OK) return status;
        }
      /* The displayed drawable bound can be clipped by a group mask.
       * The raw projection still allocates its full child-effect extent. */
      projection = gimp_projectable_get_bounding_box (GIMP_PROJECTABLE (parent));
      left = MIN (left, (gint64) x + projection.x);
      top = MIN (top, (gint64) y + projection.y);
      right = MAX (right, (gint64) x + projection.x + projection.width);
      bottom = MAX (bottom, (gint64) y + projection.y + projection.height);
      status = admit_transform_storage (drawable, left, top, right, bottom, &remaining, error);
      if (status != GLIMS_STATUS_OK) return status;
    }
  return status;
}

typedef enum
{
  TRANSFORM_COMMIT,
  TRANSFORM_VALIDATE,
  TRANSFORM_PREVIEW
} TransformPurpose;

/* A private root raster layer can keep the upstream transform graph lazy.
 * This is the same buffer-space matrix and sampler as
 * gimp_drawable_transform_buffer_affine/gimp_gegl_apply_transform in
 * GIMP_3_2_8. The tile handler owns the graph and its original buffer; only
 * tiles demanded by the composite are materialized, at native precision.
 * Masks, groups, ancestors and effects retain the ordinary native path until
 * independently qualified. No original document ever receives this buffer. */
static void
preview_transform_raster (GimpLayer *layer, const GimpMatrix3 *matrix,
                          GimpInterpolationType interpolation)
{
  GimpDrawable *drawable = GIMP_DRAWABLE (layer);
  GeglBuffer *source = gimp_drawable_get_buffer (drawable);
  const Babl *format = gegl_buffer_get_format (source);
  GimpMatrix3 local;
  gint x, y, left, top, right, bottom;
  GeglNode *graph, *input, *transform, *output;
  GeglBuffer *buffer;
  GimpTileHandlerValidate *validate;

  gimp_item_get_offset (GIMP_ITEM (layer), &x, &y);
  gimp_transform_resize_boundary (matrix, GIMP_TRANSFORM_RESIZE_ADJUST,
                                  x, y, x + gegl_buffer_get_width (source),
                                  y + gegl_buffer_get_height (source),
                                  &left, &top, &right, &bottom);
  if (! gimp_matrix3_is_simple (matrix) && ! gimp_drawable_has_alpha (drawable))
    format = gimp_drawable_get_format_with_alpha (drawable);

  gimp_matrix3_identity (&local);
  gimp_matrix3_translate (&local, x, y);
  gimp_matrix3_mult (matrix, &local);
  gimp_matrix3_translate (&local, -left, -top);
  graph = gegl_node_new ();
  input = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", source, NULL);
  transform = gegl_node_new_child (graph, "operation", "gegl:transform",
                                   "near-z", GIMP_TRANSFORM_NEAR_Z, "sampler", interpolation, NULL);
  gimp_gegl_node_set_matrix (transform, &local);
  output = gegl_node_get_output_proxy (graph, "output");
  gegl_node_link_many (input, transform, output, NULL);
  buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, right - left, bottom - top), format);
  validate = GIMP_TILE_HANDLER_VALIDATE (gimp_tile_handler_validate_new (graph));
  gimp_tile_handler_validate_assign (validate, buffer);
  gimp_tile_handler_validate_invalidate (validate, gegl_buffer_get_extent (buffer));

  gimp_item_start_transform (GIMP_ITEM (layer), FALSE);
  gimp_drawable_set_buffer_full (drawable, FALSE, NULL, buffer,
                                 GEGL_RECTANGLE (left, top, 0, 0), TRUE);
  gimp_item_end_transform (GIMP_ITEM (layer), FALSE);
  g_object_unref (validate);
  g_object_unref (buffer);
  g_object_unref (graph);
}

static GlimsStatus
transform_layer_matrix (GlimsEngine       *engine,
                              GlimsImageID       id,
                              GlimsItemID        layer_id,
                              const GlimsMatrix *matrix,
                              uint32_t           interpolation,
                              const GlimsRect   *expected_bounds,
                              TransformPurpose   purpose,
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

  if (expected_bounds)
    {
      gint x, y;
      gimp_item_get_offset (GIMP_ITEM (layer), &x, &y);
      if (x != expected_bounds->x || y != expected_bounds->y ||
          gimp_item_get_width (GIMP_ITEM (layer)) != expected_bounds->width ||
          gimp_item_get_height (GIMP_ITEM (layer)) != expected_bounds->height)
        return glims_fail (error, NULL, "The layer changed while the transform was pending. Start the transform again.");
      /* Canvas transforms never implicitly discard editable text, links or
       * vector sources, including descendants of a selected group. */
      GList *layers = gimp_image_get_layer_list (image);
      gboolean editable = FALSE;
      for (GList *node = layers; node; node = node->next)
        {
          GimpLayer *candidate = node->data;
          if ((candidate == layer || gimp_viewable_is_ancestor (GIMP_VIEWABLE (layer), GIMP_VIEWABLE (candidate))) &&
              glims_layer_editable_source_kind (candidate))
            { editable = TRUE; break; }
        }
      g_list_free (layers);
      if (editable)
        {
          glims_fail (error, NULL, "Rasterize editable text, link or vector layers before applying this transform (Layer > Rasterize Layers).");
          return GLIMS_STATUS_UNSUPPORTED;
        }
    }

  status = glims_check_item_locks (GIMP_ITEM (layer), GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = normalize_transform (layer, &transform, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = preflight_transform_tree (image, layer, &transform, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (purpose == TRANSFORM_VALIDATE) return GLIMS_STATUS_OK;
  if (purpose == TRANSFORM_PREVIEW && ! GIMP_IS_GROUP_LAYER (layer) &&
      ! gimp_layer_get_parent (layer) && ! gimp_layer_get_mask (layer) &&
      gimp_container_get_n_children (gimp_drawable_get_filters (GIMP_DRAWABLE (layer))) == 0)
    {
      preview_transform_raster (layer, &transform, type);
      gimp_image_flush (image);
      return GLIMS_STATUS_OK;
    }
  /* Forward, grown to the result, as the unified transform tool commits
   * a layer (app/tools/gimptransformgridtool.c). gimp_item_transform opens
   * its own undo group. */
  gimp_item_transform (GIMP_ITEM (layer), gimp_get_user_context (engine->gimp), &transform,
                       GIMP_TRANSFORM_FORWARD, type, GIMP_TRANSFORM_RESIZE_ADJUST, NULL);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_transform_matrix (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                              const GlimsMatrix *matrix, uint32_t interpolation, char **error)
{
  return transform_layer_matrix (engine, image, layer, matrix, interpolation, NULL, TRANSFORM_COMMIT, error);
}

GlimsStatus
glims_layer_transform_matrix_captured (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                       const GlimsLayerTransformRequest *request, char **error)
{
  if (! request || request->struct_size < sizeof *request || layer <= 0 ||
      request->expected_bounds.width < 1 || request->expected_bounds.height < 1)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  return transform_layer_matrix (engine, image, layer, &request->matrix, request->interpolation,
                                  &request->expected_bounds, TRANSFORM_COMMIT, error);
}

GlimsStatus
glims_image_transform_preview (GlimsEngine *engine, GlimsImageID id, GlimsItemID layer_id,
                               const GlimsLayerTransformRequest *request,
                               GlimsImageID *result, char **error)
{
  GlimsStatus status;
  GlimsOpenImage *source = glims_lookup_image (engine, id);
  GlimsImageID copy = 0;
  GList *originals = NULL, *duplicates = NULL;
  GlimsItemID target = 0;

  if (result) *result = 0;
  if (! result || ! request || request->struct_size < sizeof *request || layer_id <= 0 ||
      request->expected_bounds.width < 1 || request->expected_bounds.height < 1)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (! source) return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, source, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = transform_layer_matrix (engine, id, layer_id, &request->matrix, request->interpolation,
                                   &request->expected_bounds, TRANSFORM_VALIDATE, error);
  if (status != GLIMS_STATUS_OK) return status;

  status = glims_image_duplicate (engine, id, &copy, error);
  if (status != GLIMS_STATUS_OK) return status;
  originals = gimp_image_get_layer_list (source->image);
  duplicates = gimp_image_get_layer_list (glims_lookup_image (engine, copy)->image);
  GList *a = originals, *b = duplicates;
  for (; a && b; a = a->next, b = b->next)
    {
      GimpItem *old = a->data, *new = b->data;
      if (G_OBJECT_TYPE (old) != G_OBJECT_TYPE (new) ||
          gimp_item_get_width (old) != gimp_item_get_width (new) ||
          gimp_item_get_height (old) != gimp_item_get_height (new) ||
          gimp_item_get_offset_x (old) != gimp_item_get_offset_x (new) ||
          gimp_item_get_offset_y (old) != gimp_item_get_offset_y (new))
        break;
      if (gimp_item_get_id (old) == layer_id) target = gimp_item_get_id (new);
    }
  if (a || b || ! target)
    status = glims_fail (error, NULL, "The preview copy does not match the source layer tree.");
  else
    status = transform_layer_matrix (engine, copy, target, &request->matrix, request->interpolation,
                                     &request->expected_bounds, TRANSFORM_PREVIEW, error);
  g_list_free (originals);
  g_list_free (duplicates);
  if (status == GLIMS_STATUS_OK) *result = copy;
  else glims_release_image (engine, copy);
  return status;
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

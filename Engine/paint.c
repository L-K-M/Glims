/*
 * Paint strokes with GIMP's paint cores: paintbrush, pencil, airbrush,
 * eraser, smudge, blur and sharpen, dodge and burn, clone and heal. Runs
 * on the engine thread.
 *
 * The call sequence is the one GIMP's own gimp_paint_core_stroke()
 * (app/paint/gimppaintcore-stroke.c) uses, split over begin, continue and
 * end so the app can feed pointer events as they arrive. GIMP's GTK paint
 * tool additionally paints on a worker thread and smooths input; neither is
 * reproduced yet (docs/plan.md).
 */
#include "engine-private.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdatafactory.h"
#include "core/gimpdrawable.h"
#include "core/gimpdynamics.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimppaintinfo.h"

#include "paint/gimpairbrush.h"
#include "paint/gimppaintcore.h"
#include "paint/gimppaintoptions.h"

/* Engine names; resolved at run time so a missing one fails visibly. */
#define PRESSURE_SIZE_DYNAMICS  "Pressure Size"

/* The paint info (core and options type) behind each Glims paint tool, as
 * GIMP's tools register them (app/paint/gimp*.c, gimp_*_register). */
static const gchar *const paint_infos[] =
{
  [GLIMS_PAINT_PAINTBRUSH] = "gimp-paintbrush",
  [GLIMS_PAINT_PENCIL]     = "gimp-pencil",
  [GLIMS_PAINT_AIRBRUSH]   = "gimp-airbrush",
  [GLIMS_PAINT_ERASER]     = "gimp-eraser",
  [GLIMS_PAINT_SMUDGE]     = "gimp-smudge",
  [GLIMS_PAINT_BLUR]       = "gimp-convolve",
  [GLIMS_PAINT_SHARPEN]    = "gimp-convolve",
  [GLIMS_PAINT_DODGE]      = "gimp-dodge-burn",
  [GLIMS_PAINT_BURN]       = "gimp-dodge-burn",
  [GLIMS_PAINT_CLONE]      = "gimp-clone",
  [GLIMS_PAINT_HEAL]       = "gimp-heal",
};

typedef struct
{
  GimpImage        *image;
  GimpDrawable     *drawable;
  GList            *drawables;
  GimpPaintCore    *core;
  GimpPaintOptions *options;
} GlimsStroke;

/* The paint info (core and options type) behind a Glims paint tool, or
 * NULL when the engine lacks the tool. */
GimpPaintInfo *
glims_paint_info_for_tool (Gimp    *gimp,
                           uint32_t tool)
{
  if (tool >= G_N_ELEMENTS (paint_infos))
    return NULL;

  return GIMP_PAINT_INFO (gimp_container_get_child_by_name (gimp->paint_info_list,
                                                            paint_infos[tool]));
}

void
glims_strokes_free (gpointer data)
{
  GlimsStroke *stroke = data;

  /* A stroke the app never ended is cancelled, leaving no undo step. */
  if (stroke->core && stroke->drawables)
    {
      gimp_paint_core_cancel (stroke->core, stroke->drawables);
      gimp_paint_core_cleanup (stroke->core);
    }

  if (stroke->core)
    g_signal_handlers_disconnect_matched (stroke->core, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, stroke);
  g_clear_object (&stroke->core);
  g_clear_object (&stroke->options);
  g_list_free (stroke->drawables);
  g_clear_object (&stroke->drawable);
  g_clear_object (&stroke->image);
  g_free (stroke);
}

static GimpCoords
to_coords (const GlimsStrokePoint *point)
{
  GimpCoords coords = GIMP_COORDS_DEFAULT_VALUES;

  coords.x        = point->x;
  coords.y        = point->y;
  coords.pressure = CLAMP (point->pressure, GIMP_COORDS_MIN_PRESSURE, GIMP_COORDS_MAX_PRESSURE);
  coords.xtilt    = CLAMP (point->xtilt, GIMP_COORDS_MIN_TILT, GIMP_COORDS_MAX_TILT);
  coords.ytilt    = CLAMP (point->ytilt, GIMP_COORDS_MIN_TILT, GIMP_COORDS_MAX_TILT);

  return coords;
}

/* Sets a numeric option within its own range; negative means "keep the
 * engine's default". */
static void
set_number (GObject     *options,
            const gchar *property,
            gdouble      value)
{
  GParamSpec *pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (options), property);

  if (value < 0.0 || ! G_IS_PARAM_SPEC_DOUBLE (pspec))
    return;

  g_object_set (options, property,
                CLAMP (value, G_PARAM_SPEC_DOUBLE (pspec)->minimum, G_PARAM_SPEC_DOUBLE (pspec)->maximum),
                NULL);
}

/* The tool's own options, as GIMP's tool options dialogs set them. */
void
glims_set_tool_options (GimpPaintOptions         *options,
                        const GlimsBrushSettings *brush,
                        GimpDrawable             *source)
{
  GObject *object = G_OBJECT (options);

  set_number (object, "brush-hardness", brush->hardness);

  switch (brush->tool)
    {
    case GLIMS_PAINT_AIRBRUSH:
    case GLIMS_PAINT_SMUDGE:
      set_number (object, "rate", brush->rate);
      set_number (object, "flow", brush->flow);
      break;

    case GLIMS_PAINT_BLUR:
    case GLIMS_PAINT_SHARPEN:
      g_object_set (object, "type",
                    brush->tool == GLIMS_PAINT_BLUR ? GIMP_CONVOLVE_BLUR : GIMP_CONVOLVE_SHARPEN,
                    NULL);
      set_number (object, "rate", brush->rate);
      break;

    case GLIMS_PAINT_DODGE:
    case GLIMS_PAINT_BURN:
      g_object_set (object,
                    "type", brush->tool == GLIMS_PAINT_DODGE ? GIMP_DODGE_BURN_TYPE_DODGE
                                                             : GIMP_DODGE_BURN_TYPE_BURN,
                    "mode", brush->tones == GLIMS_TONES_SHADOWS    ? GIMP_TRANSFER_SHADOWS :
                            brush->tones == GLIMS_TONES_HIGHLIGHTS ? GIMP_TRANSFER_HIGHLIGHTS :
                                                                     GIMP_TRANSFER_MIDTONES,
                    NULL);
      set_number (object, "exposure", brush->exposure);
      break;

    case GLIMS_PAINT_ERASER:
      g_object_set (object, "anti-erase", brush->anti_erase ? TRUE : FALSE, NULL);
      break;

    case GLIMS_PAINT_CLONE:
    case GLIMS_PAINT_HEAL:
      {
        GList *sources = g_list_prepend (NULL, source);

        /* "None" alignment: the stroke's first point copies the source
         * point and the source moves with the stroke, as in GIMP's clone
         * tool after a Ctrl-click (app/paint/gimpsourcecore.c). The app
         * keeps any alignment between strokes by choosing the point. */
        g_object_set (object,
                      "src-drawables", sources,
                      "src-x",         (gint) floor (brush->source_x),
                      "src-y",         (gint) floor (brush->source_y),
                      "align-mode",    GIMP_SOURCE_ALIGN_NO,
                      NULL);
        g_list_free (sources);
      }
      break;

    default:
      break;
    }
}

/* `brush_resource` is the stroke's own selected brush, or NULL to inherit
 * the user context's current brush as stroke_begin() always did. */
GimpPaintOptions *
glims_make_paint_options (Gimp                     *gimp,
                          GimpPaintInfo            *info,
                          const GlimsBrushSettings *brush,
                          GimpBrush                *brush_resource)
{
  GimpPaintOptions *options;
  GimpContext      *context;
  GeglColor        *color;
  GimpObject       *dynamics = NULL;

  options = GIMP_PAINT_OPTIONS (gimp_config_duplicate (GIMP_CONFIG (info->paint_options)));
  context = GIMP_CONTEXT (options);

  /* Inherit the paint-relevant settings (brush, gradient, ...) from the user
   * context, as the engine's own stroke procedures do, then pin what the
   * app chose. */
  gimp_context_define_properties (context, GIMP_CONTEXT_PROP_MASK_PAINT, FALSE);
  gimp_context_set_parent (context, gimp_get_user_context (gimp));

  if (brush_resource)
    {
      /* Define the property locally BEFORE assigning it: for an undefined
       * property gimp_context_set_brush() walks up to the parent — here
       * the shared user context, which must never be mutated — and the
       * local definition also shields this stroke from later parent
       * changes. Set on the stroke's own context, the brush is held
       * strongly (g_set_object) for the whole stroke. */
      gimp_context_define_property (context, GIMP_CONTEXT_PROP_BRUSH, TRUE);
      gimp_context_set_brush (context, brush_resource);
    }

  color = gegl_color_new (NULL);
  gegl_color_set_rgba_with_space (color, brush->red, brush->green, brush->blue, 1.0, NULL);
  gimp_context_define_property (context, GIMP_CONTEXT_PROP_FOREGROUND, TRUE);
  gimp_context_set_foreground (context, color);
  g_object_unref (color);

  gimp_context_define_property (context, GIMP_CONTEXT_PROP_OPACITY, TRUE);
  gimp_context_set_opacity (context, CLAMP (brush->opacity, 0.0, 1.0));

  g_object_set (options, "brush-size", brush->size, NULL);

  if (brush->pressure_size)
    dynamics = gimp_container_get_child_by_name (gimp_data_factory_get_container (gimp->dynamics_factory),
                                                 PRESSURE_SIZE_DYNAMICS);
  if (dynamics)
    {
      gimp_context_define_property (context, GIMP_CONTEXT_PROP_DYNAMICS, TRUE);
      gimp_context_set_dynamics (context, GIMP_DYNAMICS (dynamics));
    }
  gimp_paint_options_enable_dynamics (options, dynamics != NULL);

  return options;
}

/* The airbrush keeps painting while the pointer rests: its core emits
 * "stamp" from a timer on the engine's main loop, and GIMP's tool answers
 * by painting again at the last point (app/tools/gimpairbrushtool.c). */
static void
airbrush_stamp (GimpAirbrush *airbrush,
                GlimsStroke  *stroke)
{
  gimp_airbrush_stamp (airbrush);
  gimp_image_flush (stroke->image);
}

/* The caller's settings, with the fields its struct_size lacks filled with
 * defaults (an older caller paints with the paintbrush). */
gboolean
glims_read_brush (const GlimsBrushSettings *brush,
                  GlimsBrushSettings       *settings)
{
  if (! brush || brush->struct_size < offsetof (GlimsBrushSettings, tool))
    return FALSE;

  memset (settings, 0, sizeof (*settings));
  memcpy (settings, brush, MIN (brush->struct_size, sizeof (*settings)));

  if (brush->struct_size < sizeof (*settings))
    {
      settings->tool     = GLIMS_PAINT_PAINTBRUSH;
      settings->hardness = -1.0;
      settings->rate     = -1.0;
      settings->flow     = -1.0;
      settings->exposure = -1.0;
    }
  settings->struct_size = sizeof (*settings);

  return settings->tool < G_N_ELEMENTS (paint_infos);
}

/* The one paint-begin path behind stroke_begin and
 * stroke_begin_with_brush_resource: `brush_resource` is the stroke's own
 * selected brush, or NULL to inherit the user context's brush. */
static GlimsStatus
stroke_begin_common (GlimsEngine              *engine,
                     GlimsImageID              image_id,
                     GlimsItemID               layer_id,
                     const GlimsBrushSettings *brush,
                     GimpBrush                *brush_resource,
                     const GlimsStrokePoint   *first,
                     GlimsStrokeID            *out,
                     char                    **error)
{
  GlimsOpenImage     *open = glims_lookup_image (engine, image_id);
  GlimsBrushSettings  settings;
  GimpDrawable       *drawable;
  GimpDrawable       *source = NULL;
  GimpPaintInfo      *info;
  GlimsStroke        *stroke;
  GimpCoords          coords;
  GError             *gerror = NULL;
  gint                id;
  GlimsStatus         status;
  uint32_t            locks = GLIMS_LOCK_PIXELS;

  if (out)
    *out = 0;  /* a refused call leaves no stroke id behind */
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! glims_read_brush (brush, &settings) || ! first || ! out || ! (settings.size > 0.0))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  brush = &settings;
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  drawable = glims_lookup_drawable (open, layer_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;
  if (GIMP_IS_GROUP_LAYER (drawable))
    {
      if (error)
        *error = strdup ("Groups cannot be painted on.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (brush->tool == GLIMS_PAINT_ERASER && gimp_drawable_has_alpha (drawable))
    locks |= GLIMS_LOCK_ALPHA;
  status = glims_check_item_locks (GIMP_ITEM (drawable), locks, error);
  if (status != GLIMS_STATUS_OK) return status;

  if (brush->tool == GLIMS_PAINT_CLONE || brush->tool == GLIMS_PAINT_HEAL)
    {
      GimpItem *item = gimp_item_get_by_id (engine->gimp, brush->source_drawable);

      if (! GIMP_IS_DRAWABLE (item) || GIMP_IS_GROUP_LAYER (item) || ! gimp_item_is_attached (item))
        return glims_fail (error, NULL, "Choose a source point on a layer first.");
      source = GIMP_DRAWABLE (item);
    }

  info = glims_paint_info_for_tool (engine->gimp, brush->tool);
  if (! info)
    return glims_fail (error, NULL, "The engine lacks this paint tool.");

  stroke = g_new0 (GlimsStroke, 1);
  stroke->image     = g_object_ref (open->image);
  stroke->drawable  = g_object_ref (drawable);
  stroke->options   = glims_make_paint_options (engine->gimp, info, brush, brush_resource);
  stroke->core      = g_object_new (info->paint_type, "undo-desc", info->blurb, NULL);
  glims_set_tool_options (stroke->options, brush, source);

  if (GIMP_IS_AIRBRUSH (stroke->core))
    g_signal_connect (stroke->core, "stamp", G_CALLBACK (airbrush_stamp), stroke);

  coords = to_coords (first);
  stroke->drawables = g_list_prepend (NULL, drawable);

  if (! gimp_paint_core_start (stroke->core, stroke->drawables, stroke->options, &coords, &gerror))
    {
      g_list_free (stroke->drawables);
      stroke->drawables = NULL;
      glims_strokes_free (stroke);
      return glims_fail (error, gerror, "The stroke could not start.");
    }

  stroke->core->last_coords = coords;
  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options,
                         GIMP_PAINT_STATE_INIT, first->time_ms);
  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options,
                         GIMP_PAINT_STATE_MOTION, first->time_ms);
  gimp_image_flush (open->image);

  id = glims_next_session_id (engine);
  g_hash_table_insert (engine->strokes, GINT_TO_POINTER (id), stroke);
  *out = id;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_stroke_begin (GlimsEngine              *engine,
                    GlimsImageID              image_id,
                    GlimsItemID               layer_id,
                    const GlimsBrushSettings *brush,
                    const GlimsStrokePoint   *first,
                    GlimsStrokeID            *out,
                    char                    **error)
{
  return stroke_begin_common (engine, image_id, layer_id, brush, NULL, first, out, error);
}

GlimsStatus
glims_stroke_begin_with_brush_resource (GlimsEngine              *engine,
                                        GlimsImageID              image_id,
                                        GlimsItemID               layer_id,
                                        GlimsResourceID           brush_id,
                                        const GlimsBrushSettings *brush,
                                        const GlimsStrokePoint   *first,
                                        GlimsStrokeID            *out,
                                        char                    **error)
{
  GimpBrush   *resource = NULL;
  GlimsStatus  status;

  if (! out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *out = 0;

  /* Resolved once, here at begin, on the engine thread: the stroke keeps
   * exactly this brush for its whole life, whatever the caller's settings
   * or the shared user context become later. */
  status = glims_lookup_brush (engine, brush_id, &resource);
  if (status != GLIMS_STATUS_OK)
    {
      if (error)
        *error = strdup (status == GLIMS_STATUS_INVALID_ARGUMENT
                         ? "This handle cannot name a brush."
                         : "This brush is no longer in the engine's brush factory.");
      return status;
    }

  return stroke_begin_common (engine, image_id, layer_id, brush, resource, first, out, error);
}

GlimsStatus
glims_stroke_continue (GlimsEngine            *engine,
                       GlimsStrokeID           id,
                       const GlimsStrokePoint *points,
                       size_t                  count)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  size_t       i;

  if (! stroke)
    return GLIMS_STATUS_NOT_FOUND;
  if (count > 0 && ! points)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  for (i = 0; i < count; i++)
    {
      GimpCoords coords = to_coords (&points[i]);

      gimp_paint_core_interpolate (stroke->core, stroke->drawables, stroke->options,
                                   &coords, points[i].time_ms);
    }

  gimp_image_flush (stroke->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_stroke_end (GlimsEngine   *engine,
                  GlimsStrokeID  id)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));

  if (! stroke)
    return GLIMS_STATUS_NOT_FOUND;

  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options,
                         GIMP_PAINT_STATE_FINISH, 0);
  gimp_paint_core_finish (stroke->core, stroke->drawables, TRUE);
  gimp_paint_core_cleanup (stroke->core);
  gimp_image_flush (stroke->image);

  /* Finished: nothing for the free function to cancel. */
  g_list_free (stroke->drawables);
  stroke->drawables = NULL;
  g_hash_table_remove (engine->strokes, GINT_TO_POINTER (id));

  return GLIMS_STATUS_OK;
}

/*
 * Paint strokes with GIMP's paintbrush core. Runs on the engine thread.
 *
 * The call sequence is the one GIMP's own gimp_paint_core_stroke()
 * (app/paint/gimppaintcore-stroke.c) uses, split over begin, continue and
 * end so the app can feed pointer events as they arrive. GIMP's GTK paint
 * tool additionally paints on a worker thread and smooths input; neither is
 * reproduced yet (docs/plan.md).
 */
#include "engine-private.h"

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

#include "paint/gimppaintcore.h"
#include "paint/gimppaintoptions.h"

/* Engine names; resolved at run time so a missing one fails visibly. */
#define PAINTBRUSH_PAINT_INFO   "gimp-paintbrush"
#define PRESSURE_SIZE_DYNAMICS  "Pressure Size"

typedef struct
{
  GimpImage        *image;
  GimpDrawable     *drawable;
  GList            *drawables;
  GimpPaintCore    *core;
  GimpPaintOptions *options;
} GlimsStroke;

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

static GimpPaintOptions *
make_options (Gimp                     *gimp,
              GimpPaintInfo            *info,
              const GlimsBrushSettings *brush)
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

GlimsStatus
glims_stroke_begin (GlimsEngine              *engine,
                    GlimsImageID              image_id,
                    GlimsItemID               layer_id,
                    const GlimsBrushSettings *brush,
                    const GlimsStrokePoint   *first,
                    GlimsStrokeID            *out,
                    char                    **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, image_id);
  GimpDrawable   *drawable;
  GimpPaintInfo  *info;
  GlimsStroke    *stroke;
  GimpCoords      coords;
  GError         *gerror = NULL;
  gint            id;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! brush || brush->struct_size < sizeof (GlimsBrushSettings) || ! first || ! out ||
      ! (brush->size > 0.0))
    return GLIMS_STATUS_INVALID_ARGUMENT;
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

  info = GIMP_PAINT_INFO (gimp_container_get_child_by_name (engine->gimp->paint_info_list,
                                                            PAINTBRUSH_PAINT_INFO));
  if (! info)
    return glims_fail (error, NULL, "The engine has no paintbrush.");

  stroke = g_new0 (GlimsStroke, 1);
  stroke->image     = g_object_ref (open->image);
  stroke->drawable  = g_object_ref (drawable);
  stroke->options   = make_options (engine->gimp, info, brush);
  stroke->core      = g_object_new (info->paint_type, "undo-desc", info->blurb, NULL);

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

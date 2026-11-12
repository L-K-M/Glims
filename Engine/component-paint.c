/*
 * Component paint cores: owned subclasses of the native paintbrush,
 * pencil and airbrush cores whose paint parameters stay fixed for
 * component strokes. Each overrides only get_paint_params; the native
 * parent still controls mask geometry, brush dynamics, the airbrush
 * timer, undo and ownership. Runs on the engine thread.
 */
#include "component-paint.h"

#include "core/gimpcontext.h"

#include "paint/gimpairbrush.h"
#include "paint/gimppaintbrush.h"
#include "paint/gimppencil.h"

typedef struct { GimpPaintbrush      parent_instance; } GlimsComponentPaintbrush;
typedef struct { GimpPaintbrushClass parent_class;    } GlimsComponentPaintbrushClass;
typedef struct { GimpPencil          parent_instance; } GlimsComponentPencil;
typedef struct { GimpPencilClass     parent_class;    } GlimsComponentPencilClass;
typedef struct { GimpAirbrush        parent_instance; } GlimsComponentAirbrush;
typedef struct { GimpAirbrushClass   parent_class;    } GlimsComponentAirbrushClass;

static GType glims_component_paintbrush_get_type (void);
static GType glims_component_pencil_get_type     (void);
static GType glims_component_airbrush_get_type   (void);

G_DEFINE_TYPE (GlimsComponentPaintbrush, glims_component_paintbrush, GIMP_TYPE_PAINTBRUSH)
G_DEFINE_TYPE (GlimsComponentPencil,     glims_component_pencil,     GIMP_TYPE_PENCIL)
G_DEFINE_TYPE (GlimsComponentAirbrush,   glims_component_airbrush,   GIMP_TYPE_AIRBRUSH)

/* Fixed parameters for a component stroke: NORMAL mode, no pixmap, and
 * an owned copy of the options context's foreground. The painter
 * retains the returned color, so the shared context color is
 * duplicated, never borrowed. Airbrush stamps must accumulate between
 * its timed motions, hence INCREMENTAL; the other cores stamp
 * CONSTANT. The parent implementation is deliberately not chained:
 * gradient, pixmap and color-dynamics inputs do not apply here. */
static void
component_paint_params (GimpPaintbrush            *paintbrush,
                        GimpDrawable              *drawable,
                        GimpPaintOptions          *paint_options,
                        GimpSymmetry              *sym,
                        gdouble                    grad_point,
                        GimpLayerMode             *paint_mode,
                        GimpPaintApplicationMode  *paint_appl_mode,
                        const GimpTempBuf        **paint_pixmap,
                        GeglColor                **paint_color)
{
  (void) drawable;
  (void) sym;
  (void) grad_point;

  *paint_mode      = GIMP_LAYER_MODE_NORMAL;
  *paint_appl_mode = GIMP_IS_AIRBRUSH (paintbrush) ? GIMP_PAINT_INCREMENTAL
                                                 : GIMP_PAINT_CONSTANT;
  *paint_pixmap    = NULL;
  *paint_color     = gegl_color_duplicate (
      gimp_context_get_foreground (GIMP_CONTEXT (paint_options)));
}

static void
glims_component_paintbrush_class_init (GlimsComponentPaintbrushClass *klass)
{
  GIMP_PAINTBRUSH_CLASS (klass)->get_paint_params = component_paint_params;
}

static void
glims_component_paintbrush_init (GlimsComponentPaintbrush *self)
{
  (void) self;
}

static void
glims_component_pencil_class_init (GlimsComponentPencilClass *klass)
{
  GIMP_PAINTBRUSH_CLASS (klass)->get_paint_params = component_paint_params;
}

static void
glims_component_pencil_init (GlimsComponentPencil *self)
{
  (void) self;
}

static void
glims_component_airbrush_class_init (GlimsComponentAirbrushClass *klass)
{
  GIMP_PAINTBRUSH_CLASS (klass)->get_paint_params = component_paint_params;
}

static void
glims_component_airbrush_init (GlimsComponentAirbrush *self)
{
  (void) self;
}

GType
glims_component_paint_type (uint32_t tool)
{
  switch (tool)
    {
    case GLIMS_PAINT_PAINTBRUSH: return glims_component_paintbrush_get_type ();
    case GLIMS_PAINT_PENCIL:     return glims_component_pencil_get_type ();
    case GLIMS_PAINT_AIRBRUSH:   return glims_component_airbrush_get_type ();
    default:                     return 0;
    }
}

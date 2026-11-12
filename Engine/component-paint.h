/* Engine-thread-only component paint cores: owned subclasses of the
 * native painters whose paint parameters stay fixed for component
 * strokes. */
#ifndef GLIMS_COMPONENT_PAINT_H
#define GLIMS_COMPONENT_PAINT_H

#include "engine-private.h"

/* The adapter-owned paint-core type for `tool`: a GimpPaintbrush
 * subclass for GLIMS_PAINT_PAINTBRUSH, a GimpPencil subclass for
 * GLIMS_PAINT_PENCIL, a GimpAirbrush subclass for GLIMS_PAINT_AIRBRUSH.
 * 0 for every other tool. */
GType glims_component_paint_type (uint32_t tool);

#endif

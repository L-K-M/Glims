/* Private CMYK preview conversion. This does not admit a new document mode. */
#ifndef GLIMS_CMYK_TRANSFORM_H
#define GLIMS_CMYK_TRANSFORM_H

#include <glib.h>

#define GLIMS_CMYK_ICC_MAX_BYTES (4u * 1024u * 1024u)
#define GLIMS_CMYK_TRANSFORM_MAX_PIXELS 4096u

typedef struct _GlimsCmykTransform GlimsCmykTransform;

/* Copies a bounded CMYK input/output/color-space profile and builds a private
 * relative-colorimetric, black-point-compensated transform to linear sRGB.
 * Device-link, abstract, named-color and non-CMYK profiles are refused.
 * No process-global LittleCMS handlers, context or environment are changed. */
GlimsCmykTransform *glims_cmyk_transform_new (const guint8 *icc, gsize size,
                                             GError **error);
void glims_cmyk_transform_free (GlimsCmykTransform *transform);

/* At most MAX_PIXELS interleaved C/M/Y/K intensity tuples: 0=full ink,
 * 1=paper. Writes straight linear-sRGB RGBA, with alpha exactly one.
 * Rejects nonfinite/out-of-range samples before modifying any output.
 * Input/output may be the same array but must not otherwise overlap.
 * A zero-pixel call accepts NULL buffers. One instance is serialized by its
 * owner; separate instances own separate LittleCMS contexts and caches. */
gboolean glims_cmyk_transform_pixels (GlimsCmykTransform *transform,
                                       const gfloat *intensity, gsize count,
                                       gfloat *rgba, GError **error);

#endif

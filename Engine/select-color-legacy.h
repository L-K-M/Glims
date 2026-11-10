#ifndef GLIMS_SELECT_COLOR_LEGACY_H
#define GLIMS_SELECT_COLOR_LEGACY_H

#include "engine-private.h"

/* Exact-3.0.8 workaround for the source-buffer leak in the native
 * contiguous-region algorithms. In that engine,
 * gimp_pickable_contiguous_region_by_seed() and
 * gimp_pickable_contiguous_region_by_color() acquire an owned source
 * buffer through gimp_pickable_get_buffer_with_effects() and never
 * release it (_engine/src/GIMP_3_0_8/gimp/app/core/
 * gimppickable-contiguous-region.cc, src_buffer at lines 147 and 225).
 * The supported 3.2.0 and 3.2.8 sources already clear src_buffer, so this
 * helper exists and compiles only for exact 3.0.8; other engines must
 * call the native functions directly. */
#if GIMP_MAJOR_VERSION == 3 && GIMP_MINOR_VERSION == 0 && GIMP_MICRO_VERSION == 8

/* The "Y float" selection mask the unchanged 3.0.8 algorithms produce
 * for `source`, without leaking its effects buffer. `source` is flushed
 * normally, its post-effects buffer is materialized once, and the
 * algorithm runs against a private proxy pickable that counts the owned
 * references it hands out; exactly those are released afterwards.
 *
 * `contiguous` selects the seeded region at (x, y) in source
 * coordinates; otherwise the whole source is matched against `color`,
 * the caller-sampled pixel. The options are the fixed set the selection
 * tools use: `select_transparent` TRUE, criterion COMPOSITE, diagonal
 * neighbors FALSE. The native algorithm reads the original buffer's
 * format/space/extents and returns an owned Y-float mask; applying it
 * to an image's selection mask,
 * including any item-offset translation, is the caller's job — or NULL
 * when `source` has no buffer to pick from. */
GeglBuffer *glims_select_color_legacy_mask (GimpPickable *source,
                                            gboolean      contiguous,
                                            gboolean      antialias,
                                            gfloat        threshold,
                                            gint          x,
                                            gint          y,
                                            GeglColor    *color);

#endif /* exact GIMP 3.0.8 */

#endif /* GLIMS_SELECT_COLOR_LEGACY_H */

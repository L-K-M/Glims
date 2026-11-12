/* Glims saturation brush. The brush-region and dynamics sequence is
 * adapted from GIMP_3_2_8 app/paint/gimpdodgeburn.c, GPL-3.0-or-later,
 * Copyright (C) 1995 Spencer Kimball and Peter Mattis.
 * The masked replacement follows app/paint/gimppaintcore.c, also
 * Copyright (C) 2013 Daniel Sabo, with explicit nonlinear compositing.
 * The owned pixel transform preserves neutral colors and source alpha.
 * Upstream sources are not modified. */
#include "engine-private.h"
#include <math.h>
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpdynamics.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimppaintinfo.h"
#include "core/gimpsymmetry.h"
#include "core/gimptempbuf.h"
#include "gegl/gimp-gegl-loops.h"
#include "gegl/gimp-gegl-utils.h"
#include "gegl/gimpapplicator.h"
#include "paint/gimpbrushcore.h"
#include "paint/gimppaintoptions.h"

typedef struct { GimpBrushCore parent; gboolean saturate; } GlimsSponge;
typedef struct { GimpBrushCoreClass parent; } GlimsSpongeClass;
typedef struct { GlimsSponge parent; } GlimsSpongeSaturate;
typedef struct { GlimsSpongeClass parent; } GlimsSpongeSaturateClass;
static void glims_sponge_paint (GimpPaintCore *, GList *, GimpPaintOptions *,
                                GimpSymmetry *, GimpPaintState, guint32);
G_DEFINE_TYPE (GlimsSponge, glims_sponge, GIMP_TYPE_BRUSH_CORE)
G_DEFINE_TYPE (GlimsSpongeSaturate, glims_sponge_saturate, glims_sponge_get_type ())

static void glims_sponge_class_init (GlimsSpongeClass *klass)
{
  GIMP_PAINT_CORE_CLASS (klass)->paint = glims_sponge_paint;
  GIMP_BRUSH_CORE_CLASS (klass)->handles_changing_brush = TRUE;
}
static void glims_sponge_init (GlimsSponge *self) { self->saturate = FALSE; }
static void glims_sponge_saturate_class_init (GlimsSpongeSaturateClass *klass) { (void) klass; }
static void glims_sponge_saturate_init (GlimsSpongeSaturate *self) { self->parent.saturate = TRUE; }

GimpPaintInfo *
glims_sponge_paint_info (Gimp *gimp, gboolean saturate)
{
  const char *name = saturate ? "glims-sponge-saturate" : "glims-sponge-desaturate";
  GimpPaintInfo *info = GIMP_PAINT_INFO (gimp_container_get_child_by_name (gimp->paint_info_list, name));
  if (info) return info;
  info = gimp_paint_info_new (gimp,
           saturate ? glims_sponge_saturate_get_type () : glims_sponge_get_type (),
           GIMP_TYPE_PAINT_OPTIONS, name,
           saturate ? "Sponge Saturate" : "Sponge Desaturate", "gimp-tool-dodge");
  if (!info) return NULL;
  gboolean added = gimp_container_add (gimp->paint_info_list, GIMP_OBJECT (info));
  g_object_unref (info);
  return added ? info : NULL; /* the paint-info list owns its reference */
}

static void
sponge_region (GeglBuffer *source, gint x, gint y, GeglBuffer *paint,
               const Babl *space, gboolean saturate)
{
  const Babl *format = babl_format_with_space ("R'G'B'A float", space);
  GeglRectangle output = { 0, 0, gegl_buffer_get_width (paint), gegl_buffer_get_height (paint) };
  GeglRectangle input = { x, y, output.width, output.height };
  GeglBufferIterator *iter = gegl_buffer_iterator_new (paint, &output, 0, format,
                                    GEGL_ACCESS_WRITE, GEGL_ABYSS_NONE, 2);
  gegl_buffer_iterator_add (iter, source, &input, 0, format, GEGL_ACCESS_READ, GEGL_ABYSS_NONE);
  while (gegl_buffer_iterator_next (iter))
    {
      gfloat *out = iter->items[0].data;
      const gfloat *in = iter->items[1].data;
      for (gint i = 0; i < iter->length; i++, in += 4, out += 4)
        {
          gfloat low = MIN (in[0], MIN (in[1], in[2]));
          gfloat high = MAX (in[0], MAX (in[1], in[2]));
          gfloat delta = high - low;
          for (gint c = 0; c < 4; c++) out[c] = in[c];
          if (!isfinite (low) || !isfinite (high) || delta <= 0 || in[3] <= 0)
            continue;
          if (saturate)
            {
              /* Neutral pixels keep their hue undefined. HDR samples already
               * at or above full saturation keep their existing channel range. */
              if (high <= 0 || delta >= high) continue;
              for (gint c = 0; c < 3; c++) out[c] = (in[c] - low) * (high / delta);
            }
          else
            for (gint c = 0; c < 3; c++) out[c] = high;
          /* Source alpha is retained. Nonlinear replacement interpolates
           * this endpoint without changing hue or value. */
        }
    }
}

/* GimpPaintCore's stock replacement composites in linear RGB. That bends
 * HSV hue when desaturating at partial strength. Use the same native brush,
 * selection, component and undo machinery, but interpolate in working-space
 * nonlinear RGB. No alpha is introduced and no legacy HSV epsilon is used. */
static void
sponge_replace (GimpBrushCore *brush, GimpDrawable *drawable,
                GimpPaintOptions *options, const GimpCoords *coords,
                gdouble opacity, gdouble force)
{
  GimpPaintCore *core = GIMP_PAINT_CORE (brush);
  const GimpTempBuf *brush_mask = gimp_brush_core_get_brush_mask (
      brush, coords, gimp_paint_options_get_brush_mode (options), force);
  if (!brush_mask || !gimp_drawable_get_active_mask (drawable)) return;
  GimpApplicator *applicator = g_hash_table_lookup (core->applicators, drawable);
  g_return_if_fail (applicator != NULL);
  gint width = gegl_buffer_get_width (core->paint_buffer);
  gint height = gegl_buffer_get_height (core->paint_buffer);
  gint x = (gint) floor (coords->x) - (gimp_temp_buf_get_width (brush_mask) >> 1);
  gint y = (gint) floor (coords->y) - (gimp_temp_buf_get_height (brush_mask) >> 1);
  GeglRectangle paint_rect = { core->paint_buffer_x, core->paint_buffer_y, width, height };
  GeglRectangle mask_rect = { MAX (0, -x), MAX (0, -y), width, height };
  GeglBuffer *mask = gimp_temp_buf_create_buffer ((GimpTempBuf *) brush_mask);
  if (options->application_mode == GIMP_PAINT_CONSTANT)
    {
      gimp_gegl_combine_mask_weird (mask, &mask_rect, core->canvas_buffer,
                                    &paint_rect, opacity, FALSE);
      g_object_unref (mask);
      mask = g_object_ref (core->canvas_buffer);
      mask_rect = paint_rect;
      gimp_applicator_set_src_buffer (applicator,
                                      g_hash_table_lookup (core->undo_buffers, drawable));
    }
  else
    gimp_applicator_set_src_buffer (applicator, gimp_drawable_get_buffer (drawable));

  gint off_x, off_y;
  gimp_item_get_offset (GIMP_ITEM (drawable), &off_x, &off_y);
  if (core->mask_buffer)
    {
      GeglRectangle aligned;
      gegl_rectangle_align_to_buffer (&aligned, &paint_rect,
                                      gimp_drawable_get_buffer (drawable),
                                      GEGL_RECTANGLE_ALIGNMENT_SUPERSET);
      GeglBuffer *combined = gegl_buffer_new (&aligned, babl_format ("Y float"));
      gimp_gegl_buffer_copy (core->mask_buffer,
                             GEGL_RECTANGLE (aligned.x + off_x, aligned.y + off_y,
                                             aligned.width, aligned.height),
                             GEGL_ABYSS_NONE, combined, &aligned);
      gimp_gegl_combine_mask (mask, &mask_rect, combined, &paint_rect, 1.0);
      g_object_unref (mask);
      mask = combined;
      mask_rect = paint_rect;
    }
  gimp_applicator_set_mask_buffer (applicator, mask);
  gimp_applicator_set_mask_offset (applicator, paint_rect.x - mask_rect.x,
                                  paint_rect.y - mask_rect.y);
  gimp_applicator_set_apply_buffer (applicator, core->paint_buffer);
  gimp_applicator_set_apply_offset (applicator, paint_rect.x, paint_rect.y);
  gdouble strength = gimp_context_get_opacity (GIMP_CONTEXT (options));
  if (options->application_mode != GIMP_PAINT_CONSTANT) strength *= opacity;
  gimp_applicator_set_opacity (applicator, strength);
  gimp_applicator_set_mode (applicator, GIMP_LAYER_MODE_REPLACE,
                            GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR,
                            GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR,
                            GIMP_LAYER_COMPOSITE_UNION);
  gimp_applicator_blit (applicator, &paint_rect);
  gimp_applicator_set_mask_buffer (applicator, core->mask_buffer);
  gimp_applicator_set_mask_offset (applicator, -off_x, -off_y);
  g_object_unref (mask);
  core->x1 = MIN (core->x1, paint_rect.x);
  core->y1 = MIN (core->y1, paint_rect.y);
  core->x2 = MAX (core->x2, paint_rect.x + width);
  core->y2 = MAX (core->y2, paint_rect.y + height);
  gimp_drawable_update (drawable, paint_rect.x, paint_rect.y, width, height);
}

static void
glims_sponge_motion (GimpPaintCore *core, GimpDrawable *drawable,
                     GimpPaintOptions *options, GimpSymmetry *sym)
{
  GimpBrushCore *brush = GIMP_BRUSH_CORE (core);
  GimpDynamics *dynamics = brush->dynamics;
  GimpImage *image = gimp_item_get_image (GIMP_ITEM (drawable));
  gdouble fade = gimp_paint_options_get_fade (options, image, core->pixel_dist);
  gint off_x, off_y;
  gimp_item_get_offset (GIMP_ITEM (drawable), &off_x, &off_y);
  GimpCoords coords = *gimp_symmetry_get_origin (sym);
  coords.x -= off_x;
  coords.y -= off_y;
  gimp_symmetry_set_origin (sym, drawable, &coords);
  gdouble opacity = gimp_dynamics_get_linear_value (dynamics, GIMP_DYNAMICS_OUTPUT_OPACITY,
                                                    &coords, options, fade);
  if (opacity == 0) return;
  GeglBuffer *source = options->application_mode == GIMP_PAINT_CONSTANT
    ? gimp_paint_core_get_orig_image (core, drawable) : gimp_drawable_get_buffer (drawable);
  gimp_brush_core_eval_transform_dynamics (brush, image, options, &coords);
  for (gint i = 0; i < gimp_symmetry_get_size (sym); i++)
    {
      coords = *gimp_symmetry_get_coords (sym, i);
      gimp_brush_core_eval_transform_symmetry (brush, sym, i);
      gint x, y, width, height;
      GeglBuffer *paint = gimp_paint_core_get_paint_buffer (core, drawable, options,
                           GIMP_LAYER_MODE_NORMAL, &coords, &x, &y, &width, &height);
      if (!paint) continue;
      sponge_region (source, x, y, paint,
                      babl_format_get_space (gimp_drawable_get_format (drawable)),
                      ((GlimsSponge *) core)->saturate);
      gdouble force = gimp_dynamics_is_output_enabled (dynamics, GIMP_DYNAMICS_OUTPUT_FORCE)
        ? gimp_dynamics_get_linear_value (dynamics, GIMP_DYNAMICS_OUTPUT_FORCE, &coords, options, fade)
        : options->brush_force;
      sponge_replace (brush, drawable, options, &coords,
                       MIN (opacity, GIMP_OPACITY_OPAQUE), force);
    }
}

static void
glims_sponge_paint (GimpPaintCore *core, GList *drawables, GimpPaintOptions *options,
                    GimpSymmetry *sym, GimpPaintState state, guint32 time)
{
  (void) time;
  g_return_if_fail (g_list_length (drawables) == 1);
  if (state == GIMP_PAINT_STATE_MOTION)
    glims_sponge_motion (core, drawables->data, options, sym);
}

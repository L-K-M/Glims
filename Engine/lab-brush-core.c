/* Native brush geometry, physical Lab sample publication. No RGB paint
 * buffer, color applicator, or layer blend runs on the authoritative plane.
 * Geometry follows unmodified GIMP_3_2_8 gimpbrushcore.c paste_canvas and
 * gimppaintbrush.c motion. Coverage saturation is an explicit Glims rule:
 * transformed native masks can contain finite negative interpolation noise. */
#include "lab-brush-core.h"
#include "lab-brush-coverage.h"
#include "lab-fill.h"

#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimpsymmetry.h"
#include "core/gimptempbuf.h"
#include "paint/gimpbrushcore.h"
#include "paint/gimppaintoptions.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  GimpBrushCore parent;
  GlimsLabRole role;
  GlimsLabFormat format;
  double value, opacity;
  GeglBuffer *coverage;
  GeglBuffer *selection;
  const char *failure;
} GlimsLabBrushCore;
typedef struct { GimpBrushCoreClass parent; } GlimsLabBrushCoreClass;

static GType glims_lab_brush_core_get_type (void);
static void paint (GimpPaintCore *, GList *, GimpPaintOptions *,
                   GimpSymmetry *, GimpPaintState, guint32);
G_DEFINE_TYPE (GlimsLabBrushCore, glims_lab_brush_core, GIMP_TYPE_BRUSH_CORE)

static void
finalize (GObject *object)
{
  GlimsLabBrushCore *self = (GlimsLabBrushCore *) object;
  g_clear_object (&self->coverage);
  g_clear_object (&self->selection);
  /* Native finish releases this reference; native cancel/cleanup does not. */
  g_clear_object (&GIMP_PAINT_CORE (self)->mask_buffer);
  G_OBJECT_CLASS (glims_lab_brush_core_parent_class)->finalize (object);
}

static void
glims_lab_brush_core_class_init (GlimsLabBrushCoreClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = finalize;
  GIMP_PAINT_CORE_CLASS (klass)->paint = paint;
  GIMP_BRUSH_CORE_CLASS (klass)->handles_changing_brush = TRUE;
}

static void
glims_lab_brush_core_init (GlimsLabBrushCore *self)
{
  (void) self;
}

GimpPaintCore *
glims_lab_brush_core_new (GlimsLabRole role, GlimsLabFormat format,
                          double value, double opacity)
{
  bool changed = false;
  if (!glims_lab_fill_row (role, format, value, opacity, 0,
                           NULL, NULL, NULL, &changed)) return NULL;
  GlimsLabBrushCore *self = g_object_new (glims_lab_brush_core_get_type (),
                                         "undo-desc", "Paint Lab Channel", NULL);
  self->role = role;
  self->format = format;
  self->value = value;
  self->opacity = opacity;
  return GIMP_PAINT_CORE (self);
}

const char *
glims_lab_brush_core_error (GimpPaintCore *core)
{
  if (!core || !G_TYPE_CHECK_INSTANCE_TYPE (core, glims_lab_brush_core_get_type ()))
    return "This is not a physical Lab brush stroke.";
  return ((GlimsLabBrushCore *) core)->failure;
}

static gboolean
dab (GlimsLabBrushCore *self, GimpDrawable *drawable,
      const GimpCoords *coords, const GimpTempBuf *mask)
{
  GimpPaintCore *core = GIMP_PAINT_CORE (self);
  const gint mw = gimp_temp_buf_get_width (mask), mh = gimp_temp_buf_get_height (mask);
  const gint width = gimp_item_get_width (GIMP_ITEM (drawable));
  const gint height = gimp_item_get_height (GIMP_ITEM (drawable));
  const Babl *native = gimp_drawable_get_format (drawable);
  const gsize sample_size = glims_lab_sample_size (self->format);
  const Babl *mask_format = gimp_temp_buf_get_format (mask);
  const gsize mask_size = mask_format == babl_format ("Y float") ? sizeof (float) :
                          mask_format == babl_format ("Y u8") ? 1 : 0;
  if (mw <= 0 || mh <= 0 || width <= 0 || height <= 0 ||
      (gsize) mw > G_MAXSIZE / (gsize) mh / sizeof (float) ||
      !mask_size ||
      gimp_temp_buf_get_data_size (mask) != (gsize) mw * mh * mask_size ||
      !sample_size || babl_format_get_n_components (native) != 1 ||
      (gsize) babl_format_get_bytes_per_pixel (native) != sample_size ||
      !isfinite (coords->x) || !isfinite (coords->y) ||
      fabs (coords->x) > G_MAXINT / 2 || fabs (coords->y) > G_MAXINT / 2)
    return FALSE;

  const gint64 left = (gint64) floor (coords->x) - (mw >> 1);
  const gint64 top = (gint64) floor (coords->y) - (mh >> 1);
  const gint64 x1 = MAX ((gint64) 0, left), y1 = MAX ((gint64) 0, top);
  const gint64 x2 = MIN ((gint64) width, left + mw), y2 = MIN ((gint64) height, top + mh);
  if (x1 >= x2 || y1 >= y2) return TRUE;
  const GeglRectangle area = { (gint) x1, (gint) y1, (gint) (x2-x1), (gint) (y2-y1) };
  GeglBuffer *original = gimp_paint_core_get_orig_image (core, drawable);
  GeglBuffer *live = gimp_drawable_get_buffer (drawable);
  if (!original || !self->coverage) return FALSE;

  /* Tile copies stay private until the complete dab validates. A late bad
   * sample cannot publish an early row. Native Undo owns the stroke original. */
  /* Duplicating the whole canvas per dab traverses its entire tile grid.
   * Stage only this dab's rectangle, retaining unchanged bytes in its rows. */
  GeglBuffer *candidate = gegl_buffer_new (&area, native);
  GeglBuffer *coverage = gegl_buffer_new (&area, babl_format ("Y float"));
  gegl_buffer_copy (live, &area, GEGL_ABYSS_NONE, candidate, &area);
  gboolean valid = TRUE, changed_dab = FALSE;
  const guint8 *mask_bytes = gimp_temp_buf_get_data (mask);
  guint8 source[GLIMS_LAB_FILL_MAX_COUNT * sizeof (float)];
  guint8 output[GLIMS_LAB_FILL_MAX_COUNT * sizeof (float)];
  guint8 current[GLIMS_LAB_FILL_MAX_COUNT * sizeof (float)];
  float previous[GLIMS_LAB_FILL_MAX_COUNT], accumulated[GLIMS_LAB_FILL_MAX_COUNT];
  float selected[GLIMS_LAB_FILL_MAX_COUNT], weights[GLIMS_LAB_FILL_MAX_COUNT];
  float normalized_mask[GLIMS_LAB_FILL_MAX_COUNT];
  for (gint y = area.y; valid && y < area.y + area.height; y++)
    for (gint x = area.x; valid && x < area.x + area.width; )
      {
        const gint count = MIN ((gint) GLIMS_LAB_FILL_MAX_COUNT, area.x + area.width - x);
        const GeglRectangle row = { x, y, count, 1 };
        const guint8 *generated = mask_bytes +
          ((gsize) (y - top) * mw + (gsize) (x - left)) * mask_size;
        if (mask_size == 1)
          {
            for (gint i = 0; i < count; i++)
              normalized_mask[i] = (float) ((double) generated[i] / 255.0);
            generated = (const guint8 *) normalized_mask;
          }
        gegl_buffer_get (self->coverage, &row, 1, babl_format ("Y float"), previous,
                         GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        valid = glims_lab_brush_coverage ((size_t) count, previous, generated, accumulated);
        if (!valid) break;
        if (self->selection)
          gegl_buffer_get (self->selection, &row, 1, babl_format ("Y float"), selected,
                           GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        for (gint i = 0; i < count; i++)
          {
            const float selection = self->selection ? selected[i] : 1.0f;
            if (!isfinite (selection) || selection < 0 || selection > 1)
              { valid = FALSE; break; }
            /* One binary32 mask multiplication, then physical opacity is
             * applied once by the Lab kernel to the original sample. */
            weights[i] = (float) ((double) accumulated[i] * selection);
          }
        if (!valid) break;
        gegl_buffer_get (original, &row, 1, native, source, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        bool differs_from_original = false;
        valid = glims_lab_fill_row (self->role, self->format, self->value, self->opacity,
                                    (size_t) count, source, weights, output, &differs_from_original);
        if (!valid) break;
        gegl_buffer_get (live, &row, 1, native, current, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        if (memcmp (current, output, (gsize) count * sample_size))
          {
            gegl_buffer_set (candidate, &row, 0, native, output, GEGL_AUTO_ROWSTRIDE);
            changed_dab = TRUE;
          }
        gegl_buffer_set (coverage, &row, 0, babl_format ("Y float"), accumulated, GEGL_AUTO_ROWSTRIDE);
        x += count;
      }
  if (valid)
    {
      gegl_buffer_copy (coverage, &area, GEGL_ABYSS_NONE, self->coverage, &area);
      if (changed_dab)
        {
          gegl_buffer_copy (candidate, &area, GEGL_ABYSS_NONE, live, &area);
          if (core->x1 == core->x2 || core->y1 == core->y2)
            { core->x1 = area.x; core->y1 = area.y; core->x2 = area.x + area.width; core->y2 = area.y + area.height; }
          else
            { core->x1 = MIN (core->x1, area.x); core->y1 = MIN (core->y1, area.y);
              core->x2 = MAX (core->x2, area.x + area.width); core->y2 = MAX (core->y2, area.y + area.height); }
          gimp_drawable_update (drawable, area.x, area.y, area.width, area.height);
        }
    }
  g_object_unref (candidate);
  g_object_unref (coverage);
  return valid;
}

static void
paint (GimpPaintCore *core, GList *drawables, GimpPaintOptions *options,
        GimpSymmetry *sym, GimpPaintState state, guint32 time)
{
  (void) time;
  GlimsLabBrushCore *self = (GlimsLabBrushCore *) core;
  if (self->failure || state == GIMP_PAINT_STATE_FINISH) return;
  if (!drawables || drawables->next || !GIMP_IS_CHANNEL (drawables->data) ||
      options->use_applicator || core->applicators)
    { self->failure = "The Lab brush requires one scalar channel without a color applicator."; return; }
  GimpDrawable *drawable = drawables->data;
  gint offset_x, offset_y;
  gimp_item_get_offset (GIMP_ITEM (drawable), &offset_x, &offset_y);
  if (offset_x || offset_y)
    { self->failure = "The Lab channel no longer covers the native canvas."; return; }
  if (state == GIMP_PAINT_STATE_INIT)
    {
      if (self->coverage)
        { self->failure = "The Lab brush stroke was initialized twice."; return; }
      self->coverage = gegl_buffer_new (GEGL_RECTANGLE (0, 0,
          gimp_item_get_width (GIMP_ITEM (drawable)), gimp_item_get_height (GIMP_ITEM (drawable))),
          babl_format ("Y float"));
      if (core->mask_buffer) self->selection = gegl_buffer_dup (core->mask_buffer);
      return;
    }
  if (state != GIMP_PAINT_STATE_MOTION) return;
  GimpBrushCore *brush = GIMP_BRUSH_CORE (core);
  GimpImage *image = gimp_item_get_image (GIMP_ITEM (drawable));
  GimpCoords coords = *gimp_symmetry_get_origin (sym);
  gimp_symmetry_set_origin (sym, drawable, &coords);
  gimp_brush_core_eval_transform_dynamics (brush, image, options, &coords);
  for (gint i = 0; i < gimp_symmetry_get_size (sym); i++)
    {
      gimp_brush_core_eval_transform_symmetry (brush, sym, i);
      coords = *gimp_symmetry_get_coords (sym, i);
      const GimpTempBuf *mask = gimp_brush_core_get_brush_mask (
          brush, &coords, gimp_paint_options_get_brush_mode (options), options->brush_force);
      if (mask && !dab (self, drawable, &coords, mask))
        { self->failure = "The Lab brush encountered an invalid sample or coverage value. The stroke must be cancelled."; break; }
    }
}

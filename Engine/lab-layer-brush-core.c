/* Brush geometry comes from GIMP's native brush core. Four physical Lab/alpha
 * planes are staged together; native paint-core snapshots supply the stroke
 * originals and grouped Undo. This private core performs no target admission. */
#include "lab-layer-brush-core.h"
#include "lab-layer-paint.h"
#include "lab-brush-coverage.h"

#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpsymmetry.h"
#include "core/gimptempbuf.h"
#include "paint/gimpbrushcore.h"
#include "paint/gimppaintoptions.h"

#include <math.h>
#include <string.h>

typedef struct {
  GimpBrushCore parent;
  double lightness, a, b, opacity;
  GimpDrawable *planes[4];
  GeglBuffer *coverage, *selection;
  const char *failure;
} GlimsLabLayerBrushCore;
typedef struct { GimpBrushCoreClass parent; } GlimsLabLayerBrushCoreClass;

static GType glims_lab_layer_brush_core_get_type (void);
static void paint (GimpPaintCore *, GList *, GimpPaintOptions *,
                   GimpSymmetry *, GimpPaintState, guint32);
G_DEFINE_TYPE (GlimsLabLayerBrushCore, glims_lab_layer_brush_core, GIMP_TYPE_BRUSH_CORE)

static void
finalize (GObject *object)
{
  GlimsLabLayerBrushCore *self = (GlimsLabLayerBrushCore *) object;
  for (unsigned i = 0; i < 4; i++) g_clear_object (&self->planes[i]);
  g_clear_object (&self->coverage);
  g_clear_object (&self->selection);
  /* Native finish clears this; native cancel does not. */
  g_clear_object (&GIMP_PAINT_CORE (self)->mask_buffer);
  G_OBJECT_CLASS (glims_lab_layer_brush_core_parent_class)->finalize (object);
}

static void
glims_lab_layer_brush_core_class_init (GlimsLabLayerBrushCoreClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = finalize;
  GIMP_PAINT_CORE_CLASS (klass)->paint = paint;
  GIMP_BRUSH_CORE_CLASS (klass)->handles_changing_brush = TRUE;
}

static void glims_lab_layer_brush_core_init (GlimsLabLayerBrushCore *self) { (void) self; }

GimpPaintCore *
glims_lab_layer_brush_core_new (double lightness, double a, double b, double opacity)
{
  const uint8_t *source[4] = { NULL, NULL, NULL, NULL };
  uint8_t *destination[4] = { NULL, NULL, NULL, NULL };
  bool changed = false;
  if (!glims_lab_layer_paint_row (0, source, NULL, lightness, a, b, opacity,
                                  destination, &changed)) return NULL;
  GlimsLabLayerBrushCore *self = g_object_new (glims_lab_layer_brush_core_get_type (),
                                              "undo-desc", "Paint Lab Layer", NULL);
  self->lightness = lightness; self->a = a; self->b = b; self->opacity = opacity;
  return GIMP_PAINT_CORE (self);
}

const char *
glims_lab_layer_brush_core_error (GimpPaintCore *core)
{
  if (!core || !G_TYPE_CHECK_INSTANCE_TYPE (core, glims_lab_layer_brush_core_get_type ()))
    return "This is not a layered Lab brush stroke.";
  return ((GlimsLabLayerBrushCore *) core)->failure;
}

/* All planes must stay attached to the same full-size canvas. Their ordering
 * and logical identity are checked by the caller before every input packet. */
static gboolean
valid_planes (GList *drawables, GlimsLabLayerBrushCore *self, gboolean initial)
{
  if (g_list_length (drawables) != 4) return FALSE;
  GimpImage *image = NULL;
  gint width = 0, height = 0;
  unsigned i = 0;
  for (GList *it = drawables; it; it = it->next, i++)
    {
      if (!it->data || G_OBJECT_TYPE (it->data) != GIMP_TYPE_LAYER) return FALSE;
      GimpDrawable *plane = GIMP_DRAWABLE (it->data);
      GimpItem *item = GIMP_ITEM (plane);
      gint x, y;
      gimp_item_get_offset (item, &x, &y);
      const Babl *format = gimp_drawable_get_format (plane);
      if (!gimp_item_is_attached (item) || x || y ||
          babl_format_get_n_components (format) != 1 ||
          babl_format_get_bytes_per_pixel (format) != 1 ||
          (!initial && self->planes[i] != plane)) return FALSE;
      for (unsigned j = 0; j < i; j++)
        if (self->planes[j] == plane) return FALSE;
      if (!image)
        {
          image = gimp_item_get_image (item);
          width = gimp_item_get_width (item); height = gimp_item_get_height (item);
          if (!image || width <= 0 || height <= 0) return FALSE;
        }
      if (gimp_item_get_image (item) != image ||
          gimp_item_get_width (item) != width || gimp_item_get_height (item) != height)
        return FALSE;
      if (initial) self->planes[i] = g_object_ref (plane);
    }
  return TRUE;
}

static gboolean
dab (GlimsLabLayerBrushCore *self, const GimpCoords *coords, const GimpTempBuf *mask)
{
  GimpPaintCore *core = GIMP_PAINT_CORE (self);
  const gint mw = gimp_temp_buf_get_width (mask), mh = gimp_temp_buf_get_height (mask);
  const gint width = gimp_item_get_width (GIMP_ITEM (self->planes[0]));
  const gint height = gimp_item_get_height (GIMP_ITEM (self->planes[0]));
  const Babl *mask_format = gimp_temp_buf_get_format (mask);
  const gsize mask_size = mask_format == babl_format ("Y float") ? sizeof (float) :
                          mask_format == babl_format ("Y u8") ? 1 : 0;
  if (mw <= 0 || mh <= 0 || width <= 0 || height <= 0 || !mask_size ||
      (gsize) mw > G_MAXSIZE / (gsize) mh / mask_size ||
      gimp_temp_buf_get_data_size (mask) != (gsize) mw * mh * mask_size ||
      !isfinite (coords->x) || !isfinite (coords->y) ||
      fabs (coords->x) > G_MAXINT / 2 || fabs (coords->y) > G_MAXINT / 2 || !self->coverage)
    return FALSE;
  const gint64 left = (gint64) floor (coords->x) - (mw >> 1);
  const gint64 top = (gint64) floor (coords->y) - (mh >> 1);
  const gint64 x1 = MAX ((gint64) 0, left), y1 = MAX ((gint64) 0, top);
  const gint64 x2 = MIN ((gint64) width, left + mw), y2 = MIN ((gint64) height, top + mh);
  if (x1 >= x2 || y1 >= y2) return TRUE;
  const GeglRectangle area = { (gint) x1, (gint) y1, (gint) (x2-x1), (gint) (y2-y1) };
  GeglBuffer *candidate[4] = { NULL }, *original[4], *live[4];
  const Babl *native[4];
  for (unsigned i = 0; i < 4; i++)
    {
      original[i] = gimp_paint_core_get_orig_image (core, self->planes[i]);
      if (!original[i])
        { for (unsigned j = 0; j < i; j++) g_object_unref (candidate[j]); return FALSE; }
      live[i] = gimp_drawable_get_buffer (self->planes[i]);
      native[i] = gimp_drawable_get_format (self->planes[i]);
      candidate[i] = gegl_buffer_new (&area, native[i]);
      gegl_buffer_copy (live[i], &area, GEGL_ABYSS_NONE, candidate[i], &area);
    }
  GeglBuffer *coverage = gegl_buffer_new (&area, babl_format ("Y float"));
  gboolean valid = TRUE, changed_dab = FALSE;
  const guint8 *mask_bytes = gimp_temp_buf_get_data (mask);
  guint8 source[4][GLIMS_LAB_LAYER_PAINT_MAX_WIDTH], output[4][GLIMS_LAB_LAYER_PAINT_MAX_WIDTH];
  guint8 current[GLIMS_LAB_LAYER_PAINT_MAX_WIDTH];
  const uint8_t *sources[4] = { source[0], source[1], source[2], source[3] };
  uint8_t *outputs[4] = { output[0], output[1], output[2], output[3] };
  float previous[GLIMS_LAB_LAYER_PAINT_MAX_WIDTH], accumulated[GLIMS_LAB_LAYER_PAINT_MAX_WIDTH];
  float selected[GLIMS_LAB_LAYER_PAINT_MAX_WIDTH], weights[GLIMS_LAB_LAYER_PAINT_MAX_WIDTH];
  float normalized[GLIMS_LAB_LAYER_PAINT_MAX_WIDTH];
  for (gint y = area.y; valid && y < area.y + area.height; y++)
    for (gint x = area.x; valid && x < area.x + area.width; )
      {
        const gint count = MIN ((gint) GLIMS_LAB_LAYER_PAINT_MAX_WIDTH, area.x + area.width - x);
        const GeglRectangle row = { x, y, count, 1 };
        const guint8 *generated = mask_bytes + ((gsize) (y - top) * mw + (gsize) (x - left)) * mask_size;
        if (mask_size == 1)
          {
            for (gint i = 0; i < count; i++) normalized[i] = (float) ((double) generated[i] / 255.0);
            generated = (const guint8 *) normalized;
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
            weights[i] = (float) ((double) accumulated[i] * selection);
          }
        if (!valid) break;
        for (unsigned i = 0; i < 4; i++)
          gegl_buffer_get (original[i], &row, 1, native[i], source[i], GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        bool differs = false;
        valid = glims_lab_layer_paint_row ((size_t) count, sources, weights,
                                           self->lightness, self->a, self->b, self->opacity,
                                           outputs, &differs);
        if (!valid) break;
        for (unsigned i = 0; i < 4; i++)
          {
            gegl_buffer_get (live[i], &row, 1, native[i], current, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
            if (memcmp (current, output[i], (gsize) count))
              { gegl_buffer_set (candidate[i], &row, 0, native[i], output[i], GEGL_AUTO_ROWSTRIDE); changed_dab = TRUE; }
          }
        gegl_buffer_set (coverage, &row, 0, babl_format ("Y float"), accumulated, GEGL_AUTO_ROWSTRIDE);
        x += count;
      }
  if (valid)
    {
      gegl_buffer_copy (coverage, &area, GEGL_ABYSS_NONE, self->coverage, &area);
      if (changed_dab)
        {
          for (unsigned i = 0; i < 4; i++)
            gegl_buffer_copy (candidate[i], &area, GEGL_ABYSS_NONE, live[i], &area);
          if (core->x1 == core->x2 || core->y1 == core->y2)
            { core->x1 = area.x; core->y1 = area.y; core->x2 = area.x + area.width; core->y2 = area.y + area.height; }
          else
            { core->x1 = MIN (core->x1, area.x); core->y1 = MIN (core->y1, area.y);
              core->x2 = MAX (core->x2, area.x + area.width); core->y2 = MAX (core->y2, area.y + area.height); }
          for (unsigned i = 0; i < 4; i++) gimp_drawable_update (self->planes[i], area.x, area.y, area.width, area.height);
        }
    }
  for (unsigned i = 0; i < 4; i++) g_object_unref (candidate[i]);
  g_object_unref (coverage);
  return valid;
}

static void
paint (GimpPaintCore *core, GList *drawables, GimpPaintOptions *options,
       GimpSymmetry *sym, GimpPaintState state, guint32 time)
{
  (void) time;
  GlimsLabLayerBrushCore *self = (GlimsLabLayerBrushCore *) core;
  if (self->failure || state == GIMP_PAINT_STATE_FINISH) return;
  if (state == GIMP_PAINT_STATE_INIT && self->coverage)
    { self->failure = "The layered Lab brush stroke was initialized twice."; return; }
  if (options->use_applicator || core->applicators ||
      !valid_planes (drawables, self, state == GIMP_PAINT_STATE_INIT))
    { self->failure = "The layered Lab brush requires four matching scalar planes."; return; }
  if (state == GIMP_PAINT_STATE_INIT)
    {
      self->coverage = gegl_buffer_new (GEGL_RECTANGLE (0, 0,
          gimp_item_get_width (GIMP_ITEM (self->planes[0])), gimp_item_get_height (GIMP_ITEM (self->planes[0]))),
          babl_format ("Y float"));
      if (core->mask_buffer) self->selection = gegl_buffer_dup (core->mask_buffer);
      return;
    }
  if (state != GIMP_PAINT_STATE_MOTION) return;
  GimpBrushCore *brush = GIMP_BRUSH_CORE (core);
  GimpImage *image = gimp_item_get_image (GIMP_ITEM (self->planes[0]));
  GimpCoords coords = *gimp_symmetry_get_origin (sym);
  gimp_symmetry_set_origin (sym, self->planes[0], &coords);
  gimp_brush_core_eval_transform_dynamics (brush, image, options, &coords);
  for (gint i = 0; i < gimp_symmetry_get_size (sym); i++)
    {
      gimp_brush_core_eval_transform_symmetry (brush, sym, i);
      coords = *gimp_symmetry_get_coords (sym, i);
      const GimpTempBuf *mask = gimp_brush_core_get_brush_mask (
          brush, &coords, gimp_paint_options_get_brush_mode (options), options->brush_force);
      if (mask && !dab (self, &coords, mask))
        { self->failure = "The layered Lab brush encountered invalid coverage. The stroke must be cancelled."; break; }
    }
}

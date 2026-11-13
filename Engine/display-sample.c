#include "display-sample.h"
#include <cairo.h>
#include "gegl-buffer-backend.h"
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "gegl/gimptilehandlervalidate.h"

#define SAMPLE_WIDTH 256u
#define SAMPLE_COLUMNS (2u * SAMPLE_WIDTH + 2u)
#define NATIVE_LEVEL_LIMIT 4u
#define NATIVE_FACTOR_LIMIT 16
#define MIN_SCALE (1.0 / 1048576.0)
#define MAX_COORD 67108864.0

typedef struct {
  GimpTileHandlerValidate parent_instance;
  GeglBuffer *source;
  const Babl *read_format, *associated;
  GeglRectangle extent;
  guint components;
  gboolean already_associated;
  gint failed;
} GlimsDisplayValidate;
typedef struct { GimpTileHandlerValidateClass parent_class; } GlimsDisplayValidateClass;
G_DEFINE_TYPE (GlimsDisplayValidate, glims_display_validate, GIMP_TYPE_TILE_HANDLER_VALIDATE)

struct GlimsDisplaySample {
  GimpTileHandlerValidate *validate;
  GeglBuffer *buffer;
  const Babl *linear, *associated;
  GeglRectangle extent;
  guint components;
  const Babl *native;
  GimpTileHandlerValidate *source_validate;
  gulong changed, invalidated;
  gint tile_width, tile_height;
  GMutex dirty_lock;
  gboolean dirty;
  GeglRectangle dirty_rect;
};

static gboolean
clip_rect (const GeglRectangle *rect, const GeglRectangle *extent, GeglRectangle *out)
{
  if (!rect || rect->width <= 0 || rect->height <= 0) return FALSE;
  gint64 left = MAX ((gint64) rect->x, (gint64) extent->x);
  gint64 top = MAX ((gint64) rect->y, (gint64) extent->y);
  gint64 right = MIN ((gint64) rect->x + rect->width, (gint64) extent->x + extent->width);
  gint64 bottom = MIN ((gint64) rect->y + rect->height, (gint64) extent->y + extent->height);
  if (right <= left || bottom <= top) return FALSE;
  *out = (GeglRectangle) { (gint) left, (gint) top, (gint) (right-left), (gint) (bottom-top) };
  return TRUE;
}

/* Signal callbacks only record damage. Native validation may emit changed. */
static void
source_damage (gpointer source, const GeglRectangle *rect, GlimsDisplaySample *sample)
{
  (void) source;
  GeglRectangle damage;
  if (!clip_rect (rect ? rect : &sample->extent, &sample->extent, &damage)) return;
  g_mutex_lock (&sample->dirty_lock);
  if (sample->dirty)
    {
      gint64 left = MIN ((gint64) damage.x, (gint64) sample->dirty_rect.x);
      gint64 top = MIN ((gint64) damage.y, (gint64) sample->dirty_rect.y);
      gint64 right = MAX ((gint64) damage.x+damage.width,
                         (gint64) sample->dirty_rect.x+sample->dirty_rect.width);
      gint64 bottom = MAX ((gint64) damage.y+damage.height,
                          (gint64) sample->dirty_rect.y+sample->dirty_rect.height);
      sample->dirty_rect = (GeglRectangle) { (gint) left, (gint) top,
                                           (gint) (right-left), (gint) (bottom-top) };
    }
  else sample->dirty_rect = damage;
  sample->dirty = TRUE;
  g_mutex_unlock (&sample->dirty_lock);
}

static void
drain_damage (GlimsDisplaySample *sample)
{
  g_mutex_lock (&sample->dirty_lock);
  gboolean dirty = sample->dirty;
  GeglRectangle damage = sample->dirty_rect;
  sample->dirty = FALSE;
  g_mutex_unlock (&sample->dirty_lock);
  if (dirty) gimp_tile_handler_validate_invalidate (sample->validate, &damage);
}

static void
validate_region (GeglBuffer *buffer, const GeglRectangle *rect)
{
  GimpTileHandlerValidate *validate = gimp_tile_handler_validate_get_assigned (buffer);
  if (validate) gimp_tile_handler_validate_validate (validate, buffer, rect, TRUE, FALSE);
}

static gboolean
associated_row (GlimsDisplayValidate *self, gint64 x, gint64 y, guint width, gfloat *out)
{
  memset (out, 0, (gsize) width * self->components * sizeof *out);
  const gint64 bottom = (gint64) self->extent.y + self->extent.height;
  if (y < self->extent.y || y >= bottom) return TRUE;
  gint64 left = MAX (x, (gint64) self->extent.x);
  gint64 right = MIN (x + width, (gint64) self->extent.x + self->extent.width);
  if (right <= left) return TRUE;
  guint count = (guint) (right-left), offset = (guint) (left-x);
  GeglRectangle rect = { (gint) left, (gint) y, (gint) count, 1 };
  /* Prepared native mip-tile footprints include this complete level-0 tile;
   * explicit validation also avoids the source's hot1x1 bypass. */
  validate_region (self->source, &rect);
  gfloat *pixels = out + offset * self->components;
  gegl_buffer_get (self->source, &rect, 1.0, self->read_format, pixels,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  for (guint i = 0; i < count; i++)
    {
      gfloat *pixel = pixels + i*self->components;
      for (guint c = 0; c < self->components; c++)
        if (!isfinite (pixel[c])) goto failed;
      const double alpha = pixel[self->components-1];
      if (alpha == 0.0)
        for (guint c = 0; c < self->components; c++) pixel[c] = 0.0f;
      else if (!self->already_associated)
        for (guint c = 0; c < self->components-1; c++)
          {
            const double value = (double) pixel[c] * alpha;
            if (!isfinite (value) || fabs (value) > FLT_MAX) goto failed;
            pixel[c] = (gfloat) value;
          }
    }
  return TRUE;
failed:
  memset (out, 0, (gsize) width * self->components * sizeof *out);
  g_atomic_int_set (&self->failed, TRUE);
  return FALSE;
}

static gboolean
multiply_size (gsize a, gsize b, gsize *out)
{
  if (a && b > G_MAXSIZE/a) return FALSE;
  *out = a*b;
  return TRUE;
}

static gboolean
valid_layout (const GeglRectangle *rect, gpointer data, gint stride, guint components)
{
  if (!rect || rect->width < 0 || rect->height < 0) return FALSE;
  if (!rect->width || !rect->height) return TRUE;
  gsize row, last;
  if (!data || stride < 0 ||
      !multiply_size ((gsize) rect->width, components*sizeof (gfloat), &row) ||
      (gsize) stride < row || !multiply_size ((gsize) rect->height-1, (gsize) stride, &last) ||
      last > G_MAXSIZE-row) return FALSE;
  return (uintptr_t) data <= UINTPTR_MAX-(last+row);
}

static void
validate_pixels (GimpTileHandlerValidate *validate, const GeglRectangle *rect,
                 const Babl *format, gpointer data, gint stride)
{
  GlimsDisplayValidate *self = (GlimsDisplayValidate *) validate;
  if (format != self->associated || !valid_layout (rect, data, stride, self->components))
    { g_atomic_int_set (&self->failed, TRUE); return; }
  if (!rect->width || !rect->height) return;
  gfloat row[SAMPLE_WIDTH * 4];
  for (gint y = 0; y < rect->height; y++)
    for (gint x = 0; x < rect->width; )
      {
        guint width = MIN (SAMPLE_WIDTH, (guint) (rect->width-x));
        associated_row (self, (gint64) rect->x+x, (gint64) rect->y+y, width, row);
        memcpy ((guint8 *) data + (gsize) y*stride + (gsize) x*self->components*sizeof (gfloat),
                row, (gsize) width*self->components*sizeof (gfloat));
        x += width;
      }
}

static void
validate_buffer (GimpTileHandlerValidate *validate, const GeglRectangle *rect, GeglBuffer *buffer)
{
  GlimsDisplayValidate *self = (GlimsDisplayValidate *) validate;
  if (!rect || rect->width < 0 || rect->height < 0 || !buffer ||
      gegl_buffer_get_format (buffer) != self->associated)
    { g_atomic_int_set (&self->failed, TRUE); return; }
  GeglRectangle clipped;
  if (!clip_rect (rect, &self->extent, &clipped)) return;
  gfloat row[SAMPLE_WIDTH * 4];
  for (gint y = 0; y < clipped.height; y++)
    for (gint x = 0; x < clipped.width; )
      {
        guint width = MIN (SAMPLE_WIDTH, (guint) (clipped.width-x));
        GeglRectangle chunk = { clipped.x+x, clipped.y+y, (gint) width, 1 };
        associated_row (self, chunk.x, chunk.y, width, row);
        /* Same native associated format: never invoke Babl alpha-floor math. */
        gegl_buffer_set (buffer, &chunk, 0, self->associated, row, GEGL_AUTO_ROWSTRIDE);
        x += width;
      }
}

static void
finalize (GObject *object)
{
  GlimsDisplayValidate *self = (GlimsDisplayValidate *) object;
  g_clear_object (&self->source);
  G_OBJECT_CLASS (glims_display_validate_parent_class)->finalize (object);
}

static void
glims_display_validate_class_init (GlimsDisplayValidateClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = finalize;
  GimpTileHandlerValidateClass *parent = GIMP_TILE_HANDLER_VALIDATE_CLASS (klass);
  parent->validate = validate_pixels;
  parent->validate_buffer = validate_buffer;
}

static void
glims_display_validate_init (GlimsDisplayValidate *self) { (void) self; }

void
glims_display_sample_free (GlimsDisplaySample *sample)
{
  if (!sample) return;
  /* Caller has quiesced every source/read job; disconnect/unassign is no join. */
  GlimsDisplayValidate *self = (GlimsDisplayValidate *) sample->validate;
  if (sample->changed && self && self->source)
    g_signal_handler_disconnect (self->source, sample->changed);
  if (sample->invalidated && sample->source_validate)
    g_signal_handler_disconnect (sample->source_validate, sample->invalidated);
  if (sample->buffer && sample->validate &&
      gimp_tile_handler_validate_get_assigned (sample->buffer) == sample->validate)
    gimp_tile_handler_validate_unassign (sample->validate, sample->buffer);
  g_clear_object (&sample->buffer);
  g_clear_object (&sample->validate);
  g_clear_object (&sample->source_validate);
  g_mutex_clear (&sample->dirty_lock);
  g_free (sample);
}

GlimsDisplaySample *
glims_display_sample_new (GeglBuffer *source, const Babl *linear)
{
  if (!source || !GEGL_IS_BUFFER (source) || !linear) return NULL;
  const Babl *native = gegl_buffer_get_format (source);
  const Babl *space = babl_format_get_space (native);
  guint components;
  if (linear == babl_format_with_space ("RGBA float", space)) components = 4;
  else if (linear == babl_format_with_space ("YA float", space)) components = 2;
  else return NULL;
  BablModelFlag flags = babl_get_model_flags (babl_format_get_model (native));
  if (!babl_format_has_alpha (native) || babl_format_get_n_components (native) != (gint) components ||
      !(flags & (components == 4 ? BABL_MODEL_FLAG_RGB : BABL_MODEL_FLAG_GRAY))) return NULL;
  const Babl *associated = babl_format_with_space (components == 4 ? "RaGaBaA float" : "YaA float", space);
  gboolean already = (flags & BABL_MODEL_FLAG_ASSOCIATED) != 0;
  if (already && native != associated) return NULL;
  const GeglRectangle *extent = gegl_buffer_get_extent (source);
  if (!extent || extent->width < 0 || extent->height < 0 ||
      (gint64) extent->x + extent->width > G_MAXINT32 ||
      (gint64) extent->y + extent->height > G_MAXINT32) return NULL;
  GlimsDisplaySample *sample = g_try_new0 (GlimsDisplaySample, 1);
  if (!sample) return NULL;
  g_mutex_init (&sample->dirty_lock);
  sample->native = native;
  sample->linear = linear;
  sample->associated = associated;
  sample->components = components;
  sample->extent = *extent;
  sample->validate = g_object_new (glims_display_validate_get_type (), "whole-tile", TRUE, NULL);
  if (!sample->validate) { glims_display_sample_free (sample); return NULL; }
  GlimsDisplayValidate *self = (GlimsDisplayValidate *) sample->validate;
  self->source = g_object_ref (source);
  self->read_format = already ? associated : linear;
  self->associated = associated;
  self->extent = *extent;
  self->components = components;
  self->already_associated = already;
  sample->buffer = gegl_buffer_new (extent, associated);
  if (!sample->buffer) { glims_display_sample_free (sample); return NULL; }
  gint shift_x, shift_y;
  g_object_get (sample->buffer, "tile-width", &sample->tile_width,
                "tile-height", &sample->tile_height,
                "shift-x", &shift_x, "shift-y", &shift_y, NULL);
  if (sample->tile_width < 1 || sample->tile_height < 1 || shift_x || shift_y ||
      sample->tile_width > G_MAXINT / (gint) (components * sizeof (gfloat)) ||
      (gsize) sample->tile_width > G_MAXSIZE / (components * sizeof (gfloat)) / sample->tile_height)
    { glims_display_sample_free (sample); return NULL; }
  gimp_tile_handler_validate_assign (sample->validate, sample->buffer);
  GimpTileHandlerValidate *source_validate = gimp_tile_handler_validate_get_assigned (source);
  if (source_validate) sample->source_validate = g_object_ref (source_validate);
  sample->changed = gegl_buffer_signal_connect (source, "changed", G_CALLBACK (source_damage), sample);
  if (source_validate)
    sample->invalidated = g_signal_connect (source_validate, "invalidated", G_CALLBACK (source_damage), sample);
  source_damage (source, extent, sample);
  drain_damage (sample);
  return sample;
}

static gboolean
matches_source (GlimsDisplaySample *sample, GeglBuffer *source, const Babl *linear)
{
  if (!sample || !source || !GEGL_IS_BUFFER (source) || !linear) return FALSE;
  GlimsDisplayValidate *self = (GlimsDisplayValidate *) sample->validate;
  const GeglRectangle *extent = gegl_buffer_get_extent (source);
  return self->source == source && sample->linear == linear &&
    sample->native == gegl_buffer_get_format (source) && extent &&
    sample->extent.x == extent->x && sample->extent.y == extent->y &&
    sample->extent.width == extent->width && sample->extent.height == extent->height &&
    sample->source_validate == gimp_tile_handler_validate_get_assigned (source);
}

GlimsStatus
glims_display_sample_prepare (GeglBuffer *source, const Babl *linear, GlimsDisplaySample **cache)
{
  if (!cache) return GLIMS_STATUS_INVALID_ARGUMENT;
  if (matches_source (*cache, source, linear) &&
      !g_atomic_int_get (&((GlimsDisplayValidate *) (*cache)->validate)->failed))
    return GLIMS_STATUS_OK;
  GlimsDisplaySample *replacement = glims_display_sample_new (source, linear);
  glims_display_sample_free (*cache);
  *cache = replacement;
  return replacement ? GLIMS_STATUS_OK :
    (!source || !linear ? GLIMS_STATUS_INVALID_ARGUMENT : GLIMS_STATUS_FAILED);
}

static gboolean
separate_range (uintptr_t output, size_t span, const void *owner, size_t size)
{
  uintptr_t address = (uintptr_t) owner;
  return address <= UINTPTR_MAX-size &&
    !(output < address+size && address < output+span);
}

static gboolean
valid_request (GlimsDisplaySample *sample, double scale, GlimsRect area, void *out, size_t stride)
{
  if (!sample || !out || !(scale >= MIN_SCALE) ||
      !(scale < 1.0 || (scale > 1.0 && scale < 2.0)) || area.width < 1 || area.height < 1 ||
      (gint64) area.x + area.width > G_MAXINT32 || (gint64) area.y + area.height > G_MAXINT32)
    return FALSE;
  const double actual = scale;
  if (fabs (area.x/actual) > MAX_COORD || fabs (area.y/actual) > MAX_COORD ||
      fabs (((double) area.x+area.width)/actual) > MAX_COORD ||
      fabs (((double) area.y+area.height)/actual) > MAX_COORD) return FALSE;
  uint64_t row = (uint64_t) area.width*sample->components*sizeof (gfloat);
  if (row > GLIMS_MAX_PIXEL_BUFFER_BYTES || stride < row || stride > GLIMS_MAX_PIXEL_BUFFER_BYTES ||
      (uint64_t) (area.height-1) > (GLIMS_MAX_PIXEL_BUFFER_BYTES-row)/stride) return FALSE;
  size_t span = (size_t) ((uint64_t) (area.height-1)*stride+row);
  uintptr_t output = (uintptr_t) out;
  return output <= UINTPTR_MAX-span && separate_range (output, span, sample, sizeof *sample) &&
    separate_range (output, span, sample->validate, sizeof (GlimsDisplayValidate));
}

/* Euclidean division keeps native mip/tile grids global for negative origins. */
static gint64
floor_div (gint64 value, gint64 divisor)
{
  gint64 quotient = value/divisor;
  return quotient - (value%divisor < 0);
}

static guint
sampling_level (double scale, gint64 *factor)
{
  guint level = 0;
  *factor = 1;
  while (scale <= 0.5)
    { scale *= 2; *factor *= 2; level++; }
  return level;
}

static gboolean
prepare_sampling (GlimsDisplaySample *sample, double scale, GlimsRect area, gint64 factor)
{
  GlimsDisplayValidate *self = (GlimsDisplayValidate *) sample->validate;
  /* Native mip traversal is capped at level4. Coarser cells are sparse means
   * of level4 cells; prepare their complete source blocks and native tile halo
   * before draining source changed/invalidated notifications. */
  const double divisor = scale * factor;
  gint64 left = (gint64) floor (((double) area.x+0.5)/divisor-0.5);
  gint64 top = (gint64) floor (((double) area.y+0.5)/divisor-0.5);
  gint64 right = (gint64) floor (((double) area.x+area.width-0.5)/divisor-0.5)+2;
  gint64 bottom = (gint64) floor (((double) area.y+area.height-0.5)/divisor-0.5)+2;
  left = MAX (left, floor_div (sample->extent.x, factor));
  top = MAX (top, floor_div (sample->extent.y, factor));
  right = MIN (right, -floor_div (-((gint64) sample->extent.x+sample->extent.width), factor));
  bottom = MIN (bottom, -floor_div (-((gint64) sample->extent.y+sample->extent.height), factor));
  GeglRectangle full = { 0, 0, 0, 0 };
  if (sample->extent.width && sample->extent.height && right > left && bottom > top)
    {
      gint64 native_factor = MIN (factor, NATIVE_FACTOR_LIMIT);
      gint64 grid_width = sample->tile_width*native_factor;
      gint64 grid_height = sample->tile_height*native_factor;
      left = MAX (floor_div (left*factor, grid_width)*grid_width,
                  (gint64) sample->extent.x);
      top = MAX (floor_div (top*factor, grid_height)*grid_height,
                 (gint64) sample->extent.y);
      right = MIN (-floor_div (-right*factor, grid_width)*grid_width,
                   (gint64) sample->extent.x+sample->extent.width);
      bottom = MIN (-floor_div (-bottom*factor, grid_height)*grid_height,
                    (gint64) sample->extent.y+sample->extent.height);
      full = (GeglRectangle) { (gint) left, (gint) top, (gint) (right-left), (gint) (bottom-top) };
      validate_region (self->source, &full);
    }
  drain_damage (sample);
  if (full.width && full.height) validate_region (sample->buffer, &full);
  return !g_atomic_int_get (&self->failed);
}

static gboolean
native_mip_row (GlimsDisplaySample *sample, guint level, gint64 factor,
                gint64 x, gint64 y, guint width, gfloat *out)
{
  if (level > NATIVE_LEVEL_LIMIT) return FALSE;
  memset (out, 0, (gsize) width*sample->components*sizeof *out);
  if (!sample->extent.width || !sample->extent.height ||
      y*factor >= (gint64) sample->extent.y+sample->extent.height ||
      (y+1)*factor <= sample->extent.y) return TRUE;
  /* A cell wholly outside the extent is transparent. Partial cells retain the
   * native average of real level-0 samples and explicit zero abyss. */
  gint64 left = MAX (x, floor_div (sample->extent.x, factor));
  gint64 right = MIN (x+width,
                     -floor_div (-((gint64) sample->extent.x+sample->extent.width), factor));
  while (left < right)
    {
      gint64 tx = floor_div (left, sample->tile_width);
      gint64 ty = floor_div (y, sample->tile_height);
      guint offset_x = (guint) (left-tx*sample->tile_width);
      guint offset_y = (guint) (y-ty*sample->tile_height);
      guint count = (guint) MIN (right-left, sample->tile_width-offset_x);
      if (tx < G_MININT || tx > G_MAXINT || ty < G_MININT || ty > G_MAXINT) return FALSE;
      GeglTile *tile = gegl_buffer_get_tile (sample->buffer, (gint) tx, (gint) ty, (gint) level);
      if (!tile) return FALSE;
      gegl_tile_read_lock (tile);
      const guint8 *pixels = gegl_tile_get_data (tile);
      gboolean have_pixels = pixels != NULL;
      if (pixels)
        {
          gsize index = ((gsize) offset_y*sample->tile_width+offset_x)*sample->components;
          memcpy (out+(left-x)*sample->components, pixels+index*sizeof (gfloat),
                  (gsize) count*sample->components*sizeof (gfloat));
        }
      gegl_tile_read_unlock (tile);
      gegl_tile_unref (tile);
      if (!have_pixels) return FALSE;
      left += count;
    }
  return TRUE;
}

/* GEGL's native zoom recursively traverses absent tiles. Above level4,
 * sparse double means avoid a 4^level empty quadtree while retaining true
 * associated block averages. Different rounding from native deeper mips is
 * intentional; outside pixels remain in the full block-area denominator. */
static gboolean
mip_row (GlimsDisplaySample *sample, guint level, gint64 factor,
         gint64 x, gint64 y, guint width, gfloat *out)
{
  if (level <= NATIVE_LEVEL_LIMIT)
    return native_mip_row (sample, level, factor, x, y, width, out);
  memset (out, 0, (gsize) width*sample->components*sizeof *out);
  if (!sample->extent.width || !sample->extent.height) return TRUE;
  const gint64 block = factor/NATIVE_FACTOR_LIMIT;
  const double area = (double) block*block;
  const gint64 extent_left = floor_div (sample->extent.x, NATIVE_FACTOR_LIMIT);
  const gint64 extent_top = floor_div (sample->extent.y, NATIVE_FACTOR_LIMIT);
  const gint64 extent_right = -floor_div (-((gint64) sample->extent.x+sample->extent.width),
                                          NATIVE_FACTOR_LIMIT);
  const gint64 extent_bottom = -floor_div (-((gint64) sample->extent.y+sample->extent.height),
                                           NATIVE_FACTOR_LIMIT);
  gint64 top = MAX (y*block, extent_top), bottom = MIN ((y+1)*block, extent_bottom);
  if (bottom <= top) return TRUE;
  gfloat row[SAMPLE_WIDTH*4];
  for (guint i = 0; i < width; i++)
    {
      gint64 left = MAX ((x+i)*block, extent_left);
      gint64 right = MIN ((x+i+1)*block, extent_right);
      if (right <= left) continue;
      double sums[4] = { 0, 0, 0, 0 };
      for (gint64 py = top; py < bottom; py++)
        for (gint64 px = left; px < right; )
          {
            guint count = (guint) MIN (right-px, SAMPLE_WIDTH);
            if (!native_mip_row (sample, NATIVE_LEVEL_LIMIT, NATIVE_FACTOR_LIMIT,
                                 px, py, count, row)) return FALSE;
            for (guint p = 0; p < count; p++)
              for (guint c = 0; c < sample->components; c++)
                {
                  double value = row[p*sample->components+c];
                  if (!isfinite (value)) return FALSE;
                  sums[c] += value;
                  if (!isfinite (sums[c])) return FALSE;
                }
            px += count;
          }
      for (guint c = 0; c < sample->components; c++)
        {
          double value = sums[c]/area;
          if (!isfinite (value) || fabs (value) > FLT_MAX) return FALSE;
          out[i*sample->components+c] = (gfloat) value;
        }
    }
  return TRUE;
}

static gboolean
sampled_row (GlimsDisplaySample *sample, const GeglRectangle *rect, double scale,
             guint level, gint64 factor, gfloat *out)
{
  double divisor = scale*factor;
  if (divisor == 1.0)
    return mip_row (sample, level, factor, rect->x, rect->y, rect->width, out);
  double first = ((double) rect->x+0.5)/divisor-0.5;
  double last = ((double) rect->x+rect->width-0.5)/divisor-0.5;
  double sy = ((double) rect->y+0.5)/divisor-0.5;
  gint64 left = (gint64) floor (first), top = (gint64) floor (sy);
  gint64 columns = (gint64) floor (last)-left+2;
  if (columns < 2 || columns > SAMPLE_COLUMNS) return FALSE;
  gfloat rows[2 * SAMPLE_COLUMNS * 4];
  if (!mip_row (sample, level, factor, left, top, (guint) columns, rows) ||
      !mip_row (sample, level, factor, left, top+1, (guint) columns,
                rows+columns*sample->components)) return FALSE;
  double fy = sy-top;
  for (gint x = 0; x < rect->width; x++)
    {
      double sx = ((double) rect->x+x+0.5)/divisor-0.5;
      gint64 base = (gint64) floor (sx), offset = base-left;
      if (offset < 0 || offset+1 >= columns) return FALSE;
      double fx = sx-base;
      for (guint c = 0; c < sample->components; c++)
        {
          const gfloat *above = rows+offset*sample->components;
          const gfloat *below = above+columns*sample->components;
          double upper = (1-fx)*above[c]+fx*above[sample->components+c];
          double lower = (1-fx)*below[c]+fx*below[sample->components+c];
          double value = (1-fy)*upper+fy*lower;
          if (!isfinite (value) || fabs (value) > FLT_MAX) return FALSE;
          out[x*sample->components+c] = (gfloat) value;
        }
    }
  return TRUE;
}

static gboolean
unassociate (gfloat *row, guint width, guint components)
{
  for (guint i = 0; i < width; i++)
    {
      gfloat *pixel = row + i*components;
      for (guint c = 0; c < components; c++) if (!isfinite (pixel[c])) return FALSE;
      double alpha = pixel[components-1];
      if (alpha == 0)
        for (guint c = 0; c < components; c++) pixel[c] = 0.0f;
      else
        for (guint c = 0; c < components-1; c++)
          {
            double value = (double) pixel[c]/alpha;
            if (!isfinite (value) || fabs (value) > FLT_MAX) return FALSE;
            pixel[c] = (gfloat) value;
          }
    }
  return TRUE;
}

GlimsStatus
glims_display_sample_read (GlimsDisplaySample *sample, double scale, GlimsRect area, void *out, size_t stride)
{
  if (!valid_request (sample, scale, area, out, stride)) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsDisplayValidate *self = (GlimsDisplayValidate *) sample->validate;
  if (g_atomic_int_get (&self->failed)) return GLIMS_STATUS_FAILED;
  if (!matches_source (sample, self->source, sample->linear))
    { g_atomic_int_set (&self->failed, TRUE); return GLIMS_STATUS_FAILED; }
  gint64 factor;
  guint level = sampling_level (scale, &factor);
  if (!prepare_sampling (sample, scale, area, factor)) return GLIMS_STATUS_FAILED;
  gfloat row[SAMPLE_WIDTH*4];
  for (gint y = 0; y < area.height; y++)
    for (gint x = 0; x < area.width; )
      {
        guint width = MIN (SAMPLE_WIDTH, (guint) (area.width-x));
        GeglRectangle rect = { area.x+x, area.y+y, (gint) width, 1 };
        gboolean ok = TRUE;
        if (!sample->extent.width || !sample->extent.height)
          memset (row, 0, (gsize) width*sample->components*sizeof (gfloat));
        else ok = sampled_row (sample, &rect, scale, level, factor, row);
        if (!ok || g_atomic_int_get (&self->failed) || !unassociate (row, width, sample->components))
          { g_atomic_int_set (&self->failed, TRUE); return GLIMS_STATUS_FAILED; }
        memcpy ((guint8 *) out + (size_t) y*stride + (size_t) x*sample->components*sizeof (gfloat),
                row, (size_t) width*sample->components*sizeof (gfloat));
        x += width;
      }
  return GLIMS_STATUS_OK;
}

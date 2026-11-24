/*
 * Layer > Matting: Defringe, Remove Black Matte and Remove White Matte.
 * Runs on the engine thread.
 *
 * The classic editor commands clean the colored halo a layer keeps along
 * its partially transparent edge. The pixel work is a direct buffer pass,
 * not a GEGL operation: Defringe needs a nearest-opaque search and the
 * matte formulas are pointwise. The layer is read and written in its own
 * format changed to float components, so its transfer curve is kept and
 * grayscale (Y A) and RGB (R G B A) layers both work. GIMP stores
 * straight alpha; alpha is never written.
 *
 * The command is layer-wide and ignores the selection: the halo is an edge
 * property of the whole layer. Coordinates are the layer's own buffer
 * coordinates, so pixels outside the layer do not exist.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimpdrawable.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpprogress.h"

#include "gegl/gimp-babl.h"

/* Rows processed per band. The Defringe halo adds `width` rows above and
 * below, so a band's working buffer stays small and independent of the
 * layer's height. */
#define MATTING_BAND_ROWS 64

typedef struct {
  GlimsEngine  *engine;
  GlimsProgress *progress;
  guint64       completed, total;
  gint64        last_service;
  gboolean      cancelled;
} MattingProgress;

/* One pixel's nearest opaque seed: its Chebyshev distance and the seed's
 * layer coordinates. */
typedef struct {
  guint32 distance;
  gint32  x, y;
} MattingSeed;

static gboolean
engine_stopping (GlimsEngine *engine)
{
  g_mutex_lock (&engine->lock);
  gboolean stopping = engine->stopping;
  g_mutex_unlock (&engine->lock);
  return stopping;
}

static void
cancel_matting (GimpProgress *progress, gpointer data)
{
  (void)progress;
  ((MattingProgress *)data)->cancelled = TRUE;
}

static gboolean
continue_matting (MattingProgress *state)
{
  gint64 now = g_get_monotonic_time ();
  if (now - state->last_service >= 10 * G_TIME_SPAN_MILLISECOND || state->completed == state->total)
    {
      gimp_progress_set_value (GIMP_PROGRESS (state->progress), (double)state->completed / state->total);
      for (guint i = 0; i < 4; i++)
        {
          if (!g_main_context_iteration (NULL, FALSE)) break;
          if (g_get_monotonic_time () - now >= 5 * G_TIME_SPAN_MILLISECOND) break;
        }
      state->last_service = g_get_monotonic_time ();
    }
  return !state->cancelled && !engine_stopping (state->engine);
}

/* Grow the layer-wide damage box over one changed pixel. `any` is the
 * whole command's changed flag, so the first band's box is never reset by
 * a later band. */
static void
include_pixel (GeglRectangle *damage, gboolean *any, gint x, gint y)
{
  if (!*any)
    {
      *damage = (GeglRectangle) { x, y, 1, 1 };
      *any = TRUE;
    }
  else
    {
      gint x0 = MIN (damage->x, x), y0 = MIN (damage->y, y);
      gint x1 = MAX (damage->x + damage->width - 1, x);
      gint y1 = MAX (damage->y + damage->height - 1, y);
      *damage = (GeglRectangle) { x0, y0, x1 - x0 + 1, y1 - y0 + 1 };
    }
}

GlimsStatus
glims_layer_matting (GlimsEngine  *engine,
                     GlimsImageID  id,
                     GlimsItemID   layer_id,
                     uint32_t      operation,
                     uint32_t      width,
                     char        **error)
{
  GlimsStatus     status;
  GlimsOpenImage *open;
  GimpImage      *image = NULL;
  GimpLayer      *layer = NULL;
  GimpDrawable   *drawable;
  GeglBuffer     *source = NULL, *candidate = NULL;
  const Babl      *format;
  const char      *undo_name;
  gint             layer_width, layer_height;
  guint            n_components, pixel_bytes;
  gboolean         any_partial = FALSE, any_opaque = FALSE, changed = FALSE;
  GeglRectangle    damage = { 0, 0, 0, 0 };
  MattingProgress  progress = { .engine = engine };
  gulong           cancel_handler = 0;
  gboolean         busy_held = FALSE;

  if (error) *error = NULL;
  if (operation < GLIMS_MATTING_DEFRINGE || operation > GLIMS_MATTING_REMOVE_WHITE_MATTE)
    {
      if (error) *error = strdup ("Unknown matting operation.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (operation == GLIMS_MATTING_DEFRINGE)
    {
      if (width < 1 || width > GLIMS_MATTING_MAX_WIDTH)
        {
          if (error) *error = strdup ("Choose a Defringe width from 1 to 200 pixels.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
    }
  else if (width != 0)
    {
      if (error) *error = strdup ("Remove Black Matte and Remove White Matte take no width.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  image = open->image;
  if (engine->busy || engine->progress || g_hash_table_size (engine->strokes) ||
      g_hash_table_size (engine->filters) || ! gimp_image_undo_is_enabled (image) ||
      gimp_image_get_undo_group_count (image))
    {
      if (error) *error = strdup ("Finish the stroke or close the filter dialog first.");
      return GLIMS_STATUS_BUSY;
    }

  layer = NULL;
  {
    GimpItem *item = gimp_item_get_by_id (engine->gimp, layer_id);
    if (! item || ! GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image ||
        ! gimp_item_is_attached (item))
      return GLIMS_STATUS_NOT_FOUND;
    layer = GIMP_LAYER (item);
  }
  drawable = GIMP_DRAWABLE (layer);

  /* The same layer admission as the one-click adjustments. */
  if (GIMP_IS_GROUP_LAYER (layer))
    return glims_fail (error, NULL, "A layer group cannot take this matting.");
  switch (glims_layer_kind (layer))
    {
    case GLIMS_LAYER_PIXEL:
      break;
    case GLIMS_LAYER_GROUP:
      return glims_fail (error, NULL, "A layer group cannot take this matting.");
    default:
      return glims_fail (error, NULL,
                         "Rasterize the text, link or vector layer before this matting.");
    }
  if (gimp_image_get_base_type (image) == GIMP_INDEXED)
    {
      glims_fail (error, NULL, "Convert the image to RGB or grayscale before matting.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  if (! gimp_drawable_has_alpha (drawable))
    {
      if (error) *error = strdup ("The layer has no transparency to work on.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  source = g_object_ref (gimp_drawable_get_buffer (drawable));
  if (! source)
    {
      if (error) *error = strdup ("The layer's pixel buffer is unavailable.");
      return GLIMS_STATUS_FAILED;
    }
  candidate = gegl_buffer_dup (source);
  if (! candidate)
    {
      if (error) *error = strdup ("The matting could not allocate its working copy.");
      status = GLIMS_STATUS_FAILED;
      goto done;
    }
  format = gimp_babl_format_change_component_type (gimp_drawable_get_format (drawable),
                                                   GIMP_COMPONENT_TYPE_FLOAT);
  if (! format)
    {
      if (error) *error = strdup ("The layer's pixel format cannot be read as float.");
      status = GLIMS_STATUS_FAILED;
      goto done;
    }
  n_components = babl_format_get_n_components (format);
  pixel_bytes = n_components * sizeof (float);
  layer_width = gimp_item_get_width (GIMP_ITEM (drawable));
  layer_height = gimp_item_get_height (GIMP_ITEM (drawable));
  if (layer_width < 1 || layer_height < 1 || n_components < 2)
    {
      if (error) *error = strdup ("The layer has no matting pixels.");
      status = GLIMS_STATUS_FAILED;
      goto done;
    }

  switch (operation)
    {
    case GLIMS_MATTING_DEFRINGE:          undo_name = "Defringe"; break;
    case GLIMS_MATTING_REMOVE_BLACK_MATTE: undo_name = "Remove Black Matte"; break;
    default:                              undo_name = "Remove White Matte"; break;
    }

  progress.total = (guint64) layer_width * layer_height;
  progress.progress = glims_progress_new (engine);
  if (! progress.progress)
    {
      if (error) *error = strdup ("The matting could not start its progress.");
      status = GLIMS_STATUS_FAILED;
      goto done;
    }
  engine->busy++;
  busy_held = TRUE;
  g_object_ref (image);
  g_object_ref (layer);
  engine->progress = progress.progress;
  cancel_handler = g_signal_connect (progress.progress, "cancel", G_CALLBACK (cancel_matting), &progress);
  gimp_progress_start (GIMP_PROGRESS (progress.progress), TRUE, "%s", undo_name);

  for (gint band_y = 0; band_y < layer_height; band_y += MATTING_BAND_ROWS)
    {
      gint   band_height = MIN (MATTING_BAND_ROWS, layer_height - band_y);
      gint   region_y, region_height;
      guint  region_pixels, row, x;
      gboolean band_changed = FALSE;
      float *pixels;
      MattingSeed *seeds = NULL;

      if (operation == GLIMS_MATTING_DEFRINGE)
        {
          region_y = MAX (0, band_y - (gint) width);
          region_height = MIN (layer_height, band_y + band_height + (gint) width) - region_y;
        }
      else
        {
          region_y = band_y;
          region_height = band_height;
        }
      region_pixels = (guint) layer_width * region_height;
      pixels = g_try_malloc ((size_t) region_pixels * pixel_bytes);
      if (! pixels)
        {
          if (error) *error = strdup ("The matting could not allocate its band buffer.");
          status = GLIMS_STATUS_FAILED;
          goto done;
        }
      if (operation == GLIMS_MATTING_DEFRINGE)
        {
          seeds = g_try_new0 (MattingSeed, region_pixels);
          if (! seeds)
            {
              g_free (pixels);
              if (error) *error = strdup ("The matting could not allocate its search buffer.");
              status = GLIMS_STATUS_FAILED;
              goto done;
            }
        }

      GeglRectangle region = { 0, region_y, layer_width, region_height };
      gegl_buffer_get (source, &region, 1.0, format, pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);

      if (operation == GLIMS_MATTING_DEFRINGE)
        {
          /* Seeds are the fully opaque pixels. Every pixel starts one
           * step past the width cap, so only a seed within the width can
           * become the answer. */
          for (guint i = 0; i < region_pixels; i++)
            seeds[i].distance = width + 1;
          for (row = 0; row < region_height; row++)
            for (x = 0; x < layer_width; x++)
              {
                float *p = pixels + ((size_t) row * layer_width + x) * n_components;
                float  a = p[n_components - 1];
                guint  i = row * layer_width + x;

                if (a >= 1.0f)
                  {
                    any_opaque = TRUE;
                    seeds[i].distance = 0;
                    seeds[i].x = x;
                    seeds[i].y = region_y + row;
                  }
                else if (a > 0.0f && a < 1.0f)
                  any_partial = TRUE;
              }

          /* Forward pass: W, NW, N, NE. Backward pass: E, SE, S, SW. A
           * strict "<" keeps the earlier candidate on a tie. The halo
           * holds every seed within `width` rows, so each band's result
           * is exact for the Chebyshev distance. */
          for (row = 0; row < region_height; row++)
            for (x = 0; x < layer_width; x++)
              {
                guint i = row * layer_width + x;
                if (seeds[i].distance == 0) continue;
                if (x > 0 && seeds[i - 1].distance + 1 < seeds[i].distance)
                  {
                    seeds[i].distance = seeds[i - 1].distance + 1;
                    seeds[i].x = seeds[i - 1].x;
                    seeds[i].y = seeds[i - 1].y;
                  }
                if (row > 0)
                  {
                    if (x > 0 && seeds[i - layer_width - 1].distance + 1 < seeds[i].distance)
                      {
                        seeds[i].distance = seeds[i - layer_width - 1].distance + 1;
                        seeds[i].x = seeds[i - layer_width - 1].x;
                        seeds[i].y = seeds[i - layer_width - 1].y;
                      }
                    if (seeds[i - layer_width].distance + 1 < seeds[i].distance)
                      {
                        seeds[i].distance = seeds[i - layer_width].distance + 1;
                        seeds[i].x = seeds[i - layer_width].x;
                        seeds[i].y = seeds[i - layer_width].y;
                      }
                    if (x + 1 < layer_width &&
                        seeds[i - layer_width + 1].distance + 1 < seeds[i].distance)
                      {
                        seeds[i].distance = seeds[i - layer_width + 1].distance + 1;
                        seeds[i].x = seeds[i - layer_width + 1].x;
                        seeds[i].y = seeds[i - layer_width + 1].y;
                      }
                  }
              }
          for (gint reverse_row = region_height - 1; reverse_row >= 0; reverse_row--)
            for (gint reverse_x = layer_width - 1; reverse_x >= 0; reverse_x--)
              {
                guint i = reverse_row * layer_width + reverse_x;
                if (seeds[i].distance == 0) continue;
                if (reverse_x + 1 < layer_width &&
                    seeds[i + 1].distance + 1 < seeds[i].distance)
                  {
                    seeds[i].distance = seeds[i + 1].distance + 1;
                    seeds[i].x = seeds[i + 1].x;
                    seeds[i].y = seeds[i + 1].y;
                  }
                if (reverse_row + 1 < region_height)
                  {
                    if (reverse_x + 1 < layer_width &&
                        seeds[i + layer_width + 1].distance + 1 < seeds[i].distance)
                      {
                        seeds[i].distance = seeds[i + layer_width + 1].distance + 1;
                        seeds[i].x = seeds[i + layer_width + 1].x;
                        seeds[i].y = seeds[i + layer_width + 1].y;
                      }
                    if (seeds[i + layer_width].distance + 1 < seeds[i].distance)
                      {
                        seeds[i].distance = seeds[i + layer_width].distance + 1;
                        seeds[i].x = seeds[i + layer_width].x;
                        seeds[i].y = seeds[i + layer_width].y;
                      }
                    if (reverse_x > 0 &&
                        seeds[i + layer_width - 1].distance + 1 < seeds[i].distance)
                      {
                        seeds[i].distance = seeds[i + layer_width - 1].distance + 1;
                        seeds[i].x = seeds[i + layer_width - 1].x;
                        seeds[i].y = seeds[i + layer_width - 1].y;
                      }
                  }
              }

          /* Write only the band's own rows. Alpha is never written. */
          for (row = band_y - region_y; row < band_y - region_y + band_height; row++)
            for (x = 0; x < layer_width; x++)
              {
                guint  i = row * layer_width + x;
                float *p = pixels + (size_t) i * n_components;
                float  a = p[n_components - 1];

                if (a <= 0.0f || a >= 1.0f || seeds[i].distance > width)
                  continue;
                float *q = pixels + ((size_t) (seeds[i].y - region_y) * layer_width + seeds[i].x)
                           * n_components;
                gboolean pixel_changed = FALSE;
                for (guint c = 0; c + 1 < n_components; c++)
                  if (p[c] != q[c])
                    {
                      p[c] = q[c];
                      pixel_changed = TRUE;
                    }
                if (pixel_changed)
                  {
                    include_pixel (&damage, &changed, x, region_y + row);
                    band_changed = TRUE;
                  }
              }
        }
      else
        {
          gboolean black = operation == GLIMS_MATTING_REMOVE_BLACK_MATTE;
          for (row = 0; row < region_height; row++)
            for (x = 0; x < layer_width; x++)
              {
                float *p = pixels + ((size_t) row * layer_width + x) * n_components;
                float  a = p[n_components - 1];
                float  inv;
                gboolean pixel_changed = FALSE;

                if (a <= 0.0f || a >= 1.0f)
                  continue;
                any_partial = TRUE;
                inv = 1.0f / a;
                for (guint c = 0; c + 1 < n_components; c++)
                  {
                    float value = black ? p[c] * inv
                                        : (p[c] - (1.0f - a)) * inv;
                    value = CLAMP (value, 0.0f, 1.0f);
                    if (value != p[c])
                      {
                        p[c] = value;
                        pixel_changed = TRUE;
                      }
                  }
                if (pixel_changed)
                  {
                    include_pixel (&damage, &changed, x, region_y + row);
                    band_changed = TRUE;
                  }
              }
        }

      if (band_changed)
        {
          GeglRectangle band = { 0, band_y, layer_width, band_height };
          float       *start = pixels + (size_t) (band_y - region_y) * layer_width * n_components;
          gegl_buffer_set (candidate, &band, 0, format, start, GEGL_AUTO_ROWSTRIDE);
        }

      g_free (seeds);
      g_free (pixels);
      progress.completed += (guint64) band_height * layer_width;
      if (! continue_matting (&progress))
        {
          status = GLIMS_STATUS_CANCELLED;
          goto done;
        }
    }

  if (! continue_matting (&progress))
    {
      status = GLIMS_STATUS_CANCELLED;
      goto done;
    }
  if (! any_partial)
    {
      status = glims_fail (error, NULL, "The layer has no partially transparent edge pixels.");
      goto done;
    }
  if (operation == GLIMS_MATTING_DEFRINGE && ! any_opaque)
    {
      status = glims_fail (error, NULL, "The layer has no fully opaque pixels to take colors from.");
      goto done;
    }
  if (! changed)
    {
      status = GLIMS_STATUS_OK;
      goto done;
    }

  /* Nested progress callbacks may have disturbed the target. Validate the
   * image, layer and buffer again immediately before the non-yielding
   * Undo/publication transaction. */
  if (! GIMP_IS_IMAGE (image) || image->gimp != engine->gimp ||
      ! GIMP_IS_LAYER (layer) || gimp_item_get_image (GIMP_ITEM (layer)) != image ||
      ! gimp_item_is_attached (GIMP_ITEM (layer)) ||
      gimp_drawable_get_buffer (drawable) != source ||
      ! gimp_image_undo_is_enabled (image) || gimp_image_get_undo_group_count (image))
    {
      if (error) *error = strdup ("The layer changed while the matting ran; nothing was changed.");
      status = GLIMS_STATUS_BUSY;
      goto done;
    }

  if (! gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_DRAWABLE_MOD, undo_name))
    {
      if (error) *error = strdup ("The image history could not group the matting.");
      status = GLIMS_STATUS_FAILED;
      goto done;
    }
  gimp_drawable_push_undo (drawable, undo_name, NULL, damage.x, damage.y, damage.width, damage.height);
  gegl_buffer_copy (candidate, &damage, GEGL_ABYSS_NONE, source, &damage);
  gimp_drawable_update (drawable, damage.x, damage.y, damage.width, damage.height);
  gboolean group_closed = gimp_image_undo_group_end (image);
  /* Pixels have already been published, even if a native callback prevented
   * the Undo group from closing. Report and redraw that partial failure. */
  gimp_image_flush (image);
  {
    /* The damage box is in layer coordinates; the event takes image
     * pixels, so an offset layer's redraw lands where it changed. */
    gint          offset_x = 0, offset_y = 0;
    gimp_item_get_offset (GIMP_ITEM (layer), &offset_x, &offset_y);
    GeglRectangle image_damage = { damage.x + offset_x, damage.y + offset_y,
                                   damage.width, damage.height };
    glims_emit (engine, GLIMS_EVENT_PROJECTION_CHANGED, image, &image_damage, NULL);
  }
  if (! group_closed)
    {
      if (error) *error = strdup ("The matting could not finish its Undo group; pixels changed.");
      status = GLIMS_STATUS_FAILED;
      goto done;
    }
  status = GLIMS_STATUS_OK;

done:
  if (progress.progress)
    {
      if (cancel_handler) g_signal_handler_disconnect (progress.progress, cancel_handler);
      gimp_progress_end (GIMP_PROGRESS (progress.progress));
      if (engine->progress == progress.progress) engine->progress = NULL;
      g_object_unref (progress.progress);
    }
  g_clear_object (&candidate);
  g_clear_object (&source);
  /* The image and layer references are taken together with the busy
   * hold, after the early refusals; release them only when held. */
  if (busy_held)
    {
      g_object_unref (layer);
      g_object_unref (image);
      engine->busy--;
    }
  return status;
}

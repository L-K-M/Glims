/* Image > Trap for native CMYK component documents. Spreads the lighter
 * cyan, magenta and yellow inks under darker neighbours to hide small
 * plate misregistration (docs/trap.md). Follows the component-edit model:
 * a complete copy-on-write candidate is staged per plane under the busy
 * gate with cooperative cancellation, then published as one native Undo
 * group. The K plane is read for darkness but is never changed. */
#include "engine-private.h"
#include "plate-storage.h"
#include "trap-math.h"

#include <float.h>
#include <math.h>
#include <string.h>
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpprogress.h"

typedef struct {
  GlimsEngine *engine;
  GlimsProgress *progress;
  guint64 completed, total;
  gint64 last_service;
  gboolean cancelled;
} TrapProgress;

static void
cancel_trap (GimpProgress *progress, gpointer data)
{
  ((TrapProgress *) data)->cancelled = TRUE;
}

/* Same cooperative cadence as the component edits: a bounded progress and
 * cancellation service while the busy gate is held. */
static gboolean
continue_trap (TrapProgress *state)
{
  gint64 now = g_get_monotonic_time ();
  if (now - state->last_service >= 10 * G_TIME_SPAN_MILLISECOND ||
      state->completed == state->total)
    {
      gimp_progress_set_value (GIMP_PROGRESS (state->progress),
                                (double) state->completed / state->total);
      for (guint i = 0; i < 4; i++)
        {
          if (!g_main_context_iteration (NULL, FALSE)) break;
          if (g_get_monotonic_time () - now >= 5 * G_TIME_SPAN_MILLISECOND) break;
        }
      state->last_service = g_get_monotonic_time ();
    }
  g_mutex_lock (&state->engine->lock);
  gboolean stopping = state->engine->stopping;
  g_mutex_unlock (&state->engine->lock);
  return !state->cancelled && !stopping;
}

/* One native row of up to `count` samples becomes float coverage and
 * float intensity. Coverage is 1 - intensity; intensity itself is kept
 * verbatim so the winning sample can be written back byte-exact. */
static void
trap_row_to_tile (const Babl *format, const guint32 *raw, size_t count,
                  float *coverage, float *intensity)
{
  const Babl *type = babl_format_get_type (format, 0);
  if (type == babl_type ("u8"))
    for (size_t i = 0; i < count; i++)
      {
        const guint8 *sample = (const guint8 *) raw;
        intensity[i] = (float) sample[i];
        coverage[i] = (float) ((255.0 - (double) sample[i]) / 255.0);
      }
  else if (type == babl_type ("u16"))
    for (size_t i = 0; i < count; i++)
      {
        const guint16 *sample = (const guint16 *) raw;
        intensity[i] = (float) sample[i];
        coverage[i] = (float) ((65535.0 - (double) sample[i]) / 65535.0);
      }
  else
    for (size_t i = 0; i < count; i++)
      {
        const float *sample = (const float *) raw;
        intensity[i] = sample[i];
        coverage[i] = (float) (1.0 - (double) sample[i]);
      }
}

/* The blended native sample: the scalar edits' result = original +
 * coverage * (proposal - original). Integer formats round to nearest,
 * half upward, inside [0, max]; float keeps exact values at full coverage
 * and refuses unrepresentable results. Returns false on a bad mask or an
 * unrepresentable float. */
static bool
trap_blend (const Babl *format, const guint8 *original, double mask,
            double proposal, guint32 *out)
{
  const Babl *type = babl_format_get_type (format, 0);
  if (! isfinite (mask) || mask < 0 || mask > 1)
    return false;
  if (type == babl_type ("u8") || type == babl_type ("u16"))
    {
      double max = type == babl_type ("u8") ? 255.0 : 65535.0;
      double original_i, blended;
      if (type == babl_type ("u8"))
        original_i = (double) *original;
      else
        original_i = (double) *(const guint16 *) original;
      if (! isfinite (proposal) || proposal < 0 || proposal > max)
        return false;
      blended = original_i + mask * (proposal - original_i);
      if (blended < 0) blended = 0;
      if (blended > max) blended = max;
      blended = floor (blended + 0.5);
      if (type == babl_type ("u8"))
        {
          guint8 v = (guint8) blended;
          memcpy (out, &v, sizeof v);
        }
      else
        {
          guint16 v = (guint16) blended;
          memcpy (out, &v, sizeof v);
        }
      return true;
    }
  if (type == babl_type ("float"))
    {
      float original_f, result;
      memcpy (&original_f, original, sizeof original_f);

      result = mask == 1 ? (float) proposal :
               (float) ((double) original_f + mask * (proposal - (double) original_f));
      if (! isfinite (result))
        return false;
      memcpy (out, &result, sizeof result);
      return true;
    }
  return false;
}

/* One tile's inner size. With the 16-pixel margin a tile holds at most
 * 2080 x 160 pixels: two interleaved four-plane float copies (coverage
 * and intensity) are about 10.6 MiB, plus the kernel's outputs for the
 * inner pixels, whatever the canvas size. The row buffers below hold one
 * tile row. */
#define TRAP_BAND_ROWS 128
#define TRAP_CHUNK_COLUMNS 2048
#define TRAP_ROW_CAPACITY (TRAP_CHUNK_COLUMNS + 2 * GLIMS_TRAP_MAX_WIDTH)

GlimsStatus
glims_image_trap (GlimsEngine *engine, GlimsImageID id,
                  const GlimsTrapSettings *settings, char **error)
{
  if (error) *error = NULL;
  if (! settings || settings->struct_size < sizeof *settings ||
      settings->width < 1 || settings->width > (int32_t) GLIMS_TRAP_MAX_WIDTH)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (! open) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;
  if (! gimp_image_undo_is_enabled (open->image) ||
      gimp_image_get_undo_group_count (open->image))
    return GLIMS_STATUS_BUSY;

  GlimsPlateStorage storage;
  if (! glims_plate_storage_read_open (open, &storage) ||
      storage.map.mode != GLIMS_PLATE_MODE_CMYK || storage.map.count != 4)
    {
      if (error) *error = g_strdup ("Trap is available for CMYK documents only.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  /* K takes no part in the output, so only the three ink planes refuse a
   * pixel lock. */
  for (guint plane = 0; plane < 3; plane++)
    {
      status = glims_check_item_locks (GIMP_ITEM (storage.planes[plane]),
                                       GLIMS_LOCK_PIXELS, error);
      if (status != GLIMS_STATUS_OK) return status;
    }

  GeglRectangle region = { 0, 0, 0, 0 };
  if (! gimp_item_mask_intersect (GIMP_ITEM (storage.planes[0]), &region.x,
                                  &region.y, &region.width, &region.height))
    return GLIMS_STATUS_OK;
  GimpChannel *selection = gimp_image_get_mask (open->image);
  gboolean masked = ! gimp_channel_is_empty (selection);
  int radius = settings->width;
  gint image_width = gimp_image_get_width (open->image);
  gint image_height = gimp_image_get_height (open->image);

  /* Own every native object used after dispatch. Busy gates other edits;
   * the candidates and the selection snapshot hold no borrowed storage
   * state. */
  engine->busy++;
  GimpImage *image = g_object_ref (open->image);
  GimpChannel *planes[4] = { storage.planes[0], storage.planes[1],
                             storage.planes[2], storage.planes[3] };
  GeglBuffer *source[4] = { NULL };
  GeglBuffer *candidate[3] = { NULL };
  GeglBuffer *mask = masked ? gegl_buffer_dup (gimp_drawable_get_buffer (GIMP_DRAWABLE (selection))) : NULL;
  const Babl *native_format;
  for (guint plane = 0; plane < 4; plane++)
    {
      g_object_ref (storage.planes[plane]);
      source[plane] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (storage.planes[plane])));
      if (plane < 3) candidate[plane] = gegl_buffer_dup (source[plane]);
    }
  native_format = gegl_buffer_get_format (source[0]);
  gint bpp = babl_format_get_bytes_per_pixel (native_format);
  gboolean floats = babl_format_get_type (native_format, 0) == babl_type ("float");
  TrapProgress state = { .engine = engine,
    .total = (guint64) region.width * region.height };
  state.progress = glims_progress_new (engine);
  engine->progress = state.progress;
  gulong cancel_handler = g_signal_connect (state.progress, "cancel",
                                            G_CALLBACK (cancel_trap), &state);
  gimp_progress_start (GIMP_PROGRESS (state.progress), TRUE, "Trap");

  GeglRectangle damage[3] = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } };
  gboolean changed[3] = { FALSE, FALSE, FALSE };
  float *tile = NULL, *intensity = NULL, *trapped = NULL, *scan = NULL;
  int32_t *winner = NULL;
  guint32 raw[TRAP_ROW_CAPACITY], row_out[TRAP_ROW_CAPACITY];
  float mask_row[TRAP_ROW_CAPACITY];

  /* Fixed tiles bound the scratch memory whatever the canvas size: each
   * holds at most TRAP_BAND_ROWS x TRAP_CHUNK_COLUMNS inner pixels plus the
   * width margin on every side, clipped to the canvas, so every inner
   * pixel sees all of its disk across tile seams. */
  gint tile_cap_w = TRAP_CHUNK_COLUMNS + 2 * radius;
  gint tile_cap_h = TRAP_BAND_ROWS + 2 * radius;
  size_t tile_cap = (size_t) tile_cap_w * (size_t) tile_cap_h;
  size_t inner_cap = (size_t) TRAP_CHUNK_COLUMNS * (size_t) TRAP_BAND_ROWS;

  tile = g_malloc (tile_cap * GLIMS_TRAP_PLANES * sizeof (float));
  intensity = g_malloc (tile_cap * GLIMS_TRAP_PLANES * sizeof (float));
  trapped = g_malloc (inner_cap * 3 * sizeof (float));
  winner = g_malloc (inner_cap * 3 * sizeof (int32_t));
  scan = g_malloc ((size_t) tile_cap_w * 2 * sizeof (float));

  for (gint inner_y0 = region.y; inner_y0 < region.y + region.height;
       inner_y0 += TRAP_BAND_ROWS)
    {
      gint inner_y1 = MIN (inner_y0 + TRAP_BAND_ROWS, region.y + region.height);
      gint inner_h = inner_y1 - inner_y0;
      gint tile_y0 = MAX (0, inner_y0 - radius);
      gint tile_y1 = MIN (image_height, inner_y1 + radius);
      gint tile_h = tile_y1 - tile_y0;

      for (gint inner_x0 = region.x; inner_x0 < region.x + region.width;
           inner_x0 += TRAP_CHUNK_COLUMNS)
        {
          gint inner_x1 = MIN (inner_x0 + TRAP_CHUNK_COLUMNS, region.x + region.width);
          gint inner_w = inner_x1 - inner_x0;
          gint tile_x0 = MAX (0, inner_x0 - radius);
          gint tile_x1 = MIN (image_width, inner_x1 + radius);
          gint tile_w = tile_x1 - tile_x0;

          if (! continue_trap (&state)) { status = GLIMS_STATUS_CANCELLED; goto finish; }

          /* Read the four planes' rows as coverage for the kernel and as
           * intensity for the exact winner writeback. A nonfinite float
           * sample anywhere in the tile refuses the operation. */
          for (gint y = tile_y0; y < tile_y1; y++)
            {
              if (! continue_trap (&state)) { status = GLIMS_STATUS_CANCELLED; goto finish; }
              GeglRectangle row = { tile_x0, y, tile_w, 1 };
              size_t base = (size_t) (y - tile_y0) * (size_t) tile_w;
              for (guint plane = 0; plane < 4; plane++)
                {
                  gegl_buffer_get (source[plane], &row, 1, native_format, raw,
                                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
                  trap_row_to_tile (native_format, raw, (size_t) tile_w,
                                    scan, scan + tile_w);
                  if (floats)
                    for (gint i = 0; i < tile_w; i++)
                      if (! isfinite (scan[i]))
                        {
                          if (error) *error = g_strdup (
                            "The Trap operation contains invalid samples. No pixels were changed.");
                          status = GLIMS_STATUS_INVALID_ARGUMENT;
                          goto finish;
                        }
                  for (gint i = 0; i < tile_w; i++)
                    {
                      tile[(base + (size_t) i) * 4 + plane] = scan[i];
                      intensity[(base + (size_t) i) * 4 + plane] = scan[tile_w + i];
                    }
                }
            }

          /* Every tile pixel is inside the canvas, so `valid` is the tile. */
          if (! glims_trap_inner (tile, (size_t) tile_w, (size_t) tile_h,
                                  (size_t) (inner_x0 - tile_x0),
                                  (size_t) (inner_y0 - tile_y0),
                                  (size_t) inner_w, (size_t) inner_h,
                                  0, 0, (size_t) tile_w, (size_t) tile_h,
                                  (uint32_t) radius, trapped, winner))
            {
              status = GLIMS_STATUS_FAILED;
              goto finish;
            }

          /* Write each changed run into that plane's candidate, tracking
           * one damage box per plane for the single Undo group. */
          for (gint y = inner_y0; y < inner_y1; y++)
            {
              if (! continue_trap (&state)) { status = GLIMS_STATUS_CANCELLED; goto finish; }
              GeglRectangle row = { inner_x0, y, inner_w, 1 };
              if (mask)
                gegl_buffer_get (mask, &row, 1, babl_format ("Y float"),
                                 mask_row, GEGL_AUTO_ROWSTRIDE,
                                 GEGL_ABYSS_NONE);
              for (guint plane = 0; plane < 3; plane++)
                {
                  bool row_changed = false;
                  gegl_buffer_get (source[plane], &row, 1, native_format,
                                   raw, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
                  memcpy (row_out, raw, (size_t) inner_w * (size_t) bpp);
                  for (gint i = 0; i < inner_w; i++)
                    {
                      size_t inner_index =
                        ((size_t) (y - inner_y0) * (size_t) inner_w + (size_t) i) * 3 + plane;
                      double proposal =
                        intensity[(size_t) winner[inner_index] * 4 + plane];
                      guint32 blended;
                      if (! trap_blend (native_format,
                                        (const guint8 *) raw + (size_t) i * bpp,
                                        mask ? (double) mask_row[i] : 1.0,
                                        proposal, &blended))
                        {
                          if (error) *error = g_strdup (
                            "The Trap operation contains invalid samples or produces an unrepresentable value. No pixels were changed.");
                          status = GLIMS_STATUS_INVALID_ARGUMENT;
                          goto finish;
                        }
                      if (memcmp (&blended, (const guint8 *) raw + (size_t) i * bpp, (size_t) bpp))
                        {
                          memcpy ((guint8 *) row_out + (size_t) i * bpp, &blended, (size_t) bpp);
                          row_changed = true;
                        }
                    }
                  if (row_changed)
                    {
                      gegl_buffer_set (candidate[plane], &row, 0,
                                       native_format, row_out,
                                       GEGL_AUTO_ROWSTRIDE);
                      if (changed[plane])
                        gegl_rectangle_bounding_box (&damage[plane],
                                                     &damage[plane], &row);
                      else
                        damage[plane] = row;
                      changed[plane] = TRUE;
                    }
                }
            }
          state.completed += (guint64) inner_w * (guint64) inner_h;
        }
    }

  if (! continue_trap (&state)) { status = GLIMS_STATUS_CANCELLED; goto finish; }
  if (changed[0] || changed[1] || changed[2])
    {
      /* Re-resolve after nested dispatch, then publish without yielding. */
      GlimsOpenImage *current = glims_lookup_image (engine, id);
      GlimsPlateStorage check;
      gboolean same = current && current->image == image &&
        glims_plate_storage_read_open (current, &check) &&
        check.map.mode == GLIMS_PLATE_MODE_CMYK && check.map.count == 4;
      for (guint plane = 0; same && plane < 4; plane++)
        same = check.planes[plane] == planes[plane] &&
          gimp_drawable_get_buffer (GIMP_DRAWABLE (check.planes[plane])) == source[plane];
      if (! same)
        {
          if (error) *error = g_strdup ("The image changed before the trap could finish.");
          status = GLIMS_STATUS_INVALID_ARGUMENT;
          goto finish;
        }
      for (guint plane = 0; plane < 3; plane++)
        {
          status = glims_check_item_locks (GIMP_ITEM (planes[plane]),
                                           GLIMS_LOCK_PIXELS, error);
          if (status != GLIMS_STATUS_OK) goto finish;
        }
      /* Progress dispatch may have changed native Undo admission. Never
       * publish into a foreign group or consume a stage without Undo. */
      if (! gimp_image_undo_is_enabled (image) ||
          gimp_image_get_undo_group_count (image))
        {
          status = GLIMS_STATUS_BUSY;
          goto finish;
        }
      if (! gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_DRAWABLE, "Trap"))
        {
          if (error) *error = g_strdup ("Trap could not start its Undo group; no pixels were changed.");
          status = GLIMS_STATUS_FAILED;
          goto finish;
        }
      for (guint plane = 0; plane < 3; plane++)
        if (changed[plane])
          {
            GimpDrawable *drawable = GIMP_DRAWABLE (planes[plane]);
            gimp_drawable_push_undo (drawable, "Trap", NULL, damage[plane].x,
                                     damage[plane].y, damage[plane].width,
                                     damage[plane].height);
            gegl_buffer_copy (candidate[plane], &damage[plane], GEGL_ABYSS_NONE,
                              source[plane], &damage[plane]);
            gimp_drawable_update (drawable, damage[plane].x, damage[plane].y,
                                  damage[plane].width, damage[plane].height);
          }
      /* The planes already hold the result, so a group that cannot close
       * still flushes and reports that pixels changed, as matting does. */
      gboolean closed = gimp_image_undo_group_end (image);
      gimp_image_flush (image);
      if (! closed)
        {
          if (error) *error = g_strdup ("Trap could not finish its Undo group; pixels changed.");
          status = GLIMS_STATUS_FAILED;
          goto finish;
        }
    }
  status = GLIMS_STATUS_OK;

finish:
  g_free (tile); g_free (intensity);
  g_free (trapped); g_free (winner); g_free (scan);
  g_signal_handler_disconnect (state.progress, cancel_handler);
  gimp_progress_end (GIMP_PROGRESS (state.progress));
  engine->progress = NULL;
  g_object_unref (state.progress);
  g_clear_object (&mask);
  for (guint plane = 0; plane < 4; plane++)
    {
      g_clear_object (&source[plane]);
      if (plane < 3) g_clear_object (&candidate[plane]);
      g_object_unref (planes[plane]);
    }
  g_object_unref (image);
  engine->busy--;
  return status;
}

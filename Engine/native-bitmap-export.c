/* Export a frozen ordinary grayscale/indexed projection without changing the
 * open document. Bitmap PSD has no alpha, color profile, or layer records. */
#include "engine-private.h"
#include "bitmap-psd-file.h"
#include "bitmap-diffusion.h"
#include <cairo.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "core/gimpimage.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimppickable.h"
#include "core/gimpprogress.h"
#include "core/gimpprojectable.h"
#include "core/gimpprojection.h"
#include "gegl/gimptilehandlervalidate.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplinklayer.h"
#endif

typedef enum { BITMAP_EXISTING, BITMAP_THRESHOLD, BITMAP_DIFFUSION } BitmapMethod;

typedef struct {
  GlimsEngine *engine;
  GeglBuffer *projection;
  const Babl *format;
  GlimsProgress *progress;
  guint components;
  BitmapMethod method;
  guint threshold;
  GlimsBitmapDiffusion diffusion;
  guint64 samples, total;
  gint64 last_service;
  gboolean cancelled;
} BitmapExport;

static void
bitmap_cancel (GimpProgress *progress, gpointer data)
{
  (void) progress;
  ((BitmapExport *) data)->cancelled = TRUE;
}

static bool
bitmap_continue (void *data)
{
  BitmapExport *state = data;
  gint64 now = g_get_monotonic_time ();
  if (now - state->last_service >= 10 * G_TIME_SPAN_MILLISECOND ||
      state->samples == state->total)
    {
      gimp_progress_set_value (GIMP_PROGRESS (state->progress),
                               (double) state->samples / state->total);
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

static bool
bitmap_read (void *data, uint32_t y, uint32_t x, uint32_t count, uint8_t *samples)
{
  BitmapExport *state = data;
  float pixels[GLIMS_BITMAP_PSD_CHUNK_PIXELS * 4];
  GeglRectangle area = { (gint) x, (gint) y, (gint) count, 1 };
  if (count == 1)
    {
      /* GEGL's one-pixel shortcut can bypass projection tile validation. */
      GimpTileHandlerValidate *validate = gimp_tile_handler_validate_get_assigned (state->projection);
      if (validate)
        gimp_tile_handler_validate_validate (validate, state->projection, &area, TRUE, FALSE);
    }
  gegl_buffer_get (state->projection, &area, 1.0, state->format, pixels,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  if (state->method == BITMAP_DIFFUSION)
    {
      float values[GLIMS_BITMAP_PSD_CHUNK_PIXELS];
      gboolean valid = TRUE;
      for (uint32_t i = 0; i < count; i++)
        {
          float *p = pixels + i * state->components;
          values[i] = p[0];
          valid = valid && p[state->components - 1] == 1.0f;
        }
      if (!valid || !glims_bitmap_diffusion_apply (&state->diffusion, y, x, count, values, samples))
        memset (samples, 127, count); /* serializer reports invalid pixel */
    }
  else
    for (uint32_t i = 0; i < count; i++)
      {
        float *p = pixels + i * state->components;
        gboolean opaque = p[state->components - 1] == 1.0f;
        if (state->method == BITMAP_THRESHOLD)
          {
            gboolean valid = opaque && isfinite (p[0]) && p[0] >= 0.0f && p[0] <= 1.0f;
            guint value = valid ? (guint) floorf (p[0] * 255.0f + 0.5f) : 0;
            samples[i] = valid ? (value <= state->threshold ? 0 : 255) : 127;
          }
        else
          {
            gboolean binary = p[0] == 0.0f || p[0] == 1.0f;
            for (guint c = 1; c + 1 < state->components; c++) binary = binary && p[c] == p[0];
            samples[i] = binary && opaque ? (p[0] == 0.0f ? 0 : 255) : 127;
          }
      }
  state->samples += count;
  return true;
}

/* A duplicate can retain a monitored link, and an already queued update can
 * still run after its monitor is frozen. Refuse the whole class, including
 * hidden/nested/frozen links, until the export can capture it safely. */
static gboolean
bitmap_has_link_layer (GimpImage *image)
{
#if GIMP_CHECK_VERSION (3, 2, 0)
  GList *layers = gimp_image_get_layer_list (image);
  gboolean found = FALSE;
  for (GList *it = layers; it && !found; it = it->next)
    found = GIMP_IS_LINK_LAYER (it->data);
  g_list_free (layers);
  return found;
#else
  (void) image;
  return FALSE;
#endif
}

static GlimsStatus
bitmap_export (GlimsEngine *engine, GlimsImageID id, const char *path,
               BitmapMethod method, uint32_t threshold, char **error)
{
  if (error) *error = NULL;
  if (!path || !g_path_is_absolute (path) || (method == BITMAP_THRESHOLD && threshold > 255))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  const char *extension = strrchr (path, '.');
  if (!extension || g_ascii_strcasecmp (extension, ".psd"))
    {
      if (error) *error = strdup ("Bitmap export requires a .psd filename.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy || g_hash_table_size (engine->strokes) ||
      g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;
  GimpImageBaseType base = gimp_image_get_base_type (open->image);
  if (open->component_document || (base != GIMP_GRAY && base != GIMP_INDEXED))
    {
      if (error) *error = strdup ("Bitmap PSD export requires a grayscale or indexed document.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (method != BITMAP_EXISTING && base != GIMP_GRAY)
    {
      if (error) *error = strdup ("Bitmap conversion requires a grayscale document.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (bitmap_has_link_layer (open->image))
    {
      if (error) *error = strdup ("Bitmap PSD export cannot safely snapshot linked layers. Remove them from a copy before exporting.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  GlimsBitmapPsdSpec spec = { (uint32_t) gimp_image_get_width (open->image),
                              (uint32_t) gimp_image_get_height (open->image) };
  uint64_t size;
  if (glims_bitmap_psd_size (&spec, &size) != GLIMS_BITMAP_PSD_OK)
    {
      if (error) *error = strdup ("Bitmap PSD dimensions must be between 1 and 30000 pixels.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* A private image freezes layer content before cooperative dispatch. Its
   * projection renders lazily; no pointers borrowed from the live document
   * survive the first cancellation/service callback. */
  engine->busy++;
  GimpImage *copy = gimp_image_duplicate (open->image);
  if (!copy) { engine->busy--; return GLIMS_STATUS_FAILED; }
  gimp_pickable_flush (GIMP_PICKABLE (copy));
  GimpProjection *projection = gimp_image_get_projection (copy);
  GeglBuffer *buffer = gimp_pickable_get_buffer (GIMP_PICKABLE (projection));
  gimp_projection_stop_rendering (projection);
  gimp_projection_flush_now (projection, FALSE);
  const Babl *projection_format = gimp_projectable_get_format (GIMP_PROJECTABLE (copy));
  const Babl *space = projection_format ? babl_format_get_space (projection_format) : NULL;
  const char *name = method != BITMAP_EXISTING ? "Y'A float" : base == GIMP_GRAY ? "YA float" : "RGBA float";
  const Babl *format = space ? babl_format_with_space (name, space) : babl_format (name);
  if (!buffer || !format)
    { g_object_unref (copy); engine->busy--; return GLIMS_STATUS_FAILED; }
  BitmapExport state = { .engine = engine, .projection = buffer, .format = format,
                         .components = base == GIMP_GRAY ? 2u : 4u,
                         .method = method, .threshold = threshold,
                         .total = (guint64) spec.width * spec.height };
  if (method == BITMAP_DIFFUSION && !glims_bitmap_diffusion_begin (&state.diffusion, spec.width, spec.height))
    { g_object_unref (copy); engine->busy--; return GLIMS_STATUS_FAILED; }
  state.progress = glims_progress_new (engine);
  engine->progress = state.progress;
  gulong cancel = g_signal_connect (state.progress, "cancel", G_CALLBACK (bitmap_cancel), &state);
  gimp_progress_start (GIMP_PROGRESS (state.progress), TRUE, "Exporting Bitmap PSD");
  int os_error = 0;
  GlimsBitmapPsdFileStatus result = glims_bitmap_psd_write_file (
    &spec, bitmap_read, &state, path, bitmap_continue, &state, &os_error);
  g_signal_handler_disconnect (state.progress, cancel);
  gimp_progress_end (GIMP_PROGRESS (state.progress));
  engine->progress = NULL;
  g_object_unref (state.progress);
  glims_bitmap_diffusion_end (&state.diffusion);
  g_object_unref (copy);
  engine->busy--;

  if (result == GLIMS_BITMAP_PSD_FILE_OK) return GLIMS_STATUS_OK;
  if (result == GLIMS_BITMAP_PSD_FILE_CANCELLED) return GLIMS_STATUS_CANCELLED;
  if (error)
    {
      if (result == GLIMS_BITMAP_PSD_FILE_INVALID_PIXEL)
        *error = strdup (method != BITMAP_EXISTING
          ? "Bitmap conversion requires fully opaque grayscale pixels with finite values from 0 to 1."
          : "Bitmap PSD requires fully opaque black and white pixels. Convert a copy before exporting.");
      else if (os_error)
        *error = strdup (g_strerror (os_error));
      else
        *error = strdup ("Bitmap PSD could not be exported. The destination was not replaced.");
    }
  return result == GLIMS_BITMAP_PSD_FILE_INVALID ? GLIMS_STATUS_INVALID_ARGUMENT : GLIMS_STATUS_FAILED;
}

GlimsStatus
glims_image_export_bitmap_psd (GlimsEngine *engine, GlimsImageID id,
                               const char *path, char **error)
{
  return bitmap_export (engine, id, path, BITMAP_EXISTING, 0, error);
}

GlimsStatus
glims_image_export_bitmap_threshold_psd (GlimsEngine *engine, GlimsImageID id,
                                         const char *path, uint32_t threshold,
                                         char **error)
{
  return bitmap_export (engine, id, path, BITMAP_THRESHOLD, threshold, error);
}

GlimsStatus
glims_image_export_bitmap_diffusion_psd (GlimsEngine *engine, GlimsImageID id,
                                         const char *path, char **error)
{
  return bitmap_export (engine, id, path, BITMAP_DIFFUSION, 0, error);
}

/* Explicit pixel-only converted CMYK copies. Source storage and history are
 * never replaced. The result stays private until all rows and cancellation
 * pass. */
#include "engine-private.h"
#include "component-document.h"
#include "plate-storage.h"
#include "copy-admission.h"
#include "cmyk-transform.h"

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "gegl/gimp-babl.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-quick-mask.h"
#include "core/gimpimage-undo.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpprogress.h"

#define CMYK_COPY_ROW 4096

_Static_assert (CMYK_COPY_ROW <= GLIMS_CMYK_TRANSFORM_MAX_PIXELS,
                "copy chunks must fit the CMYK transform's bound");

typedef struct {
  GlimsEngine *engine;
  GlimsProgress *progress;
  gboolean cancelled;
  guint64 completed, total;
  gint64 last_service;
} CmykCopyProgress;

typedef struct {
  float rgba[CMYK_COPY_ROW * 4];
  float rgb[CMYK_COPY_ROW * 3];
  float cmyk[CMYK_COPY_ROW * 4];
  float plane[CMYK_COPY_ROW];
} CmykCopyRow;

static GlimsStatus
refuse_copy (GlimsStatus status, char **error, const char *message)
{
  if (error) *error = g_strdup (message);
  return status;
}

static void
cancel_copy (GimpProgress *progress, gpointer data)
{
  ((CmykCopyProgress *) data)->cancelled = TRUE;
}

static gboolean
continue_copy (CmykCopyProgress *state)
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

static gboolean
copy_settings (const GlimsCmykCopySettings *input, GlimsCmykCopySettings *out)
{
  if (!input) return FALSE;
  uint32_t size;
  memcpy (&size, input, sizeof size);
  const size_t required = offsetof (GlimsCmykCopySettings, profile_length) +
                          sizeof out->profile_length;
  if (size < required) return FALSE;
  memcpy (out, input, required);
  return (out->destination_mode == GLIMS_COLOR_MODE_CMYK ||
          out->destination_mode == GLIMS_COLOR_MODE_RGB) &&
         (out->output_component == GLIMS_COLOR_COMPONENT_U8 ||
          out->output_component == GLIMS_COLOR_COMPONENT_U16 ||
          out->output_component == GLIMS_COLOR_COMPONENT_FLOAT);
}

/* U8/U16 RGB output stores standard sRGB; FLOAT keeps linear sRGB, like
 * slot197's RGB output. The layer stays opaque without an alpha channel. */
static GimpImage *
prepare_rgb (GlimsEngine *engine, gint width, gint height, uint32_t component,
             char **error)
{
  GimpPrecision precision =
    component == GLIMS_COLOR_COMPONENT_U8 ? GIMP_PRECISION_U8_NON_LINEAR :
    component == GLIMS_COLOR_COMPONENT_U16 ? GIMP_PRECISION_U16_NON_LINEAR :
    GIMP_PRECISION_FLOAT_LINEAR;
  GimpImage *image = gimp_create_image (engine->gimp, width, height, GIMP_RGB,
                                       precision, FALSE);
  if (!image) return NULL;
  gimp_image_undo_disable (image);
  GimpColorProfile *profile = component == GLIMS_COLOR_COMPONENT_FLOAT
    ? gimp_color_profile_new_rgb_srgb_linear ()
    : gimp_color_profile_new_rgb_srgb ();
  GError *gerror = NULL;
  if (!profile || !gimp_image_set_color_profile (image, profile, &gerror))
    {
      g_clear_object (&profile);
      g_object_unref (image);
      glims_fail (error, gerror, "The RGB copy profile could not be prepared.");
      return NULL;
    }
  g_object_unref (profile);
  /* Native storage omits redundant builtin ICC bytes. Precision and the
   * effective builtin profile together retain the exact interpretation. */
  GimpLayer *layer = gimp_layer_new (image, width, height,
                                    gimp_image_get_layer_format (image, FALSE),
                                    "Converted appearance", GIMP_OPACITY_OPAQUE,
                                    GIMP_LAYER_MODE_NORMAL);
  if (!layer || !gimp_image_add_layer (image, layer, NULL, 0, FALSE))
    {
      if (layer) g_object_unref (layer);
      g_object_unref (image);
      refuse_copy (GLIMS_STATUS_FAILED, error, "The RGB copy layer could not be prepared.");
      return NULL;
    }
  gimp_image_undo_enable (image);
  gimp_image_clean_all (image);
  return image;
}

static GlimsStatus
convert_cmyk_copy (GlimsEngine *engine, GlimsImageID id,
                   const GlimsCmykCopySettings *input,
                   GlimsImageID *result, char **error)
{
  if (result) *result = 0;
  if (error) *error = NULL;
  GlimsCmykCopySettings settings = { 0 };
  if (!result || !copy_settings (input, &settings))
    return refuse_copy (GLIMS_STATUS_INVALID_ARGUMENT, error,
                        "Choose a CMYK or RGB copy in 8-bit, 16-bit or 32-bit float precision.");
  gboolean to_cmyk = settings.destination_mode == GLIMS_COLOR_MODE_CMYK;
  if (to_cmyk && (!settings.profile_icc || !settings.profile_length))
    return refuse_copy (GLIMS_STATUS_INVALID_ARGUMENT, error,
                        "A CMYK copy requires a CMYK ICC profile.");
  if (!to_cmyk && (settings.profile_icc || settings.profile_length))
    return refuse_copy (GLIMS_STATUS_INVALID_ARGUMENT, error,
                        "An RGB copy takes its profile from the CMYK document; pass no profile.");
  if (!engine) return GLIMS_STATUS_NOT_RUNNING;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (g_hash_table_size (engine->filters) || engine->progress ||
      !gimp_image_undo_is_enabled (open->image) ||
      gimp_image_get_undo_group_count (open->image))
    return refuse_copy (GLIMS_STATUS_BUSY, error,
                        "Finish the current edit before creating a converted copy.");
  if (gimp_image_get_floating_selection (open->image) ||
      gimp_image_get_quick_mask_state (open->image))
    return refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                        "Anchor the floating selection and leave Quick Mask before creating a converted copy.");

  GlimsPlateStorage source_storage;
  if (to_cmyk)
    {
      if (copy_admission_has_link_layer (open->image))
        return refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                            "Replace linked layers with ordinary pixel layers before creating a CMYK copy. A queued linked-file update can change the canvas during conversion.");
      if (open->component_document || !copy_admission_qualified_rgb (open->image))
        return refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                            "A CMYK copy requires an 8-bit, 16-bit or 32-bit RGB image using standard sRGB or linear sRGB. Convert a custom profile to sRGB first.");
    }
  else if (!open->component_document || open->component_mode != GLIMS_PLATE_MODE_CMYK ||
           !glims_plate_storage_read_open (open, &source_storage) ||
           source_storage.map.mode != GLIMS_PLATE_MODE_CMYK || source_storage.map.count != 4 ||
           !source_storage.profile || !source_storage.profile_size)
    return refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                        "An RGB copy requires a valid native CMYK document.");

  gint width = gimp_image_get_width (open->image), height = gimp_image_get_height (open->image);
  GimpImage *source = g_object_ref (open->image), *candidate = NULL;
  GeglBuffer *inputs[4] = { NULL }, *outputs[4] = { NULL };
  const Babl *read_format = NULL;
  GlimsCmykTransform *transform = NULL;
  CmykCopyRow *row = g_try_new (CmykCopyRow, 1);
  if (!row)
    {
      status = refuse_copy (GLIMS_STATUS_FAILED, error, "There is not enough memory for the color conversion.");
      goto cleanup;
    }

  /* Preparation has no event dispatch. It finishes before busy is acquired;
   * no public image ID exists until the final adoption below. */
  if (to_cmyk)
    {
      GError *gerror = NULL;
      transform = glims_cmyk_dest_transform_new (settings.profile_icc,
                                                 settings.profile_length, &gerror);
      if (!transform)
        {
          status = glims_fail (error, gerror, "The CMYK copy profile could not be used.");
          goto cleanup;
        }
      status = glims_component_image_prepare (engine, width, height,
                 settings.output_component, 4, GLIMS_PLATE_MODE_CMYK,
                 settings.profile_icc, settings.profile_length,
                 &candidate, error);
      if (status != GLIMS_STATUS_OK) goto cleanup;
      GlimsPlateStorage destination;
      if (glims_plate_storage_read (candidate, &destination) != GLIMS_PLATE_STORAGE_VALID)
        {
          status = refuse_copy (GLIMS_STATUS_FAILED, error, "The CMYK copy storage could not be prepared.");
          goto cleanup;
        }
      for (guint axis = 0; axis < 4; axis++)
        outputs[axis] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (destination.planes[axis])));
      GeglBuffer *projection = NULL;
      status = glims_projection_prepare_read (open, 1.0, (GlimsRect) { 0, 0, width, height }, &projection);
      if (status != GLIMS_STATUS_OK) goto cleanup;
      inputs[0] = g_object_ref (projection);
      const Babl *format = gegl_buffer_get_format (projection);
      if (!format || !babl_format_has_alpha (format) || babl_format_get_n_components (format) != 4 ||
          !babl_format_get_space (format))
        {
          status = refuse_copy (GLIMS_STATUS_UNSUPPORTED, error, "The RGB canvas has an unsupported pixel format.");
          goto cleanup;
        }
      /* Own-space straight linear float: no display/U8 path or second TRC. */
      read_format = babl_format_with_space ("RGBA float", babl_format_get_space (format));
    }
  else
    {
      GError *gerror = NULL;
      transform = glims_cmyk_transform_new (source_storage.profile,
                                              source_storage.profile_size, &gerror);
      if (!transform)
        {
          status = glims_fail (error, gerror, "The document's CMYK profile could not be used.");
          goto cleanup;
        }
      candidate = prepare_rgb (engine, width, height, settings.output_component, error);
      if (!candidate) { status = GLIMS_STATUS_FAILED; goto cleanup; }
      /* The iterator is the image's own layer list; it is not freed. */
      GList *layers = gimp_image_get_layer_iter (candidate);
      outputs[0] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (layers->data)));
      for (guint axis = 0; axis < 4; axis++)
        inputs[axis] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (source_storage.planes[axis])));
    }
  /* Candidate metadata and pixels are construction, not user edits. */
  gimp_image_undo_disable (candidate);
  gdouble xres, yres;
  gimp_image_get_resolution (source, &xres, &yres);
  gimp_image_set_resolution (candidate, xres, yres);
  gimp_image_set_unit (candidate, gimp_image_get_unit (source));

  engine->busy++;
  CmykCopyProgress progress = { .engine = engine, .total = (guint64) width * height };
  progress.progress = glims_progress_new (engine);
  engine->progress = progress.progress;
  gulong handler = g_signal_connect (progress.progress, "cancel", G_CALLBACK (cancel_copy), &progress);
  gimp_progress_start (GIMP_PROGRESS (progress.progress), TRUE,
                        to_cmyk ? "Creating CMYK copy" : "Creating RGB copy");
  status = GLIMS_STATUS_OK;
  for (gint y = 0; status == GLIMS_STATUS_OK && y < height; y++)
    for (gint x = 0; status == GLIMS_STATUS_OK && x < width; )
      {
        if (!continue_copy (&progress)) { status = GLIMS_STATUS_CANCELLED; break; }
        gint count = MIN (CMYK_COPY_ROW, width - x);
        GeglRectangle area = { x, y, count, 1 };
        if (to_cmyk)
          {
            /* A two-row read for a one-pixel tail avoids GEGL's cached 1x1
             * shortcut, which can bypass projection tile validation. */
            GeglRectangle read_area = { x, y, count, count == 1 ? 2 : 1 };
            gegl_buffer_get (inputs[0], &read_area, 1.0, read_format, row->rgba,
                              GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
            for (gint i = 0; i < count; i++)
              {
                if (row->rgba[4 * i + 3] != 1.0f)
                  {
                    status = refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                              "CMYK has no transparency plane. Create an opaque RGB canvas before making a CMYK copy.");
                    break;
                  }
                memcpy (row->rgb + 3 * i, row->rgba + 4 * i, 3 * sizeof (float));
              }
            if (status != GLIMS_STATUS_OK) break;
            GError *gerror = NULL;
            if (!glims_cmyk_dest_transform_pixels (transform, row->rgb, count,
                                                    row->cmyk, &gerror))
              {
                status = glims_fail (error, gerror,
                                     "The canvas contains color values that cannot be represented in this CMYK copy.");
                break;
              }
            for (guint axis = 0; axis < 4; axis++)
              {
                for (gint i = 0; i < count; i++) row->plane[i] = row->cmyk[4 * i + axis];
                gegl_buffer_set (outputs[axis], &area, 0, babl_format ("Y float"),
                                  row->plane, GEGL_AUTO_ROWSTRIDE);
              }
          }
        else
          {
            for (guint axis = 0; axis < 4; axis++)
              {
                gegl_buffer_get (inputs[axis], &area, 1.0, babl_format ("Y float"),
                                  row->plane, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
                for (gint i = 0; i < count; i++) row->cmyk[4 * i + axis] = row->plane[i];
              }
            GError *gerror = NULL;
            if (!glims_cmyk_transform_pixels (transform, row->cmyk, count,
                                              row->rgba, &gerror))
              {
                status = glims_fail (error, gerror,
                                     "The CMYK document contains ink values that cannot be represented in this RGB copy.");
                break;
              }
            for (gint i = 0; i < count; i++)
              memcpy (row->rgb + 3 * i, row->rgba + 4 * i, 3 * sizeof (float));
            /* Float output stores linear sRGB directly; integer output
             * encodes to standard sRGB through babl. */
            gegl_buffer_set (outputs[0], &area, 0, babl_format ("RGB float"),
                              row->rgb, GEGL_AUTO_ROWSTRIDE);
          }
        progress.completed += count;
        x += count;
      }
  if (status == GLIMS_STATUS_OK && !continue_copy (&progress)) status = GLIMS_STATUS_CANCELLED;
  g_signal_handler_disconnect (progress.progress, handler);
  gimp_progress_end (GIMP_PROGRESS (progress.progress));
  engine->progress = NULL;
  g_object_unref (progress.progress);
  if (status == GLIMS_STATUS_OK)
    {
      gimp_image_undo_enable (candidate);
      gimp_image_clean_all (candidate);
      status = glims_adopt_image (engine, candidate, result);
      if (status == GLIMS_STATUS_OK) candidate = NULL;
      else refuse_copy (status, error, "The converted copy could not be opened.");
    }
  engine->busy--;

cleanup:
  for (guint i = 0; i < 4; i++)
    {
      g_clear_object (&inputs[i]);
      g_clear_object (&outputs[i]);
    }
  g_clear_object (&candidate);
  g_object_unref (source);
  glims_cmyk_transform_free (transform);
  g_free (row);
  return status;
}

GlimsStatus
glims_image_convert_cmyk_copy (GlimsEngine *engine, GlimsImageID id,
                               const GlimsCmykCopySettings *settings,
                               GlimsImageID *result, char **error)
{
  return convert_cmyk_copy (engine, id, settings, result, error);
}

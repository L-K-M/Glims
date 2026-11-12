/* Explicit pixel-only converted copies. Source storage and history are never
 * replaced. The result stays private until all rows and cancellation pass. */
#include "engine-private.h"
#include "component-document.h"
#include "plate-storage.h"
#include "lab-samples.h"
#include "lab-transform.h"

#include <math.h>
#include <stddef.h>
#include <string.h>
#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
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
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplinklayer.h"
#endif
#include "core/gimpprogress.h"

#define LAB_COPY_ROW 4096

typedef struct {
  GlimsEngine *engine;
  GlimsProgress *progress;
  gboolean cancelled;
  guint64 completed, total;
  gint64 last_service;
} LabCopyProgress;

typedef struct {
  float rgba[LAB_COPY_ROW * 4];
  float rgb[LAB_COPY_ROW * 3];
  float lab[LAB_COPY_ROW * 3];
  float plane[LAB_COPY_ROW];
  double decoded[LAB_COPY_ROW];
} LabCopyRow;

static GlimsStatus
refuse_copy (GlimsStatus status, char **error, const char *message)
{
  if (error) *error = g_strdup (message);
  return status;
}

static void
cancel_copy (GimpProgress *progress, gpointer data)
{
  ((LabCopyProgress *) data)->cancelled = TRUE;
}

static gboolean
continue_copy (LabCopyProgress *state)
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
copy_settings (const GlimsLabCopySettings *input, GlimsLabCopySettings *out)
{
  if (!input) return FALSE;
  uint32_t size;
  memcpy (&size, input, sizeof size);
  const size_t required = offsetof (GlimsLabCopySettings, output_component) +
                          sizeof out->output_component;
  if (size < required) return FALSE;
  memcpy (out, input, required);
  return (out->destination_mode == GLIMS_COLOR_MODE_LAB ||
          out->destination_mode == GLIMS_COLOR_MODE_RGB) &&
         out->content == GLIMS_LAB_COPY_MERGED_CANVAS &&
         out->output_component == GLIMS_COLOR_COMPONENT_FLOAT;
}

/* Native queued link updates survive freezing a monitor and bypass facade
 * busy gates. Refuse the class, including frozen, nested and hidden layers. */
static gboolean
has_link_layer (GimpImage *image)
{
#if GIMP_CHECK_VERSION (3, 2, 0)
  GList *layers = gimp_image_get_layer_list (image);
  gboolean found = FALSE;
  for (GList *it = layers; it && !found; it = it->next)
    if (GIMP_IS_LINK_LAYER (it->data)) found = TRUE;
  g_list_free (layers);
  return found;
#else
  (void) image;
  return FALSE;
#endif
}

static gboolean
qualified_rgb (GimpImage *image)
{
  if (gimp_image_get_base_type (image) != GIMP_RGB) return FALSE;
  GimpComponentType component = gimp_babl_component_type (gimp_image_get_precision (image));
  if (component != GIMP_COMPONENT_TYPE_U8 && component != GIMP_COMPONENT_TYPE_U16 &&
      component != GIMP_COMPONENT_TYPE_FLOAT) return FALSE;
  GimpColorProfile *profile = gimp_image_get_color_profile (image);
  if (!profile) profile = gimp_image_get_builtin_color_profile (image);
  GimpColorProfile *srgb = gimp_color_profile_new_rgb_srgb ();
  GimpColorProfile *linear = gimp_color_profile_new_rgb_srgb_linear ();
  gboolean valid = profile && srgb && linear &&
    (gimp_color_profile_is_equal (profile, srgb) ||
     gimp_color_profile_is_equal (profile, linear));
  g_clear_object (&srgb);
  g_clear_object (&linear);
  return valid;
}

static GimpImage *
prepare_rgb (GlimsEngine *engine, gint width, gint height, char **error)
{
  GimpImage *image = gimp_create_image (engine->gimp, width, height, GIMP_RGB,
                                       GIMP_PRECISION_FLOAT_LINEAR, FALSE);
  if (!image) return NULL;
  gimp_image_undo_disable (image);
  GimpColorProfile *profile = gimp_color_profile_new_rgb_srgb_linear ();
  GError *gerror = NULL;
  if (!profile || !gimp_image_set_color_profile (image, profile, &gerror))
    {
      g_clear_object (&profile);
      g_object_unref (image);
      glims_fail (error, gerror, "The linear RGB copy profile could not be prepared.");
      return NULL;
    }
  g_object_unref (profile);
  /* Native storage omits redundant builtin ICC bytes. Float-linear precision
   * and the effective builtin profile together retain the exact interpretation. */
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

GlimsStatus
glims_image_convert_lab_copy (GlimsEngine *engine, GlimsImageID id,
                               const GlimsLabCopySettings *input,
                               GlimsImageID *result, char **error)
{
  if (result) *result = 0;
  if (error) *error = NULL;
  GlimsLabCopySettings settings = { 0 };
  if (!result || !copy_settings (input, &settings))
    return refuse_copy (GLIMS_STATUS_INVALID_ARGUMENT, error,
                        "Choose a merged canvas copy in 32-bit Lab or linear RGB.");
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

  gboolean to_lab = settings.destination_mode == GLIMS_COLOR_MODE_LAB;
  GlimsPlateStorage source_storage;
  if (to_lab)
    {
      if (has_link_layer (open->image))
        return refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                            "Replace linked layers with ordinary pixel layers before creating a Lab copy. A queued linked-file update can change the canvas during conversion.");
      if (open->component_document || !qualified_rgb (open->image))
        return refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                            "A Lab copy requires an 8-bit, 16-bit or 32-bit RGB image using standard sRGB or linear sRGB. Convert a custom profile to sRGB first.");
    }
  else if (!open->component_document || open->component_mode != GLIMS_PLATE_MODE_LAB ||
           !glims_plate_storage_read_open (open, &source_storage) ||
           source_storage.map.mode != GLIMS_PLATE_MODE_LAB || source_storage.map.count != 3)
    return refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                        "An RGB copy requires a valid native Lab document.");

  gint width = gimp_image_get_width (open->image), height = gimp_image_get_height (open->image);
  GimpImage *source = g_object_ref (open->image), *candidate = NULL;
  GeglBuffer *inputs[3] = { NULL }, *outputs[3] = { NULL };
  const Babl *read_format = NULL, *write_format = NULL;
  GlimsLabFormat lab_format = GLIMS_LAB_FORMAT_FLOAT;
  GlimsLabTransform *transform = glims_lab_transform_new ();
  LabCopyRow *row = g_try_new (LabCopyRow, 1);
  if (!transform || !row)
    {
      status = refuse_copy (GLIMS_STATUS_FAILED, error, "There is not enough memory for the color conversion.");
      goto cleanup;
    }

  /* Preparation has no event dispatch. It finishes before busy is acquired;
   * no public image ID exists until the final adoption below. */
  if (to_lab)
    {
      status = glims_component_image_prepare (engine, width, height,
                 GLIMS_COLOR_COMPONENT_FLOAT, 3, GLIMS_PLATE_MODE_LAB,
                 NULL, 0, &candidate, error);
      if (status != GLIMS_STATUS_OK) goto cleanup;
      GlimsPlateStorage destination;
      if (glims_plate_storage_read (candidate, &destination) != GLIMS_PLATE_STORAGE_VALID)
        {
          status = refuse_copy (GLIMS_STATUS_FAILED, error, "The Lab copy storage could not be prepared.");
          goto cleanup;
        }
      for (guint axis = 0; axis < 3; axis++)
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
      candidate = prepare_rgb (engine, width, height, error);
      if (!candidate) { status = GLIMS_STATUS_FAILED; goto cleanup; }
      GList *layers = gimp_image_get_layer_iter (candidate);
      outputs[0] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (layers->data)));
      write_format = gegl_buffer_get_format (outputs[0]);
      for (guint axis = 0; axis < 3; axis++)
        inputs[axis] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (source_storage.planes[axis])));
      lab_format = source_storage.map.storage == GLIMS_PLATE_STORAGE_U8 ? GLIMS_LAB_FORMAT_U8 :
                   source_storage.map.storage == GLIMS_PLATE_STORAGE_U16 ? GLIMS_LAB_FORMAT_U16 :
                   GLIMS_LAB_FORMAT_FLOAT;
    }
  /* Candidate metadata and pixels are construction, not user edits. */
  gimp_image_undo_disable (candidate);
  gdouble xres, yres;
  gimp_image_get_resolution (source, &xres, &yres);
  gimp_image_set_resolution (candidate, xres, yres);

  engine->busy++;
  LabCopyProgress progress = { .engine = engine, .total = (guint64) width * height };
  progress.progress = glims_progress_new (engine);
  engine->progress = progress.progress;
  gulong handler = g_signal_connect (progress.progress, "cancel", G_CALLBACK (cancel_copy), &progress);
  gimp_progress_start (GIMP_PROGRESS (progress.progress), TRUE,
                        to_lab ? "Creating Lab copy" : "Creating linear RGB copy");
  status = GLIMS_STATUS_OK;
  for (gint y = 0; status == GLIMS_STATUS_OK && y < height; y++)
    for (gint x = 0; status == GLIMS_STATUS_OK && x < width; x += LAB_COPY_ROW)
      {
        if (!continue_copy (&progress)) { status = GLIMS_STATUS_CANCELLED; break; }
        gint count = MIN (LAB_COPY_ROW, width - x);
        GeglRectangle area = { x, y, count, 1 };
        if (to_lab)
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
                              "Lab has no transparency plane. Create an opaque RGB canvas before making a Lab copy.");
                    break;
                  }
                memcpy (row->rgb + 3 * i, row->rgba + 4 * i, 3 * sizeof (float));
              }
            if (status != GLIMS_STATUS_OK) break;
            if (!glims_lab_transform_from_linear_rgb (transform, row->rgb, count, row->lab))
              {
                status = refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                                      "The canvas contains color values that cannot be represented in this Lab copy.");
                break;
              }
            for (guint axis = 0; axis < 3; axis++)
              {
                for (gint i = 0; i < count; i++) row->plane[i] = row->lab[3 * i + axis];
                gegl_buffer_set (outputs[axis], &area, 0, gegl_buffer_get_format (outputs[axis]),
                                  row->plane, GEGL_AUTO_ROWSTRIDE);
              }
          }
        else
          {
            for (guint axis = 0; axis < 3; axis++)
              {
                gegl_buffer_get (inputs[axis], &area, 1.0, gegl_buffer_get_format (inputs[axis]),
                                  row->plane, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
                if (!glims_lab_decode_row ((GlimsLabRole) axis, lab_format, count,
                                            row->plane, row->decoded))
                  { status = GLIMS_STATUS_UNSUPPORTED; break; }
                for (gint i = 0; i < count; i++) row->lab[3 * i + axis] = (float) row->decoded[i];
              }
            if (status != GLIMS_STATUS_OK ||
                !glims_lab_transform_pixels (transform, row->lab, count, row->rgba))
              {
                status = refuse_copy (GLIMS_STATUS_UNSUPPORTED, error,
                                      "The Lab document contains color values that cannot be represented in this RGB copy.");
                break;
              }
            for (gint i = 0; i < count; i++)
              memcpy (row->rgb + 3 * i, row->rgba + 4 * i, 3 * sizeof (float));
            gegl_buffer_set (outputs[0], &area, 0, write_format, row->rgb, GEGL_AUTO_ROWSTRIDE);
          }
        progress.completed += count;
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
  for (guint i = 0; i < 3; i++)
    {
      g_clear_object (&inputs[i]);
      g_clear_object (&outputs[i]);
    }
  g_clear_object (&candidate);
  g_object_unref (source);
  glims_lab_transform_free (transform);
  g_free (row);
  return status;
}

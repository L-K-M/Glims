/* Captured filter-input histograms. Native objects stay on the engine thread;
 * exported bins are independent heap arrays and keep native signed weights. */
#include "filter-histogram.h"
#include "levels-config.h"
#include "curves-config.h"

#include <math.h>
#include <string.h>

#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawable-histogram.h"
#include "core/gimpfilter.h"
#include "core/gimpchannel.h"
#include "core/gimpimage.h"
#include "core/gimphistogram.h"
#include "core/gimpitem.h"

static const struct {
  GimpHistogramChannel native;
  uint32_t owned;
} channels[] = {
  { GIMP_HISTOGRAM_VALUE, GLIMS_HISTOGRAM_VALUE },
  { GIMP_HISTOGRAM_RED, GLIMS_HISTOGRAM_RED },
  { GIMP_HISTOGRAM_GREEN, GLIMS_HISTOGRAM_GREEN },
  { GIMP_HISTOGRAM_BLUE, GLIMS_HISTOGRAM_BLUE },
  { GIMP_HISTOGRAM_ALPHA, GLIMS_HISTOGRAM_ALPHA },
  { GIMP_HISTOGRAM_LUMINANCE, GLIMS_HISTOGRAM_LUMINANCE }
};

static GlimsStatus
histogram_error (GlimsStatus status, char **error, const char *message)
{
  if (error) *error = strdup (message);
  return status;
}

static uint32_t
own_trc (GimpTRCType trc)
{
  switch (trc) {
    case GIMP_TRC_LINEAR: return GLIMS_COLOR_TRC_LINEAR;
    case GIMP_TRC_NON_LINEAR: return GLIMS_COLOR_TRC_NONLINEAR;
    case GIMP_TRC_PERCEPTUAL: return GLIMS_COLOR_TRC_PERCEPTUAL;
    default: return GLIMS_COLOR_TRC_UNKNOWN;
  }
}

static double **
bins_at (GlimsHistogramSnapshot *out, guint index)
{
  switch (index) {
    case 0: return &out->value;
    case 1: return &out->red;
    case 2: return &out->green;
    case 3: return &out->blue;
    case 4: return &out->alpha;
    default: return &out->luminance;
  }
}

void
glims_histogram_snapshot_clear (GlimsHistogramSnapshot *out)
{
  if (!out || out->struct_size < sizeof *out) return;
  out->trc = GLIMS_COLOR_TRC_UNKNOWN;
  out->bin_count = out->channels = 0;
  for (guint i = 0; i < G_N_ELEMENTS (channels); i++) *bins_at (out, i) = NULL;
}

void
glims_histogram_snapshot_free (GlimsHistogramSnapshot *out)
{
  if (!out || out->struct_size < sizeof *out) return;
  for (guint i = 0; i < G_N_ELEMENTS (channels); i++) g_free (*bins_at (out, i));
  glims_histogram_snapshot_clear (out);
}

static GlimsStatus
validate_histogram (GimpHistogram *histogram, char **error)
{
  gint bins = gimp_histogram_n_bins (histogram);
  gint components = gimp_histogram_n_components (histogram);
  uint32_t expected = GLIMS_HISTOGRAM_VALUE;

  if (bins < 0 || components < 0 || components > 4 || (bins == 0) != (components == 0))
    return histogram_error (GLIMS_STATUS_FAILED, error, "The native input histogram has an invalid shape.");
  if ((guint) bins > GLIMS_HISTOGRAM_MAX_BINS)
    return histogram_error (GLIMS_STATUS_UNSUPPORTED, error, "Input histograms support up to 4096 bins per channel.");
  if (bins != 0 && bins != 256 && bins != 1024)
    return histogram_error (GLIMS_STATUS_UNSUPPORTED, error, "The native input histogram has an unsupported bin count.");

  if (components >= 3)
    expected |= GLIMS_HISTOGRAM_RED | GLIMS_HISTOGRAM_GREEN |
                GLIMS_HISTOGRAM_BLUE | GLIMS_HISTOGRAM_LUMINANCE;
  if (components == 2 || components == 4) expected |= GLIMS_HISTOGRAM_ALPHA;

  /* Check every shape before reading any bins. A fresh empty histogram still
   * reports Value available, with zero bins and no allocated values. */
  for (guint i = 0; i < G_N_ELEMENTS (channels); i++) {
    gboolean present = gimp_histogram_has_channel (histogram, channels[i].native);
    if (present != ((expected & channels[i].owned) != 0))
      return histogram_error (GLIMS_STATUS_FAILED, error, "The native input histogram has inconsistent channels.");
  }
  for (guint i = 0; i < G_N_ELEMENTS (channels); i++) {
    if (!(expected & channels[i].owned)) continue;
    if (!isfinite (gimp_histogram_get_count (histogram, channels[i].native, 0, bins - 1)))
      return histogram_error (GLIMS_STATUS_FAILED, error, "The native input histogram has a nonfinite channel count.");
    for (gint bin = 0; bin < bins; bin++) {
      if (!isfinite (gimp_histogram_get_value (histogram, channels[i].native, bin)))
        return histogram_error (GLIMS_STATUS_FAILED, error, "The native input histogram has a nonfinite bin weight.");
    }
  }
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_input_histogram_native (GlimsEngine *engine, GlimsFilterID id,
                                     GimpHistogram **out_histogram,
                                     GlimsFilter **out_session,
                                     uint32_t *out_trc, char **error)
{
  GlimsFilter *session;
  GlimsStatus status;
  GObject *config = NULL;
  GimpHistogram *histogram;
  GimpTRCType trc = (GimpTRCType) -1;
  uint32_t owned_trc;

  if (out_histogram) *out_histogram = NULL;
  if (out_session) *out_session = NULL;
  if (out_trc) *out_trc = GLIMS_COLOR_TRC_UNKNOWN;
  if (!engine || !engine->filters || !out_histogram || !out_session || !out_trc)
    return histogram_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "An engine and complete histogram outputs are required.");

  session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  if (!session || !GIMP_IS_DRAWABLE (session->drawable) || !session->filter ||
      !gimp_item_is_attached (GIMP_ITEM (session->drawable)) ||
      gimp_item_get_image (GIMP_ITEM (session->drawable)) != session->image ||
      !gimp_drawable_has_filter (session->drawable, GIMP_FILTER (session->filter)))
    return GLIMS_STATUS_NOT_FOUND;
  if (session->existing &&
      !gimp_drawable_has_filter (session->drawable, GIMP_FILTER (session->existing)))
    return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;

  /* Read admission intentionally does not use the pixel-lock edit gate. Both
   * typed validators also check operation/config TRC coherence before work. */
  if (glims_levels_config_is_operation (session->operation)) {
    GlimsLevelsSettings checked = { .struct_size = sizeof checked };
    status = glims_levels_config_get (session->operation, &checked, error);
  } else if (glims_curves_config_is_operation (session->operation)) {
    status = glims_curves_config_validate (session->operation, error);
  } else {
    return histogram_error (GLIMS_STATUS_UNSUPPORTED, error, "Input histograms are only available for Levels and Curves.");
  }
  if (status != GLIMS_STATUS_OK) return status;

  /* The typed validation above establishes the config type and its enum
   * property. The object-valued property read supplies a temporary owned ref. */
  gegl_node_get (session->operation, "config", &config, NULL);
  if (!config)
    return histogram_error (GLIMS_STATUS_FAILED, error, "The filter has no input histogram configuration.");
  g_object_get (config, "trc", &trc, NULL);
  g_object_unref (config);
  owned_trc = own_trc (trc);
  if (owned_trc == GLIMS_COLOR_TRC_UNKNOWN)
    return histogram_error (GLIMS_STATUS_FAILED, error, "The filter has an invalid input histogram TRC.");

  histogram = gimp_histogram_new (trc);
  if (!histogram)
    return histogram_error (GLIMS_STATUS_FAILED, error, "The input histogram could not be created.");
  /* GIMP Levels tool initialization at 7addd2b77efb798bbdc4d2fb082e786a48478ced
   * reads this captured drawable before filters, weighted by image selection.
   * Use a fresh synchronous histogram: no previous values or async readiness. */
  gimp_drawable_calculate_histogram (session->drawable, histogram, FALSE);
  status = validate_histogram (histogram, error);
  if (status != GLIMS_STATUS_OK) {
    g_object_unref (histogram);
    return status;
  }
  *out_histogram = histogram;
  *out_session = session;
  *out_trc = owned_trc;
  return GLIMS_STATUS_OK;
}

/* Native shape, channel counts and all bin weights are fully validated
 * before allocating any exported arrays. Signed finite weights are kept.
 * Consumes `histogram`. */
static GlimsStatus
export_histogram (GimpHistogram *histogram, uint32_t trc,
                  GlimsHistogramSnapshot *out, char **error)
{
  GlimsHistogramSnapshot result = { .struct_size = sizeof result };

  result.trc = trc;
  result.bin_count = (uint32_t) gimp_histogram_n_bins (histogram);
  for (guint i = 0; i < G_N_ELEMENTS (channels); i++) {
    double **bins = bins_at (&result, i);
    if (!gimp_histogram_has_channel (histogram, channels[i].native)) continue;
    result.channels |= channels[i].owned;
    if (!result.bin_count) continue;
    *bins = g_try_new (double, result.bin_count);
    if (!*bins) {
      glims_histogram_snapshot_free (&result);
      g_object_unref (histogram);
      return histogram_error (GLIMS_STATUS_FAILED, error, "Memory could not be allocated for the complete input histogram.");
    }
    for (uint32_t bin = 0; bin < result.bin_count; bin++)
      (*bins)[bin] = gimp_histogram_get_value (histogram, channels[i].native, (gint) bin);
  }
  g_object_unref (histogram);
  result.struct_size = out->struct_size;
  *out = result; /* Known bytes only; preserve the caller's future tail. */
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_input_histogram (GlimsEngine *engine, GlimsFilterID id,
                              GlimsHistogramSnapshot *out, char **error)
{
  GimpHistogram *histogram = NULL;
  GlimsFilter *session = NULL;
  uint32_t trc;
  GlimsStatus status;

  if (!out || out->struct_size < sizeof *out)
    return histogram_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A full input histogram output is required.");
  glims_histogram_snapshot_clear (out);
  status = glims_filter_input_histogram_native (engine, id, &histogram, &session, &trc, error);
  if (status != GLIMS_STATUS_OK) return status;
  return export_histogram (histogram, trc, out, error);
}

/* Image > Histogram. Mirrors GIMP's Histogram dockable
 * (widgets/gimphistogrameditor.c): one drawable, its own TRC
 * (gimp_drawable_get_trc), visible non-destructive filters included, and
 * weighted by the image selection and the drawable's alpha. Read-only:
 * no undo, no dirty flag, no pixel-lock gate. */
GlimsStatus
glims_drawable_histogram (GlimsEngine *engine, GlimsImageID image_id,
                          GlimsItemID drawable_id,
                          GlimsHistogramSnapshot *out, char **error)
{
  GlimsOpenImage *open;
  GimpImage *image;
  GimpDrawable *drawable;
  GimpHistogram *histogram;
  GlimsStatus status;
  uint32_t trc;

  if (!out || out->struct_size < sizeof *out)
    return histogram_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A full histogram output is required.");
  glims_histogram_snapshot_clear (out);
  open = glims_lookup_image (engine, image_id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0)
    return histogram_error (GLIMS_STATUS_BUSY, error, "The image is busy; try the histogram again when it finishes.");
  image = open->image;

  if (drawable_id == 0) {
    GList *selected = gimp_image_get_selected_drawables (image);
    guint count = g_list_length (selected);

    drawable = count == 1 ? selected->data : NULL;
    g_list_free (selected);
    if (count == 0)
      return histogram_error (GLIMS_STATUS_FAILED, error, "Select a layer, mask or channel to show its histogram.");
    if (count > 1)
      return histogram_error (GLIMS_STATUS_FAILED, error, "More than one layer is selected; select one to show its histogram.");
  } else {
    drawable = glims_lookup_drawable (open, drawable_id);
    if (!drawable) return GLIMS_STATUS_NOT_FOUND;
  }
  if (drawable == GIMP_DRAWABLE (gimp_image_get_mask (image)))
    return histogram_error (GLIMS_STATUS_FAILED, error, "The selection itself has no histogram; select a layer, mask or channel.");

  trc = own_trc (gimp_drawable_get_trc (drawable));
  if (trc == GLIMS_COLOR_TRC_UNKNOWN)
    return histogram_error (GLIMS_STATUS_FAILED, error, "The drawable has an unsupported tone response.");
  histogram = gimp_histogram_new (gimp_drawable_get_trc (drawable));
  if (!histogram)
    return histogram_error (GLIMS_STATUS_FAILED, error, "The histogram could not be created.");
  gimp_drawable_calculate_histogram (drawable, histogram, TRUE);
  status = validate_histogram (histogram, error);
  if (status != GLIMS_STATUS_OK) {
    g_object_unref (histogram);
    return status;
  }
  return export_histogram (histogram, trc, out, error);
}

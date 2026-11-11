/* Owned Curves snapshots and immutable patches; native objects remain on the
 * serialized engine thread. Native duplicate recomputes Smooth tables, so a
 * private clone restores the admitted samples/identity before any edit. */
#include "curves-config.h"
#include "point-config-trc.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

#include "core/gimpcurve.h"
#include "core/gimpdata.h"
#include "core/gimpsettings.h"
#include "operations/gimpcurvesconfig.h"
#include "operations/gimpoperationcurves.h"
#include "operations/gimpoperationsettings.h"

static const GimpHistogramChannel channels[] = {
  GIMP_HISTOGRAM_VALUE, GIMP_HISTOGRAM_RED, GIMP_HISTOGRAM_GREEN,
  GIMP_HISTOGRAM_BLUE, GIMP_HISTOGRAM_ALPHA
};

static GlimsStatus
curves_error (GlimsStatus status, char **error, const char *message)
{
  if (error) *error = strdup (message);
  return status;
}

static GlimsPointConfigTRCSpec
curves_spec (void)
{
  return (GlimsPointConfigTRCSpec) { "gimp:curves", "Curves",
    GIMP_TYPE_OPERATION_CURVES, GIMP_TYPE_CURVES_CONFIG };
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

static gboolean
native_trc (uint32_t own, GimpTRCType *out)
{
  switch (own) {
    case GLIMS_COLOR_TRC_LINEAR: *out = GIMP_TRC_LINEAR; return TRUE;
    case GLIMS_COLOR_TRC_NONLINEAR: *out = GIMP_TRC_NON_LINEAR; return TRUE;
    case GLIMS_COLOR_TRC_PERCEPTUAL: *out = GIMP_TRC_PERCEPTUAL; return TRUE;
    default: return FALSE;
  }
}

static uint32_t
own_point_type (GimpCurvePointType type)
{
  switch (type) {
    case GIMP_CURVE_POINT_SMOOTH: return GLIMS_CURVE_POINT_SMOOTH;
    case GIMP_CURVE_POINT_CORNER: return GLIMS_CURVE_POINT_CORNER;
    default: return 0;
  }
}

static GimpCurvePointType
native_point_type (uint32_t type)
{
  return type == GLIMS_CURVE_POINT_CORNER ? GIMP_CURVE_POINT_CORNER : GIMP_CURVE_POINT_SMOOTH;
}

static gboolean
unit_value (double value)
{
  return isfinite (value) && value >= 0.0 && value <= 1.0;
}

static GimpCurve *
curve_at (const GimpCurvesConfig *config, guint index)
{
  G_STATIC_ASSERT (G_N_ELEMENTS (config->curve) == 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_VALUE >= 0 && GIMP_HISTOGRAM_VALUE < 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_RED >= 0 && GIMP_HISTOGRAM_RED < 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_GREEN >= 0 && GIMP_HISTOGRAM_GREEN < 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_BLUE >= 0 && GIMP_HISTOGRAM_BLUE < 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_ALPHA >= 0 && GIMP_HISTOGRAM_ALPHA < 5);
  return config->curve[channels[index]];
}

static GlimsCurveState *
state_at (GlimsCurvesSnapshot *out, guint index)
{
  switch (index) {
    case 0: return &out->value;
    case 1: return &out->red;
    case 2: return &out->green;
    case 3: return &out->blue;
    default: return &out->alpha;
  }
}

/* Include partial overlaps, not only equal starting addresses. Counts have
 * already been bounded before this helper is called. */
static gboolean
storage_overlaps (const void *a, size_t a_size, const void *b, size_t b_size)
{
  uintptr_t x = (uintptr_t) a, y = (uintptr_t) b;
  if (!a || !b) return FALSE;
  if (a == b) return TRUE;
  if (!a_size || !b_size) return FALSE;
  if (x > UINTPTR_MAX - a_size || y > UINTPTR_MAX - b_size) return TRUE;
  return x < y + b_size && y < x + a_size;
}

static GlimsStatus
validate_config (GimpCurvesConfig *config, char **error)
{
  gboolean cursor_valid = FALSE;
  const void *storage[10]; size_t sizes[10];
  if (!config || G_OBJECT_TYPE (config) != GIMP_TYPE_CURVES_CONFIG)
    return curves_error (GLIMS_STATUS_FAILED, error, "The native Curves configuration has the wrong type.");
  for (guint i = 0; i < 5; i++) cursor_valid |= config->channel == channels[i];
  if (!cursor_valid || own_trc (config->trc) == GLIMS_COLOR_TRC_UNKNOWN)
    return curves_error (GLIMS_STATUS_FAILED, error, "The native Curves channel or TRC is invalid.");
  /* Validate all shapes and storage relationships before reading any arrays. */
  for (guint i = 0; i < 5; i++) {
    GimpCurve *curve = curve_at (config, i);
    if (!curve || G_OBJECT_TYPE (curve) != GIMP_TYPE_CURVE || curve->n_points < 0 || curve->n_samples < 0)
      return curves_error (GLIMS_STATUS_FAILED, error, "A native Curves channel is invalid.");
    if ((guint) curve->n_points > GLIMS_CURVE_MAX_POINTS || (guint) curve->n_samples != GLIMS_CURVE_SAMPLE_COUNT)
      return curves_error (GLIMS_STATUS_UNSUPPORTED, error, "Curves supports up to 65536 points and exactly 256 samples per channel.");
    if (!curve->samples || (curve->n_points && !curve->points) ||
        (curve->curve_type != GIMP_CURVE_SMOOTH && curve->curve_type != GIMP_CURVE_FREE) ||
        (curve->identity != FALSE && curve->identity != TRUE))
      return curves_error (GLIMS_STATUS_FAILED, error, "A native Curves channel has invalid storage, type or identity state.");
    if (gimp_data_is_frozen (GIMP_DATA (curve)))
      return curves_error (GLIMS_STATUS_UNSUPPORTED, error, "Finish the native curve edit before reading or changing Curves.");
    for (guint j = 0; j < i; j++) if (curve == curve_at (config, j))
      return curves_error (GLIMS_STATUS_UNSUPPORTED, error, "Aliased native Curves channels cannot be edited safely.");
    storage[i * 2] = curve->points;
    sizes[i * 2] = (size_t) curve->n_points * sizeof *curve->points;
    storage[i * 2 + 1] = curve->samples;
    sizes[i * 2 + 1] = (size_t) curve->n_samples * sizeof *curve->samples;
  }
  for (guint i = 0; i < 10; i++) for (guint j = 0; j < i; j++)
    if (storage_overlaps (storage[i], sizes[i], storage[j], sizes[j]))
      return curves_error (GLIMS_STATUS_UNSUPPORTED, error, "Aliased native curve storage cannot be edited safely.");
  for (guint i = 0; i < 5; i++) {
    GimpCurve *curve = curve_at (config, i);
    for (gint j = 0; j < curve->n_points; j++) {
      GimpCurvePoint *point = &curve->points[j];
      if (!unit_value (point->x) || !unit_value (point->y) || !own_point_type (point->type) ||
          (j && point->x < curve->points[j - 1].x))
        return curves_error (GLIMS_STATUS_FAILED, error, "Native curve points must be finite, ordered and within 0 to 1, with known point types.");
    }
    for (gint j = 0; j < curve->n_samples; j++) if (!unit_value (curve->samples[j]))
      return curves_error (GLIMS_STATUS_FAILED, error, "Native curve samples must be finite and within 0 to 1.");
  }
  return GLIMS_STATUS_OK;
}

static GlimsStatus
checked_point (GeglNode *node, gboolean allow_empty, GimpOperationPointFilter **out, char **error)
{
  GlimsPointConfigTRCSpec spec = curves_spec ();
  GlimsStatus status = glims_point_config_trc_check (node, &spec, allow_empty, out, error);
  if (status == GLIMS_STATUS_OK && (*out)->config) {
    status = validate_config (GIMP_CURVES_CONFIG ((*out)->config), error);
    if (status != GLIMS_STATUS_OK) *out = NULL;
  }
  return status;
}

gboolean
glims_curves_config_is_operation (GeglNode *node)
{
  return GEGL_IS_NODE (node) && g_strcmp0 (gegl_node_get_operation (node), "gimp:curves") == 0;
}

GlimsStatus
glims_curves_config_validate (GeglNode *node, char **error)
{
  GimpOperationPointFilter *point;
  return checked_point (node, FALSE, &point, error);
}

void
glims_curves_snapshot_clear (GlimsCurvesSnapshot *out)
{
  if (!out || out->struct_size < sizeof *out) return;
  out->trc = GLIMS_COLOR_TRC_UNKNOWN;
  for (guint i = 0; i < 5; i++) *state_at (out, i) = (GlimsCurveState) {0};
}

void
glims_curves_snapshot_free (GlimsCurvesSnapshot *out)
{
  if (!out || out->struct_size < sizeof *out) return;
  for (guint i = 0; i < 5; i++) {
    GlimsCurveState *state = state_at (out, i);
    g_free (state->points); g_free (state->samples);
  }
  glims_curves_snapshot_clear (out);
}

static GlimsStatus
export_config (GimpCurvesConfig *config, GlimsCurvesSnapshot *out, char **error)
{
  GlimsCurvesSnapshot result = { .struct_size = sizeof result };
  GlimsStatus status = validate_config (config, error);
  if (status != GLIMS_STATUS_OK) return status;
  result.trc = own_trc (config->trc);
  for (guint i = 0; i < 5; i++) {
    GimpCurve *curve = curve_at (config, i);
    GlimsCurveState *state = state_at (&result, i);
    state->kind = curve->curve_type == GIMP_CURVE_SMOOTH ? GLIMS_CURVE_KIND_SMOOTH : GLIMS_CURVE_KIND_FREE;
    state->identity = (uint32_t) curve->identity;
    state->point_count = (uint32_t) curve->n_points;
    state->sample_count = GLIMS_CURVE_SAMPLE_COUNT;
    if (state->point_count) state->points = g_try_new0 (GlimsCurvePoint, state->point_count);
    state->samples = g_try_new (double, GLIMS_CURVE_SAMPLE_COUNT);
    if ((state->point_count && !state->points) || !state->samples) {
      glims_curves_snapshot_free (&result);
      return curves_error (GLIMS_STATUS_FAILED, error, "Memory could not be allocated for the complete Curves snapshot.");
    }
    for (gint j = 0; j < curve->n_points; j++)
      state->points[j] = (GlimsCurvePoint) { curve->points[j].x, curve->points[j].y,
                                           own_point_type (curve->points[j].type) };
    memcpy (state->samples, curve->samples, GLIMS_CURVE_SAMPLE_COUNT * sizeof *state->samples);
  }
  result.struct_size = out->struct_size;
  *out = result; /* Only known bytes; caller's future tail is untouched. */
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_curves_config_get (GeglNode *node, GlimsCurvesSnapshot *out, char **error)
{
  GimpOperationPointFilter *point;
  if (!out || out->struct_size < sizeof *out)
    return curves_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A full Curves snapshot output is required.");
  glims_curves_snapshot_clear (out);
  GlimsStatus status = checked_point (node, FALSE, &point, error);
  return status == GLIMS_STATUS_OK ? export_config (GIMP_CURVES_CONFIG (point->config), out, error) : status;
}

static gboolean
same_points (const GimpCurve *a, const GimpCurve *b)
{
  if (a->curve_type != b->curve_type || a->n_points != b->n_points) return FALSE;
  for (gint i = 0; i < a->n_points; i++)
    if (a->points[i].x != b->points[i].x || a->points[i].y != b->points[i].y ||
        a->points[i].type != b->points[i].type) return FALSE;
  return TRUE;
}

static gboolean
same_curve (const GimpCurve *a, const GimpCurve *b)
{
  if (!same_points (a, b) || a->identity != b->identity || a->n_samples != b->n_samples) return FALSE;
  for (gint i = 0; i < a->n_samples; i++) if (a->samples[i] != b->samples[i]) return FALSE;
  return TRUE;
}

static gboolean
same_base (GimpCurvesConfig *a, GimpCurvesConfig *b, gboolean compare_trc)
{
  GimpOperationSettings *x = GIMP_OPERATION_SETTINGS (a), *y = GIMP_OPERATION_SETTINGS (b);
  return a->channel == b->channel && (!compare_trc || a->trc == b->trc) &&
    GIMP_SETTINGS (a)->time == GIMP_SETTINGS (b)->time && x->clip == y->clip &&
    x->region == y->region && x->mode == y->mode && x->opacity == y->opacity;
}

static GlimsStatus
clone_config (GimpCurvesConfig *source, GimpCurvesConfig **out, char **error)
{
  *out = NULL;
  GlimsStatus status = validate_config (source, error);
  if (status != GLIMS_STATUS_OK) return status;
  GimpCurvesConfig *copy = gimp_config_duplicate (GIMP_CONFIG (source)); /* Owned. */
  if (!copy) return curves_error (GLIMS_STATUS_FAILED, error, "The native Curves configuration could not be copied.");
  status = validate_config (copy, error);
  if (status != GLIMS_STATUS_OK) goto fail;
  if (copy == source) goto invalid;
  /* Native duplicate can leave the access cursor at VALUE; restoring this
   * private property does not dirty any curve or recompute its table. */
  g_object_set (copy, "channel", source->channel, NULL);
  if (!same_base (copy, source, TRUE)) goto invalid;
  for (guint i = 0; i < 5; i++) {
    GimpCurve *d = curve_at (copy, i);
    if (!same_points (d, curve_at (source, i))) goto invalid;
    for (guint j = 0; j < 5; j++) {
      GimpCurve *s = curve_at (source, j);
      if (d == s ||
          storage_overlaps (d->points, (size_t) d->n_points * sizeof *d->points,
                            s->points, (size_t) s->n_points * sizeof *s->points) ||
          storage_overlaps (d->samples, (size_t) d->n_samples * sizeof *d->samples,
                            s->samples, (size_t) s->n_samples * sizeof *s->samples) ||
          storage_overlaps (d->points, (size_t) d->n_points * sizeof *d->points,
                            s->samples, (size_t) s->n_samples * sizeof *s->samples) ||
          storage_overlaps (d->samples, (size_t) d->n_samples * sizeof *d->samples,
                            s->points, (size_t) s->n_points * sizeof *s->points)) goto invalid;
    }
  }
  /* Every object/storage relationship is checked before any restoration.
   * Do not dirty or thaw the four untouched channels after these copies. */
  for (guint i = 0; i < 5; i++) {
    GimpCurve *d = curve_at (copy, i), *s = curve_at (source, i);
    memcpy (d->samples, s->samples, GLIMS_CURVE_SAMPLE_COUNT * sizeof *d->samples);
    d->identity = s->identity;
  }
  *out = copy;
  return GLIMS_STATUS_OK;
invalid:
  status = curves_error (GLIMS_STATUS_FAILED, error, "The copied Curves configuration is not an independent, faithful candidate.");
fail:
  g_object_unref (copy);
  return status;
}

GlimsStatus
glims_curves_config_prepare (GeglNode *node, char **error)
{
  if (!GEGL_IS_NODE (node))
    return curves_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A filter operation is required.");
  if (!glims_curves_config_is_operation (node)) return GLIMS_STATUS_OK;
  GimpOperationPointFilter *point;
  GlimsStatus status = checked_point (node, TRUE, &point, error);
  if (status != GLIMS_STATUS_OK || point->config) return status;
  GimpCurvesConfig *config = g_object_new (GIMP_TYPE_CURVES_CONFIG, NULL);
  if (!config) return curves_error (GLIMS_STATUS_FAILED, error, "The native Curves configuration could not be created.");
  g_object_set (config, "trc", GIMP_TRC_PERCEPTUAL, NULL); /* Explicit after 3.0 legacy construction. */
  status = validate_config (config, error);
  if (status == GLIMS_STATUS_OK) {
    GlimsPointConfigTRCSpec spec = curves_spec ();
    status = glims_point_config_trc_install (point, G_OBJECT (config), &spec, error);
  }
  g_object_unref (config);
  return status;
}

GlimsStatus
glims_curves_config_copy (GeglNode *destination, GeglNode *source, char **error)
{
  GimpOperationPointFilter *dest, *src;
  GlimsStatus status = checked_point (destination, TRUE, &dest, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = checked_point (source, FALSE, &src, error);
  if (status != GLIMS_STATUS_OK) return status;
  GlimsPointConfigTRCSpec spec = curves_spec ();
  /* Node/source owns this immutable whole config throughout the call. */
  return glims_point_config_trc_install (dest, src->config, &spec, error);
}

static gint
edit_index (uint32_t channel)
{
  switch (channel) {
    case GLIMS_CURVE_CHANNEL_VALUE: return 0;
    case GLIMS_CURVE_CHANNEL_RED: return 1;
    case GLIMS_CURVE_CHANNEL_GREEN: return 2;
    case GLIMS_CURVE_CHANNEL_BLUE: return 3;
    case GLIMS_CURVE_CHANNEL_ALPHA: return 4;
    default: return -1;
  }
}

static gboolean
valid_edit (const GlimsCurveEdit *edit)
{
  if (!edit || edit->struct_size < sizeof *edit || edit_index (edit->channel) < 0) return FALSE;
  switch (edit->mode) {
    case GLIMS_CURVE_EDIT_SMOOTH_POINTS:
      if (edit->point_count > GLIMS_CURVE_MAX_POINTS || (!!edit->points != !!edit->point_count) ||
          edit->samples || edit->sample_count) return FALSE;
      for (guint i = 0; i < edit->point_count; i++) {
        const GlimsCurvePoint *p = &edit->points[i];
        if (!unit_value (p->x) || !unit_value (p->y) ||
            (p->kind != GLIMS_CURVE_POINT_SMOOTH && p->kind != GLIMS_CURVE_POINT_CORNER) ||
            (i && p->x < edit->points[i - 1].x)) return FALSE;
      }
      return TRUE;
    case GLIMS_CURVE_EDIT_FREE_SAMPLES:
      if (edit->points || edit->point_count || !edit->samples || edit->sample_count != GLIMS_CURVE_SAMPLE_COUNT) return FALSE;
      for (guint i = 0; i < edit->sample_count; i++) if (!unit_value (edit->samples[i])) return FALSE;
      return TRUE;
    case GLIMS_CURVE_EDIT_RESET:
      return !edit->points && !edit->point_count && !edit->samples && !edit->sample_count;
    default: return FALSE;
  }
}

static gboolean
edit_matches (const GimpCurve *curve, const GlimsCurveEdit *edit)
{
  if (edit->mode == GLIMS_CURVE_EDIT_SMOOTH_POINTS) {
    if (curve->curve_type != GIMP_CURVE_SMOOTH || (guint) curve->n_points != edit->point_count) return FALSE;
    for (guint i = 0; i < edit->point_count; i++)
      if (curve->points[i].x != edit->points[i].x || curve->points[i].y != edit->points[i].y ||
          own_point_type (curve->points[i].type) != edit->points[i].kind) return FALSE;
    return TRUE;
  }
  if (edit->mode == GLIMS_CURVE_EDIT_FREE_SAMPLES) {
    if (curve->curve_type != GIMP_CURVE_FREE) return FALSE;
    for (guint i = 0; i < GLIMS_CURVE_SAMPLE_COUNT; i++) if (curve->samples[i] != edit->samples[i]) return FALSE;
    return TRUE;
  }
  return FALSE; /* Reset compares the actual native result instead. */
}

static GlimsStatus
apply_edit (GimpCurve *curve, const GlimsCurveEdit *edit, char **error)
{
  if (edit->mode == GLIMS_CURVE_EDIT_RESET) {
    /* Core's trailing dirty recalculates and clears identity. Keep that
     * native result; reset_type TRUE requests Smooth, not an HDR override. */
    gimp_curve_reset (curve, TRUE);
    return GLIMS_STATUS_OK;
  }
  GimpValueArray *points = NULL, *types = NULL;
  if (edit->mode == GLIMS_CURVE_EDIT_SMOOTH_POINTS) {
    points = gimp_value_array_new ((gint) edit->point_count * 2);
    types = gimp_value_array_new ((gint) edit->point_count);
    if (!points || !types) {
      if (points) gimp_value_array_unref (points);
      if (types) gimp_value_array_unref (types);
      return curves_error (GLIMS_STATUS_FAILED, error, "The native curve point arrays could not be created.");
    }
    GValue coordinate = G_VALUE_INIT, type = G_VALUE_INIT;
    g_value_init (&coordinate, G_TYPE_DOUBLE);
    g_value_init (&type, GIMP_TYPE_CURVE_POINT_TYPE);
    for (guint i = 0; i < edit->point_count; i++) {
      g_value_set_double (&coordinate, edit->points[i].x); gimp_value_array_append (points, &coordinate);
      g_value_set_double (&coordinate, edit->points[i].y); gimp_value_array_append (points, &coordinate);
      g_value_set_enum (&type, native_point_type (edit->points[i].kind)); gimp_value_array_append (types, &type);
    }
    g_value_unset (&coordinate); g_value_unset (&type);
  }
  gimp_data_freeze (GIMP_DATA (curve));
  if (edit->mode == GLIMS_CURVE_EDIT_SMOOTH_POINTS) {
    gimp_curve_set_curve_type (curve, GIMP_CURVE_SMOOTH);
    g_object_set (curve, "points", points, "point-types", types, NULL);
    gimp_data_dirty (GIMP_DATA (curve));
  } else {
    gimp_curve_set_curve_type (curve, GIMP_CURVE_FREE);
    for (guint i = 0; i < GLIMS_CURVE_SAMPLE_COUNT; i++) {
      double x = (double) i / (GLIMS_CURVE_SAMPLE_COUNT - 1);
#if GIMP_CHECK_VERSION (3, 2, 0)
      gimp_curve_set_sample (curve, x, edit->samples[i]);
#else
      gimp_curve_set_curve (curve, x, edit->samples[i]);
#endif
    }
  }
  gimp_data_thaw (GIMP_DATA (curve));
  if (points) gimp_value_array_unref (points);
  if (types) gimp_value_array_unref (types);
  return GLIMS_STATUS_OK;
}

/* All fallible candidate generation and full output allocation precede the
 * shared installer's staged binding/ordinary-ref replacement. */
static GlimsStatus
install_result (GimpOperationPointFilter *point, GimpCurvesConfig *copy,
                GlimsCurvesSnapshot *out, gboolean *changed, char **error)
{
  GlimsCurvesSnapshot result = { .struct_size = out->struct_size };
  GlimsStatus status = export_config (copy, &result, error);
  if (status != GLIMS_STATUS_OK) return status;
  GlimsPointConfigTRCSpec spec = curves_spec ();
  status = glims_point_config_trc_install (point, G_OBJECT (copy), &spec, error);
  if (status == GLIMS_STATUS_OK) {
    *out = result;
    *changed = TRUE;
  } else glims_curves_snapshot_free (&result);
  return status;
}

static const GlimsCurveState *
input_state_at (const GlimsCurvesSnapshot *settings, guint index)
{
  switch (index) {
    case 0: return &settings->value;
    case 1: return &settings->red;
    case 2: return &settings->green;
    case 3: return &settings->blue;
    default: return &settings->alpha;
  }
}

static gboolean
valid_settings (const GlimsCurvesSnapshot *settings)
{
  GimpTRCType trc;
  if (!settings || settings->struct_size < sizeof *settings || !native_trc (settings->trc, &trc)) return FALSE;
  for (guint c = 0; c < 5; c++) {
    const GlimsCurveState *state = input_state_at (settings, c);
    if ((state->kind != GLIMS_CURVE_KIND_SMOOTH && state->kind != GLIMS_CURVE_KIND_FREE) ||
        state->identity > 1 || state->point_count > GLIMS_CURVE_MAX_POINTS ||
        (!!state->point_count != !!state->points) ||
        state->sample_count != GLIMS_CURVE_SAMPLE_COUNT || !state->samples) return FALSE;
    for (guint p = 0; p < state->point_count; p++) {
      const GlimsCurvePoint *point = &state->points[p];
      if (!unit_value (point->x) || !unit_value (point->y) ||
          (point->kind != GLIMS_CURVE_POINT_SMOOTH && point->kind != GLIMS_CURVE_POINT_CORNER) ||
          (p && point->x < state->points[p - 1].x)) return FALSE;
    }
    for (guint s = 0; s < state->sample_count; s++) if (!unit_value (state->samples[s])) return FALSE;
  }
  return TRUE;
}

static gboolean
settings_match (GimpCurvesConfig *config, const GlimsCurvesSnapshot *settings)
{
  if (own_trc (config->trc) != settings->trc) return FALSE;
  for (guint c = 0; c < 5; c++) {
    const GlimsCurveState *state = input_state_at (settings, c);
    const GimpCurve *curve = curve_at (config, c);
    uint32_t kind = curve->curve_type == GIMP_CURVE_SMOOTH ? GLIMS_CURVE_KIND_SMOOTH : GLIMS_CURVE_KIND_FREE;
    if (kind != state->kind || (uint32_t) curve->identity != state->identity ||
        (guint) curve->n_points != state->point_count) return FALSE;
    for (guint p = 0; p < state->point_count; p++)
      if (curve->points[p].x != state->points[p].x || curve->points[p].y != state->points[p].y ||
          own_point_type (curve->points[p].type) != state->points[p].kind) return FALSE;
    if (memcmp (curve->samples, state->samples, GLIMS_CURVE_SAMPLE_COUNT * sizeof (double))) return FALSE;
  }
  return TRUE;
}

/* A recorded whole value must retain hidden points, noncanonical Smooth
 * samples and identity's HDR bypass. Replaying editing patches would derive
 * and discard some of those fields. Replace them only in an independent,
 * unpublished candidate; dirty/thaw would recompute Smooth samples again. */
GlimsStatus
glims_curves_config_set (GeglNode *node, const GlimsCurvesSnapshot *settings,
                         gboolean *changed, char **error)
{
  GimpOperationPointFilter *point;
  GimpCurvesConfig *source, *copy = NULL;
  GimpTRCType trc;
  GlimsStatus status;
  if (changed) *changed = FALSE;
  if (!changed || !valid_settings (settings))
    return curves_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "Curves requires five complete finite channel states, known kinds and TRC, ordered points and 256 samples per channel.");
  status = checked_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  source = GIMP_CURVES_CONFIG (point->config);
  if (settings_match (source, settings)) return GLIMS_STATUS_OK;
  status = clone_config (source, &copy, error);
  if (status != GLIMS_STATUS_OK) return status;
  native_trc (settings->trc, &trc);
  g_object_set (copy, "trc", trc, NULL);
  for (guint c = 0; c < 5; c++) {
    const GlimsCurveState *state = input_state_at (settings, c);
    GimpCurve *curve = curve_at (copy, c);
    GimpCurvePoint *points = state->point_count ? g_try_new (GimpCurvePoint, state->point_count) : NULL;
    if (state->point_count && !points) {
      status = curves_error (GLIMS_STATUS_FAILED, error, "Memory could not be allocated for the complete Curves settings.");
      goto done;
    }
    for (guint p = 0; p < state->point_count; p++)
      points[p] = (GimpCurvePoint) { state->points[p].x, state->points[p].y, native_point_type (state->points[p].kind) };
    g_free (curve->points);
    curve->points = points;
    curve->n_points = (gint) state->point_count;
    curve->curve_type = state->kind == GLIMS_CURVE_KIND_SMOOTH ? GIMP_CURVE_SMOOTH : GIMP_CURVE_FREE;
    memcpy (curve->samples, state->samples, GLIMS_CURVE_SAMPLE_COUNT * sizeof *curve->samples);
    curve->identity = state->identity != 0;
  }
  status = validate_config (copy, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (!same_base (copy, source, FALSE) || !settings_match (copy, settings)) {
    status = curves_error (GLIMS_STATUS_FAILED, error, "The native Curves candidate did not preserve the complete requested settings.");
    goto done;
  }
  GlimsPointConfigTRCSpec spec = curves_spec ();
  status = glims_point_config_trc_install (point, G_OBJECT (copy), &spec, error);
  if (status == GLIMS_STATUS_OK) *changed = TRUE;
done:
  g_object_unref (copy);
  return status;
}

GlimsStatus
glims_curves_config_edit (GeglNode *node, const GlimsCurveEdit *edit,
                         GlimsCurvesSnapshot *out, gboolean *changed, char **error)
{
  if (changed) *changed = FALSE;
  if (!out || out->struct_size < sizeof *out)
    return curves_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A full Curves snapshot output is required.");
  glims_curves_snapshot_clear (out);
  if (!changed || !valid_edit (edit))
    return curves_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "Curves requires a known channel and complete finite ordered points or 256 samples in 0 to 1, with unused arrays empty.");
  GimpOperationPointFilter *point;
  GlimsStatus status = checked_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  GimpCurvesConfig *source = GIMP_CURVES_CONFIG (point->config), *copy = NULL;
  guint selected = (guint) edit_index (edit->channel);
  /* Authoritative numeric equality, including signed zero, preserves a
   * noncanonical Smooth table and its identity shortcut without dirtying. */
  if (edit_matches (curve_at (source, selected), edit)) return export_config (source, out, error);
  status = clone_config (source, &copy, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = apply_edit (curve_at (copy, selected), edit, error);
  if (status != GLIMS_STATUS_OK) goto done;
  status = validate_config (copy, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (!same_base (copy, source, TRUE)) goto invalid;
  for (guint i = 0; i < 5; i++) if (i != selected &&
      (!same_curve (curve_at (copy, i), curve_at (source, i)) ||
       memcmp (curve_at (copy, i)->samples, curve_at (source, i)->samples,
               GLIMS_CURVE_SAMPLE_COUNT * sizeof (double)))) goto invalid;
  if (edit->mode != GLIMS_CURVE_EDIT_RESET && !edit_matches (curve_at (copy, selected), edit)) goto invalid;
  if (same_curve (curve_at (copy, selected), curve_at (source, selected)))
    status = export_config (source, out, error);
  else status = install_result (point, copy, out, changed, error);
  goto done;
invalid:
  status = curves_error (GLIMS_STATUS_FAILED, error, "The native Curves edit did not preserve the complete requested channel and untouched settings.");
done:
  g_object_unref (copy);
  return status;
}

GlimsStatus
glims_curves_config_set_trc (GeglNode *node, uint32_t trc, GlimsCurvesSnapshot *out,
                            gboolean *changed, char **error)
{
  if (changed) *changed = FALSE;
  if (!out || out->struct_size < sizeof *out)
    return curves_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A full Curves snapshot output is required.");
  glims_curves_snapshot_clear (out);
  GimpTRCType native;
  if (!changed || !native_trc (trc, &native))
    return curves_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A known Curves TRC and change output are required.");
  GimpOperationPointFilter *point;
  GlimsStatus status = checked_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  GimpCurvesConfig *source = GIMP_CURVES_CONFIG (point->config), *copy = NULL;
  if (source->trc == native) return export_config (source, out, error);
  status = clone_config (source, &copy, error);
  if (status != GLIMS_STATUS_OK) return status;
  g_object_set (copy, "trc", native, NULL);
  status = validate_config (copy, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (!same_base (copy, source, FALSE) || copy->trc != native) goto invalid;
  for (guint i = 0; i < 5; i++) if (!same_curve (curve_at (copy, i), curve_at (source, i)) ||
      memcmp (curve_at (copy, i)->samples, curve_at (source, i)->samples,
              GLIMS_CURVE_SAMPLE_COUNT * sizeof (double))) goto invalid;
  status = install_result (point, copy, out, changed, error);
  goto done;
invalid:
  status = curves_error (GLIMS_STATUS_FAILED, error, "Changing Curves TRC did not preserve all curve and base settings.");
done:
  g_object_unref (copy);
  return status;
}

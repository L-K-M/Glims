/* Whole owned Levels values; native objects stay on the engine thread. */
#include "levels-config.h"

#include <math.h>
#include <string.h>

#include "operations/operations-types.h"
#include "operations/gimplevelsconfig.h"
#include "operations/gimpoperationlevels.h"
#include "operations/gimpoperationpointfilter.h"

static GlimsStatus
levels_error (GlimsStatus status, char **error, const char *message)
{
  if (error) *error = strdup (message);
  return status;
}

static uint32_t
own_trc (GimpTRCType trc)
{
  switch (trc) {
    case GIMP_TRC_LINEAR:     return GLIMS_COLOR_TRC_LINEAR;
    case GIMP_TRC_NON_LINEAR: return GLIMS_COLOR_TRC_NONLINEAR;
    case GIMP_TRC_PERCEPTUAL: return GLIMS_COLOR_TRC_PERCEPTUAL;
    default:                 return GLIMS_COLOR_TRC_UNKNOWN;
  }
}

/* Only called after the owned enum has been validated. */
static GimpTRCType
native_trc (uint32_t trc)
{
  switch (trc) {
    case GLIMS_COLOR_TRC_NONLINEAR:  return GIMP_TRC_NON_LINEAR;
    case GLIMS_COLOR_TRC_PERCEPTUAL: return GIMP_TRC_PERCEPTUAL;
    default:                       return GIMP_TRC_LINEAR;
  }
}

static gboolean
valid_channel (const GlimsLevelsChannel *c)
{
  return isfinite (c->low_input) && c->low_input >= 0 && c->low_input <= 1 &&
         isfinite (c->high_input) && c->high_input >= 0 && c->high_input <= 1 &&
         isfinite (c->gamma) && c->gamma >= 0.1 && c->gamma <= 10 &&
         isfinite (c->low_output) && c->low_output >= 0 && c->low_output <= 1 &&
         isfinite (c->high_output) && c->high_output >= 0 && c->high_output <= 1;
}

static gboolean
valid_settings (const GlimsLevelsSettings *s)
{
  return (s->trc == GLIMS_COLOR_TRC_LINEAR || s->trc == GLIMS_COLOR_TRC_NONLINEAR ||
          s->trc == GLIMS_COLOR_TRC_PERCEPTUAL) &&
         s->clamp_input <= 1 && s->clamp_output <= 1 &&
         valid_channel (&s->value) && valid_channel (&s->red) &&
         valid_channel (&s->green) && valid_channel (&s->blue) && valid_channel (&s->alpha);
}

static gboolean
equal_channel (const GlimsLevelsChannel *a, const GlimsLevelsChannel *b)
{
  return a->low_input == b->low_input && a->high_input == b->high_input &&
         a->gamma == b->gamma && a->low_output == b->low_output &&
         a->high_output == b->high_output;
}

static gboolean
equal_settings (const GlimsLevelsSettings *a, const GlimsLevelsSettings *b)
{
  return a->trc == b->trc && a->clamp_input == b->clamp_input &&
         a->clamp_output == b->clamp_output && equal_channel (&a->value, &b->value) &&
         equal_channel (&a->red, &b->red) && equal_channel (&a->green, &b->green) &&
         equal_channel (&a->blue, &b->blue) && equal_channel (&a->alpha, &b->alpha);
}

static gboolean
valid_cursor (GimpHistogramChannel channel)
{
  return channel == GIMP_HISTOGRAM_VALUE || channel == GIMP_HISTOGRAM_RED ||
         channel == GIMP_HISTOGRAM_GREEN || channel == GIMP_HISTOGRAM_BLUE ||
         channel == GIMP_HISTOGRAM_ALPHA;
}

static gboolean
trc_property (GObject *object)
{
  GParamSpec *spec = g_object_class_find_property (G_OBJECT_GET_CLASS (object), "trc");
  return spec && G_IS_PARAM_SPEC_ENUM (spec) &&
         G_PARAM_SPEC_VALUE_TYPE (spec) == GIMP_TYPE_TRC_TYPE &&
         (spec->flags & G_PARAM_READWRITE) == G_PARAM_READWRITE;
}

#if GIMP_CHECK_VERSION (3, 2, 0)
static gboolean
binding_matches (GBinding *binding, GObject *config, GimpOperationPointFilter *point)
{
  GObject *source, *target;
  gboolean matches;
  if (!binding || !G_IS_BINDING (binding)) return FALSE;
  if ((g_binding_get_flags (binding) & ~G_BINDING_SYNC_CREATE) != 0) return FALSE;
  if (g_strcmp0 (g_binding_get_source_property (binding), "trc") ||
      g_strcmp0 (g_binding_get_target_property (binding), "trc")) return FALSE;
  source = g_binding_dup_source (binding); /* owned endpoint witnesses */
  target = g_binding_dup_target (binding);
  matches = source == config && target == G_OBJECT (point);
  g_clear_object (&source);
  g_clear_object (&target);
  return matches;
}
#endif

gboolean
glims_levels_config_is_operation (GeglNode *node)
{
  const char *name;
  if (!GEGL_IS_NODE (node)) return FALSE;
  name = gegl_node_get_operation (node); /* borrowed */
  return name && strcmp (name, "gimp:levels") == 0;
}

static GlimsStatus
checked_point (GeglNode *node, gboolean allow_empty,
               GimpOperationPointFilter **out, char **error)
{
  GeglOperation *operation;
  GimpOperationPointFilter *point;
  *out = NULL;
  if (!GEGL_IS_NODE (node))
    return levels_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A filter operation is required.");
  if (!glims_levels_config_is_operation (node))
    return levels_error (GLIMS_STATUS_UNSUPPORTED, error, "These settings are only available for Levels.");
  operation = gegl_node_get_gegl_operation (node); /* borrowed from node */
  if (!operation || G_OBJECT_TYPE (operation) != GIMP_TYPE_OPERATION_LEVELS)
    return levels_error (GLIMS_STATUS_FAILED, error, "The native Levels operation is invalid.");
  point = GIMP_OPERATION_POINT_FILTER (operation);
  if (!trc_property (G_OBJECT (point)))
    return levels_error (GLIMS_STATUS_UNSUPPORTED, error, "The native Levels operation has an incompatible TRC property.");
  if (own_trc (point->trc) == GLIMS_COLOR_TRC_UNKNOWN)
    return levels_error (GLIMS_STATUS_FAILED, error, "The native Levels operation TRC is invalid.");
  if (point->config) {
    GimpLevelsConfig *config;
    if (G_OBJECT_TYPE (point->config) != GIMP_TYPE_LEVELS_CONFIG)
      return levels_error (GLIMS_STATUS_FAILED, error, "The native Levels configuration has the wrong type.");
    if (!trc_property (point->config))
      return levels_error (GLIMS_STATUS_UNSUPPORTED, error, "The native Levels configuration has an incompatible TRC property.");
    config = GIMP_LEVELS_CONFIG (point->config);
    if (own_trc (config->trc) == GLIMS_COLOR_TRC_UNKNOWN)
      return levels_error (GLIMS_STATUS_FAILED, error, "The native Levels configuration TRC is invalid.");
    if (point->trc != config->trc)
      return levels_error (GLIMS_STATUS_UNSUPPORTED, error, "This Levels effect has inconsistent operation and configuration TRCs and cannot be edited safely.");
  } else if (!allow_empty) {
    return levels_error (GLIMS_STATUS_FAILED, error, "The filter has no Levels configuration.");
  }
#if GIMP_CHECK_VERSION (3, 2, 0)
  if (point->config ? !binding_matches (point->trc_binding, point->config, point)
                    : point->trc_binding != NULL)
    return levels_error (GLIMS_STATUS_UNSUPPORTED, error, "The native Levels TRC binding is incompatible.");
#endif
  *out = point;
  return GLIMS_STATUS_OK;
}

static GlimsLevelsChannel
read_channel (const GimpLevelsConfig *c, GimpHistogramChannel channel)
{
  GlimsLevelsChannel out = { c->low_input[channel], c->high_input[channel],
                            c->gamma[channel], c->low_output[channel], c->high_output[channel] };
  return out;
}

static GlimsStatus
read_config (GimpLevelsConfig *config, GlimsLevelsSettings *out, char **error)
{
  G_STATIC_ASSERT (G_N_ELEMENTS (config->low_input) == 5);
  G_STATIC_ASSERT (G_N_ELEMENTS (config->high_input) == 5);
  G_STATIC_ASSERT (G_N_ELEMENTS (config->gamma) == 5);
  G_STATIC_ASSERT (G_N_ELEMENTS (config->low_output) == 5);
  G_STATIC_ASSERT (G_N_ELEMENTS (config->high_output) == 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_VALUE >= 0 && GIMP_HISTOGRAM_VALUE < 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_RED >= 0 && GIMP_HISTOGRAM_RED < 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_GREEN >= 0 && GIMP_HISTOGRAM_GREEN < 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_BLUE >= 0 && GIMP_HISTOGRAM_BLUE < 5);
  G_STATIC_ASSERT (GIMP_HISTOGRAM_ALPHA >= 0 && GIMP_HISTOGRAM_ALPHA < 5);
  if (!valid_cursor (config->channel))
    return levels_error (GLIMS_STATUS_FAILED, error, "The native Levels channel is invalid.");
  if ((config->clamp_input != FALSE && config->clamp_input != TRUE) ||
      (config->clamp_output != FALSE && config->clamp_output != TRUE))
    return levels_error (GLIMS_STATUS_FAILED, error, "The native Levels clamp flags are invalid.");
  out->trc = own_trc (config->trc);
  out->clamp_input = (uint32_t) config->clamp_input;
  out->clamp_output = (uint32_t) config->clamp_output;
  out->value = read_channel (config, GIMP_HISTOGRAM_VALUE);
  out->red = read_channel (config, GIMP_HISTOGRAM_RED);
  out->green = read_channel (config, GIMP_HISTOGRAM_GREEN);
  out->blue = read_channel (config, GIMP_HISTOGRAM_BLUE);
  out->alpha = read_channel (config, GIMP_HISTOGRAM_ALPHA);
  if (!valid_settings (out))
    return levels_error (GLIMS_STATUS_FAILED, error, "The native Levels settings are invalid.");
  return GLIMS_STATUS_OK;
}

static void
clear_fields (GlimsLevelsSettings *out)
{
  out->trc = GLIMS_COLOR_TRC_UNKNOWN;
  out->clamp_input = out->clamp_output = 0;
  out->value = out->red = out->green = out->blue = out->alpha = (GlimsLevelsChannel) {0};
}

/* The candidate is fully private/validated before staging. DEFAULT creates no
 * target update; after staging succeeds, installation has no failing step. */
static GlimsStatus
install_config (GimpOperationPointFilter *point, GimpLevelsConfig *config, char **error)
{
  GlimsLevelsSettings checked = { .struct_size = sizeof checked };
  GlimsStatus status;
#if GIMP_CHECK_VERSION (3, 2, 0)
  GBinding *staged, *old;
#endif
  if (G_OBJECT_TYPE (config) != GIMP_TYPE_LEVELS_CONFIG || !trc_property (G_OBJECT (config)))
    return levels_error (GLIMS_STATUS_FAILED, error, "The replacement Levels configuration is invalid.");
  status = read_config (config, &checked, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (point->config == G_OBJECT (config)) return GLIMS_STATUS_OK;
#if GIMP_CHECK_VERSION (3, 2, 0)
  staged = g_object_bind_property (config, "trc", point, "trc", G_BINDING_DEFAULT);
  if (!staged)
    return levels_error (GLIMS_STATUS_FAILED, error, "The Levels TRC binding could not be created.");
  /* Staged source differs from the currently installed config. No TRC equality
   * check belongs here: the target must retain its old value until commit. */
  if (!binding_matches (staged, G_OBJECT (config), point)) {
    g_binding_unbind (staged);
    return levels_error (GLIMS_STATUS_FAILED, error, "The staged Levels TRC binding is invalid.");
  }
  old = point->trc_binding;
  point->trc_binding = NULL;
  if (old) g_binding_unbind (old);
#endif
  /* Native point setters duplicate a config ref (3.0:105, 3.2+:108). Avoid that
   * setter; release only local refs. GLib binding owns its initial ref. */
  g_set_object (&point->config, G_OBJECT (config));
#if GIMP_CHECK_VERSION (3, 2, 0)
  point->trc_binding = staged; /* borrowed, compatible with native clear */
#endif
  g_object_set (point, "trc", config->trc, NULL);
  g_object_notify (G_OBJECT (point), "config");
  return GLIMS_STATUS_OK;
}

static void
apply_channel (GimpLevelsConfig *config, GimpHistogramChannel channel,
               const GlimsLevelsChannel *values)
{
  g_object_set (config, "channel", channel,
                "low-input", values->low_input, "high-input", values->high_input,
                "gamma", values->gamma, "low-output", values->low_output,
                "high-output", values->high_output, NULL);
}

static void
apply_settings (GimpLevelsConfig *config, const GlimsLevelsSettings *settings)
{
  GimpHistogramChannel cursor = config->channel;
  apply_channel (config, GIMP_HISTOGRAM_VALUE, &settings->value);
  apply_channel (config, GIMP_HISTOGRAM_RED, &settings->red);
  apply_channel (config, GIMP_HISTOGRAM_GREEN, &settings->green);
  apply_channel (config, GIMP_HISTOGRAM_BLUE, &settings->blue);
  apply_channel (config, GIMP_HISTOGRAM_ALPHA, &settings->alpha);
  g_object_set (config, "trc", native_trc (settings->trc),
                "clamp-input", (gboolean) settings->clamp_input,
                "clamp-output", (gboolean) settings->clamp_output,
                "channel", cursor, NULL);
}

GlimsStatus
glims_levels_config_prepare (GeglNode *node, char **error)
{
  GimpOperationPointFilter *point;
  GlimsLevelsSettings checked = { .struct_size = sizeof checked };
  GlimsStatus status;
  GimpLevelsConfig *config;
  const GlimsLevelsSettings defaults = {
    .struct_size = sizeof defaults, .trc = GLIMS_COLOR_TRC_LINEAR,
    .value = {0, 1, 1, 0, 1}, .red = {0, 1, 1, 0, 1}, .green = {0, 1, 1, 0, 1},
    .blue = {0, 1, 1, 0, 1}, .alpha = {0, 1, 1, 0, 1}
  };
  if (!GEGL_IS_NODE (node))
    return levels_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A filter operation is required.");
  if (!glims_levels_config_is_operation (node)) return GLIMS_STATUS_OK;
  status = checked_point (node, TRUE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (point->config) return read_config (GIMP_LEVELS_CONFIG (point->config), &checked, error);
  config = g_object_new (GIMP_TYPE_LEVELS_CONFIG, NULL); /* owned */
  if (!config)
    return levels_error (GLIMS_STATUS_FAILED, error, "The Levels configuration could not be created.");
  /* 3.0 construction may apply the legacy alias. Set the explicit TRC last. */
  apply_settings (config, &defaults);
  status = install_config (point, config, error);
  g_object_unref (config);
  return status;
}

GlimsStatus
glims_levels_config_copy (GeglNode *destination, GeglNode *source, char **error)
{
  GimpOperationPointFilter *dest, *src;
  GlimsLevelsSettings checked = { .struct_size = sizeof checked };
  GlimsStatus status;
  status = checked_point (destination, TRUE, &dest, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = checked_point (source, FALSE, &src, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = read_config (GIMP_LEVELS_CONFIG (src->config), &checked, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (dest->config) {
    status = read_config (GIMP_LEVELS_CONFIG (dest->config), &checked, error);
    if (status != GLIMS_STATUS_OK) return status;
  }
  /* Source node retains this borrowed config throughout the serialized call. */
  return install_config (dest, GIMP_LEVELS_CONFIG (src->config), error);
}

GlimsStatus
glims_levels_config_get (GeglNode *node, GlimsLevelsSettings *out, char **error)
{
  GimpOperationPointFilter *point;
  GlimsLevelsSettings result = { .struct_size = sizeof result };
  GlimsStatus status;
  if (!out || out->struct_size < sizeof *out)
    return levels_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A full Levels output is required.");
  clear_fields (out);
  status = checked_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = read_config (GIMP_LEVELS_CONFIG (point->config), &result, error);
  if (status != GLIMS_STATUS_OK) return status;
  out->trc = result.trc;
  out->clamp_input = result.clamp_input;
  out->clamp_output = result.clamp_output;
  out->value = result.value;
  out->red = result.red;
  out->green = result.green;
  out->blue = result.blue;
  out->alpha = result.alpha;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_levels_config_set (GeglNode *node, const GlimsLevelsSettings *settings,
                         gboolean *changed, char **error)
{
  GimpOperationPointFilter *point;
  GlimsLevelsSettings current = { .struct_size = sizeof current };
  GlimsStatus status;
  GimpLevelsConfig *copy;
  if (changed) *changed = FALSE;
  if (!changed || !settings || settings->struct_size < sizeof *settings)
    return levels_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "Full Levels settings and a change output are required.");
  if (!valid_settings (settings))
    return levels_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "Levels require finite input/output endpoints in [0,1], gamma in [0.1,10], valid TRC and boolean clamp flags.");
  status = checked_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = read_config (GIMP_LEVELS_CONFIG (point->config), &current, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (equal_settings (&current, settings)) return GLIMS_STATUS_OK;
  copy = gimp_config_duplicate (GIMP_CONFIG (point->config)); /* owned */
  if (!copy)
    return levels_error (GLIMS_STATUS_FAILED, error, "The Levels configuration could not be copied.");
  if (G_OBJECT_TYPE (copy) != GIMP_TYPE_LEVELS_CONFIG) {
    g_object_unref (copy);
    return levels_error (GLIMS_STATUS_FAILED, error, "The copied Levels configuration has the wrong type.");
  }
  apply_settings (copy, settings);
  status = install_config (point, copy, error);
  g_object_unref (copy);
  if (status == GLIMS_STATUS_OK) *changed = TRUE;
  return status;
}

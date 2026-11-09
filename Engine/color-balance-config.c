/* Owned GlimsColorBalanceSettings; native config stays in the adapter. */
#include "color-balance-config.h"

#include <math.h>
#include <string.h>

#include "operations/operations-types.h"
#include "libgimpbase/gimpbase.h"
#include "libgimpconfig/gimpconfig.h"
#include "operations/gimpcolorbalanceconfig.h"
#include "operations/gimpoperationcolorbalance.h"
#include "operations/gimpoperationpointfilter.h"

static GlimsStatus
cb_error (GlimsStatus status, char **error, const char *message)
{
  if (error) *error = strdup (message);
  return status;
}

static gboolean
valid_range (const GlimsColorBalanceRange *r)
{
  return isfinite (r->cyan_red) && r->cyan_red >= -1.0 && r->cyan_red <= 1.0 &&
         isfinite (r->magenta_green) && r->magenta_green >= -1.0 && r->magenta_green <= 1.0 &&
         isfinite (r->yellow_blue) && r->yellow_blue >= -1.0 && r->yellow_blue <= 1.0;
}

static gboolean
valid_settings (const GlimsColorBalanceSettings *s)
{
  return (s->preserve_luminosity == 0 || s->preserve_luminosity == 1) &&
         valid_range (&s->shadows) && valid_range (&s->midtones) && valid_range (&s->highlights);
}

static gboolean
equal_range (const GlimsColorBalanceRange *a, const GlimsColorBalanceRange *b)
{
  return a->cyan_red == b->cyan_red && a->magenta_green == b->magenta_green &&
         a->yellow_blue == b->yellow_blue;
}

static gboolean
valid_native_cursor (GimpTransferMode range)
{
  return range == GIMP_TRANSFER_SHADOWS || range == GIMP_TRANSFER_MIDTONES ||
         range == GIMP_TRANSFER_HIGHLIGHTS;
}

gboolean
glims_color_balance_config_is_operation (GeglNode *node)
{
  const gchar *name;
  if (!GEGL_IS_NODE (node)) return FALSE;
  name = gegl_node_get_operation (node);
  return name && strcmp (name, "gimp:color-balance") == 0;
}

static GlimsStatus
cb_point (GeglNode *node, gboolean allow_empty, GimpOperationPointFilter **out, char **error)
{
  GeglOperation *operation;
  GimpOperationPointFilter *point;

  *out = NULL;
  if (!GEGL_IS_NODE (node))
    return cb_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A filter operation is required.");
  if (!glims_color_balance_config_is_operation (node))
    return cb_error (GLIMS_STATUS_UNSUPPORTED, error,
                     "These settings are only available for Color Balance.");

  operation = gegl_node_get_gegl_operation (node);
  if (!operation || G_OBJECT_TYPE (operation) != GIMP_TYPE_OPERATION_COLOR_BALANCE)
    return cb_error (GLIMS_STATUS_FAILED, error, "The native Color Balance operation is invalid.");
  point = GIMP_OPERATION_POINT_FILTER (operation);
#if GIMP_CHECK_VERSION (3, 2, 0)
  if (point->trc_binding)
    return cb_error (GLIMS_STATUS_UNSUPPORTED, error,
                     "A bound transfer-curve configuration cannot be replaced.");
#endif
  if (point->config && G_OBJECT_TYPE (point->config) != GIMP_TYPE_COLOR_BALANCE_CONFIG)
    return cb_error (GLIMS_STATUS_FAILED, error,
                     "The native Color Balance configuration has the wrong type.");
  if (point->config &&
      g_object_class_find_property (G_OBJECT_GET_CLASS (operation), "trc") &&
      g_object_class_find_property (G_OBJECT_GET_CLASS (point->config), "trc"))
    return cb_error (GLIMS_STATUS_UNSUPPORTED, error,
                     "A transfer-curve binding would be required for this configuration.");
  if (!allow_empty && !point->config)
    return cb_error (GLIMS_STATUS_FAILED, error, "The filter has no Color Balance configuration.");

  *out = point;
  return GLIMS_STATUS_OK;
}

static GlimsStatus
read_native (GimpOperationPointFilter *point, GlimsColorBalanceSettings *tmp, char **error)
{
  GimpColorBalanceConfig *cfg = GIMP_COLOR_BALANCE_CONFIG (point->config);
  G_STATIC_ASSERT (G_N_ELEMENTS (cfg->cyan_red) == 3);
  G_STATIC_ASSERT (G_N_ELEMENTS (cfg->magenta_green) == 3);
  G_STATIC_ASSERT (G_N_ELEMENTS (cfg->yellow_blue) == 3);
  G_STATIC_ASSERT (GIMP_TRANSFER_SHADOWS >= 0 && GIMP_TRANSFER_SHADOWS < 3);
  G_STATIC_ASSERT (GIMP_TRANSFER_MIDTONES >= 0 && GIMP_TRANSFER_MIDTONES < 3);
  G_STATIC_ASSERT (GIMP_TRANSFER_HIGHLIGHTS >= 0 && GIMP_TRANSFER_HIGHLIGHTS < 3);

  if (!valid_native_cursor (cfg->range))
    return cb_error (GLIMS_STATUS_FAILED, error, "The native Color Balance range is invalid.");
  if (cfg->preserve_luminosity != FALSE && cfg->preserve_luminosity != TRUE)
    return cb_error (GLIMS_STATUS_FAILED, error,
                     "The native Color Balance preserve flag is invalid.");

  tmp->preserve_luminosity = (uint32_t) cfg->preserve_luminosity;
  tmp->shadows.cyan_red = cfg->cyan_red[GIMP_TRANSFER_SHADOWS];
  tmp->shadows.magenta_green = cfg->magenta_green[GIMP_TRANSFER_SHADOWS];
  tmp->shadows.yellow_blue = cfg->yellow_blue[GIMP_TRANSFER_SHADOWS];
  tmp->midtones.cyan_red = cfg->cyan_red[GIMP_TRANSFER_MIDTONES];
  tmp->midtones.magenta_green = cfg->magenta_green[GIMP_TRANSFER_MIDTONES];
  tmp->midtones.yellow_blue = cfg->yellow_blue[GIMP_TRANSFER_MIDTONES];
  tmp->highlights.cyan_red = cfg->cyan_red[GIMP_TRANSFER_HIGHLIGHTS];
  tmp->highlights.magenta_green = cfg->magenta_green[GIMP_TRANSFER_HIGHLIGHTS];
  tmp->highlights.yellow_blue = cfg->yellow_blue[GIMP_TRANSFER_HIGHLIGHTS];
  if (!valid_settings (tmp))
    return cb_error (GLIMS_STATUS_FAILED, error, "The native Color Balance settings are invalid.");
  return GLIMS_STATUS_OK;
}

static void
clear_own_fields (GlimsColorBalanceSettings *out)
{
  out->preserve_luminosity = 0;
  out->shadows = (GlimsColorBalanceRange) { 0.0, 0.0, 0.0 };
  out->midtones = (GlimsColorBalanceRange) { 0.0, 0.0, 0.0 };
  out->highlights = (GlimsColorBalanceRange) { 0.0, 0.0, 0.0 };
}

static void
replace_config (GimpOperationPointFilter *point, GObject *replacement)
{
  if (point->config == replacement) return;
  /* gimpoperationpointfilter.c:105 (3.0), :108 (3.2+) duplicates a ref in its
   * setter. Own the exposed field normally; operation notify invalidates GEGL. */
  g_set_object (&point->config, replacement);
  g_object_notify (G_OBJECT (point), "config");
}

static void
apply_range (GimpColorBalanceConfig *cfg, GimpTransferMode range,
             const GlimsColorBalanceRange *r)
{
  g_object_set (cfg, "range", range,
                     "cyan-red", r->cyan_red,
                     "magenta-green", r->magenta_green,
                     "yellow-blue", r->yellow_blue, NULL);
}

GlimsStatus
glims_color_balance_config_prepare (GeglNode *node, char **error)
{
  GimpOperationPointFilter *point;
  GlimsStatus status;
  GObject *config;
  GlimsColorBalanceSettings tmp = { 0 };

  if (!GEGL_IS_NODE (node))
    return cb_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A filter operation is required.");
  if (!glims_color_balance_config_is_operation (node)) return GLIMS_STATUS_OK;
  status = cb_point (node, TRUE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (point->config) { tmp.struct_size = sizeof tmp; return read_native (point, &tmp, error); }

  config = g_object_new (GIMP_TYPE_COLOR_BALANCE_CONFIG, NULL);
  if (!config)
    return cb_error (GLIMS_STATUS_FAILED, error,
                     "The Color Balance configuration could not be created.");
  /* Native init resets defaults: all zero, preserve TRUE, MIDTONES cursor. */
  replace_config (point, config);
  g_object_unref (config);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_color_balance_config_copy (GeglNode *destination, GeglNode *source, char **error)
{
  GimpOperationPointFilter *dest_point, *source_point;
  GlimsStatus status;
  GlimsColorBalanceSettings tmp = { 0 };

  status = cb_point (destination, TRUE, &dest_point, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = cb_point (source, FALSE, &source_point, error);
  if (status != GLIMS_STATUS_OK) return status;
  tmp.struct_size = sizeof tmp;
  status = read_native (source_point, &tmp, error);
  if (status != GLIMS_STATUS_OK) return status;

  /* Immutable installed ref is safe because Set duplicates before mutation;
   * preserves base/cursor/arrays via the same config object. */
  replace_config (dest_point, source_point->config);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_color_balance_config_get (GeglNode *node, GlimsColorBalanceSettings *out, char **error)
{
  GimpOperationPointFilter *point;
  GlimsStatus status;
  GlimsColorBalanceSettings tmp = { 0 };

  if (!out || out->struct_size < sizeof *out)
    return cb_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                     "A full Color Balance settings output is required.");
  /* Preserve struct_size/future tail; clear own fields before every failure. */
  clear_own_fields (out);
  status = cb_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) { clear_own_fields (out); return status; }
  tmp.struct_size = sizeof tmp;
  status = read_native (point, &tmp, error);
  if (status != GLIMS_STATUS_OK) { clear_own_fields (out); return status; }
  out->preserve_luminosity = tmp.preserve_luminosity;
  out->shadows = tmp.shadows;
  out->midtones = tmp.midtones;
  out->highlights = tmp.highlights;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_color_balance_config_set (GeglNode *node,
                                const GlimsColorBalanceSettings *settings,
                                gboolean *changed, char **error)
{
  GimpOperationPointFilter *point;
  GlimsStatus status;
  GObject *copy;
  GimpColorBalanceConfig *cfg;
  GimpTransferMode old_range;
  GlimsColorBalanceSettings current = { 0 };

  if (changed) *changed = FALSE;
  if (!changed || !settings || settings->struct_size < sizeof *settings)
    return cb_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                     "Full Color Balance settings and a change output are required.");
  if (!valid_settings (settings))
    return cb_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                     "Color Balance values must be finite, ranges in [-1, 1], and preserve 0 or 1.");

  status = cb_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  current.struct_size = sizeof current;
  status = read_native (point, &current, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (equal_range (&current.shadows, &settings->shadows) &&
      equal_range (&current.midtones, &settings->midtones) &&
      equal_range (&current.highlights, &settings->highlights) &&
      current.preserve_luminosity == settings->preserve_luminosity)
    return GLIMS_STATUS_OK;

  copy = gimp_config_duplicate (GIMP_CONFIG (point->config)); /* owned */
  if (!copy)
    return cb_error (GLIMS_STATUS_FAILED, error,
                     "The Color Balance configuration could not be copied.");
  if (G_OBJECT_TYPE (copy) != G_OBJECT_TYPE (point->config)) {
    g_object_unref (copy);
    return cb_error (GLIMS_STATUS_FAILED, error,
                     "The copied Color Balance configuration has the wrong type.");
  }
  cfg = GIMP_COLOR_BALANCE_CONFIG (copy);
  old_range = cfg->range;
  apply_range (cfg, GIMP_TRANSFER_SHADOWS, &settings->shadows);
  apply_range (cfg, GIMP_TRANSFER_MIDTONES, &settings->midtones);
  apply_range (cfg, GIMP_TRANSFER_HIGHLIGHTS, &settings->highlights);
  g_object_set (cfg, "preserve-luminosity", settings->preserve_luminosity != 0, NULL);
  g_object_set (cfg, "range", old_range, NULL); /* restore private copy cursor */
  replace_config (point, copy);
  g_object_unref (copy);
  *changed = TRUE;
  return GLIMS_STATUS_OK;
}

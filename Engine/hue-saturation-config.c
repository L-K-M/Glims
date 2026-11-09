/* Owned GlimsHueSaturationSettings; native config stays in the adapter. */
#include "hue-saturation-config.h"

#include <math.h>
#include <string.h>

#include "operations/operations-types.h"
#include "libgimpbase/gimpbase.h"
#include "libgimpconfig/gimpconfig.h"
#include "operations/gimphuesaturationconfig.h"
#include "operations/gimpoperationhuesaturation.h"
#include "operations/gimpoperationpointfilter.h"

/* Source-backed: hue-saturation-config-contract.md + native
 * gimphuesaturationconfig.[ch]/gimpoperationhuesaturation.[ch]. */

static GlimsStatus
hs_error (GlimsStatus status, char **error, const char *message)
{
  if (error) *error = strdup (message);
  return status;
}

static gboolean
valid_range (const GlimsHueSaturationRange *r)
{
  return isfinite (r->hue) && r->hue >= -1.0 && r->hue <= 1.0 &&
         isfinite (r->saturation) && r->saturation >= -1.0 && r->saturation <= 1.0 &&
         isfinite (r->lightness) && r->lightness >= -1.0 && r->lightness <= 1.0;
}

static gboolean
valid_settings (const GlimsHueSaturationSettings *s)
{
  return isfinite (s->overlap) && s->overlap >= 0.0 && s->overlap <= 1.0 &&
         valid_range (&s->master) && valid_range (&s->red) &&
         valid_range (&s->yellow) && valid_range (&s->green) &&
         valid_range (&s->cyan) && valid_range (&s->blue) &&
         valid_range (&s->magenta);
}

static gboolean
equal_range (const GlimsHueSaturationRange *a, const GlimsHueSaturationRange *b)
{
  /* Numeric ==, including signed zero equivalence; not memcmp on padding. */
  return a->hue == b->hue && a->saturation == b->saturation && a->lightness == b->lightness;
}

static gboolean
equal_settings (const GlimsHueSaturationSettings *a, const GlimsHueSaturationSettings *b)
{
  return a->overlap == b->overlap &&
         equal_range (&a->master, &b->master) &&
         equal_range (&a->red, &b->red) &&
         equal_range (&a->yellow, &b->yellow) &&
         equal_range (&a->green, &b->green) &&
         equal_range (&a->cyan, &b->cyan) &&
         equal_range (&a->blue, &b->blue) &&
         equal_range (&a->magenta, &b->magenta);
}

static gboolean
valid_native_cursor (GimpHueRange range)
{
  /* Native cursor must be one of ALL/RED/YELLOW/GREEN/CYAN/BLUE/MAGENTA. */
  return range == GIMP_HUE_RANGE_ALL ||
         range == GIMP_HUE_RANGE_RED ||
         range == GIMP_HUE_RANGE_YELLOW ||
         range == GIMP_HUE_RANGE_GREEN ||
         range == GIMP_HUE_RANGE_CYAN ||
         range == GIMP_HUE_RANGE_BLUE ||
         range == GIMP_HUE_RANGE_MAGENTA;
}

gboolean
glims_hue_saturation_config_is_operation (GeglNode *node)
{
  const gchar *name;
  if (!GEGL_IS_NODE (node)) return FALSE;
  name = gegl_node_get_operation (node);
  return name && strcmp (name, "gimp:hue-saturation") == 0;
}

static GlimsStatus
hs_point (GeglNode *node, gboolean allow_empty,
          GimpOperationPointFilter **out, char **error)
{
  GeglOperation *operation;
  GimpOperationPointFilter *point;

  *out = NULL;
  if (!GEGL_IS_NODE (node))
    return hs_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A filter operation is required.");
  if (!glims_hue_saturation_config_is_operation (node))
    return hs_error (GLIMS_STATUS_UNSUPPORTED, error,
                     "These settings are only available for Hue-Saturation.");

  operation = gegl_node_get_gegl_operation (node);
  if (!operation || G_OBJECT_TYPE (operation) != GIMP_TYPE_OPERATION_HUE_SATURATION)
    return hs_error (GLIMS_STATUS_FAILED, error, "The native Hue-Saturation operation is invalid.");
  point = GIMP_OPERATION_POINT_FILTER (operation);
#if GIMP_CHECK_VERSION (3, 2, 0)
  if (point->trc_binding)
    return hs_error (GLIMS_STATUS_UNSUPPORTED, error,
                     "A bound transfer-curve configuration cannot be replaced.");
#endif
  if (point->config && G_OBJECT_TYPE (point->config) != GIMP_TYPE_HUE_SATURATION_CONFIG)
    return hs_error (GLIMS_STATUS_FAILED, error,
                     "The native Hue-Saturation configuration has the wrong type.");
  /* Hue-Saturation has no trc property; unexpected op+cfg trc properties refused. */
  if (point->config &&
      g_object_class_find_property (G_OBJECT_GET_CLASS (operation), "trc") &&
      g_object_class_find_property (G_OBJECT_GET_CLASS (point->config), "trc"))
    return hs_error (GLIMS_STATUS_UNSUPPORTED, error,
                     "A transfer-curve binding would be required for this configuration.");
  if (!allow_empty && !point->config)
    return hs_error (GLIMS_STATUS_FAILED, error, "The filter has no Hue-Saturation configuration.");

  *out = point;
  return GLIMS_STATUS_OK;
}

static void
clear_own_fields (GlimsHueSaturationSettings *out)
{
  /* Preserve struct_size and any future tail; clear only the 22 owned doubles. */
  out->overlap = 0.0;
  out->master = (GlimsHueSaturationRange) { 0.0, 0.0, 0.0 };
  out->red = (GlimsHueSaturationRange) { 0.0, 0.0, 0.0 };
  out->yellow = (GlimsHueSaturationRange) { 0.0, 0.0, 0.0 };
  out->green = (GlimsHueSaturationRange) { 0.0, 0.0, 0.0 };
  out->cyan = (GlimsHueSaturationRange) { 0.0, 0.0, 0.0 };
  out->blue = (GlimsHueSaturationRange) { 0.0, 0.0, 0.0 };
  out->magenta = (GlimsHueSaturationRange) { 0.0, 0.0, 0.0 };
}

static GlimsStatus
read_native (GimpOperationPointFilter *point, GlimsHueSaturationSettings *tmp, char **error)
{
  GimpHueSaturationConfig *cfg = GIMP_HUE_SATURATION_CONFIG (point->config);

  /* Actual native array lengths are 7; named enum indices are 0..6. */
  G_STATIC_ASSERT (G_N_ELEMENTS (cfg->hue) == 7);
  G_STATIC_ASSERT (G_N_ELEMENTS (cfg->saturation) == 7);
  G_STATIC_ASSERT (G_N_ELEMENTS (cfg->lightness) == 7);
  G_STATIC_ASSERT (GIMP_HUE_RANGE_ALL >= 0 && GIMP_HUE_RANGE_ALL < 7);
  G_STATIC_ASSERT (GIMP_HUE_RANGE_RED >= 0 && GIMP_HUE_RANGE_RED < 7);
  G_STATIC_ASSERT (GIMP_HUE_RANGE_YELLOW >= 0 && GIMP_HUE_RANGE_YELLOW < 7);
  G_STATIC_ASSERT (GIMP_HUE_RANGE_GREEN >= 0 && GIMP_HUE_RANGE_GREEN < 7);
  G_STATIC_ASSERT (GIMP_HUE_RANGE_CYAN >= 0 && GIMP_HUE_RANGE_CYAN < 7);
  G_STATIC_ASSERT (GIMP_HUE_RANGE_BLUE >= 0 && GIMP_HUE_RANGE_BLUE < 7);
  G_STATIC_ASSERT (GIMP_HUE_RANGE_MAGENTA >= 0 && GIMP_HUE_RANGE_MAGENTA < 7);

  if (!valid_native_cursor (cfg->range))
    return hs_error (GLIMS_STATUS_FAILED, error, "The native Hue-Saturation cursor is invalid.");
  if (!isfinite (cfg->overlap) || cfg->overlap < 0.0 || cfg->overlap > 1.0)
    return hs_error (GLIMS_STATUS_FAILED, error, "The native Hue-Saturation overlap is invalid.");

  /* Read typed native arrays at named constants; never change the live cursor. */
  tmp->overlap = cfg->overlap;
  tmp->master.hue = cfg->hue[GIMP_HUE_RANGE_ALL];
  tmp->master.saturation = cfg->saturation[GIMP_HUE_RANGE_ALL];
  tmp->master.lightness = cfg->lightness[GIMP_HUE_RANGE_ALL];
  tmp->red.hue = cfg->hue[GIMP_HUE_RANGE_RED];
  tmp->red.saturation = cfg->saturation[GIMP_HUE_RANGE_RED];
  tmp->red.lightness = cfg->lightness[GIMP_HUE_RANGE_RED];
  tmp->yellow.hue = cfg->hue[GIMP_HUE_RANGE_YELLOW];
  tmp->yellow.saturation = cfg->saturation[GIMP_HUE_RANGE_YELLOW];
  tmp->yellow.lightness = cfg->lightness[GIMP_HUE_RANGE_YELLOW];
  tmp->green.hue = cfg->hue[GIMP_HUE_RANGE_GREEN];
  tmp->green.saturation = cfg->saturation[GIMP_HUE_RANGE_GREEN];
  tmp->green.lightness = cfg->lightness[GIMP_HUE_RANGE_GREEN];
  tmp->cyan.hue = cfg->hue[GIMP_HUE_RANGE_CYAN];
  tmp->cyan.saturation = cfg->saturation[GIMP_HUE_RANGE_CYAN];
  tmp->cyan.lightness = cfg->lightness[GIMP_HUE_RANGE_CYAN];
  tmp->blue.hue = cfg->hue[GIMP_HUE_RANGE_BLUE];
  tmp->blue.saturation = cfg->saturation[GIMP_HUE_RANGE_BLUE];
  tmp->blue.lightness = cfg->lightness[GIMP_HUE_RANGE_BLUE];
  tmp->magenta.hue = cfg->hue[GIMP_HUE_RANGE_MAGENTA];
  tmp->magenta.saturation = cfg->saturation[GIMP_HUE_RANGE_MAGENTA];
  tmp->magenta.lightness = cfg->lightness[GIMP_HUE_RANGE_MAGENTA];

  if (!valid_settings (tmp))
    return hs_error (GLIMS_STATUS_FAILED, error, "The native Hue-Saturation settings are invalid.");
  return GLIMS_STATUS_OK;
}

static void
replace_config (GimpOperationPointFilter *point, GObject *replacement)
{
  if (point->config == replacement) return;
  /* gimpoperationpointfilter.c: setter duplicates the ref; own the exposed field
   * normally and notify on the operation so GEGL invalidates. */
  g_set_object (&point->config, replacement);
  g_object_notify (G_OBJECT (point), "config");
}

static void
apply_range (GimpHueSaturationConfig *cfg, GimpHueRange range,
             const GlimsHueSaturationRange *r)
{
  /* Set the named native cursor, then hue/saturation/lightness for that range. */
  g_object_set (cfg, "range", range,
                     "hue", r->hue,
                     "saturation", r->saturation,
                     "lightness", r->lightness, NULL);
}

GlimsStatus
glims_hue_saturation_config_prepare (GeglNode *node, char **error)
{
  GimpOperationPointFilter *point;
  GlimsStatus status;
  GObject *config;
  GlimsHueSaturationSettings tmp = { 0 };

  if (!GEGL_IS_NODE (node))
    return hs_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A filter operation is required.");
  if (!glims_hue_saturation_config_is_operation (node)) return GLIMS_STATUS_OK;
  status = hs_point (node, TRUE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (point->config) { tmp.struct_size = sizeof tmp; return read_native (point, &tmp, error); }

  config = g_object_new (GIMP_TYPE_HUE_SATURATION_CONFIG, NULL);
  if (!config)
    return hs_error (GLIMS_STATUS_FAILED, error,
                     "The Hue-Saturation configuration could not be created.");
  /* Native init resets defaults: all 22 values zero, cursor ALL. */
  replace_config (point, config);
  g_object_unref (config);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_hue_saturation_config_copy (GeglNode *destination, GeglNode *source, char **error)
{
  GimpOperationPointFilter *dest_point, *source_point;
  GlimsStatus status;
  GlimsHueSaturationSettings tmp = { 0 };

  /* Validate actual types/binding conditions before touching destination. */
  status = hs_point (destination, TRUE, &dest_point, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = hs_point (source, FALSE, &source_point, error);
  if (status != GLIMS_STATUS_OK) return status;

  /* Validate source whole 22/cursor and existing dest whole 22/cursor when present. */
  tmp.struct_size = sizeof tmp;
  status = read_native (source_point, &tmp, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (dest_point->config)
    {
      GlimsHueSaturationSettings dest_tmp = { 0 };
      dest_tmp.struct_size = sizeof dest_tmp;
      status = read_native (dest_point, &dest_tmp, error);
      if (status != GLIMS_STATUS_OK) return status;
    }

  /* Immutable source ref share: preserves 21+overlap+cursor/base exactly.
   * Safe because Set duplicates before mutation. */
  replace_config (dest_point, source_point->config);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_hue_saturation_config_get (GeglNode *node, GlimsHueSaturationSettings *out, char **error)
{
  GimpOperationPointFilter *point;
  GlimsStatus status;
  GlimsHueSaturationSettings tmp = { 0 };

  if (!out || out->struct_size < sizeof *out)
    return hs_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                     "A full Hue-Saturation settings output is required.");
  /* Preserve struct_size/future tail; clear only own 22 doubles before failures. */
  clear_own_fields (out);

  status = hs_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) { clear_own_fields (out); return status; }

  tmp.struct_size = sizeof tmp;
  status = read_native (point, &tmp, error);
  if (status != GLIMS_STATUS_OK) { clear_own_fields (out); return status; }

  /* Temporary publish only after full validated result. */
  out->overlap = tmp.overlap;
  out->master = tmp.master;
  out->red = tmp.red;
  out->yellow = tmp.yellow;
  out->green = tmp.green;
  out->cyan = tmp.cyan;
  out->blue = tmp.blue;
  out->magenta = tmp.magenta;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_hue_saturation_config_set (GeglNode *node,
                                 const GlimsHueSaturationSettings *settings,
                                 gboolean *changed, char **error)
{
  GimpOperationPointFilter *point;
  GlimsStatus status;
  GObject *copy;
  GimpHueSaturationConfig *cfg;
  GimpHueRange old_range;
  GlimsHueSaturationSettings current = { 0 };

  if (changed) *changed = FALSE;
  if (!changed || !settings || settings->struct_size < sizeof *settings)
    return hs_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                     "Full Hue-Saturation settings and a change output are required.");
  /* Validate ALL 21 finite [-1,1] + overlap finite [0,1] before mutation. */
  if (!valid_settings (settings))
    return hs_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                     "Hue-Saturation values must be finite, hue/saturation/lightness in [-1, 1], and overlap in [0, 1].");

  status = hs_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;

  current.struct_size = sizeof current;
  status = read_native (point, &current, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (equal_settings (&current, settings))
    return GLIMS_STATUS_OK;

  /* Duplicate privately before changes; never mutate a shared source config. */
  copy = gimp_config_duplicate (GIMP_CONFIG (point->config)); /* owned */
  if (!copy)
    return hs_error (GLIMS_STATUS_FAILED, error,
                     "The Hue-Saturation configuration could not be copied.");
  if (G_OBJECT_TYPE (copy) != G_OBJECT_TYPE (point->config))
    {
      g_object_unref (copy);
      return hs_error (GLIMS_STATUS_FAILED, error,
                       "The copied Hue-Saturation configuration has the wrong type.");
    }

  cfg = GIMP_HUE_SATURATION_CONFIG (copy);
  old_range = cfg->range; /* preserve original cursor */

  /* Set each 7 range using named native constants. */
  apply_range (cfg, GIMP_HUE_RANGE_ALL, &settings->master);
  apply_range (cfg, GIMP_HUE_RANGE_RED, &settings->red);
  apply_range (cfg, GIMP_HUE_RANGE_YELLOW, &settings->yellow);
  apply_range (cfg, GIMP_HUE_RANGE_GREEN, &settings->green);
  apply_range (cfg, GIMP_HUE_RANGE_CYAN, &settings->cyan);
  apply_range (cfg, GIMP_HUE_RANGE_BLUE, &settings->blue);
  apply_range (cfg, GIMP_HUE_RANGE_MAGENTA, &settings->magenta);

  g_object_set (cfg, "overlap", settings->overlap, NULL);
  /* Restore original cursor; no live cursor change on Get, preserve UI state. */
  g_object_set (cfg, "range", old_range, NULL);

  replace_config (point, copy);
  g_object_unref (copy); /* release exactly local duplicate ref */
  *changed = TRUE;
  return GLIMS_STATUS_OK;
}

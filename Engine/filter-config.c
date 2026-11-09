/* Two owned facade values; native config objects remain inside the adapter. */
#include "filter-config.h"

#include <math.h>
#include <string.h>

#include "operations/operations-types.h"
#include "operations/gimpbrightnesscontrastconfig.h"
#include "operations/gimpoperationbrightnesscontrast.h"

static GlimsStatus
config_error (GlimsStatus status, char **error, const char *message)
{
  if (error) *error = strdup (message);
  return status;
}

static gboolean
valid_pair (double brightness, double contrast)
{
  return isfinite (brightness) && brightness >= -1.0 && brightness <= 1.0 &&
         isfinite (contrast) && contrast >= -1.0 && contrast <= 1.0;
}

gboolean
glims_filter_config_is_brightness_contrast (GeglNode *node)
{
  const gchar *name;

  if (!GEGL_IS_NODE (node)) return FALSE;
  name = gegl_node_get_operation (node); /* borrowed */
  return name && strcmp (name, "gimp:brightness-contrast") == 0;
}

/* The field is declared by the real Core header, never a mirrored layout.
 * 3.0 has no trc_binding; the exact BC operation/config have no TRC property. */
static GlimsStatus
config_point (GeglNode *node, gboolean allow_empty,
              GimpOperationPointFilter **out, char **error)
{
  GeglOperation *operation;
  GimpOperationPointFilter *point;

  *out = NULL;
  if (!GEGL_IS_NODE (node))
    return config_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                         "A filter operation is required.");
  if (!glims_filter_config_is_brightness_contrast (node))
    return config_error (GLIMS_STATUS_UNSUPPORTED, error,
                         "These settings are only available for Brightness/Contrast.");

  operation = gegl_node_get_gegl_operation (node); /* borrowed from node */
  if (!operation || G_OBJECT_TYPE (operation) != GIMP_TYPE_OPERATION_BRIGHTNESS_CONTRAST)
    return config_error (GLIMS_STATUS_FAILED, error,
                         "The native Brightness/Contrast operation is invalid.");
  point = GIMP_OPERATION_POINT_FILTER (operation);
#if GIMP_CHECK_VERSION (3, 2, 0)
  if (point->trc_binding)
    return config_error (GLIMS_STATUS_UNSUPPORTED, error,
                         "A bound transfer-curve configuration cannot be replaced.");
#endif
  if (point->config &&
      G_OBJECT_TYPE (point->config) != GIMP_TYPE_BRIGHTNESS_CONTRAST_CONFIG)
    return config_error (GLIMS_STATUS_FAILED, error,
                         "The native Brightness/Contrast configuration has the wrong type.");
  if (point->config &&
      g_object_class_find_property (G_OBJECT_GET_CLASS (operation), "trc") &&
      g_object_class_find_property (G_OBJECT_GET_CLASS (point->config), "trc"))
    return config_error (GLIMS_STATUS_UNSUPPORTED, error,
                         "A transfer-curve binding would be required for this configuration.");
  if (!allow_empty && !point->config)
    return config_error (GLIMS_STATUS_FAILED, error,
                         "The filter has no Brightness/Contrast configuration.");

  *out = point;
  return GLIMS_STATUS_OK;
}

static GlimsStatus
config_pair (GimpOperationPointFilter *point, double *brightness,
             double *contrast, char **error)
{
  g_object_get (point->config, "brightness", brightness, "contrast", contrast, NULL);
  if (!valid_pair (*brightness, *contrast))
    return config_error (GLIMS_STATUS_FAILED, error,
                         "The native Brightness/Contrast settings are invalid.");
  return GLIMS_STATUS_OK;
}

static void
replace_config (GimpOperationPointFilter *point, GObject *replacement)
{
  if (point->config == replacement) return;

  /* All four pinned gimpoperationpointfilter.c setters combine g_set_object
   * with g_value_dup_object, retaining an extra ref. Use the exposed field
   * with ordinary ref ownership instead; never compensate with extra unrefs.
   * GEGL gegl-node.c:1515-1516 listens to OPERATION notify for invalidation.
   * Native Undo/XCF setters retain their upstream reference limitation. */
  g_set_object (&point->config, replacement);
  g_object_notify (G_OBJECT (point), "config");
}

GlimsStatus
glims_filter_config_prepare (GeglNode *node, char **error)
{
  GimpOperationPointFilter *point;
  GlimsStatus status;
  GObject *config;
  double brightness, contrast;

  if (!GEGL_IS_NODE (node))
    return config_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                         "A filter operation is required.");
  if (!glims_filter_config_is_brightness_contrast (node)) return GLIMS_STATUS_OK;
  status = config_point (node, TRUE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (point->config) return config_pair (point, &brightness, &contrast, error);

  config = g_object_new (GIMP_TYPE_BRIGHTNESS_CONTRAST_CONFIG, NULL);
  if (!config)
    return config_error (GLIMS_STATUS_FAILED, error,
                         "The Brightness/Contrast configuration could not be created.");
  /* Native property defaults are 0/0, each within -1..1. */
  replace_config (point, config);
  g_object_unref (config); /* exactly our constructor reference */
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_config_copy (GeglNode *destination, GeglNode *source, char **error)
{
  GimpOperationPointFilter *dest_point, *source_point;
  GlimsStatus status;
  double brightness, contrast;

  status = config_point (destination, TRUE, &dest_point, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = config_point (source, FALSE, &source_point, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = config_pair (source_point, &brightness, &contrast, error);
  if (status != GLIMS_STATUS_OK) return status;

  /* Sharing is safe only because every subsequent Set copies first. This
   * preserves native base settings, including clip/region/mode/opacity. */
  replace_config (dest_point, source_point->config);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_config_get (GeglNode *node, GlimsBrightnessContrastSettings *out,
                         char **error)
{
  GimpOperationPointFilter *point;
  GlimsStatus status;
  double brightness, contrast;

  if (!out || out->struct_size < sizeof *out)
    return config_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                         "A full Brightness/Contrast settings output is required.");
  /* Keep struct_size and any future tail untouched; clear only our fields. */
  out->brightness = 0.0;
  out->contrast = 0.0;
  status = config_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = config_pair (point, &brightness, &contrast, error);
  if (status != GLIMS_STATUS_OK) return status;
  out->brightness = brightness;
  out->contrast = contrast;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_config_set (GeglNode *node,
                         const GlimsBrightnessContrastSettings *settings,
                         gboolean *changed, char **error)
{
  GimpOperationPointFilter *point;
  GlimsStatus status;
  GObject *copy;
  double brightness, contrast;

  if (changed) *changed = FALSE;
  if (!changed || !settings || settings->struct_size < sizeof *settings)
    return config_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                         "Full Brightness/Contrast settings and a change output are required.");
  if (!valid_pair (settings->brightness, settings->contrast))
    return config_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
                         "Brightness and contrast must be finite values between -1 and 1.");

  status = config_point (node, FALSE, &point, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = config_pair (point, &brightness, &contrast, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (brightness == settings->brightness && contrast == settings->contrast)
    return GLIMS_STATUS_OK;

  copy = gimp_config_duplicate (GIMP_CONFIG (point->config)); /* owned */
  if (!copy)
    return config_error (GLIMS_STATUS_FAILED, error,
                         "The Brightness/Contrast configuration could not be copied.");
  if (G_OBJECT_TYPE (copy) != G_OBJECT_TYPE (point->config)) {
    g_object_unref (copy);
    return config_error (GLIMS_STATUS_FAILED, error,
                         "The copied Brightness/Contrast configuration has the wrong type.");
  }
  g_object_set (copy, "brightness", settings->brightness,
                      "contrast", settings->contrast, NULL);
  replace_config (point, copy);
  g_object_unref (copy); /* field holds its own ordinary reference */
  *changed = TRUE;
  return GLIMS_STATUS_OK;
}

#include "stroke-dynamics-fingerprint.h"
#include "core/gimpcurve.h"
#include "core/gimpdynamics.h"
#include "core/gimpdynamicsoutput.h"
#include "core/gimpobject.h"

#include <math.h>
#include <string.h>

/* The installed stock Pressure Size source is 215511 bytes on all four
 * pins. The V1 subset admits at most 1 MiB of serialized configuration.
 * Native curves have 256 samples; bound editable points and object counts
 * before serialization as well, including inactive curves. */
#define DYNAMICS_CONFIG_MAX_BYTES (1024u * 1024u)
#define DYNAMICS_MAX_PROPERTIES 128u
#define DYNAMICS_MAX_OUTPUTS 32u
#define DYNAMICS_MAX_CURVES 16u
#define DYNAMICS_MAX_POINTS 256
#define DYNAMICS_MAX_NAME_BYTES 255u

static gboolean
curve_supported (GimpCurve *curve)
{
  if (!curve || G_OBJECT_TYPE (curve) != GIMP_TYPE_CURVE)
    return FALSE;
  gint count = gimp_curve_get_n_points (curve);
  if (count < 0 || count > DYNAMICS_MAX_POINTS ||
      gimp_curve_get_n_samples (curve) != 256 || !curve->samples ||
      (count && !curve->points) ||
      (curve->curve_type != GIMP_CURVE_SMOOTH && curve->curve_type != GIMP_CURVE_FREE))
    return FALSE;
  for (gint i = 0; i < count; i++)
    if (!isfinite (curve->points[i].x) || !isfinite (curve->points[i].y) ||
        (curve->points[i].type != GIMP_CURVE_POINT_SMOOTH &&
         curve->points[i].type != GIMP_CURVE_POINT_CORNER))
      return FALSE;
  for (gint i = 0; i < 256; i++)
    if (!isfinite (curve->samples[i]))
      return FALSE;
  return TRUE;
}

static gboolean
output_supported (GimpDynamicsOutput *output, gboolean size_output)
{
  if (!output || G_OBJECT_TYPE (output) != GIMP_TYPE_DYNAMICS_OUTPUT)
    return FALSE;
  guint count = 0, curves = 0;
  g_autofree GParamSpec **properties = g_object_class_list_properties (G_OBJECT_GET_CLASS (output), &count);
  if (count > DYNAMICS_MAX_PROPERTIES)
    return FALSE;
  gboolean saw_pressure = FALSE, saw_pressure_curve = FALSE;
  for (guint i = 0; i < count; i++)
    {
      GParamSpec *spec = properties[i];
      if (g_str_has_prefix (spec->name, "use-"))
        {
          if (!G_IS_PARAM_SPEC_BOOLEAN (spec) || !(spec->flags & G_PARAM_READABLE))
            return FALSE;
          gboolean active = FALSE;
          g_object_get (output, spec->name, &active, NULL);
          gboolean pressure = !strcmp (spec->name, "use-pressure");
          if (active != (size_output && pressure))
            return FALSE;
          saw_pressure |= pressure;
        }
      else if (g_type_is_a (spec->value_type, GIMP_TYPE_CURVE))
        {
          if (!(spec->flags & G_PARAM_READABLE) || ++curves > DYNAMICS_MAX_CURVES)
            return FALSE;
          GimpCurve *curve = NULL;
          g_object_get (output, spec->name, &curve, NULL);
          gboolean supported = curve_supported (curve);
          g_clear_object (&curve);
          if (!supported) return FALSE;
          saw_pressure_curve |= !strcmp (spec->name, "pressure-curve");
        }
      else if ((spec->flags & GIMP_CONFIG_PARAM_SERIALIZE) &&
               !(spec->flags & GIMP_CONFIG_PARAM_IGNORE))
        return FALSE;
    }
  return saw_pressure && saw_pressure_curve &&
         gimp_dynamics_output_is_enabled (output) == size_output;
}

static gboolean
dynamics_supported (GimpDynamics *dynamics)
{
  if (!dynamics || G_OBJECT_TYPE (dynamics) != GIMP_TYPE_DYNAMICS)
    return FALSE;
  const gchar *name = gimp_object_get_name (GIMP_OBJECT (dynamics));
  if (name && strnlen (name, DYNAMICS_MAX_NAME_BYTES + 1) > DYNAMICS_MAX_NAME_BYTES)
    return FALSE;
  GimpDynamicsOutput *size_output = gimp_dynamics_get_output (dynamics, GIMP_DYNAMICS_OUTPUT_SIZE);
  if (!size_output) return FALSE;

  guint count = 0, outputs = 0, size_outputs = 0;
  g_autofree GParamSpec **properties = g_object_class_list_properties (G_OBJECT_GET_CLASS (dynamics), &count);
  if (count > DYNAMICS_MAX_PROPERTIES)
    return FALSE;
  for (guint i = 0; i < count; i++)
    {
      GParamSpec *spec = properties[i];
      if (g_type_is_a (spec->value_type, GIMP_TYPE_DYNAMICS_OUTPUT))
        {
          if (!(spec->flags & G_PARAM_READABLE) || ++outputs > DYNAMICS_MAX_OUTPUTS)
            return FALSE;
          GimpDynamicsOutput *output = NULL;
          g_object_get (dynamics, spec->name, &output, NULL);
          gboolean is_size = output == size_output;
          gboolean supported = output_supported (output, is_size);
          g_clear_object (&output);
          if (!supported || (is_size && ++size_outputs > 1)) return FALSE;
        }
      else if ((spec->flags & GIMP_CONFIG_PARAM_SERIALIZE) &&
               !(spec->flags & GIMP_CONFIG_PARAM_IGNORE) &&
               (strcmp (spec->name, "name") || spec->value_type != G_TYPE_STRING))
        return FALSE;
    }
  return size_outputs == 1;
}

gchar *
glims_stroke_dynamics_fingerprint (gboolean enabled, GimpDynamics *dynamics)
{
  g_autofree gchar *serialized = NULL;
  gsize length = 0;
  if (enabled)
    {
      if (!dynamics_supported (dynamics))
        return NULL;
      serialized = gimp_config_serialize_to_string (GIMP_CONFIG (dynamics), NULL);
      if (!serialized) return NULL;
      length = strnlen (serialized, DYNAMICS_CONFIG_MAX_BYTES + 1);
      if (!length || length > DYNAMICS_CONFIG_MAX_BYTES ||
          !g_utf8_validate (serialized, (gssize) length, NULL))
        return NULL;
    }

  static const guchar domain[] = "Glims stroke dynamics fingerprint v1";
  const guchar mode = enabled ? 1 : 0;
  GChecksum *sum = g_checksum_new (G_CHECKSUM_SHA256);
  g_checksum_update (sum, domain, sizeof domain);
  g_checksum_update (sum, &mode, sizeof mode);
  if (enabled) g_checksum_update (sum, (const guchar *) serialized, length + 1);
  gchar *digest = g_strdup (g_checksum_get_string (sum));
  g_checksum_free (sum);
  return digest;
}

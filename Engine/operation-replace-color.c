/* Adapter-owned Replace Color. Every setting is an ordinary scalar property
 * so native effect copying and XCF persistence preserve the complete value.
 * The weight kernel and the Hue-Saturation master mapping are documented in
 * replace-color-math.h. No upstream source changes or GUI dependencies. */
#include "engine-private.h"
#include "operation-replace-color.h"
#include "replace-color-math.h"

#include <math.h>
#include <string.h>

#include <operation/gegl-operation-point-filter.h>

#include <cairo.h>

#include "libgimpcolor/gimpcolor.h"

typedef struct {
  GeglOperationPointFilter parent;
  GlimsReplaceColorSettings settings;
} GlimsOperationReplaceColor;

typedef struct {
  GeglOperationPointFilterClass parent;
} GlimsOperationReplaceColorClass;

enum {
  PROP_NONE,
  PROP_FUZZINESS,
  PROP_SAMPLE_COUNT,
  PROP_FIRST_SAMPLE,
  PROP_FIRST_SUBTRACT = PROP_FIRST_SAMPLE + (gint) GLIMS_REPLACE_COLOR_MAX_SAMPLES,
  PROP_HUE = PROP_FIRST_SUBTRACT + (gint) GLIMS_REPLACE_COLOR_MAX_SAMPLES,
  PROP_SATURATION,
  PROP_LIGHTNESS
};

G_DEFINE_TYPE (GlimsOperationReplaceColor, glims_operation_replace_color,
               GEGL_TYPE_OPERATION_POINT_FILTER)

static double *
double_value (GlimsOperationReplaceColor *self, guint property)
{
  switch (property)
    {
    case PROP_FUZZINESS:   return &self->settings.fuzziness;
    case PROP_HUE:         return &self->settings.hue;
    case PROP_SATURATION:  return &self->settings.saturation;
    case PROP_LIGHTNESS:   return &self->settings.lightness;
    default:               return NULL;
    }
}

static GlimsCRSample *
sample_value (GlimsOperationReplaceColor *self, guint property)
{
  guint index = property - PROP_FIRST_SAMPLE;

  return index < GLIMS_REPLACE_COLOR_MAX_SAMPLES ? &self->settings.samples[index] : NULL;
}

static uint32_t *
subtract_value (GlimsOperationReplaceColor *self, guint property)
{
  guint index = property - PROP_FIRST_SUBTRACT;

  return index < GLIMS_REPLACE_COLOR_MAX_SAMPLES
    ? &self->settings.samples[index].subtract : NULL;
}

static void
color_to_sample (GlimsCRSample *sample, GeglColor *color)
{
  gdouble rgba[4] = { 0.0, 0.0, 0.0, 1.0 };

  if (color)
    gegl_color_get_pixel (color, babl_format ("R'G'B'A double"), rgba);
  sample->red = rgba[0];
  sample->green = rgba[1];
  sample->blue = rgba[2];
}

static GeglColor *
sample_to_color (const GlimsCRSample *sample)
{
  GeglColor *color = gegl_color_new ("black");
  gdouble    rgba[4] = { sample->red, sample->green, sample->blue, 1.0 };

  gegl_color_set_pixel (color, babl_format ("R'G'B'A double"), rgba);
  return color;
}

static void
set_property (GObject *object, guint property, const GValue *value, GParamSpec *spec)
{
  GlimsOperationReplaceColor *self = (GlimsOperationReplaceColor *) object;
  double                     *number;
  GlimsCRSample              *sample;
  uint32_t                   *subtract;

  if (property == PROP_SAMPLE_COUNT)
    {
      self->settings.sample_count = (uint32_t) g_value_get_int (value);
      return;
    }
  if ((number = double_value (self, property)) != NULL)
    {
      *number = g_value_get_double (value);
      return;
    }
  if ((sample = sample_value (self, property)) != NULL)
    {
      color_to_sample (sample, g_value_get_object (value));
      return;
    }
  if ((subtract = subtract_value (self, property)) != NULL)
    {
      *subtract = g_value_get_boolean (value) ? 1 : 0;
      return;
    }
  G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property, spec);
}

static void
get_property (GObject *object, guint property, GValue *value, GParamSpec *spec)
{
  GlimsOperationReplaceColor *self = (GlimsOperationReplaceColor *) object;
  const double               *number;
  const GlimsCRSample        *sample;
  const uint32_t             *subtract;

  if (property == PROP_SAMPLE_COUNT)
    {
      g_value_set_int (value, (gint) self->settings.sample_count);
      return;
    }
  if ((number = double_value (self, property)) != NULL)
    {
      g_value_set_double (value, *number);
      return;
    }
  if ((sample = sample_value (self, property)) != NULL)
    {
      g_value_take_object (value, sample_to_color (sample));
      return;
    }
  if ((subtract = subtract_value (self, property)) != NULL)
    {
      g_value_set_boolean (value, *subtract != 0);
      return;
    }
  G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property, spec);
}

static void
prepare (GeglOperation *operation)
{
  const Babl *format = babl_format_with_space ("R~G~B~A float",
                                               gegl_operation_get_format (operation, "input"));
  gegl_operation_set_format (operation, "input", format);
  gegl_operation_set_format (operation, "output", format);
}

static gboolean
process (GeglOperation *operation, void *input, void *output, glong samples,
         const GeglRectangle *roi, gint level)
{
  GlimsOperationReplaceColor *self = (GlimsOperationReplaceColor *) operation;

  (void) roi;
  (void) level;
  if (samples < 0 || ! glims_replace_color_settings_valid (&self->settings))
    return FALSE;
  glims_replace_color_apply (&self->settings, input, output, (size_t) samples);
  return TRUE;
}

/* GLib keeps static property names and labels by pointer, so they live
 * in static tables rather than a reused buffer. */
static const gchar *const sample_names[] = {
  "sample-0", "sample-1", "sample-2", "sample-3",
  "sample-4", "sample-5", "sample-6", "sample-7" };
static const gchar *const sample_labels[] = {
  "Sample 1", "Sample 2", "Sample 3", "Sample 4",
  "Sample 5", "Sample 6", "Sample 7", "Sample 8" };
static const gchar *const subtract_names[] = {
  "subtract-0", "subtract-1", "subtract-2", "subtract-3",
  "subtract-4", "subtract-5", "subtract-6", "subtract-7" };
static const gchar *const subtract_labels[] = {
  "Subtract sample 1", "Subtract sample 2", "Subtract sample 3", "Subtract sample 4",
  "Subtract sample 5", "Subtract sample 6", "Subtract sample 7", "Subtract sample 8" };
G_STATIC_ASSERT (G_N_ELEMENTS (sample_names) == GLIMS_REPLACE_COLOR_MAX_SAMPLES);
G_STATIC_ASSERT (G_N_ELEMENTS (sample_labels) == GLIMS_REPLACE_COLOR_MAX_SAMPLES);
G_STATIC_ASSERT (G_N_ELEMENTS (subtract_names) == GLIMS_REPLACE_COLOR_MAX_SAMPLES);
G_STATIC_ASSERT (G_N_ELEMENTS (subtract_labels) == GLIMS_REPLACE_COLOR_MAX_SAMPLES);

static void
glims_operation_replace_color_class_init (GlimsOperationReplaceColorClass *klass)
{
  GObjectClass                  *object = G_OBJECT_CLASS (klass);
  GeglOperationClass            *operation = GEGL_OPERATION_CLASS (klass);
  GeglOperationPointFilterClass *point = GEGL_OPERATION_POINT_FILTER_CLASS (klass);
  GeglColor                     *black = gegl_color_new ("black");
  guint                          i;

  object->get_property = get_property;
  object->set_property = set_property;
  operation->prepare = prepare;
  point->process = process;
  gegl_operation_class_set_keys (operation,
                                 "name", "glims:replace-color",
                                 "title", "Replace Color",
                                 "categories", "color",
                                 "description", "Replace colors near sampled colors",
                                 NULL);
  GIMP_CONFIG_PROP_DOUBLE (object, PROP_FUZZINESS, "fuzziness", "Fuzziness", NULL,
                           0.0, 200.0, 40.0, GIMP_PARAM_STATIC_STRINGS);
  GIMP_CONFIG_PROP_INT (object, PROP_SAMPLE_COUNT, "sample-count", "Sample count", NULL,
                        0, (gint) GLIMS_REPLACE_COLOR_MAX_SAMPLES, 0,
                        GIMP_PARAM_STATIC_STRINGS);
  for (i = 0; i < GLIMS_REPLACE_COLOR_MAX_SAMPLES; i++)
    {
      GIMP_CONFIG_PROP_COLOR (object, PROP_FIRST_SAMPLE + i, sample_names[i], sample_labels[i], NULL,
                              FALSE, black, GIMP_PARAM_STATIC_STRINGS);
    }
  for (i = 0; i < GLIMS_REPLACE_COLOR_MAX_SAMPLES; i++)
    {
      GIMP_CONFIG_PROP_BOOLEAN (object, PROP_FIRST_SUBTRACT + i, subtract_names[i], subtract_labels[i], NULL,
                                FALSE, GIMP_PARAM_STATIC_STRINGS);
    }
  GIMP_CONFIG_PROP_DOUBLE (object, PROP_HUE, "hue", "Hue", NULL,
                           -180.0, 180.0, 0.0, GIMP_PARAM_STATIC_STRINGS);
  GIMP_CONFIG_PROP_DOUBLE (object, PROP_SATURATION, "saturation", "Saturation", NULL,
                           -100.0, 100.0, 0.0, GIMP_PARAM_STATIC_STRINGS);
  GIMP_CONFIG_PROP_DOUBLE (object, PROP_LIGHTNESS, "lightness", "Lightness", NULL,
                           -100.0, 100.0, 0.0, GIMP_PARAM_STATIC_STRINGS);
  g_object_unref (black);
}

static void
glims_operation_replace_color_init (GlimsOperationReplaceColor *self)
{
  self->settings.fuzziness = 40.0;
}

void
glims_operation_replace_color_register (void)
{
  g_type_class_ref (glims_operation_replace_color_get_type ());
  /* Refresh GEGL's name cache after the new in-process type registers. */
  g_warn_if_fail (gegl_has_operation ("glims:replace-color"));
}

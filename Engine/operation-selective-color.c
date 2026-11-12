/* Adapter-owned Selective Color. Each range stores all four adjustments
 * as ordinary scalar properties so native effect copying and XCF persistence
 * preserve the complete value. Pixel math and its input policy are documented
 * in selective-color-math.h. No upstream source changes or GUI dependencies. */
#include "engine-private.h"
#include "operation-selective-color.h"
#include "selective-color-math.h"

#include <operation/gegl-operation-point-filter.h>

typedef struct {
  GeglOperationPointFilter parent;
  GlimsSelectiveColorSettings settings;
} GlimsOperationSelectiveColor;

typedef struct {
  GeglOperationPointFilterClass parent;
} GlimsOperationSelectiveColorClass;

enum { PROP_NONE, PROP_RELATIVE, PROP_FIRST_ADJUSTMENT };
static const struct { const char *name; const char *label; } adjustments[] = {
  { "red-cyan", "Reds: Cyan" },
  { "red-magenta", "Reds: Magenta" },
  { "red-yellow", "Reds: Yellow" },
  { "red-black", "Reds: Black" },
  { "yellow-cyan", "Yellows: Cyan" },
  { "yellow-magenta", "Yellows: Magenta" },
  { "yellow-yellow", "Yellows: Yellow" },
  { "yellow-black", "Yellows: Black" },
  { "green-cyan", "Greens: Cyan" },
  { "green-magenta", "Greens: Magenta" },
  { "green-yellow", "Greens: Yellow" },
  { "green-black", "Greens: Black" },
  { "cyan-cyan", "Cyans: Cyan" },
  { "cyan-magenta", "Cyans: Magenta" },
  { "cyan-yellow", "Cyans: Yellow" },
  { "cyan-black", "Cyans: Black" },
  { "blue-cyan", "Blues: Cyan" },
  { "blue-magenta", "Blues: Magenta" },
  { "blue-yellow", "Blues: Yellow" },
  { "blue-black", "Blues: Black" },
  { "magenta-cyan", "Magentas: Cyan" },
  { "magenta-magenta", "Magentas: Magenta" },
  { "magenta-yellow", "Magentas: Yellow" },
  { "magenta-black", "Magentas: Black" },
  { "white-cyan", "Whites: Cyan" },
  { "white-magenta", "Whites: Magenta" },
  { "white-yellow", "Whites: Yellow" },
  { "white-black", "Whites: Black" },
  { "neutral-cyan", "Neutrals: Cyan" },
  { "neutral-magenta", "Neutrals: Magenta" },
  { "neutral-yellow", "Neutrals: Yellow" },
  { "neutral-black", "Neutrals: Black" },
  { "black-cyan", "Blacks: Cyan" },
  { "black-magenta", "Blacks: Magenta" },
  { "black-yellow", "Blacks: Yellow" },
  { "black-black", "Blacks: Black" }
};

G_DEFINE_TYPE (GlimsOperationSelectiveColor, glims_operation_selective_color,
               GEGL_TYPE_OPERATION_POINT_FILTER)

static double *
adjustment_value (GlimsOperationSelectiveColor *self, guint property)
{
  guint index = property - PROP_FIRST_ADJUSTMENT;
  if (index >= G_N_ELEMENTS (adjustments)) return NULL;
  GlimsSelectiveColorRange *range = &self->settings.ranges[index / 4];
  switch (index % 4)
    {
    case 0: return &range->c;
    case 1: return &range->m;
    case 2: return &range->y;
    default: return &range->k;
    }
}

static void
set_property (GObject *object, guint property, const GValue *value, GParamSpec *spec)
{
  GlimsOperationSelectiveColor *self = (GlimsOperationSelectiveColor *) object;
  if (property == PROP_RELATIVE) self->settings.relative = g_value_get_boolean (value);
  else
    {
      double *target = adjustment_value (self, property);
      if (target) *target = g_value_get_double (value);
      else G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property, spec);
    }
}

static void
get_property (GObject *object, guint property, GValue *value, GParamSpec *spec)
{
  GlimsOperationSelectiveColor *self = (GlimsOperationSelectiveColor *) object;
  if (property == PROP_RELATIVE) g_value_set_boolean (value, self->settings.relative);
  else
    {
      const double *source = adjustment_value (self, property);
      if (source) g_value_set_double (value, *source);
      else G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property, spec);
    }
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
  GlimsOperationSelectiveColor *self = (GlimsOperationSelectiveColor *) operation;
  (void) roi;
  (void) level;
  if (samples < 0 || !glims_selective_color_settings_validate (&self->settings)) return FALSE;
  glims_selective_color_apply (&self->settings, input, output, (size_t) samples);
  return TRUE;
}

static void
glims_operation_selective_color_class_init (GlimsOperationSelectiveColorClass *klass)
{
  GObjectClass *object = G_OBJECT_CLASS (klass);
  GeglOperationClass *operation = GEGL_OPERATION_CLASS (klass);
  GeglOperationPointFilterClass *point = GEGL_OPERATION_POINT_FILTER_CLASS (klass);
  object->get_property = get_property;
  object->set_property = set_property;
  operation->prepare = prepare;
  point->process = process;
  gegl_operation_class_set_keys (operation,
                                 "name", "glims:selective-color",
                                 "title", "Selective Color",
                                 "categories", "color",
                                 "description", "Adjust color components within selected color ranges",
                                 NULL);
  GIMP_CONFIG_PROP_BOOLEAN (object, PROP_RELATIVE, "relative", "Relative", NULL,
                            TRUE, GIMP_PARAM_STATIC_STRINGS);
  for (guint i = 0; i < G_N_ELEMENTS (adjustments); i++)
    GIMP_CONFIG_PROP_DOUBLE (object, PROP_FIRST_ADJUSTMENT + i,
                             adjustments[i].name, adjustments[i].label, NULL,
                             -1.0, 1.0, 0.0, GIMP_PARAM_STATIC_STRINGS);
}

static void
glims_operation_selective_color_init (GlimsOperationSelectiveColor *self)
{
  self->settings.relative = true;
}

void
glims_operation_selective_color_register (void)
{
  g_type_class_ref (glims_operation_selective_color_get_type ());
  /* Refresh GEGL's name cache after the new in-process type registers. */
  g_warn_if_fail (gegl_has_operation ("glims:selective-color"));
}

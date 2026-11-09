/*
 * GEGL operation discovery and the typed parameters of a live filter
 * session, for native filter forms. Runs on the engine thread.
 *
 * The operation list follows the gate GIMP applies to non-destructive
 * filters: gimp_gegl_op_nde_allowed() on 3.2+, which rejects sources,
 * sinks, debug and other hidden categories, a name blacklist and the
 * unsafe gegl:gegl (app/gegl/gimp-gegl-utils.c). 3.0.x has no such
 * function — its drawable-filter-new checks only sinks, gegl:gegl and
 * gegl:nop inline (app/pdb/drawable-filter-cmds.c) — so the 3.2 gate is
 * reproduced below for it, keeping the list the same on every engine.
 *
 * Property metadata mirrors libgimp's pspec-to-wire mapping
 * (_gimp_param_spec_to_gp_param_def, libgimp/gimpgpparams-body.c):
 * numbers, integers, booleans, enum nicks, strings and colors cross the
 * facade; every other kind is reported UNSUPPORTED. Enum values cross as
 * nicks, never as the engine's raw integers, and the choice list honors
 * each spec's excluded values like app/core/gimpdrawablefilter.c does.
 */
#include "engine-private.h"
#include "levels-config.h"
#include "curves-config.h"

#include <math.h>
#include <string.h>

/* Not part of gegl.h: the spec structs (ui ranges, excluded enum values)
 * and the sink check. */
#include <gegl-paramspecs.h>
#include <operation/gegl-operation-sink.h>

#include "core/gimp.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpimage.h"
#include "operations/gimp-operation-config.h"

#if GIMP_CHECK_VERSION (3, 2, 0)
#include "gegl/gimp-gegl-utils.h"
#endif

/* ---- The NDE gate ------------------------------------------------------ */

#if ! GIMP_CHECK_VERSION (3, 2, 0)

/* Comes from gegl/operation/gegl-operations.h which is not public. */
GType gegl_operation_gtype_from_name (const gchar *name);

/* The 3.2 gate, gimp_gegl_op_blacklisted() with block_gimp_ops FALSE as
 * gimp_gegl_op_nde_allowed() calls it (the flag only adds the "gimp:"
 * prefix check). The category and name lists are 3.2's verbatim. */
static gboolean
op_allowed (const gchar *name)
{
  static const gchar * const category_blacklist[] =
  {
    "compositors",
    "core",
    "debug",
    "display",
    "hidden",
    "input",
    "output",
    "programming",
    "transform",
    "video"
  };
  static const gchar * const category_exceptions[] =
  {
    "gimp:offset",
  };
  static const gchar * const name_blacklist[] =
  {
    "gegl:color",
    "gegl:contrast-curve",
    "gegl:convert-format",
    "gegl:ditto",
    "gegl:fill-path",
    "gegl:gray",
    "gegl:hstack",
    "gegl:introspect",
    "gegl:json:dropshadow2",
    "gegl:json:grey2",
    "gegl:layer",
    "gegl:lcms-from-profile",
    "gegl:linear-gradient",
    "gegl:map-absolute",
    "gegl:map-relative",
    "gegl:matting-global",
    "gegl:matting-levin",
    "gegl:nop",
    "gegl:opacity",
    "gegl:pack",
    "gegl:path",
    "gegl:posterize",
    "gegl:radial-gradient",
    "gegl:rectangle",
    "gegl:seamless-clone",
    "gegl:text",
    "gegl:threshold",
    "gegl:tile",
    "gegl:unpremul",
    "gegl:vector-stroke",
    "gegl:wavelet-blur",
  };

  GType       op_type;
  const gchar *category_keys;
  gchar      **categories;
  gint         i;

  if (! name)
    return FALSE;

  /* the same testing flag upstream's gate honors */
  if (g_getenv ("GIMP_TESTING_NO_GEGL_BLACKLIST"))
    return TRUE;

  for (i = 0; i < G_N_ELEMENTS (category_exceptions); i++)
    {
      if (g_strcmp0 (name, category_exceptions[i]) == 0)
        return TRUE;
    }

  for (i = 0; i < G_N_ELEMENTS (name_blacklist); i++)
    {
      if (! strcmp (name, name_blacklist[i]))
        return FALSE;
    }

  if (g_strcmp0 (name, "gegl:gegl") == 0)
    return g_getenv ("GIMP_ALLOW_GEGL_GRAPH_LAYER_EFFECT") != NULL;

  category_keys = gegl_operation_get_key (name, "categories");
  categories    = category_keys ? g_strsplit (category_keys, ":", 0) : NULL;
  for (i = 0; categories && categories[i]; i++)
    {
      gint j;

      for (j = 0; j < G_N_ELEMENTS (category_blacklist); j++)
        {
          if (! strcmp (categories[i], category_blacklist[j]))
            {
              g_strfreev (categories);
              return FALSE;
            }
        }
    }
  g_strfreev (categories);

  /* Sinks write files; 3.0.x's drawable-filter-new rejects them inline,
   * 3.2's gate rejects them too. */
  op_type = gegl_operation_gtype_from_name (name);
  if (g_type_is_a (op_type, GEGL_TYPE_OPERATION_SINK))
    return FALSE;

  return TRUE;
}

#else

static gboolean
op_allowed (const gchar *name)
{
  GError   *error = NULL;
  gboolean  allowed;

  allowed = gimp_gegl_op_nde_allowed (name, &error);
  g_clear_error (&error);

  return allowed;
}

#endif

gboolean
glims_filter_operation_allowed (const gchar *name)
{
  return gegl_has_operation (name) && op_allowed (name);
}

/* Whether a native form can drive the operation. */
static uint32_t
op_support (GlimsEngine *engine, const gchar *name)
{
  GeglNode *node;
  gboolean  aux = FALSE;

  if (gimp_operation_config_is_custom (engine->gimp, name))
    return GLIMS_FILTER_OP_CONFIG;

  /* The aux pad is created in attach() for some ops (gegl:displace,
   * gegl:watershed-transform), so the class property list cannot see it;
   * the node is instantiated and checked as drawable-cmds.c does. */
  node = gegl_node_new_child (NULL, "operation", name, NULL);
  if (node)
    {
      aux = gegl_node_has_pad (node, "aux");
      g_object_unref (node);
    }

  return aux ? GLIMS_FILTER_OP_AUX_INPUT : GLIMS_FILTER_OP_SUPPORTED;
}

/* ---- Properties --------------------------------------------------------- */

static uint32_t
property_kind (const GParamSpec *pspec)
{
  GType type = G_PARAM_SPEC_TYPE (pspec);

  if (type == GEGL_TYPE_PARAM_DOUBLE || type == G_TYPE_PARAM_DOUBLE ||
      type == G_TYPE_PARAM_FLOAT)
    return GLIMS_FILTER_VALUE_NUMBER;
  if (type == GEGL_TYPE_PARAM_INT || type == GEGL_TYPE_PARAM_SEED ||
      type == G_TYPE_PARAM_INT || type == G_TYPE_PARAM_UINT ||
      type == G_TYPE_PARAM_UCHAR)
    return GLIMS_FILTER_VALUE_INTEGER;
  if (type == G_TYPE_PARAM_BOOLEAN)
    return GLIMS_FILTER_VALUE_BOOL;
  if (G_IS_PARAM_SPEC_ENUM (pspec))
    return GLIMS_FILTER_VALUE_ENUM;
  if (GEGL_IS_PARAM_SPEC_COLOR (pspec))
    return GLIMS_FILTER_VALUE_COLOR;
  if (G_IS_PARAM_SPEC_STRING (pspec))
    return GLIMS_FILTER_VALUE_STRING;
  return GLIMS_FILTER_VALUE_UNSUPPORTED;
}

static gboolean
enum_value_excluded (GParamSpec *pspec, gint value)
{
  GeglParamSpecEnum *espec;
  GSList            *iter;

  if (! GEGL_IS_PARAM_SPEC_ENUM (pspec))
    return FALSE;

  espec = GEGL_PARAM_SPEC_ENUM (pspec);
  for (iter = espec->excluded_values; iter; iter = iter->next)
    if (GPOINTER_TO_INT (iter->data) == value)
      return TRUE;
  return FALSE;
}

/* The values a form may pick: inside the enum class's window minus the
 * spec's excluded values, as gimp_drawable_filter_update() counts them. */
static gboolean
enum_value_allowed (GParamSpec *pspec, GEnumClass *klass, const GEnumValue *value)
{
  return value->value >= klass->minimum && value->value <= klass->maximum &&
         ! enum_value_excluded (pspec, value->value);
}

static gint
enum_choice_count (GParamSpec *pspec)
{
  GEnumClass *klass;
  GEnumValue *value;
  gint        count = 0;

  klass = g_type_class_ref (G_PARAM_SPEC_VALUE_TYPE (pspec));
  for (value = klass->values; value->value_name; value++)
    if (enum_value_allowed (pspec, klass, value))
      count++;
  g_type_class_unref (klass);

  return count;
}

static void
copy_string (char *target, size_t size, const gchar *text)
{
  g_strlcpy (target, text ? text : "", size);
}

static void
property_row (GParamSpec *pspec, GlimsFilterProperty *row)
{
  memset (row, 0, sizeof *row);

  copy_string (row->name, sizeof row->name, g_param_spec_get_name (pspec));
  copy_string (row->label, sizeof row->label, g_param_spec_get_nick (pspec));
  copy_string (row->blurb, sizeof row->blurb, g_param_spec_get_blurb (pspec));
  copy_string (row->unit, sizeof row->unit,
               gegl_param_spec_get_property_key (pspec, "unit"));
  row->kind = property_kind (pspec);

  switch (row->kind)
    {
    case GLIMS_FILTER_VALUE_NUMBER:
      {
        if (G_IS_PARAM_SPEC_DOUBLE (pspec))
          {
            GParamSpecDouble *spec = G_PARAM_SPEC_DOUBLE (pspec);

            row->min            = spec->minimum;
            row->max            = spec->maximum;
            row->default_number = spec->default_value;
          }
        else
          {
            GParamSpecFloat *spec = G_PARAM_SPEC_FLOAT (pspec);

            row->min            = spec->minimum;
            row->max            = spec->maximum;
            row->default_number = spec->default_value;
          }

        row->ui_min    = row->min;
        row->ui_max    = row->max;
        row->ui_gamma  = 1.0;
        row->ui_digits = -1;

        if (GEGL_IS_PARAM_SPEC_DOUBLE (pspec))
          {
            GeglParamSpecDouble *gspec = GEGL_PARAM_SPEC_DOUBLE (pspec);

            row->ui_min        = gspec->ui_minimum;
            row->ui_max        = gspec->ui_maximum;
            row->ui_gamma      = gspec->ui_gamma;
            row->ui_step_small = gspec->ui_step_small;
            row->ui_step_big   = gspec->ui_step_big;
            row->ui_digits     = gspec->ui_digits;
          }
      }
      break;

    case GLIMS_FILTER_VALUE_INTEGER:
      {
        if (G_IS_PARAM_SPEC_INT (pspec))
          {
            GParamSpecInt *spec = G_PARAM_SPEC_INT (pspec);

            row->min            = spec->minimum;
            row->max            = spec->maximum;
            row->default_number = spec->default_value;
          }
        else if (G_IS_PARAM_SPEC_UINT (pspec))
          {
            GParamSpecUInt *spec = G_PARAM_SPEC_UINT (pspec);

            row->min            = spec->minimum;
            row->max            = spec->maximum;
            row->default_number = spec->default_value;
          }
        else if (G_IS_PARAM_SPEC_UCHAR (pspec))
          {
            GParamSpecUChar *spec = G_PARAM_SPEC_UCHAR (pspec);

            row->min            = spec->minimum;
            row->max            = spec->maximum;
            row->default_number = spec->default_value;
          }

        row->ui_min    = row->min;
        row->ui_max    = row->max;
        row->ui_gamma  = 1.0;
        row->ui_digits = -1;

        if (GEGL_IS_PARAM_SPEC_INT (pspec))
          {
            GeglParamSpecInt *gspec = GEGL_PARAM_SPEC_INT (pspec);

            row->ui_min        = gspec->ui_minimum;
            row->ui_max        = gspec->ui_maximum;
            row->ui_gamma      = gspec->ui_gamma;
            row->ui_step_small = gspec->ui_step_small;
            row->ui_step_big   = gspec->ui_step_big;
          }
        else if (GEGL_IS_PARAM_SPEC_SEED (pspec))
          {
            GeglParamSpecSeed *gspec = GEGL_PARAM_SPEC_SEED (pspec);

            row->ui_min = gspec->ui_minimum;
            row->ui_max = gspec->ui_maximum;
          }
      }
      break;

    case GLIMS_FILTER_VALUE_BOOL:
      row->default_bool = G_PARAM_SPEC_BOOLEAN (pspec)->default_value ? true : false;
      break;

    case GLIMS_FILTER_VALUE_ENUM:
      {
        GParamSpecEnum *spec = G_PARAM_SPEC_ENUM (pspec);
        GEnumValue     *value;

        row->choice_count = enum_choice_count (pspec);
        value = g_enum_get_value (spec->enum_class, spec->default_value);
        if (value)
          copy_string (row->default_string, sizeof row->default_string, value->value_nick);
      }
      break;

    case GLIMS_FILTER_VALUE_STRING:
      copy_string (row->default_string, sizeof row->default_string,
                   G_PARAM_SPEC_STRING (pspec)->default_value);
      break;

    case GLIMS_FILTER_VALUE_COLOR:
      {
        GeglColor *color = gegl_param_spec_color_get_default (pspec);
        gdouble    rgba[4] = { 0.0, 0.0, 0.0, 1.0 };

        if (color)
          gegl_color_get_pixel (color, babl_format ("R'G'B'A double"), rgba);
        row->default_color = (GlimsColor) { rgba[0], rgba[1], rgba[2], rgba[3] };
      }
      break;

    default:
      break;
    }
}

/* A session's settable properties live on the operation's class; pads
 * and the node's own properties ("operation") are not filter settings. */
static GParamSpec *
session_property (GeglNode *node, const gchar *name)
{
  GeglOperation *op = gegl_node_get_gegl_operation (node);

  if (! op)
    return NULL;

  return g_object_class_find_property (G_OBJECT_GET_CLASS (op), name);
}

/* ---- Facade calls ------------------------------------------------------- */

GlimsStatus
glims_filter_operations (GlimsEngine        *engine,
                         GlimsOperationInfo *rows,
                         gint32              capacity,
                         gint32             *count)
{
  gchar **names;
  guint   n_names, i;
  gint32  total = 0;

  if (! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  names = gegl_list_operations (&n_names);
  for (i = 0; i < n_names; i++)
    {
      const gchar *name = names[i];

      if (! glims_filter_operation_allowed (name))
        continue;

      if (rows && total < capacity)
        {
          GlimsOperationInfo *row = &rows[total];

          memset (row, 0, sizeof *row);
          copy_string (row->name, sizeof row->name, name);
          copy_string (row->title, sizeof row->title,
                       gegl_operation_get_key (name, "title"));
          copy_string (row->categories, sizeof row->categories,
                       gegl_operation_get_key (name, "categories"));
          copy_string (row->blurb, sizeof row->blurb,
                       gegl_operation_get_key (name, "description"));
          row->support = op_support (engine, name);
        }
      total++;
    }
  g_free (names);

  *count = total;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_operation_properties (GlimsEngine          *engine,
                                   const gchar          *operation,
                                   GlimsFilterProperty  *rows,
                                   gint32                capacity,
                                   gint32               *count)
{
  GParamSpec **pspecs;
  guint        n_specs, i;
  gint32       total = 0;

  if (! operation || ! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (! glims_filter_operation_allowed (operation))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  pspecs = gegl_operation_list_properties (operation, &n_specs);
  for (i = 0; i < n_specs; i++)
    {
      GParamSpec *pspec = pspecs[i];

      /* Match app/operations/gimp-operation-config.c. GEGL marks even
       * ordinary numeric settings with GEGL_PARAM_PAD_INPUT, so those
       * flags do not distinguish graph pads from editable settings. */
      if (! (pspec->flags & G_PARAM_READABLE) ||
          ! (pspec->flags & G_PARAM_WRITABLE) ||
          ! strcmp (pspec->name, "input") || ! strcmp (pspec->name, "output"))
        continue;

      if (rows && total < capacity)
        property_row (pspec, &rows[total]);
      total++;
    }
  g_free (pspecs);

  *count = total;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_enum_choices (GlimsEngine           *engine,
                           const gchar           *operation,
                           const gchar           *property,
                           GlimsFilterEnumChoice *rows,
                           gint32                 capacity,
                           gint32                *count)
{
  GParamSpec *pspec;
  GEnumClass *klass;
  GEnumValue *value;
  gint32      total = 0;

  if (! operation || ! property || ! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (! glims_filter_operation_allowed (operation))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  pspec = gegl_operation_find_property (operation, property);
  if (! pspec)
    return GLIMS_STATUS_NOT_FOUND;
  if (property_kind (pspec) != GLIMS_FILTER_VALUE_ENUM)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  klass = g_type_class_ref (G_PARAM_SPEC_VALUE_TYPE (pspec));
  for (value = klass->values; value->value_name; value++)
    {
      if (! enum_value_allowed (pspec, klass, value))
        continue;
      if (rows && total < capacity)
        {
          GlimsFilterEnumChoice *row = &rows[total];

          memset (row, 0, sizeof *row);
          copy_string (row->nick, sizeof row->nick, value->value_nick);
          copy_string (row->label, sizeof row->label, value->value_name);
        }
      total++;
    }
  g_type_class_unref (klass);

  *count = total;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_get_property (GlimsEngine       *engine,
                           GlimsFilterID      id,
                           const gchar       *property,
                           GlimsFilterValue  *value)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  GParamSpec  *pspec;
  GValue       current = G_VALUE_INIT;
  uint32_t     kind;

  if (! session)
    return GLIMS_STATUS_NOT_FOUND;
  if (! property || ! value)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  pspec = session_property (session->operation, property);
  if (! pspec)
    {
      /* Pads some ops create per instance (displace's aux) are not on the
       * class either; they are still refused as pads, not unknown. */
      return gegl_node_has_pad (session->operation, property) ? GLIMS_STATUS_INVALID_ARGUMENT
                                                            : GLIMS_STATUS_NOT_FOUND;
    }
  if (gegl_node_has_pad (session->operation, property) ||
      ! (pspec->flags & G_PARAM_READABLE))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  kind = property_kind (pspec);
  if (kind == GLIMS_FILTER_VALUE_UNSUPPORTED)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  memset (value, 0, sizeof *value);
  value->kind = kind;

  g_value_init (&current, G_PARAM_SPEC_VALUE_TYPE (pspec));
  gegl_node_get_property (session->operation, property, &current);

  switch (kind)
    {
    case GLIMS_FILTER_VALUE_NUMBER:
      value->number = G_VALUE_HOLDS_DOUBLE (&current) ? g_value_get_double (&current)
                                                      : g_value_get_float (&current);
      break;

    case GLIMS_FILTER_VALUE_INTEGER:
      if (G_VALUE_HOLDS_INT (&current))
        value->integer = g_value_get_int (&current);
      else if (G_VALUE_HOLDS_UINT (&current))
        value->integer = g_value_get_uint (&current);
      else
        value->integer = g_value_get_uchar (&current);
      break;

    case GLIMS_FILTER_VALUE_BOOL:
      value->boolean = g_value_get_boolean (&current) ? true : false;
      break;

    case GLIMS_FILTER_VALUE_ENUM:
      {
        GEnumClass *klass  = g_type_class_ref (G_PARAM_SPEC_VALUE_TYPE (pspec));
        GEnumValue *choice = g_enum_get_value (klass, g_value_get_enum (&current));

        if (choice)
          copy_string (value->string, sizeof value->string, choice->value_nick);
        g_type_class_unref (klass);
      }
      break;

    case GLIMS_FILTER_VALUE_STRING:
      copy_string (value->string, sizeof value->string, g_value_get_string (&current));
      break;

    case GLIMS_FILTER_VALUE_COLOR:
      {
        GeglColor *color = g_value_get_object (&current);
        gdouble    rgba[4] = { 0.0, 0.0, 0.0, 1.0 };

        if (color)
          gegl_color_get_pixel (color, babl_format ("R'G'B'A double"), rgba);
        value->color = (GlimsColor) { rgba[0], rgba[1], rgba[2], rgba[3] };
      }
      break;
    }

  g_value_unset (&current);

  return GLIMS_STATUS_OK;
}

static GlimsStatus
filter_set_value (GlimsFilter          *session,
                  GParamSpec           *pspec,
                  const GlimsFilterValue *value)
{
  GValue   typed  = G_VALUE_INIT;
  GeglColor *color = NULL;
  gboolean  valid  = FALSE;

  g_value_init (&typed, G_PARAM_SPEC_VALUE_TYPE (pspec));

  switch (value->kind)
    {
    case GLIMS_FILTER_VALUE_NUMBER:
      {
        double minimum, maximum;

        if (G_IS_PARAM_SPEC_DOUBLE (pspec))
          {
            minimum = G_PARAM_SPEC_DOUBLE (pspec)->minimum;
            maximum = G_PARAM_SPEC_DOUBLE (pspec)->maximum;
          }
        else
          {
            minimum = G_PARAM_SPEC_FLOAT (pspec)->minimum;
            maximum = G_PARAM_SPEC_FLOAT (pspec)->maximum;
          }

        if (isfinite (value->number) && value->number >= minimum && value->number <= maximum)
          {
            if (G_VALUE_HOLDS_DOUBLE (&typed))
              g_value_set_double (&typed, value->number);
            else
              g_value_set_float (&typed, (gfloat) value->number);
            valid = TRUE;
          }
      }
      break;

    case GLIMS_FILTER_VALUE_INTEGER:
      {
        gint64 minimum = 0, maximum = 0;

        if (G_IS_PARAM_SPEC_INT (pspec))
          {
            minimum = G_PARAM_SPEC_INT (pspec)->minimum;
            maximum = G_PARAM_SPEC_INT (pspec)->maximum;
          }
        else if (G_IS_PARAM_SPEC_UINT (pspec))
          {
            minimum = G_PARAM_SPEC_UINT (pspec)->minimum;
            maximum = G_PARAM_SPEC_UINT (pspec)->maximum;
          }
        else if (G_IS_PARAM_SPEC_UCHAR (pspec))
          {
            minimum = G_PARAM_SPEC_UCHAR (pspec)->minimum;
            maximum = G_PARAM_SPEC_UCHAR (pspec)->maximum;
          }

        if (value->integer >= minimum && value->integer <= maximum)
          {
            if (G_VALUE_HOLDS_INT (&typed))
              g_value_set_int (&typed, (gint) value->integer);
            else if (G_VALUE_HOLDS_UINT (&typed))
              g_value_set_uint (&typed, (guint) value->integer);
            else
              g_value_set_uchar (&typed, (guchar) value->integer);
            valid = TRUE;
          }
      }
      break;

    case GLIMS_FILTER_VALUE_BOOL:
      g_value_set_boolean (&typed, value->boolean);
      valid = TRUE;
      break;

    case GLIMS_FILTER_VALUE_ENUM:
      {
        GEnumClass *klass;
        GEnumValue *choice;

        if (! memchr (value->string, 0, sizeof value->string))
          break;

        klass = g_type_class_ref (G_PARAM_SPEC_VALUE_TYPE (pspec));
        for (choice = klass->values; choice->value_name; choice++)
          {
            if (enum_value_allowed (pspec, klass, choice) &&
                ! strcmp (choice->value_nick, value->string))
              {
                g_value_set_enum (&typed, choice->value);
                valid = TRUE;
                break;
              }
          }
        g_type_class_unref (klass);
      }
      break;

    case GLIMS_FILTER_VALUE_STRING:
      if (memchr (value->string, 0, sizeof value->string) &&
          g_utf8_validate (value->string, -1, NULL))
        {
          g_value_set_string (&typed, value->string);
          valid = TRUE;
        }
      break;

    case GLIMS_FILTER_VALUE_COLOR:
      {
        gdouble rgba[4] = { value->color.red, value->color.green,
                            value->color.blue, value->color.alpha };
        gint    i;

        valid = TRUE;
        for (i = 0; i < 4; i++)
          if (! isfinite (rgba[i]) || rgba[i] < 0.0 || rgba[i] > 1.0)
            valid = FALSE;

        if (valid)
          {
            color = gegl_color_new (NULL);
            gegl_color_set_pixel (color, babl_format ("R'G'B'A double"), rgba);
            g_value_set_object (&typed, color);
          }
      }
      break;

    default:
      break;
    }

  if (! valid)
    {
      g_value_unset (&typed);
      g_clear_object (&color);
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  gegl_node_set_property (session->operation, pspec->name, &typed);
  g_value_unset (&typed);
  g_clear_object (&color);

  /* The same re-apply as glims_filter_set_double: a live preview pushes
   * no undo; the pending commit covers every change as one step. */
  glims_filter_preview_apply (session);
  gimp_image_flush (session->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_set_property (GlimsEngine            *engine,
                           GlimsFilterID           id,
                           const gchar            *property,
                           const GlimsFilterValue *value)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  GParamSpec  *pspec;
  GlimsStatus status = glims_filter_check_edit (engine, id, NULL);

  if (status != GLIMS_STATUS_OK) return status;
  if (! property || ! value)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  pspec = session_property (session->operation, property);
  if (! pspec)
    return gegl_node_has_pad (session->operation, property) ? GLIMS_STATUS_INVALID_ARGUMENT
                                                          : GLIMS_STATUS_NOT_FOUND;
  if (gegl_node_has_pad (session->operation, property) ||
      ! (pspec->flags & G_PARAM_WRITABLE))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  /* Typed point-filter configs own the operation/config TRC together.
   * An operation-only generic write would break that invariant. */
  if (!strcmp (pspec->name, "trc") &&
      (glims_levels_config_is_operation (session->operation) ||
       glims_curves_config_is_operation (session->operation)))
    return GLIMS_STATUS_UNSUPPORTED;
  if (property_kind (pspec) != value->kind ||
      value->kind == GLIMS_FILTER_VALUE_UNSUPPORTED)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  return filter_set_value (session, pspec, value);
}

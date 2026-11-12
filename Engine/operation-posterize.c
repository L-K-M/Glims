/* GIMP - The GNU Image Manipulation Program
 * Copyright (C) 1995 Spencer Kimball and Peter Mattis
 *
 * gimpoperationposterize.c
 * Copyright (C) 2007 Michael Natterer <mitch@gimp.org>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * The adapter's own posterize operation, glims:posterize.
 *
 * gimp:posterize (app/operations/gimpoperationposterize.c) quantizes all
 * four channels, so a partially transparent layer loses its exact alpha:
 * at 3 levels alpha 32 comes back 0 and alpha 224 comes back 255. This
 * operation is the same code restricted to color: the same levels
 * property and the same R~G~B~A float formats in the source's color
 * space, but the alpha word is copied bit-for-bit.
 *
 * Out-of-gamut and HDR RGB values follow upstream's policy: they are
 * quantized like any other value, never clamped into 0..1. With
 * non-finite input the result is non-finite, also as upstream.
 *
 * Registration happens once on engine start (engine.c, right after
 * gimp_gegl_init): holding the class reference puts the type in GEGL's
 * operation lookup the same way gimp_operations_init() does for GIMP's
 * in-process operations, before gimp_restore() and the plug-in catalogs
 * enumerate them. "levels" is an ordinary GObject property, so the
 * config facade and the XCF effect writer handle it like any
 * gimp:/gegl: operation's settings.
 */
#include "engine-private.h"
#include "operation-posterize.h"

#include <math.h>

#include <operation/gegl-operation-point-filter.h>

#include "libgimpmath/gimpmath.h"

#include "gimp-intl.h"


#define GLIMS_TYPE_OPERATION_POSTERIZE            (glims_operation_posterize_get_type ())
#define GLIMS_OPERATION_POSTERIZE(obj)            (G_TYPE_CHECK_INSTANCE_CAST ((obj), GLIMS_TYPE_OPERATION_POSTERIZE, GlimsOperationPosterize))
#define GLIMS_OPERATION_POSTERIZE_CLASS(klass)    (G_TYPE_CHECK_CLASS_CAST ((klass),  GLIMS_TYPE_OPERATION_POSTERIZE, GlimsOperationPosterizeClass))
#define GLIMS_IS_OPERATION_POSTERIZE(obj)         (G_TYPE_CHECK_INSTANCE_TYPE ((obj), GLIMS_TYPE_OPERATION_POSTERIZE))
#define GLIMS_IS_OPERATION_POSTERIZE_CLASS(klass) (G_TYPE_CHECK_CLASS_TYPE ((klass),  GLIMS_TYPE_OPERATION_POSTERIZE))
#define GLIMS_OPERATION_POSTERIZE_GET_CLASS(obj)  (G_TYPE_INSTANCE_GET_CLASS ((obj),  GLIMS_TYPE_OPERATION_POSTERIZE, GlimsOperationPosterizeClass))


typedef struct _GlimsOperationPosterize      GlimsOperationPosterize;
typedef struct _GlimsOperationPosterizeClass GlimsOperationPosterizeClass;

struct _GlimsOperationPosterize
{
  GeglOperationPointFilter  parent_instance;

  gint                      levels;
};

struct _GlimsOperationPosterizeClass
{
  GeglOperationPointFilterClass  parent_class;
};


enum
{
  PROP_0,
  PROP_LEVELS
};


static void     glims_operation_posterize_get_property (GObject             *object,
                                                        guint                property_id,
                                                        GValue              *value,
                                                        GParamSpec          *pspec);
static void     glims_operation_posterize_set_property (GObject             *object,
                                                        guint                property_id,
                                                        const GValue        *value,
                                                        GParamSpec          *pspec);

static void     glims_operation_posterize_prepare      (GeglOperation       *operation);

static gboolean glims_operation_posterize_process      (GeglOperation       *operation,
                                                        void                *in_buf,
                                                        void                *out_buf,
                                                        glong                samples,
                                                        const GeglRectangle *roi,
                                                        gint                 level);


G_DEFINE_TYPE (GlimsOperationPosterize, glims_operation_posterize,
               GEGL_TYPE_OPERATION_POINT_FILTER)

#define parent_class glims_operation_posterize_parent_class


static void
glims_operation_posterize_class_init (GlimsOperationPosterizeClass *klass)
{
  GObjectClass                  *object_class    = G_OBJECT_CLASS (klass);
  GeglOperationClass            *operation_class = GEGL_OPERATION_CLASS (klass);
  GeglOperationPointFilterClass *point_class     = GEGL_OPERATION_POINT_FILTER_CLASS (klass);

  object_class->set_property = glims_operation_posterize_set_property;
  object_class->get_property = glims_operation_posterize_get_property;
  operation_class->prepare   = glims_operation_posterize_prepare;
  point_class->process       = glims_operation_posterize_process;

  gegl_operation_class_set_keys (operation_class,
                                 "name",        "glims:posterize",
                                 "title",       _("Posterize"),
                                 "categories",  "color",
                                 "description", _("Reduce to a limited set of colors, keeping the source alpha"),
                                 NULL);

  GIMP_CONFIG_PROP_INT (object_class, PROP_LEVELS,
                        "levels",
                        _("Posterize levels"),
                        NULL,
                        2, 256, 3,
                        GIMP_PARAM_STATIC_STRINGS);
}

static void
glims_operation_posterize_init (GlimsOperationPosterize *self)
{
}

static void
glims_operation_posterize_get_property (GObject    *object,
                                        guint       property_id,
                                        GValue     *value,
                                        GParamSpec *pspec)
{
  GlimsOperationPosterize *posterize = GLIMS_OPERATION_POSTERIZE (object);

  switch (property_id)
    {
    case PROP_LEVELS:
      g_value_set_int (value, posterize->levels);
      break;

    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
      break;
    }
}

static void
glims_operation_posterize_set_property (GObject      *object,
                                        guint         property_id,
                                        const GValue *value,
                                        GParamSpec   *pspec)
{
  GlimsOperationPosterize *posterize = GLIMS_OPERATION_POSTERIZE (object);

  switch (property_id)
    {
    case PROP_LEVELS:
      posterize->levels = g_value_get_int (value);
      break;

    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
      break;
    }
}

static void
glims_operation_posterize_prepare (GeglOperation *operation)
{
  const Babl *format = babl_format_with_space ("R~G~B~A float",
                                               gegl_operation_get_format (operation, "input"));

  gegl_operation_set_format (operation, "input", format);
  gegl_operation_set_format (operation, "output", format);
}

static gboolean
glims_operation_posterize_process (GeglOperation       *operation,
                                   void                *in_buf,
                                   void                *out_buf,
                                   glong                samples,
                                   const GeglRectangle *roi,
                                   gint                 level)
{
  GlimsOperationPosterize *posterize = GLIMS_OPERATION_POSTERIZE (operation);
  gfloat                  *src       = in_buf;
  gfloat                  *dest      = out_buf;
  gfloat                   levels;

  levels = posterize->levels - 1.0;

  while (samples--)
    {
      dest[RED]   = RINT (src[RED]   * levels) / levels;
      dest[GREEN] = RINT (src[GREEN] * levels) / levels;
      dest[BLUE]  = RINT (src[BLUE]  * levels) / levels;
      dest[ALPHA] = src[ALPHA];

      src  += 4;
      dest += 4;
    }

  return TRUE;
}

/* Called once on engine start, after gimp_gegl_init(). */
void
glims_operation_posterize_register (void)
{
  g_type_class_ref (GLIMS_TYPE_OPERATION_POSTERIZE);

  /* gegl_list_operations() returns a cached list; it is rebuilt only when
   * this lookup observes the type-registration serial change made by the
   * class ref above. */
  g_warn_if_fail (gegl_has_operation ("glims:posterize"));
}

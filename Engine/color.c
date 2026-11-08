/*
 * Image color state and conversions: the color model, precision and
 * effective color profile the engine reports, and the mode and
 * precision conversions. The conversions are single validated calls
 * into GIMP's own GUI-free core (app/core/gimpimage-convert-type.c,
 * app/core/gimpimage-convert-precision.c), which open their own undo
 * group, so each is exactly one undo step; everything the core would
 * refuse is validated before the call, so a refused call mutates
 * nothing. Runs on the engine thread.
 */
#include "engine-private.h"

#include <string.h>

#include <cairo.h>

#include "gegl/gimp-babl.h"
#include "libgimpcolor/gimpcolor.h"

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-convert-precision.h"
#include "core/gimpimage-convert-type.h"

/* ---- Facade <-> engine enum mapping ------------------------------------ */
/* The engine's enum values never cross the facade; these switches are
 * the only place they meet. */

static uint32_t
facade_mode (GimpImageBaseType type)
{
  switch (type)
    {
    case GIMP_RGB:     return GLIMS_COLOR_MODE_RGB;
    case GIMP_GRAY:    return GLIMS_COLOR_MODE_GRAYSCALE;
    case GIMP_INDEXED: return GLIMS_COLOR_MODE_INDEXED;
    default:           return GLIMS_COLOR_MODE_UNKNOWN;
    }
}

/* The engine base type of a facade mode, or FALSE for an unknown value.
 * GIMP_INDEXED is reported as unsupported by the caller: converting to
 * indexed needs a palette and dither policy, a later slice. */
static gboolean
engine_mode (uint32_t           mode,
             GimpImageBaseType *type)
{
  switch (mode)
    {
    case GLIMS_COLOR_MODE_RGB:       *type = GIMP_RGB;  return TRUE;
    case GLIMS_COLOR_MODE_GRAYSCALE: *type = GIMP_GRAY; return TRUE;
    default:                                            return FALSE;
    }
}

static uint32_t
facade_component (GimpComponentType type)
{
  switch (type)
    {
    case GIMP_COMPONENT_TYPE_U8:     return GLIMS_COLOR_COMPONENT_U8;
    case GIMP_COMPONENT_TYPE_U16:    return GLIMS_COLOR_COMPONENT_U16;
    case GIMP_COMPONENT_TYPE_U32:    return GLIMS_COLOR_COMPONENT_U32;
    case GIMP_COMPONENT_TYPE_HALF:   return GLIMS_COLOR_COMPONENT_HALF;
    case GIMP_COMPONENT_TYPE_FLOAT:  return GLIMS_COLOR_COMPONENT_FLOAT;
    case GIMP_COMPONENT_TYPE_DOUBLE: return GLIMS_COLOR_COMPONENT_DOUBLE;
    default:                         return GLIMS_COLOR_COMPONENT_UNKNOWN;
    }
}

static gboolean
engine_component (uint32_t           component,
                  GimpComponentType *type)
{
  switch (component)
    {
    case GLIMS_COLOR_COMPONENT_U8:     *type = GIMP_COMPONENT_TYPE_U8;     return TRUE;
    case GLIMS_COLOR_COMPONENT_U16:    *type = GIMP_COMPONENT_TYPE_U16;    return TRUE;
    case GLIMS_COLOR_COMPONENT_U32:    *type = GIMP_COMPONENT_TYPE_U32;    return TRUE;
    case GLIMS_COLOR_COMPONENT_HALF:   *type = GIMP_COMPONENT_TYPE_HALF;   return TRUE;
    case GLIMS_COLOR_COMPONENT_FLOAT:  *type = GIMP_COMPONENT_TYPE_FLOAT;  return TRUE;
    case GLIMS_COLOR_COMPONENT_DOUBLE: *type = GIMP_COMPONENT_TYPE_DOUBLE; return TRUE;
    default:                                                          return FALSE;
    }
}

static uint32_t
facade_trc (GimpTRCType trc)
{
  switch (trc)
    {
    case GIMP_TRC_LINEAR:     return GLIMS_COLOR_TRC_LINEAR;
    case GIMP_TRC_NON_LINEAR: return GLIMS_COLOR_TRC_NONLINEAR;
    case GIMP_TRC_PERCEPTUAL: return GLIMS_COLOR_TRC_PERCEPTUAL;
    default:                  return GLIMS_COLOR_TRC_UNKNOWN;
    }
}

static gboolean
engine_trc (uint32_t     trc,
            GimpTRCType *type)
{
  switch (trc)
    {
    case GLIMS_COLOR_TRC_LINEAR:     *type = GIMP_TRC_LINEAR;     return TRUE;
    case GLIMS_COLOR_TRC_NONLINEAR:  *type = GIMP_TRC_NON_LINEAR; return TRUE;
    case GLIMS_COLOR_TRC_PERCEPTUAL: *type = GIMP_TRC_PERCEPTUAL; return TRUE;
    default:                                                   return FALSE;
    }
}

/* ---- Color state -------------------------------------------------------- */

GlimsStatus
glims_image_color_info (GlimsEngine   *engine,
                        GlimsImageID   id,
                        GlimsColorInfo *info)
{
  GlimsOpenImage   *open = glims_lookup_image (engine, id);
  GimpImage        *image;
  GimpPrecision     precision;
  GimpColorProfile *profile;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! info)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  image     = open->image;
  precision = gimp_image_get_precision (image);

  memset (info, 0, sizeof (*info));
  info->mode      = facade_mode (gimp_image_get_base_type (image));
  info->component = facade_component (gimp_babl_component_type (precision));
  info->trc       = facade_trc (gimp_babl_trc (precision));

  /* Embedded means an ICC profile parasite travels with the image (and
   * so with its files); the label is the effective profile's — the
   * image's own when it has one, the engine's builtin fallback for its
   * model otherwise (gimp_image_color_managed_get_color_profile). */
  info->profile_embedded = gimp_image_get_icc_parasite (image) != NULL;
  profile = gimp_color_managed_get_color_profile (GIMP_COLOR_MANAGED (image));
  if (profile)
    {
      const gchar *label = gimp_color_profile_get_label (profile);

      if (label)
        g_strlcpy (info->profile_label, label, sizeof (info->profile_label));
      g_object_unref (profile);
    }

  return GLIMS_STATUS_OK;
}

/* ---- Mode conversion ---------------------------------------------------- */

GlimsStatus
glims_image_convert_mode (GlimsEngine  *engine,
                          GlimsImageID  id,
                          uint32_t      mode,
                          char        **error)
{
  GlimsOpenImage   *open = glims_lookup_image (engine, id);
  GimpImageBaseType new_type;
  GlimsStatus       status;
  GError           *gerror = NULL;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  if (mode == GLIMS_COLOR_MODE_INDEXED)
    {
      /* gimp_image_convert_type refuses indexed targets itself; the
       * palette and dither policy are a later slice. */
      if (error)
        *error = strdup ("Converting an image to indexed color is not supported yet.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (! engine_mode (mode, &new_type))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* A no-op changes nothing and pushes no undo step; the core call
   * would refuse it. */
  if (new_type == gimp_image_get_base_type (open->image))
    return GLIMS_STATUS_OK;

  /* One validated core conversion. A NULL dest_profile leaves the
   * profile choice to the core, which picks the builtin profile of the
   * new model when grayscale is involved; assigning or converting the
   * profile itself is a later slice. The core opens its own undo group
   * (Convert Image to RGB / Grayscale), so the whole call is one undo
   * step and cannot leave a partial change behind. */
  if (! gimp_image_convert_type (open->image, new_type, NULL, NULL, &gerror))
    return glims_fail (error, gerror, "The image could not be converted.");

  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

/* ---- Precision conversion ------------------------------------------------ */

GlimsStatus
glims_image_convert_precision (GlimsEngine  *engine,
                               GlimsImageID  id,
                               uint32_t      component,
                               uint32_t      trc,
                               char        **error)
{
  GlimsOpenImage    *open = glims_lookup_image (engine, id);
  GimpComponentType  comp;
  GimpTRCType        trc_type;
  GimpPrecision      precision;
  GlimsStatus        status;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! engine_component (component, &comp) || ! engine_trc (trc, &trc_type))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  precision = gimp_babl_precision (comp, trc_type);

  /* The combinations the engine actually accepts: every component/TRC
   * pair for RGB and grayscale, only u8 non-linear for indexed
   * (gimp_babl_is_valid). */
  if (! gimp_babl_is_valid (gimp_image_get_base_type (open->image), precision))
    {
      if (error)
        *error = strdup ("Indexed images keep 8-bit non-linear precision.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* A no-op changes nothing and pushes no undo step; the core call
   * would refuse it. */
  if (precision == gimp_image_get_precision (open->image))
    return GLIMS_STATUS_OK;

  /* One validated core conversion with no dithering, as one undo step
   * (the core's own undo group, "Convert Image to <precision>"). */
  gimp_image_convert_precision (open->image, precision,
                                GEGL_DITHER_NONE, GEGL_DITHER_NONE, GEGL_DITHER_NONE,
                                NULL);
  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

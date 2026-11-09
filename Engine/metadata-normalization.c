/*
 * Private metadata copy normalization. See metadata-normalization.h for the
 * caller contract and the native evidence.
 *
 * Native evidence (pinned engine sets, all four identical):
 *   GIMP_3_2_8 7addd2b77efb798bbdc4d2fb082e786a48478ced
 *   GIMP_3_2_0 edbd1ea7384e63efa8fe326dd79ffe4fbe6722db
 *   master     5374deeec14a0366df4b17b6e5c6f9aff63db2ca
 *   GIMP_3_0_8 6ac8031c9555667e080fef0324fca9f28a02e5ab
 *   app/core/gimpimage-metadata.c:
 *     gimp_image_set_metadata                 57-84
 *     gimp_image_metadata_update_pixel_size   87-101
 *     gimp_image_metadata_update_bits_per_sample 104-135
 *     gimp_image_metadata_update_resolution   138-154
 *     gimp_image_metadata_update_colorspace   157-189
 */
#include "metadata-normalization.h"
#include "engine-private.h"

#include <cairo.h>

#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-metadata.h"
#include "libgimpbase/gimpmetadata.h"
#include "libgimpcolor/gimpcolor.h"

GlimsStatus
glims_metadata_normalize_private_copy (GimpImage    *image,
                                       GimpMetadata *copy,
                                       char        **error)
{
  GimpColorProfile       *profile = NULL;
  GimpColorProfile       *adobe   = NULL;
  GimpMetadataColorspace  space;
  gint                    bits;
  gdouble                 xres;
  gdouble                 yres;
  GimpUnit               *unit;

  if (! image || ! copy)
    {
      if (error)
        *error = g_strdup ("Both the image and its private metadata copy "
                           "are required.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* The image's own metadata is borrowed for this check only; normalizing
   * it in place would mutate the image without Undo or any write
   * authorization. */
  if (copy == gimp_image_get_metadata (image))
    {
      if (error)
        *error = g_strdup ("The metadata copy must be detached from the "
                           "image; the image's own metadata is never "
                           "normalized in place.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* Preflight the two facts that can fail before any setter touches the
   * copy. The native bits switch has no default and would silently skip an
   * unknown component type; the native colorspace path builds the Adobe
   * profile lazily and leaks it in a static. */
  switch (gimp_image_get_component_type (image))
    {
    case GIMP_COMPONENT_TYPE_U8:     bits = 8;  break;
    case GIMP_COMPONENT_TYPE_U16:
    case GIMP_COMPONENT_TYPE_HALF:   bits = 16; break;
    case GIMP_COMPONENT_TYPE_U32:
    case GIMP_COMPONENT_TYPE_FLOAT:  bits = 32; break;
    case GIMP_COMPONENT_TYPE_DOUBLE: bits = 64; break;
    default:
      if (error)
        *error = g_strdup ("The image component type has no metadata bit "
                           "depth.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  profile = gimp_image_get_color_profile (image);   /* borrowed */
  if (profile)
    {
      adobe = gimp_color_profile_new_rgb_adobe ();
      if (! adobe)
        {
          if (error)
            *error = g_strdup ("The Adobe RGB profile could not be "
                               "constructed.");
          return GLIMS_STATUS_FAILED;
        }
      space = gimp_color_profile_is_equal (profile, adobe)
                ? GIMP_METADATA_COLORSPACE_ADOBERGB
                : GIMP_METADATA_COLORSPACE_UNSPECIFIED;
      g_object_unref (adobe);
    }
  else
    {
      space = GIMP_METADATA_COLORSPACE_SRGB;
    }

  gimp_image_get_resolution (image, &xres, &yres);
  unit = gimp_image_get_unit (image);

  /* Native order: pixel size, bits per sample, resolution, colorspace. */
  gimp_metadata_set_pixel_size (copy,
                                gimp_image_get_width (image),
                                gimp_image_get_height (image));
  gimp_metadata_set_bits_per_sample (copy, bits);
  gimp_metadata_set_resolution (copy, xres, yres, unit);
  gimp_metadata_set_colorspace (copy, space);

  return GLIMS_STATUS_OK;
}

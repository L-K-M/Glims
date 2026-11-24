/* Shared converted-copy source admission. Engine thread only; no public
 * document mode is admitted here. The helpers are static inline, so each
 * including file gets private copies. */
#ifndef GLIMS_COPY_ADMISSION_H
#define GLIMS_COPY_ADMISSION_H

#include <glib.h>
#include <cairo.h>
#include "gegl/gimp-babl.h"
#include "libgimpcolor/gimpcolor.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplinklayer.h"
#endif

/* Native queued link updates survive freezing a monitor and bypass facade
 * busy gates. Refuse the class, including frozen, nested and hidden layers. */
static inline gboolean
copy_admission_has_link_layer (GimpImage *image)
{
#if GIMP_CHECK_VERSION (3, 2, 0)
  GList *layers = gimp_image_get_layer_list (image);
  gboolean found = FALSE;
  for (GList *it = layers; it && !found; it = it->next)
    if (GIMP_IS_LINK_LAYER (it->data)) found = TRUE;
  g_list_free (layers);
  return found;
#else
  (void) image;
  return FALSE;
#endif
}

/* 8-bit, 16-bit or 32-bit RGB using the effective standard or linear sRGB
 * profile. Custom profiles must be converted to sRGB first. */
static inline gboolean
copy_admission_qualified_rgb (GimpImage *image)
{
  if (gimp_image_get_base_type (image) != GIMP_RGB) return FALSE;
  GimpComponentType component = gimp_babl_component_type (gimp_image_get_precision (image));
  if (component != GIMP_COMPONENT_TYPE_U8 && component != GIMP_COMPONENT_TYPE_U16 &&
      component != GIMP_COMPONENT_TYPE_FLOAT) return FALSE;
  GimpColorProfile *profile = gimp_image_get_color_profile (image);
  if (!profile) profile = gimp_image_get_builtin_color_profile (image);
  GimpColorProfile *srgb = gimp_color_profile_new_rgb_srgb ();
  GimpColorProfile *linear = gimp_color_profile_new_rgb_srgb_linear ();
  gboolean valid = profile && srgb && linear &&
    (gimp_color_profile_is_equal (profile, srgb) ||
     gimp_color_profile_is_equal (profile, linear));
  g_clear_object (&srgb);
  g_clear_object (&linear);
  return valid;
}

#endif

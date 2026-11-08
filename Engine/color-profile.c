/* ICC assignment changes interpretation; conversion changes pixel values to
 * preserve appearance. Both use the core's validated, single-undo operations.
 * Profiles loaded here are owned; profiles returned by image getters are not. */
#include "engine-private.h"

#include <string.h>
#include <gio/gio.h>
#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"

static gboolean
profile_intent (uint32_t value, GimpColorRenderingIntent *intent)
{
  switch (value)
    {
    case GLIMS_PROFILE_PERCEPTUAL:
      *intent = GIMP_COLOR_RENDERING_INTENT_PERCEPTUAL; return TRUE;
    case GLIMS_PROFILE_RELATIVE_COLORIMETRIC:
      *intent = GIMP_COLOR_RENDERING_INTENT_RELATIVE_COLORIMETRIC; return TRUE;
    case GLIMS_PROFILE_SATURATION:
      *intent = GIMP_COLOR_RENDERING_INTENT_SATURATION; return TRUE;
    case GLIMS_PROFILE_ABSOLUTE_COLORIMETRIC:
      *intent = GIMP_COLOR_RENDERING_INTENT_ABSOLUTE_COLORIMETRIC; return TRUE;
    default:
      return FALSE;
    }
}

/* NULL means the image model's builtin profile. Assignment passes NULL to
 * the core to discard an embedded/hidden profile; conversion needs a profile
 * object, so its caller explicitly retains the borrowed builtin instead. */
static GlimsStatus
load_profile (const char *path, GimpColorProfile **out, char **error)
{
  GFile *file;
  GError *gerror = NULL;

  *out = NULL;
  if (! path)
    return GLIMS_STATUS_OK;
  if (! *path || ! g_utf8_validate (path, -1, NULL) || ! g_path_is_absolute (path))
    {
      if (error) *error = g_strdup ("Choose a color profile file using its full path.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  file = g_file_new_for_path (path);
  *out = gimp_color_profile_new_from_file (file, &gerror);
  g_object_unref (file);
  if (! *out)
    return glims_fail (error, gerror, "The color profile could not be opened.");
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_assign_profile (GlimsEngine *engine, GlimsImageID id,
                            const char *path, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpColorProfile *profile = NULL;
  GError *gerror = NULL;
  GlimsStatus status;
  gboolean hidden = FALSE;

  if (! open) return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = load_profile (path, &profile, error);
  if (status != GLIMS_STATUS_OK) return status;

  /* Discarding an already builtin profile is a real no-op, including
   * clean state. A hidden custom profile must still be discarded. */
  if (! path && gimp_image_get_use_srgb_profile (open->image, &hidden) && ! hidden)
    return GLIMS_STATUS_OK;

  if (! gimp_image_assign_color_profile (open->image, profile, NULL, &gerror))
    {
      g_clear_object (&profile);
      return glims_fail (error, gerror, "The color profile could not be assigned.");
    }
  g_clear_object (&profile);
  gimp_image_flush (open->image);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_convert_profile (GlimsEngine *engine, GlimsImageID id,
                             const char *path, uint32_t intent_value,
                             bool black_point_compensation, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpColorProfile *profile = NULL;
  GimpColorRenderingIntent intent;
  GlimsStatus status;
  GError *gerror = NULL;

  if (! open) return GLIMS_STATUS_NOT_FOUND;
  if (! profile_intent (intent_value, &intent)) return GLIMS_STATUS_INVALID_ARGUMENT;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = load_profile (path, &profile, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (! profile)
    {
      profile = gimp_image_get_builtin_color_profile (open->image);
      if (! profile)
        {
          if (error) *error = g_strdup ("This image has no builtin color profile to convert to.");
          return GLIMS_STATUS_UNSUPPORTED;
        }
      g_object_ref (profile);
    }
  if (! gimp_image_convert_color_profile (open->image, profile, intent,
                                          black_point_compensation, NULL, &gerror))
    {
      g_object_unref (profile);
      return glims_fail (error, gerror, "The image could not be converted to the color profile.");
    }
  g_object_unref (profile);
  gimp_image_flush (open->image);
  return GLIMS_STATUS_OK;
}

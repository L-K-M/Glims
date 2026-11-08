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
#include "core/gimpitem.h"
#include "text/gimptextlayer.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimpvectorlayer.h"
#include "core/gimplinklayer.h"
#endif

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
      if (error) *error = strdup ("Choose a color profile file using its full path.");
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

/* A native profile conversion replaces drawable buffers with undo enabled,
 * which rasterizes genuine text/vector/link layers. Ordinary conversion
 * must refuse that change; a separate entry point records explicit consent. */
static gboolean
has_editable_layers (GimpImage *image)
{
  GList *layers = gimp_image_get_layer_list (image);
  GList *iter;
  gboolean found = FALSE;
  for (iter = layers; iter; iter = iter->next)
    {
      GimpItem *item = GIMP_ITEM (iter->data);
      if (gimp_item_is_text_layer (item)
#if GIMP_CHECK_VERSION (3, 2, 0)
          || gimp_item_is_vector_layer (item) || gimp_item_is_link_layer (item)
#endif
         )
        { found = TRUE; break; }
    }
  g_list_free (layers);
  return found;
}

static GlimsStatus
convert_profile (GlimsEngine *engine, GlimsImageID id,
                             const char *path, uint32_t intent_value,
                             bool black_point_compensation, gboolean allow_rasterize,
                             char **error)
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
  /* The native indexed-colormap path uses babl restriction and ignores
   * rendering intent and black-point compensation. Do not claim those
   * requested conversion settings were applied. RGB/gray use the full
   * native color transform; convert an indexed image to RGB first. */
  if (gimp_image_get_base_type (open->image) == GIMP_INDEXED)
    {
      if (error) *error = strdup ("Convert the indexed image to RGB before converting its color profile.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  status = load_profile (path, &profile, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (! profile)
    {
      profile = gimp_image_get_builtin_color_profile (open->image);
      if (! profile)
        {
          if (error) *error = strdup ("This image has no builtin color profile to convert to.");
          return GLIMS_STATUS_UNSUPPORTED;
        }
      g_object_ref (profile);
    }
  if (! gimp_image_validate_color_profile (open->image, profile, NULL, &gerror))
    {
      g_object_unref (profile);
      return glims_fail (error, gerror, "This color profile is not compatible with the image.");
    }
  {
    GimpColorProfile *source = gimp_image_get_color_profile (open->image);
    if (! source) source = gimp_image_get_builtin_color_profile (open->image);
    if (source && gimp_color_profile_is_equal (source, profile))
      { g_object_unref (profile); return GLIMS_STATUS_OK; }
  }
  if (! allow_rasterize && has_editable_layers (open->image))
    {
      g_object_unref (profile);
      if (error) *error = strdup ("Converting this color profile requires turning editable text, vector, or linked layers into pixels.");
      return GLIMS_STATUS_REQUIRES_RASTERIZE;
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

GlimsStatus
glims_image_convert_profile (GlimsEngine *engine, GlimsImageID id,
                             const char *path, uint32_t intent,
                             bool black_point_compensation, char **error)
{
  return convert_profile (engine, id, path, intent, black_point_compensation, FALSE, error);
}

GlimsStatus
glims_image_convert_profile_rasterizing (GlimsEngine *engine, GlimsImageID id,
                                         const char *path, uint32_t intent,
                                         bool black_point_compensation, char **error)
{
  return convert_profile (engine, id, path, intent, black_point_compensation, TRUE, error);
}

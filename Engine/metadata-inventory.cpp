#include "metadata-inventory.h"
#include <gexiv2/gexiv2.h>
#include "vendor/gexiv2-0.14.7/gexiv2-metadata-private.h"
#include <exception>
#include <algorithm>

#if GEXIV2_MAJOR_VERSION != 0 || GEXIV2_MINOR_VERSION != 14 || GEXIV2_MICRO_VERSION != 7
#error Review the private metadata inventory layout for this GExiv2 version
#endif
#if EXIV2_VERSION != EXIV2_MAKE_VERSION(0, 28, 9)
#error Review the private metadata inventory layout for this Exiv2 version
#endif

extern "C" GlimsStatus
glims_metadata_xmp_entry_count (GExiv2Metadata *metadata, gsize *out, char **error)
{
  if (out) *out = 0;
  if (!metadata || !out) return GLIMS_STATUS_INVALID_ARGUMENT;
  // The object layout is borrowed from exact upstream private headers.
  // Check BOTH running dependencies before reading even the first field.
  if (gexiv2_get_version () != 1407 || Exiv2::versionNumber () != EXIV2_MAKE_VERSION (0, 28, 9)) {
    if (error) *error = g_strdup ("This metadata library version needs an inventory compatibility review.");
    return GLIMS_STATUS_UNSUPPORTED;
  }
  try {
    if (!GEXIV2_IS_METADATA (metadata) || !metadata->priv || !metadata->priv->image) {
      if (error) *error = g_strdup ("The metadata object has no native image.");
      return GLIMS_STATUS_FAILED;
    }
    *out = static_cast<gsize> (metadata->priv->image->xmpData ().count ());
    return GLIMS_STATUS_OK;
  } catch (const std::exception &exception) {
    if (error) *error = g_strdup (exception.what ());
    return GLIMS_STATUS_FAILED;
  } catch (...) {
    if (error) *error = g_strdup ("The native metadata inventory could not be read.");
    return GLIMS_STATUS_FAILED;
  }
}

extern "C" GlimsStatus
glims_metadata_empty_entry_count (GExiv2Metadata *metadata, gsize *out, char **error)
{
  if (out) *out = 0;
  if (!out) return GLIMS_STATUS_INVALID_ARGUMENT;
  gsize ignored = 0;
  // Reuse the complete version/type/image validation before private access.
  GlimsStatus status = glims_metadata_xmp_entry_count (metadata, &ignored, error);
  if (status != GLIMS_STATUS_OK) return status;
  try {
    auto empty_count = [](const auto &data) {
      return std::count_if (data.begin (), data.end (), [](const auto &entry) { return entry.count () == 0; });
    };
    auto &image = *metadata->priv->image;
    *out = static_cast<gsize> (empty_count (image.exifData ()) + empty_count (image.iptcData ()) + empty_count (image.xmpData ()));
    return GLIMS_STATUS_OK;
  } catch (const std::exception &exception) {
    if (error) *error = g_strdup (exception.what ());
    return GLIMS_STATUS_FAILED;
  } catch (...) {
    if (error) *error = g_strdup ("The empty metadata inventory could not be read.");
    return GLIMS_STATUS_FAILED;
  }
}

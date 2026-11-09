/*
 * Destination-profile rendering (facade slot 132, image_render_to_profile):
 * like glims_image_render, but the composited area is converted into the
 * caller's exact RGB destination ICC profile instead of sRGB, and written
 * as premultiplied 8-bit RGBA in that profile's own RGB space.
 *
 * Source correctness: the projection is read through the shared lazy
 * preparation (glims_projection_prepare_read) into a STRAIGHT (unassociated)
 * float encoding in the projection's OWN babl space, so the read changes
 * only the encoding (premultiplied -> straight, source precision -> float)
 * and never the color space. The effective source profile is the image's
 * own, or the engine's builtin fallback for its model (as
 * glims_image_color_info reports it); the destination profile is built
 * from the caller's immutable ICC bytes, which
 * gimp_color_profile_new_from_icc_profile copies. gimp_color_transform_new
 * determines the color spaces exclusively from the two profiles; the
 * format arguments only select pixel encodings, so the source encoding is
 * passed space-less and re-tagged with the source profile's space — which
 * is the projection's own space whenever the image carries an explicit
 * profile (layer_space is derived from it at relative-colorimetric), so
 * no second conversion runs in that case. The transform runs on straight
 * color and preserves alpha (LCMS copies alpha; the babl fish passes it),
 * then the result is premultiplied exactly once, by a babl fish inside the
 * destination space, into the caller's rows. Nonlinear ICC math never sees
 * associated components. Alpha 0, partial and opaque pixels are therefore
 * deterministic: straight color through the transform, alpha unchanged,
 * then one premultiplication.
 *
 * Policy is fixed: relative colorimetric SDR with no flags (no proofing,
 * no gamut check, no black point compensation, no optimize change). No
 * transform or profile is cached: everything is created, used and released
 * on this engine thread within the call. The call is a read: it never
 * checks write readiness and never touches pixels, profile, history or
 * dirty state. Runs on the engine thread.
 */
#include "engine-private.h"

#include <string.h>

#include <cairo.h>

/* gimpcolor.h is the only libgimpcolor header included directly; it pulls
 * in gimpcolorprofile.h and gimpcolortransform.h (and needs cairo.h first). */
#include "libgimpcolor/gimpcolor.h"

#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpprojectable.h"

/* The one documented SDR transform policy of slot 132. */
#define DISPLAY_RENDER_INTENT GIMP_COLOR_RENDERING_INTENT_RELATIVE_COLORIMETRIC

GlimsStatus
glims_image_render_to_profile (GlimsEngine   *engine,
                               GlimsImageID    id,
                               double          scale,
                               GlimsRect       area,
                               const uint8_t  *destination_icc,
                               size_t          destination_icc_length,
                               uint8_t        *pixels,
                               size_t          stride,
                               char          **error)
{
  GlimsOpenImage     *open = glims_lookup_image (engine, id);
  GimpImage          *image;
  GimpImageBaseType   base_type;
  GimpColorProfile   *src_profile;
  GimpColorProfile   *dest_profile = NULL;
  GimpColorTransform *transform = NULL;
  GError             *gerror = NULL;
  GeglBuffer         *buffer = NULL;
  const Babl         *proj_format;
  const Babl         *proj_space;
  const Babl         *src_format;   /* straight float, the projection's own space */
  const Babl         *dest_plain;   /* "R G B A float"; the transform re-tags the space */
  const Babl         *dest_space;
  const Babl         *premul_src;
  const Babl         *premul_dst;
  const Babl         *premul_fish = NULL;
  const char         *src_encoding;
  gboolean            gray;
  uint64_t            row_src, row_dst, out_bytes;
  size_t              chunk_rows, rows_done, row;
  uint8_t            *tmp_src = NULL;
  uint8_t            *tmp_dst = NULL;
  GlimsStatus         status;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! pixels)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  /* NULL or empty destination ICC is invalid; the cap keeps the length
   * far inside LCMS's 32-bit size domain (never narrowed unchecked). */
  if (! destination_icc || destination_icc_length == 0 ||
      destination_icc_length > GLIMS_MAX_ICC_PROFILE_BYTES)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Coordinate, stride and size arithmetic in 64 bits: the area is
   * int32, but sums, the per-row scratch stride and the total output size
   * must not overflow, and gegl_buffer_get takes a gint row stride. */
  if (area.width < 1 || area.height < 1 ||
      (int64_t) area.x + area.width  > G_MAXINT32 ||
      (int64_t) area.x + area.width  < G_MININT32 ||
      (int64_t) area.y + area.height > G_MAXINT32 ||
      (int64_t) area.y + area.height < G_MININT32)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (stride < (uint64_t) area.width * 4u || stride > G_MAXINT32)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  out_bytes = (uint64_t) stride * (uint64_t) (area.height - 1) +
              (uint64_t) area.width * 4u;
  if (out_bytes > GLIMS_MAX_PIXEL_BUFFER_BYTES)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Same scale and area validation and lazy projection preparation as
   * image_render; a read, allowed whenever image_render is allowed. */
  status = glims_projection_prepare_read (open, scale, area, &buffer);
  if (status != GLIMS_STATUS_OK)
    return status;

  image     = open->image;
  base_type = gimp_image_get_base_type (image);
  switch (base_type)
    {
    case GIMP_RGB:
    case GIMP_INDEXED: /* an indexed image's projection is RGB */
      gray = FALSE;
      src_encoding = "R G B A float";
      break;
    case GIMP_GRAY:
      gray = TRUE;
      src_encoding = "Y A float";
      break;
    default:
      if (error)
        *error = strdup ("Only RGB, grayscale and indexed images can render to a destination profile.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* Honest source-format validation: the projection must really be an
   * alpha-carrying 4-component format for RGB/indexed or 2-component for
   * grayscale; anything else is refused rather than coerced. */
  proj_format = gimp_projectable_get_format (GIMP_PROJECTABLE (image));
  if (! proj_format ||
      babl_format_get_n_components (proj_format) != (gray ? 2 : 4) ||
      ! babl_format_has_alpha (proj_format))
    {
      if (error)
        *error = strdup ("The image's projection format is inconsistent with its color model.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* Read in the projection's OWN space so gegl only re-encodes
   * (premultiplied -> straight, source precision -> float). */
  proj_space = babl_format_get_space (proj_format);
  src_format = proj_space ? babl_format_with_space (src_encoding, proj_space)
                           : babl_format (src_encoding);
  if (! src_format)
    return glims_fail (error, NULL, "Could not build the source read format.");

  /* Effective source profile: the image's own when it has one, the
   * builtin fallback for its model otherwise. Borrowed; not released. */
  src_profile = gimp_image_get_color_profile (image);
  if (! src_profile)
    src_profile = gimp_image_get_builtin_color_profile (image);
  if (! src_profile)
    return glims_fail (error, NULL, "The image has no usable color profile.");

  /* Owned destination profile; new_from_icc_profile copies the ICC bytes,
   * so nothing of the caller's is retained after this call. Malformed
   * data is refused here with the LCMS error — never a silent fallback. */
  dest_profile = gimp_color_profile_new_from_icc_profile (destination_icc,
                                                          destination_icc_length,
                                                          &gerror);
  if (! dest_profile)
    return glims_fail (error, g_steal_pointer (&gerror),
                       "The destination data is not a valid ICC color profile.");
  if (! gimp_color_profile_is_rgb (dest_profile))
    {
      g_object_unref (dest_profile);
      if (error)
        *error = strdup ("The destination ICC profile is not an RGB profile.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  dest_space = gimp_color_profile_get_space (dest_profile, DISPLAY_RENDER_INTENT, &gerror);
  if (! dest_space)
    {
      status = glims_fail (error, g_steal_pointer (&gerror),
                           "The destination profile has no usable color space.");
      g_object_unref (dest_profile);
      return status;
    }

  /* One transform per call, on this thread. The profiles alone determine
   * the color spaces; the formats only pick encodings: straight float in,
   * straight float out, alpha preserved. When the babl fish cannot serve
   * the pair, the constructor falls back to LCMS — either way malformed
   * or unsupported combinations already failed above or return NULL here. */
  dest_plain = babl_format ("R G B A float");
  transform = gimp_color_transform_new (src_profile, babl_format (src_encoding),
                                        dest_profile, dest_plain,
                                        DISPLAY_RENDER_INTENT,
                                        (GimpColorTransformFlags) 0);
  if (! transform)
    {
      status = glims_fail (error, NULL,
                           "The engine could not build a transform to the destination profile.");
      g_object_unref (dest_profile);
      return status;
    }

  /* Premultiply exactly once, inside the destination space, with babl's
   * own straight->premultiplied u8 conversion. */
  premul_src = babl_format_with_space ("R G B A float", dest_space);
  premul_dst = babl_format_with_space ("R'aG'aB'aA u8", dest_space);
  if (premul_src && premul_dst)
    premul_fish = babl_fish (premul_src, premul_dst);
  if (! premul_fish)
    {
      status = glims_fail (error, NULL,
                           "Could not build the premultiplication conversion in the destination space.");
      goto out;
    }

  /* Bounded scratch: rows are processed in chunks whose source+destination
   * bytes together never exceed the temp cap, and a single row must fit
   * gegl's gint stride. */
  row_src = (uint64_t) area.width * (gray ? 8u : 16u);
  row_dst = (uint64_t) area.width * 16u;
  if (row_src > GLIMS_RENDER_TEMP_CHUNK_BYTES || row_dst > GLIMS_RENDER_TEMP_CHUNK_BYTES ||
      row_src > G_MAXINT32 || row_dst > G_MAXINT32)
    {
      status = GLIMS_STATUS_INVALID_ARGUMENT;
      goto out;
    }
  chunk_rows = (size_t) (GLIMS_RENDER_TEMP_CHUNK_BYTES / (row_src + row_dst));
  if (chunk_rows < 1)
    chunk_rows = 1;
  if (chunk_rows > (size_t) area.height)
    chunk_rows = (size_t) area.height;
  tmp_src = g_malloc (chunk_rows * (size_t) row_src);
  tmp_dst = g_malloc (chunk_rows * (size_t) row_dst);

  rows_done = 0;
  while (rows_done < (size_t) area.height)
    {
      size_t        rows = chunk_rows;
      GeglRectangle rect;

      if (rows > (size_t) area.height - rows_done)
        rows = (size_t) area.height - rows_done;
      rect.x      = area.x;
      rect.y      = area.y + (gint) rows_done;
      rect.width  = area.width;
      rect.height = (gint) rows;

      /* Read straight float in the projection's own space (encoding-only
       * conversion), transform straight, then premultiply into the
       * caller's rows at the caller's stride. */
      gegl_buffer_get (buffer, &rect, scale, src_format,
                       tmp_src, (gint) row_src, GEGL_ABYSS_NONE);
      gimp_color_transform_process_pixels (transform, src_format, tmp_src,
                                           dest_plain, tmp_dst,
                                           (gsize) rows * (gsize) area.width);
      for (row = 0; row < rows; row++)
        babl_process (premul_fish,
                      tmp_dst + row * (size_t) row_dst,
                      pixels + (rows_done + row) * stride,
                      (long) area.width);

      rows_done += rows;
    }

  status = GLIMS_STATUS_OK;

out:
  g_free (tmp_src);
  g_free (tmp_dst);
  if (transform)
    g_object_unref (transform);
  if (dest_profile)
    g_object_unref (dest_profile);
  return status;
}

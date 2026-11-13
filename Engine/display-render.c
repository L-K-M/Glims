/*
 * Destination-profile rendering (facade slot 132, image_render_to_profile):
 * like glims_image_render, but the composited area is converted into the
 * caller's exact RGB destination ICC profile instead of sRGB, and written
 * as premultiplied 8-bit RGBA in that profile's own RGB space.
 *
 * Source correctness: projection preparation keeps native level zero current.
 * Reductions and fractional magnification use an image-owned associated-linear
 * source in the projection's OWN babl space, preserving true alpha through
 * spatial filtering. The result is unassociated, then encoded into that same
 * source space's TRC before ICC processing. Unit/nearest reads retain their
 * direct straight-float path. The effective source profile is the image's
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
 * Slot132 policy is fixed: relative colorimetric SDR with no flags (no proofing,
 * no gamut check, no black point compensation, no optimize change). No
 * transform or profile is cached: everything is created, used and released
 * on this engine thread within the call. The call is a read: it never
 * checks write readiness and never touches pixels, profile, history or
 * dirty state. Runs on the engine thread.
 *
 * Slot164 uses the same read/premultiply path with an explicit native
 * proofing transform. Its separate entry validates facade-owned settings
 * and both ICC blobs before calling the shared renderer. No missing or
 * unusable proof can select the unproofed branch through that entry.
 */
#include "engine-private.h"
#include "plate-preview.h"
#include "display-sample.h"
#include "lab-layer-preview-read.h"

#include <math.h>
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

typedef struct { GlimsEngine *engine; GlimsOpenImage *open; } DisplayReadLease;

static void
display_read_lease_clear (DisplayReadLease *lease)
{
  if (lease->open) lease->open->display_sample_active = FALSE;
  if (lease->engine) lease->engine->busy--;
}
G_DEFINE_AUTO_CLEANUP_CLEAR_FUNC (DisplayReadLease, display_read_lease_clear)

static GlimsStatus
display_render (GlimsEngine   *engine,
                               GlimsImageID    id,
                               double          scale,
                               GlimsRect       area,
                               const uint8_t  *destination_icc,
                               size_t          destination_icc_length,
                               const uint8_t  *proof_icc,
                               size_t          proof_icc_length,
                               GimpColorRenderingIntent proof_intent,
                               GimpColorRenderingIntent display_intent,
                               GimpColorTransformFlags flags,
                               uint8_t        *pixels,
                               size_t          stride,
                               char          **error)
{
  GlimsOpenImage     *open = glims_lookup_image (engine, id);
  GimpImage          *image;
  GimpImageBaseType   base_type;
  GimpColorProfile   *src_profile;
  g_autoptr(GimpColorProfile) component_profile = NULL;
  GimpColorProfile   *dest_profile = NULL;
  GimpColorProfile   *proof_profile = NULL;
  GimpColorTransform *transform = NULL;
  GError             *gerror = NULL;
  GeglBuffer         *buffer = NULL;
  const Babl         *proj_format;
  const Babl         *proj_space;
  const Babl         *src_format;   /* straight float, the projection's own space */
  const Babl         *dest_plain;   /* "R'G'B'A float"; the transform re-tags the space */
  const Babl         *dest_space;
  const Babl         *premul_src;
  const Babl         *premul_dst;
  const Babl         *premul_fish = NULL;
  const Babl         *linear_format = NULL;
  const Babl         *encode_fish = NULL;
  GlimsDisplaySample *sample = NULL;
  const gboolean      layered_lab = open && open->component_layout == GLIMS_COMPONENT_LAYOUT_LAYERED_LAB;
  const gboolean      needs_sampling = !layered_lab && scale < 2.0 && scale != 1.0;
  g_auto (DisplayReadLease) read_lease = { NULL, NULL };
  const char         *src_encoding;
  gboolean            gray;
  uint64_t            row_src, row_dst, out_bytes;
  size_t              chunk_rows, rows_done, row;
  uint8_t            *tmp_src = NULL;
  uint8_t            *tmp_dst = NULL;
  uint8_t            *tmp_linear = NULL;
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
  if (!(scale >= 1.0 / 1048576.0) || scale > 32.0)
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
  if (layered_lab)
    {
      const double native_scale = (double) (float) scale;
      const double max_coord = 67108864.0;
      if ((uintptr_t) pixels > UINTPTR_MAX - out_bytes ||
          fabs ((double) area.x / native_scale) > max_coord ||
          fabs ((double) area.y / native_scale) > max_coord ||
          fabs (((double) area.x + area.width) / native_scale) > max_coord ||
          fabs (((double) area.y + area.height) / native_scale) > max_coord)
        return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* Refuse reentry into this image's sampler while protecting the read from
   * writes. Global busy may already be set by a plug-in's nested loop: viewing
   * must remain available while its dialog is open. Balance both guards on
   * every return, including profile-validation failures. */
  if (needs_sampling || layered_lab)
    {
      if (open->display_sample_active) return GLIMS_STATUS_BUSY;
      open->display_sample_active = TRUE;
      engine->busy++;
      read_lease.engine = engine;
      read_lease.open = open;
    }

  /* Retain native projection stop/flush behavior before creating the derived
   * source. Its reader validates the additional filter and mip footprints. */
  if (!layered_lab)
    {
      status = glims_projection_prepare_read (open, scale, area, &buffer);
      if (status != GLIMS_STATUS_OK)
        return status;
    }

  image     = open->image;
  base_type = open->component_document ? GIMP_RGB : gimp_image_get_base_type (image);
  switch (base_type)
    {
    case GIMP_RGB:
    case GIMP_INDEXED: /* an indexed image's projection is RGB */
      gray = FALSE;
      src_encoding = layered_lab ? "RGBA float" : "R'G'B'A float";
      break;
    case GIMP_GRAY:
      gray = TRUE;
      src_encoding = "Y'A float";
      break;
    default:
      if (error)
        *error = strdup ("Only RGB, grayscale and indexed images can render to a destination profile.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* Honest source-format validation: the projection must really be an
   * alpha-carrying 4-component format for RGB/indexed or 2-component for
   * grayscale; anything else is refused rather than coerced. */
  proj_format = layered_lab ? babl_format ("RGBA float") :
                open->component_document ? gegl_buffer_get_format (buffer)
                                        : gimp_projectable_get_format (GIMP_PROJECTABLE (image));
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
  if (open->component_document)
    {
      component_profile = layered_lab ? gimp_color_profile_new_rgb_srgb_linear ()
                                      : gimp_color_profile_new_rgb_srgb ();
      src_profile = component_profile;
    }
  else
    {
      src_profile = gimp_image_get_color_profile (image);
      if (!src_profile) src_profile = gimp_image_get_builtin_color_profile (image);
    }
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

  /* This space only associates and quantizes values already converted by
   * LCMS. A relative space supplies the profile's primaries/TRC without
   * asking Babl to implement the proof's saturation/absolute intents. */
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
  dest_plain = babl_format ("R'G'B'A float");
  if (proof_icc)
    {
      proof_profile = gimp_color_profile_new_from_icc_profile (proof_icc,
                                                               proof_icc_length,
                                                               &gerror);
      if (! proof_profile)
        {
          status = glims_fail (error, g_steal_pointer (&gerror),
                               "The proof data is not a valid ICC color profile.");
          goto out;
        }
      /* No RGB restriction on the proof: the native LCMS-backed constructor
       * decides which profile/intent combinations it can represent. It
       * always enables proofing and copies alpha on all supported engines. */
      transform = gimp_color_transform_new_proofing (src_profile, babl_format (src_encoding),
                                                     dest_profile, dest_plain, proof_profile,
                                                     proof_intent, display_intent, flags);
    }
  else
    {
      /* Keep slot132's constructor, policy and flags exactly as before. */
      transform = gimp_color_transform_new (src_profile, babl_format (src_encoding),
                                            dest_profile, dest_plain,
                                            DISPLAY_RENDER_INTENT,
                                            (GimpColorTransformFlags) 0);
    }
  if (! transform)
    {
      status = glims_fail (error, NULL,
                           proof_icc ? "The engine could not build the requested ICC proofing transform."
                                     : "The engine could not build a transform to the destination profile.");
      goto out;
    }

  /* Premultiply exactly once, inside the destination space, with babl's
   * own straight->premultiplied u8 conversion. */
  premul_src = babl_format_with_space ("R'G'B'A float", dest_space);
  premul_dst = babl_format_with_space ("R'aG'aB'aA u8", dest_space);
  if (premul_src && premul_dst)
    premul_fish = babl_fish (premul_src, premul_dst);
  if (! premul_fish)
    {
      status = glims_fail (error, NULL,
                           "Could not build the premultiplication conversion in the destination space.");
      goto out;
    }

  /* Bounded scratch: rows are processed in chunks whose complete temporary
   * bytes together never exceed the temp cap, and a single row must fit
   * gegl's gint stride. */
  row_src = (uint64_t) area.width * (gray ? 8u : 16u);
  row_dst = (uint64_t) area.width * 16u;
  const uint64_t row_work = row_dst + row_src * (needs_sampling ? 2u : 1u);
  if (row_work > GLIMS_RENDER_TEMP_CHUNK_BYTES ||
      row_src > G_MAXINT32 || row_dst > G_MAXINT32)
    {
      status = GLIMS_STATUS_INVALID_ARGUMENT;
      goto out;
    }
  chunk_rows = (size_t) (GLIMS_RENDER_TEMP_CHUNK_BYTES / row_work);
  if (chunk_rows < 1)
    chunk_rows = 1;
  if (chunk_rows > (size_t) area.height)
    chunk_rows = (size_t) area.height;
  /* GEGL converts one-column reads using stack scratch proportional to
   * height, so bound its calls independently of our own heap-scratch cap. */
  if (area.width == 1 && chunk_rows > 256)
    chunk_rows = 256;
  tmp_src = g_malloc (chunk_rows * (size_t) row_src);
  tmp_dst = g_malloc (chunk_rows * (size_t) row_dst);
  if (needs_sampling)
    {
      const char *linear_encoding = gray ? "YA float" : "RGBA float";
      linear_format = proj_space ? babl_format_with_space (linear_encoding, proj_space)
                                 : babl_format (linear_encoding);
      encode_fish = linear_format ? babl_fish (linear_format, src_format) : NULL;
      if (!linear_format || !encode_fish)
        {
          status = glims_fail (error, NULL, "The alpha-aware display source could not be prepared.");
          goto out;
        }
      status = glims_display_sample_prepare (buffer, linear_format, &open->display_sample);
      if (status != GLIMS_STATUS_OK) goto out;
      sample = open->display_sample;
      tmp_linear = g_malloc (chunk_rows * (size_t) row_src);
    }

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

      /* Spatial sampling stays associated and linear. Encoding afterward in
       * the same source space preserves the existing ICC/proof contract. */
      /* A final single-pixel chunk can take GEGL's hot-pixel shortcut
       * even when the whole request was larger. Validate that chunk too. */
      if (!layered_lab && scale == 1.0 && rect.width == 1 && rect.height == 1)
        {
          GlimsRect single = { rect.x, rect.y, 1, 1 };
          status = glims_projection_prepare_read (open, scale, single, &buffer);
          if (status != GLIMS_STATUS_OK) goto out;
        }
      if (layered_lab)
        {
          status = glims_lab_layer_preview_read (image, &open->layered_lab_preview, scale,
            (GlimsRect) { rect.x, rect.y, rect.width, rect.height }, tmp_src, (size_t) row_src);
          if (status != GLIMS_STATUS_OK) goto out;
        }
      else if (needs_sampling)
        {
          status = glims_display_sample_read (sample, scale,
            (GlimsRect) { rect.x, rect.y, rect.width, rect.height }, tmp_linear, (size_t) row_src);
          if (status != GLIMS_STATUS_OK) goto out;
          for (row = 0; row < rows; row++)
            babl_process (encode_fish, tmp_linear + row * (size_t) row_src,
                           tmp_src + row * (size_t) row_src, (long) area.width);
        }
      else
        gegl_buffer_get (buffer, &rect, scale, src_format,
                         tmp_src, (gint) row_src, GEGL_ABYSS_NONE);
      if (!glims_plate_preview_succeeded (open->component_preview))
        { status = GLIMS_STATUS_FAILED; goto out; }
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
  g_free (tmp_linear);
  g_free (tmp_src);
  g_free (tmp_dst);
  if (transform)
    g_object_unref (transform);
  if (dest_profile)
    g_object_unref (dest_profile);
  if (proof_profile)
    g_object_unref (proof_profile);
  return status;
}

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
  return display_render (engine, id, scale, area, destination_icc, destination_icc_length,
                         NULL, 0, DISPLAY_RENDER_INTENT, DISPLAY_RENDER_INTENT,
                         (GimpColorTransformFlags) 0, pixels, stride, error);
}

static gboolean
proof_render_intent (uint32_t value, GimpColorRenderingIntent *intent)
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

GlimsStatus
glims_image_render_proofed (GlimsEngine             *engine,
                            GlimsImageID              id,
                            double                    scale,
                            GlimsRect                 area,
                            const uint8_t            *destination_icc,
                            size_t                    destination_icc_length,
                            const uint8_t            *proof_icc,
                            size_t                    proof_icc_length,
                            const GlimsProofSettings *settings,
                            uint8_t                  *pixels,
                            size_t                    stride,
                            char                    **error)
{
  GimpColorRenderingIntent proof_intent;
  GimpColorRenderingIntent display_intent;
  GimpColorTransformFlags flags = 0;

  /* Check size before reading any later field. Larger future tails are
   * ignored, while unknown owned flags and intent values are refused. */
  if (! settings || settings->struct_size < sizeof *settings)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if ((settings->flags & ~((uint32_t) (GLIMS_PROOF_BLACK_POINT_COMPENSATION |
                                     GLIMS_PROOF_GAMUT_CHECK))) != 0 ||
      ! proof_render_intent (settings->proof_intent, &proof_intent) ||
      ! proof_render_intent (settings->display_intent, &display_intent))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (! destination_icc || destination_icc_length == 0 ||
      destination_icc_length > GLIMS_MAX_ICC_PROFILE_BYTES ||
      ! proof_icc || proof_icc_length == 0 || proof_icc_length > GLIMS_MAX_ICC_PROFILE_BYTES)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (settings->flags & GLIMS_PROOF_BLACK_POINT_COMPENSATION)
    flags |= GIMP_COLOR_TRANSFORM_FLAGS_BLACK_POINT_COMPENSATION;
  if (settings->flags & GLIMS_PROOF_GAMUT_CHECK)
    flags |= GIMP_COLOR_TRANSFORM_FLAGS_GAMUT_CHECK;

  return display_render (engine, id, scale, area, destination_icc, destination_icc_length,
                         proof_icc, proof_icc_length, proof_intent, display_intent,
                         flags, pixels, stride, error);
}

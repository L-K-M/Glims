#include "cmyk-transform.h"

#include <lcms2.h>
#include <math.h>
#include <string.h>

struct _GlimsCmykTransform {
  cmsContext context;
  cmsHPROFILE source;
  cmsHPROFILE destination;
  cmsHTRANSFORM conversion;
  guint8 *icc;
};

static gboolean
fail (GError **error, const gchar *message)
{
  g_set_error_literal (error, g_quark_from_static_string ("glims-cmyk-transform"),
                       1, message);
  return FALSE;
}

void
glims_cmyk_transform_free (GlimsCmykTransform *transform)
{
  if (!transform) return;
  if (transform->conversion) cmsDeleteTransform (transform->conversion);
  if (transform->destination) cmsCloseProfile (transform->destination);
  if (transform->source) cmsCloseProfile (transform->source);
  if (transform->context) cmsDeleteContext (transform->context);
  g_free (transform->icc);
  g_free (transform);
}

/* sRGB chromaticities adjusted for ICC fixed-point quantization, matching
 * GIMP's unmodified libgimpcolor/gimpcolorprofile.c linear-sRGB definition.
 * This profile belongs to this context, not GIMP's shared profile singleton. */
static cmsHPROFILE
linear_srgb (cmsContext context)
{
  const cmsCIExyY white = { 0.3127, 0.3290, 1.0 };
  const cmsCIExyYTRIPLE primaries = {
    { 0.639998686, 0.330010138, 1.0 },
    { 0.300003784, 0.600003357, 1.0 },
    { 0.150002046, 0.059997204, 1.0 }
  };
  cmsToneCurve *curve = cmsBuildGamma (context, 1.0);
  if (!curve) return NULL;
  cmsToneCurve *curves[3] = { curve, curve, curve };
  cmsHPROFILE profile = cmsCreateRGBProfileTHR (context, &white, &primaries, curves);
  cmsFreeToneCurve (curve);
  return profile;
}

/* Validates the bounded profile bytes and allocates the context plus its
 * private copy. On failure the message explains the caller-facing contract. */
static GlimsCmykTransform *
begin_transform (const guint8 *icc, gsize size, GError **error)
{
  if (!icc || size < 128 || size > GLIMS_CMYK_ICC_MAX_BYTES)
    { fail (error, "Choose a CMYK ICC profile no larger than 4 MB."); return NULL; }
  guint32 declared = ((guint32) icc[0] << 24) | ((guint32) icc[1] << 16) |
                     ((guint32) icc[2] << 8) | icc[3];
  if (declared != size || memcmp (icc + 36, "acsp", 4))
    { fail (error, "The CMYK ICC profile has an invalid length or signature."); return NULL; }
  GlimsCmykTransform *transform = g_try_new0 (GlimsCmykTransform, 1);
  if (!transform)
    { fail (error, "The CMYK conversion could not allocate its transform."); return NULL; }
  transform->icc = g_try_malloc (size);
  if (transform->icc)
    {
      memcpy (transform->icc, icc, size);
      transform->context = cmsCreateContext (NULL, NULL);
    }
  if (!transform->icc || !transform->context)
    {
      glims_cmyk_transform_free (transform);
      fail (error, "The CMYK conversion could not allocate its transform.");
      return NULL;
    }
  return transform;
}

GlimsCmykTransform *
glims_cmyk_transform_new (const guint8 *icc, gsize size, GError **error)
{
  GlimsCmykTransform *transform = begin_transform (icc, size, error);
  if (!transform) return NULL;
  transform->source = cmsOpenProfileFromMemTHR (transform->context,
                                                transform->icc, (cmsUInt32Number) size);
  if (!transform->source || cmsGetColorSpace (transform->source) != cmsSigCmykData)
    goto failed;
  cmsProfileClassSignature kind = cmsGetDeviceClass (transform->source);
  if (kind != cmsSigInputClass && kind != cmsSigOutputClass && kind != cmsSigColorSpaceClass)
    goto failed;
  if (!cmsIsIntentSupported (transform->source, INTENT_RELATIVE_COLORIMETRIC, LCMS_USED_AS_INPUT))
    goto failed;
  transform->destination = linear_srgb (transform->context);
  if (!transform->destination) goto failed;
  transform->conversion = cmsCreateTransformTHR (transform->context,
    transform->source, TYPE_CMYK_FLT, transform->destination, TYPE_RGB_FLT,
    INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_BLACKPOINTCOMPENSATION | cmsFLAGS_NOCACHE);
  if (!transform->conversion) goto failed;
  return transform;

failed:
  glims_cmyk_transform_free (transform);
  fail (error, "The CMYK profile cannot provide a relative-colorimetric preview.");
  return NULL;
}

GlimsCmykTransform *
glims_cmyk_dest_transform_new (const guint8 *icc, gsize size, GError **error)
{
  GlimsCmykTransform *transform = begin_transform (icc, size, error);
  if (!transform) return NULL;
  transform->destination = cmsOpenProfileFromMemTHR (transform->context,
                                                     transform->icc, (cmsUInt32Number) size);
  if (!transform->destination || cmsGetColorSpace (transform->destination) != cmsSigCmykData)
    goto failed;
  cmsProfileClassSignature kind = cmsGetDeviceClass (transform->destination);
  if (kind != cmsSigOutputClass && kind != cmsSigColorSpaceClass)
    goto failed;
  if (!cmsIsIntentSupported (transform->destination, INTENT_RELATIVE_COLORIMETRIC, LCMS_USED_AS_OUTPUT))
    goto failed;
  transform->source = linear_srgb (transform->context);
  if (!transform->source) goto failed;
  transform->conversion = cmsCreateTransformTHR (transform->context,
    transform->source, TYPE_RGB_FLT, transform->destination, TYPE_CMYK_FLT,
    INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_BLACKPOINTCOMPENSATION | cmsFLAGS_NOCACHE);
  if (!transform->conversion) goto failed;
  return transform;

failed:
  glims_cmyk_transform_free (transform);
  fail (error, "The CMYK profile cannot provide a relative-colorimetric destination transform.");
  return NULL;
}

gboolean
glims_cmyk_dest_transform_pixels (GlimsCmykTransform *transform,
                                  const gfloat *rgb, gsize count,
                                  gfloat *intensity, GError **error)
{
  if (!transform || count > GLIMS_CMYK_TRANSFORM_MAX_PIXELS ||
      (count && (!rgb || !intensity)))
    return fail (error, "The CMYK conversion sample buffer is invalid.");
  for (gsize i = 0; i < count * 3; i++)
    if (!isfinite (rgb[i]))
      return fail (error, "Linear sRGB samples must be finite.");

  /* LittleCMS floating CMYK uses coverage percentages. Convert back to the
   * native ink intensity convention: 0 = full ink, 1 = paper. Float output
   * can land a little outside 0...100, and the planes and their preview
   * accept only 0...1, so it is clamped. Bound scratch space independently
   * of the image or requested tile size. */
  for (gsize offset = 0; offset < count; offset += 256)
    {
      const gsize n = MIN (count - offset, 256);
      gfloat percent[256 * 4];
      cmsDoTransform (transform->conversion, rgb + offset * 3, percent, (cmsUInt32Number) n);
      for (gsize i = 0; i < n * 4; i++)
        intensity[offset * 4 + i] = CLAMP (1.0f - percent[i] / 100.0f, 0.0f, 1.0f);
    }
  return TRUE;
}

gboolean
glims_cmyk_transform_pixels (GlimsCmykTransform *transform,
                              const gfloat *intensity, gsize count,
                              gfloat *rgba, GError **error)
{
  if (!transform || count > GLIMS_CMYK_TRANSFORM_MAX_PIXELS ||
      (count && (!intensity || !rgba)))
    return fail (error, "The CMYK preview sample buffer is invalid.");
  for (gsize i = 0; i < count * 4; i++)
    if (!isfinite (intensity[i]) || intensity[i] < 0 || intensity[i] > 1)
      return fail (error, "CMYK ink intensity must be finite and between zero and one.");

  /* LittleCMS floating CMYK uses coverage percentages, not normalized
   * coverage and not the inverted native ink intensity. Bound scratch space
   * independently of the image or requested tile size. */
  for (gsize offset = 0; offset < count; offset += 256)
    {
      const gsize n = MIN (count - offset, 256);
      gfloat percent[256 * 4], rgb[256 * 3];
      for (gsize i = 0; i < n * 4; i++)
        percent[i] = 100.0f * (1.0f - intensity[offset * 4 + i]);
      cmsDoTransform (transform->conversion, percent, rgb, (cmsUInt32Number) n);
      for (gsize i = 0; i < n; i++)
        {
          memcpy (rgba + (offset + i) * 4, rgb + i * 3, 3 * sizeof (gfloat));
          rgba[(offset + i) * 4 + 3] = 1.0f;
        }
    }
  return TRUE;
}

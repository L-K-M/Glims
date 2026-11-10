/* Native-only slot164 regression. Link a fresh API164 producer, never an
 * API163 engine.o under the new header. Expected colors come from a separate
 * authentic native proofing transform over the fixture layer's own pixels;
 * no production render/common/projection-read helper computes the oracle.
 *
 * proof-render-tests WORK_DIR [CMYK_PROFILE]
 * Optional CMYK ICC is read in place, never copied into this repository. */
#include "engine-private.h"
#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpitem.h"
#include "core/gimppickable.h"
#include "core/gimpprojectable.h"
#include "core/gimpprojection.h"
#include <lcms2.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static const char *cmyk_path;
static int failures;
static int checks;
#define W 4
#define H 2
#define N (W * H * 4)
#define STRIDE (W * 4 + 7)
#define GUARD 8
#define OUTPUT_BYTES (GUARD + H * STRIDE + GUARD)
#define CHECK(c, text) do { gboolean ok_ = (c); \
  checks++; \
  printf ("%s %s\n", ok_ ? "ok  " : "FAIL", text); \
  if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, text) do { gboolean ready_ = (c); CHECK (ready_, text); \
  if (!ready_) goto cleanup; } while (0)

static const guint8 input[N] = {
  255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 128, 128, 128, 128,
  200, 70, 30, 0, 255, 255, 255, 255, 5, 3, 2, 64, 77, 88, 99, 200
};
typedef struct {
  GlimsEngine *engine;
  GlimsImageID id;
  GimpImage *image;
  GimpDrawable *drawable;
  gfloat straight[N];
} Fixture;

static void
clear_error (char **error)
{
  if (*error) api->free_string (*error);
  *error = NULL;
}

static GimpColorProfile *
profile_from_lcms (cmsHPROFILE native)
{
  cmsUInt32Number size = 0;
  GimpColorProfile *profile = NULL;
  GError *error = NULL;
  if (native && cmsSaveProfileToMem (native, NULL, &size) && size > 0)
    {
      guint8 *data = g_malloc (size);
      if (cmsSaveProfileToMem (native, data, &size))
        profile = gimp_color_profile_new_from_icc_profile (data, size, &error);
      g_free (data);
    }
  if (error) fprintf (stderr, "fixture ICC: %s\n", error->message);
  g_clear_error (&error);
  if (native) cmsCloseProfile (native);
  return profile;
}

static GimpColorProfile *
rgb_proof (void)
{
  cmsCIExyY white = { 0.3457, 0.3585, 1.0 };
  cmsCIExyYTRIPLE primaries = { {0.58, 0.35, 1.0}, {0.33, 0.52, 1.0}, {0.23, 0.20, 1.0} };
  cmsToneCurve *gamma = cmsBuildGamma (NULL, 2.2);
  if (!gamma) return NULL;
  cmsToneCurve *curves[3] = { gamma, gamma, gamma };
  cmsHPROFILE native = cmsCreateRGBProfile (&white, &primaries, curves);
  cmsFreeToneCurve (gamma);
  /* Deliberately distinct media white, in addition to narrow primaries.
   * This is a synthetic transform discriminator, not a physical device or
   * a paper-simulation policy. The test below must observe a difference. */
  cmsCIEXYZ media_white = { 0.95047, 1.0, 1.08883 };
  if (native && !cmsWriteTag (native, cmsSigMediaWhitePointTag, &media_white))
    { cmsCloseProfile (native); return NULL; }
  return profile_from_lcms (native);
}

static GimpColorProfile *
gray_proof (void)
{
  cmsToneCurve *gamma = cmsBuildGamma (NULL, 2.2);
  if (!gamma) return NULL;
  cmsHPROFILE native = cmsCreateGrayProfile (cmsD50_xyY (), gamma);
  cmsFreeToneCurve (gamma);
  return profile_from_lcms (native);
}

static gboolean
hash_buffer (GChecksum *sum, GeglBuffer *buffer)
{
  const Babl *format = gegl_buffer_get_format (buffer);
  gint bpp = babl_format_get_bytes_per_pixel (format);
  if (bpp < 1 || bpp > 128) return FALSE;
  gsize size = (gsize) W * H * bpp;
  guint8 *data = g_malloc (size);
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, W, H), 1, format, data,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  g_checksum_update (sum, data, size); g_free (data);
  return TRUE;
}

static gchar *
state (Fixture *f)
{
  GChecksum *sum = g_checksum_new (G_CHECKSUM_SHA256);
  GlimsImageInfo info = {0}; GlimsUndoInfo undo = {0};
  if (api->image_info (f->engine, f->id, &info) != GLIMS_STATUS_OK ||
      api->image_undo_info (f->engine, f->id, &undo) != GLIMS_STATUS_OK ||
      !hash_buffer (sum, gimp_drawable_get_buffer (f->drawable)) ||
      !hash_buffer (sum, gimp_drawable_get_buffer (GIMP_DRAWABLE (gimp_image_get_mask (f->image)))))
    { g_checksum_free (sum); return NULL; }
  g_checksum_update (sum, (const guchar *) &info, sizeof info);
  g_checksum_update (sum, (const guchar *) &undo, sizeof undo);
  GimpColorProfile *profiles[] = { gimp_image_get_color_profile (f->image),
                                  gimp_image_get_simulation_profile (f->image) };
  for (guint i = 0; i < G_N_ELEMENTS (profiles); i++)
    {
      g_checksum_update (sum, (const guchar *) &profiles[i], sizeof profiles[i]);
      if (profiles[i])
        { gsize length = 0; const guint8 *data = gimp_color_profile_get_icc_profile (profiles[i], &length);
          g_checksum_update (sum, data, length); }
    }
  GimpColorRenderingIntent intent = gimp_image_get_simulation_intent (f->image);
  gboolean bpc = gimp_image_get_simulation_bpc (f->image);
  g_checksum_update (sum, (const guchar *) &intent, sizeof intent);
  g_checksum_update (sum, (const guchar *) &bpc, sizeof bpc);
  GList *lists[] = { gimp_image_get_selected_layers (f->image),
                    gimp_image_get_selected_channels (f->image), gimp_image_get_selected_paths (f->image) };
  for (guint i = 0; i < G_N_ELEMENTS (lists); i++)
    {
      guint length = g_list_length (lists[i]);
      g_checksum_update (sum, (const guchar *) &length, sizeof length);
      for (GList *p = lists[i]; p; p = p->next)
        { gint id = gimp_item_get_id (GIMP_ITEM (p->data)); g_checksum_update (sum, (const guchar *) &id, sizeof id); }
    }
  gchar *result = g_strdup (g_checksum_get_string (sum)); g_checksum_free (sum); return result;
}

static gboolean
native_reference (Fixture *f, GimpColorProfile *dest, GimpColorProfile *proof,
                   const GlimsProofSettings *settings, gfloat expected[N])
{
  /* Independent table: never reuse the production owned-intent mapper. */
  static const GimpColorRenderingIntent intents[] = {
    GIMP_COLOR_RENDERING_INTENT_PERCEPTUAL, GIMP_COLOR_RENDERING_INTENT_RELATIVE_COLORIMETRIC,
    GIMP_COLOR_RENDERING_INTENT_SATURATION, GIMP_COLOR_RENDERING_INTENT_ABSOLUTE_COLORIMETRIC
  };
  GimpColorProfile *source = gimp_image_get_color_profile (f->image);
  if (!source) source = gimp_image_get_builtin_color_profile (f->image);
  GimpColorTransform *transform = gimp_color_transform_new_proofing (
    source, babl_format ("R'G'B'A float"), dest, babl_format ("R'G'B'A float"), proof,
    intents[settings->proof_intent - 1], intents[settings->display_intent - 1],
    settings->flags ? GIMP_COLOR_TRANSFORM_FLAGS_BLACK_POINT_COMPENSATION : 0);
  if (!transform) return FALSE;
  gimp_color_transform_process_pixels (transform, babl_format ("R'G'B'A float"), f->straight,
                                       babl_format ("R'G'B'A float"), expected, W * H);
  g_object_unref (transform);
  for (guint i = 0; i < N; i++) if (!isfinite (expected[i])) return FALSE;
  return TRUE;
}

static int
quantize_unit (double value)
{
  return (int) lround (CLAMP (value, 0.0, 1.0) * 255.0);
}

static gboolean
output_matches (const guint8 out[OUTPUT_BYTES], const gfloat expected[N], const Fixture *f)
{
  for (guint i = 0; i < OUTPUT_BYTES; i++)
    {
      gboolean pixel = i >= GUARD && i < GUARD + H * STRIDE && (i - GUARD) % STRIDE < W * 4;
      if (!pixel && out[i] != 0xA7) return FALSE;
    }
  for (guint y = 0; y < H; y++) for (guint x = 0; x < W; x++)
    {
      guint j = (y * W + x) * 4, k = GUARD + y * STRIDE + x * 4;
      double alpha = f->straight[j + 3];
      if (fabs (expected[j + 3] - alpha) > 1e-6 || abs ((int) out[k + 3] - quantize_unit (alpha)) > 1) return FALSE;
      for (guint c = 0; c < 3; c++)
        if (abs ((int) out[k + c] - quantize_unit (expected[j + c] * alpha)) > 1) return FALSE;
    }
  return TRUE;
}

static guint
matrix (Fixture *f, GimpColorProfile *dest, GimpColorProfile *proof, gboolean mandatory,
         const guint8 plain[N], gboolean *discriminates)
{
  gsize dest_size = 0, proof_size = 0;
  const guint8 *dest_data = gimp_color_profile_get_icc_profile (dest, &dest_size);
  const guint8 *proof_data = gimp_color_profile_get_icc_profile (proof, &proof_size);
  guint supported = 0;
  for (uint32_t pi = 1; pi <= 4; pi++) for (uint32_t di = 1; di <= 4; di++) for (uint32_t bpc = 0; bpc <= 1; bpc++)
    {
      GlimsProofSettings settings = { sizeof settings, pi, di, bpc ? GLIMS_PROOF_BLACK_POINT_COMPENSATION : 0 };
      gfloat expected[N]; guint8 out[OUTPUT_BYTES]; memset (out, 0xA7, sizeof out);
      gboolean reference_ok = native_reference (f, dest, proof, &settings, expected);
      printf ("OBS native proof matrix %s proof_intent=%u display_intent=%u bpc=%u accepted=%d\n",
              mandatory ? "RGB" : "provided non-RGB", pi, di, bpc, reference_ok); fflush (stdout);
      if (mandatory) CHECK (reference_ok, "mandatory RGB native reference is constructible and finite");
      char *error = NULL;
      GlimsStatus result = api->image_render_proofed (f->engine, f->id, 1, (GlimsRect) {0, 0, W, H},
        dest_data, dest_size, proof_data, proof_size, &settings, out + GUARD, STRIDE, &error);
      if (reference_ok)
        {
          supported++;
          CHECK (result == GLIMS_STATUS_OK, "actual slot164 dispatch accepts native-supported profile/intents/BPC");
          CHECK (result == GLIMS_STATUS_OK && output_matches (out, expected, f),
                 "actual proof pixels match independent native reference, alpha and stride guards");
          for (guint i = 0; i < N; i++) if (i % 4 != 3 &&
              abs (quantize_unit (expected[i] * f->straight[(i / 4) * 4 + 3]) - plain[i]) > 2) *discriminates = TRUE;
        }
      else
        {
          guint8 poison[OUTPUT_BYTES]; memset (poison, 0xA7, sizeof poison);
          CHECK (result != GLIMS_STATUS_OK && !memcmp (out, poison, sizeof out),
                 "native-unsupported proof combination refuses without writing output");
        }
      clear_error (&error);
    }
  return supported;
}

static void
refusal (Fixture *f, const guint8 *dest, gsize dest_size, const guint8 *proof, gsize proof_size,
          const GlimsProofSettings *settings, double scale, GlimsRect area, size_t stride,
          GlimsStatus expected, const char *label)
{
  guint8 out[OUTPUT_BYTES], poison[OUTPUT_BYTES]; char *error = NULL;
  memset (out, 0xA7, sizeof out); memset (poison, 0xA7, sizeof poison);
  GlimsStatus result = api->image_render_proofed (f->engine, f->id, scale, area, dest, dest_size,
    proof, proof_size, settings, out + GUARD, stride, &error);
  CHECK (result == expected && !memcmp (out, poison, sizeof out), label);
  clear_error (&error);
}

/* Two small source-model oracles, not another intent matrix. The independent
 * reference reads the authentic projection in its OWN space: two-component
 * Y'A float for gray, four-component RGB expansion for indexed. */
static void
source_model_case (GlimsEngine *engine, uint32_t mode, GimpColorProfile *dest, GimpColorProfile *proof)
{
  Fixture f = { .engine = engine };
  GimpColorTransform *reference = NULL;
  gchar *before = NULL, *after = NULL; char *error = NULL;
  gboolean gray = mode == GLIMS_COLOR_MODE_GRAYSCALE;
  const char *encoding = gray ? "Y'A float" : "R'G'B'A float";
  guint components = gray ? 2 : 4;
  gfloat source[N] = {0}, expected[N] = {0}; guint8 out[OUTPUT_BYTES];
  printf ("OBS source image oracle: %s\n", gray ? "grayscale" : "indexed");
  NEED (api->image_from_pixels (engine, W, H, input, sizeof input, &f.id, &error) == GLIMS_STATUS_OK,
         "source-model oracle creates a fresh native image"); clear_error (&error);
  if (gray)
    {
      NEED (api->image_convert_mode (engine, f.id, GLIMS_COLOR_MODE_GRAYSCALE, &error) == GLIMS_STATUS_OK,
             "fixture converts the actual image to grayscale"); clear_error (&error);
    }
  else
    {
      NEED (api->image_convert_precision (engine, f.id, GLIMS_COLOR_COMPONENT_U8,
        GLIMS_COLOR_TRC_NONLINEAR, &error) == GLIMS_STATUS_OK,
        "indexed source fixture establishes required u8 nonlinear precision"); clear_error (&error);
      GlimsIndexedSettings settings = { .struct_size = sizeof settings,
        .palette = GLIMS_INDEXED_PALETTE_GENERATED, .max_colors = 16,
        .dither = GLIMS_INDEXED_DITHER_NONE, .preservation = GLIMS_INDEXED_PRESERVE_EDITABLE };
      NEED (api->image_convert_indexed (engine, f.id, &settings, NULL, 0, &error) == GLIMS_STATUS_OK,
             "fixture converts the actual image to indexed"); clear_error (&error);
    }
  GlimsOpenImage *open = glims_lookup_image (engine, f.id);
  NEED (open && gimp_image_get_base_type (open->image) == (gray ? GIMP_GRAY : GIMP_INDEXED),
         "source-model fixture has the requested authentic native base type");
  f.image = open->image;
  GlimsLayerInfo layer = {0}; int32_t count = 0;
  NEED (api->image_layers (engine, f.id, &layer, 1, &count) == GLIMS_STATUS_OK && count == 1 &&
        (f.drawable = glims_lookup_drawable (open, layer.id)) != NULL,
        "converted fixture resolves its live native pixel source");
  const Babl *projection_format = gimp_projectable_get_format (GIMP_PROJECTABLE (f.image));
  NEED (projection_format && babl_format_get_n_components (projection_format) == (gint) components &&
        babl_format_has_alpha (projection_format), "native projection has the expected source component shape");
  const Babl *format = babl_format_with_space (encoding, babl_format_get_space (projection_format));
  GimpProjection *projection = gimp_image_get_projection (f.image);
  GeglBuffer *buffer = gimp_pickable_get_buffer (GIMP_PICKABLE (projection));
  gimp_projection_flush_now (projection, TRUE);
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, W, H), 1, format, source,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  for (guint i = 0; i < W * H; i++) f.straight[i * 4 + 3] = source[i * components + components - 1];
  GimpColorProfile *source_profile = gimp_image_get_color_profile (f.image);
  if (!source_profile) source_profile = gimp_image_get_builtin_color_profile (f.image);
  reference = gimp_color_transform_new_proofing (source_profile, babl_format (encoding),
    dest, babl_format ("R'G'B'A float"), proof, GIMP_COLOR_RENDERING_INTENT_RELATIVE_COLORIMETRIC,
    GIMP_COLOR_RENDERING_INTENT_RELATIVE_COLORIMETRIC, (GimpColorTransformFlags) 0);
  NEED (reference != NULL, "native source-model proof reference is constructible");
  gimp_color_transform_process_pixels (reference, format, source, babl_format ("R'G'B'A float"), expected, W * H);
  gboolean finite = TRUE;
  for (guint i = 0; i < N; i++) finite = finite && isfinite (expected[i]);
  NEED (finite, "native source-model reference pixels are finite");
  before = state (&f); NEED (before != NULL, "converted native source state is captured before rendering");
  gsize ds = 0, ps = 0;
  const guint8 *d = gimp_color_profile_get_icc_profile (dest, &ds), *p = gimp_color_profile_get_icc_profile (proof, &ps);
  GlimsProofSettings settings = { sizeof settings, GLIMS_PROFILE_RELATIVE_COLORIMETRIC,
    GLIMS_PROFILE_RELATIVE_COLORIMETRIC, 0 };
  memset (out, 0xA7, sizeof out);
  GlimsStatus rendered = api->image_render_proofed (engine, f.id, 1, (GlimsRect) {0, 0, W, H},
    d, ds, p, ps, &settings, out + GUARD, STRIDE, &error);
  CHECK (rendered == GLIMS_STATUS_OK, "actual slot164 renders the converted source model"); clear_error (&error);
  CHECK (rendered == GLIMS_STATUS_OK && output_matches (out, expected, &f),
         "converted source proof matches native own-space reference plus alpha/premultiply/row guards");
  after = state (&f);
  CHECK (before && after && !strcmp (before, after),
         "proof rendering preserves converted source pixels/profile/selection/dirty/full history");
cleanup:
  clear_error (&error); g_free (before); g_free (after); g_clear_object (&reference);
  if (f.id) api->image_close (engine, f.id);
}

static GlimsStatus
regression (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = { .engine = engine };
  GimpColorProfile *dest = NULL, *proof = NULL, *gray = NULL, *cmyk = NULL;
  gchar *before = NULL, *after = NULL; char *error = NULL;
  guint8 plain[N], after_plain[N]; gboolean discriminates = FALSE;
  NEED (api->image_from_pixels (engine, W, H, input, sizeof input, &f.id, &error) == GLIMS_STATUS_OK,
         "real native RGBA source image is created"); clear_error (&error);
  GlimsOpenImage *open = glims_lookup_image (engine, f.id);
  NEED (open != NULL, "fixture resolves the real live image"); f.image = open->image;
  GlimsLayerInfo layer = {0}; int32_t count = 0;
  NEED (api->image_layers (engine, f.id, &layer, 1, &count) == GLIMS_STATUS_OK && count == 1,
         "fixture has exactly one pixel source layer");
  f.drawable = glims_lookup_drawable (open, layer.id);
  NEED (f.drawable != NULL, "fixture resolves the authentic native drawable");
  GeglBuffer *buffer = gimp_drawable_get_buffer (f.drawable);
  const Babl *own_space = babl_format_get_space (gegl_buffer_get_format (buffer));
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, W, H), 1,
    babl_format_with_space ("R'G'B'A float", own_space), f.straight, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  dest = gimp_color_profile_new_rgb_srgb (); proof = rgb_proof (); gray = gray_proof ();
  NEED (dest && proof && gray, "native-generated RGB/gray profiles are constructible");
  gsize ds = 0, ps = 0, gs = 0;
  const guint8 *d = gimp_color_profile_get_icc_profile (dest, &ds);
  const guint8 *p = gimp_color_profile_get_icc_profile (proof, &ps);
  const guint8 *g = gimp_color_profile_get_icc_profile (gray, &gs);
  GlimsPoint corners[] = { {0, 0}, {2, 1} };
  GlimsSelectOptions select = { .struct_size = sizeof select, .operation = GLIMS_SELECT_REPLACE };
  NEED (api->select_shape (engine, f.id, GLIMS_SHAPE_RECTANGLE, corners, 2, &select) == GLIMS_STATUS_OK,
         "fixture carries a nonempty partial native selection");
  NEED (gimp_image_set_simulation_profile (f.image, dest), "fixture holds independent saved simulation profile");
  gimp_image_set_simulation_intent (f.image, GIMP_COLOR_RENDERING_INTENT_SATURATION);
  gimp_image_set_simulation_bpc (f.image, TRUE);
  before = state (&f); NEED (before != NULL, "complete native read-only state fingerprint is captured");
  NEED (api->image_render_to_profile (engine, f.id, 1, (GlimsRect) {0, 0, W, H}, d, ds,
    plain, W * 4, &error) == GLIMS_STATUS_OK, "unchanged slot132 renders the unproofed baseline"); clear_error (&error);
  CHECK (matrix (&f, dest, proof, TRUE, plain, &discriminates) == 32,
         "all32 RGB intent/BPC native references are constructible and finite");
  CHECK (discriminates, "mandatory RGB proof fixture is discriminating against unproofed output");
  gboolean gray_diff = FALSE;
  guint gray_supported = matrix (&f, dest, gray, FALSE, plain, &gray_diff);
  printf ("OBS generated Gray proof: %u native-supported combinations; others explicitly refused\n", gray_supported);
  if (cmyk_path)
    {
      int checks_before_cmyk = checks;
      GError *native_error = NULL; GFile *file = g_file_new_for_path (cmyk_path);
      cmyk = gimp_color_profile_new_from_file (file, &native_error); g_object_unref (file);
      if (native_error) fprintf (stderr, "CMYK fixture: %s\n", native_error->message);
      g_clear_error (&native_error);
      NEED (cmyk && cmsGetColorSpace (gimp_color_profile_get_lcms_profile (cmyk)) == cmsSigCmykData,
             "provided external fixture is a valid native CMYK ICC profile");
      gboolean cmyk_diff = FALSE;
      CHECK (matrix (&f, dest, cmyk, FALSE, plain, &cmyk_diff) > 0,
             "provided CMYK proof is accepted by at least one native intent/BPC combination");
      printf ("OBS external CMYK adds %d checks\n", checks - checks_before_cmyk);
    }
  else printf ("OBS no external CMYK fixture supplied; CMYK coverage is not claimed\n");
  GlimsProofSettings settings = { sizeof settings, GLIMS_PROFILE_RELATIVE_COLORIMETRIC,
    GLIMS_PROFILE_RELATIVE_COLORIMETRIC, 0 };
  GlimsRect full = {0, 0, W, H};
#define BAD(dst, dl, prf, pl, set, scale, area, stride, status, text) \
  refusal (&f, dst, dl, prf, pl, set, scale, area, stride, status, text)
  BAD (d, ds, p, ps, NULL, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "NULL settings refuse before output write");
  uint32_t short_settings = sizeof short_settings;
  BAD (d, ds, p, ps, (const GlimsProofSettings *) &short_settings, 1, full, STRIDE,
       GLIMS_STATUS_INVALID_ARGUMENT, "genuinely short settings prefix refuses without reading later fields");
  GlimsProofSettings invalid = settings; invalid.proof_intent = 0;
  BAD (d, ds, p, ps, &invalid, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "invalid proof intent refuses");
  invalid = settings; invalid.display_intent = UINT32_MAX;
  BAD (d, ds, p, ps, &invalid, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "invalid display intent refuses");
  invalid = settings; invalid.flags = 2;
  BAD (d, ds, p, ps, &invalid, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "unknown owned proof flag refuses");
  invalid.flags = 0x2000;
  BAD (d, ds, p, ps, &invalid, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "raw native BPC flag is not an owned flag");
  BAD (NULL, ds, p, ps, &settings, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "NULL destination ICC refuses");
  BAD (d, 0, p, ps, &settings, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "empty destination ICC refuses");
  BAD (d, GLIMS_MAX_ICC_PROFILE_BYTES + 1, p, ps, &settings, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "oversized destination ICC refuses before read");
  BAD (d, ds, NULL, ps, &settings, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "NULL proof ICC cannot select unproofed rendering");
  BAD (d, ds, p, 0, &settings, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "empty proof ICC refuses");
  BAD (d, ds, p, GLIMS_MAX_ICC_PROFILE_BYTES + 1, &settings, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "oversized proof ICC refuses before read");
  const guint8 malformed[] = "not an ICC profile";
  BAD (malformed, sizeof malformed, p, ps, &settings, 1, full, STRIDE, GLIMS_STATUS_FAILED, "malformed destination ICC refuses without output writes");
  BAD (d, ds, malformed, sizeof malformed, &settings, 1, full, STRIDE, GLIMS_STATUS_FAILED, "malformed proof ICC never falls back to unproofed output");
  BAD (g, gs, p, ps, &settings, 1, full, STRIDE, GLIMS_STATUS_UNSUPPORTED, "valid non-RGB destination remains unsupported");
  BAD (d, ds, p, ps, &settings, NAN, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "NaN scale refuses");
  BAD (d, ds, p, ps, &settings, INFINITY, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "infinite scale refuses");
  BAD (d, ds, p, ps, &settings, 0, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "zero scale refuses");
  BAD (d, ds, p, ps, &settings, 33, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "above-cap scale refuses");
  BAD (d, ds, p, ps, &settings, 1.0 / 2097152, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "below-cap scale refuses");
  BAD (d, ds, p, ps, &settings, 1, full, W * 4 - 1, GLIMS_STATUS_INVALID_ARGUMENT, "short output stride refuses");
  BAD (d, ds, p, ps, &settings, 1, full, SIZE_MAX, GLIMS_STATUS_INVALID_ARGUMENT, "overflow output stride refuses");
  GlimsRect huge = {0, 0, W, INT32_MAX};
  BAD (d, ds, p, ps, &settings, 1, huge, W * 4, GLIMS_STATUS_INVALID_ARGUMENT, "oversized output area refuses");
  GlimsRect overflow = {INT32_MAX, 0, W, H};
  BAD (d, ds, p, ps, &settings, 1, overflow, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "overflowing coordinate sum refuses");
#undef BAD
  Fixture missing = f; missing.id = -12345;
  refusal (&missing, d, ds, p, ps, &settings, 1, full, STRIDE, GLIMS_STATUS_NOT_FOUND,
           "unknown image refuses without writing output");
  CHECK (api->image_render_proofed (engine, f.id, 1, full, d, ds, p, ps, &settings,
    NULL, STRIDE, &error) == GLIMS_STATUS_INVALID_ARGUMENT, "NULL output is rejected"); clear_error (&error);
  struct { GlimsProofSettings prefix; uint64_t tail; } extended = { settings, UINT64_C (0x1234567890abcdef) };
  extended.prefix.struct_size = sizeof extended;
  guint8 guarded[OUTPUT_BYTES]; memset (guarded, 0xA7, sizeof guarded);
  CHECK (api->image_render_proofed (engine, f.id, 1, full, d, ds, p, ps, &extended.prefix,
    guarded + GUARD, STRIDE, &error) == GLIMS_STATUS_OK && extended.tail == UINT64_C (0x1234567890abcdef),
    "larger settings prefix is accepted without touching future tail"); clear_error (&error);
  engine->busy++;
  GlimsStatus busy_read = api->image_render_proofed (engine, f.id, 1, full, d, ds, p, ps,
    &settings, guarded + GUARD, STRIDE, &error);
  engine->busy--;
  CHECK (busy_read == GLIMS_STATUS_OK, "read-only proofing remains available while mutation admission is busy"); clear_error (&error);
  CHECK (api->image_render_to_profile (engine, f.id, 1, full, d, ds, after_plain, W * 4, &error) == GLIMS_STATUS_OK &&
         !memcmp (plain, after_plain, sizeof plain), "slot132 bytes stay unchanged after successful and refused proofing"); clear_error (&error);
  after = state (&f);
  CHECK (before && after && !strcmp (before, after),
         "native pixels/profile/selection/saved simulation/dirty/full Undo are unchanged");
  source_model_case (engine, GLIMS_COLOR_MODE_GRAYSCALE, dest, proof);
  source_model_case (engine, GLIMS_COLOR_MODE_INDEXED, dest, proof);
cleanup:
  clear_error (&error); g_free (before); g_free (after);
  g_clear_object (&cmyk); g_clear_object (&gray); g_clear_object (&proof); g_clear_object (&dest);
  if (f.id) api->image_close (engine, f.id);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2 && argc != 3) { fprintf (stderr, "usage: %s WORK_DIR [CMYK_PROFILE]\n", argv[0]); return 2; }
  if (argc == 3) cmyk_path = argv[2];
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api || !api->image_render_proofed)
    { fprintf (stderr, "fresh API164 producer required; old engine.o is not a valid harness input\n"); return 2; }
  /* A sentinel detects untouched output without ever dereferencing or
   * freeing it. The facade must define optional error output on failures
   * both before dispatch and during native argument validation. */
  char *refused_error = (char *) api;
  CHECK (api->image_render_proofed (NULL, 0, 1, (GlimsRect) { 0, 0, 1, 1 },
    NULL, 0, NULL, 0, NULL, NULL, 0, &refused_error) == GLIMS_STATUS_NOT_RUNNING &&
    refused_error == NULL, "proof error output is cleared before rejected engine dispatch");
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    { fprintf (stderr, "start: %s\n", error ? error : "failed"); clear_error (&error); g_free (user); g_free (cache); return 2; }
  refused_error = (char *) api;
  CHECK (api->image_render_proofed (engine, 0, 1, (GlimsRect) { 0, 0, 1, 1 },
    NULL, 0, NULL, 0, NULL, NULL, 0, &refused_error) == GLIMS_STATUS_INVALID_ARGUMENT &&
    refused_error == NULL, "proof error output is cleared before native argument refusal");
  CHECK (glims_engine_call (engine, regression, NULL) == GLIMS_STATUS_OK, "native proof regression executes on the engine worker");
  api->stop (engine); g_free (user); g_free (cache);
  printf ("OBS total native proof checks: %d\n", checks);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}

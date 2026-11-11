/* TEST-ONLY native gamut-warning contract slice for facade slot164
 * (image_render_proofed). No production code is changed by this file.
 *
 * The proof-render suite's static helpers (fixture profiles, state
 * fingerprint, refusal sentinels, output/alpha/premultiply oracle, old
 * native reference) are reused by inclusion with the included main renamed;
 * it never runs here, so scripts/test-proof-gamut.py compiles this harness
 * with -Wno-unused-function. The included suite's own regression — including
 * its unknown-flag refusal case — is dead code in this binary and is not
 * executed.
 *
 * Contract under test: owned bit 2, named independently below rather than
 * read from the facade header, must be
 * accepted by the public proof renderer and must match an independently
 * constructed direct native proofing transform carrying the native
 * GAMUT_CHECK flag. The baseline renderer refused bit 2 with
 * INVALID_ARGUMENT and wrote nothing; the regression requires actual native
 * gamut pixels rather than accepting that old refusal.
 *
 * proof-gamut-tests WORK_DIR
 */
#define main proof_render_suite_main
#include "proof-render-tests.c"
#undef main

/* Independently fixed owned flag bit 2. Reusing the facade enum here could
 * let a mistaken production value silently change this regression oracle. */
#define GLIMS_PROOF_GAMUT_CANDIDATE2 2u

/* Deliberately saturated samples with differing, mostly partial alpha: the
 * narrow mandatory proof profile below cannot reproduce them, so the gamut
 * alarm must mark them, each premultiplied by its own alpha. */
static const guint8 gamut_input[N] = {
  255, 0, 0, 255,   0, 255, 0, 200,   0, 0, 255, 128,   255, 255, 0, 64,
  255, 0, 255, 32,  0, 255, 255, 16,  255, 128, 0, 255, 10, 200, 90, 255
};

/* Independent per-bit native flag table for the candidate: owned bit 1 maps
 * to native BPC, candidate bit 2 maps to the native GAMUT_CHECK flag. The
 * production owned-flag mask is never reused here. */
static GimpColorTransformFlags
candidate_native_flags (uint32_t owned)
{
  GimpColorTransformFlags flags = (GimpColorTransformFlags) 0;
  if (owned & (uint32_t) GLIMS_PROOF_BLACK_POINT_COMPENSATION)
    flags |= GIMP_COLOR_TRANSFORM_FLAGS_BLACK_POINT_COMPENSATION;
  if (owned & GLIMS_PROOF_GAMUT_CANDIDATE2)
    flags |= GIMP_COLOR_TRANSFORM_FLAGS_GAMUT_CHECK;
  return flags;
}

/* Read-only ambient default-context alarm codes. This suite NEVER calls
 * cmsSetAlarmCodes or any other alarm setter: the local lcms2 default is
 * neutral gray, codes are consumed while pixels are evaluated, and nothing
 * here may assume blue/magenta or captured-at-construction alarm state. */
static void
read_alarm_codes (cmsUInt16Number codes[cmsMAXCHANNELS])
{
  memset (codes, 0, cmsMAXCHANNELS * sizeof (codes[0]));
  cmsGetAlarmCodes (codes);
}

/* Independent native proofing oracle for the candidate: its own intent
 * table and per-bit flag mapping over the fixture's own straight pixels.
 * alarm_at_evaluation receives the ambient codes read around the pixel
 * evaluation. */
static gboolean
gamut_native_reference (Fixture *f, GimpColorProfile *dest, GimpColorProfile *proof,
                        const GlimsProofSettings *settings, gfloat expected[N],
                        cmsUInt16Number alarm_at_evaluation[cmsMAXCHANNELS])
{
  static const GimpColorRenderingIntent intents[] = {
    GIMP_COLOR_RENDERING_INTENT_PERCEPTUAL, GIMP_COLOR_RENDERING_INTENT_RELATIVE_COLORIMETRIC,
    GIMP_COLOR_RENDERING_INTENT_SATURATION, GIMP_COLOR_RENDERING_INTENT_ABSOLUTE_COLORIMETRIC
  };
  cmsUInt16Number after[cmsMAXCHANNELS];
  GimpColorProfile *source = gimp_image_get_color_profile (f->image);
  if (!source) source = gimp_image_get_builtin_color_profile (f->image);
  GimpColorTransform *transform = gimp_color_transform_new_proofing (
    source, babl_format ("R'G'B'A float"), dest, babl_format ("R'G'B'A float"), proof,
    intents[settings->proof_intent - 1], intents[settings->display_intent - 1],
    candidate_native_flags (settings->flags));
  if (! transform) return FALSE;
  read_alarm_codes (alarm_at_evaluation);
  gimp_color_transform_process_pixels (transform, babl_format ("R'G'B'A float"), f->straight,
                                       babl_format ("R'G'B'A float"), expected, W * H);
  read_alarm_codes (after);
  g_object_unref (transform);
  CHECK (!memcmp (alarm_at_evaluation, after, sizeof after),
         "ambient alarm codes are unchanged across native pixel evaluation");
  for (guint i = 0; i < N; i++) if (!isfinite (expected[i])) return FALSE;
  return TRUE;
}

static gboolean
pixel_is_alarm (const gfloat pixel[4], const cmsUInt16Number alarm[cmsMAXCHANNELS])
{
  for (guint c = 0; c < 3; c++)
    if (fabs (pixel[c] - alarm[c] / 65535.0) > 1e-3) return FALSE;
  return TRUE;
}

/* Direct per-sample alpha and premultiply checks on EVERY sample; for each
 * gamut-marked sample, a direct check that the output RGB is the ambient
 * alarm color premultiplied by THAT sample's own alpha — never one
 * identical premultiplied alarm color across differing alpha. */
static gboolean
alarm_sample_checks (const guint8 out[OUTPUT_BYTES], const gfloat expected[N],
                     const cmsUInt16Number alarm[cmsMAXCHANNELS], const Fixture *f,
                     guint *marked, gboolean *marked_partial, gboolean *marked_spread)
{
  gboolean first_seen = FALSE;
  double first_alpha = 0;
  guint8 first_rgb[3] = { 0, 0, 0 };
  for (guint y = 0; y < H; y++) for (guint x = 0; x < W; x++)
    {
      guint j = (y * W + x) * 4, k = GUARD + y * STRIDE + x * 4;
      double alpha = f->straight[j + 3];
      if (abs ((int) out[k + 3] - quantize_unit (alpha)) > 1) return FALSE;
      for (guint c = 0; c < 3; c++)
        if (abs ((int) out[k + c] - quantize_unit (expected[j + c] * alpha)) > 1) return FALSE;
      if (! pixel_is_alarm (expected + j, alarm)) continue;
      (*marked)++;
      if (alpha > 1.0 / 255.0 && alpha < 254.0 / 255.0) *marked_partial = TRUE;
      for (guint c = 0; c < 3; c++)
        if (abs ((int) out[k + c] - quantize_unit (alarm[c] / 65535.0 * alpha)) > 1) return FALSE;
      if (! first_seen)
        {
          first_seen = TRUE; first_alpha = alpha;
          for (guint c = 0; c < 3; c++) first_rgb[c] = out[k + c];
        }
      else if (fabs (alpha - first_alpha) > 4.0 / 255.0)
        {
          gboolean identical = TRUE;
          *marked_spread = TRUE;
          for (guint c = 0; c < 3; c++) if (out[k + c] != first_rgb[c]) identical = FALSE;
          if (identical) return FALSE;
        }
    }
  return TRUE;
}

/* Mandatory (RGB proof) or optional (non-RGB proof) 4x4 intent x 2 BPC x 2
 * gamut-state matrix. Gamut-off rows reuse the included old native oracle
 * (flags 0/1 must retain old behavior); gamut-on rows use the independent
 * per-bit GAMUT_CHECK oracle. Native-unsupported combinations must refuse
 * without writing output. */
static void
gamut_matrix (Fixture *f, GimpColorProfile *dest, GimpColorProfile *proof, gboolean mandatory)
{
  gsize dest_size = 0, proof_size = 0;
  const guint8 *dest_data = gimp_color_profile_get_icc_profile (dest, &dest_size);
  const guint8 *proof_data = gimp_color_profile_get_icc_profile (proof, &proof_size);
  cmsUInt16Number alarm_start[cmsMAXCHANNELS], alarm_end[cmsMAXCHANNELS];
  read_alarm_codes (alarm_start);
  guint marked_total = 0;
  gboolean partial = FALSE, spread = FALSE, oracle_diff = FALSE, actual_diff = FALSE;
  for (uint32_t pi = 1; pi <= 4; pi++) for (uint32_t di = 1; di <= 4; di++)
    for (uint32_t bpc = 0; bpc <= 1; bpc++)
    {
      GlimsProofSettings off = { sizeof off, pi, di,
                                 bpc ? (uint32_t) GLIMS_PROOF_BLACK_POINT_COMPENSATION : 0u };
      GlimsProofSettings on = off;
      on.flags |= GLIMS_PROOF_GAMUT_CANDIDATE2;
      gfloat expected_off[N] = { 0 }, expected_on[N] = { 0 };
      guint8 out_off[OUTPUT_BYTES], out_on[OUTPUT_BYTES];
      cmsUInt16Number alarm_eval[cmsMAXCHANNELS] = { 0 };
      memset (out_off, 0xA7, sizeof out_off);
      memset (out_on, 0xA7, sizeof out_on);
      gboolean ref_off = native_reference (f, dest, proof, &off, expected_off);
      gboolean ref_on = gamut_native_reference (f, dest, proof, &on, expected_on, alarm_eval);
      printf ("OBS gamut matrix proof_intent=%u display_intent=%u bpc=%u gamut_ref=%d plain_ref=%d\n",
              pi, di, bpc, ref_on, ref_off); fflush (stdout);
      char *error = NULL;
      GlimsStatus r_off = api->image_render_proofed (f->engine, f->id, 1, (GlimsRect) {0, 0, W, H},
        dest_data, dest_size, proof_data, proof_size, &off, out_off + GUARD, STRIDE, &error);
      clear_error (&error);
      GlimsProofSettings on_before = on;
      GlimsStatus r_on = api->image_render_proofed (f->engine, f->id, 1, (GlimsRect) {0, 0, W, H},
        dest_data, dest_size, proof_data, proof_size, &on, out_on + GUARD, STRIDE, &error);
      clear_error (&error);
      CHECK (!memcmp (&on, &on_before, sizeof on), "caller-owned settings struct is not mutated");
      if (ref_off)
        {
          CHECK (r_off == GLIMS_STATUS_OK, "flags 0/1 keep old oracle behavior: still accepted");
          CHECK (r_off == GLIMS_STATUS_OK && output_matches (out_off, expected_off, f),
                 "flags 0/1 output still matches the old independent native oracle");
        }
      else
        {
          guint8 poison[OUTPUT_BYTES]; memset (poison, 0xA7, sizeof poison);
          CHECK (r_off != GLIMS_STATUS_OK && !memcmp (out_off, poison, sizeof out_off),
                 "native-unsupported plain-proof combination refuses without output writes");
        }
      if (ref_on)
        {
          CHECK (r_on == GLIMS_STATUS_OK, "candidate owned bit 2 is accepted by the public proof renderer");
          CHECK (r_on == GLIMS_STATUS_OK && output_matches (out_on, expected_on, f),
                 "candidate bit 2 output matches the independent native GAMUT_CHECK oracle with guards");
          guint marked = 0; gboolean part = FALSE, spr = FALSE;
          CHECK (alarm_sample_checks (out_on, expected_on, alarm_eval, f, &marked, &part, &spr),
                 "per-sample alpha/premultiply and own-alpha alarm checks hold on every sample");
          marked_total += marked; partial = partial || part; spread = spread || spr;
          if (ref_off)
            for (guint i = 0; i < N; i++)
              if (fabs (expected_on[i] - expected_off[i]) > 1e-4) { oracle_diff = TRUE; break; }
          if (r_on == GLIMS_STATUS_OK && r_off == GLIMS_STATUS_OK)
            for (guint i = 0; i < OUTPUT_BYTES; i++)
              if (out_on[i] != out_off[i]) { actual_diff = TRUE; break; }
        }
      else
        {
          guint8 poison[OUTPUT_BYTES]; memset (poison, 0xA7, sizeof poison);
          CHECK (r_on != GLIMS_STATUS_OK && !memcmp (out_on, poison, sizeof out_on),
                 "native-unsupported gamut combination refuses without output writes");
        }
    }
  read_alarm_codes (alarm_end);
  CHECK (!memcmp (alarm_start, alarm_end, sizeof alarm_start),
         "global cmsGetAlarmCodes is unchanged across the whole matrix (no setter is ever called)");
  if (mandatory)
    {
      CHECK (marked_total > 0, "mandatory narrow proof profile really marks samples (hard failure if none)");
      CHECK (oracle_diff, "mandatory fixture: gamut oracle output really differs from plain proof (hard failure)");
      CHECK (actual_diff, "accepted gamut output really differs from plain-proof output (hard failure)");
      CHECK (partial, "marked samples include partial alpha");
      CHECK (spread, "marked samples at differing alpha carry differing premultiplied alarm bytes");
    }
}

static GlimsStatus
gamut_regression (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = { .engine = engine };
  GimpColorProfile *dest = NULL, *proof = NULL, *gray = NULL;
  gchar *before = NULL, *after = NULL; char *error = NULL;
  guint8 plain[N], after_plain[N];
  cmsUInt16Number alarm_before[cmsMAXCHANNELS], alarm_after[cmsMAXCHANNELS];
  read_alarm_codes (alarm_before);
  NEED (api->image_from_pixels (engine, W, H, gamut_input, sizeof gamut_input, &f.id, &error) == GLIMS_STATUS_OK,
        "real native RGBA source image with saturated partial-alpha samples is created"); clear_error (&error);
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
  NEED (dest && proof && gray, "native sRGB destination and narrow RGB/gray proof profiles are constructible");
  gsize ds = 0, ps = 0, gs = 0;
  const guint8 *d = gimp_color_profile_get_icc_profile (dest, &ds);
  const guint8 *p = gimp_color_profile_get_icc_profile (proof, &ps);
  const guint8 *g = gimp_color_profile_get_icc_profile (gray, &gs);
  GlimsPoint corners[] = { {0, 0}, {2, 1} };
  GlimsSelectOptions select = { .struct_size = sizeof select, .operation = GLIMS_SELECT_REPLACE };
  NEED (api->select_shape (engine, f.id, GLIMS_SHAPE_RECTANGLE, corners, 2, &select) == GLIMS_STATUS_OK,
        "fixture carries a nonempty partial native selection");
  NEED (gimp_image_set_simulation_profile (f.image, dest), "fixture holds an independent saved simulation profile");
  gimp_image_set_simulation_intent (f.image, GIMP_COLOR_RENDERING_INTENT_SATURATION);
  gimp_image_set_simulation_bpc (f.image, TRUE);
  before = state (&f); NEED (before != NULL, "complete native read-only state fingerprint is captured");
  GlimsRect full = {0, 0, W, H};
  NEED (api->image_render_to_profile (engine, f.id, 1, full, d, ds, plain, W * 4, &error) == GLIMS_STATUS_OK,
        "unchanged slot132 renders the unproofed baseline"); clear_error (&error);
  gamut_matrix (&f, dest, proof, TRUE);
  printf ("OBS generated Gray proof with candidate bit 2:\n"); fflush (stdout);
  gamut_matrix (&f, dest, gray, FALSE);
  GlimsProofSettings settings = { sizeof settings, GLIMS_PROFILE_RELATIVE_COLORIMETRIC,
    GLIMS_PROFILE_RELATIVE_COLORIMETRIC, GLIMS_PROOF_GAMUT_CANDIDATE2 };
#define BAD(dst, dl, prf, pl, set, scale, area, stride, status, text) \
  refusal (&f, dst, dl, prf, pl, set, scale, area, stride, status, text)
  BAD (d, ds, p, ps, NULL, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "NULL settings refuse before output write");
  uint32_t short_settings = sizeof short_settings;
  BAD (d, ds, p, ps, (const GlimsProofSettings *) &short_settings, 1, full, STRIDE,
       GLIMS_STATUS_INVALID_ARGUMENT, "genuinely short settings prefix refuses without reading later fields");
  GlimsProofSettings invalid = settings; invalid.flags = 4;
  BAD (d, ds, p, ps, &invalid, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "unknown owned bit 4 refuses");
  invalid.flags = GLIMS_PROOF_GAMUT_CANDIDATE2 | 4;
  BAD (d, ds, p, ps, &invalid, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "candidate bit 2 plus unknown bit 4 refuses");
  invalid.flags = 0x1000;
  BAD (d, ds, p, ps, &invalid, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "raw native GAMUT_CHECK value is not an owned flag");
  invalid.flags = 0x2000;
  BAD (d, ds, p, ps, &invalid, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "raw native BPC value is not an owned flag");
  invalid.flags = GLIMS_PROOF_GAMUT_CANDIDATE2 | 0x1000;
  BAD (d, ds, p, ps, &invalid, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "candidate bit 2 plus raw native value refuses");
  const guint8 malformed[] = "not an ICC profile";
  BAD (d, ds, malformed, sizeof malformed, &settings, 1, full, STRIDE, GLIMS_STATUS_FAILED,
       "malformed proof ICC with candidate bit 2 refuses without output writes");
  BAD (g, gs, p, ps, &settings, 1, full, STRIDE, GLIMS_STATUS_UNSUPPORTED,
       "valid non-RGB destination with candidate bit 2 remains unsupported");
  BAD (d, ds, NULL, ps, &settings, 1, full, STRIDE, GLIMS_STATUS_INVALID_ARGUMENT, "NULL proof ICC refuses");
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
    "larger settings prefix with candidate bit 2 is accepted without touching the future tail"); clear_error (&error);
  GlimsProofSettings plain_settings = { sizeof plain_settings, GLIMS_PROFILE_RELATIVE_COLORIMETRIC,
    GLIMS_PROFILE_RELATIVE_COLORIMETRIC, 0 };
  engine->busy++;
  GlimsStatus busy_read = api->image_render_proofed (engine, f.id, 1, full, d, ds, p, ps,
    &plain_settings, guarded + GUARD, STRIDE, &error);
  engine->busy--;
  CHECK (busy_read == GLIMS_STATUS_OK, "read-only proofing remains available while mutation admission is busy"); clear_error (&error);
  CHECK (api->image_render_to_profile (engine, f.id, 1, full, d, ds, after_plain, W * 4, &error) == GLIMS_STATUS_OK &&
         !memcmp (plain, after_plain, sizeof plain), "slot132 bytes stay unchanged after gamut-proof calls"); clear_error (&error);
  read_alarm_codes (alarm_after);
  CHECK (!memcmp (alarm_before, alarm_after, sizeof alarm_before),
         "global cmsGetAlarmCodes unchanged before/after the whole regression (never any setter)");
  after = state (&f);
  CHECK (before && after && !strcmp (before, after),
         "native pixels/profile/selection/saved simulation/dirty/full Undo are unchanged");
cleanup:
  clear_error (&error); g_free (before); g_free (after);
  g_clear_object (&gray); g_clear_object (&proof); g_clear_object (&dest);
  if (f.id) api->image_close (engine, f.id);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) { fprintf (stderr, "usage: %s WORK_DIR\n", argv[0]); return 2; }
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api || !api->image_render_proofed)
    { fprintf (stderr, "producer exposing slot164 under the current API173 header is required\n"); return 2; }
  /* Sentinel detects untouched error output without dereferencing it. */
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
  CHECK (glims_engine_call (engine, gamut_regression, NULL) == GLIMS_STATUS_OK,
         "native gamut contract regression executes on the engine worker");
  api->stop (engine); g_free (user); g_free (cache);
  printf ("OBS total native gamut contract checks: %d\n", checks);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}

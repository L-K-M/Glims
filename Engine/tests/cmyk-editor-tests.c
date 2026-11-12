/* Facade-only CMYK integration checks (slot 181 image_new_cmyk).
 * No private GIMP internals, no product-preview/naive-RGB color derivation.
 * Render expectations come from an independent LCMS oracle on source ink
 * intensities (TYPE_CMYK_DBL percent coverage -> TYPE_RGB_DBL sRGB, relative
 * colorimetric + black-point compensation). */
#include "glims_engine.h"

#include <lcms2.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 32
#define H 24
#define BYTES (W * H * 4)

static unsigned checks, failures;
#define CHECK(c, msg) do { int pass = !!(c); checks++; \
  printf("%s %s\n", pass ? "ok" : "FAIL", (msg)); \
  if (!pass) failures++; fflush(stdout); } while (0)

static bool
read_file (const char *path, uint8_t **bytes, size_t *length)
{
  FILE *f = fopen (path, "rb");
  long size;
  if (!f) return false;
  if (fseek (f, 0, SEEK_END) != 0) { fclose (f); return false; }
  size = ftell (f);
  if (size <= 0 || fseek (f, 0, SEEK_SET) != 0) { fclose (f); return false; }
  *bytes = (uint8_t *) malloc ((size_t) size);
  if (!*bytes) { fclose (f); return false; }
  if (fread (*bytes, 1, (size_t) size, f) != (size_t) size) { free (*bytes); *bytes = NULL; fclose (f); return false; }
  fclose (f);
  *length = (size_t) size;
  return true;
}

static uint8_t *
make_srgb_icc (size_t *length)
{
  cmsHPROFILE profile = cmsCreate_sRGBProfile ();
  uint8_t *bytes = NULL;
  cmsUInt32Number size = 0;
  if (!profile) return NULL;
  if (cmsSaveProfileToMem (profile, NULL, &size) && size > 0)
    {
      bytes = (uint8_t *) malloc (size);
      if (bytes && !cmsSaveProfileToMem (profile, bytes, &size))
        { free (bytes); bytes = NULL; }
    }
  cmsCloseProfile (profile);
  *length = bytes ? (size_t) size : 0;
  return bytes;
}

static double
quantized_intensity (double value, uint32_t component)
{
  if (component == GLIMS_COLOR_COMPONENT_U8)
    return lrint (value * 255.0) / 255.0;
  if (component == GLIMS_COLOR_COMPONENT_U16)
    return lrint (value * 65535.0) / 65535.0;
  return value;
}

static void
oracle_rgb (cmsHTRANSFORM xform, double c, double m, double y, double k, uint8_t out[3])
{
  /* Oracle takes CMYK coverage percentages (0..100) in TYPE_CMYK_DBL, in that
   * order. Source ink intensity is (1 - coverage), so coverage = (1 - intensity). */
  double cmyk[4] = { (1.0 - c) * 100.0, (1.0 - m) * 100.0,
                     (1.0 - y) * 100.0, (1.0 - k) * 100.0 };
  double rgb[3] = { 0, 0, 0 };
  cmsDoTransform (xform, cmyk, rgb, 1);
  CHECK (isfinite (rgb[0]) && isfinite (rgb[1]) && isfinite (rgb[2]), "independent LCMS oracle returns finite RGB");
  for (int i = 0; i < 3; i++)
    {
      double v = rgb[i];
      if (!isfinite (v)) v = 0;
      if (v < 0) v = 0;
      if (v > 1) v = 1;
      out[i] = (uint8_t) lrint (v * 255.0);
    }
}

static bool
bytes_equal (const uint8_t *a, const uint8_t *b, size_t n)
{
  return memcmp (a, b, n) == 0;
}

static int
max_channel_diff (const uint8_t *a, const uint8_t *b)
{
  int d = 0;
  for (int i = 0; i < 4; i++)
    {
      int diff = abs ((int) a[i] - (int) b[i]);
      if (diff > d) d = diff;
    }
  return d;
}

static void
render_all (const GlimsEngineAPI *api, GlimsEngine *engine, GlimsImageID id, uint8_t *out)
{
  memset (out, 0, BYTES);
  GlimsStatus st = api->image_render (engine, id, 1.0, (GlimsRect){0, 0, W, H}, out, W * 4);
  CHECK (st == GLIMS_STATUS_OK, "image_render returns OK");
}

static void
run_case (const GlimsEngineAPI *api, GlimsEngine *engine,
          uint32_t component, const char *component_name,
          const uint8_t *icc, size_t icc_len, cmsHTRANSFORM xform,
          const char *work_dir)
{
  char label[256], *error = NULL;
  GlimsImageID id = 12345; /* prove reset-to-0 on refusal paths separately */
  GlimsStatus st;

  /* Create safe 32x24 CMYK image with four named C/M/Y/K native channels, zero
   * layers, CMYK color and component mode, source profile embedded/label. */
  snprintf (label, sizeof label, "%s: image_new_cmyk creates 32x24 CMYK document", component_name);
  st = api->image_new_cmyk (engine, W, H, component, icc, icc_len, &id, &error);
  CHECK (st == GLIMS_STATUS_OK && id != 0, label);
  if (st != GLIMS_STATUS_OK || !id)
    { api->free_string (error); return; }
  api->free_string (error); error = NULL;

  GlimsColorInfo color = {0};
  CHECK (api->image_color_info (engine, id, &color) == GLIMS_STATUS_OK, "image_color_info succeeds");
  snprintf (label, sizeof label, "%s: color mode is CMYK", component_name);
  CHECK (color.mode == GLIMS_COLOR_MODE_CMYK, label);
  snprintf (label, sizeof label, "%s: color component matches request", component_name);
  CHECK (color.component == component, label);
  CHECK (color.profile_embedded, "source profile is embedded");
  CHECK (color.profile_label[0] != '\0', "profile label is available");

  GlimsComponentState comp = {0};
  CHECK (api->image_components (engine, id, &comp) == GLIMS_STATUS_OK, "image_components succeeds");
  CHECK (comp.mode == GLIMS_COMPONENT_MODE_CMYK, "component mode is CMYK");

  int32_t layer_count = -1;
  CHECK (api->image_layers (engine, id, NULL, 0, &layer_count) == GLIMS_STATUS_OK && layer_count == 0,
         "document has zero layers");

  GlimsChannelInfo channels[4] = {0};
  int32_t chan_count = 0;
  st = api->image_channels (engine, id, channels, 4, &chan_count);
  CHECK (st == GLIMS_STATUS_OK && chan_count == 4, "four native channels are present");
  if (st != GLIMS_STATUS_OK || chan_count != 4)
    { api->image_close (engine, id); return; }
  const char *expected_names[4] = { "Cyan", "Magenta", "Yellow", "Black" };
  for (int i = 0; i < 4; i++)
    {
      snprintf (label, sizeof label, "%s: channel %d named %s", component_name, i, expected_names[i]);
      CHECK (strcmp (channels[i].name, expected_names[i]) == 0, label);
    }

  /* Stroke Cyan channel with pencil, gray foreground intensity 0.25 => intended
   * source C coverage 75%. Account independently for scalar quantization. */
  GlimsChannelInfo cyan = channels[0];
  GlimsItemID selected = 0;
  CHECK (api->channel_command (engine, id, cyan.id, GLIMS_CHANNEL_SELECT, &selected, &error) == GLIMS_STATUS_OK,
         "Cyan is explicitly selected as the paint target");
  api->free_string (error); error = NULL;
  CHECK (api->image_channels (engine, id, channels, 4, &chan_count) == GLIMS_STATUS_OK &&
         chan_count == 4 && channels[0].id == cyan.id && channels[0].selected,
         "facade channel state confirms the selected Cyan target");
  uint8_t baseline[BYTES];
  render_all (api, engine, id, baseline);
  GlimsBrushSettings brush = {0};
  brush.struct_size = sizeof (brush);
  brush.tool = GLIMS_PAINT_PENCIL;
  brush.size = 9.0;
  brush.opacity = 1.0;
  brush.red = 0.25; brush.green = 0.25; brush.blue = 0.25;
  brush.hardness = 1.0; /* Pencil is hard-edged; provide explicit fields. */
  brush.rate = 0.0;
  brush.flow = 100.0;
  brush.exposure = -1.0;
  GlimsStrokePoint point = {16.0, 12.0, 1.0, 0.0, 0.0, 100};
  GlimsStrokeID stroke = 0;
  st = api->stroke_begin (engine, id, cyan.id, &brush, &point, &stroke, &error);
  CHECK (st == GLIMS_STATUS_OK && stroke != 0, "Pencil stroke begins on Cyan channel");
  api->free_string (error); error = NULL;
  if (stroke)
    CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "Pencil stroke ends");

  uint8_t rendered[BYTES], after_undo[BYTES], after_redo[BYTES];
  render_all (api, engine, id, rendered);

  /* Oracle: C intensity after 75% coverage, quantized by component; others paper. */
  double c_intensity = quantized_intensity (0.25, component);
  uint8_t expected_center[3], expected_paper[3];
  oracle_rgb (xform, c_intensity, 1.0, 1.0, 1.0, expected_center);
  oracle_rgb (xform, 1.0, 1.0, 1.0, 1.0, expected_paper);

  const int center_idx = (12 * W + 16) * 4;
  const int paper_idx = (2 * W + 2) * 4; /* distant paper pixel */
  int center_diff = max_channel_diff (rendered + center_idx, (uint8_t[]){expected_center[0], expected_center[1], expected_center[2], 255});
  int paper_diff = max_channel_diff (rendered + paper_idx, (uint8_t[]){expected_paper[0], expected_paper[1], expected_paper[2], 255});
  snprintf (label, sizeof label, "%s: center pixel matches LCMS oracle within 2 byte levels (diff=%d, got=%u,%u,%u exp=%u,%u,%u qC=%.9g)",
            component_name, center_diff,
            rendered[center_idx], rendered[center_idx+1], rendered[center_idx+2],
            expected_center[0], expected_center[1], expected_center[2], c_intensity);
  CHECK (center_diff <= 2, label);
  snprintf (label, sizeof label, "%s: distant paper pixel matches LCMS oracle within 2 byte levels (diff=%d)",
            component_name, paper_diff);
  CHECK (paper_diff <= 2, label);
  CHECK (rendered[center_idx + 3] == 255 && rendered[paper_idx + 3] == 255,
         "CMYK painted and paper pixels are exactly opaque");

  /* Stroke contributes exactly one Undo step; undo/redo restore exact full bytes. */
  GlimsUndoInfo undo = {0};
  CHECK (api->image_undo_info (engine, id, &undo) == GLIMS_STATUS_OK && undo.undo_count == 1,
         "stroke contributes exactly one Undo step");
  CHECK (api->image_undo (engine, id) == GLIMS_STATUS_OK, "undo succeeds");
  render_all (api, engine, id, after_undo);
  CHECK (bytes_equal (baseline, after_undo, BYTES), "undo restores exact pre-stroke rendered bytes");
  CHECK (api->image_undo_info (engine, id, &undo) == GLIMS_STATUS_OK && undo.undo_count == 0 && undo.redo_count == 1,
         "after undo there is one redo step");
  CHECK (api->image_redo (engine, id) == GLIMS_STATUS_OK, "redo succeeds");
  render_all (api, engine, id, after_redo);
  CHECK (bytes_equal (rendered, after_redo, BYTES), "redo restores exact full rendered bytes");
  /* Hiding/showing C channel changes/restores preview using visibility API. */
  GlimsChannelChange vis = {0};
  vis.struct_size = sizeof (vis);
  vis.properties = GLIMS_CHANNEL_VISIBLE;
  vis.visible = 0;
  CHECK (api->channel_change (engine, id, cyan.id, &vis, &error) == GLIMS_STATUS_OK,
         "hiding Cyan channel succeeds");
  api->free_string (error); error = NULL;
  uint8_t hidden[BYTES];
  render_all (api, engine, id, hidden);
  CHECK (!bytes_equal (hidden, rendered, BYTES), "hiding C channel changes preview");
  vis.visible = 1;
  CHECK (api->channel_change (engine, id, cyan.id, &vis, &error) == GLIMS_STATUS_OK,
         "showing Cyan channel succeeds");
  api->free_string (error); error = NULL;
  uint8_t shown[BYTES];
  render_all (api, engine, id, shown);
  CHECK (bytes_equal (shown, rendered, BYTES), "showing C channel restores preview");

  /* Representative unsupported RGB-only operation returns explicit refusal
   * while leaving rendered bytes and undo unchanged. */
  GlimsUndoInfo before_op = {0};
  CHECK (api->image_undo_info (engine, id, &before_op) == GLIMS_STATUS_OK, "read undo state before refused operation");
  uint8_t before_bytes[BYTES];
  memcpy (before_bytes, rendered, BYTES);
  st = api->image_convert_mode (engine, id, GLIMS_COLOR_MODE_GRAYSCALE, &error);
  CHECK (st == GLIMS_STATUS_UNSUPPORTED, "unsupported RGB-only operation is explicitly refused");
  api->free_string (error); error = NULL;
  GlimsUndoInfo after_op = {0};
  CHECK (api->image_undo_info (engine, id, &after_op) == GLIMS_STATUS_OK, "read undo state after refused operation");
  CHECK (before_op.undo_count == after_op.undo_count && before_op.redo_count == after_op.redo_count,
         "refused operation leaves undo unchanged");
  uint8_t after_bytes[BYTES];
  render_all (api, engine, id, after_bytes);
  CHECK (bytes_equal (before_bytes, after_bytes, BYTES), "refused operation leaves rendered bytes unchanged");

  /* XCF save/close/reopen preserves CMYK mode, four channels, pixels and profile label. */
  char xcf_path[1024];
  snprintf (xcf_path, sizeof xcf_path, "%s/cmyk-%s.xcf", work_dir, component_name);
  st = api->image_save (engine, id, xcf_path, &error);
  CHECK (st == GLIMS_STATUS_OK, "XCF save succeeds");
  api->free_string (error); error = NULL;

  /* Verify saved ordinary XCF contains exact original ICC bytes if feasible.
   * XCF stores this metadata uncompressed as embedded blobs/parasites in file. */
  {
    uint8_t *xcf = NULL; size_t xcf_len = 0;
    if (read_file (xcf_path, &xcf, &xcf_len))
      {
        bool found = false;
        if (icc_len > 0 && xcf_len >= icc_len)
          {
            for (size_t i = 0; i + icc_len <= xcf_len; i++)
              if (memcmp (xcf + i, icc, icc_len) == 0) { found = true; break; }
          }
        CHECK (found, "saved XCF contains the exact original ICC bytes");
        free (xcf);
      }
    else
      {
        CHECK (0, "could read saved XCF to verify ICC bytes");
      }
  }

  CHECK (api->image_close (engine, id) == GLIMS_STATUS_OK, "close saved CMYK image succeeds");
  id = 0;
  st = api->image_open (engine, xcf_path, &id, &error);
  CHECK (st == GLIMS_STATUS_OK && id != 0, "XCF reopen succeeds");
  api->free_string (error); error = NULL;
  if (st == GLIMS_STATUS_OK && id)
    {
      GlimsColorInfo reopened = {0};
      CHECK (api->image_color_info (engine, id, &reopened) == GLIMS_STATUS_OK &&
             reopened.mode == GLIMS_COLOR_MODE_CMYK &&
             reopened.component == component &&
             reopened.profile_embedded &&
             strcmp (reopened.profile_label, color.profile_label) == 0,
             "reopened XCF preserves CMYK mode, component and profile label");
      GlimsComponentState rcomp = {0};
      CHECK (api->image_components (engine, id, &rcomp) == GLIMS_STATUS_OK &&
             rcomp.mode == GLIMS_COMPONENT_MODE_CMYK, "reopened component mode is CMYK");
      GlimsChannelInfo rch[4] = {0}; int32_t rc = 0;
      CHECK (api->image_channels (engine, id, rch, 4, &rc) == GLIMS_STATUS_OK && rc == 4,
             "reopened XCF preserves four channels");
      for (int i = 0; i < 4; i++)
        {
          snprintf (label, sizeof label, "reopened channel %d named %s", i, expected_names[i]);
          CHECK (strcmp (rch[i].name, expected_names[i]) == 0, label);
        }
      uint8_t reopened_pixels[BYTES];
      render_all (api, engine, id, reopened_pixels);
      CHECK (bytes_equal (reopened_pixels, rendered, BYTES), "reopened XCF preserves pixels");
      CHECK (api->image_close (engine, id) == GLIMS_STATUS_OK, "close reopened image succeeds");
    }
}

int
main (int argc, char **argv)
{
  if (argc != 3)
    {
      fprintf (stderr, "usage: %s <work-dir> <cmyk-profile.icc>\n", argv[0]);
      return 2;
    }
  const char *work_dir = argv[1];
  const char *profile_path = argv[2];

  uint8_t *icc = NULL; size_t icc_len = 0;
  if (!read_file (profile_path, &icc, &icc_len))
    {
      fprintf (stderr, "could not read CMYK profile: %s\n", profile_path);
      return 2;
    }

  /* Independent LCMS oracle: source = Generic CMYK profile, dest = sRGB.
   * TYPE_CMYK_DBL percent coverage -> TYPE_RGB_DBL sRGB, relative colorimetric + BPC. */
  cmsHPROFILE src_profile = cmsOpenProfileFromMem (icc, (cmsUInt32Number) icc_len);
  cmsHPROFILE dst_profile = cmsCreate_sRGBProfile ();
  if (!src_profile || !dst_profile)
    {
      fprintf (stderr, "failed to create LCMS profiles\n");
      return 2;
    }
  cmsHTRANSFORM xform = cmsCreateTransform (src_profile, TYPE_CMYK_DBL,
                                            dst_profile, TYPE_RGB_DBL,
                                            INTENT_RELATIVE_COLORIMETRIC,
                                            cmsFLAGS_BLACKPOINTCOMPENSATION | cmsFLAGS_NOCACHE);
  if (!xform)
    {
      fprintf (stderr, "failed to create LCMS transform\n");
      return 2;
    }

  /* Generated sRGB ICC for non-CMYK refusal (never copy vendor data into source). */
  size_t srgb_len = 0;
  uint8_t *srgb_icc = make_srgb_icc (&srgb_len);
  if (!srgb_icc)
    {
      fprintf (stderr, "failed to generate sRGB ICC\n");
      return 2;
    }

  const GlimsEngineAPI *api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof (GlimsEngineAPI, image_new_cmyk) + sizeof api->image_new_cmyk ||
      !api->image_new_cmyk)
    { fprintf (stderr, "adapter lacks the CMYK document factory slot\n"); return 2; }

  char user_dir[1024], cache_dir[1024];
  snprintf (user_dir, sizeof user_dir, "%s/user", work_dir);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", work_dir);
  GlimsEngineConfig config = {0};
  config.struct_size = sizeof (config);
  config.user_directory = user_dir;
  config.cache_directory = cache_dir;
  GlimsEngine *engine = NULL;
  char *error = NULL;
  GlimsStatus st = api->start (&config, &engine, &error);
  if (st != GLIMS_STATUS_OK || !engine)
    {
      fprintf (stderr, "engine start failed: %s\n", error ? error : "(no message)");
      api->free_string (error);
      return 2;
    }
  api->free_string (error); error = NULL;

  /* Invalid/missing/non-CMYK ICC refuses with output id reset to 0. */
  {
    GlimsImageID bad = 99;
    st = api->image_new_cmyk (engine, W, H, GLIMS_COLOR_COMPONENT_U8, NULL, icc_len, &bad, &error);
    CHECK (st != GLIMS_STATUS_OK && bad == 0, "missing ICC refuses and resets output id to 0");
    api->free_string (error); error = NULL;

    bad = 99;
    st = api->image_new_cmyk (engine, W, H, GLIMS_COLOR_COMPONENT_U8, icc, 0, &bad, &error);
    CHECK (st != GLIMS_STATUS_OK && bad == 0, "invalid (empty) ICC refuses and resets output id to 0");
    api->free_string (error); error = NULL;

    const uint8_t malformed_icc[128] = {0};
    bad = 99;
    st = api->image_new_cmyk (engine, W, H, GLIMS_COLOR_COMPONENT_U8, malformed_icc, sizeof malformed_icc, &bad, &error);
    CHECK (st != GLIMS_STATUS_OK && bad == 0, "malformed nonempty ICC refuses and resets output id to 0");
    api->free_string (error); error = NULL;

    bad = 99;
    st = api->image_new_cmyk (engine, W, H, GLIMS_COLOR_COMPONENT_U8, srgb_icc, srgb_len, &bad, &error);
    CHECK (st != GLIMS_STATUS_OK && bad == 0, "non-CMYK ICC refuses and resets output id to 0");
    api->free_string (error); error = NULL;
  }

  run_case (api, engine, GLIMS_COLOR_COMPONENT_U8, "U8", icc, icc_len, xform, work_dir);
  run_case (api, engine, GLIMS_COLOR_COMPONENT_U16, "U16", icc, icc_len, xform, work_dir);
  run_case (api, engine, GLIMS_COLOR_COMPONENT_FLOAT, "FLOAT", icc, icc_len, xform, work_dir);

  api->stop (engine);
  cmsDeleteTransform (xform);
  cmsCloseProfile (src_profile);
  cmsCloseProfile (dst_profile);
  free (icc);
  free (srgb_icc);

  printf ("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}

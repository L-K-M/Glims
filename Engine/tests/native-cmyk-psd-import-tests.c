/* Proves native CMYK PSD exported by slot 182 opens through the unmodified
 * pinned GIMP PSD loader with correct dimensions and RGB appearance.
 * RGB appearance interoperability only: the loader converts CMYK to RGB, so
 * this does not duplicate/relabel the exact-plane numeric writer oracle.
 * Expected RGB is computed independently with LittleCMS double CMYK coverage
 * percentages from known seeded raw integer intensities (0=full ink, 1=paper),
 * transformed to the imported document's effective RGB ICC. */
#include "engine-private.h"
#include "glims_engine.h"
#include "plate-storage.h"

#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"

#include <lcms2.h>
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static unsigned checks, failures;

#define CHECK(c, msg) do { \
  int _ok = !!(c); checks++; \
  printf("%s %s\n", _ok ? "ok" : "FAIL", (msg)); \
  if (!_ok) failures++; fflush(stdout); \
} while (0)

#define LOGF(fmt, ...) do { printf("INFO " fmt "\n", __VA_ARGS__); fflush(stdout); } while (0)

typedef struct {
  GlimsImageID id;
  int width, height;
  uint32_t component;
  uint8_t *planes[4];
  size_t plane_bytes;
  size_t pixel_bytes;
} Seed;

typedef struct {
  GlimsImageID id;
  uint8_t *icc;
  uint32_t icc_len;
} ProfileCapture;

static uint8_t clamp_u8(double v) {
  long r;
  if (!isfinite(v)) v = 0.0;
  if (v < 0.0) v = 0.0;
  if (v > 1.0) v = 1.0;
  r = lrint(v * 255.0);
  if (r < 0) r = 0;
  if (r > 255) r = 255;
  return (uint8_t)r;
}

static size_t bpp_for(uint32_t component) {
  if (component == GLIMS_COLOR_COMPONENT_U8) return 1;
  if (component == GLIMS_COLOR_COMPONENT_U16) return 2;
  return 4;
}

static double intensity_from_raw(const uint8_t *plane, size_t idx, uint32_t component) {
  if (component == GLIMS_COLOR_COMPONENT_U8) return plane[idx] / 255.0;
  if (component == GLIMS_COLOR_COMPONENT_U16) {
    uint16_t v = 0;
    memcpy(&v, plane + idx * 2, 2);
    return v / 65535.0;
  }
  {
    float f = 0.0f;
    memcpy(&f, plane + idx * 4, 4);
    if (!isfinite((double)f)) return 0.0;
    if (f < 0.0f) return 0.0;
    if (f > 1.0f) return 1.0;
    return (double)f;
  }
}

static void fill_seed_plane(uint8_t *buf, int width, int height, int c, uint32_t component) {
  int x, y, i;
  int xs[8] = {0, 1, 2, 3, 4, 5, 31, 16};
  int ys[8] = {0, 0, 1, 1, 2, 2, 23, 12};
  static const uint8_t u8_pat[8][4] = {
    {0, 0, 0, 0}, {255, 255, 255, 255}, {255, 0, 0, 0}, {0, 255, 0, 0},
    {0, 0, 255, 0}, {0, 0, 0, 255}, {51, 102, 153, 204}, {200, 20, 180, 40}
  };
  static const uint16_t u16_pat[8][4] = {
    {0, 0, 0, 0}, {65535, 65535, 65535, 65535}, {65535, 0, 0, 0}, {0, 65535, 0, 0},
    {0, 0, 65535, 0}, {0, 0, 0, 65535}, {13107, 26214, 39321, 52428}, {51400, 5140, 46260, 10280}
  };
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++) {
      size_t idx = (size_t)y * (size_t)width + (size_t)x;
      uint32_t v = (uint32_t)(x * 131u + y * 977u + c * 4099u + 17u);
      if (component == GLIMS_COLOR_COMPONENT_U8) {
        buf[idx] = (uint8_t)(v & 0xffu);
      } else if (component == GLIMS_COLOR_COMPONENT_U16) {
        uint16_t u = (uint16_t)((v * 97u + c * 17u) & 0xffffu);
        memcpy(buf + idx * 2, &u, 2);
      } else {
        float f = (float)((v % 1024u) / 1023.0f);
        memcpy(buf + idx * 4, &f, 4);
      }
    }
  }
  for (i = 0; i < 8; i++) {
    size_t idx = (size_t)ys[i] * (size_t)width + (size_t)xs[i];
    if (component == GLIMS_COLOR_COMPONENT_U8) {
      buf[idx] = u8_pat[i][c];
    } else {
      uint16_t u = u16_pat[i][c];
      memcpy(buf + idx * 2, &u, 2);
    }
  }
}

static GlimsStatus seed_native(GlimsEngine *engine, gpointer data) {
  Seed *seed = (Seed *)data;
  GlimsOpenImage *open = glims_lookup_image(engine, seed->id);
  GlimsPlateStorage storage;
  guint c;
  if (!open || !glims_plate_storage_read_open(open, &storage)) return GLIMS_STATUS_FAILED;
  if (storage.map.count != 4 || storage.map.mode != GLIMS_PLATE_MODE_CMYK)
    return GLIMS_STATUS_FAILED;
  for (c = 0; c < 4; c++)
    if (!storage.visible[c]) return GLIMS_STATUS_FAILED;
  for (c = 0; c < 4; c++) {
    GimpDrawable *drawable = GIMP_DRAWABLE(storage.planes[c]);
    gegl_buffer_set(gimp_drawable_get_buffer(drawable),
                    GEGL_RECTANGLE(0, 0, seed->width, seed->height), 0,
                    gimp_drawable_get_format(drawable), seed->planes[c],
                    GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(drawable, 0, 0, seed->width, seed->height);
  }
  return GLIMS_STATUS_OK;
}

static GlimsStatus capture_rgb_profile(GlimsEngine *engine, gpointer data) {
  ProfileCapture *cap = (ProfileCapture *)data;
  GlimsOpenImage *open = glims_lookup_image(engine, cap->id);
  const guint8 *icc = NULL;
  GimpColorProfile *profile;
  gsize len = 0;
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  /* The image's embedded profile may be absent. The color-managed getter
   * returns its actual effective profile, including GIMP's built-in sRGB. */
  profile = gimp_color_managed_get_color_profile(GIMP_COLOR_MANAGED(open->image));
  if (!profile || !gimp_color_profile_is_rgb(profile)) return GLIMS_STATUS_FAILED;
  icc = gimp_color_profile_get_icc_profile(profile, &len);
  if (icc && len > 0 && len <= 16u * 1024u * 1024u) {
    cap->icc = (uint8_t *)g_memdup2(icc, len);
    cap->icc_len = (uint32_t)len;
    return cap->icc ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
  }
  return GLIMS_STATUS_FAILED;
}

static bool read_file_all(const char *path, uint8_t **bytes, size_t *len) {
  FILE *f;
  long sz;
  *bytes = NULL; *len = 0;
  f = fopen(path, "rb");
  if (!f) return false;
  if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return false; }
  sz = ftell(f);
  if (sz < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return false; }
  *len = (size_t)sz;
  *bytes = (uint8_t *)malloc(*len ? *len : 1);
  if (!*bytes) { fclose(f); *len = 0; return false; }
  if (*len && fread(*bytes, 1, *len, f) != *len) {
    free(*bytes); *bytes = NULL; *len = 0; fclose(f); return false;
  }
  fclose(f);
  return true;
}

static void run_case(GlimsEngine *engine, uint32_t component, const char *cname,
                     const uint8_t *cmyk_icc, size_t cmyk_icc_len,
                     const char *work_dir) {
  char label[512], psd_path[1024];
  char *error = NULL;
  Seed seed = {0};
  GlimsStatus st;
  GlimsImageID opened = 0;
  GlimsImageInfo info = {0};
  GlimsColorInfo cinfo = {0};
  ProfileCapture pc = {0};
  size_t pxcount;
  uint8_t *rendered = NULL;
  int c;

  seed.width = 32; seed.height = 24; seed.component = component;
  seed.pixel_bytes = bpp_for(component);
  seed.plane_bytes = (size_t)seed.width * (size_t)seed.height * seed.pixel_bytes;

  snprintf(label, sizeof label, "%s: create native CMYK source", cname);
  st = api->image_new_cmyk(engine, seed.width, seed.height, component,
                           cmyk_icc, cmyk_icc_len, &seed.id, &error);
  CHECK(st == GLIMS_STATUS_OK && seed.id != 0, label);
  api->free_string(error); error = NULL;
  if (st != GLIMS_STATUS_OK || !seed.id) return;

  for (c = 0; c < 4; c++) {
    seed.planes[c] = (uint8_t *)malloc(seed.plane_bytes);
    if (!seed.planes[c]) { CHECK(false, "seed plane allocation"); goto cleanup; }
    fill_seed_plane(seed.planes[c], seed.width, seed.height, c, component);
  }
  st = glims_engine_call(engine, seed_native, &seed);
  snprintf(label, sizeof label, "%s: seed raw CMYK planes on engine thread", cname);
  CHECK(st == GLIMS_STATUS_OK, label);
  if (st != GLIMS_STATUS_OK) goto cleanup;

  snprintf(psd_path, sizeof psd_path, "%s/native-cmyk-%s.psd", work_dir, cname);
  st = api->image_export_native_cmyk_psd(engine, seed.id, psd_path, &error);
  snprintf(label, sizeof label, "%s: native CMYK PSD export succeeds", cname);
  CHECK(st == GLIMS_STATUS_OK, label);
  if (error) { printf("INFO %s export: %s\n", cname, error); fflush(stdout); }
  api->free_string(error); error = NULL;
  if (st != GLIMS_STATUS_OK) goto cleanup;

  snprintf(label, sizeof label, "%s: close source image", cname);
  CHECK(api->image_close(engine, seed.id) == GLIMS_STATUS_OK, label);
  seed.id = 0;

  st = api->image_open(engine, psd_path, &opened, &error);
  snprintf(label, sizeof label, "%s: unmodified pinned PSD loader opens exported PSD", cname);
  CHECK(st == GLIMS_STATUS_OK && opened != 0, label);
  if (error) { printf("INFO %s open: %s\n", cname, error); fflush(stdout); }
  api->free_string(error); error = NULL;
  if (st != GLIMS_STATUS_OK || !opened) goto cleanup;

  snprintf(label, sizeof label, "%s: imported image_info", cname);
  CHECK(api->image_info(engine, opened, &info) == GLIMS_STATUS_OK, label);
  snprintf(label, sizeof label, "%s: imported dimensions %dx%d", cname, info.width, info.height);
  CHECK(info.width == seed.width && info.height == seed.height, label);
  snprintf(label, sizeof label, "%s: PSD loader produces one float non-linear RGB layer", cname);
  CHECK(info.layer_count == 1 && strcmp(info.precision, "float-non-linear") == 0, label);
  LOGF("%s imported precision=%s dirty=%d layers=%d", cname, info.precision, info.dirty, info.layer_count);

  snprintf(label, sizeof label, "%s: imported color info", cname);
  CHECK(api->image_color_info(engine, opened, &cinfo) == GLIMS_STATUS_OK, label);
  snprintf(label, sizeof label, "%s: imported mode is RGB (loader conversion)", cname);
  CHECK(cinfo.mode == GLIMS_COLOR_MODE_RGB, label);
  snprintf(label, sizeof label, "%s: imported image reports RGB profile label", cname);
  CHECK(cinfo.profile_label[0] != '\0', label);
  LOGF("%s imported color mode=%u component=%u embedded=%d label=%s", cname,
       cinfo.mode, cinfo.component, cinfo.profile_embedded, cinfo.profile_label);

  pc.id = opened;
  st = glims_engine_call(engine, capture_rgb_profile, &pc);
  snprintf(label, sizeof label, "%s: capture actual effective RGB document ICC", cname);
  CHECK(st == GLIMS_STATUS_OK && pc.icc && pc.icc_len > 0, label);

  pxcount = (size_t)seed.width * (size_t)seed.height;
  rendered = (uint8_t *)calloc(pxcount, 4);
  CHECK(rendered != NULL, (snprintf(label,sizeof label,"%s: allocate render buffer",cname),label));
  if (!rendered) goto cleanup;

  st = api->image_render(engine, opened, 1.0, (GlimsRect){0, 0, seed.width, seed.height},
                         rendered, (size_t)seed.width * 4);
  snprintf(label, sizeof label, "%s: render imported composite", cname);
  CHECK(st == GLIMS_STATUS_OK, label);
  if (st == GLIMS_STATUS_OK) {
    size_t i;
    bool opaque = true;
    for (i = 0; i < pxcount; i++) {
      if (rendered[i * 4 + 3] != 255) { opaque = false; break; }
    }
    snprintf(label, sizeof label, "%s: imported RGB composite alpha is opaque", cname);
    CHECK(opaque, label);
  }

  if (st == GLIMS_STATUS_OK && pc.icc) {
    cmsHPROFILE src = cmsOpenProfileFromMem(cmyk_icc, (cmsUInt32Number)cmyk_icc_len);
    cmsHPROFILE dst = cmsOpenProfileFromMem(pc.icc, (cmsUInt32Number)pc.icc_len);
    cmsHPROFILE render_space = cmsCreate_sRGBProfile();
    if (!src || !dst || !render_space || cmsGetColorSpace(src) != cmsSigCmykData ||
        cmsGetColorSpace(dst) != cmsSigRgbData) {
      snprintf(label, sizeof label, "%s: open LCMS profiles for oracle", cname);
      CHECK(false, label);
    } else {
      cmsHTRANSFORM xform = cmsCreateTransform(src, TYPE_CMYK_DBL, dst, TYPE_RGB_DBL,
                                               INTENT_RELATIVE_COLORIMETRIC,
                                               cmsFLAGS_BLACKPOINTCOMPENSATION | cmsFLAGS_NOCACHE);
      /* image_render returns sRGB bytes, not document-space bytes. Keep this
       * conversion explicit even when the effective document is also sRGB. */
      cmsHTRANSFORM to_render = cmsCreateTransform(dst, TYPE_RGB_DBL, render_space, TYPE_RGB_DBL,
                                                  INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOCACHE);
      snprintf(label, sizeof label, "%s: create independent LCMS oracle (RelCol+BPC, source ICC -> actual document ICC -> sRGB render)", cname);
      CHECK(xform != NULL && to_render != NULL, label);
      if (xform && to_render) {
        bool finite = true;
        int max_err = 0;
        int worst = -1, worst_x = -1, worst_y = -1, worst_ch = 0;
        int got_r = 0, got_g = 0, got_b = 0, exp_r = 0, exp_g = 0, exp_b = 0;
        double worst_c = 0, worst_m = 0, worst_yi = 0, worst_k = 0;
        size_t i;
        for (i = 0; i < pxcount; i++) {
          double ci = intensity_from_raw(seed.planes[0], i, component);
          double mi = intensity_from_raw(seed.planes[1], i, component);
          double yi = intensity_from_raw(seed.planes[2], i, component);
          double ki = intensity_from_raw(seed.planes[3], i, component);
          double cmyk[4];
          double document_rgb[3];
          double rgb[3];
          uint8_t er, eg, eb, gr, gg, gb;
          int dr, dg, db, pixel_max;
          cmyk[0] = (1.0 - ci) * 100.0; cmyk[1] = (1.0 - mi) * 100.0;
          cmyk[2] = (1.0 - yi) * 100.0; cmyk[3] = (1.0 - ki) * 100.0;
          cmsDoTransform(xform, cmyk, document_rgb, 1);
          for (int ch = 0; ch < 3; ch++) {
            if (!isfinite(document_rgb[ch])) finite = false;
            /* CMYK imports are stored as float-non-linear RGB. */
            document_rgb[ch] = (double)(float)document_rgb[ch];
          }
          cmsDoTransform(to_render, document_rgb, rgb, 1);
          for (int ch = 0; ch < 3; ch++)
            if (!isfinite(rgb[ch])) finite = false;
          er = clamp_u8(rgb[0]); eg = clamp_u8(rgb[1]); eb = clamp_u8(rgb[2]);
          gr = rendered[i * 4 + 0]; gg = rendered[i * 4 + 1]; gb = rendered[i * 4 + 2];
          dr = abs((int)gr - (int)er); dg = abs((int)gg - (int)eg); db = abs((int)gb - (int)eb);
          pixel_max = dr; if (dg > pixel_max) pixel_max = dg; if (db > pixel_max) pixel_max = db;
          if (pixel_max > max_err) {
            max_err = pixel_max; worst = (int)i;
            worst_x = (int)(i % (size_t)seed.width); worst_y = (int)(i / (size_t)seed.width);
            worst_ch = (dr >= dg && dr >= db) ? 0 : ((dg >= db) ? 1 : 2);
            got_r = gr; got_g = gg; got_b = gb; exp_r = er; exp_g = eg; exp_b = eb;
            worst_c = ci; worst_m = mi; worst_yi = yi; worst_k = ki;
          }
        }
        if (worst >= 0) {
          LOGF("%s max_err=%d worst_pixel=%d(x=%d,y=%d,ch=%d) got=(%d,%d,%d) expected=(%d,%d,%d) intensities_CMYK=(%.9g,%.9g,%.9g,%.9g)",
               cname, max_err, worst, worst_x, worst_y, worst_ch,
               got_r, got_g, got_b, exp_r, exp_g, exp_b,
               worst_c, worst_m, worst_yi, worst_k);
        } else {
          LOGF("%s max_err=%d", cname, max_err);
        }
        snprintf(label, sizeof label,
                 "%s: all independent oracle values are finite", cname);
        CHECK(finite, label);
        snprintf(label, sizeof label,
                 "%s: imported RGB appearance matches independent LCMS oracle within 2 byte levels (RelCol+BPC, effective ICC=%s, rendered sRGB)",
                 cname, cinfo.profile_label);
        CHECK(max_err <= 2, label);
      }
      if (xform) cmsDeleteTransform(xform);
      if (to_render) cmsDeleteTransform(to_render);
    }
    if (src) cmsCloseProfile(src);
    if (dst) cmsCloseProfile(dst);
    if (render_space) cmsCloseProfile(render_space);
  } else {
    snprintf(label, sizeof label, "%s: oracle comparison prerequisites unavailable", cname);
    CHECK(false, label);
  }

cleanup:
  g_free(pc.icc);
  free(rendered);
  if (opened) {
    snprintf(label, sizeof label, "%s: close imported image", cname);
    CHECK(api->image_close(engine, opened) == GLIMS_STATUS_OK, label);
  }
  if (seed.id) CHECK(api->image_close(engine, seed.id) == GLIMS_STATUS_OK, "cleanup source image");
  for (c = 0; c < 4; c++) free(seed.planes[c]);
}

int main(int argc, char **argv) {
  const char *work_dir;
  const char *profile_path;
  uint8_t *icc = NULL;
  size_t icc_len = 0;
  char user_dir[1024], cache_dir[1024];
  GlimsEngineConfig config = {0};
  GlimsEngine *engine = NULL;
  char *error = NULL;
  GlimsStatus st;

  if (argc != 3) {
    fprintf(stderr, "usage: %s <work-dir> <cmyk-profile.icc>\n", argv[0]);
    return 2;
  }
  work_dir = argv[1];
  profile_path = argv[2];
  if (!read_file_all(profile_path, &icc, &icc_len)) {
    fprintf(stderr, "FAIL could not read CMYK profile: %s (%s)\n", profile_path, strerror(errno));
    return 2;
  }

  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_export_native_cmyk_psd) + sizeof api->image_export_native_cmyk_psd ||
      !api->image_new_cmyk || !api->image_export_native_cmyk_psd || !api->image_open || !api->image_render) {
    fprintf(stderr, "FAIL adapter lacks required slots (181/182/open/render)\n");
    free(icc);
    return 2;
  }

  snprintf(user_dir, sizeof user_dir, "%s/user", work_dir);
  snprintf(cache_dir, sizeof cache_dir, "%s/cache", work_dir);
  config.struct_size = sizeof config;
  config.user_directory = user_dir;
  config.cache_directory = cache_dir;
  st = api->start(&config, &engine, &error);
  if (st != GLIMS_STATUS_OK || !engine) {
    fprintf(stderr, "FAIL engine start: %s\n", error ? error : "(null)");
    api->free_string(error);
    free(icc);
    return 2;
  }
  api->free_string(error); error = NULL;

  run_case(engine, GLIMS_COLOR_COMPONENT_U8, "U8", icc, icc_len, work_dir);
  run_case(engine, GLIMS_COLOR_COMPONENT_U16, "U16", icc, icc_len, work_dir);

  api->stop(engine);
  free(icc);
  LOGF("checks=%u failures=%u", checks, failures);
  return failures ? 1 : 0;
}

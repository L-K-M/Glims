/* Facade-only CMYK PSD checks. The optional external ICC is read in place;
 * no vendor profile is copied into the repository. LittleCMS is an independent
 * RGB-to-CMYK oracle; a small bounded decoder reads the exported PSD planes. */
#include "glims_engine.h"
#include <lcms2.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int checks, failures;
#define CHECK(c, label) do { int ok_ = !!(c); checks++; failures += !ok_; printf("%s %s\n", ok_ ? "ok" : "FAIL", label); fflush(stdout); } while (0)
#define NEED(c) do { if (!(c)) { fprintf(stderr, "fixture failure at line %d\n", __LINE__); exit(2); } } while (0)
static unsigned be16(const unsigned char *p) { return (unsigned)p[0] << 8 | p[1]; }
static unsigned be32(const unsigned char *p) { return (unsigned)p[0] << 24 | (unsigned)p[1] << 16 | (unsigned)p[2] << 8 | p[3]; }
static unsigned char *read_file(const char *path, size_t *length) {
  FILE *f = fopen(path, "rb"); if (!f) return NULL;
  NEED(!fseek(f, 0, SEEK_END)); long n = ftell(f); NEED(n >= 0 && n <= 64 * 1024 * 1024);
  rewind(f); unsigned char *p = malloc((size_t)n + 1); NEED(p);
  NEED(fread(p, 1, (size_t)n, f) == (size_t)n); fclose(f); *length = (size_t)n; return p;
}
static GlimsExportSettings settings(unsigned layout) {
  return (GlimsExportSettings){ .struct_size = sizeof(GlimsExportSettings), .format = GLIMS_EXPORT_PSD,
    .jpeg_quality = .9, .jpeg_progressive = 1, .jpeg_optimize = 1, .png_compression = 9,
    .tiff_preserve_transparent_color = 1, .psd_layout = layout };
}
/* Tiny fixture parser, not a general-purpose untrusted-file reader. Every
 * count is checked against this test's fixed 8x6 dimensions before allocation. */
static void inspect(const char *path, const unsigned char *icc, size_t icc_length,
                    const unsigned char *expected, int depth) {
  size_t size = 0; unsigned char *bytes = read_file(path, &size); NEED(bytes && size > 40);
  CHECK(!memcmp(bytes, "8BPS", 4) && be16(bytes + 4) == 1 && be16(bytes + 24) == 4,
        "exported file declares PSD CMYK, not RGB fallback");
  NEED(be32(bytes + 14) == 6 && be32(bytes + 18) == 8);
  CHECK(be16(bytes + 22) == (unsigned)depth, "CMYK output has the promised 8/16-bit precision");
  unsigned channels = be16(bytes + 12); NEED(channels == 4 || channels == 5);
  size_t pos = 26, n = be32(bytes + pos); pos += 4; NEED(n <= size - pos); pos += n;
  NEED(size - pos >= 4); n = be32(bytes + pos); pos += 4; NEED(n <= size - pos);
  size_t end = pos + n; int found = 0;
  while (pos < end) {
    NEED(end - pos >= 7 && !memcmp(bytes + pos, "8BIM", 4)); unsigned id = be16(bytes + pos + 4); pos += 6;
    n = 1 + bytes[pos]; n += n % 2; NEED(n <= end - pos); pos += n;
    NEED(end - pos >= 4); n = be32(bytes + pos); pos += 4; NEED(n <= end - pos);
    if (id == 1039) { found++; CHECK(n == icc_length && !memcmp(bytes + pos, icc, n), "PSD embeds exactly the requested CMYK ICC profile"); }
    pos += n; if (n % 2) { NEED(pos < end); pos++; }
  }
  CHECK(found == 1, "one CMYK profile resource is present");
  NEED(size - pos >= 4); n = be32(bytes + pos); pos += 4; NEED(n <= size - pos); pos += n;
  NEED(size - pos >= 2); unsigned compression = be16(bytes + pos); pos += 2;
  NEED(compression == 0 || compression == 1);
  size_t row_bytes = 8 * (size_t)depth / 8, rows = channels * 6;
  unsigned char plane[5 * 6 * 16] = {0};
  if (compression == 0) { NEED(rows * row_bytes <= size - pos); memcpy(plane, bytes + pos, rows * row_bytes); }
  else {
    NEED(rows * 2 <= size - pos); size_t lengths = pos; pos += rows * 2;
    for (size_t row = 0; row < rows; row++) {
      size_t encoded = be16(bytes + lengths + row * 2); NEED(encoded <= size - pos);
      size_t stop = pos + encoded, output = row * row_bytes, limit = output + row_bytes;
      while (pos < stop) {
        int control = (signed char)bytes[pos++];
        if (control >= 0) { size_t count = (size_t)control + 1; NEED(count <= stop - pos && count <= limit - output); memcpy(plane + output, bytes + pos, count); pos += count; output += count; }
        else if (control != -128) { size_t count = (size_t)(1 - control); NEED(pos < stop && count <= limit - output); memset(plane + output, bytes[pos++], count); output += count; }
      }
      NEED(output == limit);
    }
  }
  if (expected && depth == 8) {
    int maximum = 0;
    for (size_t i = 0; i < 48; i++) for (size_t channel = 0; channel < 4; channel++) {
      int delta = abs((255 - plane[channel * 48 + i]) - expected[i * 4 + channel]);
      if (delta > maximum) maximum = delta;
    }
    printf("independent CMYK maximum byte difference: %d\n", maximum);
    CHECK(maximum <= 2, "PSD CMYK planes agree with independent LittleCMS conversion within two byte levels");
  }
  free(bytes);
}
static void roundtrip(GlimsImageID image, const char *path, const unsigned char *icc, size_t length,
                      unsigned layout, const unsigned char *expected, int depth) {
  GlimsExportSettings s = settings(layout); GlimsPixelBuffer before = {0}, after = {0};
  GlimsUndoInfo u0 = {0}, u1 = {0}; GlimsImageInfo i0 = {0}, i1 = {0};
  GlimsLayerInfo layers0[8] = {0}, layers1[8] = {0}; int32_t count0 = 0, count1 = 0;
  NEED(api->image_layers(engine, image, layers0, 8, &count0) == GLIMS_STATUS_OK);
  NEED(api->image_copy_pixels(engine, image, true, &before, NULL) == GLIMS_STATUS_OK);
  NEED(api->image_undo_info(engine, image, &u0) == GLIMS_STATUS_OK);
  NEED(api->image_info(engine, image, &i0) == GLIMS_STATUS_OK);
  int major = 0, minor = 0; sscanf(api->engine_version(engine), "%d.%d", &major, &minor);
  int refused_writer = major == 3 && minor == 3;
  if (refused_writer) { FILE *f = fopen(path, "wb"); NEED(f); NEED(fwrite("keep",1,4,f)==4); fclose(f); }
  char *error = NULL; GlimsStatus status = api->image_export_psd_cmyk(engine, image, path, &s, icc, length, &error);
  if (error) { printf("export: %s\n", error); api->free_string(error); }
  if (refused_writer) {
    CHECK(status == GLIMS_STATUS_UNSUPPORTED, "development writer refuses its reproduced corrupt CMYK composite");
    size_t kept_length = 0; unsigned char *kept = read_file(path, &kept_length);
    CHECK(kept && kept_length == 4 && !memcmp(kept,"keep",4), "development writer refusal preserves existing output"); free(kept);
  } else CHECK(status == GLIMS_STATUS_OK, "explicit CMYK export succeeds");
  if (status == GLIMS_STATUS_OK) {
    inspect(path, icc, length, expected, depth);
    GlimsImageID reopened = 0; NEED(api->image_open(engine, path, &reopened, NULL) == GLIMS_STATUS_OK);
    GlimsImageInfo info = {0}; NEED(api->image_info(engine, reopened, &info) == GLIMS_STATUS_OK);
    CHECK(info.width == 8 && info.height == 6 && info.layer_count == (layout == GLIMS_PSD_MERGED ? 1 : count0), "native loader reads the selected layered or merged CMYK PSD structure");
    NEED(api->image_close(engine, reopened) == GLIMS_STATUS_OK);
  }
  NEED(api->image_copy_pixels(engine, image, true, &after, NULL) == GLIMS_STATUS_OK);
  NEED(api->image_undo_info(engine, image, &u1) == GLIMS_STATUS_OK);
  NEED(api->image_info(engine, image, &i1) == GLIMS_STATUS_OK);
  CHECK(before.byte_count == after.byte_count && !memcmp(before.pixels, after.pixels, before.byte_count), "CMYK conversion leaves original RGB pixels unchanged");
  CHECK(i0.dirty == i1.dirty && !strcmp(i0.precision, i1.precision) && u0.undo_count == u1.undo_count && u0.redo_count == u1.redo_count, "CMYK output leaves source precision, dirty state and Undo/Redo unchanged");
  NEED(api->image_layers(engine, image, layers1, 8, &count1) == GLIMS_STATUS_OK);
  CHECK(count0 == count1 && !memcmp(layers0, layers1, sizeof layers0), "CMYK export preserves source layer identities, selection and structure");
  api->free_pixels(before.pixels); api->free_pixels(after.pixels);
}
int main(int argc, char **argv) {
  if (argc != 4) { fprintf(stderr, "usage: psd-cmyk-tests ADAPTER PRIVATE_WORK CMYK_ICC\n"); return 2; }
  size_t length = 0; unsigned char *icc = read_file(argv[3], &length); NEED(icc && length <= 4 * 1024 * 1024);
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); if (!library) { fprintf(stderr, "%s\n", dlerror()); return 2; }
  GlimsEngineGetAPIFunction get = (GlimsEngineGetAPIFunction)dlsym(library, "glims_engine_get_api");
  api = get ? get(GLIMS_ENGINE_API_VERSION) : NULL; NEED(api && api->struct_size >= sizeof *api);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = argv[2], .cache_directory = argv[2]};
  NEED(api->start(&config, &engine, NULL) == GLIMS_STATUS_OK);
  unsigned char rgba[48 * 4], expected[48 * 4];
  for (int i = 0; i < 48; i++) { rgba[4*i] = (unsigned char)(20 + 30*(i%8)); rgba[4*i+1] = (unsigned char)(35 + 35*(i%6)); rgba[4*i+2] = (unsigned char)(210 - 20*(i%8)); rgba[4*i+3] = 255; }
  GlimsImageID image = 0; NEED(api->image_from_pixels(engine, 8, 6, rgba, sizeof rgba, &image, NULL) == GLIMS_STATUS_OK);
  unsigned char overlay[4 * 3 * 4];
  for (int i = 0; i < 12; i++) { overlay[i*4]=36; overlay[i*4+1]=160; overlay[i*4+2]=92; overlay[i*4+3]=255; }
  GlimsItemID top = 0;
  NEED(api->image_paste_pixels(engine, image, (GlimsRect){2,1,4,3}, overlay, sizeof overlay, &top, NULL) == GLIMS_STATUS_OK);
  for (int y = 1; y < 4; y++) for (int x = 2; x < 6; x++) memcpy(rgba + (y * 8 + x) * 4, overlay, 4);
  cmsHPROFILE source = cmsCreate_sRGBProfile(), destination = cmsOpenProfileFromMem(icc, (cmsUInt32Number)length); NEED(source && destination);
  char path[4096];
  cmsHTRANSFORM transform = cmsCreateTransform(source, TYPE_RGBA_8, destination, TYPE_CMYK_8,
                                                INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_BLACKPOINTCOMPENSATION);
  NEED(transform); cmsDoTransform(transform, rgba, expected, 48); cmsDeleteTransform(transform);
  for (unsigned layout = 0; layout <= 1; layout++) {
    snprintf(path, sizeof path, "%s/cmyk-%u.psd", argv[2], layout);
    roundtrip(image, path, icc, length, layout, expected, 8);
  }
  GlimsExportSettings s = settings(GLIMS_PSD_MERGED);
  snprintf(path, sizeof path, "%s/refused.psd", argv[2]); FILE *sentinel = fopen(path, "wb"); NEED(sentinel); NEED(fwrite("keep",1,4,sentinel)==4); fclose(sentinel);
  CHECK(api->image_export_psd_cmyk(engine, image, path, &s, NULL, length, NULL) == GLIMS_STATUS_INVALID_ARGUMENT, "missing profile refuses without RGB fallback");
  GlimsExportSettings wrong = s; wrong.format = GLIMS_EXPORT_PNG;
  CHECK(api->image_export_psd_cmyk(engine, image, path, &wrong, icc, length, NULL) == GLIMS_STATUS_INVALID_ARGUMENT, "CMYK request cannot silently export another format");
  CHECK(api->image_export_psd_cmyk(engine, image, path, &s, icc, 4 * 1024 * 1024 + 1, NULL) == GLIMS_STATUS_INVALID_ARGUMENT, "oversize profile refuses before reading its bytes");
  CHECK(api->image_export_psd_cmyk(engine, image, path, &s, (const unsigned char *)"broken", 6, NULL) != GLIMS_STATUS_OK, "malformed ICC refuses");
  cmsUInt32Number rgb_length = 0; NEED(cmsSaveProfileToMem(source, NULL, &rgb_length)); unsigned char *rgb = malloc(rgb_length); NEED(rgb && cmsSaveProfileToMem(source, rgb, &rgb_length));
  CHECK(api->image_export_psd_cmyk(engine, image, path, &s, rgb, rgb_length, NULL) != GLIMS_STATUS_OK, "RGB profile cannot stand in for a CMYK profile"); free(rgb);
  size_t kept_length = 0; unsigned char *kept = read_file(path, &kept_length); CHECK(kept && kept_length == 4 && !memcmp(kept,"keep",4), "all profile refusals preserve an existing output"); free(kept);
  NEED(api->image_convert_precision(engine, image, GLIMS_COLOR_COMPONENT_FLOAT, GLIMS_COLOR_TRC_NONLINEAR, NULL) == GLIMS_STATUS_OK);
  snprintf(path, sizeof path, "%s/float.psd", argv[2]); roundtrip(image, path, icc, length, GLIMS_PSD_MERGED, NULL, 16);
  NEED(api->image_close(engine, image) == GLIMS_STATUS_OK); api->stop(engine); cmsCloseProfile(source); cmsCloseProfile(destination); free(icc);
  printf("%d checks; %d failures\n", checks, failures); return failures ? 1 : 0;
}

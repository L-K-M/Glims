#define _POSIX_C_SOURCE 200809L
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(condition, label) do { int ok = !!(condition); checks++; failures += !ok; \
  printf("%s %s\n", ok ? "ok" : "FAIL", label); fflush(stdout); } while (0)

static size_t
read_file(const char *path, unsigned char *data, size_t capacity)
{
  FILE *f = fopen(path, "rb"); if (!f) return 0;
  size_t n = fread(data, 1, capacity, f); int bad = ferror(f) || !feof(f);
  fclose(f); return bad ? 0 : n;
}

static void
clear_error(const GlimsEngineAPI *api, char **error)
{
  if (*error) { fprintf(stderr, "%s\n", *error); api->free_string(*error); *error = NULL; }
}

/* Independent flat PSD envelope using the actual Photoshop-authored block.
 * This also exercises engines that cannot import the fixture's live gradient. */
static int
write_flat(const char *path, const unsigned char *source, size_t block)
{
  static const unsigned char header[26] = {
    '8','B','P','S',0,1, 0,0,0,0,0,0, 0,1, 0,0,0,4, 0,0,0,4, 0,8, 0,8
  };
  static const unsigned char empty_sections[10] = {0};
  static const unsigned char pixels[16] = {0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255};
  FILE *f = fopen(path, "wb"); if (!f) return 0;
  int ok = fwrite(header,1,sizeof header,f)==sizeof header &&
           fwrite(source+26,1,4+block,f)==4+block &&
           fwrite(empty_sections,1,sizeof empty_sections,f)==sizeof empty_sections &&
           fwrite(pixels,1,sizeof pixels,f)==sizeof pixels;
  return fclose(f)==0 && ok;
}

int main(int argc, char **argv)
{
  if (argc != 4) return 2;
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf(stderr, "%s\n", dlerror()); return 2; }
  GlimsEngineGetAPIFunction get = (GlimsEngineGetAPIFunction) dlsym(library, "glims_engine_get_api");
  const GlimsEngineAPI *api = get ? get(GLIMS_ENGINE_API_VERSION) : NULL;
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_export_duotone_psd) + sizeof api->image_export_duotone_psd || !api->image_export_duotone_psd) return 2;
  char user[1024], cache[1024], fixture[1024], flat[1024], out[1024], xcf[1024], no_tag[1024];
  snprintf(user, sizeof user, "%s/user", argv[2]); snprintf(cache, sizeof cache, "%s/cache", argv[2]);
  snprintf(fixture, sizeof fixture, "%s/photoshop-cc2018-duotone.psd", argv[3]);
  snprintf(flat, sizeof flat, "%s/flat-photoshop-settings.psd", argv[2]);
  snprintf(out, sizeof out, "%s/export.psd", argv[2]); snprintf(xcf, sizeof xcf, "%s/reopened.xcf", argv[2]);
  snprintf(no_tag, sizeof no_tag, "%s/plain.pgm", argv[2]);
  unsigned char original[65536], exported[65536];
  size_t original_size = read_file(fixture, original, sizeof original);
  if (original_size < 30) return 2;
  size_t block = ((size_t) original[26] << 24) | ((size_t) original[27] << 16) | ((size_t) original[28] << 8) | original[29];
  if (!block || block > original_size - 30) return 2;
  if (!write_flat(flat, original, block)) return 2;
  FILE *f = fopen(no_tag, "wb"); if (!f) return 2;
  static const unsigned char pgm[] = "P5\n1 1\n255\n\200";
  int wrote = fwrite(pgm, 1, sizeof pgm - 1, f) == sizeof pgm - 1; if (fclose(f) || !wrote) return 2;
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus status = api->start(&config, &engine, &error);
  CHECK(status == GLIMS_STATUS_OK && engine, "engine starts"); clear_error(api, &error);
  if (!engine) return 1;
  GlimsImageID image = 0, reopened = 0, plain = 0;
  status = api->image_open(engine, fixture, &image, &error);
  CHECK(status == GLIMS_STATUS_OK && image, "Photoshop Duotone opens"); clear_error(api, &error);
  if (image) {
    GlimsImageInfo before = {0}, after = {0}; GlimsUndoInfo ub = {0}, ua = {0};
    unsigned char source_pixels[4 * 4 * 4], reopened_pixels[4 * 4 * 4];
    CHECK(api->image_info(engine, image, &before) == GLIMS_STATUS_OK && api->image_undo_info(engine, image, &ub) == GLIMS_STATUS_OK, "capture source state");
    CHECK(api->image_render(engine, image, 1, (GlimsRect){0,0,4,4}, source_pixels, 16) == GLIMS_STATUS_OK, "capture original rendered pixels");
    if (source_pixels[3] != 255) {
      /* Development GIMP currently turns this PSD's Gradient Fill into an
       * empty adjustment group. Never flatten the resulting transparency. */
      CHECK(strncmp(api->engine_version(engine), "3.3", 3) == 0, "only development GIMP exposes the known gradient import limitation");
      status = api->image_export_duotone_psd(engine, image, out, &error);
      CHECK(status != GLIMS_STATUS_OK && error && strstr(error, "opaque"), "incomplete gradient import is refused instead of flattened"); clear_error(api, &error);
      api->image_close(engine, image); image = 0;
      status = api->image_open(engine, flat, &image, &error);
      CHECK(status == GLIMS_STATUS_OK && image, "open flat fixture containing Photoshop's exact Duotone settings"); clear_error(api, &error);
      if (!image) { api->stop(engine); dlclose(library); return 1; }
      CHECK(api->image_info(engine, image, &before) == GLIMS_STATUS_OK && api->image_undo_info(engine, image, &ub) == GLIMS_STATUS_OK &&
            api->image_render(engine, image, 1, (GlimsRect){0,0,4,4}, source_pixels, 16) == GLIMS_STATUS_OK && source_pixels[3] == 255,
            "flat fixture imports as opaque grayscale");
    }
    status = api->image_export_duotone_psd(engine, image, out, &error);
    CHECK(status == GLIMS_STATUS_OK, "export Photoshop-authored Duotone"); clear_error(api, &error);
    size_t exported_size = read_file(out, exported, sizeof exported);
    CHECK(exported_size == 40 + block + 16 && !memcmp(exported, "8BPS", 4) && exported[13] == 1 && exported[23] == 8 && exported[25] == 8 && !memcmp(exported + 26, original + 26, 4 + block), "output is flat 8-bit Duotone and preserves exact Photoshop settings");
    CHECK(api->image_info(engine, image, &after) == GLIMS_STATUS_OK && api->image_undo_info(engine, image, &ua) == GLIMS_STATUS_OK && before.dirty == after.dirty && ub.undo_count == ua.undo_count && ub.redo_count == ua.redo_count, "export does not change source history or dirty state");
    status = api->image_open(engine, out, &reopened, &error);
    CHECK(status == GLIMS_STATUS_OK && reopened, "GIMP reopens exported PSD"); clear_error(api, &error);
    if (reopened) {
      CHECK(api->image_render(engine, reopened, 1, (GlimsRect){0,0,4,4}, reopened_pixels, 16) == GLIMS_STATUS_OK && !memcmp(source_pixels, reopened_pixels, sizeof source_pixels), "exported grayscale pixels render identically");
      api->image_close(engine, reopened); reopened = 0;
    }
    status = api->image_save(engine, image, xcf, &error);
    CHECK(status == GLIMS_STATUS_OK, "save source as XCF"); clear_error(api, &error);
    status = api->image_open(engine, xcf, &reopened, &error);
    CHECK(status == GLIMS_STATUS_OK && reopened, "reopen XCF"); clear_error(api, &error);
    if (reopened) {
      status = api->image_export_duotone_psd(engine, reopened, out, &error);
      size_t n = read_file(out, exported, sizeof exported);
      CHECK(status == GLIMS_STATUS_OK && n >= 30 + block && !memcmp(exported + 26, original + 26, 4 + block), "XCF retains exportable exact Duotone settings"); clear_error(api, &error);
      api->image_close(engine, reopened);
    }
    GlimsItemID link = 0;
    status = api->image_place_link(engine, image, no_tag, &link, &error);
    clear_error(api, &error);
    if (status == GLIMS_STATUS_OK && link) {
      size_t saved = read_file(out, original, sizeof original);
      status = api->image_export_duotone_psd(engine, image, out, &error);
      size_t current = read_file(out, exported, sizeof exported);
      CHECK(status == GLIMS_STATUS_UNSUPPORTED && error && saved == current && !memcmp(original, exported, saved),
            "linked layer refuses without replacing destination"); clear_error(api, &error);
      GlimsLayerChange hidden = { .struct_size=sizeof hidden, .properties=GLIMS_LAYER_VISIBLE, .visible=false };
      CHECK(api->layer_change(engine, image, link, &hidden, &error) == GLIMS_STATUS_OK, "hide linked layer"); clear_error(api, &error);
      status = api->image_export_duotone_psd(engine, image, out, &error);
      current = read_file(out, exported, sizeof exported);
      CHECK(status == GLIMS_STATUS_UNSUPPORTED && error && saved == current && !memcmp(original, exported, saved),
            "hidden linked layer still refuses without replacing destination"); clear_error(api, &error);
      CHECK(api->image_undo(engine, image) == GLIMS_STATUS_OK && api->image_undo(engine, image) == GLIMS_STATUS_OK,
            "undo linked-layer changes");
    } else {
      CHECK(status == GLIMS_STATUS_UNSUPPORTED && !link, "engine without linked layers refuses placement");
    }
    status = api->image_convert_precision(engine, image, GLIMS_COLOR_COMPONENT_U16, GLIMS_COLOR_TRC_NONLINEAR, &error);
    CHECK(status == GLIMS_STATUS_OK, "convert retained document to 16-bit for refusal test"); clear_error(api, &error);
    size_t saved_size = read_file(out, original, sizeof original);
    status = api->image_export_duotone_psd(engine, image, out, &error);
    size_t after_refusal = read_file(out, exported, sizeof exported);
    CHECK(status == GLIMS_STATUS_UNSUPPORTED && error && strstr(error, "8-bit") && saved_size == after_refusal && !memcmp(original, exported, saved_size), "16-bit document refuses without replacing destination"); clear_error(api, &error);
    api->image_close(engine, image);
  }
  status = api->image_open(engine, no_tag, &plain, &error);
  CHECK(status == GLIMS_STATUS_OK && plain, "open grayscale without Duotone settings"); clear_error(api, &error);
  if (plain) {
    size_t before = read_file(out, original, sizeof original);
    status = api->image_export_duotone_psd(engine, plain, out, &error);
    size_t after = read_file(out, exported, sizeof exported);
    CHECK(status == GLIMS_STATUS_UNSUPPORTED && error && before == after && !memcmp(original, exported, before), "missing settings refuse without changing destination"); clear_error(api, &error);
    api->image_close(engine, plain);
  }
  api->stop(engine); dlclose(library);
  printf("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}

/* Independent numeric regression fixture for public native CMYK PSD export
 * (slot 182: api->image_export_native_cmyk_psd). No private PSD codec, no
 * native-cmyk-export implementation, and no color-conversion preview oracle.
 * The PSD is decoded literally here and compared against exact raw plate
 * samples captured after a public Pencil stroke. */
#include "engine-private.h"
#include "glims_engine.h"
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpobject.h"

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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
  GlimsPlateMap map;
  GlimsItemID item_ids[4];
  GlimsChannelInfo channels[4];
  GlimsUndoInfo undo;
  GlimsHistoryInfo history;
  gint dirty;
  GlimsItemID native_order[4], selected_ids[4];
  guint native_count, selected_count;
  GFile *image_file, *imported_file, *exported_file, *save_a_copy_file;
  uint8_t *profile;
  size_t profile_len;
  uint8_t *planes[4];
  size_t plane_bytes;
  size_t pixel_bytes;
} Capture;

typedef struct {
  uint8_t *bytes;
  size_t len;
} Blob;

static bool read_file_all(const char *path, Blob *out) {
  out->bytes = NULL; out->len = 0;
  FILE *f = fopen(path, "rb");
  if (!f) return false;
  if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return false; }
  long sz = ftell(f);
  if (sz < 0 || sz > 16 * 1024 * 1024 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return false; }
  out->len = (size_t)sz;
  out->bytes = (uint8_t *)malloc(out->len ? out->len : 1);
  if (!out->bytes) { fclose(f); out->len = 0; return false; }
  if (out->len && fread(out->bytes, 1, out->len, f) != out->len) {
    free(out->bytes); out->bytes = NULL; out->len = 0; fclose(f); return false;
  }
  fclose(f);
  return true;
}

static bool write_bytes(const char *path, const uint8_t *bytes, size_t len) {
  FILE *f = fopen(path, "wb");
  if (!f) return false;
  bool ok = (len == 0) || fwrite(bytes, 1, len, f) == len;
  if (fclose(f) != 0) ok = false;
  return ok;
}

static bool blob_eq(const Blob *a, const Blob *b) {
  return a->len == b->len && (a->len == 0 || memcmp(a->bytes, b->bytes, a->len) == 0);
}

static uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t be32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static size_t bpp_for(uint32_t component) {
  if (component == GLIMS_COLOR_COMPONENT_U8) return 1;
  if (component == GLIMS_COLOR_COMPONENT_U16) return 2;
  return 4;
}

static void release_capture(Capture *cap) {
  if (!cap) return;
  for (int c = 0; c < 4; c++) g_clear_pointer(&cap->planes[c], g_free);
  g_clear_object(&cap->image_file);
  g_clear_object(&cap->imported_file);
  g_clear_object(&cap->exported_file);
  g_clear_object(&cap->save_a_copy_file);
  g_clear_pointer(&cap->profile, g_free);
  memset(cap, 0, sizeof *cap);
}

static bool channels_equal(const GlimsChannelInfo *a, const GlimsChannelInfo *b) {
  return a->id == b->id &&
         strcmp(a->name, b->name) == 0 &&
         a->visible == b->visible &&
         a->selected == b->selected &&
         a->quick_mask == b->quick_mask &&
         a->opacity == b->opacity &&
         a->color.red == b->color.red && a->color.green == b->color.green &&
         a->color.blue == b->color.blue && a->color.alpha == b->color.alpha;
}

static bool file_equal_nullable(GFile *a, GFile *b) {
  return (!a || !b) ? a == b : g_file_equal(a, b);
}

static bool capture_equal(const Capture *a, const Capture *b) {
  if (a->map.width != b->map.width || a->map.height != b->map.height ||
      a->map.count != b->map.count || a->map.mode != b->map.mode ||
      a->map.storage != b->map.storage || a->map.encoding != b->map.encoding ||
      a->native_count != b->native_count || a->selected_count != b->selected_count ||
      memcmp(a->native_order, b->native_order, sizeof a->native_order) ||
      memcmp(a->selected_ids, b->selected_ids, sizeof a->selected_ids)) return false;
  if (a->component != b->component || a->plane_bytes != b->plane_bytes) return false;
  for (int c = 0; c < 4; c++) {
    if (memcmp(a->map.entries[c].uuid, b->map.entries[c].uuid, 16) != 0 ||
        a->item_ids[c] != b->item_ids[c]) return false;
    for (int k = 0; k < 3; k++)
      if (a->map.entries[c].ink_rgb[k] != b->map.entries[c].ink_rgb[k]) return false;
    if (memcmp(a->planes[c], b->planes[c], a->plane_bytes) != 0) return false;
    if (!channels_equal(&a->channels[c], &b->channels[c])) return false;
  }
  if (a->profile_len != b->profile_len) return false;
  if (a->profile_len && memcmp(a->profile, b->profile, a->profile_len) != 0) return false;
  if (a->undo.undo_count != b->undo.undo_count || a->undo.redo_count != b->undo.redo_count ||
      strcmp(a->undo.next_undo, b->undo.next_undo) || strcmp(a->undo.next_redo, b->undo.next_redo)) return false;
  if (a->history.revision != b->history.revision || a->history.count != b->history.count ||
      a->history.current_position != b->history.current_position) return false;
  if (a->dirty != b->dirty) return false;
  return file_equal_nullable(a->image_file, b->image_file) &&
         file_equal_nullable(a->imported_file, b->imported_file) &&
         file_equal_nullable(a->exported_file, b->exported_file) &&
         file_equal_nullable(a->save_a_copy_file, b->save_a_copy_file);
}

static GlimsStatus capture_state(GlimsEngine *engine, gpointer data) {
  Capture *cap = (Capture *)data;
  GlimsOpenImage *open = glims_lookup_image(engine, cap->id);
  GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open, &storage))
    return GLIMS_STATUS_FAILED;
  cap->map = storage.map;
  cap->profile_len = storage.profile_size;
  cap->profile = (uint8_t *)g_memdup2(storage.profile, storage.profile_size);
  cap->pixel_bytes = bpp_for(storage.map.storage == GLIMS_PLATE_STORAGE_U8 ? GLIMS_COLOR_COMPONENT_U8
                          : storage.map.storage == GLIMS_PLATE_STORAGE_U16 ? GLIMS_COLOR_COMPONENT_U16
                          : GLIMS_COLOR_COMPONENT_FLOAT);
  cap->plane_bytes = (size_t)cap->width * (size_t)cap->height * cap->pixel_bytes;
  for (guint c = 0; c < 4; c++) {
    GimpDrawable *drawable = GIMP_DRAWABLE(storage.planes[c]);
    cap->item_ids[c] = gimp_item_get_id(GIMP_ITEM(drawable));
    cap->planes[c] = (uint8_t *)g_malloc(cap->plane_bytes);
    gegl_buffer_get(gimp_drawable_get_buffer(drawable),
                    GEGL_RECTANGLE(0, 0, cap->width, cap->height), 1.0,
                    gimp_drawable_get_format(drawable), cap->planes[c],
                    GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  }
  for (GList *it = gimp_image_get_channel_iter(open->image); it; it = it->next) {
    if (cap->native_count == 4) return GLIMS_STATUS_FAILED;
    cap->native_order[cap->native_count++] = gimp_item_get_id(GIMP_ITEM(it->data));
  }
  for (GList *it = gimp_image_get_selected_channels(open->image); it; it = it->next) {
    if (cap->selected_count == 4) return GLIMS_STATUS_FAILED;
    cap->selected_ids[cap->selected_count++] = gimp_item_get_id(GIMP_ITEM(it->data));
  }
  cap->dirty = gimp_image_is_dirty(open->image);
  cap->image_file = gimp_image_get_file(open->image); if (cap->image_file) g_object_ref(cap->image_file);
  cap->imported_file = gimp_image_get_imported_file(open->image); if (cap->imported_file) g_object_ref(cap->imported_file);
  cap->exported_file = gimp_image_get_exported_file(open->image); if (cap->exported_file) g_object_ref(cap->exported_file);
  cap->save_a_copy_file = gimp_image_get_save_a_copy_file(open->image); if (cap->save_a_copy_file) g_object_ref(cap->save_a_copy_file);
  return (cap->profile || cap->profile_len == 0) ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static bool take_capture(GlimsEngine *engine, Capture *cap, const char *label) {
  memset(&cap->undo, 0, sizeof cap->undo);
  memset(&cap->history, 0, sizeof cap->history);
  memset(cap->channels, 0, sizeof cap->channels);
  GlimsStatus st = api->image_undo_info(engine, cap->id, &cap->undo);
  CHECK(st == GLIMS_STATUS_OK, label);
  if (st != GLIMS_STATUS_OK) return false;
  st = api->image_history(engine, cap->id, NULL, 0, &cap->history);
  CHECK(st == GLIMS_STATUS_OK, label);
  if (st != GLIMS_STATUS_OK) return false;
  int32_t chan_count = 0;
  st = api->image_channels(engine, cap->id, cap->channels, 4, &chan_count);
  CHECK(st == GLIMS_STATUS_OK && chan_count == 4, label);
  if (st != GLIMS_STATUS_OK || chan_count != 4) return false;
  st = glims_engine_call(engine, capture_state, cap);
  CHECK(st == GLIMS_STATUS_OK, label);
  return st == GLIMS_STATUS_OK;
}

static GlimsStatus seed_native(GlimsEngine *engine, gpointer data) {
  Capture *cap = (Capture *)data;
  GlimsOpenImage *open = glims_lookup_image(engine, cap->id);
  GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open, &storage)) return GLIMS_STATUS_FAILED;
  cap->map = storage.map;
  for (guint c = 0; c < 4; c++) {
    GimpDrawable *drawable = GIMP_DRAWABLE(storage.planes[c]);
    cap->item_ids[c] = gimp_item_get_id(GIMP_ITEM(drawable));
    const Babl *format = gimp_drawable_get_format(drawable);
    uint8_t *buf = cap->planes[c];
    for (int y = 0; y < cap->height; y++) {
      for (int x = 0; x < cap->width; x++) {
        size_t idx = ((size_t)y * (size_t)cap->width + (size_t)x);
        /* Deterministic, distinct per-plane integer pattern crossing chunk edge. */
        uint32_t v = (uint32_t)(x * 131u + y * 977u + c * 4099u + 17u);
        if (cap->component == GLIMS_COLOR_COMPONENT_U8) {
          buf[idx] = (uint8_t)(v & 0xffu);
        } else if (cap->component == GLIMS_COLOR_COMPONENT_U16) {
          uint16_t u = (uint16_t)((v * 97u + c * 17u) & 0xffffu);
          memcpy(buf + idx * 2, &u, 2);
        } else {
          float f = (float)((v % 1024u) / 1023.0f);
          memcpy(buf + idx * 4, &f, 4);
        }
      }
    }
    /* Required U16 sentinels at known positions. */
    if (cap->component == GLIMS_COLOR_COMPONENT_U16) {
      uint16_t sentinels[9] = {0,1,255,256,257,32767,32768,65534,65535};
      int posx[9] = {0,1,2,3,4,4096,4097,4101,4102};
      int posy[9] = {0,0,0,0,0,1,1,2,2};
      for (int i = 0; i < 9; i++) {
        size_t idx = (size_t)posy[i] * (size_t)cap->width + (size_t)posx[i];
        memcpy(buf + idx * 2, &sentinels[i], 2);
      }
    }
    gegl_buffer_set(gimp_drawable_get_buffer(drawable),
                    GEGL_RECTANGLE(0, 0, cap->width, cap->height), 0,
                    format, buf, GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(drawable, 0, 0, cap->width, cap->height);
  }

  /* Reorder native channels and rename/hide one so export must follow map UUID
   * C/M/Y/K order and include hidden samples, not native list order/names. */
  gboolean moved = gimp_image_reorder_item(open->image, GIMP_ITEM(storage.planes[3]), NULL, 0, FALSE, NULL);
  if (!moved) return GLIMS_STATUS_FAILED;
  /* Authoritative rename/hide follows through the public channel API. */

  /* Distinctive non-null file identities before painting/baseline. */
  gchar *base = g_strdup_printf("file:///tmp/glims-native-cmyk-%u.xcf", cap->component);
  gchar *imp = g_strdup_printf("file:///tmp/glims-native-cmyk-%u-import.tif", cap->component);
  gchar *exp = g_strdup_printf("file:///tmp/glims-native-cmyk-%u-export-old.tif", cap->component);
  gchar *cpy = g_strdup_printf("file:///tmp/glims-native-cmyk-%u-copy.xcf", cap->component);
  GFile *f1 = g_file_new_for_uri(base), *f2 = g_file_new_for_uri(imp);
  GFile *f3 = g_file_new_for_uri(exp), *f4 = g_file_new_for_uri(cpy);
  gimp_image_set_file(open->image, f1);
  gimp_image_set_imported_file(open->image, f2);
  gimp_image_set_exported_file(open->image, f3);
  gimp_image_set_save_a_copy_file(open->image, f4);
  g_object_unref(f1); g_object_unref(f2); g_object_unref(f3); g_object_unref(f4);
  g_free(base); g_free(imp); g_free(exp); g_free(cpy);

  gimp_image_undo_free(open->image);
  gimp_image_clean_all(open->image); /* public edits below establish Undo/dirty */
  return GLIMS_STATUS_OK;
}

static GlimsStatus mutate_profile(GlimsEngine *engine, gpointer data) {
  const char *kind = (const char *)((void **)data)[1];
  GlimsImageID id = *(GlimsImageID *)((void **)data)[0];
  GlimsOpenImage *open = glims_lookup_image(engine, id);
  if (!open) return GLIMS_STATUS_FAILED;
  const guint8 *profile = NULL; guint32 size = 0;
  const GimpParasite *tag = gimp_image_parasite_find(open->image, GLIMS_PLATE_PROFILE_PARASITE);
  if (!tag) return GLIMS_STATUS_FAILED;
  profile = (const guint8 *)gimp_parasite_get_data(tag, &size);
  guint8 *bad = g_memdup2(profile, size);
  if (strcmp(kind, "alter") == 0) {
    /* Alter exact ICC bytes while keeping plausible structure/header size. */
    bad[80] ^= 1; bad[size - 1] ^= 1;
  } else { /* structural damage */
    memset(bad + 128, 0, size - 128);
  }
  GimpParasite *newtag = gimp_parasite_new(GLIMS_PLATE_PROFILE_PARASITE,
                                           gimp_parasite_get_flags(tag), size, bad);
  gimp_image_parasite_attach(open->image, newtag, FALSE);
  gimp_parasite_free(newtag);
  g_free(bad);
  return GLIMS_STATUS_OK;
}

static GlimsStatus restore_profile(GlimsEngine *engine, gpointer data) {
  GlimsImageID id = *(GlimsImageID *)((void **)data)[0];
  uint8_t *orig = (uint8_t *)((void **)data)[1];
  size_t len = *(size_t *)((void **)data)[2];
  GlimsOpenImage *open = glims_lookup_image(engine, id);
  if (!open) return GLIMS_STATUS_FAILED;
  GimpParasite *tag = gimp_parasite_new(GLIMS_PLATE_PROFILE_PARASITE,
                                        GIMP_PARASITE_PERSISTENT, (guint32)len, orig);
  gimp_image_parasite_attach(open->image, tag, FALSE);
  gimp_parasite_free(tag);
  return GLIMS_STATUS_OK;
}

static bool decode_psd_and_compare(const char *path, const Capture *cap, const uint8_t *orig_icc,
                                   size_t orig_icc_len, const char *label_prefix) {
  char label[512];
  Blob psd = {0};
  snprintf(label, sizeof label, "%s: export wrote a readable PSD file", label_prefix);
  if (!read_file_all(path, &psd)) { CHECK(false, label); return false; }
  CHECK(true, label);

  const uint8_t *b = psd.bytes; size_t n = psd.len;
  bool ok = true;
  snprintf(label, sizeof label, "%s: PSD header and reserved fields are literal", label_prefix);
  if (n < 26 || memcmp(b, "8BPS", 4) != 0 || be16(b + 4) != 1 || be16(b + 6) != 0 ||
      be32(b + 8) != 0 || be16(b + 12) != 4 ||
      be32(b + 14) != (uint32_t)cap->height || be32(b + 18) != (uint32_t)cap->width ||
      be16(b + 22) != (cap->component == GLIMS_COLOR_COMPONENT_U8 ? 8 : 16) ||
      be16(b + 24) != 4) {
    CHECK(false, label);
    ok = false;
  } else {
    CHECK(true, label);
  }
  if (!ok) { free(psd.bytes); return false; }

  size_t off = 26;
  snprintf(label, sizeof label, "%s: color mode data section is zero", label_prefix);
  if (off + 4 > n) { CHECK(false, label); free(psd.bytes); return false; }
  uint32_t color_len = be32(b + off); off += 4;
  CHECK(color_len == 0, label);
  if (color_len != 0) { free(psd.bytes); return false; }

  snprintf(label, sizeof label, "%s: image resources contain exactly one ICC profile (1039) matching original bytes", label_prefix);
  if (off + 4 > n) { CHECK(false, label); free(psd.bytes); return false; }
  uint32_t res_len = be32(b + off); off += 4;
  if (res_len > n - off) { CHECK(false, label); free(psd.bytes); return false; }
  size_t res_end = off + res_len;
  bool found_icc = false; bool icc_match = false; bool one_icc = true; bool padding_ok = true;
  if (res_end > n) { CHECK(false, label); free(psd.bytes); return false; }
  size_t ro = off; int icc_count = 0, resource_count = 0;
  while (ro < res_end) {
    if (res_end - ro < 6 || memcmp(b + ro, "8BIM", 4) != 0) { padding_ok = false; break; }
    uint16_t rid = be16(b + ro + 4); ro += 6; resource_count++;
    if (ro >= res_end) { padding_ok = false; break; }
    uint8_t pname_len = b[ro++];
    if (pname_len != 0) padding_ok = false;
    if (res_end - ro < pname_len) { padding_ok = false; break; }
    ro += pname_len;
    /* Pascal string padded to even total (length byte + chars). */
    if (((1u + (unsigned)pname_len) & 1u) != 0) {
      if (ro >= res_end) { padding_ok = false; break; }
      if (b[ro] != 0) padding_ok = false;
      ro += 1;
    }
    if (res_end - ro < 4) { padding_ok = false; break; }
    uint32_t dlen = be32(b + ro); ro += 4;
    if (res_end - ro < dlen) { padding_ok = false; break; }
    if (rid == 1039) {
      icc_count++;
      found_icc = true;
      icc_match = (dlen == orig_icc_len && memcmp(b + ro, orig_icc, dlen) == 0);
    }
    ro += dlen;
    if (dlen & 1u) {
      if (ro >= res_end) { padding_ok = false; break; }
      if (b[ro] != 0) padding_ok = false;
      ro += 1; /* even padding byte */
    }
  }
  if (icc_count != 1 || resource_count != 1) one_icc = false;
  CHECK(found_icc && one_icc && icc_match && padding_ok && ro == res_end, label);
  off = res_end;

  snprintf(label, sizeof label, "%s: layer/mask section is zero", label_prefix);
  if (off + 4 > n) { CHECK(false, label); free(psd.bytes); return false; }
  uint32_t lm_len = be32(b + off); off += 4;
  CHECK(lm_len == 0, label);
  if (lm_len != 0) { free(psd.bytes); return false; }

  snprintf(label, sizeof label, "%s: image data is RAW (compression 0)", label_prefix);
  if (off + 2 > n) { CHECK(false, label); free(psd.bytes); return false; }
  uint16_t comp = be16(b + off); off += 2;
  CHECK(comp == 0, label);

  size_t plane_pixels = (size_t)cap->width * (size_t)cap->height;
  size_t sample_bytes = bpp_for(cap->component);
  size_t expected_data = plane_pixels * sample_bytes * 4;
  snprintf(label, sizeof label, "%s: exact total remaining planar bytes and EOF", label_prefix);
  CHECK(n - off == expected_data, label);

  /* Decode and compare ALL samples in canonical C/M/Y/K map order. */
  snprintf(label, sizeof label, "%s: all decoded samples match raw baseline in canonical CMYK order", label_prefix);
  bool samples_ok = (n - off == expected_data);
  for (int c = 0; c < 4 && samples_ok; c++) {
    const uint8_t *src = b + off + (size_t)c * plane_pixels * sample_bytes;
    const uint8_t *exp = cap->planes[c];
    for (size_t pixel = 0; pixel < plane_pixels && samples_ok; pixel++) {
      uint16_t expected = exp[pixel];
      if (sample_bytes == 2) memcpy(&expected, exp + pixel * 2, 2);
      uint16_t actual = sample_bytes == 1 ? src[pixel] : be16(src + pixel * 2);
      if (actual != expected) {
        fprintf(stderr, "%s plane%d sample%zu: expected%u actual%u\n", label_prefix,c,pixel,expected,actual);
        samples_ok = false;
      }
    }
  }
  CHECK(samples_ok, label);

  free(psd.bytes);
  return samples_ok && found_icc && one_icc && icc_match && padding_ok && comp == 0 && color_len == 0 && lm_len == 0;
}

static void make_sentinel(const char *path) {
  const uint8_t sent[] = "GLIMS_NATIVE_CMYK_EXPORT_SENTINEL_V1";
  CHECK(write_bytes(path, sent, sizeof sent - 1), "fixture sentinel write succeeds");
}

static bool sentinel_intact(const char *path) {
  Blob b = {0}; if (!read_file_all(path, &b)) return false;
  const char expected[] = "GLIMS_NATIVE_CMYK_EXPORT_SENTINEL_V1";
  bool ok = b.len == strlen(expected) && memcmp(b.bytes, expected, b.len) == 0;
  free(b.bytes);
  return ok;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <work-dir> <cmyk-profile.icc>\n", argv[0]);
    return 2;
  }
  const char *work_dir = argv[1];
  const char *profile_path = argv[2];

  Blob icc = {0};
  if (!read_file_all(profile_path, &icc)) {
    fprintf(stderr, "FAIL could not read CMYK profile: %s\n", profile_path);
    return 2;
  }

  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_export_native_cmyk_psd) + sizeof api->image_export_native_cmyk_psd ||
      !api->image_export_native_cmyk_psd) {
    fprintf(stderr, "FAIL adapter lacks slot182 image_export_native_cmyk_psd\n");
    free(icc.bytes);
    return 2;
  }

  gchar *user_dir = g_build_filename(work_dir, "user", NULL);
  gchar *cache_dir = g_build_filename(work_dir, "cache", NULL);
  GlimsEngineConfig config = {0};
  config.struct_size = sizeof config;
  config.user_directory = user_dir;
  config.cache_directory = cache_dir;
  GlimsEngine *engine = NULL;
  char *error = NULL;
  GlimsStatus st = api->start(&config, &engine, &error);
  if (st != GLIMS_STATUS_OK || !engine) {
    fprintf(stderr, "FAIL engine start: %s\n", error ? error : "(null)");
    api->free_string(error);
    free(icc.bytes);
    g_free(user_dir); g_free(cache_dir);
    return 2;
  }
  api->free_string(error); error = NULL;

  const int W = 4103, H = 3; /* crosses chunk edge, cheap */

  /* ---- Successful export cases: U8 and U16 ---- */
  uint32_t comps[2] = { GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16 };
  const char *cnames[2] = { "U8", "U16" };
  for (int ci = 0; ci < 2; ci++) {
    uint32_t component = comps[ci];
    const char *cname = cnames[ci];
    char label[512];
    Capture cap = {0};
    cap.id = 0; cap.width = W; cap.height = H; cap.component = component;

    snprintf(label, sizeof label, "%s: image_new_cmyk creates native CMYK document", cname);
    st = api->image_new_cmyk(engine, W, H, component, icc.bytes, icc.len, &cap.id, &error);
    CHECK(st == GLIMS_STATUS_OK && cap.id != 0, label);
    api->free_string(error); error = NULL;
    if (st != GLIMS_STATUS_OK || !cap.id) continue;

    cap.pixel_bytes = bpp_for(component);
    cap.plane_bytes = (size_t)W * (size_t)H * cap.pixel_bytes;
    for (int c = 0; c < 4; c++) cap.planes[c] = (uint8_t *)g_malloc0(cap.plane_bytes);

    /* Seed all four authoritative planes, reorder/rename/hide, set file identities. */
    st = glims_engine_call(engine, seed_native, &cap);
    snprintf(label, sizeof label, "%s: fixture seeded planes, reorder/rename/hide and file identities", cname);
    CHECK(st == GLIMS_STATUS_OK, label);

    GlimsChannelChange change = {.struct_size = sizeof change,
      .properties = GLIMS_CHANNEL_NAME | GLIMS_CHANNEL_VISIBLE, .visible = false};
    g_strlcpy(change.name, "NotMagenta", sizeof change.name);
    st = api->channel_change(engine, cap.id, cap.item_ids[1], &change, &error);
    CHECK(st == GLIMS_STATUS_OK, "public channel change renames and hides authoritative Magenta ink");
    api->free_string(error); error = NULL;
    GlimsUndoInfo before_stroke = {0};
    CHECK(api->image_undo_info(engine, cap.id, &before_stroke) == GLIMS_STATUS_OK, "capture Undo before public stroke");

    /* Public Pencil stroke on one plane to establish dirty state and Undo. */
    int32_t chan_count = 0;
    GlimsChannelInfo chs[4] = {{0}};
    st = api->image_channels(engine, cap.id, chs, 4, &chan_count);
    CHECK(st == GLIMS_STATUS_OK && chan_count == 4, "channels available for stroke target");
    GlimsItemID stroke_target = cap.item_ids[1]; /* canonical Magenta UUID */
    GlimsBrushSettings brush = {0};
    brush.struct_size = sizeof brush; brush.tool = GLIMS_PAINT_PENCIL;
    brush.size = 11.0; brush.opacity = 1.0; brush.red = 0.2; brush.green = 0.2; brush.blue = 0.2;
    brush.hardness = 1.0; brush.rate = 0.0; brush.flow = 100.0; brush.exposure = -1.0;
    GlimsStrokePoint pt = { 12.5, 1.5, 1.0, 0.0, 0.0, 100 };
    GlimsStrokeID stroke = 0;
    st = api->stroke_begin(engine, cap.id, stroke_target, &brush, &pt, &stroke, &error);
    snprintf(label, sizeof label, "%s: public Pencil stroke begins on one plane", cname);
    CHECK(st == GLIMS_STATUS_OK && stroke != 0, label);
    api->free_string(error); error = NULL;
    if (stroke != 0) {
      st = api->stroke_end(engine, stroke);
      snprintf(label, sizeof label, "%s: public Pencil stroke ends", cname);
      CHECK(st == GLIMS_STATUS_OK, label);
    }

    Capture baseline = {0};
    baseline.id = cap.id; baseline.width = W; baseline.height = H; baseline.component = component;
    snprintf(label, sizeof label, "%s: capture exact post-stroke baseline (raw/history/undo/dirty/identity)", cname);
    bool captured = take_capture(engine, &baseline, label);
    CHECK(captured, label);
    if (captured) {
      if (component == GLIMS_COLOR_COMPONENT_U16) {
        const uint16_t gold[] = {0,1,255,256,257,32767,32768,65534,65535};
        const int xs[] = {0,1,2,3,4,4096,4097,4101,4102};
        const int ys[] = {0,0,0,0,0,1,1,2,2};
        bool exact = true;
        for (int c = 0; c < 4; c++) for (size_t i = 0; i < G_N_ELEMENTS(gold); i++) {
          uint16_t actual = 0;
          memcpy(&actual, baseline.planes[c] + ((size_t)ys[i]*W + xs[i])*2, 2);
          exact &= actual == gold[i];
        }
        CHECK(exact, "U16: all nine literal boundary values survive native storage on all four planes");
      }
      bool hidden = false;
      for (int i = 0; i < 4; i++) if (baseline.channels[i].id == cap.item_ids[1])
        hidden = !baseline.channels[i].visible && !strcmp(baseline.channels[i].name, "NotMagenta");
      CHECK(hidden, "baseline really has renamed and hidden authoritative ink");
      CHECK(baseline.native_count == 4 && baseline.native_order[0] == cap.item_ids[3], "native channel order differs from canonical CMYK");
      CHECK(baseline.image_file && baseline.imported_file && baseline.exported_file && baseline.save_a_copy_file, "baseline file identities are all nonnull");
      CHECK(baseline.undo.undo_count == before_stroke.undo_count + 1, "public stroke adds exactly one Undo step");
      bool changed_only_target = memcmp(cap.planes[1], baseline.planes[1], cap.plane_bytes) != 0;
      for (int c = 0; c < 4; c++) if (c != 1) changed_only_target &= !memcmp(cap.planes[c], baseline.planes[c], cap.plane_bytes);
      CHECK(changed_only_target, "public stroke changes only the explicit authoritative target");
      /* Deterministic seeded values outside stroke must remain exact after paint. */
      /* Check a few far-away positions on all planes against what seed_native wrote. */
      bool outside_ok = true;
      for (int c = 0; c < 4 && outside_ok; c++) {
        /* far corner away from stroke center (12.5,1.5), radius ~5.5 */
        int px = 4000, py = 2;
        size_t idx = ((size_t)py * W + (size_t)px);
        if (component == GLIMS_COLOR_COMPONENT_U8) {
          uint8_t expected = (uint8_t)(((uint32_t)(px * 131u + py * 977u + c * 4099u + 17u)) & 0xffu);
          if (baseline.planes[c][idx] != expected) outside_ok = false;
        } else {
          /* compare U16 at a sentinel position known outside stroke */
          int sx = 4102, sy = 2; size_t si = (size_t)sy * W + (size_t)sx;
          uint16_t expected_s = 65535;
          uint16_t got_s = 0; memcpy(&got_s, baseline.planes[c] + si * 2, 2);
          if (got_s != expected_s) outside_ok = false;
        }
      }
      snprintf(label, sizeof label, "%s: deterministic seeded values outside stroke remain exact", cname);
      CHECK(outside_ok, label);
      CHECK(baseline.undo.undo_count >= 1, cname[0] ? (snprintf(label,sizeof label,"%s: meaningful Undo exists after stroke",cname),label) : "");
      CHECK(baseline.dirty, cname[0] ? (snprintf(label,sizeof label,"%s: image is dirty after stroke",cname),label) : "");
    }

    gchar *out1 = g_build_filename(work_dir, component == GLIMS_COLOR_COMPONENT_U8 ? "native-u8.psd" : "native-u16.psd", NULL);
    gchar *out2 = g_build_filename(work_dir, component == GLIMS_COLOR_COMPONENT_U8 ? "native-u8-again.psd" : "native-u16-again.psd", NULL);
    make_sentinel(out1);
    CHECK(sentinel_intact(out1), (snprintf(label,sizeof label,"%s: sentinel preexisting file created",cname),label));

    /* First export overwrites preexisting sentinel successfully. */
    st = api->image_export_native_cmyk_psd(engine, cap.id, out1, &error);
    snprintf(label, sizeof label, "%s: first native CMYK PSD export succeeds and overwrites sentinel", cname);
    CHECK(st == GLIMS_STATUS_OK, label);
    api->free_string(error); error = NULL;

    Capture after1 = {0};
    after1.id = cap.id; after1.width = W; after1.height = H; after1.component = component;
    if (st == GLIMS_STATUS_OK && captured) {
      bool okcap = take_capture(engine, &after1, (snprintf(label,sizeof label,"%s: capture source state after first export",cname),label));
      CHECK(okcap && capture_equal(&baseline, &after1), (snprintf(label,sizeof label,"%s: successful export preserves every captured source field and raw data/Undo/dirty/fileidentity",cname),label));
      decode_psd_and_compare(out1, &baseline, icc.bytes, icc.len, cname);
    }

    /* Save the first successful result, replace that SAME path again, and compare. */
    Blob first_result = {0};
    CHECK(read_file_all(out1, &first_result), "first result available for repeated replacement comparison");
    CHECK(write_bytes(out2, first_result.bytes, first_result.len), "save independent first result copy");
    free(first_result.bytes);
    st = api->image_export_native_cmyk_psd(engine, cap.id, out1, &error);
    snprintf(label, sizeof label, "%s: repeated export succeeds", cname);
    CHECK(st == GLIMS_STATUS_OK, label);
    api->free_string(error); error = NULL;
    if (st == GLIMS_STATUS_OK && captured) {
      Capture after2 = {0};
      after2.id = cap.id; after2.width = W; after2.height = H; after2.component = component;
      bool okcap = take_capture(engine, &after2, (snprintf(label,sizeof label,"%s: capture after repeated export",cname),label));
      CHECK(okcap && capture_equal(&baseline, &after2), (snprintf(label,sizeof label,"%s: repeated export preserves all source state",cname),label));
      Blob b1 = {0}, b2 = {0};
      bool r1 = read_file_all(out1, &b1), r2 = read_file_all(out2, &b2);
      CHECK(r1 && r2 && blob_eq(&b1, &b2), (snprintf(label,sizeof label,"%s: repeated export produces exact same PSD bytes",cname),label));
      free(b1.bytes); free(b2.bytes);
      release_capture(&after2);
    }

    /* A fresh destination exercises publication without an existing entry. */
    gchar *fresh = g_build_filename(work_dir, ci == 0 ? "fresh-u8.psd" : "fresh-u16.psd", NULL);
    CHECK(!g_file_test(fresh, G_FILE_TEST_EXISTS), "fresh export destination initially absent");
    st = api->image_export_native_cmyk_psd(engine, cap.id, fresh, &error);
    CHECK(st == GLIMS_STATUS_OK, "fresh destination native CMYK export succeeds");
    api->free_string(error); error = NULL;
    if (st == GLIMS_STATUS_OK && captured) {
      Capture after_fresh = {.id = cap.id, .width = W, .height = H, .component = component};
      bool captured_fresh = take_capture(engine, &after_fresh, "capture after fresh destination export");
      CHECK(captured_fresh && capture_equal(&baseline, &after_fresh), "fresh destination export preserves complete source state");
      decode_psd_and_compare(fresh, &baseline, icc.bytes, icc.len, cname);
      release_capture(&after_fresh);
    }
    g_free(fresh);

    /* Cleanup image */
    st = api->image_close(engine, cap.id);
    snprintf(label, sizeof label, "%s: image closes after export tests", cname);
    CHECK(st == GLIMS_STATUS_OK, label);

    release_capture(&baseline);
    release_capture(&after1);
    release_capture(&cap);
    g_free(out1); g_free(out2);
  }

  /* ---- Refusal cases with sentinel preservation ---- */
  {
    /* Ordinary RGB */
    GlimsImageID rgb = 0;
    st = api->image_new(engine, 8, 8, &rgb, &error);
    api->free_string(error); error = NULL;
    if (st == GLIMS_STATUS_OK && rgb) {
      gchar *p = g_build_filename(work_dir, "refuse-rgb.psd", NULL);
      make_sentinel(p);
      st = api->image_export_native_cmyk_psd(engine, rgb, p, &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: ordinary RGB image");
      CHECK(sentinel_intact(p), "refusal RGB preserves sentinel");
      api->free_string(error); error = NULL;
      api->image_close(engine, rgb); g_free(p);
    } else {
      CHECK(false, "setup RGB refusal image failed");
    }

    GlimsImageID multi = 0;
    st = api->image_new_multichannel(engine, 8, 8, GLIMS_COLOR_COMPONENT_U8, 4, &multi, &error);
    CHECK(st == GLIMS_STATUS_OK && multi, "setup Multichannel refusal source");
    api->free_string(error); error = NULL;
    if (multi) {
      gchar *p = g_build_filename(work_dir, "refuse-multichannel.psd", NULL); make_sentinel(p);
      st = api->image_export_native_cmyk_psd(engine, multi, p, &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: four-plate Multichannel is not CMYK");
      CHECK(sentinel_intact(p), "refusal Multichannel preserves sentinel");
      api->free_string(error); error = NULL;
      CHECK(api->image_close(engine, multi) == GLIMS_STATUS_OK, "Multichannel fixture closes"); g_free(p);
    }
    gchar *unknown = g_build_filename(work_dir, "refuse-unknown.psd", NULL); make_sentinel(unknown);
    st = api->image_export_native_cmyk_psd(engine, INT32_MAX, unknown, &error);
    CHECK(st != GLIMS_STATUS_OK, "refusal: nonexistent nonzero image ID");
    CHECK(sentinel_intact(unknown), "unknown nonzero ID preserves sentinel");
    api->free_string(error); error = NULL; g_free(unknown);

    /* Unknown/zero id */
    gchar *p0 = g_build_filename(work_dir, "refuse-zero.psd", NULL);
    make_sentinel(p0);
    st = api->image_export_native_cmyk_psd(engine, 0, p0, &error);
    CHECK(st != GLIMS_STATUS_OK, "refusal: unknown/zero image id");
    CHECK(sentinel_intact(p0), "refusal zero-id preserves sentinel");
    api->free_string(error); error = NULL; g_free(p0);

    /* CMYK FLOAT refusal */
    GlimsImageID fimg = 0;
    st = api->image_new_cmyk(engine, 8, 8, GLIMS_COLOR_COMPONENT_FLOAT, icc.bytes, icc.len, &fimg, &error);
    api->free_string(error); error = NULL;
    if (st == GLIMS_STATUS_OK && fimg) {
      gchar *p = g_build_filename(work_dir, "refuse-float.psd", NULL);
      make_sentinel(p);
      st = api->image_export_native_cmyk_psd(engine, fimg, p, &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: CMYK FLOAT (U8/U16 only)");
      CHECK(sentinel_intact(p), "refusal CMYK FLOAT preserves sentinel");
      api->free_string(error); error = NULL;
      api->image_close(engine, fimg); g_free(p);
    } else {
      CHECK(false, "setup CMYK FLOAT refusal image must succeed");
    }

    /* Valid U8 CMYK source for path/dimension/profile refusal checks */
    GlimsImageID src = 0;
    st = api->image_new_cmyk(engine, 8, 8, GLIMS_COLOR_COMPONENT_U8, icc.bytes, icc.len, &src, &error);
    api->free_string(error); error = NULL;
    CHECK(st == GLIMS_STATUS_OK && src != 0, "setup: valid U8 CMYK source for refusal cases");
    if (st == GLIMS_STATUS_OK && src) {
      gchar *p;

      p = g_build_filename(work_dir, "refuse-null.psd", NULL); make_sentinel(p);
      st = api->image_export_native_cmyk_psd(engine, src, NULL, &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: null path");
      CHECK(sentinel_intact(p), "refusal null path preserves unrelated sentinel");
      api->free_string(error); error = NULL; g_free(p);

      p = g_build_filename(work_dir, "refuse-empty.psd", NULL); make_sentinel(p);
      st = api->image_export_native_cmyk_psd(engine, src, "", &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: empty path");
      CHECK(sentinel_intact(p), "refusal empty path preserves unrelated sentinel");
      api->free_string(error); error = NULL; g_free(p);

      p = g_build_filename(work_dir, "relative.psd", NULL); make_sentinel(p);
      st = api->image_export_native_cmyk_psd(engine, src, "relative.psd", &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: relative path");
      CHECK(sentinel_intact(p), "refusal relative path preserves its exact sentinel target");
      api->free_string(error); error = NULL; g_free(p);

      p = g_build_filename(work_dir, "refuse-ext.tif", NULL); make_sentinel(p);
      st = api->image_export_native_cmyk_psd(engine, src, p, &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: wrong extension (not .psd)");
      CHECK(sentinel_intact(p), "refusal wrong extension preserves sentinel");
      api->free_string(error); error = NULL; g_free(p);

      /* Damaged admitted profile: alter exact ICC bytes, expect failure w/o touching sentinel, restore. */
      p = g_build_filename(work_dir, "refuse-damaged-alter.psd", NULL); make_sentinel(p);
      void *mut1_args[2] = { &src, "alter" };
      st = glims_engine_call(engine, mutate_profile, mut1_args);
      CHECK(st == GLIMS_STATUS_OK, "fixture mutates admitted profile bytes (altered)");
      st = api->image_export_native_cmyk_psd(engine, src, p, &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: damaged admitted profile (altered exact ICC bytes)");
      CHECK(sentinel_intact(p), "refusal altered profile preserves sentinel");
      api->free_string(error); error = NULL;
      void *rest1_args[3] = { &src, icc.bytes, &icc.len };
      st = glims_engine_call(engine, restore_profile, rest1_args);
      CHECK(st == GLIMS_STATUS_OK, "fixture restores admitted profile after alter refusal");
      g_free(p);

      p = g_build_filename(work_dir, "refuse-damaged-struct.psd", NULL); make_sentinel(p);
      void *mut2_args[2] = { &src, "struct" };
      st = glims_engine_call(engine, mutate_profile, mut2_args);
      CHECK(st == GLIMS_STATUS_OK, "fixture mutates admitted profile (structural damage)");
      st = api->image_export_native_cmyk_psd(engine, src, p, &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: damaged admitted profile (structural)");
      CHECK(sentinel_intact(p), "refusal structural profile damage preserves sentinel");
      api->free_string(error); error = NULL;
      void *rest2_args[3] = { &src, icc.bytes, &icc.len };
      st = glims_engine_call(engine, restore_profile, rest2_args);
      CHECK(st == GLIMS_STATUS_OK, "fixture restores admitted profile after structural refusal");
      /* Verify source still usable after restore. */
      Capture after_damage = {0};
      after_damage.id = src; after_damage.width = 8; after_damage.height = 8; after_damage.component = GLIMS_COLOR_COMPONENT_U8;
      bool ok_after = take_capture(engine, &after_damage, "source state capturable after profile restore");
      CHECK(ok_after, "source remains healthy after damaged-profile refusal+restore");
      release_capture(&after_damage);
      g_free(p);

      api->image_close(engine, src);
    } else {
      LOGF("%s", "INFO: valid U8 CMYK refusal-source setup failed; path/profile refusals incomplete");
    }

    /* Dimension limit refusals (cheap strips) if factory allows. */
    GlimsImageID wide = 0;
    st = api->image_new_cmyk(engine, 30001, 1, GLIMS_COLOR_COMPONENT_U8, icc.bytes, icc.len, &wide, &error);
    api->free_string(error); error = NULL;
    if (st == GLIMS_STATUS_OK && wide) {
      gchar *p = g_build_filename(work_dir, "refuse-wide.psd", NULL); make_sentinel(p);
      st = api->image_export_native_cmyk_psd(engine, wide, p, &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: width 30001 exceeds PSD/native limit");
      CHECK(sentinel_intact(p), "refusal width limit preserves sentinel");
      api->free_string(error); error = NULL;
      api->image_close(engine, wide); g_free(p);
    } else {
      CHECK(false, "setup 30001x1 CMYK source must succeed to exercise PSD width refusal");
    }
    GlimsImageID tall = 0;
    st = api->image_new_cmyk(engine, 1, 30001, GLIMS_COLOR_COMPONENT_U8, icc.bytes, icc.len, &tall, &error);
    api->free_string(error); error = NULL;
    if (st == GLIMS_STATUS_OK && tall) {
      gchar *p = g_build_filename(work_dir, "refuse-tall.psd", NULL); make_sentinel(p);
      st = api->image_export_native_cmyk_psd(engine, tall, p, &error);
      CHECK(st != GLIMS_STATUS_OK, "refusal: height 30001 exceeds PSD/native limit");
      CHECK(sentinel_intact(p), "refusal height limit preserves sentinel");
      api->free_string(error); error = NULL;
      api->image_close(engine, tall); g_free(p);
    } else {
      CHECK(false, "setup 1x30001 CMYK source must succeed to exercise PSD height refusal");
    }
  }

  api->stop(engine);
  g_free(user_dir); g_free(cache_dir);
  free(icc.bytes);

  LOGF("checks=%u failures=%u", checks, failures);
  return failures ? 1 : 0;
}

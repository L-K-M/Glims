/* Private bounded native Lab storage experiment.
 * Creates private GimpImage (GRAY carrier, no layers) with 3 raw GimpChannels
 * named L,a,b per precision. No Glims plate map/profile, no adoption, no
 * facade image APIs. Runs on engine thread via glims_engine_call.
 */
#include "engine-private.h"

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gegl.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"

#include "file/file-open.h"
#include "file/file-save.h"
#include "pdb/gimppdb.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
#include "plug-in/gimppluginprocedure.h"

#define W 32
#define H 2
#define PIXELS (W * H)
#define PLANES 3

static const GlimsEngineAPI *api;
static unsigned checks_total, failures_total;
static const char *g_stage = "init";
static const char *g_precision_name = "?";

#define CHECK(cond, msg) do { \
  gboolean _ok = !!(cond); checks_total++; \
  printf("%s [%s/%s] %s\n", _ok ? "ok" : "FAIL", g_precision_name, g_stage, msg); \
  if (!_ok) failures_total++; fflush(stdout); } while (0)

static void set_stage(const char *s) { g_stage = s; }

static uint32_t f32_bits(float v) { uint32_t u; memcpy(&u, &v, 4); return u; }
static uint32_t sample_bits(const guint8 *plane, unsigned i) { uint32_t v; memcpy(&v, plane + i*4, 4); return v; }

static const char *format_name(const Babl *fmt) {
  return fmt ? (babl_get_name(fmt) ? babl_get_name(fmt) : "<unnamed>") : "<null>";
}

static void print_hex(const guint8 *b, size_t n) {
  for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
}

static gboolean compare_plane(const guint8 *expected, const guint8 *actual, size_t bytes,
                              size_t sample_size, const char *label) {
  if (memcmp(expected, actual, bytes) == 0) return TRUE;
  for (size_t i = 0; i < bytes; i++) {
    if (expected[i] != actual[i]) {
      size_t sample = i / sample_size;
      printf("  first mismatch [%s/%s] %s sample=%zu byte=%zu expected=0x",
             g_precision_name, g_stage, label, sample, i);
      print_hex(expected + sample * sample_size, sample_size);
      printf(" actual=0x");
      print_hex(actual + sample * sample_size, sample_size);
      if (sample_size == 4) {
        float ef, af; uint32_t eu, au;
        memcpy(&ef, expected + sample * 4, 4); memcpy(&af, actual + sample * 4, 4);
        eu = f32_bits(ef); au = f32_bits(af);
        printf(" (float expected=%a/0x%08x actual=%a/0x%08x)", ef, eu, af, au);
      }
      printf("\n");
      return FALSE;
    }
  }
  return FALSE;
}

static gboolean compare_all(const guint8 expected[PLANES][PIXELS * 4],
                            const guint8 actual[PLANES][PIXELS * 4],
                            size_t bytes, size_t sample_size, const char *label) {
  static const char *names[PLANES] = {"L", "a", "b"};
  gboolean ok = TRUE;
  for (unsigned p = 0; p < PLANES; p++) {
    char msg[128];
    snprintf(msg, sizeof msg, "%s plane %s", label, names[p]);
    if (!compare_plane(expected[p], actual[p], bytes, sample_size, msg)) ok = FALSE;
  }
  CHECK(ok, label);
  return ok;
}

static void read_planes(GimpImage *image, GimpChannel *planes[PLANES], const Babl *fmt,
                        size_t bytes, guint8 out[PLANES][PIXELS * 4]) {
  for (unsigned p = 0; p < PLANES; p++) {
    memset(out[p], 0, PIXELS * 4);
    gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(planes[p])),
                    GEGL_RECTANGLE(0, 0, W, H), 1.0, fmt, out[p],
                    GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  }
  (void)image; (void)bytes;
}

static void write_plane(GimpChannel *plane, const Babl *fmt, const guint8 *data) {
  gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(plane)),
                  GEGL_RECTANGLE(0, 0, W, H), 0, fmt, data, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(GIMP_DRAWABLE(plane), 0, 0, W, H);
}

static void fill_seed_u8(guint8 seed[PLANES][PIXELS * 4]) {
  memset(seed, 0, PLANES * PIXELS * 4);
  /* Independent literal bytes; include neutral 128 and endpoints. */
  const guint8 lvals[PIXELS] = {0,128,255,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
                                32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61};
  const guint8 avals[PIXELS] = {128,0,255,127,126,129,1,254,2,253,3,252,4,251,5,250,6,249,7,248,8,247,9,246,10,245,11,244,12,243,13,242,
                                14,241,15,240,16,239,17,238,18,237,19,236,20,235,21,234,22,233,23,232,24,231,25,230,26,229,27,228,31,200};
  const guint8 bvals[PIXELS] = {255,128,0,1,254,2,253,3,252,4,251,5,250,6,249,7,248,8,247,9,246,10,245,11,244,12,243,13,242,14,241,15,240,
                                16,239,17,238,18,237,19,236,20,235,21,234,22,233,23,232,24,231,25,230,26,229,27,228,29,201,33,199};
  memcpy(seed[0], lvals, PIXELS);
  memcpy(seed[1], avals, PIXELS);
  memcpy(seed[2], bvals, PIXELS);
}

static void fill_seed_u16(guint8 seed[PLANES][PIXELS * 4]) {
  memset(seed, 0, PLANES * PIXELS * 4);
  const guint16 lvals[PIXELS] = {0,32896,65535,1,2,1024,2048,4096,8192,16384,24576,32768,40960,49152,57344,65534,
                                 10,20,30,40,50,60,70,80,90,100,110,120,130,140,150,160,
                                 170,180,190,200,210,220,230,240,250,260,270,280,290,300,310,320,
                                 330,340,350,360,370,380,390,400,410,420,430,440,450,460,470,480};
  const guint16 avals[PIXELS] = {32896,0,65535,32768,32767,32897,1,65534,256,65280,512,65024,768,64768,1024,64512,
                                 1280,64256,1536,64000,1792,63744,2048,63488,2304,63232,2560,62976,2816,62720,3072,62464,
                                 3328,62208,3584,61952,3840,61696,4096,61440,4352,61184,4608,60928,4864,60672,5120,60416,
                                 5376,60160,5632,59904,5888,59648,6144,59392,6400,59136,6656,58880,6912,58624,7168,58368};
  const guint16 bvals[PIXELS] = {65535,32896,0,1,65534,2,65533,3,65532,4,65531,5,65530,6,65529,7,65528,
                                 8,65527,9,65526,10,65525,11,65524,12,65523,13,65522,14,65521,15,65520,
                                 16,65519,17,65518,18,65517,19,65516,20,65515,21,65514,22,65513,23,65512,
                                 24,65511,25,65510,26,65509,27,65508,28,65507,29,65506,30,65505,31};
  memcpy(seed[0], lvals, sizeof lvals);
  memcpy(seed[1], avals, sizeof avals);
  memcpy(seed[2], bvals, sizeof bvals);
}

static void fill_seed_float(guint8 seed[PLANES][PIXELS * 4]) {
  memset(seed, 0, PLANES * PIXELS * 4);
  const float neutral_norm = 128.0f / 255.0f;
  const uint32_t minsub = 0x00000001u, neg_minsub = 0x80000001u;
  /* L plane: include required physical values and neutral normalized sample. */
  const float lvals[PIXELS] = {
    -5.f,0.f,8.f,50.f,100.f,110.f, neutral_norm, 1.f,
    -1.f,-0.f,25.f,75.f,99.f,101.f,0.5f,2.f,
    3.f,4.f,5.f,6.f,7.f,9.f,10.f,11.f,12.f,13.f,14.f,15.f,16.f,17.f,18.f,19.f,
    20.f,21.f,22.f,23.f,24.f,26.f,27.f,28.f,29.f,30.f,31.f,32.f,33.f,34.f,35.f,36.f,
    37.f,38.f,39.f,40.f,41.f,42.f,43.f,44.f,45.f,46.f,47.f,48.f,49.f,51.f,52.f,53.f
  };
  /* chroma a: required values plus minsub, -minsub, FLT_MAX finite, signed zero. */
  const float avals[PIXELS] = {
    -160.f,-128.f,-1.f,-0.f,+0.f,1.f,127.f,160.f,
    0.f /*placeholder minsub*/, 0.f /*neg minsub*/, FLT_MAX, -FLT_MAX, 0.25f,-0.25f,64.f,-64.f,
    2.f,3.f,4.f,5.f,6.f,7.f,8.f,9.f,10.f,11.f,12.f,13.f,14.f,15.f,16.f,17.f,
    18.f,19.f,20.f,21.f,22.f,23.f,24.f,25.f,26.f,27.f,28.f,29.f,30.f,31.f,32.f,33.f,
    34.f,35.f,36.f,37.f,38.f,39.f,40.f,41.f,42.f,43.f,44.f,45.f,46.f,47.f,48.f,49.f
  };
  const float bvals[PIXELS] = {
    160.f,127.f,1.f,+0.f,-0.f,-1.f,-128.f,-160.f,
    -FLT_MAX, FLT_MAX, 0.f /*minsub*/, 0.f /*neg minsub*/, -64.f,64.f,-0.25f,0.25f,
    -2.f,-3.f,-4.f,-5.f,-6.f,-7.f,-8.f,-9.f,-10.f,-11.f,-12.f,-13.f,-14.f,-15.f,-16.f,-17.f,
    -18.f,-19.f,-20.f,-21.f,-22.f,-23.f,-24.f,-25.f,-26.f,-27.f,-28.f,-29.f,-30.f,-31.f,-32.f,-33.f,
    -34.f,-35.f,-36.f,-37.f,-38.f,-39.f,-40.f,-41.f,-42.f,-43.f,-44.f,-45.f,-46.f,-47.f,-48.f,-49.f
  };
  memcpy(seed[0], lvals, sizeof lvals);
  memcpy(seed[1], avals, sizeof avals);
  memcpy(seed[2], bvals, sizeof bvals);
  memcpy(seed[1] + 8*4, &minsub, 4); memcpy(seed[1] + 9*4, &neg_minsub, 4);
  memcpy(seed[2] + 10*4, &minsub, 4); memcpy(seed[2] + 11*4, &neg_minsub, 4);
}

static void derive_after(const guint8 seed[PLANES][PIXELS * 4], guint8 after[PLANES][PIXELS * 4],
                         size_t bytes, size_t sample_size, unsigned target_plane) {
  memcpy(after, seed, PLANES * PIXELS * 4);
  /* Byte-only permutation retains every finite special, including signed zeros. */
  guint8 tmp[PIXELS * 4];
  memcpy(tmp, seed[target_plane], bytes);
  for (unsigned i = 0; i < PIXELS; i++) {
    unsigned src = (i + 13) % PIXELS;
    memcpy(after[target_plane] + i * sample_size, tmp + src * sample_size, sample_size);
  }
}

typedef struct {
  const char *work;
  GimpPrecision precision;
  const char *precision_name;
  const Babl *expected_format;
  size_t sample_size;
  char xcf_path[1024];
} Case;

static GimpImage *open_xcf(Gimp *gimp, const char *path, GimpPDBStatusType *status, GError **error) {
  GFile *file = g_file_new_for_path(path);
  const gchar *mime = NULL;
#if GIMP_CHECK_VERSION(3, 2, 0)
  gboolean handles_vector = FALSE;
  GimpImage *image = file_open_image(gimp, gimp_get_user_context(gimp), NULL, file,
                                     0, 0, FALSE, FALSE, NULL, GIMP_RUN_NONINTERACTIVE,
                                     &handles_vector, status, &mime, error);
#else
  GimpImage *image = file_open_image(gimp, gimp_get_user_context(gimp), NULL, file,
                                     0, 0, FALSE, NULL, GIMP_RUN_NONINTERACTIVE,
                                     status, &mime, error);
#endif
  g_object_unref(file);
  return image;
}

static gboolean save_xcf(Gimp *gimp, GimpImage *image, const char *path, char *errbuf, size_t errsz) {
  GError *gerror = NULL;
  GFile *file = g_file_new_for_path(path);
  GimpPlugInProcedure *proc = gimp_plug_in_manager_file_procedure_find(
      gimp->plug_in_manager, GIMP_FILE_PROCEDURE_GROUP_SAVE, file, &gerror);
  if (!proc) {
    snprintf(errbuf, errsz, "no save proc: %s", gerror ? gerror->message : "unknown");
    g_clear_error(&gerror); g_object_unref(file); return FALSE;
  }
  GimpPDBStatusType status = file_save(gimp, image, NULL, file, proc, GIMP_RUN_NONINTERACTIVE,
                                       TRUE, FALSE, FALSE, &gerror);
  if (status != GIMP_PDB_SUCCESS) {
    snprintf(errbuf, errsz, "save status=%d error=%s", (int)status, gerror ? gerror->message : "none");
    g_clear_error(&gerror); g_object_unref(file); return FALSE;
  }
  g_clear_error(&gerror);
  g_object_unref(file);
  errbuf[0] = '\0';
  return TRUE;
}

static gboolean check_float_specials(const guint8 seed[PLANES][PIXELS * 4]) {
  /* verify seeded literal bits are present in our source buffer for required specials */
  const guint8 *A = seed[1], *B = seed[2], *L = seed[0];
  gboolean ok = TRUE;
  if (sample_bits(A, 2) != f32_bits(-1.f)) ok = FALSE;
  if (sample_bits(A, 3) != 0x80000000u) ok = FALSE; /* -0 */
  if (sample_bits(A, 4) != 0x00000000u) ok = FALSE; /* +0 */
  if (sample_bits(A, 8) != 0x00000001u) ok = FALSE;
  if (sample_bits(A, 9) != 0x80000001u) ok = FALSE;
  if (sample_bits(A, 10) != f32_bits(FLT_MAX)) ok = FALSE;
  if (sample_bits(A, 11) != f32_bits(-FLT_MAX)) ok = FALSE;
  if (sample_bits(B, 8) != f32_bits(-FLT_MAX)) ok = FALSE;
  if (sample_bits(B, 9) != f32_bits(FLT_MAX)) ok = FALSE;
  if (sample_bits(B, 10) != 0x00000001u) ok = FALSE;
  if (sample_bits(B, 11) != 0x80000001u) ok = FALSE;
  if (sample_bits(L, 6) != f32_bits(128.0f/255.0f)) ok = FALSE;
  return ok;
}

static GlimsStatus run_case(GlimsEngine *engine, gpointer data) {
  Case *c = (Case *)data;
  g_precision_name = c->precision_name;
  char errbuf[512] = {0};
  guint8 seed[PLANES][PIXELS * 4], after[PLANES][PIXELS * 4], got[PLANES][PIXELS * 4];
  guint8 got_dup[PLANES][PIXELS * 4], got_reopen[PLANES][PIXELS * 4];
  memset(seed,0,sizeof seed); memset(after,0,sizeof after);

  if (c->sample_size == 1) fill_seed_u8(seed);
  else if (c->sample_size == 2) fill_seed_u16(seed);
  else fill_seed_float(seed);

  set_stage("seed-controls");
  if (c->sample_size == 1) {
    CHECK(seed[1][0] == 128, "literal U8 neutral control is 128");
    printf("CONTROL U8 neutral=%u\n", (unsigned)seed[1][0]);
  } else if (c->sample_size == 2) {
    guint16 neutral; memcpy(&neutral, seed[1], sizeof neutral);
    CHECK(neutral == 32896, "literal U16 neutral control is 32896");
    printf("CONTROL U16 neutral=%u bits=0x%04x\n", (unsigned)neutral, (unsigned)neutral);
  } else {
    gboolean finite = TRUE;
    for (unsigned p=0; p<PLANES; p++) for (unsigned i=0; i<PIXELS; i++) {
      float value; memcpy(&value, seed[p] + i*4, 4); finite &= isfinite(value);
    }
    CHECK(finite, "all physical and control float samples are finite");
    CHECK(sample_bits(seed[0], 6) == 0x3f008081u, "normalized neutral128/255 has literal binary32 control bits");
    printf("CONTROL FLOAT neutral=0x%08x minuszero=0x%08x pluszero=0x%08x subnormal=0x%08x negative_subnormal=0x%08x max=0x%08x negative_max=0x%08x\n",
      sample_bits(seed[0],6), sample_bits(seed[1],3), sample_bits(seed[1],4), sample_bits(seed[1],8), sample_bits(seed[1],9), sample_bits(seed[1],10), sample_bits(seed[1],11));
  }
  set_stage("create");
  CHECK(g_hash_table_size(engine->images) == 0, "no private image admitted into facade registry");
  GimpImage *image = gimp_create_image(engine->gimp, W, H, GIMP_GRAY, c->precision, FALSE);
  CHECK(image != NULL, "create private GRAY image");
  if (!image) return GLIMS_STATUS_FAILED;

  GimpChannel *planes[PLANES] = {NULL, NULL, NULL};
  static const char *names[PLANES] = {"L", "a", "b"};
  gimp_image_undo_disable(image);
  for (unsigned p = 0; p < PLANES; p++) {
    GeglColor *color = gegl_color_new("black");
    planes[p] = gimp_channel_new(image, W, H, names[p], color);
    g_object_unref(color);
    CHECK(planes[p] != NULL, "create raw channel");
    if (!planes[p]) { g_object_unref(image); return GLIMS_STATUS_FAILED; }
    if (!gimp_image_add_channel(image, planes[p], NULL, p, FALSE)) {
      CHECK(FALSE, "attach raw channel");
      g_object_unref(planes[p]); g_object_unref(image); return GLIMS_STATUS_FAILED;
    }
    gimp_item_set_visible(GIMP_ITEM(planes[p]), FALSE, FALSE);
  }
  CHECK(gimp_container_get_n_children(gimp_image_get_layers(image)) == 0, "no layers");

  set_stage("format");
  const Babl *expected = c->expected_format;
  for (unsigned p = 0; p < PLANES; p++) {
    const Babl *fmt = gimp_drawable_get_format(GIMP_DRAWABLE(planes[p]));
    char msg[128];
    snprintf(msg, sizeof msg, "plane %s actual format == expected scalar format (%s)", names[p], format_name(expected));
    CHECK(fmt == expected, msg);
    if (fmt != expected) {
      printf("  format detail: expected=%s actual=%s\n", format_name(expected), format_name(fmt));
    }
    CHECK(babl_format_get_bytes_per_pixel(fmt) == (int)c->sample_size, "bytes per pixel");
    CHECK(babl_format_get_n_components(fmt) == 1, "scalar components == 1");
  }

  set_stage("seed-write");
  for (unsigned p = 0; p < PLANES; p++) write_plane(planes[p], expected, seed[p]);
  if (c->sample_size == 4) CHECK(check_float_specials(seed), "seed contains required exact float bit patterns");

  set_stage("raw-get");
  read_planes(image, planes, expected, c->sample_size * PIXELS, got);
  compare_all(seed, got, c->sample_size * PIXELS, c->sample_size, "initial raw get matches seed");

  set_stage("set-get-stability");
  for (unsigned p = 0; p < PLANES; p++) write_plane(planes[p], expected, seed[p]);
  read_planes(image, planes, expected, c->sample_size * PIXELS, got);
  compare_all(seed, got, c->sample_size * PIXELS, c->sample_size, "raw set/get stable");

  set_stage("undo-redo");
  gimp_image_undo_enable(image);
  gimp_image_undo_free(image);
  CHECK(gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image)) == 0, "initial native Undo stack empty");
  derive_after(seed, after, c->sample_size * PIXELS, c->sample_size, 1);
  gimp_drawable_push_undo(GIMP_DRAWABLE(planes[1]), "Lab storage edit", NULL, 0, 0, W, H);
  /* manual bytes expected */
  write_plane(planes[1], expected, after[1]);
  read_planes(image, planes, expected, c->sample_size * PIXELS, got);
  CHECK(memcmp(got[1], after[1], c->sample_size * PIXELS) == 0, "edited channel has after bytes");
  CHECK(memcmp(got[0], seed[0], c->sample_size * PIXELS) == 0, "unedited L unchanged after edit");
  CHECK(memcmp(got[2], seed[2], c->sample_size * PIXELS) == 0, "unedited b unchanged after edit");
  CHECK(gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image)) == 1, "one native drawable Undo record");
  gboolean undone = gimp_image_undo(image);
  CHECK(undone, "native undo returns true");
  read_planes(image, planes, expected, c->sample_size * PIXELS, got);
  compare_all(seed, got, c->sample_size * PIXELS, c->sample_size, "undo restores exact all planes");
  gboolean redone = gimp_image_redo(image);
  CHECK(redone, "native redo returns true");
  read_planes(image, planes, expected, c->sample_size * PIXELS, got);
  compare_all(after, got, c->sample_size * PIXELS, c->sample_size, "redo restores exact all planes");

  set_stage("duplicate");
  GimpImage *dup = gimp_image_duplicate(image);
  CHECK(dup != NULL, "native duplicate created");
  if (dup) {
    GList *chs = gimp_image_get_channel_list(dup);
    int n = g_list_length(chs);
    CHECK(n == PLANES, "duplicate has 3 channels");
    /* match by name in case list order differs */
    GimpChannel *dplanes[PLANES] = {NULL,NULL,NULL};
    for (GList *it = chs; it; it = it->next) {
      const char *nm = gimp_object_get_name(it->data);
      for (unsigned p=0;p<PLANES;p++) if (nm && strcmp(nm,names[p])==0) dplanes[p] = GIMP_CHANNEL(it->data);
    }
    g_list_free(chs);
    gboolean have = dplanes[0] && dplanes[1] && dplanes[2];
    CHECK(have, "duplicate channels found by name L,a,b");
    if (have) {
      read_planes(dup, dplanes, expected, c->sample_size * PIXELS, got_dup);
      compare_all(after, got_dup, c->sample_size * PIXELS, c->sample_size, "duplicate exact all planes");
    }
    g_object_unref(dup);
  }

  set_stage("xcf-save");
  snprintf(c->xcf_path, sizeof c->xcf_path, "%s/lab-%s.xcf", c->work, c->precision_name);
  gboolean saved = save_xcf(engine->gimp, image, c->xcf_path, errbuf, sizeof errbuf);
  if (!saved) printf("  save detail [%s/%s]: %s\n", g_precision_name, g_stage, errbuf);
  CHECK(saved, "native XCF save");
  gint orig_ids[PLANES];
  gint orig_image_id = gimp_image_get_id(image);
  for (unsigned p=0;p<PLANES;p++) orig_ids[p] = gimp_item_get_id(GIMP_ITEM(planes[p]));

  set_stage("xcf-close-original");
  /* close original: unref and null pointer; must not compare original after load */
  GimpImage *closed_observer = image;
  g_object_add_weak_pointer(G_OBJECT(image), (gpointer *)&closed_observer);
  g_object_unref(image);
  image = NULL;
  CHECK(closed_observer == NULL, "original private image finalized before reopen");
  if (closed_observer) g_object_remove_weak_pointer(G_OBJECT(closed_observer), (gpointer *)&closed_observer);
  planes[0]=planes[1]=planes[2]=NULL;

  set_stage("xcf-reopen");
  GError *gerror = NULL;
  GimpImage *reopened = NULL;
  GimpPDBStatusType load_status = GIMP_PDB_EXECUTION_ERROR;
  if (saved) reopened = open_xcf(engine->gimp, c->xcf_path, &load_status, &gerror);
  printf("  reopen status=%d\n", (int)load_status);
  if (!reopened) {
    printf("  reopen detail [%s/%s]: status/error=%s\n", g_precision_name, g_stage,
           gerror ? gerror->message : "null image");
  }
  CHECK(reopened != NULL && load_status == GIMP_PDB_SUCCESS, "native XCF reopen");
  g_clear_error(&gerror);

  if (reopened) {
    gint new_image_id = gimp_image_get_id(reopened);
    CHECK(new_image_id != orig_image_id, "reopened image id differs from original");
    CHECK(gimp_container_get_n_children(gimp_image_get_layers(reopened)) == 0, "reopened has no layers");
    CHECK((gint)gimp_image_get_width(reopened) == W && (gint)gimp_image_get_height(reopened) == H, "reopened dimensions");
    CHECK(gimp_image_get_precision(reopened) == c->precision, "reopened precision");

    GList *chs = gimp_image_get_channel_list(reopened);
    int n = g_list_length(chs);
    CHECK(n == PLANES, "reopened has 3 channels");
    GimpChannel *rplanes[PLANES] = {NULL,NULL,NULL};
    for (GList *it = chs; it; it = it->next) {
      const char *nm = gimp_object_get_name(it->data);
      for (unsigned p=0;p<PLANES;p++) if (nm && strcmp(nm,names[p])==0) rplanes[p] = GIMP_CHANNEL(it->data);
    }
    g_list_free(chs);
    gboolean have = rplanes[0] && rplanes[1] && rplanes[2];
    CHECK(have, "reopened channels found by name L,a,b");
    if (have) {
      for (unsigned p=0;p<PLANES;p++) {
        gint rid = gimp_item_get_id(GIMP_ITEM(rplanes[p]));
        gboolean fresh = TRUE;
        for (unsigned original = 0; original < PLANES; original++) fresh &= rid != orig_ids[original];
        CHECK(fresh, "reopened channel id differs from every original channel");
      }
      for (unsigned p=0;p<PLANES;p++) {
        const Babl *fmt = gimp_drawable_get_format(GIMP_DRAWABLE(rplanes[p]));
        CHECK(fmt == expected, "reopened channel format == expected");
      }
      read_planes(reopened, rplanes, expected, c->sample_size * PIXELS, got_reopen);
      /* compare against expected state at save time: after undo/redo sequence ended at 'after' */
      compare_all(after, got_reopen, c->sample_size * PIXELS, c->sample_size, "reopened exact all planes/bytes vs expected");
      const char *rn0 = gimp_object_get_name(GIMP_OBJECT(rplanes[0]));
      const char *rn1 = gimp_object_get_name(GIMP_OBJECT(rplanes[1]));
      const char *rn2 = gimp_object_get_name(GIMP_OBJECT(rplanes[2]));
      CHECK(rn0 && strcmp(rn0,"L")==0, "reopened name L");
      CHECK(rn1 && strcmp(rn1,"a")==0, "reopened name a");
      CHECK(rn2 && strcmp(rn2,"b")==0, "reopened name b");
    }
    g_object_unref(reopened);
  }

  CHECK(g_hash_table_size(engine->images) == 0, "facade registry remains empty after private image disposal");
  return failures_total ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: %s PRIVATE_WORK\n", argv[0]); return 2; }
  const char *work = argv[1];
  api = glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api) { fprintf(stderr, "engine api unavailable\n"); return 2; }

  gchar *user = g_build_filename(work, "user", NULL);
  gchar *cache = g_build_filename(work, "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus status = api->start(&config, &engine, &error);
  g_free(user); g_free(cache);
  if (status != GLIMS_STATUS_OK || !engine) {
    fprintf(stderr, "engine start failed: %s\n", error ? error : "unknown");
    api->free_string(error);
    return 2;
  }
  api->free_string(error);

  Case cases[] = {
    {work, GIMP_PRECISION_U8_LINEAR,    "U8_LINEAR",    babl_format("Y u8"),    1, ""},
    {work, GIMP_PRECISION_U16_LINEAR,   "U16_LINEAR",   babl_format("Y u16"),   2, ""},
    {work, GIMP_PRECISION_FLOAT_LINEAR, "FLOAT_LINEAR", babl_format("Y float"), 4, ""},
  };
  for (unsigned i = 0; i < G_N_ELEMENTS(cases); i++) {
    printf("CASE %s\n", cases[i].precision_name); fflush(stdout);
    GlimsStatus rc = glims_engine_call(engine, run_case, &cases[i]);
    if (rc != GLIMS_STATUS_OK) {
      failures_total++;
      printf("CASE_RESULT %s callback_status=%d\n", cases[i].precision_name, (int)rc);
    } else {
      printf("CASE_RESULT %s callback_status=OK\n", cases[i].precision_name);
    }
  }

  api->stop(engine);
  printf("checks=%u failures=%u\n", checks_total, failures_total);
  return failures_total ? 1 : 0;
}

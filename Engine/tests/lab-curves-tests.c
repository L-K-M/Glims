#include "lab-curves.h"

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned g_checks = 0;
static unsigned g_failures = 0;

#define CHECK(cond) do { \
  g_checks++; \
  if (!(cond)) { \
    g_failures++; \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
  } \
} while (0)

static uint32_t f32_bits(float f) { uint32_t u; memcpy(&u, &f, sizeof(u)); return u; }
static float bits_f32(uint32_t u) { float f; memcpy(&f, &u, sizeof(f)); return f; }

static void make_identity(GlimsLabCurve *c)
{
  for (int i = 0; i < 256; i++) c->samples[i] = (double)i / 255.0;
}

static void test_identity_exhaustive_integer(void)
{
  GlimsLabCurve id; make_identity(&id);
  /* U8 exhaustive */
  {
    GlimsLabRole roles[3] = {GLIMS_LAB_ROLE_L, GLIMS_LAB_ROLE_A, GLIMS_LAB_ROLE_B};
    for (int r = 0; r < 3; r++) {
      for (int q = 0; q < 256; q++) {
        uint8_t src[1] = {(uint8_t)q};
        uint8_t dst[1] = {0xA5};
        bool changed = true;
        CHECK(glims_lab_curves_row(roles[r], GLIMS_LAB_FORMAT_U8, &id, 1, src, NULL, dst, &changed));
        CHECK(dst[0] == (uint8_t)q);
        CHECK(!changed);
      }
    }
  }
  /* Every U16 encoding, across all three roles and fractional masks. */
  for (int role = 0; role < 3; role++) {
    uint16_t source[4096], destination[4096];
    float masks[4096];
    for (unsigned first = 0; first < 65536; first += 4096) {
      for (unsigned i = 0; i < 4096; i++) {
        source[i] = (uint16_t)(first + i);
        masks[i] = (float)(i % 5) / 4;
      }
      memset(destination, 0xA5, sizeof destination);
      bool changed = true;
      CHECK(glims_lab_curves_row((GlimsLabRole)role, GLIMS_LAB_FORMAT_U16,
          &id, 4096, source, masks, destination, &changed));
      CHECK(memcmp(source, destination, sizeof source) == 0);
      CHECK(!changed);
    }
  }
}

static void test_constant_curves(void)
{
  /* all0 and all1 */
  {
    GlimsLabCurve all0; for (int i=0;i<256;i++) all0.samples[i] = 0.0;
    GlimsLabCurve all1; for (int i=0;i<256;i++) all1.samples[i] = 1.0;
    /* The upper normalized endpoint means physical L=100. */
    float src[1] = {50.0f}; /* L=50 */
    float dst[1] = {0};
    bool changed = false;
    CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &all1, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 100.0f && changed);
    CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &all0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 0.0f && changed);
    /* chroma */
    float srca[1] = {0.0f}; /* a = 0 means normalized (0+128)/255 ~ 0.501... */
    memset(&dst, 0, sizeof(dst));
    changed = false;
    CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, &all1, 1, srca, NULL, dst, &changed));
    CHECK(dst[0] == 127.0f && changed);
    CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, &all0, 1, srca, NULL, dst, &changed));
    CHECK(dst[0] == -128.0f && changed);
  }
}

static void test_l50_chroma_half_output(void)
{
  /* L50/chroma-0.5 at half output - construct curve that gives 0.5 normalized output */
  GlimsLabCurve c; for (int i=0;i<256;i++) c.samples[i] = 0.5; /* constant 0.5 */
  /* L50 input: normalized 0.5, maps to L = 100*0.5 = 50 */
  float src[1] = {50.0f};
  float dst[1] = {0};
  bool changed = false;
  CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &c, 1, src, NULL, dst, &changed));
  CHECK(dst[0] == 50.0f && !changed);
  /* chroma -0.5: physical -0.5, normalized (-0.5+128)/255 = 127.5/255 = 0.5, maps to 255*0.5-128 = -0.5 */
  float srca[1] = {-0.5f};
  memset(dst, 0, sizeof(float));
  changed = true;
  CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, &c, 1, srca, NULL, dst, &changed));
  /* target == source means preserve original bytes */
  CHECK(fabs(dst[0] - (-0.5f)) < 1e-10 || dst[0] == -0.5f);
}


static void test_coverage_half_zero(void)
{
  GlimsLabCurve all1; for (int i=0;i<256;i++) all1.samples[i] = 1.0;
  /* coverage half */
  uint8_t src[1] = {0}; /* L 0 */
  uint8_t dst[1] = {5};
  float mask[1] = {0.5f};
  bool changed = false;
  CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &all1, 1, src, mask, dst, &changed));
  /* blend: weight 0.5, target is L100 (normalized 1.0 -> 100), source decoded L is 0. result = fma(0.5,100,0.5*0)=50, encode gives 128 for L */
  CHECK(dst[0] == 128 && changed);
  /* coverage zero copies raw bytes */
  uint8_t src2[1] = {10};
  uint8_t dst2[1] = {99};
  float mask0[1] = {0.0f};
  changed = true;
  CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &all1, 1, src2, mask0, dst2, &changed));
  CHECK(dst2[0] == 10 && !changed);
}

static void test_floating_extended_minus0_late_nan(void)
{
  GlimsLabCurve id; make_identity(&id);
  GlimsLabCurve all1; for (int i=0;i<256;i++) all1.samples[i] = 1.0;
  /* extended float */
  {
    float src[1] = {1.0e30f};
    float dst[1] = {0};
    bool changed = false;
    CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &all1, 1, src, NULL, dst, &changed));
    CHECK(isfinite(dst[0]) && changed);
  }
  /* -0 with identity preserves raw encoding including -0 */
  {
    float src[1] = {bits_f32(0x80000000u)}; /* -0 */
    float dst[1] = {1.0f};
    bool changed = false;
    CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, &id, 1, src, NULL, dst, &changed));
    CHECK(f32_bits(dst[0]) == 0x80000000u && !changed);
  }
  /* late NaN - reject nonfinite affected float even identity */
  {
    float dst2[3] = {bits_f32(0x11111111u), bits_f32(0x22222222u), bits_f32(0x33333333u)};
    float saved[3]; memcpy(saved, dst2, sizeof(saved));
    float src2[3] = {0.0f, 0.0f, bits_f32(0x7FC00000u)};
    bool changed = true;
    CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &id, 3, src2, NULL, dst2, &changed));
    CHECK(memcmp(dst2, saved, sizeof(saved)) == 0);
    CHECK(!changed);
  }
}

static void test_unaligned_inplace(void)
{
  /* unaligned */
  {
    unsigned char src_buf[64], dst_buf[64], mask_buf[64];
    memset(src_buf, 0, sizeof(src_buf));
    memset(dst_buf, 0xA5, sizeof(dst_buf));
    memset(mask_buf, 0, sizeof(mask_buf));
    uint8_t *src = (uint8_t *)(src_buf + 1);
    uint8_t *dst = (uint8_t *)(dst_buf + 3);
    const float *mask = (const float *)(const void *)(mask_buf + 1);
    GlimsLabCurve all1; for (int i=0;i<256;i++) all1.samples[i] = 1.0;
    src[0] = 0;
    const float m = 1.0f;
    memcpy(mask_buf + 1, &m, sizeof(m));
    bool changed = false;
    CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &all1, 1, src, mask, dst, &changed));
    CHECK(dst[0] == 255 && changed);
  }
  /* inplace */
  {
    GlimsLabCurve all1; for (int i=0;i<256;i++) all1.samples[i] = 1.0;
    uint8_t row[4] = {0, 64, 128, 255};
    bool changed = false;
    CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &all1, 4, row, NULL, row, &changed));
    CHECK(row[0]==255 && row[1]==255 && row[2]==255 && row[3]==255 && changed);
  }
}

static void test_alias_canaries_badlastmask(void)
{
  GlimsLabCurve id; make_identity(&id);
  /* bad last mask */
  {
    float src[3] = {0,0,0};
    float dst[3] = {1,2,3};
    float saved[3]; memcpy(saved, dst, sizeof(saved));
    float mask[3] = {1.0f,1.0f,NAN};
    bool changed = true;
    CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &id, 3, src, mask, dst, &changed));
    CHECK(memcmp(dst,saved,sizeof(saved))==0);
    CHECK(!changed);
  }
  /* overlaps/canaries - mask overlaps source refused */
  {
    unsigned char src[16], dst[16];
    memset(src, 128, sizeof(src));
    memset(dst, 0xCC, sizeof(dst));
    bool changed = true;
    CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &id, 2, src, (const float *)src, dst, &changed));
    CHECK(!changed);
  }
  /* curve overlaps refused */
  {
    unsigned char src[4]={0}, dst[4]={1};
    GlimsLabCurve c; make_identity(&c);
    bool *bad = (bool *)(void *)&c;
    CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &c, 1, src, NULL, dst, bad));
  }
  /* count 0 permits NULLs */
  {
    GlimsLabCurve id2; make_identity(&id2);
    bool changed = true;
    CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &id2, 0, NULL, NULL, NULL, &changed));
    CHECK(!changed);
  }
}

static void test_u16_fraction_golden_independent(void)
{
  /* Fraction oracle uses exact fused products and final rational quantization.
   * The q=258/357 cases distinguish fractional indexing from U8 quantization. */
  const uint16_t inputs[] = {1, 128, 256, 257, 258, 357, 513, 514, 515, 65534};
  const uint16_t full[] = {64, 8160, 16320, 16384, 16511, 29134, 49024, 49151, 49215, 65535};
  const uint16_t half_l[] = {32, 4144, 8288, 8320, 8385, 14745, 24768, 24833, 24865, 65535};
  const uint16_t half_ab[] = {32, 4144, 8288, 8320, 8385, 14745, 24768, 24833, 24865, 65534};
  GlimsLabCurve curve;
  for (unsigned i = 0; i < 256; i++) curve.samples[i] = 1;
  curve.samples[0] = 0; curve.samples[1] = .25; curve.samples[2] = .75;
  for (int role = 0; role < 3; role++) {
    uint16_t destination[10];
    float masks[10];
    for (unsigned i = 0; i < 10; i++) masks[i] = .5f;
    bool changed = false;
    CHECK(glims_lab_curves_row((GlimsLabRole)role, GLIMS_LAB_FORMAT_U16,
        &curve, 10, inputs, NULL, destination, &changed));
    CHECK(changed && memcmp(full, destination, sizeof full) == 0);
    CHECK(glims_lab_curves_row((GlimsLabRole)role, GLIMS_LAB_FORMAT_U16,
        &curve, 10, inputs, masks, destination, &changed));
    CHECK(changed && memcmp(role == 0 ? half_l : half_ab, destination, sizeof full) == 0);
  }
}

static void test_invalid_argument_aliases(void)
{
  GlimsLabCurve curve, saved;
  make_identity(&curve);
  curve.samples[0] = .1;
  saved = curve;
  unsigned char source[4] = {255, 255, 255, 255};
  unsigned char destination[4] = {7, 7, 7, 7};
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, (GlimsLabFormat)-1,
      &curve, 1, source, NULL, destination, (bool *)(void *)&curve));
  CHECK(memcmp(&curve, &saved, sizeof curve) == 0);
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      NULL, 4, source, NULL, destination, (bool *)(void *)(source + 1)));
  CHECK(source[1] == 255);
}

static void test_unaligned_curve(void)
{
  GlimsLabCurve curve;
  for (int i = 0; i < 256; i++) curve.samples[i] = 1;
  _Alignas(GlimsLabCurve) unsigned char storage[sizeof curve + 1];
  memcpy(storage + 1, &curve, sizeof curve);
  unsigned char source = 0, destination = 9;
  bool changed = false;
  CHECK(glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      (const GlimsLabCurve *)(const void *)(storage + 1), 1,
      &source, NULL, &destination, &changed));
  CHECK(destination == 255 && changed);
}

static void test_refusal_and_atomicity(void)
{
  GlimsLabCurve curve;
  make_identity(&curve);
  unsigned char source[32], destination[32], saved[32];
  memset(source, 0x88, sizeof source);
  memset(saved, 0x77, sizeof saved);
  memcpy(destination, saved, sizeof saved);
  bool changed = true;
  CHECK(!glims_lab_curves_row((GlimsLabRole)-1, GLIMS_LAB_FORMAT_U8,
      &curve, 4, source, NULL, destination, &changed));
  CHECK(!changed && memcmp(saved, destination, sizeof saved) == 0);
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      &curve, 4097, source, NULL, destination, &changed));
  CHECK(!changed && memcmp(saved, destination, sizeof saved) == 0);
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      &curve, 4, source, NULL, destination, NULL));
  CHECK(memcmp(saved, destination, sizeof saved) == 0);

  const double invalid[] = {NAN, INFINITY, -.01, 1.01};
  for (unsigned i = 0; i < sizeof invalid / sizeof *invalid; i++) {
    curve.samples[255] = invalid[i];
    changed = true;
    CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
        &curve, 4, source, NULL, destination, &changed));
    CHECK(!changed && memcmp(saved, destination, sizeof saved) == 0);
    changed = true;
    CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
        &curve, 0, NULL, NULL, NULL, &changed));
    CHECK(!changed);
  }
  make_identity(&curve);
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      (const GlimsLabCurve *)(UINTPTR_MAX - 3), 0, NULL, NULL, NULL, &changed));
  CHECK(!changed);

  /* Exact in-place is accepted; each direction of partial overlap refuses. */
  unsigned char snapshot[32];
  memcpy(snapshot, source, sizeof source);
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16,
      &curve, 4, source, NULL, source + 1, &changed));
  CHECK(memcmp(snapshot, source, sizeof source) == 0);
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16,
      &curve, 4, source + 1, NULL, source, &changed));
  CHECK(memcmp(snapshot, source, sizeof source) == 0);
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      &curve, 4, source, (const float *)(const void *)(destination + 1), destination, &changed));
  CHECK(memcmp(saved, destination, sizeof saved) == 0);
  GlimsLabCurve original = curve;
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      &curve, 4, source, NULL, (unsigned char *)&curve + 1, &changed));
  CHECK(memcmp(&curve, &original, sizeof curve) == 0);
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      &curve, 4, (unsigned char *)&curve + 1, NULL, destination, &changed));
  CHECK(memcmp(saved, destination, sizeof saved) == 0);
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      &curve, 4, source, (const float *)(const void *)&curve, destination, &changed));
  CHECK(memcmp(saved, destination, sizeof saved) == 0);

  /* A late invalid mask must not modify even an in-place row. */
  float masks[] = {1, 1, 1, INFINITY};
  CHECK(!glims_lab_curves_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8,
      &curve, 4, source, masks, source, &changed));
  CHECK(!changed && memcmp(source, snapshot, sizeof source) == 0);
}

static void test_float_preservation(void)
{
  const uint32_t bits[] = {0x80000000u, 0x00000001u, 0x7f7fffffu,
                          0xff7fffffu, 0x7fc01234u, 0x7f800000u, 0xff800000u};
  float zero[7] = {0}, fractional[7] = {.1f, .5f, .25f, .75f, 0, 0, 0};
  GlimsLabCurve curve;
  make_identity(&curve);
  for (int role = 0; role < 3; role++) {
    uint32_t output[7];
    bool changed = true;
    CHECK(glims_lab_curves_row((GlimsLabRole)role, GLIMS_LAB_FORMAT_FLOAT,
        &curve, 7, bits, zero, output, &changed));
    CHECK(!changed && memcmp(bits, output, sizeof bits) == 0);
    CHECK(glims_lab_curves_row((GlimsLabRole)role, GLIMS_LAB_FORMAT_FLOAT,
        &curve, 7, bits, fractional, output, &changed));
    CHECK(!changed && memcmp(bits, output, sizeof bits) == 0);
  }
}

int main(void)
{
  test_refusal_and_atomicity();
  test_float_preservation();
  test_invalid_argument_aliases();
  test_unaligned_curve();
  test_identity_exhaustive_integer();
  test_constant_curves();
  test_l50_chroma_half_output();
  test_coverage_half_zero();
  test_floating_extended_minus0_late_nan();
  test_unaligned_inplace();
  test_alias_canaries_badlastmask();
  test_u16_fraction_golden_independent();
  printf("Lab curves: %u checks, %u failures\n", g_checks, g_failures);
  return g_failures ? 1 : 0;
}

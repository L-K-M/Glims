#include "lab-samples.h"

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

static uint32_t f32_bits(float f)
{
  uint32_t u;
  memcpy(&u, &f, sizeof(u));
  return u;
}

static float bits_f32(uint32_t u)
{
  float f;
  memcpy(&f, &u, sizeof(f));
  return f;
}

static uint64_t f64_bits(double d)
{
  uint64_t u;
  memcpy(&u, &d, sizeof(u));
  return u;
}

static double bits_f64(uint64_t u)
{
  double d;
  memcpy(&d, &u, sizeof(d));
  return d;
}

static bool is_neg_zero_d(double d)
{
  return f64_bits(d) == UINT64_C(0x8000000000000000);
}


static void test_exhaustive_u8(void)
{
  GlimsLabRole roles[3] = {GLIMS_LAB_ROLE_L, GLIMS_LAB_ROLE_A, GLIMS_LAB_ROLE_B};
  for (int r = 0; r < 3; r++) {
    for (int q = 0; q < 256; q++) {
      uint8_t in = (uint8_t)q;
      double phys = 0.0;
      CHECK(glims_lab_decode_row(roles[r], GLIMS_LAB_FORMAT_U8, 1, &in, &phys));
      uint8_t out = 0xA5;
      CHECK(glims_lab_encode_row(roles[r], GLIMS_LAB_FORMAT_U8, 1, &phys, &out));
      CHECK(out == in);
    }
  }
}

static void test_exhaustive_u16(void)
{
  GlimsLabRole roles[3] = {GLIMS_LAB_ROLE_L, GLIMS_LAB_ROLE_A, GLIMS_LAB_ROLE_B};
  for (int r = 0; r < 3; r++) {
    for (int q = 0; q < 65536; q++) {
      uint16_t in = (uint16_t)q;
      double phys = 0.0;
      CHECK(glims_lab_decode_row(roles[r], GLIMS_LAB_FORMAT_U16, 1, &in, &phys));
      uint16_t out = 0xA5A5u;
      CHECK(glims_lab_encode_row(roles[r], GLIMS_LAB_FORMAT_U16, 1, &phys, &out));
      CHECK(out == in);
    }
  }
}

static void test_v4_literals(void)
{
  /* U16 chroma ICC v4: neutral 32896 -> 0, 0 -> -128, 65535 -> 127 */
  uint16_t in;
  double v;
  in = 32896; CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, 1, &in, &v)); CHECK(v == 0.0);
  in = 0;     CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, 1, &in, &v)); CHECK(v == -128.0);
  in = 65535; CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, 1, &in, &v)); CHECK(v == 127.0);
  in = 32896; CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_U16, 1, &in, &v)); CHECK(v == 0.0);
  /* U16 L extrema */
  in = 0;     CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 1, &in, &v)); CHECK(v == 0.0);
  in = 65535; CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 1, &in, &v)); CHECK(v == 100.0);
  /* U8 */
  uint8_t b;
  b = 0;   CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 1, &b, &v)); CHECK(v == 0.0);
  b = 255; CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 1, &b, &v)); CHECK(v == 100.0);
  b = 128; CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 1, &b, &v)); CHECK(v == 0.0);
  b = 0;   CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 1, &b, &v)); CHECK(v == -128.0);
  b = 255; CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 1, &b, &v)); CHECK(v == 127.0);
}

static void test_half_ties_and_neighbors(void)
{
  /* Half-integer physical chroma is exact in binary64 for both formats. */
  for (int role = GLIMS_LAB_ROLE_A; role <= GLIMS_LAB_ROLE_B; role++) {
    for (unsigned q = 0; q < 255; q++) {
      double mid = (double)q - 127.5;
      double values[3] = {nextafter(mid, -INFINITY), mid, nextafter(mid, INFINITY)};
      uint8_t bytes[3]; uint16_t words[3];
      CHECK(glims_lab_encode_row((GlimsLabRole)role, GLIMS_LAB_FORMAT_U8, 3, values, bytes));
      CHECK(bytes[0] == q && bytes[1] == q + 1 && bytes[2] == q + 1);
      CHECK(glims_lab_encode_row((GlimsLabRole)role, GLIMS_LAB_FORMAT_U16, 3, values, words));
      CHECK(words[0] == q * 257 + 128 && words[1] == q * 257 + 129 && words[2] == q * 257 + 129);
    }
  }
  double lightness[3] = {nextafter(50.0, -INFINITY), 50.0, nextafter(50.0, INFINITY)};
  uint8_t bytes[3]; uint16_t words[3];
  CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 3, lightness, bytes));
  CHECK(bytes[0] == 127 && bytes[1] == 128 && bytes[2] == 128);
  CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 3, lightness, words));
  CHECK(words[0] == 32767 && words[1] == 32768 && words[2] == 32768);

  /* Literals independently calculated with Python Fraction.from_float:
   * floor(x*M/100 + 1/2), or floor((x+128)*(M/255) + 1/2).
   * A nearest-double representation of a rational midpoint is not generally
   * an exact tie. These goldens deliberately distinguish the two. */
  const struct { GlimsLabRole role; GlimsLabFormat format; double value; unsigned expected; } gold[] = {
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.9191919191918p-3, 0},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.9191919191919p-3, 0},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.919191919191ap-3, 1},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.2d2d2d2d2d2d2p-1, 1},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.2d2d2d2d2d2d3p-1, 2},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.2d2d2d2d2d2d4p-1, 2},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.8f37373737372p+6, 254},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.8f37373737373p+6, 254},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.8f37373737374p+6, 255},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.8ffffffffffffp+5, 127},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.9000000000000p+5, 128},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0x1.9000000000001p+5, 128},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.9001900190018p-11, 0},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.9001900190019p-11, 0},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.900190019001ap-11, 1},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.2c012c012c012p-9, 1},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.2c012c012c013p-9, 2},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.2c012c012c014p-9, 2},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.8fff37ff37ff2p+6, 65534},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.8fff37ff37ff3p+6, 65534},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.8fff37ff37ff4p+6, 65535},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.8ffe6ffe6ffe6p+4, 16383},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.8ffe6ffe6ffe7p+4, 16384},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.8ffe6ffe6ffe8p+4, 16384},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.8ffffffffffffp+5, 32767},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.9000000000000p+5, 32768},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.9000000000001p+5, 32768},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.91900190018ffp+5, 32895},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.9190019001900p+5, 32895},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.9190019001901p+5, 32896},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.9193219321931p+5, 32896},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.9193219321932p+5, 32896},
    {GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0x1.9193219321933p+5, 32897},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -0x1.fe00000000001p+6, 0},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -0x1.fe00000000000p+6, 1},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -0x1.fdfffffffffffp+6, 1},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -0x1.fa00000000001p+6, 1},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -0x1.fa00000000000p+6, 2},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -0x1.f9fffffffffffp+6, 2},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 0x1.f9fffffffffffp+6, 254},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 0x1.fa00000000000p+6, 255},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 0x1.fa00000000001p+6, 255},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -0x1.0000000000001p-1, 127},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -0x1.0000000000000p-1, 128},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -0x1.fffffffffffffp-2, 128},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fffe01fe01fe1p+6, 0},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fffe01fe01fe0p+6, 1},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fffe01fe01fdfp+6, 1},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fffa05fa05fa1p+6, 1},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fffa05fa05fa0p+6, 2},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fffa05fa05f9fp+6, 2},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, 0x1.fbfe01fe01fdfp+6, 65534},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, 0x1.fbfe01fe01fe0p+6, 65534},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, 0x1.fbfe01fe01fe1p+6, 65535},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.0100ff00ff011p+6, 16383},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.0100ff00ff010p+6, 16383},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.0100ff00ff00fp+6, 16384},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.0000000000001p-1, 32767},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.0000000000000p-1, 32768},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fffffffffffffp-2, 32768},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fe01fe01fe021p-10, 32895},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fe01fe01fe020p-10, 32895},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, -0x1.fe01fe01fe01fp-10, 32896},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, 0x1.fe01fe01fe01fp-10, 32896},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, 0x1.fe01fe01fe020p-10, 32897},
    {GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U16, 0x1.fe01fe01fe021p-10, 32897},
  };
  for (size_t i = 0; i < sizeof(gold) / sizeof(gold[0]); i++) {
    unsigned char encoded[2] = {0, 0};
    CHECK(glims_lab_encode_row(gold[i].role, gold[i].format, 1, &gold[i].value, encoded));
    unsigned actual;
    if (gold[i].format == GLIMS_LAB_FORMAT_U8) actual = encoded[0];
    else { uint16_t value; memcpy(&value, encoded, sizeof(value)); actual = value; }
    CHECK(actual == gold[i].expected);
  }
}

static void test_partial_unaligned_canaries(void)
{
  for (int format = GLIMS_LAB_FORMAT_U8; format <= GLIMS_LAB_FORMAT_FLOAT; format++) {
    unsigned char input[40], encoded[40], decoded[40];
    const double physical[3] = {-128.0, 0.0, 127.0};
    memset(input, 0x35, sizeof(input)); memset(encoded, 0xA3, sizeof(encoded));
    memset(decoded, 0x59, sizeof(decoded));
    memcpy(input + 1, physical, sizeof(physical));
    unsigned char original[sizeof(input)]; memcpy(original, input, sizeof(input));
    CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_A, (GlimsLabFormat)format, 3, input + 1, encoded + 1));
    CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, (GlimsLabFormat)format, 3, encoded + 1, decoded + 1));
    double values[3]; memcpy(values, decoded + 1, sizeof(values));
    CHECK(memcmp(values, physical, sizeof(values)) == 0);
    CHECK(memcmp(input, original, sizeof(input)) == 0);
    size_t used = 3 * glims_lab_sample_size((GlimsLabFormat)format);
    for (size_t i = 0; i < sizeof(encoded); i++)
      if (i < 1 || i >= 1 + used) CHECK(encoded[i] == 0xA3);
    for (size_t i = 0; i < sizeof(decoded); i++)
      if (i < 1 || i >= 1 + sizeof(physical)) CHECK(decoded[i] == 0x59);
  }
}

static void test_zero_count_null_invalid(void)
{
  /* zero count: NULL buffers accepted only count 0 */
  CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, NULL, NULL));
  CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, NULL, NULL));

  for (int role = 0; role < 3; role++) {
    for (int format = 0; format < 3; format++) {
      CHECK(glims_lab_decode_row((GlimsLabRole)role, (GlimsLabFormat)format, 0, NULL, NULL));
      CHECK(glims_lab_encode_row((GlimsLabRole)role, (GlimsLabFormat)format, 0, NULL, NULL));
    }
  }
  CHECK(!glims_lab_decode_row((GlimsLabRole)-1, GLIMS_LAB_FORMAT_U8, 0, NULL, NULL));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, (GlimsLabFormat)-1, 0, NULL, NULL));
  CHECK(glims_lab_sample_size((GlimsLabFormat)99) == 0);

  /* invalid enums */
  double d = 0;
  uint8_t b = 0;
  CHECK(!glims_lab_decode_row((GlimsLabRole)3, GLIMS_LAB_FORMAT_U8, 1, &b, &d));
  CHECK(!glims_lab_decode_row((GlimsLabRole)-1, GLIMS_LAB_FORMAT_U8, 1, &b, &d));
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, (GlimsLabFormat)3, 1, &b, &d));
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, (GlimsLabFormat)-1, 1, &b, &d));
  CHECK(!glims_lab_encode_row((GlimsLabRole)9, GLIMS_LAB_FORMAT_U8, 1, &d, &b));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, (GlimsLabFormat)9, 1, &d, &b));

  /* NULL with nonzero */
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 1, NULL, &d));
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 1, &b, NULL));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 1, NULL, &b));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 1, &d, NULL));

  /* Address wrap must refuse before dereferencing even when count fits. */
  const void *near_end = (const void *)(UINTPTR_MAX - 2);
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 4, near_end, &d));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 4, near_end, &b));
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 1, &b, (void *)near_end));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &d, (void *)near_end));

  /* size overflow */
  uint8_t *p = (uint8_t *)0x1;
  void *dp = (void *)(uintptr_t)0x1000;
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, (SIZE_MAX / 2u) + 1u, p, dp));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, (SIZE_MAX / 2u) + 1u, dp, p));
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, (SIZE_MAX / 4u) + 1u, p, dp));
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, (SIZE_MAX / sizeof(double)) + 1u, p, dp));
}

static void test_overlap_refusal(void)
{
  /* Overlap forbidden including equal pointers */
  unsigned char buf[64];
  memset(buf, 0x5C, sizeof(buf));

  /* equal pointers: cast tricks for same address region */
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 8, buf, buf));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 8, buf, buf));

  /* partial overlap */
  uint16_t u16[8];
  for (int i = 0; i < 8; i++) u16[i] = (uint16_t)(i * 1000);
  double d8[8];
  /* decode: src 16 bytes, dst 64 bytes overlapping */
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 4, (unsigned char *)d8 + 8, d8));
  /* encode overlap */
  for (int i = 0; i < 4; i++) d8[i] = 50.0;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 4, d8, (unsigned char *)d8 + 8));

  /* verify unchanged on a refused call is not required to write, but we ensure
     it returns false; test a normal non-overlap works */
  double okd[4] = {0,0,0,0};
  CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 4, u16, okd));
}

static void test_late_bad_unchanged(void)
{
  /* decode float: late NaN must leave destination unchanged */
  float fin[4];
  fin[0] = 1.0f; fin[1] = 2.0f; fin[2] = NAN; fin[3] = 4.0f;
  double dout[4];
  for (int i = 0; i < 4; i++) dout[i] = bits_f64(UINT64_C(0x1111111111111111) * (uint64_t)(i + 1));
  double saved[4]; memcpy(saved, dout, sizeof(saved));
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 4, fin, dout));
  CHECK(memcmp(dout, saved, sizeof(saved)) == 0);

  /* encode: late bad input leaves all destination bytes unchanged */
  uint16_t u16[4] = {0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD};
  uint16_t usaved[4]; memcpy(usaved, u16, sizeof(usaved));
  double vals[4] = {50.0, 0.0, 100.0, 200.0}; /* Only the last sample is bad. */
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 4, vals, u16));
  CHECK(memcmp(u16, usaved, sizeof(usaved)) == 0);

  double vals2[4] = {0.0, 0.0, NAN, 0.0};
  uint8_t u8[4] = {1,2,3,4};
  uint8_t u8s[4]; memcpy(u8s, u8, sizeof(u8s));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 4, vals2, u8));
  CHECK(memcmp(u8, u8s, sizeof(u8s)) == 0);

  double vals3[3] = {0.0, INFINITY, 0.0};
  float fout[3];
  memset(fout, 0x77, sizeof(fout));
  float fs[3]; memcpy(fs, fout, sizeof(fs));
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 3, vals3, fout));
  CHECK(memcmp(fout, fs, sizeof(fs)) == 0);
}

static void test_float_roundtrips_and_specials(void)
{
  /* Representative finite binary32 bit patterns, including both signs and limits. */
  uint32_t samples[] = {
    0x00000000u, 0x80000000u, /* +-0 */
    0x00000001u, 0x80000001u, /* min subnormal */
    0x007FFFFFu, 0x807FFFFFu, /* max subnormal */
    0x00800000u, 0x80800000u, /* min normal FLT_MIN */
    0x7F7FFFFFu, 0xFF7FFFFFu, /* FLT_MAX */
    0x3F800000u, 0xBF800000u, /* +-1 */
    0xBF800001u, 0xC2FF0000u, /* extended negative */
    0x4B000000u, 0x7F000000u, /* large */
    0x7F7F0000u, 0xFF7F0000u
  };
  for (size_t i = 0; i < sizeof(samples)/sizeof(samples[0]); i++) {
    float f = bits_f32(samples[i]);
    if (!isfinite(f)) continue;
    double d = 0.0;
    CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &f, &d));
    float out = 0.123f;
    CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &d, &out));
    CHECK(f32_bits(out) == samples[i]);
  }

  /* Cover every finite exponent, both signs, and three mantissa patterns. */
  for (unsigned exponent = 0; exponent < 255; exponent++) {
    const uint32_t mantissas[] = {0, 0x555555, 0x7fffff};
    for (unsigned sign = 0; sign < 2; sign++) {
      for (size_t m = 0; m < 3; m++) {
        uint32_t bits = (sign << 31) | (exponent << 23) | mantissas[m];
        float value = bits_f32(bits), restored;
        double decoded;
        for (int role = 0; role < 3; role++) {
          CHECK(glims_lab_decode_row((GlimsLabRole)role, GLIMS_LAB_FORMAT_FLOAT, 1, &value, &decoded));
          CHECK(glims_lab_encode_row((GlimsLabRole)role, GLIMS_LAB_FORMAT_FLOAT, 1, &decoded, &restored));
          CHECK(f32_bits(restored) == bits);
        }
      }
    }
  }

  /* ±0 */
  float fz = 0.0f, fnz = -0.0f;
  double dz = -1.0, dnz = 1.0;
  CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, 1, &fz, &dz));
  CHECK(f64_bits(dz) == 0x0u);
  CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, 1, &fnz, &dnz));
  CHECK(is_neg_zero_d(dnz));
  float oz = 1.0f, onz = 1.0f;
  CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_FLOAT, 1, &dz, &oz));
  CHECK(f32_bits(oz) == 0x00000000u);
  CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_FLOAT, 1, &dnz, &onz));
  CHECK(f32_bits(onz) == 0x80000000u);

  /* signed chroma, extended negative and huge L/chroma via float */
  float neg = -123.5f;
  CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, 1, &neg, &dz));
  CHECK(dz == -123.5);
  float huge = 1.0e30f;
  CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &huge, &dz));
  CHECK(dz == (double)huge);

  /* FLT_MIN/MAX encode */
  float fmin = FLT_MIN, fmax = FLT_MAX;
  CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &fmin, &dz));
  CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &dz, &oz));
  CHECK(f32_bits(oz) == f32_bits(fmin));
  CHECK(glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &fmax, &dz));
  CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &dz, &oz));
  CHECK(f32_bits(oz) == f32_bits(fmax));

  /* NaN/Inf decode rejection with unchanged output */
  float badf[2] = {1.0f, NAN};
  double dd[2] = {bits_f64(UINT64_C(1)), bits_f64(UINT64_C(2))};
  double sdd[2]; memcpy(sdd, dd, sizeof(dd));
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 2, badf, dd));
  CHECK(memcmp(dd, sdd, sizeof(sdd)) == 0);
  badf[1] = INFINITY;
  memcpy(dd, sdd, sizeof(sdd));
  CHECK(!glims_lab_decode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 2, badf, dd));
  CHECK(memcmp(dd, sdd, sizeof(sdd)) == 0);

  /* encode NaN/Inf/range/overflow with unchanged output */
  float encf[2] = {1.0f, 2.0f};
  float encs[2]; memcpy(encs, encf, sizeof(encf));
  double badd = NAN;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &badd, encf));
  CHECK(memcmp(encf, encs, sizeof(encf)) == 0);
  badd = INFINITY;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &badd, encf));
  CHECK(memcmp(encf, encs, sizeof(encf)) == 0);
  badd = (double)FLT_MAX * 2.0;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &badd, encf));
  CHECK(memcmp(encf, encs, sizeof(encf)) == 0);
  badd = - (double)FLT_MAX * 2.0;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &badd, encf));
  CHECK(memcmp(encf, encs, sizeof(encf)) == 0);

  /* double underflow: value below FLT_MIN magnitude follows cast */
  badd = DBL_MIN;
  CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 1, &badd, &oz));
  float expected = (float)DBL_MIN;
  CHECK(f32_bits(oz) == f32_bits(expected));

  badd = -DBL_MIN;
  CHECK(glims_lab_encode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, 1, &badd, &oz));
  CHECK(f32_bits(oz) == 0x80000000u);
  badd = nextafter((double)FLT_MAX, INFINITY);
  oz = 3.0f;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_FLOAT, 1, &badd, &oz));
  CHECK(oz == 3.0f);

  /* nominal range refusals for integer formats */
  uint8_t ob = 0x5A; uint8_t obs = ob;
  badd = -0.0000001;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 1, &badd, &ob));
  CHECK(ob == obs);
  badd = 100.0000001;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 1, &badd, &ob));
  CHECK(ob == obs);
  badd = -128.0000001;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 1, &badd, &ob));
  CHECK(ob == obs);
  badd = 127.0000001;
  CHECK(!glims_lab_encode_row(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_U8, 1, &badd, &ob));
  CHECK(ob == obs);
}

static void test_all_range_refusals(void)
{
  for (int role = 0; role < 3; role++) {
    double low = role == GLIMS_LAB_ROLE_L ? 0 : -128;
    double high = role == GLIMS_LAB_ROLE_L ? 100 : 127;
    double bad[] = {nextafter(low, -INFINITY), nextafter(high, INFINITY), NAN, INFINITY, -INFINITY};
    for (int format = GLIMS_LAB_FORMAT_U8; format <= GLIMS_LAB_FORMAT_U16; format++) {
      for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        double source[3] = {low, high, bad[i]};
        unsigned char output[8], saved[8];
        memset(output, 0xC7, sizeof(output)); memcpy(saved, output, sizeof(output));
        CHECK(!glims_lab_encode_row((GlimsLabRole)role, (GlimsLabFormat)format, 3, source, output));
        CHECK(memcmp(output, saved, sizeof(output)) == 0);
      }
    }
  }
}

int
main(void)
{
  test_exhaustive_u8();
  test_exhaustive_u16();
  test_v4_literals();
  test_half_ties_and_neighbors();
  test_partial_unaligned_canaries();
  test_zero_count_null_invalid();
  test_overlap_refusal();
  test_late_bad_unchanged();
  test_float_roundtrips_and_specials();
  test_all_range_refusals();

  printf("Lab sample literals: %u checks, %u failures\n", g_checks, g_failures);
  return g_failures ? 1 : 0;
}

#include "lab-levels.h"

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
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

static void identity_levels(GlimsLabLevels *s)
{
  s->low_input = 0; s->high_input = 1; s->gamma = 1;
  s->low_output = 0; s->high_output = 1;
  s->clamp_input = 0; s->clamp_output = 0;
}

static bool call(GlimsLabRole role, GlimsLabFormat format, const GlimsLabLevels *s,
                 size_t count, const void *src, const float *mask, void *dst, bool *changed)
{
  return glims_lab_levels_row(role, format, s, count, src, mask, dst, changed);
}

static void test_u8_exhaustive_identity_all_roles(void)
{
  const GlimsLabRole roles[3] = {GLIMS_LAB_ROLE_L, GLIMS_LAB_ROLE_A, GLIMS_LAB_ROLE_B};
  GlimsLabLevels id; identity_levels(&id);
  for (int r = 0; r < 3; r++) {
    for (int q = 0; q < 256; q++) {
      uint8_t src = (uint8_t)q, dst = 0xA5;
      bool changed = true;
      CHECK(call(roles[r], GLIMS_LAB_FORMAT_U8, &id, 1, &src, NULL, &dst, &changed));
      CHECK(dst == (uint8_t)q);
      CHECK(!changed);
    }
    for (int q = 0; q < 256; q++) {
      uint8_t src = (uint8_t)q, dst = 0x5A;
      float m = 0.5f;
      bool changed = true;
      CHECK(call(roles[r], GLIMS_LAB_FORMAT_U8, &id, 1, &src, &m, &dst, &changed));
      CHECK(dst == (uint8_t)q);
      CHECK(!changed);
    }
  }
}

static void test_u16_exhaustive_identity_all_roles(void)
{
  const GlimsLabRole roles[3] = {GLIMS_LAB_ROLE_L, GLIMS_LAB_ROLE_A, GLIMS_LAB_ROLE_B};
  GlimsLabLevels id; identity_levels(&id);
  for (int r = 0; r < 3; r++) {
    uint16_t source[4096], destination[4096];
    float masks[4096];
    for (unsigned base = 0; base < 65536; base += 4096) {
      for (unsigned i = 0; i < 4096; i++) {
        source[i] = (uint16_t)(base + i);
        destination[i] = (uint16_t)(0xA5A5u ^ i);
        masks[i] = (float)(i % 5) / 4.0f;
      }
      bool changed = true;
      CHECK(call(roles[r], GLIMS_LAB_FORMAT_U16, &id, 4096, source, masks, destination, &changed));
      CHECK(memcmp(source, destination, sizeof source) == 0);
      CHECK(!changed);
    }
  }
}

static void test_gamma_l25_to_50_mask_half_37_5(void)
{
  GlimsLabLevels s; identity_levels(&s);
  s.gamma = 2.0; /* pow(t,1/2): L25->L50 */
  uint8_t src = 64; /* 100*64/255 ~ 25.098 */
  uint8_t dst = 0;
  bool changed = false;
  CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &s, 1, &src, NULL, &dst, &changed));
  CHECK(dst == 128 && changed); /* 50 -> 127.5 rounded half up = 128 */
  float m = 0.5f;
  dst = 0;
  changed = false;
  CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &s, 1, &src, &m, &dst, &changed));
  CHECK(dst == 96 && changed); /* ~37.549 -> 95.7495 rounded = 96 */
}

/* Exact physical inputs, independent of integer encoding and codec helpers. */
static void test_exact_physical_gamma_and_mask(void)
{
  GlimsLabLevels s; identity_levels(&s); s.gamma = 2;
  float src = 25, dst = -999, mask = .5f; bool changed = false;
  CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &s, 1, &src, NULL, &dst, &changed));
  CHECK(dst == 50 && changed);
  CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &s, 1, &src, &mask, &dst, &changed));
  CHECK(dst == 37.5f && changed);
  for (int role = 1; role <= 2; role++) {
    src = -64.25f; /* normalized .25 => sqrt .5 => physical -.5 */
    CHECK(call((GlimsLabRole)role, GLIMS_LAB_FORMAT_FLOAT, &s, 1, &src, NULL, &dst, &changed));
    CHECK(dst == -.5f && changed);
    CHECK(call((GlimsLabRole)role, GLIMS_LAB_FORMAT_FLOAT, &s, 1, &src, &mask, &dst, &changed));
    CHECK(dst == -32.375f && changed);
    identity_levels(&s); s.low_output = 1; s.high_output = 0;
    src = 0;
    CHECK(call((GlimsLabRole)role, GLIMS_LAB_FORMAT_FLOAT, &s, 1, &src, NULL, &dst, &changed));
    CHECK(dst == -1 && changed);
    identity_levels(&s); s.gamma = 2;
  }
  unsigned char unaligned[sizeof s + 1]; memcpy(unaligned + 1, &s, sizeof s);
  src = 25;
  CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT,
             (const GlimsLabLevels *)(const void *)(unaligned + 1), 1, &src, NULL, &dst, &changed));
  CHECK(dst == 50 && changed);
}

static void test_integer_inversion_half_ties_and_chroma_zero(void)
{
  GlimsLabLevels inv; identity_levels(&inv);
  inv.low_input = 0; inv.high_input = 1; inv.low_output = 1; inv.high_output = 0;

  for (int q = 0; q < 256; q++) {
    uint8_t src = (uint8_t)q, dst = 0;
    bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 1, &src, NULL, &dst, &changed));
    CHECK(dst == (uint8_t)(255 - q));
    CHECK(changed == (dst != src));
  }
  for (int q = 0; q < 256; q++) {
    uint8_t src = (uint8_t)q, dst = 0;
    bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, &inv, 1, &src, NULL, &dst, &changed));
    CHECK(dst == (uint8_t)(255 - q));
    CHECK(changed == (dst != src));
  }

  for (unsigned q = 0; q < 65536; q += 257) {
    uint16_t src = (uint16_t)q, dst = 0;
    bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, &inv, 1, &src, NULL, &dst, &changed));
    CHECK(dst == (uint16_t)(65535 - q));
  }
  for (unsigned q = 0; q < 65536; q += 257) {
    uint16_t src = (uint16_t)q, dst = 0;
    bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_U16, &inv, 1, &src, NULL, &dst, &changed));
    CHECK(dst == (uint16_t)(65535 - q));
  }

  /* half ties: half mask on inversion */
  {
    uint8_t src = 0, dst = 0; /* L0 -> L100, half -> L50 = q128 */
    float m = 0.5f; bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 1, &src, &m, &dst, &changed));
    CHECK(dst == 128);
  }
  {
    uint8_t src = 255, dst = 0; /* L100 -> L0, half -> L50 = q128 */
    float m = 0.5f; bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 1, &src, &m, &dst, &changed));
    CHECK(dst == 128);
  }
  {
    uint8_t src = 0, dst = 0; /* chroma -128 -> 127, half -> -0.5 encoded q128? 127.5 rounds 128 */
    float m = 0.5f; bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, &inv, 1, &src, &m, &dst, &changed));
    CHECK(dst == 128);
  }
  {
    uint8_t src = 128, dst = 0; /* physical chroma 0 -> -1, unchanged by mask semantics? inversion maps 0 to -1 */
    bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, &inv, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 127 && changed);
  }
  {
    uint16_t src = 32896, dst = 0; /* chroma 0 neutral */
    bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_U16, &inv, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 32639 && changed);
  }
}

static void test_equal_reversed_endpoints_literal(void)
{
  GlimsLabLevels s; identity_levels(&s);
  /* equal input endpoints: t = n-low_input per spec */
  s.low_input = 0.25; s.high_input = 0.25; s.low_output = 0.0; s.high_output = 1.0; s.gamma = 1;
  {
    uint8_t src = 128; /* L ~50.196, n~0.502, t=n-0.25~0.252 -> L~25.2 q64 */
    uint8_t dst = 0; bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &s, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 64 && changed);
  }
  {
    uint8_t src = 0; /* n 0, t -0.25, output clips at quantization to 0 (unchanged) */
    uint8_t dst = 0xAA; bool changed = true;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &s, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 0 && !changed);
  }
  /* reversed endpoints */
  s.low_input = 1.0; s.high_input = 0.0; s.low_output = 1.0; s.high_output = 0.0;
  {
    uint8_t src = 64; bool changed = false; uint8_t dst = 0;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &s, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 64 && !changed);
  }
  s.low_input = 1.0; s.high_input = 0.0; s.low_output = 0.0; s.high_output = 1.0;
  {
    uint8_t src = 0, dst = 0; bool changed = false; /* n 0 -> t=(0-1)/(0-1)=1 -> 1 */
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &s, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 255 && changed);
  }
  {
    uint8_t src = 255, dst = 0; bool changed = false; /* n 1 -> t=0 -> 0 */
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &s, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 0 && changed);
  }
}

static void test_extended_float_clampoff_on(void)
{
  GlimsLabLevels id; identity_levels(&id);
  {
    float src = 150.0f, dst = 0; bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &id, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 150.0f && !changed);
  }
  {
    float src = -200.0f, dst = 0; bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, &id, 1, &src, NULL, &dst, &changed));
    CHECK(dst == -200.0f && !changed);
  }
  id.clamp_output = 1;
  {
    float src = 150.0f, dst = 0; bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &id, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 100.0f && changed);
  }
  {
    float src = -200.0f, dst = 0; bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, &id, 1, &src, NULL, &dst, &changed));
    CHECK(dst == -128.0f && changed);
  }
  identity_levels(&id); id.clamp_input = 1;
  {
    float src = 150.0f, dst = 0; bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &id, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 100.0f && changed);
  }
}

static void test_flt_max_half_inversion_cancellation(void)
{
  GlimsLabLevels inv; identity_levels(&inv);
  inv.low_output = 1; inv.high_output = 0; /* inversion */
  float m = 0.5f; bool changed = false;
  float src, dst;

  src = FLT_MAX; dst = 0;
  CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &inv, 1, &src, &m, &dst, &changed));
  CHECK(dst == 50.0f && changed);

  src = -FLT_MAX; dst = 0; changed = false;
  CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &inv, 1, &src, &m, &dst, &changed));
  CHECK(dst == 50.0f && changed);

  src = FLT_MAX; dst = 0; changed = false;
  CHECK(call(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, &inv, 1, &src, &m, &dst, &changed));
  CHECK(dst == -0.5f && changed);

  src = -FLT_MAX; dst = 0; changed = false;
  CHECK(call(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_FLOAT, &inv, 1, &src, &m, &dst, &changed));
  CHECK(dst == -0.5f && changed);
}

static void test_nonfinite_affected_refusal_and_zero_mask_raw_bytes(void)
{
  GlimsLabLevels id; identity_levels(&id);
  float saved3[3];
  bool changed = true;

  /* NaN affected with identity/nonzero coverage -> refusal, destination unchanged */
  {
    float dst[3] = {bits_f32(0x11111111u), bits_f32(0x22222222u), bits_f32(0x33333333u)};
    memcpy(saved3, dst, sizeof saved3);
    float src[3] = {0.0f, 0.0f, bits_f32(0x7FC00000u)};
    changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &id, 3, src, NULL, dst, &changed));
    CHECK(memcmp(dst, saved3, sizeof saved3) == 0);
    CHECK(!changed);
  }
  /* Inf affected */
  {
    float dst[2] = {1,2}; memcpy(saved3, dst, sizeof(float)*2);
    float src[2] = {1.0f, INFINITY};
    changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, &id, 2, src, NULL, dst, &changed));
    CHECK(memcmp(dst, saved3, sizeof(float)*2) == 0);
    CHECK(!changed);
  }
  /* -Inf affected */
  {
    float dst[2] = {1,2}; memcpy(saved3, dst, sizeof(float)*2);
    float src[2] = {-INFINITY, 0.0f};
    changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_FLOAT, &id, 2, src, NULL, dst, &changed));
    CHECK(memcmp(dst, saved3, sizeof(float)*2) == 0);
    CHECK(!changed);
  }
  /* zero mask preserves every source byte including NaN/Inf/-0 */
  {
    uint32_t srcbits[4] = {0x7FC01234u, 0x7F800000u, 0xFF800000u, 0x80000000u};
    float src[4], dst[4];
    memcpy(src, srcbits, sizeof srcbits);
    memset(dst, 0x55, sizeof dst);
    float mask[4] = {0,0,0,0};
    changed = true;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &id, 4, src, mask, dst, &changed));
    CHECK(memcmp(dst, srcbits, sizeof srcbits) == 0);
    CHECK(!changed);
  }
  /* -0 preserved on identity */
  {
    float src = bits_f32(0x80000000u), dst = 1.0f;
    changed = true;
    CHECK(call(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, &id, 1, &src, NULL, &dst, &changed));
    CHECK(f32_bits(dst) == 0x80000000u && !changed);
  }
}

static void test_settings_count_unaligned_partial_alias_inplace_maskoverlap(void)
{
  GlimsLabLevels id; identity_levels(&id);

  /* count 0 valid settings still, NULL sample buffers permitted */
  {
    bool changed = true;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &id, 0, NULL, NULL, NULL, &changed));
    CHECK(!changed);
  }
  /* invalid role/format/settings/count>max/count overflow invalid setup */
  {
    uint8_t src[1]={0}, dst[1]={1}; bool changed = true;
    CHECK(!call((GlimsLabRole)-1, GLIMS_LAB_FORMAT_U8, &id, 1, src, NULL, dst, &changed));
    CHECK(!changed && dst[0]==1);
    CHECK(!call(GLIMS_LAB_ROLE_L, (GlimsLabFormat)-1, &id, 1, src, NULL, dst, &changed));
    CHECK(!changed && dst[0]==1);
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, NULL, 1, src, NULL, dst, &changed));
    CHECK(!changed && dst[0]==1);
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &id, GLIMS_LAB_LEVELS_MAX_SAMPLES + 1, src, NULL, dst, &changed));
    CHECK(!changed && dst[0]==1);
  }

  /* unaligned pointers */
  {
    unsigned char sb[32], db[32], mb[64];
    memset(sb, 0, sizeof sb); memset(db, 0xA5, sizeof db); memset(mb, 0, sizeof mb);
    GlimsLabLevels inv; identity_levels(&inv); inv.low_output=1; inv.high_output=0;
    uint8_t *src = (uint8_t *)(sb + 1);
    uint8_t *dst = (uint8_t *)(db + 3);
    src[0] = 0;
    bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 255 && changed);
  }
  {
    unsigned char sb[64], db[64], mb[64];
    memset(db, 0x5A, sizeof db);
    void *src = sb + 1;
    void *dst = db + 3;
    void *maskp = mb + 2;
    uint16_t srcv = 0;
    memcpy(src, &srcv, sizeof srcv);
    float m = 1.0f; memcpy(maskp, &m, sizeof m);
    GlimsLabLevels inv; identity_levels(&inv); inv.low_output=1; inv.high_output=0;
    bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, &inv, 1, src, (const float *)maskp, dst, &changed));
    uint16_t got = 0;
    memcpy(&got, dst, sizeof got);
    CHECK(got == 65535 && changed);
  }

  /* inplace exact */
  {
    GlimsLabLevels inv; identity_levels(&inv); inv.low_output=1; inv.high_output=0;
    uint8_t row[4] = {0, 64, 128, 255};
    bool changed = false;
    CHECK(call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 4, row, NULL, row, &changed));
    CHECK(row[0]==255 && row[1]==191 && row[2]==127 && row[3]==0 && changed);
  }

  /* partial alias refused: source overlaps destination but not exact */
  {
    unsigned char buf[32]; memset(buf, 0x77, sizeof buf);
    GlimsLabLevels inv; identity_levels(&inv); inv.low_output=1; inv.high_output=0;
    uint8_t snap[32]; memcpy(snap, buf, sizeof snap);
    bool changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 4, buf, NULL, buf + 1, &changed));
    CHECK(memcmp(buf, snap, sizeof snap) == 0);
    CHECK(!changed);
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 4, buf + 1, NULL, buf, &changed));
    CHECK(memcmp(buf, snap, sizeof snap) == 0);
    CHECK(!changed);
  }

  /* mask overlap refused */
  {
    unsigned char src[32], dst[32], snapd[32];
    memset(src, 0, sizeof src); memset(dst, 0xCC, sizeof dst); memcpy(snapd, dst, sizeof dst);
    bool changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &id, 4, src, (const float *)(const void *)src, dst, &changed));
    CHECK(memcmp(dst, snapd, sizeof snapd) == 0);
    CHECK(!changed);
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &id, 4, src, (const float *)(const void *)(dst), dst, &changed));
    CHECK(memcmp(dst, snapd, sizeof snapd) == 0);
    CHECK(!changed);
  }
}

static void test_changed_protected_storage_late_invalid_atomic(void)
{
  GlimsLabLevels id; identity_levels(&id);

  /* late invalid mask: destination unchanged, changed false unless protected storage - test no write */
  {
    uint8_t src[4] = {10,20,30,40};
    uint8_t dst[4] = {1,2,3,4};
    uint8_t snap[4]; memcpy(snap, dst, sizeof dst);
    float mask[4] = {1,1,1,NAN};
    bool changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &id, 4, src, mask, dst, &changed));
    CHECK(memcmp(dst, snap, sizeof snap) == 0);
    CHECK(!changed);
  }
  {
    uint8_t src[4] = {10,20,30,40};
    uint8_t dst[4] = {1,2,3,4};
    uint8_t snap[4]; memcpy(snap, dst, sizeof dst);
    float mask[4] = {1,1,1,2.0f};
    bool changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &id, 4, src, mask, dst, &changed));
    CHECK(memcmp(dst, snap, sizeof snap) == 0);
    CHECK(!changed);
  }
  {
    float src[3] = {0,0,0};
    float dst[3] = {9,8,7};
    float snap[3]; memcpy(snap, dst, sizeof snap);
    float mask[3] = {1,1,INFINITY};
    bool changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &id, 3, src, mask, dst, &changed));
    CHECK(memcmp(dst, snap, sizeof snap) == 0);
    CHECK(!changed);
  }

  /* late nonfinite affected float sample in middle/end */
  {
    float fsrc[3] = {1.0f, NAN, 2.0f};
    float dst[3] = {5,6,7};
    float snap[3]; memcpy(snap, dst, sizeof snap);
    bool changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, &id, 3, fsrc, NULL, dst, &changed));
    CHECK(memcmp(dst, snap, sizeof snap) == 0);
    CHECK(!changed);
  }

  /* changed overlaps protected storage (settings/mask/source/destination) refused before writes */
  {
    float src = 25;
    struct { unsigned char first; bool changed; unsigned char tail[2]; } dst = { 9, true, { 7, 6 } };
    unsigned char before[sizeof dst]; memcpy(before, &dst, sizeof dst);
    CHECK(!call(GLIMS_LAB_ROLE_A, (GlimsLabFormat)99, &id, 1, &src, NULL, &dst, &dst.changed));
    CHECK(memcmp(before, &dst, sizeof dst) == 0);
    CHECK(dst.changed);
  }
  {
    uint8_t src[4] = {0,0,0,0};
    uint8_t dst[4] = {9,9,9,9};
    uint8_t snap[4]; memcpy(snap, dst, sizeof snap);
    GlimsLabLevels inv; identity_levels(&inv); inv.low_output=1; inv.high_output=0;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 4, src, NULL, dst, (bool *)(void *)(dst + 1)));
    CHECK(memcmp(dst, snap, sizeof snap) == 0);
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 4, src, NULL, dst, (bool *)(void *)(src + 1)));
    CHECK(memcmp(dst, snap, sizeof snap) == 0);
    float mask[4] = {1,1,1,1};
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &inv, 4, src, mask, dst, (bool *)(void *)(mask)));
    CHECK(memcmp(dst, snap, sizeof snap) == 0);
  }

  /* in-place late invalid mask atomic unchanged */
  {
    uint8_t row[4] = {10,20,30,40};
    uint8_t snap[4]; memcpy(snap, row, sizeof row);
    float mask[4] = {1,1,-1.0f,1};
    bool changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &id, 4, row, mask, row, &changed));
    CHECK(memcmp(row, snap, sizeof row) == 0);
    CHECK(!changed);
  }

  /* settings validated even for identity */
  {
    GlimsLabLevels bad; identity_levels(&bad); bad.gamma = NAN;
    uint8_t src = 5, dst = 7; bool changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &bad, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 7 && !changed);
  }
  {
    GlimsLabLevels bad; identity_levels(&bad); bad.clamp_input = 2;
    uint8_t src = 5, dst = 7; bool changed = true;
    CHECK(!call(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, &bad, 1, &src, NULL, &dst, &changed));
    CHECK(dst == 7 && !changed);
  }
}

int main(void)
{
  test_u8_exhaustive_identity_all_roles();
  test_u16_exhaustive_identity_all_roles();
  test_gamma_l25_to_50_mask_half_37_5();
  test_exact_physical_gamma_and_mask();
  test_integer_inversion_half_ties_and_chroma_zero();
  test_equal_reversed_endpoints_literal();
  test_extended_float_clampoff_on();
  test_flt_max_half_inversion_cancellation();
  test_nonfinite_affected_refusal_and_zero_mask_raw_bytes();
  test_settings_count_unaligned_partial_alias_inplace_maskoverlap();
  test_changed_protected_storage_late_invalid_atomic();

  printf("Lab levels: %u checks, %u failures\n", g_checks, g_failures);
  return g_failures ? 1 : 0;
}

#include "lab-fill.h"

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

static void
test_literals_u8_u16(void)
{
  /* U8: L 0->0,100->255; a/b -128->0,0->128,127->255 */
  {
    uint8_t src[5] = {10, 20, 30, 40, 50};
    uint8_t dst[5];
    memset(dst, 0xA5, sizeof(dst));
    bool changed = true;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 0 && changed);
    memset(dst, 0xA5, sizeof(dst)); changed = true;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 100.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 255 && changed);
  }
  {
    uint8_t src[1] = {99};
    uint8_t dst[1] = {0};
    bool changed = false;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -128.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 0 && changed);
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 0.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 128 && changed);
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 127.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 255 && changed);
  }
  /* U16: L 0->0,100->65535; chroma neutral 32896 -> 0 physical (codec literal) */
  {
    uint16_t src[1] = {1234};
    uint16_t dst[1] = {0};
    bool changed = false;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 0.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 0);
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U16, 100.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 65535u);
  }
  {
    uint16_t src[1] = {1};
    uint16_t dst[1] = {0};
    bool changed = false;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_U16, 0.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 32896u && changed); /* neutral */
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_U16, -128.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 0u);
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_U16, 127.0, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == 65535u);
  }
}

static void
test_all_roles_formats_and_masks(void)
{
  /* Exact rational physical blends, derived independently with Fraction.
   * Rows cover weights 0,1/4,1/2,1 and 0,1/8,1/4,1/2. No expected sample
   * is obtained from either production codec or fill. */
  static const struct {
    GlimsLabRole role; double target, opacity;
    uint8_t u8[4]; uint16_t u16[4]; float physical[4];
  } rows[] = {
    {GLIMS_LAB_ROLE_L,100,1,{0,64,128,255},{0,16384,32768,65535},{0,25,50,100}},
    {GLIMS_LAB_ROLE_L,100,.5,{0,32,64,128},{0,8192,16384,32768},{0,12.5,25,50}},
    {GLIMS_LAB_ROLE_A,0,1,{0,32,64,128},{0,8224,16448,32896},{-128,-96,-64,0}},
    {GLIMS_LAB_ROLE_A,0,.5,{0,16,32,64},{0,4112,8224,16448},{-128,-112,-96,-64}},
    {GLIMS_LAB_ROLE_B,127,1,{0,64,128,255},{0,16384,32768,65535},{-128,-64.25,-.5,127}},
    {GLIMS_LAB_ROLE_B,127,.5,{0,32,64,128},{0,8192,16384,32768},{-128,-96.125,-64.25,-.5}}
  };
  const float mask[4] = {0,.25f,.5f,1};
  for (size_t i=0; i<sizeof rows/sizeof rows[0]; i++) {
    uint8_t src8[4]={0}, dst8[4]; uint16_t src16[4]={0}, dst16[4];
    float srcf[4], dstf[4];
    for (unsigned n=0;n<4;n++) srcf[n]=rows[i].role==GLIMS_LAB_ROLE_L ? 0 : -128;
    bool changed=false;
    CHECK(glims_lab_fill_row(rows[i].role,GLIMS_LAB_FORMAT_U8,rows[i].target,
      rows[i].opacity,4,src8,mask,dst8,&changed));
    CHECK(changed && !memcmp(dst8,rows[i].u8,sizeof dst8));
    CHECK(glims_lab_fill_row(rows[i].role,GLIMS_LAB_FORMAT_U16,rows[i].target,
      rows[i].opacity,4,src16,mask,dst16,&changed));
    CHECK(changed && !memcmp(dst16,rows[i].u16,sizeof dst16));
    CHECK(glims_lab_fill_row(rows[i].role,GLIMS_LAB_FORMAT_FLOAT,rows[i].target,
      rows[i].opacity,4,srcf,mask,dstf,&changed));
    CHECK(changed && !memcmp(dstf,rows[i].physical,sizeof dstf));
  }
}

static void
test_full_weight_endpoint_and_specials(void)
{
  /* Full weight writes exact requested endpoint even with extreme source. */
  {
    float src[1] = {FLT_MAX};
    float dst[1] = {0.0f};
    bool changed = false;
    float m = 1.0f;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 0.0, 1.0, 1, src, &m, dst, &changed));
    CHECK(f32_bits(dst[0]) == f32_bits(0.0f) && changed);
    src[0] = -FLT_MAX;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_FLOAT, (double)FLT_MAX, 1.0, 1, src, NULL, dst, &changed));
    CHECK(dst[0] == FLT_MAX && changed);
  }
  /* ±0, subnormals, extended finite preserved/handled */
  {
    float src[1] = {bits_f32(0x80000000u)}; /* -0 */
    float dst[1] = {1.0f};
    bool changed = false;
    float m = 0.0f;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_B, GLIMS_LAB_FORMAT_FLOAT, 10.0, 1.0, 1, src, &m, dst, &changed));
    CHECK(f32_bits(dst[0]) == 0x80000000u && !changed);
  }
  {
    float src[1] = {bits_f32(0x00000001u)}; /* min subnormal */
    float dst[1] = {0.0f};
    bool changed = false;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, (double)bits_f32(0x00000001u), 1.0, 1, src, NULL, dst, &changed));
    CHECK(f32_bits(dst[0]) == 0x00000001u && !changed);
  }
  {
    float src[1] = {1.0e30f}; /* extended for L in float */
    float dst[1] = {0.0f};
    bool changed = false;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 50.0, 0.5, 1, src, NULL, dst, &changed));
    CHECK(isfinite(dst[0]) && changed);
  }
}

static void
test_zero_weight_nan_and_atomicity(void)
{
  /* Untouched NaN at zero weight copied raw */
  uint32_t nan_bits = 0x7FC00000u;
  float srcf[2] = {bits_f32(nan_bits), 1.0f};
  float dstf[2] = {0.0f, 0.0f};
  bool changed = false;
  float mask[2] = {0.0f, 0.0f};
  CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 10.0, 1.0, 2, srcf, mask, dstf, &changed));
  CHECK(f32_bits(dstf[0]) == nan_bits && f32_bits(dstf[1]) == f32_bits(srcf[1]) && !changed);

  /* Late affected NaN atomicity: destination unchanged */
  float dst2[3] = {bits_f32(0x11111111u), bits_f32(0x22222222u), bits_f32(0x33333333u)};
  float saved[3]; memcpy(saved, dst2, sizeof(saved));
  float src2[3] = {0.0f, 0.0f, bits_f32(nan_bits)};
  float mask2[3] = {1.0f, 1.0f, 1.0f};
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 10.0, 1.0, 3, src2, mask2, dst2, &changed));
  CHECK(memcmp(dst2, saved, sizeof(saved)) == 0);
  CHECK(!changed);

  /* Malformed mask late even with zero opacity: validates all masks */
  float src3[3] = {0.0f, 0.0f, 0.0f};
  float dst3[3] = {1.0f, 2.0f, 3.0f};
  memcpy(saved, dst3, sizeof(saved));
  float mask3[3] = {0.0f, 0.0f, NAN};
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 10.0, 0.0, 3, src3, mask3, dst3, &changed));
  CHECK(memcmp(dst3, saved, sizeof(saved)) == 0);
  CHECK(!changed);
}

static void
test_invalids_and_null_zero(void)
{
  uint8_t src = 0, dst = 0;
  bool changed = true;
  /* invalid enums/settings */
  CHECK(!glims_lab_fill_row((GlimsLabRole)-1, GLIMS_LAB_FORMAT_U8, 0, 1, 1, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, (GlimsLabFormat)-1, 0, 1, 1, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, NAN, 1, 1, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, NAN, 1, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, -0.1, 1, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1.1, 1, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, -1, 1, 1, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, -129, 1, 1, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_A, GLIMS_LAB_FORMAT_U8, 128, 1, 1, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1, 4097, &src, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1, SIZE_MAX, &src, NULL, &dst, &changed) && !changed);

  /* count 0 validates and permits NULL buffers */
  changed = true;
  CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 50.0, 0.5, 0, NULL, NULL, NULL, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, -1.0, 0.5, 0, NULL, NULL, NULL, &changed) && !changed);
  /* changed NULL refused without write - cannot observe, but must return false */
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 50.0, 1.0, 0, NULL, NULL, NULL, NULL));

  /* nonzero null buffers */
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1, 1, NULL, NULL, &dst, &changed) && !changed);
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1, 1, &src, NULL, NULL, &changed) && !changed);
}

static void
test_overflow_ranges_no_deref(void)
{
  bool changed = true;
  const void *near_end = (const void *)(UINTPTR_MAX - 2);
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1, 4, near_end, NULL, (void *)0x1000, &changed));
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1, 4, (void *)0x1000, NULL, (void *)near_end, &changed));
  changed = true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_FLOAT, 0, 1, 4, (void *)0x1000, near_end, (void *)0x2000, &changed));
}

static void
test_in_place_unaligned_and_max_count(void)
{
  /* in-place */
  {
    uint8_t row[4] = {0, 64, 128, 255};
    bool changed = false;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0.0, 1.0, 4, row, NULL, row, &changed));
    CHECK(row[0] == 0 && row[1] == 0 && row[2] == 0 && row[3] == 0 && changed);
  }
  /* unaligned all buffers */
  {
    unsigned char src_buf[64], dst_buf[64], mask_buf[64];
    memset(src_buf, 0, sizeof(src_buf));
    memset(dst_buf, 0xA5, sizeof(dst_buf));
    memset(mask_buf, 0, sizeof(mask_buf));
    uint8_t *src = (uint8_t *)(src_buf + 1);
    uint8_t *dst = (uint8_t *)(dst_buf + 3);
    const float *mask = (const float *)(const void *)(mask_buf + 1);
    src[0] = 0; src[1] = 255; src[2] = 128;
    const float masks[3] = {1.0f, 0.0f, 0.5f};
    memcpy(mask_buf + 1, masks, sizeof masks);
    bool changed = false;
    /* target 100 -> 255 */
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 100.0, 1.0, 3, src, mask, dst, &changed));
    CHECK(dst[0] == 255);
    CHECK(dst[1] == 255);
    /* Independent Fraction.from_float golden: decoded128 is
     * 0x1.9191919191919p+5; blended double 0x1.2c64646464646p+6
     * lies below exact code191.5. Physical-double quantization gives191. */
    CHECK(dst[2] == 191);
    CHECK(changed);
  }
  /* max count 4096 */
  {
    size_t n = 4096;
    uint8_t *src = (uint8_t *)malloc(n);
    uint8_t *dst = (uint8_t *)malloc(n);
    float *mask = (float *)malloc(n * sizeof(float));
    CHECK(src && dst && mask);
    if (src && dst && mask) {
      memset(src, 128, n); /* L ~50.196 */
      memset(dst, 0, n);
      for (size_t i = 0; i < n; i++) mask[i] = 0.0f;
      bool changed = true;
      CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0.0, 1.0, n, src, mask, dst, &changed));
      CHECK(memcmp(src, dst, n) == 0 && !changed);
    }
    free(src); free(dst); free(mask);
  }
}

static void
test_overlaps_and_canaries(void)
{
  /* partial overlap source/dest refused */
  {
    unsigned char buf[64];
    memset(buf, 0x5A, sizeof(buf));
    bool changed = true;
    CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1, 4, buf, NULL, buf + 2, &changed));
    /* destination must be unchanged on refusal for invalid/overlap case with nonaliased changed? spec: "Other invalid settings should clear nonaliased changed false" - overlap refused so changed cleared, dest not written */
    for (size_t i = 0; i < sizeof(buf); i++) CHECK(buf[i] == 0x5A);
    CHECK(!changed);
  }
  /* source overlaps mask, dest overlaps mask, source/dest overlap changed, mask vs changed */
  {
    unsigned char src[16], dst[16];
    memset(src, 128, sizeof(src));
    memset(dst, 0xCC, sizeof(dst));
    bool changed = true;
    /* mask overlaps source */
    CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1, 2, src, (const float *)src, dst, &changed));
    CHECK(!changed);
    /* changed overlaps destination: must refuse without writing changed */
    bool *chp = (bool *)(dst + 1);
    const bool yes = true; memcpy(dst + 1, &yes, sizeof yes);
    uint8_t dst_before[16]; memcpy(dst_before, dst, sizeof(dst));
    CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 0, 1, 2, src, NULL, dst, chp));
    CHECK(memcmp(dst, dst_before, sizeof(dst)) == 0); /* unchanged including chp byte */
  }
  {
    /* mask vs changed */
    float mask[4] = {1,1,1,1};
    uint8_t src[4] = {0,0,0,0};
    uint8_t dst[4] = {1,1,1,1};
    bool *chp = (bool *)(void *)mask;
    unsigned char saved[sizeof mask]; memcpy(saved, mask, sizeof saved);
    CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L, GLIMS_LAB_FORMAT_U8, 100, 1, 4, src, mask, dst, chp));
    CHECK(!memcmp(mask, saved, sizeof saved));
  }
}

static void
test_additional_edges(void)
{
  /* Full endpoint survives arbitrary finite source magnitude; signed zero is
   * an exact endpoint too, and unselected special values retain their bits. */
  const float extremes[] = {FLT_MAX,-FLT_MAX,0x1p60f,-0x1p60f};
  for (int role=0;role<3;role++) for (unsigned n=0;n<4;n++) {
    float output=0; bool changed=false;
    CHECK(glims_lab_fill_row((GlimsLabRole)role,GLIMS_LAB_FORMAT_FLOAT,
      1,1,1,&extremes[n],NULL,&output,&changed));
    CHECK(output==1 && changed);
    CHECK(glims_lab_fill_row((GlimsLabRole)role,GLIMS_LAB_FORMAT_FLOAT,
      -0.0,1,1,&extremes[n],NULL,&output,&changed));
    CHECK(f32_bits(output)==UINT32_C(0x80000000) && changed);
    CHECK(glims_lab_fill_row((GlimsLabRole)role,GLIMS_LAB_FORMAT_FLOAT,
      -(double)extremes[n],.5,1,&extremes[n],NULL,&output,&changed));
    CHECK(output==0 && changed);
  }
  const uint32_t special_bits[]={0x80000000,1,0x80000001,0x7fc12345,0x7f800000,0xff800000};
  float source[6],output[6],mask[6]={0};
  memcpy(source,special_bits,sizeof source);
  bool changed=true;
  CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_B,GLIMS_LAB_FORMAT_FLOAT,
    0,1,6,source,mask,output,&changed));
  CHECK(!changed && !memcmp(source,output,sizeof source));
  CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_B,GLIMS_LAB_FORMAT_FLOAT,
    0,0,6,source,NULL,source,&changed));
  CHECK(!changed && !memcmp(source,special_bits,sizeof source));

  /* Every format gets genuinely unaligned source/destination/mask pointers,
   * canaries, and the same independent physical midpoint 50/-0.5. */
  for (int format=0;format<3;format++) for (int role=0;role<3;role++) {
    unsigned char src[24],dst[24],masks[24],saved[24];
    memset(src,0x61,sizeof src); memset(dst,0xa5,sizeof dst); memset(masks,0x71,sizeof masks);
    size_t width=format==0 ? 1 : format==1 ? 2 : 4;
    uint32_t zero=0; float start=role==0 ? 0 : -128;
    memcpy(src+1,format==2 ? (const void *)&start : (const void *)&zero,width);
    float coverage=.5f; memcpy(masks+1,&coverage,sizeof coverage);
    memcpy(saved,src,sizeof src); changed=false;
    CHECK(glims_lab_fill_row((GlimsLabRole)role,(GlimsLabFormat)format,
      role==0 ? 100 : 127,1,1,src+1,(const float *)(const void *)(masks+1),dst+3,&changed));
    CHECK(changed && !memcmp(src,saved,sizeof src));
    if (format==0) CHECK(dst[3]==128);
    else if (format==1) { uint16_t v;memcpy(&v,dst+3,2);CHECK(v==32768); }
    else { float v;memcpy(&v,dst+3,4);CHECK(v==(role==0 ? 50 : -.5f)); }
    for (size_t n=0;n<sizeof dst;n++) if(n<3 || n>=3+width) CHECK(dst[n]==0xa5);
    unsigned char result[4];memcpy(result,dst+3,width);
    CHECK(glims_lab_fill_row((GlimsLabRole)role,(GlimsLabFormat)format,
      role==0 ? 100 : 127,1,1,src+1,(const float *)(const void *)(masks+1),src+1,&changed));
    CHECK(changed && !memcmp(src+1,result,width));
    for(size_t n=0;n<sizeof src;n++) if(n<1 || n>=1+width) CHECK(src[n]==saved[n]);
  }

  /* A late bad mask/source refuses atomically, including in-place source. */
  const float bad_masks[]={NAN,INFINITY,-INFINITY,-.25f,1.25f};
  const float bad_sources[]={NAN,INFINITY,-INFINITY};
  for(unsigned n=0;n<sizeof bad_masks/sizeof bad_masks[0];n++) {
    float values[]={-128,0,127},copy[3],m[]={1,1,bad_masks[n]};
    memcpy(copy,values,sizeof copy);changed=true;
    CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_A,GLIMS_LAB_FORMAT_FLOAT,
      50,1,3,values,m,values,&changed));
    CHECK(!changed && !memcmp(values,copy,sizeof copy));
    changed=true;
    CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_A,GLIMS_LAB_FORMAT_FLOAT,
      50,0,3,values,m,values,&changed));
    CHECK(!changed && !memcmp(values,copy,sizeof copy));
  }
  for(unsigned n=0;n<sizeof bad_sources/sizeof bad_sources[0];n++) {
    float values[]={-128,0,bad_sources[n]},copy[3];
    memcpy(copy,values,sizeof copy);changed=true;
    CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_A,GLIMS_LAB_FORMAT_FLOAT,
      50,1,3,values,NULL,values,&changed));
    CHECK(!changed && !memcmp(values,copy,sizeof copy));
  }
  float old=1,result=37;changed=true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_FLOAT,
    nextafter((double)FLT_MAX,INFINITY),1,1,&old,NULL,&result,&changed));
  CHECK(!changed && result==37);
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_FLOAT,
    -INFINITY,1,0,NULL,NULL,NULL,&changed));

  /* All overlap directions, including interior changed aliases, are rejected
   * before writes. Never read a bool through arbitrary sample representation. */
  unsigned char shared[128],snapshot[128],separate[32];
  memset(shared,0x5a,sizeof shared);memset(separate,0x22,sizeof separate);
  memcpy(snapshot,shared,sizeof shared);changed=true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_U16,
    50,1,4,shared+4,NULL,shared,&changed));
  CHECK(!changed && !memcmp(shared,snapshot,sizeof shared));
  changed=true;
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_U8,
    50,1,4,separate,(const float *)(const void *)(shared+1),shared,&changed));
  CHECK(!changed && !memcmp(shared,snapshot,sizeof shared));
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_U16,
    50,1,4,shared,NULL,separate,(bool *)(void *)(shared+3)));
  CHECK(!memcmp(shared,snapshot,sizeof shared));
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_U16,
    50,1,4,separate,NULL,shared,(bool *)(void *)(shared+3)));
  CHECK(!memcmp(shared,snapshot,sizeof shared));
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_U8,
    50,1,4,separate,(const float *)(const void *)shared,separate+16,(bool *)(void *)(shared+9)));
  CHECK(!memcmp(shared,snapshot,sizeof shared));
  /* Even rejected settings cannot clear an exact changed/input alias. */
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_U8,
    50,1,SIZE_MAX,shared,NULL,separate,(bool *)(void *)shared));
  CHECK(!memcmp(shared,snapshot,sizeof shared));
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,(GlimsLabFormat)-1,
    50,1,1,shared,NULL,separate,(bool *)(void *)shared));
  CHECK(!memcmp(shared,snapshot,sizeof shared));
  CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_U16,
    NAN,1,4,shared,NULL,separate,(bool *)(void *)(shared+3)));
  CHECK(!memcmp(shared,snapshot,sizeof shared));
}

static void
test_full_row_publication(void)
{
  const size_t n=GLIMS_LAB_FILL_MAX_COUNT;
  float *source=calloc(n,sizeof *source), *output=malloc(n*sizeof *output);
  uint16_t *words=calloc(n,sizeof *words), *encoded=malloc(n*sizeof *encoded);
  CHECK(source && output && words && encoded);
  if(source && output && words && encoded) {
    bool changed=false;
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_A,GLIMS_LAB_FORMAT_U16,
      0,1,n,words,NULL,encoded,&changed));
    bool exact=true;for(size_t i=0;i<n;i++) if(encoded[i]!=32896) exact=false;
    CHECK(exact && changed);
    CHECK(glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_FLOAT,
      50,1,n,source,NULL,output,&changed));
    exact=true;for(size_t i=0;i<n;i++) if(output[i]!=50) exact=false;
    CHECK(exact && changed);
    source[n-1]=bits_f32(UINT32_C(0x7fc12345));changed=true;
    CHECK(!glims_lab_fill_row(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_FLOAT,
      100,1,n,source,NULL,output,&changed));
    exact=true;for(size_t i=0;i<n;i++) if(output[i]!=50) exact=false;
    CHECK(exact && !changed);
  }
  free(source);free(output);free(words);free(encoded);
}

static uint32_t
random_word(uint32_t *state)
{
  *state = *state * UINT32_C(1664525) + UINT32_C(1013904223);
  return *state;
}

static void
test_identity_roundoff(void)
{
  const double weights[]={0x1p-1074,0x1.fffffffffffffp-1,.1,.3,.7,
    0x1.6824beb35711dp-19,0x1.47229384f9b02p-29,0x1.d453dd341dd13p-48,
    0x1.1800b28a718aep-14};
  const float values[]={FLT_MAX,-FLT_MAX,100,127,-128,0,-0.0f,0x1p-149f,-0x1p-149f};
  for(unsigned n=0;n<sizeof values/sizeof values[0];n++)
    for(unsigned w=0;w<sizeof weights/sizeof weights[0];w++) {
      float out=42;bool changed=true;
      CHECK(glims_lab_fill_row((GlimsLabRole)(n%3),GLIMS_LAB_FORMAT_FLOAT,
        values[n],weights[w],1,&values[n],NULL,&out,&changed));
      CHECK(!changed && f32_bits(out)==f32_bits(values[n]));
    }
  for(int role=0;role<3;role++) for(int format=0;format<2;format++)
    for(unsigned w=0;w<sizeof weights/sizeof weights[0];w++) {
      unsigned char input[2]={255,255},output[2]={0};bool changed=true;
      CHECK(glims_lab_fill_row((GlimsLabRole)role,(GlimsLabFormat)format,
        role==0 ? 100 : 127,weights[w],1,input,NULL,output,&changed));
      CHECK(!changed && !memcmp(input,output,format==0 ? 1 : 2));
    }
  /* Weight exponents vary, so 1-w is not always an exactly representable
   * complement as it is for random 53-bit fractions in [0,1]. */
  uint32_t state=UINT32_C(0x12ab34cd);
  for(unsigned n=0;n<1000;n++) {
    float source=bits_f32(random_word(&state));
    double weight=ldexp(1.0+(double)(random_word(&state)>>8)/16777216.0,
                        -(int)(1+random_word(&state)%1074));
    if(!isfinite(source)) continue;
    float output=42;bool changed=true;
    CHECK(glims_lab_fill_row((GlimsLabRole)(n%3),GLIMS_LAB_FORMAT_FLOAT,
      source,weight,1,&source,NULL,&output,&changed));
    CHECK(!changed && f32_bits(source)==f32_bits(output));
  }
}

int
main(void)
{
  test_literals_u8_u16();
  test_all_roles_formats_and_masks();
  test_full_weight_endpoint_and_specials();
  test_zero_weight_nan_and_atomicity();
  test_invalids_and_null_zero();
  test_overflow_ranges_no_deref();
  test_in_place_unaligned_and_max_count();
  test_overlaps_and_canaries();
  test_additional_edges();
  test_identity_roundoff();
  test_full_row_publication();

  printf("Lab fill: %u checks, %u failures\n", g_checks, g_failures);
  return g_failures ? 1 : 0;
}

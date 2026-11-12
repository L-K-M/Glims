#include "component-scalar.h"
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c) do { ++checks; if (!(c)) { ++failures; \
  fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)
#define ROW(f,o,t,a,n,s,m,d) glims_component_scalar_row(f,o,t,a,n,s,m,d,&changed)
int main(void)
{
  bool changed = false;
  float input = .25f, output = -9, mask = .5f;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_FILL,.75,.5,1,&input,&mask,&output));
  CHECK(changed && output == .375f);

  uint8_t u8[] = {0,1,127,128,254,255}, b8[6] = {0};
  const uint8_t inverse8[] = {255,254,128,127,1,0};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_INVERT,0,1,6,u8,NULL,b8));
  CHECK(changed && memcmp(b8,inverse8,sizeof b8)==0);
  uint16_t u16[] = {0,1,32767,32768,65534,65535}, b16[6] = {0};
  const uint16_t inverse16[] = {65535,65534,32768,32767,1,0};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,GLIMS_COMPONENT_SCALAR_INVERT,0,1,6,u16,NULL,b16));
  CHECK(changed && memcmp(b16,inverse16,sizeof b16)==0);
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,1,.5,1,u8,NULL,b8));
  CHECK(changed && b8[0]==128);
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,GLIMS_COMPONENT_SCALAR_FILL,1,.5,1,u16,NULL,b16));
  CHECK(changed && b16[0]==32768);
  uint8_t half8[] = {136,170}, half8out[2];
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,1,.5,2,half8,NULL,half8out));
  CHECK(half8out[0]==196 && half8out[1]==213);
  uint16_t half16[] = {34952,43690}, half16out[2];
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,GLIMS_COMPONENT_SCALAR_FILL,1,.5,2,half16,NULL,half16out));
  CHECK(half16out[0]==50244 && half16out[1]==54613);
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,0,1,1,u8,NULL,b8));
  CHECK(!changed && b8[0]==0); /* changed compares source/result, not old output. */

  float extended[] = {-.5f,1.5f,FLT_MAX,-FLT_MAX}, eout[4];
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_INVERT,0,1,4,extended,NULL,eout));
  CHECK(changed && eout[0]==1.5f && eout[1]==-.5f && eout[2]==-FLT_MAX && eout[3]==FLT_MAX);
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_FILL,.75,1,4,extended,NULL,eout));
  CHECK(changed && eout[0]==.75f && eout[1]==.75f && eout[2]==.75f && eout[3]==.75f);
  float extreme[] = {FLT_MAX,-FLT_MAX,0x1p60f,-0x1p60f};
  float halfway[] = {.5f,.5f,.5f,.5f};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_INVERT,0,1,4,extreme,halfway,eout));
  CHECK(changed);
  for (unsigned i=0; i<4; i++) CHECK(eout[i]==.5f);

  uint32_t raw[] = {UINT32_C(0x7fc01234),UINT32_C(0x80000000),UINT32_C(0x7f800000)};
  float exceptional[3]; memcpy(exceptional,raw,sizeof raw);
  float no_mask[] = {0,0,0}, excout[3];
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_INVERT,0,1,3,exceptional,no_mask,excout));
  CHECK(!changed && memcmp(excout,raw,sizeof raw)==0);
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_FILL,.7,0,3,exceptional,NULL,excout));
  CHECK(!changed && memcmp(excout,raw,sizeof raw)==0);

  float valid[] = {.25f,.5f,.75f}, bad_mask[] = {1,1,NAN};
  unsigned char bytes[sizeof valid], saved[sizeof valid]; memset(bytes,0xa5,sizeof bytes);memcpy(saved,bytes,sizeof bytes);
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_FILL,.9,1,3,valid,bad_mask,bytes));
  CHECK(!changed && memcmp(bytes,saved,sizeof bytes)==0);
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_FILL,.9,0,3,valid,bad_mask,bytes));
  CHECK(!changed && memcmp(bytes,saved,sizeof bytes)==0);
  float bad_source[] = {.25f,.5f,NAN};
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_FILL,.9,1,3,bad_source,NULL,bytes));
  CHECK(!changed && memcmp(bytes,saved,sizeof bytes)==0);
  unsigned char original[sizeof bad_source];memcpy(original,bad_source,sizeof original);
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_INVERT,0,1,3,bad_source,NULL,bad_source));
  CHECK(!changed && memcmp(original,bad_source,sizeof original)==0);

  float in_place[] = {.25f,.75f};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_INVERT,0,1,2,in_place,NULL,in_place));
  CHECK(changed && in_place[0]==.75f && in_place[1]==.25f);
  unsigned char unaligned_source[5],unaligned_dest[5];uint16_t near_end[] = {1,65534};
  memcpy(unaligned_source+1,near_end,sizeof near_end);
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,GLIMS_COMPONENT_SCALAR_INVERT,0,1,2,unaligned_source+1,NULL,unaligned_dest+1));
  uint16_t loaded[2];memcpy(loaded,unaligned_dest+1,sizeof loaded);
  CHECK(changed && loaded[0]==65534 && loaded[1]==1);

  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,.5,.5,0,NULL,NULL,NULL));
  CHECK(!changed);
  CHECK(!glims_component_scalar_row(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,0,1,0,NULL,NULL,NULL,NULL));
  CHECK(!ROW((GlimsComponentScalarFormat)99,GLIMS_COMPONENT_SCALAR_FILL,0,1,0,NULL,NULL,NULL));
  CHECK(!changed);
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,(GlimsComponentScalarOperation)99,0,1,0,NULL,NULL,NULL));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_INVERT,.1,1,0,NULL,NULL,NULL));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_INVERT,0,.5,0,NULL,NULL,NULL));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,NAN,1,0,NULL,NULL,NULL));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,0,INFINITY,0,NULL,NULL,NULL));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,-.1,1,0,NULL,NULL,NULL));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,0,1.1,0,NULL,NULL,NULL));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,0,1,1,NULL,NULL,b8));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,0,1,1,u8,NULL,NULL));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,GLIMS_COMPONENT_SCALAR_FILL,0,1,SIZE_MAX/sizeof(float)+1,&input,NULL,&output));
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_FILL,0,1,SIZE_MAX/sizeof(float)+1,u8,&mask,b8));
  CHECK(!changed);
  /* Exhaust every integer input independently of normalized producer math. */
  uint8_t all8[256], flipped8[256];
  for (unsigned i=0; i<256; i++) all8[i]=(uint8_t)i;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,GLIMS_COMPONENT_SCALAR_INVERT,0,1,256,all8,NULL,flipped8));
  for (unsigned i=0; i<256; i++) CHECK(flipped8[i]==255-i);
  for (unsigned base=0; base<65536; base+=256) {
    uint16_t block[256], flipped[256];
    for(unsigned i=0;i<256;i++) block[i]=(uint16_t)(base+i);
    CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,GLIMS_COMPONENT_SCALAR_INVERT,0,1,256,block,NULL,flipped));
    bool exact=true;
    for(unsigned i=0;i<256;i++) if(flipped[i]!=65535-base-i) exact=false;
    CHECK(exact);
  }
  printf("Scalar literals: %u checks, %u failures\n",checks,failures);
  return failures ? 1 : 0;
}

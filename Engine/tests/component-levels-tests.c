/* Literal/rational scalar oracles, independent of the Levels implementation. */
#include "component-levels.h"
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)
static GlimsComponentLevels identity(void) {
  return (GlimsComponentLevels) { .low_input=0, .high_input=1, .gamma=1,
    .low_output=0, .high_output=1, .clamp_input=0, .clamp_output=0 };
}
static void integer_oracles(void) {
  GlimsComponentLevels s=identity(); bool changed=true;
  for (unsigned i=0;i<=UINT16_MAX;i++) {
    uint16_t in=(uint16_t)i,out=0;
    CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U16,&s,1,&in,NULL,&out,&changed));
    CHECK(out==in && !changed);
  }
  for (unsigned i=0;i<=UINT8_MAX;i++) {
    uint8_t in=(uint8_t)i,out=0;
    CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,1,&in,NULL,&out,&changed));
    CHECK(out==in && !changed);
  }
  s.low_output=.5;
  uint8_t in8[]={0,64,128,136,170,255},out8[6];
  const uint8_t expected8[]={128,160,192,196,213,255};
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,6,in8,NULL,out8,&changed));
  CHECK(changed && !memcmp(out8,expected8,sizeof out8));
  uint16_t in16[]={0,16384,32768,34952,43690,65535},out16[6];
  const uint16_t expected16[]={32768,40960,49152,50244,54613,65535};
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U16,&s,6,in16,NULL,out16,&changed));
  CHECK(changed && !memcmp(out16,expected16,sizeof out16));
  s=identity();s.low_input=.25;s.high_input=.75;s.clamp_input=1;s.clamp_output=1;
  uint8_t ramp8[]={0,64,128,192,255},mapped8[5];
  const uint8_t range8[]={0,1,129,255,255};
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,5,ramp8,NULL,mapped8,&changed));
  CHECK(!memcmp(mapped8,range8,sizeof mapped8));
  uint16_t ramp16[]={0,16384,32768,49152,65535},mapped16[5];
  const uint16_t range16[]={0,1,32769,65535,65535};
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U16,&s,5,ramp16,NULL,mapped16,&changed));
  CHECK(!memcmp(mapped16,range16,sizeof mapped16));
  s=identity();s.low_input=.875;s.high_input=.25;s.low_output=1;s.high_output=0;
  uint16_t rational=16020,rationalOut;float threeQuarters=.75f;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U16,&s,1,&rational,&threeQuarters,&rationalOut,&changed));
  CHECK(rationalOut==3569); /* exact selected result is 3568.5 */
  s=identity();s.high_input=DBL_TRUE_MIN;s.low_output=.5;
  uint8_t zero8=0,tinySpan8;uint16_t zero16=0,tinySpan16;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,1,&zero8,NULL,&tinySpan8,&changed) && tinySpan8==128);
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U16,&s,1,&zero16,NULL,&tinySpan16,&changed) && tinySpan16==32768);
  s.low_output=.75;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,1,&zero8,NULL,&tinySpan8,&changed) && tinySpan8==191);
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U16,&s,1,&zero16,NULL,&tinySpan16,&changed) && tinySpan16==49151);
  s=identity();s.gamma=2;
  uint8_t quarter8=64,q8;uint16_t quarter16=16384,q16;float half=.5f;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,1,&quarter8,NULL,&q8,&changed) && q8==128);
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,1,&quarter8,&half,&q8,&changed) && q8==96);
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U16,&s,1,&quarter16,NULL,&q16,&changed) && q16==32768);
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U16,&s,1,&quarter16,&half,&q16,&changed) && q16==24576);
}
static void float_oracles(void) {
  GlimsComponentLevels s=identity();bool changed=true;
  float in[]={-FLT_MAX,-0.0f,0,.25f,.5f,.75f,1,2,FLT_MAX},out[9];
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,9,in,NULL,out,&changed));
  CHECK(!changed && !memcmp(in,out,sizeof in));
  s.gamma=2;
  float values[]={.0625f,.25f,1,-.25f},mask[]={1,.5f,1,1},mapped[4];
  const float expected[]={.25f,.375f,1,-.25f};
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,4,values,mask,mapped,&changed));
  CHECK(changed && !memcmp(mapped,expected,sizeof mapped));
  s=identity();s.low_input=.5;s.high_input=.5;
  float equal[]={.75f,.25f},equalOut[2];
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,2,equal,NULL,equalOut,&changed));
  CHECK(equalOut[0]==.25f && equalOut[1]==-.25f);
  s.clamp_input=1;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,2,equal,NULL,equalOut,&changed));
  CHECK(equalOut[0]==.25f && equalOut[1]==0);
  s=identity();s.low_input=1;s.high_input=0;
  float extremes[]={FLT_MAX,-FLT_MAX,0x1p60f,-0x1p60f},half[]={.5f,.5f,.5f,.5f},halfOut[4];
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,4,extremes,half,halfOut,&changed));
  for(unsigned i=0;i<4;i++) CHECK(halfOut[i]==.5f);
  s=identity();s.low_output=1;s.high_output=0;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,4,extremes,half,halfOut,&changed));
  for(unsigned i=0;i<4;i++) CHECK(halfOut[i]==.5f);
  /* Exact cancellation before division: (1-c)I + c[1+(I/c)(c-1)] = c. */
  const float coverages[]={.75f,.6f,.875f,.3f};
  for(unsigned c=0;c<4;c++) {
    s=identity();s.high_input=coverages[c];s.low_output=1;s.high_output=coverages[c];
    float weights[]={coverages[c],coverages[c],coverages[c],coverages[c]};
    CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,4,extremes,weights,halfOut,&changed));
    for(unsigned i=0;i<4;i++) CHECK(halfOut[i]==coverages[c]);
  }
  s=identity();
  s.low_output=s.high_output=.25;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,4,extremes,NULL,halfOut,&changed));
  for(unsigned i=0;i<4;i++) CHECK(halfOut[i]==.25f);
  s=identity();s.clamp_input=1;
  float extended[]={-2,2},extendedOut[2];
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,2,extended,NULL,extendedOut,&changed));
  CHECK(extendedOut[0]==0 && extendedOut[1]==1);
  s.clamp_input=0;s.clamp_output=1;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,2,extended,NULL,extendedOut,&changed));
  CHECK(extendedOut[0]==0 && extendedOut[1]==1);
  float partial[]={.5f,.5f};
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,2,extended,partial,extendedOut,&changed));
  CHECK(extendedOut[0]==-1 && extendedOut[1]==1.5f);
  s=identity();s.low_input=.875;s.high_input=0;s.low_output=.125;s.high_output=0;s.clamp_input=1;
  float tiny=-1.4301510959957262e-31f, weight=.5f, tinyOut;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,1,&tiny,&weight,&tinyOut,&changed));
  CHECK(tinyOut==tiny*.5f);
  s=identity();s.low_input=.6;s.high_input=0;s.low_output=.3;s.high_output=0;s.clamp_output=1;
  tiny=3.126701687292062e-16f;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,1,&tiny,NULL,&tinyOut,&changed));
  CHECK(tinyOut==tiny*.5f);
  s=identity();s.low_input=nextafter(.5,1);s.high_input=.5;s.low_output=.3;s.high_output=1;s.clamp_input=s.clamp_output=1;
  tiny=.5f;weight=.875f;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,1,&tiny,&weight,&tinyOut,&changed));
  CHECK(tinyOut==.9375f);
  s=identity();s.low_input=s.low_output=.875;s.high_input=s.high_output=0;s.clamp_input=s.clamp_output=1;
  tiny=-1.2839001986861176e-17f;weight=.6f;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,1,&tiny,&weight,&tinyOut,&changed));
  CHECK(tinyOut==(float)((double)tiny*(1-(double)weight)));
  s=identity();s.gamma=.1;
  float oneHalf=.5f,result;
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,1,&oneHalf,NULL,&result,&changed));
  CHECK(fabsf(result-0x1p-10f)<0x1p-30f);
}
static void validation_and_storage(void) {
  GlimsComponentLevels s=identity();bool changed;
  float in[]={.25f,.5f,NAN},out[]={7,8,9},before[3];memcpy(before,out,sizeof out);
  CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,3,in,NULL,out,&changed));
  CHECK(!changed && !memcmp(before,out,sizeof out));
  float zeroMask[]={1,1,0};
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,3,in,zeroMask,out,&changed));
  CHECK(!changed && !memcmp(in,out,sizeof out));
  float badMasks[][3]={{1,1,NAN},{1,1,INFINITY},{1,1,-.01f},{1,1,1.01f}};
  for(unsigned i=0;i<4;i++) {
    memcpy(out,before,sizeof out);changed=true;
    CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,3,in,badMasks[i],out,&changed));
    CHECK(!changed && !memcmp(out,before,sizeof out));
  }
  double invalid[]={NAN,INFINITY,-INFINITY,-.01,1.01};
  for(unsigned field=0;field<4;field++) for(unsigned i=0;i<5;i++) {
    GlimsComponentLevels bad=identity();
    double *fields[]={&bad.low_input,&bad.high_input,&bad.low_output,&bad.high_output};
    *fields[field]=invalid[i];changed=true;
    CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&bad,0,NULL,NULL,NULL,&changed) && !changed);
  }
  double gammas[]={0,.099,10.01,NAN,INFINITY};
  for(unsigned i=0;i<5;i++) {
    s=identity();s.gamma=gammas[i];changed=true;
    CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,0,NULL,NULL,NULL,&changed) && !changed);
  }
  s=identity();s.clamp_input=2;
  CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,0,NULL,NULL,NULL,&changed));
  s=identity();s.clamp_output=2;
  CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,0,NULL,NULL,NULL,&changed));
  s=identity();
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,0,NULL,NULL,NULL,&changed) && !changed);
  CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,NULL,0,NULL,NULL,NULL,&changed));
  CHECK(!glims_component_levels_row((GlimsComponentScalarFormat)77,&s,0,NULL,NULL,NULL,&changed));
  CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,1,NULL,NULL,out,&changed));
  CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,1,in,NULL,NULL,&changed));
  CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,SIZE_MAX/sizeof(float)+1,in,NULL,out,&changed));
  CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_U8,&s,0,NULL,NULL,NULL,NULL));
  s.gamma=2;
  float inplace[]={.0625f,.25f,1};const float ipExpected[]={.25f,.5f,1};
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,3,inplace,NULL,inplace,&changed));
  CHECK(changed && !memcmp(inplace,ipExpected,sizeof inplace));
  unsigned char unaligned[20]={0},dest[20]={0};
  memcpy(unaligned+1,inplace,sizeof inplace);s=identity();
  CHECK(glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,3,unaligned+1,NULL,dest+3,&changed));
  CHECK(!changed && !memcmp(unaligned+1,dest+3,sizeof inplace));
  float huge=FLT_MAX, overflowOut=42;s.gamma=.1;
  CHECK(!glims_component_levels_row(GLIMS_COMPONENT_SCALAR_FLOAT,&s,1,&huge,NULL,&overflowOut,&changed));
  CHECK(!changed && overflowOut==42);
}
int main(void) {
  integer_oracles();float_oracles();validation_and_storage();
  printf("%u checks, %u failures\n",checks,failures);
  return failures?1:0;
}

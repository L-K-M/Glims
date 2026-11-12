/* Literal/rational scalar oracles, independent of the Curves implementation. */
#include "component-curves.h"
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; \
  fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)
#define ROW(f,c,n,s,m,d) glims_component_curves_row(f,c,n,s,m,d,&changed)

static GlimsComponentCurve identity_curve(void) {
  GlimsComponentCurve c;
  for (unsigned i=0;i<GLIMS_COMPONENT_CURVE_SAMPLES;i++)
    c.samples[i]=(double)i/(GLIMS_COMPONENT_CURVE_SAMPLES-1);
  return c;
}
static GlimsComponentCurve constant_curve(double v) {
  GlimsComponentCurve c;
  for (unsigned i=0;i<GLIMS_COMPONENT_CURVE_SAMPLES;i++) c.samples[i]=v;
  return c;
}
static GlimsComponentCurve invert_curve(void) {
  GlimsComponentCurve c;
  for (unsigned i=0;i<GLIMS_COMPONENT_CURVE_SAMPLES;i++)
    c.samples[i]=1-(double)i/255;
  return c;
}
/* Literal nonmonotone table: a peak, a zero dip and hand-picked segment
 * endpoints on an otherwise untouched linear ramp. */
static GlimsComponentCurve literal_curve(void) {
  GlimsComponentCurve c=identity_curve();
  c.samples[10]=1; c.samples[20]=0; c.samples[30]=.75; c.samples[200]=.5;
  c.samples[63]=.25; c.samples[64]=.5;
  c.samples[127]=.5; c.samples[128]=1;
  c.samples[191]=1; c.samples[192]=0;
  return c;
}

static void identity_oracles(void) {
  GlimsComponentCurve c=identity_curve(); bool changed=true;
  uint8_t all8[256],o8[256];
  for (unsigned i=0;i<256;i++) all8[i]=(uint8_t)i;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&c,256,all8,NULL,o8));
  CHECK(!changed && !memcmp(all8,o8,sizeof o8));
  for (unsigned base=0;base<65536;base+=256) {
    uint16_t block[256],out[256];
    for (unsigned i=0;i<256;i++) block[i]=(uint16_t)(base+i);
    CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&c,256,block,NULL,out));
    CHECK(!changed && !memcmp(block,out,sizeof out));
  }
  /* Extended floats and negative zero keep their source bytes. */
  float ef[]={-FLT_MAX,-0x1p60f,-0.0f,0.f,.25f,.5f,.75f,1.f,2.f,0x1p60f,FLT_MAX},eo[11];
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,11,ef,NULL,eo));
  CHECK(!changed && !memcmp(ef,eo,sizeof eo));
  /* Affected NaN/Inf samples reject even under identity. */
  float bad[][2]={{.25f,NAN},{.25f,INFINITY},{.25f,-INFINITY}};
  for (unsigned i=0;i<3;i++) {
    float out[2]; unsigned char before[sizeof out];
    memset(out,0xa5,sizeof out); memcpy(before,out,sizeof out);
    changed=true;
    CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,2,bad[i],NULL,out));
    CHECK(!changed && !memcmp(out,before,sizeof out));
  }
  /* Zero coverage copies arbitrary bytes, including NaN, Inf and -0. */
  uint32_t bits[]={0x7fc01234u,0x7f800000u,0x80000000u};
  float raw[3],zo[3]; float zmask[]={0,-0.0f,0};
  memcpy(raw,bits,sizeof raw);
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,3,raw,zmask,zo));
  CHECK(!changed && !memcmp(zo,bits,sizeof zo));
}

static void literal_oracles(void) {
  GlimsComponentCurve c=literal_curve(); bool changed;
  uint8_t in8[]={9,10,11,19,20,21,30,63,64,127,128,191,192,200},o8[14];
  const uint8_t ex8[]={9,255,11,19,0,21,191,64,128,128,255,255,0,128};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&c,14,in8,NULL,o8));
  CHECK(changed && !memcmp(o8,ex8,sizeof o8));
  /* Entries matching the ramp still byte-match: no phantom edits. */
  uint8_t same8[]={9,11},so8[2];
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&c,2,same8,NULL,so8));
  CHECK(!changed && !memcmp(so8,same8,sizeof same8));
  /* U16 subsegments: index v/257, remainder r/257 inside the segment.
   * v=2634: i=10,r=64 -> 255*(1*193 + (11/255)*64) = 49215+704 = 49919.
   * v=2826: i=10,r=256 -> 255*(1 + (11/255)*256) = 255+2816 = 3071.
   * v=5083: i=19,r=200 -> 255*((19/255)*57 + 0*200) = 19*57 = 1083.
   * v=5268: i=20,r=128 -> 255*(0*129 + (21/255)*128) = 21*128 = 2688.
   * v=7838: i=30,r=128 -> 255*(.75*129 + (31/255)*128) = 28639.25 -> 28639.
   * v=16319: i=63,r=128 -> 255*(.25*129 + .5*128) = 24543.75 -> 24544.
   * v=32767: i=127,r=128 -> 255*(.5*129 + 1*128) = 49087.5 -> 49088 (half up).
   * v=49215: i=191,r=128 -> 255*(1*129 + 0*128) = 32895.
   * Exact samples: 16191->16383.75, 32639->32767.5, ties round upward. */
  uint16_t in16[]={2570,2634,2826,5083,5140,5268,7838,
                   16191,16319,16448,32639,32767,32896,49087,49215,49344},o16[16];
  const uint16_t ex16[]={65535,49919,3071,1083,0,2688,28639,
                         16384,24544,32768,32768,49088,65535,65535,32895,0};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&c,16,in16,NULL,o16));
  CHECK(changed && !memcmp(o16,ex16,sizeof o16));
  /* Segment boundary r=0 lands back on the ramp: v=2313 maps to itself. */
  uint16_t same16=2313,so16;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&c,1,&same16,NULL,&so16));
  CHECK(!changed && so16==2313);
  /* Float interpolation: .25f->x=63.75 (.25+.75*.25), .5f->x=127.5 (.5+.5*.5),
   * .75f->x=191.25 (1-.25*1). The third lands on its original: no change. */
  float fi[]={.25f,.5f,.75f},fo[3];
  const float fe[]={.4375f,.75f,.75f};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,3,fi,NULL,fo));
  CHECK(changed && !memcmp(fo,fe,sizeof fo));
  float single=.75f,sout;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,1,&single,NULL,&sout));
  CHECK(!changed && sout==.75f);
  /* Non-dyadic input: (float)(21/510) places x=10.500000324100256 between
   * s[10]=1 and s[11]=11/255, giving 0.5215683173315198 in double. */
  float nd=(float)(21.0/510.0),ndout;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,1,&nd,NULL,&ndout));
  CHECK(changed && ndout==0.52156829833984375f);
  /* Extended floats read the endpoint entries: below 0 -> s[0]=0,
   * above 1 -> s[255]=1. */
  float ext[]={-0.3f,-2.f,-FLT_MAX,1.7f,2.f,FLT_MAX},exo[6];
  const float exe[]={0.f,0.f,0.f,1.f,1.f,1.f};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,6,ext,NULL,exo));
  CHECK(changed && !memcmp(exo,exe,sizeof exo));
  /* s[0]=0 maps -0.0 to a zero value equal to its source: bytes kept. */
  float negz=-0.0f,nzout;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,1,&negz,NULL,&nzout));
  CHECK(!changed && !memcmp(&negz,&nzout,sizeof nzout));
  /* Per-element coverage: mask rows blend each sample once. */
  float mi[]={.5f,.5f,.5f,.5f}; float mm[]={0,.25f,.5f,1}; float mo[4];
  const float me[]={.5f,.5625f,.625f,.75f};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,4,&mi,mm,mo));
  CHECK(changed && !memcmp(mo,me,sizeof mo));
  /* The same coverage cycle on U8 input 10: copies, 10+.25*245=71.25,
   * 10+.5*245=132.5 and 255. */
  uint8_t row8[1024]; uint8_t o8b[1024]; float cyc[4]={0,.25f,.5f,1};
  memset(row8,10,sizeof row8);
  {
    float bigmask[1024];
    for (unsigned i=0;i<1024;i++) bigmask[i]=cyc[i%4];
    CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&c,1024,row8,bigmask,o8b));
  }
  CHECK(changed);
  {
    const uint8_t want[4]={10,71,133,255};
    for (unsigned i=0;i<1024;i++) CHECK(o8b[i]==want[i%4]);
  }
  /* A bounded larger row stays deterministic: every 2634 -> 49919. */
  {
    uint16_t big[8192],bigout[8192];
    for (unsigned i=0;i<8192;i++) big[i]=2634;
    CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&c,8192,big,NULL,bigout));
    CHECK(changed);
    for (unsigned i=0;i<8192;i++) CHECK(bigout[i]==49919);
  }
}

static void invert_and_constant(void) {
  bool changed;
  GlimsComponentCurve inv=invert_curve();
  uint8_t i8[]={0,1,127,128,254,255},o8[6];
  const uint8_t ie8[]={255,254,128,127,1,0};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&inv,6,i8,NULL,o8));
  CHECK(changed && !memcmp(o8,ie8,sizeof o8));
  uint16_t i16[]={0,1,32767,32768,65534,65535},o16[6];
  const uint16_t ie16[]={65535,65534,32768,32767,1,0};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&inv,6,i16,NULL,o16));
  CHECK(changed && !memcmp(o16,ie16,sizeof o16));
  float iv[]={.25f,.5f,.75f,-2.f,2.f,-FLT_MAX,FLT_MAX},ivo[7];
  const float ive[]={.75f,.5f,.25f,1.f,0.f,1.f,0.f};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&inv,7,iv,NULL,ivo));
  CHECK(changed && !memcmp(ivo,ive,sizeof ivo));
  /* Half coverage on inverted extremes: -FLT_MAX blends toward s[0]=1,
   * +FLT_MAX toward s[255]=0; both land on FLT_MAX/2 = 0x1.fffffep126f. */
  float extremes[]={-FLT_MAX,FLT_MAX}; float half[]={.5f,.5f},ho[2];
  const float he[]={-0x1.fffffep126f,0x1.fffffep126f};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&inv,2,extremes,half,ho));
  CHECK(changed && !memcmp(ho,he,sizeof ho));
  /* -0.0 under inversion maps to s[0]=1. */
  float nz=-0.0f,nzout;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&inv,1,&nz,NULL,&nzout));
  CHECK(changed && nzout==1.f);
  /* Quarter coverage: v0 -> .25*255 = 63.75 -> 64, v255 -> 191.25 -> 191. */
  uint8_t q8[]={0,255},qo8[2]; float qm[]={.25f,.25f};
  const uint8_t qe8[]={64,191};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&inv,2,q8,qm,qo8));
  CHECK(changed && !memcmp(qo8,qe8,sizeof qo8));
  uint16_t q16[]={0,65535},qo16[2];
  const uint16_t qe16[]={16384,49151};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&inv,2,q16,qm,qo16));
  CHECK(changed && !memcmp(qo16,qe16,sizeof qo16));
  /* Half coverage tie: (0+65535)/2 = 32767.5 rounds up to 32768. */
  float hm[]={.5f,.5f}; uint16_t hv[]={0,65535},hvo[2];
  const uint16_t hve[]={32768,32768};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&inv,2,hv,hm,hvo));
  CHECK(changed && !memcmp(hvo,hve,sizeof hvo));
  float one=.25f; float wm[]={.25f}; float wout;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&inv,1,&one,wm,&wout));
  CHECK(changed && wout==.375f);

  GlimsComponentCurve half5=constant_curve(.5);
  uint8_t c8[]={0,1,127,128,254,255},co8[6];
  const uint8_t ce8[]={128,128,128,128,128,128}; /* 127.5 ties upward. */
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&half5,6,c8,NULL,co8));
  CHECK(changed && !memcmp(co8,ce8,sizeof co8));
  uint16_t c16[]={0,1,65535},co16[3];
  const uint16_t ce16[]={32768,32768,32768};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&half5,3,c16,NULL,co16));
  CHECK(changed && !memcmp(co16,ce16,sizeof co16));
  float cf[]={0.f,.5f,2.f,-1.f,FLT_MAX,-FLT_MAX},cfo[6];
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&half5,6,cf,NULL,cfo));
  CHECK(changed);
  for (unsigned i=0;i<6;i++) CHECK(cfo[i]==.5f);
  /* Mask .5 under constant .5: (v+127.5)/2 -> 64, 64, 191. */
  uint8_t m8[]={0,1,255},mo8[3]; float mhalf[]={.5f,.5f,.5f};
  const uint8_t me8[]={64,64,191};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&half5,3,m8,mhalf,mo8));
  CHECK(changed && !memcmp(mo8,me8,sizeof mo8));
  uint16_t m16[]={0,1,65535},mo16[3];
  const uint16_t me16[]={16384,16384,49151};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&half5,3,m16,mhalf,mo16));
  CHECK(changed && !memcmp(mo16,me16,sizeof mo16));
  /* A sample that already equals the target reports no change: v=128 -> 128. */
  uint8_t same=128,sameout;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&half5,1,&same,NULL,&sameout));
  CHECK(!changed && sameout==128);
  GlimsComponentCurve quarter=constant_curve(.25);
  uint8_t qv=0,qo; uint16_t qv16=0,qo16s;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&quarter,1,&qv,NULL,&qo));
  CHECK(changed && qo==64);
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&quarter,1,&qv16,NULL,&qo16s));
  CHECK(changed && qo16s==16384);
}

static void atomic_failures(void) {
  GlimsComponentCurve c=literal_curve(); bool changed;
  /* Late invalid source, mask or table entry leaves the whole row intact. */
  float bad_src[]={.25f,.5f,NAN};
  float bad_inf[]={.25f,.5f,-INFINITY};
  float good_src[]={.25f,.5f,.75f};
  float bad_masks[][3]={{1,1,NAN},{1,1,INFINITY},{1,1,-.01f},{1,1,1.01f}};
  float out[3]; unsigned char before[sizeof out];
  memset(out,0xa5,sizeof out); memcpy(before,out,sizeof out);
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,3,bad_src,NULL,out));
  CHECK(!changed && !memcmp(out,before,sizeof out));
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,3,bad_inf,NULL,out));
  CHECK(!changed && !memcmp(out,before,sizeof out));
  for (unsigned i=0;i<4;i++) {
    changed=true;
    CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,3,good_src,bad_masks[i],out));
    CHECK(!changed && !memcmp(out,before,sizeof out));
  }
  /* Late-invalid table entries reject the call, even at count zero. */
  uint8_t ok8[]={9,10,11};
  double badvals[]={NAN,INFINITY,-INFINITY,-.01,1.01};
  for (unsigned i=0;i<5;i++) {
    GlimsComponentCurve bad=identity_curve();
    bad.samples[255]=badvals[i];
    changed=true;
    CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,&bad,3,ok8,NULL,out));
    CHECK(!changed && !memcmp(out,before,sizeof out));
    bad.samples[255]=0; bad.samples[37]=badvals[i];
    changed=true;
    CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,&bad,0,NULL,NULL,NULL));
    CHECK(!changed);
  }
  /* In-place failure leaves the shared buffer untouched. */
  float inplace_bad[]={.25f,.5f,NAN},saved[3];
  memcpy(saved,inplace_bad,sizeof saved);
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,3,inplace_bad,NULL,inplace_bad));
  CHECK(!changed && !memcmp(inplace_bad,saved,sizeof saved));
  /* Integer rows still validate a bad late float mask. */
  uint8_t bad8out[3]; float badmask[]={1,NAN,1};
  memset(bad8out,0xa5,sizeof bad8out);
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,&c,3,ok8,badmask,bad8out));
  unsigned char zeros[3]={0xa5,0xa5,0xa5};
  CHECK(!changed && !memcmp(bad8out,zeros,sizeof bad8out));
}

static void storage_and_requests(void) {
  GlimsComponentCurve c=literal_curve(),id=identity_curve(); bool changed;
  /* In-place mapping succeeds through the supported exact overlap. */
  float ip[]={.25f,.5f,.75f};
  GlimsComponentCurve inv=invert_curve();
  const float ipe[]={.75f,.5f,.25f};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&inv,3,ip,NULL,ip));
  CHECK(changed && !memcmp(ip,ipe,sizeof ip));
  uint8_t ip8[]={10,20,30};
  const uint8_t ip8e[]={255,0,191};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&c,3,ip8,NULL,ip8));
  CHECK(changed && !memcmp(ip8,ip8e,sizeof ip8));
  /* Unaligned source and destination go through memcpy. */
  unsigned char usrc[9],udst[16];
  uint16_t near_end[]={2570,2826,65535};
  memcpy(usrc+1,near_end,sizeof near_end);
  const uint16_t uexp[]={65535,3071,65535};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U16,&c,3,usrc+1,NULL,udst+3));
  {
    uint16_t got[3]; memcpy(got,udst+3,sizeof got);
    CHECK(changed && !memcmp(got,uexp,sizeof got));
  }
  float uf[]={.25f,.75f};
  memcpy(usrc+1,uf,sizeof uf);
  const float ufe[]={.4375f,.75f};
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,2,usrc+1,NULL,udst+5));
  {
    float got[2]; memcpy(got,udst+5,sizeof got);
    CHECK(changed && !memcmp(got,ufe,sizeof got));
  }
  /* Zero count: NULL buffers allowed, parameters still validated. */
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&c,0,NULL,NULL,NULL) && !changed);
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&id,0,NULL,NULL,NULL) && !changed);
  {
    GlimsComponentCurve bad=identity_curve(); bad.samples[100]=1.5;
    changed=true;
    CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,&bad,0,NULL,NULL,NULL) && !changed);
  }
  /* Malformed requests reject and clear changed. */
  uint8_t one8=9,o8; float onef=.5f,of; float mask1=1;
  changed=true;
  CHECK(!ROW((GlimsComponentScalarFormat)99,&c,0,NULL,NULL,NULL) && !changed);
  changed=true;
  CHECK(!ROW((GlimsComponentScalarFormat)-1,&c,1,&one8,NULL,&o8) && !changed);
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,NULL,0,NULL,NULL,NULL) && !changed);
  CHECK(!glims_component_curves_row(GLIMS_COMPONENT_SCALAR_U8,&c,0,NULL,NULL,NULL,NULL));
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,&c,1,NULL,NULL,&o8) && !changed);
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,&c,1,&one8,NULL,NULL) && !changed);
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,SIZE_MAX/sizeof(float)+1,&onef,NULL,&of) && !changed);
  changed=true;
  CHECK(!ROW(GLIMS_COMPONENT_SCALAR_U8,&c,SIZE_MAX/sizeof(float)+1,&one8,&mask1,&o8) && !changed);
  /* A NULL mask behaves like full coverage; an explicit 1 mask matches it. */
  float mv=.5f,mout1,mout2;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,1,&mv,&mask1,&mout1));
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_FLOAT,&c,1,&mv,NULL,&mout2));
  CHECK(mout1==.75f && mout1==mout2);
  /* Identity also reports no change on the whole byte range in-place. */
  uint8_t all[256];
  for (unsigned i=0;i<256;i++) all[i]=(uint8_t)i;
  CHECK(ROW(GLIMS_COMPONENT_SCALAR_U8,&id,256,all,NULL,all));
  CHECK(!changed);
  for (unsigned i=0;i<256;i++) CHECK(all[i]==i);
}

int main(void) {
  identity_oracles();
  literal_oracles();
  invert_and_constant();
  atomic_failures();
  storage_and_requests();
  printf("Curves literals: %u checks, %u failures\n",checks,failures);
  return failures?1:0;
}

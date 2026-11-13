#include "lab-layer-composite.h"
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c); } } while (0)

static void pixel(const void *row, size_t x, double l, double a, double b, double alpha)
{
  double actual[4], expected[4] = {l,a,b,alpha};
  memcpy(actual, (const unsigned char *)row + x * sizeof actual, sizeof actual);
  for (unsigned i=0;i<4;i++) {
    CHECK(isfinite(actual[i]) && fabs(actual[i]-expected[i]) <= (i==3 ? 1e-15 : 1e-12));
    if (expected[i]==0 && alpha==0) CHECK(actual[i]==0 && !signbit(actual[i]));
  }
}

static void literals(void)
{
  /* Independent rational witnesses. Top effective alpha=64/255. */
  uint8_t q[2][4]={{255,255,0,128},{0,0,255,255}};
  GlimsLabLayerCompositeLayer rows[2]={{&q[0][0],&q[0][1],&q[0][2],&q[0][3],.5},
                                     {&q[1][0],&q[1][1],&q[1][2],&q[1][3],1}};
  unsigned char destination[34]; memset(destination,0xA5,sizeof destination);
  CHECK(glims_lab_layer_composite_row(2,1,rows,destination+1));
  pixel(destination+1,0,1280.0/51,-64,63,1);
  CHECK(destination[0]==0xA5 && destination[33]==0xA5);
  GlimsLabLayerCompositeLayer reversed[2]={rows[1],rows[0]};
  CHECK(glims_lab_layer_composite_row(2,1,reversed,destination+1));
  pixel(destination+1,0,0,-128,127,1);
  q[1][3]=128; rows[1].opacity=.5;
  CHECK(glims_lab_layer_composite_row(2,1,rows,destination+1));
  pixel(destination+1,0,12750.0/223,7937.0/446,-8383.0/446,28544.0/65025);

  /* Positive subnormal coverage preserves one-layer straight color. */
  q[0][0]=1; q[0][1]=1; q[0][2]=255; q[0][3]=255; rows[0].opacity=DBL_TRUE_MIN;
  CHECK(glims_lab_layer_composite_row(1,1,rows,destination+1));
  pixel(destination+1,0,100.0/255,-127,127,DBL_TRUE_MIN);
  double alpha; memcpy(&alpha,destination+1+3*sizeof(double),sizeof alpha);
  CHECK(alpha==DBL_TRUE_MIN);
  q[0][3]=1; /* Effective alpha itself rounds to zero in binary64. */
  CHECK(glims_lab_layer_composite_row(1,1,rows,destination+1));
  pixel(destination+1,0,0,0,0,0);
}

static void immutable_inputs(void)
{
  uint8_t planes[2][4][4]={{{1,2,3,4},{5,6,7,8},{9,10,11,12},{0,128,255,255}},
                          {{240,220,200,180},{170,150,130,110},{90,70,50,30},{255,128,0,255}}};
  uint8_t before[sizeof planes]; memcpy(before,planes,sizeof planes);
  GlimsLabLayerCompositeLayer rows[2]={{planes[0][0],planes[0][1],planes[0][2],planes[0][3],1},
                                     {planes[1][0],planes[1][1],planes[1][2],planes[1][3],.5}};
  unsigned char descriptors[sizeof rows]; memcpy(descriptors,rows,sizeof rows);
  double out[16]; CHECK(glims_lab_layer_composite_row(2,4,rows,out));
  CHECK(!memcmp(before,planes,sizeof planes) && !memcmp(descriptors,rows,sizeof rows));
  rows[0].opacity=0; rows[1].opacity=0;
  CHECK(glims_lab_layer_composite_row(2,4,rows,out));
  for(unsigned i=0;i<4;i++) pixel(out,i,0,0,0,0);
  CHECK(!memcmp(before,planes,sizeof planes));
  /* All four planes and both descriptors may alias the same byte buffer. */
  uint8_t shared[4]={255,128,0,1};
  rows[0]=(GlimsLabLayerCompositeLayer){shared,shared,shared,shared,1}; rows[1]=rows[0];
  CHECK(glims_lab_layer_composite_row(2,4,rows,out));
  pixel(out,0,100,127,127,1); pixel(out,2,0,0,0,0);
  CHECK(shared[0]==255 && shared[1]==128 && shared[2]==0 && shared[3]==1);
}

static void validation(void)
{
  double out[64]; memset(out,0xA5,sizeof out);
  unsigned char before[sizeof out]; memcpy(before,out,sizeof out);
  uint8_t plane[8]={255};
  GlimsLabLayerCompositeLayer rows[2]={{plane,plane,plane,plane,1},{plane,plane,plane,plane,1}};
#define REFUSE(n,w,r) do { CHECK(!glims_lab_layer_composite_row((n),(w),(r),out)); CHECK(!memcmp(before,out,sizeof out)); } while(0)
  REFUSE(257,1,NULL); REFUSE(0,4097,NULL); REFUSE(SIZE_MAX,1,NULL); REFUSE(0,SIZE_MAX,NULL);
  REFUSE(1,1,NULL); REFUSE(1,0,NULL);
  CHECK(!glims_lab_layer_composite_row(1,1,rows,NULL));
  CHECK(glims_lab_layer_composite_row(0,0,NULL,NULL));
  GlimsLabLayerCompositeLayer empty[2]={{NULL,NULL,NULL,NULL,0},{NULL,NULL,NULL,NULL,1}};
  CHECK(glims_lab_layer_composite_row(2,0,empty,NULL));
  const double invalid[]={NAN,INFINITY,-INFINITY,-.01,1.01};
  for(unsigned i=0;i<sizeof invalid/sizeof *invalid;i++) {
    rows[1].opacity=invalid[i]; REFUSE(2,1,rows); REFUSE(2,0,rows);
  }
  rows[1].opacity=1;
  const uint8_t **slots[4]={&rows[1].l,&rows[1].a,&rows[1].b,&rows[1].alpha};
  for(unsigned i=0;i<4;i++) {
    *slots[i]=NULL; REFUSE(2,1,rows); *slots[i]=plane;
    *slots[i]=(const uint8_t *)(uintptr_t)(UINTPTR_MAX-2); REFUSE(2,8,rows); *slots[i]=plane;
  }
  CHECK(!glims_lab_layer_composite_row(2,0,(const GlimsLabLayerCompositeLayer *)(uintptr_t)(UINTPTR_MAX-8),NULL));
  CHECK(!glims_lab_layer_composite_row(1,8,rows,(void *)(uintptr_t)(UINTPTR_MAX-8)));
  CHECK(!memcmp(before,out,sizeof out));
#undef REFUSE
}

static void overlap(void)
{
  uint8_t arena[512], before[512], samples[4][4]={{1,2,3,4},{128,128,128,128},{127,127,127,127},{255,255,255,255}};
  GlimsLabLayerCompositeLayer rows[2]={{samples[0],samples[1],samples[2],samples[3],1},
                                     {samples[0],samples[1],samples[2],samples[3],0}};
  const uint8_t **slots[4]={&rows[1].l,&rows[1].a,&rows[1].b,&rows[1].alpha};
  /* Every plane is checked even below an opaque first layer, at opacity0. */
  for(unsigned i=0;i<4;i++) {
    memset(arena,0xA5,sizeof arena); memcpy(before,arena,sizeof arena);
    *slots[i]=arena+128;
    const unsigned positions[]={128,127,131};
    for(unsigned j=0;j<3;j++) {
      CHECK(!glims_lab_layer_composite_row(2,4,rows,arena+positions[j]));
      CHECK(!memcmp(before,arena,sizeof arena));
    }
    *slots[i]=samples[i];
  }
  /* Properly aligned descriptors inside an arena large enough for output. */
  union { max_align_t alignment; unsigned char bytes[512]; } storage;
  memset(&storage,0x5A,sizeof storage);
  GlimsLabLayerCompositeLayer *descriptors=(void *)storage.bytes;
  memcpy(descriptors,rows,sizeof rows);
  unsigned char saved[sizeof storage]; memcpy(saved,&storage,sizeof storage);
  CHECK(!glims_lab_layer_composite_row(2,4,descriptors,storage.bytes));
  CHECK(!memcmp(saved,&storage,sizeof storage));
  CHECK(!glims_lab_layer_composite_row(2,4,descriptors,storage.bytes+sizeof rows-1));
  CHECK(!memcmp(saved,&storage,sizeof storage));
}

static void limits(void)
{
  static uint8_t plane[GLIMS_LAB_LAYER_COMPOSITE_MAX_WIDTH];
  uint8_t before[sizeof plane];
  for(size_t x=0;x<sizeof plane;x++) plane[x]=(uint8_t)x;
  memcpy(before,plane,sizeof plane);
  GlimsLabLayerCompositeLayer rows[GLIMS_LAB_LAYER_COMPOSITE_MAX_LAYERS];
  for(size_t i=0;i<256;i++) rows[i]=(GlimsLabLayerCompositeLayer){plane,plane,plane,plane,i==255 ? 1:0};
  double *out=malloc(4096*4*sizeof(double)); CHECK(out!=NULL); if(!out)return;
  CHECK(glims_lab_layer_composite_row(256,4096,rows,out));
  for(size_t x=0;x<4096;x++) {
    unsigned q=plane[x];
    if(q) pixel(out,x,100.0*q/255,(double)q-128,(double)q-128,(double)q/255);
    else pixel(out,x,0,0,0,0);
  }
  CHECK(!memcmp(plane,before,sizeof plane));
  CHECK(glims_lab_layer_composite_row(0,4096,NULL,out));
  for(size_t x=0;x<4096;x++) pixel(out,x,0,0,0,0);
  free(out);
}

int main(void)
{
  literals(); immutable_inputs(); validation(); overlap(); limits();
  printf("Lab layer composite: %u checks, %u failures\n",checks,failures);
  return failures ? 1:0;
}

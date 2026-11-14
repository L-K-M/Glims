#include "bitmap-diffusion.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c, label) do { bool ok=!!(c); checks++; failures+=!ok; \
  printf("%s %s\n",ok?"ok":"FAIL",label); } while (0)
int main(void)
{
  GlimsBitmapDiffusion state={0};
  CHECK(!glims_bitmap_diffusion_begin(NULL,1,1) && !glims_bitmap_diffusion_begin(&state,0,1) &&
        !glims_bitmap_diffusion_begin(&state,1,0) && !glims_bitmap_diffusion_begin(&state,30001,1), "invalid dimensions refuse");
  CHECK(glims_bitmap_diffusion_begin(&state,5,3), "begin bounded image");
  CHECK(!glims_bitmap_diffusion_begin(&state,5,3), "a live state cannot be reinitialized");
  const float row[]={0,0.25f,0.5f,0.75f,1};
  const uint8_t expected[]={0,0,255,255,255, 0,0,0,255,255, 0,0,255,255,255};
  uint8_t actual[15]={0};
  CHECK(!glims_bitmap_diffusion_apply(&state,0,1,1,row,actual), "out-of-order chunk refuses");
  float invalid[]={0.5f,NAN}; uint8_t guard[]={37,38};
  CHECK(!glims_bitmap_diffusion_apply(&state,0,0,2,invalid,guard) && guard[0]==37 && guard[1]==38 &&
        state.next_x==0 && state.next_y==0, "nonfinite input leaves the entire chunk and state untouched");
  invalid[1]=1.01f;
  CHECK(!glims_bitmap_diffusion_apply(&state,0,0,2,invalid,guard) && state.next_x==0,
        "out-of-range input leaves state untouched");
  bool okay=true;
  for (uint32_t y=0;y<3;y++) {
    okay &= glims_bitmap_diffusion_apply(&state,y,0,2,row,actual+y*5);
    okay &= glims_bitmap_diffusion_apply(&state,y,2,3,row+2,actual+y*5+2);
  }
  CHECK(okay && !memcmp(actual,expected,sizeof actual), "chunked gradient matches independent rational oracle");
  CHECK(!glims_bitmap_diffusion_apply(&state,3,0,1,row,actual), "completed image rejects more samples");
  glims_bitmap_diffusion_end(&state); glims_bitmap_diffusion_end(&state);
  CHECK(!state.current && !state.next && !state.width, "end is idempotent and clears state");
  CHECK(glims_bitmap_diffusion_begin(&state,4,4), "begin half-gray image");
  const float half[]={0.5f,0.5f,0.5f,0.5f};
  const uint8_t checker[]={255,0,255,0, 0,255,0,255, 255,0,255,0, 0,255,0,255};
  uint8_t output[16]; okay=true;
  for(uint32_t y=0;y<4;y++) okay &= glims_bitmap_diffusion_apply(&state,y,0,4,half,output+y*4);
  CHECK(okay && !memcmp(output,checker,sizeof output), "half-gray produces the independent checkerboard");
  glims_bitmap_diffusion_end(&state);
  CHECK(glims_bitmap_diffusion_begin(&state,1,4), "begin a one-pixel-wide image");
  const uint8_t column_expected[]={255,0,255,0};
  uint8_t column[4]; okay=true;
  for(uint32_t y=0;y<4;y++) okay &= glims_bitmap_diffusion_apply(&state,y,0,1,half,column+y);
  CHECK(okay && !memcmp(column,column_expected,sizeof column), "single-pixel rows keep error within image bounds");
  glims_bitmap_diffusion_end(&state);
  CHECK(glims_bitmap_diffusion_begin(&state,5001,1), "begin a row wider than the PSD streaming chunk");
  float *wide = malloc(5001u * sizeof *wide); uint8_t *wide_output = malloc(5001u);
  if (!wide || !wide_output) return 2;
  for (size_t i=0;i<5001;i++) wide[i]=1.0f;
  wide[4095]=wide[4096]=wide[4097]=0.5f;
  okay=glims_bitmap_diffusion_apply(&state,0,0,4096,wide,wide_output) &&
       glims_bitmap_diffusion_apply(&state,0,4096,905,wide+4096,wide_output+4096);
  for (size_t i=0;i<5001;i++) okay &= wide_output[i] == (i==4096 ? 0 : 255);
  CHECK(okay, "diffusion carries error across the 4096-pixel chunk boundary");
  free(wide); free(wide_output); glims_bitmap_diffusion_end(&state);
  CHECK(glims_bitmap_diffusion_begin(&state,30000,30000), "maximum supported dimensions allocate only two rows");
  glims_bitmap_diffusion_end(&state);
  printf("%u checks, %u failures\n",checks,failures);
  return failures ? 1 : 0;
}

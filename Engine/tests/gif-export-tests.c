/* Facade-only still-GIF checks with an independent bounded container parser. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int checks, failures;
#define NEED(c) do { if (!(c)) { fprintf(stderr,"fixture failure at line %d\n",__LINE__); exit(2); } } while (0)
#define CHECK(c,label) do { int ok=!!(c); checks++; failures+=!ok; printf("%s %s\n",ok?"ok":"FAIL",label); fflush(stdout); } while (0)
#define OK(call) NEED((call)==GLIMS_STATUS_OK)
static unsigned le16(const unsigned char *p) { return p[0] | (unsigned)p[1]<<8; }
static unsigned char *read_file(const char *path, size_t *size) {
  FILE *f=fopen(path,"rb"); NEED(f); NEED(!fseek(f,0,SEEK_END)); long n=ftell(f); NEED(n>=0 && n<1024*1024);
  rewind(f); unsigned char *bytes=malloc((size_t)n+1); NEED(bytes); NEED(fread(bytes,1,(size_t)n,f)==(size_t)n); fclose(f); *size=(size_t)n; return bytes;
}
static void subblocks(const unsigned char *b,size_t n,size_t *p) {
  for (;;) { NEED(*p<n); unsigned count=b[(*p)++]; NEED(count<=n-*p); *p+=count; if(!count)return; }
}
static void inspect(const char *path,int width,int height) {
  size_t n=0; unsigned char *b=read_file(path,&n);
  NEED(n>=13); CHECK(!memcmp(b,"GIF87a",6)||!memcmp(b,"GIF89a",6),"GIF signature identifies the requested format");
  CHECK(le16(b+6)==(unsigned)width && le16(b+8)==(unsigned)height,"GIF little-endian dimensions equal the visible canvas");
  size_t p=13; if(b[10]&128)p+=3u*(1u<<((b[10]&7)+1)); NEED(p<=n);
  int frames=0, interlace=0, loops=0, trailer=0;
  while(p<n) {
    unsigned kind=b[p++];
    if(kind==0x3b) { trailer=1; break; }
    if(kind==0x21) {
      NEED(p<n); unsigned label=b[p++];
      if(label==0xff && n-p>=12 && b[p]==11 && !memcmp(b+p+1,"NETSCAPE2.0",11))loops++;
      subblocks(b,n,&p);
    } else if(kind==0x2c) {
      NEED(n-p>=9); unsigned packed=b[p+8]; frames++; interlace+=(packed&64)!=0; p+=9;
      if(packed&128)p+=3u*(1u<<((packed&7)+1)); NEED(p<n); p++; subblocks(b,n,&p);
    } else NEED(0);
  }
  CHECK(trailer && frames==1 && !loops,"GIF has exactly one still frame and no looping extension");
  CHECK(!interlace,"GIF frame is non-interlaced"); free(b);
}
static GlimsExportSettings settings(void) {
  return (GlimsExportSettings){.struct_size=sizeof(GlimsExportSettings),.format=GLIMS_EXPORT_GIF,
    .jpeg_quality=.9,.jpeg_progressive=1,.jpeg_optimize=1,.png_compression=9,.tiff_preserve_transparent_color=1};
}
static void roundtrip(GlimsImageID image,const char *path,const unsigned char *expected) {
  GlimsImageInfo i0={0},i1={0}; GlimsUndoInfo u0={0},u1={0}; GlimsHistoryInfo h0={0},h1={0};
  GlimsColorInfo c0={0},c1={0};
  GlimsLayerInfo l0[16]={0},l1[16]={0}; int32_t n0=0,n1=0;
  GlimsPixelBuffer before={0},after={0},raw0={0},raw1={0};
  OK(api->image_info(engine,image,&i0)); OK(api->image_undo_info(engine,image,&u0)); OK(api->image_history(engine,image,NULL,0,&h0));
  OK(api->image_color_info(engine,image,&c0));
  OK(api->image_layers(engine,image,l0,16,&n0)); OK(api->image_copy_pixels(engine,image,true,&before,NULL)); OK(api->image_copy_pixels(engine,image,false,&raw0,NULL));
  GlimsExportSettings s=settings(); char *error=NULL;
  GlimsStatus status=api->image_export_configured(engine,image,path,&s,&error);
  if(error) { printf("export: %s\n",error); api->free_string(error); }
  CHECK(status==GLIMS_STATUS_OK,"configured still GIF export succeeds");
  if(status==GLIMS_STATUS_OK) {
    inspect(path,i0.width,i0.height);
    GlimsImageID reopened=0; OK(api->image_open(engine,path,&reopened,NULL));
    GlimsImageInfo ri={0}; OK(api->image_info(engine,reopened,&ri)); CHECK(ri.layer_count==1,"GIF reopens as one layer from the visible projection");
    GlimsPixelBuffer pixels={0}; OK(api->image_copy_pixels(engine,reopened,true,&pixels,NULL));
    const unsigned char *wanted=expected?expected:before.pixels; int match=pixels.byte_count==before.byte_count,maximum=0;
    if(match)for(size_t k=0;k<before.byte_count;k+=4) {
      unsigned alpha=wanted[k+3]<128?0:255;
      if(pixels.pixels[k+3]!=alpha)match=0;
      if(alpha)for(size_t c=0;c<3;c++) { int d=abs(pixels.pixels[k+c]-wanted[k+c]); if(d>maximum)maximum=d; }
    }
    printf("GIF color maximum difference: %d\n",maximum);
    CHECK(match && maximum<=2,"GIF retains expected small-palette sRGB colors and thresholds alpha at 50 percent");
    api->free_pixels(pixels.pixels); OK(api->image_close(engine,reopened));
  }
  OK(api->image_info(engine,image,&i1)); OK(api->image_undo_info(engine,image,&u1)); OK(api->image_history(engine,image,NULL,0,&h1));
  OK(api->image_color_info(engine,image,&c1));
  OK(api->image_layers(engine,image,l1,16,&n1)); OK(api->image_copy_pixels(engine,image,true,&after,NULL)); OK(api->image_copy_pixels(engine,image,false,&raw1,NULL));
  CHECK(i0.width==i1.width && i0.height==i1.height && i0.dirty==i1.dirty && !strcmp(i0.precision,i1.precision),"GIF preserves source dimensions, precision and dirty state");
  CHECK(!memcmp(&c0,&c1,sizeof c0),"GIF preserves source color mode, precision and profile state");
  CHECK(u0.undo_count==u1.undo_count && u0.redo_count==u1.redo_count && h0.revision==h1.revision && h0.current_position==h1.current_position && h0.count==h1.count,"GIF preserves Undo/Redo and history revision");
  CHECK(n0==n1 && !memcmp(l0,l1,sizeof l0),"GIF preserves source layer identities, properties and selection");
  CHECK(before.byte_count==after.byte_count && !memcmp(before.pixels,after.pixels,before.byte_count) && raw0.byte_count==raw1.byte_count && !memcmp(raw0.pixels,raw1.pixels,raw0.byte_count),"GIF preserves source composite and raw pixels exactly");
  api->free_pixels(before.pixels); api->free_pixels(after.pixels); api->free_pixels(raw0.pixels); api->free_pixels(raw1.pixels);
}
int main(int argc,char **argv) {
  NEED(argc==4); void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
  GlimsEngineGetAPIFunction get=(GlimsEngineGetAPIFunction)dlsym(lib,"glims_engine_get_api"); api=get?get(GLIMS_ENGINE_API_VERSION):NULL; NEED(api && api->struct_size>=sizeof *api);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=argv[2],.cache_directory=argv[2]}; OK(api->start(&config,&engine,NULL));
  const unsigned char base[]={255,0,0,255, 0,255,0,64, 0,0,255,255, 255,255,255,255, 10,20,30,0, 0,0,0,192};
  const unsigned char top[]={0,255,255,255, 255,0,255,255};
  const unsigned char expected[]={0,255,255,255, 0,0,0,0, 0,0,255,255, 255,0,255,255, 0,0,0,0, 0,0,0,255};
  GlimsImageID image=0; OK(api->image_from_pixels(engine,3,2,base,sizeof base,&image,NULL)); GlimsItemID layer=0;
  OK(api->image_paste_pixels(engine,image,(GlimsRect){0,0,1,2},top,sizeof top,&layer,NULL));
  char path[4096]; snprintf(path,sizeof path,"%s/layered.gif",argv[2]); roundtrip(image,path,expected);
  snprintf(path,sizeof path,"%s/keep.png",argv[2]); FILE *f=fopen(path,"wb"); NEED(f); NEED(fwrite("keep",1,4,f)==4); fclose(f);
  GlimsExportSettings s=settings(); CHECK(api->image_export_configured(engine,image,path,&s,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"GIF refuses a mismatched filename");
  size_t n=0; unsigned char *kept=read_file(path,&n); CHECK(n==4 && !memcmp(kept,"keep",4),"GIF refusal preserves existing destination bytes"); free(kept);
  OK(api->image_close(engine,image));
  /* Low-count midtone palette catches lost profile conversion as well as
   * primary colors which can mask profile mistakes by clipping to the gamut. */
  const unsigned char colors[]={90,120,60,255, 170,80,100,255, 50,75,120,255, 130,160,180,255, 100,100,100,255, 210,150,70,255};
  for(int kind=0;kind<5;kind++) {
    OK(api->image_from_pixels(engine,3,2,colors,sizeof colors,&image,NULL));
    if(kind==1)OK(api->image_convert_precision(engine,image,GLIMS_COLOR_COMPONENT_FLOAT,GLIMS_COLOR_TRC_LINEAR,NULL));
    if(kind==2)OK(api->image_convert_mode(engine,image,GLIMS_COLOR_MODE_GRAYSCALE,NULL));
    if(kind==3) { snprintf(path,sizeof path,"%s/wide-linear-rgb.icc",argv[3]); OK(api->image_assign_profile(engine,image,path,NULL)); }
    if(kind==4) {
      GlimsIndexedSettings indexed={.struct_size=sizeof indexed,.palette=GLIMS_INDEXED_PALETTE_GENERATED,
        .max_colors=16,.dither=GLIMS_INDEXED_DITHER_NONE,.preservation=GLIMS_INDEXED_PRESERVE_EDITABLE};
      OK(api->image_convert_indexed(engine,image,&indexed,NULL,0,NULL));
    }
    snprintf(path,sizeof path,"%s/mode-%d.gif",argv[2],kind); roundtrip(image,path,NULL); OK(api->image_close(engine,image));
  }
  /* Independent two-frame, looping 1x1 GIF: red then green. The source
   * importer carries animation metadata; still export must not copy it. */
  const unsigned char animation[]={
    'G','I','F','8','9','a',1,0,1,0,0x80,0,0,255,0,0,0,255,0,
    0x21,0xff,11,'N','E','T','S','C','A','P','E','2','.','0',3,1,0,0,0,
    0x21,0xf9,4,0,10,0,0,0,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0,
    0x21,0xf9,4,0,10,0,0,0,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x4c,1,0,0x3b};
  snprintf(path,sizeof path,"%s/animated-input.gif",argv[2]); f=fopen(path,"wb"); NEED(f); NEED(fwrite(animation,1,sizeof animation,f)==sizeof animation); fclose(f);
  OK(api->image_open(engine,path,&image,NULL)); GlimsImageInfo animated={0}; OK(api->image_info(engine,image,&animated));
  CHECK(animated.layer_count==2,"independent looping GIF imports both source frames");
  snprintf(path,sizeof path,"%s/animated-as-still.gif",argv[2]); roundtrip(image,path,NULL); OK(api->image_close(engine,image));
  api->stop(engine); printf("%d checks, %d failures\n",checks,failures); return failures?1:0;
}

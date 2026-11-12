/* Facade-only BMP/TGA checks with independent header and pixel decoding. */
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
static unsigned le32(const unsigned char *p) { return le16(p) | le16(p+2)<<16; }
static unsigned requested_format;
static GlimsExportSettings settings(void) {
  return (GlimsExportSettings){.struct_size=sizeof(GlimsExportSettings),.format=requested_format,
    .jpeg_quality=.9,.jpeg_progressive=1,.jpeg_optimize=1,.png_compression=9,.tiff_preserve_transparent_color=1};
}
static void inspect(const char *path,int width,int height,const unsigned char *expected) {
  size_t n=0; unsigned char *b=read_file(path,&n); size_t offset=0; int bottom_up=0;
  if(requested_format==GLIMS_EXPORT_BMP) {
    NEED(n>=138);
    CHECK(b[0]=='B' && b[1]=='M' && le32(b+2)==n,"BMP signature and declared file size are correct");
    CHECK(le32(b+14)==124 && le16(b+26)==1 && le16(b+28)==32,"BMP is 32-bit with a V5 header");
    CHECK(le32(b+18)==(unsigned)width && le32(b+22)==(unsigned)height,"BMP dimensions match the canvas");
    CHECK(le32(b+30)==3 && le32(b+54)==0x00ff0000 && le32(b+58)==0x0000ff00 && le32(b+62)==0x000000ff && le32(b+66)==0xff000000,"BMP explicitly declares four RGBA masks without RLE");
    CHECK(le32(b+70)==0x73524742 && !le32(b+126) && !le32(b+130),"BMP declares sRGB without embedding a foreign profile");
    offset=le32(b+10);bottom_up=1;
  } else {
    NEED(n>=18);
    CHECK(b[1]==0 && b[2]==2 && b[16]==32 && b[17]==0x28,"TGA is uncompressed truecolor with top-left origin and eight alpha bits");
    CHECK(le16(b+12)==(unsigned)width && le16(b+14)==(unsigned)height,"TGA dimensions match the canvas");
    offset=18u+b[0];
  }
  NEED(offset<=n && (size_t)width*height*4<=n-offset);
  int max_color=0,alpha_ok=1;
  for(int y=0;y<height;y++)for(int x=0;x<width;x++) {
    const unsigned char *got=b+offset+4*((bottom_up?height-y-1:y)*width+x),*want=expected+4*(y*width+x);
    if(got[3]!=want[3])alpha_ok=0;
    if(want[3])for(int c=0;c<3;c++){int d=abs(got[2-c]-want[c]);if(d>max_color)max_color=d;}
  }
  printf("Independent encoded color difference: %d\n",max_color);
  CHECK(alpha_ok && max_color<=2,"Raw file pixels preserve the expected sRGB colors and partial alpha");free(b);
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
  CHECK(status==GLIMS_STATUS_OK,"configured bitmap export succeeds");
  if(status==GLIMS_STATUS_OK) {
    inspect(path,i0.width,i0.height,expected?expected:before.pixels);
    GlimsImageID reopened=0; OK(api->image_open(engine,path,&reopened,NULL));
    GlimsImageInfo ri={0}; OK(api->image_info(engine,reopened,&ri)); CHECK(ri.layer_count==1,"Bitmap reopens as one layer from the visible projection");
    GlimsPixelBuffer pixels={0}; OK(api->image_copy_pixels(engine,reopened,true,&pixels,NULL));
    const unsigned char *wanted=expected?expected:before.pixels; int match=pixels.byte_count==before.byte_count,maximum=0;
    if(match)for(size_t k=0;k<before.byte_count;k+=4) {
      unsigned alpha=wanted[k+3];
      if(pixels.pixels[k+3]!=alpha)match=0;
      if(alpha)for(size_t c=0;c<3;c++) { int d=abs(pixels.pixels[k+c]-wanted[k+c]); if(d>maximum)maximum=d; }
    }
    printf("Reopened bitmap color maximum difference: %d\n",maximum);
    CHECK(match && maximum<=2,"Reopened bitmap retains expected sRGB colors and partial alpha");
    api->free_pixels(pixels.pixels); OK(api->image_close(engine,reopened));
  }
  OK(api->image_info(engine,image,&i1)); OK(api->image_undo_info(engine,image,&u1)); OK(api->image_history(engine,image,NULL,0,&h1));
  OK(api->image_color_info(engine,image,&c1));
  OK(api->image_layers(engine,image,l1,16,&n1)); OK(api->image_copy_pixels(engine,image,true,&after,NULL)); OK(api->image_copy_pixels(engine,image,false,&raw1,NULL));
  CHECK(i0.width==i1.width && i0.height==i1.height && i0.dirty==i1.dirty && !strcmp(i0.precision,i1.precision),"Bitmap preserves source dimensions, precision and dirty state");
  CHECK(!memcmp(&c0,&c1,sizeof c0),"Bitmap preserves source color mode, precision and profile state");
  CHECK(u0.undo_count==u1.undo_count && u0.redo_count==u1.redo_count && h0.revision==h1.revision && h0.current_position==h1.current_position && h0.count==h1.count,"Bitmap preserves Undo/Redo and history revision");
  CHECK(n0==n1 && !memcmp(l0,l1,sizeof l0),"Bitmap preserves source layer identities, properties and selection");
  CHECK(before.byte_count==after.byte_count && !memcmp(before.pixels,after.pixels,before.byte_count) && raw0.byte_count==raw1.byte_count && !memcmp(raw0.pixels,raw1.pixels,raw0.byte_count),"Bitmap preserves source composite and raw pixels exactly");
  api->free_pixels(before.pixels); api->free_pixels(after.pixels); api->free_pixels(raw0.pixels); api->free_pixels(raw1.pixels);
}
int main(int argc,char **argv) {
  NEED(argc==4); void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
  GlimsEngineGetAPIFunction get=(GlimsEngineGetAPIFunction)dlsym(lib,"glims_engine_get_api"); api=get?get(GLIMS_ENGINE_API_VERSION):NULL; NEED(api && api->struct_size>=sizeof *api);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=argv[2],.cache_directory=argv[2]}; OK(api->start(&config,&engine,NULL));
  const unsigned char base[]={255,0,0,255, 0,255,0,64, 0,0,255,255, 255,255,255,255, 10,20,30,0, 0,0,0,192};
  const unsigned char top[]={0,255,255,255, 255,0,255,255};
  const unsigned char expected[]={0,255,255,255, 0,255,0,64, 0,0,255,255, 255,0,255,255, 0,0,0,0, 0,0,0,192};
  const unsigned char colors[]={90,120,60,255, 170,80,100,64, 50,75,120,255, 130,160,180,0, 100,100,100,192, 210,150,70,255};
  char path[4096];GlimsImageID image=0;
  for(unsigned format=GLIMS_EXPORT_BMP;format<=GLIMS_EXPORT_TGA;format++) {
    requested_format=format;const char *ext=format==GLIMS_EXPORT_BMP?"bmp":"tga";
    OK(api->image_from_pixels(engine,3,2,base,sizeof base,&image,NULL));GlimsItemID layer=0;
    OK(api->image_paste_pixels(engine,image,(GlimsRect){0,0,1,2},top,sizeof top,&layer,NULL));
    snprintf(path,sizeof path,"%s/layered.%s",argv[2],ext);roundtrip(image,path,expected);
    snprintf(path,sizeof path,"%s/keep.png",argv[2]);FILE *f=fopen(path,"wb");NEED(f);NEED(fwrite("keep",1,4,f)==4);fclose(f);
    GlimsExportSettings s=settings();CHECK(api->image_export_configured(engine,image,path,&s,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"Bitmap refuses a mismatched filename");
    size_t n=0;unsigned char *kept=read_file(path,&n);CHECK(n==4 && !memcmp(kept,"keep",4),"Refusal preserves existing destination bytes");free(kept);
    OK(api->image_close(engine,image));
    for(int kind=0;kind<5;kind++) {
      OK(api->image_from_pixels(engine,3,2,colors,sizeof colors,&image,NULL));
      if(kind==1)OK(api->image_convert_precision(engine,image,GLIMS_COLOR_COMPONENT_FLOAT,GLIMS_COLOR_TRC_LINEAR,NULL));
      if(kind==2)OK(api->image_convert_mode(engine,image,GLIMS_COLOR_MODE_GRAYSCALE,NULL));
      if(kind==3) {snprintf(path,sizeof path,"%s/wide-linear-rgb.icc",argv[3]);OK(api->image_assign_profile(engine,image,path,NULL));}
      if(kind==4) {
        GlimsIndexedSettings indexed={.struct_size=sizeof indexed,.palette=GLIMS_INDEXED_PALETTE_GENERATED,
          .max_colors=16,.dither=GLIMS_INDEXED_DITHER_NONE,.preservation=GLIMS_INDEXED_PRESERVE_EDITABLE};
        OK(api->image_convert_indexed(engine,image,&indexed,NULL,0,NULL));
      }
      snprintf(path,sizeof path,"%s/mode-%d.%s",argv[2],kind,ext);roundtrip(image,path,NULL);OK(api->image_close(engine,image));
    }
  }
  requested_format=GLIMS_EXPORT_TGA;
  for(int axis=0;axis<2;axis++) {
    OK(api->image_new(engine,axis?1:65536,axis?65536:1,&image,NULL));
    snprintf(path,sizeof path,"%s/oversized-%d.tga",argv[2],axis);FILE *f=fopen(path,"wb");NEED(f);NEED(fwrite("keep",1,4,f)==4);fclose(f);
    GlimsExportSettings s=settings();char *error=NULL;
    GlimsStatus status=api->image_export_configured(engine,image,path,&s,&error);
    CHECK(status!=GLIMS_STATUS_OK && error && strstr(error,"65535"),"TGA reports its dimension limit before writing");
    if(error)api->free_string(error);
    size_t n=0;unsigned char *kept=read_file(path,&n);CHECK(n==4 && !memcmp(kept,"keep",4),"Oversized TGA refusal preserves existing destination bytes");free(kept);
    GlimsImageInfo info={0};OK(api->image_info(engine,image,&info));CHECK(info.width==(axis?1:65536) && info.height==(axis?65536:1) && !info.dirty,"Oversized TGA refusal leaves the source unchanged");
    OK(api->image_close(engine,image));
  }
  api->stop(engine);printf("%d checks, %d failures\n",checks,failures);return failures?1:0;
}

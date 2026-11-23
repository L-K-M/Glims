/* Facade-only BMP/TGA/PCX/EPS/PDF checks with independent decoding. */
#include "glims_engine.h"
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <math.h>
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
/* PCX, EPS and PDF composite on white in linear light, as Flatten does. */
static unsigned char on_white(unsigned char value,unsigned char alpha) {
  double v=value/255.,a=alpha/255.,light=v<=.04045?v/12.92:pow((v+.055)/1.055,2.4);
  light=light*a+(1-a);
  return (unsigned char)lrint(255*(light<=.0031308?12.92*light:1.055*pow(light,1/2.4)-.055));
}
static int pcx_difference(const unsigned char *b,size_t n,int width,int height,const unsigned char *want) {
  if(n<128 || b[0]!=10 || b[1]!=5 || b[2]!=1 || b[3]!=8 || b[65]!=3) return 999;
  if(le16(b+8)-le16(b+4)+1!=(unsigned)width || le16(b+10)-le16(b+6)+1!=(unsigned)height) return 999;
  int stride=(int)le16(b+66),worst=0; size_t at=128;
  if(stride<width || stride%2) return 999;
  for(int y=0;y<height;y++) for(int plane=0;plane<3;plane++) for(int x=0;x<stride;) {
    if(at>=n) return 999;
    int value=b[at++],run=1;
    if(value>=0xc0) { run=value&0x3f; if(at>=n) return 999; value=b[at++]; }
    for(;run>0 && x<stride;run--,x++) if(x<width) { int d=abs(value-want[4*(y*width+x)+plane]); if(d>worst)worst=d; }
    if(run) return 999;
  }
  return worst;
}
static int pdf_difference(const char *path,int width,int height,double ppi,const unsigned char *want) {
  enum { CELL=10 };
  int worst=999; CGDataProviderRef provider=CGDataProviderCreateWithFilename(path); NEED(provider);
  CGPDFDocumentRef document=CGPDFDocumentCreateWithProvider(provider);
  if(document && CGPDFDocumentGetNumberOfPages(document)==1) {
    CGPDFPageRef page=CGPDFDocumentGetPage(document,1); CGRect box=CGPDFPageGetBoxRect(page,kCGPDFMediaBox);
    if(fabs(box.size.width-width*72/ppi)<.01 && fabs(box.size.height-height*72/ppi)<.01) {
      if(!want) worst=0; else {
        size_t w=(size_t)width*CELL,h=(size_t)height*CELL; unsigned char *got=calloc(w*h,4); NEED(got);
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=CGBitmapContextCreate(got,w,h,8,w*4,space,(uint32_t)kCGImageAlphaPremultipliedLast); NEED(context);
        CGContextSetInterpolationQuality(context,kCGInterpolationNone);
        CGContextScaleCTM(context,w/box.size.width,h/box.size.height); CGContextDrawPDFPage(context,page); worst=0;
        for(int y=0;y<height;y++) for(int x=0;x<width;x++) {
          const unsigned char *pixel=got+4*((y*CELL+CELL/2)*w+x*CELL+CELL/2);
          for(int c=0;c<3;c++) { int d=abs(pixel[c]-want[4*(y*width+x)+c]); if(d>worst)worst=d; }
        }
        CGContextRelease(context); CGColorSpaceRelease(space); free(got);
      }
    }
  }
  CGPDFDocumentRelease(document); CGDataProviderRelease(provider); return worst;
}
static const char *flat_extension(unsigned format) {
  return format==GLIMS_EXPORT_PCX?"pcx":format==GLIMS_EXPORT_EPS?"eps":"pdf";
}
/* A new image has the engine's 300 ppi default, so pages are pixels * 72 / 300. */
static void flat_export(GlimsImageID image,const char *path,int width,int height) {
  GlimsPixelBuffer before={0},after={0}; GlimsUndoInfo u0={0},u1={0}; GlimsImageInfo i0={0},i1={0};
  OK(api->image_info(engine,image,&i0)); OK(api->image_undo_info(engine,image,&u0));
  OK(api->image_copy_pixels(engine,image,true,&before,NULL));
  unsigned char *want=malloc(before.byte_count); NEED(want);
  for(size_t k=0;k<before.byte_count;k+=4) {
    for(int c=0;c<3;c++) want[k+c]=on_white(before.pixels[k+c],before.pixels[k+3]);
    want[k+3]=255;
  }
  GlimsExportSettings s=settings(); char *error=NULL;
  GlimsStatus status=api->image_export_configured(engine,image,path,&s,&error);
  if(error) { printf("export: %s\n",error); api->free_string(error); }
  CHECK(status==GLIMS_STATUS_OK,"flat export succeeds");
  if(status==GLIMS_STATUS_OK) {
    size_t n=0; unsigned char *b=read_file(path,&n); b[n]=0;
    if(requested_format==GLIMS_EXPORT_PCX) {
      int d=pcx_difference(b,n,width,height,want); printf("PCX color difference: %d\n",d);
      CHECK(d<=3,"PCX holds the visible image on white");
      GlimsImageID reopened=0; GlimsStatus opened=api->image_open(engine,path,&reopened,NULL); GlimsImageInfo info={0};
      CHECK(opened==GLIMS_STATUS_OK && api->image_info(engine,reopened,&info)==GLIMS_STATUS_OK && info.width==width && info.height==height,"PCX reopens at its size");
      if(reopened) OK(api->image_close(engine,reopened));
    } else if(requested_format==GLIMS_EXPORT_PDF) {
      int d=pdf_difference(path,width,height,300,width<=4?want:NULL); printf("PDF color difference: %d\n",d);
      CHECK(d<=4,"PDF is one page of the print size with the visible image on white");
    } else {
      char box[96]; snprintf(box,sizeof box,"%%%%BoundingBox: 0 0 %d %d\n",(int)ceil(width*72/300.-1e-9),(int)ceil(height*72/300.-1e-9));
      CHECK(n>30 && !memcmp(b,"%!PS-Adobe",10) && strstr((char*)b,"EPSF"),"EPS declares Encapsulated PostScript");
      CHECK(strstr((char*)b,box)!=NULL,"EPS bounding box is the print size at the origin");
    }
    free(b);
  }
  OK(api->image_info(engine,image,&i1)); OK(api->image_undo_info(engine,image,&u1)); OK(api->image_copy_pixels(engine,image,true,&after,NULL));
  CHECK(i0.dirty==i1.dirty && i0.layer_count==i1.layer_count && u0.undo_count==u1.undo_count && before.byte_count==after.byte_count && !memcmp(before.pixels,after.pixels,before.byte_count),"flat export leaves the source image and its history alone");
  free(want); api->free_pixels(before.pixels); api->free_pixels(after.pixels);
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
  for(unsigned format=GLIMS_EXPORT_PCX;format<=GLIMS_EXPORT_PDF;format++) {
    requested_format=format; const char *ext=flat_extension(format);
    OK(api->image_from_pixels(engine,3,2,base,sizeof base,&image,NULL)); GlimsItemID layer=0;
    OK(api->image_paste_pixels(engine,image,(GlimsRect){0,0,1,2},top,sizeof top,&layer,NULL));
    snprintf(path,sizeof path,"%s/flat-layered.%s",argv[2],ext); flat_export(image,path,3,2);
    snprintf(path,sizeof path,"%s/keep.png",argv[2]);
    GlimsExportSettings s=settings();
    CHECK(api->image_export_configured(engine,image,path,&s,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"flat format refuses a mismatched filename");
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
      snprintf(path,sizeof path,"%s/flat-mode-%d.%s",argv[2],kind,ext); flat_export(image,path,3,2);
      OK(api->image_close(engine,image));
    }
    OK(api->image_new(engine,600,300,&image,NULL));
    snprintf(path,sizeof path,"%s/flat-page.%s",argv[2],ext); flat_export(image,path,600,300);
    OK(api->image_close(engine,image));
    for(int axis=0;axis<2;axis++) {
      int w=axis?1:format==GLIMS_EXPORT_PCX?65535:60001,h=!axis?1:format==GLIMS_EXPORT_PCX?65537:60001;
      OK(api->image_new(engine,w,h,&image,NULL));
      snprintf(path,sizeof path,"%s/oversized-%d.%s",argv[2],axis,ext);FILE *f=fopen(path,"wb");NEED(f);NEED(fwrite("keep",1,4,f)==4);fclose(f);
      char *error=NULL; GlimsStatus status=api->image_export_configured(engine,image,path,&s,&error);
      CHECK(status==GLIMS_STATUS_UNSUPPORTED && error && strstr(error,format==GLIMS_EXPORT_PCX?"65534":"200 inches"),"flat format reports its size limit before writing");
      if(error)api->free_string(error);
      size_t n=0;unsigned char *kept=read_file(path,&n);CHECK(n==4 && !memcmp(kept,"keep",4),"size refusal preserves the destination");free(kept);
      OK(api->image_close(engine,image));
    }
  }
  api->stop(engine);printf("%d checks, %d failures\n",checks,failures);return failures?1:0;
}

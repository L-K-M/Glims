/* Facade-only Sponge checks: independent HSV relationships and exact Undo. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int checks, failures;
#define NEED(c) do { if (!(c)) { fprintf(stderr,"fixture failure at line %d\n",__LINE__); exit(2); } } while (0)
#define CHECK(c,label) do { int ok=!!(c); checks++; failures+=!ok; printf("%s %s\n",ok?"ok":"FAIL",label); fflush(stdout); } while (0)
#define OK(c) NEED((c)==GLIMS_STATUS_OK)
static GlimsBrushSettings brush(unsigned tool) {
  return (GlimsBrushSettings){.struct_size=sizeof(GlimsBrushSettings),.tool=tool,.size=18,
    .hardness=1,.opacity=.5,.red=0,.green=1,.blue=0,.rate=-1,.flow=-1,.exposure=-1};
}
static GlimsStatus paint_resource(GlimsImageID image,GlimsItemID layer,GlimsBrushSettings *b,GlimsResourceID resource,char **error) {
  GlimsStrokePoint p={.x=28,.y=32,.pressure=1,.time_ms=1};GlimsStrokeID stroke=0;
  GlimsStatus s=resource?api->stroke_begin_with_brush_resource(engine,image,layer,resource,b,&p,&stroke,error):api->stroke_begin(engine,image,layer,b,&p,&stroke,error);
  if(s!=GLIMS_STATUS_OK){CHECK(!stroke,"refused Sponge request creates no live stroke");return s;}
  p.x=32;p.time_ms=20;OK(api->stroke_continue(engine,stroke,&p,1));return api->stroke_end(engine,stroke);
}
static GlimsStatus paint(GlimsImageID image,GlimsItemID layer,GlimsBrushSettings *b,char **error) {
  return paint_resource(image,layer,b,0,error);
}
static void le16(FILE *f,unsigned value) { fputc(value&255,f);fputc((value>>8)&255,f); }
static void le32(FILE *f,unsigned value) { le16(f,value&65535);le16(f,value>>16); }
static void tiff_tag(FILE *f,unsigned tag,unsigned type,unsigned count,unsigned value) {
  le16(f,tag);le16(f,type);le32(f,count);le32(f,value);
}
/* Independent IEEE float RGB TIFF, no GIMP or adapter pixel constructors. */
static void near_neutral_tiff(const char *path) {
  FILE *f=fopen(path,"wb");NEED(f);fwrite("II",1,2,f);le16(f,42);le32(f,8);le16(f,11);
  const unsigned bits=8+2+11*12+4, samples=bits+6, data=samples+6;
  tiff_tag(f,256,4,1,64);tiff_tag(f,257,4,1,64);tiff_tag(f,258,3,3,bits);
  tiff_tag(f,259,3,1,1);tiff_tag(f,262,3,1,2);tiff_tag(f,273,4,1,data);
  tiff_tag(f,277,3,1,3);tiff_tag(f,278,4,1,64);tiff_tag(f,279,4,1,64*64*12);
  tiff_tag(f,284,3,1,1);tiff_tag(f,339,3,3,samples);le32(f,0);
  for(int k=0;k<3;k++)le16(f,32);for(int k=0;k<3;k++)le16(f,3);
  for(int k=0;k<64*64;k++)for(int c=0;c<3;c++){float value=c==1?.50005f:.5f;unsigned bits32;memcpy(&bits32,&value,4);le32(f,bits32);}
  NEED(!ferror(f));NEED(fclose(f)==0);
}
static void adversarial_dynamics(const char *work) {
  char path[4096];snprintf(path,sizeof path,"%s/dynamics",work);NEED(mkdir(path,0700)==0);
  snprintf(path,sizeof path,"%s/dynamics/Pressure-Size.gdyn",work);FILE *f=fopen(path,"w");NEED(f);
  fputs("(name \"Pressure Size\")\n(size-output (use-pressure yes))\n(color-output (use-pressure yes))\n",f);NEED(fclose(f)==0);
  snprintf(path,sizeof path,"%s/gimprc",work);f=fopen(path,"w");NEED(f);
  fputs("(dynamics-path \"${gimp_dir}/dynamics\")\n",f);NEED(fclose(f)==0);
}
static GlimsItemID layer_of(GlimsImageID image) {
  GlimsLayerInfo rows[2]={0};int32_t count=0;OK(api->image_layers(engine,image,rows,2,&count));NEED(count==1);return rows[0].id;
}
static GlimsStatus read_full(GlimsImageID image,GlimsPixelBuffer *out) {
  out->bounds=(GlimsRect){0,0,64,64};out->byte_count=64*64*4;
  out->pixels=malloc(out->byte_count);NEED(out->pixels);
  return api->image_render(engine,image,1,out->bounds,out->pixels,64*4);
}
static void colors(unsigned char *p,unsigned alpha) {
  const unsigned char hues[][3]={{60,120,180},{180,100,40},{90,180,60}};
  for(int y=0;y<64;y++)for(int x=0;x<64;x++) {const unsigned char *c=hues[(y/8)%3];size_t k=4*(y*64+x);memcpy(p+k,c,3);p[k+3]=(unsigned char)alpha;}
}
static void verify_pixels(const GlimsPixelBuffer *before,const GlimsPixelBuffer *after,int increase) {
  NEED(before->byte_count==64*64*4 && after->byte_count==before->byte_count);
  int changed=0,direction=1,hue=1,value=1,alpha=1,outside=1;
  for(int y=0;y<64;y++)for(int x=0;x<64;x++) {
    size_t k=4*(y*64+x);const unsigned char *a=before->pixels+k,*b=after->pixels+k;
    if(a[3]!=b[3])alpha=0;
    if((x>=32 || x<16 || y<20 || y>44) && memcmp(a,b,4))outside=0;
    if(memcmp(a,b,3)) {
      changed++;
      int lo=0,hi=0;for(int c=1;c<3;c++){if(a[c]<a[lo])lo=c;if(a[c]>a[hi])hi=c;}
      int mid=3-lo-hi;
      double sa=(double)(a[hi]-a[lo])/a[hi], sb=(double)(b[hi]-b[lo])/b[hi];
      if(increase?sb<sa-.012:sb>sa+.012)direction=0;
      if(abs(a[hi]-b[hi])>2)value=0;
      if(b[hi]-b[lo]>5 && fabs((double)(a[mid]-a[lo])/(a[hi]-a[lo])-(double)(b[mid]-b[lo])/(b[hi]-b[lo]))>.06)hue=0;
    }
  }
  CHECK(changed>20 && direction,"Sponge changes saturation in the requested direction");
  CHECK(hue && value,"Sponge preserves hue and HSV value within quantization");
  CHECK(alpha,"Sponge preserves every alpha value exactly");
  CHECK(outside,"Sponge obeys the selection and leaves distant pixels untouched");
}
int main(int argc,char **argv) {
  NEED(argc==4);void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
  GlimsEngineGetAPIFunction get=(GlimsEngineGetAPIFunction)dlsym(lib,"glims_engine_get_api");api=get?get(GLIMS_ENGINE_API_VERSION):NULL;NEED(api && api->struct_size>=sizeof *api);
  adversarial_dynamics(argv[2]);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=argv[2],.cache_directory=argv[2]};OK(api->start(&config,&engine,NULL));
  unsigned char source[64*64*4];char path[4096];
  for(int mode=0;mode<2;mode++)for(int variant=0;variant<3;variant++) {
    colors(source,variant==1?128:255);GlimsImageID image=0;OK(api->image_from_pixels(engine,64,64,source,sizeof source,&image,NULL));
    if(variant==2)OK(api->image_convert_precision(engine,image,GLIMS_COLOR_COMPONENT_FLOAT,GLIMS_COLOR_TRC_LINEAR,NULL));
    GlimsItemID layer=layer_of(image);GlimsPoint points[]={{0,0},{32,64}};
    GlimsSelectOptions selection={.struct_size=sizeof selection,.operation=GLIMS_SELECT_REPLACE,.antialias=false};
    OK(api->select_shape(engine,image,GLIMS_SHAPE_RECTANGLE,points,2,&selection));
    GlimsPixelBuffer before={0},after={0},undo_pixels={0},redo_pixels={0};GlimsUndoInfo u0={0},u1={0};
    OK(read_full(image,&before));OK(api->image_undo_info(engine,image,&u0));
    GlimsBrushSettings b=brush(mode?GLIMS_PAINT_SPONGE_SATURATE:GLIMS_PAINT_SPONGE_DESATURATE);char *error=NULL;
    GlimsStatus status=paint(image,layer,&b,&error);if(error){printf("stroke: %s\n",error);api->free_string(error);}CHECK(status==GLIMS_STATUS_OK,"Sponge accepts an RGB pixel layer");
    OK(read_full(image,&after));OK(api->image_undo_info(engine,image,&u1));
    if(status==GLIMS_STATUS_OK){verify_pixels(&before,&after,mode);CHECK(u1.undo_count==u0.undo_count+1,"Sponge is exactly one editing Undo step");
      OK(api->image_undo(engine,image));OK(read_full(image,&undo_pixels));CHECK(!memcmp(undo_pixels.pixels,before.pixels,before.byte_count),"Sponge Undo restores exact source pixels");
      OK(api->image_redo(engine,image));OK(read_full(image,&redo_pixels));CHECK(!memcmp(redo_pixels.pixels,after.pixels,after.byte_count),"Sponge Redo restores exact painted pixels");
      snprintf(path,sizeof path,"%s/sponge-%d-%d.xcf",argv[2],mode,variant);OK(api->image_save_copy(engine,image,path,NULL));GlimsImageID loaded=0;OK(api->image_open(engine,path,&loaded,NULL));GlimsPixelBuffer saved={0};OK(read_full(loaded,&saved));CHECK(saved.byte_count==after.byte_count && !memcmp(saved.pixels,after.pixels,after.byte_count),"Sponge result survives XCF save and reopen");free(saved.pixels);OK(api->image_close(engine,loaded));
      free(undo_pixels.pixels);free(redo_pixels.pixels);
    }
    free(before.pixels);free(after.pixels);OK(api->image_close(engine,image));
  }
  memset(source,128,sizeof source);
  for(size_t k=3;k<sizeof source;k+=4)source[k]=255;
  GlimsImageID neutral=0;OK(api->image_from_pixels(engine,64,64,source,sizeof source,&neutral,NULL));
  GlimsPixelBuffer gray_before={0},gray_after={0};OK(read_full(neutral,&gray_before));
  GlimsBrushSettings saturate=brush(GLIMS_PAINT_SPONGE_SATURATE);
  OK(paint(neutral,layer_of(neutral),&saturate,NULL));OK(read_full(neutral,&gray_after));
  CHECK(!memcmp(gray_before.pixels,gray_after.pixels,gray_before.byte_count),"Saturating neutral pixels never invents a hue");
  free(gray_before.pixels);free(gray_after.pixels);OK(api->image_close(engine,neutral));
  snprintf(path,sizeof path,"%s/near-neutral.tif",argv[2]);near_neutral_tiff(path);
  GlimsImageID faint=0;OK(api->image_open(engine,path,&faint,NULL));
  GlimsPixelBuffer faint_before={0},faint_after={0};OK(read_full(faint,&faint_before));
  OK(paint(faint,layer_of(faint),&saturate,NULL));OK(read_full(faint,&faint_after));
  int green_hue=1,green_changed=0;
  for(size_t k=0;k<faint_after.byte_count;k+=4){unsigned char *a=faint_before.pixels+k,*b=faint_after.pixels+k;
    if(b[0]>b[1]+1||b[2]>b[1]+1)green_hue=0;if(memcmp(a,b,3))green_changed++;
  }
  CHECK(green_hue && green_changed>20,"Near-neutral float green retains its green hue when saturated");
  free(faint_before.pixels);free(faint_after.pixels);OK(api->image_close(engine,faint));
  /* Pressure=1 gives identical geometry in both runs. White gradient output
   * from ordinary Paintbrush proves our mutable color dynamics is active. */
  GlimsPixelBuffer control[2]={{0}};
  for(int enabled=0;enabled<2;enabled++){
    colors(source,255);GlimsImageID image=0;OK(api->image_from_pixels(engine,64,64,source,sizeof source,&image,NULL));
    GlimsBrushSettings b=brush(GLIMS_PAINT_PAINTBRUSH);b.pressure_size=enabled;b.opacity=1;
    OK(paint(image,layer_of(image),&b,NULL));OK(read_full(image,&control[enabled]));OK(api->image_close(engine,image));
  }
  size_t center=4*(32*64+28);
  CHECK(control[0].pixels[center]<10 && control[0].pixels[center+1]>245 && control[0].pixels[center+2]<10 &&
        control[1].pixels[center]>245 && control[1].pixels[center+1]>245 && control[1].pixels[center+2]>245,
        "Adversarial Pressure Size dynamics demonstrably drives ordinary brush gradient color");
  free(control[0].pixels);free(control[1].pixels);
  for(int mode=0;mode<2;mode++){
    GlimsPixelBuffer images[2]={{0}};
    for(int enabled=0;enabled<2;enabled++){
      colors(source,128);GlimsImageID image=0;OK(api->image_from_pixels(engine,64,64,source,sizeof source,&image,NULL));
      GlimsBrushSettings b=brush(mode?GLIMS_PAINT_SPONGE_SATURATE:GLIMS_PAINT_SPONGE_DESATURATE);b.pressure_size=enabled;
      OK(paint(image,layer_of(image),&b,NULL));OK(read_full(image,&images[enabled]));OK(api->image_close(engine,image));
    }
    CHECK(!memcmp(images[0].pixels,images[1].pixels,images[0].byte_count),"Color dynamics cannot bypass or reverse Sponge saturation");
    free(images[0].pixels);free(images[1].pixels);
  }
  int32_t n=0;OK(api->resources(engine,GLIMS_RESOURCE_BRUSH,NULL,0,&n));NEED(n>0);
  GlimsResourceInfo *resources=calloc(n,sizeof *resources);NEED(resources);OK(api->resources(engine,GLIMS_RESOURCE_BRUSH,resources,n,&n));
  GlimsResourceID textured[2]={0};
  for(int i=0;i<n;i++){if(strstr(resources[i].name,"Pepper")||strstr(resources[i].name,"pepper"))textured[0]=resources[i].id;
    if(strstr(resources[i].name,"Vine")||strstr(resources[i].name,"vine"))textured[1]=resources[i].id;}
  free(resources);NEED(textured[0] && textured[1]);
  for(int resource=0;resource<2;resource++)for(int mode=0;mode<2;mode++){
    colors(source,128);GlimsImageID image=0;OK(api->image_from_pixels(engine,64,64,source,sizeof source,&image,NULL));
    GlimsPoint points[]={{0,0},{32,64}};GlimsSelectOptions selection={.struct_size=sizeof selection,.operation=GLIMS_SELECT_REPLACE};
    OK(api->select_shape(engine,image,GLIMS_SHAPE_RECTANGLE,points,2,&selection));
    GlimsPixelBuffer before={0},after={0};OK(read_full(image,&before));
    GlimsBrushSettings b=brush(mode?GLIMS_PAINT_SPONGE_SATURATE:GLIMS_PAINT_SPONGE_DESATURATE);
    OK(paint_resource(image,layer_of(image),&b,textured[resource],NULL));OK(read_full(image,&after));
    verify_pixels(&before,&after,mode);free(before.pixels);free(after.pixels);OK(api->image_close(engine,image));
  }
  for(int mode=0;mode<2;mode++){
    colors(source,128);GlimsImageID image=0;OK(api->image_from_pixels(engine,64,64,source,sizeof source,&image,NULL));
    GlimsItemID layer=layer_of(image);GlimsPoint points[]={{20,20},{40,40}};
    GlimsSelectOptions selection={.struct_size=sizeof selection,.operation=GLIMS_SELECT_REPLACE};
    OK(api->select_shape(engine,image,GLIMS_SHAPE_RECTANGLE,points,2,&selection));
    OK(api->set_layer_locks(engine,image,layer,GLIMS_LOCK_ALPHA,GLIMS_LOCK_ALPHA,NULL));
    GlimsPixelBuffer before={0},after={0},undone={0};GlimsUndoInfo u0={0},u1={0};
    OK(read_full(image,&before));OK(api->image_undo_info(engine,image,&u0));
    GlimsBrushSettings b=brush(mode?GLIMS_PAINT_SPONGE_SATURATE:GLIMS_PAINT_SPONGE_DESATURATE);
    OK(api->selection_stroke(engine,image,layer,0,&b,NULL));OK(read_full(image,&after));OK(api->image_undo_info(engine,image,&u1));
    int alpha=1;for(size_t k=3;k<after.byte_count;k+=4)if(before.pixels[k]!=after.pixels[k])alpha=0;
    CHECK(memcmp(before.pixels,after.pixels,before.byte_count) && alpha && u1.undo_count==u0.undo_count+1,
          "Selection Stroke accepts Sponge with alpha lock, preserving alpha in one Undo");
    OK(api->image_undo(engine,image));OK(read_full(image,&undone));CHECK(!memcmp(before.pixels,undone.pixels,before.byte_count),"Selection Stroke Undo restores exact Sponge source");
    OK(api->set_layer_locks(engine,image,layer,GLIMS_LOCK_PIXELS,GLIMS_LOCK_PIXELS,NULL));OK(api->image_undo_info(engine,image,&u0));
    CHECK(paint(image,layer,&b,NULL)==GLIMS_STATUS_LOCKED,"Sponge respects the layer pixel lock");
    OK(api->image_undo_info(engine,image,&u1));CHECK(u0.undo_count==u1.undo_count,"Locked Sponge creates no Undo");
    free(before.pixels);free(after.pixels);free(undone.pixels);OK(api->image_close(engine,image));
  }
  for(int target=0;target<3;target++) {
    colors(source,255);GlimsImageID image=0;OK(api->image_from_pixels(engine,64,64,source,sizeof source,&image,NULL));GlimsItemID layer=layer_of(image),drawable=layer;
    if(target==0)OK(api->image_convert_mode(engine,image,GLIMS_COLOR_MODE_GRAYSCALE,NULL));
    if(target==1){GlimsIndexedSettings s={.struct_size=sizeof s,.palette=GLIMS_INDEXED_PALETTE_GENERATED,.max_colors=16,.dither=GLIMS_INDEXED_DITHER_NONE,.preservation=GLIMS_INDEXED_PRESERVE_EDITABLE};OK(api->image_convert_indexed(engine,image,&s,NULL,0,NULL));}
    if(target==2)OK(api->layer_mask_add(engine,image,layer,GLIMS_MASK_WHITE,true,&drawable,NULL));
    GlimsPixelBuffer before={0},after={0};GlimsUndoInfo u0={0},u1={0};OK(read_full(image,&before));OK(api->image_undo_info(engine,image,&u0));
    GlimsBrushSettings b=brush(GLIMS_PAINT_SPONGE_DESATURATE);char *error=NULL;CHECK(paint(image,drawable,&b,&error)==GLIMS_STATUS_UNSUPPORTED && error,"Non-RGB Sponge targets are explicitly refused");if(error)api->free_string(error);
    OK(read_full(image,&after));OK(api->image_undo_info(engine,image,&u1));CHECK(u1.undo_count==u0.undo_count && before.byte_count==after.byte_count && !memcmp(before.pixels,after.pixels,before.byte_count),"Refused Sponge leaves pixels and Undo unchanged");
    free(before.pixels);free(after.pixels);OK(api->image_close(engine,image));
  }
  api->stop(engine);printf("%d checks, %d failures\n",checks,failures);return failures?1:0;
}

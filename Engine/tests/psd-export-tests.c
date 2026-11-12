/* Typed PSD export: independent RGBA fixtures, file headers and reopen oracles.
 * Run with adapter path and private work directory. No GIMP headers. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int checks, failures;
#define CHECK(c, label) do { int checked_ = !!(c); checks++; failures += !checked_; printf("%s %s\n",checked_?"ok":"FAIL",label); fflush(stdout); } while(0)
static void require(GlimsStatus status) {
  if(status != GLIMS_STATUS_OK) { fprintf(stderr,"fixture setup failed: %d\n",status); api->stop(engine); exit(2); }
}
static GlimsExportSettings settings(unsigned layout) {
  return (GlimsExportSettings){.struct_size=sizeof(GlimsExportSettings), .format=GLIMS_EXPORT_PSD,
    .jpeg_quality=.9, .jpeg_progressive=1, .jpeg_optimize=1, .png_compression=9,
    .tiff_preserve_transparent_color=1, .psd_layout=layout};
}
static int export(GlimsImageID image,const char *path,GlimsExportSettings *s) {
  char *error=NULL; GlimsStatus status=api->image_export_configured(engine,image,path,s,&error);
  if(error) { printf("export: %s\n",error);api->free_string(error); }
  return status==GLIMS_STATUS_OK;
}
static GlimsPixelBuffer pixels(GlimsImageID image,int merged) {
  GlimsPixelBuffer p={0};require(api->image_copy_pixels(engine,image,merged,&p,NULL));return p;
}
static int same(const GlimsPixelBuffer *a,const GlimsPixelBuffer *b,int tolerance) {
  if(a->byte_count != b->byte_count || memcmp(&a->bounds,&b->bounds,sizeof a->bounds)) return 0;
  for(size_t i=0;i<a->byte_count;i++) {
    /* Invisible RGB is not part of the visible-appearance contract. */
    if(i%4!=3 && a->pixels[i-i%4+3]==0 && b->pixels[i-i%4+3]==0) continue;
    if(abs((int)a->pixels[i]-(int)b->pixels[i])>tolerance) {
      fprintf(stderr,"pixel byte %zu: %u -> %u\n",i,a->pixels[i],b->pixels[i]);return 0;
    }
  }
  return 1;
}
static unsigned be16(const unsigned char *p) { return (unsigned)p[0]<<8|p[1]; }
static unsigned be32(const unsigned char *p) { return (unsigned)p[0]<<24|(unsigned)p[1]<<16|(unsigned)p[2]<<8|p[3]; }
static void header(const char *path,int width,int height,int mode,int depth) {
  unsigned char bytes[26]={0};FILE *f=fopen(path,"rb");size_t n=f?fread(bytes,1,sizeof bytes,f):0;if(f)fclose(f);
  CHECK(n==26 && !memcmp(bytes,"8BPS",4) && be16(bytes+4)==1 && be32(bytes+18)==(unsigned)width &&
    be32(bytes+14)==(unsigned)height && be16(bytes+24)==(unsigned)mode,"independent PSD header has expected signature, canvas and mode");
  CHECK(be16(bytes+22)==(unsigned)depth,"PSD declares the expected native encoding depth");
}
static int layers(GlimsImageID image,GlimsLayerInfo rows[16]) {
  int32_t count=0; memset(rows,0,sizeof(GlimsLayerInfo)*16);require(api->image_layers(engine,image,rows,16,&count));return count;
}
static int same_layers(const GlimsLayerInfo *a,const GlimsLayerInfo *b,int count) {
  for(int i=0;i<count;i++) if(a[i].id!=b[i].id || a[i].parent!=b[i].parent || a[i].kind!=b[i].kind ||
    a[i].visible!=b[i].visible || a[i].selected!=b[i].selected || a[i].has_mask!=b[i].has_mask ||
    a[i].opacity!=b[i].opacity || a[i].filter_count!=b[i].filter_count || strcmp(a[i].name,b[i].name) ||
    strcmp(a[i].mode,b[i].mode) || memcmp(&a[i].bounds,&b[i].bounds,sizeof a[i].bounds)) return 0;
  return 1;
}
static void roundtrip(GlimsImageID image,const char *path,unsigned layout,int count,int mode,int unsupported) {
  printf("CASE %s\n",path);fflush(stdout);
  GlimsPixelBuffer before=pixels(image,1);GlimsLayerInfo old[16],after[16];int n=layers(image,old);
  GlimsImageInfo info_before={0},info_after={0};GlimsUndoInfo undo_before={0},undo_after={0};GlimsHistoryInfo hist_before={0},hist_after={0};
  require(api->image_info(engine,image,&info_before));require(api->image_undo_info(engine,image,&undo_before));
  require(api->image_history(engine,image,NULL,0,&hist_before));
  GlimsExportSettings s=settings(layout);int ok=0;
  if(unsupported) {
    /* Independently known upstream profile bug: refusal must precede IO. */
    FILE *sentinel=fopen(path,"wb");if(!sentinel)exit(2);fwrite("keep",1,4,sentinel);fclose(sentinel);
    CHECK(api->image_export_configured(engine,image,path,&s,NULL)==GLIMS_STATUS_UNSUPPORTED,"old engine refuses its known PSD profile mismatch");
    char kept[5]={0};sentinel=fopen(path,"rb");if(sentinel){fread(kept,1,4,sentinel);fclose(sentinel);}
    CHECK(!strcmp(kept,"keep"),"profile refusal preserves existing destination");
  } else { ok=export(image,path,&s);CHECK(ok,"configured PSD export succeeds"); }
  if(ok) {
    GlimsColorInfo color={0};require(api->image_color_info(engine,image,&color));
    int major=0,minor=0;sscanf(api->engine_version(engine),"%d.%d",&major,&minor);
    /* The supported development engine adds 32-bit PSD writing; stable
     * 3.2/3.0 writers quantize these source components to 16-bit instead. */
    int depth=color.component==GLIMS_COLOR_COMPONENT_U8?8:16;
    if((major>3 || (major==3 && minor>=3)) &&
       (color.component==GLIMS_COLOR_COMPONENT_FLOAT || color.component==GLIMS_COLOR_COMPONENT_U32)) depth=32;
    header(path,info_before.width,info_before.height,mode,depth);
    GlimsImageID reopened=0;require(api->image_open(engine,path,&reopened,NULL));
    GlimsLayerInfo rows[16];int m=layers(reopened,rows);CHECK(m==count,"reopened PSD has the requested layer structure");
    if(layout==GLIMS_PSD_MERGED) {
      GlimsPixelBuffer got=pixels(reopened,1),raw=pixels(reopened,0);
      CHECK(same(&before,&got,1),"merged PSD visible pixels retain source colors and alpha within one 8-bit level");
      CHECK(same(&before,&raw,1),"merged PSD layer carries the composite rather than a white-backed preview");
      CHECK(m==1 && !rows[0].has_mask && rows[0].filter_count==0 && rows[0].opacity==1,"merged output has one plain opaque-opacity raster layer");
      api->free_pixels(got.pixels);api->free_pixels(raw.pixels);
    } else if(m==n) {
      for(int i=0;i<n;i++) {
        CHECK(!strcmp(old[i].name,rows[i].name) && old[i].visible==rows[i].visible && old[i].has_mask==rows[i].has_mask &&
          !memcmp(&old[i].bounds,&rows[i].bounds,sizeof old[i].bounds),"layered PSD retains name, visibility, mask and bounds");
        CHECK(fabs(old[i].opacity-rows[i].opacity)<=1.0/255,"layered opacity stays within PSD's 8-bit quantization");
        if(old[i].has_mask && rows[i].has_mask) {
          GlimsMaskState a={0},b={0};unsigned char ap[32*32*4]={0},bp[32*32*4]={0};int32_t aw=0,ah=0,bw=0,bh=0;
          require(api->layer_mask(engine,image,old[i].id,&a));require(api->layer_mask(engine,reopened,rows[i].id,&b));
          require(api->drawable_thumbnail(engine,image,a.mask,32,ap,sizeof ap,&aw,&ah));
          require(api->drawable_thumbnail(engine,reopened,b.mask,32,bp,sizeof bp,&bw,&bh));
          CHECK(aw==bw && ah==bh && !memcmp(ap,bp,(size_t)aw*ah*4),"layered PSD preserves non-white mask bytes");
        }
        CHECK(rows[i].filter_count==0,"PSD effects are explicitly baked rather than advertised as editable");
      }
    }
    require(api->image_close(engine,reopened));
  }
  int after_count=layers(image,after);GlimsPixelBuffer after_pixels=pixels(image,1);
  CHECK(after_count==n && same_layers(old,after,n),"export preserves source layer IDs, selection, masks and effects");
  CHECK(same(&before,&after_pixels,0),"export preserves source composite exactly");
  require(api->image_info(engine,image,&info_after));require(api->image_undo_info(engine,image,&undo_after));
  require(api->image_history(engine,image,NULL,0,&hist_after));
  CHECK(info_before.dirty==info_after.dirty && undo_before.undo_count==undo_after.undo_count && undo_before.redo_count==undo_after.redo_count &&
    hist_before.revision==hist_after.revision && hist_before.current_position==hist_after.current_position,"export preserves dirty state and Undo/Redo/history");
  api->free_pixels(before.pixels);api->free_pixels(after_pixels.pixels);
}
int main(int argc,char **argv) {
  if(argc!=3 && argc!=4)return 2;
  void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
  GlimsEngineGetAPIFunction get=(GlimsEngineGetAPIFunction)dlsym(lib,"glims_engine_get_api");api=get?get(GLIMS_ENGINE_API_VERSION):NULL;
  if(!api || api->struct_size<sizeof *api)return 2;
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=argv[2],.cache_directory=argv[2]};
  if(api->start(&config,&engine,NULL)!=GLIMS_STATUS_OK)return 2;
  unsigned char base[8*6*4],overlay[4*6*4];
  for(int i=0;i<8*6;i++){base[i*4]=(unsigned char)(20+25*(i%8));base[i*4+1]=(unsigned char)(180-15*(i%8));base[i*4+2]=(unsigned char)(70+20*(i%6));base[i*4+3]=(i%8==7)?0:64;}
  for(int i=0;i<4*6;i++){overlay[i*4]=180;overlay[i*4+1]=30;overlay[i*4+2]=220;overlay[i*4+3]=128;}
  GlimsImageID image=0;require(api->image_from_pixels(engine,8,6,base,sizeof base,&image,NULL));
  GlimsItemID top=0,mask=0;require(api->image_paste_pixels(engine,image,(GlimsRect){-1,0,4,6},overlay,sizeof overlay,&top,NULL));
  GlimsLayerChange change={.struct_size=sizeof change,.properties=GLIMS_LAYER_NAME|GLIMS_LAYER_OPACITY,.opacity=.5};strcpy(change.name,"Edited foreground");
  require(api->layer_change(engine,image,top,&change,NULL));
  require(api->layer_mask_add(engine,image,top,GLIMS_MASK_WHITE,true,&mask,NULL));
  GlimsFillSettings fill={.struct_size=sizeof fill,.mode=GLIMS_FILL_SELECTION,.color={.5,.5,.5,1},.opacity=1};
  require(api->fill(engine,image,(GlimsPoint){0,0},&fill,NULL));
  require(api->layer_mask_set(engine,image,top,GLIMS_MASK_EDITING,0,NULL));
  GlimsFilterID effect=0;require(api->filter_begin(engine,image,top,"gegl:value-invert",&effect,NULL));require(api->filter_commit(engine,effect,NULL));
  char path[4096];snprintf(path,sizeof path,"%s/layers.psd",argv[2]);roundtrip(image,path,GLIMS_PSD_LAYERS,2,3,0);
  snprintf(path,sizeof path,"%s/merged.psd",argv[2]);roundtrip(image,path,GLIMS_PSD_MERGED,1,3,0);
  /* A different hidden layer must neither appear nor change canvas bounds. */
  GlimsItemID hidden=0;require(api->image_paste_pixels(engine,image,(GlimsRect){12,-2,4,6},overlay,sizeof overlay,&hidden,NULL));
  change=(GlimsLayerChange){.struct_size=sizeof change,.properties=GLIMS_LAYER_VISIBLE,.visible=false};require(api->layer_change(engine,image,hidden,&change,NULL));
  snprintf(path,sizeof path,"%s/hidden.psd",argv[2]);roundtrip(image,path,GLIMS_PSD_MERGED,1,3,0);
  GlimsLayerInfo rows[16];int count=layers(image,rows);
  for(int i=0;i<count;i++)require(api->layer_change(engine,image,rows[i].id,&change,NULL));
  snprintf(path,sizeof path,"%s/transparent.psd",argv[2]);roundtrip(image,path,GLIMS_PSD_MERGED,1,3,0);
  /* ABI uses a separate declaration of the exact pre-PSD settings type. */
  struct Legacy { uint32_t size,format; double quality; uint32_t progressive,optimize,sampling; int32_t compression; uint32_t interlace,transparent,tiff_compression,tiff_transparent; };
  struct Legacy legacy={sizeof legacy,GLIMS_EXPORT_PNG,.9,1,1,0,9,0,0,0,1};
  snprintf(path,sizeof path,"%s/legacy.png",argv[2]);CHECK(export(image,path,(GlimsExportSettings*)&legacy),"legacy PNG settings prefix remains accepted");
  GlimsExportSettings s=settings(GLIMS_PSD_MERGED),bad=s;
  snprintf(path,sizeof path,"%s/refused.psd",argv[2]);
  FILE *sentinel=fopen(path,"wb");if(!sentinel)return 2;fwrite("keep",1,4,sentinel);fclose(sentinel);
  for(size_t size=sizeof legacy;size<offsetof(GlimsExportSettings,psd_layout)+sizeof s.psd_layout;size++) {
    bad=s;bad.struct_size=(uint32_t)size;
    CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"PSD rejects absent or partial content choice");
  }
  bad=s;bad.psd_layout=2;CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"PSD rejects unknown layout");
  bad=s;bad.jpeg_quality=NAN;CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"PSD also validates inactive settings");
  char bytes[5]={0};sentinel=fopen(path,"rb");if(sentinel){fread(bytes,1,4,sentinel);fclose(sentinel);}CHECK(!strcmp(bytes,"keep"),"invalid export leaves existing file untouched");
  snprintf(path,sizeof path,"%s/mismatch.png",argv[2]);CHECK(!export(image,path,&s) && access(path,F_OK)!=0,"PSD rejects an extension belonging to another format");
  snprintf(path,sizeof path,"%s/mismatch.psb",argv[2]);CHECK(!export(image,path,&s) && access(path,F_OK)!=0,"PSD refuses the distinct PSB file format");
  snprintf(path,sizeof path,"%s/unaligned.psd",argv[2]);unsigned char packed[sizeof s+9];s.struct_size=sizeof s+8;memcpy(packed+1,&s,sizeof s);
  CHECK(export(image,path,(GlimsExportSettings*)(packed+1)),"unaligned complete PSD settings accept future trailing members");
  require(api->image_close(engine,image));
  int major=0,minor=0,micro=0;sscanf(api->engine_version(engine),"%d.%d.%d",&major,&minor,&micro);
  int legacy_profile=major==3 && (minor<2 || (minor==2 && micro<6));
  for(int gray=0;gray<2;gray++) for(int precision=0;precision<3;precision++) {
    require(api->image_from_pixels(engine,8,6,base,sizeof base,&image,NULL));
    if(gray)require(api->image_convert_mode(engine,image,GLIMS_COLOR_MODE_GRAYSCALE,NULL));
    if(gray && precision==0) {
      snprintf(path,sizeof path,"%s/standard-gray.psd",argv[2]);
      roundtrip(image,path,GLIMS_PSD_MERGED,1,1,0);
    }
    unsigned component=precision==0?GLIMS_COLOR_COMPONENT_U8:precision==1?GLIMS_COLOR_COMPONENT_U16:GLIMS_COLOR_COMPONENT_FLOAT;
    require(api->image_convert_precision(engine,image,component,GLIMS_COLOR_TRC_LINEAR,NULL));
    if(argc==4) {
      char profile[4096];snprintf(profile,sizeof profile,"%s/%s",argv[3],gray?"gray.icc":"wide-linear-rgb.icc");
      require(api->image_assign_profile(engine,image,profile,NULL));
    }
    snprintf(path,sizeof path,"%s/mode-%d-precision-%d.psd",argv[2],gray,precision);
    roundtrip(image,path,GLIMS_PSD_MERGED,1,gray?1:3,legacy_profile);
    require(api->image_close(engine,image));
  }
  api->stop(engine);
  printf("%d checks, %d failures\n",checks,failures);return failures?1:0;
}

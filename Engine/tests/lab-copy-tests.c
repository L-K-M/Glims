/* Slot197 converted-copy acceptance. Independent LCMS/literal oracle; never
 * calls the product Lab transform or Lab sample codec to compute expectations.
 * Private engine callbacks only seed scenes and read authoritative raw buffers.
 * Fixed pre-run limits: Lab abs <= .03 physical units; linear RGB abs <=
 * .0003 * max(1,abs(expected)). They account for independently constructed
 * LCMS sRGB colorants, not measured/adjusted output errors. */
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-quick-mask.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
#include "libgimpbase/gimpversion.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplink.h"
#include "core/gimplinklayer.h"
#include "core/gimprasterizable.h"
#endif
#include <float.h>
#include <lcms2.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define W 33
#define H 7
#define N (W * H)
static const GlimsEngineAPI *api;
static guint checks, failures;
static double maximum_lab_error, maximum_rgb_error;
#define CHECK(c,m) do { gboolean pass=!!(c); checks++; printf("%s %s\n",pass?"ok":"FAIL",m); if(!pass) failures++; fflush(stdout); } while(0)

typedef struct {
  GlimsImageID id;
  guint component;
  gboolean lab, layered;
  double expected[N][3];
} Scene;
typedef struct {
  GlimsImageID id;
  gchar pixels[65], state[65];
  guint public_images;
  double xres, yres;
  gint undo, redo, layers, channels;
  gboolean empty_mask, empty_files, linear_profile, bounded_fractional_mask;
  guint8 uuids[3][16];
  float samples[N][4];
} Capture;
typedef struct {
  cmsContext context;
  cmsHPROFILE encoded, linear, lab;
  cmsHTRANSFORM forward_encoded, forward_linear, reverse;
} Oracle;

static void clear_error(char **error) { api->free_string(*error); *error=NULL; }
static guint bytes_per(guint component) { return component==GLIMS_COLOR_COMPONENT_U8?1:component==GLIMS_COLOR_COMPONENT_U16?2:4; }
static const Babl *scalar_format(guint component) {
  return babl_format(component==GLIMS_COLOR_COMPONENT_U8?"Y u8":component==GLIMS_COLOR_COMPONENT_U16?"Y u16":"Y float");
}
static void hash_text(GChecksum *h,const char *text) {
  guint64 size=text?strlen(text):0; g_checksum_update(h,(const guchar*)&size,sizeof size);
  if(size)g_checksum_update(h,(const guchar*)text,size);
}
static void hash_parasite(GChecksum *h,const GimpParasite *p) {
  guint32 size=0; const guint8 *data=p?gimp_parasite_get_data(p,&size):NULL;
  g_checksum_update(h,(const guchar*)&size,sizeof size); if(data&&size)g_checksum_update(h,data,size);
}
static gboolean hash_drawable(GChecksum *pixels,GChecksum *state,GimpDrawable *d) {
  GimpItem *item=GIMP_ITEM(d); GeglBuffer *buffer=gimp_drawable_get_buffer(d);
  const Babl *format=gimp_drawable_get_format(d);
  gint w=gimp_item_get_width(item),h=gimp_item_get_height(item);
  if(w<=0||h<=0||w>W+8||h>H+8)return FALSE;
  gsize size=(gsize)w*h*babl_format_get_bytes_per_pixel(format);
  gpointer raw=g_malloc(size);
  gegl_buffer_get(buffer,GEGL_RECTANGLE(0,0,w,h),1,format,raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  hash_text(pixels,babl_get_name(format)); g_checksum_update(pixels,raw,size); g_free(raw);
  hash_text(pixels,gimp_object_get_name(item));
  hash_parasite(pixels,gimp_item_parasite_find(item,GLIMS_PLATE_UUID_PARASITE));
  hash_parasite(pixels,gimp_item_parasite_find(item,GLIMS_PLATE_VISIBLE_PARASITE));
  gint facts[]={w,h,gimp_item_get_offset_x(item),gimp_item_get_offset_y(item),gimp_item_get_visible(item)};
  g_checksum_update(pixels,(const guchar*)facts,sizeof facts);
  gint id=gimp_item_get_id(item);g_checksum_update(state,(const guchar*)&id,sizeof id);
  if(GIMP_IS_LAYER(d)){double opacity=gimp_layer_get_opacity(GIMP_LAYER(d));g_checksum_update(pixels,(const guchar*)&opacity,sizeof opacity);}
  return TRUE;
}
static GlimsStatus capture(GlimsEngine *engine,gpointer data) {
  Capture *out=data; GlimsImageID id=out->id; memset(out,0,sizeof *out);out->id=id;
  GlimsOpenImage *open=glims_lookup_image(engine,id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image=open->image;
  if(gimp_image_get_width(image)!=W||gimp_image_get_height(image)!=H)return GLIMS_STATUS_FAILED;
  GChecksum *pixels=g_checksum_new(G_CHECKSUM_SHA256),*state=g_checksum_new(G_CHECKSUM_SHA256);
  gboolean valid=TRUE;
  GList *layers=gimp_image_get_layer_list(image),*channels=gimp_image_get_channel_list(image);
  out->layers=g_list_length(layers);out->channels=g_list_length(channels);
  for(GList *i=layers;i;i=i->next)valid&=hash_drawable(pixels,state,i->data);
  for(GList *i=channels;i;i=i->next)valid&=hash_drawable(pixels,state,i->data);
  valid&=hash_drawable(pixels,state,GIMP_DRAWABLE(gimp_image_get_mask(image)));
  hash_parasite(pixels,gimp_image_parasite_find(image,GLIMS_PLATE_MAP_PARASITE));
  hash_parasite(pixels,gimp_image_parasite_find(image,GLIMS_PLATE_PROFILE_PARASITE));
  gsize icc_size=0;const guint8 *icc=gimp_image_get_icc_profile(image,&icc_size);
  if(icc&&icc_size)g_checksum_update(pixels,icc,icc_size);
  gimp_image_get_resolution(image,&out->xres,&out->yres);
  g_checksum_update(state,(const guchar*)&out->xres,sizeof out->xres);
  g_checksum_update(state,(const guchar*)&out->yres,sizeof out->yres);
  gint facts[]={gimp_image_is_dirty(image),gimp_image_get_undo_group_count(image),
    gimp_image_undo_is_enabled(image),gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image)),
    gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image))};
  out->undo=facts[3];out->redo=facts[4];
  g_checksum_update(state,(const guchar*)facts,sizeof facts);
  g_checksum_update(state,(const guchar*)&open->history_revision,sizeof open->history_revision);
  GList *selected=gimp_image_get_selected_drawables(image);
  for(GList *i=selected;i;i=i->next){gint item=gimp_item_get_id(i->data);g_checksum_update(state,(const guchar*)&item,sizeof item);}
  g_list_free(selected);
  GFile *files[]={gimp_image_get_file(image),gimp_image_get_imported_file(image),gimp_image_get_exported_file(image)};
  out->empty_files=TRUE;
  for(guint i=0;i<3;i++){gchar *uri=files[i]?g_file_get_uri(files[i]):NULL;out->empty_files&=!files[i];hash_text(state,uri);g_free(uri);}
  out->public_images=g_hash_table_size(engine->images);
  out->empty_mask=gimp_channel_is_empty(gimp_image_get_mask(image));
  float mask[N];gboolean fractional=FALSE,exterior_zero=TRUE;
  gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(gimp_image_get_mask(image))),
    GEGL_RECTANGLE(0,0,W,H),1,babl_format("Y float"),mask,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  for(guint p=0;p<N;p++)if(p%W>=3)exterior_zero&=mask[p]==0;else fractional|=mask[p]>0&&mask[p]<1;
  out->bounded_fractional_mask=exterior_zero&&fractional;
  if(open->component_document&&open->component_mode==GLIMS_PLATE_MODE_LAB){
    GlimsPlateStorage storage;
    valid&=glims_plate_storage_read_open(open,&storage);
    if(valid){
      for(guint c=0;c<3;c++){
        memcpy(out->uuids[c],storage.map.entries[c].uuid,16);
        if(storage.map.storage==GLIMS_PLATE_STORAGE_FLOAT){
          float row[N];gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(storage.planes[c])),
            GEGL_RECTANGLE(0,0,W,H),1,babl_format("Y float"),row,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
          for(guint p=0;p<N;p++)out->samples[p][c]=row[p];
        }
      }
    }
  }else if(layers&&out->layers==1&&gimp_image_get_base_type(image)==GIMP_RGB){
    GimpDrawable *d=layers->data;
    const Babl *format=babl_format_with_space("RGBA float",gimp_drawable_get_format(d));
    gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),1,format,out->samples,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    GimpColorProfile *profile=gimp_image_get_color_profile(image);
    if(!profile)profile=gimp_image_get_builtin_color_profile(image);
    GimpColorProfile *linear=gimp_color_profile_new_rgb_srgb_linear();
    out->linear_profile=profile&&linear&&gimp_color_profile_is_equal(profile,linear);g_clear_object(&linear);
  }
  g_strlcpy(out->pixels,g_checksum_get_string(pixels),sizeof out->pixels);
  g_strlcpy(out->state,g_checksum_get_string(state),sizeof out->state);
  g_checksum_free(pixels);g_checksum_free(state);g_list_free(layers);g_list_free(channels);
  return valid?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
}
static gboolean same_source(GlimsEngine *engine,const Capture *before) {
  Capture *now=g_new0(Capture,1);now->id=before->id;
  gboolean ok=glims_engine_call(engine,capture,now)==GLIMS_STATUS_OK&&!strcmp(before->pixels,now->pixels)&&!strcmp(before->state,now->state);
  g_free(now);return ok;
}
static GlimsStatus seed_metadata(GlimsEngine *engine,gpointer data) {
  Scene *s=data;GlimsOpenImage *open=glims_lookup_image(engine,s->id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  gimp_image_set_resolution(open->image,300,144);
  float mask[N];for(guint p=0;p<N;p++)mask[p]=(p%W<3)?(p%3+1)*.25f:0;
  GimpDrawable *d=GIMP_DRAWABLE(gimp_image_get_mask(open->image));
  gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),0,babl_format("Y float"),mask,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(d,0,0,W,H);
  gchar *path=g_strdup_printf("/tmp/glims-lab-copy-source-%d.xcf",s->id);
  GFile *file=g_file_new_for_path(path);
  gimp_image_set_file(open->image,file);
  gimp_image_set_imported_file(open->image,file);
  gimp_image_set_exported_file(open->image,file);
  g_object_unref(file);g_free(path);
  gimp_image_undo_free(open->image);
  gimp_channel_invert(gimp_image_get_mask(open->image),TRUE);
  gimp_channel_invert(gimp_image_get_mask(open->image),TRUE); /* Restore bounded mask; retain real Undo. */
  return GLIMS_STATUS_OK;
}
static const double colors[12][3]={
  {0,0,0},{1,1,1},{.5,.5,.5},{1,0,0},{0,1,0},{0,0,1},
  {1,1,0},{0,1,1},{1,0,1},{.25,.5,.75},{.1,.2,.3},{.8,.4,.2}};
static GlimsStatus create_rgb(GlimsEngine *engine,gpointer data) {
  Scene *s=data;
  GimpPrecision precision=s->component==GLIMS_COLOR_COMPONENT_U8?GIMP_PRECISION_U8_NON_LINEAR:
    s->component==GLIMS_COLOR_COMPONENT_U16?GIMP_PRECISION_U16_NON_LINEAR:GIMP_PRECISION_FLOAT_LINEAR;
  GimpImage *image=gimp_image_new(engine->gimp,W,H,GIMP_RGB,precision);if(!image)return GLIMS_STATUS_FAILED;
  const Babl *format=gimp_image_get_layer_format(image,TRUE);
  GimpLayer *layer=gimp_layer_new(image,W,H,format,"RGB oracle source",1,GIMP_LAYER_MODE_NORMAL);
  if(!layer){g_object_unref(image);return GLIMS_STATUS_FAILED;}
  guint b=bytes_per(s->component);guint8 raw[N*4*4];memset(raw,0,sizeof raw);
  for(guint p=0;p<N;p++)for(guint c=0;c<4;c++){
    double value=c==3?1:colors[p%12][c];
    if(s->component==GLIMS_COLOR_COMPONENT_FLOAT&&p%12==10)value=c==3?1:-.01;
    if(s->component==GLIMS_COLOR_COMPONENT_FLOAT&&p%12==11)value=c==3?1:2;
    if(b==1){guint8 v=(guint8)floor(value*255+.5);memcpy(raw+(p*4+c)*b,&v,b);if(c<3)s->expected[p][c]=v/255.;}
    else if(b==2){guint16 v=(guint16)floor(value*65535+.5);memcpy(raw+(p*4+c)*b,&v,b);if(c<3)s->expected[p][c]=v/65535.;}
    else{float v=value;memcpy(raw+(p*4+c)*b,&v,b);if(c<3)s->expected[p][c]=v;}
  }
  gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)),GEGL_RECTANGLE(0,0,W,H),0,format,raw,GEGL_AUTO_ROWSTRIDE);
  if(!gimp_image_add_layer(image,layer,NULL,0,FALSE)){g_object_unref(layer);g_object_unref(image);return GLIMS_STATUS_FAILED;}
  if(s->layered){
    GimpLayer *top=gimp_layer_new(image,W/2+3,H,format,"Opaque offset overlay",1,GIMP_LAYER_MODE_NORMAL);
    if(!top){g_object_unref(image);return GLIMS_STATUS_FAILED;}
    float overlay[(W/2+3)*H][4];
    for(guint p=0;p<G_N_ELEMENTS(overlay);p++){overlay[p][0]=.25;overlay[p][1]=.5;overlay[p][2]=.75;overlay[p][3]=1;}
    gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(top)),GEGL_RECTANGLE(0,0,W/2+3,H),0,
      babl_format_with_space("RGBA float",format),overlay,GEGL_AUTO_ROWSTRIDE);
    gimp_item_set_offset(GIMP_ITEM(top),-3,0);
    if(!gimp_image_add_layer(image,top,NULL,0,FALSE)){g_object_unref(top);g_object_unref(image);return GLIMS_STATUS_FAILED;}
    for(guint p=0;p<N;p++)if(p%W<W/2){s->expected[p][0]=.25;s->expected[p][1]=.5;s->expected[p][2]=.75;}
  }
  GlimsStatus status=glims_adopt_image(engine,image,&s->id);
  if(status!=GLIMS_STATUS_OK)g_object_unref(image);
  else status=seed_metadata(engine,s);
  return status;
}
static GlimsStatus seed_lab(GlimsEngine *engine,gpointer data) {
  Scene *s=data;GlimsOpenImage *open=glims_lookup_image(engine,s->id);GlimsPlateStorage storage;
  if(!open||!glims_plate_storage_read_open(open,&storage))return GLIMS_STATUS_FAILED;
  const guint8 l8[]={0,20,128,255,64,192},ab8[]={128,127,129,160,96,255};
  const guint16 l16[]={0,5243,32768,65535,16384,49152},ab16[]={32896,32639,33153,41120,24672,65535};
  const float lf[]={0,8,50,100,-5,110},af[]={0,0,-20,0,0,30},bf[]={0,0,40,0,0,-30};
  guint b=bytes_per(s->component);
  for(guint c=0;c<3;c++){
    guint8 raw[N*4];memset(raw,0,sizeof raw);
    for(guint p=0;p<N;p++){
      guint i=p%6;
      if(b==1){guint8 v=c?((i==0||i==3)?128:ab8[(i+(c-1)*2)%6]):l8[i];memcpy(raw+p*b,&v,b);s->expected[p][c]=c?(double)v-128:v*100./255;}
      else if(b==2){guint16 v=c?((i==0||i==3)?32896:ab16[(i+(c-1)*2)%6]):l16[i];memcpy(raw+p*b,&v,b);s->expected[p][c]=c?v/257.-128:v*100./65535;}
      else{float v=c==0?lf[i]:c==1?af[i]:bf[i];memcpy(raw+p*b,&v,b);s->expected[p][c]=v;}
    }
    GimpDrawable *d=GIMP_DRAWABLE(storage.planes[c]);
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),0,scalar_format(s->component),raw,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d,0,0,W,H);
  }
  return seed_metadata(engine,s);
}
static gboolean oracle_open(Oracle *o) {
  memset(o,0,sizeof *o);o->context=cmsCreateContext(NULL,NULL);if(!o->context)return FALSE;
  o->encoded=cmsCreate_sRGBProfileTHR(o->context);o->linear=cmsCreate_sRGBProfileTHR(o->context);o->lab=cmsCreateLab4ProfileTHR(o->context,NULL);
  if(!o->encoded||!o->linear||!o->lab)return FALSE;
  cmsToneCurve *curve=cmsBuildGamma(o->context,1);if(!curve)return FALSE;
  gboolean ok=cmsWriteTag(o->linear,cmsSigRedTRCTag,curve)&&cmsWriteTag(o->linear,cmsSigGreenTRCTag,curve)&&cmsWriteTag(o->linear,cmsSigBlueTRCTag,curve);
  cmsFreeToneCurve(curve);if(!ok)return FALSE;
  guint flags=cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE;
  o->forward_encoded=cmsCreateTransformTHR(o->context,o->encoded,TYPE_RGB_DBL,o->lab,TYPE_Lab_DBL,INTENT_RELATIVE_COLORIMETRIC,flags);
  o->forward_linear=cmsCreateTransformTHR(o->context,o->linear,TYPE_RGB_DBL,o->lab,TYPE_Lab_DBL,INTENT_RELATIVE_COLORIMETRIC,flags);
  o->reverse=cmsCreateTransformTHR(o->context,o->lab,TYPE_Lab_DBL,o->linear,TYPE_RGB_DBL,INTENT_RELATIVE_COLORIMETRIC,flags);
  return o->forward_encoded&&o->forward_linear&&o->reverse;
}
static void oracle_close(Oracle *o) {
  if(o->forward_encoded)cmsDeleteTransform(o->forward_encoded);if(o->forward_linear)cmsDeleteTransform(o->forward_linear);if(o->reverse)cmsDeleteTransform(o->reverse);
  if(o->encoded)cmsCloseProfile(o->encoded);if(o->linear)cmsCloseProfile(o->linear);if(o->lab)cmsCloseProfile(o->lab);if(o->context)cmsDeleteContext(o->context);
}
static void check_numeric(Oracle *o,const Scene *s,const Capture *copy) {
  gboolean valid=TRUE,negative=FALSE,extended=FALSE;double max_error=0;
  for(guint p=0;p<N;p++){
    double expected[3];
    if(!s->lab&&s->component==GLIMS_COLOR_COMPONENT_FLOAT&&s->expected[p][0]==s->expected[p][1]&&s->expected[p][1]==s->expected[p][2]&&
       (s->expected[p][0]<0||s->expected[p][0]>1)){
      double y=s->expected[p][0];expected[0]=y<=216./24389?y*(24389./27):116*cbrt(y)-16;expected[1]=expected[2]=0;
    }else cmsDoTransform(s->lab?o->reverse:s->component==GLIMS_COLOR_COMPONENT_FLOAT?o->forward_linear:o->forward_encoded,s->expected[p],expected,1);
    for(guint c=0;c<3;c++){
      double actual=copy->samples[p][c],error=fabs(actual-expected[c]);
      double limit=s->lab?.0003*fmax(1,fabs(expected[c])):.03;
      if(!isfinite(actual)||!isfinite(expected[c])||error>limit){
        if(valid)printf("     first mismatch p=%u c=%u actual=%.12g expected=%.12g limit=%.12g\n",p,c,actual,expected[c],limit);
        valid=FALSE;
      }
      max_error=fmax(max_error,error);negative|=actual<0;extended|=actual>1;
    }
    if(s->lab&&copy->samples[p][3]!=1)valid=FALSE;
  }
  CHECK(valid,s->lab?"raw linear RGB and opaque alpha match independent LCMS":"raw physical Lab matches independent LCMS/analytic literals over entire canvas");
  if(s->lab){maximum_rgb_error=fmax(maximum_rgb_error,max_error);CHECK(negative&&extended,"reverse conversion retains out-of-gamut signed/extended RGB");}
  else maximum_lab_error=fmax(maximum_lab_error,max_error);
}
static GlimsLabCopySettings settings(gboolean source_lab) {
  GlimsLabCopySettings value={sizeof value,source_lab?GLIMS_COLOR_MODE_RGB:GLIMS_COLOR_MODE_LAB,
    GLIMS_LAB_COPY_MERGED_CANVAS,GLIMS_COLOR_COMPONENT_FLOAT};return value;
}
static gboolean get_capture(GlimsEngine *engine,GlimsImageID id,Capture *out) {
  out->id=id;return glims_engine_call(engine,capture,out)==GLIMS_STATUS_OK;
}
static void check_result(GlimsEngine *engine,GlimsImageID id,gboolean source_lab,Capture *out) {
  CHECK(get_capture(engine,id,out),"capture new copy's actual raw storage");
  GlimsColorInfo color={0};GlimsUndoInfo undo={0};
  CHECK(api->image_color_info(engine,id,&color)==GLIMS_STATUS_OK&&color.mode==(source_lab?GLIMS_COLOR_MODE_RGB:GLIMS_COLOR_MODE_LAB)&&
    color.component==GLIMS_COLOR_COMPONENT_FLOAT&&color.trc==GLIMS_COLOR_TRC_LINEAR,"copy has explicit destination mode and linear Float storage");
  CHECK(out->layers==(source_lab?1:0)&&out->channels==(source_lab?0:3),"copy has only intended raster layer or three native Lab axes");
  CHECK(out->xres==300&&out->yres==144,"copy preserves nondefault 300 by 144 DPI");
  CHECK(out->empty_mask&&out->empty_files,"copy has empty selection and no source file identity");
  CHECK(out->undo==0&&out->redo==0&&api->image_undo_info(engine,id,&undo)==GLIMS_STATUS_OK&&undo.undo_count==0&&undo.redo_count==0,
    "copy has no native or facade Undo/Redo, including metadata creation");
  if(source_lab)CHECK(out->linear_profile,"RGB copy has effective built-in linear-sRGB profile (embedding is not required)");
  else CHECK(memcmp(out->uuids[0],out->uuids[1],16)&&memcmp(out->uuids[0],out->uuids[2],16)&&memcmp(out->uuids[1],out->uuids[2],16),
    "new Lab axes have distinct durable UUIDs");
}
static void roundtrip(GlimsEngine *engine,GlimsImageID id,gboolean lab,const char *work,guint serial) {
  Capture *before=g_new0(Capture,1),*after=g_new0(Capture,1);char *error=NULL;
  gboolean captured=get_capture(engine,id,before);CHECK(captured,"capture converted output before XCF persistence");
  gchar *path=g_strdup_printf("%s/copy-%u.xcf",work,serial);
  GlimsStatus status=api->image_save(engine,id,path,&error);CHECK(status==GLIMS_STATUS_OK,"save converted output as XCF");clear_error(&error);
  GlimsImageID reopened=0;
  if(status==GLIMS_STATUS_OK){status=api->image_open(engine,path,&reopened,&error);CHECK(status==GLIMS_STATUS_OK&&reopened&&reopened!=id,"reopen saved copy under a distinct owned handle");clear_error(&error);}
  if(reopened){
    CHECK(get_capture(engine,reopened,after),"read reopened converted raw samples");
    CHECK(captured&&!memcmp(before->samples,after->samples,sizeof before->samples),"XCF preserves every raw converted Float sample exactly");
    CHECK(after->xres==300&&after->yres==144&&after->empty_mask&&after->undo==0&&after->redo==0,"reopened copy preserves resolution and empty selection/history");
    GlimsColorInfo info={0};CHECK(api->image_color_info(engine,reopened,&info)==GLIMS_STATUS_OK&&info.mode==(lab?GLIMS_COLOR_MODE_LAB:GLIMS_COLOR_MODE_RGB)&&info.component==GLIMS_COLOR_COMPONENT_FLOAT,"reopened copy preserves typed mode and Float precision");
    CHECK(lab?!memcmp(before->uuids,after->uuids,sizeof before->uuids):after->linear_profile,"reopened copy retains Lab UUIDs or effective linear-sRGB profile");
    CHECK(api->image_close(engine,reopened)==GLIMS_STATUS_OK,"close reopened copy");
  }
  g_free(before);g_free(after);g_free(path);
}
static void accepted_case(GlimsEngine *engine,Oracle *oracle,Scene *s,const char *work,guint serial) {
  Capture *before=g_new0(Capture,1),*out=g_new0(Capture,1);char *error=NULL;
  CHECK(get_capture(engine,s->id,before),"capture immutable source samples, mask, metadata, history and identity");
  CHECK(!before->empty_mask,"source has an active fractional selection for full-canvas oracle");
  CHECK(before->bounded_fractional_mask,"selection has fractional interior and exactly zero exterior across the source canvas");
  CHECK(before->undo>0&&!before->empty_files,"source preservation oracle includes real Undo and nonempty file identity");
  GlimsLabCopySettings request=settings(s->lab);GlimsImageID copy=0;
  GlimsStatus status=api->image_convert_lab_copy(engine,s->id,&request,&copy,&error);
  CHECK(status==GLIMS_STATUS_OK&&copy&&copy!=s->id,"public converted-copy call returns a separate owned image");
  if(status!=GLIMS_STATUS_OK)printf("     convert status=%d error=%s\n",status,error?error:"(none)");clear_error(&error);
  CHECK(same_source(engine,before),"successful conversion leaves source byte/metadata/history identity exact");
  if(copy){
    check_result(engine,copy,s->lab,out);check_numeric(oracle,s,out);
    if(!s->lab){
      GlimsImageID second=0;status=api->image_convert_lab_copy(engine,s->id,&request,&second,&error);clear_error(&error);
      CHECK(status==GLIMS_STATUS_OK&&second&&second!=copy,"a second Lab copy is independently owned");
      if(second){Capture *other=g_new0(Capture,1);CHECK(get_capture(engine,second,other),"capture second copy identities");gboolean distinct=TRUE;
        for(guint a=0;a<3;a++)for(guint b=0;b<3;b++)distinct&=memcmp(out->uuids[a],other->uuids[b],16)!=0;
        CHECK(distinct,"unrelated copies never reuse any Lab plane UUID");g_free(other);CHECK(api->image_close(engine,second)==GLIMS_STATUS_OK,"close second copy");}
    }
    roundtrip(engine,copy,!s->lab,work,serial);
    CHECK(api->image_close(engine,copy)==GLIMS_STATUS_OK,"close converted copy independently of its source");
    CHECK(same_source(engine,before),"closing/saving copies still leaves source unchanged");
  }
  g_free(before);g_free(out);
}

/* Changes only fixture setup, never production output: final source sample is
 * deliberately invalid, so a producer that publishes after early rows fails. */
typedef enum { LATE_ALPHA, LATE_NAN, LATE_INFINITY, LATE_OVERFLOW, CUSTOM_PROFILE } Mutation;
typedef struct { Scene *scene; Mutation kind; } MutationCall;
static GlimsStatus mutate(GlimsEngine *engine,gpointer data) {
  MutationCall *m=data;Scene *s=m->scene;GlimsOpenImage *open=glims_lookup_image(engine,s->id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  GimpDrawable *d=NULL;GlimsPlateStorage storage;
  if(s->lab){if(!glims_plate_storage_read_open(open,&storage))return GLIMS_STATUS_FAILED;d=GIMP_DRAWABLE(storage.planes[0]);}
  else{GList *list=gimp_image_get_layer_list(open->image);d=list?list->data:NULL;g_list_free(list);if(!d)return GLIMS_STATUS_FAILED;}
  if(m->kind==CUSTOM_PROFILE){
    cmsHPROFILE handle=cmsCreate_sRGBProfile();cmsToneCurve *curve=cmsBuildGamma(NULL,1.8);
    if(!handle||!curve){if(handle)cmsCloseProfile(handle);if(curve)cmsFreeToneCurve(curve);return GLIMS_STATUS_FAILED;}
    gboolean ok=cmsWriteTag(handle,cmsSigRedTRCTag,curve)&&cmsWriteTag(handle,cmsSigGreenTRCTag,curve)&&cmsWriteTag(handle,cmsSigBlueTRCTag,curve);
    cmsFreeToneCurve(curve);cmsUInt32Number length=0;ok&=cmsSaveProfileToMem(handle,NULL,&length);
    guint8 *bytes=g_malloc(length);ok&=cmsSaveProfileToMem(handle,bytes,&length);cmsCloseProfile(handle);
    GimpColorProfile *profile=ok?gimp_color_profile_new_from_icc_profile(bytes,length,NULL):NULL;g_free(bytes);
    ok=profile&&gimp_image_set_color_profile(open->image,profile,NULL);g_clear_object(&profile);return ok?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
  }
  float value=m->kind==LATE_NAN?NAN:m->kind==LATE_INFINITY?INFINITY:FLT_MAX;
  if(s->lab)gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(W-1,H-1,1,1),0,babl_format("Y float"),&value,GEGL_AUTO_ROWSTRIDE);
  else{float rgba[4]={.25,.5,.75,1};if(m->kind==LATE_ALPHA)rgba[3]=.5;else rgba[0]=value;
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(W-1,H-1,1,1),0,babl_format_with_space("RGBA float",gimp_drawable_get_format(d)),rgba,GEGL_AUTO_ROWSTRIDE);}
  gimp_drawable_update(d,W-1,H-1,1,1);return GLIMS_STATUS_OK;
}
static GlimsStatus refused(GlimsEngine *engine,Scene *s,const GlimsLabCopySettings *request,const char *name) {
  Capture *before=g_new0(Capture,1),*after=g_new0(Capture,1);char *error=NULL;GlimsImageID output=12345;
  CHECK(get_capture(engine,s->id,before),"capture source before refused conversion");
  GlimsStatus status=api->image_convert_lab_copy(engine,s->id,request,&output,&error);
  CHECK(status!=GLIMS_STATUS_OK&&output==0&&error&&*error,name);clear_error(&error);
  CHECK(same_source(engine,before),"refusal preserves source raw bytes, mask, metadata and history");
  CHECK(get_capture(engine,s->id,after)&&after->public_images==before->public_images,"refusal publishes no partial output image");
  if(output)api->image_close(engine,output);
  g_free(before);g_free(after);return status;
}
static void settings_cases(GlimsEngine *engine,Scene *s) {
  GlimsLabCopySettings request=settings(FALSE);refused(engine,s,NULL,"null conversion settings refuse with zero result");
  request.struct_size=sizeof request-1;refused(engine,s,&request,"short conversion settings refuse before mutation");request=settings(FALSE);
  request.destination_mode=GLIMS_COLOR_MODE_RGB;refused(engine,s,&request,"same-mode copy is refused");request=settings(FALSE);
  request.destination_mode=999;refused(engine,s,&request,"unknown destination mode refuses");request=settings(FALSE);
  request.content=0;refused(engine,s,&request,"implicit/unknown content mode refuses");request=settings(FALSE);
  request.output_component=GLIMS_COLOR_COMPONENT_U8;refused(engine,s,&request,"integer destination precision refuses");
  struct { GlimsLabCopySettings settings;guint8 tail[19]; } future;memset(&future,0xa5,sizeof future);future.settings=settings(FALSE);future.settings.struct_size=sizeof future;
  guint8 unaligned[sizeof future+2],original[sizeof unaligned];memset(unaligned,0x6b,sizeof unaligned);memcpy(unaligned+1,&future,sizeof future);memcpy(original,unaligned,sizeof original);
  char *error=NULL;GlimsImageID output=0;GlimsStatus status=api->image_convert_lab_copy(engine,s->id,(const void*)(unaligned+1),&output,&error);clear_error(&error);
  CHECK(status==GLIMS_STATUS_OK&&output,"unaligned complete settings with future tail are accepted");
  CHECK(!memcmp(unaligned,original,sizeof original),"settings, future tail and canaries remain untouched");if(output)CHECK(api->image_close(engine,output)==GLIMS_STATUS_OK,"close future-settings copy");
  status=api->image_convert_lab_copy(engine,s->id,&future.settings,NULL,&error);CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT,"null result pointer refuses");clear_error(&error);
  output=12345;status=api->image_convert_lab_copy(engine,INT32_MAX,&future.settings,&output,&error);CHECK(status!=GLIMS_STATUS_OK&&output==0,"missing source refuses with cleared result");clear_error(&error);
}

typedef enum { GUARD_BUSY, GUARD_DISABLED_UNDO, GUARD_UNDO_GROUP, GUARD_QUICK_MASK } Guard;
typedef struct { Scene *scene;Guard guard;gboolean restore; } GuardCall;
static GlimsStatus set_guard(GlimsEngine *engine,gpointer data) {
  GuardCall *g=data;GlimsOpenImage *open=glims_lookup_image(engine,g->scene->id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  switch(g->guard){
    case GUARD_BUSY:engine->busy+=g->restore?-1:1;break;
    case GUARD_DISABLED_UNDO:
      if(!(g->restore?gimp_image_undo_enable(open->image):gimp_image_undo_disable(open->image)))return GLIMS_STATUS_FAILED;break;
    case GUARD_UNDO_GROUP:
      if(!(g->restore?gimp_image_undo_group_end(open->image):gimp_image_undo_group_start(open->image,GIMP_UNDO_GROUP_PAINT,"Fixture competing edit")))return GLIMS_STATUS_FAILED;break;
    case GUARD_QUICK_MASK:gimp_image_set_quick_mask_state(open->image,!g->restore);break;
  }
  return GLIMS_STATUS_OK;
}
static void admission_cases(GlimsEngine *engine,Scene *s) {
  GlimsLabCopySettings request=settings(s->lab);
  for(guint i=0;i<=GUARD_QUICK_MASK;i++){
    GuardCall guard={s,i,FALSE};gboolean armed=glims_engine_call(engine,set_guard,&guard)==GLIMS_STATUS_OK;
    CHECK(armed,"fixture arms actual native admission guard");
    if(armed)CHECK(refused(engine,s,&request,"active engine/history/Quick Mask refuses without changing source")==(i==GUARD_QUICK_MASK?GLIMS_STATUS_UNSUPPORTED:GLIMS_STATUS_BUSY),"admission refusal returns its documented status");
    guard.restore=TRUE;if(armed)CHECK(glims_engine_call(engine,set_guard,&guard)==GLIMS_STATUS_OK,"fixture restores native admission guard");
  }
}

#if GIMP_CHECK_VERSION (3, 2, 0)
typedef struct { Scene *scene;GlimsItemID layer;gboolean hidden; } LinkCall;
static GlimsStatus freeze_link(GlimsEngine *engine,gpointer data) {
  LinkCall *call=data;GlimsOpenImage *open=glims_lookup_image(engine,call->scene->id);
  GimpDrawable *d=open?glims_lookup_drawable(open,call->layer):NULL;
  if(!d||!GIMP_IS_LINK_LAYER(d))return GLIMS_STATUS_FAILED;
  if(!gimp_rasterizable_is_rasterized(GIMP_RASTERIZABLE(d)))
    gimp_rasterizable_rasterize(GIMP_RASTERIZABLE(d),FALSE);
  if(call->hidden)gimp_item_set_visible(GIMP_ITEM(d),FALSE,FALSE);
  return gimp_link_layer_get_link(GIMP_LINK_LAYER(d))&&
    !gimp_link_layer_is_monitored(GIMP_LINK_LAYER(d))?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
}
#endif
static void linked_cases(GlimsEngine *engine,const char *work) {
#if GIMP_CHECK_VERSION (3, 2, 0)
  gchar *path=g_build_filename(work,"linked-opaque.png",NULL);
  GdkPixbuf *pixbuf=gdk_pixbuf_new(GDK_COLORSPACE_RGB,FALSE,8,4,4);
  if(pixbuf)gdk_pixbuf_fill(pixbuf,0x4080bfff);
  gboolean saved=pixbuf&&gdk_pixbuf_save(pixbuf,path,"png",NULL,NULL);
  g_clear_object(&pixbuf);CHECK(saved,"write owned opaque PNG for genuine linked-layer fixture");
  Scene *s=g_new0(Scene,1);s->component=GLIMS_COLOR_COMPONENT_FLOAT;
  gboolean created=saved&&glims_engine_call(engine,create_rgb,s)==GLIMS_STATUS_OK;
  CHECK(created,"create RGB source for linked-layer admission");
  if(created){
    LinkCall call={.scene=s};char *error=NULL;
    GlimsStatus status=api->image_place_link(engine,s->id,path,&call.layer,&error);clear_error(&error);
    CHECK(status==GLIMS_STATUS_OK&&call.layer,"place a genuine monitored link over opaque RGB");
    if(status==GLIMS_STATUS_OK&&call.layer){
      GlimsLabCopySettings request=settings(FALSE);
      CHECK(refused(engine,s,&request,"monitored linked class refuses converted copy")==GLIMS_STATUS_UNSUPPORTED,"linked-layer refusal is UNSUPPORTED");
      CHECK(glims_engine_call(engine,freeze_link,&call)==GLIMS_STATUS_OK,"freeze genuine link while retaining native linked class and source");
      CHECK(refused(engine,s,&request,"frozen linked class also refuses converted copy")==GLIMS_STATUS_UNSUPPORTED,"unmonitored linked-layer refusal is UNSUPPORTED");
      call.hidden=TRUE;CHECK(glims_engine_call(engine,freeze_link,&call)==GLIMS_STATUS_OK,"hide frozen linked class");
      CHECK(refused(engine,s,&request,"hidden frozen linked class cannot evade admission")==GLIMS_STATUS_UNSUPPORTED,"hidden linked-layer refusal is UNSUPPORTED");
    }
  }
  if(s->id)api->image_close(engine,s->id);g_free(s);g_free(path);
#else
  (void)engine;(void)work;
  printf("LIMIT: engine has no native linked-layer class; modern linked-class cases unavailable\n");
#endif
}

typedef struct {
  GlimsEngine *engine;Scene *scene;GlimsLabCopySettings request;GlimsImageID output;
  gint armed,paused,release,timed_out;GlimsStatus status;char *error;
} Control;
static gboolean pause_idle(gpointer data) {
  Control *c=data;g_atomic_int_set(&c->paused,1);gint64 end=g_get_monotonic_time()+10*G_TIME_SPAN_SECOND;
  while(!g_atomic_int_get(&c->release)){
    g_mutex_lock(&c->engine->lock);gboolean stopping=c->engine->stopping;g_mutex_unlock(&c->engine->lock);if(stopping)break;
    if(g_get_monotonic_time()>end){g_atomic_int_set(&c->timed_out,1);break;}
    g_main_context_iteration(NULL,FALSE);g_usleep(1000);
  }
  return G_SOURCE_REMOVE;
}
static void event(void *data,const GlimsEvent *e) {
  Control *c=data;if(e->kind==GLIMS_EVENT_PROGRESS&&e->active&&g_atomic_int_compare_and_exchange(&c->armed,1,0))g_idle_add_full(G_PRIORITY_HIGH,pause_idle,c,NULL);
}
static gpointer copy_thread(gpointer data) {
  Control *c=data;c->status=api->image_convert_lab_copy(c->engine,c->scene->id,&c->request,&c->output,&c->error);return NULL;
}
static void control_case(Control *c,Scene *s) {
  c->scene=s;c->request=settings(s->lab);c->output=0;c->status=GLIMS_STATUS_FAILED;
  Capture *before=g_new0(Capture,1),*after=g_new0(Capture,1);CHECK(get_capture(c->engine,s->id,before),"capture source before controlled cancellation");
  g_atomic_int_set(&c->paused,0);g_atomic_int_set(&c->release,0);g_atomic_int_set(&c->timed_out,0);g_atomic_int_set(&c->armed,1);
  GThread *worker=g_thread_new("copy-cancel-test",copy_thread,c);
  gint64 end=g_get_monotonic_time()+10*G_TIME_SPAN_SECOND;
  while(!g_atomic_int_get(&c->paused)&&g_get_monotonic_time()<end)g_usleep(1000);
  gboolean paused=g_atomic_int_get(&c->paused);CHECK(paused,"copy services a bounded cooperative checkpoint before publication");
  if(paused){
    GlimsImageInfo info={0};CHECK(api->image_info(c->engine,s->id,&info)==GLIMS_STATUS_OK,"source metadata read remains serviceable during copy");
    CHECK(api->image_close(c->engine,s->id)==GLIMS_STATUS_BUSY,"source close is refused while converted copy owns it");
    CHECK(api->image_undo(c->engine,s->id)==GLIMS_STATUS_BUSY,"source Undo is refused while converted copy is active");
    char *error=NULL;GlimsImageID output=12345;GlimsStatus status=api->image_convert_lab_copy(c->engine,s->id,&c->request,&output,&error);
    CHECK(status==GLIMS_STATUS_BUSY&&output==0,"reentrant second copy refuses with cleared output");clear_error(&error);
    CHECK(same_source(c->engine,before),"source remains unchanged during private staging");
    CHECK(api->procedure_cancel(c->engine)==GLIMS_STATUS_OK,"Cancel reaches owned copy progress");
  }
  g_atomic_int_set(&c->release,1);g_thread_join(worker);g_atomic_int_set(&c->armed,0);
  CHECK(!g_atomic_int_get(&c->timed_out)&&c->status==GLIMS_STATUS_CANCELLED&&c->output==0,"Cancel retires private result and returns zero without timeout");clear_error(&c->error);
  CHECK(same_source(c->engine,before),"cancel leaves source exactly unchanged");
  CHECK(get_capture(c->engine,s->id,after)&&after->public_images==before->public_images,"cancel leaves no published output handle");
  CHECK(api->procedure_cancel(c->engine)==GLIMS_STATUS_NOT_FOUND,"cancelled operation releases progress ownership");
  if(c->output)api->image_close(c->engine,c->output);
  g_free(before);g_free(after);
}
/* Supplemental chunk/one-pixel branches. This oracle is CIE neutral algebra,
 * not LCMS's potentially clipping TRC path or any product helper. */
typedef struct {
  GlimsImageID id;gint width,height;gboolean lab;
  float *samples;gchar digest[65];guint public_images;
} Wide;
static double wide_value(const Wide *w,guint p) {
  static const double rgb[]={0,.003,.125,.5,1,2,-.01};
  static const double lab[]={0,8,25,50,100,110,-5};
  if(p==(guint)(w->width*w->height-1))return w->lab?37:.375;
  return w->lab?lab[p%7]:rgb[p%7];
}
static GlimsStatus wide_seed(GlimsEngine *engine,gpointer data) {
  Wide *w=data;GlimsOpenImage *open=NULL;GimpImage *image=NULL;GimpDrawable *drawable=NULL;
  gsize count=(gsize)w->width*w->height;
  if(w->lab){open=glims_lookup_image(engine,w->id);if(!open)return GLIMS_STATUS_NOT_FOUND;image=open->image;}
  else{
    image=gimp_image_new(engine->gimp,w->width,w->height,GIMP_RGB,GIMP_PRECISION_FLOAT_LINEAR);if(!image)return GLIMS_STATUS_FAILED;
    GimpLayer *layer=gimp_layer_new(image,w->width,w->height,gimp_image_get_layer_format(image,TRUE),"Wide neutral oracle",1,GIMP_LAYER_MODE_NORMAL);
    if(!layer){g_object_unref(image);return GLIMS_STATUS_FAILED;}
    if(!gimp_image_add_layer(image,layer,NULL,0,FALSE)){g_object_unref(layer);g_object_unref(image);return GLIMS_STATUS_FAILED;}
    drawable=GIMP_DRAWABLE(layer);
  }
  float *raw=g_new(float,count*4);
  if(w->lab){
    GlimsPlateStorage storage;if(!glims_plate_storage_read_open(open,&storage)){g_free(raw);return GLIMS_STATUS_FAILED;}
    for(guint c=0;c<3;c++){
      for(gsize p=0;p<count;p++)raw[p]=c?0:wide_value(w,p);
      drawable=GIMP_DRAWABLE(storage.planes[c]);
      gegl_buffer_set(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,w->width,w->height),0,babl_format("Y float"),raw,GEGL_AUTO_ROWSTRIDE);
      gimp_drawable_update(drawable,0,0,w->width,w->height);
    }
  }else{
    for(gsize p=0;p<count;p++){raw[p*4]=raw[p*4+1]=raw[p*4+2]=wide_value(w,p);raw[p*4+3]=1;}
    gegl_buffer_set(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,w->width,w->height),0,gimp_drawable_get_format(drawable),raw,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(drawable,0,0,w->width,w->height);
  }
  g_free(raw);
  if(w->lab)return GLIMS_STATUS_OK;
  GlimsStatus status=glims_adopt_image(engine,image,&w->id);if(status!=GLIMS_STATUS_OK)g_object_unref(image);return status;
}
static GlimsStatus wide_capture(GlimsEngine *engine,gpointer data) {
  Wide *w=data;GlimsOpenImage *open=glims_lookup_image(engine,w->id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image=open->image;
  if(gimp_image_get_width(image)!=w->width||gimp_image_get_height(image)!=w->height||gimp_image_get_precision(image)!=GIMP_PRECISION_FLOAT_LINEAR)return GLIMS_STATUS_FAILED;
  gsize count=(gsize)w->width*w->height;GChecksum *hash=g_checksum_new(G_CHECKSUM_SHA256);
  float *raw=g_new(float,count*4);gboolean valid=TRUE;
  if(w->lab){
    GlimsPlateStorage storage;valid=glims_plate_storage_read_open(open,&storage)&&storage.map.mode==GLIMS_PLATE_MODE_LAB&&storage.map.storage==GLIMS_PLATE_STORAGE_FLOAT;
    if(valid)for(guint c=0;c<3;c++){
      gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(storage.planes[c])),GEGL_RECTANGLE(0,0,w->width,w->height),1,babl_format("Y float"),raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      g_checksum_update(hash,(const guchar*)raw,count*sizeof(float));
      if(w->samples)for(gsize p=0;p<count;p++)w->samples[p*4+c]=raw[p];
    }
  }else{
    GList *layers=gimp_image_get_layer_list(image);valid=layers&&!layers->next&&gimp_image_get_base_type(image)==GIMP_RGB;
    if(valid){GimpDrawable *d=layers->data;
      gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,w->width,w->height),1,babl_format_with_space("RGBA float",gimp_drawable_get_format(d)),raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      g_checksum_update(hash,(const guchar*)raw,count*4*sizeof(float));if(w->samples)memcpy(w->samples,raw,count*4*sizeof(float));
    }g_list_free(layers);
  }
  gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(gimp_image_get_mask(image))),GEGL_RECTANGLE(0,0,w->width,w->height),1,babl_format("Y float"),raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  g_checksum_update(hash,(const guchar*)raw,count*sizeof(float));g_free(raw);
  hash_parasite(hash,gimp_image_parasite_find(image,GLIMS_PLATE_MAP_PARASITE));
  gsize size=0;const guint8 *icc=gimp_image_get_icc_profile(image,&size);if(icc&&size)g_checksum_update(hash,icc,size);
  gint state[]={gimp_image_is_dirty(image),gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image)),gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image))};
  g_checksum_update(hash,(const guchar*)state,sizeof state);g_checksum_update(hash,(const guchar*)&open->history_revision,sizeof open->history_revision);
  g_strlcpy(w->digest,g_checksum_get_string(hash),sizeof w->digest);g_checksum_free(hash);w->public_images=g_hash_table_size(engine->images);
  return valid?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
}
static void wide_numeric(const Wide *source,const Wide *result,gboolean round_trip) {
  gboolean correct=TRUE;double maximum=0;gsize count=(gsize)source->width*source->height;
  for(gsize p=0;p<count;p++){
    /* Expected seed is binary32, exactly what the raw fixture writes. */
    double value=(float)wide_value(source,p),expected[3];
    if(round_trip){expected[0]=value;expected[1]=expected[2]=source->lab?0:value;}
    else if(source->lab){double y=value<=8?value*(27./24389):pow((value+16)/116,3);expected[0]=expected[1]=expected[2]=y;}
    else{expected[0]=value<=216./24389?value*(24389./27):116*cbrt(value)-16;expected[1]=expected[2]=0;}
    for(guint c=0;c<3;c++){
      double actual=result->samples[p*4+c],error=fabs(actual-expected[c]);
      double limit=result->lab?.03:.0003*fmax(1,fabs(expected[c]));
      if(!isfinite(actual)||error>limit){if(correct)printf("     wide mismatch %dx%d sourceLab%d roundTrip%d p=%zu c=%u got=%.12g expected=%.12g limit=%.12g\n",source->width,source->height,source->lab,round_trip,p,c,actual,expected[c],limit);correct=FALSE;}
      maximum=fmax(maximum,error);
    }
    if(!result->lab&&result->samples[p*4+3]!=1)correct=FALSE;
  }
  CHECK(correct,round_trip?"extended neutral raw roundtrip matches independent CIE algebra":"chunk/one-pixel raw conversion matches independent CIE algebra through final pixel");
  printf("     wide %dx%d sourceLab%d roundTrip%d maximum absolute error %.9g\n",source->width,source->height,source->lab,round_trip,maximum);
}
typedef struct { Wide *source;gboolean alpha; } WideMutation;
static GlimsStatus wide_invalid(GlimsEngine *engine,gpointer data) {
  WideMutation *m=data;Wide *w=m->source;GlimsOpenImage *open=glims_lookup_image(engine,w->id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  GList *layers=gimp_image_get_layer_list(open->image);GimpDrawable *d=layers?layers->data:NULL;g_list_free(layers);if(!d)return GLIMS_STATUS_FAILED;
  float rgba[]={.375,.375,.375,1};if(m->alpha)rgba[3]=.5;else rgba[0]=NAN;
  gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(w->width-1,w->height-1,1,1),0,gimp_drawable_get_format(d),rgba,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(d,w->width-1,w->height-1,1,1);return GLIMS_STATUS_OK;
}
static void wide_cases(GlimsEngine *engine) {
  for(guint geometry=0;geometry<2;geometry++)for(guint direction=0;direction<2;direction++){
    Wide source={.width=geometry?1:4097,.height=geometry?9:2,.lab=direction};char *error=NULL;
    GlimsStatus status=direction?api->image_new_lab(engine,source.width,source.height,GLIMS_COLOR_COMPONENT_FLOAT,&source.id,&error):GLIMS_STATUS_OK;clear_error(&error);
    if(status==GLIMS_STATUS_OK)status=glims_engine_call(engine,wide_seed,&source);
    CHECK(status==GLIMS_STATUS_OK&&source.id,"create wide/changing single-column Float source");
    if(status!=GLIMS_STATUS_OK){if(source.id)api->image_close(engine,source.id);continue;}
    CHECK(glims_engine_call(engine,wide_capture,&source)==GLIMS_STATUS_OK,"capture complete wide source including final chunk");gchar before[65];memcpy(before,source.digest,sizeof before);
    GlimsLabCopySettings request=settings(direction);Wide copy={.width=source.width,.height=source.height,.lab=!direction};
    status=api->image_convert_lab_copy(engine,source.id,&request,&copy.id,&error);clear_error(&error);
    CHECK(status==GLIMS_STATUS_OK&&copy.id,"copy accepts wide/changing single-column finite extended source");
    if(copy.id){
      copy.samples=g_new0(float,(gsize)copy.width*copy.height*4);
      CHECK(glims_engine_call(engine,wide_capture,&copy)==GLIMS_STATUS_OK,"read wide converted raw Float samples");wide_numeric(&source,&copy,FALSE);
      Wide back={.width=source.width,.height=source.height,.lab=direction};request=settings(copy.lab);
      status=api->image_convert_lab_copy(engine,copy.id,&request,&back.id,&error);clear_error(&error);CHECK(status==GLIMS_STATUS_OK&&back.id,"finite extended converted output converts back without clipping");
      if(back.id){back.samples=g_new0(float,(gsize)back.width*back.height*4);CHECK(glims_engine_call(engine,wide_capture,&back)==GLIMS_STATUS_OK,"read roundtrip raw Float samples");wide_numeric(&source,&back,TRUE);g_free(back.samples);CHECK(api->image_close(engine,back.id)==GLIMS_STATUS_OK,"close wide roundtrip copy");}
      g_free(copy.samples);CHECK(api->image_close(engine,copy.id)==GLIMS_STATUS_OK,"close wide intermediate copy");
    }
    CHECK(glims_engine_call(engine,wide_capture,&source)==GLIMS_STATUS_OK&&!strcmp(before,source.digest),"wide conversion/roundtrip preserve every source sample and history");
    if(!geometry&&!direction)for(guint kind=0;kind<2;kind++){
      WideMutation mutation={&source,kind==0};CHECK(glims_engine_call(engine,wide_invalid,&mutation)==GLIMS_STATUS_OK,"place invalid alpha/NaN at final pixel beyond first 4096 samples");
      CHECK(glims_engine_call(engine,wide_capture,&source)==GLIMS_STATUS_OK,"capture late-invalid wide source bits");memcpy(before,source.digest,sizeof before);guint images=source.public_images;
      request=settings(FALSE);GlimsImageID result=12345;status=api->image_convert_lab_copy(engine,source.id,&request,&result,&error);
      CHECK(status!=GLIMS_STATUS_OK&&result==0&&error,"late second-chunk alpha/NaN refuses without publishing any output");clear_error(&error);
      CHECK(glims_engine_call(engine,wide_capture,&source)==GLIMS_STATUS_OK&&!strcmp(before,source.digest)&&source.public_images==images,"late invalid conversion keeps all source bits/history and public image count");if(result)api->image_close(engine,result);
    }
    CHECK(api->image_close(engine,source.id)==GLIMS_STATUS_OK,"close wide source");
  }
}
static void other_modes(GlimsEngine *engine) {
  for(guint indexed=0;indexed<2;indexed++){
    Scene *s=g_new0(Scene,1);s->component=GLIMS_COLOR_COMPONENT_U8;char *error=NULL;GlimsStatus status=glims_engine_call(engine,create_rgb,s);
    if(status==GLIMS_STATUS_OK){
      if(indexed){GlimsIndexedSettings settings={.struct_size=sizeof settings,.palette=GLIMS_INDEXED_PALETTE_MONO,.max_colors=2,.dither=GLIMS_INDEXED_DITHER_NONE,.preservation=GLIMS_INDEXED_PRESERVE_EDITABLE};status=api->image_convert_indexed(engine,s->id,&settings,NULL,0,&error);}
      else status=api->image_convert_mode(engine,s->id,GLIMS_COLOR_MODE_GRAYSCALE,&error);
    }clear_error(&error);CHECK(status==GLIMS_STATUS_OK,"create ordinary grayscale/indexed admission fixture");
    if(status==GLIMS_STATUS_OK){GlimsLabCopySettings request=settings(FALSE);CHECK(refused(engine,s,&request,"ordinary non-RGB mode cannot pass RGB/Lab copy admission")==GLIMS_STATUS_UNSUPPORTED,"grayscale/indexed copy returns UNSUPPORTED");}
    if(s->id)api->image_close(engine,s->id);g_free(s);
  }
  const char *path=g_getenv("GLIMS_TEST_CMYK_PROFILE");gchar *profile=NULL;gsize size=0;
  gboolean read=path&&g_file_get_contents(path,&profile,&size,NULL)&&size>=128&&size<=4*1024*1024;
  CHECK(read,"read external CMYK profile for independent unsupported-mode fixture");
  if(read){Scene s={0};char *error=NULL;GlimsStatus status=api->image_new_cmyk(engine,W,H,GLIMS_COLOR_COMPONENT_U8,(const guint8*)profile,size,&s.id,&error);clear_error(&error);
    CHECK(status==GLIMS_STATUS_OK&&s.id,"create genuine profiled CMYK admission fixture");
    if(s.id){GlimsLabCopySettings request=settings(FALSE);CHECK(refused(engine,&s,&request,"CMYK cannot pass RGB/Lab copy admission")==GLIMS_STATUS_UNSUPPORTED,"CMYK copy returns UNSUPPORTED");api->image_close(engine,s.id);}
  }g_free(profile);
}

int main(int argc,char **argv) {
  if(argc!=2){fprintf(stderr,"usage: %s WORK\n",argv[0]);return 2;}
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api||api->struct_size<offsetof(GlimsEngineAPI,image_convert_lab_copy)+sizeof api->image_convert_lab_copy||!api->image_convert_lab_copy)return 2;
  Oracle oracle;gboolean oracle_ok=oracle_open(&oracle);CHECK(oracle_ok,"independent encoded/linear sRGB and D50 Lab LCMS oracle exists");if(!oracle_ok){oracle_close(&oracle);return 2;}
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  Control control={0};GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache,.on_event=event,.event_context=&control};char *error=NULL;
  if(api->start(&config,&control.engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"start: %s\n",error?error:"failed");clear_error(&error);oracle_close(&oracle);g_free(user);g_free(cache);return 2;}
  GlimsEngine *engine=control.engine;const guint components[]={GLIMS_COLOR_COMPONENT_U8,GLIMS_COLOR_COMPONENT_U16,GLIMS_COLOR_COMPONENT_FLOAT};guint serial=0;
  for(guint direction=0;direction<2;direction++)for(guint i=0;i<3;i++){
    Scene *s=g_new0(Scene,1);s->lab=direction;s->component=components[i];
    GlimsStatus status=s->lab?api->image_new_lab(engine,W,H,s->component,&s->id,&error):glims_engine_call(engine,create_rgb,s);clear_error(&error);
    if(status==GLIMS_STATUS_OK&&s->lab)status=glims_engine_call(engine,seed_lab,s);
    CHECK(status==GLIMS_STATUS_OK&&s->id,"create precision-specific raw source fixture");
    if(status==GLIMS_STATUS_OK){accepted_case(engine,&oracle,s,argv[1],++serial);if(!direction&&i==2){settings_cases(engine,s);control_case(&control,s);admission_cases(engine,s);}}
    if(s->id)CHECK(api->image_close(engine,s->id)==GLIMS_STATUS_OK,"close source after independent copies");g_free(s);
  }
  Scene *layered=g_new0(Scene,1);layered->component=GLIMS_COLOR_COMPONENT_FLOAT;layered->layered=TRUE;
  GlimsStatus status=glims_engine_call(engine,create_rgb,layered);CHECK(status==GLIMS_STATUS_OK,"create offset opaque two-layer RGB fixture");
  if(status==GLIMS_STATUS_OK)accepted_case(engine,&oracle,layered,argv[1],++serial);
  if(layered->id)api->image_close(engine,layered->id);g_free(layered);
  for(guint direction=0;direction<2;direction++)for(guint kind=0;kind<=CUSTOM_PROFILE;kind++){
    if((direction&&kind==LATE_ALPHA)||(direction&&kind==CUSTOM_PROFILE)||(!direction&&kind==LATE_OVERFLOW))continue;
    Scene *s=g_new0(Scene,1);s->lab=direction;s->component=GLIMS_COLOR_COMPONENT_FLOAT;
    status=s->lab?api->image_new_lab(engine,W,H,s->component,&s->id,&error):glims_engine_call(engine,create_rgb,s);clear_error(&error);
    if(status==GLIMS_STATUS_OK&&s->lab)status=glims_engine_call(engine,seed_lab,s);
    MutationCall m={s,kind};gboolean seeded=status==GLIMS_STATUS_OK&&glims_engine_call(engine,mutate,&m)==GLIMS_STATUS_OK;
    CHECK(seeded,"construct independent late-invalid/profile refusal fixture");
    if(seeded){GlimsLabCopySettings request=settings(s->lab);refused(engine,s,&request,"unsupported profile or late invalid/alpha/overflow source refuses atomically");}
    if(s->id)api->image_close(engine,s->id);g_free(s);
  }
  GlimsImageID multi=0;status=api->image_new_multichannel(engine,W,H,GLIMS_COLOR_COMPONENT_U8,4,&multi,&error);clear_error(&error);
  CHECK(status==GLIMS_STATUS_OK&&multi,"create unsupported Multichannel source");
  if(multi){Scene s={.id=multi};GlimsLabCopySettings request=settings(FALSE);refused(engine,&s,&request,"Multichannel is not silently relabeled RGB or Lab");api->image_close(engine,multi);}
  linked_cases(engine,argv[1]);
  wide_cases(engine);
  other_modes(engine);
  api->stop(engine);oracle_close(&oracle);g_free(user);g_free(cache);
  printf("max physical-Lab error %.9g; max linear-RGB error %.9g (fixed limits .03 and .0003 relative)\n",maximum_lab_error,maximum_rgb_error);
  printf("%u Lab copy checks, %u failures\n",checks,failures);return failures?1:0;
}

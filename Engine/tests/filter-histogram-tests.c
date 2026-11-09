/* Fixed pixel/bin oracles; no copied histogram/stretch implementation. */
#include "engine-private.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpchannel-select.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#include "core/gimpsettings.h"
#include "operations/operations-types.h"
#include "operations/gimplevelsconfig.h"
#include "operations/gimpoperationpointfilter.h"
#include "operations/gimpoperationsettings.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static const char *work_dir;
static int failures;
#define CHECK(c,t) do { gboolean ok_=(c); printf("%s %s\n",ok_?"ok  ":"FAIL",t); if(!ok_)failures++; fflush(stdout); } while(0)
#define NEED(c,t) do { gboolean need_=(c); CHECK(need_,t); if(!need_)goto cleanup; } while(0)
typedef struct { GlimsEngine *engine; GlimsImageID id; GimpImage *image; GimpLayer *layer; } Fixture;
typedef struct { GlimsHistogramSnapshot value; guint64 tail; } Retained;
static const guint8 rgba[]={51,76,102,64,204,179,153,192,51,76,102,128,204,179,153,255};
static void clear_error(char **error) { if(*error)api->free_string(*error);*error=NULL; }
static GlimsItemID item(Fixture *f) { return gimp_item_get_id(GIMP_ITEM(f->layer)); }
static GlimsHistogramSnapshot empty(void) { return (GlimsHistogramSnapshot){.struct_size=sizeof(GlimsHistogramSnapshot)}; }
static GlimsLevelsSettings levels(void) { return (GlimsLevelsSettings){.struct_size=sizeof(GlimsLevelsSettings)}; }
static GlimsFilter *session(Fixture *f,GlimsFilterID id) { return g_hash_table_lookup(f->engine->filters,GINT_TO_POINTER(id)); }
static GimpLevelsConfig *config(Fixture *f,GlimsFilterID id) {
  return GIMP_LEVELS_CONFIG(GIMP_OPERATION_POINT_FILTER(gegl_node_get_gegl_operation(session(f,id)->operation))->config);
}
static gboolean fixture_open(GlimsEngine *engine,Fixture *f,GimpImageBaseType type,GimpPrecision precision,const void *pixels) {
  f->engine=engine;f->image=gimp_create_image(engine->gimp,8,4,type,precision,FALSE);
  if(!f->image)return FALSE;
  if(glims_adopt_image(engine,f->image,&f->id)!=GLIMS_STATUS_OK){g_object_unref(f->image);f->image=NULL;return FALSE;}
  f->layer=gimp_layer_new(f->image,4,1,gimp_image_get_layer_format(f->image,TRUE),"Histogram source",1,GIMP_LAYER_MODE_NORMAL);
  if(!f->layer)return FALSE;
  if(!gimp_image_add_layer(f->image,f->layer,NULL,0,FALSE)){g_object_unref(f->layer);f->layer=NULL;return FALSE;}
  gimp_item_set_offset(GIMP_ITEM(f->layer),2,1);
  gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(f->layer)),GEGL_RECTANGLE(0,0,4,1),0,
                  gimp_drawable_get_format(GIMP_DRAWABLE(f->layer)),pixels,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(GIMP_DRAWABLE(f->layer),0,0,4,1);gimp_image_clean_all(f->image);return TRUE;
}
static void fixture_close(Fixture *f) { if(f->id)api->image_close(f->engine,f->id);f->id=0;f->image=NULL;f->layer=NULL; }
static gboolean pixels(Fixture *f,gboolean effects,gfloat out[16]) {
  if(effects)gimp_pickable_flush(GIMP_PICKABLE(f->layer));
  GeglBuffer *buffer=effects?gimp_drawable_get_buffer_with_effects(GIMP_DRAWABLE(f->layer)):gimp_drawable_get_buffer(GIMP_DRAWABLE(f->layer));
  if(!buffer)return FALSE;
  gegl_buffer_get(buffer,GEGL_RECTANGLE(0,0,4,1),1,babl_format("R'G'B'A float"),out,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  if(effects)g_object_unref(buffer);return TRUE;
}
static gboolean near_pixels(const gfloat *a,const gfloat *b) { for(guint i=0;i<16;i++)if(!isfinite(b[i])||fabs(a[i]-b[i])>2e-4)return FALSE;return TRUE; }
static gboolean channel_equal(const GlimsLevelsChannel *a,const GlimsLevelsChannel *b) {
  return fabs(a->low_input-b->low_input)<1e-10&&fabs(a->high_input-b->high_input)<1e-10&&a->gamma==b->gamma&&a->low_output==b->low_output&&a->high_output==b->high_output;
}
static gboolean settings_equal(const GlimsLevelsSettings *a,const GlimsLevelsSettings *b) {
  return a->trc==b->trc&&a->clamp_input==b->clamp_input&&a->clamp_output==b->clamp_output&&channel_equal(&a->value,&b->value)&&
    channel_equal(&a->red,&b->red)&&channel_equal(&a->green,&b->green)&&channel_equal(&a->blue,&b->blue)&&channel_equal(&a->alpha,&b->alpha);
}
static gboolean history_same(Fixture *f,const GlimsUndoInfo *before) {
  GlimsUndoInfo after={0};return api->image_undo_info(f->engine,f->id,&after)==GLIMS_STATUS_OK&&before->undo_count==after.undo_count&&before->redo_count==after.redo_count;
}
static double sum(const double *bins,guint count) { double result=0;for(guint i=0;i<count;i++)result+=bins[i];return result; }
static gboolean sparse(const double *bins,guint count,guint first,double a,guint second,double b) {
  if(!bins)return FALSE;
  for(guint i=0;i<count;i++)if(!isfinite(bins[i])||fabs(bins[i]-(i==first?a:0)-(i==second?b:0))>2e-6)return FALSE;
  return TRUE;
}
static gboolean histogram_equal(const GlimsHistogramSnapshot *a,const GlimsHistogramSnapshot *b) {
  const double *x[]={a->value,a->red,a->green,a->blue,a->alpha,a->luminance},*y[]={b->value,b->red,b->green,b->blue,b->alpha,b->luminance};
  if(a->trc!=b->trc||a->bin_count!=b->bin_count||a->channels!=b->channels)return FALSE;
  for(guint i=0;i<6;i++)if((!x[i])!=(!y[i])||(x[i]&&memcmp(x[i],y[i],a->bin_count*sizeof(double))))return FALSE;
  return TRUE;
}
static gboolean cleared(const GlimsHistogramSnapshot *s) { return !s->trc&&!s->bin_count&&!s->channels&&!s->value&&!s->red&&!s->green&&!s->blue&&!s->alpha&&!s->luminance; }
static gboolean begin(Fixture *f,const char *operation,GlimsFilterID *id,char **error) { return api->filter_begin(f->engine,f->id,item(f),operation,id,error)==GLIMS_STATUS_OK; }
static gboolean nonlinear(Fixture *f,GlimsFilterID id,char **error) {
  GlimsLevelsSettings s=levels();return api->filter_levels_get(f->engine,id,&s,error)==GLIMS_STATUS_OK&&
    (s.trc=GLIMS_COLOR_TRC_NONLINEAR,api->filter_levels_set(f->engine,id,&s,error)==GLIMS_STATUS_OK);
}
static gboolean endpoints(const GlimsLevelsChannel *c,int low,int high,int bins) {
  return fabs(c->low_input-(double)low/(bins-1))<1e-10&&fabs(c->high_input-(double)high/(bins-1))<1e-10&&c->gamma==1&&c->low_output==0&&c->high_output==1;
}
static GlimsStatus rgb_auto(GlimsEngine *engine,gpointer data) {
  Retained *retained=data;Fixture f={0},loaded={0};GlimsFilterID filter=0;GimpLevelsConfig *old=NULL;char *error=NULL;
  GlimsHistogramSnapshot h=empty(),again=empty();GlimsLevelsSettings rich=levels(),out=levels(),accepted=levels();
  GlimsUndoInfo before={0},after={0};gfloat raw[16],actual[16],preview[16];GlimsImageID opened=0;
  NEED(fixture_open(engine,&f,GIMP_RGB,GIMP_PRECISION_U8_NON_LINEAR,rgba)&&begin(&f,"gimp:levels",&filter,&error)&&nonlinear(&f,filter,&error),"u8 captured Levels source starts in explicit NONLINEAR TRC");
  NEED(api->filter_input_histogram(engine,filter,&h,&error)==GLIMS_STATUS_OK,"public histogram exports actual captured source");
  NEED(h.bin_count==256&&h.channels==63&&h.trc==GLIMS_COLOR_TRC_NONLINEAR&&h.value&&h.red&&h.green&&h.blue&&h.alpha&&h.luminance,"u8 RGB-alpha exports all six native 256-bin channels");
  const double low=192.0/255,high=447.0/255;
  CHECK(sparse(h.red,256,51,low,204,high)&&sparse(h.green,256,76,low,179,high)&&sparse(h.blue,256,102,low,153,high),"literal encoded RGB bins carry fractional source-alpha weights");
  CHECK(sparse(h.value,256,102,low,204,high)&&memcmp(h.value,h.luminance,256*sizeof(double))&&fabs(sum(h.luminance,256)-low-high)<2e-6,"Value is max RGB while independent luminance retains weighted count");
  CHECK(h.alpha[64]==1&&h.alpha[128]==1&&h.alpha[192]==1&&h.alpha[255]==1&&sum(h.alpha,256)==4,"Alpha counts pixels without multiplying their source alpha");
  CHECK(h.red!=h.green&&h.green!=h.blue&&h.blue!=h.value&&h.alpha!=h.luminance,"exported channel arrays have independent ownership");
  NEED(api->filter_levels_get(engine,filter,&rich,&error)==GLIMS_STATUS_OK,"capture full Levels settings before rich preview");
  rich.value=(GlimsLevelsChannel){.02,.98,1.7,.1,.9};rich.red=rich.green=rich.blue=(GlimsLevelsChannel){.1,.9,1.4,.1,.9};
  rich.alpha=(GlimsLevelsChannel){.05,.95,1.3,.1,.9};rich.clamp_input=1;rich.clamp_output=0;
  NEED(api->filter_levels_set(engine,filter,&rich,&error)==GLIMS_STATUS_OK,"deliberately different RGB and Alpha preview installs");
  g_object_set(config(&f,filter),"channel",GIMP_HISTOGRAM_BLUE,"time",(gint64)12345,"gimp-opacity",.63,
                "gimp-clip",GIMP_TRANSFORM_RESIZE_CLIP,"gimp-region",GIMP_FILTER_REGION_DRAWABLE,"gimp-mode",GIMP_LAYER_MODE_MULTIPLY,NULL);
  old=g_object_ref(config(&f,filter));GimpOperationSettings *base=GIMP_OPERATION_SETTINGS(old);
  gimp_layer_set_opacity(f.layer,.25,FALSE);
  NEED(api->filter_input_histogram(engine,filter,&again,&error)==GLIMS_STATUS_OK&&pixels(&f,FALSE,raw)&&api->image_undo_info(engine,f.id,&before)==GLIMS_STATUS_OK,"rich preview captures independent histogram, raw source and history");
  CHECK(histogram_equal(&h,&again),"input histogram ignores active Levels RGB/Alpha preview and layer opacity");api->free_histogram_snapshot(&again);gimp_layer_set_opacity(f.layer,1,FALSE);
  NEED(api->filter_levels_auto(engine,filter,&out,&error)==GLIMS_STATUS_OK,"public Levels Auto returns a complete authoritative result");
  CHECK(endpoints(&out.value,0,255,256)&&endpoints(&out.red,51,204,256)&&endpoints(&out.green,76,179,256)&&endpoints(&out.blue,102,153,256),"Auto resets Value and uses literal RGB bin endpoints, gamma and outputs");
  CHECK(out.trc==rich.trc&&out.clamp_input==rich.clamp_input&&out.clamp_output==rich.clamp_output&&channel_equal(&out.alpha,&rich.alpha)&&config(&f,filter)->channel==GIMP_HISTOGRAM_BLUE,"Auto preserves Alpha, TRC, clamps and non-Value native cursor");
  GimpOperationSettings *now=GIMP_OPERATION_SETTINGS(config(&f,filter));
  CHECK(config(&f,filter)!=old&&GIMP_SETTINGS(config(&f,filter))->time==12345&&now->clip==base->clip&&now->region==base->region&&now->mode==base->mode&&now->opacity==base->opacity,"Auto replaces config immutably and preserves complete base metadata");
  CHECK(pixels(&f,FALSE,actual)&&!memcmp(raw,actual,sizeof raw)&&history_same(&f,&before),"Auto preview leaves raw source and native history untouched");accepted=out;
  GimpLevelsConfig *same=config(&f,filter);
  NEED(api->filter_levels_auto(engine,filter,&out,&error)==GLIMS_STATUS_OK,"repeated Auto succeeds");
  CHECK(config(&f,filter)==same&&settings_equal(&accepted,&out)&&history_same(&f,&before),"Auto no-op retains config identity and history");
  gimp_item_set_lock_content(GIMP_ITEM(f.layer),TRUE,FALSE);
  CHECK(api->filter_input_histogram(engine,filter,&again,&error)==GLIMS_STATUS_OK&&histogram_equal(&h,&again),"pixel-locked source remains readable");api->free_histogram_snapshot(&again);
  CHECK(api->filter_levels_auto(engine,filter,&out,&error)==GLIMS_STATUS_LOCKED&&config(&f,filter)==same,"pixel lock refuses Auto without replacing config");clear_error(&error);gimp_item_set_lock_content(GIMP_ITEM(f.layer),FALSE,FALSE);
  engine->busy++;GlimsStatus read_status=api->filter_input_histogram(engine,filter,&again,&error);clear_error(&error);
  GlimsStatus auto_status=api->filter_levels_auto(engine,filter,&out,&error);engine->busy--;
  CHECK(read_status==GLIMS_STATUS_BUSY&&cleared(&again)&&auto_status==GLIMS_STATUS_BUSY&&config(&f,filter)==same,"busy histogram and Auto refuse with no mutation");clear_error(&error);
  NEED(api->filter_input_histogram(engine,filter,&retained->value,&error)==GLIMS_STATUS_OK,"future-tail owned histogram retained for host after stop");
  CHECK(retained->value.struct_size==sizeof *retained&&retained->tail==0x12345678&&histogram_equal(&h,&retained->value)&&retained->value.red!=h.red,"owned snapshot preserves future tail and independent storage");
  NEED(pixels(&f,TRUE,preview)&&api->filter_commit(engine,filter,&error)==GLIMS_STATUS_OK,"Auto preview applies");filter=0;
  CHECK(api->image_undo_info(engine,f.id,&after)==GLIMS_STATUS_OK&&after.undo_count==before.undo_count+1,"Auto Apply contributes exactly one native Undo");
  CHECK(api->image_undo(engine,f.id)==GLIMS_STATUS_OK&&pixels(&f,TRUE,actual)&&near_pixels(raw,actual),"Undo restores the original normalized pixels");
  CHECK(api->image_redo(engine,f.id)==GLIMS_STATUS_OK&&pixels(&f,TRUE,actual)&&near_pixels(preview,actual),"Redo restores the Auto rendered pixels");
  GlimsEffectInfo effects[2]={{0}};int32_t count=0;
  NEED(api->drawable_effects(engine,f.id,item(&f),effects,2,&count)==GLIMS_STATUS_OK&&count==1&&api->filter_edit_begin(engine,f.id,item(&f),effects[0].id,&filter,&error)==GLIMS_STATUS_OK,"committed Auto settings reopen");
  NEED(api->filter_levels_get(engine,filter,&out,&error)==GLIMS_STATUS_OK&&settings_equal(&accepted,&out),"committed full settings match Auto result");
  rich=accepted;rich.red.gamma=2;NEED(api->filter_levels_set(engine,filter,&rich,&error)==GLIMS_STATUS_OK&&api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"Cancel drops a later preview");filter=0;
  CHECK(pixels(&f,TRUE,actual)&&near_pixels(preview,actual),"Cancel preserves committed Auto pixels");
  gchar *path=g_build_filename(work_dir,"histogram-auto-normalized.xcf",NULL);
  gboolean saved=api->image_save(engine,f.id,path,&error)==GLIMS_STATUS_OK&&api->image_open(engine,path,&opened,&error)==GLIMS_STATUS_OK;g_free(path);
  NEED(saved,"normalized Auto XCF saves and reopens");GlimsLayerInfo layers[2]={{0}};GlimsOpenImage *open=glims_lookup_image(engine,opened);
  NEED(api->image_layers(engine,opened,layers,2,&count)==GLIMS_STATUS_OK&&count==1,"loaded Auto XCF has one source layer");
  loaded=(Fixture){engine,opened,open->image,GIMP_LAYER(glims_lookup_drawable(open,layers[0].id))};
  CHECK(pixels(&loaded,TRUE,actual)&&near_pixels(preview,actual),"normalized XCF retains rendered Auto pixels");
  NEED(api->drawable_effects(engine,opened,item(&loaded),effects,2,&count)==GLIMS_STATUS_OK&&count==1&&api->filter_edit_begin(engine,opened,item(&loaded),effects[0].id,&filter,&error)==GLIMS_STATUS_OK,"loaded Auto effect reopens");
  CHECK(api->filter_levels_get(engine,filter,&out,&error)==GLIMS_STATUS_OK&&settings_equal(&accepted,&out),"normalized XCF retains all authoritative Levels settings");
cleanup:
  if(f.layer)gimp_item_set_lock_content(GIMP_ITEM(f.layer),FALSE,FALSE);
  if(filter)api->filter_abort(engine,filter);if(opened)api->image_close(engine,opened);
  clear_error(&error);g_clear_object(&old);api->free_histogram_snapshot(&h);api->free_histogram_snapshot(&again);fixture_close(&f);return GLIMS_STATUS_OK;
}
static GlimsStatus selection_and_refusals(GlimsEngine *engine,gpointer unused) {
  (void)unused;Fixture f={0};GlimsFilterID filter=0;char *error=NULL;GlimsHistogramSnapshot h=empty(),out=empty();GlimsLevelsSettings auto_out=levels();
  NEED(fixture_open(engine,&f,GIMP_RGB,GIMP_PRECISION_U8_NON_LINEAR,rgba)&&begin(&f,"gimp:levels",&filter,&error)&&nonlinear(&f,filter,&error),"selection fixture starts at nonzero drawable offset");
  /* The u8 image's selection stores encoded coverage bytes 255/128/64/0. */
  const gfloat weights[]={1,128.0f/255,64.0f/255,0};GeglBuffer *mask=gegl_buffer_new(GEGL_RECTANGLE(0,0,4,1),babl_format("Y float"));
  gegl_buffer_set(mask,GEGL_RECTANGLE(0,0,4,1),0,babl_format("Y float"),weights,GEGL_AUTO_ROWSTRIDE);
  gimp_channel_select_buffer(gimp_image_get_mask(f.image),"Histogram fixture",mask,2,1,GIMP_CHANNEL_OP_REPLACE,FALSE,0,0);g_object_unref(mask);
  NEED(api->filter_input_histogram(engine,filter,&h,&error)==GLIMS_STATUS_OK,"fractional selection histogram calculates");
  CHECK(sparse(h.red,256,51,24512.0/65025,204,24576.0/65025)&&sparse(h.value,256,102,24512.0/65025,204,24576.0/65025),"image-space fractional selection translates through drawable offset and multiplies RGB alpha weights");
  CHECK(h.alpha[64]==1&&fabs(h.alpha[128]-64.0/255)<2e-6&&fabs(h.alpha[192]-128.0/255)<2e-6&&fabs(sum(h.alpha,256)-(1+192.0/255))<2e-6,"selected Alpha counts selection only, including fractional coverage");
  NEED(api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"selection Levels preview aborts");filter=0;
  NEED(begin(&f,"gimp:curves",&filter,&error),"Curves shares captured input histogram");GlimsCurvesSnapshot curve={.struct_size=sizeof curve};
  NEED(api->filter_curves_set_trc(engine,filter,GLIMS_COLOR_TRC_NONLINEAR,&curve,&error)==GLIMS_STATUS_OK,"Curves TRC matches source histogram");api->free_curves_snapshot(&curve);
  GlimsCurvePoint invert[]={{0,1,GLIMS_CURVE_POINT_SMOOTH},{1,0,GLIMS_CURVE_POINT_SMOOTH}},zero[]={{0,0,GLIMS_CURVE_POINT_SMOOTH},{1,0,GLIMS_CURVE_POINT_SMOOTH}};
  GlimsCurveEdit edit={.struct_size=sizeof edit,.channel=GLIMS_CURVE_CHANNEL_VALUE,.mode=GLIMS_CURVE_EDIT_SMOOTH_POINTS,.points=invert,.point_count=2};
  NEED(api->filter_curves_edit(engine,filter,&edit,&curve,&error)==GLIMS_STATUS_OK,"Curves preview changes RGB");api->free_curves_snapshot(&curve);edit.channel=GLIMS_CURVE_CHANNEL_ALPHA;edit.points=zero;
  NEED(api->filter_curves_edit(engine,filter,&edit,&curve,&error)==GLIMS_STATUS_OK,"Curves preview zeros Alpha");api->free_curves_snapshot(&curve);
  CHECK(api->filter_input_histogram(engine,filter,&out,&error)==GLIMS_STATUS_OK&&histogram_equal(&h,&out),"input histogram ignores active Curves RGB and zero-Alpha preview");api->free_histogram_snapshot(&out);
  CHECK(api->filter_levels_auto(engine,filter,&auto_out,&error)==GLIMS_STATUS_UNSUPPORTED,"Curves refuses Levels-only Auto");clear_error(&error);
  const gfloat one=1;mask=gegl_buffer_new(GEGL_RECTANGLE(0,0,1,1),babl_format("Y float"));gegl_buffer_set(mask,GEGL_RECTANGLE(0,0,1,1),0,babl_format("Y float"),&one,GEGL_AUTO_ROWSTRIDE);
  gimp_channel_select_buffer(gimp_image_get_mask(f.image),"Outside fixture",mask,0,0,GIMP_CHANNEL_OP_REPLACE,FALSE,0,0);g_object_unref(mask);
  CHECK(api->filter_input_histogram(engine,filter,&out,&error)==GLIMS_STATUS_OK&&out.bin_count==0&&out.channels==GLIMS_HISTOGRAM_VALUE&&!out.value&&!out.red&&!out.alpha,"fresh no-intersection histogram has zero bins and no arrays");api->free_histogram_snapshot(&out);
  NEED(api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"Curves preview aborts before stale lookup");
  CHECK(api->filter_input_histogram(engine,filter,&out,&error)==GLIMS_STATUS_NOT_FOUND&&cleared(&out)&&api->filter_levels_auto(engine,filter,&auto_out,&error)==GLIMS_STATUS_NOT_FOUND,"aborted session ids refuse histogram and Auto");filter=0;clear_error(&error);
  NEED(begin(&f,"gegl:invert-linear",&filter,&error),"other native operation begins");
  CHECK(api->filter_input_histogram(engine,filter,&out,&error)==GLIMS_STATUS_UNSUPPORTED&&cleared(&out),"other filter refuses histogram without owned output");clear_error(&error);
  CHECK(api->filter_levels_auto(engine,filter,&auto_out,&error)==GLIMS_STATUS_UNSUPPORTED,"other filter refuses Auto");clear_error(&error);
  NEED(api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"other preview aborts");filter=0;
  NEED(begin(&f,"gimp:levels",&filter,&error),"closed-image refusal fixture begins");fixture_close(&f);
  CHECK(api->filter_input_histogram(engine,filter,&out,&error)==GLIMS_STATUS_NOT_FOUND&&cleared(&out),"closed image destroys its captured histogram session");filter=0;
cleanup:
  if(filter)api->filter_abort(engine,filter);clear_error(&error);api->free_histogram_snapshot(&h);api->free_histogram_snapshot(&out);fixture_close(&f);return GLIMS_STATUS_OK;
}
static GlimsStatus precision_and_gray(GlimsEngine *engine,gpointer unused) {
  (void)unused;Fixture f={0};GlimsFilterID filter=0;char *error=NULL;GlimsHistogramSnapshot h=empty();GlimsLevelsSettings rich=levels(),out=levels();
  const gfloat hdr[]={.25,.5,.75,-.5,1.5,-.5,.5,1.5,.25,.5,.75,-.5,1.5,-.5,.5,1.5};
  NEED(fixture_open(engine,&f,GIMP_RGB,GIMP_PRECISION_FLOAT_LINEAR,hdr)&&begin(&f,"gimp:levels",&filter,&error),"actual linear FLOAT HDR source begins");
  NEED(api->filter_input_histogram(engine,filter,&h,&error)==GLIMS_STATUS_OK,"FLOAT histogram calculates");
  CHECK(h.bin_count==1024&&h.trc==GLIMS_COLOR_TRC_LINEAR&&h.channels==63,"FLOAT source retains native 1024-bin LINEAR shape");
  CHECK(sparse(h.red,1024,256,-1,1023,3)&&sparse(h.value,1024,767,-1,1023,3)&&sparse(h.alpha,1024,0,2,1023,2),"fixed HDR alpha excursions retain signed RGB weights and selection-only Alpha counts");api->free_histogram_snapshot(&h);
  NEED(api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"FLOAT preview aborts");filter=0;fixture_close(&f);
  const guint8 gray[]={51,255,204,255,51,255,204,255};
  NEED(fixture_open(engine,&f,GIMP_GRAY,GIMP_PRECISION_U8_NON_LINEAR,gray)&&begin(&f,"gimp:levels",&filter,&error)&&nonlinear(&f,filter,&error),"encoded gray-alpha fixture begins");
  NEED(api->filter_input_histogram(engine,filter,&h,&error)==GLIMS_STATUS_OK,"gray histogram calculates");
  CHECK(h.channels==(GLIMS_HISTOGRAM_VALUE|GLIMS_HISTOGRAM_ALPHA)&&h.bin_count==256&&sparse(h.value,256,51,2,204,2)&&!h.red&&!h.green&&!h.blue&&!h.luminance,"gray has Value/Alpha only and literal encoded bins");
  NEED(api->filter_levels_get(engine,filter,&rich,&error)==GLIMS_STATUS_OK,"capture gray full settings");rich.red=rich.green=rich.blue=(GlimsLevelsChannel){.1,.9,2,.2,.8};
  NEED(api->filter_levels_set(engine,filter,&rich,&error)==GLIMS_STATUS_OK&&api->filter_levels_auto(engine,filter,&out,&error)==GLIMS_STATUS_OK,"gray Auto runs on captured gray histogram");
  CHECK(endpoints(&out.value,51,204,256)&&channel_equal(&rich.red,&out.red)&&channel_equal(&rich.green,&out.green)&&channel_equal(&rich.blue,&out.blue)&&channel_equal(&rich.alpha,&out.alpha)&&out.trc==rich.trc,"gray Auto stretches Value while preserving unused RGB, Alpha and TRC");
cleanup:
  if(filter)api->filter_abort(engine,filter);clear_error(&error);api->free_histogram_snapshot(&h);fixture_close(&f);return GLIMS_STATUS_OK;
}
static GlimsStatus invalid_outputs(GlimsEngine *engine,gpointer unused) {
  (void)unused;char *error=NULL;GlimsHistogramSnapshot small,witness;
  memset(&small,0xA5,sizeof small);small.struct_size=sizeof small-1;memcpy(&witness,&small,sizeof small);
  CHECK(api->filter_input_histogram(engine,0,NULL,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&api->filter_input_histogram(engine,0,&small,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"NULL/undersized histogram output refuses before lookup");clear_error(&error);
  api->free_histogram_snapshot(&small);CHECK(!memcmp(&small,&witness,sizeof small),"undersized Get/Free preserves every caller byte");
  GlimsLevelsSettings out=levels();out.struct_size=sizeof out-1;
  CHECK(api->filter_levels_auto(engine,0,NULL,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&api->filter_levels_auto(engine,0,&out,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"Auto validates output size before lookup");clear_error(&error);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
  if(argc!=2)return 2;work_dir=argv[1];api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api||api->struct_size<sizeof *api)return 2;
  Retained retained={.value={.struct_size=sizeof retained},.tail=0x12345678};char *error=NULL;
  gchar *user=g_build_filename(work_dir,"user",NULL),*cache=g_build_filename(work_dir,"cache",NULL);
  GlimsEngineConfig config_={.struct_size=sizeof config_,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;
  if(api->start(&config_,&engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"%s\n",error?error:"start failed");clear_error(&error);g_free(user);g_free(cache);return 2;}
  CHECK(glims_engine_call(engine,rgb_auto,&retained)==GLIMS_STATUS_OK,"RGB histogram and actual Auto workflow execute on worker");
  CHECK(glims_engine_call(engine,selection_and_refusals,NULL)==GLIMS_STATUS_OK,"selection/captured-input/refusal fixtures execute on worker");
  CHECK(glims_engine_call(engine,precision_and_gray,NULL)==GLIMS_STATUS_OK,"FLOAT signed weights and gray Auto execute on worker");
  CHECK(glims_engine_call(engine,invalid_outputs,NULL)==GLIMS_STATUS_OK,"invalid-output fixtures execute on worker");api->stop(engine);
  CHECK(retained.value.bin_count==256&&retained.value.red&&fabs(retained.value.red[51]-192.0/255)<2e-6&&retained.tail==0x12345678,"host reads owned bins after image destruction and engine stop");
  api->free_histogram_snapshot(&retained.value);api->free_histogram_snapshot(&retained.value);
  CHECK(cleared(&retained.value)&&retained.value.struct_size==sizeof retained&&retained.tail==0x12345678,"host Free after stop is repeatable and preserves future tail");
  memset(&retained.value,0xA5,sizeof retained.value);retained.value.struct_size=sizeof retained;
  CHECK(api->filter_input_histogram(NULL,1,&retained.value,&error)==GLIMS_STATUS_NOT_RUNNING&&cleared(&retained.value)&&retained.tail==0x12345678,"stopped Get clears owned output and preserves future tail");clear_error(&error);api->free_histogram_snapshot(&retained.value);
  GlimsLevelsSettings stopped=levels();CHECK(api->filter_levels_auto(NULL,1,&stopped,&error)==GLIMS_STATUS_NOT_RUNNING&&!stopped.trc,"stopped Auto returns empty output");clear_error(&error);
  g_free(user);g_free(cache);printf("%s: %d failures\n",failures?"FAILED":"PASSED",failures);return failures!=0;
}

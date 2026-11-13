/* Independent native associated-linear preview sampling/cache fixture. */
#include "lab-layer-preview.h"
#include "lab-layer-preview-read.h"
#include "lab-layer-storage.h"
#include "plate-storage.h"
#include <cairo.h>
#include <float.h>
#include <limits.h>
#include <lcms2.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpundostack.h"
#define W 267
#define H 2
#define N (W*H)
static unsigned checks, failures;
static const GlimsEngineAPI *api;
#define CHECK(c,msg) do { gboolean pass_=!!(c); checks++; if(!pass_) failures++; \
  printf("%s %s\n",pass_?"ok":"FAIL",msg); fflush(stdout); } while(0)
typedef struct { cmsContext context; cmsHPROFILE lab,rgb; cmsHTRANSFORM transform; } Oracle;
static void oracle_free(Oracle *o) {
  if(o->transform)cmsDeleteTransform(o->transform);
  if(o->rgb)cmsCloseProfile(o->rgb); if(o->lab)cmsCloseProfile(o->lab);
  if(o->context)cmsDeleteContext(o->context); memset(o,0,sizeof *o);
}
static gboolean oracle_new(Oracle *o) {
  memset(o,0,sizeof *o); o->context=cmsCreateContext(NULL,NULL);
  if(!o->context)return FALSE;
  o->lab=cmsCreateLab4ProfileTHR(o->context,NULL); o->rgb=cmsCreate_sRGBProfileTHR(o->context);
  cmsToneCurve *linear=cmsBuildGamma(o->context,1.0);
  gboolean ok=o->lab&&o->rgb&&linear;
  if(ok)ok=cmsWriteTag(o->rgb,cmsSigRedTRCTag,linear)&&cmsWriteTag(o->rgb,cmsSigGreenTRCTag,linear)&&cmsWriteTag(o->rgb,cmsSigBlueTRCTag,linear);
  if(linear)cmsFreeToneCurve(linear);
  if(ok)o->transform=cmsCreateTransformTHR(o->context,o->lab,TYPE_Lab_DBL,o->rgb,TYPE_RGB_DBL,
    INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE);
  if(!o->transform){oracle_free(o);return FALSE;} return TRUE;
}
static gboolean scalar(GimpLayer *p) {
  if(!p||!GIMP_IS_LAYER(p))return FALSE;
  const Babl *f=gimp_drawable_get_format(GIMP_DRAWABLE(p));
  return f&&babl_format_get_bytes_per_pixel(f)==1&&babl_format_get_n_components(f)==1&&
    gimp_item_get_width(GIMP_ITEM(p))==W&&gimp_item_get_height(GIMP_ITEM(p))==H;
}
static gboolean write_plane(GimpLayer *p,const guint8 *bytes) {
  if(!scalar(p)){CHECK(FALSE,"fixture requires independent scalar U8 shape guard");return FALSE;}
  GimpDrawable *d=GIMP_DRAWABLE(p);gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),0,
    gimp_drawable_get_format(d),bytes,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(d,0,0,W,H);return TRUE;
}
static GlimsLabLayerMap map_for(guint count) {
  GlimsLabLayerMap m={.width=W,.height=H,.count=count,.mode=3,.storage=1,.encoding=2};
  for(guint i=0;i<count;i++) {
    for(guint p=0;p<5;p++) {
      guint8 *id=((guint8*)&m.entries[i])+16*p;id[0]=0x71;id[14]=i+1;id[15]=p+1;
    }
  }
  return m;
}
static GimpImage *make(GlimsEngine *e,guint count) {
  GlimsLabLayerMap m=map_for(count);char *error=NULL;
  GimpImage *im=glims_lab_layer_storage_create(e,&m,&error);
  CHECK(im&&error==NULL,"private carrier setup succeeds");if(error)api->free_string(error);return im;
}
/* Full source state around each render phase; no rendered/cache oracle. */
typedef struct {
  guint8 raw[2][4][N],mask[N*16],mapping[GLIMS_LAB_LAYER_MAP_MAX_SIZE];
  guint32 mapping_size; guint mask_size,count; gint undo,redo,dirty; gboolean export_dirty;
  gint64 dirty_time; gint selected[16];guint selected_count;
  gint group_ids[2],plane_ids[2][4]; gboolean visible[2];gdouble opacity[2];
} Snapshot;
static gboolean snapshot(GimpImage *im,Snapshot *s) {
  memset(s,0,sizeof *s);GlimsLabLayerStorage st;
  if(glims_lab_layer_storage_read(im,&st)!=GLIMS_LAB_LAYER_STORAGE_VALID||st.map.count>2)return FALSE;
  s->count=st.map.count;
  for(guint i=0;i<s->count;i++) {
    s->group_ids[i]=gimp_item_get_id(GIMP_ITEM(st.layers[i].group));
    s->visible[i]=gimp_item_get_visible(GIMP_ITEM(st.layers[i].group));s->opacity[i]=gimp_layer_get_opacity(st.layers[i].group);
    for(guint p=0;p<4;p++) {
      if(!scalar(st.layers[i].planes[p]))return FALSE;
      GimpDrawable *d=GIMP_DRAWABLE(st.layers[i].planes[p]);s->plane_ids[i][p]=gimp_item_get_id(GIMP_ITEM(d));
      gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),1,gimp_drawable_get_format(d),s->raw[i][p],GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    }
  }
  const GimpParasite *parasite=gimp_image_parasite_find(im,GLIMS_PLATE_MAP_PARASITE);
  if(!parasite)return FALSE;
  const void *bytes=gimp_parasite_get_data(parasite,&s->mapping_size);
  if(!bytes||s->mapping_size>sizeof s->mapping)return FALSE;memcpy(s->mapping,bytes,s->mapping_size);
  GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(im));const Babl *f=gimp_drawable_get_format(mask);
  gint bpp=babl_format_get_bytes_per_pixel(f);if(bpp<=0||bpp>16)return FALSE;s->mask_size=N*bpp;
  gegl_buffer_get(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(0,0,W,H),1,f,s->mask,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  s->undo=gimp_undo_stack_get_depth(gimp_image_get_undo_stack(im));s->redo=gimp_undo_stack_get_depth(gimp_image_get_redo_stack(im));
  s->dirty=gimp_image_is_dirty(im);s->export_dirty=gimp_image_is_export_dirty(im);s->dirty_time=gimp_image_get_dirty_time(im);
  /* Native selected-layers list is borrowed, never freed. */
  for(GList *it=gimp_image_get_selected_layers(im);it;it=it->next){if(s->selected_count==16)return FALSE;s->selected[s->selected_count++]=gimp_item_get_id(it->data);}
  return TRUE;
}
static void preserved(GimpImage *im,const Snapshot *before) {
  Snapshot after;gboolean ok=snapshot(im,&after);CHECK(ok&&memcmp(before,&after,sizeof after)==0,"render preserves all source bytes, UUID map, selection, attrs and native history/dirty state");
}
/* Reference is a separate GEGL associated-linear buffer, with pixels derived
 * from literal physical triples through an independent LCMS profile. */
static void rgb_for(Oracle *o,double l,double a,double b,float *rgb) {
  double lab[3]={(float)l,(float)a,(float)b},out[3];cmsDoTransform(o->transform,lab,out,1);
  for(guint c=0;c<3;c++)rgb[c]=(float)out[c];
}
static GeglBuffer *reference(Oracle *o,gboolean bottom_visible,gboolean reordered,
                            double top_opacity,gboolean bottom_black,gboolean changed_pixel) {
  float pixels[N*4];
  for(guint y=0;y<H;y++)for(guint x=0;x<W;x++) {
    float *p=pixels+4*(y*W+x);gboolean opaque=(x+y)%2==0;
    if(changed_pixel&&x==1&&y==1)opaque=FALSE;
    double alpha=opaque?top_opacity:0,l=100.0*128/255;
    if(bottom_visible){alpha=1;if(reordered)l=bottom_black?0:100;
      else l=opaque?(top_opacity*(100.0*128/255)+(1-top_opacity)*(bottom_black?0:100)):(bottom_black?0:100);}
    if(alpha==0){memset(p,0,4*sizeof(float));continue;}
    rgb_for(o,l,0,0,p);for(guint c=0;c<3;c++)p[c]*=(float)alpha;p[3]=(float)alpha;
  }
  GeglBuffer *b=gegl_buffer_new(GEGL_RECTANGLE(0,0,W,H),babl_format("RaGaBaA float"));
  if(b)gegl_buffer_set(b,GEGL_RECTANGLE(0,0,W,H),0,babl_format("RaGaBaA float"),pixels,GEGL_AUTO_ROWSTRIDE);
  return b;
}
/* Independent mathematical interpolation: weighted sum of four known
 * associated source neighbors, computed in long double without row recurrence.
 * GEGL's native upscale BOX/BILINEAR paths are deliberately not this oracle. */
static void sample_reference(GeglBuffer *ref,double scale,GlimsRect area,float *out) {
  if(!(scale>.5&&scale<2&&scale!=1)) {
    gegl_buffer_get(ref,GEGL_RECTANGLE(area.x,area.y,area.width,area.height),scale,babl_format("RaGaBaA float"),out,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);return;
  }
  float source[N*4];gegl_buffer_get(ref,GEGL_RECTANGLE(0,0,W,H),1,babl_format("RaGaBaA float"),source,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  for(gint y=0;y<area.height;y++)for(gint x=0;x<area.width;x++) {
    long double u=((long double)area.x+x+.5L)/(long double)scale-.5L;
    long double v=((long double)area.y+y+.5L)/(long double)scale-.5L;
    gint left=(gint)floorl(u),top=(gint)floorl(v);long double tx=u-left,ty=v-top;
    const long double weight[4]={(1-tx)*(1-ty),tx*(1-ty),(1-tx)*ty,tx*ty};
    for(guint c=0;c<4;c++){long double sum=0;for(guint k=0;k<4;k++){
      gint sx=left+(k%2),sy=top+(k/2);if(sx>=0&&sx<W&&sy>=0&&sy<H)sum+=weight[k]*source[4*(sy*W+sx)+c];
    }out[4*(y*area.width+x)+c]=(float)sum;}
  }
}
static void compare_read(GimpImage *image,GlimsLabLayerPreview **cache,GeglBuffer *ref,double scale,GlimsRect area) {
  if(!ref){CHECK(FALSE,"reference setup must succeed before comparison");return;}
  printf("PHASE scale=%.17g area=%d,%d,%d,%d\n",scale,area.x,area.y,area.width,area.height);
  size_t stride=(size_t)area.width*16+9,total=(size_t)area.height*stride+2;
  guint8 *actual=g_malloc(total),*prior=g_malloc(total);memset(actual,0xa5,total);memcpy(prior,actual,total);
  float *associated=g_new(float,(size_t)area.width*area.height*4);
  sample_reference(ref,scale,area,associated);
  GlimsStatus status=glims_lab_layer_preview_read(image,cache,scale,area,actual+1,stride);
  CHECK(status==GLIMS_STATUS_OK,"preview safe read succeeds");
  if(status==GLIMS_STATUS_OK) {
    for(gint y=0;y<area.height;y++)for(gint x=0;x<area.width;x++) {
      float got[4];memcpy(got,actual+1+y*stride+x*16,sizeof got);float *p=associated+4*(y*area.width+x);
      if(p[3]==0){for(guint c=0;c<4;c++)CHECK(got[c]==0&&!signbit(got[c]),"filtered alpha zero is canonical positive-zero RGBA");}
      else {
        for(guint c=0;c<3;c++) {
          double expected=(double)p[c]/p[3];gboolean ok=isfinite(got[c])&&fabs(got[c]-expected)<=.00035*fmax(1,fabs(expected));
          if(!ok)printf("MISMATCH scale=%g xy=%d,%d c=%u actual=%a expected=%a alpha=%a\n",scale,x+area.x,y+area.y,c,(double)got[c],expected,(double)p[3]);
          CHECK(ok,"filtered straight RGB matches independent premultiplied reference then unassociation");
        }
        if(fabs(got[3]-p[3])>2e-6)printf("ALPHA scale=%g xy=%d,%d actual=%a expected=%a diff=%.9g\n",scale,x+area.x,y+area.y,(double)got[3],(double)p[3],fabs(got[3]-p[3]));
        CHECK(fabs(got[3]-p[3])<=2e-6,"filtered alpha matches reference without double premultiplication");
      }
    }
    CHECK(actual[0]==0xa5&&actual[total-1]==0xa5,"unaligned allocation canaries survive");
    for(gint y=0;y<area.height;y++)CHECK(!memcmp(actual+1+y*stride+area.width*16,prior+1+y*stride+area.width*16,9),"row padding preserved");
    CHECK(*cache&&glims_lab_layer_preview_succeeded(*cache),"preview joined validation reports success");
  }
  g_free(associated);g_free(prior);g_free(actual);
}
/* Synchronous lazy tile callback path, separate from the safe helper's
 * explicit scaled validation; request associated format to avoid Babl floors. */
static void compare_lazy(GimpImage *image,GlimsLabLayerPreview **cache,GeglBuffer *ref) {
  GeglBuffer *borrowed=NULL;
  GlimsStatus status=glims_lab_layer_preview_prepare(image,cache,&borrowed);
  CHECK(status==GLIMS_STATUS_OK&&borrowed,"prepare for lazy native tile validation");
  if(status!=GLIMS_STATUS_OK||!borrowed||!ref)return;
  float actual[7*2*4],expected[7*2*4];
  gegl_buffer_get(ref,GEGL_RECTANGLE(0,0,7,2),1,babl_format("RaGaBaA float"),expected,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  gegl_buffer_get(borrowed,GEGL_RECTANGLE(0,0,7,2),1,babl_format("RaGaBaA float"),actual,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(glims_lab_layer_preview_succeeded(*cache),"synchronous lazy validation succeeds");
  for(guint i=0;i<14;i++) {
    CHECK(actual[4*i+3]==expected[4*i+3],"lazy callback preserves exact sub-floor alpha");
    for(guint c=0;c<3;c++) {
      double want=expected[4*i+3]>0?(double)expected[4*i+c]/expected[4*i+3]:0;
      double got=actual[4*i+3]>0?(double)actual[4*i+c]/actual[4*i+3]:actual[4*i+c];
      CHECK(isfinite(got)&&fabs(got-want)<.00035*fmax(1,fabs(want)),"lazy associated tile retains straight color below Babl alpha floor");
    }
  }
}
static gboolean write_pixel(GimpLayer *plane,guint x,guint y,guint8 value) {
  if(!scalar(plane)){CHECK(FALSE,"pixel fixture scalar U8 guard");return FALSE;}
  GimpDrawable *d=GIMP_DRAWABLE(plane);gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(x,y,1,1),0,gimp_drawable_get_format(d),&value,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(d,x,y,1,1);return TRUE;
}
static void seed_checker(GlimsLabLayerStorage *st) {
  guint8 data[N];
  for(guint i=0;i<2;i++)for(guint p=0;p<4;p++) {
    for(guint y=0;y<H;y++)for(guint x=0;x<W;x++) {
      gboolean opaque=(x+y)%2==0;
      data[y*W+x]=i? (p==0?255:p==3?0:128) :
        (p==3?(opaque?255:0):p==0?(opaque?128:255):opaque?128:(p==1?0:255));
    }
    write_plane(st->layers[i].planes[p],data);
  }
}
static void invalid_arguments(GimpImage *im,GlimsLabLayerPreview **cache) {
  guint8 out[80],before[80];memset(out,0xa5,sizeof out);memcpy(before,out,sizeof out);
  const double scales[]={0,-1,NAN,INFINITY};
  for(guint i=0;i<G_N_ELEMENTS(scales);i++) {
    CHECK(glims_lab_layer_preview_read(im,cache,scales[i],(GlimsRect){0,0,1,1},out+1,16)!=GLIMS_STATUS_OK,"invalid scale refuses");
    CHECK(!memcmp(out,before,sizeof out),"invalid scale preserves output");
  }
  CHECK(glims_lab_layer_preview_read(im,cache,1,(GlimsRect){0,0,2,1},out+1,31)!=GLIMS_STATUS_OK,"undersized stride refuses before publication");
  CHECK(!memcmp(out,before,sizeof out),"invalid stride preserves whole destination");
  CHECK(glims_lab_layer_preview_read(im,cache,1,(GlimsRect){0,0,1,1},NULL,16)!=GLIMS_STATUS_OK,"nonempty NULL output refuses");
}
static void real_corner(GlimsEngine *engine,Oracle *o) {
  GlimsLabLayerMap map=map_for(1);map.width=map.height=4;char *error=NULL;
  GimpImage *image=glims_lab_layer_storage_create(engine,&map,&error);
  CHECK(image&&error==NULL,"real corner carrier creates");if(error)api->free_string(error);if(!image)return;
  GlimsLabLayerStorage st;gboolean valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID;
  CHECK(valid,"real corner carrier validates");if(!valid){g_object_unref(image);return;}
  guint8 raw[4][16];
  for(guint p=0;p<4;p++) {
    GimpLayer *plane=st.layers[0].planes[p];const Babl *f=gimp_drawable_get_format(GIMP_DRAWABLE(plane));
    gboolean safe=babl_format_get_bytes_per_pixel(f)==1&&babl_format_get_n_components(f)==1&&gimp_item_get_width(GIMP_ITEM(plane))==4&&gimp_item_get_height(GIMP_ITEM(plane))==4;
    CHECK(safe,"real corner independently guards scalar shape");if(!safe){g_object_unref(image);return;}
    memset(raw[p],p==0?255:p==3?0:128,16);if(p==3)raw[p][15]=255;
    gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(plane)),GEGL_RECTANGLE(0,0,4,4),0,f,raw[p],GEGL_AUTO_ROWSTRIDE);
  }
  guint8 alpha=0;gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(st.layers[0].planes[3])),GEGL_RECTANGLE(3,3,1,1),1,gimp_drawable_get_format(GIMP_DRAWABLE(st.layers[0].planes[3])),&alpha,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(alpha==255,"real corner positively witnesses opaque bottom-right source");
  GlimsLabLayerPreview *cache=NULL;float pixel[4]={-9,-9,-9,-9};
  GlimsStatus status=glims_lab_layer_preview_read(image,&cache,1.25,(GlimsRect){3,3,1,1},pixel,sizeof pixel);
  CHECK(status==GLIMS_STATUS_OK,"real corner read succeeds");
  printf("REAL_CORNER scale1.25 RGBA=%a,%a,%a,%a expectedalpha=.09\n",(double)pixel[0],(double)pixel[1],(double)pixel[2],(double)pixel[3]);
  if(status==GLIMS_STATUS_OK){float white[3];rgb_for(o,100,0,0,white);for(guint c=0;c<3;c++)CHECK(fabs(pixel[c]-white[c])<.00035,"real corner retains straight white after filtered association");CHECK(fabs(pixel[3]-.09)<1e-6,"real corner bilinear policy has literal .09 alpha");}
  glims_lab_layer_preview_free(cache);
  for(guint p=0;p<4;p++){guint8 after[16];GimpDrawable *d=GIMP_DRAWABLE(st.layers[0].planes[p]);gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,4,4),1,gimp_drawable_get_format(d),after,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);CHECK(!memcmp(after,raw[p],16),"real corner read preserves authoritative source bytes");}
  g_object_unref(image);
}
static GlimsStatus worker(GlimsEngine *engine,gpointer unused) {
  (void)unused;Oracle o;CHECK(oracle_new(&o),"independent LCMS oracle constructs");if(!o.transform)return GLIMS_STATUS_OK;
  real_corner(engine,&o);
  GimpImage *image=make(engine,2);if(!image){oracle_free(&o);return GLIMS_STATUS_OK;}
  GlimsLabLayerPreview *cache=NULL;GeglBuffer *borrowed=NULL,*ref=NULL;GlimsLabLayerStorage st;
  gboolean valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID;
  CHECK(valid,"fixture carrier validates");if(!valid)goto done;
  seed_checker(&st);gimp_item_set_visible(GIMP_ITEM(st.layers[1].group),FALSE,FALSE);
  /* Each 2^20-square footprint contains the entire 267x2 checker plus
   * transparent abyss. Exactly 267 source pixels have full coverage. */
  {Snapshot deep_before;CHECK(snapshot(image,&deep_before),"minimum-scale source snapshot");
   float deep[4]={0};GlimsStatus status=glims_lab_layer_preview_read(image,&cache,0x1p-20,
      (GlimsRect){0,0,1,1},deep,sizeof deep);
   CHECK(status==GLIMS_STATUS_OK,"minimum-scale Lab preview completes");
   CHECK(status==GLIMS_STATUS_OK && fabs((double)deep[3]-267.0*0x1p-40)<0x1p-58,
         "minimum-scale Lab coverage includes the entire transparent abyss");
   float expected[3];rgb_for(&o,100.0*128/255,0,0,expected);
   for(guint c=0;c<3;c++)CHECK(status==GLIMS_STATUS_OK && fabs(deep[c]-expected[c])<2e-5,
       "minimum-scale Lab preview preserves straight linear color");
   preserved(image,&deep_before);}
  /* An actual partial native selection must not be applied a second time. */
  GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(image));float coverage=.375f;
  gegl_buffer_set(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,1,1,1),0,babl_format("Y float"),&coverage,GEGL_AUTO_ROWSTRIDE);
  float readback=0;gegl_buffer_get(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,1,1,1),1,babl_format("Y float"),&readback,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(fabs(readback-.375)<.005,"selection setup positively has partial coverage");
  Snapshot before;
  /* Below 1/65536: prove both lazy tiles and explicit scaled reads agree with
   * true manual alpha division, rather than Babl's straight-format floor. */
  gimp_layer_set_opacity(st.layers[0].group,0x1p-20,FALSE);
  ref=reference(&o,FALSE,FALSE,0x1p-20,FALSE,FALSE);CHECK(ref!=NULL,"sub-floor independent reference allocates");
  CHECK(snapshot(image,&before),"sub-floor source snapshot");
  compare_lazy(image,&cache,ref);
  compare_read(image,&cache,ref,1,(GlimsRect){0,0,7,2});
  compare_read(image,&cache,ref,.75,(GlimsRect){0,0,7,2});preserved(image,&before);
  gimp_layer_set_opacity(st.layers[0].group,1,FALSE);g_clear_object(&ref);
  CHECK(snapshot(image,&before),"all source state snapshotted before prepare");
  CHECK(glims_lab_layer_preview_prepare(image,&cache,&borrowed)==GLIMS_STATUS_OK&&cache&&borrowed,"prepare returns owned cache and borrowed lazy buffer");
  ref=reference(&o,FALSE,FALSE,1,FALSE,FALSE);CHECK(ref!=NULL,"independent associated reference allocates");if(!ref)goto done;
  const double scales[]={.5,.75,1,1.3};
  for(guint i=0;i<G_N_ELEMENTS(scales);i++) {
    gint width=(gint)ceil(W*scales[i]),height=(gint)ceil(H*scales[i]);
    compare_read(image,&cache,ref,scales[i],(GlimsRect){0,0,width,height});
  }
  /* Literal rational neighbors straddling the 256-output seam. At scale13/10
   * sourceu255=196+1/26,u256=196+21/26,v0=-3/26. */
  {float seam[8];GlimsStatus status=glims_lab_layer_preview_read(image,&cache,1.3,(GlimsRect){255,0,2,1},seam,sizeof seam);
   CHECK(status==GLIMS_STATUS_OK,"literal magnification seam read succeeds");
   if(status==GLIMS_STATUS_OK){CHECK(fabs(seam[3]-575.0/676)<1e-6,"left seam alpha is literal575/676");CHECK(fabs(seam[7]-115.0/676)<1e-6,"right seam alpha is literal115/676");}}
  /* Explicit single pixel and chunk/tile edge after scaled mipmap reads. */
  compare_read(image,&cache,ref,1,(GlimsRect){256,1,1,1});
  compare_read(image,&cache,ref,1,(GlimsRect){0,1,257,1});
  invalid_arguments(image,&cache);preserved(image,&before);
  GlimsLabLayerPreview *original_cache=cache;GeglBuffer *original_buffer=borrowed;
  write_pixel(st.layers[0].planes[3],1,1,0);CHECK(snapshot(image,&before),"source snapshot after intentional alpha pixel mutation");
  g_clear_object(&ref);ref=reference(&o,FALSE,FALSE,1,FALSE,TRUE);
  CHECK(glims_lab_layer_preview_prepare(image,&cache,&borrowed)==GLIMS_STATUS_OK&&cache==original_cache&&borrowed==original_buffer,"same-buffer dirty tracking reuses cache identity");
  compare_read(image,&cache,ref,1,(GlimsRect){1,1,1,1});
  compare_read(image,&cache,ref,.75,(GlimsRect){0,0,(gint)ceil(W*.75),(gint)ceil(H*.75)});
  {float deep[4]={0};GlimsStatus status=glims_lab_layer_preview_read(image,&cache,0x1p-20,
      (GlimsRect){0,0,1,1},deep,sizeof deep);
   CHECK(status==GLIMS_STATUS_OK && fabs((double)deep[3]-266.0*0x1p-40)<0x1p-58,
         "minimum-scale cache refreshes after an alpha write");}
  preserved(image,&before);
  /* Stale-alpha neighbor at the 257-pixel chunk boundary, after scaled warmup. */
  write_pixel(st.layers[0].planes[3],256,1,255);
  { float associated[4];rgb_for(&o,100,-128,127,associated);associated[3]=1;
    gegl_buffer_set(ref,GEGL_RECTANGLE(256,1,1,1),0,babl_format("RaGaBaA float"),associated,GEGL_AUTO_ROWSTRIDE); }
  CHECK(snapshot(image,&before),"boundary alpha-edit snapshot");
  compare_read(image,&cache,ref,1,(GlimsRect){0,1,257,1});
  compare_read(image,&cache,ref,1,(GlimsRect){256,1,1,1});
  compare_read(image,&cache,ref,1.3,(GlimsRect){330,0,5,3});preserved(image,&before);
  write_pixel(st.layers[0].planes[3],256,1,0);
  {const float transparent[4]={0,0,0,0};gegl_buffer_set(ref,GEGL_RECTANGLE(256,1,1,1),0,babl_format("RaGaBaA float"),transparent,GEGL_AUTO_ROWSTRIDE);}

  /* Change an excluded hidden source, then unhide: no missed stale tile. */
  guint8 data[N];memset(data,255,N);write_plane(st.layers[1].planes[3],data);
  compare_read(image,&cache,ref,1,(GlimsRect){1,1,1,1});
  gimp_item_set_visible(GIMP_ITEM(st.layers[1].group),TRUE,FALSE);
  g_clear_object(&ref);ref=reference(&o,TRUE,FALSE,1,FALSE,TRUE);
  CHECK(snapshot(image,&before),"snapshot after explicit unhide");compare_read(image,&cache,ref,1,(GlimsRect){0,0,W,H});preserved(image,&before);
  /* Opacity0 source remains tracked while excluded; recapture after enabling. */
  gimp_layer_set_opacity(st.layers[1].group,0,FALSE);memset(data,0,N);write_plane(st.layers[1].planes[0],data);
  g_clear_object(&ref);ref=reference(&o,FALSE,FALSE,1,FALSE,TRUE);compare_read(image,&cache,ref,1,(GlimsRect){1,1,1,1});
  gimp_layer_set_opacity(st.layers[1].group,1,FALSE);
  gimp_layer_set_opacity(st.layers[0].group,.5,FALSE);g_clear_object(&ref);ref=reference(&o,TRUE,FALSE,.5,TRUE,TRUE);
  compare_read(image,&cache,ref,.75,(GlimsRect){0,0,(gint)ceil(W*.75),(gint)ceil(H*.75)});
  CHECK(gimp_image_reorder_item(image,GIMP_ITEM(st.layers[1].group),NULL,0,FALSE,NULL),"reorder fixture succeeds");
  g_clear_object(&ref);ref=reference(&o,TRUE,TRUE,.5,TRUE,TRUE);compare_read(image,&cache,ref,1,(GlimsRect){256,1,1,1});
  /* Replace a native plane buffer; prepare must stop using the old ref. */
  GimpDrawable *d=GIMP_DRAWABLE(st.layers[1].planes[0]);const Babl *format=gimp_drawable_get_format(d);
  GeglBuffer *replacement=gegl_buffer_new(GEGL_RECTANGLE(0,0,W,H),format);CHECK(replacement!=NULL,"replacement buffer creates");
  if(replacement){memset(data,255,N);gegl_buffer_set(replacement,GEGL_RECTANGLE(0,0,W,H),0,format,data,GEGL_AUTO_ROWSTRIDE);gimp_drawable_set_buffer(d,FALSE,NULL,replacement);g_object_unref(replacement);
    g_clear_object(&ref);ref=reference(&o,TRUE,TRUE,.5,FALSE,TRUE);CHECK(snapshot(image,&before),"replacement snapshot");compare_read(image,&cache,ref,1,(GlimsRect){1,1,1,1});preserved(image,&before);}
  gimp_image_parasite_detach(image,GLIMS_PLATE_MAP_PARASITE,FALSE);borrowed=(GeglBuffer*)image;
  CHECK(glims_lab_layer_preview_prepare(image,&cache,&borrowed)!=GLIMS_STATUS_OK&&cache==NULL&&borrowed==NULL,"invalid metadata refuses and clears existing cache/output");
  {GlimsLabLayerMap m=map_for(2);guint8 bytes[GLIMS_LAB_LAYER_MAP_MAX_SIZE];size_t length=0;
   CHECK(glims_lab_layer_map_encode(&m,bytes,sizeof bytes,&length),"original explicit map encodes for recovery");
   GimpParasite *p=gimp_parasite_new(GLIMS_PLATE_MAP_PARASITE,GIMP_PARASITE_PERSISTENT,length,bytes);gimp_image_parasite_attach(image,p,FALSE);gimp_parasite_free(p);}
  compare_read(image,&cache,ref,1,(GlimsRect){1,1,1,1});
done:
  glims_lab_layer_preview_free(cache);g_clear_object(&ref);g_object_unref(image);
  image=make(engine,0);cache=NULL;if(image){ref=gegl_buffer_new(GEGL_RECTANGLE(0,0,W,H),babl_format("RaGaBaA float"));CHECK(ref!=NULL,"transparent empty reference creates");if(ref){gegl_buffer_clear(ref,NULL);CHECK(snapshot(image,&before),"empty state snapshot");compare_read(image,&cache,ref,1.3,(GlimsRect){0,0,4,2});preserved(image,&before);g_object_unref(ref);}glims_lab_layer_preview_free(cache);g_object_unref(image);}
  oracle_free(&o);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
  if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;
  GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start failed: %s\n",error?error:"unknown");api->free_string(error);return 2;}api->free_string(error);
  status=glims_engine_call(engine,worker,NULL);api->stop(engine);printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;
}

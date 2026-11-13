/* Independent native byte transport and physical-Lab row-render oracle. */
#include "lab-layer-render.h"
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
static gboolean saw_negative, saw_extended;
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
static void expected_pixel(Oracle *o,const void *out,double l,double a,double b,double alpha) {
  float got[4];memcpy(got,out,sizeof got);
  if((float)alpha==0) {
    for(guint c=0;c<4;c++)CHECK(got[c]==0&&!signbit(got[c]),"float-alpha-zero result is canonical positive zero");return;
  }
  /* Contract narrows the physical composite once to binary32 before transform. */
  double lab[3]={(float)l,(float)a,(float)b},rgb[3];cmsDoTransform(o->transform,lab,rgb,1);
  for(guint c=0;c<3;c++) {
    gboolean ok=isfinite(got[c])&&fabs((double)got[c]-rgb[c])<=.0003*fmax(1,fabs(rgb[c]));
    if(!ok)printf("MISMATCH RGB%u actual=%a expected=%a Lab=%a,%a,%a\n",c,(double)got[c],rgb[c],lab[0],lab[1],lab[2]);
    CHECK(ok,"straight linear RGB agrees with separate LCMS oracle");
    saw_negative |= got[c]<0; saw_extended |= got[c]>1;
  }
  CHECK(got[3]==(float)alpha,"alpha equals independently rounded rational coverage");
}
static gboolean render_expect(GlimsLabLayerRender *r,Oracle *o,gint x,gint y,guint width,
                              double l,double a,double b,double alpha) {
  guint8 bytes[256*4*sizeof(float)+2];memset(bytes,0xa5,sizeof bytes);
  gboolean ok=glims_lab_layer_render_row(r,x,y,width,bytes+1);CHECK(ok,"row succeeds at valid offset and width");if(!ok)return FALSE;
  CHECK(bytes[0]==0xa5&&bytes[1+width*4*sizeof(float)]==0xa5,"unaligned row output preserves canaries");
  for(guint i=0;i<width;i++)expected_pixel(o,bytes+1+i*4*sizeof(float),l,a,b,alpha);return TRUE;
}
static GlimsLabLayerRender *capture(GimpImage *im) {
  GlimsLabLayerRender *r=glims_lab_layer_render_new(im);CHECK(r!=NULL,"fresh validated image captures renderer");return r;
}
static void refusals(GlimsLabLayerRender *r) {
  guint8 out[256*16+2],before[sizeof out];memset(out,0xa5,sizeof out);memcpy(before,out,sizeof out);
  const struct {gint x,y;guint width;} bad[]={{-1,0,1},{0,-1,1},{W,0,1},{W+1,0,0},{0,H,1},{0,H,0},{0,0,257},{W-1,0,2},{INT_MAX,0,1},{0,INT_MAX,1},{0,0,G_MAXUINT}};
  for(guint i=0;i<G_N_ELEMENTS(bad);i++) {
    CHECK(!glims_lab_layer_render_row(r,bad[i].x,bad[i].y,bad[i].width,out+1),"invalid row bounds refuse");
    CHECK(!memcmp(out,before,sizeof out),"refusal preserves whole output allocation");
  }
  CHECK(!glims_lab_layer_render_row(NULL,0,0,1,out+1),"NULL renderer refuses");CHECK(!memcmp(out,before,sizeof out),"NULL renderer preserves destination");
  CHECK(!glims_lab_layer_render_row(r,0,0,1,NULL),"nonempty NULL output refuses");
  CHECK(!glims_lab_layer_render_row(r,0,0,1,(void *)(uintptr_t)(UINTPTR_MAX-3)),"overflowing output address refuses before access");
  CHECK(!glims_lab_layer_render_row(r,0,0,1,r),"output cannot overlap opaque renderer allocation");
  CHECK(glims_lab_layer_render_row(r,W,H-1,0,NULL),"zero-width edge accepts NULL destination");
  CHECK(!glims_lab_layer_render_row(NULL,0,0,0,NULL),"zero-width still requires renderer");
}
static void seed(GlimsLabLayerStorage *st,guint8 top_alpha,guint8 bottom_alpha) {
  const guint8 colors[2][4]={{255,255,0,0},{0,0,255,0}};guint8 plane[N];
  for(guint i=0;i<2;i++)for(guint p=0;p<4;p++){memset(plane,p==3?(i?bottom_alpha:top_alpha):colors[i][p],N);write_plane(st->layers[i].planes[p],plane);}
}
static GlimsStatus worker(GlimsEngine *engine,gpointer unused) {
  (void)unused;Oracle oracle;CHECK(oracle_new(&oracle),"independent D50 Lab to linear sRGB LCMS oracle creates");if(!oracle.transform)return GLIMS_STATUS_OK;
  GimpImage *image=make(engine,2);if(!image){oracle_free(&oracle);return GLIMS_STATUS_OK;}
  GlimsLabLayerStorage st;gboolean valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID;
  CHECK(valid,"carrier validates before fixture topology edits");if(!valid)goto done;
  /* Reverse root order relative to immutable map order, permute all four children. */
  CHECK(gimp_image_reorder_item(image,GIMP_ITEM(st.layers[1].group),NULL,0,FALSE,NULL),"root order intentionally differs from map order");
  for(guint i=0;i<2;i++)CHECK(gimp_image_reorder_item(image,GIMP_ITEM(st.layers[i].planes[3]),GIMP_ITEM(st.layers[i].group),0,FALSE,NULL),"child native order intentionally differs from role order");
  valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID;
  CHECK(valid&&st.layers[0].map_index==1&&st.layers[1].map_index==0,"fixture reads reversed native root membership");if(!valid)goto done;
  seed(&st,128,255);gimp_layer_set_opacity(st.layers[0].group,.5,FALSE);
  /* Nonempty selection must not influence an independent display row. */
  GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(image));float coverage=.375f;
  gegl_buffer_set(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,1,1,1),0,babl_format("Y float"),&coverage,GEGL_AUTO_ROWSTRIDE);
  Snapshot before;CHECK(snapshot(image,&before),"source snapshot captured");
  GlimsLabLayerRender *r=capture(image);
  if(r) {
    render_expect(r,&oracle,0,0,256,1280.0/51,-64,63,1);
    render_expect(r,&oracle,256,1,11,1280.0/51,-64,63,1);
    render_expect(r,&oracle,266,1,1,1280.0/51,-64,63,1);refusals(r);preserved(image,&before);
    /* Live pixel edit to one captured buffer, not a new renderer. */
    guint8 plane[N];memset(plane,255,N);plane[W+1]=0;write_plane(st.layers[0].planes[0],plane);
    CHECK(snapshot(image,&before),"snapshot after deliberate live pixel mutation");
    render_expect(r,&oracle,1,1,1,0,-64,63,1);
    render_expect(r,&oracle,0,0,1,1280.0/51,-64,63,1);preserved(image,&before);
    glims_lab_layer_render_free(r);
  }
  seed(&st,128,128);gimp_layer_set_opacity(st.layers[1].group,.5,FALSE);
  r=capture(image);if(r){CHECK(snapshot(image,&before),"partial source snapshot");render_expect(r,&oracle,1,1,1,12750.0/223,7937.0/446,-8383.0/446,28544.0/65025);preserved(image,&before);glims_lab_layer_render_free(r);}
  /* Recapture attributes: hidden/zero opacity reveals the literal bottom. */
  gimp_item_set_visible(GIMP_ITEM(st.layers[0].group),FALSE,FALSE);
  r=capture(image);if(r){render_expect(r,&oracle,0,0,1,0,-128,127,64.0/255);glims_lab_layer_render_free(r);}
  gimp_item_set_visible(GIMP_ITEM(st.layers[0].group),TRUE,FALSE);gimp_layer_set_opacity(st.layers[0].group,0,FALSE);
  r=capture(image);if(r){render_expect(r,&oracle,0,0,1,0,-128,127,64.0/255);glims_lab_layer_render_free(r);}
  gimp_layer_set_opacity(st.layers[0].group,1,FALSE);gimp_layer_set_opacity(st.layers[1].group,1,FALSE);seed(&st,0,0);
  r=capture(image);if(r){render_expect(r,&oracle,0,0,1,0,0,0,0);glims_lab_layer_render_free(r);}
  seed(&st,255,255);gimp_layer_set_opacity(st.layers[0].group,DBL_TRUE_MIN,FALSE);gimp_layer_set_opacity(st.layers[1].group,0,FALSE);
  CHECK(gimp_layer_get_opacity(st.layers[0].group)==DBL_TRUE_MIN,"native group retains tiny positive opacity witness");
  r=capture(image);if(r){render_expect(r,&oracle,0,0,1,100,127,-128,DBL_TRUE_MIN);glims_lab_layer_render_free(r);}
  /* Full opaque extreme yields negative and >1 RGB; no clipping/premultiplication. */
  gimp_layer_set_opacity(st.layers[0].group,1,FALSE);
  r=capture(image);if(r){float output[4];gboolean ok=glims_lab_layer_render_row(r,0,0,1,output);CHECK(ok,"opaque gamut-extreme row succeeds");if(ok){expected_pixel(&oracle,output,100,127,-128,1);}glims_lab_layer_render_free(r);}
  /* Reorder and recapture changes which opaque literal is visible. */
  gimp_layer_set_opacity(st.layers[1].group,1,FALSE);
  CHECK(gimp_image_reorder_item(image,GIMP_ITEM(st.layers[1].group),NULL,0,FALSE,NULL),"second root reorder succeeds");
  r=capture(image);if(r){render_expect(r,&oracle,0,0,1,0,-128,127,1);glims_lab_layer_render_free(r);}
  /* Replace buffer only after disposal; new capture must read replacement. */
  GimpDrawable *d=GIMP_DRAWABLE(st.layers[1].planes[0]);const Babl *format=gimp_drawable_get_format(d);
  GeglBuffer *replacement=gegl_buffer_new(GEGL_RECTANGLE(0,0,W,H),format);
  CHECK(replacement!=NULL,"replacement buffer allocates");if(replacement){guint8 plane[N];memset(plane,255,N);gegl_buffer_set(replacement,GEGL_RECTANGLE(0,0,W,H),0,format,plane,GEGL_AUTO_ROWSTRIDE);gimp_drawable_set_buffer(d,FALSE,NULL,replacement);g_object_unref(replacement);
    r=capture(image);if(r){CHECK(snapshot(image,&before),"replacement source snapshot");render_expect(r,&oracle,0,0,1,100,-128,127,1);preserved(image,&before);glims_lab_layer_render_free(r);}}
  /* Constructor validation: malformed new captures never authorize state. */
  gimp_item_set_offset(GIMP_ITEM(st.layers[0].planes[0]),1,0);
  r=glims_lab_layer_render_new(image);CHECK(r==NULL,"constructor refuses malformed carrier geometry");glims_lab_layer_render_free(r);
done:
  g_object_unref(image);image=make(engine,0);if(image){r=capture(image);if(r){CHECK(snapshot(image,&before),"empty source snapshot");render_expect(r,&oracle,256,1,11,0,0,0,0);preserved(image,&before);glims_lab_layer_render_free(r);}g_object_unref(image);}
  CHECK(saw_negative&&saw_extended,"literal gamut witnesses preserve negative and greater-than-one RGB");
  CHECK(glims_lab_layer_render_new(NULL)==NULL,"constructor refuses NULL image");glims_lab_layer_render_free(NULL);oracle_free(&oracle);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
  if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;
  GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start failed: %s\n",error?error:"unknown");api->free_string(error);return 2;}api->free_string(error);
  status=glims_engine_call(engine,worker,NULL);api->stop(engine);printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;
}

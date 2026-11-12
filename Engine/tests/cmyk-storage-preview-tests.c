/* Native CMYK: independent full-resolution oracle, cache/Undo identity,
 * damaged ICC admission, and nonfinite-sample failure/recovery. */
#include "plate-preview.h"
#include <cairo.h>
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "gegl/gimptilehandlervalidate.h"
#include "libgimpcolor/gimpcolor.h"
#include <lcms2.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#define W 32
#define H 24
#define PIXELS (W * H)
#define RAW_BYTES (PIXELS * 4)
static const GlimsEngineAPI *api;
static guint checks, failures;
static guint8 *icc;
static gsize icc_size;
static cmsHTRANSFORM oracle;
#define CHECK(c,s) do { gboolean ok=(c); checks++; printf("%s %s\n",ok?"ok":"FAIL",s); if(!ok)failures++; fflush(stdout); } while(0)
typedef struct {
  GlimsImageID id;
  GlimsPlateMap map;
  GlimsItemID ids[4];
  guint8 before[4][RAW_BYTES], after[4][RAW_BYTES], actual[4][RAW_BYTES];
  gsize bytes;
} Scene;

static double sample(const Scene *s,guint c,guint p) {
  if(s->map.storage==GLIMS_PLATE_STORAGE_U8)return s->actual[c][p]/255.;
  if(s->map.storage==GLIMS_PLATE_STORAGE_U16){guint16 v;memcpy(&v,s->actual[c]+p*2,2);return v/65535.;}
  float v;memcpy(&v,s->actual[c]+p*4,4);return v;
}
static GlimsStatus setup(GlimsEngine *e,gpointer data) {
  Scene *s=data;GlimsOpenImage *open=glims_lookup_image(e,s->id);GlimsPlateStorage storage;
  if(!open || !glims_plate_storage_read_open(open,&storage))return GLIMS_STATUS_FAILED;
  s->map=storage.map;s->bytes=PIXELS*(s->map.storage==1?1:s->map.storage==2?2:4);
  CHECK(storage.map.mode==GLIMS_PLATE_MODE_CMYK && storage.map.count==4,"CMYK storage has four authoritative planes");
  CHECK(storage.profile_size==icc_size && !memcmp(storage.profile,icc,icc_size),"native source ICC bytes are exact");
  for(guint c=0;c<4;c++){
    GimpDrawable *d=GIMP_DRAWABLE(storage.planes[c]);
    for(guint p=0;p<PIXELS;p++){
      guint v=(p*137+c*31)%1024;
      if(s->map.storage==1)s->before[c][p]=v%256;
      if(s->map.storage==2){guint16 x=v*61;memcpy(s->before[c]+p*2,&x,2);}
      if(s->map.storage==3){float x=v/1023.f;memcpy(s->before[c]+p*4,&x,4);}
    }
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),0,gimp_drawable_get_format(d),s->before[c],GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d,0,0,W,H);s->ids[c]=gimp_item_get_id(GIMP_ITEM(d));
  }
  CHECK(gimp_image_reorder_item(open->image,GIMP_ITEM(storage.planes[3]),NULL,0,FALSE,NULL),"native list reordering does not redefine CMYK order");
  gimp_image_undo_free(open->image);gimp_image_clean_all(open->image);
  return GLIMS_STATUS_OK;
}
static GlimsStatus snapshot(GlimsEngine *e,gpointer data) {
  Scene *s=data;GlimsOpenImage *open=glims_lookup_image(e,s->id);GlimsPlateStorage storage;
  if(!open || !glims_plate_storage_read_open(open,&storage))return GLIMS_STATUS_FAILED;
  if(storage.map.mode!=GLIMS_PLATE_MODE_CMYK || storage.map.count!=4 || storage.map.storage!=s->map.storage ||
     storage.profile_size!=icc_size || memcmp(storage.profile,icc,icc_size))return GLIMS_STATUS_FAILED;
  for(guint c=0;c<4;c++){
    if(memcmp(storage.map.entries[c].uuid,s->map.entries[c].uuid,16))return GLIMS_STATUS_FAILED;
    GimpDrawable *d=GIMP_DRAWABLE(storage.planes[c]);s->ids[c]=gimp_item_get_id(GIMP_ITEM(d));
    gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),1,gimp_drawable_get_format(d),s->actual[c],GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  }
  GeglBuffer *buffer=NULL;
  if(glims_plate_preview_prepare(open->image,&open->component_preview,&buffer)!=GLIMS_STATUS_OK)return GLIMS_STATUS_FAILED;
  GimpTileHandlerValidate *handler=gimp_tile_handler_validate_get_assigned(buffer);
  GeglRectangle extent={0,0,W,H};
  gimp_tile_handler_validate_validate(handler,buffer,&extent,TRUE,FALSE);
  float rgba[PIXELS*4],scaled[PIXELS],roi[6*5*4];
  gegl_buffer_get(buffer,&extent,1,babl_format("RGBA float"),rgba,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(glims_plate_preview_succeeded(open->component_preview),"valid native CMYK samples render successfully");
  double maximum=0;gboolean finite=TRUE,alpha=TRUE;
  for(guint p=0;p<PIXELS;p++){
    double coverage[4],expected[3];
    for(guint c=0;c<4;c++)coverage[c]=storage.visible[c]?(1-CLAMP(sample(s,c,p),0,1))*100:0;
    cmsDoTransform(oracle,coverage,expected,1);
    for(guint c=0;c<3;c++){
      finite &= isfinite(rgba[p*4+c]) && isfinite(expected[c]);
      maximum=MAX(maximum,fabs(rgba[p*4+c]-expected[c]));
    }
    alpha &= rgba[p*4+3]==1;
  }
  CHECK(finite && alpha && maximum<0.0002,"native full-resolution preview matches independent double LCMS oracle");
  gegl_buffer_get(buffer,GEGL_RECTANGLE(0,0,W/2,H/2),.5,babl_format("RGBA float"),scaled,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  double scale_error=0;
  for(guint y=0;y<H/2;y++)for(guint x=0;x<W/2;x++)for(guint c=0;c<4;c++){
    double expected=0;for(guint dy=0;dy<2;dy++)for(guint dx=0;dx<2;dx++)expected+=rgba[((2*y+dy)*W+2*x+dx)*4+c]/4.;
    scale_error=MAX(scale_error,fabs(expected-scaled[(y*W/2+x)*4+c]));
  }
  CHECK(scale_error<1e-6,"zoom mipmaps average converted full-resolution color");
  gegl_buffer_get(buffer,GEGL_RECTANGLE(3,7,6,5),1,babl_format("RGBA float"),roi,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  gboolean roi_equal=TRUE;
  for(guint y=0;y<5;y++)roi_equal &= !memcmp(roi+y*6*4,rgba+((y+7)*W+3)*4,6*4*sizeof(float));
  CHECK(roi_equal,"nonzero-origin preview crop is byte-identical");
  float outside[4]={1,1,1,1};
  gegl_buffer_get(buffer,GEGL_RECTANGLE(-1,-1,1,1),1,babl_format("RGBA float"),outside,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(outside[0]==0 && outside[1]==0 && outside[2]==0 && outside[3]==0,"CMYK preview outside canvas is transparent");
  printf("ORACLE storage=%u max=%.9g mipmap=%.9g\n",s->map.storage,maximum,scale_error);
  return GLIMS_STATUS_OK;
}
static gboolean same(Scene *s,guint8 expected[4][RAW_BYTES],gint except) {
  for(guint c=0;c<4;c++)if((gint)c!=except && memcmp(expected[c],s->actual[c],s->bytes))return FALSE;
  return TRUE;
}
static void profile_tag(GimpImage *image,const guint8 *bytes,guint32 size,guint32 flags) {
  GimpParasite *tag=gimp_parasite_new(GLIMS_PLATE_PROFILE_PARASITE,flags,size,bytes);
  gimp_image_parasite_attach(image,tag,FALSE);gimp_parasite_free(tag);
}
static GlimsStatus corruption(GlimsEngine *e,gpointer data) {
  Scene *s=data;GlimsOpenImage *open=glims_lookup_image(e,s->id);
  for(guint kind=0;kind<8;kind++){
    GimpImage *copy=gimp_image_duplicate(open->image);GlimsPlateStorage storage;
    if(!copy)return GLIMS_STATUS_FAILED;
    guint8 *bad=g_memdup2(icc,icc_size);
    if(kind==0)gimp_image_parasite_detach(copy,GLIMS_PLATE_PROFILE_PARASITE,FALSE);
    if(kind==1)profile_tag(copy,bad,127,GIMP_PARASITE_PERSISTENT);
    if(kind==2)profile_tag(copy,bad,icc_size,0);
    if(kind==3){bad[0]^=1;profile_tag(copy,bad,icc_size,GIMP_PARASITE_PERSISTENT);}
    if(kind==4){memcpy(bad+16,"RGB ",4);profile_tag(copy,bad,icc_size,GIMP_PARASITE_PERSISTENT);}
    if(kind==5){memcpy(bad+12,"link",4);profile_tag(copy,bad,icc_size,GIMP_PARASITE_PERSISTENT);}
    if(kind==6){memset(bad+128,0,icc_size-128);profile_tag(copy,bad,icc_size,GIMP_PARASITE_PERSISTENT);}
    if(kind==7)gimp_image_parasite_detach(copy,GLIMS_PLATE_MAP_PARASITE,FALSE);
    if(kind!=5 && kind!=6){
      memset(&storage,0xa5,sizeof storage);
      CHECK(glims_plate_storage_read(copy,&storage)==GLIMS_PLATE_STORAGE_INVALID,"structurally damaged CMYK metadata refuses");
      guint8 zero[sizeof storage]={0};CHECK(!memcmp(&storage,zero,sizeof storage),"invalid metadata clears all borrowed pointers");
    }
    GlimsImageID adopted=99;
    GlimsStatus result=glims_adopt_image(e,copy,&adopted);
    CHECK(result==GLIMS_STATUS_UNSUPPORTED && !adopted,"damaged CMYK profile cannot become a public image");
    if(result==GLIMS_STATUS_OK)api->image_close(e,adopted);else g_object_unref(copy);
    g_free(bad);
  }
  /* A valid alternate header still cannot replace the admitted source ICC in
   * an open document without an explicit color-conversion operation. */
  guint8 *changed=g_memdup2(icc,icc_size);changed[80]^=1;
  profile_tag(open->image,changed,icc_size,GIMP_PARASITE_PERSISTENT);
  GlimsPlateStorage storage;
  CHECK(!glims_plate_storage_read_open(open,&storage),"live document binds to the exact admitted ICC bytes");
  guint8 pixels[4];
  CHECK(api->image_render(e,s->id,1,(GlimsRect){0,0,1,1},pixels,4)==GLIMS_STATUS_UNSUPPORTED,"facade refuses a mutated source profile");
  profile_tag(open->image,icc,icc_size,GIMP_PARASITE_PERSISTENT);g_free(changed);
  CHECK(glims_plate_storage_read_open(open,&storage),"restoring the exact admitted profile restores storage validity");
  return GLIMS_STATUS_OK;
}
static GlimsStatus nonfinite(GlimsEngine *e,gpointer data) {
  Scene *s=data;GlimsOpenImage *open=glims_lookup_image(e,s->id);GlimsPlateStorage storage;
  if(!glims_plate_storage_read_open(open,&storage))return GLIMS_STATUS_FAILED;
  GimpDrawable *d=GIMP_DRAWABLE(storage.planes[0]);
  const float invalid[]={NAN,INFINITY,-INFINITY};guint8 pixels[PIXELS*4];
  for(guint i=0;i<G_N_ELEMENTS(invalid);i++){
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(10,10,1,1),0,babl_format("Y float"),invalid+i,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d,10,10,1,1);
    CHECK(api->image_render(e,s->id,1,(GlimsRect){0,0,W,H},pixels,W*4)==GLIMS_STATUS_FAILED,"nonfinite ink rejects a full public render");
    CHECK(api->image_render(e,s->id,.5,(GlimsRect){0,0,W/2,H/2},pixels,W*2)==GLIMS_STATUS_FAILED,"failed cached preview cannot masquerade as a valid zoom render");
    float repaired=.375f;
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(10,10,1,1),0,babl_format("Y float"),&repaired,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d,10,10,1,1);
    CHECK(api->image_render(e,s->id,1,(GlimsRect){0,0,W,H},pixels,W*4)==GLIMS_STATUS_OK,"repair retries failed cache entries successfully");
    CHECK(snapshot(e,s)==GLIMS_STATUS_OK,"repaired pixels satisfy the independent oracle");
  }
  float extended[]={-0.25f,1.25f};
  gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(10,10,2,1),0,babl_format("Y float"),extended,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(d,10,10,2,1);
  CHECK(snapshot(e,s)==GLIMS_STATUS_OK,"finite extended inks clip only when deriving preview");
  float actual[2];gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(10,10,2,1),1,babl_format("Y float"),actual,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(!memcmp(actual,extended,sizeof actual),"display clipping never rewrites authoritative extended samples");
  return GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
  if(argc!=3){fprintf(stderr,"usage: %s WORK CMYK_ICC\n",argv[0]);return 2;}
  if(!g_file_get_contents(argv[2],(gchar**)&icc,&icc_size,NULL))return 2;
  cmsHPROFILE input=cmsOpenProfileFromMem(icc,icc_size);
  GimpColorProfile *output=gimp_color_profile_new_rgb_srgb_linear();
  if(!input || !output)return 2;
  oracle=cmsCreateTransform(input,TYPE_CMYK_DBL,gimp_color_profile_get_lcms_profile(output),TYPE_RGB_DBL,
    INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_BLACKPOINTCOMPENSATION|cmsFLAGS_NOCACHE);
  if(!oracle)return 2;
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
  GlimsEngine *engine=NULL;char *error=NULL;
  if(api->start(&config,&engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"start: %s\n",error);return 2;}
  for(guint precision=1;precision<=3;precision++){
    Scene s={0};guint component=precision==1?GLIMS_COLOR_COMPONENT_U8:precision==2?GLIMS_COLOR_COMPONENT_U16:GLIMS_COLOR_COMPONENT_FLOAT;
    CHECK(api->image_new_cmyk(engine,W,H,component,icc,icc_size,&s.id,&error)==GLIMS_STATUS_OK && s.id,"public CMYK factory succeeds");
    if(!s.id)continue;
    CHECK(glims_engine_call(engine,setup,&s)==GLIMS_STATUS_OK,"native fixture seeds source samples and identities");
    CHECK(glims_engine_call(engine,snapshot,&s)==GLIMS_STATUS_OK && same(&s,s.before,-1),"initial raw samples are exact");
    GlimsBrushSettings brush={.struct_size=sizeof brush,.tool=GLIMS_PAINT_PENCIL,.size=7,.opacity=.5,.red=.25,.green=.25,.blue=.25,.hardness=1,.rate=0,.flow=100,.exposure=-1};
    GlimsStrokePoint point={16.5,12.5,1,0,0,100};GlimsStrokeID stroke=0;
    CHECK(api->stroke_begin(engine,s.id,s.ids[1],&brush,&point,&stroke,&error)==GLIMS_STATUS_OK && stroke,"Pencil paints the native Magenta plane");
    if(stroke)CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"native stroke ends");
    CHECK(glims_engine_call(engine,snapshot,&s)==GLIMS_STATUS_OK && same(&s,s.before,1) && memcmp(s.before[1],s.actual[1],s.bytes),"paint changes only the targeted scalar plane");
    memcpy(s.after,s.actual,sizeof s.after);
    CHECK(api->image_undo(engine,s.id)==GLIMS_STATUS_OK && glims_engine_call(engine,snapshot,&s)==GLIMS_STATUS_OK && same(&s,s.before,-1),"Undo restores every exact raw sample");
    CHECK(api->image_redo(engine,s.id)==GLIMS_STATUS_OK && glims_engine_call(engine,snapshot,&s)==GLIMS_STATUS_OK && same(&s,s.after,-1),"Redo restores edited raw samples and updates mipmaps");
    CHECK(glims_engine_call(engine,corruption,&s)==GLIMS_STATUS_OK,"profile corruption and source binding checks complete");
    gchar *path=g_strdup_printf("%s/native-cmyk-%u.xcf",argv[1],precision);
    CHECK(api->image_save(engine,s.id,path,&error)==GLIMS_STATUS_OK && api->image_close(engine,s.id)==GLIMS_STATUS_OK,"native CMYK saves and closes");
    s.id=0;
    CHECK(api->image_open(engine,path,&s.id,&error)==GLIMS_STATUS_OK && s.id,"native CMYK XCF reopens");
    if(s.id){
      CHECK(glims_engine_call(engine,snapshot,&s)==GLIMS_STATUS_OK && same(&s,s.after,-1),"XCF retains exact ICC, ordered UUIDs, precision and samples");
      if(precision==3)CHECK(glims_engine_call(engine,nonfinite,&s)==GLIMS_STATUS_OK,"float failure/recovery checks complete");
      CHECK(api->image_close(engine,s.id)==GLIMS_STATUS_OK,"CMYK document closes");
    }
    g_free(path);api->free_string(error);error=NULL;
  }
  api->stop(engine);g_free(user);g_free(cache);g_free(icc);
  cmsDeleteTransform(oracle);cmsCloseProfile(input);g_object_unref(output);
  printf("%u checks, %u failures\n",checks,failures);return failures?1:0;
}

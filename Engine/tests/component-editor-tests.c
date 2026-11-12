/* Derived component preview: independent numeric oracle, live edit/Undo/cache
 * invalidation, XCF identity replacement and malformed-storage refusal. */
#include "plate-preview.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpobject.h"
#include <stdio.h>
#include <math.h>
#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
#include "gegl/gimptilehandlervalidate.h"
#include <string.h>

static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c,s) do { gboolean pass=(c); checks++; printf("%s %s\n",pass?"ok":"FAIL",s); if(!pass)failures++; fflush(stdout); } while(0)
#define W 24
#define H 16
#define N 4
#define MAX_BYTES (W*H*4)
typedef struct {
  GlimsImageID id;
  GlimsPlatePreview *preview;
  GlimsPlateMap map;
  GlimsItemID ids[N];
  guint8 before[N][MAX_BYTES], after[N][MAX_BYTES], actual[N][MAX_BYTES];
  guint8 mapping[GLIMS_PLATE_MAP_MAX_SIZE];
  size_t mapping_length;
  gsize bytes;
} Scene;
static void sample_pattern(unsigned storage, unsigned plane, guint8 *bytes) {
  for(unsigned i=0;i<W*H;i++) {
    if(storage==1) {guint8 v=(i*11+plane*71)&255;memcpy(bytes+i,&v,1);}
    if(storage==2) {guint16 v=(i*149+plane*1801)&65535;memcpy(bytes+2*i,&v,2);}
    if(storage==3) {float v=((i*13+plane*117)%1024)/1024.0f;memcpy(bytes+4*i,&v,4);}
  }
}
static GlimsStatus setup(GlimsEngine *e,gpointer data) {
  Scene *s=data;
  GlimsOpenImage *open=glims_lookup_image(e,s->id);
  if(!open || !open->component_document)return GLIMS_STATUS_FAILED;
  GimpImage *image=open->image;
  GlimsPlateStorage storage;
  CHECK(glims_plate_storage_read(image,&storage)==GLIMS_PLATE_STORAGE_VALID,"created native storage validates");
  s->map=storage.map;
  CHECK(gimp_container_get_n_children(gimp_image_get_layers(image))==0,"there is no editable RGB proxy layer");
  const GimpParasite *mapping=gimp_image_parasite_find(image,GLIMS_PLATE_MAP_PARASITE);guint32 mapping_length=0;
  const void *mapping_bytes=gimp_parasite_get_data(mapping,&mapping_length);
  if(!mapping_bytes || mapping_length>sizeof s->mapping)return GLIMS_STATUS_FAILED;
  memcpy(s->mapping,mapping_bytes,mapping_length);s->mapping_length=mapping_length;
  s->bytes=W*H*(s->map.storage==1?1:s->map.storage==2?2:4);
  gboolean paper=TRUE, format=TRUE;
  for(unsigned p=0;p<N;p++) {
    GimpDrawable *drawable=GIMP_DRAWABLE(storage.planes[p]);
    const Babl *actual_format=gimp_drawable_get_format(drawable);
    format &= babl_format_get_bytes_per_pixel(actual_format)==s->bytes/(W*H) && babl_format_get_n_components(actual_format)==1;
    guint8 raw[MAX_BYTES]={0};
    gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,W,H),1,actual_format,raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    for(unsigned i=0;i<W*H;i++) {
      if(s->map.storage==1)paper &= raw[i]==255;
      if(s->map.storage==2){guint16 v;memcpy(&v,raw+2*i,2);paper &= v==65535;}
      if(s->map.storage==3){float v;memcpy(&v,raw+4*i,4);paper &= v==1.0f;}
    }
    sample_pattern(s->map.storage,p,s->before[p]);
    gegl_buffer_set(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,W,H),0,actual_format,s->before[p],GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(drawable,0,0,W,H);
    s->ids[p]=gimp_item_get_id(GIMP_ITEM(drawable));
    /* Reordering and unrelated display names cannot redefine component order. */
    gchar *name=g_strdup_printf("Decoy component %u",N-p);
    CHECK(gimp_item_rename(GIMP_ITEM(drawable),name,NULL),"rename keeps identity independent of display name");g_free(name);
  }
  CHECK(format && paper,"raw scalar formats and full-paper samples are exact at declared precision");
  CHECK(gimp_image_reorder_item(image,GIMP_ITEM(storage.planes[3]),NULL,0,FALSE,NULL),"native channel list order can differ from component order");
  gimp_image_undo_free(image);gimp_image_clean_all(image);
  return GLIMS_STATUS_OK;
}
static double linearize(double x){return x<=0.04045?x/12.92:pow((x+0.055)/1.055,2.4);}
static double raw_value(const Scene*s,unsigned plane,unsigned pixel){
  if(s->map.storage==1)return s->actual[plane][pixel]/255.;
  if(s->map.storage==2){guint16 v;memcpy(&v,s->actual[plane]+2*pixel,2);return v/65535.;}
  float v;memcpy(&v,s->actual[plane]+4*pixel,4);return v;
}
static gboolean graph_check(GlimsEngine *engine,GlimsPlateStorage *storage,Scene*s){
  (void)storage;
  GeglBuffer *buffer=NULL;
  GimpImage *image=gimp_item_get_image(GIMP_ITEM(storage->planes[0]));
  if(glims_plate_preview_prepare(image,&s->preview,&buffer)!=GLIMS_STATUS_OK)return FALSE;
  GeglRectangle extent={0,0,W,H};
  GimpTileHandlerValidate *handler=gimp_tile_handler_validate_get_assigned(buffer);
  gimp_tile_handler_validate_validate(handler,buffer,&extent,TRUE,FALSE);
  float pixels[W*H*4]={0};
  gegl_buffer_get(buffer,&extent,1,babl_format("RGBA float"),pixels,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  double max_error=0;
  for(unsigned i=0;i<W*H;i++){
    for(unsigned c=0;c<3;c++){
      double expected=1;
      for(unsigned p=0;p<N;p++){
        double intensity=raw_value(s,p,i),ink=linearize(s->map.entries[p].ink_rgb[c]);
        expected*=intensity+(1-intensity)*ink;
      }
      double error=fabs(expected-pixels[4*i+c]);if(error>max_error)max_error=error;
    }
    if(pixels[4*i+3]!=1)max_error=1;
  }
  CHECK(max_error<1e-6,"full-resolution component preview matches independent ink multiplication");
  uint8_t output[W*H*4],profile_output[W*H*4];
  gboolean rendered=api->image_render(engine,s->id,1,(GlimsRect){0,0,W,H},output,W*4)==GLIMS_STATUS_OK;
  GimpColorProfile *profile=gimp_color_profile_new_rgb_srgb();gsize icc_length=0;
  const guint8 *icc=gimp_color_profile_get_icc_profile(profile,&icc_length);char *error=NULL;
  gboolean profiled=api->image_render_to_profile(engine,s->id,1,(GlimsRect){0,0,W,H},icc,icc_length,profile_output,W*4,&error)==GLIMS_STATUS_OK;
  gboolean correct=rendered && profiled;
  for(unsigned i=0;i<W*H && correct;i++){
    for(unsigned c=0;c<3;c++){
      double v=pixels[4*i+c];double encoded=v<=0.0031308?12.92*v:1.055*pow(v,1/2.4)-0.055;
      int expected=(int)floor(encoded*255+0.5);
      correct &= abs((int)output[4*i+c]-expected)<=1 && abs((int)profile_output[4*i+c]-expected)<=1;
    }
    correct &= output[4*i+3]==255 && profile_output[4*i+3]==255;
  }
  CHECK(correct,"public preview and ICC display render the authoritative ink planes");
  api->free_string(error);g_object_unref(profile);

  float scaled[(W/2)*(H/2)*4];
  gegl_buffer_get(buffer,GEGL_RECTANGLE(0,0,W/2,H/2),0.5,babl_format("RGBA float"),scaled,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  double scale_error=0;
  for(unsigned y=0;y<H/2;y++)for(unsigned x=0;x<W/2;x++)for(unsigned c=0;c<4;c++){
    double expected=0;for(unsigned dy=0;dy<2;dy++)for(unsigned dx=0;dx<2;dx++)expected+=pixels[((y*2+dy)*W+x*2+dx)*4+c]*.25;
    double error=fabs(expected-scaled[(y*(W/2)+x)*4+c]);if(error>scale_error)scale_error=error;
  }
  CHECK(scale_error<1e-6,"zoomed preview averages the composite instead of composing averaged inks");
  float outside[4]={1,1,1,1};
  gegl_buffer_get(buffer,GEGL_RECTANGLE(-1,-1,1,1),1,babl_format("RGBA float"),outside,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(outside[0]==0&&outside[1]==0&&outside[2]==0&&outside[3]==0,"outside component canvas remains transparent");
  printf("RENDER precision=%u error=%.9g scaled-error=%.9g\n",s->map.storage,max_error,scale_error);

  return max_error<1e-6 && scale_error<1e-6;
}

static GlimsStatus snapshot(GlimsEngine *e,gpointer data) {
  Scene *s=data;GlimsOpenImage *open=glims_lookup_image(e,s->id);
  if(!open)return GLIMS_STATUS_NOT_FOUND;
  GlimsPlateStorage storage;
  if(glims_plate_storage_read(open->image,&storage)!=GLIMS_PLATE_STORAGE_VALID)return GLIMS_STATUS_FAILED;
  if(storage.map.count!=N || storage.map.storage!=s->map.storage)return GLIMS_STATUS_FAILED;
  if(storage.map.width!=W || storage.map.height!=H || storage.map.mode!=1 || storage.map.encoding!=1)return GLIMS_STATUS_FAILED;
  const GimpParasite *mapping=gimp_image_parasite_find(open->image,GLIMS_PLATE_MAP_PARASITE);guint32 mapping_length=0;
  const void *mapping_bytes=gimp_parasite_get_data(mapping,&mapping_length);
  if(!mapping_bytes || mapping_length!=s->mapping_length || memcmp(mapping_bytes,s->mapping,mapping_length))return GLIMS_STATUS_FAILED;
  for(unsigned p=0;p<N;p++) {
    if(memcmp(storage.map.entries[p].uuid,s->map.entries[p].uuid,16))return GLIMS_STATUS_FAILED;
    if(memcmp(storage.map.entries[p].ink_rgb,s->map.entries[p].ink_rgb,sizeof s->map.entries[p].ink_rgb))return GLIMS_STATUS_FAILED;
    /* Independently scan persisted UUIDs rather than trusting resolver indices. */
    GList *channels=gimp_image_get_channel_list(open->image);GimpChannel *found=NULL;unsigned matches=0;
    for(GList *it=channels;it;it=it->next) {
      const GimpParasite *tag=gimp_item_parasite_find(GIMP_ITEM(it->data),GLIMS_PLATE_UUID_PARASITE);guint32 length=0;
      const void *bytes=tag?gimp_parasite_get_data(tag,&length):NULL;
      if(bytes && length==16 && !memcmp(bytes,s->map.entries[p].uuid,16)){found=it->data;matches++;}
    }
    g_list_free(channels);
    if(matches!=1 || found!=storage.planes[p])return GLIMS_STATUS_FAILED;
    GimpDrawable *drawable=GIMP_DRAWABLE(found);
    gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,W,H),1,gimp_drawable_get_format(drawable),s->actual[p],GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    s->ids[p]=gimp_item_get_id(GIMP_ITEM(found));
  }
  return graph_check(e,&storage,s)?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
}
static gboolean same(Scene *s,guint8 expected[N][MAX_BYTES],int except) {
  for(unsigned p=0;p<N;p++)if((int)p!=except && memcmp(s->actual[p],expected[p],s->bytes))return FALSE;
  return TRUE;
}
static void set_tag(GimpImage *image,const guint8 *bytes,guint32 length,guint32 flags) {
  GimpParasite *tag=gimp_parasite_new(GLIMS_PLATE_MAP_PARASITE,flags,length,bytes);
  gimp_image_parasite_attach(image,tag,FALSE);gimp_parasite_free(tag);
}
static GlimsStatus corruption(GlimsEngine *e,gpointer data) {
  Scene *s=data;GimpImage *source=glims_lookup_image(e,s->id)->image;
  for(unsigned kind=0;kind<10;kind++) {
    GimpImage *copy=gimp_image_duplicate(source);GlimsPlateStorage storage;
    CHECK(copy && glims_plate_storage_read(copy,&storage)==GLIMS_PLATE_STORAGE_VALID,"native duplicate preserves all component identities");
    if(!copy)continue;
    GlimsPlatePreview *preview=NULL;GeglBuffer *buffer=NULL;
    CHECK(glims_plate_preview_prepare(copy,&preview,&buffer)==GLIMS_STATUS_OK && preview && buffer,"valid duplicate creates a derived preview");
    GimpItem *first=GIMP_ITEM(storage.planes[0]);
    if(kind==0)gimp_image_parasite_detach(copy,GLIMS_PLATE_MAP_PARASITE,FALSE);
    if(kind==1)gimp_item_parasite_detach(first,GLIMS_PLATE_UUID_PARASITE,FALSE);
    if(kind==2) {
      GimpParasite *tag=gimp_parasite_new(GLIMS_PLATE_UUID_PARASITE,GIMP_PARASITE_PERSISTENT,16,storage.map.entries[1].uuid);
      gimp_item_parasite_attach(first,tag,FALSE);gimp_parasite_free(tag);
    }
    if(kind==3)gimp_image_remove_channel(copy,storage.planes[0],FALSE,NULL);
    if(kind==4) {
      GimpItem *extra=gimp_item_duplicate(first,GIMP_TYPE_CHANNEL);
      CHECK(gimp_image_add_channel(copy,GIMP_CHANNEL(extra),NULL,0,FALSE),"extra copied channel added for malformed fixture");
    }
    if(kind>=5 && kind<=8) {
      guint8 bytes[GLIMS_PLATE_MAP_MAX_SIZE];size_t length=0;
      glims_plate_map_encode(&storage.map,bytes,sizeof bytes,&length);
      if(kind==5)bytes[12]++;
      if(kind==6)bytes[28]=s->map.storage==1?3:1;
      if(kind==7)bytes[0]='X';
      set_tag(copy,bytes,length,kind==8?0:GIMP_PARASITE_PERSISTENT);
    }
    if(kind==9) {
      GimpLayer *layer=gimp_layer_new(copy,W,H,gimp_image_get_layer_format(copy,FALSE),"Unexpected layer",1,GIMP_LAYER_MODE_NORMAL);
      CHECK(gimp_image_add_layer(copy,layer,NULL,0,FALSE),"unexpected layer added for malformed fixture");
    }
    memset(&storage,0xa5,sizeof storage);
    CHECK(glims_plate_storage_read(copy,&storage)==GLIMS_PLATE_STORAGE_INVALID,"damaged or unsupported native component layout refuses");
    guint8 zero[sizeof storage]={0};CHECK(!memcmp(&storage,zero,sizeof storage),"invalid layout cannot leak partially resolved planes");
    buffer=(GeglBuffer*)copy;
    CHECK(glims_plate_preview_prepare(copy,&preview,&buffer)==GLIMS_STATUS_UNSUPPORTED && !preview && !buffer,"malformed layout drops its cached preview and clears output");
    glims_plate_preview_free(preview);
    g_object_unref(copy);
  }
  GimpImage *ordinary=gimp_create_image(e->gimp,W,H,GIMP_RGB,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
  GlimsPlateStorage storage;memset(&storage,0xa5,sizeof storage);
  CHECK(glims_plate_storage_read(ordinary,&storage)==GLIMS_PLATE_STORAGE_NONE,"ordinary images remain explicitly distinct from invalid plate data");
  g_object_unref(ordinary);
  return GLIMS_STATUS_OK;
}
static GlimsStatus release_preview(GlimsEngine *engine,gpointer data){
  (void)engine;Scene*s=data;glims_plate_preview_free(s->preview);s->preview=NULL;return GLIMS_STATUS_OK;
}

static void numeric_paint(GlimsEngine *engine) {
  const double intensities[]={0,.25,.5,1}, opacities[]={.25,.5,1};
  const uint32_t tools[]={GLIMS_PAINT_PAINTBRUSH,GLIMS_PAINT_PENCIL,GLIMS_PAINT_AIRBRUSH};
  for(unsigned precision=1;precision<=3;precision++)
    for(unsigned tool=0;tool<3;tool++)
      for(unsigned t=0;t<4;t++)for(unsigned o=0;o<3;o++) {
        Scene s={0};char *error=NULL;
        uint32_t component=precision==1?GLIMS_COLOR_COMPONENT_U8:precision==2?GLIMS_COLOR_COMPONENT_U16:GLIMS_COLOR_COMPONENT_FLOAT;
        CHECK(api->image_new_multichannel(engine,W,H,component,N,&s.id,&error)==GLIMS_STATUS_OK && s.id,"numeric paint creates actual public component image");
        if(!s.id){api->free_string(error);continue;}
        CHECK(glims_engine_call(engine,setup,&s)==GLIMS_STATUS_OK,"numeric oracle seeds authoritative scalar planes");
        memcpy(s.actual,s.before,sizeof s.actual);
        const unsigned center=8*W+12;
        double before=raw_value(&s,2,center);
        GlimsBrushSettings brush={.struct_size=sizeof brush,.tool=tools[tool],.size=11,.opacity=opacities[o],.red=intensities[t],.green=intensities[t],.blue=intensities[t],.hardness=1,.rate=0,.flow=100,.exposure=-1};
        GlimsStrokePoint point={12.5,8.5,1,0,0,100};GlimsStrokeID stroke=0;
        CHECK(api->stroke_begin(engine,s.id,s.ids[2],&brush,&point,&stroke,&error)==GLIMS_STATUS_OK && stroke,"numeric production core begins one full-pressure dab");
        if(stroke)CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"numeric production core ends its dab");
        CHECK(glims_engine_call(engine,snapshot,&s)==GLIMS_STATUS_OK,"numeric oracle reads real plane samples and derived preview");
        const double actual=raw_value(&s,2,center), expected=(1-opacities[o])*before+opacities[o]*intensities[t];
        printf("NUMERIC precision=%u tool=%u intensity=%g opacity=%g before=%.9g actual=%.9g expected=%.9g\n",precision,tools[tool],intensities[t],opacities[o],before,actual,expected);
        CHECK(fabs(actual-expected)<=(precision==1?1./255:precision==2?1./65535:1e-6),"paint opacity blends authoritative numeric intensity linearly");
        CHECK(same(&s,s.before,2),"numeric paint leaves every unselected plane byte-identical");
        memcpy(s.after,s.actual,sizeof s.after);
        CHECK(api->image_undo(engine,s.id)==GLIMS_STATUS_OK && glims_engine_call(engine,snapshot,&s)==GLIMS_STATUS_OK && same(&s,s.before,-1),"numeric stroke Undo restores every exact scalar sample");
        CHECK(api->image_redo(engine,s.id)==GLIMS_STATUS_OK && glims_engine_call(engine,snapshot,&s)==GLIMS_STATUS_OK && same(&s,s.after,-1),"numeric stroke Redo restores every exact scalar sample");
        CHECK(glims_engine_call(engine,release_preview,&s)==GLIMS_STATUS_OK,"numeric derived preview releases");
        CHECK(api->image_close(engine,s.id)==GLIMS_STATUS_OK,"numeric document closes");
        api->free_string(error);
      }
}

static void channel_attributes(GlimsEngine *engine, const char *work) {
  GlimsImageID id=0;char *error=NULL;GlimsChannelInfo row={0};int32_t count=0;
  CHECK(api->image_new_multichannel(engine,32,32,GLIMS_COLOR_COMPONENT_U8,1,&id,&error)==GLIMS_STATUS_OK,"ink attributes fixture creates");
  if(!id)return;
  CHECK(api->image_channels(engine,id,&row,1,&count)==GLIMS_STATUS_OK && count==1,"ink attributes obtains the real plane");
  GlimsBrushSettings brush={.struct_size=sizeof brush,.tool=GLIMS_PAINT_PENCIL,.size=9,.opacity=1,.hardness=-1,.rate=-1,.flow=-1,.exposure=-1};
  GlimsStrokePoint point={16,16,1,0,0,100};GlimsStrokeID stroke=0;
  CHECK(api->stroke_begin(engine,id,row.id,&brush,&point,&stroke,&error)==GLIMS_STATUS_OK && stroke,"ink attribute fixture paints full coverage");
  if(stroke)CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"ink attribute fixture finishes painting");
  uint8_t pixel[4]={0};GlimsRect rect={16,16,1,1};
  CHECK(api->image_render(engine,id,1,rect,pixel,4)==GLIMS_STATUS_OK && pixel[0]==0 && pixel[1]==0 && pixel[2]==0 && pixel[3]==255,"default black ink renders black");
  GlimsUndoInfo before={0},after={0};api->image_undo_info(engine,id,&before);
  GlimsChannelChange change={.struct_size=sizeof change,.properties=GLIMS_CHANNEL_NAME|GLIMS_CHANNEL_COLOR|GLIMS_CHANNEL_VISIBLE,.name="Spot red",.color={1,0,0,1},.visible=0};
  CHECK(api->channel_change(engine,id,row.id,&change,&error)==GLIMS_STATUS_OK,"one ink edit accepts name, color and visibility");
  api->free_string(error);error=NULL;
  CHECK(api->image_channels(engine,id,&row,1,&count)==GLIMS_STATUS_OK && !strcmp(row.name,"Spot red") && !row.visible && row.color.red==1 && row.color.green==0 && row.color.blue==0,"ink attributes read their persistent metadata");
  CHECK(api->image_render(engine,id,1,rect,pixel,4)==GLIMS_STATUS_OK && pixel[0]==255 && pixel[1]==255 && pixel[2]==255,"hiding ink reveals paper without changing samples");
  api->image_undo_info(engine,id,&after);
  CHECK(after.undo_count==before.undo_count+1,"combined ink attributes are one Undo step");
  CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK && api->image_channels(engine,id,&row,1,&count)==GLIMS_STATUS_OK && row.visible && !strcmp(row.name,"Black") && row.color.red==0,"Undo restores name, color and visibility together");
  CHECK(api->image_render(engine,id,1,rect,pixel,4)==GLIMS_STATUS_OK && pixel[0]==0 && pixel[1]==0 && pixel[2]==0,"Undo invalidates derived ink color");
  CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK,"Redo reapplies ink attributes");
  change=(GlimsChannelChange){.struct_size=sizeof change,.properties=GLIMS_CHANNEL_VISIBLE,.visible=1};
  CHECK(api->channel_change(engine,id,row.id,&change,&error)==GLIMS_STATUS_OK,"ink visibility can be restored independently");
  CHECK(api->image_render(engine,id,1,rect,pixel,4)==GLIMS_STATUS_OK && pixel[0]==255 && pixel[1]==0 && pixel[2]==0,"edited ink color tints the authoritative coverage");
  api->image_undo_info(engine,id,&before);
  change=(GlimsChannelChange){.struct_size=sizeof change,.properties=GLIMS_CHANNEL_NAME|GLIMS_CHANNEL_COLOR,.name="Must not rename",.color={NAN,0,0,1}};
  CHECK(api->channel_change(engine,id,row.id,&change,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"nonfinite ink color refuses before any rename");
  api->free_string(error);error=NULL;
  api->image_undo_info(engine,id,&after);
  CHECK(api->image_channels(engine,id,&row,1,&count)==GLIMS_STATUS_OK && !strcmp(row.name,"Spot red") && before.undo_count==after.undo_count,"refused ink attributes leave state and Undo unchanged");
  gchar *path=g_build_filename(work,"ink-attributes.xcf",NULL);
  CHECK(api->image_save(engine,id,path,&error)==GLIMS_STATUS_OK,"ink attributes save to XCF");
  CHECK(api->image_close(engine,id)==GLIMS_STATUS_OK,"ink fixture closes");id=0;
  CHECK(api->image_open(engine,path,&id,&error)==GLIMS_STATUS_OK && id,"ink attribute XCF reopens");
  if(id){
    CHECK(api->image_channels(engine,id,&row,1,&count)==GLIMS_STATUS_OK && !strcmp(row.name,"Spot red") && row.visible && row.color.red==1,"XCF retains ink attributes");
    CHECK(api->image_render(engine,id,1,rect,pixel,4)==GLIMS_STATUS_OK && pixel[0]==255 && pixel[1]==0 && pixel[2]==0,"XCF retains exact ink coverage and display color");
    api->image_close(engine,id);
  }
  api->free_string(error);g_free(path);
}
int main(int argc,char **argv) {
  if(argc!=2)return 2;
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;
  if(api->start(&config,&engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"%s\n",error?error:"startup failed");return 2;}
  for(unsigned precision=1;precision<=3;precision++) {
    Scene scene={.map={.width=W,.height=H,.count=N,.mode=1,.encoding=1,.storage=precision}};
    for(unsigned p=0;p<N;p++){
      for(unsigned i=0;i<16;i++)scene.map.entries[p].uuid[i]=(guint8)(p*16+i+1);
      scene.map.entries[p].ink_rgb[p%3]=0.75;
    }
    uint32_t component=precision==1?GLIMS_COLOR_COMPONENT_U8:precision==2?GLIMS_COLOR_COMPONENT_U16:GLIMS_COLOR_COMPONENT_FLOAT;
    CHECK(api->image_new_multichannel(engine,W,H,component,N,&scene.id,&error)==GLIMS_STATUS_OK && scene.id,"public factory creates a component document");
    CHECK(glims_engine_call(engine,setup,&scene)==GLIMS_STATUS_OK,"native scalar oracle seeds the public document");
    GlimsColorInfo color_info={0};GlimsImageInfo image_info={0};int32_t layers=-1;
    CHECK(api->image_color_info(engine,scene.id,&color_info)==GLIMS_STATUS_OK && color_info.mode==GLIMS_COLOR_MODE_MULTICHANNEL && color_info.component==component,"public color info reports actual Multichannel precision");
    CHECK(api->image_info(engine,scene.id,&image_info)==GLIMS_STATUS_OK && image_info.width==W && image_info.height==H,"public image info reports dimensions");
    CHECK(api->image_layers(engine,scene.id,NULL,0,&layers)==GLIMS_STATUS_OK && layers==0,"public layer list contains no RGB proxy");
    GlimsComponentState components={0};
    CHECK(api->image_components(engine,scene.id,&components)==GLIMS_STATUS_OK && components.mode==GLIMS_COMPONENT_MODE_MULTICHANNEL && components.supported==0,"component model identifies ink channels without inventing RGB components");
    if(!scene.id)continue;
    CHECK(glims_engine_call(engine,snapshot,&scene)==GLIMS_STATUS_OK && same(&scene,scene.before,-1),"raw seeded values and UUID order are exact independently of names and list order");
    GlimsBrushSettings brush={.struct_size=sizeof brush,.tool=GLIMS_PAINT_PENCIL,.size=7,.opacity=1,.red=0.5,.green=0.5,.blue=0.5,.hardness=-1,.rate=-1,.flow=-1,.exposure=-1};
    GlimsStrokePoint points[2]={{6,6,1,0,0,100},{18,10,1,0,0,120}};GlimsStrokeID stroke=0;GlimsUndoInfo before={0},after={0};
    CHECK(api->image_undo_info(engine,scene.id,&before)==GLIMS_STATUS_OK,"initial Undo information is available");
    CHECK(api->stroke_begin(engine,scene.id,scene.ids[2],&brush,points,&stroke,&error)==GLIMS_STATUS_OK && stroke,"real facade Pencil begins on one scalar plane");
    if(stroke){CHECK(api->stroke_continue(engine,stroke,points+1,1)==GLIMS_STATUS_OK && api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"native paint stroke ends");}
    CHECK(glims_engine_call(engine,snapshot,&scene)==GLIMS_STATUS_OK && same(&scene,scene.before,2) && memcmp(scene.actual[2],scene.before[2],scene.bytes),"only the intended plane changes");
    memcpy(scene.after,scene.actual,sizeof scene.after);
    CHECK(api->image_undo_info(engine,scene.id,&after)==GLIMS_STATUS_OK,"painted Undo information is available");
    CHECK(after.undo_count==before.undo_count+1,"component stroke contributes exactly one Undo step");
    CHECK(api->image_undo(engine,scene.id)==GLIMS_STATUS_OK && glims_engine_call(engine,snapshot,&scene)==GLIMS_STATUS_OK && same(&scene,scene.before,-1),"Undo restores exact component samples");
    CHECK(api->image_redo(engine,scene.id)==GLIMS_STATUS_OK && glims_engine_call(engine,snapshot,&scene)==GLIMS_STATUS_OK && same(&scene,scene.after,-1),"Redo restores exact edited component samples");
    CHECK(glims_engine_call(engine,corruption,&scene)==GLIMS_STATUS_OK,"all native layout validation cases completed");
    gchar *name=g_strdup_printf("plates-%u.xcf",precision),*path=g_build_filename(argv[1],name,NULL);g_free(name);
    CHECK(api->image_save(engine,scene.id,path,&error)==GLIMS_STATUS_OK,"layerless authoritative planes save to XCF");
    CHECK(api->image_close(engine,scene.id)==GLIMS_STATUS_OK,"saved component image closes");scene.id=0;
    CHECK(api->image_open(engine,path,&scene.id,&error)==GLIMS_STATUS_OK && scene.id,"component XCF reopens");
    if(scene.id){CHECK(glims_engine_call(engine,snapshot,&scene)==GLIMS_STATUS_OK && same(&scene,scene.after,-1),"XCF preserves all exact samples, UUID identities and ink metadata");api->image_close(engine,scene.id);}
    CHECK(glims_engine_call(engine,release_preview,&scene)==GLIMS_STATUS_OK,"derived preview releases on engine thread");
    if(error){fprintf(stderr,"OBS %s\n",error);api->free_string(error);error=NULL;}g_free(path);
  }
  channel_attributes(engine,argv[1]);
  numeric_paint(engine);
  api->stop(engine);g_free(user);g_free(cache);printf("%u component-editor checks, %u failures\n",checks,failures);return failures?1:0;
}

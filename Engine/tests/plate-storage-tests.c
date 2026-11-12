/* Private component storage integration. Raw sample oracle and deliberate
 * native corruption are independent of the metadata resolver. No UI mode. */
#include "plate-storage.h"
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
  Scene *s=data;char *error=NULL;
  GimpImage *image=glims_plate_storage_create(e,&s->map,&error);
  CHECK(image && !error,"create layerless all-paper image with native scalar planes");
  free(error);if(!image)return GLIMS_STATUS_FAILED;
  GlimsPlateStorage storage;
  CHECK(glims_plate_storage_read(image,&storage)==GLIMS_PLATE_STORAGE_VALID,"created native storage validates");
  CHECK(gimp_container_get_n_children(gimp_image_get_layers(image))==0,"there is no editable RGB proxy layer");
  const GimpParasite *mapping=gimp_image_parasite_find(image,GLIMS_PLATE_MAP_PARASITE);guint32 mapping_length=0;
  const void *mapping_bytes=gimp_parasite_get_data(mapping,&mapping_length);
  if(!mapping_bytes || mapping_length>sizeof s->mapping){g_object_unref(image);return GLIMS_STATUS_FAILED;}
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
  return glims_adopt_image(e,image,&s->id);
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
  return GLIMS_STATUS_OK;
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
    g_object_unref(copy);
  }
  GimpImage *ordinary=gimp_create_image(e->gimp,W,H,GIMP_RGB,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
  GlimsPlateStorage storage;memset(&storage,0xa5,sizeof storage);
  CHECK(glims_plate_storage_read(ordinary,&storage)==GLIMS_PLATE_STORAGE_NONE,"ordinary images remain explicitly distinct from invalid plate data");
  g_object_unref(ordinary);
  return GLIMS_STATUS_OK;
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
    CHECK(glims_engine_call(engine,setup,&scene)==GLIMS_STATUS_OK,"component fixture admitted privately for storage tests");
    if(!scene.id)continue;
    CHECK(glims_engine_call(engine,snapshot,&scene)==GLIMS_STATUS_OK && same(&scene,scene.before,-1),"raw seeded values and UUID order are exact independently of names and list order");
    GlimsBrushSettings brush={.struct_size=sizeof brush,.tool=GLIMS_PAINT_PENCIL,.size=7,.opacity=1,.red=1,.green=1,.blue=1,.hardness=-1,.rate=-1,.flow=-1,.exposure=-1};
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
    if(error){fprintf(stderr,"OBS %s\n",error);api->free_string(error);error=NULL;}g_free(path);
  }
  api->stop(engine);g_free(user);g_free(cache);printf("%u plate-storage checks, %u failures\n",checks,failures);return failures?1:0;
}

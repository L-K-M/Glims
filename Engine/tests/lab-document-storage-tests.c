/* Private Lab creation/storage qualification. Independent literal raw-white
 * samples, mode binding, and metadata corruption. No public Lab adoption. */
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WIDTH 259
#define HEIGHT 3
#define PIXELS (WIDTH * HEIGHT)
static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c,s) do { gboolean ok=!!(c); checks++; printf("%s %s\n",ok?"ok":"FAIL",s); if(!ok)failures++; fflush(stdout); } while(0)

static gboolean cleared(const GlimsPlateStorage *storage)
{
  const guint8 *bytes=(const guint8 *)storage;
  for(size_t i=0;i<sizeof *storage;i++)if(bytes[i])return FALSE;
  return TRUE;
}

static void visible_tag(GimpItem *item, guint8 value)
{
  GimpParasite *tag=gimp_parasite_new(GLIMS_PLATE_VISIBLE_PARASITE,
    GIMP_PARASITE_PERSISTENT,1,&value);
  gimp_item_parasite_attach(item,tag,FALSE);
  gimp_parasite_free(tag);
}

static void check_white(const GlimsPlateStorage *storage, gboolean lab)
{
  for(unsigned role=0;role<storage->map.count;role++) {
    GimpDrawable *plane=GIMP_DRAWABLE(storage->planes[role]);
    const Babl *format=gimp_drawable_get_format(plane);
    guint8 bytes[PIXELS*4]={0};
    const unsigned width=storage->map.storage==1?1:storage->map.storage==2?2:4;
    CHECK(babl_format_get_n_components(format)==1 &&
          babl_format_get_bytes_per_pixel(format)==(gint)width,"native scalar format matches storage");
    if(babl_format_get_bytes_per_pixel(format)!=(gint)width)continue;
    gegl_buffer_get(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,WIDTH,HEIGHT),1,
                    format,bytes,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    gboolean exact=TRUE;
    for(unsigned i=0;i<PIXELS;i++) {
      if(width==1)exact &= bytes[i]==(lab && role!=0?128:255);
      else if(width==2) {
        guint16 actual;memcpy(&actual,bytes+2*i,2);
        exact &= actual==(lab && role!=0?32896:65535);
      } else {
        /* Literal IEEE754 bits: +100, +0, and legacy paper +1. */
        guint32 actual;memcpy(&actual,bytes+4*i,4);
        guint32 expected=lab?(role==0?0x42c80000u:0u):0x3f800000u;
        exact &= actual==expected;
      }
    }
    CHECK(exact,"every raw sample matches independent white/paper bits across tile edge");
  }
}

static GlimsStatus exercise(GlimsEngine *engine,gpointer unused)
{
  (void)unused;
  for(unsigned mode=1;mode<=3;mode+=2)for(unsigned precision=1;precision<=3;precision++) {
    const gboolean lab=mode==3;
    GlimsPlateMap map={.width=WIDTH,.height=HEIGHT,.count=3,.mode=mode,
                       .storage=precision,.encoding=lab?2:1};
    for(unsigned role=0;role<3;role++)map.entries[role].uuid[15]=(guint8)(role+1);
    char *error=NULL;
    GimpImage *image=glims_plate_storage_create(engine,&map,&error);
    CHECK(image && !error,"create private native storage");free(error);
    if(!image)continue;
    GlimsPlateStorage storage;
    gboolean valid=glims_plate_storage_read(image,&storage)==GLIMS_PLATE_STORAGE_VALID;
    CHECK(valid,"created storage validates");
    if(!valid){g_object_unref(image);continue;}
    CHECK(storage.map.mode==mode && storage.map.encoding==(lab?2u:1u),"mode and encoding retained");
    CHECK(!storage.profile && !storage.profile_size,"no component profile for Lab/Multichannel");
    CHECK(gimp_container_get_n_children(gimp_image_get_layers(image))==0,"no editable RGB layer");
    CHECK(!gimp_image_is_dirty(image),"created image is clean");
    CHECK(gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==0,"creation leaves Undo empty");
    GList *selected=gimp_image_get_selected_channels(image);
    CHECK(g_list_length(selected)==1 && selected->data==storage.planes[0],"first canonical plane is selected");
    static const char *lab_names[]={"Lightness","a","b"};
    GimpChannel *original[3];
    for(unsigned role=0;role<3;role++) {
      original[role]=storage.planes[role];
      const GimpParasite *tag=gimp_item_parasite_find(GIMP_ITEM(original[role]),GLIMS_PLATE_UUID_PARASITE);
      guint32 size=0;const void *uuid=tag?gimp_parasite_get_data(tag,&size):NULL;
      CHECK(uuid && size==16 && !memcmp(uuid,map.entries[role].uuid,16),"raw persistent UUID matches canonical role");
      CHECK(storage.visible[role] && !gimp_item_get_visible(GIMP_ITEM(original[role])),"component visible while native overlay hidden");
      char expected[32];snprintf(expected,sizeof expected,"Channel %u",role+1);
      CHECK(!strcmp(gimp_object_get_name(GIMP_OBJECT(original[role])),lab?lab_names[role]:expected),"created names match mode contract");
    }
    check_white(&storage,lab);
    GlimsOpenImage open={.image=image,.component_document=TRUE,.component_mode=mode};
    CHECK(glims_plate_storage_read_open(&open,&storage),"matching adopted-mode binding accepts storage");
    for(unsigned mismatch=0;mismatch<=4;mismatch++)if(mismatch!=mode) {
      open.component_mode=mismatch;memset(&storage,0xa5,sizeof storage);
      CHECK(!glims_plate_storage_read_open(&open,&storage) && cleared(&storage),"all mismatching cached modes refuse and clear output");
    }
    open.component_mode=mode;
    guint8 byte=1;open.component_cmyk_profile=g_bytes_new(&byte,1);
    CHECK(!glims_plate_storage_read_open(&open,&storage) && cleared(&storage),"non-CMYK storage refuses cached CMYK profile");
    g_bytes_unref(open.component_cmyk_profile);open.component_cmyk_profile=NULL;
    CHECK(glims_plate_storage_read_open(&open,&storage),"restored binding remains valid");
    CHECK(gimp_image_reorder_item(image,GIMP_ITEM(original[2]),NULL,0,FALSE,NULL),"native container reorder succeeds");
    CHECK(gimp_item_rename(GIMP_ITEM(original[0]),"Display name is not a role",NULL),"display name can differ from canonical role");
    CHECK(glims_plate_storage_read(image,&storage)==GLIMS_PLATE_STORAGE_VALID &&
          storage.planes[0]==original[0] && storage.planes[1]==original[1] && storage.planes[2]==original[2],
          "UUID mapping survives native order and display name changes");
    for(unsigned role=0;role<3;role++) {
      visible_tag(GIMP_ITEM(original[role]),0);
      GlimsPlateStorageState state=glims_plate_storage_read(image,&storage);
      CHECK(lab?(state==GLIMS_PLATE_STORAGE_INVALID && cleared(&storage)):
                (state==GLIMS_PLATE_STORAGE_VALID && !storage.visible[role]),
            "hidden metadata refuses Lab while preserving Multichannel visibility semantics");
      visible_tag(GIMP_ITEM(original[role]),1);
      CHECK(glims_plate_storage_read(image,&storage)==GLIMS_PLATE_STORAGE_VALID && storage.visible[role],
            "explicit visible metadata accepts");
      gimp_item_parasite_detach(GIMP_ITEM(original[role]),GLIMS_PLATE_VISIBLE_PARASITE,FALSE);
    }
    GimpParasite *profile=gimp_parasite_new(GLIMS_PLATE_PROFILE_PARASITE,GIMP_PARASITE_PERSISTENT,1,&byte);
    gimp_image_parasite_attach(image,profile,FALSE);gimp_parasite_free(profile);
    CHECK(glims_plate_storage_read(image,&storage)==GLIMS_PLATE_STORAGE_INVALID && cleared(&storage),
          "any component profile parasite refuses for Lab/Multichannel");
    gimp_image_parasite_detach(image,GLIMS_PLATE_PROFILE_PARASITE,FALSE);
    CHECK(glims_plate_storage_read(image,&storage)==GLIMS_PLATE_STORAGE_VALID,"profile removal restores validity");
    check_white(&storage,lab);
    g_object_unref(image);
    error=NULL;
    image=glims_plate_storage_create_profiled(engine,&map,&byte,1,&error);
    CHECK(!image && error,"supplied profile refuses before creating Lab/Multichannel");
    free(error);if(image)g_object_unref(image);
    CHECK(g_hash_table_size(engine->images)==0,"private fixture never adopts a public document");
  }
  return failures?GLIMS_STATUS_FAILED:GLIMS_STATUS_OK;
}

int main(int argc,char **argv)
{
  if(argc!=2){fprintf(stderr,"usage: %s PRIVATE_WORK\n",argv[0]);return 2;}
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
  GlimsEngine *engine=NULL;char *error=NULL;
  GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);
  if(status!=GLIMS_STATUS_OK || !engine){fprintf(stderr,"start failed: %s\n",error?error:"unknown");api->free_string(error);return 2;}
  api->free_string(error);
  status=glims_engine_call(engine,exercise,NULL);
  if(status!=GLIMS_STATUS_OK && !failures)failures++;
  api->stop(engine);
  printf("%u Lab document storage checks, %u failures\n",checks,failures);
  return failures?1:0;
}

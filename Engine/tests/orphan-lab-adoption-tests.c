/* Public adoption must quarantine stripped layered Lab identities. */
#include "engine-private.h"
#include "lab-layer-storage.h"
#include "plate-storage.h"
#include <stdio.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "file/file-save.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"

static unsigned checks, failures;
static const GlimsEngineAPI *api;
#define CHECK(c, name) do { gboolean ok_ = !!(c); checks++; if (!ok_) failures++; \
  printf("%s %s\n", ok_ ? "ok" : "FAIL", name); fflush(stdout); } while (0)

static gboolean
save_xcf (Gimp *gimp, GimpImage *image, const char *path)
{
  GError *error=NULL; GFile *file=g_file_new_for_path(path);
  GimpPlugInProcedure *proc=gimp_plug_in_manager_file_procedure_find(
    gimp->plug_in_manager,GIMP_FILE_PROCEDURE_GROUP_SAVE,file,&error);
  GimpPDBStatusType status=proc ? file_save(gimp,image,NULL,file,proc,
    GIMP_RUN_NONINTERACTIVE,TRUE,FALSE,FALSE,&error) : GIMP_PDB_EXECUTION_ERROR;
  if(error){fprintf(stderr,"fixture save: %s\n",error->message);g_clear_error(&error);}
  g_object_unref(file);return status==GIMP_PDB_SUCCESS;
}

static GlimsStatus
worker (GlimsEngine *engine, gpointer work)
{
  GlimsImageID id = 0;
  GimpImage *ordinary = gimp_create_image (engine->gimp, 4, 4, GIMP_GRAY,
                                            GIMP_PRECISION_U8_LINEAR, FALSE);
  CHECK (ordinary != NULL, "ordinary gray source creates");
  if (ordinary)
    {
      GlimsStatus status = glims_adopt_image (engine, ordinary, &id);
      CHECK (status == GLIMS_STATUS_OK && id != 0, "ordinary gray still adopts");
      if (status == GLIMS_STATUS_OK) CHECK (glims_image_close (engine, id) == GLIMS_STATUS_OK, "ordinary gray closes");
      else g_object_unref (ordinary);
    }

  GlimsPlateMap flat = {.width=4,.height=4,.count=3,.mode=GLIMS_PLATE_MODE_LAB,
                        .storage=GLIMS_PLATE_STORAGE_U8,.encoding=GLIMS_PLATE_ENCODING_LAB_D50};
  for (guint i=0;i<3;i++) flat.entries[i].uuid[15] = i+1;
  char *error = NULL;
  GimpImage *flat_image = glims_plate_storage_create (engine, &flat, &error);
  CHECK (flat_image != NULL && !error, "existing flat Lab carrier creates");
  if (error) api->free_string (error);
  if (flat_image)
    {
      id=0; GlimsStatus status=glims_adopt_image (engine, flat_image, &id);
      CHECK (status == GLIMS_STATUS_OK && id != 0, "existing flat Lab still adopts");
      if (status == GLIMS_STATUS_OK) CHECK (glims_image_close (engine,id) == GLIMS_STATUS_OK, "flat Lab closes");
      else g_object_unref (flat_image);
    }

  GlimsLabLayerMap map = {.width=4,.height=4,.count=1,.mode=GLIMS_LAB_LAYER_MAP_MODE_LAB,
    .storage=GLIMS_LAB_LAYER_MAP_STORAGE_U8,.encoding=GLIMS_LAB_LAYER_MAP_ENCODING_LAB_D50};
  map.entries[0].group[15]=1;map.entries[0].l[15]=2;map.entries[0].a[15]=3;
  map.entries[0].b[15]=4;map.entries[0].alpha[15]=5;
  error=NULL;GimpImage *layered=glims_lab_layer_storage_create (engine,&map,&error);
  CHECK (layered != NULL && !error, "layered Lab carrier creates");
  if (error) api->free_string (error);
  if (!layered) return GLIMS_STATUS_OK;
  GlimsLabLayerStorage storage;
  CHECK (glims_lab_layer_storage_read (layered,&storage)==GLIMS_LAB_LAYER_STORAGE_VALID,
         "layered carrier starts valid");
  guint before=g_hash_table_size(engine->images);id=-1;
  GlimsStatus status=glims_adopt_image(engine,layered,&id);
  CHECK(status==GLIMS_STATUS_UNSUPPORTED && id==0 && g_hash_table_size(engine->images)==before,
        "layered carrier remains refused until supported");
  if (status==GLIMS_STATUS_OK) { glims_image_close(engine,id); return GLIMS_STATUS_OK; }
  gimp_image_parasite_detach(layered,GLIMS_PLATE_MAP_PARASITE,FALSE);
  CHECK(glims_lab_layer_storage_read(layered,&storage)==GLIMS_LAB_LAYER_STORAGE_INVALID,
        "stripped map leaves recognizable orphan identities");
  gchar *path=g_build_filename((const gchar *)work,"stripped-lab.xcf",NULL);
  gboolean saved=save_xcf(engine->gimp,layered,path);
  CHECK(saved,"stripped carrier is saved to a private XCF fixture");
  gchar *before_bytes=NULL,*after_bytes=NULL;gsize before_size=0,after_size=0;
  CHECK(saved && g_file_get_contents(path,&before_bytes,&before_size,NULL),"private XCF baseline is readable");
  id=-1;status=glims_adopt_image(engine,layered,&id);
  CHECK(status==GLIMS_STATUS_UNSUPPORTED && id==0 && g_hash_table_size(engine->images)==before,
        "stripped layered carrier is not adopted as ordinary gray");
  if(status==GLIMS_STATUS_OK) glims_image_close(engine,id); else g_object_unref(layered);
  if(saved){
    error=NULL;id=-1;status=glims_image_open(engine,path,&id,&error);
    CHECK(status==GLIMS_STATUS_UNSUPPORTED && id==0 && error!=NULL &&
          g_hash_table_size(engine->images)==before,
          "opening stripped XCF refuses without publishing an image");
    if(status==GLIMS_STATUS_OK)glims_image_close(engine,id);
    if(error)api->free_string(error);
    CHECK(g_file_get_contents(path,&after_bytes,&after_size,NULL) && before_bytes &&
          before_size==after_size && !memcmp(before_bytes,after_bytes,before_size),
          "refused open leaves the source XCF byte-identical");
  }
  g_free(before_bytes);g_free(after_bytes);g_free(path);

  /* Even one remaining identity on any root or plane is enough to keep
   * a map-stripped carrier out of ordinary image editing. */
  for(guint keep=0;keep<5;keep++){
    error=NULL;GimpImage *single=glims_lab_layer_storage_create(engine,&map,&error);
    CHECK(single!=NULL && !error,"single-orphan carrier creates");
    if(error)api->free_string(error);
    if(!single)continue;
    GlimsLabLayerStorage intact;
    gboolean valid=glims_lab_layer_storage_read(single,&intact)==GLIMS_LAB_LAYER_STORAGE_VALID;
    CHECK(valid,"single-orphan carrier starts valid");
    if(!valid){g_object_unref(single);continue;}
    GimpItem *items[5]={GIMP_ITEM(intact.layers[0].group),GIMP_ITEM(intact.layers[0].planes[0]),
      GIMP_ITEM(intact.layers[0].planes[1]),GIMP_ITEM(intact.layers[0].planes[2]),
      GIMP_ITEM(intact.layers[0].planes[3])};
    gimp_image_parasite_detach(single,GLIMS_PLATE_MAP_PARASITE,FALSE);
    for(guint i=0;i<5;i++)if(i!=keep)gimp_item_parasite_detach(items[i],GLIMS_PLATE_UUID_PARASITE,FALSE);
    CHECK(glims_lab_layer_storage_read(single,&storage)==GLIMS_LAB_LAYER_STORAGE_INVALID,
          "single identity remains recognizable after stripping");
    id=-1;status=glims_adopt_image(engine,single,&id);
    CHECK(status==GLIMS_STATUS_UNSUPPORTED && id==0 && g_hash_table_size(engine->images)==before,
          "single orphan identity refuses ordinary adoption");
    if(status==GLIMS_STATUS_OK)glims_image_close(engine,id);else g_object_unref(single);
  }
  return GLIMS_STATUS_OK;
}
int main(int argc,char **argv)
{
  if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
  GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&config,&engine,&error);
  g_free(user);g_free(cache);if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}
  api->free_string(error);status=glims_engine_call(engine,worker,argv[1]);api->stop(engine);
  printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;
}

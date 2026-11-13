#include "lab-layer-fill.h"
#include "lab-layer-storage.h"
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
#include "core/gimpprogress.h"
#include "core/gimpundostack.h"
#include "file/file-save.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"

static const GlimsEngineAPI *api;
static unsigned checks, failures;
static unsigned projection_events;
static GlimsRect last_damage;
static GlimsEngine *running_engine;
static gboolean request_cancel, cancel_scheduled, cancel_fired;
static gboolean request_retarget, retarget_scheduled, retarget_fired;
static GimpImage *retarget_image;
static GimpLayer *retarget_layer;
#define CHECK(c,n) do { gboolean ok=!!(c); checks++; if(!ok) failures++; printf("%s %s\n",ok?"ok":"FAIL",n); fflush(stdout); } while(0)

static gboolean cancel_on_engine(gpointer unused)
{
  (void)unused;
  if(running_engine && running_engine->progress)
    cancel_fired=api->procedure_cancel(running_engine)==GLIMS_STATUS_OK;
  return G_SOURCE_REMOVE;
}

static gboolean retarget_on_engine(gpointer unused)
{
  (void)unused;
  GList *selection=g_list_prepend(NULL,retarget_layer);
  gimp_image_set_selected_layers(retarget_image,selection);
  g_list_free(selection);
  retarget_fired=TRUE;
  return G_SOURCE_REMOVE;
}

static void on_event(void *context,const GlimsEvent *event)
{
  (void)context;
  if(event->kind==GLIMS_EVENT_PROJECTION_CHANGED){projection_events++;last_damage=event->rect;}
  if(event->kind==GLIMS_EVENT_PROGRESS && event->active && event->value>=1 && request_cancel && !cancel_scheduled){
    cancel_scheduled=TRUE;g_idle_add(cancel_on_engine,NULL);
  }
  if(event->kind==GLIMS_EVENT_PROGRESS && event->active && event->value>=1 && request_retarget && !retarget_scheduled){
    retarget_scheduled=TRUE;g_idle_add(retarget_on_engine,NULL);
  }
}

static gboolean read_planes(GimpImage *image, guint root, guint8 bytes[4][6])
{
  GlimsLabLayerStorage storage;
  if (glims_lab_layer_storage_read(image,&storage)!=GLIMS_LAB_LAYER_STORAGE_VALID || root>=storage.map.count) return FALSE;
  for (guint i=0;i<4;i++) {
    GimpDrawable *plane=GIMP_DRAWABLE(storage.layers[root].planes[i]);
    const Babl *format=gimp_drawable_get_format(plane);
    if (babl_format_get_bytes_per_pixel(format)!=1) return FALSE;
    gegl_buffer_get(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,3,2),1,format,bytes[i],GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  }
  return TRUE;
}

static GlimsStatus worker(GlimsEngine *engine, gpointer context)
{
  GlimsLabLayerMap map={.width=3,.height=2,.count=2,.mode=3,.storage=1,.encoding=2};
  for(guint i=0;i<2;i++)for(guint role=0;role<5;role++){
    guint8 *id=(guint8 *)&map.entries[i]+16*role;id[0]=0x31;id[14]=i+1;id[15]=role+1;
  }
  char *error=NULL;GimpImage *image=glims_lab_layer_storage_create(engine,&map,&error);
  CHECK(image && !error,"fixture creates logical carrier");if(error)api->free_string(error);if(!image)return GLIMS_STATUS_FAILED;
  GlimsLabLayerStorage storage;
  gboolean valid=glims_lab_layer_storage_read(image,&storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
  CHECK(valid,"fixture validates");if(!valid){g_object_unref(image);return GLIMS_STATUS_FAILED;}
  GimpLayer *root=storage.layers[0].group, *other=storage.layers[1].group;
  GList *selection=g_list_prepend(NULL,root);gimp_image_set_selected_layers(image,selection);g_list_free(selection);
  guint8 before[4][6], after[4][6], raw_other[4][6], unchanged_other[4][6];
  CHECK(read_planes(image,0,before)&&read_planes(image,1,raw_other),"both source roots captured");
  gboolean changed=TRUE;error=NULL;
  GlimsStatus status=glims_lab_layer_fill(engine,image,root,50,0,0,0,&changed,&error);
  CHECK(status==GLIMS_STATUS_OK&&!changed&&gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==0,
        "zero opacity leaves pixels and history untouched");if(error)api->free_string(error);error=NULL;
  status=glims_lab_layer_fill(engine,image,root,NAN,0,0,1,&changed,&error);
  CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT&&!changed&&read_planes(image,0,after)&&!memcmp(before,after,sizeof before),
        "invalid physical color refuses without mutation");if(error)api->free_string(error);error=NULL;
  status=glims_lab_layer_fill(engine,image,other,50,0,0,1,&changed,&error);
  CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT&&!changed,"an unselected logical root is refused");if(error)api->free_string(error);error=NULL;
  engine->busy++;
  status=glims_lab_layer_fill(engine,image,root,50,0,0,1,&changed,&error);
  engine->busy--;
  CHECK(status==GLIMS_STATUS_BUSY&&!changed&&read_planes(image,0,after)&&!memcmp(before,after,sizeof before),
        "a busy engine refuses without changing any plane");if(error)api->free_string(error);error=NULL;
  g_mutex_lock(&engine->lock);engine->stopping=TRUE;g_mutex_unlock(&engine->lock);
  status=glims_lab_layer_fill(engine,image,root,50,0,0,1,&changed,&error);
  g_mutex_lock(&engine->lock);engine->stopping=FALSE;g_mutex_unlock(&engine->lock);
  CHECK(status==GLIMS_STATUS_CANCELLED&&!changed&&read_planes(image,0,after)&&!memcmp(before,after,sizeof before),
        "a stopping engine cancels without changing any plane");if(error)api->free_string(error);error=NULL;
  CHECK(gimp_image_undo_freeze(image),"Undo freeze fixture starts");
  status=glims_lab_layer_fill(engine,image,root,50,0,0,1,&changed,&error);
  CHECK(status==GLIMS_STATUS_BUSY&&!changed,"frozen Undo refuses the entire fill");if(error)api->free_string(error);error=NULL;
  CHECK(gimp_image_undo_thaw(image),"Undo freeze fixture thaws");
  gimp_item_set_lock_content(GIMP_ITEM(root),TRUE,FALSE);
  status=glims_lab_layer_fill(engine,image,root,50,0,0,1,&changed,&error);
  gimp_item_set_lock_content(GIMP_ITEM(root),FALSE,FALSE);
  CHECK(status==GLIMS_STATUS_UNSUPPORTED&&!changed&&read_planes(image,0,after)&&!memcmp(before,after,sizeof before),
        "a locked logical root refuses without changing any plane");if(error)api->free_string(error);error=NULL;
  unsigned before_cancel_events=projection_events;
  request_cancel=TRUE;cancel_scheduled=FALSE;cancel_fired=FALSE;
  status=glims_lab_layer_fill(engine,image,root,50,0,0,1,&changed,&error);
  request_cancel=FALSE;
  CHECK(cancel_scheduled&&cancel_fired&&status==GLIMS_STATUS_CANCELLED&&!changed,
        "progress cancellation interrupts a fully staged fill before publication");
  CHECK(read_planes(image,0,after)&&!memcmp(before,after,sizeof before)&&
        gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==0&&
        !gimp_image_get_undo_group_count(image)&&!engine->busy&&!engine->progress&&projection_events==before_cancel_events,
        "cancelled staged fill leaves planes, history, redraw and engine admission unchanged");
  if(error)api->free_string(error);error=NULL;
  retarget_image=image;retarget_layer=other;
  request_retarget=TRUE;retarget_scheduled=FALSE;retarget_fired=FALSE;
  status=glims_lab_layer_fill(engine,image,root,50,0,0,1,&changed,&error);
  request_retarget=FALSE;retarget_image=NULL;retarget_layer=NULL;
  CHECK(retarget_scheduled&&retarget_fired&&status==GLIMS_STATUS_INVALID_ARGUMENT&&!changed,
        "a changed selection refuses the fully staged fill before publication");
  CHECK(read_planes(image,0,after)&&!memcmp(before,after,sizeof before)&&
        gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==0&&
        !gimp_image_get_undo_group_count(image)&&!engine->busy&&!engine->progress&&projection_events==before_cancel_events,
        "a stale target leaves planes, history, redraw and engine admission unchanged");
  selection=g_list_prepend(NULL,root);gimp_image_set_selected_layers(image,selection);g_list_free(selection);
  if(error)api->free_string(error);error=NULL;
  retarget_image=image;retarget_layer=other;
  request_retarget=TRUE;retarget_scheduled=FALSE;retarget_fired=FALSE;
  status=glims_lab_layer_fill(engine,image,root,50,0,0,0.000001,&changed,&error);
  request_retarget=FALSE;retarget_image=NULL;retarget_layer=NULL;
  CHECK(retarget_scheduled&&retarget_fired&&status==GLIMS_STATUS_INVALID_ARGUMENT&&!changed,
        "a changed selection also refuses a quantized no-op fill");
  CHECK(read_planes(image,0,after)&&!memcmp(before,after,sizeof before)&&
        gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==0&&
        !gimp_image_get_undo_group_count(image)&&!engine->busy&&!engine->progress&&projection_events==before_cancel_events,
        "a stale no-op leaves planes, history, redraw and engine admission unchanged");
  selection=g_list_prepend(NULL,root);gimp_image_set_selected_layers(image,selection);g_list_free(selection);
  if(error)api->free_string(error);error=NULL;
  unsigned before_event=projection_events;
  status=glims_lab_layer_fill(engine,image,root,50,0,0,1,&changed,&error);
  CHECK(status==GLIMS_STATUS_OK&&changed,"opaque physical Lab fill succeeds");if(error)api->free_string(error);error=NULL;
  if(status==GLIMS_STATUS_OK){
    CHECK(projection_events>before_event&&last_damage.x==0&&last_damage.y==0&&last_damage.width==3&&last_damage.height==2,
          "fill publishes full affected canvas damage");
    GlimsLabLayerStorage after_storage;
    CHECK(glims_lab_layer_storage_read(image,&after_storage)==GLIMS_LAB_LAYER_STORAGE_VALID&&
          !memcmp(&after_storage.map,&map,sizeof map),"fill retains the complete logical identity map");
    CHECK(read_planes(image,0,after),"filled root reads");
    for(guint p=0;p<4;p++)for(guint x=0;x<6;x++)
      CHECK(after[p][x]==(p==0?128:p==3?255:128),"opaque fill publishes expected plane byte");
    CHECK(read_planes(image,1,unchanged_other)&&!memcmp(raw_other,unchanged_other,sizeof raw_other),"other logical root remains byte-exact");
    CHECK(gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==1,"four-plane fill is one Undo step");
    guint8 opaque[4][6];memcpy(opaque,after,sizeof opaque);
    status=glims_lab_layer_fill(engine,image,root,0,-128,127,.5,&changed,&error);
    CHECK(status==GLIMS_STATUS_OK&&changed&&read_planes(image,0,after)&&
          after[0][0]==64&&after[1][0]==64&&after[2][0]==192&&after[3][0]==255,
          "half-opacity source-over blends all channels over opaque pixels");if(error)api->free_string(error);error=NULL;
    CHECK(gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==2&&gimp_image_undo(image)&&
          read_planes(image,0,after)&&!memcmp(opaque,after,sizeof opaque),"one Undo restores the prior opaque fill");
    CHECK(gimp_image_undo(image)&&read_planes(image,0,after)&&!memcmp(before,after,sizeof before),"Undo restores all four scalar planes");
    CHECK(gimp_image_redo(image)&&read_planes(image,0,after)&&after[0][0]==128&&after[3][0]==255,"Redo restores the same physical fill");
    CHECK(gimp_image_undo(image),"fixture returns to transparent root");
  }
  GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(image));float half=.5f;
  gegl_buffer_set(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,0,1,1),0,babl_format("Y float"),&half,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(mask,1,0,1,1);
  CHECK(!gimp_channel_is_empty(gimp_image_get_mask(image)),"partial selection mask is active");
  status=glims_lab_layer_fill(engine,image,root,0,-128,127,1,&changed,&error);
  CHECK(status==GLIMS_STATUS_OK&&changed,"selection-weighted fill succeeds");if(error)api->free_string(error);error=NULL;
  if(status==GLIMS_STATUS_OK){
    CHECK(last_damage.x==1&&last_damage.y==0&&last_damage.width==1&&last_damage.height==1,
          "masked fill publishes its bounded canvas damage");
    CHECK(read_planes(image,0,after),"selection-weighted result reads");
    CHECK(after[0][1]==0&&after[1][1]==0&&after[2][1]==255&&after[3][1]==128,"half coverage writes exact physical color and alpha");
    gboolean rest=TRUE;for(guint p=0;p<4;p++)for(guint x=0;x<6;x++)if(x!=1&&after[p][x]!=before[p][x])rest=FALSE;
    CHECK(rest,"fill does not alter pixels outside the selection");
    CHECK(gimp_image_undo(image)&&read_planes(image,0,after)&&!memcmp(before,after,sizeof before),"one Undo restores the masked fill");
    CHECK(gimp_image_redo(image),"masked fill is redoable");
  }
  gchar *path=g_build_filename((const gchar *)context,"lab-layer-fill.xcf",NULL);GFile *file=g_file_new_for_path(path);GError *gerror=NULL;
  GimpPlugInProcedure *save=gimp_plug_in_manager_file_procedure_find(engine->gimp->plug_in_manager,GIMP_FILE_PROCEDURE_GROUP_SAVE,file,&gerror);
  GimpPDBStatusType saved=save?file_save(engine->gimp,image,NULL,file,save,GIMP_RUN_NONINTERACTIVE,TRUE,FALSE,FALSE,&gerror):GIMP_PDB_EXECUTION_ERROR;
  CHECK(saved==GIMP_PDB_SUCCESS,"filled logical carrier saves as XCF");if(gerror)g_clear_error(&gerror);
  if(saved==GIMP_PDB_SUCCESS){
    GlimsImageID reopened=0;error=NULL;GlimsStatus opened=api->image_open(engine,path,&reopened,&error);
    CHECK(opened==GLIMS_STATUS_OK&&reopened,"filled logical XCF reopens");if(error)api->free_string(error);error=NULL;
    if(opened==GLIMS_STATUS_OK&&reopened){
     GlimsOpenImage *copy=glims_lookup_image(engine,reopened);
     CHECK(copy&&read_planes(copy->image,0,after)&&after[0][1]==0&&after[1][1]==0&&after[2][1]==255&&after[3][1]==128,
           "XCF preserves all filled plane values");
     CHECK(api->image_close(engine,reopened)==GLIMS_STATUS_OK,"filled copy closes");
    }
  }
  g_object_unref(file);g_free(path);g_object_unref(image);
  map.width=4103;map.count=1;error=NULL;
  GimpImage *wide=glims_lab_layer_storage_create(engine,&map,&error);
  CHECK(wide&&!error,"wide logical carrier creates");if(error)api->free_string(error);error=NULL;
  if(wide){
   GlimsLabLayerStorage wide_storage;
   gboolean wide_valid=glims_lab_layer_storage_read(wide,&wide_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
   CHECK(wide_valid,"wide logical carrier validates");
   if(wide_valid){
    GimpLayer *wide_root=wide_storage.layers[0].group;GList *one=g_list_prepend(NULL,wide_root);
    gimp_image_set_selected_layers(wide,one);g_list_free(one);
    status=glims_lab_layer_fill(engine,wide,wide_root,0,-128,127,1,&changed,&error);
    CHECK(status==GLIMS_STATUS_OK&&changed,"wide fill crosses the 4096-pixel chunk boundary");if(error)api->free_string(error);error=NULL;
    if(status==GLIMS_STATUS_OK){
     guint8 samples[3];GimpDrawable *alpha=GIMP_DRAWABLE(wide_storage.layers[0].planes[3]);
     gegl_buffer_get(gimp_drawable_get_buffer(alpha),GEGL_RECTANGLE(4094,0,3,1),1,gimp_drawable_get_format(alpha),samples,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
     CHECK(samples[0]==255&&samples[1]==255&&samples[2]==255,"fill publishes pixels on both sides of chunk boundary");
     CHECK(gimp_image_undo(wide),"wide fill is one undoable transaction");
     gegl_buffer_get(gimp_drawable_get_buffer(alpha),GEGL_RECTANGLE(4094,0,3,1),1,gimp_drawable_get_format(alpha),samples,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
     CHECK(samples[0]==0&&samples[1]==0&&samples[2]==0,"Undo restores both sides of chunk boundary");
    }
   }
   g_object_unref(wide);
  }
  return GLIMS_STATUS_OK;
}

int main(int argc,char **argv)
{
  if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig cfg={.struct_size=sizeof cfg,.user_directory=user,.cache_directory=cache,.on_event=on_event};GlimsEngine *engine=NULL;char *error=NULL;
  GlimsStatus status=api->start(&cfg,&engine,&error);g_free(user);g_free(cache);
  if(status||!engine){fprintf(stderr,"start: %s\n",error?error:"");if(error)api->free_string(error);return 2;}
  if(error)api->free_string(error);running_engine=engine;status=glims_engine_call(engine,worker,argv[1]);running_engine=NULL;api->stop(engine);
  printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;
}

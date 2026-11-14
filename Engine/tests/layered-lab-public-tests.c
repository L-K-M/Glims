/* Public read-only layered Lab acceptance probe, with an LCMS color oracle. */
#include "engine-private.h"
#include "lab-layer-storage.h"
#include "plate-storage.h"
#include <lcms2.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpbrush-private.h"
#include "core/gimpimage.h"
#include "core/gimpdrawable.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimptempbuf.h"
#include "file/file-save.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
static const GlimsEngineAPI *api;static unsigned checks,failures;
static GlimsEngine *running_engine;
static gboolean request_fill_cancel, fill_cancel_scheduled, fill_cancelled;
static guint fill_cancel_source;
static GlimsImageID brush_retarget_image;
static GlimsItemID brush_retarget_root;
static gboolean brush_retargeted;
static GlimsStrokeID brush_reentrant_stroke;
static GlimsStatus brush_close_status,brush_cancel_status,brush_end_status,brush_continue_status;
static GlimsImageID brush_event_image;
static unsigned brush_projection_events;
static GlimsRect brush_projection_rect;
#define CHECK(c,n) do{gboolean b=!!(c);checks++;if(!b)failures++;printf("%s %s\n",b?"ok":"FAIL",n);fflush(stdout);}while(0)
static gboolean cancel_fill_on_engine(gpointer unused){(void)unused;fill_cancel_source=0;if(request_fill_cancel)fill_cancelled=running_engine&&api->procedure_cancel(running_engine)==GLIMS_STATUS_OK;return G_SOURCE_REMOVE;}
static void on_event(void *context,const GlimsEvent *event){(void)context;
 if(event->kind==GLIMS_EVENT_PROJECTION_CHANGED&&event->image==brush_event_image){brush_projection_events++;brush_projection_rect=event->rect;}
 if(event->kind==GLIMS_EVENT_PROGRESS&&event->active&&event->value>=1&&request_fill_cancel&&!fill_cancel_scheduled){fill_cancel_scheduled=TRUE;fill_cancel_source=g_idle_add(cancel_fill_on_engine,NULL);}}
static void retarget_on_brush_update(GimpDrawable *drawable,gint x,gint y,gint width,gint height,gpointer data){
 (void)drawable;(void)x;(void)y;(void)width;(void)height;(void)data;
 if(!brush_retargeted){
  brush_retargeted=TRUE;brush_close_status=api->image_close(running_engine,brush_retarget_image);
  if(brush_reentrant_stroke){
   GlimsStrokePacketV2 empty={.struct_size=sizeof empty,.sample_stride=sizeof(GlimsStrokeSampleV2)};
   brush_cancel_status=api->stroke_cancel_lab_layer(running_engine,brush_reentrant_stroke);
   brush_end_status=api->stroke_end(running_engine,brush_reentrant_stroke);
   brush_continue_status=api->stroke_continue_v2(running_engine,brush_reentrant_stroke,&empty,NULL);
  }
  if(brush_retarget_root)api->layer_select(running_engine,brush_retarget_image,brush_retarget_root);
 }
}
static gboolean brush_raw(GlimsEngine *engine,GlimsImageID image,unsigned root,guint8 pixels[4][16]){
 GlimsOpenImage *open=glims_lookup_image(engine,image);GlimsLabLayerStorage storage;
 if(!open||glims_lab_layer_storage_read(open->image,&storage)!=GLIMS_LAB_LAYER_STORAGE_VALID||root>=storage.map.count)return FALSE;
 for(unsigned i=0;i<4;i++){GimpDrawable *plane=GIMP_DRAWABLE(storage.layers[root].planes[i]);
  gegl_buffer_get(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,4,4),1,
                  gimp_drawable_get_format(plane),pixels[i],GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);}
 return TRUE;
}
static gboolean save_fixture(Gimp *g,GimpImage *im,const char *path){GError *err=NULL;GFile *f=g_file_new_for_path(path);GimpPlugInProcedure *p=gimp_plug_in_manager_file_procedure_find(g->plug_in_manager,GIMP_FILE_PROCEDURE_GROUP_SAVE,f,&err);GimpPDBStatusType s=p?file_save(g,im,NULL,f,p,GIMP_RUN_NONINTERACTIVE,TRUE,FALSE,FALSE,&err):GIMP_PDB_EXECUTION_ERROR;if(err){fprintf(stderr,"fixture save: %s\n",err->message);g_clear_error(&err);}g_object_unref(f);return s==GIMP_PDB_SUCCESS;}
static GlimsStatus worker(GlimsEngine *engine,gpointer work){
 GlimsLabLayerMap m={.width=4,.height=4,.count=2,.mode=GLIMS_LAB_LAYER_MAP_MODE_LAB,.storage=GLIMS_LAB_LAYER_MAP_STORAGE_U8,.encoding=GLIMS_LAB_LAYER_MAP_ENCODING_LAB_D50};
 for(guint i=0;i<2;i++)for(guint role=0;role<5;role++){guint8 *p=(guint8*)&m.entries[i]+16*role;p[14]=i+1;p[15]=role+1;}
 char *error=NULL;GimpImage *image=glims_lab_layer_storage_create(engine,&m,&error);CHECK(image&&!error,"valid layered Lab fixture creates");if(error)api->free_string(error);if(!image)return GLIMS_STATUS_OK;
 GlimsLabLayerStorage storage;gboolean valid=glims_lab_layer_storage_read(image,&storage)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(valid,"fixture passes strict native storage validation");
 if(!valid){g_object_unref(image);return GLIMS_STATUS_OK;}
 for(guint i=0;i<2;i++)for(guint role=0;role<4;role++){
  guint8 values[16];memset(values,role==3?255:role==0?(i?255:128):128,sizeof values);
  GimpDrawable *d=GIMP_DRAWABLE(storage.layers[i].planes[role]);gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,4,4),0,gimp_drawable_get_format(d),values,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(d,0,0,4,4);
 }
 GList *private_selection=g_list_prepend(NULL,storage.layers[0].planes[0]);
 gimp_image_set_selected_layers(image,private_selection);g_list_free(private_selection);
 CHECK(gimp_image_get_selected_layers(image) &&
       gimp_image_get_selected_layers(image)->data==storage.layers[0].planes[0],
       "fixture initially selects a private scalar plane");
 gchar *path=g_build_filename((const gchar*)work,"layered-lab.xcf",NULL);gboolean saved=save_fixture(engine->gimp,image,path);CHECK(saved,"valid layered carrier saves as XCF");g_object_unref(image);if(!saved){g_free(path);return GLIMS_STATUS_OK;}
 gchar *before=NULL,*after=NULL;gsize before_size=0,after_size=0;CHECK(g_file_get_contents(path,&before,&before_size,NULL),"source XCF bytes captured");
 GlimsImageID id=0;error=NULL;GlimsStatus s=api->image_open(engine,path,&id,&error);printf("OPEN status=%d id=%d error=%s\n",s,id,error?error:"");CHECK(s==GLIMS_STATUS_OK&&id!=0,"public open accepts valid layered Lab XCF");if(error)api->free_string(error);
 if(s==GLIMS_STATUS_OK&&id){
  guint8 info_bytes[sizeof(GlimsImageStorageInfo)+2];memset(info_bytes,0xa5,sizeof info_bytes);
  guint32 info_size=sizeof(GlimsImageStorageInfo);memcpy(info_bytes+1,&info_size,sizeof info_size);
  s=api->image_storage_info(engine,id,(GlimsImageStorageInfo*)(info_bytes+1));
  GlimsImageStorageInfo layout;memcpy(&layout,info_bytes+1,sizeof layout);
  CHECK(s==GLIMS_STATUS_OK&&layout.layout==GLIMS_IMAGE_LAYOUT_LAYERED_LAB&&
        (layout.flags&GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES)&&!(layout.flags&GLIMS_IMAGE_STORAGE_READ_ONLY)&&
        (layout.flags&GLIMS_IMAGE_STORAGE_LAYER_RENAME)&&(layout.flags&GLIMS_IMAGE_STORAGE_LAYER_DUPLICATE)&&
        (layout.flags&GLIMS_IMAGE_STORAGE_LAYER_CREATE)&&(layout.flags&GLIMS_IMAGE_STORAGE_LAYER_DELETE)&&
        (layout.flags&GLIMS_IMAGE_STORAGE_LAYER_REORDER)&&(layout.flags&GLIMS_IMAGE_STORAGE_LAB_SELECTIONS)&&
        (layout.flags&GLIMS_IMAGE_STORAGE_LAB_LAYER_COLOR_FILL)&&
        (layout.flags&GLIMS_IMAGE_STORAGE_LAB_LAYER_BRUSH)&&
        info_bytes[0]==0xa5&&info_bytes[sizeof info_bytes-1]==0xa5,
        "size-versioned unaligned layout reports limited layer-property editing");
  guint8 short_info[sizeof(GlimsImageStorageInfo)+2],saved_short[sizeof short_info];
  memset(short_info,0xa5,sizeof short_info);info_size=sizeof(GlimsImageStorageInfo)-1;
  memcpy(short_info+1,&info_size,sizeof info_size);memcpy(saved_short,short_info,sizeof short_info);
  CHECK(api->image_storage_info(engine,id,(GlimsImageStorageInfo*)(short_info+1))==GLIMS_STATUS_INVALID_ARGUMENT&&
        !memcmp(short_info,saved_short,sizeof short_info),"short layout output is refused without writing");
  guint8 extended[sizeof(GlimsImageStorageInfo)+8];memset(extended,0xa5,sizeof extended);
  info_size=sizeof extended;memcpy(extended,&info_size,sizeof info_size);
  CHECK(api->image_storage_info(engine,id,(GlimsImageStorageInfo*)extended)==GLIMS_STATUS_OK &&
        !memcmp(extended+sizeof(GlimsImageStorageInfo),"\xa5\xa5\xa5\xa5\xa5\xa5\xa5\xa5",8),
        "extended layout output leaves its unknown tail untouched");
  CHECK(api->image_storage_info(engine,id,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,
        "null layout output is refused");
  GlimsImageStorageInfo absent={.struct_size=sizeof absent};
  CHECK(api->image_storage_info(engine,0,&absent)==GLIMS_STATUS_NOT_FOUND,
        "layout query for an unknown image is refused");
  GlimsColorInfo color;CHECK(api->image_color_info(engine,id,&color)==GLIMS_STATUS_OK&&color.mode==GLIMS_COLOR_MODE_LAB,"public color info reports Lab");
  GlimsLayerInfo rows[8];int32_t count=0;CHECK(api->image_layers(engine,id,rows,8,&count)==GLIMS_STATUS_OK&&count==2,"only two logical layer roots are exposed");
  if(count==2){
   CHECK(rows[0].depth==0&&rows[1].depth==0&&rows[0].parent==0&&rows[1].parent==0,"logical rows are top-level");
   GlimsPoint points[2]={{1,1},{3,3}};
   GlimsLabSelectOptions select_options={.struct_size=sizeof select_options,.operation=GLIMS_SELECT_REPLACE};
   guint8 before_mask_render[4]={0},after_mask_render[4]={0};
   CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},before_mask_render,4)==GLIMS_STATUS_OK,
         "layered Lab pixels are captured before selection edits");
   engine->busy++;
   CHECK(api->image_select_lab_shape(engine,id,GLIMS_SHAPE_RECTANGLE,points,2,&select_options,&error)==GLIMS_STATUS_BUSY,
         "layered Lab selection refuses a busy engine");
   engine->busy--;if(error)api->free_string(error);error=NULL;
   CHECK(api->select_shape(engine,id,GLIMS_SHAPE_RECTANGLE,points,2,NULL)==GLIMS_STATUS_UNSUPPORTED,
         "ordinary selection facade remains closed for layered Lab");
   error=NULL;
   GlimsStatus selected_shape=api->image_select_lab_shape(engine,id,GLIMS_SHAPE_RECTANGLE,points,2,&select_options,&error);
   CHECK(selected_shape==GLIMS_STATUS_OK,"layered Lab rectangle edits its root selection mask");
   if(error)api->free_string(error);error=NULL;
   if(selected_shape==GLIMS_STATUS_OK){
    bool empty=true;GlimsRect bounds={0};
    CHECK(api->selection_bounds(engine,id,&empty,&bounds)==GLIMS_STATUS_OK&&!empty&&
          bounds.x==1&&bounds.y==1&&bounds.width==2&&bounds.height==2,
          "layered Lab selection has expected rectangle bounds");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&
          api->selection_bounds(engine,id,&empty,&bounds)==GLIMS_STATUS_OK&&empty,
          "Undo restores the empty layered Lab selection");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&
          api->selection_bounds(engine,id,&empty,&bounds)==GLIMS_STATUS_OK&&!empty&&bounds.width==2,
          "Redo restores the layered Lab selection");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"selection fixture returns to its initial state");
    CHECK(api->image_select_lab_command(engine,id,GLIMS_SELECT_ALL,&error)==GLIMS_STATUS_OK&&
          api->selection_bounds(engine,id,&empty,&bounds)==GLIMS_STATUS_OK&&!empty&&bounds.width==4&&bounds.height==4,
          "Select All fills the layered Lab root mask");
    if(error)api->free_string(error);error=NULL;
    CHECK(api->image_select_lab_command(engine,id,GLIMS_SELECT_INVERT,&error)==GLIMS_STATUS_OK&&
          api->selection_bounds(engine,id,&empty,&bounds)==GLIMS_STATUS_OK&&empty,
          "Invert clears a full layered Lab selection");
    if(error)api->free_string(error);error=NULL;
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&api->image_undo(engine,id)==GLIMS_STATUS_OK,
          "selection commands each undo independently");
    CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},after_mask_render,4)==GLIMS_STATUS_OK&&
          !memcmp(before_mask_render,after_mask_render,sizeof before_mask_render),
          "selection editing leaves layered Lab pixels unchanged");
   }
   guint8 raw_identity[sizeof(GlimsLabLayerIdentity)+10];memset(raw_identity,0xa5,sizeof raw_identity);
   guint32 identity_size=sizeof(GlimsLabLayerIdentity)+8;memcpy(raw_identity+1,&identity_size,sizeof identity_size);
   GlimsUndoInfo identity_before={0},identity_after={0};
   CHECK(api->image_undo_info(engine,id,&identity_before)==GLIMS_STATUS_OK,"identity read captures history");
   GlimsStatus identity_status=api->image_lab_layer_identity(engine,id,rows[0].id,(GlimsLabLayerIdentity*)(raw_identity+1));
   GlimsLabLayerIdentity first_identity;memcpy(&first_identity,raw_identity+1,sizeof first_identity);
   CHECK(identity_status==GLIMS_STATUS_OK&&first_identity.struct_size==identity_size&&
         !memcmp(first_identity.uuid,m.entries[0].group,16)&&raw_identity[0]==0xa5&&
         !memcmp(raw_identity+1+sizeof first_identity,"\xa5\xa5\xa5\xa5\xa5\xa5\xa5\xa5",8)&&
         raw_identity[sizeof raw_identity-1]==0xa5,
         "unaligned logical identity returns the captured UUID and preserves its extension");
   GlimsLabLayerIdentity second_identity={.struct_size=sizeof second_identity};
   CHECK(api->image_lab_layer_identity(engine,id,rows[1].id,&second_identity)==GLIMS_STATUS_OK&&
         !memcmp(second_identity.uuid,m.entries[1].group,16)&&memcmp(first_identity.uuid,second_identity.uuid,16),
         "distinct logical roots have their own durable identities");
   engine->busy++;
   CHECK(api->image_lab_layer_identity(engine,id,rows[0].id,&second_identity)==GLIMS_STATUS_OK&&
         !memcmp(first_identity.uuid,second_identity.uuid,16),"identity remains readable while busy");
   engine->busy--;
   GlimsOpenImage *identity_open=glims_lookup_image(engine,id);GlimsLabLayerStorage identity_storage;
   gboolean identity_valid=identity_open&&glims_lab_layer_storage_read(identity_open->image,&identity_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
   CHECK(identity_valid,"identity fixture retains valid native mapping");
   if(identity_valid){
    GlimsItemID hidden=gimp_item_get_id(GIMP_ITEM(identity_storage.layers[0].planes[0]));
    memset(second_identity.uuid,0xa5,sizeof second_identity.uuid);
    guint8 zero_uuid[16]={0};
    CHECK(api->image_lab_layer_identity(engine,id,hidden,&second_identity)==GLIMS_STATUS_NOT_FOUND&&
          !memcmp(second_identity.uuid,zero_uuid,sizeof zero_uuid),"hidden planes refuse and clear the UUID");
   }
   guint8 short_identity[sizeof(GlimsLabLayerIdentity)+2],saved_identity[sizeof short_identity];
   memset(short_identity,0xa5,sizeof short_identity);identity_size=sizeof(GlimsLabLayerIdentity)-1;
   memcpy(short_identity+1,&identity_size,sizeof identity_size);memcpy(saved_identity,short_identity,sizeof short_identity);
   CHECK(api->image_lab_layer_identity(engine,id,rows[0].id,(GlimsLabLayerIdentity*)(short_identity+1))==GLIMS_STATUS_INVALID_ARGUMENT&&
         !memcmp(short_identity,saved_identity,sizeof short_identity),"short identity output is untouched");
   CHECK(api->image_lab_layer_identity(engine,id,rows[0].id,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,
         "null identity output is refused");
   memset(second_identity.uuid,0xa5,sizeof second_identity.uuid);
   CHECK(api->image_lab_layer_identity(engine,id,0,&second_identity)==GLIMS_STATUS_INVALID_ARGUMENT&&
         !memcmp(second_identity.uuid,"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",16),
         "a missing explicit root is refused and clears the identity");
   memset(second_identity.uuid,0xa5,sizeof second_identity.uuid);
   CHECK(api->image_lab_layer_identity(NULL,id,rows[0].id,&second_identity)==GLIMS_STATUS_NOT_RUNNING&&
         !memcmp(second_identity.uuid,"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",16),
         "a stopped engine clears an accepted identity output");
   CHECK(api->image_undo_info(engine,id,&identity_after)==GLIMS_STATUS_OK&&
         identity_before.undo_count==identity_after.undo_count&&identity_before.redo_count==identity_after.redo_count,
         "identity reads leave Undo and Redo unchanged");
   GlimsImageID ordinary=0;error=NULL;
   CHECK(api->image_new(engine,2,2,&ordinary,&error)==GLIMS_STATUS_OK&&ordinary,
         "ordinary image fixture for identity refusal opens");if(error)api->free_string(error);error=NULL;
   if(ordinary){
    memset(second_identity.uuid,0xa5,sizeof second_identity.uuid);
    CHECK(api->image_lab_layer_identity(engine,ordinary,rows[0].id,&second_identity)==GLIMS_STATUS_UNSUPPORTED&&
          !memcmp(second_identity.uuid,"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",16),
          "ordinary image refuses a Lab root identity and clears the output");
    CHECK(api->image_close(engine,ordinary)==GLIMS_STATUS_OK,"ordinary identity fixture closes");
   }
   CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK,"fill fixture selects its captured root");
   GlimsLabLayerBrushSettings brush={.struct_size=sizeof brush,.root=rows[0].id,
     .color={1,0,0,1},.opacity=1,.size=5,.hardness=1};memcpy(brush.uuid,first_identity.uuid,16);
   GlimsStrokeSampleV2 brush_point={.struct_size=sizeof brush_point,.x=1.5,.y=1.5,.pressure=1,.time_ms=1};
   GlimsStrokePacketV2 brush_packet={.struct_size=sizeof brush_packet,.sample_stride=sizeof brush_point,
     .samples=&brush_point,.count=1,.byte_count=sizeof brush_point};
   guint8 brush_before[4][16],brush_after[4][16],brush_other[4][16],brush_other_after[4][16];
   CHECK(brush_raw(engine,id,0,brush_before)&&brush_raw(engine,id,1,brush_other),"capture public brush source planes");
   GlimsUndoInfo brush_history_before={0},brush_history_after={0};
   CHECK(api->image_undo_info(engine,id,&brush_history_before)==GLIMS_STATUS_OK,"capture public brush history");
   brush_retarget_image=id;brush_retarget_root=rows[1].id;brush_retargeted=FALSE;brush_reentrant_stroke=0;
   gulong brush_update_handler=g_signal_connect(identity_storage.layers[0].planes[0],"update",G_CALLBACK(retarget_on_brush_update),NULL);
   GlimsStrokeID reentrant_stroke=0;GlimsStatus reentrant_status=api->stroke_begin_lab_layer(engine,id,0,&brush,&brush_packet,&reentrant_stroke,&error);
   g_signal_handler_disconnect(identity_storage.layers[0].planes[0],brush_update_handler);
   CHECK(brush_retargeted&&reentrant_status==GLIMS_STATUS_INVALID_ARGUMENT&&!reentrant_stroke,
         "reentrant target change cancels the first brush dab");
   CHECK(brush_close_status==GLIMS_STATUS_BUSY,"reentrant close refuses while the first dab is running");
   if(error)api->free_string(error);error=NULL;
   if(reentrant_stroke)api->stroke_cancel_lab_layer(engine,reentrant_stroke);
   CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK&&brush_raw(engine,id,0,brush_after)&&
         !memcmp(brush_before,brush_after,sizeof brush_before),"reentrant begin restores its captured planes");
   GlimsStrokeID brush_id=123;GlimsLabLayerBrushSettings invalid_brush=brush;invalid_brush.uuid[0]^=0xff;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&invalid_brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&brush_id==0,
         "public brush refuses a stale UUID before painting");if(error)api->free_string(error);error=NULL;
   invalid_brush=brush;invalid_brush.color.red=NAN;brush_id=123;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&invalid_brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&brush_id==0,
         "public brush refuses nonfinite color");if(error)api->free_string(error);error=NULL;
   invalid_brush=brush;invalid_brush.struct_size=sizeof invalid_brush-1;brush_id=123;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&invalid_brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&brush_id==0,
         "public brush refuses a short request");if(error)api->free_string(error);error=NULL;
   invalid_brush=brush;invalid_brush.root=rows[1].id;memcpy(invalid_brush.uuid,m.entries[1].group,16);brush_id=123;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&invalid_brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&brush_id==0,
         "public brush refuses an unselected root");if(error)api->free_string(error);error=NULL;
   engine->busy++;brush_id=123;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_BUSY&&brush_id==0,
         "public brush refuses a busy engine");engine->busy--;if(error)api->free_string(error);error=NULL;
   brush_id=123;
   CHECK(api->stroke_begin_lab_layer(engine,id,INT32_MAX,&brush,&brush_packet,&brush_id,&error)!=GLIMS_STATUS_OK&&brush_id==0,
         "public brush refuses an unknown brush resource");if(error)api->free_string(error);error=NULL;
   CHECK(brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before)&&
         api->image_undo_info(engine,id,&brush_history_after)==GLIMS_STATUS_OK&&
         brush_history_before.undo_count==brush_history_after.undo_count&&brush_history_before.redo_count==brush_history_after.redo_count,
         "refused public strokes preserve pixels and history");
   CHECK(api->stroke_begin_lab_layer_with_capture_facts!=NULL,"layered Lab brush facts entry is available");
   if(api->stroke_begin_lab_layer_with_capture_facts){
    GlimsStrokeCaptureFacts facts={.struct_size=sizeof facts},replayed={.struct_size=sizeof replayed};
    GlimsStrokeID capture_id=123;
    CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,0,&brush,false,&brush_packet,NULL,
          &capture_id,NULL,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&capture_id==0,
          "capture requires a facts output");if(error)api->free_string(error);error=NULL;
    char sentinel[]="sentinel";
    GlimsStrokeCaptureFacts short_facts={.struct_size=sizeof short_facts-1,.brush_name=sentinel};
    capture_id=123;
    CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,0,&brush,false,&brush_packet,NULL,
          &capture_id,&short_facts,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&capture_id==0&&
          short_facts.brush_name==sentinel,"short facts output is refused without overwriting it");
    if(error)api->free_string(error);error=NULL;
    capture_id=123;facts.struct_size=sizeof facts;
    CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,0,&brush,false,NULL,NULL,
          &capture_id,&facts,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&!capture_id&&!facts.fingerprint,
          "capture refuses a null first packet and clears its output");
    if(error)api->free_string(error);error=NULL;
    brush_retargeted=FALSE;brush_retarget_image=id;brush_retarget_root=rows[1].id;
    brush_update_handler=g_signal_connect(identity_storage.layers[0].planes[0],"update",G_CALLBACK(retarget_on_brush_update),NULL);
    capture_id=123;facts.struct_size=sizeof facts;
    GlimsStatus retargeted_capture=api->stroke_begin_lab_layer_with_capture_facts(engine,id,0,&brush,false,
      &brush_packet,NULL,&capture_id,&facts,&error);
    g_signal_handler_disconnect(identity_storage.layers[0].planes[0],brush_update_handler);
    CHECK(brush_retargeted&&retargeted_capture==GLIMS_STATUS_INVALID_ARGUMENT&&!capture_id&&
      !facts.brush_name&&!facts.brush_collection&&!facts.fingerprint&&
      brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before),
      "retargeting during first dab cancels capture and clears its facts");
    if(error)api->free_string(error);error=NULL;
    CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK,
          "captured-brush retarget fixture restores the selected root");
    capture_id=0;
    GlimsStatus captured=api->stroke_begin_lab_layer_with_capture_facts(engine,id,0,&brush,false,
      &brush_packet,NULL,&capture_id,&facts,&error);
    CHECK(captured==GLIMS_STATUS_OK&&capture_id&&facts.brush_name&&facts.fingerprint&&strlen(facts.fingerprint)==64,
          "live brush returns same-call resource identity and fingerprint");
    if(error)api->free_string(error);error=NULL;
    guint8 first_capture[4][16];
    gboolean captured_pixels=capture_id&&brush_raw(engine,id,0,first_capture)&&memcmp(brush_before,first_capture,sizeof brush_before);
    if(capture_id)CHECK(api->stroke_cancel_lab_layer(engine,capture_id)==GLIMS_STATUS_OK&&
      brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before),
      "cancelled captured brush restores its source planes");
    GlimsResourceID captured_brush=0;
    if(facts.brush_name&&facts.fingerprint){
     CHECK(api->resource_resolve(engine,GLIMS_RESOURCE_BRUSH,facts.brush_name,facts.brush_collection,
           facts.brush_internal,&captured_brush,&error)==GLIMS_STATUS_OK&&captured_brush,
           "captured brush identity resolves in the resource catalog");
     if(error)api->free_string(error);error=NULL;
     char wrong[65];memset(wrong,'0',64);wrong[64]=0;
     if(!strcmp(wrong,facts.fingerprint))wrong[0]='1';
     capture_id=123;replayed.struct_size=sizeof replayed;
     CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,captured_brush,&brush,false,
       &brush_packet,"invalid",&capture_id,&replayed,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&
       !capture_id&&!replayed.fingerprint,"malformed fingerprint is refused before painting");
     if(error)api->free_string(error);error=NULL;
     capture_id=123;replayed.struct_size=sizeof replayed;
     CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,0,&brush,false,
       &brush_packet,facts.fingerprint,&capture_id,&replayed,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&
       !capture_id&&!replayed.fingerprint,"guarded replay requires an explicit brush identity");
     if(error)api->free_string(error);error=NULL;
     capture_id=123;replayed.struct_size=sizeof replayed;
     CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,captured_brush,&brush,false,
       &brush_packet,wrong,&capture_id,&replayed,&error)!=GLIMS_STATUS_OK&&capture_id==0&&
       !replayed.brush_name&&!replayed.brush_collection&&!replayed.fingerprint&&
       brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before),
       "mismatched fingerprint refuses before painting and clears returned facts");
     if(error)api->free_string(error);error=NULL;
     capture_id=0;replayed.struct_size=sizeof replayed;
     GlimsStatus replay_status=api->stroke_begin_lab_layer_with_capture_facts(engine,id,captured_brush,
       &brush,false,&brush_packet,facts.fingerprint,&capture_id,&replayed,&error);
     CHECK(replay_status==GLIMS_STATUS_OK&&capture_id&&replayed.fingerprint&&
       !strcmp(facts.fingerprint,replayed.fingerprint)&&captured_pixels&&
       brush_raw(engine,id,0,brush_after)&&!memcmp(first_capture,brush_after,sizeof first_capture),
       "matching fingerprint reproduces captured four-plane pixels");
     if(error)api->free_string(error);error=NULL;
     if(capture_id)CHECK(api->stroke_cancel_lab_layer(engine,capture_id)==GLIMS_STATUS_OK&&
       brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before),
       "guarded replay can be cancelled without changing the source");
     guint8 unaligned_settings[sizeof brush+2],unaligned_facts[sizeof facts+2];
     memset(unaligned_settings,0xa5,sizeof unaligned_settings);memcpy(unaligned_settings+1,&brush,sizeof brush);
     memset(unaligned_facts,0xa5,sizeof unaligned_facts);
     GlimsStrokeCaptureFacts aligned_facts={.struct_size=sizeof aligned_facts};
     memcpy(unaligned_facts+1,&aligned_facts,sizeof aligned_facts);capture_id=0;
     GlimsStatus unaligned_status=api->stroke_begin_lab_layer_with_capture_facts(engine,id,captured_brush,
       (const GlimsLabLayerBrushSettings *)(unaligned_settings+1),false,&brush_packet,facts.fingerprint,
       &capture_id,(GlimsStrokeCaptureFacts *)(unaligned_facts+1),&error);
     memcpy(&aligned_facts,unaligned_facts+1,sizeof aligned_facts);
     CHECK(unaligned_status==GLIMS_STATUS_OK&&capture_id&&aligned_facts.fingerprint&&
       !strcmp(facts.fingerprint,aligned_facts.fingerprint)&&unaligned_settings[0]==0xa5&&
       unaligned_settings[sizeof unaligned_settings-1]==0xa5&&unaligned_facts[0]==0xa5&&
       unaligned_facts[sizeof unaligned_facts-1]==0xa5,
       "unaligned request and facts preserve surrounding bytes");
     if(error)api->free_string(error);error=NULL;
     if(capture_id)api->stroke_cancel_lab_layer(engine,capture_id);
     api->free_string(aligned_facts.brush_name);api->free_string(aligned_facts.brush_collection);api->free_string(aligned_facts.fingerprint);
     GlimsStrokeCaptureFacts pressure_facts={.struct_size=sizeof pressure_facts};
     capture_id=0;brush_point.pressure=.5;
     GlimsStatus pressure_capture=api->stroke_begin_lab_layer_with_capture_facts(engine,id,captured_brush,
       &brush,true,&brush_packet,NULL,&capture_id,&pressure_facts,&error);
     CHECK(pressure_capture==GLIMS_STATUS_OK&&capture_id&&pressure_facts.fingerprint&&
       strcmp(facts.fingerprint,pressure_facts.fingerprint),"pressure capture has distinct brush facts");
     if(error)api->free_string(error);error=NULL;
     guint8 pressure_pixels[4][16];
     gboolean had_pressure=capture_id&&brush_raw(engine,id,0,pressure_pixels)&&
       memcmp(brush_before,pressure_pixels,sizeof brush_before);
     if(capture_id)api->stroke_cancel_lab_layer(engine,capture_id);
     if(pressure_facts.fingerprint){
      GlimsStrokeCaptureFacts wrong_mode={.struct_size=sizeof wrong_mode};capture_id=123;
      CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,captured_brush,&brush,false,
        &brush_packet,pressure_facts.fingerprint,&capture_id,&wrong_mode,&error)!=GLIMS_STATUS_OK&&
        !capture_id&&!wrong_mode.fingerprint&&brush_raw(engine,id,0,brush_after)&&
        !memcmp(brush_before,brush_after,sizeof brush_before),
        "pressure fingerprint refuses fixed-size replay before painting");
      if(error)api->free_string(error);error=NULL;
      capture_id=0;wrong_mode.struct_size=sizeof wrong_mode;
      CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,captured_brush,&brush,true,
        &brush_packet,pressure_facts.fingerprint,&capture_id,&wrong_mode,&error)==GLIMS_STATUS_OK&&
        capture_id&&wrong_mode.fingerprint&&!strcmp(pressure_facts.fingerprint,wrong_mode.fingerprint)&&
        had_pressure&&brush_raw(engine,id,0,brush_after)&&!memcmp(pressure_pixels,brush_after,sizeof pressure_pixels),
        "equivalent pressure dynamics reproduce captured four-plane pixels");
      if(error)api->free_string(error);error=NULL;
      if(capture_id)api->stroke_cancel_lab_layer(engine,capture_id);
      api->free_string(wrong_mode.brush_name);api->free_string(wrong_mode.brush_collection);api->free_string(wrong_mode.fingerprint);
     }
     api->free_string(pressure_facts.brush_name);api->free_string(pressure_facts.brush_collection);api->free_string(pressure_facts.fingerprint);
     brush_point.pressure=1;
     GimpBrush *native_brush=NULL;
     gboolean plain_brush=glims_lookup_brush(engine,captured_brush,&native_brush)==GLIMS_STATUS_OK&&
       native_brush&&!native_brush->priv->pixmap;
     CHECK(plain_brush,"unsupported-capture fixture has a registered mask brush");
     if(plain_brush){
      GimpTempBuf *pixmap=gimp_temp_buf_new(1,1,babl_format("R'G'B'A u8"));
      memset(gimp_temp_buf_get_data(pixmap),255,gimp_temp_buf_get_data_size(pixmap));
      native_brush->priv->pixmap=pixmap;
      GlimsStrokeCaptureFacts unsupported={.struct_size=sizeof unsupported};capture_id=0;
      CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,captured_brush,&brush,false,
        &brush_packet,NULL,&capture_id,&unsupported,&error)==GLIMS_STATUS_OK&&capture_id&&
        !unsupported.brush_name&&!unsupported.brush_collection&&!unsupported.fingerprint&&
        brush_raw(engine,id,0,brush_after)&&memcmp(brush_before,brush_after,sizeof brush_before),
        "unsupported brush still paints live but returns no recording facts");
      if(error)api->free_string(error);error=NULL;
      if(capture_id)api->stroke_cancel_lab_layer(engine,capture_id);
      capture_id=123;unsupported.struct_size=sizeof unsupported;
      CHECK(api->stroke_begin_lab_layer_with_capture_facts(engine,id,captured_brush,&brush,false,
        &brush_packet,facts.fingerprint,&capture_id,&unsupported,&error)!=GLIMS_STATUS_OK&&
        !capture_id&&!unsupported.fingerprint&&brush_raw(engine,id,0,brush_after)&&
        !memcmp(brush_before,brush_after,sizeof brush_before),
        "unsupported brush refuses guarded replay before painting");
      if(error)api->free_string(error);error=NULL;
      native_brush->priv->pixmap=NULL;gimp_temp_buf_unref(pixmap);
     }
    }
    api->free_string(facts.brush_name);api->free_string(facts.brush_collection);api->free_string(facts.fingerprint);
    api->free_string(replayed.brush_name);api->free_string(replayed.brush_collection);api->free_string(replayed.fingerprint);
   }
   CHECK(api->stroke_begin_lab_layer_pressure!=NULL,"pressure brush has its own optional API entry");
   if(api->stroke_begin_lab_layer_pressure){
    brush_id=123;invalid_brush=brush;invalid_brush.struct_size=sizeof invalid_brush-1;
    CHECK(api->stroke_begin_lab_layer_pressure(engine,id,0,&invalid_brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&brush_id==0,
          "pressure brush refuses a short captured request");if(error)api->free_string(error);error=NULL;
    brush_id=123;invalid_brush=brush;invalid_brush.uuid[0]^=0xff;
    CHECK(api->stroke_begin_lab_layer_pressure(engine,id,0,&invalid_brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&brush_id==0,
          "pressure brush refuses a stale logical identity");if(error)api->free_string(error);error=NULL;
    brush_id=123;engine->busy++;
    CHECK(api->stroke_begin_lab_layer_pressure(engine,id,0,&brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_BUSY&&brush_id==0,
          "pressure brush refuses a busy engine");engine->busy--;if(error)api->free_string(error);error=NULL;
    brush_id=123;
    CHECK(api->stroke_begin_lab_layer_pressure(engine,id,0,&brush,NULL,&brush_id,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&brush_id==0,
          "pressure brush safely refuses a null first packet");if(error)api->free_string(error);error=NULL;
    brush_id=123;
    CHECK(api->stroke_begin_lab_layer(engine,id,0,&brush,NULL,&brush_id,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&brush_id==0,
          "fixed-size brush safely refuses a null first packet");if(error)api->free_string(error);error=NULL;
    guint8 pressure_unaligned[sizeof brush+2];memset(pressure_unaligned,0xa5,sizeof pressure_unaligned);
    memcpy(pressure_unaligned+1,&brush,sizeof brush);
    brush_point.pressure=0;brush_point.time_ms=1;brush_id=0;
    CHECK(api->image_undo_info(engine,id,&brush_history_before)==GLIMS_STATUS_OK&&
          api->stroke_begin_lab_layer_pressure(engine,id,0,(const GlimsLabLayerBrushSettings*)(pressure_unaligned+1),
                                               &brush_packet,&brush_id,&error)==GLIMS_STATUS_OK&&brush_id&&
          pressure_unaligned[0]==0xa5&&pressure_unaligned[sizeof pressure_unaligned-1]==0xa5,
          "pressure brush accepts an unaligned request and zero-pressure start");
    if(error)api->free_string(error);error=NULL;
    if(brush_id){
     CHECK(brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before),
           "zero-pressure first sample leaves all four planes untouched");
     brush_point.x=2.5;brush_point.pressure=1;brush_point.time_ms=2;
     CHECK(api->stroke_continue_v2(engine,brush_id,&brush_packet,&error)==GLIMS_STATUS_OK&&
           brush_raw(engine,id,0,brush_after)&&memcmp(brush_before,brush_after,sizeof brush_before),
           "full-pressure continuation paints after a zero-pressure start");
     if(error)api->free_string(error);error=NULL;
     CHECK(api->stroke_cancel_lab_layer(engine,brush_id)==GLIMS_STATUS_OK&&
           brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before)&&
           api->image_undo_info(engine,id,&brush_history_after)==GLIMS_STATUS_OK&&
           brush_history_before.undo_count==brush_history_after.undo_count&&
           brush_history_before.redo_count==brush_history_after.redo_count,
           "cancelling a public pressure stroke restores planes and history");
    }
    brush_point.x=1.5;brush_point.pressure=1;brush_point.time_ms=1;
    brush_id=0;
    CHECK(api->stroke_begin_lab_layer_pressure(engine,id,0,&brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_OK&&brush_id,
          "full-pressure public stroke begins");if(error)api->free_string(error);error=NULL;
    if(brush_id){
     guint8 pressure_painted[4][16];
     CHECK(api->stroke_end(engine,brush_id)==GLIMS_STATUS_OK&&brush_raw(engine,id,0,pressure_painted)&&
           memcmp(brush_before,pressure_painted,sizeof brush_before)&&
           api->image_undo_info(engine,id,&brush_history_after)==GLIMS_STATUS_OK&&
           brush_history_after.undo_count==brush_history_before.undo_count+1,
           "pressure stroke commits as one Undo step");
     CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&brush_raw(engine,id,0,brush_after)&&
           !memcmp(brush_before,brush_after,sizeof brush_before),"pressure Undo restores all four planes");
     CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&brush_raw(engine,id,0,brush_after)&&
           !memcmp(pressure_painted,brush_after,sizeof pressure_painted),"pressure Redo restores all four planes");
     CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"pressure fixture restores original planes");
    }
    brush_point.pressure=0;brush_id=0;
    CHECK(api->stroke_begin_lab_layer(engine,id,0,&brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_OK&&brush_id&&
          brush_raw(engine,id,0,brush_after)&&memcmp(brush_before,brush_after,sizeof brush_before),
          "original brush entry retains fixed-size behavior at zero pressure");
    if(error)api->free_string(error);error=NULL;
    if(brush_id)CHECK(api->stroke_cancel_lab_layer(engine,brush_id)==GLIMS_STATUS_OK&&
      brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before),
      "fixed-size compatibility witness cancels cleanly");
    brush_point.pressure=1;
   }
   guint8 unaligned_brush[sizeof brush+2];memset(unaligned_brush,0xa5,sizeof unaligned_brush);memcpy(unaligned_brush+1,&brush,sizeof brush);
   brush_event_image=id;brush_projection_events=0;
   brush_id=0;GlimsStatus brush_status=api->stroke_begin_lab_layer(engine,id,0,(const GlimsLabLayerBrushSettings*)(unaligned_brush+1),&brush_packet,&brush_id,&error);
   CHECK(brush_status==GLIMS_STATUS_OK&&brush_id&&unaligned_brush[0]==0xa5&&unaligned_brush[sizeof unaligned_brush-1]==0xa5,
         "public brush accepts a captured unaligned request");if(error)api->free_string(error);error=NULL;
   if(brush_status==GLIMS_STATUS_OK&&brush_id){
    CHECK(brush_projection_events>0&&brush_projection_rect.x<=1&&brush_projection_rect.y<=1&&
          brush_projection_rect.x+brush_projection_rect.width>1&&brush_projection_rect.y+brush_projection_rect.height>1,
          "first brush dab emits bounded canvas damage containing the painted pixel");
    brush_point.x=2.5;brush_point.time_ms=2;
    CHECK(api->stroke_continue_v2(engine,brush_id,&brush_packet,&error)==GLIMS_STATUS_OK,"public brush accepts V2 continuation");
    if(error)api->free_string(error);error=NULL;
    CHECK(api->stroke_end(engine,brush_id)==GLIMS_STATUS_OK,"public brush commits");
    CHECK(brush_raw(engine,id,0,brush_after)&&memcmp(brush_before,brush_after,sizeof brush_before)&&
          brush_raw(engine,id,1,brush_other_after)&&!memcmp(brush_other,brush_other_after,sizeof brush_other),
          "public brush paints the captured root and preserves the other root");
    guint8 brush_painted[4][16];memcpy(brush_painted,brush_after,sizeof brush_painted);
    CHECK(api->image_undo_info(engine,id,&brush_history_after)==GLIMS_STATUS_OK&&
          brush_history_after.undo_count==brush_history_before.undo_count+1,"public brush makes one Undo step");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&brush_raw(engine,id,0,brush_after)&&
          !memcmp(brush_before,brush_after,sizeof brush_before),"public brush Undo restores all source planes");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&brush_raw(engine,id,0,brush_after)&&
          !memcmp(brush_painted,brush_after,sizeof brush_painted),"public brush Redo restores all planes");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"public brush fixture restores original planes");
   }
   brush_point.x=1.5;brush_point.time_ms=1;brush_id=0;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_OK&&brush_id,
         "public cancel witness begins");if(error)api->free_string(error);error=NULL;
   if(brush_id){unsigned events_before_cancel=brush_projection_events;
    CHECK(api->stroke_cancel_lab(engine,brush_id)==GLIMS_STATUS_UNSUPPORTED,
      "flat Lab cancel cannot consume a layered Lab stroke");
    CHECK(api->stroke_cancel_lab_layer(engine,brush_id)==GLIMS_STATUS_OK&&
      brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before)&&
      brush_projection_events>events_before_cancel,
      "public cancellation restores all planes and invalidates the canvas");}
   brush_id=0;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_OK&&brush_id,
         "public stale-target witness begins");if(error)api->free_string(error);error=NULL;
   if(brush_id){
    CHECK(api->layer_select(engine,id,rows[1].id)==GLIMS_STATUS_OK,"public root selection changes during a live brush");
    brush_point.time_ms=2;
    CHECK(api->stroke_continue_v2(engine,brush_id,&brush_packet,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&error,
          "public brush cancels when the selected root changes");if(error)api->free_string(error);error=NULL;
    CHECK(brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before)&&
          api->stroke_cancel_lab_layer(engine,brush_id)==GLIMS_STATUS_NOT_FOUND,
          "stale brush restores all planes and releases its handle");
    CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK,"public brush fixture restores selected root");
   }
   GlimsLabLayerBrushSettings motion_brush=brush;motion_brush.size=3;
   brush_point.x=.5;brush_point.time_ms=1;brush_id=0;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&motion_brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_OK&&brush_id,
         "reentrant continuation witness begins");if(error)api->free_string(error);error=NULL;
   if(brush_id){
    brush_retargeted=FALSE;brush_reentrant_stroke=brush_id;
    brush_update_handler=g_signal_connect(identity_storage.layers[0].planes[0],"update",G_CALLBACK(retarget_on_brush_update),NULL);
    brush_point.x=3.5;brush_point.time_ms=2;
    GlimsStatus motion_status=api->stroke_continue_v2(engine,brush_id,&brush_packet,&error);
    g_signal_handler_disconnect(identity_storage.layers[0].planes[0],brush_update_handler);
    CHECK(brush_retargeted&&brush_close_status==GLIMS_STATUS_BUSY&&brush_cancel_status==GLIMS_STATUS_BUSY&&
          brush_end_status==GLIMS_STATUS_BUSY&&brush_continue_status==GLIMS_STATUS_BUSY,
          "reentrant close, cancel, end and continuation refuse during a dab");
    CHECK(motion_status==GLIMS_STATUS_INVALID_ARGUMENT&&brush_raw(engine,id,0,brush_after)&&
          !memcmp(brush_before,brush_after,sizeof brush_before)&&
          api->stroke_cancel_lab_layer(engine,brush_id)==GLIMS_STATUS_NOT_FOUND,
          "reentrant target change cancels and restores the entire continued stroke");
    if(error)api->free_string(error);error=NULL;brush_reentrant_stroke=0;
    CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK,"reentrant continuation restores selected root");
   }
   brush_point.x=1.5;
   brush_id=0;brush_point.time_ms=1;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_OK&&brush_id,
         "public stale-target end witness begins");if(error)api->free_string(error);error=NULL;
   if(brush_id){
    CHECK(api->layer_select(engine,id,rows[1].id)==GLIMS_STATUS_OK,"public root changes before stroke end");
    CHECK(api->stroke_end(engine,brush_id)==GLIMS_STATUS_INVALID_ARGUMENT&&
          brush_raw(engine,id,0,brush_after)&&!memcmp(brush_before,brush_after,sizeof brush_before)&&
          api->stroke_cancel_lab_layer(engine,brush_id)==GLIMS_STATUS_NOT_FOUND,
          "ending a stale brush cancels and restores its target");
    CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK,"public brush root is reselected after stale end");
   }
   GlimsLabLayerBrushSettings transparent_brush=brush;transparent_brush.color.alpha=0;brush_id=0;brush_point.time_ms=1;
   unsigned events_before_transparent=brush_projection_events;
   CHECK(api->image_undo_info(engine,id,&brush_history_before)==GLIMS_STATUS_OK&&
         api->stroke_begin_lab_layer(engine,id,0,&transparent_brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_OK&&brush_id,
         "transparent public brush begins");if(error)api->free_string(error);error=NULL;
   if(brush_id)CHECK(api->stroke_end(engine,brush_id)==GLIMS_STATUS_OK&&brush_raw(engine,id,0,brush_after)&&
         !memcmp(brush_before,brush_after,sizeof brush_before)&&api->image_undo_info(engine,id,&brush_history_after)==GLIMS_STATUS_OK&&
         brush_history_before.undo_count==brush_history_after.undo_count&&brush_history_before.redo_count==brush_history_after.redo_count&&
         brush_projection_events==events_before_transparent,
         "transparent public brush preserves pixels, history and canvas damage");
   GlimsLabSelectOptions brush_selection={.struct_size=sizeof brush_selection,.operation=GLIMS_SELECT_REPLACE};
   GlimsPoint brush_points[2]={{1,1},{3,3}};
   CHECK(api->image_select_lab_shape(engine,id,GLIMS_SHAPE_RECTANGLE,brush_points,2,&brush_selection,&error)==GLIMS_STATUS_OK,
         "public brush selection fixture is active");if(error)api->free_string(error);error=NULL;
   brush_id=0;
   CHECK(api->stroke_begin_lab_layer(engine,id,0,&brush,&brush_packet,&brush_id,&error)==GLIMS_STATUS_OK&&brush_id,
         "selected public brush begins");if(error)api->free_string(error);error=NULL;
   if(brush_id){
    CHECK(api->stroke_end(engine,brush_id)==GLIMS_STATUS_OK&&brush_raw(engine,id,0,brush_after),"selected public brush commits");
    gboolean outside_same=TRUE,inside_diff=FALSE;
    for(unsigned p=0;p<4;p++)for(unsigned y=0;y<4;y++)for(unsigned x=0;x<4;x++){
      unsigned pos=y*4+x;
      if(x>=1&&x<3&&y>=1&&y<3)inside_diff|=brush_before[p][pos]!=brush_after[p][pos];
      else outside_same&=brush_before[p][pos]==brush_after[p][pos];
    }
    CHECK(inside_diff&&outside_same,"public brush respects the captured selection mask");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&brush_raw(engine,id,0,brush_after)&&
          !memcmp(brush_before,brush_after,sizeof brush_before),"Undo restores the selected brush stroke");
   }
   CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"brush fixture restores the empty selection");
   GlimsLabLayerFillSettings fill={.struct_size=sizeof fill,.root=rows[0].id,.lightness=0,.a=0,.b=0,.opacity=1};
   memcpy(fill.uuid,first_identity.uuid,16);
   GlimsLabSelectOptions fill_selection={.struct_size=sizeof fill_selection,.operation=GLIMS_SELECT_REPLACE};
   GlimsPoint fill_points[2]={{1,1},{3,3}};error=NULL;
   CHECK(api->image_select_lab_shape(engine,id,GLIMS_SHAPE_RECTANGLE,fill_points,2,&fill_selection,&error)==GLIMS_STATUS_OK,
         "public fill fixture selects part of the canvas");if(error)api->free_string(error);error=NULL;
   guint8 fill_inside_before[4]={0},fill_outside_before[4]={0},fill_inside_after[4]={0},fill_outside_after[4]={0};
   CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},fill_inside_before,4)==GLIMS_STATUS_OK&&
         api->image_render(engine,id,1,(GlimsRect){0,0,1,1},fill_outside_before,4)==GLIMS_STATUS_OK,
         "public fill fixture captures the original pixels");
   GlimsUndoInfo fill_undo_before={0},fill_undo_after={0};
   CHECK(api->image_undo_info(engine,id,&fill_undo_before)==GLIMS_STATUS_OK,"public fill captures selection history");
   GlimsLabLayerFillSettings short_fill=fill;short_fill.struct_size=sizeof short_fill-1;
   CHECK(api->image_fill_lab_layer(engine,id,&short_fill,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "public fill refuses a short request");if(error)api->free_string(error);error=NULL;
   GlimsLabLayerFillSettings zero_identity=fill;memset(zero_identity.uuid,0,16);
   CHECK(api->image_fill_lab_layer(engine,id,&zero_identity,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "public fill refuses an empty UUID");if(error)api->free_string(error);error=NULL;
   GlimsLabLayerFillSettings unselected=fill;unselected.root=rows[1].id;
   memcpy(unselected.uuid,m.entries[1].group,16);
   CHECK(api->image_fill_lab_layer(engine,id,&unselected,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "public fill refuses an unselected logical root");if(error)api->free_string(error);error=NULL;
   identity_open=glims_lookup_image(engine,id);
   identity_valid=identity_open&&glims_lab_layer_storage_read(identity_open->image,&identity_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
   if(identity_valid){
    GlimsLabLayerFillSettings hidden_fill=fill;
    hidden_fill.root=gimp_item_get_id(GIMP_ITEM(identity_storage.layers[0].planes[0]));
    CHECK(api->image_fill_lab_layer(engine,id,&hidden_fill,&error)==GLIMS_STATUS_NOT_FOUND,
          "public fill refuses a hidden scalar plane");if(error)api->free_string(error);error=NULL;
   }
   GlimsLabLayerFillSettings stale_fill=fill;stale_fill.uuid[0]^=0xff;
   CHECK(api->image_fill_lab_layer(engine,id,&stale_fill,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "public fill refuses a stale root UUID");if(error)api->free_string(error);error=NULL;
   GlimsLabLayerFillSettings invalid=fill;invalid.lightness=NAN;
   CHECK(api->image_fill_lab_layer(engine,id,&invalid,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "public fill refuses a nonfinite physical color");if(error)api->free_string(error);error=NULL;
   GlimsLabLayerFillSettings range_fill=fill;range_fill.lightness=100.5;
   CHECK(api->image_fill_lab_layer(engine,id,&range_fill,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "public fill refuses L* above 100");if(error)api->free_string(error);error=NULL;
   range_fill=fill;range_fill.a=-128.5;
   CHECK(api->image_fill_lab_layer(engine,id,&range_fill,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "public fill refuses a* below -128");if(error)api->free_string(error);error=NULL;
   range_fill=fill;range_fill.b=127.5;
   CHECK(api->image_fill_lab_layer(engine,id,&range_fill,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "public fill refuses b* above 127");if(error)api->free_string(error);error=NULL;
   range_fill=fill;range_fill.opacity=1.0001;
   CHECK(api->image_fill_lab_layer(engine,id,&range_fill,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "public fill refuses opacity above one");if(error)api->free_string(error);error=NULL;
   guint8 unaligned_fill[sizeof fill+2];memset(unaligned_fill,0xa5,sizeof unaligned_fill);memcpy(unaligned_fill+1,&fill,sizeof fill);
   request_fill_cancel=TRUE;fill_cancel_scheduled=FALSE;fill_cancelled=FALSE;
   GlimsStatus fill_status=api->image_fill_lab_layer(engine,id,(const GlimsLabLayerFillSettings*)(unaligned_fill+1),&error);
   request_fill_cancel=FALSE;
   if(fill_cancel_source){g_source_remove(fill_cancel_source);fill_cancel_source=0;}
   CHECK(fill_cancel_scheduled&&fill_cancelled&&fill_status==GLIMS_STATUS_CANCELLED,
         "public fill honors cancellation after staging");if(error)api->free_string(error);error=NULL;
   CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},fill_inside_after,4)==GLIMS_STATUS_OK&&
         !memcmp(fill_inside_before,fill_inside_after,4)&&api->image_undo_info(engine,id,&fill_undo_after)==GLIMS_STATUS_OK&&
         fill_undo_before.undo_count==fill_undo_after.undo_count&&fill_undo_before.redo_count==fill_undo_after.redo_count,
         "cancelled and refused public fills preserve pixels and history");
   fill_status=api->image_fill_lab_layer(engine,id,(const GlimsLabLayerFillSettings*)(unaligned_fill+1),&error);
   CHECK(fill_status==GLIMS_STATUS_OK&&unaligned_fill[0]==0xa5&&unaligned_fill[sizeof unaligned_fill-1]==0xa5,
         "public fill accepts an unaligned captured request");if(error)api->free_string(error);error=NULL;
   if(fill_status==GLIMS_STATUS_OK){
    CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},fill_inside_after,4)==GLIMS_STATUS_OK&&
          api->image_render(engine,id,1,(GlimsRect){0,0,1,1},fill_outside_after,4)==GLIMS_STATUS_OK&&
          memcmp(fill_inside_before,fill_inside_after,4)&&!memcmp(fill_outside_before,fill_outside_after,4),
          "public fill changes only the selected pixels");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&
          api->image_render(engine,id,1,(GlimsRect){1,1,1,1},fill_inside_after,4)==GLIMS_STATUS_OK&&
          !memcmp(fill_inside_before,fill_inside_after,4),"one Undo restores the public four-plane fill");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&
          api->image_render(engine,id,1,(GlimsRect){1,1,1,1},fill_inside_after,4)==GLIMS_STATUS_OK&&
          memcmp(fill_inside_before,fill_inside_after,4),"Redo restores the public fill");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"public fill undo restores the original before no-op");
    GlimsLabLayerFillSettings zero_opacity=fill;zero_opacity.opacity=0;
    CHECK(api->image_undo_info(engine,id,&fill_undo_before)==GLIMS_STATUS_OK&&
          api->image_fill_lab_layer(engine,id,&zero_opacity,&error)==GLIMS_STATUS_OK&&
          api->image_undo_info(engine,id,&fill_undo_after)==GLIMS_STATUS_OK&&
          fill_undo_before.undo_count==fill_undo_after.undo_count&&fill_undo_before.redo_count==fill_undo_after.redo_count,
          "zero-opacity public fill preserves Undo and Redo");if(error)api->free_string(error);error=NULL;
    GlimsOpenImage *fill_open=glims_lookup_image(engine,id);GlimsLabLayerStorage fill_storage;
    gboolean fill_valid=fill_open&&glims_lab_layer_storage_read(fill_open->image,&fill_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
    CHECK(fill_valid,"public fill preserves the layered Lab carrier");
    if(fill_valid){
     guint8 other_sample=0;GimpDrawable *other_plane=GIMP_DRAWABLE(fill_storage.layers[1].planes[0]);
     gegl_buffer_get(gimp_drawable_get_buffer(other_plane),GEGL_RECTANGLE(1,1,1,1),1,
                     gimp_drawable_get_format(other_plane),&other_sample,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
     CHECK(other_sample==255,"public fill leaves the other logical root unchanged");
    }
   }
   CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"public fill fixture restores the empty selection");
   GlimsLabLayerColorFillSettings color_fill={.struct_size=sizeof color_fill,.root=rows[0].id,
     .color={1,0,0,1},.opacity=1};memcpy(color_fill.uuid,first_identity.uuid,16);
   guint8 color_request[sizeof color_fill+2];memset(color_request,0xa5,sizeof color_request);
   memcpy(color_request+1,&color_fill,sizeof color_fill);
   GlimsStatus color_status=api->image_fill_lab_layer_srgb(engine,id,(const GlimsLabLayerColorFillSettings*)(color_request+1),&error);
   CHECK(color_status==GLIMS_STATUS_OK&&color_request[0]==0xa5&&color_request[sizeof color_request-1]==0xa5,
         "unaligned sRGB fill request succeeds");if(error)api->free_string(error);error=NULL;
   if(color_status==GLIMS_STATUS_OK){
    guint8 red[4]={0};
    CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},red,4)==GLIMS_STATUS_OK&&
          red[0]>245&&red[1]<20&&red[2]<20&&red[3]==255,"sRGB red fills the logical Lab root as red");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"one Undo restores the sRGB fill");
   }
   cmsHPROFILE color_srgb=cmsCreate_sRGBProfile(),color_lab=cmsCreateLab4Profile(NULL);
   cmsHTRANSFORM color_oracle=color_srgb&&color_lab?cmsCreateTransform(color_srgb,TYPE_RGB_DBL,color_lab,TYPE_Lab_DBL,INTENT_RELATIVE_COLORIMETRIC,0):NULL;
   double red_rgb[3]={1,0,0},red_lab[3]={0};if(color_oracle)cmsDoTransform(color_oracle,red_rgb,red_lab,1);
   CHECK(color_oracle!=NULL,"independent sRGB-to-Lab oracle creates");
   color_fill.color=(GlimsColor){.5,.5,.5,1};
   color_status=api->image_fill_lab_layer_srgb(engine,id,&color_fill,&error);
   CHECK(color_status==GLIMS_STATUS_OK,"mid-gray sRGB fill succeeds");if(error)api->free_string(error);error=NULL;
   if(color_status==GLIMS_STATUS_OK&&color_oracle){
    double gray_rgb[3]={.5,.5,.5},gray_lab[3]={0};cmsDoTransform(color_oracle,gray_rgb,gray_lab,1);
    GlimsOpenImage *gray_open=glims_lookup_image(engine,id);GlimsLabLayerStorage gray_storage;
    gboolean valid_gray=gray_open&&glims_lab_layer_storage_read(gray_open->image,&gray_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
    CHECK(valid_gray,"mid-gray fill retains the carrier");
    if(valid_gray){
     guint8 sample=0;GimpDrawable *plane=GIMP_DRAWABLE(gray_storage.layers[0].planes[0]);
     gegl_buffer_get(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(1,1,1,1),1,
                     gimp_drawable_get_format(plane),&sample,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
     CHECK(abs((int)sample-(int)floor(gray_lab[0]*255/100+.5))<=1,
           "sRGB mid-gray uses the correct transfer curve");
    }
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"Undo restores the mid-gray fill");
   }
   color_fill.color=(GlimsColor){1,0,0,1};
   color_fill.color.alpha=.5;color_fill.opacity=.5;
   color_status=api->image_fill_lab_layer_srgb(engine,id,&color_fill,&error);
   CHECK(color_status==GLIMS_STATUS_OK,"sRGB fill accepts separate color alpha and opacity");if(error)api->free_string(error);error=NULL;
   if(color_status==GLIMS_STATUS_OK&&color_oracle){
    GlimsOpenImage *color_open=glims_lookup_image(engine,id);GlimsLabLayerStorage color_storage;
    gboolean valid_color=color_open&&glims_lab_layer_storage_read(color_open->image,&color_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
    CHECK(valid_color,"sRGB fill preserves the carrier");
    if(valid_color){
     double target[3]={red_lab[0]*255/100,red_lab[1]+128,red_lab[2]+128};
     for(guint role=0;role<3;role++){
      guint8 sample=0;GimpDrawable *plane=GIMP_DRAWABLE(color_storage.layers[0].planes[role]);
      gegl_buffer_get(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(1,1,1,1),1,
                      gimp_drawable_get_format(plane),&sample,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      int expected=(int)floor(128+.25*(target[role]-128)+.5);
      CHECK(abs((int)sample-expected)<=1,"sRGB alpha and opacity multiply in physical Lab");
     }
    }
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"one Undo restores the translucent sRGB fill");
   }
   if(color_oracle)cmsDeleteTransform(color_oracle);if(color_srgb)cmsCloseProfile(color_srgb);if(color_lab)cmsCloseProfile(color_lab);
   GlimsUndoInfo color_before={0},color_after={0};color_fill.color.alpha=0;
   CHECK(api->image_undo_info(engine,id,&color_before)==GLIMS_STATUS_OK&&
         api->image_fill_lab_layer_srgb(engine,id,&color_fill,&error)==GLIMS_STATUS_OK&&
         api->image_undo_info(engine,id,&color_after)==GLIMS_STATUS_OK&&color_before.undo_count==color_after.undo_count&&
         color_before.redo_count==color_after.redo_count,"transparent sRGB fill leaves Undo and Redo unchanged");
   if(error)api->free_string(error);error=NULL;
   color_fill.color.red=NAN;
   CHECK(api->image_fill_lab_layer_srgb(engine,id,&color_fill,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "sRGB fill rejects nonfinite components");if(error)api->free_string(error);error=NULL;
   color_fill.color.red=1.01;
   CHECK(api->image_fill_lab_layer_srgb(engine,id,&color_fill,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "sRGB fill rejects out-of-range components");if(error)api->free_string(error);error=NULL;
   color_fill.color.red=1;color_fill.uuid[0]^=0xff;
   CHECK(api->image_fill_lab_layer_srgb(engine,id,&color_fill,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
         "sRGB fill refuses a stale root UUID");if(error)api->free_string(error);error=NULL;
   GlimsItemID duplicate=0;error=NULL;
   GlimsStatus duplicated=api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_DUPLICATE,&duplicate,&error);
   CHECK(duplicated==GLIMS_STATUS_OK&&duplicate!=0,"public command duplicates a logical Lab layer");
   if(error)api->free_string(error);error=NULL;
   if(duplicated==GLIMS_STATUS_OK&&duplicate){
    GlimsLayerInfo duplicated_rows[8];int32_t duplicated_count=0;
    CHECK(api->image_layers(engine,id,duplicated_rows,8,&duplicated_count)==GLIMS_STATUS_OK&&
          duplicated_count==3&&duplicated_rows[0].id==duplicate&&duplicated_rows[1].id==rows[0].id,
          "duplicate is a logical root immediately above its source");
    GlimsLabLayerIdentity duplicate_identity={.struct_size=sizeof duplicate_identity};
    CHECK(api->image_lab_layer_identity(engine,id,duplicate,&duplicate_identity)==GLIMS_STATUS_OK&&
          memcmp(first_identity.uuid,duplicate_identity.uuid,16),"duplicate has a new root UUID");
    GlimsOpenImage *dup_open=glims_lookup_image(engine,id);GlimsLabLayerStorage dup_storage;
    gboolean dup_valid=dup_open&&glims_lab_layer_storage_read(dup_open->image,&dup_storage)==GLIMS_LAB_LAYER_STORAGE_VALID&&
                       dup_storage.map.count==3;
    CHECK(dup_valid,"duplicated carrier has valid distinct physical identities");
    if(dup_valid){
     for(guint role=0;role<4;role++){
      GimpDrawable *copy_plane=GIMP_DRAWABLE(dup_storage.layers[0].planes[role]);
      GimpDrawable *source_plane=GIMP_DRAWABLE(dup_storage.layers[1].planes[role]);
      guint8 copy_samples[16],source_samples[16];
      gboolean one_byte=babl_format_get_bytes_per_pixel(gimp_drawable_get_format(copy_plane))==1&&
                        babl_format_get_bytes_per_pixel(gimp_drawable_get_format(source_plane))==1;
      CHECK(one_byte,"logical duplicate planes retain one-byte samples");
      if(!one_byte)continue;
      gegl_buffer_get(gimp_drawable_get_buffer(copy_plane),GEGL_RECTANGLE(0,0,4,4),1,
                      gimp_drawable_get_format(copy_plane),copy_samples,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      gegl_buffer_get(gimp_drawable_get_buffer(source_plane),GEGL_RECTANGLE(0,0,4,4),1,
                      gimp_drawable_get_format(source_plane),source_samples,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      CHECK(!memcmp(copy_samples,source_samples,sizeof copy_samples),"logical copy preserves its scalar samples");
     }
    }
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&
          api->image_layers(engine,id,duplicated_rows,8,&duplicated_count)==GLIMS_STATUS_OK&&duplicated_count==2,
          "one Undo removes the logical copy");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&
          api->image_layers(engine,id,duplicated_rows,8,&duplicated_count)==GLIMS_STATUS_OK&&
          duplicated_count==3&&duplicated_rows[0].id==duplicate,"Redo restores the same logical copy");
    GlimsLabLayerIdentity redone_identity={.struct_size=sizeof redone_identity};
    CHECK(api->image_lab_layer_identity(engine,id,duplicate,&redone_identity)==GLIMS_STATUS_OK&&
          !memcmp(duplicate_identity.uuid,redone_identity.uuid,16),"Redo retains the duplicate root UUID");
    gchar *dup_path=g_build_filename((const gchar*)work,"layered-lab-duplicate.xcf",NULL);
    GlimsStatus dup_saved=api->image_save_copy(engine,id,dup_path,&error);
    CHECK(dup_saved==GLIMS_STATUS_OK,"duplicated layered Lab saves");if(error)api->free_string(error);error=NULL;
    if(dup_saved==GLIMS_STATUS_OK){
     GlimsImageID dup_copy=0;GlimsStatus dup_opened=api->image_open(engine,dup_path,&dup_copy,&error);
     CHECK(dup_opened==GLIMS_STATUS_OK&&dup_copy,"duplicated layered Lab reopens");if(error)api->free_string(error);error=NULL;
     if(dup_opened==GLIMS_STATUS_OK&&dup_copy){
      CHECK(api->image_layers(engine,dup_copy,duplicated_rows,8,&duplicated_count)==GLIMS_STATUS_OK&&duplicated_count==3,
            "saved XCF preserves all logical layers");
      CHECK(api->image_close(engine,dup_copy)==GLIMS_STATUS_OK,"duplicated copy closes");
     }
    }
    g_free(dup_path);
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"duplicate test restores the original fixture");
   }
   guint8 old_pixel[4]={0},new_pixel[4]={0};
   CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},old_pixel,4)==GLIMS_STATUS_OK,
         "render before creating a logical layer succeeds");
   GlimsItemID new_layer=0;error=NULL;
   GlimsStatus made=api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_NEW,&new_layer,&error);
   CHECK(made==GLIMS_STATUS_OK&&new_layer,"public command creates a logical Lab layer");
   if(error)api->free_string(error);error=NULL;
   if(made==GLIMS_STATUS_OK&&new_layer){
    GlimsLayerInfo created_rows[8];int32_t n=0;
    CHECK(api->image_layers(engine,id,created_rows,8,&n)==GLIMS_STATUS_OK&&n==3&&
          created_rows[0].id==new_layer&&created_rows[1].id==rows[0].id,
          "new logical layer appears above the captured root");
    CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},new_pixel,4)==GLIMS_STATUS_OK&&
          !memcmp(old_pixel,new_pixel,sizeof old_pixel),"new transparent layer does not change the composite");
    GlimsOpenImage *created_open=glims_lookup_image(engine,id);GlimsLabLayerStorage created_storage;
    gboolean created_valid=created_open&&glims_lab_layer_storage_read(created_open->image,&created_storage)==GLIMS_LAB_LAYER_STORAGE_VALID&&
                           created_storage.map.count==3;
    CHECK(created_valid,"new logical layer has a valid physical mapping");
    if(created_valid)for(guint role=0;role<4;role++){
     GimpDrawable *plane=GIMP_DRAWABLE(created_storage.layers[0].planes[role]);guint8 samples[16];
     gegl_buffer_get(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,4,4),1,
                     gimp_drawable_get_format(plane),samples,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
     guint8 expected=role==0?255:role==3?0:128;gboolean same=TRUE;
     for(guint px=0;px<16;px++)if(samples[px]!=expected)same=FALSE;
     CHECK(same,"new layer has the expected transparent Lab plane samples");
    }
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&
          api->image_layers(engine,id,created_rows,8,&n)==GLIMS_STATUS_OK&&n==2,
          "one Undo removes the new layer");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&
          api->image_layers(engine,id,created_rows,8,&n)==GLIMS_STATUS_OK&&n==3&&created_rows[0].id==new_layer,
          "Redo restores the same logical layer");
    gchar *new_path=g_build_filename((const gchar*)work,"layered-lab-new.xcf",NULL);
    GlimsStatus new_saved=api->image_save_copy(engine,id,new_path,&error);
    CHECK(new_saved==GLIMS_STATUS_OK,"new logical layer saves");if(error)api->free_string(error);error=NULL;
    if(new_saved==GLIMS_STATUS_OK){
     GlimsImageID new_copy=0;GlimsStatus new_opened=api->image_open(engine,new_path,&new_copy,&error);
     CHECK(new_opened==GLIMS_STATUS_OK&&new_copy,"new logical layer reopens");if(error)api->free_string(error);error=NULL;
     if(new_opened==GLIMS_STATUS_OK&&new_copy){
      CHECK(api->image_layers(engine,new_copy,created_rows,8,&n)==GLIMS_STATUS_OK&&n==3,
            "saved XCF preserves the new logical layer");
      CHECK(api->image_close(engine,new_copy)==GLIMS_STATUS_OK,"new-layer copy closes");
     }
    }
    g_free(new_path);
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"creation test restores the original fixture");
   }
   error=NULL;
   GlimsStatus cleared=api->image_select_layers(engine,id,NULL,0,&error);
   CHECK(cleared==GLIMS_STATUS_OK,"logical selection can be cleared");
   if(error)api->free_string(error);error=NULL;
   if(cleared==GLIMS_STATUS_OK){
    GlimsItemID empty_new=0;GlimsStatus empty_made=api->layer_command(engine,id,0,GLIMS_LAYER_NEW,&empty_new,&error);
    CHECK(empty_made==GLIMS_STATUS_OK&&empty_new,"creation without selection succeeds");
    if(error)api->free_string(error);error=NULL;
    if(empty_made==GLIMS_STATUS_OK&&empty_new){
     GlimsLayerInfo empty_rows[8];int32_t n=0;GlimsItemID selected[8]={0};int32_t selected_count=0;
     CHECK(api->image_layers(engine,id,empty_rows,8,&n)==GLIMS_STATUS_OK&&n==3&&empty_rows[0].id==empty_new,
           "creation without selection inserts at the top");
     CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&
           api->image_selected_layers(engine,id,selected,8,&selected_count)==GLIMS_STATUS_OK&&selected_count==0,
           "Undo restores an empty layer selection");
     CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&
           api->image_selected_layers(engine,id,selected,8,&selected_count)==GLIMS_STATUS_OK&&
           selected_count==1&&selected[0]==empty_new,"Redo selects the same created layer");
     CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"empty-selection test removes the new layer");
    }
    CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK,"original logical selection restored");
   }
   GlimsItemID stale=123;error=NULL;
   CHECK(api->layer_command(engine,id,2147483647,GLIMS_LAYER_NEW,&stale,&error)==GLIMS_STATUS_NOT_FOUND&&stale==0,
         "creation with a stale explicit anchor is refused");
   if(error)api->free_string(error);error=NULL;
   guint8 order_before[4]={0},order_after[4]={0};
   CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},order_before,4)==GLIMS_STATUS_OK,
         "logical composite renders before reorder");
   GlimsUndoInfo before_edge={0},after_edge={0};
   CHECK(api->image_undo_info(engine,id,&before_edge)==GLIMS_STATUS_OK&&
         api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_TO_TOP,NULL,&error)==GLIMS_STATUS_OK&&
         api->image_undo_info(engine,id,&after_edge)==GLIMS_STATUS_OK&&
         before_edge.undo_count==after_edge.undo_count&&before_edge.redo_count==after_edge.redo_count,
         "moving an already-top layer to top is a history-preserving no-op");
   if(error)api->free_string(error);error=NULL;
   GlimsStatus lowered=api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_LOWER,NULL,&error);
   CHECK(lowered==GLIMS_STATUS_OK,"public command lowers one logical Lab layer");
   if(error)api->free_string(error);error=NULL;
   if(lowered==GLIMS_STATUS_OK){
    GlimsLayerInfo ordered[8];int32_t n=0;
    CHECK(api->image_layers(engine,id,ordered,8,&n)==GLIMS_STATUS_OK&&n==2&&ordered[0].id==rows[1].id&&ordered[1].id==rows[0].id,
          "lowering swaps logical roots without exposing scalar planes");
    GlimsLabLayerIdentity reordered_identity={.struct_size=sizeof reordered_identity};
    CHECK(api->image_lab_layer_identity(engine,id,rows[0].id,&reordered_identity)==GLIMS_STATUS_OK&&
          !memcmp(reordered_identity.uuid,first_identity.uuid,16),"root UUID remains stable across reorder");
    CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},order_after,4)==GLIMS_STATUS_OK&&
          order_after[0]>order_before[0]+20,"reorder changes the visible composite");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&api->image_layers(engine,id,ordered,8,&n)==GLIMS_STATUS_OK&&
          n==2&&ordered[0].id==rows[0].id,"Undo restores the original logical order");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&api->image_layers(engine,id,ordered,8,&n)==GLIMS_STATUS_OK&&
          n==2&&ordered[0].id==rows[1].id,"Redo restores the reordered roots");
    gchar *ordered_path=g_build_filename((const gchar*)work,"layered-lab-reordered.xcf",NULL);
    GlimsStatus saved_order=api->image_save_copy(engine,id,ordered_path,&error);
    CHECK(saved_order==GLIMS_STATUS_OK,"reordered logical layers save");if(error)api->free_string(error);error=NULL;
    if(saved_order==GLIMS_STATUS_OK){
     GlimsImageID reordered_copy=0;GlimsStatus opened_order=api->image_open(engine,ordered_path,&reordered_copy,&error);
     CHECK(opened_order==GLIMS_STATUS_OK&&reordered_copy,"reordered logical XCF reopens");if(error)api->free_string(error);error=NULL;
     if(opened_order==GLIMS_STATUS_OK&&reordered_copy){
      guint8 reopened_pixel[4]={0};
      GlimsLayerInfo reopened_rows[8];int32_t reopened_count=0;
      GlimsLabLayerIdentity reopened_identity={.struct_size=sizeof reopened_identity};
      CHECK(api->image_layers(engine,reordered_copy,reopened_rows,8,&reopened_count)==GLIMS_STATUS_OK&&
            reopened_count==2&&api->image_lab_layer_identity(engine,reordered_copy,reopened_rows[1].id,&reopened_identity)==GLIMS_STATUS_OK&&
            !memcmp(first_identity.uuid,reopened_identity.uuid,16),"root UUID survives reorder, save and reopen");
      CHECK(api->image_render(engine,reordered_copy,1,(GlimsRect){1,1,1,1},reopened_pixel,4)==GLIMS_STATUS_OK&&
            !memcmp(reopened_pixel,order_after,4),"saved XCF retains reordered composite");
      CHECK(api->image_close(engine,reordered_copy)==GLIMS_STATUS_OK,"reordered copy closes");
     }
    }
    g_free(ordered_path);
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"reorder test restores the original layer order");
    CHECK(api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_TO_BOTTOM,NULL,&error)==GLIMS_STATUS_OK&&
          api->image_layers(engine,id,ordered,8,&n)==GLIMS_STATUS_OK&&n==2&&ordered[1].id==rows[0].id,
          "send to bottom moves the logical root");if(error)api->free_string(error);error=NULL;
    CHECK(api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_RAISE,NULL,&error)==GLIMS_STATUS_OK&&
          api->image_layers(engine,id,ordered,8,&n)==GLIMS_STATUS_OK&&n==2&&ordered[0].id==rows[0].id,
          "raise moves the logical root forward");if(error)api->free_string(error);error=NULL;
    CHECK(api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_TO_BOTTOM,NULL,&error)==GLIMS_STATUS_OK&&
          api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_TO_TOP,NULL,&error)==GLIMS_STATUS_OK&&
          api->image_layers(engine,id,ordered,8,&n)==GLIMS_STATUS_OK&&n==2&&ordered[0].id==rows[0].id,
          "bring to front restores the logical root at the top");if(error)api->free_string(error);error=NULL;
   }
   GlimsItemID implicit_copy=0;error=NULL;
   GlimsStatus implicit_status=api->layer_command(engine,id,0,GLIMS_LAYER_DUPLICATE,&implicit_copy,&error);
   CHECK(implicit_status==GLIMS_STATUS_OK&&implicit_copy,"implicit single-selection duplication succeeds");
   if(error)api->free_string(error);error=NULL;
   if(implicit_status==GLIMS_STATUS_OK&&implicit_copy){
    GlimsItemID selected[8]={0};int32_t n=0;
    CHECK(api->image_selected_layers(engine,id,selected,8,&n)==GLIMS_STATUS_OK&&n==1&&selected[0]==implicit_copy,
          "implicit duplication selects its logical copy");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"implicit duplicate is undone");
   }
   GlimsLayerChange rename={.struct_size=sizeof rename,.properties=GLIMS_LAYER_NAME,.name="Retouched Lab"};
   error=NULL;GlimsStatus renamed=api->layer_change(engine,id,rows[0].id,&rename,&error);
   CHECK(renamed==GLIMS_STATUS_OK,"logical Lab layer can be renamed");if(error)api->free_string(error);error=NULL;
   if(renamed==GLIMS_STATUS_OK){
    GlimsLayerInfo named[8];int32_t named_count=0;
    CHECK(api->image_layers(engine,id,named,8,&named_count)==GLIMS_STATUS_OK&&named_count==2&&
          !strcmp(named[0].name,"Retouched Lab"),"renamed logical layer is visible to clients");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&api->image_layers(engine,id,named,8,&named_count)==GLIMS_STATUS_OK&&
          !strcmp(named[0].name,rows[0].name),"undo restores logical layer name");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&api->image_layers(engine,id,named,8,&named_count)==GLIMS_STATUS_OK&&
          !strcmp(named[0].name,"Retouched Lab"),"redo restores renamed logical layer");
    gchar *renamed_path=g_build_filename((const gchar*)work,"layered-lab-renamed.xcf",NULL);
    GlimsStatus name_saved=api->image_save_copy(engine,id,renamed_path,&error);
    CHECK(name_saved==GLIMS_STATUS_OK,"renamed layered Lab saves");if(error)api->free_string(error);error=NULL;
    if(name_saved==GLIMS_STATUS_OK){
     GlimsImageID name_copy=0;GlimsStatus name_opened=api->image_open(engine,renamed_path,&name_copy,&error);
     CHECK(name_opened==GLIMS_STATUS_OK&&name_copy,"renamed layered Lab reopens");if(error)api->free_string(error);error=NULL;
     if(name_opened==GLIMS_STATUS_OK&&name_copy){
      CHECK(api->image_layers(engine,name_copy,named,8,&named_count)==GLIMS_STATUS_OK&&named_count==2&&
            !strcmp(named[0].name,"Retouched Lab"),"XCF preserves logical layer name");
      CHECK(api->image_close(engine,name_copy)==GLIMS_STATUS_OK,"renamed copy closes");
     }
    }
    g_free(renamed_path);
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"original logical layer name restored");
   }
   int32_t initial_count=0;GlimsItemID initial[8]={0};
   CHECK(api->image_selected_layers(engine,id,initial,8,&initial_count)==GLIMS_STATUS_OK&&
         initial_count==1&&initial[0]==rows[0].id,
         "private XCF selection is normalized to its logical root");
   int32_t item_count=0;GlimsItemID items[8]={0};
   CHECK(api->image_selected_items(engine,id,GLIMS_ITEM_SET_LAYER,items,8,&item_count)==GLIMS_STATUS_OK&&
         item_count==1&&items[0]==rows[0].id,
         "generic selected-items query exposes only the logical root");
   CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK,"selecting a logical root succeeds");
   GlimsItemID both_roots[]={rows[0].id,rows[1].id};error=NULL;
   CHECK(api->image_select_layers(engine,id,both_roots,2,&error)==GLIMS_STATUS_OK,
         "two logical roots can be selected");
   if(error)api->free_string(error);error=NULL;
   GlimsItemID ambiguous=123;
   CHECK(api->layer_command(engine,id,0,GLIMS_LAYER_DUPLICATE,&ambiguous,&error)==GLIMS_STATUS_UNSUPPORTED&&ambiguous==0,
         "implicit duplication refuses an ambiguous multi-selection");
   if(error)api->free_string(error);error=NULL;
   ambiguous=123;
   CHECK(api->layer_command(engine,id,0,GLIMS_LAYER_NEW,&ambiguous,&error)==GLIMS_STATUS_UNSUPPORTED&&ambiguous==0,
         "implicit creation refuses an ambiguous multi-selection");
   if(error)api->free_string(error);error=NULL;
   ambiguous=123;
   CHECK(api->layer_command(engine,id,0,GLIMS_LAYER_DELETE,&ambiguous,&error)==GLIMS_STATUS_UNSUPPORTED&&ambiguous==0,
         "implicit deletion refuses an ambiguous multi-selection");
   if(error)api->free_string(error);error=NULL;
   CHECK(api->layer_command(engine,id,0,GLIMS_LAYER_LOWER,NULL,&error)==GLIMS_STATUS_UNSUPPORTED,
         "implicit reorder refuses an ambiguous multi-selection");
   if(error)api->free_string(error);error=NULL;
   CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK,"single logical selection restored");
   GlimsLayerChange visibility={.struct_size=sizeof visibility,.properties=GLIMS_LAYER_VISIBLE,.visible=FALSE};
   error=NULL;GlimsStatus changed=api->layer_change(engine,id,rows[0].id,&visibility,&error);
   CHECK(changed==GLIMS_STATUS_OK,"logical Lab layer visibility can be edited");
   if(error)api->free_string(error);error=NULL;
   if(changed==GLIMS_STATUS_OK){
    GlimsLayerInfo after_change[8];int32_t n=0;
    CHECK(api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&n==2&&!after_change[0].visible,
          "visibility edit updates the logical root");
    guint8 visible_pixel[4]={0};
    CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},visible_pixel,4)==GLIMS_STATUS_OK&&visible_pixel[0]>=250&&visible_pixel[3]==255,
          "visibility edit reveals the white lower layer");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"visibility change can be undone");
    CHECK(api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&n==2&&after_change[0].visible,
          "undo restores logical visibility");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK,"visibility change can be redone");
    CHECK(api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&n==2&&!after_change[0].visible,
          "redo restores the visibility edit");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"fixture visibility restored");
    GlimsLayerChange combined={.struct_size=sizeof combined,.properties=GLIMS_LAYER_VISIBLE|GLIMS_LAYER_OPACITY,.visible=FALSE,.opacity=.5};
    error=NULL;GlimsStatus both=api->layer_change(engine,id,rows[0].id,&combined,&error);
    CHECK(both==GLIMS_STATUS_OK,"visibility and opacity can change together");if(error)api->free_string(error);
    if(both==GLIMS_STATUS_OK){
     CHECK(api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&!after_change[0].visible&&fabs(after_change[0].opacity-.5)<1e-6,
           "combined layer properties are applied");
     CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&
           after_change[0].visible&&fabs(after_change[0].opacity-1)<1e-6,
           "one undo restores both layer properties");
    }
    GlimsLayerChange opacity={.struct_size=sizeof opacity,.properties=GLIMS_LAYER_OPACITY,.opacity=.5};
    error=NULL;GlimsStatus adjusted=api->layer_change(engine,id,rows[0].id,&opacity,&error);
    CHECK(adjusted==GLIMS_STATUS_OK,"logical Lab layer opacity can be edited");if(error)api->free_string(error);
    if(adjusted==GLIMS_STATUS_OK){
     guint8 blended[4]={0};
     CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},blended,4)==GLIMS_STATUS_OK&&blended[0]>180&&blended[0]<250&&blended[3]==255,
           "opacity edit changes the composite while retaining opaque output");
     gchar *property_path=g_build_filename((const gchar*)work,"layered-lab-properties.xcf",NULL);error=NULL;
     GlimsStatus persisted=api->image_save_copy(engine,id,property_path,&error);
     CHECK(persisted==GLIMS_STATUS_OK,"edited Lab layer properties save as XCF");if(error)api->free_string(error);
     if(persisted==GLIMS_STATUS_OK){
      GlimsImageID reopened=0;error=NULL;GlimsStatus opened=api->image_open(engine,property_path,&reopened,&error);
      CHECK(opened==GLIMS_STATUS_OK&&reopened,"edited Lab layer properties reopen");if(error)api->free_string(error);
      if(opened==GLIMS_STATUS_OK&&reopened){
       GlimsLayerInfo persisted_rows[8];int32_t persisted_count=0;
       CHECK(api->image_layers(engine,reopened,persisted_rows,8,&persisted_count)==GLIMS_STATUS_OK&&persisted_count==2&&
             persisted_rows[0].visible&&fabs(persisted_rows[0].opacity-.5)<1e-6,
             "XCF retains edited opacity and visibility");
       GlimsOpenImage *reopened_image=glims_lookup_image(engine,reopened);GlimsLabLayerStorage persisted_storage;
       gboolean persisted_valid=reopened_image&&glims_lab_layer_storage_read(reopened_image->image,&persisted_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
       CHECK(persisted_valid&&!memcmp(&persisted_storage.map,&m,sizeof m),"edited XCF retains the Lab identity map");
       if(persisted_valid)for(guint li=0;li<2;li++)for(guint role=0;role<4;role++){
        GimpDrawable *plane=GIMP_DRAWABLE(persisted_storage.layers[li].planes[role]);guint8 raw[16];
        gegl_buffer_get(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,4,4),1,gimp_drawable_get_format(plane),raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
        guint8 expected=role==3?255:role==0?(li?255:128):128;gboolean matches=TRUE;
        for(guint px=0;px<16;px++)if(raw[px]!=expected)matches=FALSE;
        CHECK(matches,"edited XCF preserves scalar samples");
       }
       CHECK(api->image_close(engine,reopened)==GLIMS_STATUS_OK,"edited XCF copy closes");
      }
     }
     g_free(property_path);
     CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"opacity edit can be undone");
    }
   }
   GlimsOpenImage *open=glims_lookup_image(engine,id);GlimsLabLayerStorage current;
   gboolean intact=open&&glims_lab_layer_storage_read(open->image,&current)==GLIMS_LAB_LAYER_STORAGE_VALID;
   CHECK(intact,"adopted storage remains strictly valid");
   if(intact){
    GlimsItemID hidden=gimp_item_get_id(GIMP_ITEM(current.layers[0].planes[0]));
    GlimsUndoInfo undo_before={0},undo_after={0};
    CHECK(api->image_undo_info(engine,id,&undo_before)==GLIMS_STATUS_OK,"history captured before invalid property edits");
    GlimsItemID hidden_copy=123;error=NULL;
    CHECK(api->layer_command(engine,id,hidden,GLIMS_LAYER_DUPLICATE,&hidden_copy,&error)==GLIMS_STATUS_UNSUPPORTED&&hidden_copy==0,
          "a private scalar plane cannot be duplicated through the public layer command");
    if(error)api->free_string(error);error=NULL;
    hidden_copy=123;
    CHECK(api->layer_command(engine,id,hidden,GLIMS_LAYER_NEW,&hidden_copy,&error)==GLIMS_STATUS_UNSUPPORTED&&hidden_copy==0,
          "a private scalar plane cannot anchor a public layer creation");
    if(error)api->free_string(error);error=NULL;
    hidden_copy=123;
    CHECK(api->layer_command(engine,id,hidden,GLIMS_LAYER_DELETE,&hidden_copy,&error)==GLIMS_STATUS_UNSUPPORTED&&hidden_copy==0,
          "a private scalar plane cannot be deleted through the public layer command");
    if(error)api->free_string(error);error=NULL;
    CHECK(api->layer_command(engine,id,hidden,GLIMS_LAYER_LOWER,NULL,&error)==GLIMS_STATUS_UNSUPPORTED,
          "a private scalar plane cannot be reordered through the public layer command");
    if(error)api->free_string(error);error=NULL;
    GimpLayer *locked_root=current.layers[0].group;GimpItem *locked_item=GIMP_ITEM(locked_root);
    gboolean old_visible=gimp_item_get_visible(locked_item);gdouble old_opacity=gimp_layer_get_opacity(locked_root);
    gimp_item_set_lock_visibility(locked_item,TRUE,FALSE);
    GlimsLayerChange locked={.struct_size=sizeof locked,.properties=GLIMS_LAYER_VISIBLE|GLIMS_LAYER_OPACITY,
                             .visible=!old_visible,.opacity=.25};error=NULL;
    GlimsStatus locked_status=api->layer_change(engine,id,gimp_item_get_id(locked_item),&locked,&error);
    gimp_item_set_lock_visibility(locked_item,FALSE,FALSE);
    CHECK(locked_status==GLIMS_STATUS_UNSUPPORTED,"a locked logical root refuses a combined property edit");
    if(error)api->free_string(error);error=NULL;
    CHECK(gimp_item_get_visible(locked_item)==old_visible && gimp_layer_get_opacity(locked_root)==old_opacity,
          "refused locked-root edit leaves visibility and opacity unchanged");
    CHECK(api->layer_select(engine,id,hidden)!=GLIMS_STATUS_OK,"private scalar plane cannot be selected as a public layer");
    GlimsLayerChange bad={.struct_size=sizeof bad,.properties=GLIMS_LAYER_VISIBLE,.visible=FALSE};error=NULL;
    CHECK(api->layer_change(engine,id,hidden,&bad,&error)==GLIMS_STATUS_UNSUPPORTED,
          "private scalar plane properties cannot be edited");
    if(error)api->free_string(error);error=NULL;
    bad.properties=GLIMS_LAYER_OPACITY;bad.opacity=NAN;
    CHECK(api->layer_change(engine,id,rows[0].id,&bad,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
          "non-finite opacity is refused before mutation");
    if(error)api->free_string(error);error=NULL;
    bad.properties=GLIMS_LAYER_MODE;bad.opacity=1;
    CHECK(api->layer_change(engine,id,rows[0].id,&bad,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
          "unsupported Lab blend-mode edits are refused before mutation");
    if(error)api->free_string(error);error=NULL;
    GlimsLayerChange invalid_name={.struct_size=sizeof invalid_name,.properties=GLIMS_LAYER_NAME};
    CHECK(api->layer_change(engine,id,rows[0].id,&invalid_name,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
          "empty logical layer name is refused");
    if(error)api->free_string(error);error=NULL;
    strcpy(invalid_name.name,"Private plane");
    CHECK(api->layer_change(engine,id,hidden,&invalid_name,&error)==GLIMS_STATUS_UNSUPPORTED,
          "private scalar plane cannot be renamed");
    if(error)api->free_string(error);error=NULL;
    memset(invalid_name.name,'x',sizeof invalid_name.name);
    CHECK(api->layer_change(engine,id,rows[0].id,&invalid_name,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
          "unterminated logical layer name is refused");
    if(error)api->free_string(error);error=NULL;
    invalid_name.name[0]=(char)0xff;invalid_name.name[1]='\0';
    CHECK(api->layer_change(engine,id,rows[0].id,&invalid_name,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
          "invalid UTF-8 logical layer name is refused");
    if(error)api->free_string(error);error=NULL;
    invalid_name.properties=GLIMS_LAYER_NAME|GLIMS_LAYER_VISIBLE;
    strcpy(invalid_name.name,"Changed");invalid_name.visible=FALSE;
    CHECK(api->layer_change(engine,id,rows[0].id,&invalid_name,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
          "mixed name and visibility edit is refused before mutation");
    if(error)api->free_string(error);error=NULL;
    GlimsLayerInfo unchanged_names[8];int32_t unchanged_count=0;
    CHECK(api->image_layers(engine,id,unchanged_names,8,&unchanged_count)==GLIMS_STATUS_OK&&
          unchanged_count==2&&!strcmp(unchanged_names[0].name,rows[0].name)&&unchanged_names[0].visible,
          "invalid names and mixed edits leave layer name and visibility intact");
    CHECK(api->image_undo_info(engine,id,&undo_after)==GLIMS_STATUS_OK&&
          undo_after.undo_count==undo_before.undo_count&&undo_after.redo_count==undo_before.redo_count,
          "invalid property edits leave Undo and Redo unchanged");
    GlimsItemID mixed[]={rows[0].id,hidden};error=NULL;
    CHECK(api->image_select_layers(engine,id,mixed,2,&error)!=GLIMS_STATUS_OK,
          "mixed logical and private selection is refused atomically");
    if(error)api->free_string(error);error=NULL;
    CHECK(api->image_select_items(engine,id,GLIMS_ITEM_SET_LAYER,&hidden,1,&error)==GLIMS_STATUS_UNSUPPORTED,
          "generic item selection cannot bypass logical-root admission");
    if(error)api->free_string(error);
    guint8 thumbnail[4*16*16]={0};int32_t width=0,height=0;
    CHECK(api->drawable_thumbnail(engine,id,hidden,16,thumbnail,sizeof thumbnail,&width,&height)==GLIMS_STATUS_UNSUPPORTED,
          "private scalar plane thumbnail is unavailable");
    int32_t selected_count=0;GlimsItemID selected[8]={0};
    CHECK(api->image_selected_layers(engine,id,selected,8,&selected_count)==GLIMS_STATUS_OK&&selected_count==1&&selected[0]==rows[0].id,
          "rejected hidden-plane selection preserves the logical root");
   }
   GlimsItemID result=123;error=NULL;
   CHECK(api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_MERGE_DOWN,&result,&error)==GLIMS_STATUS_UNSUPPORTED&&result==0,
         "unqualified logical layer commands remain refused");
   if(error)api->free_string(error);error=NULL;result=123;
   CHECK(api->layer_command(engine,id,rows[0].id,UINT32_MAX,&result,&error)==GLIMS_STATUS_UNSUPPORTED&&result==0,
         "unknown logical layer commands fail closed");
   if(error)api->free_string(error);error=NULL;result=123;
   GlimsStatus deleted=api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_DELETE,&result,&error);
   CHECK(deleted==GLIMS_STATUS_OK&&result==0,"public command deletes a logical Lab layer");
   if(error)api->free_string(error);error=NULL;
   if(deleted==GLIMS_STATUS_OK){
    GlimsLayerInfo remaining[8];int32_t n=0;
    CHECK(api->image_layers(engine,id,remaining,8,&n)==GLIMS_STATUS_OK&&n==1&&remaining[0].id==rows[1].id,
          "deleting a logical root preserves the other layer");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&api->image_layers(engine,id,remaining,8,&n)==GLIMS_STATUS_OK&&
          n==2&&remaining[0].id==rows[0].id&&remaining[1].id==rows[1].id,"Undo restores the deleted logical root");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK&&api->image_layers(engine,id,remaining,8,&n)==GLIMS_STATUS_OK&&
          n==1&&remaining[0].id==rows[1].id,"Redo removes the same logical root");
    GlimsStatus last=api->layer_command(engine,id,rows[1].id,GLIMS_LAYER_DELETE,NULL,&error);
    CHECK(last==GLIMS_STATUS_OK,"last logical layer can be deleted");if(error)api->free_string(error);error=NULL;
    if(last==GLIMS_STATUS_OK){
     CHECK(api->image_layers(engine,id,remaining,8,&n)==GLIMS_STATUS_OK&&n==0,"last deletion leaves an empty logical layer tree");
     guint8 empty[4]={1,1,1,1};
     CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},empty,4)==GLIMS_STATUS_OK&&
           empty[0]==0&&empty[1]==0&&empty[2]==0&&empty[3]==0,"empty logical document renders transparent black");
     gchar *empty_path=g_build_filename((const gchar*)work,"layered-lab-empty.xcf",NULL);
     GlimsStatus empty_saved=api->image_save_copy(engine,id,empty_path,&error);
     CHECK(empty_saved==GLIMS_STATUS_OK,"empty logical document saves as XCF");if(error)api->free_string(error);error=NULL;
     if(empty_saved==GLIMS_STATUS_OK){
      GlimsImageID empty_copy=0;GlimsStatus empty_opened=api->image_open(engine,empty_path,&empty_copy,&error);
      CHECK(empty_opened==GLIMS_STATUS_OK&&empty_copy,"empty logical XCF reopens");if(error)api->free_string(error);error=NULL;
      if(empty_opened==GLIMS_STATUS_OK&&empty_copy){
       CHECK(api->image_layers(engine,empty_copy,remaining,8,&n)==GLIMS_STATUS_OK&&n==0,
             "reopened logical XCF has no layers");
       CHECK(api->image_close(engine,empty_copy)==GLIMS_STATUS_OK,"empty logical copy closes");
      }
     }
     g_free(empty_path);
     GlimsItemID added=0;GlimsStatus recreated=api->layer_command(engine,id,0,GLIMS_LAYER_NEW,&added,&error);
     CHECK(recreated==GLIMS_STATUS_OK&&added,"an empty logical document can create a layer");
     if(error)api->free_string(error);error=NULL;
     if(recreated==GLIMS_STATUS_OK)CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"Undo removes the newly created layer");
     CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"Undo restores the last deleted layer");
    }
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&api->image_layers(engine,id,remaining,8,&n)==GLIMS_STATUS_OK&&n==2,
          "final Undo restores both original logical roots");
   }
  }
  GlimsPixelBuffer copied={0};error=NULL;
  CHECK(api->image_copy_pixels(engine,id,TRUE,&copied,&error)==GLIMS_STATUS_UNSUPPORTED,
        "ordinary merged clipboard copy is quarantined");
  if(error)api->free_string(error);if(copied.pixels)api->free_pixels(copied.pixels);
  cmsHPROFILE lab=cmsCreateLab4Profile(NULL),rgb=cmsCreate_sRGBProfile();cmsHTRANSFORM transform=lab&&rgb?cmsCreateTransform(lab,TYPE_Lab_DBL,rgb,TYPE_RGB_DBL,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE):NULL;
  double input[3]={100.0*128/255,0,0},expected[3]={0};CHECK(transform!=NULL,"independent Lab to sRGB oracle creates");if(transform)cmsDoTransform(transform,input,expected,1);
  const double scales[]={1,.75,1.3};for(unsigned i=0;i<3;i++){guint8 pixel[4]={0};s=api->image_render(engine,id,scales[i],(GlimsRect){1,1,1,1},pixel,4);CHECK(s==GLIMS_STATUS_OK,"public layered Lab render succeeds");if(transform&&s==GLIMS_STATUS_OK){for(unsigned c=0;c<3;c++)CHECK(abs((int)pixel[c]-(int)floor(fmin(1,fmax(0,expected[c]))*255+.5))<=3,"rendered Lab color matches independent LCMS");CHECK(pixel[3]==255,"opaque logical layer remains opaque");}}
  cmsUInt32Number icc_size=0;guint8 *icc=NULL;
  if(rgb&&cmsSaveProfileToMem(rgb,NULL,&icc_size)&&icc_size){icc=g_malloc(icc_size);if(!cmsSaveProfileToMem(rgb,icc,&icc_size))g_clear_pointer(&icc,g_free);}
  CHECK(icc!=NULL,"independent sRGB destination profile serializes");
  if(icc){
   for(unsigned i=0;i<3;i++){
    guint8 pixel[4]={0};error=NULL;
    s=api->image_render_to_profile(engine,id,scales[i],(GlimsRect){1,1,1,1},icc,icc_size,pixel,4,&error);
    CHECK(s==GLIMS_STATUS_OK,"profile-aware layered Lab render succeeds");if(error)api->free_string(error);
    if(transform&&s==GLIMS_STATUS_OK){for(unsigned c=0;c<3;c++)CHECK(abs((int)pixel[c]-(int)floor(fmin(1,fmax(0,expected[c]))*255+.5))<=3,"profile-aware Lab color matches independent LCMS");CHECK(pixel[3]==255,"profile-aware logical layer remains opaque");}
   }
   GlimsProofSettings proof={.struct_size=sizeof proof,.proof_intent=GLIMS_PROFILE_RELATIVE_COLORIMETRIC,.display_intent=GLIMS_PROFILE_RELATIVE_COLORIMETRIC};
   guint8 pixel[4]={0};error=NULL;
   s=api->image_render_proofed(engine,id,1,(GlimsRect){1,1,1,1},icc,icc_size,icc,icc_size,&proof,pixel,4,&error);
   CHECK(s==GLIMS_STATUS_UNSUPPORTED,"unqualified layered Lab soft proof is refused");if(error)api->free_string(error);
  }
  g_free(icc);
  if(transform)cmsDeleteTransform(transform);if(lab)cmsCloseProfile(lab);if(rgb)cmsCloseProfile(rgb);
  gchar *copy_path=g_build_filename((const gchar*)work,"layered-lab-copy.xcf",NULL);error=NULL;
  s=api->image_save_copy(engine,id,copy_path,&error);
  CHECK(s==GLIMS_STATUS_OK,"public Save Copy preserves layered Lab format");if(error)api->free_string(error);
  if(s==GLIMS_STATUS_OK){
   GlimsImageID copy_id=0;error=NULL;GlimsStatus opened=api->image_open(engine,copy_path,&copy_id,&error);
   CHECK(opened==GLIMS_STATUS_OK&&copy_id!=0,"saved layered Lab copy reopens");if(error)api->free_string(error);
   if(opened==GLIMS_STATUS_OK&&copy_id){
    GlimsOpenImage *copy=glims_lookup_image(engine,copy_id);GlimsLabLayerStorage readback;
    gboolean valid_copy=copy&&glims_lab_layer_storage_read(copy->image,&readback)==GLIMS_LAB_LAYER_STORAGE_VALID;
    CHECK(valid_copy && !memcmp(&readback.map,&m,sizeof m),"saved copy preserves the full Lab identity map");
    if(valid_copy)for(guint i=0;i<2;i++)for(guint role=0;role<4;role++){
     GimpDrawable *d=GIMP_DRAWABLE(readback.layers[i].planes[role]);const Babl *fmt=gimp_drawable_get_format(d);
     guint8 raw[16];memset(raw,0,sizeof raw);
     gboolean one_byte=babl_format_get_n_components(fmt)==1&&babl_format_get_bytes_per_pixel(fmt)==1;
     CHECK(one_byte,"saved scalar plane retains one-byte samples");
     if(one_byte){gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,4,4),1,fmt,raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      guint8 expected_byte=role==3?255:role==0?(i?255:128):128;gboolean matches=TRUE;
      for(guint p=0;p<16;p++)if(raw[p]!=expected_byte)matches=FALSE;
      CHECK(matches,"saved scalar plane preserves every sample");}
    }
    CHECK(api->image_close(engine,copy_id)==GLIMS_STATUS_OK,"saved copy closes");
   }
  }
  g_free(copy_path);
  /* Exercise the public display conversions with a translucent source and
   * transparent abyss, using LCMS independently for the expected color. */
  GlimsOpenImage *alpha_open=glims_lookup_image(engine,id);GlimsLabLayerStorage alpha_storage;
  gboolean alpha_valid=alpha_open&&glims_lab_layer_storage_read(alpha_open->image,&alpha_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
  CHECK(alpha_valid,"storage is valid for translucent display probe");
  if(alpha_valid){
   for(guint i=0;i<2;i++){
    guint8 alpha[16];memset(alpha,i==0?128:0,sizeof alpha);
    GimpDrawable *plane=GIMP_DRAWABLE(alpha_storage.layers[i].planes[3]);
    gegl_buffer_set(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,4,4),0,gimp_drawable_get_format(plane),alpha,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(plane,0,0,4,4);
   }
   cmsHPROFILE lp=cmsCreateLab4Profile(NULL),sp=cmsCreate_sRGBProfile();
   cmsHTRANSFORM tx=lp&&sp?cmsCreateTransform(lp,TYPE_Lab_DBL,sp,TYPE_RGB_DBL,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE):NULL;
   double lab_pixel[3]={100.0*128/255,0,0},rgb_pixel[3]={0};
   CHECK(tx!=NULL,"translucent display oracle creates");if(tx)cmsDoTransform(tx,lab_pixel,rgb_pixel,1);
   guint8 out[28];memset(out,0xa5,sizeof out);
   s=api->image_render(engine,id,1,(GlimsRect){0,0,2,2},out+1,13);
   CHECK(s==GLIMS_STATUS_OK&&out[0]==0xa5&&out[9]==0xa5&&out[13]==0xa5&&out[22]==0xa5&&out[27]==0xa5,
         "unaligned translucent render preserves row padding and guards");
   if(tx&&s==GLIMS_STATUS_OK)for(guint y=0;y<2;y++)for(guint x=0;x<2;x++){
    guint8 *p=out+1+y*13+x*4;gboolean match=abs((int)p[3]-128)<=1;
    for(guint c=0;c<3;c++)if(abs((int)p[c]-(int)floor(fmin(1,fmax(0,rgb_pixel[c]))*128+.5))>3)match=FALSE;
    CHECK(match,"translucent public render matches premultiplied LCMS color");
   }
   cmsUInt32Number profile_size=0;guint8 *profile=NULL;
   if(sp&&cmsSaveProfileToMem(sp,NULL,&profile_size)&&profile_size){
    profile=g_malloc(profile_size);if(!cmsSaveProfileToMem(sp,profile,&profile_size))g_clear_pointer(&profile,g_free);
   }
   CHECK(profile!=NULL,"translucent destination profile serializes");
   if(profile){
    guint8 profiled[4]={0};error=NULL;
    s=api->image_render_to_profile(engine,id,1,(GlimsRect){1,1,1,1},profile,profile_size,profiled,4,&error);
    gboolean match=s==GLIMS_STATUS_OK&&abs((int)profiled[3]-128)<=1;
    if(tx)for(guint c=0;c<3;c++)if(abs((int)profiled[c]-(int)floor(fmin(1,fmax(0,rgb_pixel[c]))*128+.5))>3)match=FALSE;
    CHECK(tx&&match,"profile-aware translucent render matches premultiplied LCMS color");
    if(error)api->free_string(error);g_free(profile);
   }
   guint8 zero[16]={0};GimpDrawable *plane=GIMP_DRAWABLE(alpha_storage.layers[0].planes[3]);
   gegl_buffer_set(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,4,4),0,gimp_drawable_get_format(plane),zero,GEGL_AUTO_ROWSTRIDE);
   gimp_drawable_update(plane,0,0,4,4);
   guint8 transparent[4]={0x5a,0x5a,0x5a,0x5a};
   CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},transparent,4)==GLIMS_STATUS_OK &&
         transparent[0]==0&&transparent[1]==0&&transparent[2]==0&&transparent[3]==0,
         "transparent Lab display is canonical transparent black after alpha change");
   if(tx)cmsDeleteTransform(tx);if(lp)cmsCloseProfile(lp);if(sp)cmsCloseProfile(sp);
  }
  /* Corrupt only the in-memory copy after a successful save. Every admitted
   * operation must revalidate the carrier, while close must remain possible. */
  GlimsOpenImage *damaged=glims_lookup_image(engine,id);
  CHECK(damaged!=NULL,"open image remains available for damaged-storage probe");
  if(damaged){
   gimp_image_parasite_detach(damaged->image,GLIMS_PLATE_MAP_PARASITE,FALSE);
   GlimsImageStorageInfo damaged_info={.struct_size=sizeof damaged_info};
   CHECK(api->image_storage_info(engine,id,&damaged_info)==GLIMS_STATUS_UNSUPPORTED,
         "storage query rejects a damaged adopted carrier");
   guint8 pixel[4]={0x5a,0x5a,0x5a,0x5a};
   CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},pixel,4)==GLIMS_STATUS_UNSUPPORTED &&
         pixel[0]==0x5a&&pixel[1]==0x5a&&pixel[2]==0x5a&&pixel[3]==0x5a,
         "render rejects damaged storage without writing output");
   if(count==2)CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_UNSUPPORTED,
                     "selection rejects damaged storage");
   if(count==2){
    GlimsLabLayerIdentity bad={.struct_size=sizeof bad};memset(bad.uuid,0xa5,sizeof bad.uuid);
    guint8 zero_uuid[16]={0};
    CHECK(api->image_lab_layer_identity(engine,id,rows[0].id,&bad)==GLIMS_STATUS_UNSUPPORTED&&
          !memcmp(bad.uuid,zero_uuid,sizeof zero_uuid),"damaged storage clears and rejects identity");
    error=NULL;
    CHECK(api->image_select_layers(engine,id,&rows[0].id,1,&error)==GLIMS_STATUS_UNSUPPORTED && error && *error,
          "damaged storage selection supplies an actionable error");
    if(error)api->free_string(error);error=NULL;
   }
   GlimsLayerChange damaged_change={.struct_size=sizeof damaged_change,.properties=GLIMS_LAYER_VISIBLE,.visible=FALSE};error=NULL;
   if(count==2)CHECK(api->layer_change(engine,id,rows[0].id,&damaged_change,&error)==GLIMS_STATUS_UNSUPPORTED,
                     "layer edits reject damaged storage");
   if(error)api->free_string(error);error=NULL;
   if(count==2)CHECK(api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_DUPLICATE,NULL,&error)==GLIMS_STATUS_UNSUPPORTED,
                     "duplication rejects damaged storage");
   if(error)api->free_string(error);error=NULL;
   CHECK(api->image_undo(engine,id)==GLIMS_STATUS_UNSUPPORTED&&api->image_redo(engine,id)==GLIMS_STATUS_UNSUPPORTED,
         "Undo and Redo reject damaged storage");
   gchar *damaged_path=g_build_filename((const gchar*)work,"damaged-copy.xcf",NULL);error=NULL;
   CHECK(api->image_save_copy(engine,id,damaged_path,&error)==GLIMS_STATUS_UNSUPPORTED &&
         !g_file_test(damaged_path,G_FILE_TEST_EXISTS),"save copy rejects damaged storage without creating a file");
   if(error)api->free_string(error);g_free(damaged_path);
  }
  CHECK(api->image_close(engine,id)==GLIMS_STATUS_OK,"public layered Lab image closes");
 }
 GlimsImageID close_image=0;error=NULL;
 CHECK(api->image_open(engine,path,&close_image,&error)==GLIMS_STATUS_OK&&close_image,"open independent brush-close fixture");
 if(error)api->free_string(error);error=NULL;
 if(close_image){
  GlimsLayerInfo close_rows[4];int32_t close_count=0;GlimsLabLayerIdentity close_identity={.struct_size=sizeof close_identity};
  gboolean close_ready=api->image_layers(engine,close_image,close_rows,4,&close_count)==GLIMS_STATUS_OK&&close_count==2&&
    api->layer_select(engine,close_image,close_rows[0].id)==GLIMS_STATUS_OK&&
    api->image_lab_layer_identity(engine,close_image,close_rows[0].id,&close_identity)==GLIMS_STATUS_OK;
  CHECK(close_ready,"brush-close fixture captures a logical root");
  if(close_ready){
   GlimsLabLayerBrushSettings close_brush={.struct_size=sizeof close_brush,.root=close_rows[0].id,
     .color={1,0,0,1},.opacity=1,.size=5,.hardness=1};memcpy(close_brush.uuid,close_identity.uuid,16);
   GlimsStrokeSampleV2 point={.struct_size=sizeof point,.x=1.5,.y=1.5,.pressure=1,.time_ms=1};
   GlimsStrokePacketV2 packet={.struct_size=sizeof packet,.sample_stride=sizeof point,.samples=&point,.count=1,.byte_count=sizeof point};
   GlimsStrokeID stroke=0;GlimsStatus started=api->stroke_begin_lab_layer(engine,close_image,0,&close_brush,&packet,&stroke,&error);
   CHECK(started==GLIMS_STATUS_OK&&stroke,"brush-close fixture starts a live stroke");if(error)api->free_string(error);error=NULL;
   if(started==GLIMS_STATUS_OK&&stroke){
    GlimsOpenImage *close_open=glims_lookup_image(engine,close_image);GlimsLabLayerStorage close_storage;
    gboolean close_valid=close_open&&glims_lab_layer_storage_read(close_open->image,&close_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
    CHECK(close_valid,"brush-close fixture has an intact target");
    if(close_valid){
     GimpDrawable *observed=g_object_ref(GIMP_DRAWABLE(close_storage.layers[0].planes[0]));
     brush_retarget_image=close_image;brush_retarget_root=0;brush_retargeted=FALSE;brush_reentrant_stroke=stroke;
     gulong handler=g_signal_connect(observed,"update",G_CALLBACK(retarget_on_brush_update),NULL);
     GlimsStatus closed=api->image_close(engine,close_image);
     g_signal_handler_disconnect(observed,handler);g_object_unref(observed);
     CHECK(closed==GLIMS_STATUS_OK&&brush_retargeted&&brush_close_status==GLIMS_STATUS_BUSY,
           "closing an active brush refuses reentrant close during rollback");
     CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_NOT_FOUND,"close releases the active brush handle");
     close_image=0;brush_reentrant_stroke=0;
    }
   }
  }
  if(close_image)CHECK(api->image_close(engine,close_image)==GLIMS_STATUS_OK,"close fixture cleans up");
 }
 CHECK(g_file_get_contents(path,&after,&after_size,NULL)&&before&&before_size==after_size&&!memcmp(before,after,before_size),"open/read leaves source XCF bytes unchanged");g_free(before);g_free(after);g_free(path);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv){if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;gchar *u=g_build_filename(argv[1],"user",NULL),*c=g_build_filename(argv[1],"cache",NULL);GlimsEngineConfig cfg={.struct_size=sizeof cfg,.user_directory=u,.cache_directory=c,.on_event=on_event};GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus s=api->start(&cfg,&engine,&error);g_free(u);g_free(c);if(s||!engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}api->free_string(error);running_engine=engine;s=glims_engine_call(engine,worker,argv[1]);running_engine=NULL;api->stop(engine);printf("checks=%u failures=%u\n",checks,failures);return s==GLIMS_STATUS_OK&&!failures?0:1;}

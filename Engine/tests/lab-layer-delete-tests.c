/* Private native deletion acceptance, independent of document adoption. */
#include "lab-layer-delete.h"
#include "lab-layer-storage.h"
#include "plate-storage.h"
#include <cairo.h>
#include <stdio.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#include "file/file-open.h"
#include "file/file-save.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
#include "plug-in/gimppluginprocedure.h"
#define W 3
#define H 2
#define N 6
#define MAX_ITEMS (GLIMS_LAB_LAYER_LIMIT*5+5)
static unsigned checks,failures;
static const GlimsEngineAPI *api;
#define CHECK(c,msg) do {gboolean ok_=!!(c);checks++;if(!ok_)failures++;printf("%s %s\n",ok_?"ok":"FAIL",msg);fflush(stdout);}while(0)
static GlimsLabLayerMap map_for(guint count) {
 GlimsLabLayerMap m={.width=W,.height=H,.count=count,.mode=3,.storage=1,.encoding=2};
 for(guint i=0;i<count&&i<256;i++) {
  for(guint p=0;p<5;p++){guint8 *id=(guint8*)&m.entries[i]+16*p;id[0]=0x72;id[12]=(i+1)>>8;id[13]=i+1;id[15]=p+1;}
 }
 return m;
}
static GimpImage *make(GlimsEngine *e,guint count) {
 GlimsLabLayerMap m=map_for(count);char *error=NULL;GimpImage *im=glims_lab_layer_storage_create(e,&m,&error);
 CHECK(im&&error==NULL,"factory setup creates carrier");if(error)api->free_string(error);return im;
}
static gboolean scalar(GimpLayer *p) {
 if(!p||!GIMP_IS_LAYER(p))return FALSE;const Babl *f=gimp_drawable_get_format(GIMP_DRAWABLE(p));
 return f&&babl_format_get_bytes_per_pixel(f)==1&&babl_format_get_n_components(f)==1&&gimp_item_get_width(GIMP_ITEM(p))==W&&gimp_item_get_height(GIMP_ITEM(p))==H;
}
static gboolean pixels(GimpLayer *p,guint8 out[N]) {
 if(!scalar(p))return FALSE;GimpDrawable *d=GIMP_DRAWABLE(p);gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),1,gimp_drawable_get_format(d),out,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);return TRUE;
}
static gboolean put(GimpLayer *p,const guint8 bytes[N]) {
 if(!scalar(p)){CHECK(FALSE,"independent scalar fixture write guard");return FALSE;}GimpDrawable *d=GIMP_DRAWABLE(p);gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),0,gimp_drawable_get_format(d),bytes,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(d,0,0,W,H);return TRUE;
}
static void seed(GlimsLabLayerStorage *s,guint count,guint8 expected[3][4][N]) {
 for(guint i=0;i<count;i++)for(guint p=0;p<4;p++){for(guint x=0;x<N;x++)expected[i][p][x]=(19+97*i+37*p+47*x)&255;if(p==3){expected[i][p][0]=0;expected[i][p][1]=128;expected[i][p][2]=255;}put(s->layers[i].planes[p],expected[i][p]);}
}
typedef struct {gint id,parent,index;gboolean group,visible,named;gint x,y,width,height,mode,blend,composite,composite_mode;gboolean lock_content,lock_position,lock_visibility,lock_alpha;gdouble opacity;guint8 raw[N],uuid[16];gulong uuid_flags;guint uuid_size;gchar name[80];} Item;
typedef struct {guint count,selected_count,map_size,mask_size;gint selected[MAX_ITEMS];gulong map_flags;gboolean map_present,enabled,export_dirty;gint undo,redo,group,dirty;gint64 dirty_time;guint8 map[GLIMS_LAB_LAYER_MAP_MAX_SIZE],mask[N*16];Item items[MAX_ITEMS];} Snapshot;
static gboolean snapshot(GimpImage *im,Snapshot *s) {
 memset(s,0,sizeof *s);GList *list=gimp_image_get_layer_list(im);gboolean ok=TRUE;
 for(GList *it=list;it;it=it->next){if(s->count==MAX_ITEMS){ok=FALSE;break;}GimpLayer *layer=it->data;GimpItem *item=GIMP_ITEM(layer);Item *r=&s->items[s->count++];r->id=gimp_item_get_id(item);r->index=gimp_item_get_index(item);GimpItem *parent=gimp_item_get_parent(item);r->parent=parent?gimp_item_get_id(parent):0;r->group=GIMP_IS_GROUP_LAYER(layer);r->visible=gimp_item_get_visible(item);r->opacity=gimp_layer_get_opacity(layer);gimp_item_get_offset(item,&r->x,&r->y);r->width=gimp_item_get_width(item);r->height=gimp_item_get_height(item);r->mode=gimp_layer_get_mode(layer);r->blend=gimp_layer_get_blend_space(layer);r->composite=gimp_layer_get_composite_space(layer);r->composite_mode=gimp_layer_get_composite_mode(layer);r->lock_content=gimp_item_get_lock_content(item);r->lock_position=gimp_item_get_lock_position(item);r->lock_visibility=gimp_item_get_lock_visibility(item);r->lock_alpha=gimp_layer_get_lock_alpha(layer);const gchar *name=gimp_object_get_name(layer);r->named=name!=NULL;if(name)g_strlcpy(r->name,name,sizeof r->name);
  if(!r->group&&!pixels(layer,r->raw)){ok=FALSE;break;}
  const GimpParasite *p=gimp_item_parasite_find(item,GLIMS_PLATE_UUID_PARASITE);if(p){guint32 size=0;const void *data=gimp_parasite_get_data(p,&size);if(size>16||!data){ok=FALSE;break;}r->uuid_size=size;r->uuid_flags=gimp_parasite_get_flags(p);memcpy(r->uuid,data,size);}}
 g_list_free(list);if(!ok)return FALSE;
 const GimpParasite *p=gimp_image_parasite_find(im,GLIMS_PLATE_MAP_PARASITE);if(p){guint32 size=0;const void *data=gimp_parasite_get_data(p,&size);if(size>sizeof s->map||!data)return FALSE;s->map_present=TRUE;s->map_size=size;s->map_flags=gimp_parasite_get_flags(p);memcpy(s->map,data,size);}
 GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(im));const Babl *f=gimp_drawable_get_format(mask);gint bpp=babl_format_get_bytes_per_pixel(f);if(bpp<=0||bpp>16)return FALSE;s->mask_size=N*bpp;gegl_buffer_get(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(0,0,W,H),1,f,s->mask,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
 for(GList *it=gimp_image_get_selected_layers(im);it;it=it->next){if(s->selected_count==MAX_ITEMS)return FALSE;s->selected[s->selected_count++]=gimp_item_get_id(it->data);}
 s->undo=gimp_undo_stack_get_depth(gimp_image_get_undo_stack(im));s->redo=gimp_undo_stack_get_depth(gimp_image_get_redo_stack(im));s->group=gimp_image_get_undo_group_count(im);s->enabled=gimp_image_undo_is_enabled(im);s->dirty=gimp_image_is_dirty(im);s->export_dirty=gimp_image_is_export_dirty(im);s->dirty_time=gimp_image_get_dirty_time(im);return TRUE;
}
static gboolean same_state(const Snapshot *a,const Snapshot *b,gboolean history) {
 if(history)return !memcmp(a,b,sizeof *a);
 Snapshot *x=g_memdup2(a,sizeof *a),*y=g_memdup2(b,sizeof *b);
 x->undo=x->redo=x->group=x->dirty=0;x->dirty_time=0;x->enabled=x->export_dirty=FALSE;
 y->undo=y->redo=y->group=y->dirty=0;y->dirty_time=0;y->enabled=y->export_dirty=FALSE;
 gboolean same=!memcmp(x,y,sizeof *x);g_free(x);g_free(y);return same;
}
static void select_items(GimpImage *im,GimpLayer **items,guint count){GList *list=NULL;for(guint i=0;i<count;i++)list=g_list_append(list,items[i]);gimp_image_set_selected_layers(im,list);g_list_free(list);}
static void refusal(GlimsEngine *engine,GimpImage *im,GimpLayer *source,GlimsStatus expected,const char *label) {
 Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);gboolean a=snapshot(im,before);CHECK(a,"refusal baseline snapshot succeeds");
 char *error=NULL;GlimsStatus status=glims_lab_layer_delete(engine,im,source,&error);
 if(status!=expected)printf("STATUS %s actual=%d expected=%d error=%s\n",label,status,expected,error?error:"none");
 CHECK(status==expected,label);CHECK(error&&*error,"refusal gives meaningful owned error");if(error)api->free_string(error);
 gboolean b=snapshot(im,after);CHECK(a&&b&&same_state(before,after,TRUE),"refusal preserves complete tree/raw/map/selection/history/redo/dirty");g_free(after);g_free(before);
}
static gboolean role_bytes(const GlimsLabLayerNative *native,const guint8 data[4][N]) {
 for(guint p=0;p<4;p++){guint8 actual[N];if(!pixels(native->planes[p],actual)||memcmp(actual,data[p],N))return FALSE;}return TRUE;
}
static gboolean
save_xcf (Gimp *gimp, GimpImage *image, const char *path)
{
  GError *error = NULL;
  GFile *file = g_file_new_for_path (path);
  GimpPlugInProcedure *proc = gimp_plug_in_manager_file_procedure_find (
    gimp->plug_in_manager, GIMP_FILE_PROCEDURE_GROUP_SAVE, file, &error);
  GimpPDBStatusType status = proc ? file_save (gimp, image, NULL, file, proc,
    GIMP_RUN_NONINTERACTIVE, TRUE, FALSE, FALSE, &error) : GIMP_PDB_EXECUTION_ERROR;
  if (error) { printf ("save error: %s\n", error->message); g_clear_error (&error); }
  g_object_unref (file);
  return status == GIMP_PDB_SUCCESS;
}

static GimpImage *
open_xcf (Gimp *gimp, const char *path)
{
  GError *error = NULL;
  GimpPDBStatusType status;
  const gchar *mime = NULL;
  GFile *file = g_file_new_for_path (path);
#if GIMP_CHECK_VERSION(3, 2, 0)
  gboolean handles_vector = FALSE;
  GimpImage *image = file_open_image (gimp, gimp_get_user_context (gimp), NULL, file,
    0, 0, FALSE, FALSE, NULL, GIMP_RUN_NONINTERACTIVE, &handles_vector, &status, &mime, &error);
#else
  GimpImage *image = file_open_image (gimp, gimp_get_user_context (gimp), NULL, file,
    0, 0, FALSE, NULL, GIMP_RUN_NONINTERACTIVE, &status, &mime, &error);
#endif
  CHECK (image != NULL && status == GIMP_PDB_SUCCESS, "XCF reopens successfully");
  if (error) { printf ("open error: %s\n", error->message); g_clear_error (&error); }
  g_object_unref (file);
  return image;
}

static gboolean selected_is(GimpImage *im,const gint *ids,guint count) {
 GList *selected=gimp_image_get_selected_layers(im);guint i=0;
 for(GList *it=selected;it;it=it->next){if(i>=count||gimp_item_get_id(it->data)!=ids[i])return FALSE;i++;}return i==count;
}
static const Item *find_item(const Snapshot *s,gint id) {
 for(guint i=0;i<s->count;i++)if(s->items[i].id==id)return &s->items[i];return NULL;
}
static gboolean survivors_preserved(const Snapshot *before,const Snapshot *after,gint removed) {
 if(after->count+5!=before->count||after->mask_size!=before->mask_size||memcmp(after->mask,before->mask,sizeof after->mask))return FALSE;
 for(guint i=0;i<after->count;i++) {
  Item item=after->items[i];const Item *old=find_item(before,item.id);if(!old||item.id==removed||item.parent==removed)return FALSE;
  Item expected=*old;if(item.parent==0)item.index=expected.index=0;if(memcmp(&item,&expected,sizeof item))return FALSE;
 }
 return TRUE;
}
static void mask_and_redo(GimpImage *im,GimpLayer *other) {
 GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(im));float value=.375f,observed=0;
 gegl_buffer_set(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,0,1,1),0,babl_format("Y float"),&value,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(mask,1,0,1,1);
 gegl_buffer_get(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,0,1,1),1,babl_format("Y float"),&observed,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
 CHECK(observed>.37f&&observed<.38f&&!gimp_channel_is_empty(gimp_image_get_mask(im)),"baseline positively has partial nonempty mask");
 gimp_layer_set_opacity(other,.25,TRUE);CHECK(gimp_image_undo(im),"baseline creates native redo branch");
 CHECK(gimp_undo_stack_get_depth(gimp_image_get_redo_stack(im))>0,"baseline redo is nonempty");gimp_image_clean_all(im);
}
static void success_case(GlimsEngine *engine,const char *work,guint scenario) {
 guint count=scenario==3?1:3;GimpImage *im=make(engine,count);if(!im)return;
 GlimsLabLayerStorage st;gboolean valid=glims_lab_layer_storage_read(im,&st)==GLIMS_LAB_LAYER_STORAGE_VALID;
 CHECK(valid,"success fixture validates before edits");if(!valid){g_object_unref(im);return;}
 guint8 bytes[3][4][N];seed(&st,count,bytes);GimpLayer *source=st.layers[0].group;
 GimpLayer *b=count==3?st.layers[1].group:NULL,*c=count==3?st.layers[2].group:NULL;
 if(count==3)CHECK(gimp_image_reorder_item(im,GIMP_ITEM(c),NULL,0,FALSE,NULL),"native root order differs from UUID map order");
 CHECK(gimp_image_reorder_item(im,GIMP_ITEM(st.layers[0].planes[3]),GIMP_ITEM(source),0,FALSE,NULL),"source child order permuted independently of roles");
 gimp_item_set_visible(GIMP_ITEM(source),FALSE,FALSE);gimp_layer_set_opacity(source,.375,FALSE);
 GimpLayer *selection[3];guint selection_count;
 if(scenario==0){selection[0]=b;selection[1]=source;selection[2]=c;selection_count=3;}
 else if(scenario==1){selection[0]=source;selection_count=1;}
 else if(scenario==2){selection[0]=st.layers[0].planes[2];selection[1]=st.layers[1].planes[1];selection_count=2;}
 else if(scenario==3){selection[0]=st.layers[0].planes[2];selection_count=1;}
 else {selection_count=0;}
 select_items(im,selection,selection_count);
 gint before_ids[3];for(guint i=0;i<selection_count;i++)before_ids[i]=gimp_item_get_id(GIMP_ITEM(selection[i]));
 CHECK(selected_is(im,before_ids,selection_count),"baseline native ordered selection matches requested roots/children");
 mask_and_redo(im,count==3?b:source);
 Snapshot *before=g_new0(Snapshot,1),*created=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);CHECK(snapshot(im,before),"complete baseline snapshot");
 CHECK(selected_is(im,before_ids,selection_count),"actual pre-delete selection remains exact after redo setup, including empty-before");
 gint source_id=gimp_item_get_id(GIMP_ITEM(source));char *error=NULL;
 GlimsStatus status=glims_lab_layer_delete(engine,im,source,&error);
 CHECK(status==GLIMS_STATUS_OK&&error==NULL,"explicit logical root delete succeeds");if(error)api->free_string(error);if(status!=GLIMS_STATUS_OK)goto done;
 CHECK(snapshot(im,created)&&survivors_preserved(before,created,source_id),"surviving native IDs/raw/attrs/parentage and full mask are preserved");
 GlimsLabLayerMap expected=map_for(count);if(count==3)memmove(&expected.entries[0],&expected.entries[1],2*sizeof expected.entries[0]);expected.count=count-1;memset(&expected.entries[count-1],0,sizeof expected.entries[0]);
 GlimsLabLayerStorage after_storage;valid=glims_lab_layer_storage_read(im,&after_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
 CHECK(valid&&!memcmp(&after_storage.map,&expected,sizeof expected),"exact map entry is removed by map index, not native order");
 if(count==3&&valid)CHECK(after_storage.layers[0].group==c&&after_storage.layers[1].group==b&&after_storage.layers[0].map_index==1&&after_storage.layers[1].map_index==0&&role_bytes(&after_storage.layers[0],bytes[2])&&role_bytes(&after_storage.layers[1],bytes[1]),"native survivor order and each role byte remain independent of shifted map indices");
 gint expected_selection[2];guint expected_count=0;
 if(scenario==0){expected_selection[0]=gimp_item_get_id(GIMP_ITEM(b));expected_selection[1]=gimp_item_get_id(GIMP_ITEM(c));expected_count=2;}
 else if(count==3){expected_selection[0]=gimp_item_get_id(GIMP_ITEM(c));expected_count=1;}
 CHECK(selected_is(im,expected_selection,expected_count),"success retains ordered surviving logical roots or exact native-first fallback, never scalar children");
 CHECK(created->undo==before->undo+1&&created->redo==0,"one delete Undo is added and actual previous redo cleared");
 CHECK(gimp_image_undo(im),"single native Undo succeeds");CHECK(snapshot(im,after)&&same_state(before,after,FALSE),"Undo restores exact original map/tree/object IDs/raw/mask/complete ordered selection");CHECK(gimp_image_is_dirty(im)==before->dirty,"Undo restores original dirty count");
 CHECK(gimp_image_redo(im),"native Redo succeeds");CHECK(snapshot(im,after)&&same_state(created,after,FALSE),"Redo repeats exact removal and same survivor selection");
 CHECK(gimp_image_undo(im)&&gimp_image_redo(im),"second Undo/Redo cycle succeeds");CHECK(snapshot(im,after)&&same_state(created,after,FALSE),"second Redo keeps exact surviving IDs and metadata");
 gchar *name=g_strdup_printf("deleted-case-%u.xcf",scenario),*path=g_build_filename(work,name,NULL);g_free(name);
 gboolean saved=save_xcf(engine->gimp,im,path);CHECK(saved,"post-delete carrier saves native XCF");
 if(saved){GimpImage *opened=open_xcf(engine->gimp,path);if(opened){GlimsLabLayerStorage loaded;gboolean ok=glims_lab_layer_storage_read(opened,&loaded)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(ok&&!memcmp(&loaded.map,&expected,sizeof expected),"XCF preserves exact post-delete map, including empty last-root map");if(ok&&count==3)CHECK(loaded.layers[0].map_index==1&&loaded.layers[1].map_index==0&&role_bytes(&loaded.layers[0],bytes[2])&&role_bytes(&loaded.layers[1],bytes[1]),"XCF preserves survivor order and raw role bytes without runtime-ID assumptions");Snapshot *reopened=g_new0(Snapshot,1);CHECK(snapshot(opened,reopened)&&reopened->mask_size==created->mask_size&&!memcmp(reopened->mask,created->mask,sizeof created->mask),"XCF preserves nonempty selection-mask bytes after delete");g_free(reopened);g_object_unref(opened);}}
 g_free(path);
done:
 g_free(after);g_free(created);g_free(before);g_object_unref(im);
}
static void refusal_cases(GlimsEngine *engine) {
 GimpImage *im=make(engine,2),*foreign=make(engine,1);if(!im||!foreign){if(im)g_object_unref(im);if(foreign)g_object_unref(foreign);return;}
 GlimsLabLayerStorage st,other;gboolean valid=glims_lab_layer_storage_read(im,&st)==GLIMS_LAB_LAYER_STORAGE_VALID&&glims_lab_layer_storage_read(foreign,&other)==GLIMS_LAB_LAYER_STORAGE_VALID;
 CHECK(valid,"refusal fixture carriers validate");if(!valid)goto done;
 mask_and_redo(im,st.layers[1].group);
 refusal(engine,im,other.layers[0].group,GLIMS_STATUS_NOT_FOUND,"foreign root refuses");
 refusal(engine,im,st.layers[0].planes[0],GLIMS_STATUS_UNSUPPORTED,"scalar child target refuses");
 GimpLayer *detached=gimp_group_layer_new(im);CHECK(detached!=NULL,"detached source allocates");if(detached){refusal(engine,im,detached,GLIMS_STATUS_NOT_FOUND,"unattached source refuses");g_object_unref(detached);}
 engine->busy++;refusal(engine,im,st.layers[0].group,GLIMS_STATUS_BUSY,"engine busy refuses");engine->busy--;
 CHECK(gimp_image_undo_freeze(im),"freeze setup");refusal(engine,im,st.layers[0].group,GLIMS_STATUS_BUSY,"frozen Undo refuses");CHECK(gimp_image_undo_thaw(im),"thaw cleanup");
 CHECK(gimp_image_undo_group_start(im,GIMP_UNDO_GROUP_LAYER_ADD,"fixture"),"existing native group setup");refusal(engine,im,st.layers[0].group,GLIMS_STATUS_BUSY,"active Undo group refuses");CHECK(gimp_image_undo_group_end(im),"group cleanup");
 CHECK(gimp_image_undo_disable(im),"disable setup");refusal(engine,im,st.layers[0].group,GLIMS_STATUS_BUSY,"disabled Undo refuses");CHECK(gimp_image_undo_enable(im),"enable cleanup");
 Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);CHECK(snapshot(im,before),"null engine baseline");char *error=NULL;
 CHECK(glims_lab_layer_delete(NULL,im,st.layers[0].group,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"NULL engine refuses");if(error)api->free_string(error);CHECK(snapshot(im,after)&&same_state(before,after,TRUE),"NULL engine preserves state");g_free(after);g_free(before);
 {guint8 map[GLIMS_LAB_LAYER_MAP_MAX_SIZE];size_t length=0;CHECK(glims_lab_layer_map_encode(&st.map,map,sizeof map,&length),"malformed map setup");map[8]=99;GimpParasite *p=gimp_parasite_new(GLIMS_PLATE_MAP_PARASITE,GIMP_PARASITE_PERSISTENT,length,map);gimp_image_parasite_attach(im,p,FALSE);gimp_parasite_free(p);refusal(engine,im,st.layers[0].group,GLIMS_STATUS_UNSUPPORTED,"malformed whole carrier refuses");}
done:
 g_object_unref(foreign);g_object_unref(im);
 im=make(engine,0);if(im){refusal(engine,im,NULL,GLIMS_STATUS_INVALID_ARGUMENT,"empty carrier with NULL explicit target refuses");g_object_unref(im);}
}
static void maximum_case(GlimsEngine *engine) {
 GimpImage *im=make(engine,256);if(!im)return;GlimsLabLayerStorage st;gboolean ok=glims_lab_layer_storage_read(im,&st)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(ok,"maximum carrier validates");if(!ok){g_object_unref(im);return;}
 Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);CHECK(snapshot(im,before),"maximum baseline snapshot");char *error=NULL;
 GlimsStatus status=glims_lab_layer_delete(engine,im,st.layers[128].group,&error);CHECK(status==GLIMS_STATUS_OK&&error==NULL,"maximum-size carrier can delete a middle root");if(error)api->free_string(error);
 if(status==GLIMS_STATUS_OK){GlimsLabLayerStorage result;CHECK(glims_lab_layer_storage_read(im,&result)==GLIMS_LAB_LAYER_STORAGE_VALID&&result.map.count==255,"maximum deletion produces valid255-entry map");CHECK(gimp_image_undo(im)&&snapshot(im,after)&&same_state(before,after,FALSE),"maximum delete Undo restores all original native IDs/map/raw/selection");}
 g_free(after);g_free(before);g_object_unref(im);
}
static GlimsStatus worker(GlimsEngine *engine,gpointer work){for(guint scenario=0;scenario<5;scenario++)success_case(engine,work,scenario);refusal_cases(engine);maximum_case(engine);return GLIMS_STATUS_OK;}
int main(int argc,char **argv){if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start %s\n",error?error:"");api->free_string(error);return 2;}api->free_string(error);status=glims_engine_call(engine,worker,argv[1]);api->stop(engine);printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;}

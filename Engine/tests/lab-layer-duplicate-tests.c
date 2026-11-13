/* Private native duplication acceptance, independent of document adoption. */
#include "lab-layer-duplicate.h"
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
static void seed(GlimsLabLayerStorage *s,guint8 expected[2][4][N]) {
 for(guint i=0;i<2;i++)for(guint p=0;p<4;p++){for(guint x=0;x<N;x++)expected[i][p][x]=(19+97*i+37*p+47*x)&255;if(p==3){expected[i][p][0]=0;expected[i][p][1]=128;expected[i][p][2]=255;}put(s->layers[i].planes[p],expected[i][p]);}
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
static void select_pair(GimpImage *im,GimpLayer *first,GimpLayer *second){GList *list=g_list_append(NULL,first);list=g_list_append(list,second);gimp_image_set_selected_layers(im,list);g_list_free(list);}
static void refusal(GlimsEngine *engine,GimpImage *im,GimpLayer *source,GlimsStatus expected,const char *label) {
 Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);gboolean a=snapshot(im,before);CHECK(a,"refusal baseline snapshot succeeds");
 GimpLayer *copy=(GimpLayer*)im;char *error=NULL;GlimsStatus status=glims_lab_layer_duplicate(engine,im,source,&copy,&error);
 if(status!=expected)printf("STATUS %s actual=%d expected=%d error=%s\n",label,status,expected,error?error:"none");
 CHECK(status==expected,label);CHECK(copy==NULL,"refusal prezeros borrowed copy output");CHECK(error&&*error,"refusal gives meaningful owned error");if(error)api->free_string(error);
 gboolean b=snapshot(im,after);CHECK(a&&b&&same_state(before,after,TRUE),"refusal preserves complete tree/raw/map/selection/history/redo/dirty");g_free(after);g_free(before);
}
static gboolean role_bytes(const GlimsLabLayerNative *native,const guint8 data[4][N]) {
 for(guint p=0;p<4;p++){guint8 actual[N];if(!pixels(native->planes[p],actual)||memcmp(actual,data[p],N))return FALSE;}return TRUE;
}
static gboolean unique_map(const GlimsLabLayerMap *map) {
 for(guint i=0;i<map->count*5;i++){const guint8 *a=(const guint8*)&map->entries[i/5]+16*(i%5);guint any=0;for(guint b=0;b<16;b++)any|=a[b];if(!any)return FALSE;
  for(guint j=0;j<i;j++){const guint8 *b=(const guint8*)&map->entries[j/5]+16*(j%5);if(!memcmp(a,b,16))return FALSE;}}
 return TRUE;
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

static void success_case(GlimsEngine *engine,const char *work) {
 GimpImage *im=make(engine,2);if(!im)return;GlimsLabLayerStorage initial;
 gboolean valid=glims_lab_layer_storage_read(im,&initial)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(valid,"initial carrier validates");if(!valid){g_object_unref(im);return;}
 guint8 bytes[2][4][N];seed(&initial,bytes);GimpLayer *source=initial.layers[0].group,*other=initial.layers[1].group;
 CHECK(gimp_image_reorder_item(im,GIMP_ITEM(other),NULL,0,FALSE,NULL),"root order is independent of map order");
 CHECK(gimp_image_reorder_item(im,GIMP_ITEM(initial.layers[0].planes[3]),GIMP_ITEM(source),0,FALSE,NULL),"source child order is permuted before duplicate");
 gimp_item_set_visible(GIMP_ITEM(source),FALSE,FALSE);gimp_layer_set_opacity(source,.375,FALSE);select_pair(im,other,source);
 GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(im));float coverage=.375f,observed=0;
 gegl_buffer_set(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,0,1,1),0,babl_format("Y float"),&coverage,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(mask,1,0,1,1);
 gegl_buffer_get(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,0,1,1),1,babl_format("Y float"),&observed,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
 CHECK(observed>.37f&&observed<.38f&&!gimp_channel_is_empty(gimp_image_get_mask(im)),"success baseline positively has partial nonempty selection mask");
 gimp_layer_set_opacity(other,.25,TRUE);CHECK(gimp_image_undo(im),"success baseline creates a real redo branch");
 CHECK(gimp_undo_stack_get_depth(gimp_image_get_redo_stack(im))>0,"success baseline redo is nonempty");gimp_image_clean_all(im);
 Snapshot *before=g_new0(Snapshot,1),*created=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);CHECK(snapshot(im,before),"complete pre-duplicate baseline snapshot");
 CHECK(before->selected_count==2&&before->selected[0]==gimp_item_get_id(GIMP_ITEM(other))&&before->selected[1]==gimp_item_get_id(GIMP_ITEM(source)),"baseline has ordered plural selection with explicit source second");
 GimpLayer *copy=NULL;char *error=NULL;GlimsStatus status=glims_lab_layer_duplicate(engine,im,source,&copy,&error);
 CHECK(status==GLIMS_STATUS_OK&&copy&&error==NULL,"logical duplicate succeeds with borrowed copy");if(error)api->free_string(error);if(status!=GLIMS_STATUS_OK||!copy)goto done;
 GlimsLabLayerStorage st;valid=glims_lab_layer_storage_read(im,&st)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(valid,"duplicated carrier validates");if(!valid)goto done;
 CHECK(st.map.count==3&&st.layers[0].group==other&&st.layers[1].group==copy&&st.layers[2].group==source,"copy is directly above captured source, without moving other root");
 CHECK(st.layers[0].map_index==1&&st.layers[1].map_index==2&&st.layers[2].map_index==0,"new UUID map entry appends independent of native root order");
 CHECK(!memcmp(st.map.entries,initial.map.entries,2*sizeof initial.map.entries[0])&&unique_map(&st.map),"old map identities unchanged and every new role globally nonzero/distinct");
 CHECK(copy!=source&&gimp_item_get_id(GIMP_ITEM(copy))!=gimp_item_get_id(GIMP_ITEM(source)),"duplicate is a distinct native root");
 CHECK(!gimp_item_get_visible(GIMP_ITEM(copy))&&gimp_layer_get_opacity(copy)==.375,"hidden and partial-opacity source attrs preserved");
 CHECK(role_bytes(&st.layers[1],bytes[0])&&role_bytes(&st.layers[2],bytes[0])&&role_bytes(&st.layers[0],bytes[1]),"copy/source/other exact role bytes ignore permuted child order");
 for(guint p=0;p<4;p++)CHECK(st.layers[1].planes[p]!=st.layers[2].planes[p]&&gimp_drawable_get_buffer(GIMP_DRAWABLE(st.layers[1].planes[p]))!=gimp_drawable_get_buffer(GIMP_DRAWABLE(st.layers[2].planes[p])),"each copy role owns distinct native item/buffer");
 GList *selected=gimp_image_get_selected_layers(im);CHECK(g_list_length(selected)==1&&selected->data==copy,"success selects exactly new logical root");
 CHECK(gimp_undo_stack_get_depth(gimp_image_get_undo_stack(im))==before->undo+1&&gimp_undo_stack_get_depth(gimp_image_get_redo_stack(im))==0,"success creates exactly one Undo and clears redo");
 CHECK(snapshot(im,created),"created state snapshotted before Undo");
 CHECK(gimp_image_undo(im),"one native Undo succeeds");CHECK(snapshot(im,after)&&same_state(before,after,FALSE),"one Undo restores exact original tree/map/rolebytes/selection");CHECK(gimp_image_is_dirty(im)==before->dirty,"Undo restores original native dirty count");
 CHECK(gimp_image_redo(im),"one native Redo succeeds");CHECK(snapshot(im,after)&&same_state(created,after,FALSE),"Redo restores same copy IDs/UUIDs/raw/attrs/selection");
 CHECK(gimp_image_undo(im)&&gimp_image_redo(im),"second native Undo/Redo cycle succeeds");CHECK(snapshot(im,after)&&same_state(created,after,FALSE),"second Redo retains exact copy identity and data");
 gchar *path=g_build_filename(work,"duplicated-layered-lab.xcf",NULL);gboolean saved=save_xcf(engine->gimp,im,path);CHECK(saved,"duplicated carrier saves XCF");
 if(saved){GimpImage *opened=open_xcf(engine->gimp,path);if(opened){GlimsLabLayerStorage loaded;gboolean ok=glims_lab_layer_storage_read(opened,&loaded)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(ok,"fresh XCF carrier validates");if(ok)CHECK(!memcmp(&loaded.map,&st.map,sizeof st.map)&&loaded.layers[0].map_index==1&&loaded.layers[1].map_index==2&&loaded.layers[2].map_index==0&&role_bytes(&loaded.layers[0],bytes[1])&&role_bytes(&loaded.layers[1],bytes[0])&&role_bytes(&loaded.layers[2],bytes[0])&&!gimp_item_get_visible(GIMP_ITEM(loaded.layers[1].group))&&gimp_layer_get_opacity(loaded.layers[1].group)==.375,"XCF preserves complete UUID map, root order, raw roles and attrs without runtime-ID assumptions");g_object_unref(opened);}}
 g_free(path);
 /* Positive mutations only AFTER exact one-step Undo/Redo proof. */
 valid=glims_lab_layer_storage_read(im,&st)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(valid,"copy mutation setup validates");
 if(valid){guint8 copied[4][N];memcpy(copied,bytes[0],sizeof copied);for(guint p=0;p<4;p++){memset(copied[p],201+p,N);put(st.layers[1].planes[p],copied[p]);CHECK(role_bytes(&st.layers[1],copied),"chosen copy plane positively mutates while other copy planes stay exact");CHECK(role_bytes(&st.layers[2],bytes[0])&&role_bytes(&st.layers[0],bytes[1]),"each copy COW mutation leaves source and unrelated root unchanged");}}
done:
 g_free(after);g_free(created);g_free(before);g_object_unref(im);
}
static void refusal_cases(GlimsEngine *engine) {
 GimpImage *im=make(engine,2),*foreign=make(engine,1);if(!im||!foreign){if(im)g_object_unref(im);if(foreign)g_object_unref(foreign);return;}
 GlimsLabLayerStorage st,other;gboolean valid=glims_lab_layer_storage_read(im,&st)==GLIMS_LAB_LAYER_STORAGE_VALID&&glims_lab_layer_storage_read(foreign,&other)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(valid,"refusal sources validate");if(!valid)goto done;
 /* Nonempty redo must survive refusals. */
 gimp_layer_set_opacity(st.layers[0].group,.5,TRUE);CHECK(gimp_image_undo(im),"refusal fixture builds real native redo");CHECK(gimp_undo_stack_get_depth(gimp_image_get_redo_stack(im))>0,"redo control is nonempty");
 refusal(engine,im,other.layers[0].group,GLIMS_STATUS_NOT_FOUND,"foreign source refuses");
 refusal(engine,im,st.layers[0].planes[0],GLIMS_STATUS_UNSUPPORTED,"child source refuses");
 GimpLayer *detached=gimp_group_layer_new(im);CHECK(detached!=NULL,"detached source setup allocates");if(detached){refusal(engine,im,detached,GLIMS_STATUS_NOT_FOUND,"unattached source refuses");g_object_unref(detached);}
 engine->busy++;refusal(engine,im,st.layers[0].group,GLIMS_STATUS_BUSY,"engine busy refuses quietly");engine->busy--;
 CHECK(gimp_image_undo_freeze(im),"native Undo freeze setup");refusal(engine,im,st.layers[0].group,GLIMS_STATUS_BUSY,"frozen Undo refuses");CHECK(gimp_image_undo_thaw(im),"native Undo thaw cleanup");
 CHECK(gimp_image_undo_group_start(im,GIMP_UNDO_GROUP_LAYER_ADD,"fixture group"),"native existing group setup");refusal(engine,im,st.layers[0].group,GLIMS_STATUS_BUSY,"nested Undo group refuses");CHECK(gimp_image_undo_group_end(im),"native group cleanup");
 /* Disable legitimately clears history; preservation is measured after setup. */
 CHECK(gimp_image_undo_disable(im),"native Undo disable setup");refusal(engine,im,st.layers[0].group,GLIMS_STATUS_BUSY,"disabled Undo refuses");CHECK(gimp_image_undo_enable(im),"native Undo enable cleanup");
 Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);CHECK(snapshot(im,before),"null-output baseline snapshot");char *error=NULL;
 CHECK(glims_lab_layer_duplicate(engine,im,st.layers[0].group,NULL,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"NULL copy output refuses");if(error)api->free_string(error);CHECK(snapshot(im,after)&&same_state(before,after,TRUE),"NULL output refusal preserves complete state");
 GimpLayer *sentinel=(GimpLayer*)im;error=NULL;CHECK(glims_lab_layer_duplicate(NULL,im,st.layers[0].group,&sentinel,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&sentinel==NULL,"NULL engine refuses and prezeros output");if(error)api->free_string(error);CHECK(snapshot(im,after)&&same_state(before,after,TRUE),"NULL engine refusal preserves state");g_free(after);g_free(before);
 /* Malformed version preserves the damaged input, not a normalized replacement. */
 {guint8 map[GLIMS_LAB_LAYER_MAP_MAX_SIZE];size_t length=0;CHECK(glims_lab_layer_map_encode(&st.map,map,sizeof map,&length),"malformed map control encodes");map[8]=99;GimpParasite *p=gimp_parasite_new(GLIMS_PLATE_MAP_PARASITE,GIMP_PARASITE_PERSISTENT,length,map);gimp_image_parasite_attach(im,p,FALSE);gimp_parasite_free(p);refusal(engine,im,st.layers[0].group,GLIMS_STATUS_UNSUPPORTED,"malformed whole carrier refuses");}
done:
 g_object_unref(foreign);g_object_unref(im);
 im=make(engine,256);if(im){GlimsLabLayerStorage max;gboolean ok=glims_lab_layer_storage_read(im,&max)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(ok,"maximum carrier validates before refusal");if(ok)refusal(engine,im,max.layers[0].group,GLIMS_STATUS_UNSUPPORTED,"256 logical layer limit refuses");g_object_unref(im);}
}
static GlimsStatus worker(GlimsEngine *engine,gpointer work){success_case(engine,work);refusal_cases(engine);return GLIMS_STATUS_OK;}
int main(int argc,char **argv){if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start %s\n",error?error:"");api->free_string(error);return 2;}api->free_string(error);status=glims_engine_call(engine,worker,argv[1]);api->stop(engine);printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;}

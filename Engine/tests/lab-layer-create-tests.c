/* Independent creation acceptance from lab-layer-create.h; no adoption. */
#include "lab-layer-create.h"
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
typedef struct {gint id,parent,index;gboolean group,visible,named;gint x,y,width,height,mode,blend,composite,composite_mode;gboolean lock_content,lock_position,lock_visibility,lock_alpha;gdouble opacity;guint8 raw[N],uuid[16];gulong uuid_flags;guint uuid_size;gchar name[1100];} Item;
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

static const Item *find_uuid(const Snapshot *s,const guint8 uuid[16]) {
 for(guint i=0;i<s->count;i++)if(s->items[i].uuid_size==16&&!memcmp(s->items[i].uuid,uuid,16))return &s->items[i];
 return NULL;
}
static gboolean old_items_preserved(const Snapshot *before,const Snapshot *after,gint index) {
 if(after->count!=before->count+5||after->mask_size!=before->mask_size||memcmp(after->mask,before->mask,sizeof before->mask))return FALSE;
 for(guint i=0;i<before->count;i++) {
  Item expected=before->items[i];const Item *now=find_item(after,expected.id);if(!now)return FALSE;
  if(expected.parent==0&&expected.index>=index)expected.index++;
  if(memcmp(&expected,now,sizeof expected))return FALSE;
 }
 return TRUE;
}
static const guint8 *identity(const GlimsLabLayerEntry *e,guint role) {
 switch(role){case 0:return e->group;case 1:return e->l;case 2:return e->a;case 3:return e->b;default:return e->alpha;}
}
static gboolean identities_fresh(const GlimsLabLayerMap *old,const GlimsLabLayerEntry *fresh) {
 const guint8 zero[16]={0};
 for(guint r=0;r<5;r++) {
  const guint8 *id=identity(fresh,r);if(!memcmp(id,zero,16))return FALSE;
  for(guint q=0;q<r;q++)if(!memcmp(id,identity(fresh,q),16))return FALSE;
  for(guint i=0;i<old->count;i++)for(guint q=0;q<5;q++)if(!memcmp(id,identity(&old->entries[i],q),16))return FALSE;
 }
 return TRUE;
}
static gboolean initial_bytes(const GlimsLabLayerNative *layer) {
 const guint8 literal[4]={255,128,128,0};
 for(guint role=0;role<4;role++){guint8 got[N];if(!pixels(layer->planes[role],got))return FALSE;for(guint x=0;x<N;x++)if(got[x]!=literal[role])return FALSE;}
 return TRUE;
}
static void mask_and_redo(GimpImage *im) {
 GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(im));float value=.375f,observed=0;
 gegl_buffer_set(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,0,1,1),0,babl_format("Y float"),&value,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(mask,1,0,1,1);
 gegl_buffer_get(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,0,1,1),1,babl_format("Y float"),&observed,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
 CHECK(observed>.37f&&observed<.38f&&!gimp_channel_is_empty(gimp_image_get_mask(im)),"baseline positively has partial nonempty selection mask");
 const guint8 byte=37;GimpParasite *p=gimp_parasite_new("fixture/create-redo",GIMP_PARASITE_PERSISTENT|GIMP_PARASITE_UNDOABLE,1,&byte);
 CHECK(p!=NULL,"native redo control parasite allocates");if(!p)return;
 gimp_image_parasite_attach(im,p,TRUE);gimp_parasite_free(p);
 CHECK(gimp_image_undo(im),"baseline creates real native redo branch");
 CHECK(!gimp_image_parasite_find(im,"fixture/create-redo")&&gimp_undo_stack_get_depth(gimp_image_get_redo_stack(im))>0,"redo control is positive and restored metadata is absent");
 gimp_image_clean_all(im);
}
static gboolean map_appended(const GlimsLabLayerMap *old,const GlimsLabLayerMap *now) {
 return now->width==old->width&&now->height==old->height&&now->mode==old->mode&&now->storage==old->storage&&now->encoding==old->encoding&&now->count==old->count+1&&
  !memcmp(now->entries,old->entries,old->count*sizeof old->entries[0])&&identities_fresh(old,&now->entries[old->count]);
}
static gboolean stack_matches(const GlimsLabLayerStorage *old,const GlimsLabLayerStorage *now,gint index,GimpLayer *made) {
 for(guint i=0;i<now->map.count;i++) {
  if(i==(guint)index){if(now->layers[i].group!=made||now->layers[i].map_index!=old->map.count)return FALSE;}
  else {guint prior=i-(i>(guint)index);if(now->layers[i].group!=old->layers[prior].group||now->layers[i].map_index!=old->layers[prior].map_index)return FALSE;}
 }
 return TRUE;
}
static void success_case(GlimsEngine *engine,const char *work,guint scenario) {
 const guint count=(scenario==0||scenario==5)?0:3;
 const gint index=scenario==0||scenario==1||scenario==5?0:scenario==2?1:scenario==3?3:2;
 gchar boundary[1025];for(guint i=0;i<1024;i+=2){boundary[i]=(gchar)0xc3;boundary[i+1]=(gchar)0xa9;}boundary[1024]=0;
 const char *name=scenario==0?NULL:scenario==1?"":scenario==2?"Crème 🧪":scenario==5?boundary:"Created end";
 const char *expected_name=name&&*name?name:"Layer";
 GimpImage *im=make(engine,count);if(!im)return;
 GlimsLabLayerStorage old;gboolean valid=glims_lab_layer_storage_read(im,&old)==GLIMS_LAB_LAYER_STORAGE_VALID;
 CHECK(valid,"creation control carrier validates");if(!valid){g_object_unref(im);return;}
 guint8 bytes[3][4][N];if(count) {
  seed(&old,count,bytes);
  CHECK(gimp_image_reorder_item(im,GIMP_ITEM(old.layers[2].group),NULL,0,FALSE,NULL),"old native stack intentionally differs from map order");
  CHECK(gimp_image_reorder_item(im,GIMP_ITEM(old.layers[0].planes[3]),GIMP_ITEM(old.layers[0].group),0,FALSE,NULL),"old child order intentionally differs from physical roles");
  gimp_item_set_visible(GIMP_ITEM(old.layers[0].group),FALSE,FALSE);gimp_layer_set_opacity(old.layers[0].group,.375,FALSE);
 }
 GimpLayer *picks[3];guint picked=0;
 if(scenario==2){picks[0]=old.layers[1].group;picks[1]=old.layers[2].group;picks[2]=old.layers[0].group;picked=3;}
 else if(scenario==3){picks[0]=old.layers[0].planes[2];picks[1]=old.layers[1].planes[1];picked=2;}
 else if(scenario==4){picks[0]=old.layers[2].group;picked=1;}
 select_items(im,picks,picked);mask_and_redo(im);
 gint before_ids[3];for(guint i=0;i<picked;i++)before_ids[i]=gimp_item_get_id(GIMP_ITEM(picks[i]));
 CHECK(selected_is(im,before_ids,picked),"actual prior native selection is exact, including empty/plural/scalar cases");
 CHECK(glims_lab_layer_storage_read(im,&old)==GLIMS_LAB_LAYER_STORAGE_VALID,"fresh pre-create storage captures permuted native order");
 Snapshot *before=g_new0(Snapshot,1),*created=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);
 CHECK(snapshot(im,before),"complete creation baseline snapshots");
 GimpLayer *made=(GimpLayer*)im;char *error=NULL;
 GlimsStatus status=glims_lab_layer_create(engine,im,index,name,&made,&error);
 printf("CREATE scenario=%u index=%d count=%u status=%d\n",scenario,index,count,status);
 CHECK(status==GLIMS_STATUS_OK&&made&&error==NULL,"logical creation succeeds with borrowed root");if(error)api->free_string(error);if(status!=GLIMS_STATUS_OK||!made)goto done;
 GlimsLabLayerStorage now;valid=glims_lab_layer_storage_read(im,&now)==GLIMS_LAB_LAYER_STORAGE_VALID;
 CHECK(valid,"created native carrier validates");if(!valid)goto done;
 CHECK(map_appended(&old.map,&now.map),"map appends five independently checked fresh nonzero identities without changing old entries");
 CHECK(stack_matches(&old,&now,index,made),"exact native insertion index is independent of appended map membership");
 CHECK(now.layers[index].group==made&&initial_bytes(&now.layers[index]),"new full-canvas raw planes are literal L255 a128 b128 alpha0");
 CHECK(gimp_item_get_visible(GIMP_ITEM(made))&&gimp_layer_get_opacity(made)==1&&gimp_layer_get_mode(made)==GIMP_LAYER_MODE_NORMAL,"new logical root is visible opacity1 Normal");
 CHECK(!strcmp(gimp_object_get_name(made),expected_name),"NULL/empty, UTF8 and 1024-byte names have exact contract values");
 gint made_id=gimp_item_get_id(GIMP_ITEM(made));CHECK(selected_is(im,&made_id,1),"creation selects exactly new logical root");
 CHECK(snapshot(im,created)&&old_items_preserved(before,created,index),"every old native item/rolebyte/UUID/attribute and full mask remains exact");
 CHECK(created->undo==before->undo+1&&created->redo==0,"creation adds exactly one Undo and clears actual redo branch");
 CHECK(gimp_image_undo(im),"one creation Undo succeeds");CHECK(snapshot(im,after)&&same_state(before,after,FALSE),"one Undo restores exact original tree/map/raw/mask/ordered selection including empty");CHECK(gimp_image_is_dirty(im)==before->dirty,"Undo restores original native dirty count");
 CHECK(gimp_image_redo(im),"creation Redo succeeds");CHECK(snapshot(im,after)&&same_state(created,after,FALSE),"Redo restores same new native IDs UUIDs raw data attrs and selection");
 CHECK(gimp_image_undo(im)&&gimp_image_redo(im),"second create Undo/Redo cycle succeeds");CHECK(snapshot(im,after)&&same_state(created,after,FALSE),"second Redo retains exact created state");
 gchar *leaf=g_strdup_printf("created-case-%u.xcf",scenario),*path=g_build_filename(work,leaf,NULL);g_free(leaf);
 gboolean saved=save_xcf(engine->gimp,im,path);CHECK(saved,"created carrier saves real XCF");
 if(saved) {
  GimpImage *opened=open_xcf(engine->gimp,path);
  if(opened) {
   GlimsLabLayerStorage loaded;
   gboolean ok=glims_lab_layer_storage_read(opened,&loaded)==GLIMS_LAB_LAYER_STORAGE_VALID;
   CHECK(ok&&loaded.map.count==count+1&&!memcmp(&loaded.map,&now.map,sizeof now.map),
         "fresh XCF preserves complete created UUID map exactly");
   if(ok&&loaded.map.count==count+1) {
    for(guint i=0;i<loaded.map.count;i++) {
     guint member=loaded.layers[i].map_index;
     GimpLayer *group=loaded.layers[i].group;
     CHECK(member==now.layers[i].map_index,"fresh XCF preserves native stack independent of map order");
     if(member==count) {
      CHECK(initial_bytes(&loaded.layers[i])&&!strcmp(gimp_object_get_name(group),expected_name),
            "fresh XCF preserves new literal scalar bytes and complete name");
      CHECK(gimp_item_get_visible(GIMP_ITEM(group))&&gimp_layer_get_opacity(group)==1&&
            gimp_layer_get_mode(group)==GIMP_LAYER_MODE_NORMAL,"fresh XCF preserves new visible opacity1 Normal root");
     } else {
      CHECK(member<count&&role_bytes(&loaded.layers[i],bytes[member]),
            "fresh XCF preserves every original raw physical role");
      const Item *prior=member<count?find_uuid(before,old.map.entries[member].group):NULL;
      CHECK(prior&&prior->group&&!strcmp(gimp_object_get_name(group),prior->name)&&
            gimp_item_get_visible(GIMP_ITEM(group))==prior->visible&&
            gimp_layer_get_opacity(group)==prior->opacity,"fresh XCF preserves original root name visibility and opacity by UUID");
     }
    }
   }
   Snapshot *reopened=g_new0(Snapshot,1);
   CHECK(snapshot(opened,reopened)&&reopened->mask_size==created->mask_size&&
         !memcmp(reopened->mask,created->mask,sizeof created->mask),"fresh XCF preserves complete nonempty selection mask");
   g_free(reopened);g_object_unref(opened);
  }
 }

 g_free(path);
 done:g_free(after);g_free(created);g_free(before);g_object_unref(im);
}
static void refusal(GlimsEngine *engine,GimpImage *im,gint index,const char *name,GlimsStatus expected,const char *label) {
 Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);gboolean a=snapshot(im,before);CHECK(a,"refusal baseline snapshots complete state");
 GimpLayer *made=(GimpLayer*)im;char *error=NULL;GlimsStatus status=glims_lab_layer_create(engine,im,index,name,&made,&error);
 if(status!=expected)printf("STATUS %s actual=%d expected=%d error=%s\n",label,status,expected,error?error:"none");
 CHECK(status==expected,label);CHECK(made==NULL,"refusal clears borrowed root output");CHECK(error&&*error,"refusal returns meaningful owned error");if(error)api->free_string(error);
 CHECK(snapshot(im,after)&&a&&same_state(before,after,TRUE),"refusal preserves whole tree/raw/map/selection/mask/history/Redo/dirty");g_free(after);g_free(before);
}
static void refusal_cases(GlimsEngine *engine) {
 GimpImage *im=make(engine,3);if(!im)return;mask_and_redo(im);
 refusal(engine,im,-1,"bad",GLIMS_STATUS_INVALID_ARGUMENT,"negative insertion refuses");
 refusal(engine,im,4,"bad",GLIMS_STATUS_INVALID_ARGUMENT,"past-end insertion refuses");
 refusal(engine,im,G_MAXINT32,"bad",GLIMS_STATUS_INVALID_ARGUMENT,"huge insertion refuses");
 const char invalid_utf8[]={(char)0xc3,'(',0};refusal(engine,im,1,invalid_utf8,GLIMS_STATUS_INVALID_ARGUMENT,"invalid UTF8 name refuses");
 char oversized[1026];memset(oversized,'x',1025);oversized[1025]=0;refusal(engine,im,1,oversized,GLIMS_STATUS_INVALID_ARGUMENT,"1025-byte name refuses");
 engine->busy++;refusal(engine,im,1,"busy",GLIMS_STATUS_BUSY,"busy engine refuses");engine->busy--;
 CHECK(gimp_image_undo_freeze(im),"freeze control starts");refusal(engine,im,1,"frozen",GLIMS_STATUS_BUSY,"frozen Undo refuses");CHECK(gimp_image_undo_thaw(im),"freeze control thaws");
 CHECK(gimp_image_undo_group_start(im,GIMP_UNDO_GROUP_LAYER_ADD,"fixture group"),"group control starts");refusal(engine,im,1,"grouped",GLIMS_STATUS_BUSY,"active Undo group refuses");CHECK(gimp_image_undo_group_end(im),"group control closes");
 CHECK(gimp_image_undo_disable(im),"disable control starts");refusal(engine,im,1,"disabled",GLIMS_STATUS_BUSY,"disabled Undo refuses");CHECK(gimp_image_undo_enable(im),"disable control enables");
 Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);CHECK(snapshot(im,before),"NULL argument baseline snapshots");char *error=NULL;
 CHECK(glims_lab_layer_create(engine,im,0,"null",NULL,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"NULL output refuses");if(error)api->free_string(error);CHECK(snapshot(im,after)&&same_state(before,after,TRUE),"NULL output preserves whole state");
 GimpLayer *made=(GimpLayer*)im;error=NULL;CHECK(glims_lab_layer_create(NULL,im,0,"null",&made,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&made==NULL,"NULL engine refuses and clears output");if(error)api->free_string(error);CHECK(snapshot(im,after)&&same_state(before,after,TRUE),"NULL engine preserves whole state");
 made=(GimpLayer*)im;error=NULL;CHECK(glims_lab_layer_create(engine,NULL,0,"null",&made,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&made==NULL,"NULL image refuses and clears output");if(error)api->free_string(error);CHECK(snapshot(im,after)&&same_state(before,after,TRUE),"NULL image preserves live carrier state");g_free(after);g_free(before);
 GlimsLabLayerStorage st;CHECK(glims_lab_layer_storage_read(im,&st)==GLIMS_LAB_LAYER_STORAGE_VALID,"malformed control starts valid");guint8 encoded[GLIMS_LAB_LAYER_MAP_MAX_SIZE];size_t length=0;CHECK(glims_lab_layer_map_encode(&st.map,encoded,sizeof encoded,&length),"malformed control map encodes");encoded[8]=99;
 GimpParasite *p=gimp_parasite_new(GLIMS_PLATE_MAP_PARASITE,GIMP_PARASITE_PERSISTENT,length,encoded);gimp_image_parasite_attach(im,p,FALSE);gimp_parasite_free(p);refusal(engine,im,1,"malformed",GLIMS_STATUS_UNSUPPORTED,"malformed whole carrier refuses");g_object_unref(im);
 im=make(engine,256);if(im){mask_and_redo(im);refusal(engine,im,256,"over limit",GLIMS_STATUS_UNSUPPORTED,"256 logical root cap refuses");g_object_unref(im);}
}
static void capacity_success(GlimsEngine *engine) {
 GimpImage *im=make(engine,255);if(!im)return;Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);CHECK(snapshot(im,before),"255-root baseline snapshots");
 GimpLayer *made=NULL;char *error=NULL;GlimsStatus status=glims_lab_layer_create(engine,im,255,"Last permitted",&made,&error);CHECK(status==GLIMS_STATUS_OK&&made&&error==NULL,"255-root carrier admits exact capacity/end insertion");if(error)api->free_string(error);
 if(status==GLIMS_STATUS_OK&&made){GlimsLabLayerStorage st;gboolean ok=glims_lab_layer_storage_read(im,&st)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(ok&&st.map.count==256&&st.layers[255].group==made&&initial_bytes(&st.layers[255]),"capacity success has256 roots and literal new scalar bytes");CHECK(snapshot(im,after)&&old_items_preserved(before,after,255),"capacity success preserves every old item and mask");CHECK(gimp_image_undo(im)&&snapshot(im,after)&&same_state(before,after,FALSE),"capacity Undo restores every original object raw byte map and selection");CHECK(gimp_image_redo(im),"capacity Redo succeeds");}
 g_free(after);g_free(before);g_object_unref(im);
}
static GlimsStatus worker(GlimsEngine *engine,gpointer work) {
 for(guint scenario=0;scenario<6;scenario++)success_case(engine,work,scenario);
 refusal_cases(engine);capacity_success(engine);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
 if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
 gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
 GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;
 GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);
 if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start %s\n",error?error:"");api->free_string(error);return 2;}
 api->free_string(error);status=glims_engine_call(engine,worker,argv[1]);api->stop(engine);
 printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;
}

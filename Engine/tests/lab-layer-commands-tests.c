/* Independent private create/duplicate/delete/preview workflow. */
#include "lab-layer-delete.h"
#include "lab-layer-create.h"
#include "lab-layer-duplicate.h"
#include "lab-layer-preview-read.h"
#include <math.h>
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
static void preview_matches(GimpImage *image,GlimsLabLayerPreview **preview,gboolean opaque) {
 Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);CHECK(snapshot(image,before),"workflow preview baseline snapshot");
 const GlimsRect areas[]={{0,0,W,H},{1,1,1,1}};
 for(guint a=0;a<G_N_ELEMENTS(areas);a++) {
  float output[N*4];memset(output,0xa5,sizeof output);
  GlimsStatus status=glims_lab_layer_preview_read(image,preview,1,areas[a],output,(size_t)areas[a].width*4*sizeof(float));
  CHECK(status==GLIMS_STATUS_OK&&*preview&&glims_lab_layer_preview_succeeded(*preview),"same preview slot validates across topology transition");
  if(status==GLIMS_STATUS_OK)for(gint i=0;i<areas[a].width*areas[a].height;i++)for(guint c=0;c<4;c++) {
   float actual=output[4*i+c];
   if(opaque)CHECK(isfinite(actual)&&fabs(actual-1)<(c==3?1e-7:2e-5),"populated workflow is literal straight linear white with alpha1");
   else CHECK(actual==0&&!signbit(actual),"empty/new workflow preview is canonical transparent positivezero");
  }
 }
 CHECK(snapshot(image,after)&&same_state(before,after,TRUE),"workflow preview preserves exact raw/map/mask/selection/history/dirty");g_free(after);g_free(before);
}
static gboolean single_selected(GimpImage *image,gint id) {
 GList *selected=gimp_image_get_selected_layers(image);return selected&&selected->next==NULL&&gimp_item_get_id(selected->data)==id;
}
static gboolean literal_planes(const GlimsLabLayerNative *root,gboolean opaque) {
 for(guint p=0;p<4;p++){guint8 actual[N];if(!pixels(root->planes[p],actual))return FALSE;guint8 expected=p==0?255:p==3?(opaque?255:0):128;for(guint i=0;i<N;i++)if(actual[i]!=expected)return FALSE;}return TRUE;
}
static gboolean unique_map(const GlimsLabLayerMap *map) {
 for(guint i=0;i<map->count*5;i++){const guint8 *id=(const guint8*)&map->entries[i/5]+16*(i%5);guint any=0;for(guint k=0;k<16;k++)any|=id[k];if(!any)return FALSE;for(guint j=0;j<i;j++)if(!memcmp(id,(const guint8*)&map->entries[j/5]+16*(j%5),16))return FALSE;}return TRUE;
}
static void stage(GimpImage *image,GlimsLabLayerPreview **preview,const Snapshot *expected,gint undo,gint redo,gboolean opaque,const char *label) {
 Snapshot *actual=g_new0(Snapshot,1);gboolean ok=snapshot(image,actual);
 if(!ok||!same_state(expected,actual,FALSE))printf("STATE_MISMATCH %s\n",label);
 CHECK(ok&&same_state(expected,actual,FALSE),label);
 CHECK(actual->undo==undo&&actual->redo==redo,"workflow native history depths match exact operation sequence");
 preview_matches(image,preview,opaque);g_free(actual);
}
static void prove_current_source(GimpImage *image,GlimsLabLayerPreview **preview,const char *label) {
 Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);GlimsLabLayerStorage st;
 gboolean valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID&&st.map.count==1;
 CHECK(valid,label);if(!valid){g_free(after);g_free(before);return;}
 guint8 saved[N],transparent[N]={0};gboolean read=pixels(st.layers[0].planes[3],saved),opaque=read;
 for(guint i=0;i<N&&opaque;i++)opaque=saved[i]==255;
 CHECK(opaque,"cache witness positively starts with opaque sole attached source");
 gboolean captured=snapshot(image,before);CHECK(captured,"cache witness baseline snapshot");
 if(opaque&&captured&&put(st.layers[0].planes[3],transparent)) {
  CHECK(gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==before->undo&&gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image))==before->redo,"temporary direct alpha edit adds no history");
  preview_matches(image,preview,FALSE);
  put(st.layers[0].planes[3],saved);
  CHECK(snapshot(image,after)&&same_state(before,after,TRUE),"restoring alpha restores exact source/raw/map/mask/selection/history/dirty state");
  preview_matches(image,preview,TRUE);
 }
 g_free(after);g_free(before);
}
static GlimsStatus worker(GlimsEngine *engine,gpointer unused) {
 (void)unused;GimpImage *image=make(engine,0);if(!image)return GLIMS_STATUS_OK;
 GlimsLabLayerPreview *preview=NULL;Snapshot *empty=g_new0(Snapshot,1),*original=g_new0(Snapshot,1),*doubled=g_new0(Snapshot,1),*removed=g_new0(Snapshot,1);
 GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(image));float coverage=.375f,observed=0;
 gegl_buffer_set(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,0,1,1),0,babl_format("Y float"),&coverage,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(mask,1,0,1,1);
 gegl_buffer_get(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(1,0,1,1),1,babl_format("Y float"),&observed,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
 CHECK(observed>.37f&&observed<.38f&&!gimp_channel_is_empty(gimp_image_get_mask(image)),"workflow positively seeds partial nonempty mask");gimp_image_clean_all(image);
 CHECK(snapshot(image,empty)&&empty->count==0&&empty->selected_count==0,"workflow begins exact empty carrier with empty layer selection");stage(image,&preview,empty,0,0,FALSE,"initial empty state");
 GimpLayer *root=NULL;char *error=NULL;GlimsStatus status=glims_lab_layer_create(engine,image,0,"Workflow",&root,&error);
 CHECK(status==GLIMS_STATUS_OK&&root&&error==NULL,"workflow creates explicit logical root");if(error)api->free_string(error);if(status!=GLIMS_STATUS_OK||!root)goto done;
 GlimsLabLayerStorage st;gboolean valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID&&st.map.count==1;
 CHECK(valid&&st.map.count==1&&st.layers[0].group==root&&unique_map(&st.map)&&literal_planes(&st.layers[0],FALSE),"created root has fresh UUIDs and independent literal transparent plane values");if(!valid)goto done;
 gint root_id=gimp_item_get_id(GIMP_ITEM(root));GlimsLabLayerMap first_map=st.map;
 CHECK(single_selected(image,root_id),"creation selects exactly new logical root");
 CHECK(snapshot(image,original)&&original->mask_size==empty->mask_size&&!memcmp(original->mask,empty->mask,sizeof empty->mask),"creation preserves independently seeded initial mask bytes");preview_matches(image,&preview,FALSE);
 guint8 alpha[N];memset(alpha,255,N);put(st.layers[0].planes[3],alpha);
 guint8 readback[N];CHECK(pixels(st.layers[0].planes[3],readback)&&!memcmp(readback,alpha,N)&&literal_planes(&st.layers[0],TRUE),"opaque alpha write is positively read without changing L/a/b");
 CHECK(snapshot(image,original),"created object with live opaque pixels captured");stage(image,&preview,original,1,0,TRUE,"created root after explicit non-Undo fixture write");
 /* Resolve fresh native membership after every edit; no borrowed root survives edits. */
 valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID&&st.map.count==1;CHECK(valid,"fresh duplicate target resolves");if(!valid)goto done;
 GimpLayer *copy=NULL;error=NULL;status=glims_lab_layer_duplicate(engine,image,st.layers[0].group,&copy,&error);
 CHECK(status==GLIMS_STATUS_OK&&copy&&error==NULL,"workflow duplicates explicit original");if(error)api->free_string(error);if(status!=GLIMS_STATUS_OK||!copy)goto done;
 gint copy_id=gimp_item_get_id(GIMP_ITEM(copy));valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID&&st.map.count==2;
 CHECK(valid&&st.map.count==2&&unique_map(&st.map)&&!memcmp(&st.map.entries[0],&first_map.entries[0],sizeof first_map.entries[0])&&st.layers[0].map_index==1&&st.layers[1].map_index==0&&gimp_item_get_id(GIMP_ITEM(st.layers[1].group))==root_id&&literal_planes(&st.layers[0],TRUE)&&literal_planes(&st.layers[1],TRUE),"duplicate appends five disjoint UUIDs, preserves original, and orders copy above original with opaque raw data");if(!valid)goto done;
 GlimsLabLayerMap two_map=st.map;CHECK(single_selected(image,copy_id),"duplicate selects exactly copy");CHECK(snapshot(image,doubled),"duplicated state captured");CHECK(doubled->mask_size==empty->mask_size&&!memcmp(doubled->mask,empty->mask,sizeof empty->mask),"duplication preserves independently seeded initial mask bytes");stage(image,&preview,doubled,2,0,TRUE,"after duplicate");
 valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID&&st.map.count==2&&st.layers[1].map_index==0&&gimp_item_get_id(GIMP_ITEM(st.layers[1].group))==root_id;CHECK(valid,"fresh explicit original resolves beneath copy");if(!valid)goto done;
 error=NULL;status=glims_lab_layer_delete(engine,image,st.layers[1].group,&error);
 CHECK(status==GLIMS_STATUS_OK&&error==NULL,"workflow deletes explicit original rather than selected copy");if(error)api->free_string(error);if(status!=GLIMS_STATUS_OK)goto done;
 valid=glims_lab_layer_storage_read(image,&st)==GLIMS_LAB_LAYER_STORAGE_VALID&&st.map.count==1;
 CHECK(valid&&st.map.count==1&&st.layers[0].map_index==0&&gimp_item_get_id(GIMP_ITEM(st.layers[0].group))==copy_id&&!memcmp(&st.map.entries[0],&two_map.entries[1],sizeof two_map.entries[1])&&literal_planes(&st.layers[0],TRUE),"delete compacts same copy UUIDs/raw and retains copy native identity");if(!valid)goto done;
 CHECK(single_selected(image,copy_id),"deleting unselected original retains selected surviving copy");CHECK(snapshot(image,removed),"deleted state captured");CHECK(removed->mask_size==empty->mask_size&&!memcmp(removed->mask,empty->mask,sizeof empty->mask),"deletion preserves independently seeded initial mask bytes");stage(image,&preview,removed,3,0,TRUE,"after delete original");
 prove_current_source(image,&preview,"copy-only cache binds surviving copy, not deleted original");
 CHECK(gimp_image_undo(image),"Undo1 reverses deletion");stage(image,&preview,doubled,2,1,TRUE,"Undo deletion exact duplicated state");
 CHECK(gimp_image_undo(image),"Undo2 reverses duplication");stage(image,&preview,original,1,2,TRUE,"Undo duplicate exact original opaque state");
 prove_current_source(image,&preview,"original-only cache binds restored original, not removed copy");
 CHECK(gimp_image_undo(image),"Undo3 reverses creation");stage(image,&preview,empty,0,3,FALSE,"Undo creation exact original empty carrier and selection");
 CHECK(gimp_image_redo(image),"Redo1 restores created object");stage(image,&preview,original,1,2,TRUE,"Redo creation retains original IDs/UUIDs and live opaque pixel edit");
 CHECK(gimp_image_redo(image),"Redo2 restores same duplicate");stage(image,&preview,doubled,2,1,TRUE,"Redo duplicate retains both objects and copy identities");
 CHECK(gimp_image_redo(image),"Redo3 repeats explicit original deletion");stage(image,&preview,removed,3,0,TRUE,"final Redo retains exact same copy-only map/native IDs/raw/mask/selection");
done:
 glims_lab_layer_preview_free(preview);g_free(removed);g_free(doubled);g_free(original);g_free(empty);g_object_unref(image);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv){if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start %s\n",error?error:"");api->free_string(error);return 2;}api->free_string(error);status=glims_engine_call(engine,worker,NULL);api->stop(engine);printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;}

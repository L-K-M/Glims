/* Internal admission proof. The flag is synthetic: no public component mode. */
#include "facade-policy.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include <stdio.h>
#include <string.h>
static const GlimsEngineAPI *api;
static unsigned checks,failures;
#define CHECK(c,s) do {gboolean pass=(c);checks++;printf("%s %s\n",pass?"ok":"FAIL",s);if(!pass)failures++;fflush(stdout);}while(0)
typedef struct {GlimsImageID image;gboolean flagged;GlimsStatus result;GlimsPixelBuffer pixels;GlimsUndoInfo undo;} State;
static GlimsStatus mark(GlimsEngine *e,gpointer p){State*s=p;GlimsOpenImage*o=glims_lookup_image(e,s->image);if(!o)return GLIMS_STATUS_NOT_FOUND;o->component_document=s->flagged;return GLIMS_STATUS_OK;}
static GlimsStatus oracle(GlimsEngine*e,gpointer p){State*s=p;GlimsStatus status=glims_image_undo_info(e,s->image,&s->undo);if(status!=GLIMS_STATUS_OK)return status;return glims_image_copy_pixels(e,s->image,TRUE,&s->pixels,NULL);}
static GlimsStatus callback(GlimsEngine*e,gpointer p){(void)e;(*(unsigned*)p)++;return GLIMS_STATUS_OK;}
static GlimsStatus inline_call(GlimsEngine*e,gpointer p){State*s=p;s->result=api->image_clear(e,s->image,NULL,NULL);return GLIMS_STATUS_OK;}
static gboolean direct_op(GlimsFacadeOperation op){
  return op==GLIMS_FACADE_OP_start||op==GLIMS_FACADE_OP_stop||op==GLIMS_FACADE_OP_free_string||op==GLIMS_FACADE_OP_engine_version||op==GLIMS_FACADE_OP_free_pixels||op==GLIMS_FACADE_OP_free_metadata_strings||op==GLIMS_FACADE_OP_metadata_languages_free||op==GLIMS_FACADE_OP_free_curves_snapshot||op==GLIMS_FACADE_OP_free_histogram_snapshot;
}
static gboolean cleanup_op(GlimsFacadeOperation op){return op==GLIMS_FACADE_OP_image_close||op==GLIMS_FACADE_OP_stroke_end||op==GLIMS_FACADE_OP_filter_abort||op==GLIMS_FACADE_OP_procedure_cancel;}
static void matrix(GlimsEngine*engine,GlimsFacadeTargetKind kind,int32_t id){
  for(unsigned i=0;i<GLIMS_FACADE_OPERATION_COUNT;i++){
    if(glims_facade_target_kind(i)!=kind)continue;
    unsigned reached=0;
    GlimsStatus want=direct_op(i)?GLIMS_STATUS_INVALID_ARGUMENT:kind==GLIMS_FACADE_TARGET_NONE||cleanup_op(i)?GLIMS_STATUS_OK:GLIMS_STATUS_UNSUPPORTED;
    GlimsStatus got=glims_facade_call(engine,i,(GlimsFacadeTarget){kind,id,{0,0}},callback,&reached,NULL);
    CHECK(got==want && reached==(want==GLIMS_STATUS_OK),glims_facade_operation_name(i));
  }
}
static gboolean equal(State*a,State*b){return a->pixels.byte_count==b->pixels.byte_count && !memcmp(a->pixels.pixels,b->pixels.pixels,a->pixels.byte_count) && a->undo.undo_count==b->undo.undo_count && a->undo.redo_count==b->undo.redo_count;}
int main(int argc,char**argv){
  if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar*user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine*engine=NULL;char*error=NULL;
  if(api->start(&config,&engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"%s\n",error?error:"startup failed");return 2;}
  State owned={0},ordinary={0};
  CHECK(api->image_new(engine,24,16,&owned.image,&error)==GLIMS_STATUS_OK,"owned witness starts ordinary");
  CHECK(api->image_new(engine,24,16,&ordinary.image,&error)==GLIMS_STATUS_OK,"second ordinary document opens");
  if(!owned.image||!ordinary.image)goto cleanup;
  GlimsLayerInfo layer[1];int32_t count=0;
  CHECK(api->image_layers(engine,owned.image,layer,1,&count)==GLIMS_STATUS_OK&&count==1,"owned witness has one stable source drawable");
  GlimsItemID source=layer[0].id;
  CHECK(glims_engine_call(engine,oracle,&owned)==GLIMS_STATUS_OK,"capture raw pixels and Undo before admission refusals");
  owned.flagged=TRUE;CHECK(glims_engine_call(engine,mark,&owned)==GLIMS_STATUS_OK,"mark synthetic component ownership only on engine thread");
  matrix(engine,GLIMS_FACADE_TARGET_NONE,0);matrix(engine,GLIMS_FACADE_TARGET_IMAGE,owned.image);matrix(engine,GLIMS_FACADE_TARGET_ALL_IMAGES,0);
  CHECK(api->image_clear(engine,owned.image,NULL,&error)==GLIMS_STATUS_UNSUPPORTED,"actual queued clear refuses before mutation");api->free_string(error);error=NULL;
  CHECK(glims_engine_call(engine,inline_call,&owned)==GLIMS_STATUS_OK && owned.result==GLIMS_STATUS_UNSUPPORTED,"actual inline engine-thread clear also refuses");
  CHECK(api->image_transform(engine,owned.image,GLIMS_TRANSFORM_ROTATE_90)==GLIMS_STATUS_UNSUPPORTED,"geometry mutation refuses");
  CHECK(api->select_command(engine,owned.image,GLIMS_SELECT_ALL,0,&error)==GLIMS_STATUS_UNSUPPORTED,"selection mutation refuses");api->free_string(error);error=NULL;
  CHECK(api->procedure_run(engine,0,"unused-global-procedure",0,&error)==GLIMS_STATUS_UNSUPPORTED,"global procedure cannot bypass an owned document with image zero");api->free_string(error);error=NULL;
  gchar*destination=g_build_filename(argv[1],"sentinel.xcf",NULL);g_file_set_contents(destination,"keep",4,NULL);
  CHECK(api->image_save(engine,owned.image,destination,&error)==GLIMS_STATUS_UNSUPPORTED,"save refuses before touching destination");api->free_string(error);error=NULL;
  gchar*contents=NULL;gsize length=0;CHECK(g_file_get_contents(destination,&contents,&length,NULL)&&length==4&&!memcmp(contents,"keep",4),"refusal preserves an existing destination byte-for-byte");g_free(contents);g_free(destination);
  char **vectors=(char **)(uintptr_t)1;int32_t vector_count=91;
  CHECK(api->image_metadata_tags(engine,owned.image,GLIMS_METADATA_EXIF,&vectors,&vector_count,&error)==GLIMS_STATUS_UNSUPPORTED && !vectors && !vector_count,"metadata tag refusal clears owned vector outputs");api->free_string(error);error=NULL;
  vectors=(char **)(uintptr_t)1;vector_count=91;
  CHECK(api->image_metadata_values(engine,owned.image,"Exif.Image.Artist",&vectors,&vector_count,&error)==GLIMS_STATUS_UNSUPPORTED && !vectors && !vector_count,"metadata value refusal clears owned vector outputs");api->free_string(error);error=NULL;
  struct {GlimsMetadataTagInfo info;guint8 tail[16];} tag_info, expected_info;
  memset(&tag_info,0x5a,sizeof tag_info);tag_info.info.struct_size=sizeof tag_info;
  expected_info=tag_info;memset(&expected_info.info,0,sizeof expected_info.info);expected_info.info.struct_size=sizeof expected_info.info;
  CHECK(api->image_metadata_tag_info(engine,owned.image,"Exif.Image.Artist",&tag_info.info,&error)==GLIMS_STATUS_UNSUPPORTED && !memcmp(&tag_info,&expected_info,sizeof tag_info),"sized metadata refusal clears known fields and preserves future tail");api->free_string(error);error=NULL;
  memset(&tag_info,0x5a,sizeof tag_info);tag_info.info.struct_size=4;expected_info=tag_info;
  CHECK(api->image_metadata_tag_info(engine,owned.image,"Exif.Image.Artist",&tag_info.info,&error)==GLIMS_STATUS_UNSUPPORTED && !memcmp(&tag_info,&expected_info,sizeof tag_info),"short metadata output remains untouched on refusal");api->free_string(error);error=NULL;
  GlimsItemID copies[1]={source};
  CHECK(api->image_duplicate_layers(engine,owned.image,copies,1,copies,&error)==GLIMS_STATUS_UNSUPPORTED && copies[0]==0,"duplicate refusal clears aliased output after admission fails");api->free_string(error);error=NULL;
  GlimsBrushSettings brush={.struct_size=sizeof brush,.tool=GLIMS_PAINT_CLONE,.size=5,.opacity=1,.red=0,.green=0,.blue=0,.hardness=-1,.rate=-1,.flow=-1,.exposure=-1,.source_drawable=source};
  GlimsStrokePoint point={6,6,1,0,0,10};GlimsStrokeID stroke=0;
  CHECK(api->stroke_begin(engine,ordinary.image,0,&brush,&point,&stroke,&error)==GLIMS_STATUS_UNSUPPORTED&&!stroke,"ordinary destination cannot clone from a component source");api->free_string(error);error=NULL;
  GlimsFilterID filter=123;
  CHECK(api->filter_begin_with_source(engine,ordinary.image,0,"gegl:bump-map",source,&filter,&error)==GLIMS_STATUS_UNSUPPORTED&&filter==0,"captured filter source checks foreign component ownership and clears output");api->free_string(error);error=NULL;
  State after={.image=owned.image};CHECK(glims_engine_call(engine,oracle,&after)==GLIMS_STATUS_OK&&equal(&owned,&after),"all denials preserve witness pixels and Undo exactly");api->free_pixels(after.pixels.pixels);
  CHECK(api->image_clear(engine,ordinary.image,NULL,&error)==GLIMS_STATUS_OK,"ordinary document still edits while a component witness is open");api->free_string(error);error=NULL;
  GlimsLayerInfo ordinary_layer[1];int32_t ordinary_count=0;
  CHECK(api->image_layers(engine,ordinary.image,ordinary_layer,1,&ordinary_count)==GLIMS_STATUS_OK && ordinary_count==1,"ordinary alias witness resolves");
  copies[0]=ordinary_layer[0].id;
  CHECK(api->image_duplicate_layers(engine,ordinary.image,copies,1,copies,&error)==GLIMS_STATUS_OK && copies[0]>0 && copies[0]!=ordinary_layer[0].id,"admitted duplication captures overlapping input before output clearing");api->free_string(error);error=NULL;
  /* Establish real sessions while ordinary, then mark their owner. Only
   * finishing/aborting remains available after a component refusal. */
  owned.flagged=FALSE;glims_engine_call(engine,mark,&owned);
  CHECK(api->filter_begin(engine,owned.image,source,"gegl:brightness-contrast",&filter,&error)==GLIMS_STATUS_OK&&filter,"establish actual native filter session");api->free_string(error);error=NULL;
  if(filter){owned.flagged=TRUE;glims_engine_call(engine,mark,&owned);matrix(engine,GLIMS_FACADE_TARGET_FILTER,filter);
    CHECK(api->filter_set_double(engine,filter,"brightness",0.5)==GLIMS_STATUS_UNSUPPORTED,"handle-only filter setter resolves owner");
    CHECK(api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"filter abort remains available after refusal");}
  owned.flagged=FALSE;glims_engine_call(engine,mark,&owned);brush.tool=GLIMS_PAINT_PENCIL;brush.source_drawable=0;
  CHECK(api->stroke_begin(engine,owned.image,source,&brush,&point,&stroke,&error)==GLIMS_STATUS_OK&&stroke,"establish actual native stroke session");api->free_string(error);error=NULL;
  if(stroke){owned.flagged=TRUE;glims_engine_call(engine,mark,&owned);matrix(engine,GLIMS_FACADE_TARGET_STROKE,stroke);point.x=18;point.time_ms=20;
    CHECK(api->stroke_continue(engine,stroke,&point,1)==GLIMS_STATUS_UNSUPPORTED,"handle-only stroke continuation resolves owner");
    CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"stroke end remains available after refusal");}
  /* The source can change admission state after a cross-image Clone starts. */
  owned.flagged=FALSE;glims_engine_call(engine,mark,&owned);brush.tool=GLIMS_PAINT_CLONE;brush.source_drawable=source;brush.source_x=6;brush.source_y=6;point.x=6;point.time_ms=100;stroke=0;
  CHECK(api->stroke_begin(engine,ordinary.image,copies[0],&brush,&point,&stroke,&error)==GLIMS_STATUS_OK && stroke,"establish live cross-image Clone before source state transition");api->free_string(error);error=NULL;
  if(stroke){owned.flagged=TRUE;glims_engine_call(engine,mark,&owned);point.x=12;point.time_ms=120;
    CHECK(api->stroke_continue(engine,stroke,&point,1)==GLIMS_STATUS_UNSUPPORTED,"live Clone continuation rechecks its source owner");
    CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"live Clone cleanup remains available after source refusal");}
  unsigned reached=0;
  CHECK(glims_facade_call(engine,GLIMS_FACADE_OPERATION_COUNT,(GlimsFacadeTarget){0},callback,&reached,NULL)==GLIMS_STATUS_INVALID_ARGUMENT&&!reached,"unknown operation fails closed");
  CHECK(glims_facade_call(engine,GLIMS_FACADE_OP_image_clear,(GlimsFacadeTarget){GLIMS_FACADE_TARGET_NONE,0,{0,0}},callback,&reached,NULL)==GLIMS_STATUS_INVALID_ARGUMENT&&!reached,"wrong resolver cannot impersonate an image-free operation");
cleanup:
  if(owned.pixels.pixels)api->free_pixels(owned.pixels.pixels);
  if(owned.image)CHECK(api->image_close(engine,owned.image)==GLIMS_STATUS_OK,"close remains available for a marked document");
  if(ordinary.image)api->image_close(engine,ordinary.image);
  if(error){fprintf(stderr,"OBS %s\n",error);api->free_string(error);}api->stop(engine);g_free(user);g_free(cache);
  printf("%u facade-policy checks, %u failures\n",checks,failures);return failures?1:0;
}

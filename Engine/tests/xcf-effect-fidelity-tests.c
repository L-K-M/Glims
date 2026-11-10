/* Native-only regression fixture: imported Curves HDR identity and explicit
 * composite settings must survive public XCF writes. No preservation code. */
#include "engine-private.h"
#include "effect-state.h"
#include "effect-archive.h"
#include "curves-config.h"
#include "core/gimp.h"
#include "core/gimpcurve.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#include "operations/operations-types.h"
#include "operations/gimpcurvesconfig.h"
#include "operations/gimpoperationpointfilter.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static const char *work_dir;
static int failures;
#define CHECK(c,t) do { gboolean ok_=(c);printf("%s %s\n",ok_?"ok  ":"FAIL",t);if(!ok_)failures++;fflush(stdout); } while(0)
#define NEED(c,t) do { gboolean need_=(c);CHECK(need_,t);if(!need_)goto cleanup; } while(0)
typedef struct { GlimsEngine *engine; GlimsImageID id; GimpImage *image; GimpLayer *layer; } Fixture;
/* These native enums stay entirely in this test translation unit. */
typedef struct {
  gboolean identity[5];
  GimpLayerMode mode;
  GimpLayerColorSpace blend, composite;
  GimpLayerCompositeMode composite_mode;
} EffectState;
typedef struct {
  GFile *file, *imported, *exported, *copy;
  GimpPlugInProcedure *save_proc; /* borrowed from live engine */
  gboolean dirty, export_dirty;
  gint64 dirty_time;
  GlimsUndoInfo undo;
} FileState;
static void clear_error(char **error) { if(*error)api->free_string(*error);*error=NULL; }
static void file_state_clear(FileState *s) { g_clear_object(&s->file);g_clear_object(&s->imported);g_clear_object(&s->exported);g_clear_object(&s->copy); }
static gboolean file_state(Fixture *f,FileState *s) {
  g_set_object(&s->file,gimp_image_get_file(f->image));g_set_object(&s->imported,gimp_image_get_imported_file(f->image));
  g_set_object(&s->exported,gimp_image_get_exported_file(f->image));g_set_object(&s->copy,gimp_image_get_save_a_copy_file(f->image));
  s->save_proc=gimp_image_get_save_proc(f->image);s->dirty=gimp_image_is_dirty(f->image);s->export_dirty=gimp_image_is_export_dirty(f->image);
  s->dirty_time=gimp_image_get_dirty_time(f->image);return api->image_undo_info(f->engine,f->id,&s->undo)==GLIMS_STATUS_OK;
}
static gboolean history_same(Fixture *f,const FileState *s) {
  GlimsUndoInfo undo={0};return api->image_undo_info(f->engine,f->id,&undo)==GLIMS_STATUS_OK&&!memcmp(&undo,&s->undo,sizeof undo);
}
static gboolean file_state_same(Fixture *f,const FileState *s) {
  return history_same(f,s)&&s->file==gimp_image_get_file(f->image)&&s->imported==gimp_image_get_imported_file(f->image)&&
    s->exported==gimp_image_get_exported_file(f->image)&&s->copy==gimp_image_get_save_a_copy_file(f->image)&&
    s->save_proc==gimp_image_get_save_proc(f->image)&&s->dirty==gimp_image_is_dirty(f->image)&&
    s->export_dirty==gimp_image_is_export_dirty(f->image)&&s->dirty_time==gimp_image_get_dirty_time(f->image);
}
static gboolean pixels(Fixture *f,gboolean effects,gfloat out[32]) {
  if(effects)gimp_pickable_flush(GIMP_PICKABLE(f->layer));
  GeglBuffer *buffer=effects?gimp_drawable_get_buffer_with_effects(GIMP_DRAWABLE(f->layer)):gimp_drawable_get_buffer(GIMP_DRAWABLE(f->layer));
  if(!buffer)return FALSE;
  gegl_buffer_get(buffer,GEGL_RECTANGLE(0,0,4,2),1,babl_format("RGBA float"),out,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  if(effects)g_object_unref(buffer);return TRUE;
}
static gboolean close_pixels(const gfloat *a,const gfloat *b) {
  for(guint i=0;i<32;i++)if(!isfinite(a[i])||!isfinite(b[i])||fabs(a[i]-b[i])>2e-4)return FALSE;return TRUE;
}
static GimpDrawableFilter *effect(Fixture *f) {
  GlimsEffectInfo rows[2]={{0}};int32_t count=0;
  if(api->drawable_effects(f->engine,f->id,gimp_item_get_id(GIMP_ITEM(f->layer)),rows,2,&count)!=GLIMS_STATUS_OK||count!=1)return NULL;
  return glims_lookup_effect(f->engine,GIMP_DRAWABLE(f->layer),rows[0].id); /* borrowed */
}
static GimpCurvesConfig *curves(GimpDrawableFilter *filter) {
  if(!filter)return NULL;GeglNode *node=gimp_drawable_filter_get_operation(filter);
  if(g_strcmp0(gegl_node_get_operation(node),"gimp:curves"))return NULL;
  GimpOperationPointFilter *point=GIMP_OPERATION_POINT_FILTER(gegl_node_get_gegl_operation(node));
  return point->config&&G_OBJECT_TYPE(point->config)==GIMP_TYPE_CURVES_CONFIG?GIMP_CURVES_CONFIG(point->config):NULL;
}
static gboolean effect_state(Fixture *f,EffectState *s) {
  GimpDrawableFilter *filter=effect(f);GimpCurvesConfig *config=curves(filter);if(!config)return FALSE;
  for(guint i=0;i<5;i++)s->identity[i]=config->curve[i]->identity;
  s->mode=gimp_drawable_filter_get_paint_mode(filter);s->blend=gimp_drawable_filter_get_blend_space(filter);
  s->composite=gimp_drawable_filter_get_composite_space(filter);s->composite_mode=gimp_drawable_filter_get_composite_mode(filter);return TRUE;
}
static gboolean effect_same(const EffectState *a,const EffectState *b) {
  return !memcmp(a->identity,b->identity,sizeof a->identity)&&a->mode==b->mode&&a->blend==b->blend&&a->composite==b->composite&&a->composite_mode==b->composite_mode;
}
static gchar *canonical_config(GimpCurvesConfig *source) {
  if(!source)return NULL;gchar *serialized=gimp_config_serialize_to_string(GIMP_CONFIG(source),NULL),*result=NULL;GError *error=NULL;
  GimpCurvesConfig *copy=g_object_new(GIMP_TYPE_CURVES_CONFIG,NULL);
  if(serialized&&gimp_config_deserialize_string(GIMP_CONFIG(copy),serialized,-1,NULL,&error))result=gimp_config_serialize_to_string(GIMP_CONFIG(copy),NULL);
  if(error)fprintf(stderr,"OBS canonical normalization failed: %s\n",error->message);
  g_clear_error(&error);g_free(serialized);g_object_unref(copy);return result;
}
static void canonical_observation(const gchar *canonical,GimpCurvesConfig *loaded) {
  gchar *actual=loaded?gimp_config_serialize_to_string(GIMP_CONFIG(loaded),NULL):NULL;
  gchar *a=canonical?g_compute_checksum_for_string(G_CHECKSUM_SHA256,canonical,-1):NULL,*b=actual?g_compute_checksum_for_string(G_CHECKSUM_SHA256,actual,-1):NULL;
  printf("OBS canonical normalized-to-loaded match=%s normalized_sha256=%s loaded_sha256=%s\n",canonical&&actual&&!strcmp(canonical,actual)?"yes":"no",a?a:"unavailable",b?b:"unavailable");
  g_free(a);g_free(b);g_free(actual);fflush(stdout);
}
static void round_trip(Fixture *source,const char *path,const EffectState *expected,const gfloat raw[32],const gfloat rendered[32],const char *canonical) {
  GlimsImageID id=0;char *error=NULL;printf("OBS fresh load %s\n",path);fflush(stdout);
  GlimsStatus status=api->image_open(source->engine,path,&id,&error);CHECK(status==GLIMS_STATUS_OK,"public XCF fresh reopen succeeds");
  if(status!=GLIMS_STATUS_OK){clear_error(&error);return;}
  GlimsLayerInfo rows[2]={{0}};int32_t count=0;GlimsOpenImage *open=glims_lookup_image(source->engine,id);
  gboolean one=api->image_layers(source->engine,id,rows,2,&count)==GLIMS_STATUS_OK&&count==1;CHECK(one,"fresh XCF keeps the single source layer");
  GlimsUndoInfo opened_undo={0};CHECK(open&&!gimp_image_is_dirty(open->image)&&api->image_undo_info(source->engine,id,&opened_undo)==GLIMS_STATUS_OK&&opened_undo.undo_count==0&&opened_undo.redo_count==0,"restoration exposes a clean loaded document with empty native history");
  if(one&&open) {
    Fixture loaded={source->engine,id,open->image,GIMP_LAYER(glims_lookup_drawable(open,rows[0].id))};EffectState actual={0};gfloat values[32];
    gboolean present=effect_state(&loaded,&actual);CHECK(present,"fresh XCF keeps one genuine native Curves effect");
    if(present) {
      printf("OBS identities source=%d%d%d%d%d loaded=%d%d%d%d%d; mode=%d/%d blend=%d/%d composite_space=%d/%d composite_mode=%d/%d\n",
             expected->identity[0],expected->identity[1],expected->identity[2],expected->identity[3],expected->identity[4],actual.identity[0],actual.identity[1],actual.identity[2],actual.identity[3],actual.identity[4],
             expected->mode,actual.mode,expected->blend,actual.blend,expected->composite,actual.composite,expected->composite_mode,actual.composite_mode);
      CHECK(!memcmp(expected->identity,actual.identity,sizeof actual.identity),"all five actual native Curves identity flags survive XCF");
      CHECK(actual.mode==expected->mode,"native filter paint mode survives XCF");CHECK(actual.blend==expected->blend,"explicit native filter blend space survives XCF");
      CHECK(actual.composite==expected->composite,"explicit native filter composite space survives XCF");CHECK(actual.composite_mode==expected->composite_mode,"explicit native filter composite mode survives XCF");
    }
    CHECK(pixels(&loaded,FALSE,values)&&!memcmp(raw,values,sizeof values),"raw FLOAT_LINEAR source bytes survive XCF");
    gboolean read=pixels(&loaded,TRUE,values);if(read)printf("OBS HDR loaded first pixel %.9g %.9g %.9g %.9g\n",values[0],values[1],values[2],values[3]);
    CHECK(read&&close_pixels(rendered,values),"actual with-effects HDR result survives XCF without endpoint clamping");
    canonical_observation(canonical,curves(effect(&loaded)));
  }
  api->image_close(source->engine,id);clear_error(&error);
}
static gboolean carrier_is(Fixture *f,const char *bytes,gsize length) {
  const GimpParasite *p=gimp_image_parasite_find(f->image,"glims-effect-state-v1");guint32 count=0;
  const void *actual=p?gimp_parasite_get_data(p,&count):NULL;
  return actual&&count==length&&!memcmp(actual,bytes,length);
}
static void put_carrier(Fixture *f,const char *bytes,gsize length) {
  GimpParasite *p=gimp_parasite_new("glims-effect-state-v1",GIMP_PARASITE_PERSISTENT,length,bytes);
  gimp_image_parasite_attach(f->image,p,FALSE);gimp_parasite_free(p);
}
static void archive_boundaries(Fixture *f) {
  char *error=NULL;GError *gerror=NULL;FileState before={0};GlimsEffectSaveState *guard=NULL;
  const char previous[]={'o','l','d',0,'b','y','t','e','s'};gfloat raw[32],actual[32];
  GlimsEffectArchive *archive=NULL;gchar *encoded=NULL;gsize size=0;
  NEED(file_state(f,&before)&&pixels(f,FALSE,raw),"carrier boundary captures clean file/history/source baseline");
  CHECK(!gimp_image_parasite_find(f->image,"glims-effect-state-v1"),"successful writes leave no private carrier on the live source");
  gchar *blocker=g_build_filename(work_dir,"failed-write-parent",NULL),*path=g_build_filename(blocker,"copy.xcf",NULL);
  gboolean created=g_file_set_contents(blocker,"block",5,&gerror);g_clear_error(&gerror);
  put_carrier(f,previous,sizeof previous);
  CHECK(created&&api->image_save_copy(f->engine,f->id,path,&error)!=GLIMS_STATUS_OK,"supplemented Save Copy refuses child of regular file");clear_error(&error);
  CHECK(carrier_is(f,previous,sizeof previous)&&file_state_same(f,&before)&&pixels(f,FALSE,actual)&&!memcmp(raw,actual,sizeof raw),"failed supplemented Save Copy restores exact previous binary carrier, savepoint, history and source");
  g_free(path);g_free(blocker);
  NEED(glims_effect_state_save_begin(f->image,&guard,&error)==GLIMS_STATUS_OK,"private capture creates a bounded supplement for current effect");
  const GimpParasite *p=gimp_image_parasite_find(f->image,"glims-effect-state-v1");guint32 count=0;
  const void *bytes=p?gimp_parasite_get_data(p,&count):NULL;
  archive=glims_effect_archive_decode(bytes,count,&gerror);
  NEED(archive&&archive->records->len==1,"captured supplement decodes exactly one owned target");
  glims_effect_state_save_end(guard);guard=NULL;
  CHECK(carrier_is(f,previous,sizeof previous)&&file_state_same(f,&before),"capture cleanup restores prior carrier without dirtying or Undo");
  GlimsEffectArchiveRecord *record=g_ptr_array_index(archive->records,0);
  g_free(record->blend_space);record->blend_space=g_strdup("not-a-native-color-space");
  NEED(glims_effect_archive_encode(archive,&encoded,&size,&gerror),"valid bounded syntax can contain an unknown native symbol");
  put_carrier(f,encoded,size);GimpCurvesConfig *config=curves(effect(f));config->curve[0]->identity=FALSE;
  CHECK(glims_effect_state_load(f->image,&error)!=GLIMS_STATUS_OK&&!config->curve[0]->identity,
        "unknown native enum refuses the complete supplement before any Curves mutation");clear_error(&error);
  config->curve[0]->identity=TRUE;g_free(encoded);encoded=NULL;
  g_free(record->blend_space);record->blend_space=g_strdup("rgb-non-linear");
  record->fingerprint[0]=record->fingerprint[0]=='a'?'b':'a';
  NEED(glims_effect_archive_encode(archive,&encoded,&size,&gerror),"stale correspondence remains syntactically valid input");
  put_carrier(f,encoded,size);config->curve[0]->identity=FALSE;
  CHECK(glims_effect_state_load(f->image,&error)!=GLIMS_STATUS_OK&&!config->curve[0]->identity,
        "stale fingerprint refuses without applying an earlier matching record or bypass");clear_error(&error);
  config->curve[0]->identity=TRUE;
  put_carrier(f,"[archive]\nversion=999\n",22);
  CHECK(glims_effect_state_load(f->image,&error)!=GLIMS_STATUS_OK&&file_state_same(f,&before),"unknown supplement version refuses without changing history or savepoint");clear_error(&error);
  gimp_image_parasite_detach(f->image,"glims-effect-state-v1",FALSE);
  CHECK(file_state_same(f,&before)&&pixels(f,FALSE,actual)&&!memcmp(raw,actual,sizeof raw),"all carrier refusals preserve original source pixels and file/history baseline");
cleanup:
  if(guard)glims_effect_state_save_end(guard);gimp_image_parasite_detach(f->image,"glims-effect-state-v1",FALSE);
  clear_error(&error);g_clear_error(&gerror);glims_effect_archive_free(archive);g_free(encoded);file_state_clear(&before);
}

static void history_roundtrips(Fixture *f) {
  GlimsFilterID live=0;char *error=NULL;GlimsCurvesSnapshot out={.struct_size=sizeof out};
  GlimsEffectInfo row={0};int32_t count=0;gfloat raw[32],actual[32];EffectState expected={0};
  GlimsCurvePoint points[]={{0,0,GLIMS_CURVE_POINT_SMOOTH},{1,.5,GLIMS_CURVE_POINT_SMOOTH}};
  GlimsCurveEdit edit={.struct_size=sizeof edit,.channel=GLIMS_CURVE_CHANNEL_VALUE,.mode=GLIMS_CURVE_EDIT_SMOOTH_POINTS,.point_count=2,.points=points};
  NEED(api->drawable_effects(f->engine,f->id,gimp_item_get_id(GIMP_ITEM(f->layer)),&row,1,&count)==GLIMS_STATUS_OK&&count==1,
       "history fixture captures the existing effect identity");
  NEED(api->filter_edit_begin(f->engine,f->id,gimp_item_get_id(GIMP_ITEM(f->layer)),row.id,&live,&error)==GLIMS_STATUS_OK&&
       api->filter_curves_edit(f->engine,live,&edit,&out,&error)==GLIMS_STATUS_OK&&api->filter_commit(f->engine,live,&error)==GLIMS_STATUS_OK,
       "existing effect edit applies a nonidentity Value curve");live=0;api->free_curves_snapshot(&out);
  for(guint pass=0;pass<3;pass++) {
    if(pass==1)CHECK(api->image_undo(f->engine,f->id)==GLIMS_STATUS_OK,"committed Value edit undoes before saving again");
    if(pass==2)CHECK(api->image_redo(f->engine,f->id)==GLIMS_STATUS_OK,"committed Value edit redoes before saving again");
    NEED(effect_state(f,&expected)&&pixels(f,FALSE,raw)&&pixels(f,TRUE,actual),"current Undo/Redo native effect state and raw output are captured");
    CHECK(expected.identity[0]==(pass==1)&&expected.identity[1]&&expected.identity[2]&&expected.identity[3]&&expected.identity[4],
          "current native Value bypass follows edit, Undo and Redo independently of previous saved carriers");
    const gfloat wanted[4]={pass==1?-.5f:0,pass==1?.5f:.25f,pass==1?1.5f:.5f,1.25f};
    gboolean literal=TRUE;for(guint i=0;i<32;i++)literal&=fabs(actual[i]-wanted[i%4])<2e-4;
    CHECK(literal,"edit/Undo/Redo live HDR output obeys independent literal endpoints and untouched Alpha bypass");
    gchar *name=g_strdup_printf("history-%u.xcf",pass),*path=g_build_filename(work_dir,name,NULL);g_free(name);
    FileState before={0};gboolean captured=file_state(f,&before);
    GlimsStatus status=api->image_save_copy(f->engine,f->id,path,&error);
    CHECK(captured&&status==GLIMS_STATUS_OK&&file_state_same(f,&before),"each re-save regenerates current state without changing its dirty savepoint or history");clear_error(&error);
    if(status==GLIMS_STATUS_OK)round_trip(f,path,&expected,raw,actual,NULL);
    file_state_clear(&before);g_free(path);
  }
  CHECK(api->image_undo(f->engine,f->id)==GLIMS_STATUS_OK,"history fixture restores original effect before admission checks");
cleanup:
  if(live)api->filter_abort(f->engine,live);api->free_curves_snapshot(&out);clear_error(&error);
}

static void ambiguous_payload(Fixture *f) {
  char *error=NULL;GError *gerror=NULL;GlimsEffectSaveState *guard=NULL;GlimsEffectArchive *archive=NULL;
  gchar *encoded=NULL;gsize size=0;GimpDrawableFilter *first=effect(f),*second=NULL;
  GeglNode *node=gegl_node_new_child(NULL,"operation","gimp:curves",NULL);
  NEED(first&&glims_curves_config_prepare(node,&error)==GLIMS_STATUS_OK&&
       glims_curves_config_copy(node,gimp_drawable_filter_get_operation(first),&error)==GLIMS_STATUS_OK,
       "ambiguity fixture creates an independent identical native config");
  second=gimp_drawable_filter_new(GIMP_DRAWABLE(f->layer),gimp_object_get_name(GIMP_OBJECT(first)),node,NULL);
  NEED(second!=NULL,"ambiguity fixture creates its second filter");
  gimp_drawable_filter_set_mode(second,gimp_drawable_filter_get_paint_mode(first),gimp_drawable_filter_get_blend_space(first),
      gimp_drawable_filter_get_composite_space(first),gimp_drawable_filter_get_composite_mode(first));
  gimp_drawable_filter_set_clip(second,gimp_drawable_filter_get_clip(first));gimp_drawable_filter_set_region(second,gimp_drawable_filter_get_region(first));
  gimp_drawable_filter_set_opacity(second,gimp_drawable_filter_get_opacity(first));gimp_drawable_filter_set_temporary(second,FALSE);gimp_drawable_filter_apply(second,NULL);
  gimp_drawable_filter_layer_mask_freeze(second);
  NEED(gimp_drawable_filter_commit(second,TRUE,NULL,FALSE),"ambiguity fixture commits the second native effect and its mask");
  GlimsStatus capture_status=glims_effect_state_save_begin(f->image,&guard,&error);
  printf("OBS duplicate capture status=%d error=%s masks=%d,%d identities=%d,%d\n",capture_status,error?error:"none",gimp_drawable_filter_get_mask(first)!=NULL,gimp_drawable_filter_get_mask(second)!=NULL,curves(first)->curve[0]->identity,curves(second)->curve[0]->identity);
  NEED(capture_status==GLIMS_STATUS_OK,"identical effects with identical supplements remain saveable");
  const GimpParasite *p=gimp_image_parasite_find(f->image,"glims-effect-state-v1");guint32 count=0;const void *bytes=p?gimp_parasite_get_data(p,&count):NULL;
  archive=glims_effect_archive_decode(bytes,count,&gerror);NEED(archive&&archive->records->len==2,"ambiguity fixture captures two independent addresses");
  GlimsEffectArchiveRecord *a=g_ptr_array_index(archive->records,0),*b=g_ptr_array_index(archive->records,1);
  NEED(!strcmp(a->fingerprint,b->fingerprint)&&a->identities==b->identities,"ambiguous target contents match without including positional indexes");
  b->identities^=1;NEED(glims_effect_archive_encode(archive,&encoded,&size,&gerror),"conflicting duplicate is syntactically valid but semantically ambiguous");
  glims_effect_state_save_end(guard);guard=NULL;put_carrier(f,encoded,size);
  gboolean before_first=curves(first)->curve[0]->identity,before_second=curves(second)->curve[0]->identity;
  CHECK(glims_effect_state_load(f->image,&error)==GLIMS_STATUS_UNSUPPORTED&&curves(first)->curve[0]->identity==before_first&&curves(second)->curve[0]->identity==before_second,
        "load refuses conflicting indistinguishable records before mutating either native effect");clear_error(&error);
cleanup:
  if(guard)glims_effect_state_save_end(guard);gimp_image_parasite_detach(f->image,"glims-effect-state-v1",FALSE);
  if(second){gimp_drawable_filter_abort(second);g_object_unref(second);}g_object_unref(node);
  clear_error(&error);g_clear_error(&gerror);glims_effect_archive_free(archive);g_free(encoded);
}

static GlimsStatus regression(GlimsEngine *engine,gpointer unused) {
  (void)unused;Fixture f={.engine=engine};GlimsFilterID live=0;char *error=NULL;gchar *canonical=NULL;FileState before={0};
  GlimsCurvesSnapshot out={.struct_size=sizeof out};EffectState baseline={0},after={0};gfloat raw[32],rendered[32],actual[32];
  f.image=gimp_create_image(engine->gimp,4,2,GIMP_RGB,GIMP_PRECISION_FLOAT_LINEAR,FALSE);NEED(f.image!=NULL,"real FLOAT_LINEAR image created");
  if(glims_adopt_image(engine,f.image,&f.id)!=GLIMS_STATUS_OK){g_object_unref(f.image);f.image=NULL;NEED(FALSE,"native image adopted");}
  f.layer=gimp_layer_new(f.image,4,2,gimp_image_get_layer_format(f.image,TRUE),"HDR literal source",1,GIMP_LAYER_MODE_NORMAL);NEED(f.layer!=NULL,"real alpha pixel layer created");
  if(!gimp_image_add_layer(f.image,f.layer,NULL,0,FALSE)){g_object_unref(f.layer);f.layer=NULL;NEED(FALSE,"pixel layer attached");}
  const gfloat literal[]={-.5,.5,1.5,1.25};for(guint i=0;i<8;i++)memcpy(raw+4*i,literal,sizeof literal);
  gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(f.layer)),GEGL_RECTANGLE(0,0,4,2),0,babl_format("RGBA float"),raw,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(GIMP_DRAWABLE(f.layer),0,0,4,2);gimp_image_clean_all(f.image);
  NEED(api->filter_begin(engine,f.id,gimp_item_get_id(GIMP_ITEM(f.layer)),"gimp:curves",&live,&error)==GLIMS_STATUS_OK&&api->filter_curves_set_trc(engine,live,GLIMS_COLOR_TRC_LINEAR,&out,&error)==GLIMS_STATUS_OK,"public Curves preview starts with explicit LINEAR config");api->free_curves_snapshot(&out);
  GlimsFilter *session=g_hash_table_lookup(engine->filters,GINT_TO_POINTER(live));GimpCurvesConfig *config=curves(session->filter);NEED(config!=NULL,"authentic native Curves config is available to fixture");
  /* Imported state, not Reset: native Reset's trailing dirty clears identity. */
  for(guint i=0;i<5;i++)config->curve[i]->identity=TRUE;
  g_object_notify(G_OBJECT(gegl_node_get_gegl_operation(session->operation)),"config");
  gimp_drawable_filter_set_mode(session->filter,GIMP_LAYER_MODE_REPLACE,GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR,GIMP_LAYER_COLOR_SPACE_RGB_LINEAR,GIMP_LAYER_COMPOSITE_UNION);
  NEED(api->filter_commit(engine,live,&error)==GLIMS_STATUS_OK,"native Curves fixture commits through the public path");live=0;
  NEED(effect_state(&f,&baseline)&&pixels(&f,FALSE,actual)&&!memcmp(raw,actual,sizeof raw)&&pixels(&f,TRUE,rendered),"committed flags, native fields, raw bytes and actual rendered result captured");
  CHECK(baseline.identity[0]&&baseline.identity[1]&&baseline.identity[2]&&baseline.identity[3]&&baseline.identity[4],"fixture imports TRUE HDR bypass for all five curves");
  CHECK(baseline.blend==GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR&&baseline.composite==GIMP_LAYER_COLOR_SPACE_RGB_LINEAR&&baseline.composite_mode==GIMP_LAYER_COMPOSITE_UNION,"fixture stores explicit non-AUTO native blend/composite values");
  CHECK(close_pixels(raw,rendered),"committed native identity fixture renders the literal negative RGB, HDR RGB and alpha excursions");
  printf("OBS HDR baseline first pixel %.9g %.9g %.9g %.9g\n",rendered[0],rendered[1],rendered[2],rendered[3]);
  config=curves(effect(&f));GimpHistogramChannel cursor=config->channel;canonical=canonical_config(config);
  printf("OBS canonical normalization available=%s source_cursor_unchanged=%s\n",canonical?"yes":"no",config->channel==cursor?"yes":"no");
  for(guint save=0;save<2;save++) {
    const char *name=save?"hdr-effect-save.xcf":"hdr-effect-copy.xcf";gchar *path=g_build_filename(work_dir,name,NULL);
    if(!file_state(&f,&before)){CHECK(FALSE,"source file/Undo state captured before write");g_free(path);continue;}
    printf("OBS write %s\n",save?"Save":"Save Copy");fflush(stdout);
    GlimsStatus status=save?api->image_save(engine,f.id,path,&error):api->image_save_copy(engine,f.id,path,&error);
    CHECK(status==GLIMS_STATUS_OK,"public XCF write succeeds");clear_error(&error);
    CHECK(effect_state(&f,&after)&&effect_same(&baseline,&after)&&pixels(&f,FALSE,actual)&&!memcmp(raw,actual,sizeof raw)&&pixels(&f,TRUE,actual)&&close_pixels(rendered,actual),"XCF write leaves live native flags/composites and source/effect pixels unchanged");
    if(!save)CHECK(file_state_same(&f,&before),"Save Copy preserves current file/savepoint/dirty state and complete native UndoInfo");
    else {GFile *expected=g_file_new_for_path(path);CHECK(gimp_image_get_file(f.image)&&g_file_equal(gimp_image_get_file(f.image),expected)&&!gimp_image_is_dirty(f.image)&&history_same(&f,&before),"normal Save changes document identity/clean state without changing Undo");g_object_unref(expected);}
    if(status==GLIMS_STATUS_OK)round_trip(&f,path,&baseline,raw,rendered,canonical);g_free(path);
  }
  history_roundtrips(&f);
  GlimsEffectChange default_name={.struct_size=sizeof default_name,.properties=GLIMS_EFFECT_NAME};
  g_strlcpy(default_name.name,gegl_operation_get_key("gimp:curves","title"),sizeof default_name.name);
  GimpDrawableFilter *named_effect=effect(&f);
  CHECK(api->effect_change(engine,f.id,gimp_item_get_id(GIMP_ITEM(f.layer)),gimp_drawable_filter_get_id(named_effect),&default_name,&error)==GLIMS_STATUS_OK,
        "public rename can explicitly choose the operation default title");clear_error(&error);
  gchar *default_path=g_build_filename(work_dir,"custom-default-name.xcf",NULL);GlimsImageID default_id=0;
  CHECK(api->image_save_copy(engine,f.id,default_path,&error)==GLIMS_STATUS_OK,"explicit custom default-title fixture saves");clear_error(&error);
  CHECK(api->image_open(engine,default_path,&default_id,&error)==GLIMS_STATUS_OK,"native loader reclassification of a default-title custom name keeps correspondence");clear_error(&error);
  if(default_id)api->image_close(engine,default_id);g_free(default_path);
  archive_boundaries(&f);
  GimpDrawableFilter *display_named=effect(&f);
  const gchar *old_name=gimp_object_get_name(GIMP_OBJECT(display_named));gchar *saved_name=g_strdup(old_name);
  gimp_object_set_name(GIMP_OBJECT(display_named),"Display only name");g_object_set(display_named,"custom-name",FALSE,NULL);
  gchar *display_path=g_build_filename(work_dir,"display-name.xcf",NULL);GlimsImageID display_id=0;
  CHECK(api->image_save_copy(engine,f.id,display_path,&error)==GLIMS_STATUS_OK,"noncustom display-name fixture saves");clear_error(&error);
  CHECK(api->image_open(engine,display_path,&display_id,&error)==GLIMS_STATUS_OK,"noncustom effect display name omitted by XCF does not invalidate correspondence");clear_error(&error);
  if(display_id)api->image_close(engine,display_id);g_free(display_path);
  gimp_object_set_name(GIMP_OBJECT(display_named),saved_name);g_free(saved_name);
  GimpCurvesConfig *large=curves(effect(&f));
  gimp_curve_set_n_samples(large->curve[0],4096);
  GlimsEffectSaveState *large_guard=NULL;
  CHECK(glims_effect_state_save_begin(f.image,&large_guard,&error)==GLIMS_STATUS_UNSUPPORTED,
        "non-native sample count refuses preservation before a lossy native serialization");
  clear_error(&error);glims_effect_state_save_end(large_guard);
  gimp_curve_set_n_samples(large->curve[0],256);large->curve[0]->identity=TRUE;
  GimpDrawableFilter *original_effect=effect(&f);
  gimp_drawable_filter_set_mode(original_effect,GIMP_LAYER_MODE_OVERLAY_LEGACY,GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR,GIMP_LAYER_COLOR_SPACE_RGB_LINEAR,GIMP_LAYER_COMPOSITE_UNION);
  gchar *alias_path=g_build_filename(work_dir,"legacy-alias.xcf",NULL);GlimsImageID alias_id=0;
  CHECK(api->image_save_copy(engine,f.id,alias_path,&error)==GLIMS_STATUS_OK,"native legacy alias fixture saves with its supplemental state");clear_error(&error);
  CHECK(api->image_open(engine,alias_path,&alias_id,&error)==GLIMS_STATUS_OK,"native overlay-to-softlight legacy alias remains a matching saved effect");clear_error(&error);
  if(alias_id)api->image_close(engine,alias_id);g_free(alias_path);
  gimp_drawable_filter_set_mode(original_effect,GIMP_LAYER_MODE_REPLACE,GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR,GIMP_LAYER_COLOR_SPACE_RGB_LINEAR,GIMP_LAYER_COMPOSITE_UNION);
  GimpLayerMask *mask=gimp_layer_create_mask(f.layer,GIMP_ADD_MASK_WHITE,NULL);
#if GIMP_CHECK_VERSION(3,2,0)
  gboolean mask_attached=mask&&gimp_layer_add_mask(f.layer,mask,FALSE,FALSE,NULL);
#else
  gboolean mask_attached=mask&&gimp_layer_add_mask(f.layer,mask,FALSE,NULL);
#endif
  if(mask_attached) {
    GeglNode *mask_node=gegl_node_new_child(NULL,"operation","gimp:curves",NULL);
    gboolean prepared=glims_curves_config_prepare(mask_node,&error)==GLIMS_STATUS_OK;clear_error(&error);
    GimpDrawableFilter *mask_filter=prepared?gimp_drawable_filter_new(GIMP_DRAWABLE(mask),"Mask Curves",mask_node,NULL):NULL;
    if(mask_filter) {
      gimp_drawable_filter_set_temporary(mask_filter,FALSE);gimp_drawable_filter_apply(mask_filter,NULL);
      gimp_drawable_filter_layer_mask_freeze(mask_filter);
      CHECK(gimp_drawable_filter_commit(mask_filter,TRUE,NULL,FALSE),"mask fixture commits a genuine native effect");
      GlimsEffectSaveState *mask_guard=NULL;
      CHECK(glims_effect_state_save_begin(f.image,&mask_guard,&error)==GLIMS_STATUS_UNSUPPORTED&&mask_guard==NULL,"unsupported mask effect is detected before saving rather than silently losing bypass/composites");
      clear_error(&error);glims_effect_state_save_end(mask_guard);
      gimp_drawable_filter_abort(mask_filter);g_object_unref(mask_filter);
    } else CHECK(FALSE,"native mask effect fixture is constructible");
    g_object_unref(mask_node);gimp_layer_apply_mask(f.layer,GIMP_MASK_DISCARD,FALSE);
  } else {if(mask)g_object_unref(mask);CHECK(FALSE,"native layer mask fixture attaches");}
  GeglNode *graph=gegl_node_new();
  GeglNode *input=gegl_node_get_input_proxy(graph,"input"),*output=gegl_node_get_output_proxy(graph,"output");
  gegl_node_link(input,output);
  GimpDrawableFilter *graph_filter=gimp_drawable_filter_new(GIMP_DRAWABLE(f.layer),"Graph fixture",graph,NULL);
  if(graph_filter) {
    gimp_drawable_filter_set_temporary(graph_filter,FALSE);
    gimp_drawable_filter_apply(graph_filter,NULL);
    gimp_drawable_filter_layer_mask_freeze(graph_filter);
    CHECK(gimp_drawable_filter_commit(graph_filter,TRUE,NULL,FALSE),"graph fixture commits its native mask before preservation admission");
    GlimsEffectSaveState *graph_guard=NULL;
    CHECK(glims_effect_state_save_begin(f.image,&graph_guard,&error)==GLIMS_STATUS_UNSUPPORTED&&graph_guard==NULL,"native-unwritable graph-filter refuses safely before carrier attachment");
    clear_error(&error);glims_effect_state_save_end(graph_guard);
    gimp_drawable_filter_abort(graph_filter);g_object_unref(graph_filter);
  } else CHECK(FALSE,"native graph-filter fixture is constructible");
  g_object_unref(graph);
  ambiguous_payload(&f);
cleanup:
  if(live)api->filter_abort(engine,live);if(f.id)api->image_close(engine,f.id);
  clear_error(&error);api->free_curves_snapshot(&out);file_state_clear(&before);g_free(canonical);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
  if(argc!=2)return 2;work_dir=argv[1];api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api||api->struct_size<sizeof *api)return 2;
  gchar *user=g_build_filename(work_dir,"user",NULL),*cache=g_build_filename(work_dir,"cache",NULL);GlimsEngine *engine=NULL;char *error=NULL;
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
  if(api->start(&config,&engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"%s\n",error?error:"engine startup failed");clear_error(&error);g_free(user);g_free(cache);return 2;}
  CHECK(glims_engine_call(engine,regression,NULL)==GLIMS_STATUS_OK,"native XCF fidelity regression executes on engine worker");
  api->stop(engine);g_free(user);g_free(cache);printf("%s: %d failures\n",failures?"FAILED":"PASSED",failures);return failures!=0;
}

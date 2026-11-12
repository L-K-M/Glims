/* Reuse only the independently seeded Lab fixture and raw-byte capture/oracle.
 * Snapshot operations below are exclusively exercised through the public ABI. */
#define main lab_direct_fixture_main
#include "lab-curves-edit-tests.c"
#undef main

_Static_assert(offsetof(GlimsEngineAPI,image_lab_snapshot_end)==
 offsetof(GlimsEngineAPI,image_curves_lab)+4*sizeof(void *),"append-only Lab snapshot slots");

static uint64_t begin_lab(GlimsEngine *e, Scene *s, unsigned role) {
  GlimsLabSnapshotTarget target={.struct_size=sizeof target,.axis=s->ids[role],.role=role};
  memcpy(target.uuid,s->uuids[role],16); uint64_t token=0; char *error=NULL;
  GlimsStatus status=api->image_lab_snapshot_begin(e,s->id,&target,&token,&error);
  if(status!=GLIMS_STATUS_OK) fprintf(stderr,"begin status %d: %s\n",status,error?error:"");
  CHECK(status==GLIMS_STATUS_OK && token,"begin captured physical Lab preview");
  api->free_string(error); return status==GLIMS_STATUS_OK?token:0;
}
static Snapshot *preview_capture(GlimsEngine *e, Scene *s, GlimsImageID id) {
  GlimsLabAxes axes={.struct_size=sizeof axes}; Scene copy=*s; copy.id=id;
  gboolean ok=api->image_lab_axes(e,id,&axes)==GLIMS_STATUS_OK && axes.count==3;
  for(unsigned i=0;i<3 && ok;i++) {
    ok=axes.axes[i].role==i && !memcmp(axes.axes[i].uuid,s->uuids[i],16) && axes.axes[i].id!=s->ids[i];
    copy.ids[i]=axes.axes[i].id;
  }
  CHECK(ok,"preview retains axis roles and UUIDs with independent native handles");
  return ok?capture(e,&copy):NULL;
}
static void unchanged(GlimsEngine *e, Scene *s, Snapshot *before, const char *label) {
  Snapshot *after=capture(e,s);
  if(after && before) CHECK(source_equal(s,before,after),label);
  snapshot_free(after);
}
static void snapshot_success(GlimsEngine *e,uint32_t component,unsigned role,gboolean identity) {
  Scene *s=create_scene(e,component,1,0); if(!s)return;
  if(!select_role(e,s,role)){close_scene(e,s);return;}
  Snapshot *before=capture(e,s),*preview=NULL,*after=NULL;
  uint64_t token=begin_lab(e,s,role); GlimsImageID copy=0,again=0;
  double value=role?-.5:50;
  GlimsLabCurvesSettings set=settings(s,role,value,!identity); char *error=NULL;
  if(!before || !token)goto done;
  GlimsStatus status=api->image_lab_snapshot_curves(e,s->id,token,&set,&copy,&error);
  CHECK(status==GLIMS_STATUS_OK && copy>0 && copy!=s->id,"render owned Lab preview copy");
  api->free_string(error);error=NULL;
  if(status!=GLIMS_STATUS_OK || !copy)goto done;
  preview=preview_capture(e,s,copy);
  if(preview){
    guint8 expected[MAX_BYTES];
    if(identity)memcpy(expected,before->raw[role],s->bytes);
    else oracle(s,before,role,value,1,expected);
    CHECK(!memcmp(expected,preview->raw[role],s->bytes),"preview matches independent physical Lab oracle");
    gboolean others=TRUE;
    for(unsigned i=0;i<3;i++)if(i!=role && memcmp(before->raw[i],preview->raw[i],s->bytes))others=FALSE;
    CHECK(others,"preview leaves every other physical axis exact");
  }
  unchanged(e,s,before,"render leaves source pixels, history and metadata unchanged");
  GlimsLabAxes copy_axes={.struct_size=sizeof copy_axes};
  if(api->image_lab_axes(e,copy,&copy_axes)==GLIMS_STATUS_OK){
    GlimsLabCurvesSettings edit=set;edit.axis=copy_axes.axes[role].id;
    for(unsigned i=0;i<256;i++)edit.samples[i]=.25;
    CHECK(api->image_curves_lab(e,copy,&edit,&error)==GLIMS_STATUS_OK,"caller may edit returned copy independently of private cache");
    api->free_string(error);error=NULL;
  }else CHECK(FALSE,"read returned copy axes for mutation witness");
  CHECK(api->image_close(e,copy)==GLIMS_STATUS_OK,"close first returned preview copy");copy=0;
  status=api->image_lab_snapshot_curves(e,s->id,token,&set,&again,&error);
  CHECK(status==GLIMS_STATUS_OK && again>0 && again!=s->id,"render from private cache after caller closes copy");
  api->free_string(error);error=NULL;
  if(status==GLIMS_STATUS_OK && again){
    Snapshot *cached=preview_capture(e,s,again);
    if(cached && preview)CHECK(pixels_equal(s,preview,cached),"cached copy has exact independently verified pixels");
    snapshot_free(cached);
  }
  status=api->image_lab_snapshot_apply_curves(e,s->id,token,&set,&error);
  CHECK(status==GLIMS_STATUS_OK,"apply captured Lab preview");api->free_string(error);error=NULL;
  after=capture(e,s);
  if(after && preview)CHECK(pixels_equal(s,after,preview),"Apply and preview agree exactly on all native bytes");
  if(after && before){
    CHECK(metadata_equal(before,after),"Apply preserves metadata, selection and file identities");
    if(identity)CHECK(source_equal(s,before,after),"identity Apply consumes preview without changing Undo or dirty state");
    else{
      CHECK(after->undo==before->undo+1 && after->redo==0,"Apply adds exactly one native Undo step");
      CHECK(api->image_undo(e,s->id)==GLIMS_STATUS_OK,"Undo applied Lab curve");
      Snapshot *undone=capture(e,s);
      if(undone)CHECK(pixels_equal(s,before,undone),"Undo restores exact source bytes");
      snapshot_free(undone);
      CHECK(api->image_redo(e,s->id)==GLIMS_STATUS_OK,"Redo applied Lab curve");
      Snapshot *redone=capture(e,s);
      if(redone)CHECK(pixels_equal(s,after,redone),"Redo restores exact applied bytes");
      snapshot_free(redone);
    }
  }
  CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_NOT_FOUND,"successful Apply consumes token");token=0;
done:
  if(copy)CHECK(api->image_close(e,copy)==GLIMS_STATUS_OK,"close owned preview on failure");
  if(again)CHECK(api->image_close(e,again)==GLIMS_STATUS_OK,"close cached result");
  if(token)CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_OK,"clean up remaining preview token");
  snapshot_free(before);snapshot_free(preview);snapshot_free(after);close_scene(e,s);
}
typedef struct {Scene *scene;unsigned kind;} Stale;
static GlimsStatus mutate_baseline(GlimsEngine *e,gpointer data){
  Stale *m=data;Scene *s=m->scene;GlimsOpenImage *open=glims_lookup_image(e,s->id);
  if(!open)return GLIMS_STATUS_NOT_FOUND;
  GimpItem *item=gimp_item_get_by_id(e->gimp,s->ids[m->kind==1?1:0]);
  if(m->kind<2){
    guint8 value=201;GimpDrawable *d=GIMP_DRAWABLE(item);
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(W-1,H-1,1,1),0,gimp_drawable_get_format(d),&value,GEGL_AUTO_ROWSTRIDE);
  }else if(m->kind==2){
    float value=.37f;GimpDrawable *d=GIMP_DRAWABLE(gimp_image_get_mask(open->image));
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(W-1,H-1,1,1),0,babl_format("Y float"),&value,GEGL_AUTO_ROWSTRIDE);
  }else if(m->kind==3)gimp_object_set_name(GIMP_OBJECT(item),"Changed after preview");
  else gimp_item_set_lock_content(item,TRUE,FALSE);
  return GLIMS_STATUS_OK;
}
static void stale_cases(GlimsEngine *e){
  for(unsigned kind=0;kind<6;kind++){
    Scene *s=create_scene(e,GLIMS_COLOR_COMPONENT_U8,1,0);if(!s)continue;
    select_role(e,s,0);uint64_t token=begin_lab(e,s,0);
    if(!token){close_scene(e,s);continue;}
    if(kind==5)select_role(e,s,1);
    else{Stale m={s,kind};CHECK(glims_engine_call(e,mutate_baseline,&m)==GLIMS_STATUS_OK,"inject independent source change after begin");}
    Snapshot *changed=capture(e,s);GlimsLabCurvesSettings set=settings(s,0,50,1);char *error=NULL;
    CHECK(api->image_lab_snapshot_apply_curves(e,s->id,token,&set,&error)!=GLIMS_STATUS_OK,"stale baseline or locked target refuses Apply");
    api->free_string(error);unchanged(e,s,changed,"refused Apply preserves changed source and exact history");
    CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_OK,"failed Apply retains token for cancellation");
    snapshot_free(changed);close_scene(e,s);
  }
}
static GlimsStatus ink_target(GlimsEngine *e,gpointer data){
  GlimsItemID *ids=data;GlimsOpenImage *open=glims_lookup_image(e,ids[0]);GlimsPlateStorage storage;
  if(!open || !glims_plate_storage_read_open(open,&storage))return GLIMS_STATUS_FAILED;
  ids[1]=gimp_item_get_id(GIMP_ITEM(storage.planes[0]));return GLIMS_STATUS_OK;
}
static void token_cases(GlimsEngine *e){
  GlimsItemID ink[2]={0};uint64_t ink_token=0;char *error=NULL;
  CHECK(api->image_new_multichannel(e,W,H,GLIMS_COLOR_COMPONENT_U8,3,&ink[0],&error)==GLIMS_STATUS_OK,"create ink token witness");api->free_string(error);error=NULL;
  if(!ink[0])return;
  CHECK(glims_engine_call(e,ink_target,ink)==GLIMS_STATUS_OK,"capture ink witness target");
  CHECK(api->channel_command(e,ink[0],ink[1],GLIMS_CHANNEL_SELECT,NULL,&error)==GLIMS_STATUS_OK,"select ink witness");api->free_string(error);error=NULL;
  CHECK(api->image_ink_snapshot_begin(e,ink[0],ink[1],&ink_token,&error)==GLIMS_STATUS_OK && ink_token,"begin ink witness snapshot");api->free_string(error);error=NULL;
  Scene *s=create_scene(e,GLIMS_COLOR_COMPONENT_U8,1,0);
  if(s){
    select_role(e,s,0);uint64_t token=begin_lab(e,s,0);
    CHECK(token && token!=ink_token,"Lab and ink snapshots use distinct engine-wide tokens");
    Snapshot *before=capture(e,s);GlimsLabCurvesSettings set=settings(s,0,50,1);GlimsImageID output=99;
    CHECK(api->image_lab_snapshot_curves(e,s->id,ink_token,&set,&output,&error)==GLIMS_STATUS_NOT_FOUND && output==0,"ink token cannot access Lab snapshot even with correct image and settings");api->free_string(error);error=NULL;
    unchanged(e,s,before,"wrong-token request preserves Lab source");snapshot_free(before);
    CHECK(api->image_ink_snapshot_end(e,ink[0],token)==GLIMS_STATUS_NOT_FOUND,"Lab token cannot end ink snapshot");
    if(token)CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_OK,"end Lab witness");
    close_scene(e,s);
  }
  if(ink_token)CHECK(api->image_ink_snapshot_end(e,ink[0],ink_token)==GLIMS_STATUS_OK,"end ink witness");
  CHECK(api->image_close(e,ink[0])==GLIMS_STATUS_OK,"close ink witness");
}
static void invalid_snapshots(GlimsEngine *e){
  Scene *s=create_scene(e,GLIMS_COLOR_COMPONENT_U8,1,0);if(!s)return;
  select_role(e,s,0);uint64_t token=begin_lab(e,s,0);Snapshot *before=capture(e,s);
  if(token)for(unsigned kind=0;kind<7;kind++){
    GlimsLabCurvesSettings set=settings(s,0,50,1);char *error=NULL;GlimsImageID copy=123;
    if(kind==0)set.struct_size=4;
    else if(kind==1)set.axis=s->ids[1];
    else if(kind==2)set.role=GLIMS_LAB_AXIS_A;
    else if(kind==3)set.uuid[0]^=1;
    else if(kind==4)set.samples[255]=NAN;
    else if(kind==5)set.samples[255]=-DBL_MIN;
    else set.samples[255]=nextafter(1.,2.);
    CHECK(api->image_lab_snapshot_curves(e,s->id,token,&set,&copy,&error)==GLIMS_STATUS_INVALID_ARGUMENT && copy==0,"malformed or retargeted preview refuses and clears result");api->free_string(error);error=NULL;
    CHECK(api->image_lab_snapshot_apply_curves(e,s->id,token,&set,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"malformed or retargeted Apply refuses");api->free_string(error);
    unchanged(e,s,before,"invalid request preserves source bytes, metadata and history");
  }
  if(token)CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_OK,"cancel after invalid requests retains valid token");
  unchanged(e,s,before,"Cancel preserves entire source");snapshot_free(before);close_scene(e,s);
  for(unsigned bad=1;bad<=5;bad++){
    if(bad==3)continue; /* Fully masked non-finite source is legal, tested separately. */
    s=create_scene(e,GLIMS_COLOR_COMPONENT_FLOAT,1,bad);if(!s)continue;
    select_role(e,s,0);token=begin_lab(e,s,0);before=capture(e,s);
    if(token){
      GlimsLabCurvesSettings set=settings(s,0,50,0);char *error=NULL;GlimsImageID copy=99;
      CHECK(api->image_lab_snapshot_curves(e,s->id,token,&set,&copy,&error)==GLIMS_STATUS_INVALID_ARGUMENT && copy==0,"identity preview validates affected non-finite source and coverage");api->free_string(error);error=NULL;
      CHECK(api->image_lab_snapshot_apply_curves(e,s->id,token,&set,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"identity Apply validates affected non-finite source and coverage");api->free_string(error);
      unchanged(e,s,before,"late malformed sample cannot partially publish");
      CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_OK,"cancel malformed-source snapshot");
    }
    snapshot_free(before);close_scene(e,s);
  }
}
typedef struct {Control base;uint64_t token;gboolean preview;GlimsImageID output;} PreviewControl;
static gpointer preview_worker(gpointer data){
  PreviewControl *p=data;Control *c=&p->base;
  c->status=p->preview?api->image_lab_snapshot_curves(c->engine,c->scene->id,p->token,&c->settings,&p->output,&c->error)
    :api->image_lab_snapshot_apply_curves(c->engine,c->scene->id,p->token,&c->settings,&c->error);
  return NULL;
}
static void controlled_snapshots(PreviewControl *p){
  Control *c=&p->base;Scene *s=create_scene(c->engine,GLIMS_COLOR_COMPONENT_U16,1,0);
  g_atomic_pointer_set(&c->scene,s);if(!s)return;
  for(unsigned kind=0;kind<4;kind++){
    select_role(c->engine,s,0);p->token=begin_lab(c->engine,s,0);if(!p->token)continue;
    Snapshot *before=capture(c->engine,s),*changed=NULL;
    c->settings=settings(s,0,75,1);c->status=GLIMS_STATUS_FAILED;c->error=NULL;
    p->preview=kind==0;p->output=99;c->pause_value=kind<2?.25:1.;
    g_atomic_int_set(&c->paused,0);g_atomic_int_set(&c->release,0);g_atomic_int_set(&c->timed_out,0);g_atomic_int_set(&c->armed,1);
    GThread *thread=g_thread_new("lab-preview-checkpoint",preview_worker,p);
    gint64 deadline=g_get_monotonic_time()+WAIT_US;
    while(!g_atomic_int_get(&c->paused) && g_get_monotonic_time()<deadline)g_usleep(1000);
    gboolean paused=g_atomic_int_get(&c->paused);CHECK(paused,"reach native preview or Apply staging checkpoint");
    if(paused){
      unchanged(c->engine,s,before,"staging has published no source changes");
      CHECK(api->image_lab_snapshot_end(c->engine,s->id,p->token)==GLIMS_STATUS_BUSY,"End cannot free active snapshot during nested dispatch");
      CHECK(api->image_close(c->engine,s->id)==GLIMS_STATUS_BUSY,"Close cannot destroy source during staged transaction");
      if(kind<3)CHECK(api->procedure_cancel(c->engine)==GLIMS_STATUS_OK,"cancel active preview or Apply transaction");
      else{select_role(c->engine,s,1);changed=capture(c->engine,s);}
    }
    g_atomic_int_set(&c->release,1);g_thread_join(thread);g_atomic_int_set(&c->armed,0);
    CHECK(glims_engine_call(c->engine,drain_idle,NULL)==GLIMS_STATUS_OK,"drain controlled preview idle");
    CHECK(!g_atomic_int_get(&c->timed_out),"preview checkpoint exits without timeout");
    CHECK(kind<3?c->status==GLIMS_STATUS_CANCELLED:c->status==GLIMS_STATUS_INVALID_ARGUMENT,"Cancel or late retarget refuses staged publication");
    if(p->preview)CHECK(p->output==0,"cancelled preview returns no adopted image");
    api->free_string(c->error);c->error=NULL;
    unchanged(c->engine,s,kind==3?changed:before,"interrupted transaction preserves source state and history");
    CHECK(api->image_lab_snapshot_end(c->engine,s->id,p->token)==GLIMS_STATUS_OK,"interrupted transaction retains token for explicit cleanup");
    snapshot_free(before);snapshot_free(changed);
  }
  g_atomic_pointer_set(&c->scene,NULL);close_scene(c->engine,s);
}
int main(int argc,char **argv){
  if(argc<2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api || api->struct_size<offsetof(GlimsEngineAPI,image_lab_snapshot_end)+sizeof api->image_lab_snapshot_end || !api->image_lab_snapshot_end)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  PreviewControl control={0};
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache,.on_event=event,.event_context=&control.base};
  GlimsEngine *engine=NULL;char *error=NULL;
  GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);
  if(status!=GLIMS_STATUS_OK || !engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}
  api->free_string(error);control.base.engine=engine;token_cases(engine);
  const uint32_t components[]={GLIMS_COLOR_COMPONENT_U8,GLIMS_COLOR_COMPONENT_U16,GLIMS_COLOR_COMPONENT_FLOAT};
  for(unsigned c=0;c<3;c++)for(unsigned role=0;role<3;role++){
    snapshot_success(engine,components[c],role,FALSE);snapshot_success(engine,components[c],role,TRUE);
  }
  stale_cases(engine);invalid_snapshots(engine);controlled_snapshots(&control);api->stop(engine);
  printf("checks=%u failures=%u\n",checks,failures);return failures?1:0;
}

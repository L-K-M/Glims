/* Pause actual cooperative checkpoints through a test-only idle source.
 * Event delivery only schedules that source, never calls back into the API. */
#include "engine-private.h"
#include "plate-storage.h"
#include "core/gimpdrawable.h"
#include "core/gimpitem.h"
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c,s) do { gboolean ok=(c); checks++; printf("%s %s\n",ok?"ok":"FAIL",s); if(!ok)failures++; fflush(stdout); } while(0)

typedef struct {
  GlimsEngine *engine;
  GlimsImageID image;
  GlimsItemID channel;
  gint armed, paused, release, timed_out;
  gint projection_events;
  double pause_value;
  GlimsStatus status;
  char *error;
  gchar digest[65];
} State;

static gboolean pause_at_checkpoint (gpointer data)
{
  State *s=data;
  gint64 deadline=g_get_monotonic_time()+10*G_TIME_SPAN_SECOND;
  g_atomic_int_set(&s->paused,1);
  while(!g_atomic_int_get(&s->release)) {
    g_mutex_lock(&s->engine->lock);
    gboolean stopping=s->engine->stopping;
    g_mutex_unlock(&s->engine->lock);
    if(stopping)break;
    if(g_get_monotonic_time()>deadline){g_atomic_int_set(&s->timed_out,1);break;}
    g_main_context_iteration(NULL,FALSE);
    g_usleep(1000);
  }
  return G_SOURCE_REMOVE;
}

static void event (void *data,const GlimsEvent *event)
{
  State *s=data;
  if(event->kind==GLIMS_EVENT_PROJECTION_CHANGED && event->image==s->image)
    g_atomic_int_inc(&s->projection_events);
  if(event->kind==GLIMS_EVENT_PROGRESS && event->active && event->value>=s->pause_value &&
     g_atomic_int_compare_and_exchange(&s->armed,1,0))
    g_idle_add_full(G_PRIORITY_HIGH,pause_at_checkpoint,s,NULL);
}

static gpointer edit_thread (gpointer data)
{
  State *s=data;
  s->status=api->image_edit_ink(s->engine,s->image,s->channel,GLIMS_INK_EDIT_FILL,.25,1,&s->error);
  return NULL;
}

static gboolean await_pause (State *s)
{
  gint64 deadline=g_get_monotonic_time()+10*G_TIME_SPAN_SECOND;
  while(!g_atomic_int_get(&s->paused)&&g_get_monotonic_time()<deadline)g_usleep(1000);
  return g_atomic_int_get(&s->paused);
}

static GlimsStatus capture (GlimsEngine *engine,gpointer data)
{
  State *s=data;GlimsPlateStorage storage;
  GlimsOpenImage *open=glims_lookup_image(engine,s->image);
  if(!open||!glims_plate_storage_read_open(open,&storage)||storage.map.width!=128||storage.map.height!=96)
    return GLIMS_STATUS_FAILED;
  s->channel=gimp_item_get_id(GIMP_ITEM(storage.planes[0]));
  guint16 samples[128*96];
  GChecksum *hash=g_checksum_new(G_CHECKSUM_SHA256);
  for(guint c=0;c<storage.map.count;c++) {
    GeglBuffer *buffer=gimp_drawable_get_buffer(GIMP_DRAWABLE(storage.planes[c]));
    gegl_buffer_get(buffer,GEGL_RECTANGLE(0,0,128,96),1,gegl_buffer_get_format(buffer),samples,
                    GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    g_checksum_update(hash,(const guchar*)samples,sizeof samples);
  }
  g_strlcpy(s->digest,g_checksum_get_string(hash),sizeof s->digest);
  g_checksum_free(hash);return GLIMS_STATUS_OK;
}

static void arm (State *s,double value)
{
  s->pause_value=value;s->status=GLIMS_STATUS_FAILED;
  g_atomic_int_set(&s->paused,0);g_atomic_int_set(&s->release,0);
  g_atomic_int_set(&s->timed_out,0);g_atomic_int_set(&s->armed,1);
  g_atomic_int_set(&s->projection_events,0);
}

int main (int argc,char **argv)
{
  if(argc!=3)return 2;
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api||api->struct_size<offsetof(GlimsEngineAPI,image_edit_ink)+sizeof api->image_edit_ink||!api->image_edit_ink)return 2;
  gchar *profile=NULL;gsize length=0;
  if(!g_file_get_contents(argv[2],&profile,&length,NULL))return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  State state={0};char *error=NULL;
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache,
    .on_event=event,.event_context=&state};
  if(api->start(&config,&state.engine,&error)!=GLIMS_STATUS_OK)return 2;
  GlimsStatus created=api->image_new_cmyk(state.engine,128,96,GLIMS_COLOR_COMPONENT_U16,
    (const guint8*)profile,length,&state.image,&error);
  CHECK(created==GLIMS_STATUS_OK,"create controlled native ink image");
  api->free_string(error);error=NULL;
  if(created!=GLIMS_STATUS_OK)goto done;
  CHECK(glims_engine_call(state.engine,capture,&state)==GLIMS_STATUS_OK,"capture all original raw planes");
  gchar before[65];memcpy(before,state.digest,sizeof before);
  for(guint phase=0;phase<2;phase++) {
    GlimsImageInfo image_before={0},image_after={0};GlimsUndoInfo undo_before={0},undo_after={0};
    CHECK(api->image_info(state.engine,state.image,&image_before)==GLIMS_STATUS_OK&&
          api->image_undo_info(state.engine,state.image,&undo_before)==GLIMS_STATUS_OK,"capture original image and history state");
    arm(&state,phase==0?0:1);
    GThread *worker=g_thread_new("controlled-ink-edit",edit_thread,&state);
    gboolean paused=await_pause(&state);CHECK(paused,phase==0?"pause before staging":"pause after staging before publication");
    if(paused) {
      CHECK(api->image_info(state.engine,state.image,&image_after)==GLIMS_STATUS_OK,"read RPC is serviceable");
      CHECK(api->image_close(state.engine,state.image)==GLIMS_STATUS_BUSY,"close refuses during ink edit");
      CHECK(api->image_undo(state.engine,state.image)==GLIMS_STATUS_BUSY,"Undo refuses during ink edit");
      CHECK(api->select_command(state.engine,state.image,GLIMS_SELECT_ALL,0,&error)==GLIMS_STATUS_BUSY,"selection refuses during ink edit");
      api->free_string(error);error=NULL;
      GlimsChannelChange change={.struct_size=sizeof change,.properties=GLIMS_CHANNEL_NAME,.name="Unexpected"};
      CHECK(api->channel_change(state.engine,state.image,state.channel,&change,&error)==GLIMS_STATUS_BUSY,"ink attributes refuse during ink edit");
      api->free_string(error);error=NULL;
      CHECK(api->image_edit_ink(state.engine,state.image,state.channel,GLIMS_INK_EDIT_CLEAR,1,1,&error)==GLIMS_STATUS_BUSY,"overlapping ink edit refuses");
      api->free_string(error);error=NULL;
      CHECK(glims_engine_call(state.engine,capture,&state)==GLIMS_STATUS_OK&&!strcmp(before,state.digest),"live pixels stay unchanged at checkpoint");
      CHECK(api->procedure_cancel(state.engine)==GLIMS_STATUS_OK,"Cancel reaches the active ink edit");
    }
    g_atomic_int_set(&state.release,1);g_thread_join(worker);
    CHECK(!g_atomic_int_get(&state.timed_out)&&state.status==GLIMS_STATUS_CANCELLED,"cancellation unwinds without timeout");
    api->free_string(state.error);state.error=NULL;
    CHECK(glims_engine_call(state.engine,capture,&state)==GLIMS_STATUS_OK&&!strcmp(before,state.digest),"cancel preserves every raw plane");
    CHECK(api->image_info(state.engine,state.image,&image_after)==GLIMS_STATUS_OK&&
          api->image_undo_info(state.engine,state.image,&undo_after)==GLIMS_STATUS_OK&&
          !memcmp(&image_before,&image_after,sizeof image_before)&&!memcmp(&undo_before,&undo_after,sizeof undo_before),"cancel preserves image identity, dirty state and Undo");
    CHECK(api->procedure_cancel(state.engine)==GLIMS_STATUS_NOT_FOUND,"progress owner is cleared");
    CHECK(g_atomic_int_get(&state.projection_events)==0,"cancel publishes no canvas damage");
  }
  g_atomic_int_set(&state.projection_events,0);
  CHECK(api->image_edit_ink(state.engine,state.image,state.channel,GLIMS_INK_EDIT_FILL,.25,1,&error)==GLIMS_STATUS_OK,"retry succeeds after cancellation");
  api->free_string(error);error=NULL;
  CHECK(g_atomic_int_get(&state.projection_events)>0,"changed native-invisible ink publishes canvas damage");
  CHECK(glims_engine_call(state.engine,capture,&state)==GLIMS_STATUS_OK&&strcmp(before,state.digest),"successful retry changes raw pixels");
  CHECK(api->image_undo(state.engine,state.image)==GLIMS_STATUS_OK&&
    glims_engine_call(state.engine,capture,&state)==GLIMS_STATUS_OK&&!strcmp(before,state.digest),"one Undo restores every original plane");
  g_atomic_int_set(&state.projection_events,0);
  CHECK(api->image_edit_ink(state.engine,state.image,state.channel,GLIMS_INK_EDIT_FILL,.25,0,&error)==GLIMS_STATUS_OK&&
    g_atomic_int_get(&state.projection_events)==0,"zero-opacity edit publishes no canvas damage");
  api->free_string(error);error=NULL;
  arm(&state,1);GThread *worker=g_thread_new("ink-edit-stop",edit_thread,&state);
  CHECK(await_pause(&state),"shutdown reaches final prepublication checkpoint");
  api->stop(state.engine);g_thread_join(worker);state.engine=NULL;
  CHECK(!g_atomic_int_get(&state.timed_out)&&state.status==GLIMS_STATUS_CANCELLED,"shutdown drains and cancels accepted ink edit");
  api->free_string(state.error);
done:
  if(state.engine)api->stop(state.engine);
  g_free(profile);g_free(user);g_free(cache);
  printf("%u checks, %u failures\n",checks,failures);return failures?1:0;
}

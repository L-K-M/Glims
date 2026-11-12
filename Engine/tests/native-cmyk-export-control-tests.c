/* Deterministic export/cancel/shutdown checks. A test-only idle source pauses
 * the engine at the export's real cooperative checkpoint, while dispatching
 * nested RPCs. No production delay or test hook is installed in the adapter. */
#include "engine-private.h"
#include "plate-storage.h"
#include "core/gimpitem.h"
#include <stdio.h>
#include <string.h>

static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c,s) do { gboolean ok=(c); checks++; printf("%s %s\n",ok?"ok":"FAIL",s); if(!ok)failures++; fflush(stdout); } while(0)

typedef struct {
  GlimsEngine *engine;
  GlimsImageID image;
  GlimsItemID channel;
  const char *path;
  gint armed, paused, release, timed_out;
  GlimsStatus status;
  char *error;
} State;

static gboolean
pause_at_checkpoint (gpointer data)
{
  State *s = data;
  gint64 deadline = g_get_monotonic_time () + 10 * G_TIME_SPAN_SECOND;
  g_atomic_int_set (&s->paused, 1);
  while (!g_atomic_int_get (&s->release))
    {
      g_mutex_lock (&s->engine->lock);
      gboolean stopping = s->engine->stopping;
      g_mutex_unlock (&s->engine->lock);
      if (stopping) break;
      if (g_get_monotonic_time () > deadline)
        { g_atomic_int_set (&s->timed_out, 1); break; }
      g_main_context_iteration (NULL, FALSE);
      g_usleep (1000);
    }
  return G_SOURCE_REMOVE;
}

static void
event (void *data, const GlimsEvent *event)
{
  State *s = data;
  if (event->kind == GLIMS_EVENT_PROGRESS && event->active &&
      g_atomic_int_compare_and_exchange (&s->armed, 1, 0))
    g_idle_add_full (G_PRIORITY_HIGH, pause_at_checkpoint, s, NULL);
}

static gpointer
export_thread (gpointer data)
{
  State *s = data;
  s->status = api->image_export_native_cmyk_psd (s->engine, s->image, s->path, &s->error);
  return NULL;
}

static gboolean
await_pause (State *s)
{
  gint64 deadline = g_get_monotonic_time () + 10 * G_TIME_SPAN_SECOND;
  while (!g_atomic_int_get (&s->paused) && g_get_monotonic_time () < deadline)
    g_usleep (1000);
  return g_atomic_int_get (&s->paused);
}

static gboolean
sentinel (const char *path)
{
  gchar *bytes = NULL; gsize length = 0;
  gboolean result = g_file_get_contents (path, &bytes, &length, NULL) &&
                    length == 8 && !memcmp (bytes, "sentinel", 8);
  g_free (bytes); return result;
}

static GlimsStatus
find_channel (GlimsEngine *engine, gpointer data)
{
  State *s = data; GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open (glims_lookup_image (engine, s->image), &storage))
    return GLIMS_STATUS_FAILED;
  s->channel = gimp_item_get_id (GIMP_ITEM (storage.planes[0]));
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 3) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  gchar *profile = NULL; gsize profile_size = 0;
  if (!g_file_get_contents (argv[2], &profile, &profile_size, NULL)) return 2;
  gchar *user = g_build_filename (argv[1], "user", NULL);
  gchar *cache = g_build_filename (argv[1], "cache", NULL);
  gchar *path = g_build_filename (argv[1], "controlled.psd", NULL);
  gchar *second = g_build_filename (argv[1], "second.psd", NULL);
  State state = { .path = path };
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user,
    .cache_directory = cache, .on_event = event, .event_context = &state };
  char *error = NULL;
  if (api->start (&config, &state.engine, &error) != GLIMS_STATUS_OK) return 2;
  CHECK(api->image_new_cmyk(state.engine,128,96,GLIMS_COLOR_COMPONENT_U16,
    (guint8*)profile,profile_size,&state.image,&error)==GLIMS_STATUS_OK,"create control fixture");
  CHECK(glims_engine_call(state.engine,find_channel,&state)==GLIMS_STATUS_OK,"resolve native ink target");
  CHECK(g_file_set_contents(path,"sentinel",8,NULL)&&g_file_set_contents(second,"sentinel",8,NULL),"seed both destinations");
  GlimsImageInfo info_before={0},info_after={0}; GlimsUndoInfo undo_before={0},undo_after={0};
  CHECK(api->image_info(state.engine,state.image,&info_before)==GLIMS_STATUS_OK &&
    api->image_undo_info(state.engine,state.image,&undo_before)==GLIMS_STATUS_OK,"capture document state");
  g_atomic_int_set(&state.armed,1);
  GThread *worker=g_thread_new("native-psd-export",export_thread,&state);
  gboolean paused=await_pause(&state); CHECK(paused,"export services the test checkpoint");
  if(paused){
    CHECK(api->image_info(state.engine,state.image,&info_after)==GLIMS_STATUS_OK,"read RPC remains deliverable while export is paused");
    CHECK(api->image_close(state.engine,state.image)==GLIMS_STATUS_BUSY,"close refuses during export");
    CHECK(api->image_undo(state.engine,state.image)==GLIMS_STATUS_BUSY,"Undo refuses during export");
    GlimsChannelChange change={.struct_size=sizeof change,.properties=GLIMS_CHANNEL_NAME,.name="Must not rename"};
    CHECK(api->channel_change(state.engine,state.image,state.channel,&change,&error)==GLIMS_STATUS_BUSY,"ink rename refuses during export");
    api->free_string(error);error=NULL;
    GlimsBrushSettings brush={.struct_size=sizeof brush,.tool=GLIMS_PAINT_PENCIL,.size=3,.opacity=1,.hardness=1};
    GlimsStrokePoint point={8,8,1,0,0,100};GlimsStrokeID stroke=0;
    CHECK(api->stroke_begin(state.engine,state.image,state.channel,&brush,&point,&stroke,&error)==GLIMS_STATUS_BUSY&&!stroke,"paint refuses during export");
    api->free_string(error);error=NULL;
    CHECK(api->image_export_native_cmyk_psd(state.engine,state.image,second,&error)==GLIMS_STATUS_BUSY&&sentinel(second),"overlapping export refuses without touching destination");
    api->free_string(error);error=NULL;
    CHECK(api->procedure_cancel(state.engine)==GLIMS_STATUS_OK,"external cancellation reaches native export progress");
  }
  g_atomic_int_set(&state.release,1);g_thread_join(worker);
  CHECK(!g_atomic_int_get(&state.timed_out),"checkpoint resumed without timeout");
  CHECK(state.status==GLIMS_STATUS_CANCELLED&&sentinel(path),"cancelled export preserves existing destination");
  api->free_string(state.error);state.error=NULL;
  CHECK(api->image_info(state.engine,state.image,&info_after)==GLIMS_STATUS_OK&&
    api->image_undo_info(state.engine,state.image,&undo_after)==GLIMS_STATUS_OK&&
    !memcmp(&info_before,&info_after,sizeof info_before)&&!memcmp(&undo_before,&undo_after,sizeof undo_before),"cancellation preserves complete facade image and Undo state");
  CHECK(api->procedure_cancel(state.engine)==GLIMS_STATUS_NOT_FOUND,"cancelled export clears progress ownership");
  CHECK(api->image_export_native_cmyk_psd(state.engine,state.image,path,&error)==GLIMS_STATUS_OK&&!sentinel(path),"export retries successfully after cancellation");
  api->free_string(error);error=NULL;
  CHECK(g_file_set_contents(path,"sentinel",8,NULL),"seed shutdown destination");
  g_atomic_int_set(&state.armed,1);g_atomic_int_set(&state.paused,0);g_atomic_int_set(&state.release,0);
  worker=g_thread_new("native-psd-shutdown",export_thread,&state);
  paused=await_pause(&state);CHECK(paused,"shutdown fixture reaches export checkpoint");
  /* No new calls enter after stop begins. The already registered export owns
   * its stack arguments until the transport drains it. */
  api->stop(state.engine);g_thread_join(worker);state.engine=NULL;
  CHECK(!g_atomic_int_get(&state.timed_out),"shutdown unwinds without checkpoint timeout");
  CHECK(state.status==GLIMS_STATUS_CANCELLED&&sentinel(path),"stop cancels native export and preserves destination");
  api->free_string(state.error);
  GDir *dir=g_dir_open(argv[1],0,NULL);const char *name;gboolean clean=TRUE;
  if(dir){while((name=g_dir_read_name(dir)))if(g_str_has_prefix(name,".glims-cmyk-"))clean=FALSE;g_dir_close(dir);}
  CHECK(clean,"cancel and shutdown leave no transaction temporary");
  g_free(profile);g_free(user);g_free(cache);g_free(path);g_free(second);
  printf("%u checks, %u failures\n",checks,failures);return failures?1:0;
}

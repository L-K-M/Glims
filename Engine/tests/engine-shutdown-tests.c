/* A ready higher-priority idle keeps RC autosave pending until shutdown. */
#include "engine-private.h"
#include "core/gimp.h"
#include "config/gimprc.h"
#include <execinfo.h>
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"
static int failures;
static guint gate_id;
#define CHECK(c,t) do{gboolean checked=(c);printf("%s %s\n",checked?"ok  ":"FAIL",t);if(!checked)failures++;fflush(stdout);}while(0)
static void critical(const gchar *domain,GLogLevelFlags level,const gchar *message,gpointer ignored)
{
  void *frames[80];(void)domain;(void)level;(void)ignored;fprintf(stderr,"native critical: %s\n",message);backtrace_symbols_fd(frames,backtrace(frames,80),2);
}
static gboolean hold_autosave(gpointer user)
{
  GlimsEngine *engine=user;
  if(engine->loop&&g_main_loop_is_running(engine->loop))return G_SOURCE_CONTINUE;
  gate_id=0;return G_SOURCE_REMOVE;
}
static GlimsStatus arrange(GlimsEngine *engine,gpointer ignored)
{
  (void)ignored;
  gimp_rc_set_autosave(GIMP_RC(engine->gimp->edit_config),TRUE);
  g_object_set(engine->gimp->edit_config,"prev-language","glims-shutdown-regression",NULL);
  CHECK(GIMP_RC(engine->gimp->edit_config)->save_idle_id!=0,"a real native RC autosave is queued");
  gate_id=g_idle_add_full(G_PRIORITY_HIGH_IDLE,hold_autosave,engine,NULL);
  CHECK(gate_id!=0,"a higher-priority test idle holds autosave until the quit RPC");
  return GLIMS_STATUS_OK;
}
int main(int argc,char **argv)
{
  if(argc!=2)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;
  const GlimsEngineAPI *api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api||api->start(&config,&engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"%s\n",error?error:"engine startup failed");return 2;}
  if(error)api->free_string(error);
  g_log_set_handler("Gimp-Core",G_LOG_LEVEL_CRITICAL|G_LOG_FLAG_FATAL|G_LOG_FLAG_RECURSION,critical,NULL);
  CHECK(glims_engine_call(engine,arrange,NULL)==GLIMS_STATUS_OK,"the pending-save fixture is admitted");
  api->stop(engine);
  CHECK(gate_id==0,"shutdown removes the test idle before freeing its engine");
  gchar *rc=g_build_filename(user,"gimprc",NULL),*contents=NULL;gsize length=0;
  CHECK(g_file_get_contents(rc,&contents,&length,NULL)&&g_strstr_len(contents,length,"(prev-language \"glims-shutdown-regression\")"),
        "shutdown persists the exact pending preference before destroying its native context");
  g_free(contents);g_free(rc);g_free(user);g_free(cache);
  printf("%s: %d failures\n",failures?"FAILED":"PASSED",failures);return failures!=0;
}

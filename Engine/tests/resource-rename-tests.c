/* Native saved-name replacement: independent PAT bytes and fault oracles. */
#include "engine-private.h"
#include "resource-rename.h"
#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpobject.h"
#include "core/gimppattern.h"
#include "core/gimppattern-load.h"
#include "core/gimptempbuf.h"
#include "babl/babl.h"
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"
static const GlimsEngineAPI *api;
static int failures, save_calls, commit_calls;
static gboolean deny_save, deny_commit, deny_association;
static int association_checks;
static char *target_path;
#define CHECK(c,t) do { gboolean checked=(c); printf("%s %s\n",checked?"ok  ":"FAIL",t); if(!checked)failures++;fflush(stdout); } while(0)
#define NEED(c,t) do { gboolean needed=(c); CHECK(needed,t);if(!needed){if(error)fprintf(stderr,"%s\n",error);goto done;} } while(0)

GFileOutputStream *g_file_replace (GFile *file, const char *etag, gboolean backup, GFileCreateFlags flags, GCancellable *cancel, GError **error)
{
  static GFileOutputStream *(*real_replace)(GFile*,const char*,gboolean,GFileCreateFlags,GCancellable*,GError**);
  if(!real_replace)*(void**)(&real_replace)=dlsym(RTLD_NEXT,"g_file_replace");
  gchar *path=g_file_get_path(file); gboolean staged=path&&strstr(path,"/.glims-rename-");g_free(path);
  if(staged){save_calls++;if(deny_save){g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_PERMISSION_DENIED,"Injected private save denial");return NULL;}}
  if(!real_replace){g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_FAILED,"Missing replace delegate");return NULL;}
  return real_replace(file,etag,backup,flags,cancel,error);
}
GFileInfo *g_file_query_info (GFile *file,const char *attributes,GFileQueryInfoFlags flags,GCancellable *cancel,GError **error)
{
  static GFileInfo *(*real_query)(GFile*,const char*,GFileQueryInfoFlags,GCancellable*,GError**);
  if(!real_query)*(void**)(&real_query)=dlsym(RTLD_NEXT,"g_file_query_info");
  gchar *path=g_file_get_path(file);
  gboolean deny=deny_association&&path&&strstr(path,"/.glims-rename-")&&strstr(attributes,G_FILE_ATTRIBUTE_ACCESS_CAN_WRITE);
  g_free(path);
  if(deny){association_checks++;GFileInfo *info=g_file_info_new();g_file_info_set_attribute_boolean(info,G_FILE_ATTRIBUTE_ACCESS_CAN_WRITE,FALSE);return info;}
  if(!real_query){g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_FAILED,"Missing query delegate");return NULL;}
  return real_query(file,attributes,flags,cancel,error);
}
int rename (const char *from,const char *to)
{
  static int(*real_rename)(const char*,const char*);
  if(!real_rename)*(void**)(&real_rename)=dlsym(RTLD_NEXT,"rename");
  if(target_path&&strcmp(to,target_path)==0){commit_calls++;if(deny_commit){errno=EACCES;return -1;}}
  if(!real_rename){errno=ENOSYS;return -1;}return real_rename(from,to);
}
static void clear_error(char **error){if(*error)api->free_string(*error);*error=NULL;}
static gboolean same_bytes(GFile *file,const gchar *original,gsize count)
{
  gchar *now=NULL;gsize length=0;gboolean same=g_file_load_contents(file,NULL,&now,&length,NULL,NULL)&&length==count&&memcmp(now,original,count)==0;g_free(now);return same;
}
static guint32 be32(const guint8 *p){guint32 value;memcpy(&value,p,4);return GUINT32_FROM_BE(value);}
static GlimsStatus run_all(GlimsEngine *engine,gpointer unused)
{
  const guint8 rgba[16]={255,0,0,255, 0,0,255,128, 0,255,0,255, 255,255,255,0};
  GlimsResourceID id=0, collision=0;
  GlimsResourceMutationFacts *facts=NULL,*fresh=NULL;
  gchar *guard=NULL,*baseline=NULL,*renamed=NULL;gsize baseline_size=0,renamed_size=0;
  GFile *file=NULL;char *error=NULL;
  (void)unused;
  NEED(api->resource_create_pixels(engine,GLIMS_RESOURCE_PATTERN,"Rename original",2,2,rgba,sizeof rgba,0,&id,&error)==GLIMS_STATUS_OK,"a known RGBA pattern is saved");
  NEED(api->resource_create_pixels(engine,GLIMS_RESOURCE_PATTERN,"Collision",2,2,rgba,sizeof rgba,0,&collision,&error)==GLIMS_STATUS_OK,"a same-kind collision fixture exists");
  NEED(glims_resource_mutation_inspect(engine,id,&facts,&error)==GLIMS_STATUS_OK&&facts,"the original resource has mutation facts");
  file=g_object_ref(facts->file);target_path=g_file_get_path(file);
  NEED(chmod(target_path,0600)==0,"the original file has deliberately private permissions");
  NEED(setxattr(target_path,"com.glims.rename-test","metadata",8,0,0)==0,"the original file has an independent extended-attribute sentinel");
  guard=glims_resource_mutation_guard(facts);
  NEED(guard&&g_file_load_contents(file,NULL,&baseline,&baseline_size,NULL,NULL),"an observed guard and independent file baseline exist");
  GimpContext *context=gimp_get_user_context(engine->gimp);gimp_context_set_pattern(context,GIMP_PATTERN(facts->data));
  save_calls=commit_calls=0;
  GlimsStatus status=glims_resource_rename_checked(engine,id,guard,"Rename original",&error);
  CHECK(status==GLIMS_STATUS_OK&&save_calls==0&&commit_calls==0&&same_bytes(file,baseline,baseline_size),"an exact no-op performs no serialization or file replacement");clear_error(&error);
  status=glims_resource_rename_checked(engine,id,guard,"Collision",&error);
  CHECK(status==GLIMS_STATUS_FAILED&&save_calls==0&&same_bytes(file,baseline,baseline_size),"an exact collision refuses before file work");clear_error(&error);
  status=glims_resource_rename_checked(engine,id,guard,"bad\nname",&error);
  CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT&&same_bytes(file,baseline,baseline_size),"control characters refuse without changing the file");clear_error(&error);
  gchar *wrong=g_strdup(guard);wrong[0]=wrong[0]=='0'?'1':'0';
  status=glims_resource_rename_checked(engine,id,wrong,"Renamed Ω",&error);g_free(wrong);
  CHECK(status==GLIMS_STATUS_NOT_FOUND&&save_calls==0&&same_bytes(file,baseline,baseline_size),"a stale guard refuses before staging");clear_error(&error);
  deny_association=TRUE;association_checks=save_calls=commit_calls=0;
  status=glims_resource_rename_checked(engine,id,guard,"Renamed Ω",&error);
  deny_association=FALSE;
  CHECK(status==GLIMS_STATUS_FAILED&&association_checks>0&&save_calls==0&&commit_calls==0&&engine->busy==0,
        "a native association that becomes unwritable refuses before save rather than hitting its fatal precondition");clear_error(&error);
  CHECK(same_bytes(file,baseline,baseline_size)&&strcmp(gimp_object_get_name(facts->data),"Rename original")==0,
        "an unwritable association preserves the original file and live name");
  for(int fault=0;fault<2;fault++){
    deny_save=fault==0;deny_commit=fault==1;save_calls=commit_calls=0;
    status=glims_resource_rename_checked(engine,id,guard,"Renamed Ω",&error);
    deny_save=deny_commit=FALSE;
    fprintf(stderr,"fault %d status %d saves %d commits %d: %s\n",fault,status,save_calls,commit_calls,error?error:"none");
    CHECK(status==GLIMS_STATUS_FAILED&&save_calls==1&&commit_calls==(fault==0?0:1)&&engine->busy==0,"injected save or atomic-commit denial is reported and releases the busy gate");clear_error(&error);
    CHECK(same_bytes(file,baseline,baseline_size)&&strcmp(gimp_object_get_name(facts->data),"Rename original")==0&&!gimp_data_is_dirty(facts->data),"pre-commit failure preserves every original byte and the live name/clean state");
    CHECK(gimp_context_get_pattern(context)==GIMP_PATTERN(facts->data),"pre-commit failure preserves the selected native resource");
  }
  status=glims_resource_rename_checked(engine,id,guard,"Renamed Ω",&error);
  if(status!=GLIMS_STATUS_OK)fprintf(stderr,"rename status %d: %s\n",status,error?error:"none");
  CHECK(status==GLIMS_STATUS_OK&&engine->busy==0,"checked Rename succeeds and releases the busy gate");clear_error(&error);
  CHECK(strcmp(gimp_object_get_name(facts->data),"Renamed Ω")==0&&!gimp_data_is_dirty(facts->data)&&gimp_context_get_pattern(context)==GIMP_PATTERN(facts->data),"success keeps the live object/context and installs the exact Unicode name");
  struct stat st;CHECK(stat(target_path,&st)==0&&(st.st_mode&0777)==0600,"atomic replacement preserves private file permissions");
  char attribute[16]={0};CHECK(getxattr(target_path,"com.glims.rename-test",attribute,sizeof attribute,0,0)==8&&memcmp(attribute,"metadata",8)==0,"atomic replacement preserves the original extended attribute exactly");
  NEED(g_file_load_contents(file,NULL,&renamed,&renamed_size,NULL,NULL)&&renamed_size>=24,"the renamed native file is independently readable");
  guint32 header=be32((guint8*)renamed);
  CHECK(header>=25&&header<=renamed_size&&renamed_size-header==sizeof rgba&&memcmp(renamed+header,rgba,sizeof rgba)==0&&
        header==24+strlen("Renamed Ω")+1&&memcmp(renamed+24,"Renamed Ω",strlen("Renamed Ω")+1)==0,
        "the actual PAT header contains the exact new name and all independently expected RGBA bytes");
  GInputStream *input=G_INPUT_STREAM(g_file_read(file,NULL,NULL));GError *load_error=NULL;
  GList *loaded=input?gimp_pattern_load(context,file,input,&load_error):NULL;if(input)g_object_unref(input);
  CHECK(loaded&&loaded->data&&!loaded->next&&!load_error,"a fresh native loader accepts exactly one renamed resource");
  if(loaded&&loaded->data){GimpPattern *p=GIMP_PATTERN(loaded->data);CHECK(strcmp(gimp_object_get_name(p),"Renamed Ω")==0&&p->mask&&gimp_temp_buf_get_width(p->mask)==2&&gimp_temp_buf_get_height(p->mask)==2&&gimp_temp_buf_get_format(p->mask)==babl_format("R'G'B'A u8")&&memcmp(gimp_temp_buf_get_data(p->mask),rgba,sizeof rgba)==0,"fresh native parsing preserves the new identity, exact dimensions, format and known pixels");}
  g_clear_error(&load_error);g_list_free_full(loaded,g_object_unref);
  NEED(glims_resource_mutation_inspect(engine,id,&fresh,&error)==GLIMS_STATUS_OK&&fresh,"the same native handle has fresh saved facts");
  gchar *new_guard=glims_resource_mutation_guard(fresh);CHECK(new_guard&&strcmp(new_guard,guard)!=0&&g_file_equal(fresh->file,file),"rename changes the observed guard while retaining the exact file path");g_free(new_guard);
  status=glims_resource_rename_checked(engine,id,guard,"Must not land",&error);
  CHECK(status==GLIMS_STATUS_NOT_FOUND&&strcmp(gimp_object_get_name(facts->data),"Renamed Ω")==0,"the old confirmation cannot rename the committed new identity");clear_error(&error);
done:
  deny_save=deny_commit=deny_association=FALSE;g_clear_pointer(&target_path,g_free);
  clear_error(&error);glims_resource_mutation_facts_free(fresh);glims_resource_mutation_facts_free(facts);
  g_clear_object(&file);g_free(guard);g_free(baseline);g_free(renamed);
  return failures?GLIMS_STATUS_FAILED:GLIMS_STATUS_OK;
}
int main(int argc,char **argv)
{
  if(argc!=2)return 2;gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api||api->struct_size<sizeof(GlimsEngineAPI))return 2;
  if(api->start(&config,&engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"%s\n",error?error:"start failed");clear_error(&error);return 2;}clear_error(&error);
  GlimsStatus status=glims_engine_call(engine,run_all,NULL);api->stop(engine);g_free(user);g_free(cache);
  printf("%s: %d failures\n",failures||status!=GLIMS_STATUS_OK?"FAILED":"PASSED",failures);return failures||status!=GLIMS_STATUS_OK;
}

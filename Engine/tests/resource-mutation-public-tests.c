/* Public ABI-only checks of owned capabilities, guards and resource writes. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
static const GlimsEngineAPI *api;
static int failures;
#define CHECK(c,t) do { int checked=(c);printf("%s %s\n",checked?"ok  ":"FAIL",t);if(!checked)failures++;fflush(stdout); } while(0)
#define NEED(c,t) do { int needed=(c);CHECK(needed,t);if(!needed)goto done; } while(0)
static void release(char **text){if(*text)api->free_string(*text);*text=NULL;}
int main(int argc,char **argv)
{
  if(argc!=3)return 2;
  void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!library){fprintf(stderr,"%s\n",dlerror());return 2;}
  const GlimsEngineAPI *(*getter)(uint32_t);*(void**)(&getter)=dlsym(library,"glims_engine_get_api");
  if(!getter)return 2;api=getter(1);
  if(!api||api->api_version!=1||api->struct_size<offsetof(GlimsEngineAPI,resource_delete)+sizeof(api->resource_delete))return 2;
  CHECK(api->resource_mutation_info&&api->resource_rename&&api->resource_delete,"API 1 exposes all three additive resource methods");
  uint32_t flags=99;char *guard=(char*)1,*reason=(char*)1,*error=NULL;
  GlimsStatus status=api->resource_mutation_info(NULL,1,&flags,&guard,&reason,&error);
  CHECK(status==GLIMS_STATUS_NOT_RUNNING&&flags==0&&!guard&&!reason,"a nonrunning Info clears every owned output before dispatch");release(&error);
  GlimsEngine *engine=NULL;GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=argv[2],.cache_directory=argv[2]};
  char *old_guard=NULL,*new_guard=NULL,*name=NULL,*collection=NULL;bool internal=false;
  const uint8_t pixels[16]={255,0,0,255,0,0,255,128,0,255,0,255,255,255,255,0};
  GlimsResourceID source=0,other=0;
  NEED(api->start(&config,&engine,&error)==GLIMS_STATUS_OK,"the public engine starts in private settings");release(&error);
  NEED(api->resource_create_pixels(engine,GLIMS_RESOURCE_PATTERN,"Public original",2,2,pixels,sizeof pixels,0,&source,&error)==GLIMS_STATUS_OK,
       "a public known-pixel resource is created");release(&error);
  NEED(api->resource_mutation_info(engine,source,&flags,&guard,&reason,&error)==GLIMS_STATUS_OK,"public Info reads the saved resource");release(&error);
  CHECK(flags==(GLIMS_RESOURCE_CAN_RENAME|GLIMS_RESOURCE_CAN_DELETE)&&guard&&strlen(guard)==64&&!reason,"eligible Info returns exact facade flags and one owned opaque guard");
  old_guard=guard;guard=NULL;release(&reason);
  GlimsResourceID invalid[]={0,source+(UINT64_C(1)<<32),UINT64_C(1)<<63};
  for(int i=0;i<3;i++){
    flags=99;guard=(char*)1;reason=(char*)1;
    status=api->resource_mutation_info(engine,invalid[i],&flags,&guard,&reason,&error);
    CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT&&flags==0&&!guard&&!reason,"zero and high-bit resource handles are never narrowed to a live resource");release(&error);
  }
  NEED(api->resource_create_pixels(engine,GLIMS_RESOURCE_PATTERN,"Public collision",2,2,pixels,sizeof pixels,0,&other,&error)==GLIMS_STATUS_OK,"a public name-collision fixture exists");release(&error);
  status=api->resource_rename(engine,source,old_guard,"Public collision",&error);
  CHECK(status==GLIMS_STATUS_FAILED,"the public rename refuses an exact same-kind collision");release(&error);
  status=api->resource_rename(engine,source,old_guard,"",&error);
  CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT,"the public rename refuses an empty name");release(&error);
  status=api->resource_delete(engine,source,NULL,&error);
  CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT,"the public delete requires an observed guard");release(&error);
  status=api->resource_rename(engine,source,old_guard,"Public original",&error);
  CHECK(status==GLIMS_STATUS_OK,"public same-name Rename is an exact no-op");release(&error);
  NEED(api->resource_mutation_info(engine,source,&flags,&guard,&reason,&error)==GLIMS_STATUS_OK,"Info remains readable after refusals and no-op");release(&error);
  CHECK(guard&&old_guard&&strcmp(guard,old_guard)==0,"refusals and exact no-op preserve the observed native/file version");release(&guard);release(&reason);
  NEED(api->resource_rename(engine,source,old_guard,"Public renamed Ω",&error)==GLIMS_STATUS_OK,"public Rename commits the exact Unicode label");release(&error);
  NEED(api->resource_identifiers(engine,source,&name,&collection,&internal,&error)==GLIMS_STATUS_OK,"the same public handle resolves after Rename");release(&error);
  CHECK(name&&strcmp(name,"Public renamed Ω")==0&&!internal,"public persistent identity exposes the actual new native name");release(&name);release(&collection);
  NEED(api->resource_mutation_info(engine,source,&flags,&guard,&reason,&error)==GLIMS_STATUS_OK,"the renamed resource has a fresh public guard");release(&error);
  CHECK(guard&&strcmp(guard,old_guard)!=0,"public Rename invalidates the old observed guard");new_guard=guard;guard=NULL;release(&reason);
  status=api->resource_rename(engine,source,old_guard,"Must not land",&error);
  CHECK(status==GLIMS_STATUS_NOT_FOUND,"an old public Rename confirmation cannot mutate the new identity");release(&error);
  status=api->resource_delete(engine,source,old_guard,&error);
  CHECK(status==GLIMS_STATUS_NOT_FOUND,"an old public Delete confirmation cannot remove the new identity");release(&error);
  NEED(api->resource_delete(engine,source,new_guard,&error)==GLIMS_STATUS_OK,"a fresh public Delete removes the resource");release(&error);
  flags=99;guard=(char*)1;reason=(char*)1;
  status=api->resource_mutation_info(engine,source,&flags,&guard,&reason,&error);
  CHECK(status==GLIMS_STATUS_NOT_FOUND&&flags==0&&!guard&&!reason,"deleted public handles return NOT_FOUND with no owned partial outputs");release(&error);
  status=api->resource_delete(engine,source,new_guard,&error);
  CHECK(status==GLIMS_STATUS_NOT_FOUND,"repeated public Delete reports the stale handle");release(&error);
done:
  if(error)fprintf(stderr,"public test: %s\n",error);
  release(&error);release(&old_guard);release(&new_guard);release(&name);release(&collection);
  if(guard!=(char*)1)release(&guard);if(reason!=(char*)1)release(&reason);
  if(engine)api->stop(engine);dlclose(library);
  printf("%s: %d failures\n",failures?"FAILED":"PASSED",failures);return failures!=0;
}

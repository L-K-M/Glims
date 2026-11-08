#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(value, message) do { if (value) printf("ok %s\n", message); \
  else { fprintf(stderr,"FAIL %s\n",message); failures++; } } while (0)

int main (int argc, char **argv)
{
  if (argc != 4) return 2;
  void *library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf(stderr,"%s\n",dlerror()); return 2; }
  GlimsEngineGetAPIFunction get_api = (GlimsEngineGetAPIFunction)dlsym(library,"glims_engine_get_api");
  unsigned (*release_count)(void) = (unsigned (*)(void))dlsym(RTLD_DEFAULT,"glims_test_error_releases");
  void (*release_error)(void) = (void (*)(void))dlsym(RTLD_DEFAULT,"glims_test_release_injected_error");
  if (!get_api || !release_count || !release_error) return 2;
  const GlimsEngineAPI *api = get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof(*api)) return 2;
  GlimsEngineConfig config = { .struct_size = sizeof(config), .user_directory = argv[2], .cache_directory = argv[3] };
  GlimsEngine *engine = NULL;
  GlimsImageID image = 0;
  char *error = NULL;
  if (api->start(&config,&engine,&error) != GLIMS_STATUS_OK)
    { fprintf(stderr,"start: %s\n",error ? error : "unknown"); return 2; }
  CHECK(api->image_new(engine,8,8,&image,&error) == GLIMS_STATUS_OK,"image created");
  const char *before[] = { "Before" };
  CHECK(api->image_metadata_edit(engine,image,"Exif.Image.Artist",GLIMS_METADATA_SET,before,1,&error) == GLIMS_STATUS_OK,
        "baseline metadata is set");
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  CHECK(api->image_undo_info(engine,image,&undo_before) == GLIMS_STATUS_OK,"baseline history is readable");
  const char *bad[] = { "glims-error-ownership-test" };
  GlimsStatus result = api->image_metadata_edit(engine,image,"Exif.Image.Artist",GLIMS_METADATA_SET,bad,1,&error);
  CHECK(result == GLIMS_STATUS_FAILED && error && strstr(error,"Injected metadata setter failure"),
        "native setter failure is returned through the facade");
  CHECK(release_count() == 1,"injected GError is consumed exactly once");
  printf("observed error releases: %u\n",release_count());
  api->free_string(error); error = NULL;
  release_error();
  CHECK(api->image_undo_info(engine,image,&undo_after) == GLIMS_STATUS_OK,"history after failure is readable");
  CHECK(undo_after.undo_count == undo_before.undo_count,"failed edit leaves history unchanged");
  char **values = NULL; int32_t count = 0;
  CHECK(api->image_metadata_values(engine,image,"Exif.Image.Artist",&values,&count,&error) == GLIMS_STATUS_OK
        && count == 1 && !strcmp(values[0],"Before"),"failed edit preserves original metadata");
  api->free_metadata_strings(values);
  const char *after[] = { "After" };
  CHECK(api->image_metadata_edit(engine,image,"Exif.Image.Artist",GLIMS_METADATA_SET,after,1,&error) == GLIMS_STATUS_OK,
        "another valid edit works after the failure");
  api->free_string(error);
  api->image_close(engine,image);
  api->stop(engine);
  dlclose(library);
  printf("%s: %d failures\n",failures ? "FAILED" : "PASSED",failures);
  return failures ? 1 : 0;
}

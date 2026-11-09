/* Test-only facade proxy: fail the catalog, forward every other operation. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdlib.h>

static const GlimsEngineAPI *real_api;
static GlimsEngineAPI proxy_api;

static GlimsStatus
fail_catalog (GlimsEngine *engine, GlimsOperationInfo *rows,
              int32_t capacity, int32_t *count)
{
  (void) engine;
  (void) rows;
  (void) capacity;
  if (count) *count = 0;
  return GLIMS_STATUS_FAILED;
}

const GlimsEngineAPI *
glims_engine_get_api (uint32_t version)
{
  if (!real_api)
    {
      const char *path = getenv ("GLIMS_REAL_ENGINE_LIBRARY");
      void *library = path ? dlopen (path, RTLD_NOW | RTLD_LOCAL) : NULL;
      GlimsEngineGetAPIFunction get_api = library ? dlsym (library, "glims_engine_get_api") : NULL;
      real_api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
      if (!real_api || real_api->struct_size < sizeof proxy_api) return NULL;
      proxy_api = *real_api;
      proxy_api.struct_size = sizeof proxy_api;
      proxy_api.filter_operations = fail_catalog;
    }
  return version <= proxy_api.api_version ? &proxy_api : NULL;
}

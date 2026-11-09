/* Test-only facade: the first capability read fails, later reads are native. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *native_api;
static GlimsEngineAPI proxy_api;
static int failed_once;

static GlimsStatus
read_info (GlimsEngine *engine, GlimsResourceID id, uint32_t *flags,
           char **guard, char **reason, char **error)
{
  if (!failed_once) {
    failed_once = 1;
    if (flags) *flags = 0;
    if (guard) *guard = NULL;
    if (reason) *reason = NULL;
    if (error) *error = strdup ("Injected temporary resource capability failure.");
    return GLIMS_STATUS_FAILED;
  }
  return native_api->resource_mutation_info (engine, id, flags, guard, reason, error);
}

const GlimsEngineAPI *
glims_engine_get_api (uint32_t version)
{
  if (!native_api) {
    const char *path = getenv ("GLIMS_REAL_ENGINE_LIBRARY");
    void *library = path ? dlopen (path, RTLD_NOW | RTLD_LOCAL) : NULL;
    GlimsEngineGetAPIFunction get_api = library ? dlsym (library, "glims_engine_get_api") : NULL;
    native_api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
    if (!native_api || native_api->struct_size < sizeof proxy_api) {
      fprintf (stderr, "Resource read proxy needs the real 145-slot adapter.\n");
      return NULL;
    }
    proxy_api = *native_api;
    proxy_api.resource_mutation_info = read_info;
  }
  return version <= proxy_api.api_version ? &proxy_api : NULL;
}

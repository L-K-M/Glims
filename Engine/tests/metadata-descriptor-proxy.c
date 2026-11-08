/* Test-only facade proxy. Forward real editing; fail one descriptor query. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *native_api;
static GlimsEngineAPI proxy_api;

static GlimsStatus
fail_descriptor (GlimsEngine *engine, GlimsImageID image, const char *tag,
                 GlimsMetadataTagInfo *info, char **error)
{
  if (tag && !strcmp (tag, "Iptc.Application2.Credit"))
    {
      if (error) *error = strdup ("Injected metadata descriptor read failure.");
      return GLIMS_STATUS_FAILED;
    }
  return native_api->image_metadata_tag_info (engine, image, tag, info, error);
}

const GlimsEngineAPI *
glims_engine_get_api (uint32_t version)
{
  if (!native_api)
    {
      const char *path = getenv ("GLIMS_REAL_ENGINE_LIBRARY");
      void *library = path ? dlopen (path, RTLD_NOW | RTLD_LOCAL) : NULL;
      GlimsEngineGetAPIFunction get_api = library ? dlsym (library, "glims_engine_get_api") : NULL;
      native_api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
      if (!native_api || native_api->struct_size < sizeof proxy_api)
        {
          fprintf (stderr, "Descriptor proxy requires a real v128 adapter via GLIMS_REAL_ENGINE_LIBRARY.\n");
          return NULL;
        }
      proxy_api = *native_api;
      proxy_api.image_metadata_tag_info = fail_descriptor;
    }
  return version <= proxy_api.api_version ? &proxy_api : NULL;
}

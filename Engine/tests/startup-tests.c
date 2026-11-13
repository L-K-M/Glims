/* Cold-start probe and packaging cache producer. Uses only the public ABI.
 * Usage: startup-tests LIBRARY USER_DIRECTORY CACHE_DIRECTORY [MAX_SECONDS]
 * Timing includes dlopen, engine readiness, creating and rendering a real
 * 1600x1200 document, and obtaining the command catalog. */
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "glims_engine.h"

static double now (void)
{
  struct timespec time;
  clock_gettime (CLOCK_MONOTONIC, &time);
  return time.tv_sec + time.tv_nsec / 1e9;
}

int main (int argc, char **argv)
{
  if (argc != 4 && argc != 5) return 2;
  double limit = INFINITY;
  if (argc == 5)
    {
      char *end = NULL;
      errno = 0;
      limit = strtod (argv[4], &end);
      if (errno || end == argv[4] || *end || ! isfinite (limit) || limit <= 0)
        { fprintf (stderr, "Invalid MAX_SECONDS: %s\n", argv[4]); return 2; }
    }
  double began = now ();
  void *library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (! library) { fprintf (stderr, "%s\n", dlerror ()); return 2; }
  const GlimsEngineAPI *(*get_api) (uint32_t) = dlsym (library, "glims_engine_get_api");
  const GlimsEngineAPI *api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  if (! api) return 2;
  GlimsEngineConfig config = { .struct_size = sizeof config,
                              .user_directory = argv[2], .cache_directory = argv[3] };
  GlimsEngine *engine = NULL;
  GlimsImageID image = 0;
  char *error = NULL;
  int failed = 0;
  int32_t count = 0;
  unsigned char *pixels = calloc (1600 * 1200, 4);
  if (! pixels) return 2;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    { fprintf (stderr, "%s\n", error ? error : "Engine startup failed"); failed = 1; }
  if (! failed && (api->image_new (engine, 1600, 1200, &image, &error) != GLIMS_STATUS_OK ||
                  api->image_render (engine, image, 1, (GlimsRect) { 0, 0, 1600, 1200 }, pixels, 6400) != GLIMS_STATUS_OK ||
                  api->procedures (engine, image, NULL, 0, &count) != GLIMS_STATUS_OK || count <= 0))
    { fprintf (stderr, "Initial document or command catalog failed\n"); failed = 1; }
  double elapsed = now () - began;
  if (! failed)
    {
      printf ("READY %.6f seconds; %d commands; engine %s\n", elapsed, count, api->engine_version (engine));
      if (elapsed > limit) failed = 1;
    }
  const char *report_path = getenv ("GLIMS_STARTUP_CATALOG_REPORT");
  if (! failed && report_path)
    {
      char *fonts = NULL;
      int32_t capacity = count;
      GlimsProcedureInfo *procedures = calloc ((size_t) capacity, sizeof *procedures);
      FILE *report = fopen (report_path, "w");
      if (! report || ! procedures || api->fonts (engine, &fonts) != GLIMS_STATUS_OK ||
          api->procedures (engine, image, procedures, capacity, &count) != GLIMS_STATUS_OK ||
          count < 0 || count > capacity)
        failed = 1;
      if (! failed)
        {
          fprintf (report, "[fonts]\n%s\n[procedures]\n", fonts ? fonts : "");
          for (int i = 0; i < count; i++) fprintf (report, "%s\n", procedures[i].name);
          if (ferror (report)) failed = 1;
          const char *labels_path = getenv ("GLIMS_STARTUP_LABEL_REPORT");
          if (labels_path)
            {
              FILE *labels = fopen (labels_path, "w");
              if (!labels) failed = 1;
              else
                {
                  for (int i = 0; i < count; i++)
                    fprintf (labels, "%s\t%s\n", procedures[i].name, procedures[i].label);
                  if (ferror (labels)) failed = 1;
                  if (fclose (labels) != 0) failed = 1;
                }
            }
        }
      if (report && fclose (report) != 0) failed = 1;
      if (fonts) api->free_string (fonts);
      free (procedures);
    }
  fflush (stdout);
  if (image) api->image_close (engine, image);
  if (engine) api->stop (engine);
  if (error) api->free_string (error);
  free (pixels);
  return failed;
}

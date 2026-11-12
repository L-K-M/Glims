/* Facade-only Multichannel timings for a 4096x3072 document, 4/16/32 inks,
 * U8/float precision and a 1024x768 viewport at 100% and 25% zoom.
 * Each plane starts as paper with a separate Pencil dab. The cold read,
 * five warm reads and a full-viewport read following a local dab are timed.
 * This measures engine work, not end-to-end pointer/display latency.
 * Run through scripts/test-component-perf.py for isolated engine settings.
 */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;

static double
now_ms (void)
{
  struct timespec t;
  clock_gettime (CLOCK_MONOTONIC, &t);
  return 1000.0 * t.tv_sec + t.tv_nsec / 1e6;
}

static void
require (GlimsStatus status, const char *what)
{
  if (status != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "%s failed: %d\n", what, status);
      exit (1);
    }
}

static void
dab (GlimsImageID id, GlimsItemID target, double x, double y)
{
  GlimsBrushSettings brush = {
    .struct_size = sizeof brush, .tool = GLIMS_PAINT_PENCIL,
    .size = 31, .opacity = .5, .red = 0, .green = 0, .blue = 0,
    .hardness = 1, .rate = 0, .flow = 100, .exposure = -1
  };
  GlimsStrokePoint point = { x, y, 1, 0, 0, 100 };
  GlimsStrokeID stroke = 0;
  require (api->stroke_begin (engine, id, target, &brush, &point, &stroke, NULL), "stroke_begin");
  require (api->stroke_end (engine, stroke), "stroke_end");
}

int
main (int argc, char **argv)
{
  const unsigned counts[] = { 4, 16, 32 };
  const unsigned components[] = { GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_FLOAT };
  const double scales[] = { 1, .25 };
  char user[4096], cache[4096];

  if (argc != 3) return 2;
  void *lib = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  GlimsEngineGetAPIFunction get = lib ? (GlimsEngineGetAPIFunction) dlsym (lib, "glims_engine_get_api") : NULL;
  api = get ? get (GLIMS_ENGINE_API_VERSION) : NULL;
  if (!api || api->struct_size < offsetof (GlimsEngineAPI, image_new_multichannel) + sizeof api->image_new_multichannel ||
      !api->image_new_multichannel)
    {
      const char *error = dlerror ();
      fprintf (stderr, "Cannot load the facade: %s\n", error ? error : "incompatible API");
      return 2;
    }
  if (snprintf (user, sizeof user, "%s/user", argv[2]) >= (int) sizeof user ||
      snprintf (cache, sizeof cache, "%s/cache", argv[2]) >= (int) sizeof cache)
    return 2;
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  require (api->start (&config, &engine, NULL), "start");
  unsigned char *pixels = malloc (1024 * 768 * 4);
  if (!pixels) return 2;

  for (unsigned p = 0; p < 2; p++)
    for (unsigned n = 0; n < 3; n++)
      {
        double start = now_ms ();
        GlimsImageID id = 0;
        require (api->image_new_multichannel (engine, 4096, 3072, components[p], counts[n], &id, NULL), "new");
        double create = now_ms () - start;
        GlimsChannelInfo channels[32];
        int32_t count = 0;
        require (api->image_channels (engine, id, channels, 32, &count), "channels");
        if (count != (int) counts[n]) return 3;
        for (int i = 0; i < count; i++)
          dab (id, channels[i].id, 300 + i * 50, 300 + i * 40);

        for (unsigned z = 0; z < 2; z++)
          {
            start = now_ms ();
            require (api->image_render (engine, id, scales[z], (GlimsRect) { 0, 0, 1024, 768 }, pixels, 4096), "cold render");
            double cold = now_ms () - start, warm = 0, max = 0;
            for (unsigned i = 0; i < 5; i++)
              {
                start = now_ms ();
                require (api->image_render (engine, id, scales[z], (GlimsRect) { 0, 0, 1024, 768 }, pixels, 4096), "warm render");
                double elapsed = now_ms () - start;
                warm += elapsed;
                if (elapsed > max) max = elapsed;
              }
            start = now_ms ();
            dab (id, channels[0].id, 400, 400);
            double paint = now_ms () - start;
            start = now_ms ();
            require (api->image_render (engine, id, scales[z], (GlimsRect) { 0, 0, 1024, 768 }, pixels, 4096), "post-dab render");
            double post = now_ms () - start;
            printf ("{\"precision\":%u,\"inks\":%u,\"scale\":%.2f,\"create_ms\":%.3f,"
                    "\"cold_ms\":%.3f,\"warm_mean_ms\":%.3f,\"warm_max_ms\":%.3f,"
                    "\"dab_ms\":%.3f,\"post_dab_ms\":%.3f}\n",
                    components[p], counts[n], scales[z], create, cold, warm / 5, max, paint, post);
            fflush (stdout);
          }
        require (api->image_close (engine, id), "close");
      }
  api->stop (engine);
  free (pixels);
  return 0;
}

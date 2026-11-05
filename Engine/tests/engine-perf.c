/*
 * Performance pass for the engine adapter, through the facade only.
 *
 *   glims-engine-perf LIBRARY WORK_DIR IMAGE
 *
 * Opens IMAGE (the 24 MP, 20-layer image from make-perf-image.py) and times
 * what the canvas does: rendering a 1440 x 900 device-pixel viewport while
 * panning at several zooms, and painting, measured from one pointer sample
 * to its pixels being rendered. Prints the numbers and a verdict against a
 * 60 fps frame budget (16.7 ms).
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "glims_engine.h"

#define VIEW_W 1440
#define VIEW_H 900
#define FRAME_BUDGET_MS 16.7
#define PAN_STEPS 30
#define STROKE_POINTS 120

static const GlimsEngineAPI *api;
static GlimsEngine          *engine;
static int                   over_budget;

static double
now_ms (void)
{
  struct timespec t;
  clock_gettime (CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static int
compare (const void *a, const void *b)
{
  double x = *(const double *) a, y = *(const double *) b;
  return (x > y) - (x < y);
}

static void
report (const char *what, double *samples, int n, int budgeted)
{
  double sum = 0;
  int    i;

  qsort (samples, n, sizeof *samples, compare);
  for (i = 0; i < n; i++)
    sum += samples[i];
  printf ("%-44s mean %6.1f ms  p95 %6.1f ms  max %6.1f ms%s\n", what, sum / n,
          samples[(int) (n * 0.95) < n ? (int) (n * 0.95) : n - 1], samples[n - 1],
          budgeted ? (samples[(int) (n * 0.95)] <= FRAME_BUDGET_MS ? "  within budget" : "  OVER BUDGET") : "");
  if (budgeted && samples[(int) (n * 0.95)] > FRAME_BUDGET_MS)
    over_budget++;
}

int
main (int argc, char **argv)
{
  GlimsEngineGetAPIFunction get_api;
  GlimsEngineConfig         config = { 0 };
  GlimsImageInfo            info;
  GlimsLayerInfo            top;
  GlimsImageID              image = 0;
  int32_t                   count = 0;
  char                      user_dir[1024], cache_dir[1024];
  char                     *error = NULL;
  uint8_t                  *pixels = malloc ((size_t) VIEW_W * VIEW_H * 4);
  double                    samples[STROKE_POINTS > PAN_STEPS ? STROKE_POINTS : PAN_STEPS];
  double                    zooms[] = { 1.0, 0.5, 0.25, 0.0 };
  double                    t;
  void                     *library;
  int                       z, i;

  if (argc != 4)
    {
      fprintf (stderr, "usage: %s LIBRARY WORK_DIR IMAGE\n", argv[0]);
      return 2;
    }
  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  get_api = library ? (GlimsEngineGetAPIFunction) dlsym (library, "glims_engine_get_api") : NULL;
  api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  if (! api)
    {
      fprintf (stderr, "cannot load %s\n", argv[1]);
      return 1;
    }

  snprintf (user_dir, sizeof user_dir, "%s/user", argv[2]);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", argv[2]);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "engine start failed: %s\n", error ? error : "?");
      return 1;
    }

  t = now_ms ();
  if (api->image_open (engine, argv[3], &image, &error) != GLIMS_STATUS_OK ||
      api->image_info (engine, image, &info) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "cannot open %s: %s\n", argv[3], error ? error : "?");
      return 1;
    }
  printf ("engine %s; %s: %d x %d, %d layers, opened in %.0f ms\n", api->engine_version (engine),
          argv[3], info.width, info.height, info.layer_count, now_ms () - t);
  printf ("viewport %d x %d device pixels; budget %.1f ms per frame (60 fps)\n\n", VIEW_W, VIEW_H, FRAME_BUDGET_MS);

  /* Panning. Each zoom starts from a freshly opened image: the first frame
   * and a pan into unrendered areas (cold) measure the engine compositing
   * the image, which GIMP's own display pays too; panning back over the
   * same path (warm) measures what the canvas adds per frame. */
  zooms[3] = (double) VIEW_W / info.width < (double) VIEW_H / info.height
             ? (double) VIEW_W / info.width : (double) VIEW_H / info.height;
  for (z = 0; z < 4; z++)
    {
      double    scale = zooms[z];
      int32_t   sw = (int32_t) (info.width * scale), sh = (int32_t) (info.height * scale);
      GlimsRect start = { sw > VIEW_W ? (sw - VIEW_W) / 4 : 0, sh > VIEW_H ? (sh - VIEW_H) / 4 : 0,
                          sw < VIEW_W ? sw : VIEW_W, sh < VIEW_H ? sh : VIEW_H };
      GlimsRect area;
      char      label[128];
      double    first;
      int       pass;

      api->image_close (engine, image);
      api->image_open (engine, argv[3], &image, NULL);

      t = now_ms ();
      api->image_render (engine, image, scale, start, pixels, VIEW_W * 4);
      first = now_ms () - t;
      printf ("zoom %.1f%%: first frame of a freshly opened image %.0f ms\n", scale * 100, first);

      for (pass = 0; pass < 2; pass++)
        {
          area = start;
          for (i = 0; i < PAN_STEPS; i++)
            {
              area.x = sw > VIEW_W ? (area.x + 64) % (sw - VIEW_W) : 0;
              area.y = sh > VIEW_H ? (area.y + 40) % (sh - VIEW_H) : 0;
              t = now_ms ();
              api->image_render (engine, image, scale, area, pixels, VIEW_W * 4);
              samples[i] = now_ms () - t;
            }
          snprintf (label, sizeof label, "  pan at %.1f%%, %s", scale * 100,
                    pass == 0 ? "cold (engine composites new areas)" : "warm (canvas cost per frame)");
          report (label, samples, PAN_STEPS, pass == 1);
        }
    }

  /* Painting at 100 %: one pointer sample, then render the area it touched. */
  if (api->image_layers (engine, image, &top, 1, &count) == GLIMS_STATUS_OK && count > 0)
    {
      GlimsBrushSettings brush = { .struct_size = sizeof brush, .size = 40.0, .opacity = 1.0,
                                   .red = 0.1, .green = 0.2, .blue = 0.9, .pressure_size = true,
                                   .tool = GLIMS_PAINT_PAINTBRUSH, .hardness = -1.0, .rate = -1.0,
                                   .flow = -1.0, .exposure = -1.0 };
      GlimsStrokePoint   point = { 2000, 2000, 0.8, 0, 0, 0 };
      GlimsStrokeID      stroke = 0;
      uint8_t            dab[96 * 96 * 4];

      if (api->stroke_begin (engine, image, top.id, &brush, &point, &stroke, &error) == GLIMS_STATUS_OK)
        {
          for (i = 0; i < STROKE_POINTS; i++)
            {
              point.x += 6;
              point.pressure = 0.5 + 0.5 * (i % 20) / 20.0;
              point.time_ms += 8;
              t = now_ms ();
              api->stroke_continue (engine, stroke, &point, 1);
              api->image_render (engine, image, 1.0,
                                 (GlimsRect) { (int32_t) point.x - 48, (int32_t) point.y - 48, 96, 96 },
                                 dab, 96 * 4);
              samples[i] = now_ms () - t;
            }
          t = now_ms ();
          api->stroke_end (engine, stroke);
          printf ("\n");
          report ("brush: pointer sample to rendered pixels", samples, STROKE_POINTS, 1);
          printf ("%-44s %.1f ms\n", "brush: ending the stroke (undo step)", now_ms () - t);
          t = now_ms ();
          api->image_undo (engine, image);
          printf ("%-44s %.1f ms\n", "undo of the stroke", now_ms () - t);
        }
      else
        fprintf (stderr, "stroke failed: %s\n", error ? error : "?");
    }

  api->stop (engine);
  free (pixels);
  printf ("\n%s: %d measurement(s) over the 60 fps budget\n", over_budget ? "OVER BUDGET" : "WITHIN BUDGET", over_budget);
  return 0;
}

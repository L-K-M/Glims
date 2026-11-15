/*
 * Performance pass for the engine adapter, through the facade only.
 *
 *   glims-engine-perf LIBRARY WORK_DIR IMAGE
 *
 * Opens IMAGE (the 24 MP, 20-layer image from make-perf-image.py) and times
 * what the canvas does: rendering a 1440 x 900 device-pixel viewport while
 * panning at several zooms, and painting, measured from one pointer sample
 * to its pixels being rendered, and how long viewport renders wait while
 * a long stroke paints on another thread with an 8 ms pause between
 * synchronous samples. This does not model an input queue building up
 * when painting is slower than the pointer. Prints a verdict against a 60 fps
 * frame budget (16.7 ms).
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "glims_engine.h"

#define VIEW_W 1440
#define VIEW_H 900
#define FRAME_BUDGET_MS 16.7
#define PAN_STEPS 30
#define STROKE_POINTS 120
#define LONG_STROKE_POINTS 500   /* 4 s of nominal pauses, plus painting time */
#define POINTER_INTERVAL_US 8000
#define MAX_RENDER_SAMPLES 2000

static const GlimsEngineAPI *api;
static GlimsEngine          *engine;
static int                   over_budget;

/* A failed engine operation is not a performance sample. */
static int
check_status (GlimsStatus status, const char *operation)
{
  if (status == GLIMS_STATUS_OK)
    return 1;
  fprintf (stderr, "%s failed (status %d)\n", operation, (int) status);
  return 0;
}

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

/* A long stroke on its own thread, with a pause after each synchronous
 * sample. Its effective rate falls when painting or scheduling is slow. */
typedef struct
{
  GlimsImageID              image;
  GlimsItemID               layer;
  const GlimsBrushSettings *brush;
  atomic_bool               started;
  atomic_bool               done;
  atomic_bool               cancel;
  GlimsStatus               status;
  const char               *operation;
} LongStroke;

static void *
paint_long_stroke (void *data)
{
  LongStroke      *job   = data;
  GlimsStrokePoint point = { 600, 700, 0.8, 0, 0, 0 };
  GlimsStrokeID    stroke = 0;
  int              i;

  job->operation = "long stroke begin";
  job->status = api->stroke_begin (engine, job->image, job->layer, job->brush, &point, &stroke, NULL);
  if (job->status == GLIMS_STATUS_OK)
    {
      atomic_store (&job->started, true);
      for (i = 0; i < LONG_STROKE_POINTS && !atomic_load (&job->cancel); i++)
        {
          point.x = 600 + (i * 5) % 1200;
          point.y = 700 + 150 * ((i / 240) % 3);
          point.time_ms += 8;
          job->status = api->stroke_continue (engine, stroke, &point, 1);
          if (job->status != GLIMS_STATUS_OK)
            {
              job->operation = "long stroke continue";
              break;
            }
          usleep (POINTER_INTERVAL_US);
        }
      GlimsStatus end_status = api->stroke_end (engine, stroke);
      if (job->status == GLIMS_STATUS_OK && end_status != GLIMS_STATUS_OK)
        {
          job->status = end_status;
          job->operation = "long stroke end";
        }
    }
  atomic_store (&job->done, true);
  return NULL;
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
  uint8_t                  *pixels = NULL;
  double                    samples[STROKE_POINTS > PAN_STEPS ? STROKE_POINTS : PAN_STEPS];
  double                    zooms[] = { 1.0, 0.5, 0.25, 0.0 };
  double                    t;
  void                     *library;
  int                       z, i, result = 1;

  if (argc != 4)
    {
      fprintf (stderr, "usage: %s LIBRARY WORK_DIR IMAGE\n", argv[0]);
      return 2;
    }
  pixels = malloc ((size_t) VIEW_W * VIEW_H * 4);
  if (!pixels)
    {
      fprintf (stderr, "viewport allocation failed\n");
      return 1;
    }
  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  get_api = library ? (GlimsEngineGetAPIFunction) dlsym (library, "glims_engine_get_api") : NULL;
  api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  if (! api)
    {
      fprintf (stderr, "cannot load %s\n", argv[1]);
      free (pixels);
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
      free (pixels);
      return 1;
    }

  t = now_ms ();
  if (api->image_open (engine, argv[3], &image, &error) != GLIMS_STATUS_OK ||
      api->image_info (engine, image, &info) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "opening or reading image %s failed: %s\n", argv[3], error ? error : "?");
      goto cleanup;
    }
  if (info.width <= 0 || info.height <= 0)
    {
      fprintf (stderr, "image dimensions failed validation\n");
      goto cleanup;
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

      if (!check_status (api->image_close (engine, image), "image close") ||
          !check_status (api->image_open (engine, argv[3], &image, NULL), "image reopen"))
        goto cleanup;

      t = now_ms ();
      if (!check_status (api->image_render (engine, image, scale, start, pixels, VIEW_W * 4), "first viewport render"))
        goto cleanup;
      first = now_ms () - t;
      printf ("zoom %.1f%%: first frame of a freshly opened image %.0f ms\n", scale * 100, first);

      /* Repeat the 1:1 cold viewport on fresh projections, so one-time babl
       * setup or a busy machine's first sample doesn't hide a regression. */
      if (z == 0)
        {
          samples[0] = first;
          for (i = 1; i < 5; i++)
            {
              if (!check_status (api->image_close (engine, image), "image close"))
                goto cleanup;
              if (api->image_open (engine, argv[3], &image, NULL) != GLIMS_STATUS_OK)
                {
                  fprintf (stderr, "image reopen for a fresh viewport failed\n");
                  goto cleanup;
                }
              t = now_ms ();
              if (api->image_render (engine, image, scale, start, pixels, VIEW_W * 4) != GLIMS_STATUS_OK)
                {
                  fprintf (stderr, "fresh viewport render failed\n");
                  goto cleanup;
                }
              samples[i] = now_ms () - t;
            }
          report ("  first frame at 100%, five fresh images", samples, 5, 0);
        }

      for (pass = 0; pass < 2; pass++)
        {
          area = start;
          for (i = 0; i < PAN_STEPS; i++)
            {
              area.x = sw > VIEW_W ? (area.x + 64) % (sw - VIEW_W) : 0;
              area.y = sh > VIEW_H ? (area.y + 40) % (sh - VIEW_H) : 0;
              t = now_ms ();
              if (!check_status (api->image_render (engine, image, scale, area, pixels, VIEW_W * 4), "pan render"))
                goto cleanup;
              samples[i] = now_ms () - t;
            }
          snprintf (label, sizeof label, "  pan at %.1f%%, %s", scale * 100,
                    pass == 0 ? "cold (engine composites new areas)" : "warm (canvas cost per frame)");
          report (label, samples, PAN_STEPS, pass == 1);
        }
    }

  /* Painting at 100 %: one pointer sample, then render the area it touched. */
  if (!check_status (api->image_layers (engine, image, &top, 1, &count), "listing layers") || count <= 0)
    {
      if (count <= 0) fprintf (stderr, "finding a paint layer failed\n");
      goto cleanup;
    }
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
              if (!check_status (api->stroke_continue (engine, stroke, &point, 1), "stroke continue") ||
                  !check_status (api->image_render (engine, image, 1.0,
                                 (GlimsRect) { (int32_t) point.x - 48, (int32_t) point.y - 48, 96, 96 },
                                 dab, 96 * 4), "brush render"))
                {
                  (void) api->stroke_end (engine, stroke);
                  goto cleanup;
                }
              samples[i] = now_ms () - t;
            }
          t = now_ms ();
          if (!check_status (api->stroke_end (engine, stroke), "stroke end"))
            goto cleanup;
          double end_ms = now_ms () - t;
          printf ("\n");
          report ("brush: pointer sample to rendered pixels", samples, STROKE_POINTS, 1);
          printf ("%-44s %.1f ms\n", "brush: ending the stroke (undo step)", end_ms);
          t = now_ms ();
          if (!check_status (api->image_undo (engine, image), "stroke undo"))
            goto cleanup;
          printf ("%-44s %.1f ms\n", "undo of the stroke", now_ms () - t);
        }
      else
        {
          fprintf (stderr, "stroke begin failed: %s\n", error ? error : "?");
          goto cleanup;
        }
    }

  /* Renders of the viewport over a long stroke, idle and while it paints:
   * the engine runs one call at a time, so a render waits for the dabs
   * queued before it. */
  if (!check_status (api->image_layers (engine, image, &top, 1, &count), "listing layers") || count <= 0)
    {
      if (count <= 0) fprintf (stderr, "finding a paint layer failed\n");
      goto cleanup;
    }
    {
      GlimsBrushSettings brush = { .struct_size = sizeof brush, .size = 60.0, .opacity = 1.0,
                                   .red = 0.9, .green = 0.2, .blue = 0.1, .pressure_size = true,
                                   .tool = GLIMS_PAINT_PAINTBRUSH, .hardness = -1.0, .rate = -1.0,
                                   .flow = -1.0, .exposure = -1.0 };
      GlimsRect   view = { 400, 400, VIEW_W, VIEW_H };
      LongStroke  job = { .image = image, .layer = top.id, .brush = &brush };
      pthread_t   thread;
      double     *renders = malloc (MAX_RENDER_SAMPLES * sizeof *renders);
      double      began, elapsed;
      int         n = 0, thread_result;
      int         render_ok = 1;

      if (!renders)
        {
          fprintf (stderr, "render sample allocation failed\n");
          goto cleanup;
        }

      if (!check_status (api->image_render (engine, image, 1.0, view, pixels, VIEW_W * 4), "idle viewport render"))
        { free (renders); goto cleanup; }
      for (i = 0; i < PAN_STEPS; i++)
        {
          t = now_ms ();
          if (!check_status (api->image_render (engine, image, 1.0, view, pixels, VIEW_W * 4), "idle viewport render"))
            { free (renders); goto cleanup; }
          samples[i] = now_ms () - t;
        }
      printf ("\n");
      report ("viewport render at 100%, idle", samples, PAN_STEPS, 1);

      atomic_init (&job.started, false);
      atomic_init (&job.done, false);
      atomic_init (&job.cancel, false);
      began = now_ms ();
      thread_result = pthread_create (&thread, NULL, paint_long_stroke, &job);
      if (thread_result != 0)
        {
          fprintf (stderr, "creating the paint thread failed: %s\n", strerror (thread_result));
          free (renders);
          goto cleanup;
        }
      /* Exclude idle samples while the worker waits to begin painting. */
      while (!atomic_load (&job.started) && !atomic_load (&job.done))
        usleep (1000);
      while (! atomic_load (&job.done) && n < MAX_RENDER_SAMPLES)
        {
          t = now_ms ();
          if (!check_status (api->image_render (engine, image, 1.0, view, pixels, VIEW_W * 4), "concurrent viewport render"))
            {
              render_ok = 0;
              atomic_store (&job.cancel, true);
              break;
            }
          renders[n++] = now_ms () - t;
        }
      thread_result = pthread_join (thread, NULL);
      elapsed = now_ms () - began;
      if (thread_result != 0)
        {
          fprintf (stderr, "joining the paint thread failed: %s\n", strerror (thread_result));
          /* No engine calls or deallocation are safe while it may still run. */
          _Exit (1);
        }
      if (!render_ok || !check_status (job.status, job.operation))
        { free (renders); goto cleanup; }
      if (n == 0)
        {
          fprintf (stderr, "concurrent viewport sampling failed: no samples\n");
          free (renders);
          goto cleanup;
        }
      if (n > 0)
        report ("viewport render while a stroke paints", renders, n, 1);
      printf ("%-44s %.0f ms for %d samples (%.0f ms of nominal pauses)\n", "long stroke: painted in",
              elapsed, LONG_STROKE_POINTS, LONG_STROKE_POINTS * POINTER_INTERVAL_US / 1000.0);
      free (renders);
      if (!check_status (api->image_undo (engine, image), "long stroke undo"))
        goto cleanup;
    }

  result = 0;
  printf ("\n%s: %d measurement(s) over the 60 fps budget\n", over_budget ? "OVER BUDGET" : "WITHIN BUDGET", over_budget);
cleanup:
  api->stop (engine);
  free (pixels);
  return result;
}

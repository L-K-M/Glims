/* Small facade used to inject errors into the standalone performance runner. */
#define _POSIX_C_SOURCE 200809L
#include "glims_engine.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static atomic_int open_count, close_count, info_count, render_count, layer_count, begin_count, continue_count, end_count, undo_count;
static atomic_bool waiting_for_long_begin, reported_idle_render;

static bool fail (const char *name, atomic_int *counter)
{
  int n = atomic_fetch_add (counter, 1) + 1;
  const char *selected = getenv ("GLIMS_PERF_FAIL");
  const char *at = getenv ("GLIMS_PERF_FAIL_AT");
  return selected && strcmp (selected, name) == 0 && n == (at ? atoi (at) : 1);
}

static GlimsStatus start (const GlimsEngineConfig *c, GlimsEngine **e, char **error)
{ (void)c; (void)error; *e = (GlimsEngine *) 1; return GLIMS_STATUS_OK; }
static void stop (GlimsEngine *e) { (void)e; }
static const char *version (GlimsEngine *e) { (void)e; return "test"; }
static GlimsStatus open_image (GlimsEngine *e, const char *p, GlimsImageID *i, char **error)
{ (void)e; (void)p; (void)error; *i = 1; return fail ("open", &open_count) ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK; }
static GlimsStatus close_image (GlimsEngine *e, GlimsImageID i)
{ (void)e; (void)i; return fail ("close", &close_count) ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK; }
static GlimsStatus info (GlimsEngine *e, GlimsImageID i, GlimsImageInfo *v)
{ (void)e; (void)i; memset (v, 0, sizeof *v); v->width = 6000; v->height = 4000; v->layer_count = 1; return fail ("info", &info_count) ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK; }
static GlimsStatus render (GlimsEngine *e, GlimsImageID i, double s, GlimsRect r, uint8_t *p, size_t stride)
{
  (void)e; (void)i; (void)s; (void)r; (void)p; (void)stride;
  if (getenv ("GLIMS_PERF_DELAY_LONG_BEGIN"))
    {
      if (atomic_load (&waiting_for_long_begin) && !atomic_exchange (&reported_idle_render, true))
        fputs ("render ran before the long stroke began\n", stderr);
      struct timespec pause = { 0, 1000000 };
      nanosleep (&pause, NULL);
    }
  return fail ("render", &render_count) ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}
static GlimsStatus layers (GlimsEngine *e, GlimsImageID i, GlimsLayerInfo *l, int32_t cap, int32_t *n)
{ (void)e; (void)i; (void)cap; l->id = 1; *n = 1; return fail ("layers", &layer_count) ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK; }
static GlimsStatus undo (GlimsEngine *e, GlimsImageID i)
{ (void)e; (void)i; return fail ("undo", &undo_count) ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK; }
static GlimsStatus begin (GlimsEngine *e, GlimsImageID i, GlimsItemID l, const GlimsBrushSettings *b,
                          const GlimsStrokePoint *p, GlimsStrokeID *s, char **error)
{
  (void)e; (void)i; (void)l; (void)b; (void)p; (void)error; *s = 1;
  bool failed = fail ("begin", &begin_count);
  if (atomic_load (&begin_count) == 2 && getenv ("GLIMS_PERF_DELAY_LONG_BEGIN"))
    {
      atomic_store (&waiting_for_long_begin, true);
      struct timespec pause = { 0, 200000000 };
      nanosleep (&pause, NULL);
      atomic_store (&waiting_for_long_begin, false);
    }
  return failed ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}
static GlimsStatus cont (GlimsEngine *e, GlimsStrokeID s, const GlimsStrokePoint *p, size_t n)
{ (void)e; (void)s; (void)p; (void)n; return fail ("continue", &continue_count) ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK; }
static GlimsStatus end (GlimsEngine *e, GlimsStrokeID s)
{ (void)e; (void)s; return fail ("end", &end_count) ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK; }

static const GlimsEngineAPI api = {
  .struct_size = sizeof api, .start = start, .stop = stop, .engine_version = version,
  .image_open = open_image, .image_close = close_image, .image_info = info,
  .image_render = render, .image_layers = layers, .image_undo = undo,
  .stroke_begin = begin, .stroke_continue = cont, .stroke_end = end,
};
const GlimsEngineAPI *glims_engine_get_api (uint32_t v)
{ return v == GLIMS_ENGINE_API_VERSION ? &api : NULL; }

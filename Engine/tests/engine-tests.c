/*
 * Conformance tests for the engine adapter, through the facade only.
 *
 *   glims-engine-tests LIBRARY WORK_DIR FIXTURES_DIR
 *
 * Loads the adapter with dlopen() exactly as the app does, starts the engine
 * with directories under WORK_DIR, and checks behavior the app relies on:
 * rendering, painting, undo accounting, filter sessions, saving and
 * reopening XCF, exporting through the engine's file plug-ins, and running
 * plug-in procedures. Prints one line per check and exits non-zero if any
 * check fails.
 */
#include <dlfcn.h>
#include <sys/param.h>
#include <stddef.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "glims_engine.h"

static const GlimsEngineAPI *api;
static GlimsEngine          *engine;
static int                   failures;
static atomic_int            projection_events;
static atomic_int            undo_events;
static atomic_int            progress_starts;
static atomic_int            progress_ends;
static atomic_bool           progress_active;
static atomic_int            selection_events;
static atomic_int            size_events;
static atomic_int            channels_events;

#define CHECK(condition, ...)                       \
  do {                                              \
    if (condition) {                                \
      printf ("ok    ");                            \
    } else {                                        \
      printf ("FAIL  ");                            \
      failures++;                                   \
    }                                               \
    printf (__VA_ARGS__);                           \
    printf ("\n");                                  \
    fflush (stdout);                                \
  } while (0)

static double
now_ms (void)
{
  struct timespec t;
  clock_gettime (CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static void
on_event (void *context, const GlimsEvent *event)
{
  (void) context;
  if (event->kind == GLIMS_EVENT_PROJECTION_CHANGED)
    atomic_fetch_add (&projection_events, 1);
  else if (event->kind == GLIMS_EVENT_UNDO_CHANGED)
    atomic_fetch_add (&undo_events, 1);
  else if (event->kind == GLIMS_EVENT_MESSAGE && event->text)
    printf ("      engine message: %s\n", event->text);
  else if (event->kind == GLIMS_EVENT_SIZE_CHANGED)
    atomic_fetch_add (&size_events, 1);
  else if (event->kind == GLIMS_EVENT_SELECTION_CHANGED)
    atomic_fetch_add (&selection_events, 1);
  else if (event->kind == GLIMS_EVENT_CHANNELS_CHANGED)
    atomic_fetch_add (&channels_events, 1);
  else if (event->kind == GLIMS_EVENT_PROGRESS)
    {
      if (event->active && ! atomic_exchange (&progress_active, true))
        atomic_fetch_add (&progress_starts, 1);
      else if (! event->active && atomic_exchange (&progress_active, false))
        atomic_fetch_add (&progress_ends, 1);
    }
}

/* Renders the whole image at scale 1. The caller frees the result. */
static uint8_t *
render_all (GlimsImageID image, int32_t *width, int32_t *height)
{
  GlimsImageInfo info;
  uint8_t       *pixels;

  if (api->image_info (engine, image, &info) != GLIMS_STATUS_OK)
    return NULL;
  pixels = calloc ((size_t) info.width * info.height, 4);
  if (api->image_render (engine, image, 1.0,
                         (GlimsRect) { 0, 0, info.width, info.height },
                         pixels, (size_t) info.width * 4) != GLIMS_STATUS_OK)
    {
      free (pixels);
      return NULL;
    }
  *width  = info.width;
  *height = info.height;
  return pixels;
}

static const uint8_t *
pixel_at (const uint8_t *pixels, int32_t width, int32_t x, int32_t y)
{
  return pixels + ((size_t) y * width + x) * 4;
}

static GlimsItemID
first_layer (GlimsImageID image)
{
  GlimsLayerInfo row;
  int32_t        count = 0;

  if (api->image_layers (engine, image, &row, 1, &count) != GLIMS_STATUS_OK || count < 1)
    return 0;
  return row.id;
}

static int32_t
undo_depth (GlimsImageID image)
{
  GlimsUndoInfo info;
  return api->image_undo_info (engine, image, &info) == GLIMS_STATUS_OK ? info.undo_count : -1;
}

/* Black, fully opaque, the engine's defaults for everything else. */
static GlimsBrushSettings
brush_for (GlimsPaintTool tool, double size)
{
  GlimsBrushSettings brush = { .struct_size = sizeof (GlimsBrushSettings), .size = size, .opacity = 1.0,
                               .tool = tool, .hardness = -1.0, .rate = -1.0, .flow = -1.0,
                               .exposure = -1.0 };
  return brush;
}

/* A stroke from (x0, y0) to (x1, y1) in 16 steps; returns the status of
 * the first failing call. */
static GlimsStatus
stroke_line (GlimsImageID image, GlimsItemID layer, const GlimsBrushSettings *brush,
             double x0, double y0, double x1, double y1, char **error)
{
  GlimsStrokePoint first = { x0, y0, 1.0, 0.0, 0.0, 0 };
  GlimsStrokePoint points[16];
  GlimsStrokeID    stroke = 0;
  GlimsStatus      status;
  int              i;

  for (i = 0; i < 16; i++)
    points[i] = (GlimsStrokePoint) { x0 + (x1 - x0) * (i + 1) / 16.0, y0 + (y1 - y0) * (i + 1) / 16.0,
                                     1.0, 0.0, 0.0, (uint32_t) (i + 1) * 8 };

  status = api->stroke_begin (engine, image, layer, brush, &first, &stroke, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = api->stroke_continue (engine, stroke, points, 16);
  if (status != GLIMS_STATUS_OK)
    return status;
  return api->stroke_end (engine, stroke);
}

static void
paint_line (GlimsImageID image, GlimsItemID layer, double x0, double x1, double y)
{
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  GlimsStrokePoint   first = { x0, y, 1.0, 0.0, 0.0, 0 };
  GlimsStrokePoint   points[16];
  GlimsStrokeID      stroke = 0;
  char              *error  = NULL;
  int                i;

  for (i = 0; i < 16; i++)
    points[i] = (GlimsStrokePoint) { x0 + (x1 - x0) * (i + 1) / 16.0, y, 1.0, 0.0, 0.0, (uint32_t) (i + 1) * 8 };

  CHECK (api->stroke_begin (engine, image, layer, &brush, &first, &stroke, &error) == GLIMS_STATUS_OK,
         "stroke begins%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  CHECK (api->stroke_continue (engine, stroke, points, 16) == GLIMS_STATUS_OK, "stroke takes 16 points");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "stroke ends");
}

/* Red channel of one rendered pixel (the images here are gray). */
static int
red_at (GlimsImageID image, int32_t x, int32_t y)
{
  uint8_t pixel[4];

  if (api->image_render (engine, image, 1.0, (GlimsRect) { x, y, 1, 1 }, pixel, 4) != GLIMS_STATUS_OK)
    return -1;
  return pixel[0];
}

/* The RGBA pixel at (x, y) of the composite, rendered at scale 1. */
static void
render_pixel (GlimsImageID image, int32_t x, int32_t y, uint8_t out[4])
{
  if (api->image_render (engine, image, 1.0, (GlimsRect) { x, y, 1, 1 }, out, 4) != GLIMS_STATUS_OK)
    memset (out, 0, 4);
}

/* For a failed check after a stroke: the stroke's status and the pixel
 * read again after a pause, which tells a stroke that did not apply from a
 * render that was stale (both seen intermittently, not yet explained). */
static void
explain_stroke (GlimsStatus status, GlimsImageID image, int32_t x, int32_t y, int first)
{
  usleep (200 * 1000);
  printf ("      (stroke status %d; pixel %d, %d after 200 ms)\n", status, first, red_at (image, x, y));
}

static int
rect_equals (GlimsRect a, int32_t x, int32_t y, int32_t w, int32_t h)
{
  return a.x == x && a.y == y && a.width == w && a.height == h;
}

static void
test_selections (void)
{
  GlimsImageID       image = 0;
  GlimsItemID        layer;
  GlimsRect          bounds;
  bool               empty = false;
  GlimsSegment       segments[64];
  int32_t            n = 0, before, i, inside = 1;
  int                events = atomic_load (&selection_events);
  GlimsSelectOptions add = { .struct_size = sizeof add, .operation = GLIMS_SELECT_ADD, .antialias = false };
  GlimsSelectOptions subtract = { .struct_size = sizeof subtract, .operation = GLIMS_SELECT_SUBTRACT };
  GlimsSelectOptions color = { .struct_size = sizeof color, .operation = GLIMS_SELECT_REPLACE,
                               .threshold = 0.2, .contiguous = true };
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 30.0);
  char              *error = NULL;

  api->image_new (engine, 100, 80, &image, NULL);
  layer  = first_layer (image);
  before = undo_depth (image);

  CHECK (api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK && empty,
         "a new image has no selection");

  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) { { 50, 40 }, { 10, 10 } }, 2, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK && ! empty &&
         rect_equals (bounds, 10, 10, 40, 30),
         "a rectangle from either corner selects 10,10 40x30 (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);
  CHECK (undo_depth (image) == before + 1, "the selection is one undo step");
  CHECK (atomic_load (&selection_events) > events, "selection-changed events arrived");

  CHECK (api->selection_outline (engine, image, segments, 64, &n) == GLIMS_STATUS_OK && n >= 4 && n <= 64,
         "the outline has %d edges", n);
  for (i = 0; i < n && i < 64; i++)
    if (MIN (segments[i].x1, segments[i].x2) < 10 || MAX (segments[i].x1, segments[i].x2) > 50 ||
        MIN (segments[i].y1, segments[i].y2) < 10 || MAX (segments[i].y1, segments[i].y2) > 40)
      inside = 0;
  CHECK (inside, "every outline edge lies on the rectangle");

  CHECK (stroke_line (image, layer, &brush, 0, 25, 100, 25, NULL) == GLIMS_STATUS_OK &&
         red_at (image, 30, 25) < 64 && red_at (image, 70, 25) == 255,
         "painting stays inside the selection (%d inside, %d outside)",
         red_at (image, 30, 25), red_at (image, 70, 25));

  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_ELLIPSE,
                            (GlimsPoint[]) { { 60, 10 }, { 90, 40 } }, 2, &add) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         bounds.x == 10 && bounds.x + bounds.width == 90,
         "adding an ellipse extends the selection to x 10...90 (%d...%d)", bounds.x, bounds.x + bounds.width);

  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) { { 0, 0 }, { 55, 80 } }, 2, &subtract) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK && bounds.x >= 60,
         "subtracting a rectangle removes the left part (now from x %d)", bounds.x);

  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_POLYGON,
                            (GlimsPoint[]) { { 20, 70 }, { 40, 50 }, { 60, 70 } }, 3, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         bounds.x >= 19 && bounds.x + bounds.width <= 61 && bounds.y >= 49 && bounds.y + bounds.height <= 71,
         "a polygon selects within its vertices (%d,%d %dx%d)", bounds.x, bounds.y, bounds.width, bounds.height);
  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_POLYGON,
                            (GlimsPoint[]) { { 20, 70 }, { 40, 50 } }, 2, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a polygon needs three points");

  CHECK (api->select_color (engine, image, (GlimsPoint) { 30, 25 }, &color, &error) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         bounds.x >= 10 && bounds.x + bounds.width <= 50,
         "selecting the painted color around a point stays within the paint (%d,%d %dx%d)%s%s",
         bounds.x, bounds.y, bounds.width, bounds.height, error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  color.contiguous = false;
  CHECK (api->select_color (engine, image, (GlimsPoint) { 80, 70 }, &color, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         rect_equals (bounds, 0, 0, 100, 80),
         "selecting white everywhere reaches the image edges");

  CHECK (api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK && empty,
         "Select None empties the selection");
  CHECK (api->select_command (engine, image, GLIMS_SELECT_GROW, 4, &error) == GLIMS_STATUS_FAILED && error,
         "growing nothing is refused (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->select_command (engine, image, GLIMS_SELECT_INVERT, 0, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         rect_equals (bounds, 0, 0, 100, 80),
         "inverting nothing selects everything");
  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) { { 30, 30 }, { 50, 50 } }, 2, NULL) == GLIMS_STATUS_OK &&
         api->select_command (engine, image, GLIMS_SELECT_GROW, 5, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         rect_equals (bounds, 25, 25, 30, 30),
         "growing by 5 widens 20x20 to 30x30 (%dx%d)", bounds.width, bounds.height);
  /* The same after Select All, which leaves the engine believing the mask
   * is full (see forget_mask_state in Engine/select.c). */
  CHECK (api->select_command (engine, image, GLIMS_SELECT_ALL, 0, NULL) == GLIMS_STATUS_OK &&
         api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) { { 30, 30 }, { 50, 50 } }, 2, NULL) == GLIMS_STATUS_OK &&
         api->select_command (engine, image, GLIMS_SELECT_INVERT, 0, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         rect_equals (bounds, 0, 0, 100, 80),
         "after Select All, inverting a new rectangle selects around it (%d,%d %dx%d, empty %d)",
         bounds.x, bounds.y, bounds.width, bounds.height, empty);
  CHECK (api->select_command (engine, image, GLIMS_SELECT_INVERT, 0, NULL) == GLIMS_STATUS_OK &&
         api->select_command (engine, image, GLIMS_SELECT_SHRINK, 5, NULL) == GLIMS_STATUS_OK &&
         api->select_command (engine, image, GLIMS_SELECT_FEATHER, 3, NULL) == GLIMS_STATUS_OK &&
         api->select_command (engine, image, GLIMS_SELECT_BORDER, 2, NULL) == GLIMS_STATUS_OK &&
         api->select_command (engine, image, GLIMS_SELECT_SHARPEN, 0, NULL) == GLIMS_STATUS_OK,
         "shrink, feather, border and sharpen run");
  CHECK (api->select_command (engine, image, GLIMS_SELECT_FROM_ALPHA, 0, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         rect_equals (bounds, 0, 0, 100, 80),
         "Alpha to Selection of an opaque layer selects all of it");
  CHECK (api->select_command (engine, image, 99, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown command is rejected");

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK && ! rect_equals (bounds, 0, 0, 100, 80),
         "undo restores the previous selection");

  api->image_close (engine, image);
}

static int
layer_count (GlimsImageID image)
{
  GlimsImageInfo info;
  return api->image_info (engine, image, &info) == GLIMS_STATUS_OK ? info.layer_count : -1;
}

static void
test_editing (void)
{
  GlimsImageID          image = 0;
  GlimsItemID           background, layer = 0, copy = 0, merged = 0;
  GlimsLayerInfo        rows[4];
  GlimsImageInfo        info;
  int32_t               n = 0, before;
  uint8_t               pixel[4];
  int                   sizes = atomic_load (&size_events);
  char                 *error = NULL;
  GlimsFillSettings     fill = { .struct_size = sizeof fill, .mode = GLIMS_FILL_SELECTION,
                                 .color = { 1, 0, 0, 1 }, .opacity = 1, .threshold = 0.1, .antialias = true };
  GlimsGradientSettings gradient = { .struct_size = sizeof gradient, .shape = GLIMS_GRADIENT_LINEAR,
                                     .from = { 0, 0, 0, 1 }, .to = { 1, 1, 1, 1 }, .opacity = 1 };
  GlimsLayerChange      change = { .struct_size = sizeof change };

  api->image_new (engine, 100, 80, &image, NULL);
  background = first_layer (image);
  before     = undo_depth (image);

  CHECK (api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL) == GLIMS_STATUS_OK && layer > 0 &&
         layer_count (image) == 2 && undo_depth (image) == before + 1,
         "New Layer adds a layer as one undo step");
  api->image_layers (engine, image, rows, 4, &n);
  CHECK (n == 2 && rows[0].id == layer && rows[0].selected, "the new layer is on top and selected");

  CHECK (api->fill (engine, image, (GlimsPoint) { 0, 0 }, &fill, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 50, 40, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0,
         "filling the selection with no selection fills the whole layer red");

  change.properties = GLIMS_LAYER_OPACITY | GLIMS_LAYER_NAME;
  change.opacity    = 0.5;
  strcpy (change.name, "Tint");
  CHECK (api->layer_change (engine, image, layer, &change, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &n) == GLIMS_STATUS_OK &&
         strcmp (rows[0].name, "Tint") == 0 && rows[0].opacity > 0.49 && rows[0].opacity < 0.51 &&
         red_at (image, 50, 40) == 255 && api->image_render (engine, image, 1.0, (GlimsRect) { 50, 40, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] > 180 && pixel[1] < 196,
         "half opacity blends in linear light, as GIMP's Normal mode does (green %d, 188 expected)", pixel[1]);
  change.properties = GLIMS_LAYER_MODE;
  strcpy (change.mode, "multiply");
  CHECK (api->layer_change (engine, image, layer, &change, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &n) == GLIMS_STATUS_OK && strcmp (rows[0].mode, "multiply") == 0,
         "the blend mode changes by its nick");
  strcpy (change.mode, "no-such-mode");
  CHECK (api->layer_change (engine, image, layer, &change, &error) == GLIMS_STATUS_FAILED && error,
         "an unknown blend mode is refused (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  strcpy (change.mode, "behind");
  CHECK (api->layer_change (engine, image, layer, &change, &error) == GLIMS_STATUS_INVALID_ARGUMENT && error,
         "a paint-only blend mode (behind) is refused for a layer");
  api->free_string (error);
  error = NULL;
  change.properties = GLIMS_LAYER_VISIBLE;
  change.visible    = false;
  CHECK (api->layer_change (engine, image, layer, &change, NULL) == GLIMS_STATUS_OK && red_at (image, 50, 40) == 255 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 50, 40, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK && pixel[1] == 255,
         "hiding the layer shows the white background");

  CHECK (api->layer_select (engine, image, background) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &n) == GLIMS_STATUS_OK && rows[1].selected && ! rows[0].selected,
         "selecting the background in the engine");
  CHECK (api->layer_select (engine, image, 4242) == GLIMS_STATUS_NOT_FOUND, "selecting an unknown layer is reported");

  fill.mode  = GLIMS_FILL_SIMILAR_COLORS;
  fill.color = (GlimsColor) { 0, 0, 1, 1 };
  CHECK (api->fill (engine, image, (GlimsPoint) { 5, 5 }, &fill, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 90, 70, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[2] == 255 && pixel[0] == 0,
         "a bucket fill of similar colors floods the white background blue (%d,%d,%d,%d at 90,70)",
         pixel[0], pixel[1], pixel[2], pixel[3]);

  CHECK (api->gradient (engine, image, (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 }, &gradient, NULL) == GLIMS_STATUS_OK &&
         red_at (image, 10, 40) < 60 && red_at (image, 90, 40) > 190,
         "a black-to-white linear gradient (%d at the left, %d at the right)", red_at (image, 10, 40), red_at (image, 90, 40));
  CHECK (api->gradient (engine, image, (GlimsPoint) { 5, 5 }, (GlimsPoint) { 5, 5 }, &gradient, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a gradient needs two distinct points");

  CHECK (api->layer_move (engine, image, layer, 10, 5) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &n) == GLIMS_STATUS_OK && rows[0].bounds.x == 10 && rows[0].bounds.y == 5,
         "moving the layer by 10,5");

  CHECK (api->layer_command (engine, image, layer, GLIMS_LAYER_DUPLICATE, &copy, NULL) == GLIMS_STATUS_OK && copy > 0 &&
         layer_count (image) == 3, "duplicating the layer");
  CHECK (api->layer_command (engine, image, copy, GLIMS_LAYER_TO_BOTTOM, NULL, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &n) == GLIMS_STATUS_OK && rows[2].id == copy,
         "sending the copy to the bottom");
  CHECK (api->layer_command (engine, image, copy, GLIMS_LAYER_RAISE, NULL, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &n) == GLIMS_STATUS_OK && rows[1].id == copy,
         "raising it one step");
  CHECK (api->layer_command (engine, image, copy, GLIMS_LAYER_DELETE, NULL, NULL) == GLIMS_STATUS_OK && layer_count (image) == 2,
         "deleting it");
  change.properties = GLIMS_LAYER_VISIBLE;
  change.visible    = true;
  api->layer_change (engine, image, layer, &change, NULL);
  CHECK (api->layer_command (engine, image, layer, GLIMS_LAYER_MERGE_DOWN, &merged, NULL) == GLIMS_STATUS_OK && merged > 0 &&
         layer_count (image) == 1, "merging the top layer down");
  CHECK (api->layer_command (engine, image, 0, GLIMS_LAYER_FLATTEN, NULL, NULL) == GLIMS_STATUS_OK && layer_count (image) == 1,
         "flattening");
  CHECK (api->layer_command (engine, image, 0, 99, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT, "an unknown layer command is rejected");

  CHECK (api->image_crop (engine, image, (GlimsRect) { 10, 10, 50, 40 }, NULL) == GLIMS_STATUS_OK &&
         api->image_info (engine, image, &info) == GLIMS_STATUS_OK && info.width == 50 && info.height == 40 &&
         atomic_load (&size_events) > sizes,
         "cropping to 50x40 changes the size and reports it (%dx%d)", info.width, info.height);
  CHECK (api->image_crop (engine, image, (GlimsRect) { 500, 500, 10, 10 }, &error) == GLIMS_STATUS_FAILED && error,
         "a crop outside the image is refused");
  api->free_string (error);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_info (engine, image, &info) == GLIMS_STATUS_OK && info.width == 100 && info.height == 80,
         "undo restores the uncropped size");

  api->image_close (engine, image);
}

static void
test_transforms (void)
{
  GlimsImageID       image = 0;
  GlimsImageInfo     info;
  GlimsSelectOptions none = { .struct_size = sizeof none };
  GlimsFillSettings  fill = { .struct_size = sizeof fill, .mode = GLIMS_FILL_SELECTION,
                              .color = { 0, 0, 0, 1 }, .opacity = 1, .antialias = true };
  GlimsColor         blue = { 0, 0, 1, 1 };
  uint8_t            pixel[4];
  int32_t            before;
  int                sizes = atomic_load (&size_events);
  char              *error = NULL;

  /* A black strip along the left edge, 20 pixels wide. */
  api->image_new (engine, 100, 60, &image, NULL);
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE, (GlimsPoint[]) { { 0, 0 }, { 20, 60 } }, 2, &none);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &fill, NULL);
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  before = undo_depth (image);

  CHECK (api->image_transform (engine, image, GLIMS_TRANSFORM_ROTATE_90) == GLIMS_STATUS_OK &&
         api->image_info (engine, image, &info) == GLIMS_STATUS_OK && info.width == 60 && info.height == 100 &&
         red_at (image, 30, 5) == 0 && red_at (image, 30, 90) == 255 && atomic_load (&size_events) > sizes,
         "rotating 90° clockwise turns 100x60 into 60x100 with the strip on top");
  CHECK (undo_depth (image) == before + 1, "the rotation is one undo step");
  CHECK (api->image_transform (engine, image, GLIMS_TRANSFORM_ROTATE_270) == GLIMS_STATUS_OK &&
         api->image_info (engine, image, &info) == GLIMS_STATUS_OK && info.width == 100 &&
         red_at (image, 5, 30) == 0 && red_at (image, 95, 30) == 255,
         "rotating 90° back puts the strip on the left again");
  CHECK (api->image_transform (engine, image, GLIMS_TRANSFORM_FLIP_HORIZONTAL) == GLIMS_STATUS_OK &&
         red_at (image, 95, 30) == 0 && red_at (image, 5, 30) == 255,
         "flipping horizontally moves the strip to the right");
  CHECK (api->image_transform (engine, image, 42) == GLIMS_STATUS_INVALID_ARGUMENT, "an unknown transform is rejected");

  CHECK (api->image_scale (engine, image, 50, 30, NULL) == GLIMS_STATUS_OK &&
         api->image_info (engine, image, &info) == GLIMS_STATUS_OK && info.width == 50 && info.height == 30 &&
         red_at (image, 47, 15) < 32 && red_at (image, 10, 15) == 255,
         "Image Size scales to 50x30 with the strip still at the right");
  CHECK (api->image_scale (engine, image, 0, 30, &error) == GLIMS_STATUS_FAILED && error,
         "a zero size is refused");
  api->free_string (error);
  error = NULL;

  CHECK (api->image_resize_canvas (engine, image, 70, 50, 10, 10, &blue, NULL) == GLIMS_STATUS_OK &&
         api->image_info (engine, image, &info) == GLIMS_STATUS_OK && info.width == 70 && info.height == 50 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 2, 2, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[2] == 255 && pixel[0] == 0 && red_at (image, 30, 25) == 255,
         "Canvas Size to 70x50 grows the background and fills the new edge with the color");

  before = undo_depth (image);
  CHECK (api->layer_transform (engine, image, 0, GLIMS_TRANSFORM_FLIP_VERTICAL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "flipping the layer is one undo step");
  CHECK (api->layer_transform (engine, image, 4242, GLIMS_TRANSFORM_FLIP_VERTICAL) == GLIMS_STATUS_NOT_FOUND,
         "transforming an unknown layer is reported");

  api->image_close (engine, image);
}

/* The matrix transform the Transform tool commits: layer bounds follow
 * the matrix, pixels move with it, one undo step, bad input refused. */
static void
test_matrix_transform (void)
{
  GlimsImageID       image = 0;
  GlimsLayerInfo     row;
  int32_t            count = 0, before;
  GlimsSelectOptions none = { .struct_size = sizeof none };
  GlimsFillSettings  fill = { .struct_size = sizeof fill, .mode = GLIMS_FILL_SELECTION,
                              .color = { 0, 0, 0, 1 }, .opacity = 1, .antialias = true };
  GlimsMatrix        half = { { { 0.5, 0, 0 }, { 0, 0.5, 0 }, { 0, 0, 1 } } };
  GlimsMatrix        shift = { { { 1, 0, 10 }, { 0, 1, 5 }, { 0, 0, 1 } } };
  GlimsMatrix        flat = { { { 1, 0, 0 }, { 2, 0, 0 }, { 0, 0, 1 } } };
  GlimsMatrix        broken = { { { NAN, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } };
  double             c = cos (M_PI / 4), s = sin (M_PI / 4);
  GlimsMatrix        turn = { { { c, -s, 50 - 50 * c + 30 * s }, { s, c, 30 - 50 * s - 30 * c }, { 0, 0, 1 } } };
  char              *error = NULL;

  /* A black square in the top-left quarter of a white 100x60 image. */
  api->image_new (engine, 100, 60, &image, NULL);
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE, (GlimsPoint[]) { { 0, 0 }, { 50, 30 } }, 2, &none);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &fill, NULL);
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  before = undo_depth (image);

  CHECK (api->layer_transform_matrix (engine, image, 0, &half, GLIMS_INTERPOLATION_LINEAR, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK &&
         row.bounds.x == 0 && row.bounds.y == 0 && row.bounds.width == 50 && row.bounds.height == 30,
         "scaling by half shrinks the layer to 50x30 at the origin (%d,%d %dx%d)",
         row.bounds.x, row.bounds.y, row.bounds.width, row.bounds.height);
  CHECK (undo_depth (image) == before + 1, "the transform is one undo step");
  CHECK (red_at (image, 10, 5) == 0 && red_at (image, 40, 25) == 255,
         "the black quarter now fills the scaled layer's top-left quarter");

  CHECK (api->layer_transform_matrix (engine, image, 0, &shift, GLIMS_INTERPOLATION_NONE, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK &&
         row.bounds.x == 10 && row.bounds.y == 5,
         "a translation moves the layer to (10,5) (%d,%d)", row.bounds.x, row.bounds.y);

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK &&
         row.bounds.width == 100 && row.bounds.height == 60 && red_at (image, 40, 25) == 0,
         "undoing both restores the full-size layer and its pixels");

  CHECK (api->layer_transform_matrix (engine, image, 0, &turn, GLIMS_INTERPOLATION_DEFAULT, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK &&
         row.bounds.width > 100 && row.bounds.height > 60,
         "a 45° turn around the center grows the layer to hold its corners (%dx%d)",
         row.bounds.width, row.bounds.height);

  before = undo_depth (image);
  CHECK (api->layer_transform_matrix (engine, image, 0, &flat, 0, &error) == GLIMS_STATUS_INVALID_ARGUMENT && error &&
         undo_depth (image) == before,
         "a matrix that flattens the layer is refused, with no undo step");
  api->free_string (error);
  error = NULL;
  CHECK (api->layer_transform_matrix (engine, image, 0, &broken, 0, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a matrix that is not finite is refused");
  api->free_string (error);
  CHECK (api->layer_transform_matrix (engine, image, 0, &half, 99, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown interpolation is refused");
  CHECK (api->layer_transform_matrix (engine, image, 4242, &half, 0, NULL) == GLIMS_STATUS_NOT_FOUND,
         "an unknown layer is reported");
  CHECK (api->layer_transform_matrix (engine, image, 0, NULL, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a missing matrix is refused");

  api->image_close (engine, image);
}

/* Text layers: the font list, creating a layer from settings, reading it
 * back, changing text and look as undo steps, refusals, and an XCF round
 * trip keeping the text editable. */
static void
test_text_layers (const char *work)
{
  GlimsImageID      image = 0, reopened = 0;
  GlimsItemID       layer = 0, background;
  GlimsTextSettings settings = { .struct_size = sizeof settings, .size = 24,
                                 .color = { 0, 0, 0, 1 }, .justify = GLIMS_JUSTIFY_LEFT,
                                 .antialias = true };
  GlimsTextSettings read = { .struct_size = sizeof read };
  GlimsLayerInfo    rows[2];
  int32_t           count = 0, before;
  char             *fonts = NULL, *text = NULL, *error = NULL, *newline, xcf[1024];
  double            first_width;
  int32_t           darkest = 255, x, y;

  CHECK (api->fonts (engine, &fonts) == GLIMS_STATUS_OK && fonts && *fonts, "the engine lists fonts");
  if (! fonts || ! *fonts)
    {
      api->free_string (fonts);
      return;
    }
  /* Sans-serif is GIMP's default font; any listed font will do otherwise. */
  if (strstr (fonts, "Sans-serif\n") == fonts || strstr (fonts, "\nSans-serif\n"))
    strcpy (settings.font, "Sans-serif");
  else
    {
      newline = strchr (fonts, '\n');
      snprintf (settings.font, sizeof settings.font, "%.*s",
                (int) (newline ? newline - fonts : (ptrdiff_t) strlen (fonts)), fonts);
    }
  api->free_string (fonts);

  api->image_new (engine, 300, 120, &image, NULL);
  background = first_layer (image);
  before = undo_depth (image);

  CHECK (api->text_layer_new (engine, image, "Hello", &settings, (GlimsPoint) { 10, 20 }, &layer, &error)
           == GLIMS_STATUS_OK && layer != 0,
         "a text layer is added in %s%s%s", settings.font, error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (undo_depth (image) == before + 1, "adding it is one undo step");
  CHECK (api->image_layers (engine, image, rows, 2, &count) == GLIMS_STATUS_OK && count == 2 &&
         rows[0].id == layer && rows[0].kind == GLIMS_LAYER_TEXT && rows[0].selected &&
         rows[0].bounds.x == 10 && rows[0].bounds.y == 20 && rows[0].bounds.width > 20,
         "it sits on top at (10,20), selected, as a text layer (%d,%d %dx%d)",
         rows[0].bounds.x, rows[0].bounds.y, rows[0].bounds.width, rows[0].bounds.height);
  first_width = rows[0].bounds.width;

  for (y = rows[0].bounds.y; y < rows[0].bounds.y + rows[0].bounds.height; y += 2)
    for (x = rows[0].bounds.x; x < rows[0].bounds.x + rows[0].bounds.width; x += 2)
      darkest = MIN (darkest, red_at (image, x, y));
  CHECK (darkest < 64, "the text draws in its color (darkest red %d)", darkest);

  CHECK (api->text_layer_get (engine, image, layer, &text, &read) == GLIMS_STATUS_OK &&
         text && strcmp (text, "Hello") == 0 && strcmp (read.font, settings.font) == 0 &&
         fabs (read.size - 24) < 0.01 && read.justify == GLIMS_JUSTIFY_LEFT &&
         read.color.red < 0.01 && read.color.alpha > 0.99 && read.antialias,
         "the text and its settings read back (%s, %s, %.2f px)", text ? text : "", read.font, read.size);
  api->free_string (text);
  text = NULL;

  before = undo_depth (image);
  CHECK (api->text_layer_set (engine, image, layer, "Hello, world", NULL, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->image_layers (engine, image, rows, 2, &count) == GLIMS_STATUS_OK &&
         rows[0].bounds.width > first_width,
         "changing the text is one undo step and widens the layer (%d)", rows[0].bounds.width);
  settings.size = 48;
  settings.justify = GLIMS_JUSTIFY_CENTER;
  CHECK (api->text_layer_set (engine, image, layer, NULL, &settings, NULL) == GLIMS_STATUS_OK &&
         api->text_layer_get (engine, image, layer, &text, &read) == GLIMS_STATUS_OK &&
         strcmp (text, "Hello, world") == 0 && fabs (read.size - 48) < 0.01 &&
         read.justify == GLIMS_JUSTIFY_CENTER,
         "changing the look keeps the text");
  api->free_string (text);
  text = NULL;
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->text_layer_get (engine, image, layer, &text, &read) == GLIMS_STATUS_OK &&
         strcmp (text, "Hello") == 0 && fabs (read.size - 24) < 0.01,
         "undo brings back the first text and size");
  api->free_string (text);
  text = NULL;
  settings.size = 24;
  settings.justify = GLIMS_JUSTIFY_LEFT;

  strcpy (read.font, "No Such Font Anywhere");
  read.size = 12;
  read.justify = GLIMS_JUSTIFY_LEFT;
  CHECK (api->text_layer_new (engine, image, "x", &read, (GlimsPoint) { 0, 0 }, NULL, &error)
           == GLIMS_STATUS_NOT_FOUND && error,
         "an unknown font is reported");
  api->free_string (error);
  error = NULL;
  CHECK (api->text_layer_new (engine, image, "", &settings, (GlimsPoint) { 0, 0 }, NULL, NULL)
           == GLIMS_STATUS_INVALID_ARGUMENT,
         "empty text is refused");
  read = settings;
  read.size = -3;
  CHECK (api->text_layer_set (engine, image, layer, NULL, &read, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a negative size is refused");
  api->free_string (error);
  error = NULL;
  CHECK (api->text_layer_get (engine, image, background, &text, NULL) == GLIMS_STATUS_NOT_FOUND,
         "a pixel layer is not a text layer");

  snprintf (xcf, sizeof xcf, "%s/text.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, reopened, rows, 2, &count) == GLIMS_STATUS_OK &&
         rows[0].kind == GLIMS_LAYER_TEXT &&
         api->text_layer_get (engine, reopened, rows[0].id, &text, &read) == GLIMS_STATUS_OK &&
         strcmp (text, "Hello") == 0 && strcmp (read.font, settings.font) == 0,
         "an XCF round trip keeps the text layer editable");
  api->free_string (text);

  if (reopened)
    api->image_close (engine, reopened);
  api->image_close (engine, image);
}

/* Paths: adding one from anchors and handles, reading it back, replacing
 * its subpaths, renaming and showing it, each an undo step; drawing it as
 * a line and turning it into a selection; refusals; deleting; and an XCF
 * round trip. */
static GlimsPathPoint
corner (double x, double y)
{
  return (GlimsPathPoint) { { x, y }, { x, y }, { x, y } };
}

static void
test_paths (const char *work)
{
  GlimsImageID      image = 0, reopened = 0;
  GlimsItemID       path = 0;
  GlimsPathInfo     rows[2];
  GlimsSubpath      square[1] = { { .count = 4, .closed = true } };
  GlimsPathPoint    points[6] = { corner (20, 20), corner (80, 20), corner (80, 80), corner (20, 80) };
  GlimsSubpath      both[2]   = { { .count = 4, .closed = true }, { .count = 2, .closed = false } };
  GlimsSubpath      read_subpaths[4];
  GlimsPathPoint    read_points[8];
  GlimsPathChange   change = { .struct_size = sizeof change, .visible = -1 };
  GlimsLineSettings line = { .struct_size = sizeof line, .width = 4, .color = { 0, 0, 0, 1 },
                             .antialias = false };
  GlimsSelectOptions select = { .struct_size = sizeof select, .operation = GLIMS_SELECT_REPLACE };
  GlimsRect         bounds;
  int32_t           count = -1, subpath_count = -1, point_count = -1, before;
  bool              empty = true;
  char             *error = NULL, xcf[1024];

  /* An open curve from (100,50) to (180,50) whose handles lift its middle
   * to (140,20). */
  points[4] = (GlimsPathPoint) { { 100, 50 }, { 100, 50 }, { 120, 10 } };
  points[5] = (GlimsPathPoint) { { 160, 10 }, { 180, 50 }, { 180, 50 } };

  api->image_new (engine, 200, 100, &image, NULL);
  CHECK (api->paths (engine, image, rows, 2, &count) == GLIMS_STATUS_OK && count == 0,
         "a new image has no paths");

  before = undo_depth (image);
  CHECK (api->path_set (engine, image, 0, "Outline", square, 1, points, 4, &path, &error)
           == GLIMS_STATUS_OK && path != 0,
         "a path is added from anchors%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (undo_depth (image) == before + 1, "adding it is one undo step");
  CHECK (api->paths (engine, image, rows, 2, &count) == GLIMS_STATUS_OK && count == 1 &&
         rows[0].id == path && strcmp (rows[0].name, "Outline") == 0 && rows[0].selected &&
         ! rows[0].visible,
         "it is listed by name, selected and hidden, as GIMP adds paths");
  CHECK (api->path_get (engine, image, path, read_subpaths, 4, &subpath_count, read_points, 8,
                        &point_count) == GLIMS_STATUS_OK &&
         subpath_count == 1 && point_count == 4 && read_subpaths[0].count == 4 && read_subpaths[0].closed &&
         read_points[2].anchor.x == 80 && read_points[2].anchor.y == 80 &&
         read_points[2].in.x == 80 && read_points[2].out.y == 80,
         "its closed subpath reads back with corner anchors");

  before = undo_depth (image);
  CHECK (api->path_set (engine, image, path, NULL, both, 2, points, 6, NULL, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->path_get (engine, image, path, read_subpaths, 4, &subpath_count, read_points, 8,
                        &point_count) == GLIMS_STATUS_OK &&
         subpath_count == 2 && point_count == 6 && ! read_subpaths[1].closed &&
         read_points[4].out.x == 120 && read_points[4].out.y == 10 &&
         read_points[5].in.x == 160 && read_points[5].anchor.x == 180,
         "replacing the subpaths is one undo step and keeps the handles");
  CHECK (api->path_get (engine, image, path, NULL, 0, &subpath_count, NULL, 0, &point_count)
           == GLIMS_STATUS_OK && subpath_count == 2 && point_count == 6,
         "the counts alone can be asked for");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->path_get (engine, image, path, NULL, 0, &subpath_count, NULL, 0, &point_count)
           == GLIMS_STATUS_OK && subpath_count == 1 && point_count == 4,
         "undo brings back the single square");
  api->image_redo (engine, image);

  before = undo_depth (image);
  change.name = "Square";
  change.visible = 1;
  CHECK (api->path_change (engine, image, path, &change, NULL) == GLIMS_STATUS_OK &&
         api->paths (engine, image, rows, 2, &count) == GLIMS_STATUS_OK &&
         strcmp (rows[0].name, "Square") == 0 && rows[0].visible && undo_depth (image) == before + 2,
         "renaming and showing it are undo steps");

  before = undo_depth (image);
  CHECK (api->path_stroke (engine, image, path, 0, &line, &error) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "drawing it as a line is one undo step%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (red_at (image, 20, 50) < 64 && red_at (image, 140, 20) < 64 && red_at (image, 50, 50) > 200,
         "the line follows the square and the curve's bulge (%d, %d), not the inside (%d)",
         red_at (image, 20, 50), red_at (image, 140, 20), red_at (image, 50, 50));

  before = undo_depth (image);
  CHECK (api->path_to_selection (engine, image, path, &select) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK && ! empty &&
         abs (bounds.x - 20) <= 1 && abs (bounds.y - 20) <= 1 &&
         abs (bounds.x + bounds.width - 180) <= 1 && abs (bounds.y + bounds.height - 80) <= 1,
         "its area becomes the selection, open curve included (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);

  CHECK (api->path_set (engine, image, path, NULL, both, 2, points, 5, NULL, NULL)
           == GLIMS_STATUS_INVALID_ARGUMENT,
         "subpath counts that do not add up are refused");
  points[1].out.x = NAN;
  CHECK (api->path_set (engine, image, 0, NULL, square, 1, points, 4, NULL, NULL)
           == GLIMS_STATUS_INVALID_ARGUMENT,
         "a point that is not finite is refused");
  points[1].out.x = 80;
  CHECK (api->path_get (engine, image, first_layer (image), NULL, 0, &subpath_count, NULL, 0, &point_count)
           == GLIMS_STATUS_NOT_FOUND,
         "a layer is not a path");
  line.width = 0;
  CHECK (api->path_stroke (engine, image, path, 0, &line, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a line without width is refused");

  snprintf (xcf, sizeof xcf, "%s/paths.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
         api->paths (engine, reopened, rows, 2, &count) == GLIMS_STATUS_OK && count == 1 &&
         strcmp (rows[0].name, "Square") == 0 &&
         api->path_get (engine, reopened, rows[0].id, read_subpaths, 4, &subpath_count, read_points, 8,
                        &point_count) == GLIMS_STATUS_OK &&
         subpath_count == 2 && point_count == 6 && read_points[4].out.y == 10,
         "an XCF round trip keeps the path");

  before = undo_depth (image);
  CHECK (api->path_delete (engine, image, path) == GLIMS_STATUS_OK && undo_depth (image) == before + 1 &&
         api->paths (engine, image, rows, 2, &count) == GLIMS_STATUS_OK && count == 0,
         "deleting it is one undo step");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->paths (engine, image, rows, 2, &count) == GLIMS_STATUS_OK && count == 1,
         "undo brings it back");

  if (reopened)
    api->image_close (engine, reopened);
  api->image_close (engine, image);
}

/* Filling a path onto a drawable, the core's gimp_item_fill: a closed
 * rectangle and a closed cubic subpath filled with a known color, inside
 * and outside pixels, opacity, selection clipping, mask and channel
 * targets, locks, undo/redo, refusals with no side effects, and BUSY
 * while a stroke or a filter session is open. */
static void
test_path_fill (const char *work)
{
  GlimsImageID          image = 0, other = 0;
  GlimsItemID           path = 0, empty = 0, layer, layer2 = 0, group = 0, mask = 0, channel = 0;
  GlimsSubpath          subpaths[2] = { { .count = 4, .closed = true }, { .count = 4, .closed = true } };
  GlimsPathPoint        points[8];
  GlimsPathFillSettings fill = { .struct_size = sizeof fill, .color = { 1, 0, 0, 1 },
                                 .opacity = 1, .antialias = false };
  GlimsFillSettings     white = { .struct_size = sizeof white, .mode = GLIMS_FILL_SELECTION,
                                  .color = { 1, 1, 1, 1 }, .opacity = 1 };
  GlimsRect             bounds;
  GlimsSelectOptions    sel = { .struct_size = sizeof sel, .operation = GLIMS_SELECT_REPLACE };
  bool                  empty_sel = true;
  int32_t               before;
  uint8_t               px[4];
  GlimsStrokeID         stroke = 0;
  GlimsFilterID         filter = 0;
  GlimsBrushSettings    brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  GlimsStrokePoint      point = { 5, 5, 1.0, 0.0, 0.0, 0 };
  GlimsStatus           status;
  char                 *error = NULL;

  (void) work;

  /* A closed rectangle 20,20 ... 80,80 and a closed cubic blob around
   * (140,60) with radius 30 (handles at 0.55 * r for a circle). */
  points[0] = corner (20, 20);
  points[1] = corner (80, 20);
  points[2] = corner (80, 80);
  points[3] = corner (20, 80);
  points[4] = (GlimsPathPoint) { { 123.4, 30 }, { 140, 30 }, { 156.6, 30 } };
  points[5] = (GlimsPathPoint) { { 170, 43.4 }, { 170, 60 }, { 170, 76.6 } };
  points[6] = (GlimsPathPoint) { { 156.6, 90 }, { 140, 90 }, { 123.4, 90 } };
  points[7] = (GlimsPathPoint) { { 110, 76.6 }, { 110, 60 }, { 110, 43.4 } };

  api->image_new (engine, 200, 120, &image, NULL);
  layer = first_layer (image);

  CHECK (api->path_set (engine, image, 0, "Area", subpaths, 2, points, 8, &path, &error)
           == GLIMS_STATUS_OK && path != 0,
         "the rectangle-and-cubic path is added%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  before = undo_depth (image);
  CHECK (api->path_fill (engine, image, path, layer, &fill, &error) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "filling the path is one undo step%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  render_pixel (image, 50, 50, px);
  CHECK (px[0] == 255 && px[1] == 0 && px[3] == 255,
         "the rectangle's interior is filled red (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
  render_pixel (image, 140, 60, px);
  CHECK (px[0] == 255 && px[1] == 0,
         "the closed cubic's interior is filled red (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
  render_pixel (image, 10, 10, px);
  CHECK (px[0] == 255 && px[1] == 255,
         "outside the path the white background is untouched (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
  render_pixel (image, 95, 60, px);
  CHECK (px[0] == 255 && px[1] == 255,
         "between the two subpaths stays white (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         (render_pixel (image, 50, 50, px), px[1] == 255) &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         (render_pixel (image, 50, 50, px), px[0] == 255 && px[1] == 0),
         "undo empties the fill again, redo brings it back");

  /* Half opacity blends with what is underneath. */
  api->image_undo (engine, image); /* Back to white after the redo check. */
  fill.opacity = 0.5;
  before = undo_depth (image);
  CHECK (api->path_fill (engine, image, path, layer, &fill, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "filling at half opacity is one undo step");
  render_pixel (image, 50, 50, px);
  CHECK (px[0] == 255 && px[1] > 128 && px[1] < 250,
         "half opacity blends the red over white (green %d, between full and none)", px[1]);
  fill.opacity = 1;
  api->image_undo (engine, image);

  /* The fill stays inside the selection, and the selection survives. */
  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) { { 0, 0 }, { 40, 120 } }, 2, &sel) == GLIMS_STATUS_OK,
         "a left strip 0,0 40x120 is selected");
  before = undo_depth (image);
  CHECK (api->path_fill (engine, image, path, layer, &fill, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         (render_pixel (image, 30, 50, px), px[0] == 255 && px[1] == 0) &&
         (render_pixel (image, 50, 50, px), px[1] == 255) &&
         api->selection_bounds (engine, image, &empty_sel, &bounds) == GLIMS_STATUS_OK && ! empty_sel &&
         rect_equals (bounds, 0, 0, 40, 120),
         "the fill stays inside the selection and the selection is preserved (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);

  /* A layer mask as the explicit target: filling it moves the mask, and
   * the mask to the selection, to the path's bounds. */
  CHECK (api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer2, NULL) == GLIMS_STATUS_OK &&
         api->fill (engine, image, (GlimsPoint) { 0, 0 }, &white, NULL) == GLIMS_STATUS_OK &&
         api->layer_mask_add (engine, image, layer2, GLIMS_MASK_BLACK, false, &mask, &error) == GLIMS_STATUS_OK &&
         mask != 0,
         "a second layer with a black mask is ready%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  fill.color = (GlimsColor) { 1, 1, 1, 1 };
  before = undo_depth (image);
  CHECK (api->path_fill (engine, image, path, mask, &fill, &error) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "filling the path onto the mask is one undo step%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->layer_mask_to_selection (engine, image, layer2, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty_sel, &bounds) == GLIMS_STATUS_OK && ! empty_sel &&
         abs (bounds.x - 20) <= 1 && abs (bounds.y - 20) <= 1 &&
         abs (bounds.x + bounds.width - 170) <= 1 && abs (bounds.y + bounds.height - 90) <= 1,
         "the filled mask selects the path's bounds (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  fill.color = (GlimsColor) { 1, 0, 0, 1 };

  /* A saved channel as the explicit target. */
  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) { { 0, 0 }, { 30, 30 } }, 2, &sel) == GLIMS_STATUS_OK &&
         api->channel_from_selection (engine, image, "sel", &channel, NULL) == GLIMS_STATUS_OK && channel != 0 &&
         api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL) == GLIMS_STATUS_OK,
         "a channel is saved from a small selection");
  fill.color = (GlimsColor) { 1, 1, 1, 1 };
  before = undo_depth (image);
  CHECK (api->path_fill (engine, image, path, channel, &fill, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->channel_to_selection (engine, image, channel, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty_sel, &bounds) == GLIMS_STATUS_OK && ! empty_sel &&
         bounds.x == 0 && bounds.y == 0 &&
         abs (bounds.width - 170) <= 1 && abs (bounds.height - 90) <= 1,
         "the channel fill keeps its original area and adds the path as one undo step (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  api->channel_command (engine, image, channel, GLIMS_CHANNEL_DELETE, NULL, NULL);
  fill.color = (GlimsColor) { 1, 0, 0, 1 };

  /* A pixel-locked target is refused, inherited locks included. */
  CHECK (api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL) == GLIMS_STATUS_OK,
         "the layer's pixels are locked");
  before = undo_depth (image);
  {
    uint8_t previous[4];

    render_pixel (image, 140, 60, previous);
    status = api->path_fill (engine, image, path, layer, &fill, &error);
    CHECK (status == GLIMS_STATUS_LOCKED && error && undo_depth (image) == before &&
           (render_pixel (image, 140, 60, px), memcmp (previous, px, sizeof px) == 0),
           "filling a locked layer is LOCKED and changes nothing (%s)", error ? error : "");
  }
  api->free_string (error);
  error = NULL;
  api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, 0, NULL);

  /* Refusals: unknown and foreign ids, bad settings, a group target and
   * an empty path — each with no undo step and no other side effect. */
  api->image_new (engine, 64, 64, &other, NULL);
  before = undo_depth (image);
  CHECK (api->path_fill (engine, image, 9999, layer, &fill, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->path_fill (engine, image, layer, layer, &fill, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->path_fill (engine, image, path, 9999, &fill, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->path_fill (engine, image, path, first_layer (other), &fill, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->path_fill (engine, 9999, path, layer, &fill, NULL) == GLIMS_STATUS_NOT_FOUND &&
         undo_depth (image) == before,
         "unknown image, path and drawable ids, and a foreign drawable, are NOT_FOUND with no undo");
  api->image_close (engine, other);

  fill.opacity = 2.0;
  CHECK (api->path_fill (engine, image, path, layer, &fill, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == before,
         "an opacity above 1 is refused");
  fill.opacity = NAN;
  CHECK (api->path_fill (engine, image, path, layer, &fill, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a non-finite opacity is refused");
  fill.opacity = 1.0;
  fill.color.red = NAN;
  CHECK (api->path_fill (engine, image, path, layer, &fill, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a non-finite color is refused");
  fill.color.red = 1.0;
  CHECK (api->path_fill (engine, image, path, layer, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->path_fill (engine, image, path, layer,
                         &(GlimsPathFillSettings) { .struct_size = 4 }, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == before,
         "NULL or short settings are refused with no undo");

  CHECK (api->create_group (engine, image, 0, 0, "G", &group, NULL) == GLIMS_STATUS_OK && group != 0,
         "a group is created");
  status = api->path_fill (engine, image, path, group, &fill, &error);
  CHECK (status == GLIMS_STATUS_FAILED && error && undo_depth (image) == before + 1,
         "filling onto a group is refused and adds no undo (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  api->layer_command (engine, image, group, GLIMS_LAYER_DELETE, NULL, NULL);

  CHECK (api->path_set (engine, image, 0, "Empty", NULL, 0, NULL, 0, &empty, NULL) == GLIMS_STATUS_OK &&
         empty != 0,
         "an empty path is added");
  before = undo_depth (image);
  status = api->path_fill (engine, image, empty, layer, &fill, &error);
  CHECK (status == GLIMS_STATUS_FAILED && error && undo_depth (image) == before,
         "filling an empty path fails clearly with no undo step (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  api->path_delete (engine, image, empty);

  /* BUSY while a stroke or a filter session is open. */
  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK &&
         api->path_fill (engine, image, path, layer, &fill, NULL) == GLIMS_STATUS_BUSY &&
         api->stroke_end (engine, stroke) == GLIMS_STATUS_OK,
         "filling during an open stroke is BUSY");
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK &&
         api->path_fill (engine, image, path, layer, &fill, NULL) == GLIMS_STATUS_BUSY &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "filling during an open filter session is BUSY%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);

  api->image_close (engine, image);
}

static int
supports_vector_layers (void)
{
  int major = 0, minor = 0;
  sscanf (api->engine_version (engine), "%d.%d", &major, &minor);
  return major > 3 || (major == 3 && minor >= 2);
}

/* A genuine vector layer from a path, the core's gimp_vector_layer_new:
 * native kind, rendered pixels, the path's lifetime with the layer, one
 * undo step, an XCF round trip as structured content, refusals, and on
 * engines without vector layers UNSUPPORTED with no undo. */
static void
test_path_vector_layer (const char *work)
{
  GlimsImageID      image = 0, reopened = 0;
  GlimsItemID       path = 0, vector = 0, v = 0, layer;
  GlimsSubpath      square[1] = { { .count = 4, .closed = true } };
  GlimsPathPoint    points[4] = { corner (20, 20), corner (80, 20), corner (80, 80), corner (20, 80) };
  GlimsPathPoint    moved[4]  = { corner (30, 30), corner (90, 30), corner (90, 90), corner (30, 90) };
  GlimsLayerInfo    rows[4];
  GlimsPathInfo     prows[2];
  GlimsSubpath      rsub[2];
  GlimsPathPoint    rpts[8];
  GlimsFillSettings red_bg = { .struct_size = sizeof red_bg, .mode = GLIMS_FILL_SELECTION,
                               .color = { 1, 0, 0, 1 }, .opacity = 1 };
  int32_t           count = 0, pcount = 0, subcount = 0, ptcount = 0, before;
  uint8_t           px[4];
  GlimsStrokeID     stroke = 0;
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  GlimsStrokePoint  point = { 5, 5, 1.0, 0.0, 0.0, 0 };
  GlimsStatus       status;
  char              xcf[1024], *error = NULL;
  int               vectors = supports_vector_layers ();

  api->image_new (engine, 200, 120, &image, NULL);
  layer = first_layer (image);
  /* A red background, so the vector layer's default white fill shows. */
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &red_bg, NULL);
  CHECK (api->path_set (engine, image, 0, "Shape", square, 1, points, 4, &path, &error) == GLIMS_STATUS_OK &&
         path != 0,
         "the square path is added%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  before = undo_depth (image);
  CHECK (api->path_to_vector_layer (engine, image, 9999, NULL, &v, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->path_to_vector_layer (engine, image, path, "", &v, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         v == 0 && undo_depth (image) == before,
         "an unknown path is NOT_FOUND and an empty name INVALID_ARGUMENT, no undo");

  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK &&
         api->path_to_vector_layer (engine, image, path, NULL, &v, NULL) == GLIMS_STATUS_BUSY &&
         api->stroke_end (engine, stroke) == GLIMS_STATUS_OK,
         "making a vector layer during an open stroke is BUSY");

  before = undo_depth (image);
  status = api->path_to_vector_layer (engine, image, path, "Vector", &vector, &error);
  if (! vectors)
    {
      CHECK (status == GLIMS_STATUS_UNSUPPORTED && error && vector == 0 && undo_depth (image) == before &&
             layer_count (image) == 1,
             "this engine has no vector layers: UNSUPPORTED, no undo, no layer (%s)",
             error ? error : "");
      api->free_string (error);
    }
  else
    {
      api->free_string (error);
      CHECK (status == GLIMS_STATUS_OK && vector > 0 && undo_depth (image) == before + 1,
             "a vector layer is made from the path as one undo step");
      CHECK (api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && count == 2 &&
             rows[0].id == vector && rows[0].kind == GLIMS_LAYER_VECTOR && rows[0].selected &&
             strcmp (rows[0].name, "Vector") == 0,
             "the new layer reports VECTOR, sits on top, is selected and named (kind %u, %s)",
             rows[0].kind, rows[0].name);
      render_pixel (image, 50, 50, px);
      CHECK (px[0] > 200 && px[1] > 200 && px[2] > 200,
             "the layer renders its fill inside the path (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
      render_pixel (image, 10, 10, px);
      CHECK (px[0] > 200 && px[1] < 60,
             "outside the path the red background shows through (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
      CHECK (api->paths (engine, image, prows, 2, &pcount) == GLIMS_STATUS_OK && pcount == 1 &&
             prows[0].id == path,
             "the path stays in the image's path list with the same id");

      before = undo_depth (image);
      CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && layer_count (image) == 1 &&
             api->image_redo (engine, image) == GLIMS_STATUS_OK && layer_count (image) == 2 &&
             api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK &&
             count == 2 && rows[0].kind == GLIMS_LAYER_VECTOR &&
             strcmp (rows[0].name, "Vector") == 0 && undo_depth (image) == before,
             "undo removes the vector layer, redo restores it as VECTOR");

      /* XCF keeps it structured: the layer reports VECTOR after reopen
       * and the path geometry travels with the image. */
      snprintf (xcf, sizeof xcf, "%s/vector.xcf", work);
      CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
             api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
             api->image_layers (engine, reopened, rows, 4, &count) == GLIMS_STATUS_OK && count == 2 &&
             rows[0].kind == GLIMS_LAYER_VECTOR &&
             api->paths (engine, reopened, prows, 2, &pcount) == GLIMS_STATUS_OK && pcount == 1 &&
             api->path_get (engine, reopened, prows[0].id, rsub, 2, &subcount, rpts, 8, &ptcount)
               == GLIMS_STATUS_OK &&
             subcount == 1 && ptcount == 4 && rsub[0].closed && rpts[2].anchor.x == 80 && rpts[2].anchor.y == 80 &&
             (render_pixel (reopened, 50, 50, px), px[0] > 200 && px[1] > 200) &&
             (render_pixel (reopened, 10, 10, px), px[0] > 200 && px[1] < 60),
             "an XCF round trip keeps the vector layer VECTOR with the path's shape and rendered pixels");
      CHECK (strcmp (rows[0].name, "Vector") == 0,
             "XCF reopen preserves the explicit vector layer name (%s)", rows[0].name);
      {
        GlimsImageInfo loaded_info;
        CHECK (api->image_info (engine, reopened, &loaded_info) == GLIMS_STATUS_OK &&
               ! loaded_info.dirty && undo_depth (reopened) == 0,
               "preserving the loaded name adds no dirty state or undo history");
      }
      if (reopened)
        api->image_close (engine, reopened);
      reopened = 0;

      /* As the core behaves while the image is open, the layer and the
       * path share one object: editing the path re-renders the layer. */
      CHECK (api->path_set (engine, image, path, NULL, square, 1, moved, 4, NULL, NULL) == GLIMS_STATUS_OK &&
             (render_pixel (image, 25, 25, px), px[0] > 200 && px[1] < 60) &&
             (render_pixel (image, 50, 50, px), px[0] > 200 && px[1] > 200),
             "editing the path moves the layer's rendered shape (25,25 now red %d,%d; 50,50 still filled %d,%d)",
             px[0], px[1], px[0], px[1]);
      CHECK (api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK &&
             count == 2 && strcmp (rows[0].name, "Vector") == 0,
             "editing the path preserves the explicit vector layer name (%s)", rows[0].name);

      /* Nested containers and Open as Layers use the same native loader,
       * then copy and insert the loaded items into a different image. */
      {
        GlimsImageID destination = 0;
        GlimsItemID group = 0, destination_group = 0, imported[4];
        GlimsLayerInfo imported_rows[8];
        int32_t imported_count = 0, imported_row_count = 0;
        int named_vectors = 0;

        CHECK (api->create_group (engine, image, 0, 0, "Source group", &group, NULL) == GLIMS_STATUS_OK &&
               api->reparent_layer (engine, image, vector, group, 0, NULL) == GLIMS_STATUS_OK &&
               api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
               api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
               api->image_layers (engine, reopened, rows, 4, &count) == GLIMS_STATUS_OK && count == 3 &&
               rows[0].kind == GLIMS_LAYER_GROUP && rows[1].kind == GLIMS_LAYER_VECTOR &&
               strcmp (rows[1].name, "Vector") == 0,
               "XCF reopen preserves a named vector inside a group");
        if (reopened)
          api->image_close (engine, reopened);
        reopened = 0;

        api->image_new (engine, 200, 120, &destination, NULL);
        CHECK (api->create_group (engine, destination, 0, 0, "Destination group", &destination_group, NULL)
                 == GLIMS_STATUS_OK,
               "the import destination has an existing selected group");
        before = undo_depth (destination);
        CHECK (api->image_open_layers (engine, destination, xcf, imported, 4, &imported_count, NULL)
                 == GLIMS_STATUS_OK && imported_count == 2 && undo_depth (destination) == before + 1 &&
               api->image_layers (engine, destination, imported_rows, 8, &imported_row_count) == GLIMS_STATUS_OK,
               "nested vector import is one undo step inside the existing destination group");
        for (int32_t i = 0; i < imported_row_count && i < 8; i++)
          if (imported_rows[i].kind == GLIMS_LAYER_VECTOR &&
              strcmp (imported_rows[i].name, "Vector") == 0 && imported_rows[i].parent != 0)
            named_vectors++;
        CHECK (named_vectors == 1, "Open as Layers preserves the nested vector's explicit name");
        CHECK (api->image_undo (engine, destination) == GLIMS_STATUS_OK && layer_count (destination) == 2 &&
               api->image_redo (engine, destination) == GLIMS_STATUS_OK && layer_count (destination) == 5,
               "undo and redo remove and restore the imported vector group");
        api->image_close (engine, destination);
      }
    }

  api->image_close (engine, image);
}

/* A genuine vector layer's native style (GIMP 3.2+): reading it, changing
 * fill and stroke as exactly one undo step with real pixel changes, getter
 * round trip, undo/redo, no-op and refused or invalid calls leaving no
 * history, the explicit name and the same path association preserved, a
 * live path edit re-rendering, an XCF round trip of style and name inside
 * a group, and on a pre-3.2 engine UNSUPPORTED with nothing mutated. */
static void
test_vector_layer_style (const char *work)
{
  GlimsImageID           image = 0, reopened = 0;
  GlimsItemID            path = 0, vector = 0, layer, group = 0;
  GlimsSubpath           square[1] = { { .count = 4, .closed = true } };
  GlimsPathPoint         points[4] = { corner (20, 20), corner (80, 20), corner (80, 80), corner (20, 80) };
  GlimsPathPoint         moved[4]  = { corner (30, 30), corner (90, 30), corner (90, 90), corner (30, 90) };
  GlimsLayerInfo         rows[4];
  GlimsPathInfo          prows[2];
  GlimsFillSettings      red_bg = { .struct_size = sizeof red_bg, .mode = GLIMS_FILL_SELECTION,
                                    .color = { 1, 0, 0, 1 }, .opacity = 1 };
  GlimsVectorStyle       initial = { .struct_size = sizeof initial };
  GlimsVectorStyle       style   = { .struct_size = sizeof style };
  GlimsVectorStyle       after   = { .struct_size = sizeof after };
  GlimsVectorStyleChange change  = { .struct_size = sizeof change };
  GlimsVectorStyleChange noop    = { .struct_size = sizeof noop };
  GlimsVectorStyleChange bad     = { .struct_size = sizeof bad };
  GlimsStrokeID          stroke = 0;
  GlimsFilterID          filter = 0;
  GlimsBrushSettings     brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  GlimsStrokePoint       point = { 5, 5, 1.0, 0.0, 0.0, 0 };
  int32_t                count = 0, pcount = 0, before;
  uint8_t                px[4];
  GlimsStatus            status;
  char                   xcf[1024], *error = NULL;
  int                    vectors = supports_vector_layers ();

  api->image_new (engine, 200, 120, &image, NULL);
  layer = first_layer (image);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &red_bg, NULL);
  CHECK (api->path_set (engine, image, 0, "Shape", square, 1, points, 4, &path, &error) == GLIMS_STATUS_OK &&
         path != 0,
         "the square path is added%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  /* Guards that hold on every engine. */
  before = undo_depth (image);
  CHECK (api->vector_layer_style_get (engine, 9999, layer, &style, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->vector_layer_style_set (engine, 9999, layer, &change, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->vector_layer_style_set (engine, image, layer, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == before,
         "an unknown image is NOT_FOUND and a NULL change INVALID_ARGUMENT, no undo");

  status = api->path_to_vector_layer (engine, image, path, "Vector", &vector, &error);
  if (! vectors)
    {
      api->free_string (error);
      error = NULL;
      before = undo_depth (image);
      render_pixel (image, 50, 50, px);
      CHECK (status == GLIMS_STATUS_UNSUPPORTED &&
             api->vector_layer_style_get (engine, image, layer, &style, &error) == GLIMS_STATUS_UNSUPPORTED &&
             error != NULL &&
             api->vector_layer_style_set (engine, image, layer, &change, &error) == GLIMS_STATUS_UNSUPPORTED &&
             undo_depth (image) == before && layer_count (image) == 1 &&
             (render_pixel (image, 50, 50, px), px[0] > 200 && px[1] < 60),
             "a pre-3.2 engine reports UNSUPPORTED and mutates nothing (%s)",
             error ? error : "");
      api->free_string (error);
      api->image_close (engine, image);
      return;
    }
  api->free_string (error);
  error = NULL;
  CHECK (status == GLIMS_STATUS_OK && vector > 0, "the vector layer exists");

  CHECK (api->vector_layer_style_get (engine, image, 9999, &style, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->vector_layer_style_get (engine, image, layer, &style, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->vector_layer_style_set (engine, image, 9999, &change, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->vector_layer_style_set (engine, image, layer, &change, NULL) == GLIMS_STATUS_NOT_FOUND,
         "an id that is not a genuine vector layer is NOT_FOUND for get and set");

  /* Busy is checked first: an open stroke or filter preview refuses. */
  before = undo_depth (image);
  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK &&
         api->vector_layer_style_set (engine, image, vector, &change, NULL) == GLIMS_STATUS_BUSY &&
         undo_depth (image) == before,
         "a style change during an open stroke is BUSY, no undo");
  if (stroke) api->stroke_end (engine, stroke);
  before = undo_depth (image);
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK &&
         api->vector_layer_style_set (engine, image, vector, &change, NULL) == GLIMS_STATUS_BUSY &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK &&
         undo_depth (image) == before,
         "a style change during a filter preview is BUSY, no undo");

  CHECK (api->vector_layer_style_get (engine, image, vector, &initial, &error) == GLIMS_STATUS_OK &&
         initial.enable_fill && initial.enable_stroke && initial.stroke_width > 0,
         "the default style reads back (fill %d, stroke %d, width %.1f)%s%s",
         initial.enable_fill, initial.enable_stroke, initial.stroke_width,
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  render_pixel (image, 50, 50, px);
  CHECK (px[0] > 200 && px[1] > 200 && px[2] > 200,
         "the default fill shows inside the path (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
  render_pixel (image, 20, 50, px);
  CHECK (px[0] < 60 && px[1] < 60 && px[2] < 60,
         "the default stroke shows on the path edge (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);

  /* One style change: green fill, red 12 px stroke, round cap, bevel join,
   * miter 5, no antialias — exactly one undo step, with real pixels. */
  before = undo_depth (image);
  change.properties = GLIMS_VECTOR_STYLE_FILL_COLOR | GLIMS_VECTOR_STYLE_STROKE_COLOR |
                      GLIMS_VECTOR_STYLE_STROKE_WIDTH | GLIMS_VECTOR_STYLE_STROKE_CAP |
                      GLIMS_VECTOR_STYLE_STROKE_JOIN | GLIMS_VECTOR_STYLE_STROKE_MITER |
                      GLIMS_VECTOR_STYLE_FILL_ANTIALIAS | GLIMS_VECTOR_STYLE_STROKE_ANTIALIAS;
  change.fill_color         = (GlimsColor) { 0, 1, 0, 1 };
  change.stroke_color       = (GlimsColor) { 1, 0, 0, 1 };
  change.stroke_width       = 12;
  change.stroke_cap         = GLIMS_VECTOR_CAP_ROUND;
  change.stroke_join        = GLIMS_VECTOR_JOIN_BEVEL;
  change.stroke_miter_limit = 5;
  change.fill_antialias     = false;
  change.stroke_antialias   = false;
  status = api->vector_layer_style_set (engine, image, vector, &change, &error);
  CHECK (status == GLIMS_STATUS_OK && undo_depth (image) == before + 1,
         "one style change is one undo step%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  render_pixel (image, 50, 50, px);
  CHECK (px[1] > 200 && px[0] < 60 && px[2] < 60,
         "the fill pixels changed to green (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
  render_pixel (image, 20, 50, px);
  CHECK (px[0] > 200 && px[1] < 60 && px[2] < 60,
         "the stroke pixels changed to red on the edge (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);

  CHECK (api->vector_layer_style_get (engine, image, vector, &after, NULL) == GLIMS_STATUS_OK &&
         after.enable_fill && after.enable_stroke &&
         after.fill_color.green > 0.99 && after.fill_color.red < 0.01 &&
         after.stroke_color.red > 0.99 && after.stroke_color.green < 0.01 &&
         after.stroke_width == 12 && after.stroke_cap == GLIMS_VECTOR_CAP_ROUND &&
         after.stroke_join == GLIMS_VECTOR_JOIN_BEVEL && after.stroke_miter_limit == 5 &&
         ! after.fill_antialias && ! after.stroke_antialias,
         "the getter round-trips the set style (w %.1f, cap %u, join %u, miter %.1f)",
         after.stroke_width, after.stroke_cap, after.stroke_join, after.stroke_miter_limit);

  CHECK (api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && count == 2 &&
         rows[0].id == vector && strcmp (rows[0].name, "Vector") == 0 &&
         api->paths (engine, image, prows, 2, &pcount) == GLIMS_STATUS_OK && pcount == 1 &&
         prows[0].id == path,
         "the style change keeps the explicit name and the same path association");

  /* One undo/redo: the single step restores and reapplies the style. */
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == before &&
         api->vector_layer_style_get (engine, image, vector, &style, NULL) == GLIMS_STATUS_OK &&
         style.stroke_width == initial.stroke_width && style.stroke_cap == initial.stroke_cap &&
         style.fill_color.red == initial.fill_color.red && style.fill_color.green == initial.fill_color.green,
         "undo restores the previous style as the single step (w %.1f -> %.1f)",
         initial.stroke_width, style.stroke_width);
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == before + 1 &&
         api->vector_layer_style_get (engine, image, vector, &after, NULL) == GLIMS_STATUS_OK &&
         after.stroke_width == 12 && after.stroke_cap == GLIMS_VECTOR_CAP_ROUND,
         "redo reapplies the style (w %.1f)", after.stroke_width);

  /* A no-op change succeeds without an undo step. */
  noop.properties = GLIMS_VECTOR_STYLE_ENABLE_FILL | GLIMS_VECTOR_STYLE_FILL_COLOR |
                    GLIMS_VECTOR_STYLE_FILL_ANTIALIAS | GLIMS_VECTOR_STYLE_ENABLE_STROKE |
                    GLIMS_VECTOR_STYLE_STROKE_COLOR | GLIMS_VECTOR_STYLE_STROKE_ANTIALIAS |
                    GLIMS_VECTOR_STYLE_STROKE_WIDTH | GLIMS_VECTOR_STYLE_STROKE_CAP |
                    GLIMS_VECTOR_STYLE_STROKE_JOIN | GLIMS_VECTOR_STYLE_STROKE_MITER;
  noop.enable_fill          = after.enable_fill;
  noop.fill_color           = after.fill_color;
  noop.fill_antialias       = after.fill_antialias;
  noop.enable_stroke        = after.enable_stroke;
  noop.stroke_color         = after.stroke_color;
  noop.stroke_antialias     = after.stroke_antialias;
  noop.stroke_width         = after.stroke_width;
  noop.stroke_cap           = after.stroke_cap;
  noop.stroke_join          = after.stroke_join;
  noop.stroke_miter_limit   = after.stroke_miter_limit;
  before = undo_depth (image);
  CHECK (api->vector_layer_style_set (engine, image, vector, &noop, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before,
         "a change that alters nothing is a no-op with no undo step (%d -> %d; fill %.17g %.17g %.17g %.17g; stroke %.17g %.17g %.17g %.17g)",
         before, undo_depth (image), after.fill_color.red, after.fill_color.green,
         after.fill_color.blue, after.fill_color.alpha, after.stroke_color.red,
         after.stroke_color.green, after.stroke_color.blue, after.stroke_color.alpha);

  /* Native context colors are opaque. An ignored alpha component must
   * not manufacture an undo step when both effective colors are equal. */
  noop.properties = GLIMS_VECTOR_STYLE_FILL_COLOR | GLIMS_VECTOR_STYLE_STROKE_COLOR;
  noop.fill_color.alpha = 0.5;
  noop.stroke_color.alpha = 0.5;
  before = undo_depth (image);
  CHECK (api->vector_layer_style_set (engine, image, vector, &noop, NULL) == GLIMS_STATUS_OK &&
         api->vector_layer_style_get (engine, image, vector, &style, NULL) == GLIMS_STATUS_OK &&
         style.fill_color.alpha == 1 && style.stroke_color.alpha == 1 && undo_depth (image) == before,
         "opaque native colors normalize ignored alpha before no-op detection");

  /* Repeating a UI color with non-binary components is also a no-op
   * after the native context's float color-space round trip. */
  before = undo_depth (image);
  bad.properties = GLIMS_VECTOR_STYLE_FILL_COLOR;
  bad.fill_color = (GlimsColor) { 0.31, 0.47, 0.71, 1 };
  status = api->vector_layer_style_set (engine, image, vector, &bad, NULL);
  api->vector_layer_style_get (engine, image, vector, &style, NULL);
  render_pixel (image, 50, 50, px);
  CHECK (fabs (style.fill_color.red - 0.31) <= 1e-6 &&
         fabs (style.fill_color.green - 0.47) <= 1e-6 && fabs (style.fill_color.blue - 0.71) <= 1e-6 &&
         abs ((int) px[0] - 79) <= 1 && abs ((int) px[1] - 120) <= 1 && abs ((int) px[2] - 181) <= 1,
         "vector style colors read back as sRGB and match rendered midtones (%.6f %.6f %.6f; %u,%u,%u)",
         style.fill_color.red, style.fill_color.green, style.fill_color.blue, px[0], px[1], px[2]);
  CHECK (status == GLIMS_STATUS_OK &&
         api->vector_layer_style_set (engine, image, vector, &bad, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "repeating the same non-binary color adds only the first style undo");
  while (undo_depth (image) > before)
    if (api->image_undo (engine, image) != GLIMS_STATUS_OK) break;

  /* Invalid changes are refused before any mutation. */
  before = undo_depth (image);
  bad.properties = GLIMS_VECTOR_STYLE_FILL_COLOR;
  bad.fill_color = (GlimsColor) { NAN, 0, 0, 1 };
  CHECK (api->vector_layer_style_set (engine, image, vector, &bad, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a non-finite fill color is refused");
  bad.properties = GLIMS_VECTOR_STYLE_STROKE_COLOR;
  bad.stroke_color = (GlimsColor) { 0, 0, 0, INFINITY };
  CHECK (api->vector_layer_style_set (engine, image, vector, &bad, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a non-finite stroke alpha is refused");
  bad.properties = GLIMS_VECTOR_STYLE_STROKE_WIDTH;
  bad.stroke_width = 0;
  CHECK (api->vector_layer_style_set (engine, image, vector, &bad, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a zero width is refused");
  bad.stroke_width = 2001;
  CHECK (api->vector_layer_style_set (engine, image, vector, &bad, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a width over 2000 is refused");
  bad.stroke_width = NAN;
  CHECK (api->vector_layer_style_set (engine, image, vector, &bad, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a non-finite width is refused");
  bad.properties = GLIMS_VECTOR_STYLE_STROKE_CAP;
  bad.stroke_cap = 99;
  CHECK (api->vector_layer_style_set (engine, image, vector, &bad, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown cap style is refused");
  bad.properties = (uint32_t) 1 << 30;
  CHECK (api->vector_layer_style_set (engine, image, vector, &bad, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown property bit is refused");
  CHECK (undo_depth (image) == before,
         "refused invalid changes add no undo history");

  /* Pixel locks refuse: the layer's own and one inherited from a group. */
  api->set_layer_locks (engine, image, vector, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL);
  before = undo_depth (image);
  CHECK (api->vector_layer_style_set (engine, image, vector, &change, NULL) == GLIMS_STATUS_LOCKED &&
         undo_depth (image) == before,
         "the layer's own pixel lock refuses the style change, no undo");
  api->set_layer_locks (engine, image, vector, GLIMS_LOCK_PIXELS, 0, NULL);
  CHECK (api->create_group (engine, image, 0, 0, "Style group", &group, NULL) == GLIMS_STATUS_OK &&
         api->reparent_layer (engine, image, vector, group, 0, NULL) == GLIMS_STATUS_OK,
         "the vector layer moves into a group");
  api->set_layer_locks (engine, image, group, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL);
  before = undo_depth (image);
  CHECK (api->vector_layer_style_set (engine, image, vector, &change, NULL) == GLIMS_STATUS_LOCKED &&
         undo_depth (image) == before,
         "an inherited group pixel lock refuses the style change, no undo");
  api->set_layer_locks (engine, image, group, GLIMS_LOCK_PIXELS, 0, NULL);

  /* A live path edit still re-renders the styled layer, name preserved. */
  CHECK (api->path_set (engine, image, path, NULL, square, 1, moved, 4, NULL, NULL) == GLIMS_STATUS_OK &&
         (render_pixel (image, 22, 22, px), px[0] > 200 && px[1] < 60) &&
         (render_pixel (image, 50, 50, px), px[1] > 200 && px[0] < 60) &&
         api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && count == 3 &&
         rows[1].id == vector && strcmp (rows[1].name, "Vector") == 0,
         "a live path edit re-renders the styled layer and keeps the name (22,22 bg %d,%d; 50,50 fill %d,%d; %s)",
         px[0], px[1], px[0], px[1], rows[1].name);

  bad = (GlimsVectorStyleChange) { .struct_size = sizeof bad,
          .properties = GLIMS_VECTOR_STYLE_STROKE_WIDTH | GLIMS_VECTOR_STYLE_STROKE_MITER,
          .stroke_width = 12.3, .stroke_miter_limit = 5.2 };
  CHECK (api->vector_layer_style_set (engine, image, vector, &bad, NULL) == GLIMS_STATUS_OK,
         "fractional width and miter are set before the XCF round trip");

  /* An XCF round trip keeps the style, the name and the group. */
  snprintf (xcf, sizeof xcf, "%s/vector-style.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, reopened, rows, 4, &count) == GLIMS_STATUS_OK && count == 3 &&
         rows[0].kind == GLIMS_LAYER_GROUP && rows[1].kind == GLIMS_LAYER_VECTOR &&
         rows[1].parent == rows[0].id && strcmp (rows[1].name, "Vector") == 0,
         "XCF reopen keeps the vector layer VECTOR, named, inside the group (%s)", rows[1].name);
  CHECK (api->vector_layer_style_get (engine, reopened, rows[1].id, &style, &error) == GLIMS_STATUS_OK &&
         style.enable_fill && style.enable_stroke &&
         style.fill_color.green > 0.99 && style.fill_color.red < 0.01 &&
         style.stroke_color.red > 0.99 && style.stroke_color.green < 0.01 &&
         fabs (style.stroke_width - 12.3) < 1e-5 && style.stroke_cap == GLIMS_VECTOR_CAP_ROUND &&
         style.stroke_join == GLIMS_VECTOR_JOIN_BEVEL && fabs (style.stroke_miter_limit - 5.2) < 1e-5 &&
         ! style.fill_antialias && ! style.stroke_antialias,
         "XCF reopen preserves the style (w %.1f, cap %u, join %u, miter %.1f)%s%s",
         style.stroke_width, style.stroke_cap, style.stroke_join, style.stroke_miter_limit,
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  render_pixel (reopened, 50, 50, px);
  CHECK (px[1] > 200 && px[0] < 60,
         "the reopened vector layer renders the saved style (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
  before = undo_depth (reopened);
  CHECK (api->vector_layer_style_set (engine, reopened, rows[1].id, &bad, NULL) == GLIMS_STATUS_OK &&
         undo_depth (reopened) == before,
         "reapplying displayed fractional width and miter after XCF is a no-op");
  bad.stroke_width = 14.3;
  before = undo_depth (reopened);
  CHECK (api->vector_layer_style_set (engine, reopened, rows[1].id, &bad, NULL) == GLIMS_STATUS_OK &&
         undo_depth (reopened) == before + 1 &&
         api->image_layers (engine, reopened, rows, 4, &count) == GLIMS_STATUS_OK &&
         !strcmp (rows[1].name, "Vector") && rows[1].kind == GLIMS_LAYER_VECTOR &&
         api->paths (engine, reopened, prows, 2, &pcount) == GLIMS_STATUS_OK && pcount == 1,
         "style editing after XCF is one undo and preserves the named vector and path");
  if (reopened)
    api->image_close (engine, reopened);

  api->image_close (engine, image);
}


/* An intentionally rasterized vector layer (its pixels were edited, so the
 * XCF stores the rasterization flag together with the edited buffer) must
 * reopen as PIXEL with those edited pixels, while a genuine vector layer in
 * the same file stays VECTOR with its path, fill color and explicit name.
 * GIMP 3.2.0 re-renders the converted layer when adding it, which overwrites
 * the saved modified pixels; later engines duplicate and restore the saved
 * buffer (xcf-load.c). */
static void
test_vector_rasterized_roundtrip (const char *work)
{
  GlimsImageID      image = 0, reopened = 0;
  GlimsItemID       rpath = 0, gpath = 0, rasterized = 0, genuine = 0, genuine_path = 0;
  GlimsSubpath      rsquare[1] = { { .count = 4, .closed = true } };
  GlimsSubpath      gsquare[1] = { { .count = 4, .closed = true } };
  GlimsPathPoint    rpoints[4] = { corner (20, 20), corner (80, 20), corner (80, 80), corner (20, 80) };
  GlimsPathPoint    gpoints[4] = { corner (100, 20), corner (160, 20), corner (160, 80), corner (100, 80) };
  GlimsLayerInfo    rows[4];
  GlimsPathInfo     prows[2];
  GlimsSubpath      rsub[2];
  GlimsPathPoint    rpts[8];
  GlimsFillSettings red_bg = { .struct_size = sizeof red_bg, .mode = GLIMS_FILL_SELECTION,
                               .color = { 1, 0, 0, 1 }, .opacity = 1 };
  GlimsFillSettings green  = { .struct_size = sizeof green,  .mode = GLIMS_FILL_SELECTION,
                               .color = { 0, 0.8, 0, 1 }, .opacity = 1 };
  GlimsImageInfo    loaded_info;
  int32_t           count = 0, pcount = 0, subcount = 0, ptcount = 0;
  uint8_t           px[4];
  char              xcf[1024];
  int               vectors = supports_vector_layers ();

  if (! vectors)
    {
      CHECK (api->image_new (engine, 40, 30, &image, NULL) == GLIMS_STATUS_OK &&
             api->path_set (engine, image, 0, "Raster shape", rsquare, 1, rpoints, 4, &rpath, NULL) == GLIMS_STATUS_OK &&
             api->path_to_vector_layer (engine, image, rpath, "x", NULL, NULL) == GLIMS_STATUS_UNSUPPORTED,
             "engines without vector layers report UNSUPPORTED");
      if (image)
        api->image_close (engine, image);
      return;
    }

  api->image_new (engine, 200, 120, &image, NULL);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &red_bg, NULL);
  CHECK (api->path_set (engine, image, 0, "Raster shape", rsquare, 1, rpoints, 4, &rpath, NULL) == GLIMS_STATUS_OK &&
         api->path_to_vector_layer (engine, image, rpath, "Rasterized", &rasterized, NULL) == GLIMS_STATUS_OK,
         "the rasterized candidate is made as a vector layer named Rasterized");
  /* Editing the vector's pixels rasterizes it: the layer turns PIXEL and
   * the whole buffer takes the edited fill color. */
  CHECK (api->fill (engine, image, (GlimsPoint) { 0, 0 }, &green, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && count == 2 &&
         rows[0].id == rasterized && rows[0].kind == GLIMS_LAYER_PIXEL &&
         (render_pixel (image, 50, 50, px), px[1] > 150 && px[0] < 60),
         "editing the vector layer rasterizes it to PIXEL with the edited green pixels (kind %u, %d,%d,%d)",
         rows[0].kind, px[0], px[1], px[2]);

  CHECK (api->path_set (engine, image, 0, "Genuine shape", gsquare, 1, gpoints, 4, &gpath, NULL) == GLIMS_STATUS_OK &&
         api->path_to_vector_layer (engine, image, gpath, "Genuine", &genuine, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && count == 3 &&
         rows[0].id == genuine && rows[0].kind == GLIMS_LAYER_VECTOR && strcmp (rows[0].name, "Genuine") == 0,
         "the genuine vector layer sits on top as VECTOR, named Genuine");

  snprintf (xcf, sizeof xcf, "%s/vector-rasterized.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, reopened, rows, 4, &count) == GLIMS_STATUS_OK && count == 3 &&
         rows[0].kind == GLIMS_LAYER_VECTOR && strcmp (rows[0].name, "Genuine") == 0 &&
         rows[1].kind == GLIMS_LAYER_PIXEL && strcmp (rows[1].name, "Rasterized") == 0,
         "XCF reopen keeps the genuine layer VECTOR and the edited one PIXEL, both explicitly named (kinds %u/%u, %s/%s)",
         rows[0].kind, rows[1].kind, rows[0].name, rows[1].name);
  CHECK (api->paths (engine, reopened, prows, 2, &pcount) == GLIMS_STATUS_OK && pcount == 2,
         "both paths travel with the reopened image (%d)", pcount);
  for (int32_t i = 0; i < pcount; i++)
    if (strcmp (prows[i].name, "Genuine shape") == 0)
      genuine_path = prows[i].id;
  CHECK (genuine_path != 0 &&
         api->path_get (engine, reopened, genuine_path, rsub, 2, &subcount, rpts, 8, &ptcount) == GLIMS_STATUS_OK &&
         subcount == 1 && ptcount == 4 && rsub[0].closed &&
         rpts[2].anchor.x == 160 && rpts[2].anchor.y == 80,
         "the genuine vector's path shape survives the round trip (%d points)", ptcount);
  render_pixel (reopened, 120, 50, px);
  CHECK (px[0] > 200 && px[1] > 200,
         "the genuine vector's fill color still renders inside its path (%d,%d,%d,%d)",
         px[0], px[1], px[2], px[3]);
  render_pixel (reopened, 50, 50, px);
  CHECK (px[1] > 150 && px[0] < 60,
         "the rasterized layer reopens with its edited green pixels, not a fresh render (%d,%d,%d,%d)",
         px[0], px[1], px[2], px[3]);
  render_pixel (reopened, 10, 10, px);
  CHECK (px[0] > 200 && px[1] < 60,
         "outside both paths the red background shows through (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
  CHECK (api->image_info (engine, reopened, &loaded_info) == GLIMS_STATUS_OK &&
         ! loaded_info.dirty && undo_depth (reopened) == 0,
         "the rasterized round trip adds no dirty state or undo history");
  if (reopened)
    api->image_close (engine, reopened);
  api->image_close (engine, image);
}

/* Open as Layers of the rasterized-vector XCF saved above. The native load
 * must finish restoring the saved buffer of the rasterized layer (the
 * image's "clean" signal from file_open_sanitize_image) BEFORE
 * file_open_layers() duplicates the loaded layers into the destination
 * with file_open_convert_items(); restoring only after gimp_image_add_layers
 * is too late, the duplicate already carries the fresh render. The imported
 * genuine vector keeps its path, fill and explicit name, the imported
 * rasterized layer arrives as PIXEL with its edited green pixels, the
 * destination's own layer and name are untouched, and the whole import is
 * exactly one undo step with working undo/redo. */
static void
test_vector_rasterized_open_layers (const char *work)
{
  GlimsImageID      dest = 0, src = 0;
  GlimsItemID       added[8] = { 0 }, base = 0, genuine_path = 0;
  GlimsLayerInfo    rows[8];
  GlimsPathInfo     prows[4];
  GlimsSubpath      sub[2];
  GlimsPathPoint    pts[8];
  GlimsFillSettings blue = { .struct_size = sizeof blue, .mode = GLIMS_FILL_SELECTION,
                             .color = { 0, 0, 1, 1 }, .opacity = 1 };
  GlimsLayerChange  rename = { .struct_size = sizeof rename, .properties = GLIMS_LAYER_NAME,
                               .name = "Base" };
  int32_t           count = 0, n = 0, pcount = 0, subcount = 0, ptcount = 0, before;
  uint8_t           px[4];
  char              xcf[1024];
  int               vectors = supports_vector_layers ();

  snprintf (xcf, sizeof xcf, "%s/vector-rasterized.xcf", work);

  if (! vectors)
    {
      /* No vector layers on this engine: the same import contract with a
       * plain one-layer XCF. */
      CHECK (api->image_new (engine, 60, 40, &src, NULL) == GLIMS_STATUS_OK &&
             api->image_save (engine, src, xcf, NULL) == GLIMS_STATUS_OK,
             "a plain XCF is saved for the import");
      api->image_close (engine, src);
      src = 0;
      CHECK (api->image_new (engine, 60, 40, &dest, NULL) == GLIMS_STATUS_OK &&
             (base = first_layer (dest)) != 0,
             "a destination image exists");
      before = undo_depth (dest);
      CHECK (api->image_open_layers (engine, dest, xcf, added, 8, &n, NULL) == GLIMS_STATUS_OK && n == 1 &&
             undo_depth (dest) == before + 1 && layer_count (dest) == 2,
             "engines without vector layers: the plain import is one undo step (n=%d)", n);
      CHECK (api->image_undo (engine, dest) == GLIMS_STATUS_OK && layer_count (dest) == 1 &&
             api->image_redo (engine, dest) == GLIMS_STATUS_OK && layer_count (dest) == 2,
             "undo and redo remove and restore the imported layer");
      api->image_close (engine, dest);
      return;
    }

  CHECK (api->image_new (engine, 200, 120, &dest, NULL) == GLIMS_STATUS_OK,
         "a destination image of the file's size");
  base = first_layer (dest);
  CHECK (base != 0 && api->layer_change (engine, dest, base, &rename, NULL) == GLIMS_STATUS_OK &&
         api->fill (engine, dest, (GlimsPoint) { 0, 0 }, &blue, NULL) == GLIMS_STATUS_OK &&
         (render_pixel (dest, 10, 10, px), px[2] > 150 && px[0] < 60),
         "the destination's own layer is renamed Base and filled blue (%d,%d,%d)",
         px[0], px[1], px[2]);

  before = undo_depth (dest);
  CHECK (api->image_open_layers (engine, dest, xcf, added, 8, &n, NULL) == GLIMS_STATUS_OK && n == 3,
         "Open as Layers imports the file's three layers (n=%d)", n);
  CHECK (undo_depth (dest) == before + 1,
         "the whole import is exactly one undo step (%d -> %d)", before, undo_depth (dest));
  CHECK (api->image_layers (engine, dest, rows, 8, &count) == GLIMS_STATUS_OK && count == 4,
         "the destination now has 4 layers (%d)", count);
  if (count == 4)
    {
      CHECK (rows[0].kind == GLIMS_LAYER_VECTOR && strcmp (rows[0].name, "Genuine") == 0 &&
             rows[1].kind == GLIMS_LAYER_PIXEL && strcmp (rows[1].name, "Rasterized") == 0 &&
             rows[2].kind == GLIMS_LAYER_PIXEL && strcmp (rows[2].name, "vector-rasterized.xcf") != 0 &&
             rows[3].id == base && strcmp (rows[3].name, "Base") == 0 &&
             rows[0].id == added[0] && rows[1].id == added[1] && rows[2].id == added[2],
             "imported genuine is VECTOR named Genuine, rasterized is PIXEL named Rasterized, "
             "a multi-item import keeps the file names (not the basename) and the destination "
             "keeps Base (kinds %u/%u/%u, names %s/%s/%s/%s)",
             rows[0].kind, rows[1].kind, rows[2].kind,
             rows[0].name, rows[1].name, rows[2].name, rows[3].name);
    }

  CHECK (api->paths (engine, dest, prows, 4, &pcount) == GLIMS_STATUS_OK && pcount == 2,
         "the destination's paths are listed (%d)", pcount);
  if (pcount == 2)
    {
      /* Native duplicates carry "… copy" names. Both paths must belong
       * to the destination rather than the destroyed loading image. */
      for (int32_t i = 0; i < pcount; i++)
        if (strncmp (prows[i].name, "Genuine shape", 13) == 0)
          genuine_path = prows[i].id;
      CHECK (genuine_path != 0 &&
             api->path_get (engine, dest, genuine_path, sub, 2, &subcount, pts, 8, &ptcount) == GLIMS_STATUS_OK &&
             subcount == 1 && ptcount == 4 && sub[0].closed &&
             pts[2].anchor.x == 160 && pts[2].anchor.y == 80,
             "the imported genuine vector keeps its path geometry (%d points)", ptcount);
    }

  render_pixel (dest, 120, 50, px);
  CHECK (px[0] > 200 && px[1] > 200,
         "the imported genuine vector renders its fill inside the path (%d,%d,%d,%d)",
         px[0], px[1], px[2], px[3]);
  render_pixel (dest, 95, 50, px);
  CHECK (px[0] > 200 && px[1] < 60,
         "just left of the genuine path (x=100) the red background shows, pinning the geometry (%d,%d,%d,%d)",
         px[0], px[1], px[2], px[3]);
  render_pixel (dest, 170, 50, px);
  CHECK (px[0] > 200 && px[1] < 60,
         "just right of the genuine path (x=160) the red background shows (%d,%d,%d,%d)",
         px[0], px[1], px[2], px[3]);
  render_pixel (dest, 50, 50, px);
  CHECK (px[1] > 150 && px[0] < 60,
         "the imported rasterized layer keeps its edited green pixels, not a fresh render (%d,%d,%d,%d)",
         px[0], px[1], px[2], px[3]);
  render_pixel (dest, 10, 10, px);
  CHECK (px[0] > 200 && px[1] < 60,
         "outside both paths the imported red background shows (%d,%d,%d,%d)",
         px[0], px[1], px[2], px[3]);

  CHECK (api->image_undo (engine, dest) == GLIMS_STATUS_OK && layer_count (dest) == 1 &&
         undo_depth (dest) == before,
         "one undo removes the whole import (%d layers left)", layer_count (dest));
  CHECK (api->image_layers (engine, dest, rows, 8, &count) == GLIMS_STATUS_OK && count == 1 &&
         rows[0].id == base && strcmp (rows[0].name, "Base") == 0 &&
         (render_pixel (dest, 10, 10, px), px[2] > 150 && px[0] < 60),
         "after undo the destination's own blue Base layer is unchanged (%s, %d,%d,%d)",
         rows[0].name, px[0], px[1], px[2]);
  CHECK (api->image_redo (engine, dest) == GLIMS_STATUS_OK && layer_count (dest) == 4 &&
         (render_pixel (dest, 50, 50, px), px[1] > 150 && px[0] < 60),
         "redo restores the import with the edited green pixels again (%d,%d,%d)",
         px[0], px[1], px[2]);

  snprintf (xcf, sizeof xcf, "%s/imported-vectors-resaved.xcf", work);
  CHECK (api->image_save (engine, dest, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &src, NULL) == GLIMS_STATUS_OK,
         "the imported vector layers can be saved and reopened after their loading image is gone");
  if (src)
    {
      CHECK (api->image_layers (engine, src, rows, 8, &count) == GLIMS_STATUS_OK && count == 4 &&
             rows[0].kind == GLIMS_LAYER_VECTOR && rows[1].kind == GLIMS_LAYER_PIXEL &&
             (render_pixel (src, 120, 50, px), px[0] > 200 && px[1] > 200) &&
             (render_pixel (src, 50, 50, px), px[1] > 150 && px[0] < 60),
             "resaving imported vectors preserves both editable geometry and raster edits");
      api->image_close (engine, src);
    }

  api->image_close (engine, dest);
}

/* GIMP-made files the app must read and change as GIMP does: a layer
 * group's own blend mode, pass-through, and a text layer sized in points. */
static void
test_groups_and_text_units (const char *fixtures)
{
  char              path[1024];
  GlimsImageID      image = 0;
  GlimsLayerInfo    rows[8];
  GlimsLayerChange  change = { .struct_size = sizeof change, .properties = GLIMS_LAYER_MODE };
  GlimsTextSettings read = { .struct_size = sizeof read };
  int32_t           count = 0;
  char             *error = NULL;

  snprintf (path, sizeof path, "%s/composite.xcf", fixtures);
  if (api->image_open (engine, path, &image, NULL) == GLIMS_STATUS_OK &&
      api->image_layers (engine, image, rows, 8, &count) == GLIMS_STATUS_OK && count > 1 &&
      rows[1].kind == GLIMS_LAYER_GROUP)
    {
      GlimsItemID group = rows[1].id;

      strcpy (change.mode, "normal");
      api->layer_change (engine, image, group, &change, NULL);
      strcpy (change.mode, "pass-through");
      CHECK (api->layer_change (engine, image, group, &change, &error) == GLIMS_STATUS_OK &&
             api->image_layers (engine, image, rows, 8, &count) == GLIMS_STATUS_OK &&
             strcmp (rows[1].mode, "pass-through") == 0,
             "a layer group takes pass-through back%s%s", error ? ": " : "", error ? error : "");
      api->free_string (error);
      error = NULL;
      strcpy (change.mode, "pass-through");
      CHECK (api->layer_change (engine, image, rows[2].id, &change, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
             "pass-through is refused for a layer that is not a group");
    }
  else
    CHECK (false, "the fixture's layer group is found");
  if (image)
    api->image_close (engine, image);

  image = 0;
  snprintf (path, sizeof path, "%s/text-units.xcf", fixtures);
  CHECK (api->image_open (engine, path, &image, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 8, &count) == GLIMS_STATUS_OK && count == 2 &&
         rows[0].kind == GLIMS_LAYER_TEXT &&
         api->text_layer_get (engine, image, rows[0].id, NULL, &read) == GLIMS_STATUS_OK &&
         fabs (read.size - 48) < 0.5 && fabs (read.line_spacing - 24) < 0.5,
         "a text layer sized in points reads back in pixels: 24 pt is %.1f px, 12 pt spacing is %.1f px",
         read.size, read.line_spacing);
  /* Writing its own look back turns the layer to pixels; the indent it
   * keeps (36 pt, 72 px) must not shrink to 36 px with it. */
  if (count == 2 && rows[0].kind == GLIMS_LAYER_TEXT)
    {
      GlimsRect before = rows[0].bounds;

      CHECK (api->text_layer_set (engine, image, rows[0].id, NULL, &read, &error) == GLIMS_STATUS_OK &&
             api->image_layers (engine, image, rows, 8, &count) == GLIMS_STATUS_OK &&
             abs (rows[0].bounds.width - before.width) <= 1 && abs (rows[0].bounds.height - before.height) <= 1,
             "writing a points layer's own look back keeps its size (%dx%d, was %dx%d)%s%s",
             rows[0].bounds.width, rows[0].bounds.height, before.width, before.height,
             error ? ": " : "", error ? error : "");
      api->free_string (error);
      error = NULL;
    }
  if (image)
    api->image_close (engine, image);
}

/* The layer tree's rows in depth-first order match `ids` (with `parents`
 * and `depths`) exactly: the position check the reparent and reorder
 * tests need. */
static int
tree_is (GlimsImageID        image,
         const GlimsItemID  *ids,
         const GlimsItemID  *parents,
         const int32_t      *depths,
         int32_t             n)
{
  GlimsLayerInfo rows[16];
  int32_t        count = 0, i;

  if (api->image_layers (engine, image, rows, 16, &count) != GLIMS_STATUS_OK || count != n)
    return 0;
  for (i = 0; i < n; i++)
    if (rows[i].id != ids[i] || rows[i].parent != parents[i] || rows[i].depth != depths[i])
      return 0;
  return 1;
}

static void
test_layer_structure (void)
{
  GlimsImageID    image = 0, other = 0;
  GlimsItemID     background, a = 0, b = 0, group = 0, nested = 0, gone = 0, foreign = 0;
  GlimsLayerInfo  rows[8];
  GlimsLayerState state;
  int32_t         count = 0, before;
  char           *error = NULL;

  api->image_new (engine, 64, 48, &image, NULL);
  background = first_layer (image);

  before = undo_depth (image);
  CHECK (api->create_group (engine, image, 0, 0, "Group", &group, &error) == GLIMS_STATUS_OK &&
         group > 0 && undo_depth (image) == before + 1,
         "a group is added on top as one undo step%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_layers (engine, image, rows, 8, &count) == GLIMS_STATUS_OK && count == 2 &&
         rows[0].id == group && rows[0].kind == GLIMS_LAYER_GROUP && rows[0].depth == 0 &&
         rows[0].parent == 0 && strcmp (rows[0].name, "Group") == 0 &&
         strcmp (rows[0].mode, "pass-through") == 0 && rows[0].selected,
         "the group is on top, named, selected and pass-through (%s, %s)",
         count == 2 ? rows[0].name : "?", count == 2 ? rows[0].mode : "?");

  /* New Layer enters a selected group. Build the root-level fixture
   * using existing select/arrange commands before testing tree moves. */
  CHECK (api->layer_select (engine, image, background) == GLIMS_STATUS_OK &&
         api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &a, NULL) == GLIMS_STATUS_OK &&
         api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &b, NULL) == GLIMS_STATUS_OK &&
         api->layer_command (engine, image, a, GLIMS_LAYER_TO_TOP, NULL, NULL) == GLIMS_STATUS_OK &&
         api->layer_command (engine, image, b, GLIMS_LAYER_TO_TOP, NULL, NULL) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { b, a, group, background },
                  (GlimsItemID[]) { 0, 0, 0, 0 }, (int32_t[]) { 0, 0, 0, 0 }, 4),
         "two layers are added above the group");

  /* Reparent at exact positions; undo and redo restore them exactly. */
  CHECK (api->reparent_layer (engine, image, a, group, 0, &error) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { b, group, a, background },
                  (GlimsItemID[]) { 0, 0, group, 0 }, (int32_t[]) { 0, 0, 1, 0 }, 4),
         "a layer moves into the group at index 0%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->reparent_layer (engine, image, b, group, 1, NULL) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { group, a, b, background },
                  (GlimsItemID[]) { 0, group, group, 0 }, (int32_t[]) { 0, 1, 1, 0 }, 4),
         "a second layer follows it inside the group");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { b, group, a, background },
                  (GlimsItemID[]) { 0, 0, group, 0 }, (int32_t[]) { 0, 0, 1, 0 }, 4),
         "undo restores the layer's old top-level position");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { b, a, group, background },
                  (GlimsItemID[]) { 0, 0, 0, 0 }, (int32_t[]) { 0, 0, 0, 0 }, 4),
         "undo restores the first move too");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { group, a, b, background },
                  (GlimsItemID[]) { 0, group, group, 0 }, (int32_t[]) { 0, 1, 1, 0 }, 4),
         "redo replays both moves in order");

  /* Reorder inside one parent is the same call; undo and redo too. */
  CHECK (api->reparent_layer (engine, image, a, group, 1, NULL) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { group, b, a, background },
                  (GlimsItemID[]) { 0, group, group, 0 }, (int32_t[]) { 0, 1, 1, 0 }, 4),
         "reordering swaps the group's children");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { group, a, b, background },
                  (GlimsItemID[]) { 0, group, group, 0 }, (int32_t[]) { 0, 1, 1, 0 }, 4),
         "undo restores the children's order");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { group, b, a, background },
                  (GlimsItemID[]) { 0, group, group, 0 }, (int32_t[]) { 0, 1, 1, 0 }, 4),
         "redo swaps them again");

  before = undo_depth (image);
  CHECK (api->reparent_layer (engine, image, a, group, 1, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before,
         "a move to the same position adds no undo step");

  /* Moving back out to the top level. */
  CHECK (api->reparent_layer (engine, image, b, 0, 1, NULL) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { group, a, b, background },
                  (GlimsItemID[]) { 0, group, 0, 0 }, (int32_t[]) { 0, 1, 0, 0 }, 4),
         "a layer moves back out of the group");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK, "the move out undoes and redoes");

  CHECK (api->create_group (engine, image, group, 1, "Nested", &nested, NULL) == GLIMS_STATUS_OK &&
         tree_is (image, (GlimsItemID[]) { group, a, nested, b, background },
                  (GlimsItemID[]) { 0, group, group, 0, 0 }, (int32_t[]) { 0, 1, 1, 0, 0 }, 5),
         "a group inside the group reports its depth and parent");

  /* Cycles, a non-group parent, items of another image, deleted ids and
   * out-of-range indices are all refused before anything changes. */
  before = undo_depth (image);
  CHECK (api->reparent_layer (engine, image, group, nested, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->reparent_layer (engine, image, group, group, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->reparent_layer (engine, image, a, b, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == before,
         "a group cannot move into itself, its descendant or a pixel layer");

  api->image_new (engine, 32, 32, &other, NULL);
  foreign = first_layer (other);
  CHECK (api->reparent_layer (engine, image, foreign, group, 0, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->reparent_layer (engine, image, a, foreign, 0, NULL) == GLIMS_STATUS_NOT_FOUND &&
         undo_depth (image) == before,
         "layers of another image are refused");

  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &gone, NULL);
  api->layer_command (engine, image, gone, GLIMS_LAYER_DELETE, NULL, NULL);
  before = undo_depth (image);
  CHECK (api->reparent_layer (engine, image, gone, group, 0, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->create_group (engine, image, gone, 0, NULL, NULL, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->set_layer_locks (engine, image, gone, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL) ==
           GLIMS_STATUS_NOT_FOUND &&
         api->layer_state (engine, image, gone, &state) == GLIMS_STATUS_NOT_FOUND &&
         undo_depth (image) == before,
         "a deleted layer cannot be moved, parent to, locked or read");

  CHECK (api->create_group (engine, image, 0, 99, NULL, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->create_group (engine, image, 0, -1, NULL, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->reparent_layer (engine, image, a, group, 99, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->reparent_layer (engine, image, a, group, 2, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->reparent_layer (engine, image, a, group, -1, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == before,
         "out-of-range indices are refused without an undo step");

  /* Locks: the item's own bits, and the effective bits the ancestors set. */
  CHECK (api->layer_state (engine, image, a, &state) == GLIMS_STATUS_OK &&
         state.locks == 0 && state.locked == 0, "a new layer reports no locks");

  before = undo_depth (image);
  CHECK (api->set_layer_locks (engine, image, group, GLIMS_LOCK_PIXELS | GLIMS_LOCK_ALPHA,
                              GLIMS_LOCK_PIXELS | GLIMS_LOCK_ALPHA, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "two locks in one call are one undo step");
  CHECK (api->layer_state (engine, image, group, &state) == GLIMS_STATUS_OK &&
         state.locks == (GLIMS_LOCK_PIXELS | GLIMS_LOCK_ALPHA) &&
         state.locked == (GLIMS_LOCK_PIXELS | GLIMS_LOCK_ALPHA),
         "the group reports its own locks (%x, %x)", state.locks, state.locked);
  CHECK (api->layer_state (engine, image, a, &state) == GLIMS_STATUS_OK &&
         state.locks == 0 && state.locked == (GLIMS_LOCK_PIXELS | GLIMS_LOCK_ALPHA),
         "the group's children inherit its locks (%x, %x)", state.locks, state.locked);
  CHECK (api->layer_state (engine, image, b, &state) == GLIMS_STATUS_OK &&
         state.locked == 0, "layers outside the group keep no locks");

  CHECK (api->set_layer_locks (engine, image, a, GLIMS_LOCK_POSITION, GLIMS_LOCK_POSITION, NULL) ==
           GLIMS_STATUS_OK &&
         api->layer_state (engine, image, a, &state) == GLIMS_STATUS_OK &&
         state.locks == GLIMS_LOCK_POSITION &&
         state.locked == (GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION | GLIMS_LOCK_ALPHA),
         "the child's own and inherited locks read separately (%x, %x)", state.locks, state.locked);
  CHECK (api->layer_state (engine, image, group, &state) == GLIMS_STATUS_OK &&
         state.locked & GLIMS_LOCK_POSITION && ! (state.locks & GLIMS_LOCK_POSITION),
         "the group's effective locks cover a locked child (%x, %x)", state.locks, state.locked);

  before = undo_depth (image);
  CHECK (api->set_layer_locks (engine, image, a, GLIMS_LOCK_POSITION, GLIMS_LOCK_POSITION, NULL) ==
           GLIMS_STATUS_OK &&
         api->set_layer_locks (engine, image, a, 0, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->set_layer_locks (engine, image, a, 0x80, 0x80, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == before,
         "a no-op lock and unknown mask bits add no undo step");

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->layer_state (engine, image, a, &state) == GLIMS_STATUS_OK &&
         state.locks == 0 && state.locked == (GLIMS_LOCK_PIXELS | GLIMS_LOCK_ALPHA),
         "undo lifts the child's lock and its effective bit");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->layer_state (engine, image, a, &state) == GLIMS_STATUS_OK &&
         state.locks == GLIMS_LOCK_POSITION &&
         state.locked == (GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION | GLIMS_LOCK_ALPHA),
         "redo restores it");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->layer_state (engine, image, a, &state) == GLIMS_STATUS_OK &&
         state.locks == 0 && state.locked == 0,
         "undoing the group's locks clears the children's inherited bits");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->layer_state (engine, image, a, &state) == GLIMS_STATUS_OK &&
         state.locks == GLIMS_LOCK_POSITION &&
         state.locked == (GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION | GLIMS_LOCK_ALPHA),
         "redo brings the locks and their inheritance back");

  if (other)
    api->image_close (engine, other);
  if (image)
    api->image_close (engine, image);
}

static void
test_layer_edit_locks (void)
{
  GlimsImageID image = 0;
  GlimsItemID group = 0, layer = 0;
  GlimsStrokeID stroke = 0;
  GlimsFilterID filter = 0;
  GlimsStatus status;
  GlimsPixelBuffer before = { 0 }, after = { 0 };
  GlimsLayerInfo row;
  int32_t count = 0, depth;
  GlimsFillSettings fill = { .struct_size = sizeof fill, .mode = GLIMS_FILL_SELECTION,
                             .color = { 1, 0, 0, 1 }, .opacity = 1 };
  GlimsGradientSettings gradient = { .struct_size = sizeof gradient, .shape = GLIMS_GRADIENT_LINEAR,
                                     .from = { 0, 1, 0, 1 }, .to = { 0, 0, 1, 1 }, .opacity = 1 };
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 5);
  GlimsStrokePoint point = { .x = 10, .y = 10, .pressure = 1 };
  GlimsMatrix matrix = { .m = { { 1, 0, 2 }, { 0, 1, 3 }, { 0, 0, 1 } } };

  api->image_new (engine, 64, 48, &image, NULL);
  api->create_group (engine, image, 0, 0, "Protected Group", &group, NULL);
  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &fill, NULL);
  api->image_copy_pixels (engine, image, false, &before, NULL);
  api->set_layer_locks (engine, image, group, GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION,
                        GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, NULL);
  depth = undo_depth (image);
  fill.color = (GlimsColor) { 0, 0, 1, 1 };
  CHECK (api->fill (engine, image, (GlimsPoint) { 0, 0 }, &fill, NULL) == GLIMS_STATUS_LOCKED &&
         api->gradient (engine, image, (GlimsPoint) { 0, 0 }, (GlimsPoint) { 60, 40 }, &gradient, NULL) == GLIMS_STATUS_LOCKED &&
         api->image_clear (engine, image, NULL, NULL) == GLIMS_STATUS_LOCKED,
         "inherited pixel locks refuse fill, gradient and clear");
  status = api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL);
  CHECK (status == GLIMS_STATUS_LOCKED, "inherited pixel locks refuse paint before creating a stroke");
  if (status == GLIMS_STATUS_OK) api->stroke_end (engine, stroke);
  status = api->filter_begin (engine, image, layer, "gegl:invert-gamma", &filter, NULL);
  CHECK (status == GLIMS_STATUS_LOCKED, "inherited pixel locks refuse starting a filter");
  if (status == GLIMS_STATUS_OK) api->filter_abort (engine, filter);
  CHECK (api->layer_move (engine, image, layer, 5, 4) == GLIMS_STATUS_LOCKED &&
         api->layer_transform (engine, image, layer, GLIMS_TRANSFORM_FLIP_HORIZONTAL) == GLIMS_STATUS_LOCKED &&
         api->layer_transform_matrix (engine, image, layer, &matrix, GLIMS_INTERPOLATION_NONE, NULL) == GLIMS_STATUS_LOCKED,
         "inherited position locks refuse moves and layer transforms");
  api->image_copy_pixels (engine, image, false, &after, NULL);
  CHECK (undo_depth (image) == depth && before.byte_count == after.byte_count &&
         rect_equals (after.bounds, before.bounds.x, before.bounds.y, before.bounds.width, before.bounds.height) &&
         memcmp (before.pixels, after.pixels, before.byte_count) == 0,
         "refused locked edits preserve pixels, bounds and undo history");
  api->free_pixels (before.pixels);
  api->free_pixels (after.pixels);
  api->set_layer_locks (engine, image, group, GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION | GLIMS_LOCK_ALPHA,
                        GLIMS_LOCK_ALPHA, NULL);
  depth = undo_depth (image);
  brush.tool = GLIMS_PAINT_ERASER;
  status = api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL);
  CHECK (status == GLIMS_STATUS_LOCKED, "an inherited transparency lock refuses the eraser");
  if (status == GLIMS_STATUS_OK) api->stroke_end (engine, stroke);
  CHECK (api->image_clear (engine, image, NULL, NULL) == GLIMS_STATUS_LOCKED && undo_depth (image) == depth,
         "an inherited transparency lock refuses Clear without an undo step");
  api->set_layer_locks (engine, image, group, GLIMS_LOCK_ALPHA, 0, NULL);
  CHECK (api->layer_move (engine, image, layer, 5, 4) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK,
         "unlocking restores ordinary layer editing");
  api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, NULL);
  api->set_layer_locks (engine, image, group, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL);
  depth = undo_depth (image);
  CHECK (api->filter_set_double (engine, filter, "std-dev-x", 3) == GLIMS_STATUS_LOCKED,
         "a new inherited lock protects an already open preview from parameter edits");
  CHECK (api->filter_commit (engine, filter, NULL) == GLIMS_STATUS_LOCKED &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK && undo_depth (image) == depth,
         "a protected preview refuses commit while cancellation remains available without an undo step");
  api->image_close (engine, image);
}

/* Layer masks: reading and changing mask state, the six sources' effect
 * on the composite, painting a mask versus its layer, apply and discard,
 * mask to selection, locks inherited through the owner, id and buffer
 * refusals, small thumbnails of drawables and masks, and XCF. */
static void
test_mask_clipboard_target (void)
{
  GlimsImageID image = 0;
  GlimsItemID layer, mask = 0;
  GlimsPixelBuffer copied = { 0 };
  GlimsColor black = { 0, 0, 0, 1 };
  uint8_t *pixels;
  int width, height;

  api->image_new (engine, 16, 16, &image, NULL);
  layer = first_layer (image);
  api->layer_mask_add (engine, image, layer, GLIMS_MASK_BLACK, true, &mask, NULL);
  CHECK (api->image_copy_pixels (engine, image, false, &copied, NULL) == GLIMS_STATUS_OK &&
         copied.byte_count == 16 * 16 * 4 && copied.pixels[0] == 0 && copied.pixels[3] == 255,
         "Copy targets a selected black mask rather than its white layer");
  api->free_pixels (copied.pixels);
  api->layer_mask_apply (engine, image, layer, GLIMS_MASK_DISCARD, NULL);
  api->layer_mask_add (engine, image, layer, GLIMS_MASK_WHITE, true, &mask, NULL);
  CHECK (api->image_clear (engine, image, &black, NULL) == GLIMS_STATUS_OK,
         "Clear accepts the selected mask as its edit target");
  api->layer_mask_set (engine, image, layer, GLIMS_MASK_ENABLED, 0, NULL);
  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixels[0] == 255 && pixels[3] == 255,
         "clearing a mask preserves its layer's actual pixels");
  api->free_pixels (pixels);
  api->image_close (engine, image);
}

static void
test_layer_masks (const char *work)
{
  GlimsImageID       image = 0, src = 0, other = 0, copy = 0, reopened = 0;
  GlimsItemID        layer = 0, mask = 0, group = 0, kid = 0, gmask = 0, foreign = 0, pasted = 0;
  GlimsMaskState     state;
  GlimsLayerInfo     rows[8];
  GlimsRect          bounds;
  GlimsStatus        status;
  GlimsStrokeID      stroke = 0;
  GlimsFilterID      filter = 0;
  GlimsStrokePoint   point = { 10, 10, 1.0, 0.0, 0.0, 0 };
  GlimsSelectOptions rect = { .struct_size = sizeof rect, .operation = GLIMS_SELECT_REPLACE };
  GlimsFillSettings  red = { .struct_size = sizeof red, .mode = GLIMS_FILL_SELECTION,
                             .color = { 1, 0, 0, 1 }, .opacity = 1 };
  GlimsFillSettings  black = { .struct_size = sizeof black, .mode = GLIMS_FILL_SELECTION,
                               .color = { 0, 0, 0, 1 }, .opacity = 1 };
  GlimsGradientSettings grad = { .struct_size = sizeof grad, .shape = GLIMS_GRADIENT_LINEAR,
                                 .from = { 0, 0, 0, 1 }, .to = { 1, 1, 1, 1 }, .opacity = 1 };
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  bool               empty = true;
  int32_t            count = 0, before, w = 0, h = 0;
  uint8_t            pixel[4];
  uint8_t            thumb[256 * 256 * 4];
  char               xcf[1024];
  char              *error = NULL;

  api->image_new (engine, 64, 48, &image, NULL);
  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &red, NULL);

  /* A maskless layer, invalid arguments and clean failures: no undo step. */
  before = undo_depth (image);
  CHECK (api->layer_mask (engine, image, layer, &state) == GLIMS_STATUS_OK &&
         state.mask == 0 && ! state.enabled && ! state.editing && ! state.showing,
         "a layer without a mask reports mask 0 and clear flags");
  CHECK (api->layer_mask (engine, image, layer, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->layer_mask_add (engine, image, layer, 0, false, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->layer_mask_add (engine, image, layer, 7, false, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->layer_mask_set (engine, image, layer, 0, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->layer_mask_set (engine, image, layer, 16, 16, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->layer_mask_apply (engine, image, layer, 3, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->layer_mask_to_selection (engine, image, layer, 4, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == before,
         "unknown sources, modes, operations and flag bits are refused");
  CHECK (api->layer_mask_apply (engine, image, layer, GLIMS_MASK_DISCARD, NULL) == GLIMS_STATUS_FAILED &&
         api->layer_mask_to_selection (engine, image, layer, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_FAILED &&
         api->layer_mask_set (engine, image, layer, GLIMS_MASK_ENABLED, 0, NULL) == GLIMS_STATUS_FAILED &&
         undo_depth (image) == before,
         "mask calls on a maskless layer fail without an undo step");

  /* White leaves the red layer visible, as one undo step. */
  CHECK (api->layer_mask_add (engine, image, layer, GLIMS_MASK_WHITE, false, &mask, &error) == GLIMS_STATUS_OK &&
         mask > 0 && undo_depth (image) == before + 1,
         "a white mask is added as one undo step%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 32, 24, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0 && pixel[3] == 255,
         "a white mask leaves the composite unchanged (%d,%d,%d,%d)",
         pixel[0], pixel[1], pixel[2], pixel[3]);
  CHECK (api->layer_mask (engine, image, layer, &state) == GLIMS_STATUS_OK &&
         state.mask == mask && state.enabled && ! state.editing && ! state.showing &&
         api->image_layers (engine, image, rows, 8, &count) == GLIMS_STATUS_OK &&
         rows[0].id == layer && rows[0].has_mask,
         "the new mask reads enabled, not edited, not shown");
  CHECK (api->layer_mask_add (engine, image, layer, GLIMS_MASK_BLACK, false, NULL, &error) == GLIMS_STATUS_FAILED &&
         error && undo_depth (image) == before + 1,
         "a second mask is refused (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;

  /* The editing flag is transient: fills follow it. */
  before = undo_depth (image);
  CHECK (api->layer_mask_set (engine, image, layer, GLIMS_MASK_EDITING, GLIMS_MASK_EDITING, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before &&
         api->layer_mask (engine, image, layer, &state) == GLIMS_STATUS_OK && state.editing,
         "entering mask editing adds no undo step");
  CHECK (api->fill (engine, image, (GlimsPoint) { 0, 0 }, &black, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 32, 24, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 255,
         "a fill while editing paints the mask, hiding the layer (%d,%d,%d)",
         pixel[0], pixel[1], pixel[2]);

  /* Enabled gates the mask's effect: with the mask still black from the
   * fill, disabling shows the layer, and the flag undoes and redoes. */
  before = undo_depth (image);
  CHECK (api->layer_mask_set (engine, image, layer, GLIMS_MASK_ENABLED, 0, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->layer_mask (engine, image, layer, &state) == GLIMS_STATUS_OK && ! state.enabled &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 32, 24, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 0,
         "disabling the mask shows the layer again, as one undo step");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->layer_mask (engine, image, layer, &state) == GLIMS_STATUS_OK && state.enabled &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 32, 24, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 255 &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->layer_mask (engine, image, layer, &state) == GLIMS_STATUS_OK && ! state.enabled &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 32, 24, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 0,
         "undo and redo toggle the mask's effect");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&   /* the disable */
         api->image_undo (engine, image) == GLIMS_STATUS_OK &&   /* the mask fill */
         api->image_render (engine, image, 1.0, (GlimsRect) { 32, 24, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0,
         "undoing the mask fill restores the layer");

  /* Showing displays the mask instead of the composite: the white mask
   * reads as opaque white at its corner. */
  CHECK (api->layer_mask_set (engine, image, layer, GLIMS_MASK_SHOWING, GLIMS_MASK_SHOWING, NULL) == GLIMS_STATUS_OK &&
         api->layer_mask (engine, image, layer, &state) == GLIMS_STATUS_OK && state.showing &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 4, 4, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 240 && pixel[0] == pixel[1] && pixel[1] == pixel[2],
         "showing renders the mask's own gray levels (%d,%d,%d)", pixel[0], pixel[1], pixel[2]);
  CHECK (api->layer_mask_set (engine, image, layer, GLIMS_MASK_SHOWING, 0, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 4, 4, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 0, "un-showing returns to the composite");

  /* Painting names the drawable: the mask id darkens the mask along its
   * line, the layer id hits the layer's pixels. */
  CHECK (stroke_line (image, mask, &brush, 8, 24, 56, 24, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 32, 24, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] > 200 && pixel[0] > 200 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 32, 40, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 0,
         "painting the mask id hides the layer only along its line");
  CHECK (stroke_line (image, layer, &brush, 8, 12, 56, 12, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 32, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] < 64 && pixel[1] < 64,
         "painting the layer id hits its pixels, not the mask");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 32, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0,
         "undoing both strokes restores the composite");

  /* A gradient follows the editing flag too: dark to light across the
   * mask fades the layer in (the ramp is perceptual, so assert a fade,
   * not exact levels). */
  CHECK (api->gradient (engine, image, (GlimsPoint) { 0, 24 }, (GlimsPoint) { 64, 24 }, &grad, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 4, 24, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] > 200 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 60, 24, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] < 160,
         "a gradient while editing shades the mask (%d left, %d right)",
         pixel[1], red_at (image, 60, 24));
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK,
         "undoing the mask gradient restores the white mask");

  /* Mask to Selection combines the mask at its offset: the white mask
   * selects everything, a dark column at its left edge shrinks it. */
  before = undo_depth (image);
  CHECK (api->layer_mask_to_selection (engine, image, layer, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 0, 0, 64, 48),
         "Mask to Selection selects the whole white mask (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);
  CHECK (stroke_line (image, mask, &brush, 0, 0, 0, 48, NULL) == GLIMS_STATUS_OK &&
         api->layer_mask_to_selection (engine, image, layer, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         bounds.x > 0 && bounds.x < 12 && bounds.width < 64,
         "a dark column shrinks the selection from the left (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);

  /* Mutations refuse while a stroke or a preview runs, without ending it. */
  point = (GlimsStrokePoint) { 20, 40, 1.0, 0.0, 0.0, 0 };
  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK,
         "a stroke begins for the busy check");
  CHECK (api->layer_mask_add (engine, image, layer, GLIMS_MASK_BLACK, false, NULL, NULL) == GLIMS_STATUS_BUSY &&
         api->layer_mask_set (engine, image, layer, GLIMS_MASK_ENABLED, 0, NULL) == GLIMS_STATUS_BUSY &&
         api->layer_mask_apply (engine, image, layer, GLIMS_MASK_DISCARD, NULL) == GLIMS_STATUS_BUSY &&
         api->layer_mask_to_selection (engine, image, layer, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_BUSY &&
         api->layer_mask (engine, image, layer, &state) == GLIMS_STATUS_OK && state.mask == mask,
         "mask changes report BUSY during a stroke; reads still work");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK,
         "the refusals left the stroke alive");
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK &&
         api->layer_mask_set (engine, image, layer, GLIMS_MASK_ENABLED, 0, NULL) == GLIMS_STATUS_BUSY &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "mask changes report BUSY during a preview, and abort works");

  /* The remaining sources, each on its own 16x16 image: a white
   * background under a red layer. */
  api->image_new (engine, 16, 16, &src, NULL);
  api->layer_command (engine, src, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, src, (GlimsPoint) { 0, 0 }, &red, NULL);
  CHECK (api->layer_mask_add (engine, src, layer, GLIMS_MASK_BLACK, false, &mask, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, src, 1.0, (GlimsRect) { 8, 8, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 255,
         "a black mask hides its layer");
  api->image_close (engine, src);

  src = 0;
  api->image_new (engine, 16, 16, &src, NULL);
  api->layer_command (engine, src, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, src, (GlimsPoint) { 0, 0 }, &red, NULL);
  api->select_shape (engine, src, GLIMS_SHAPE_RECTANGLE, (GlimsPoint[]) { { 0, 0 }, { 8, 16 } }, 2, &rect);
  CHECK (api->layer_mask_add (engine, src, layer, GLIMS_MASK_SELECTION, false, &mask, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, src, 1.0, (GlimsRect) { 4, 8, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 0 &&
         api->image_render (engine, src, 1.0, (GlimsRect) { 12, 8, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 255,
         "a selection mask keeps the layer inside the selection only");
  api->image_close (engine, src);

  /* Alpha: clear the right half first so the layer's alpha differs. */
  src = 0;
  api->image_new (engine, 16, 16, &src, NULL);
  api->layer_command (engine, src, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, src, (GlimsPoint) { 0, 0 }, &red, NULL);
  api->select_shape (engine, src, GLIMS_SHAPE_RECTANGLE, (GlimsPoint[]) { { 8, 0 }, { 16, 16 } }, 2, &rect);
  api->image_clear (engine, src, NULL, NULL);
  api->select_command (engine, src, GLIMS_SELECT_NONE, 0, NULL);
  CHECK (api->layer_mask_add (engine, src, layer, GLIMS_MASK_ALPHA, false, &mask, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, src, 1.0, (GlimsRect) { 4, 8, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 0 &&
         api->image_render (engine, src, 1.0, (GlimsRect) { 12, 8, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 255,
         "an alpha mask follows the layer's transparency");
  api->layer_mask_apply (engine, src, layer, GLIMS_MASK_DISCARD, NULL);
  CHECK (api->layer_mask_add (engine, src, layer, GLIMS_MASK_ALPHA_TRANSFER, false, &mask, NULL) == GLIMS_STATUS_OK &&
         api->layer_mask (engine, src, layer, &state) == GLIMS_STATUS_OK && state.mask == mask &&
         api->drawable_thumbnail (engine, src, layer, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(8 * 16 + 12) * 4 + 3] == 255,
         "alpha transfer leaves the layer itself opaque (%d)", thumb[(8 * 16 + 12) * 4 + 3]);
  api->image_close (engine, src);

  src = 0;
  api->image_new (engine, 16, 16, &src, NULL);
  api->layer_command (engine, src, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, src, (GlimsPoint) { 0, 0 }, &red, NULL);
  CHECK (api->layer_mask_add (engine, src, layer, GLIMS_MASK_GRAYSCALE, false, &mask, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, src, 1.0, (GlimsRect) { 8, 8, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] > 120 && pixel[1] < 230,
         "a grayscale mask dims red to pink (%d)", pixel[1]);
  api->image_close (engine, src);
  src = 0;
  layer = 0;
  mask = 0;

  /* Apply bakes the mask into the layer; discard just removes it. Both
   * undo and redo, and a discarded mask's id goes stale. */
  api->image_new (engine, 32, 32, &src, NULL);
  api->layer_command (engine, src, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, src, (GlimsPoint) { 0, 0 }, &red, NULL);
  api->layer_mask_add (engine, src, layer, GLIMS_MASK_BLACK, false, &mask, NULL);
  before = undo_depth (src);
  CHECK (api->layer_mask_apply (engine, src, layer, GLIMS_MASK_DISCARD, NULL) == GLIMS_STATUS_OK &&
         undo_depth (src) == before + 1 &&
         api->layer_mask (engine, src, layer, &state) == GLIMS_STATUS_OK && state.mask == 0 &&
         api->image_render (engine, src, 1.0, (GlimsRect) { 16, 16, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] == 0,
         "Discard removes the mask without applying it");
  CHECK (api->drawable_thumbnail (engine, src, mask, 8, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_NOT_FOUND,
         "the discarded mask's id is stale");
  CHECK (api->image_undo (engine, src) == GLIMS_STATUS_OK &&
         api->layer_mask (engine, src, layer, &state) == GLIMS_STATUS_OK && state.mask != 0 &&
         api->image_redo (engine, src) == GLIMS_STATUS_OK &&
         api->layer_mask (engine, src, layer, &state) == GLIMS_STATUS_OK && state.mask == 0 &&
         api->image_undo (engine, src) == GLIMS_STATUS_OK &&
         api->layer_mask (engine, src, layer, &state) == GLIMS_STATUS_OK && state.mask != 0,
         "undo and redo of the discard toggle the mask");
  before = undo_depth (src);
  CHECK (api->layer_mask_apply (engine, src, layer, GLIMS_MASK_APPLY, NULL) == GLIMS_STATUS_OK &&
         undo_depth (src) == before + 1 &&
         api->layer_mask (engine, src, layer, &state) == GLIMS_STATUS_OK && state.mask == 0 &&
         api->image_render (engine, src, 1.0, (GlimsRect) { 16, 16, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 255,
         "Apply bakes the black mask into the layer, hiding it (%d,%d,%d)",
         pixel[0], pixel[1], pixel[2]);
  CHECK (api->image_undo (engine, src) == GLIMS_STATUS_OK &&
         api->layer_mask (engine, src, layer, &state) == GLIMS_STATUS_OK && state.mask != 0 &&
         api->image_redo (engine, src) == GLIMS_STATUS_OK &&
         api->layer_mask (engine, src, layer, &state) == GLIMS_STATUS_OK && state.mask == 0,
         "undo restores the mask, redo applies it again");
  api->image_close (engine, src);
  src = 0;

  /* Groups take masks; the group's apply is refused as GIMP's menu is,
   * locks on the group reach the child's mask through the owner, and
   * foreign, mask-typed, deleted and unknown ids are refused. */
  api->image_new (engine, 32, 32, &src, NULL);
  api->image_layers (engine, src, rows, 8, &count);
  kid = rows[0].id;
  api->create_group (engine, src, 0, 0, "Group", &group, NULL);
  api->reparent_layer (engine, src, kid, group, 0, NULL);
  CHECK (api->layer_mask_add (engine, src, group, GLIMS_MASK_WHITE, false, &gmask, &error) == GLIMS_STATUS_OK &&
         gmask > 0, "a group takes a mask%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->layer_mask_apply (engine, src, group, GLIMS_MASK_APPLY, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "applying a group's mask is refused");
  api->layer_mask_add (engine, src, kid, GLIMS_MASK_WHITE, false, NULL, NULL);
  api->set_layer_locks (engine, src, group, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL);
  status = api->stroke_begin (engine, src, gmask, &brush, &point, &stroke, NULL);
  CHECK (status == GLIMS_STATUS_LOCKED, "an inherited lock refuses painting the group's mask");
  if (status == GLIMS_STATUS_OK)
    api->stroke_end (engine, stroke);
  CHECK (api->layer_mask_apply (engine, src, kid, GLIMS_MASK_APPLY, NULL) == GLIMS_STATUS_LOCKED &&
         api->layer_mask_apply (engine, src, kid, GLIMS_MASK_DISCARD, NULL) == GLIMS_STATUS_OK,
         "the inherited lock protects apply but not discard");
  api->image_new (engine, 8, 8, &other, NULL);
  foreign = first_layer (other);
  CHECK (api->layer_mask (engine, src, foreign, &state) == GLIMS_STATUS_NOT_FOUND &&
         api->layer_mask_add (engine, src, foreign, GLIMS_MASK_WHITE, false, NULL, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->layer_mask (engine, src, gmask, &state) == GLIMS_STATUS_NOT_FOUND &&
         api->layer_mask (engine, 9999, group, &state) == GLIMS_STATUS_NOT_FOUND &&
         api->drawable_thumbnail (engine, src, foreign, 8, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_NOT_FOUND,
         "foreign, mask-typed and unknown ids are refused");
  api->layer_mask_add (engine, src, kid, GLIMS_MASK_WHITE, false, &foreign, NULL);
  api->layer_command (engine, src, kid, GLIMS_LAYER_DELETE, NULL, NULL);
  CHECK (api->layer_mask (engine, src, kid, &state) == GLIMS_STATUS_NOT_FOUND &&
         api->drawable_thumbnail (engine, src, foreign, 8, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_NOT_FOUND,
         "a deleted layer and its mask are refused while undo holds them");
  api->image_close (engine, src);
  api->image_close (engine, other);
  src = other = foreign = 0;

  /* Thumbnails of a layer and of a mask: geometry, alpha, gray levels. */
  api->image_new (engine, 64, 48, &src, NULL);
  api->layer_command (engine, src, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, src, (GlimsPoint) { 0, 0 }, &red, NULL);
  api->layer_mask_add (engine, src, layer, GLIMS_MASK_WHITE, false, &mask, NULL);
  CHECK (api->drawable_thumbnail (engine, src, layer, 16, NULL, 0, &w, &h) == GLIMS_STATUS_OK &&
         w == 16 && h == 12,
         "a 64x48 drawable thumbnails to 16x12 (%dx%d)", w, h);
  CHECK (api->drawable_thumbnail (engine, src, layer, 256, NULL, 0, &w, &h) == GLIMS_STATUS_OK &&
         w == 64 && h == 48,
         "thumbnails never upscale (%dx%d)", w, h);
  CHECK (api->drawable_thumbnail (engine, src, layer, 0, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->drawable_thumbnail (engine, src, layer, 257, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->drawable_thumbnail (engine, src, layer, -4, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->drawable_thumbnail (engine, src, layer, 16, thumb, 16 * 12 * 4 - 1, &w, &h) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->drawable_thumbnail (engine, src, layer, 16, thumb, sizeof thumb, NULL, &h) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->drawable_thumbnail (engine, src, layer, 16, thumb, sizeof thumb, &w, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "thumbnails refuse bad sizes, small buffers and missing outputs");
  CHECK (api->drawable_thumbnail (engine, src, layer, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         w == 16 && h == 12 &&
         thumb[(2 * w + 8) * 4] == 255 && thumb[(2 * w + 8) * 4 + 1] == 0 && thumb[(2 * w + 8) * 4 + 3] == 255,
         "the layer thumbnails as sRGB straight-alpha red (%d,%d,%d,%d)",
         thumb[(2 * w + 8) * 4], thumb[(2 * w + 8) * 4 + 1], thumb[(2 * w + 8) * 4 + 2],
         thumb[(2 * w + 8) * 4 + 3]);
  CHECK (stroke_line (src, mask, &brush, 0, 0, 0, 48, NULL) == GLIMS_STATUS_OK &&
         api->drawable_thumbnail (engine, src, mask, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(2 * w + 15) * 4] > 200 && thumb[(2 * w + 15) * 4 + 3] == 255 && thumb[2 * w * 4] < 100,
         "the mask thumbnails as opaque gray, dark where painted (left %d, right %d)",
         thumb[2 * w * 4], thumb[(2 * w + 15) * 4]);

  /* XCF keeps the mask and its flags; a snapshot owns a mask of its
   * own id. */
  CHECK (api->layer_mask_set (engine, src, layer, GLIMS_MASK_EDITING, GLIMS_MASK_EDITING, NULL) == GLIMS_STATUS_OK,
         "editing turns back on for the round trip");
  snprintf (xcf, sizeof xcf, "%s/masks.xcf", work);
  CHECK (api->image_save (engine, src, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, reopened, rows, 8, &count) == GLIMS_STATUS_OK && rows[0].has_mask &&
         api->layer_mask (engine, reopened, rows[0].id, &state) == GLIMS_STATUS_OK &&
         state.mask != 0 && state.enabled && state.editing && ! state.showing,
         "an XCF round trip keeps the mask and its flags");
  CHECK (api->image_duplicate (engine, src, &copy, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, copy, rows, 8, &count) == GLIMS_STATUS_OK && rows[0].has_mask &&
         api->layer_mask (engine, copy, rows[0].id, &state) == GLIMS_STATUS_OK &&
         state.mask != 0 && state.mask != mask,
         "a snapshot owns a mask of its own id");
  api->image_close (engine, copy);
  api->image_close (engine, reopened);
  copy = reopened = 0;

  /* Alpha follows the source: a pasted RGBA layer's faint pixel stays
   * faint in the thumbnail. */
  {
    uint8_t rgba[] = { 255, 0, 0, 255, 0, 0, 255, 40 };

    CHECK (api->image_paste_pixels (engine, src, (GlimsRect) { 0, 0, 2, 1 }, rgba, sizeof rgba,
                                    &pasted, NULL) == GLIMS_STATUS_OK &&
           api->drawable_thumbnail (engine, src, pasted, 2, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
           w == 2 && h == 1 && thumb[3] == 255 && thumb[7] < 60,
           "thumbnail alpha matches the source (%d, %d)", thumb[3], thumb[7]);
  }

  api->image_close (engine, src);
  api->image_close (engine, image);
}

/* Components, saved channels and the Quick Mask: enumeration, save,
 * rename, attribute, duplicate, delete and select, channel-only editing
 * with the layer untouched, channel to selection, the components'
 * effect on the composite, undo accounting, wrong ids, BUSY refusals,
 * thumbnails, Quick Mask toggling and painting, and an XCF round trip. */
static void
test_channels (const char *work)
{
  GlimsImageID        image = 0, other = 0, reopened = 0;
  GlimsItemID         layer = 0, saved = 0, saved2 = 0, dup = 0, mask = 0, qm = 0;
  GlimsComponentState comp;
  GlimsChannelInfo    rows[8];
  GlimsChannelChange  change = { 0 };
  GlimsQuickMaskState qstate;
  GlimsRect           bounds;
  GlimsPixelBuffer    copied = { 0 };
  GlimsSelectOptions  rect_opt = { .struct_size = sizeof rect_opt,
                                   .operation = GLIMS_SELECT_REPLACE };
  GlimsFillSettings   red = { .struct_size = sizeof red, .mode = GLIMS_FILL_SELECTION,
                              .color = { 1, 0, 0, 1 }, .opacity = 1 };
  GlimsFillSettings   black = { .struct_size = sizeof black, .mode = GLIMS_FILL_SELECTION,
                                .color = { 0, 0, 0, 1 }, .opacity = 1 };
  GlimsFillSettings   white = { .struct_size = sizeof white, .mode = GLIMS_FILL_SELECTION,
                                .color = { 1, 1, 1, 1 }, .opacity = 1 };
  GlimsBrushSettings  brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  GlimsStrokePoint    point = { 16, 12, 1.0, 0.0, 0.0, 0 };
  GlimsStrokeID       stroke = 0;
  GlimsFilterID       filter = 0;
  bool                empty = true;
  int32_t             count = 0, before, w = 0, h = 0;
  uint8_t             pixel[4];
  uint8_t             thumb[256 * 256 * 4];
  char                xcf[1024];
  char               *error = NULL;
  int                 events;

  api->image_new (engine, 32, 24, &image, NULL);
  layer = first_layer (image);

  /* Components of a fresh RGB image: red, green and blue. Alpha joins
   * once a layer can carry transparency. */
  CHECK (api->image_components (engine, image, &comp) == GLIMS_STATUS_OK &&
         comp.mode == GLIMS_COMPONENT_MODE_RGB &&
         comp.supported == (GLIMS_COMPONENT_RED | GLIMS_COMPONENT_GREEN | GLIMS_COMPONENT_BLUE) &&
         comp.active == comp.supported && comp.visible == comp.supported,
         "a new RGB image reports R,G,B components, all active and visible (%x,%x,%x)",
         comp.supported, comp.active, comp.visible);
  CHECK (api->image_components (engine, 9999, &comp) == GLIMS_STATUS_NOT_FOUND &&
         api->image_components (engine, image, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_channels (engine, image, rows, -1, &count) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_channels (engine, image, rows, 8, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_quick_mask (engine, image, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "component, channel and Quick Mask calls refuse bad arguments");
  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &red, NULL);
  CHECK (api->image_components (engine, image, &comp) == GLIMS_STATUS_OK &&
         comp.supported == (GLIMS_COMPONENT_RED | GLIMS_COMPONENT_GREEN |
                          GLIMS_COMPONENT_BLUE | GLIMS_COMPONENT_ALPHA),
         "alpha joins the components once a layer has it");

  /* The components' visibility feeds the composite: hiding red turns the
   * red layer black. */
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0, "the red layer renders red");
  CHECK (api->image_set_components (engine, image, 0, 0,
                                    GLIMS_COMPONENT_RED, 0, NULL) == GLIMS_STATUS_OK &&
         api->image_components (engine, image, &comp) == GLIMS_STATUS_OK &&
         ! (comp.visible & GLIMS_COMPONENT_RED) &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 0 && pixel[3] == 255,
         "hiding the red component drops it from the composite (%d,%d,%d)",
         pixel[0], pixel[1], pixel[2]);
  CHECK (api->image_set_components (engine, image, 0, 0,
                                    GLIMS_COMPONENT_RED, GLIMS_COMPONENT_RED, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255,
         "restoring red brings the layer back");

  /* Active masks change without an undo step; unknown bits and
   * components the model lacks are refused. */
  before = undo_depth (image);
  CHECK (api->image_set_components (engine, image,
                                    GLIMS_COMPONENT_BLUE | GLIMS_COMPONENT_GREEN, 0, 0, 0,
                                    NULL) == GLIMS_STATUS_OK &&
         api->image_components (engine, image, &comp) == GLIMS_STATUS_OK &&
         comp.active == (comp.supported & ~(GLIMS_COMPONENT_BLUE | GLIMS_COMPONENT_GREEN)) &&
         undo_depth (image) == before,
         "component active masks change without an undo step");
  api->image_set_components (engine, image, comp.supported, comp.supported, 0, 0, NULL);
  CHECK (api->image_set_components (engine, image, GLIMS_COMPONENT_GRAY, 0, 0, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_set_components (engine, image, 64, 0, 0, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "components the model lacks and unknown bits are refused");

  /* Save to Channel copies the selection into a new, invisible, selected
   * channel as one undo step. */
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                     (GlimsPoint[]) { { 8, 8 }, { 24, 20 } }, 2, &rect_opt);
  before = undo_depth (image);
  CHECK (api->channel_from_selection (engine, image, "Saved", &saved, &error) == GLIMS_STATUS_OK &&
         saved > 0 && undo_depth (image) == before + 1,
         "Save to Channel adds a channel as one undo step%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_channels (engine, image, rows, 8, &count) == GLIMS_STATUS_OK &&
         count == 1 && rows[0].id == saved && rows[0].selected && ! rows[0].visible &&
         ! rows[0].quick_mask && strcmp (rows[0].name, "Saved") == 0,
         "the saved channel reads selected, invisible and named (%s)", rows[0].name);
  CHECK (api->image_channels (engine, image, NULL, 0, &count) == GLIMS_STATUS_OK && count == 1,
         "a NULL list still reports the channel count");

  /* The channel's own pixels: bright coverage inside the selection. */
  CHECK (api->drawable_thumbnail (engine, image, saved, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         w == 16 && h == 12 &&
         thumb[(6 * w + 8) * 4] > 200 && thumb[(6 * w + 8) * 4 + 3] == 255 &&
         thumb[(1 * w + 1) * 4] < 60,
         "the channel thumbnails its coverage, inside bright, outside dark (%d,%d)",
         thumb[(1 * w + 1) * 4], thumb[(6 * w + 8) * 4]);

  /* Channel to selection, each combine mode, on two saved channels. The
   * second covers the first's right half and beyond. */
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                     (GlimsPoint[]) { { 16, 8 }, { 30, 20 } }, 2, &rect_opt);
  api->channel_from_selection (engine, image, "Second", &saved2, NULL);
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  CHECK (api->channel_to_selection (engine, image, saved, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 8, 8, 16, 12),
         "channel to selection replaces the selection");
  CHECK (api->channel_to_selection (engine, image, saved2, GLIMS_SELECT_ADD, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         rect_equals (bounds, 8, 8, 22, 12),
         "adding a second channel unions the bounds");
  CHECK (api->channel_to_selection (engine, image, saved2, GLIMS_SELECT_SUBTRACT, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         rect_equals (bounds, 8, 8, 8, 12),
         "subtracting keeps only the first channel's left half");
  CHECK (api->channel_to_selection (engine, image, saved2, GLIMS_SELECT_INTERSECT, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK && empty,
         "intersecting the disjoint remainder is empty");
  CHECK (api->channel_to_selection (engine, image, saved, 4, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown combine operation is refused");

  /* A selected channel is the edit target: copy reads its coverage,
   * fills and clears write it, the layer below is untouched. */
  CHECK (api->channel_command (engine, image, saved, GLIMS_CHANNEL_SELECT, NULL, NULL) == GLIMS_STATUS_OK,
         "selecting the channel makes it the edit target");
  api->channel_to_selection (engine, image, saved, GLIMS_SELECT_REPLACE, NULL);
  CHECK (api->image_copy_pixels (engine, image, false, &copied, NULL) == GLIMS_STATUS_OK &&
         copied.bounds.width == 16 && copied.bounds.height == 12 &&
         copied.pixels[0] == 255 && copied.pixels[1] == 255 && copied.pixels[3] == 255,
         "Copy reads the selected channel's coverage, not the red layer (%d,%d,%d)",
         copied.pixels[0], copied.pixels[1], copied.pixels[2]);
  api->free_pixels (copied.pixels);
  copied.pixels = NULL;
  CHECK (api->fill (engine, image, (GlimsPoint) { 0, 0 }, &black, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0 &&
         api->channel_to_selection (engine, image, saved, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK && empty,
         "a fill paints the channel's coverage and leaves the layer red");
  api->image_undo (engine, image);   /* channel to selection */
  api->image_undo (engine, image);   /* the fill: coverage restored */
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  CHECK (api->image_clear (engine, image, NULL, NULL) == GLIMS_STATUS_OK &&
         api->channel_to_selection (engine, image, saved, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 0, 0, 32, 24),
         "Clear fills the channel with coverage, selecting everything");
  api->image_undo (engine, image);   /* channel to selection */
  api->image_undo (engine, image);   /* the clear */
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  api->channel_to_selection (engine, image, saved, GLIMS_SELECT_REPLACE, NULL);

  /* A stroke on the channel's id writes the channel, not the layer. */
  CHECK (stroke_line (image, saved, &brush, 8, 14, 24, 14, NULL) == GLIMS_STATUS_OK &&
         api->drawable_thumbnail (engine, image, saved, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(7 * w + 8) * 4] < 100 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0,
         "a stroke on the channel id paints the channel, not the layer");
  api->image_undo (engine, image);   /* the stroke */

  /* Selecting the layers again makes them the target once more. */
  CHECK (api->channel_command (engine, image, 0, GLIMS_CHANNEL_SELECT, NULL, NULL) == GLIMS_STATUS_OK &&
         api->fill (engine, image, (GlimsPoint) { 0, 0 }, &white, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 255,
         "deselecting the channel returns fills to the layer");
  api->image_undo (engine, image);   /* the layer fill */
  api->channel_command (engine, image, saved, GLIMS_CHANNEL_SELECT, NULL, NULL);

  /* Channel attributes: name, overlay visibility and color. New
   * channels append to the list's end; find rows by id. */
  change.struct_size = sizeof change;
  change.properties  = GLIMS_CHANNEL_NAME;
  strcpy (change.name, "Renamed");
  before = undo_depth (image);
  CHECK (api->channel_change (engine, image, saved, &change, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "renaming a channel is one undo step");
  {
    bool renamed = false;

    api->image_channels (engine, image, rows, 8, &count);
    for (int32_t i = 0; i < count && i < 8; i++)
      renamed |= rows[i].id == saved && strcmp (rows[i].name, "Renamed") == 0;
    CHECK (renamed, "the row carries the new name");
  }
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK, "the rename step exists");
  {
    bool named = false;

    api->image_channels (engine, image, rows, 8, &count);
    for (int32_t i = 0; i < count && i < 8; i++)
      named |= rows[i].id == saved && strcmp (rows[i].name, "Saved") == 0;
    CHECK (named, "the rename undoes");
  }
  memset (&change, 0, sizeof change);
  change.struct_size = sizeof change;
  change.properties  = GLIMS_CHANNEL_VISIBLE | GLIMS_CHANNEL_COLOR | GLIMS_CHANNEL_OPACITY;
  change.visible     = true;
  change.color       = (GlimsColor) { 0, 0, 1, 0.6 };
  change.opacity     = 0.6;
  /* A visible channel composites its color over the masked-out region
   * (the channel inherits show_masked from the selection): where the
   * coverage is low the overlay tints, where it covers the composite is
   * untouched. */
  CHECK (api->channel_change (engine, image, saved, &change, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 4, 4, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[2] > 0 && pixel[0] < 255 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0,
         "a visible channel tints the composite over its masked-out area (%d,%d,%d)",
         pixel[0], pixel[1], pixel[2]);
  {
    bool attrs = false;

    api->image_channels (engine, image, rows, 8, &count);
    for (int32_t i = 0; i < count && i < 8; i++)
      attrs |= rows[i].id == saved && rows[i].visible &&
               rows[i].opacity > 0.5 && rows[i].opacity < 0.7 &&
               rows[i].color.blue > 0.9;
    CHECK (attrs, "the row reports visibility, opacity and color");
  }
  memset (&change, 0, sizeof change);
  change.struct_size = sizeof change;
  change.properties  = GLIMS_CHANNEL_VISIBLE;
  change.visible     = false;
  CHECK (api->channel_change (engine, image, saved, &change, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 4, 4, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[2] == 0,
         "hiding the channel restores the composite");
  memset (&change, 0, sizeof change);
  CHECK (api->channel_change (engine, image, saved, &change, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->channel_change (engine, image, saved, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "channel changes refuse an empty struct and a NULL change");
  change.struct_size = sizeof change;
  change.properties  = 16;
  CHECK (api->channel_change (engine, image, saved, &change, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "channel changes refuse unknown property bits");

  /* Duplicate copies coverage and selects the copy; delete removes as
   * one undo step each. */
  before = undo_depth (image);
  CHECK (api->channel_command (engine, image, saved, GLIMS_CHANNEL_DUPLICATE, &dup, NULL) == GLIMS_STATUS_OK &&
         dup > 0 && undo_depth (image) == before + 1 &&
         api->image_channels (engine, image, rows, 8, &count) == GLIMS_STATUS_OK && count == 3,
         "duplicating a channel is one undo step");
  {
    bool selected = false, old_unselected = true;

    for (int32_t i = 0; i < count && i < 8; i++)
      {
        if (rows[i].id == dup)
          selected = rows[i].selected;
        else
          old_unselected &= ! rows[i].selected;
      }
    CHECK (selected && old_unselected,
           "the copy is added selected, the rest unselected");
  }
  CHECK (api->drawable_thumbnail (engine, image, dup, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(6 * w + 8) * 4] > 200,
         "the copy carries the channel's coverage");
  CHECK (api->channel_command (engine, image, dup, GLIMS_CHANNEL_DELETE, NULL, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 2 &&
         api->image_channels (engine, image, rows, 8, &count) == GLIMS_STATUS_OK && count == 2,
         "deleting a channel is one undo step");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_channels (engine, image, rows, 8, &count) == GLIMS_STATUS_OK && count == 3 &&
         api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_channels (engine, image, rows, 8, &count) == GLIMS_STATUS_OK && count == 2,
         "undo restores the deleted channel, then the duplicate's add");
  api->channel_command (engine, image, saved, GLIMS_CHANNEL_SELECT, NULL, NULL);

  /* Component changes unselect the channel, back to layers — but only
   * when a flag actually changes, so deactivate alpha first. */
  {
    bool still_selected = false;

    api->image_set_components (engine, image,
                               GLIMS_COMPONENT_ALPHA, 0, 0, 0, NULL);
    api->image_channels (engine, image, rows, 8, &count);
    for (int32_t i = 0; i < count && i < 8; i++)
      still_selected |= rows[i].selected;
    api->image_set_components (engine, image,
                               GLIMS_COMPONENT_ALPHA, GLIMS_COMPONENT_ALPHA, 0, 0, NULL);
    CHECK (! still_selected, "changing components unselects the channel, back to layers");
  }
  api->channel_command (engine, image, saved, GLIMS_CHANNEL_SELECT, NULL, NULL);

  /* Wrong ids: layers, layer masks, foreign channels, unknown ids. */
  change.properties = GLIMS_CHANNEL_VISIBLE;
  api->layer_mask_add (engine, image, layer, GLIMS_MASK_WHITE, false, &mask, NULL);
  api->image_new (engine, 8, 8, &other, NULL);
  CHECK (api->channel_to_selection (engine, image, layer, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->channel_to_selection (engine, image, mask, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->channel_change (engine, image, layer, &change, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->channel_command (engine, image, layer, GLIMS_CHANNEL_DELETE, NULL, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->channel_command (engine, image, 7777, GLIMS_CHANNEL_SELECT, NULL, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->channel_from_selection (engine, 9999, "x", NULL, NULL) == GLIMS_STATUS_NOT_FOUND,
         "layer, mask, unknown and foreign ids are refused");
  {
    GlimsItemID fchan = 0;
    api->select_command (engine, other, GLIMS_SELECT_ALL, 0, NULL);
    api->channel_from_selection (engine, other, "Foreign", &fchan, NULL);
    CHECK (api->channel_command (engine, image, fchan, GLIMS_CHANNEL_DELETE, NULL, NULL) == GLIMS_STATUS_NOT_FOUND &&
           api->channel_to_selection (engine, image, fchan, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_NOT_FOUND,
           "a foreign channel id is refused");
  }
  api->image_close (engine, other);
  other = 0;

  /* Channels take filters too; commit policies live in
   * test_drawable_filters. */
  CHECK (api->filter_begin (engine, image, saved, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK &&
         filter > 0 && api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "a filter session opens on a channel and aborts cleanly");
  filter = 0;

  /* Mutations report BUSY during a stroke or a preview; reads and
   * selection stay allowed. */
  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK,
         "a stroke begins for the busy checks");
  CHECK (api->channel_from_selection (engine, image, "x", NULL, NULL) == GLIMS_STATUS_BUSY &&
         api->channel_change (engine, image, saved, &change, NULL) == GLIMS_STATUS_BUSY &&
         api->channel_command (engine, image, saved, GLIMS_CHANNEL_DUPLICATE, NULL, NULL) == GLIMS_STATUS_BUSY &&
         api->channel_command (engine, image, saved, GLIMS_CHANNEL_DELETE, NULL, NULL) == GLIMS_STATUS_BUSY &&
         api->channel_to_selection (engine, image, saved, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_BUSY &&
         api->image_set_components (engine, image, GLIMS_COMPONENT_ALPHA, 0, 0, 0, NULL) == GLIMS_STATUS_BUSY &&
         api->image_set_quick_mask (engine, image, true, NULL) == GLIMS_STATUS_BUSY,
         "channel and component writes report BUSY during a stroke");
  CHECK (api->image_channels (engine, image, rows, 8, &count) == GLIMS_STATUS_OK &&
         api->image_components (engine, image, &comp) == GLIMS_STATUS_OK &&
         api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK &&
         api->channel_command (engine, image, saved, GLIMS_CHANNEL_SELECT, NULL, NULL) == GLIMS_STATUS_OK,
         "reads and channel selection still work during the stroke");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK,
         "the refusals left the stroke alive");
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK &&
         api->channel_from_selection (engine, image, "x", NULL, NULL) == GLIMS_STATUS_BUSY &&
         api->image_set_quick_mask (engine, image, true, NULL) == GLIMS_STATUS_BUSY &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "channel changes report BUSY during a preview, and abort works");

  /* XCF keeps the saved channels and their coverage. */
  snprintf (xcf, sizeof xcf, "%s/channels.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
         api->image_channels (engine, reopened, rows, 8, &count) == GLIMS_STATUS_OK &&
         count == 2,
         "an XCF round trip keeps the channels (%d)", count);
  {
    bool found = false;

    for (int32_t i = 0; i < count && i < 8; i++)
      if (strcmp (rows[i].name, "Saved") == 0 &&
          api->drawable_thumbnail (engine, reopened, rows[i].id, 16, thumb,
                                   sizeof thumb, &w, &h) == GLIMS_STATUS_OK)
        found = thumb[(6 * w + 8) * 4] > 200;
    CHECK (found, "the channels keep their names and their coverage");
  }
  api->image_close (engine, reopened);
  reopened = 0;

  /* The Quick Mask moves the selection into its own channel and selects
   * it; while on, the selection itself is empty. */
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                     (GlimsPoint[]) { { 8, 8 }, { 24, 20 } }, 2, &rect_opt);
  CHECK (api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK &&
         ! qstate.enabled && qstate.channel == 0,
         "the Quick Mask starts off with no channel");
  before = undo_depth (image);
  CHECK (api->image_set_quick_mask (engine, image, true, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK &&
         qstate.enabled && qstate.channel > 0 &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK && empty,
         "enabling the Quick Mask moves the selection into its channel");
  qm = qstate.channel;
  {
    bool qm_row = false;

    api->image_channels (engine, image, rows, 8, &count);
    for (int32_t i = 0; i < count && i < 8; i++)
      qm_row |= rows[i].id == qm && rows[i].quick_mask && rows[i].selected;
    CHECK (count == 3 && qm_row,
           "the Quick Mask's channel lists as selected with its flag");
  }
  CHECK (api->drawable_thumbnail (engine, image, qm, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(6 * w + 8) * 4] > 200 && thumb[(1 * w + 1) * 4] < 60,
         "the Quick Mask channel holds the selection's coverage");
  CHECK (api->channel_command (engine, image, qm, GLIMS_CHANNEL_DELETE, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "the Quick Mask's channel cannot be deleted");

  /* Painting the Quick Mask channel narrows the selection it becomes. */
  CHECK (stroke_line (image, qm, &brush, 10, 6, 10, 22, NULL) == GLIMS_STATUS_OK,
         "painting the Quick Mask channel works");
  CHECK (api->image_set_quick_mask (engine, image, false, NULL) == GLIMS_STATUS_OK &&
         api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK &&
         ! qstate.enabled && qstate.channel == 0 &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && bounds.x > 8 && bounds.width < 16,
         "disabling the Quick Mask turns the painted mask into the selection");
  /* The previously selected channel comes back as the edit target. */
  {
    bool restored = false;

    api->image_channels (engine, image, rows, 8, &count);
    for (int32_t i = 0; i < count && i < 8; i++)
      restored |= rows[i].id == saved && rows[i].selected;
    CHECK (count == 2 && restored,
           "disabling restores the saved channel as the edit target");
  }
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK &&
         ! qstate.enabled &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 8, 8, 16, 12),
         "undoing the toggle, the stroke and the mask restores the selection");
  CHECK (api->image_set_quick_mask (engine, image, true, NULL) == GLIMS_STATUS_OK &&
         api->image_set_quick_mask (engine, image, true, NULL) == GLIMS_STATUS_OK &&
         api->image_set_quick_mask (engine, image, false, NULL) == GLIMS_STATUS_OK,
         "re-toggling to the same state adds nothing");

  /* The engine finds the Quick Mask's channel by the reserved name
   * "Qmask", not by identity: adding or renaming a channel to it turns
   * the mask on, and renaming the mask's channel away strands the mode.
   * The name is refused for ordinary channels before anything mutates. */
  {
    GlimsItemID reserved = 0;

    before = undo_depth (image);
    CHECK (api->channel_from_selection (engine, image, "Qmask", &reserved, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
           reserved == 0 && error &&
           api->image_channels (engine, image, rows, 8, &count) == GLIMS_STATUS_OK && count == 2 &&
           api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK && ! qstate.enabled &&
           undo_depth (image) == before,
           "the reserved name refuses Save to Channel without side effects (%s)",
           error ? error : "");
    api->free_string (error);
    error = NULL;
    CHECK (api->channel_from_selection (engine, image, "Qmask ", &reserved, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
           reserved == 0 &&
           api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
           ! empty && rect_equals (bounds, 8, 8, 16, 12),
           "trailing space still names the reserved channel, selection untouched");

    memset (&change, 0, sizeof change);
    change.struct_size = sizeof change;
    change.properties  = GLIMS_CHANNEL_NAME;
    strcpy (change.name, "Qmask");
    CHECK (api->channel_change (engine, image, saved, &change, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
           error && undo_depth (image) == before,
           "renaming an ordinary channel to the reserved name is refused (%s)", error ? error : "");
    api->free_string (error);
    error = NULL;
  }
  {
    bool kept = false;

    api->image_channels (engine, image, rows, 8, &count);
    for (int32_t i = 0; i < count && i < 8; i++)
      kept |= rows[i].id == saved && strcmp (rows[i].name, "Saved") == 0;
    CHECK (kept, "the refused rename keeps the old name");
  }

  /* While the mask is on its channel cannot be renamed away; an ordinary
   * channel keeps renaming freely. */
  CHECK (api->image_set_quick_mask (engine, image, true, NULL) == GLIMS_STATUS_OK &&
         api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK &&
         qstate.enabled && qstate.channel > 0,
         "the Quick Mask turns on for the rename guards");
  qm = qstate.channel;
  before = undo_depth (image);
  strcpy (change.name, "Elsewhere");
  CHECK (api->channel_change (engine, image, qm, &change, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         error && undo_depth (image) == before,
         "renaming the live Quick Mask channel is refused (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  {
    bool named = false;

    api->image_channels (engine, image, rows, 8, &count);
    for (int32_t i = 0; i < count && i < 8; i++)
      named |= rows[i].id == qm && strcmp (rows[i].name, "Qmask") == 0 && rows[i].quick_mask;
    CHECK (named && count == 3,
           "the mask channel keeps the reserved name and stays the mask (%d)", count);
  }
  strcpy (change.name, "Qmask");
  CHECK (api->channel_change (engine, image, qm, &change, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before,
         "renaming the mask channel to its own name is a no-op");
  CHECK (api->channel_change (engine, image, saved, &change, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "the reserved name stays refused for ordinary channels while the mask is on");
  CHECK (api->channel_from_selection (engine, image, "Qmask", NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "and for a new channel while the mask is on");
  strcpy (change.name, "Moved");
  CHECK (api->channel_change (engine, image, saved, &change, NULL) == GLIMS_STATUS_OK,
         "an ordinary channel still renames freely");
  api->image_undo (engine, image);   /* the rename */
  CHECK (api->image_set_quick_mask (engine, image, false, NULL) == GLIMS_STATUS_OK,
         "the mask turns back off after the guards");

  /* Toggling the Quick Mask and the component changes reported
   * CHANNELS_CHANGED along the way. */
  events = atomic_load (&channels_events);
  CHECK (events > 0, "CHANNELS_CHANGED events arrived (%d)", events);

  api->image_close (engine, image);
}

/* Filters on drawables that are not plain layers: a live preview opens
 * and cancels on a layer mask, a saved channel and the Quick Mask's
 * channel; Apply commits each as one undo step. How the pixels last —
 * merged or non-destructive — is the engine's versioning call (layers
 * and 3.2.6+ channels keep the filter, layer masks, the Quick Mask and
 * earlier channels merge); either way the result has to survive undo,
 * redo and an XCF round trip. */
static void
test_drawable_filters (const char *work)
{
  GlimsImageID        image = 0, reopened = 0, other = 0;
  GlimsItemID         layer = 0, mask = 0, saved = 0, qm = 0, foreign = 0;
  GlimsFilterID       filter = 0;
  GlimsQuickMaskState qstate;
  GlimsChannelInfo    rows[8];
  GlimsSelectOptions  rect_opt = { .struct_size = sizeof rect_opt,
                                   .operation = GLIMS_SELECT_REPLACE };
  GlimsFillSettings   red = { .struct_size = sizeof red, .mode = GLIMS_FILL_SELECTION,
                              .color = { 1, 0, 0, 1 }, .opacity = 1 };
  GlimsRect           bounds;
  bool                empty = true;
  int32_t             count = 0, before, w = 0, h = 0;
  uint8_t             pixel[4];
  uint8_t             thumb[256 * 256 * 4];
  char                xcf[1024];

  api->image_new (engine, 32, 24, &image, NULL);
  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &red, NULL);
  api->layer_mask_add (engine, image, layer, GLIMS_MASK_WHITE, true, &mask, NULL);

  /* A mask filter cancels without touching coverage or history. */
  before = undo_depth (image);
  CHECK (api->filter_begin (engine, image, mask, "gegl:value-invert", &filter, NULL) == GLIMS_STATUS_OK &&
         filter > 0,
         "a filter session opens on a layer mask");
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK &&
         undo_depth (image) == before &&
         api->drawable_thumbnail (engine, image, mask, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(6 * w + 8) * 4] > 200,
         "aborting leaves the mask and history alone (%d)", thumb[(6 * w + 8) * 4]);
  filter = 0;

  /* Apply merges the operation into the mask's pixels: white coverage
   * becomes black, the layer drops out of the composite, one undo step. */
  CHECK (api->filter_begin (engine, image, mask, "gegl:value-invert", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, filter, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "a mask filter commits as one undo step (%d -> %d)", before, undo_depth (image));
  filter = 0;
  CHECK (api->drawable_thumbnail (engine, image, mask, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(6 * w + 8) * 4] < 60,
         "the committed mask is black, not white (%d)", thumb[(6 * w + 8) * 4]);
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 255 && pixel[2] == 255,
         "the masked red layer falls out of the composite (%d,%d,%d)",
         pixel[0], pixel[1], pixel[2]);
  CHECK (api->drawable_thumbnail (engine, image, layer, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(6 * w + 8) * 4] > 200 && thumb[(6 * w + 8) * 4 + 1] < 60,
         "the layer's own pixels stayed red");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0,
         "undo restores the white mask and the red composite");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 255,
         "redo merges the inversion again");

  /* The merged mask survives an XCF round trip. */
  snprintf (xcf, sizeof xcf, "%s/mask-filter.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, reopened, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 255 && pixel[2] == 255,
         "the filtered mask persists through save and reopen");
  api->image_close (engine, reopened);
  reopened = 0;

  /* A saved channel keeps its filtered coverage through undo and through
   * XCF — merged into its buffer where channel effects don't serialize
   * (before 3.2.6), a serialized non-destructive effect after. */
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                     (GlimsPoint[]) { { 8, 8 }, { 24, 20 } }, 2, &rect_opt);
  CHECK (api->channel_from_selection (engine, image, "Filtered", &saved, NULL) == GLIMS_STATUS_OK &&
         api->drawable_thumbnail (engine, image, saved, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(6 * w + 8) * 4] > 200 && thumb[(1 * w + 1) * 4] < 60,
         "the channel starts bright inside the selection and dark outside");
  /* A filter works inside the image's selection, on any drawable:
   * select everything so the whole channel is filtered. */
  api->select_command (engine, image, GLIMS_SELECT_ALL, 0, NULL);
  before = undo_depth (image);
  CHECK (api->filter_begin (engine, image, saved, "gegl:value-invert", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, filter, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "a channel filter commits as one undo step (%d -> %d)", before, undo_depth (image));
  filter = 0;
  CHECK (api->drawable_thumbnail (engine, image, saved, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(6 * w + 8) * 4] < 60 && thumb[(1 * w + 1) * 4] > 200,
         "the committed channel's coverage inverted (%d,%d)",
         thumb[(6 * w + 8) * 4], thumb[(1 * w + 1) * 4]);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_thumbnail (engine, image, saved, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(6 * w + 8) * 4] > 200,
         "undo restores the channel's coverage");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_thumbnail (engine, image, saved, 16, thumb, sizeof thumb, &w, &h) == GLIMS_STATUS_OK &&
         thumb[(6 * w + 8) * 4] < 60,
         "redo inverts it again");

  snprintf (xcf, sizeof xcf, "%s/channel-filter.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK,
         "the filtered channel saves and reopens");
  {
    bool inverted = false;

    count = 0;
    api->image_channels (engine, reopened, rows, 8, &count);
    for (int32_t i = 0; i < count && i < 8; i++)
      if (strcmp (rows[i].name, "Filtered") == 0 &&
          api->drawable_thumbnail (engine, reopened, rows[i].id, 16, thumb,
                                   sizeof thumb, &w, &h) == GLIMS_STATUS_OK)
        inverted = thumb[(6 * w + 8) * 4] < 60 && thumb[(1 * w + 1) * 4] > 200;
    CHECK (inverted, "the inverted coverage survives the XCF round trip");
  }
  api->image_close (engine, reopened);
  reopened = 0;

  /* The Quick Mask's channel takes a filter too; Apply merges it so
   * exiting the mask cannot leave a live effect behind. The inverted
   * mask becomes the selection's complement. */
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                     (GlimsPoint[]) { { 8, 8 }, { 24, 20 } }, 2, &rect_opt);
  CHECK (api->image_set_quick_mask (engine, image, true, NULL) == GLIMS_STATUS_OK &&
         api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK &&
         qstate.enabled && qstate.channel > 0,
         "the Quick Mask turns on for its filter");
  qm = qstate.channel;
  before = undo_depth (image);
  CHECK (api->filter_begin (engine, image, qm, "gegl:value-invert", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, filter, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "a Quick Mask filter commits as one undo step (%d -> %d)", before, undo_depth (image));
  filter = 0;
  CHECK (api->image_set_quick_mask (engine, image, false, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 0, 0, 32, 24),
         "exiting turns the inverted mask into the complement selection (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&   /* the mask's exit */
         api->image_undo (engine, image) == GLIMS_STATUS_OK &&   /* the merged filter */
         api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK && qstate.enabled &&
         api->image_set_quick_mask (engine, image, false, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 8, 8, 16, 12),
         "undoing exit and merge restores the original mask (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);

  /* Unknown, detached and foreign ids stay refused; no facade call hands
   * out the image's selection mask. */
  CHECK (api->filter_begin (engine, image, 9999, "gegl:value-invert", &filter, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->filter_begin (engine, 9999, mask, "gegl:value-invert", &filter, NULL) == GLIMS_STATUS_NOT_FOUND,
         "unknown drawable and image ids refuse");
  api->image_new (engine, 8, 8, &other, NULL);
  foreign = first_layer (other);
  CHECK (api->filter_begin (engine, image, foreign, "gegl:value-invert", &filter, NULL) == GLIMS_STATUS_NOT_FOUND,
         "a foreign image's drawable refuses");
  api->image_close (engine, other);
  other = 0;
  CHECK (api->channel_command (engine, image, saved, GLIMS_CHANNEL_DELETE, NULL, NULL) == GLIMS_STATUS_OK,
         "delete the filtered channel");
  CHECK (api->filter_begin (engine, image, saved, "gegl:value-invert", &filter, NULL) == GLIMS_STATUS_NOT_FOUND,
         "the deleted channel stays unreachable while undo holds it");
  api->image_undo (engine, image);   /* the delete */

  api->image_close (engine, image);
}

/* The committed effects on a drawable — the filters test_drawable_filters
 * leaves non-destructive — listed, edited and reordered through
 * drawable_effects, effect_change and effect_command. Two effects that do
 * not commute (an invert and a brightness lift) make every stack change
 * visible in rendered pixels: inverting then lifting is not lifting then
 * inverting. Each mutation is one undo step, undo and redo restore both
 * the pixels and the stack, and the state survives an XCF round trip. */
static void
test_drawable_effects (const char *work)
{
  GlimsImageID        image = 0, reopened = 0, other = 0;
  GlimsItemID         layer = 0, layer2 = 0, mask = 0, group = 0, text = 0, foreign = 0;
  GlimsFilterID       session = 0;
  GlimsStrokeID       stroke = 0;
  GlimsEffectID       invert_id = 0, bright_id = 0, foreign_fx = 0;
  GlimsEffectInfo     rows[4];
  GlimsEffectChange   change;
  GlimsFillSettings   red = { .struct_size = sizeof red, .mode = GLIMS_FILL_SELECTION,
                              .color = { 1, 0, 0, 1 }, .opacity = 1 };
  GlimsBrushSettings  brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 6.0);
  GlimsStrokePoint    point = { 4, 4, 1.0, 0.0, 0.0, 0 };
  GlimsTextSettings   tset = { .struct_size = sizeof tset, .size = 12,
                               .color = { 0, 0, 0, 1 }, .justify = GLIMS_JUSTIFY_LEFT,
                               .antialias = true };
  int32_t             count = 0, before;
  uint8_t             pixel[4];
  char                xcf[1024];
  char               *error = NULL;

  api->image_new (engine, 32, 24, &image, NULL);
  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &red, NULL);

  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 0,
         "a fresh layer has no effects");
  CHECK (api->drawable_effects (engine, image, layer, NULL, 0, &count) == GLIMS_STATUS_OK &&
         count == 0,
         "a count-only call works");
  CHECK (api->drawable_effects (engine, image, layer, rows, -1, &count) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->drawable_effects (engine, image, layer, NULL, 2, &count) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->drawable_effects (engine, image, layer, rows, 2, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->drawable_effects (engine, image, 9999, rows, 2, &count) == GLIMS_STATUS_NOT_FOUND &&
         api->drawable_effects (engine, 9999, layer, rows, 2, &count) == GLIMS_STATUS_NOT_FOUND,
         "bad arguments and ids refuse");

  /* A live preview is on the stack but is not a committed effect. */
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &session, NULL) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 0,
         "an open preview does not list as an effect");
  api->filter_abort (engine, session);
  session = 0;

  /* Invert commits non-destructively; a brighter lift stacks on top of it.
   * The list reads top first, so the newer effect leads. */
  before = undo_depth (image);
  CHECK (api->filter_begin (engine, image, layer, "gegl:invert-linear", &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "the invert commits as one undo step");
  session = 0;
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && rows[0].id > 0 &&
         strcmp (rows[0].name, "Invert") == 0 &&
         strcmp (rows[0].operation, "gegl:invert-linear") == 0 &&
         rows[0].enabled && rows[0].opacity == 1.0,
         "the effect reads its id, name, operation, state and opacity (\"%s\" %s)",
         rows[0].name, rows[0].operation);
  invert_id = rows[0].id;

  CHECK (api->filter_begin (engine, image, layer, "gegl:brightness-contrast", &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, session, "brightness", 0.2) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK,
         "a brighter second effect commits");
  session = 0;
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 2 && rows[0].id != invert_id && rows[1].id == invert_id &&
         strcmp (rows[0].operation, "gegl:brightness-contrast") == 0 &&
         rows[1].enabled && rows[1].opacity == 1.0,
         "the newer effect tops the list (%s over %s)", rows[0].operation, rows[1].operation);
  bright_id = rows[0].id;
  CHECK (api->drawable_effects (engine, image, layer, rows, 1, &count) == GLIMS_STATUS_OK &&
         count == 2 && rows[0].id == bright_id,
         "a short buffer truncates rows but keeps the full count");

  /* Bottom first: invert the red layer to cyan, then lift it — a pale
   * cyan. Raising the invert lifts first, then inverts — a dark cyan. */
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 100 && pixel[0] < 150 && pixel[1] > 225 && pixel[2] > 225,
         "invert-then-lift renders a pale cyan (%d,%d,%d)", pixel[0], pixel[1], pixel[2]);

  before = undo_depth (image);
  CHECK (api->effect_command (engine, image, layer, invert_id, GLIMS_EFFECT_RAISE, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         rows[0].id == invert_id && rows[1].id == bright_id,
         "raising the invert swaps the stack in one undo step");
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] < 30 && pixel[1] > 200 && pixel[1] < 245 && pixel[2] > 200 && pixel[2] < 245,
         "lift-then-invert renders a dark cyan (%d,%d,%d)", pixel[0], pixel[1], pixel[2]);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         rows[0].id == bright_id && rows[1].id == invert_id &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 100 && pixel[0] < 150 && pixel[1] > 225,
         "undo restores both the order and the pixels");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         rows[0].id == invert_id &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] < 30 && pixel[1] > 200 && pixel[1] < 245,
         "redo applies the raise again");

  /* Moves that are already satisfied are free of charge. */
  before = undo_depth (image);
  CHECK (api->effect_command (engine, image, layer, invert_id, GLIMS_EFFECT_TO_TOP, NULL) == GLIMS_STATUS_OK &&
         api->effect_command (engine, image, layer, bright_id, GLIMS_EFFECT_LOWER, NULL) == GLIMS_STATUS_OK &&
         api->effect_command (engine, image, layer, bright_id, GLIMS_EFFECT_TO_BOTTOM, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before,
         "already-satisfied moves leave no undo step");
  CHECK (api->effect_command (engine, image, layer, invert_id, GLIMS_EFFECT_TO_BOTTOM, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         rows[0].id == bright_id && rows[1].id == invert_id,
         "a real move still costs one step");
  api->image_undo (engine, image);   /* invert back on top */

  /* Disabling the bottom lift leaves the invert alone: pure cyan. */
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_ENABLED,
                                 .enabled = false };
  before = undo_depth (image);
  CHECK (api->effect_change (engine, image, layer, bright_id, &change, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         ! rows[1].enabled,
         "disabling the lift is one undo step");
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] < 30 && pixel[1] > 225 && pixel[2] > 225,
         "the disabled lift drops out of the render (%d,%d,%d)", pixel[0], pixel[1], pixel[2]);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         rows[1].enabled &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[1] > 200 && pixel[1] < 245,
         "undo re-enables it and restores the pixels");
  api->image_redo (engine, image);
  api->image_undo (engine, image);   /* land back on both enabled */

  /* Half-opacity invert over the lifted red lands on middle gray; a
   * rename rides in the same undo step. */
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_NAME | GLIMS_EFFECT_OPACITY,
                                 .opacity = 0.5 };
  strcpy (change.name, "Half Invert");
  before = undo_depth (image);
  CHECK (api->effect_change (engine, image, layer, invert_id, &change, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         strcmp (rows[0].name, "Half Invert") == 0 && rows[0].opacity == 0.5,
         "rename and opacity share one undo step");
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 160 && pixel[0] < 215 &&
         abs (pixel[0] - pixel[1]) < 15 && abs (pixel[1] - pixel[2]) < 15,
         "the half-strength invert renders a middle gray (%d,%d,%d)",
         pixel[0], pixel[1], pixel[2]);

  snprintf (xcf, sizeof xcf, "%s/effects.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK,
         "the effects save and reopen");
  if (reopened)
    {
      GlimsLayerInfo rrow;

      CHECK (api->image_layers (engine, reopened, &rrow, 1, &count) == GLIMS_STATUS_OK &&
             api->drawable_effects (engine, reopened, rrow.id, rows, 4, &count) == GLIMS_STATUS_OK &&
             count == 2 &&
             strcmp (rows[0].name, "Half Invert") == 0 && rows[0].enabled &&
             rows[0].opacity == 0.5 && strcmp (rows[0].operation, "gegl:invert-linear") == 0 &&
             strcmp (rows[1].operation, "gegl:brightness-contrast") == 0 &&
             rows[1].enabled && rows[1].opacity == 1.0,
             "the XCF round trip keeps the stack's order and state (%d)", count);
      api->image_close (engine, reopened);
      reopened = 0;
    }

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         strcmp (rows[0].name, "Invert") == 0 && rows[0].opacity == 1.0 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] < 30 && pixel[1] > 200 && pixel[1] < 245,
         "undo restores the default name, full strength and the pixels");
  api->image_redo (engine, image);
  api->image_undo (engine, image);

  /* A change that asks for the current state costs nothing. */
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_ENABLED | GLIMS_EFFECT_OPACITY,
                                 .enabled = true, .opacity = 1.0 };
  before = undo_depth (image);
  CHECK (api->effect_change (engine, image, layer, invert_id, &change, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before,
         "restating the current state adds no undo step");
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_OPACITY,
                                 .opacity = NAN };
  CHECK (api->effect_change (engine, image, layer, invert_id, &change, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == before,
         "a non-finite opacity refuses without a step");
  change.opacity = 1.5;
  CHECK (api->effect_change (engine, image, layer, invert_id, &change, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an out-of-range opacity refuses");
  change = (GlimsEffectChange) { .struct_size = 4, .properties = GLIMS_EFFECT_ENABLED };
  CHECK (api->effect_change (engine, image, layer, invert_id, &change, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->effect_change (engine, image, layer, invert_id, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a bad change struct refuses");
  change = (GlimsEffectChange) { .struct_size = sizeof change, .properties = 1 << 6 };
  CHECK (api->effect_change (engine, image, layer, invert_id, &change, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "unknown property bits refuse");
  CHECK (api->effect_command (engine, image, layer, invert_id, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->effect_command (engine, image, layer, invert_id, 99, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "unknown commands refuse");
  CHECK (undo_depth (image) == before, "refusals leave history alone");

  /* Removing the bottom effect leaves the invert on the plain red: cyan.
   * Undo brings the same effect back in the same place. */
  before = undo_depth (image);
  CHECK (api->effect_command (engine, image, layer, bright_id, GLIMS_EFFECT_REMOVE, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && rows[0].id == invert_id,
         "removing the lift is one undo step");
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] < 30 && pixel[1] > 225 && pixel[2] > 225,
         "the invert alone renders cyan (%d,%d,%d)", pixel[0], pixel[1], pixel[2]);
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_ENABLED,
                                 .enabled = false };
  CHECK (api->effect_change (engine, image, layer, bright_id, &change, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->effect_command (engine, image, layer, bright_id, GLIMS_EFFECT_RAISE, NULL) == GLIMS_STATUS_NOT_FOUND,
         "the removed effect's id is dead even while undo holds it");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 2 && rows[0].id == invert_id && rows[1].id == bright_id &&
         rows[1].enabled && rows[1].opacity == 1.0 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] < 30 && pixel[1] > 200 && pixel[1] < 245,
         "undo restores the effect with its id, state and place");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK && count == 1,
         "redo removes it again");
  api->image_undo (engine, image);

  /* Merging the bottom effect bakes it into the pixels: the composite
   * stays identical because it was applied first anyway, the stack keeps
   * the invert, and undo restores both pixels and the whole stack. */
  before = undo_depth (image);
  CHECK (api->effect_command (engine, image, layer, bright_id, GLIMS_EFFECT_MERGE, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && rows[0].id == invert_id,
         "merging the bottom effect is one undo step");
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] < 30 && pixel[1] > 200 && pixel[1] < 245 && pixel[2] > 200 && pixel[2] < 245,
         "the merged composite is unchanged (%d,%d,%d)", pixel[0], pixel[1], pixel[2]);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 2 && rows[0].id == invert_id && rows[1].id == bright_id &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] < 30 && pixel[1] > 200 && pixel[1] < 245,
         "undo restores the pixels and the stack");
  api->image_redo (engine, image);

  /* Merging the last effect empties the stack; undo brings it back. */
  CHECK (api->effect_command (engine, image, layer, invert_id, GLIMS_EFFECT_MERGE, NULL) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 0,
         "merging the last effect empties the stack");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && rows[0].id == invert_id,
         "undo restores the merged effect");
  api->image_undo (engine, image);   /* unmerge the lift too */
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 2 && rows[0].id == invert_id && rows[1].id == bright_id,
         "both effects are back");

  /* Wrong drawables, foreign effects and stale ids all refuse. */
  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer2, NULL);
  api->layer_mask_add (engine, image, layer, GLIMS_MASK_WHITE, true, &mask, NULL);
  CHECK (api->drawable_effects (engine, image, mask, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 0,
         "a layer mask lists no committed effects");
  CHECK (api->drawable_effects (engine, image, layer2, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 0,
         "the untouched layer lists none");
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_ENABLED,
                                 .enabled = false };
  CHECK (api->effect_change (engine, image, layer2, invert_id, &change, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->effect_change (engine, image, mask, invert_id, &change, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->effect_change (engine, image, layer, 9999, &change, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->effect_command (engine, image, layer2, invert_id, GLIMS_EFFECT_RAISE, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->effect_command (engine, image, layer, 9999, GLIMS_EFFECT_REMOVE, NULL) == GLIMS_STATUS_NOT_FOUND,
         "foreign drawables and unknown effect ids refuse");
  api->image_new (engine, 8, 8, &other, NULL);
  foreign = first_layer (other);
  api->filter_begin (engine, other, foreign, "gegl:invert-linear", &session, NULL);
  api->filter_commit (engine, session, NULL);
  session = 0;
  CHECK (api->drawable_effects (engine, other, foreign, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1,
         "the other image keeps its own effect");
  foreign_fx = rows[0].id;
  CHECK (api->effect_command (engine, image, layer, foreign_fx, GLIMS_EFFECT_REMOVE, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->effect_change (engine, image, layer, foreign_fx, &change, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->effect_command (engine, image, foreign, invert_id, GLIMS_EFFECT_RAISE, NULL) == GLIMS_STATUS_NOT_FOUND,
         "another image's effect and drawable refuse here");
  api->image_close (engine, other);
  other = 0;
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 2 && rows[0].id == invert_id && rows[1].id == bright_id,
         "the refusals changed nothing");

  /* Writes block while a stroke or a filter preview owns the image; the
   * read stays available. */
  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK &&
         api->effect_change (engine, image, layer, invert_id, &change, NULL) == GLIMS_STATUS_BUSY &&
         api->effect_command (engine, image, layer, invert_id, GLIMS_EFFECT_RAISE, NULL) == GLIMS_STATUS_BUSY &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 2,
         "effect writes report BUSY during a stroke while the list still reads");
  api->stroke_end (engine, stroke);
  stroke = 0;
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &session, NULL) == GLIMS_STATUS_OK &&
         api->effect_change (engine, image, layer, invert_id, &change, NULL) == GLIMS_STATUS_BUSY &&
         api->effect_command (engine, image, layer, invert_id, GLIMS_EFFECT_RAISE, NULL) == GLIMS_STATUS_BUSY &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 2 && rows[0].id == invert_id,
         "effect writes report BUSY during a preview while the list still reads");
  api->filter_abort (engine, session);
  session = 0;

  /* A pixel lock protects merge but not metadata edits. */
  CHECK (api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL) == GLIMS_STATUS_OK &&
         api->effect_command (engine, image, layer, bright_id, GLIMS_EFFECT_MERGE, NULL) == GLIMS_STATUS_LOCKED &&
         api->effect_change (engine, image, layer, invert_id, &change, NULL) == GLIMS_STATUS_OK &&
         api->effect_command (engine, image, layer, invert_id, GLIMS_EFFECT_LOWER, NULL) == GLIMS_STATUS_OK &&
         api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, 0, NULL) == GLIMS_STATUS_OK,
         "a pixel lock refuses merge while edits and moves still work");
  api->image_undo (engine, image);   /* the lower */
  api->image_undo (engine, image);   /* the enable-change */
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 2 && rows[0].id == invert_id && rows[1].enabled,
         "the lock test leaves the stack as it was");

  /* Groups and text hold structured content: merge refuses it while
   * remove and reorder stay legal metadata work. */
  api->create_group (engine, image, 0, 0, "Group", &group, NULL);
  CHECK (api->filter_begin (engine, image, group, "gegl:invert-linear", &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, group, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1,
         "a group layer takes an effect");
  session = 0;
  before = undo_depth (image);
  CHECK (api->effect_command (engine, image, group, rows[0].id, GLIMS_EFFECT_MERGE, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == before &&
         api->drawable_effects (engine, image, group, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1,
         "merge refuses a group's structured pixels%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->effect_command (engine, image, group, rows[0].id, GLIMS_EFFECT_REMOVE, NULL) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, group, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 0,
         "removing a group's effect is allowed");

  strcpy (tset.font, "Sans-serif");
  if (api->text_layer_new (engine, image, "Hi", &tset, (GlimsPoint) { 2, 2 }, &text, NULL) == GLIMS_STATUS_OK &&
      api->filter_begin (engine, image, text, "gegl:invert-linear", &session, NULL) == GLIMS_STATUS_OK &&
      api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK)
    {
      session = 0;
      before = undo_depth (image);
      CHECK (api->drawable_effects (engine, image, text, rows, 4, &count) == GLIMS_STATUS_OK &&
             count == 1 && rows[0].enabled,
             "the text layer lists its committed effect");
      CHECK (api->effect_command (engine, image, text, rows[0].id, GLIMS_EFFECT_MERGE, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
             "merge refuses a text layer's editable content%s%s",
             error ? ": " : "", error ? error : "");
      CHECK (undo_depth (image) == before &&
             api->drawable_effects (engine, image, text, rows, 4, &count) == GLIMS_STATUS_OK &&
             count == 1 && rows[0].enabled,
             "the refused merge changed nothing");
      api->free_string (error);
      error = NULL;
      api->layer_command (engine, image, text, GLIMS_LAYER_DELETE, NULL, NULL);
    }
  else
    {
      CHECK (false, "a text layer with a committed effect is required here");
    }

  api->image_close (engine, image);
}

/* Editing a committed effect's parameters through a live session
 * (filter_edit_begin): the session reads the effect's own properties
 * and previews new ones through the effect's captured mask at its stack
 * slot, commit writes them back into the same effect as one undo step,
 * abort restores it untouched. On mid gray (sRGB ~0.216 linear):
 * gegl:brightness-contrast adds its brightness to each linear channel
 * and gegl:value-invert complements the gamma value, so a +0.2 lift is
 * ~173, -0.2 ~34, +0.4 ~208; invert->lift->invert is ~84. */
static void
test_filter_edit_history_gate (void)
{
  GlimsImageID image = 0;
  GlimsLayerInfo layer;
  GlimsEffectInfo effect;
  GlimsFilterID session = 0;
  GlimsEffectID effect_id;
  int32_t count = 0;

  api->image_new (engine, 16, 16, &image, NULL);
  api->image_layers (engine, image, &layer, 1, &count);
  api->filter_begin (engine, image, layer.id, "gegl:brightness-contrast", &session, NULL);
  api->filter_set_double (engine, session, "brightness", -0.1);
  api->filter_commit (engine, session, NULL);
  api->drawable_effects (engine, image, layer.id, &effect, 1, &count);
  effect_id = effect.id;
  api->filter_edit_begin (engine, image, layer.id, effect_id, &session, NULL);
  api->filter_set_double (engine, session, "brightness", -0.2);

  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_BUSY,
         "raw redo refuses during an effect edit, even with an empty redo stack");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_BUSY,
         "raw undo cannot detach the effect being edited");
  CHECK (api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer.id, &effect, 1, &count) == GLIMS_STATUS_OK &&
         count == 1 && effect.id == effect_id,
         "commit after refused history commands keeps the edited effect reachable");
  api->image_close (engine, image);
}

static void
test_filter_edit (const char *work)
{
  GlimsImageID       image = 0, reopened = 0, other = 0;
  GlimsItemID        layer = 0, layer2 = 0, foreign = 0;
  GlimsFilterID      session = 0, second = 0;
  GlimsEffectID      fx_id = 0, inv_id = 0, bright_id = 0, top_id = 0, foreign_fx = 0;
  GlimsEffectInfo    rows[4];
  GlimsEffectChange  change;
  GlimsFilterValue   value;
  GlimsSelectOptions rect_opt = { .struct_size = sizeof rect_opt,
                                  .operation = GLIMS_SELECT_REPLACE };
  GlimsFillSettings  gray = { .struct_size = sizeof gray, .mode = GLIMS_FILL_SELECTION,
                              .color = { 128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, 1 },
                              .opacity = 1 };
  GlimsRect          bounds;
  bool               empty = true;
  int32_t            count = 0, before;
  uint8_t            pixel[4];
  char               xcf[1024];
  char               blocked[1024];

  api->image_new (engine, 32, 24, &image, NULL);
  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &gray, NULL);

  /* A lift committed while a rectangle is selected keeps that selection
   * as its own mask: ~173 inside, the untouched 128 outside. */
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                     (GlimsPoint[]) { { 8, 8 }, { 24, 20 } }, 2, &rect_opt);
  CHECK (api->filter_begin (engine, image, layer, "gegl:brightness-contrast", &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, session, "brightness", 0.2) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK,
         "a masked lift commits inside the selected rectangle");
  session = 0;
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK && count == 1,
         "one committed effect");
  fx_id = rows[0].id;
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 12, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 155 && pixel[0] < 195 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 4, 4, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 120 && pixel[0] < 136,
         "the captured mask gates the committed render (%d, %d)",
         pixel[0], 0);

  /* Selecting a different rectangle must not move the mask. */
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                     (GlimsPoint[]) { { 26, 2 }, { 31, 7 } }, 2, &rect_opt);

  CHECK (api->filter_edit_begin (engine, image, layer, fx_id, &session, NULL) == GLIMS_STATUS_OK &&
         session > 0 && session != fx_id,
         "an edit session opens on the committed effect");
  value = (GlimsFilterValue) { 0 };
  CHECK (api->filter_get_property (engine, session, "brightness", &value) == GLIMS_STATUS_OK &&
         value.kind == GLIMS_FILTER_VALUE_NUMBER && fabs (value.number - 0.2) < 0.001,
         "the session reads the effect's own parameter (%f)", value.number);
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && rows[0].id == fx_id,
         "the open edit session adds no committed effect");

  /* The shadow previews through the effect's own mask: the dim covers
   * the committed rectangle only — the live selection's corner and the
   * rest of the image stay 128. */
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = -0.2 };
  CHECK (api->filter_set_property (engine, session, "brightness", &value) == GLIMS_STATUS_OK,
         "the typed property setter writes on an edit session");
  {
    uint8_t p_in[4], p_sel[4], p_out[4];

    api->image_render (engine, image, 1.0, (GlimsRect) { 12, 12, 1, 1 }, p_in, 4);
    api->image_render (engine, image, 1.0, (GlimsRect) { 28, 4, 1, 1 }, p_sel, 4);
    api->image_render (engine, image, 1.0, (GlimsRect) { 4, 4, 1, 1 }, p_out, 4);
    CHECK (p_in[0] > 15 && p_in[0] < 60 && p_sel[0] > 120 && p_sel[0] < 136 && p_out[0] > 120 && p_out[0] < 136,
           "the preview honors the effect's mask, not the live selection (%d %d %d)",
           p_in[0], p_sel[0], p_out[0]);
  }

  before = undo_depth (image);
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_ENABLED, .enabled = false };
  CHECK (api->filter_edit_begin (engine, image, layer, fx_id, &second, NULL) == GLIMS_STATUS_BUSY &&
         second == 0 &&
         api->effect_change (engine, image, layer, fx_id, &change, NULL) == GLIMS_STATUS_BUSY &&
         api->effect_command (engine, image, layer, fx_id, GLIMS_EFFECT_RAISE, NULL) == GLIMS_STATUS_BUSY &&
         api->image_history_move (engine, image, 0, 0, NULL) == GLIMS_STATUS_BUSY,
         "edits, moves and history refuse while the preview is open");
  snprintf (blocked, sizeof blocked, "%s/edit-preview.xcf", work);
  CHECK (api->image_save (engine, image, blocked, NULL) == GLIMS_STATUS_BUSY &&
         access (blocked, F_OK) != 0,
         "save refuses while the edit preview is open");

  CHECK (api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "the edit commits as one undo step (%d -> %d)", before, undo_depth (image));
  session = 0;
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && rows[0].id == fx_id && rows[0].enabled &&
         strcmp (rows[0].operation, "gegl:brightness-contrast") == 0,
         "the effect keeps its id, slot and enabled state");
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 12, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 15 && pixel[0] < 60 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 28, 4, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 120 && pixel[0] < 136,
         "the committed edit renders through the effect's own mask");
  CHECK (api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 26, 2, 5, 5),
         "the edit left the image's selection alone (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 12, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 155 && pixel[0] < 195 &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 28, 4, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 120 && pixel[0] < 136,
         "undo restores the old parameter and its masked pixels");
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && rows[0].id == fx_id && rows[0].enabled,
         "undo keeps the effect's id and state");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 12, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 15 && pixel[0] < 60,
         "redo replays the parameter edit");
  CHECK (api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 26, 2, 5, 5),
         "undo and redo left the selection alone");

  /* Abort after a committed edit restores the committed parameters. */
  before = undo_depth (image);
  CHECK (api->filter_edit_begin (engine, image, layer, fx_id, &session, NULL) == GLIMS_STATUS_OK,
         "editing again after the commit opens");
  value = (GlimsFilterValue) { 0 };
  CHECK (api->filter_get_property (engine, session, "brightness", &value) == GLIMS_STATUS_OK &&
         fabs (value.number - -0.2) < 0.001,
         "the reopened session reads the committed parameter (%f)", value.number);
  CHECK (api->filter_set_double (engine, session, "brightness", 0.4) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 12, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 195,
         "the next preview renders through the same mask (%d)", pixel[0]);
  CHECK (api->filter_abort (engine, session) == GLIMS_STATUS_OK &&
         undo_depth (image) == before &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 12, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 15 && pixel[0] < 60,
         "abort restores the committed parameter and costs no undo");
  session = 0;
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && rows[0].id == fx_id && rows[0].enabled,
         "abort left the committed effect untouched");

  snprintf (xcf, sizeof xcf, "%s/edited-effect.xcf", work);
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK,
         "the edited effect saves and reopens");
  if (reopened)
    {
      GlimsItemID relayer = first_layer (reopened);

      CHECK (api->drawable_effects (engine, reopened, relayer, rows, 4, &count) == GLIMS_STATUS_OK &&
             count == 1 && strcmp (rows[0].operation, "gegl:brightness-contrast") == 0 &&
             rows[0].enabled &&
             api->image_render (engine, reopened, 1.0, (GlimsRect) { 12, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
             pixel[0] > 15 && pixel[0] < 60 &&
             api->image_render (engine, reopened, 1.0, (GlimsRect) { 4, 4, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
             pixel[0] > 120 && pixel[0] < 136,
             "the XCF round trip keeps the edited parameter and the mask");
      api->image_close (engine, reopened);
      reopened = 0;
    }
  api->image_close (engine, image);
  image = 0;

  /* A stack that does not commute: invert -> lift -> invert. */
  api->image_new (engine, 32, 24, &image, NULL);
  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->fill (engine, image, (GlimsPoint) { 0, 0 }, &gray, NULL);
  CHECK (api->filter_begin (engine, image, layer, "gegl:value-invert", &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK &&
         api->filter_begin (engine, image, layer, "gegl:brightness-contrast", &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, session, "brightness", 0.2) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK &&
         api->filter_begin (engine, image, layer, "gegl:value-invert", &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK,
         "a three-effect stack commits");
  session = 0;
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK && count == 3,
         "three effects list");
  top_id = rows[0].id;
  bright_id = rows[1].id;
  inv_id = rows[2].id;
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 65 && pixel[0] < 105,
         "the stack renders the lifted-then-inverted gray (%d)", pixel[0]);

  /* Editing the middle effect re-renders the whole stack in place. */
  before = undo_depth (image);
  CHECK (api->filter_edit_begin (engine, image, layer, bright_id, &session, NULL) == GLIMS_STATUS_OK,
         "editing the middle effect opens");
  CHECK (api->filter_set_double (engine, session, "brightness", 0.5) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 20 && pixel[0] < 55,
         "the shadow previews at the effect's own slot (%d)", pixel[0]);
  CHECK (api->filter_abort (engine, session) == GLIMS_STATUS_OK &&
         undo_depth (image) == before &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 65 && pixel[0] < 105,
         "abort restores the whole stack exactly");
  session = 0;

  /* Name and opacity edits ride along through a parameter edit. */
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_NAME | GLIMS_EFFECT_OPACITY,
                                 .opacity = 0.75 };
  strcpy (change.name, "Middle Lift");
  CHECK (api->effect_change (engine, image, layer, bright_id, &change, NULL) == GLIMS_STATUS_OK,
         "rename and re-strength the middle effect");

  before = undo_depth (image);
  CHECK (api->filter_edit_begin (engine, image, layer, bright_id, &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, session, "brightness", -0.1) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "editing the middle effect commits in place");
  session = 0;
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 3 && rows[0].id == top_id && rows[1].id == bright_id && rows[2].id == inv_id &&
         strcmp (rows[1].name, "Middle Lift") == 0 && rows[1].opacity == 0.75 && rows[1].enabled,
         "the edited effect keeps its id, slot, name and blend state");
  /* 127 -> -0.1 lift ~93 -> 0.75 blend ~102 -> invert ~153. */
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 135 && pixel[0] < 175,
         "the edited parameter reshapes the composite (%d)", pixel[0]);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 80 && pixel[0] < 115,
         "undo restores the stack's pixels");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 135 && pixel[0] < 175,
         "redo restores the edit");

  /* A disabled effect: the shadow previews its parameters anyway, and
   * the parked state comes back on abort and on commit. */
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_ENABLED, .enabled = false };
  CHECK (api->effect_change (engine, image, layer, bright_id, &change, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 120 && pixel[0] < 136,
         "the disabled effect drops out of the stack (%d)", pixel[0]);
  CHECK (api->filter_edit_begin (engine, image, layer, bright_id, &session, NULL) == GLIMS_STATUS_OK,
         "a disabled effect still opens for editing");
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 135 && pixel[0] < 175,
         "the shadow previews the parked effect's parameters (%d)", pixel[0]);
  CHECK (api->filter_abort (engine, session) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         ! rows[1].enabled &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 120 && pixel[0] < 136,
         "abort hands the disabled state back");
  session = 0;
  before = undo_depth (image);
  CHECK (api->filter_edit_begin (engine, image, layer, bright_id, &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, session, "brightness", 0.1) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 3 && ! rows[1].enabled && rows[1].id == bright_id,
         "committing an edit keeps the effect disabled");
  session = 0;
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 120 && pixel[0] < 136,
         "the disabled committed edit stays out of the render");
  change = (GlimsEffectChange) { .struct_size = sizeof change,
                                 .properties = GLIMS_EFFECT_ENABLED, .enabled = true };
  /* +0.1 lift ~152 -> 0.75 blend ~146 -> invert ~109. */
  CHECK (api->effect_change (engine, image, layer, bright_id, &change, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] > 95 && pixel[0] < 130,
         "re-enabled, the committed parameter renders (%d)", pixel[0]);

  /* Stale, foreign, removed and detached ids all refuse. */
  CHECK (api->filter_edit_begin (engine, image, layer, 9999, &session, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->filter_edit_begin (engine, 9999, layer, bright_id, &session, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->filter_edit_begin (engine, image, layer, bright_id, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "unknown ids and a missing output refuse");
  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer2, NULL);
  CHECK (api->filter_edit_begin (engine, image, layer2, bright_id, &session, NULL) == GLIMS_STATUS_NOT_FOUND,
         "an effect id on the wrong drawable refuses");
  api->image_new (engine, 8, 8, &other, NULL);
  foreign = first_layer (other);
  api->filter_begin (engine, other, foreign, "gegl:value-invert", &session, NULL);
  api->filter_commit (engine, session, NULL);
  session = 0;
  api->drawable_effects (engine, other, foreign, rows, 4, &count);
  foreign_fx = rows[0].id;
  CHECK (api->filter_edit_begin (engine, image, layer, foreign_fx, &session, NULL) == GLIMS_STATUS_NOT_FOUND,
         "another image's effect refuses");
  api->image_close (engine, other);
  other = 0;

  CHECK (api->effect_command (engine, image, layer, top_id, GLIMS_EFFECT_REMOVE, NULL) == GLIMS_STATUS_OK,
         "remove the top effect");
  CHECK (api->filter_edit_begin (engine, image, layer, top_id, &session, NULL) == GLIMS_STATUS_NOT_FOUND,
         "the removed effect's id is dead while undo holds it");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK,
         "undo restores the top effect");

  CHECK (api->layer_command (engine, image, layer, GLIMS_LAYER_DELETE, NULL, NULL) == GLIMS_STATUS_OK &&
         api->filter_edit_begin (engine, image, layer, bright_id, &session, NULL) == GLIMS_STATUS_NOT_FOUND,
         "a detached drawable refuses");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->filter_edit_begin (engine, image, layer, bright_id, &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_abort (engine, session) == GLIMS_STATUS_OK,
         "the restored layer's effect edits again");
  session = 0;

  /* New filters on the same stack are unaffected. */
  CHECK (api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK && count == 3 &&
         api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &session, NULL) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, session, "std-dev-x", 2.0) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, session, "std-dev-y", 2.0) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, session, NULL) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 4,
         "a new filter still commits over the edited stack");
  session = 0;
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->drawable_effects (engine, image, layer, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 3,
         "undo drops it again");

  /* Closing the image releases an unfinished edit session. */
  CHECK (api->filter_edit_begin (engine, image, layer, bright_id, &session, NULL) == GLIMS_STATUS_OK,
         "a last edit session opens");
  CHECK (api->image_close (engine, image) == GLIMS_STATUS_OK &&
         api->filter_abort (engine, session) == GLIMS_STATUS_NOT_FOUND,
         "closing the image releases the edit session");
  session = 0;
  image = 0;
}

/* The qmask-name.xcf fixture (fixtures/README.md): written by GIMP 3.0.8
 * while its Quick Mask was on. The engine finds the mask's channel by
 * the reserved name "Qmask" — any channel added to or renamed to it
 * becomes the mask — so the stored channel resumes as the live mask on
 * open, and the rename guards treat it like a mask the facade made. */
static void
test_qmask_name_fixture (const char *fixtures)
{
  GlimsImageID        image = 0;
  GlimsItemID         qm = 0, saved = 0;
  GlimsQuickMaskState qstate;
  GlimsChannelInfo    rows[8];
  GlimsChannelChange  change = { .struct_size = sizeof change,
                                 .properties = GLIMS_CHANNEL_NAME };
  GlimsRect           bounds;
  bool                empty = true;
  int32_t             count = 0, i;
  char                path[1024];
  char               *error = NULL;

  snprintf (path, sizeof path, "%s/qmask-name.xcf", fixtures);
  CHECK (api->image_open (engine, path, &image, &error) == GLIMS_STATUS_OK && image > 0,
         "the Quick Mask name fixture opens%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  if (! image)
    return;

  CHECK (api->image_quick_mask (engine, image, &qstate) == GLIMS_STATUS_OK &&
         qstate.enabled && qstate.channel > 0,
         "the stored Qmask channel resumes as the live mask on open");
  qm = qstate.channel;
  {
    bool qm_row = false, saved_row = false, other_row = false;

    api->image_channels (engine, image, rows, 8, &count);
    for (i = 0; i < count && i < 8; i++)
      {
        if (rows[i].id == qm)
          qm_row = rows[i].quick_mask && strcmp (rows[i].name, "Qmask") == 0;
        else if (strcmp (rows[i].name, "Saved") == 0)
          {
            saved_row = true;
            saved     = rows[i].id;
          }
        else if (strcmp (rows[i].name, "Other") == 0)
          other_row = true;
      }
    CHECK (count == 3 && qm_row && saved_row && other_row,
           "the rows read the live mask and the two ordinary channels (%d)", count);
  }

  strcpy (change.name, "Elsewhere");
  CHECK (api->channel_change (engine, image, qm, &change, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         error,
         "renaming the adopted mask channel is refused (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  strcpy (change.name, "Qmask");
  CHECK (saved > 0 &&
         api->channel_change (engine, image, saved, &change, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an ordinary channel cannot take the reserved name");
  {
    bool named = false;

    api->image_channels (engine, image, rows, 8, &count);
    for (i = 0; i < count && i < 8; i++)
      named |= rows[i].id == qm && strcmp (rows[i].name, "Qmask") == 0 && rows[i].quick_mask;
    CHECK (named && count == 3, "the refused renames changed nothing");
  }

  /* Exiting converts the fixture's mask to its selection; a normal
   * toggle still works afterwards. */
  CHECK (api->image_set_quick_mask (engine, image, false, NULL) == GLIMS_STATUS_OK &&
         api->image_channels (engine, image, rows, 8, &count) == GLIMS_STATUS_OK && count == 2 &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 10, 8, 20, 16),
         "exiting turns the stored mask into its selection (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);
  CHECK (api->image_set_quick_mask (engine, image, true, NULL) == GLIMS_STATUS_OK &&
         api->image_set_quick_mask (engine, image, false, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty, &bounds) == GLIMS_STATUS_OK &&
         ! empty && rect_equals (bounds, 10, 8, 20, 16),
         "the mask toggles cleanly on a file that arrived with the reserved name");

  api->image_close (engine, image);
}

/* A deleted item lives on in the undo stack until the undo is dropped,
 * still under its id. Calls must not reach it: an edit would change what
 * undoing the delete brings back, outside any undo step. */
static void
test_deleted_items (void)
{
  GlimsImageID       image = 0;
  GlimsItemID        layer = 0, path = 0, text = 0;
  GlimsSubpath       subpath = { .count = 1, .closed = false };
  GlimsPathPoint     point = { { 5, 5 }, { 5, 5 }, { 5, 5 } };
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 5);
  GlimsStrokePoint   first = { 10, 10, 1, 0, 0, 0 };
  GlimsStrokeID      stroke = 0;
  GlimsLayerChange   change = { .struct_size = sizeof change, .properties = GLIMS_LAYER_OPACITY, .opacity = 0.5 };
  GlimsTextSettings  settings = { .struct_size = sizeof settings, .size = 12, .color = { 0, 0, 0, 1 },
                                  .justify = GLIMS_JUSTIFY_LEFT, .antialias = true };
  GlimsSelectOptions select = { .struct_size = sizeof select, .operation = GLIMS_SELECT_REPLACE };
  int32_t            count = 0, depth;

  api->image_new (engine, 64, 64, &image, NULL);

  api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
  api->layer_command (engine, image, layer, GLIMS_LAYER_DELETE, NULL, NULL);
  depth = undo_depth (image);
  CHECK (api->stroke_begin (engine, image, layer, &brush, &first, &stroke, NULL) == GLIMS_STATUS_NOT_FOUND,
         "a deleted layer cannot be painted on");
  if (stroke)
    api->stroke_end (engine, stroke);
  CHECK (api->layer_change (engine, image, layer, &change, NULL) == GLIMS_STATUS_NOT_FOUND &&
         undo_depth (image) == depth,
         "a deleted layer cannot be changed");

  strcpy (settings.font, "Sans-serif");
  if (api->text_layer_new (engine, image, "x", &settings, (GlimsPoint) { 0, 0 }, &text, NULL) == GLIMS_STATUS_OK)
    {
      api->layer_command (engine, image, text, GLIMS_LAYER_DELETE, NULL, NULL);
      depth = undo_depth (image);
      CHECK (api->text_layer_set (engine, image, text, "y", NULL, NULL) == GLIMS_STATUS_NOT_FOUND &&
             undo_depth (image) == depth,
             "a deleted text layer cannot be edited");
    }

  api->path_set (engine, image, 0, "Gone", &subpath, 1, &point, 1, &path, NULL);
  api->path_delete (engine, image, path);
  depth = undo_depth (image);
  CHECK (api->path_set (engine, image, path, NULL, &subpath, 1, &point, 1, NULL, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->path_get (engine, image, path, NULL, 0, &count, NULL, 0, &count) == GLIMS_STATUS_NOT_FOUND &&
         api->path_to_selection (engine, image, path, &select) == GLIMS_STATUS_NOT_FOUND &&
         api->path_delete (engine, image, path) == GLIMS_STATUS_NOT_FOUND &&
         undo_depth (image) == depth,
         "a deleted path cannot be edited, read, selected or deleted again");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->path_get (engine, image, path, NULL, 0, &count, NULL, 0, NULL) == GLIMS_STATUS_OK && count == 1,
         "undoing the delete brings the path back as it was");

  select.operation = 99;
  CHECK (api->path_to_selection (engine, image, path, &select) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown selection operation is refused");

  api->image_close (engine, image);
}

/* A render right after a change must show it. GEGL's 1 x 1 read shortcut
 * can reuse a hot tile without asking the projection's validate handler.
 * Check that shortcut separately from an ordinary multi-pixel tile read. */
static void
test_render_freshness (void)
{
  int rounds = 60, stale = 0, stale_blocks = 0, r;

  for (r = 0; r < rounds; r++)
    {
      GlimsImageID      image = 0;
      GlimsItemID       layer = 0;
      GlimsFillSettings fill = { .struct_size = sizeof fill, .mode = GLIMS_FILL_SELECTION,
                                 .color = { 1, 0, 0, 1 }, .opacity = 1, .antialias = true };
      GlimsLayerChange  change = { .struct_size = sizeof change, .properties = GLIMS_LAYER_OPACITY, .opacity = 0.5 };
      uint8_t           pixel[4], block[8 * 8 * 4];

      api->image_new (engine, 100, 80, &image, NULL);
      api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
      api->fill (engine, image, (GlimsPoint) { 0, 0 }, &fill, NULL);
      api->image_render (engine, image, 1.0, (GlimsRect) { 50, 40, 1, 1 }, pixel, 4);
      api->layer_change (engine, image, layer, &change, NULL);
      api->image_render (engine, image, 1.0, (GlimsRect) { 50, 40, 1, 1 }, pixel, 4);
      if (pixel[1] < 180)
        stale++;
      api->image_render (engine, image, 1.0, (GlimsRect) { 49, 39, 8, 8 }, block, 8 * 4);
      /* (49,39) was not validated by the preceding 1 x 1 read. */
      if (block[1] < 180)
        stale_blocks++;
      api->image_close (engine, image);
    }

  CHECK (stale == 0, "single-pixel renders right after %d changes all show them (%d stale)", rounds, stale);
  CHECK (stale_blocks == 0, "multi-pixel renders right after %d changes all show them (%d stale)", rounds, stale_blocks);
}

static void
test_paint_tools (void)
{
  GlimsImageID       image = 0;
  GlimsItemID        layer;
  GlimsBrushSettings brush;
  int32_t            before;
  char              *error = NULL;
  int                y, hard = 1, quick, rested, value;
  GlimsStatus        status;

  api->image_new (engine, 128, 64, &image, NULL);
  layer  = first_layer (image);
  before = undo_depth (image);

  /* A caller built before the paint tools existed paints with the brush. */
  brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  brush.struct_size = (uint32_t) offsetof (GlimsBrushSettings, tool);
  brush.tool = GLIMS_PAINT_PENCIL; /* beyond its struct_size: ignored */
  CHECK (stroke_line (image, layer, &brush, 8, 8, 120, 8, NULL) == GLIMS_STATUS_OK && red_at (image, 64, 8) < 64,
         "settings from an older caller paint with the paintbrush");

  brush = brush_for (GLIMS_PAINT_PENCIL, 5.0);
  CHECK (stroke_line (image, layer, &brush, 8, 20, 120, 20, NULL) == GLIMS_STATUS_OK && red_at (image, 64, 20) == 0,
         "the pencil paints");
  for (y = 14; y <= 26; y++)
    if (red_at (image, 64, y) != 0 && red_at (image, 64, y) != 255)
      hard = 0;
  CHECK (hard, "the pencil's edge is hard (only black and white across the line)");

  brush  = brush_for (GLIMS_PAINT_ERASER, 14.0);
  status = stroke_line (image, layer, &brush, 8, 8, 120, 8, NULL);
  value  = red_at (image, 64, 8);
  CHECK (status == GLIMS_STATUS_OK && value == 255,
         "the eraser restores the background on a layer without alpha (%d)", value);
  if (status != GLIMS_STATUS_OK || value != 255)
    explain_stroke (status, image, 64, 8, value);

  brush = brush_for (GLIMS_PAINT_BLUR, 10.0);
  brush.rate = 100.0;
  CHECK (stroke_line (image, layer, &brush, 64, 12, 64, 28, NULL) == GLIMS_STATUS_OK &&
         red_at (image, 64, 23) > 0 && red_at (image, 64, 23) < 255,
         "blur softens the pencil's edge (%d next to the line)", red_at (image, 64, 23));

  brush = brush_for (GLIMS_PAINT_DODGE, 10.0);
  brush.tones    = GLIMS_TONES_SHADOWS;
  brush.exposure = 100.0;
  CHECK (stroke_line (image, layer, &brush, 32, 14, 32, 26, NULL) == GLIMS_STATUS_OK && red_at (image, 32, 20) > 0,
         "dodge lightens the shadows (%d on the line)", red_at (image, 32, 20));

  /* Narrower than the line, so the paint it picks up is the line's. */
  brush = brush_for (GLIMS_PAINT_SMUDGE, 4.0);
  brush.rate = 100.0;
  status = stroke_line (image, layer, &brush, 96, 20, 96, 40, NULL);
  value  = red_at (image, 96, 30);
  CHECK (status == GLIMS_STATUS_OK && value < 255, "smudge drags the line's paint (%d below it)", value);
  if (status != GLIMS_STATUS_OK || value == 255)
    explain_stroke (status, image, 96, 30, value);

  /* The airbrush keeps painting while the pointer rests. */
  brush = brush_for (GLIMS_PAINT_AIRBRUSH, 10.0);
  brush.rate = 80.0;
  brush.flow = 10.0;
  {
    GlimsStrokePoint point = { 16, 50, 1.0, 0.0, 0.0, 0 };
    GlimsStrokeID    stroke = 0;

    api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL);
    api->stroke_end (engine, stroke);
    quick = red_at (image, 16, 50);

    point.x = 40;
    api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL);
    usleep (500 * 1000);
    api->stroke_end (engine, stroke);
    rested = red_at (image, 40, 50);
  }
  CHECK (rested < quick, "the airbrush keeps painting while the pointer rests (%d after 0.5 s, %d at once)",
         rested, quick);

  brush = brush_for (GLIMS_PAINT_CLONE, 4.0);
  brush.source_drawable = 0;
  CHECK (stroke_line (image, layer, &brush, 16, 40, 20, 40, &error) == GLIMS_STATUS_FAILED && error,
         "clone without a source is refused (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;

  brush.source_drawable = layer;
  brush.source_x = 80; /* on the pencil line, away from the blur and dodge */
  brush.source_y = 20;
  CHECK (stroke_line (image, layer, &brush, 110, 40, 112, 40, NULL) == GLIMS_STATUS_OK && red_at (image, 110, 40) < 64,
         "clone copies from the source point (%d)", red_at (image, 110, 40));

  brush = brush_for (GLIMS_PAINT_HEAL, 6.0);
  brush.source_drawable = layer;
  brush.source_x = 64;
  brush.source_y = 40;
  {
    int32_t heal_before = undo_depth (image);

    CHECK (stroke_line (image, layer, &brush, 64, 20, 70, 20, NULL) == GLIMS_STATUS_OK &&
           undo_depth (image) == heal_before + 1,
           "heal runs as one undo step");
  }

  CHECK (undo_depth (image) == before + 10, "each of the 10 strokes is one undo step, the refused one none (%d)",
         undo_depth (image) - before);

  api->image_close (engine, image);
}

static int
file_size (const char *path)
{
  struct stat st;
  return stat (path, &st) == 0 ? (int) st.st_size : -1;
}

static int
count_differences (const uint8_t *a, const uint8_t *b, size_t bytes)
{
  int    n = 0;
  size_t i;

  for (i = 0; i < bytes; i += 4)
    if (memcmp (a + i, b + i, 4) != 0)
      n++;
  return n;
}

/* Image color state (mode, precision, effective profile) and the
 * undoable mode and precision conversions, through the facade only. */
static void
test_color_state (const char *fixtures, const char *work)
{
  char               indexed_png[1024], profiled_png[1024], xcf[1024];
  GlimsImageID       image = 0, reopened = 0, indexed = 0;
  GlimsItemID        layer = 0;
  GlimsColorInfo     info;
  GlimsImageInfo     basic;
  GlimsComponentState comp;
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  GlimsStrokePoint   point = { 4, 4, 1.0, 0.0, 0.0, 0 };
  GlimsStrokeID      stroke = 0;
  GlimsFilterID      filter = 0;
  GlimsFillSettings  red = { .struct_size = sizeof red, .mode = GLIMS_FILL_SELECTION,
                             .color = { 1, 0, 0, 1 }, .opacity = 1 };
  uint8_t            pixel[4];
  uint8_t           *before_pixels = NULL, *after_pixels = NULL;
  int32_t            w1 = 0, h1 = 0, w2 = 0, h2 = 0, before;
  char              *error = NULL;

  snprintf (indexed_png, sizeof indexed_png, "%s/indexed.png", fixtures);
  snprintf (profiled_png, sizeof profiled_png, "%s/profiled.png", fixtures);
  snprintf (xcf, sizeof xcf, "%s/color-state.xcf", work);

  api->image_new (engine, 32, 24, &image, NULL);

  /* A fresh image is 8-bit non-linear RGB with the engine's builtin sRGB
   * as its effective profile and no profile embedded; the old
   * GlimsImageInfo precision string stays the engine's nick. */
  CHECK (api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.mode == GLIMS_COLOR_MODE_RGB &&
         info.component == GLIMS_COLOR_COMPONENT_U8 &&
         info.trc == GLIMS_COLOR_TRC_NONLINEAR &&
         ! info.profile_embedded &&
         strcmp (info.profile_label, "GIMP built-in sRGB") == 0,
         "a fresh image reports RGB u8 non-linear, builtin sRGB, not embedded (%u,%u,%u,\"%s\",%d)",
         info.mode, info.component, info.trc, info.profile_label, info.profile_embedded);
  CHECK (api->image_info (engine, image, &basic) == GLIMS_STATUS_OK &&
         strcmp (basic.precision, "u8-non-linear") == 0,
         "image_info keeps the precision nick string (%s)", basic.precision);

  /* Bad ids, a NULL out and invalid enums fail without touching anything. */
  before = undo_depth (image);
  CHECK (api->image_color_info (engine, 9999, &info) == GLIMS_STATUS_NOT_FOUND &&
         api->image_color_info (engine, image, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_convert_mode (engine, 9999, GLIMS_COLOR_MODE_GRAYSCALE, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->image_convert_mode (engine, image, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_convert_mode (engine, image, 99, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_convert_precision (engine, image, 99, GLIMS_COLOR_TRC_LINEAR, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_U8, 99, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.mode == GLIMS_COLOR_MODE_RGB && undo_depth (image) == before,
         "bad ids, null out and invalid enums are refused with no mutation");

  /* Conversion TO indexed is unsupported for now. */
  CHECK (api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_INDEXED, &error) == GLIMS_STATUS_UNSUPPORTED &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.mode == GLIMS_COLOR_MODE_RGB && undo_depth (image) == before,
         "converting TO indexed is UNSUPPORTED with no mutation%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  /* No-ops change nothing and push no undo. */
  CHECK (api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_RGB, NULL) == GLIMS_STATUS_OK &&
         api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_U8,
                                       GLIMS_COLOR_TRC_NONLINEAR, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before,
         "mode and precision no-ops return OK and add no undo");

  /* A red layer gives the conversions pixels to preserve. */
  layer = first_layer (image);
  CHECK (api->fill (engine, image, (GlimsPoint) { 0, 0 }, &red, NULL) == GLIMS_STATUS_OK &&
         api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == 255 && pixel[1] == 0 && pixel[3] == 255,
         "the red layer renders red");
  before = undo_depth (image);
  before_pixels = render_all (image, &w1, &h1);

  /* RGB -> grayscale -> RGB, each one undo step, structure preserved. */
  CHECK (api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_GRAYSCALE, &error) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "convert to grayscale is one undo step%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.mode == GLIMS_COLOR_MODE_GRAYSCALE && info.component == GLIMS_COLOR_COMPONENT_U8 &&
         info.trc == GLIMS_COLOR_TRC_NONLINEAR && ! info.profile_embedded &&
         strstr (info.profile_label, "Grayscale") != NULL,
         "grayscale info: mode gray, u8 non-linear, builtin gray profile (\"%s\")", info.profile_label);
  CHECK (api->image_components (engine, image, &comp) == GLIMS_STATUS_OK &&
         comp.mode == GLIMS_COMPONENT_MODE_GRAY,
         "the component state follows the mode");
  CHECK (api->image_info (engine, image, &basic) == GLIMS_STATUS_OK &&
         basic.width == 32 && basic.height == 24 && basic.layer_count == 1 && basic.dirty,
         "size, layer count and dirty state survive the mode conversion");
  CHECK (api->image_render (engine, image, 1.0, (GlimsRect) { 16, 12, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         pixel[0] == pixel[1] && pixel[1] == pixel[2] && pixel[3] == 255,
         "the converted pixel renders gray (%d,%d,%d,%d)", pixel[0], pixel[1], pixel[2], pixel[3]);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && info.mode == GLIMS_COLOR_MODE_RGB &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && info.mode == GLIMS_COLOR_MODE_GRAYSCALE,
         "undo and redo walk the mode conversion");
  CHECK (api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_RGB, NULL) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && info.mode == GLIMS_COLOR_MODE_RGB,
         "back to RGB");

  /* Precision changes, including linear vs non-linear TRC. */
  free (before_pixels);
  before_pixels = render_all (image, &w1, &h1);
  before = undo_depth (image);
  CHECK (api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_U16,
                                       GLIMS_COLOR_TRC_NONLINEAR, NULL) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.component == GLIMS_COLOR_COMPONENT_U16 && info.trc == GLIMS_COLOR_TRC_NONLINEAR &&
         api->image_info (engine, image, &basic) == GLIMS_STATUS_OK &&
         strcmp (basic.precision, "u16-non-linear") == 0 && undo_depth (image) == before + 1,
         "u16 non-linear precision, one undo step (%s)", basic.precision);
  CHECK (api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_U16,
                                       GLIMS_COLOR_TRC_LINEAR, NULL) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && info.trc == GLIMS_COLOR_TRC_LINEAR,
         "the TRC changes to linear independently of the component");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && info.trc == GLIMS_COLOR_TRC_NONLINEAR &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && info.trc == GLIMS_COLOR_TRC_LINEAR,
         "undo and redo walk the TRC change");
  CHECK (api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_FLOAT,
                                       GLIMS_COLOR_TRC_PERCEPTUAL, NULL) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.component == GLIMS_COLOR_COMPONENT_FLOAT && info.trc == GLIMS_COLOR_TRC_PERCEPTUAL &&
         api->image_info (engine, image, &basic) == GLIMS_STATUS_OK &&
         strcmp (basic.precision, "float-perceptual") == 0,
         "float perceptual precision (%s)", basic.precision);
  after_pixels = render_all (image, &w2, &h2);
  CHECK (before_pixels && after_pixels && w1 == w2 && h1 == h2 &&
         count_differences (before_pixels, after_pixels, (size_t) w1 * h1 * 4) == 0,
         "u8 -> u16 -> float keeps every pixel (%d differ)",
         before_pixels && after_pixels ? count_differences (before_pixels, after_pixels, (size_t) w1 * h1 * 4) : -1);
  CHECK (api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_U8,
                                       GLIMS_COLOR_TRC_NONLINEAR, NULL) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.component == GLIMS_COLOR_COMPONENT_U8 && info.trc == GLIMS_COLOR_TRC_NONLINEAR,
         "back to u8 non-linear");

  /* An XCF round trip keeps the color state. */
  CHECK (api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_GRAYSCALE, NULL) == GLIMS_STATUS_OK &&
         api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_U16,
                                       GLIMS_COLOR_TRC_LINEAR, NULL) == GLIMS_STATUS_OK &&
         api->image_save (engine, image, xcf, &error) == GLIMS_STATUS_OK && file_size (xcf) > 0,
         "save the gray u16-linear image%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_open (engine, xcf, &reopened, &error) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, reopened, &info) == GLIMS_STATUS_OK &&
         info.mode == GLIMS_COLOR_MODE_GRAYSCALE && info.component == GLIMS_COLOR_COMPONENT_U16 &&
         info.trc == GLIMS_COLOR_TRC_LINEAR && ! info.profile_embedded &&
         strstr (info.profile_label, "Grayscale") != NULL &&
         api->image_info (engine, reopened, &basic) == GLIMS_STATUS_OK &&
         basic.width == 32 && basic.height == 24 && basic.layer_count == 1 &&
         strcmp (basic.precision, "u16-linear") == 0,
         "the reopened XCF keeps mode, precision, profile and structure (%u,%u,%u,\"%s\",\"%s\")",
         info.mode, info.component, info.trc, info.profile_label, basic.precision);
  api->free_string (error);
  error = NULL;
  api->image_close (engine, reopened);
  reopened = 0;
  CHECK (api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_RGB, NULL) == GLIMS_STATUS_OK &&
         api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_U8,
                                       GLIMS_COLOR_TRC_NONLINEAR, NULL) == GLIMS_STATUS_OK,
         "back to RGB u8 for the busy checks");

  /* Conversions refuse while a stroke or a preview holds the image;
   * reads keep working. */
  before = undo_depth (image);
  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK,
         "a stroke begins for the busy checks");
  CHECK (api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_GRAYSCALE, NULL) == GLIMS_STATUS_BUSY &&
         api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_U16,
                                       GLIMS_COLOR_TRC_LINEAR, NULL) == GLIMS_STATUS_BUSY &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && info.mode == GLIMS_COLOR_MODE_RGB &&
         undo_depth (image) == before,
         "conversions report BUSY during a stroke; info still reads, nothing changed");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK,
         "the refusals left the stroke alive");
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK &&
         api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_GRAYSCALE, NULL) == GLIMS_STATUS_BUSY &&
         api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_DOUBLE,
                                       GLIMS_COLOR_TRC_LINEAR, NULL) == GLIMS_STATUS_BUSY &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "conversions report BUSY during a preview; info still reads, abort works");

  /* An indexed image reports accurately; precision changes on it are
   * unsupported, and converting it to RGB works. */
  CHECK (api->image_open (engine, indexed_png, &indexed, &error) == GLIMS_STATUS_OK,
         "open the indexed PNG fixture%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  if (indexed)
    {
      before = undo_depth (indexed);
      CHECK (api->image_color_info (engine, indexed, &info) == GLIMS_STATUS_OK &&
             info.mode == GLIMS_COLOR_MODE_INDEXED && info.component == GLIMS_COLOR_COMPONENT_U8 &&
             info.trc == GLIMS_COLOR_TRC_NONLINEAR,
             "the indexed image reports indexed u8 non-linear (%u,%u,%u)",
             info.mode, info.component, info.trc);
      CHECK (api->image_convert_precision (engine, indexed, GLIMS_COLOR_COMPONENT_U16,
                                           GLIMS_COLOR_TRC_NONLINEAR, NULL) == GLIMS_STATUS_UNSUPPORTED &&
             api->image_convert_mode (engine, indexed, GLIMS_COLOR_MODE_INDEXED, NULL) == GLIMS_STATUS_UNSUPPORTED &&
             undo_depth (indexed) == before &&
             api->image_color_info (engine, indexed, &info) == GLIMS_STATUS_OK &&
             info.mode == GLIMS_COLOR_MODE_INDEXED,
             "indexed refuses precision changes and indexed conversion with no mutation");
      CHECK (api->image_convert_mode (engine, indexed, GLIMS_COLOR_MODE_RGB, NULL) == GLIMS_STATUS_OK &&
             api->image_color_info (engine, indexed, &info) == GLIMS_STATUS_OK &&
             info.mode == GLIMS_COLOR_MODE_RGB && undo_depth (indexed) == before + 1,
             "converting FROM indexed to RGB works as one undo step");
      api->image_close (engine, indexed);
      indexed = 0;
    }

  /* A closed image refuses everything. */
  CHECK (api->image_close (engine, image) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_NOT_FOUND &&
         api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_GRAYSCALE, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->image_convert_precision (engine, image, GLIMS_COLOR_COMPONENT_U8,
                                       GLIMS_COLOR_TRC_LINEAR, NULL) == GLIMS_STATUS_NOT_FOUND,
         "a closed image reports NOT_FOUND");

  /* Reading metadata must not consume an image-owned profile. Repeated
   * reloads and a save/reopen must preserve the custom embedded profile. */
  image = 0;
  CHECK (api->image_open (engine, profiled_png, &image, NULL) == GLIMS_STATUS_OK,
         "the custom-profile PNG opens");
  if (image)
    {
      int valid = 1;
      int i;

      free (before_pixels);
      before_pixels = render_all (image, &w1, &h1);
      for (i = 0; i < 10; i++)
        valid = api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
                info.profile_embedded && strcmp (info.profile_label, "Glims Profile Fixture") == 0 && valid;
      CHECK (valid, "repeated color metadata reads preserve the embedded profile");
      free (after_pixels);
      after_pixels = render_all (image, &w2, &h2);
      CHECK (before_pixels && after_pixels && w1 == w2 && h1 == h2 &&
             count_differences (before_pixels, after_pixels, (size_t) w1 * h1 * 4) == 0,
             "reading color metadata never changes the rendered pixels");
      CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
             api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
             api->image_color_info (engine, reopened, &info) == GLIMS_STATUS_OK &&
             info.profile_embedded && strcmp (info.profile_label, "Glims Profile Fixture") == 0,
             "the custom embedded profile survives XCF after repeated reads");
      if (reopened) api->image_close (engine, reopened);
      api->image_close (engine, image);
    }

  free (before_pixels);
  free (after_pixels);
}

static void
test_profile_preserves_editable_layers (const char *fixtures)
{
  GlimsImageID image = 0;
  GlimsItemID text = 0;
  GlimsTextSettings settings = { .struct_size = sizeof settings, .size = 14,
                                 .color = { 0, 0, 0, 1 }, .justify = GLIMS_JUSTIFY_LEFT,
                                 .antialias = true };
  GlimsLayerInfo rows[4];
  GlimsColorInfo color;
  char rgb[1024], *fonts = NULL, *newline;
  int32_t count = 0, depth;
  GlimsStatus status;

  snprintf (rgb, sizeof rgb, "%s/linear-rgb.icc", fixtures);
  CHECK (api->fonts (engine, &fonts) == GLIMS_STATUS_OK && fonts && *fonts,
         "the structured ICC fixture has a native font");
  if (! fonts || ! *fonts) { api->free_string (fonts); return; }
  newline = strchr (fonts, '\n');
  snprintf (settings.font, sizeof settings.font, "%.*s",
            (int) (newline ? newline - fonts : (ptrdiff_t)strlen (fonts)), fonts);
  api->free_string (fonts);
  CHECK (api->image_new (engine, 100, 60, &image, NULL) == GLIMS_STATUS_OK &&
         api->text_layer_new (engine, image, "Editable", &settings, (GlimsPoint) { 2, 2 }, &text, NULL)
           == GLIMS_STATUS_OK,
         "the structured ICC fixture has an editable text layer");
  CHECK (api->image_assign_profile (engine, image, rgb, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK &&
         count == 2 && rows[0].id == text && rows[0].kind == GLIMS_LAYER_TEXT,
         "profile assignment keeps text editable");
  depth = undo_depth (image);
  CHECK (api->image_convert_profile (engine, image, rgb, GLIMS_PROFILE_RELATIVE_COLORIMETRIC,
                                      true, NULL) == GLIMS_STATUS_OK && undo_depth (image) == depth,
         "an equal profile on editable text is still a no-op");
  status = api->image_convert_profile (engine, image, NULL, GLIMS_PROFILE_RELATIVE_COLORIMETRIC, true, NULL);
  CHECK (status == GLIMS_STATUS_REQUIRES_RASTERIZE && undo_depth (image) == depth &&
         api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && rows[0].kind == GLIMS_LAYER_TEXT &&
         api->image_color_info (engine, image, &color) == GLIMS_STATUS_OK && color.profile_embedded,
         "normal profile conversion requires explicit rasterization before changing editable text (status %d)", status);
  CHECK (api->image_convert_profile_rasterizing (engine, image, NULL, GLIMS_PROFILE_RELATIVE_COLORIMETRIC,
                                                 true, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == depth + 1 &&
         api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && rows[0].kind == GLIMS_LAYER_PIXEL,
         "explicit profile conversion rasterizes text as one undo step");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && rows[0].kind == GLIMS_LAYER_TEXT &&
         api->image_color_info (engine, image, &color) == GLIMS_STATUS_OK && color.profile_embedded &&
         !strcmp (color.profile_label, "Glims Linear RGB Fixture"),
         "undo explicit profile conversion restores text editability and its source profile");
  {
    char *restored_text = NULL;
    GlimsTextSettings restored_settings = { .struct_size = sizeof restored_settings };
    CHECK (api->text_layer_get (engine, image, text, &restored_text, &restored_settings) == GLIMS_STATUS_OK &&
           restored_text && !strcmp (restored_text, "Editable"),
           "the original text content remains editable after conversion undo");
    api->free_string (restored_text);
  }
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && rows[0].kind == GLIMS_LAYER_PIXEL,
         "redo reapplies the explicitly approved text rasterization");
  api->image_close (engine, image);

  if (supports_vector_layers ())
    {
      GlimsItemID path = 0, vector = 0, link = 0;
      GlimsSubpath subpath = { .count = 4, .closed = true };
      GlimsPathPoint points[] = { corner (10, 10), corner (60, 10), corner (60, 50), corner (10, 50) };
      char linked_file[1024];
      snprintf (linked_file, sizeof linked_file, "%s/profiled.png", fixtures);
      api->image_new (engine, 100, 60, &image, NULL);
      CHECK (api->path_set (engine, image, 0, "Profile shape", &subpath, 1, points, 4, &path, NULL) == GLIMS_STATUS_OK &&
             api->path_to_vector_layer (engine, image, path, "Profile vector", &vector, NULL) == GLIMS_STATUS_OK &&
             api->image_place_link (engine, image, linked_file, &link, NULL) == GLIMS_STATUS_OK &&
             api->image_assign_profile (engine, image, rgb, NULL) == GLIMS_STATUS_OK &&
             api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && count == 3 &&
             rows[0].id == link && rows[0].kind == GLIMS_LAYER_LINK &&
             rows[1].id == vector && rows[1].kind == GLIMS_LAYER_VECTOR,
             "profile assignment preserves genuine vector and linked layers");
      depth = undo_depth (image);
      CHECK (api->image_convert_profile (engine, image, NULL, GLIMS_PROFILE_RELATIVE_COLORIMETRIC, true, NULL)
               == GLIMS_STATUS_REQUIRES_RASTERIZE && undo_depth (image) == depth,
             "normal conversion refuses to rasterize vector and linked layers");
      status = api->image_convert_profile_rasterizing (engine, image, NULL, GLIMS_PROFILE_RELATIVE_COLORIMETRIC, true, NULL);
      api->image_layers (engine, image, rows, 4, &count);
      CHECK (status == GLIMS_STATUS_OK && undo_depth (image) == depth + 1 &&
             rows[0].kind == GLIMS_LAYER_PIXEL && rows[1].kind == GLIMS_LAYER_PIXEL,
             "explicit conversion rasterizes vector and link layers in the same undo step (status %d, undo %d -> %d, kinds %u/%u)",
             status, depth, undo_depth (image), rows[0].kind, rows[1].kind);
      CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
             api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK &&
             rows[0].id == link && rows[0].kind == GLIMS_LAYER_LINK &&
             rows[1].id == vector && rows[1].kind == GLIMS_LAYER_VECTOR,
             "undo restores genuine linked and vector layers after profile conversion");
      api->image_close (engine, image);
    }
}

static int
profile_pixel (GlimsImageID image, int32_t x, int32_t y, uint8_t out[4])
{
  memset (out, 0, 4);
  return api->image_render (engine, image, 1.0, (GlimsRect) { x, y, 1, 1 }, out, 4) == GLIMS_STATUS_OK;
}

static void
test_color_profiles (const char *fixtures, const char *work)
{
  char rgb[1024], gray[1024], xcf[1024], missing[1024], indexed_png[1024];
  GlimsImageID image = 0, reopened = 0, indexed = 0;
  GlimsColorInfo info;
  GlimsFilterID preview = 0;
  GlimsStrokeID stroke = 0;
  GlimsItemID layer = 0;
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 3);
  GlimsStrokePoint point = { 1, 1, 1, 0, 0, 0 };
  GlimsFillSettings fill = { .struct_size = sizeof fill, .mode = GLIMS_FILL_SELECTION,
                              .color = { .5, .25, .75, 1 }, .opacity = 1 };
  uint8_t before[4], assigned[4], pixel[4];
  int depth, i, matches;
  char *error = NULL;
  GlimsStatus status;

  snprintf (rgb, sizeof rgb, "%s/linear-rgb.icc", fixtures);
  snprintf (gray, sizeof gray, "%s/gray.icc", fixtures);
  snprintf (xcf, sizeof xcf, "%s/icc-profile.xcf", work);
  snprintf (missing, sizeof missing, "%s/missing-profile.icc", work);
  snprintf (indexed_png, sizeof indexed_png, "%s/indexed.png", fixtures);
  CHECK (api->image_new (engine, 8, 8, &image, NULL) == GLIMS_STATUS_OK &&
         api->fill (engine, image, (GlimsPoint) { 0, 0 }, &fill, NULL) == GLIMS_STATUS_OK &&
         profile_pixel (image, 4, 4, before), "the ICC fixture has known midtone pixels");
  depth = undo_depth (image);
  CHECK (api->image_assign_profile (engine, image, NULL, NULL) == GLIMS_STATUS_OK &&
         api->image_convert_profile (engine, image, NULL, GLIMS_PROFILE_RELATIVE_COLORIMETRIC,
                                      true, NULL) == GLIMS_STATUS_OK && undo_depth (image) == depth,
         "discarding or converting an already builtin profile adds no undo");
  CHECK (api->image_assign_profile (engine, image, "", NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_assign_profile (engine, image, "relative.icc", NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_assign_profile (engine, image, "/bad\xff.icc", NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_convert_profile (engine, image, rgb, 0, true, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_convert_profile (engine, image, rgb, UINT32_MAX, true, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == depth, "invalid ICC paths and facade intents refuse before mutation");
  status = api->image_assign_profile (engine, image, missing, &error);
  CHECK (status == GLIMS_STATUS_FAILED && error && *error && undo_depth (image) == depth,
         "a missing ICC file returns an error without an undo step");
  api->free_string (error); error = NULL;
  CHECK (api->image_assign_profile (engine, image, gray, NULL) == GLIMS_STATUS_FAILED &&
         api->image_convert_profile (engine, image, gray, GLIMS_PROFILE_PERCEPTUAL, true, NULL) == GLIMS_STATUS_FAILED &&
         undo_depth (image) == depth && profile_pixel (image, 4, 4, pixel) && !memcmp (pixel, before, 4),
         "a gray profile is refused for RGB without changing pixels or history");

  status = api->image_assign_profile (engine, image, rgb, &error);
  CHECK (status == GLIMS_STATUS_OK && api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.profile_embedded && !strcmp (info.profile_label, "Glims Linear RGB Fixture") &&
         undo_depth (image) == depth + 1,
         "assignment embeds the selected ICC profile as one undo step (%d: %s)", status, error ? error : "");
  api->free_string (error); error = NULL;
  CHECK (profile_pixel (image, 4, 4, assigned) && assigned[0] > before[0] + 30 &&
         assigned[1] > before[1] + 30,
         "assigning a linear profile reinterprets unchanged component values (%u,%u -> %u,%u)",
         before[0], before[1], assigned[0], assigned[1]);
  CHECK (api->image_assign_profile (engine, image, rgb, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == depth + 1, "assigning an equal profile is a no-op");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && !info.profile_embedded &&
         profile_pixel (image, 4, 4, pixel) && !memcmp (pixel, before, 4),
         "undo assignment restores the profile and its original appearance");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         profile_pixel (image, 4, 4, pixel) && !memcmp (pixel, assigned, 4),
         "redo assignment restores the custom interpretation");
  CHECK (api->image_save (engine, image, xcf, NULL) == GLIMS_STATUS_OK &&
         api->image_open (engine, xcf, &reopened, NULL) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, reopened, &info) == GLIMS_STATUS_OK &&
         info.profile_embedded && !strcmp (info.profile_label, "Glims Linear RGB Fixture") &&
         profile_pixel (reopened, 4, 4, pixel) && !memcmp (pixel, assigned, 4),
         "the assigned profile and appearance survive XCF save and reopen");
  if (reopened) api->image_close (engine, reopened);

  depth = undo_depth (image);
  status = api->image_convert_profile (engine, image, NULL, GLIMS_PROFILE_RELATIVE_COLORIMETRIC,
                                       true, &error);
  matches = profile_pixel (image, 4, 4, pixel);
  for (i = 0; i < 4; i++) matches = matches && abs ((int)pixel[i] - assigned[i]) <= 2;
  CHECK (status == GLIMS_STATUS_OK && matches && undo_depth (image) == depth + 1 &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && !info.profile_embedded,
         "conversion to builtin sRGB preserves appearance as one undo step (%d; %u,%u,%u -> %u,%u,%u; %s)",
         status, assigned[0], assigned[1], assigned[2], pixel[0], pixel[1], pixel[2], error ? error : "");
  api->free_string (error); error = NULL;
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && info.profile_embedded &&
         !strcmp (info.profile_label, "Glims Linear RGB Fixture"),
         "undo profile conversion restores the embedded source profile");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && !info.profile_embedded,
         "redo profile conversion restores the builtin destination");
  depth = undo_depth (image);
  CHECK (api->image_assign_profile (engine, image, rgb, NULL) == GLIMS_STATUS_OK &&
         api->image_assign_profile (engine, image, NULL, NULL) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && !info.profile_embedded &&
         undo_depth (image) == depth + 2,
         "discarding an assigned profile is a separate undoable interpretation change");

  layer = first_layer (image);
  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK &&
         api->image_assign_profile (engine, image, rgb, NULL) == GLIMS_STATUS_BUSY &&
         api->image_convert_profile (engine, image, rgb, GLIMS_PROFILE_SATURATION, false, NULL) == GLIMS_STATUS_BUSY,
         "profile assignment and conversion refuse an active stroke");
  if (stroke) api->stroke_end (engine, stroke);
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &preview, NULL) == GLIMS_STATUS_OK &&
         api->image_assign_profile (engine, image, rgb, NULL) == GLIMS_STATUS_BUSY &&
         api->image_convert_profile (engine, image, rgb, GLIMS_PROFILE_ABSOLUTE_COLORIMETRIC, false, NULL) == GLIMS_STATUS_BUSY,
         "profile assignment and conversion refuse a live filter preview");
  if (preview) api->filter_abort (engine, preview);
  CHECK (api->image_convert_mode (engine, image, GLIMS_COLOR_MODE_GRAYSCALE, NULL) == GLIMS_STATUS_OK &&
         api->image_assign_profile (engine, image, gray, NULL) == GLIMS_STATUS_OK &&
         api->image_color_info (engine, image, &info) == GLIMS_STATUS_OK && info.profile_embedded &&
         !strcmp (info.profile_label, "Glims Gray Fixture"),
         "a grayscale image accepts its compatible gray ICC profile");
  depth = undo_depth (image);
  CHECK (api->image_assign_profile (engine, image, rgb, NULL) == GLIMS_STATUS_FAILED &&
         api->image_convert_profile (engine, image, rgb, GLIMS_PROFILE_PERCEPTUAL, true, NULL) == GLIMS_STATUS_FAILED &&
         undo_depth (image) == depth,
         "a grayscale image refuses an RGB destination before adding history");
  CHECK (api->image_convert_profile (engine, image, NULL, GLIMS_PROFILE_PERCEPTUAL, true, NULL) == GLIMS_STATUS_OK,
         "a gray profile converts back to the builtin gray profile");
  CHECK (api->image_open (engine, indexed_png, &indexed, NULL) == GLIMS_STATUS_OK &&
         api->image_assign_profile (engine, indexed, rgb, NULL) == GLIMS_STATUS_OK,
         "an indexed image can assign a compatible RGB profile without conversion");
  depth = undo_depth (indexed);
  CHECK (api->image_convert_profile (engine, indexed, NULL, GLIMS_PROFILE_PERCEPTUAL, true, &error)
           == GLIMS_STATUS_UNSUPPORTED && error && *error && undo_depth (indexed) == depth &&
         api->image_color_info (engine, indexed, &info) == GLIMS_STATUS_OK && info.profile_embedded &&
         !strcmp (info.profile_label, "Glims Linear RGB Fixture"),
         "indexed profile conversion refuses unsupported intent and BPC without changing the palette profile");
  api->free_string (error); error = NULL;
  if (indexed) api->image_close (engine, indexed);
  api->image_close (engine, image);
  CHECK (api->image_assign_profile (engine, image, rgb, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->image_convert_profile (engine, image, rgb, GLIMS_PROFILE_PERCEPTUAL, true, NULL) == GLIMS_STATUS_NOT_FOUND,
         "closed images refuse ICC assignment and conversion");
}

/* ---- Tests ------------------------------------------------------------- */

static void
test_new_image_and_render (GlimsImageID *out)
{
  GlimsImageID   image = 0;
  GlimsImageInfo info;
  GlimsLayerInfo rows[4];
  int32_t        count = 0, width = 0, height = 0;
  uint8_t       *pixels;
  uint8_t        half[32 * 24 * 4];
  char          *error = NULL;
  int            white = 1;
  int            i;

  CHECK (api->image_new (engine, 64, 48, &image, &error) == GLIMS_STATUS_OK && image > 0,
         "new 64x48 image");
  api->free_string (error);

  CHECK (api->image_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.width == 64 && info.height == 48 && info.layer_count == 1 && ! info.dirty,
         "image info: 64x48, 1 layer, clean (precision %s)", info.precision);

  CHECK (api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && count == 1 &&
         strcmp (rows[0].name, "Background") == 0 && rows[0].kind == GLIMS_LAYER_PIXEL &&
         rows[0].visible && strcmp (rows[0].mode, "normal") == 0,
         "layer tree: one visible pixel layer \"Background\" in mode \"%s\"", count ? rows[0].mode : "");

  pixels = render_all (image, &width, &height);
  for (i = 0; pixels && i < width * height; i++)
    if (memcmp (pixels + i * 4, "\xff\xff\xff\xff", 4) != 0)
      white = 0;
  CHECK (pixels && white, "render at 100%%: all pixels opaque white");
  free (pixels);

  CHECK (api->image_render (engine, image, 0.5, (GlimsRect) { 0, 0, 32, 24 }, half, 32 * 4) == GLIMS_STATUS_OK &&
         memcmp (half + (12 * 32 + 16) * 4, "\xff\xff\xff\xff", 4) == 0,
         "render at 50%%: 32x24 white");

  CHECK (api->image_render (engine, image, 0.0, (GlimsRect) { 0, 0, 1, 1 }, half, 4) == GLIMS_STATUS_INVALID_ARGUMENT,
         "render rejects scale 0");

  *out = image;
}

static void
test_paint_and_undo (GlimsImageID image)
{
  GlimsItemID layer = first_layer (image);
  int32_t     before = undo_depth (image);
  int32_t     width, height;
  uint8_t    *pixels;
  int         events_before = atomic_load (&projection_events);
  double      start = now_ms ();

  paint_line (image, layer, 8, 56, 12);

  CHECK (undo_depth (image) == before + 1, "one stroke adds exactly one undo step (%d -> %d)", before, undo_depth (image));

  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixel_at (pixels, width, 32, 12)[0] < 64 && pixel_at (pixels, width, 32, 40)[0] == 255,
         "stroke paints black on the line and leaves the rest white");
  free (pixels);

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK, "undo");
  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixel_at (pixels, width, 32, 12)[0] == 255, "undo restores white");
  free (pixels);

  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK, "redo");
  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixel_at (pixels, width, 32, 12)[0] < 64, "redo repaints the stroke");
  free (pixels);

  CHECK (atomic_load (&projection_events) > events_before, "projection-changed events arrived (%d)",
         atomic_load (&projection_events) - events_before);
  printf ("      stroke, undo, redo and renders took %.0f ms\n", now_ms () - start);
}

static void
test_filters (GlimsImageID image, const char *work)
{
  GlimsItemID    layer = first_layer (image);
  GlimsFilterID  filter = 0;
  GlimsLayerInfo row;
  int32_t        count, before = undo_depth (image), width, height;
  uint8_t       *pixels;
  char          *error = NULL;

  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK,
         "gaussian blur session opens%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->filter_set_double (engine, filter, "std-dev-x", 4.0) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, filter, "std-dev-y", 4.0) == GLIMS_STATUS_OK,
         "filter properties set");
  {
    char preview_path[1024];
    snprintf (preview_path, sizeof preview_path, "%s/uncommitted-preview.xcf", work);
    CHECK (api->image_save (engine, image, preview_path, NULL) == GLIMS_STATUS_BUSY && access (preview_path, F_OK) != 0,
           "Save refuses an uncommitted filter preview without writing a file");
    unlink (preview_path);
  }
  CHECK (api->filter_set_double (engine, filter, "no-such-property", 1.0) == GLIMS_STATUS_NOT_FOUND,
         "unknown filter property is reported");

  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixel_at (pixels, width, 32, 18)[0] < 255 && pixel_at (pixels, width, 32, 18)[0] > 0,
         "preview blurs the stroke edge (value %d at 6 px off the line)", pixels ? pixel_at (pixels, width, 32, 18)[0] : -1);
  free (pixels);
  CHECK (undo_depth (image) == before, "an open preview adds no undo step");

  CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "filter commits%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  CHECK (undo_depth (image) == before + 1, "commit adds exactly one undo step (%d -> %d)", before, undo_depth (image));
  {
    GlimsUndoInfo undo_info;

    CHECK (api->image_undo_info (engine, image, &undo_info) == GLIMS_STATUS_OK &&
           strcmp (undo_info.next_undo, "Gaussian Blur") == 0,
           "the undo step is named after the filter (\"%s\")", undo_info.next_undo);
  }
  CHECK (api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK && row.filter_count == 1,
         "the layer carries one non-destructive filter");

  before = undo_depth (image);
  CHECK (api->filter_begin (engine, image, layer, "gegl:invert-gamma", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "a second session opens and aborts");
  CHECK (undo_depth (image) == before, "abort adds no undo step");
  CHECK (api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK && row.filter_count == 1,
         "abort leaves the filter stack unchanged");

  CHECK (api->filter_begin (engine, image, layer, "gegl:no-such-op", &filter, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "unknown operation is rejected");
  {
    GlimsImageID closing = 0;
    GlimsFilterID preview = 0;
    api->image_new (engine, 16, 16, &closing, NULL);
    api->filter_begin (engine, closing, first_layer (closing), "gegl:gaussian-blur", &preview, NULL);
    CHECK (api->image_close (engine, closing) == GLIMS_STATUS_OK &&
           api->filter_abort (engine, preview) == GLIMS_STATUS_NOT_FOUND,
           "closing an image releases its unfinished filter sessions");
  }
}

/* Operation discovery and the typed parameters of a live filter: the
 * list is sorted and gated like GIMP's non-destructive filters, an
 * operation's property metadata reads as plain C, enum values are
 * nicks, values read and write on an open session, and every refusal
 * leaves the preview and the undo stack alone. Concrete expectations
 * come from the engine's GEGL sources: gegl:gaussian-blur (a double, an
 * enum and a boolean), gegl:median-blur (an int), gegl:color-overlay (a
 * color), gegl:displace (auxiliary input), gimp:curves (config object). */
static void
test_history_and_snapshots (void)
{
  GlimsImageID image = 0, copy = 0;
  GlimsHistoryInfo info = { 0 }, prior;
  GlimsHistoryRow rows[8];
  GlimsImageInfo image_info;
  GlimsLayerInfo layers[4];
  GlimsItemID group = 0, layer;
  GlimsFilterID filter = 0;
  int32_t count = 0, w, h, cw, ch;
  uint8_t *pixels, *copy_pixels;
  char *error = NULL;
  char second_label[256];
  GlimsLayerChange change = { .struct_size = sizeof change, .properties = GLIMS_LAYER_NAME };

  api->image_new (engine, 16, 16, &image, NULL);
  layer = first_layer (image);
  CHECK (api->image_history (engine, image, NULL, 0, &info) == GLIMS_STATUS_OK &&
         info.count == 1 && info.current_position == 0 && info.revision != 0,
         "a new image has one earliest history state");
  CHECK (api->image_history (engine, image, NULL, -1, &info) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_history (engine, image, NULL, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "history refuses invalid output arguments");
  prior = info;
  strcpy (change.name, "Snapshot layer");
  api->layer_change (engine, image, layer, &change, NULL);
  api->create_group (engine, image, 0, 0, "Snapshot group", &group, NULL);
  api->reparent_layer (engine, image, layer, group, 0, NULL);
  CHECK (api->image_history (engine, image, rows, 8, &info) == GLIMS_STATUS_OK &&
         info.count == 4 && info.current_position == 3 && info.revision != prior.revision &&
         rows[0].position == 0 && rows[1].position == 1 && rows[1].name[0] &&
         rows[3].position == 3 && rows[3].name[0],
         "history lists chronological native undo states");
  prior = info;
  strcpy (second_label, rows[2].name);
  CHECK (api->image_history_move (engine, image, info.revision, 1, &error) == GLIMS_STATUS_OK &&
         undo_depth (image) == 1 &&
         api->image_layers (engine, image, layers, 4, &count) == GLIMS_STATUS_OK &&
         count == 1 && strcmp (layers[0].name, "Snapshot layer") == 0,
         "history moves backward through native reparent and group undos (%s)", error ? error : "");
  CHECK (api->image_history_move (engine, image, prior.revision, 3, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == 1,
         "a stale history selection changes nothing");
  api->image_history (engine, image, rows, 8, &info);
  CHECK (info.count == 4 && info.current_position == 1 &&
         strcmp (rows[2].name, second_label) == 0,
         "future redo states remain in chronological order (%s)", rows[2].name);
  CHECK (api->image_history_move (engine, image, info.revision, 3, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, image, layers, 4, &count) == GLIMS_STATUS_OK && count == 2 &&
         layers[0].id == group && layers[1].id == layer && layers[1].parent == group,
         "history moving forward restores the exact native group tree");
  api->image_history (engine, image, NULL, 0, &info);
  prior = info;
  CHECK (api->image_history_move (engine, image, info.revision, 3, NULL) == GLIMS_STATUS_OK &&
         api->image_history (engine, image, NULL, 0, &info) == GLIMS_STATUS_OK &&
         info.revision == prior.revision,
         "selecting the current history state creates no edit or revision");
  CHECK (api->image_history_move (engine, image, info.revision, 4, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_history_move (engine, image, info.revision, -1, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         undo_depth (image) == 3,
         "history rejects out-of-range states without changing the image");
  pixels = render_all (image, &w, &h);
  CHECK (api->image_duplicate (engine, image, &copy, &error) == GLIMS_STATUS_OK && copy != image && copy != 0 &&
         api->image_info (engine, copy, &image_info) == GLIMS_STATUS_OK && image_info.dirty &&
         image_info.layer_count == 2 && undo_depth (copy) == 0 && undo_depth (image) == 3,
         "a snapshot is an independent unsaved layered image with empty history (%s)", error ? error : "");
  copy_pixels = render_all (copy, &cw, &ch);
  CHECK (pixels && copy_pixels && w == cw && h == ch && memcmp (pixels, copy_pixels, (size_t) w * h * 4) == 0,
         "snapshot pixels match the source");
  free (pixels);
  free (copy_pixels);
  CHECK (api->image_layers (engine, copy, layers, 4, &count) == GLIMS_STATUS_OK && count == 2 &&
         layers[0].id != group && layers[1].id != layer && layers[1].parent == layers[0].id &&
         strcmp (layers[1].name, "Snapshot layer") == 0,
         "snapshots own distinct layer identities while preserving names and parenting");
  strcpy (change.name, "Independent");
  api->layer_change (engine, copy, layers[1].id, &change, NULL);
  api->image_layers (engine, image, layers, 4, &count);
  CHECK (strcmp (layers[1].name, "Snapshot layer") == 0 && undo_depth (image) == 3,
         "editing a snapshot leaves source layers and history unchanged");
  api->image_close (engine, copy);

  api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, NULL);
  api->image_history (engine, image, NULL, 0, &info);
  CHECK (api->image_history_move (engine, image, info.revision, 0, NULL) == GLIMS_STATUS_BUSY &&
         api->image_duplicate (engine, image, &copy, NULL) == GLIMS_STATUS_BUSY && copy == 0 &&
         undo_depth (image) == 3,
         "history moves and snapshots refuse an uncommitted preview");
  api->filter_abort (engine, filter);
  api->image_history_move (engine, image, info.revision, 1, NULL);
  strcpy (change.name, "New branch");
  api->layer_change (engine, image, layer, &change, NULL);
  api->image_history (engine, image, NULL, 0, &info);
  CHECK (info.count == 3 && info.current_position == 2,
         "new edits after undo discard unreachable redo states");
  api->image_close (engine, image);
  CHECK (api->image_history (engine, image, NULL, 0, &info) == GLIMS_STATUS_NOT_FOUND &&
         api->image_duplicate (engine, image, &copy, NULL) == GLIMS_STATUS_NOT_FOUND && copy == 0,
         "history and snapshot calls reject closed images");
  if (error) api->free_string (error);
}

static void
test_filter_properties (void)
{
  GlimsImageID          image = 0;
  GlimsItemID           layer;
  GlimsFilterID         filter = 0;
  GlimsOperationInfo   *ops;
  GlimsFilterProperty   props[8];
  GlimsFilterEnumChoice choices[8];
  GlimsFilterValue      value;
  int32_t               total = -1, count = -1, before, i;
  int                   gaussian = -1, displace = -1, curves = -1;
  int                   sorted = 1, hidden = 0, malformed = 0, pads = 0;
  int                   x = -1, fil = -1, clip = -1;
  char                 *error = NULL;
  static const char    *excluded[] = { "gegl:text", "gegl:nop", "gegl:buffer-source",
                                       "gegl:write-buffer", "gegl:over", "gegl:magick-load" };

  CHECK (api->filter_operations (engine, NULL, 0, &total) == GLIMS_STATUS_OK && total > 50,
         "%d filter operations are discovered", total);
  CHECK (api->filter_operations (engine, NULL, 0, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->filter_operations (engine, NULL, -1, &count) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a missing count or a negative capacity is refused");
  ops = calloc ((size_t) MAX (total, 1), sizeof *ops);
  CHECK (ops && api->filter_operations (engine, ops, total, &count) == GLIMS_STATUS_OK && count == total,
         "the rows fill a caller array");
  for (i = 0; ops && i < count; i++)
    {
      size_t e;

      if (i && strcmp (ops[i - 1].name, ops[i].name) >= 0)
        sorted = 0;
      if (! ops[i].name[0] || ops[i].support > GLIMS_FILTER_OP_CONFIG)
        malformed = 1;
      for (e = 0; e < sizeof excluded / sizeof excluded[0]; e++)
        if (strcmp (ops[i].name, excluded[e]) == 0)
          hidden = 1;
      if (strcmp (ops[i].name, "gegl:gaussian-blur") == 0)
        gaussian = i;
      else if (strcmp (ops[i].name, "gegl:displace") == 0)
        displace = i;
      else if (strcmp (ops[i].name, "gimp:curves") == 0)
        curves = i;
    }
  CHECK (sorted, "the list is sorted by name");
  CHECK (! malformed, "every row carries a name and a known support flag");
  CHECK (! hidden, "hidden, source, sink and compositor operations are excluded");
  CHECK (gaussian >= 0 && ops[gaussian].support == GLIMS_FILTER_OP_SUPPORTED &&
         strcmp (ops[gaussian].title, "Gaussian Blur") == 0 && strstr (ops[gaussian].categories, "blur") &&
         ops[gaussian].blurb[0],
         "gegl:gaussian-blur is listed as a supported form (%s, %s)",
         gaussian >= 0 ? ops[gaussian].title : "", gaussian >= 0 ? ops[gaussian].categories : "");
  CHECK (displace >= 0 && ops[displace].support == GLIMS_FILTER_OP_AUX_INPUT,
         "gegl:displace is listed but flagged for its auxiliary input");
  CHECK (curves >= 0 && ops[curves].support == GLIMS_FILTER_OP_CONFIG,
         "gimp:curves is listed but flagged for its config object");

  CHECK (api->filter_operation_properties (engine, "gegl:gaussian-blur", NULL, 0, &count) == GLIMS_STATUS_OK &&
         count == 5, "gaussian blur exposes %d editable properties", count);
  CHECK (api->filter_operation_properties (engine, "gegl:gaussian-blur", props, 8, &count) == GLIMS_STATUS_OK &&
         count == 5, "its property rows fill");
  for (i = 0; i < count; i++)
    {
      if (! strcmp (props[i].name, "input") || ! strcmp (props[i].name, "output") ||
          ! strcmp (props[i].name, "aux"))
        pads = 1;
      if (strcmp (props[i].name, "std-dev-x") == 0)
        x = i;
      else if (strcmp (props[i].name, "filter") == 0)
        fil = i;
      else if (strcmp (props[i].name, "clip-extent") == 0)
        clip = i;
    }
  CHECK (! pads, "pads are not offered as properties");
  CHECK (x >= 0 && props[x].kind == GLIMS_FILTER_VALUE_NUMBER &&
         props[x].min == 0.0 && props[x].max == 1500.0 &&
         props[x].ui_min > 0.2 && props[x].ui_min < 0.3 && props[x].ui_max == 100.0 &&
         props[x].ui_gamma == 3.0 && props[x].default_number == 1.5 &&
         strcmp (props[x].unit, "pixel-distance") == 0 && strcmp (props[x].label, "Size X") == 0,
         "std-dev-x reads as a number with absolute and form ranges (%.2f...%.2f, ui %.2f...%.2f)",
         x >= 0 ? props[x].min : 0.0, x >= 0 ? props[x].max : 0.0,
         x >= 0 ? props[x].ui_min : 0.0, x >= 0 ? props[x].ui_max : 0.0);
  CHECK (fil >= 0 && props[fil].kind == GLIMS_FILTER_VALUE_ENUM && props[fil].choice_count == 3 &&
         strcmp (props[fil].default_string, "auto") == 0,
         "filter reads as a 3-choice enum defaulting to auto");
  CHECK (clip >= 0 && props[clip].kind == GLIMS_FILTER_VALUE_BOOL && props[clip].default_bool,
         "clip-extent reads as a default-on boolean");
  CHECK (api->filter_operation_properties (engine, "gegl:no-such-op", props, 8, &count) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->filter_operation_properties (engine, "gegl:text", props, 8, &count) == GLIMS_STATUS_INVALID_ARGUMENT,
         "unknown and hidden operations are refused");

  CHECK (api->filter_enum_choices (engine, "gegl:gaussian-blur", "filter", choices, 8, &count) == GLIMS_STATUS_OK &&
         count == 3 && strcmp (choices[0].nick, "auto") == 0 && strcmp (choices[1].nick, "fir") == 0 &&
         strcmp (choices[2].nick, "iir") == 0,
         "the filter enum lists its nicks");
  CHECK (api->filter_enum_choices (engine, "gegl:gaussian-blur", "std-dev-x", choices, 8, &count) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->filter_enum_choices (engine, "gegl:gaussian-blur", "no-such", choices, 8, &count) == GLIMS_STATUS_NOT_FOUND &&
         api->filter_enum_choices (engine, "gegl:no-such-op", "filter", choices, 8, &count) == GLIMS_STATUS_INVALID_ARGUMENT,
         "non-enums, unknown properties and unknown operations are refused");

  api->image_new (engine, 64, 48, &image, NULL);
  layer  = first_layer (image);
  {
    const char *refused[] = { "gegl:nop", "gegl:gegl" };
    size_t n;
    for (n = 0; n < sizeof refused / sizeof refused[0]; n++)
      {
        GlimsFilterID refused_filter = 0;
        GlimsStatus refused_status = api->filter_begin (engine, image, layer, refused[n], &refused_filter, NULL);
        CHECK (refused_status == GLIMS_STATUS_INVALID_ARGUMENT && refused_filter == 0,
               "session creation refuses excluded operation %s", refused[n]);
        if (refused_filter) api->filter_abort (engine, refused_filter);
      }
  }
  before = undo_depth (image);
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK,
         "a session opens for typed access%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  CHECK (api->filter_get_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_OK &&
         value.kind == GLIMS_FILTER_VALUE_NUMBER && value.number == 1.5,
         "std-dev-x reads its 1.5 default as a number");
  CHECK (api->filter_get_property (engine, filter, "filter", &value) == GLIMS_STATUS_OK &&
         value.kind == GLIMS_FILTER_VALUE_ENUM && strcmp (value.string, "auto") == 0,
         "filter reads auto as a nick");
  CHECK (api->filter_get_property (engine, filter, "clip-extent", &value) == GLIMS_STATUS_OK &&
         value.kind == GLIMS_FILTER_VALUE_BOOL && value.boolean,
         "clip-extent reads true as a boolean");
  CHECK (api->filter_get_property (engine, filter, "operation", &value) == GLIMS_STATUS_NOT_FOUND &&
         api->filter_get_property (engine, filter, "no-such", &value) == GLIMS_STATUS_NOT_FOUND,
         "node and unknown properties are reported");

  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = 6.0 };
  CHECK (api->filter_set_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_OK &&
         api->filter_get_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_OK &&
         value.number == 6.0, "a number sets and reads back");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_BOOL, .boolean = false };
  CHECK (api->filter_set_property (engine, filter, "clip-extent", &value) == GLIMS_STATUS_OK &&
         api->filter_get_property (engine, filter, "clip-extent", &value) == GLIMS_STATUS_OK &&
         ! value.boolean, "a boolean sets and reads back");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_ENUM };
  strcpy (value.string, "fir");
  CHECK (api->filter_set_property (engine, filter, "filter", &value) == GLIMS_STATUS_OK &&
         api->filter_get_property (engine, filter, "filter", &value) == GLIMS_STATUS_OK &&
         strcmp (value.string, "fir") == 0, "an enum nick sets and reads back");

  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = NAN };
  CHECK (api->filter_set_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_INVALID_ARGUMENT,
         "NaN is refused");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = 2000.0 };
  CHECK (api->filter_set_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a number beyond the absolute range is refused");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 4 };
  CHECK (api->filter_set_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_INVALID_ARGUMENT,
         "the wrong kind is refused");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_ENUM };
  strcpy (value.string, "bogus-nick");
  CHECK (api->filter_set_property (engine, filter, "filter", &value) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown enum nick is refused");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = 1.0 };
  CHECK (api->filter_set_property (engine, filter, "no-such", &value) == GLIMS_STATUS_NOT_FOUND &&
         api->filter_set_property (engine, 4242, "std-dev-x", &value) == GLIMS_STATUS_NOT_FOUND,
         "unknown properties and sessions are reported");
  CHECK (api->filter_get_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_OK &&
         value.number == 6.0 && api->filter_get_property (engine, filter, "filter", &value) == GLIMS_STATUS_OK &&
         strcmp (value.string, "fir") == 0 && undo_depth (image) == before,
         "the refusals changed nothing and pushed no undo");
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK && undo_depth (image) == before,
         "the session aborts without an undo step");

  CHECK (api->filter_begin (engine, image, layer, "gegl:displace", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_get_property (engine, filter, "aux", &value) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->filter_set_property (engine, filter, "aux", &value) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "an auxiliary input pad is refused");

  filter = 0;
  CHECK (api->filter_begin (engine, image, layer, "gegl:median-blur", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_get_property (engine, filter, "radius", &value) == GLIMS_STATUS_OK &&
         value.kind == GLIMS_FILTER_VALUE_INTEGER && value.integer == 3,
         "median blur's radius reads 3 as an integer");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 12 };
  CHECK (api->filter_set_property (engine, filter, "radius", &value) == GLIMS_STATUS_OK &&
         api->filter_get_property (engine, filter, "radius", &value) == GLIMS_STATUS_OK &&
         value.integer == 12, "an integer sets and reads back");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 500 };
  CHECK (api->filter_set_property (engine, filter, "radius", &value) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an integer beyond the range is refused");
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK && undo_depth (image) == before,
         "abort drops the session without an undo step");

  filter = 0;
  CHECK (api->filter_begin (engine, image, layer, "gegl:color-overlay", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_get_property (engine, filter, "value", &value) == GLIMS_STATUS_OK &&
         value.kind == GLIMS_FILTER_VALUE_COLOR,
         "color overlay's value reads as a color");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_COLOR, .color = { 1.0, 0.25, 0.5, 1.0 } };
  CHECK (api->filter_set_property (engine, filter, "value", &value) == GLIMS_STATUS_OK &&
         api->filter_get_property (engine, filter, "value", &value) == GLIMS_STATUS_OK &&
         value.color.red > 0.99 && value.color.green > 0.24 && value.color.green < 0.26 &&
         value.color.alpha > 0.99, "a color sets and reads back (%.2f,%.2f,%.2f,%.2f)",
         value.color.red, value.color.green, value.color.blue, value.color.alpha);
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_COLOR, .color = { 1.5, 0, 0, 1 } };
  CHECK (api->filter_set_property (engine, filter, "value", &value) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a channel beyond 1 is refused");
  value.color.red = NAN;
  CHECK (api->filter_set_property (engine, filter, "value", &value) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a NaN channel is refused");
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "the color session aborts");

  filter = 0;
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK &&
         api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL) == GLIMS_STATUS_OK,
         "a typed-preview target can acquire a pixel lock");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = 4.0 };
  CHECK (api->filter_set_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_LOCKED &&
         api->filter_get_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_OK &&
         value.number == 1.5,
         "typed preview changes refuse newly locked targets without changing the value");
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK &&
         api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, 0, NULL) == GLIMS_STATUS_OK,
         "cancelling a typed preview remains available after locking");
  before = undo_depth (image);

  filter = 0;
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_commit (engine, filter, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "commit still lands as one undo step");
  value = (GlimsFilterValue) { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = 2.0 };
  CHECK (api->filter_get_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_NOT_FOUND &&
         api->filter_set_property (engine, filter, "std-dev-x", &value) == GLIMS_STATUS_NOT_FOUND,
         "a finished session rejects reads and writes");

  free (ops);
  api->image_close (engine, image);
}

static void
test_image_from_pixels (void)
{
  const uint8_t pixels[] = { 240, 16, 32, 128, 0, 255, 0, 0 };
  GlimsImageID image = 9999;
  GlimsImageInfo info = { 0 };
  GlimsPixelBuffer copied = { 0 };
  CHECK (api->image_from_pixels (engine, 2, 1, pixels, sizeof pixels - 1, &image, NULL) == GLIMS_STATUS_INVALID_ARGUMENT && image == 0,
         "Paste as New rejects malformed pixel data without returning an image");
  CHECK (api->image_from_pixels (engine, 2, 1, pixels, sizeof pixels, &image, NULL) == GLIMS_STATUS_OK &&
         api->image_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.width == 2 && info.height == 1 && info.layer_count == 1 && info.dirty && undo_depth (image) == 0,
         "Paste as New creates a correctly sized unsaved image with one layer and no synthetic undo steps");
  CHECK (api->image_copy_pixels (engine, image, false, &copied, NULL) == GLIMS_STATUS_OK &&
         copied.byte_count == sizeof pixels && memcmp (copied.pixels, pixels, sizeof pixels) == 0,
         "Paste as New preserves partial and complete transparency without a white background");
  api->free_pixels (copied.pixels);
  api->image_close (engine, image);
}

static void
test_save_copy (const char *work)
{
  GlimsImageID image = 0, copy = 0;
  GlimsImageInfo before, after;
  GlimsLayerChange change = { .struct_size = sizeof change, .properties = GLIMS_LAYER_NAME };
  GlimsLayerInfo row;
  char path[1024], failed_path[1024];
  int32_t depth, count = 0;

  snprintf (path, sizeof path, "%s/native-copy.xcf", work);
  snprintf (failed_path, sizeof failed_path, "%s/no-such-directory/copy.xcf", work);
  api->image_new (engine, 23, 17, &image, NULL);
  strcpy (change.name, "Unsaved Copy Source");
  api->layer_change (engine, image, first_layer (image), &change, NULL);
  api->image_info (engine, image, &before);
  depth = undo_depth (image);
  CHECK (before.dirty && api->image_save_copy (engine, image, path, NULL) == GLIMS_STATUS_OK && file_size (path) > 0,
         "Save a Copy writes a native file from an unsaved image");
  api->image_info (engine, image, &after);
  CHECK (after.dirty && undo_depth (image) == depth,
         "Save a Copy preserves source dirty state and undo history");
  CHECK (api->image_open (engine, path, &copy, NULL) == GLIMS_STATUS_OK &&
         api->image_layers (engine, copy, &row, 1, &count) == GLIMS_STATUS_OK && count == 1 &&
         strcmp (row.name, change.name) == 0,
         "a native copy reopens with its editable layer name");
  CHECK (api->image_save_copy (engine, image, failed_path, NULL) != GLIMS_STATUS_OK &&
         api->image_info (engine, image, &after) == GLIMS_STATUS_OK && after.dirty && undo_depth (image) == depth,
         "a failed native copy leaves the source dirty and editable");
  api->image_save (engine, image, path, NULL);
  CHECK (api->image_save_copy (engine, image, path, NULL) == GLIMS_STATUS_OK &&
         api->image_info (engine, image, &after) == GLIMS_STATUS_OK && !after.dirty,
         "Save a Copy also preserves a clean source's state");
  api->image_close (engine, copy);
  api->image_close (engine, image);
}

static void
test_save_reopen_export (GlimsImageID image, const char *work)
{
  char           xcf[1024], png[1024];
  GlimsImageID   reopened = 0, imported = 0;
  int32_t        w1, h1, w2, h2, w3, h3;
  uint8_t       *original, *again, *from_png;
  GlimsLayerInfo row;
  int32_t        count;
  char          *error = NULL;
  double         start;

  snprintf (xcf, sizeof xcf, "%s/roundtrip.xcf", work);
  snprintf (png, sizeof png, "%s/export.png", work);

  CHECK (api->image_save (engine, image, xcf, &error) == GLIMS_STATUS_OK && file_size (xcf) > 0,
         "save XCF%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  original = render_all (image, &w1, &h1);

  CHECK (api->image_open (engine, xcf, &reopened, &error) == GLIMS_STATUS_OK, "reopen XCF%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  again = render_all (reopened, &w2, &h2);
  CHECK (original && again && w1 == w2 && h1 == h2 &&
         count_differences (original, again, (size_t) w1 * h1 * 4) == 0,
         "reopened XCF renders identical pixels");
  CHECK (api->image_layers (engine, reopened, &row, 1, &count) == GLIMS_STATUS_OK && count == 1 &&
         row.filter_count == 1 && strcmp (row.name, "Background") == 0,
         "reopened XCF keeps the layer and its non-destructive filter");

  start = now_ms ();
  CHECK (api->image_export (engine, image, png, &error) == GLIMS_STATUS_OK && file_size (png) > 8,
         "export PNG through the file plug-in (%.0f ms)%s%s", now_ms () - start,
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  CHECK (api->image_open (engine, png, &imported, &error) == GLIMS_STATUS_OK,
         "import the PNG through the file plug-in%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  from_png = render_all (imported, &w3, &h3);
  CHECK (original && from_png && w1 == w3 && h1 == h3 &&
         count_differences (original, from_png, (size_t) w1 * h1 * 4) == 0,
         "the exported PNG holds the composited pixels (%d differ)",
         original && from_png ? count_differences (original, from_png, (size_t) w1 * h1 * 4) : -1);

  free (original);
  free (again);
  free (from_png);
  api->image_close (engine, reopened);
  api->image_close (engine, imported);
}

/* Compares two layer trees by structure (ids differ between images). */
static int
same_layer_rows (const GlimsLayerInfo *a, const GlimsLayerInfo *b, int32_t count)
{
  int32_t i;

  for (i = 0; i < count; i++)
    if (strcmp (a[i].name, b[i].name) != 0 || a[i].kind != b[i].kind || a[i].depth != b[i].depth ||
        strcmp (a[i].mode, b[i].mode) != 0 || a[i].visible != b[i].visible ||
        a[i].has_mask != b[i].has_mask || a[i].filter_count != b[i].filter_count ||
        a[i].opacity != b[i].opacity ||
        memcmp (&a[i].bounds, &b[i].bounds, sizeof a[i].bounds) != 0)
      return 0;
  return 1;
}

/* The fixture made by GIMP's own engine (scripts/make-fixtures.sh): a group
 * with a masked multiply layer and a layer with a non-destructive filter, a
 * text layer, and GIMP's own composite of it. */
static void
test_fixture (const char *fixtures, const char *work)
{
  char           xcf[1024], png[1024], roundtrip[1024];
  GlimsImageID   image = 0, reference = 0, reopened = 0;
  GlimsLayerInfo rows[16], again[16];
  int32_t        count = 0, count_again = 0, w1, h1, w2, h2, w3, h3, differences;
  uint8_t       *ours, *gimps, *after;
  char          *error = NULL;

  snprintf (xcf, sizeof xcf, "%s/composite.xcf", fixtures);
  snprintf (png, sizeof png, "%s/composite.png", fixtures);
  snprintf (roundtrip, sizeof roundtrip, "%s/composite-roundtrip.xcf", work);

  CHECK (api->image_open (engine, xcf, &image, &error) == GLIMS_STATUS_OK, "open the GIMP-made fixture XCF%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  if (! image)
    return;

  /* Zoomed out before anything was rendered at full resolution: the engine
   * builds zoomed-out pixels from full-resolution tiles, so a first 50 %
   * render must equal a 50 % render made after the whole image has been
   * rendered at 100 %, instead of showing unrendered (transparent) areas. */
  {
    uint8_t *first = calloc (160 * 120, 4), *later = calloc (160 * 120, 4), *full = NULL;
    int32_t  fw = 0, fh = 0;
    int      transparent = 0, i;

    CHECK (api->image_render (engine, image, 0.5, (GlimsRect) { 0, 0, 160, 120 }, first, 160 * 4) == GLIMS_STATUS_OK,
           "render a freshly opened image at 50%% first");
    for (i = 0; i < 160 * 120; i++)
      transparent += first[i * 4 + 3] == 0;
    full = render_all (image, &fw, &fh);
    api->image_render (engine, image, 0.5, (GlimsRect) { 0, 0, 160, 120 }, later, 160 * 4);
    CHECK (full && transparent == 0 && count_differences (first, later, 160 * 120 * 4) == 0,
           "the first 50%% render equals one made after a full render (%d transparent pixels)", transparent);
    free (first);
    free (later);
    free (full);
  }

  CHECK (api->image_layers (engine, image, rows, 16, &count) == GLIMS_STATUS_OK && count == 5 &&
         strcmp (rows[0].name, "Glims") == 0 && rows[0].kind == GLIMS_LAYER_TEXT &&
         strcmp (rows[1].name, "Shapes") == 0 && rows[1].kind == GLIMS_LAYER_GROUP &&
         strcmp (rows[2].name, "Blue circle") == 0 && rows[2].depth == 1 && rows[2].parent == rows[1].id &&
         rows[2].filter_count == 1 &&
         strcmp (rows[3].name, "Red square") == 0 && rows[3].depth == 1 && rows[3].has_mask &&
         strcmp (rows[3].mode, "multiply") == 0 && rows[3].opacity > 0.79 && rows[3].opacity < 0.81 &&
         strcmp (rows[4].name, "Background") == 0 && rows[4].depth == 0,
         "fixture layer tree: text, group with a filtered layer and a masked multiply layer, background");

  CHECK (api->image_open (engine, png, &reference, &error) == GLIMS_STATUS_OK, "open GIMP's own composite PNG");
  api->free_string (error);
  error = NULL;
  ours  = render_all (image, &w1, &h1);
  gimps = reference ? render_all (reference, &w2, &h2) : NULL;
  differences = ours && gimps && w1 == w2 && h1 == h2 ? count_differences (ours, gimps, (size_t) w1 * h1 * 4) : -1;
  CHECK (differences == 0, "the adapter's render equals GIMP's own composite (%d of %d pixels differ)",
         differences, w1 * h1);

  CHECK (api->image_save (engine, image, roundtrip, &error) == GLIMS_STATUS_OK, "save the fixture as XCF%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_open (engine, roundtrip, &reopened, &error) == GLIMS_STATUS_OK, "reopen the saved fixture");
  api->free_string (error);
  after = reopened ? render_all (reopened, &w3, &h3) : NULL;
  CHECK (ours && after && w1 == w3 && h1 == h3 && count_differences (ours, after, (size_t) w1 * h1 * 4) == 0,
         "the XCF round trip keeps identical pixels");
  CHECK (reopened && api->image_layers (engine, reopened, again, 16, &count_again) == GLIMS_STATUS_OK &&
         count_again == count && same_layer_rows (rows, again, count),
         "the XCF round trip keeps the layer structure, masks, modes and filters");

  free (ours);
  free (gimps);
  free (after);
  api->image_close (engine, image);
  api->image_close (engine, reference);
  api->image_close (engine, reopened);
}

/* A procedure_run on another thread, to probe the engine while it runs. */
typedef struct
{
  GlimsImageID image;
  const char  *name;
  GlimsStatus  status;
  atomic_bool  finished;
} BackgroundRun;

/* Waits until the background run reports progress or finishes; gives up
 * after 30 s so a wedged plug-in fails a check instead of hanging. */
static void
wait_for_progress (BackgroundRun *run)
{
  double deadline = now_ms () + 30000;

  while (! atomic_load (&run->finished) && ! atomic_load (&progress_active) && now_ms () < deadline)
    usleep (1000);
}

static void *
background_run (void *data)
{
  BackgroundRun *run = data;

  run->status = api->procedure_run (engine, run->image, run->name, GLIMS_RUN_WITH_LAST_VALUES, NULL);
  atomic_store (&run->finished, true);
  return NULL;
}

/* Minimal UTF-8 validation for the resource labels and identities. */
static int
valid_utf8 (const char *text)
{
  const unsigned char *p = (const unsigned char *) text;

  while (*p)
    {
      unsigned cp;
      int      length, i;

      if (*p < 0x80)
        {
          p++;
          continue;
        }
      else if ((*p & 0xE0) == 0xC0)
        {
          length = 2;
          cp     = *p & 0x1F;
        }
      else if ((*p & 0xF0) == 0xE0)
        {
          length = 3;
          cp     = *p & 0x0F;
        }
      else if ((*p & 0xF8) == 0xF0)
        {
          length = 4;
          cp     = *p & 0x07;
        }
      else
        return 0;

      for (i = 1; i < length; i++)
        {
          if ((p[i] & 0xC0) != 0x80)
            return 0;
          cp = (cp << 6) | (p[i] & 0x3F);
        }
      if ((length == 2 && cp < 0x80) ||
          (length == 3 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) ||
          (length == 4 && (cp < 0x10000 || cp > 0x10FFFF)))
        return 0;
      p += length;
    }

  return 1;
}

/* Brushes, patterns and gradients: names-only enumeration of the stock
 * factories, and the persistent identity that survives a restart. The
 * engine prefix these tests run against installs stock .gbr/.gih, .pat
 * and .ggr files, so every kind must list file-backed data, not only
 * built-ins. */
static void
test_resources (void)
{
  static const struct
  {
    uint32_t    kind;
    const char *label;
  } kinds[] = {
    { GLIMS_RESOURCE_BRUSH, "brush" },
    { GLIMS_RESOURCE_PATTERN, "pattern" },
    { GLIMS_RESOURCE_GRADIENT, "gradient" },
  };
  char              bad_name_utf8[] = { (char) 0xC3, (char) 0x28, 0 };
  char              bad_coll_utf8[] = { (char) 0xFF, (char) 0xFE, 0 };
  GlimsResourceInfo  short_rows[2] = { { 0 } };
  GlimsResourceInfo *rows = NULL;
  size_t             k;

  for (k = 0; k < sizeof kinds / sizeof kinds[0]; k++)
    {
      uint32_t           kind  = kinds[k].kind;
      const char        *label = kinds[k].label;
      GlimsResourceID    ext_id = 0, int_id = 0;
      char              *ext_name = NULL, *ext_collection = NULL;
      char              *int_name = NULL, *int_collection = NULL;
      bool               ext_internal = false;
      int32_t            count = 0, filled = 0, short_count = 0, bad_rows = 0, i;
      int                identity_failures = 0;

      CHECK (api->resources (engine, kind, NULL, 0, &count) == GLIMS_STATUS_OK && count > 0,
             "resources lists the engine's stock %s resources (%d)", label, count);
      rows = calloc ((size_t) (count > 0 ? count : 1), sizeof *rows);
      CHECK (api->resources (engine, kind, rows, count, &filled) == GLIMS_STATUS_OK &&
             filled == count, "resources fills every %s row (%d)", label, filled);

      for (i = 0; i < filled; i++)
        if (rows[i].id == 0 || rows[i].id > 0x7FFFFFFF || rows[i].kind != kind ||
            ! rows[i].name[0] || ! valid_utf8 (rows[i].name))
          bad_rows++;
      CHECK (filled > 0 && bad_rows == 0,
             "every %s row has a current-engine id, its kind and a UTF-8 label (%d bad)",
             label, bad_rows);

      CHECK (api->resources (engine, kind, short_rows, 2, &short_count) == GLIMS_STATUS_OK &&
             short_count == count && short_rows[0].id == rows[0].id &&
             short_rows[0].kind == rows[0].kind &&
             strcmp (short_rows[0].name, rows[0].name) == 0 &&
             (count < 2 || (short_rows[1].id == rows[1].id &&
                            strcmp (short_rows[1].name, rows[1].name) == 0)),
             "a short %s buffer reports the total %d and keeps the first rows", label, count);

      count = 99;
      CHECK (api->resources (engine, 0, rows, 2, &count) == GLIMS_STATUS_INVALID_ARGUMENT && count == 0 &&
             api->resources (engine, 4, rows, 2, &count) == GLIMS_STATUS_INVALID_ARGUMENT && count == 0 &&
             api->resources (engine, kind, rows, -1, &count) == GLIMS_STATUS_INVALID_ARGUMENT && count == 0 &&
             api->resources (engine, kind, NULL, 2, &count) == GLIMS_STATUS_INVALID_ARGUMENT && count == 0 &&
             api->resources (engine, kind, rows, 2, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
             "resources rejects a wrong kind, a negative capacity and missing outputs");

      /* Identity of every listed row; keep one built-in and one
       * file-backed triplet for the round trips below. */
      for (i = 0; i < filled; i++)
        {
          char      *name = NULL, *collection = NULL;
          bool       internal = false;
          GlimsStatus status;

          status = api->resource_identifiers (engine, rows[i].id, &name, &collection,
                                              &internal, NULL);
          if (status != GLIMS_STATUS_OK || ! name || ! name[0] || ! valid_utf8 (name) ||
              (collection && ! valid_utf8 (collection)) ||
              strncmp (rows[i].name, name, strlen (rows[i].name)) != 0)
            {
              identity_failures++;
            }
          else if (internal && ! int_name)
            {
              int_id    = rows[i].id;
              int_name  = name;
              int_collection = collection;
              name = collection = NULL;
            }
          else if (! internal && ! ext_name)
            {
              ext_id    = rows[i].id;
              ext_name  = name;
              ext_collection = collection;
              ext_internal = internal;
              name = collection = NULL;
            }
          api->free_string (name);
          api->free_string (collection);
        }
      CHECK (identity_failures == 0,
             "every listed %s reports a usable identity (%d bad)", label, identity_failures);
      CHECK (ext_name != NULL,
             "the installed engine prefix ships stock %s files, so at least one "
             "file-backed %s is listed", label, label);
      CHECK (int_name != NULL, "at least one built-in %s is listed", label);

      if (ext_name)
        {
          GlimsResourceID again = 1, wrong = 1;
          char           *name2 = NULL, *collection2 = NULL;
          bool            internal2 = true;
          char           *error = NULL;

          CHECK (api->resource_resolve (engine, kind, ext_name, ext_collection, false,
                                        &again, &error) == GLIMS_STATUS_OK && again == ext_id,
                 "a file-backed %s identity round-trips%s%s", label,
                 error ? ": " : "", error ? error : "");
          api->free_string (error);
          error = NULL;
          CHECK (api->resource_identifiers (engine, again, &name2, &collection2, &internal2, NULL) ==
                 GLIMS_STATUS_OK && name2 && strcmp (name2, ext_name) == 0 && ! internal2 &&
                 ((collection2 == NULL) == (ext_collection == NULL)) &&
                 (! collection2 || strcmp (collection2, ext_collection) == 0),
                 "the resolved %s reports the same identity again", label);
          api->free_string (name2);
          api->free_string (collection2);

          CHECK (api->resource_resolve (engine, kind, "Glims No Such Resource", ext_collection,
                                        false, &wrong, NULL) == GLIMS_STATUS_NOT_FOUND && wrong == 0,
                 "an unknown %s identity does not resolve", label);
          CHECK (api->resource_resolve (engine, kind, ext_name, "glims-no-such-collection",
                                        false, &wrong, NULL) == GLIMS_STATUS_NOT_FOUND && wrong == 0,
                 "a %s identity with a stale collection never falls back to name-only matching",
                 label);
          if (ext_collection)
            CHECK (api->resource_resolve (engine, kind, ext_name, NULL, false, &wrong, NULL) ==
                   GLIMS_STATUS_NOT_FOUND && wrong == 0,
                   "a %s identity needs its collection: NULL matches only a NULL collection",
                   label);
          CHECK (api->resource_resolve (engine, kinds[(k + 1) % 3].kind, ext_name,
                                        ext_collection, ext_internal, &wrong, NULL) ==
                 GLIMS_STATUS_NOT_FOUND && wrong == 0,
                 "a %s identity does not resolve as a %s", label, kinds[(k + 1) % 3].label);
        }

      if (int_name)
        {
          GlimsResourceID again = 1;

          CHECK (api->resource_resolve (engine, kind, int_name, int_collection, true,
                                        &again, NULL) == GLIMS_STATUS_OK && again == int_id,
                 "a built-in %s identity round-trips", label);
          CHECK (api->resource_resolve (engine, kind, "Glims Not The Localized Name",
                                        int_collection, true, &again, NULL) ==
                 GLIMS_STATUS_OK && again == int_id,
                 "a built-in %s identity ignores its localized display name", label);
          CHECK (api->resource_resolve (engine, kind, int_name, int_collection, false,
                                        &again, NULL) == GLIMS_STATUS_NOT_FOUND && again == 0,
                 "a built-in %s identity keeps its internal flag", label);
        }

      /* Handles that were never issued, and missing outputs. */
      {
        char *bad_name = "reset", *bad_collection = "reset";
        bool  bad_internal = true;
        char *error = NULL;

        CHECK (api->resource_identifiers (engine, 0, &bad_name, &bad_collection,
                                          &bad_internal, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
               ! bad_name && ! bad_collection && ! bad_internal && error,
               "the zero resource id is refused and the outputs reset (%s)",
               error ? error : "");
        api->free_string (error);
        error = NULL;
        bad_name = bad_collection = "reset";
        bad_internal = true;
        CHECK (api->resource_identifiers (engine, 0xFFFFFFFFFFFFFFFFull, &bad_name,
                                          &bad_collection, &bad_internal, NULL) ==
               GLIMS_STATUS_INVALID_ARGUMENT && ! bad_name && ! bad_collection && ! bad_internal,
               "a resource id outside the native id range is refused");
        bad_name = bad_collection = "reset";
        bad_internal = true;
        CHECK (api->resource_identifiers (engine, 0x80000000ull, &bad_name, &bad_collection,
                                          &bad_internal, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
               ! bad_name && ! bad_collection && ! bad_internal,
               "a resource id just above the native id range is refused");
        if (filled > 0)
          CHECK (api->resource_identifiers (engine, (UINT64_C(1) << 32) | rows[0].id,
                                            &bad_name, &bad_collection, &bad_internal, NULL) ==
                 GLIMS_STATUS_INVALID_ARGUMENT && ! bad_name && ! bad_collection && ! bad_internal,
                 "high resource-id bits cannot narrow to a live resource handle");
        bad_name = bad_collection = "reset";
        bad_internal = true;
        CHECK (api->resource_identifiers (engine, 0x7FFFFFFFull, &bad_name, &bad_collection,
                                          &bad_internal, NULL) == GLIMS_STATUS_NOT_FOUND &&
               ! bad_name && ! bad_collection && ! bad_internal,
               "a well-shaped but unissued resource id reports NOT_FOUND");
        if (filled > 0)
          CHECK (api->resource_identifiers (engine, rows[0].id, NULL, &bad_collection,
                                            &bad_internal, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
                 api->resource_identifiers (engine, rows[0].id, &bad_name, NULL,
                                            &bad_internal, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
                 api->resource_identifiers (engine, rows[0].id, &bad_name, &bad_collection,
                                            NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
                 "resource_identifiers requires its name, collection and internal outputs");
      }

      /* resolve: wrong kinds, invalid identity text, missing output. */
      {
        GlimsResourceID out = 1;
        char           *error = NULL;

        CHECK (api->resource_resolve (engine, 0, "name", NULL, false, &out, NULL) ==
               GLIMS_STATUS_INVALID_ARGUMENT && out == 0 &&
               api->resource_resolve (engine, 4, "name", NULL, false, &out, NULL) ==
               GLIMS_STATUS_INVALID_ARGUMENT && out == 0 &&
               api->resource_resolve (engine, kind, NULL, NULL, false, &out, NULL) ==
               GLIMS_STATUS_INVALID_ARGUMENT && out == 0 &&
               api->resource_resolve (engine, kind, "", NULL, false, &out, NULL) ==
               GLIMS_STATUS_INVALID_ARGUMENT && out == 0 &&
               api->resource_resolve (engine, kind, bad_name_utf8, NULL, false, &out, NULL) ==
               GLIMS_STATUS_INVALID_ARGUMENT && out == 0 &&
               api->resource_resolve (engine, kind, "name", bad_coll_utf8, false, &out, NULL) ==
               GLIMS_STATUS_INVALID_ARGUMENT && out == 0 &&
               api->resource_resolve (engine, kind, "name", NULL, false, NULL, &error) ==
               GLIMS_STATUS_INVALID_ARGUMENT && error,
               "resolve rejects a wrong kind, invalid identity text and a missing output (%s)",
               error ? error : "");
        api->free_string (error);
        CHECK (api->resource_resolve (engine, kind, "Glims No Such Resource", NULL, false,
                                      &out, NULL) == GLIMS_STATUS_NOT_FOUND && out == 0,
               "an unknown %s identity reports NOT_FOUND with the output reset", label);
      }

      api->free_string (ext_name);
      api->free_string (ext_collection);
      api->free_string (int_name);
      api->free_string (int_collection);
      free (rows);
      rows = NULL;
    }
}

/* Copies rows y0 ... y0+height-1 of a full render; the caller frees. */
static uint8_t *
band_of (const uint8_t *full, int32_t width, int32_t y0, int32_t height, size_t *bytes)
{
  uint8_t *band;

  *bytes = (size_t) width * height * 4;
  band = malloc (*bytes);
  if (band)
    memcpy (band, full + (size_t) y0 * width * 4, *bytes);
  return band;
}

/* The handle of the file-backed (non-internal) brush whose display name
 * is `name`, or 0. The stock parametric brushes ("Hardness 025",
 * "Block 01", ...) ship as .vbr files in every engine prefix, unlike
 * animated/random pipe (.gih) brushes and the empty clipboard brush. */
static GlimsResourceID
find_file_brush (const char *name)
{
  GlimsResourceInfo *rows = NULL;
  GlimsResourceID    found = 0;
  int32_t            count = 0, i;

  if (api->resources (engine, GLIMS_RESOURCE_BRUSH, NULL, 0, &count) != GLIMS_STATUS_OK || count <= 0)
    return 0;
  rows = calloc ((size_t) count, sizeof *rows);
  if (api->resources (engine, GLIMS_RESOURCE_BRUSH, rows, count, &count) != GLIMS_STATUS_OK || count <= 0)
    {
      free (rows);
      return 0;
    }
  for (i = 0; i < count; i++)
    {
      char *rname = NULL, *collection = NULL;
      bool  internal = false;

      if (rows[i].kind == GLIMS_RESOURCE_BRUSH &&
          api->resource_identifiers (engine, rows[i].id, &rname, &collection, &internal, NULL) == GLIMS_STATUS_OK &&
          ! internal && rname && strcmp (rname, name) == 0)
        found = rows[i].id;
      api->free_string (rname);
      api->free_string (collection);
      if (found)
        break;
    }
  free (rows);
  return found;
}

/* A stroke from (x0, y0) to (x1, y1) in 16 steps that paints with the
 * explicitly selected brush resource; returns the status of the first
 * failing call. */
static GlimsStatus
stroke_line_resource (GlimsImageID image, GlimsItemID layer, GlimsResourceID brush_id,
                      const GlimsBrushSettings *brush,
                      double x0, double y0, double x1, double y1, char **error)
{
  GlimsStrokePoint first = { x0, y0, 1.0, 0.0, 0.0, 0 };
  GlimsStrokePoint points[16];
  GlimsStrokeID    stroke = 0;
  GlimsStatus      status;
  int              i;

  for (i = 0; i < 16; i++)
    points[i] = (GlimsStrokePoint) { x0 + (x1 - x0) * (i + 1) / 16.0, y0 + (y1 - y0) * (i + 1) / 16.0,
                                     1.0, 0.0, 0.0, (uint32_t) (i + 1) * 8 };

  status = api->stroke_begin_with_brush_resource (engine, image, layer, brush_id, brush,
                                                  &first, &stroke, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = api->stroke_continue (engine, stroke, points, 16);
  if (status != GLIMS_STATUS_OK)
    {
      api->stroke_end (engine, stroke);
      return status;
    }
  return api->stroke_end (engine, stroke);
}

/* Strokes with an explicitly selected brush resource:
 * stroke_begin_with_brush_resource, resolved once at begin and pinned on
 * the stroke's own paint options, driven by the same continue/end. */
static void
test_stroke_brush_resource (void)
{
  GlimsImageID       image = 0, other = 0, busy_image = 0;
  GlimsItemID        layer = 0, other_layer = 0;
  GlimsResourceID    soft = 0, block = 0, wrong_kind = 0, resolved = 0;
  GlimsResourceInfo  pat = { 0 };
  int32_t            pcount = 0, depth0, depth;
  char              *soft_name = NULL, *soft_coll = NULL, *block_name = NULL, *block_coll = NULL;
  char              *soft_name2 = NULL, *soft_coll2 = NULL, *block_name2 = NULL, *block_coll2 = NULL;
  bool               soft_int = true, block_int = true, soft_int2 = true, block_int2 = true;
  GlimsBrushSettings brush, bad;
  GlimsStrokePoint   first = { 4, 32, 1.0, 0.0, 0.0, 0 };
  GlimsStrokePoint   points[16];
  GlimsStrokeID      stroke = 77, open = 0;
  GlimsStatus        status;
  uint8_t           *blank = NULL, *shot = NULL, *legacy1 = NULL, *soft_full = NULL;
  uint8_t           *band_blank = NULL, *band_soft = NULL, *band_block = NULL;
  uint8_t           *band_legacy1 = NULL, *band_legacy2 = NULL, *band_other = NULL, *band_open = NULL;
  size_t             band_bytes = 0;
  int                w = 0, h = 0;
  size_t             i;
  char              *error = NULL;

  /* Two distinct stock file-backed parametric brushes with a real mask:
   * a soft round one and a hard square one. */
  soft  = find_file_brush ("2. Hardness 025");
  block = find_file_brush ("2. Block 01");
  CHECK (soft != 0 && block != 0 && soft != block,
         "two distinct stock file-backed parametric brushes are listed (%llu, %llu)",
         (unsigned long long) soft, (unsigned long long) block);
  if (! soft || ! block)
    return;

  CHECK (api->resource_identifiers (engine, soft, &soft_name, &soft_coll, &soft_int, NULL) == GLIMS_STATUS_OK &&
         api->resource_identifiers (engine, block, &block_name, &block_coll, &block_int, NULL) == GLIMS_STATUS_OK &&
         soft_name && block_name && ! soft_int && ! block_int &&
         strcmp (soft_name, "2. Hardness 025") == 0 && strcmp (block_name, "2. Block 01") == 0,
         "the selected brushes carry their file-backed identities (%s, %s)",
         soft_name ? soft_name : "?", block_name ? block_name : "?");

  /* A pattern handle, for the wrong-kind refusal. */
  if (api->resources (engine, GLIMS_RESOURCE_PATTERN, &pat, 1, &pcount) == GLIMS_STATUS_OK && pcount > 0)
    wrong_kind = pat.id;

  brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 20.0);
  brush.pressure_size = false;  /* deterministic: pressure never scales the size */
  bad = brush;
  bad.size = 0.0;
  for (i = 0; i < 16; i++)
    points[i] = (GlimsStrokePoint) { 4 + 88.0 * (i + 1) / 16.0, 32, 1.0, 0.0, 0.0, (uint32_t) (i + 1) * 8 };

  api->image_new (engine, 96, 64, &image, NULL);
  api->image_new (engine, 96, 64, &other, NULL);
  layer       = first_layer (image);
  other_layer = first_layer (other);
  depth0 = undo_depth (image);
  blank  = render_all (image, &w, &h);

  /* A legacy default stroke first: the inherited brush's baseline. */
  CHECK (stroke_line (image, layer, &brush, 4, 10, 92, 10, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == depth0 + 1,
         "a legacy default stroke paints as one undo step");
  legacy1 = render_all (image, &w, &h);
  band_legacy1 = legacy1 ? band_of (legacy1, w, 0, 20, &band_bytes) : NULL;
  CHECK (legacy1 && blank && memcmp (legacy1, blank, (size_t) w * h * 4) != 0,
         "the legacy stroke changed the pixels");

  /* The selected soft brush paints; undo restores exactly. */
  CHECK (stroke_line_resource (image, layer, soft, &brush, 4, 32, 92, 32, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == depth0 + 2,
         "a stroke with the selected soft brush begins, continues and ends");
  soft_full = render_all (image, &w, &h);
  band_soft  = soft_full ? band_of (soft_full, w, 22, 20, &band_bytes) : NULL;
  band_blank = blank ? band_of (blank, w, 22, 20, &band_bytes) : NULL;
  CHECK (band_soft && band_blank && memcmp (band_soft, band_blank, band_bytes) != 0,
         "the selected file-backed brush with a real mask painted its band");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == depth0 + 1,
         "the resource stroke is one undo step");
  shot = render_all (image, &w, &h);
  CHECK (shot && legacy1 && memcmp (shot, legacy1, (size_t) w * h * 4) == 0,
         "undo restores the exact pre-stroke pixels");
  free (shot);

  /* A second, different brush at the same place must paint differently. */
  CHECK (stroke_line_resource (image, layer, block, &brush, 4, 32, 92, 32, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == depth0 + 2,
         "a stroke with the selected block brush runs");
  shot = render_all (image, &w, &h);
  band_block = shot ? band_of (shot, w, 22, 20, &band_bytes) : NULL;
  CHECK (band_block && band_soft && memcmp (band_block, band_soft, band_bytes) != 0,
         "two distinct deterministic brush choices paint differently");
  free (shot);
  api->image_undo (engine, image);

  /* While a resource stroke is open, an interleaved legacy stroke on
   * another image still uses the inherited default brush, and the open
   * stroke keeps its own selected brush until the end. */
  status = api->stroke_begin_with_brush_resource (engine, image, layer, soft, &brush, &first, &open, &error);
  CHECK (status == GLIMS_STATUS_OK, "a resource stroke begins and stays open%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  if (status == GLIMS_STATUS_OK)
    {
      CHECK (api->stroke_continue (engine, open, points, 16) == GLIMS_STATUS_OK,
             "the open stroke takes 16 points");
      CHECK (stroke_line (other, other_layer, &brush, 4, 10, 92, 10, NULL) == GLIMS_STATUS_OK,
             "an interleaved legacy stroke on another image runs while the resource stroke is open");
      CHECK (api->stroke_end (engine, open) == GLIMS_STATUS_OK, "the open resource stroke ends");
      shot = render_all (image, &w, &h);
      band_open = shot ? band_of (shot, w, 22, 20, &band_bytes) : NULL;
      CHECK (band_open && band_soft && memcmp (band_open, band_soft, band_bytes) == 0,
             "the open stroke kept its selected brush across the interleaved stroke");
      free (shot);
      shot = render_all (other, &w, &h);
      band_other = shot ? band_of (shot, w, 0, 20, &band_bytes) : NULL;
      CHECK (band_other && band_legacy1 && memcmp (band_other, band_legacy1, band_bytes) == 0,
             "the interleaved legacy stroke used the unchanged inherited default brush");
      free (shot);
      CHECK (undo_depth (image) == depth0 + 2, "the open stroke pushed exactly one undo step");
      api->image_undo (engine, image);
      api->image_undo (engine, other);
    }

  /* Legacy default strokes before and after all resource strokes paint
   * identically: the shared inherited brush context never changed. */
  CHECK (stroke_line (image, layer, &brush, 4, 54, 92, 54, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == depth0 + 2,
         "a legacy default stroke after the resource strokes runs");
  shot = render_all (image, &w, &h);
  band_legacy2 = shot ? band_of (shot, w, 44, 20, &band_bytes) : NULL;
  CHECK (band_legacy2 && band_legacy1 && memcmp (band_legacy2, band_legacy1, band_bytes) == 0,
         "legacy default strokes before and after resource strokes paint identically");
  free (shot);

  /* Refusals: each sets the out stroke to 0 and mutates no image or
   * history. */
  depth = undo_depth (image);
  shot = render_all (image, &w, &h);
  stroke = 77;
  status = api->stroke_begin_with_brush_resource (engine, image, layer, 0, &brush, &first, &stroke, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && stroke == 0 && error != NULL,
         "a zero brush handle is INVALID_ARGUMENT, out stroke reset (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  stroke = 77;
  CHECK (api->stroke_begin_with_brush_resource (engine, image, layer, 0x80000000ull, &brush, &first, &stroke, NULL) == GLIMS_STATUS_INVALID_ARGUMENT && stroke == 0 &&
         api->stroke_begin_with_brush_resource (engine, image, layer, 0xFFFFFFFFFFFFFFFFull, &brush, &first, &stroke, NULL) == GLIMS_STATUS_INVALID_ARGUMENT && stroke == 0 &&
         api->stroke_begin_with_brush_resource (engine, image, layer, UINT64_C(1) << 40, &brush, &first, &stroke, NULL) == GLIMS_STATUS_INVALID_ARGUMENT && stroke == 0 &&
         api->stroke_begin_with_brush_resource (engine, image, layer, (UINT64_C(1) << 32) | soft, &brush, &first, &stroke, NULL) == GLIMS_STATUS_INVALID_ARGUMENT && stroke == 0,
         "high-bit and out-of-native-range handles are INVALID_ARGUMENT, out stroke reset");
  if (wrong_kind)
    {
      stroke = 77;
      status = api->stroke_begin_with_brush_resource (engine, image, layer, wrong_kind, &brush, &first, &stroke, &error);
      CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && stroke == 0 && error != NULL,
             "a handle of another resource kind is INVALID_ARGUMENT, out stroke reset (%s)", error ? error : "");
      api->free_string (error);
      error = NULL;
    }
  stroke = 77;
  CHECK (api->stroke_begin_with_brush_resource (engine, image, layer, 0x7FFFFFFFull, &brush, &first, &stroke, NULL) == GLIMS_STATUS_NOT_FOUND && stroke == 0,
         "a well-shaped but stale (never issued, post-reset) handle is NOT_FOUND, out stroke reset");
  stroke = 77;
  CHECK (api->stroke_begin_with_brush_resource (engine, image, layer, soft, &brush, NULL, &stroke, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->stroke_begin_with_brush_resource (engine, image, layer, soft, NULL, &first, &stroke, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->stroke_begin_with_brush_resource (engine, image, layer, soft, &bad, &first, &stroke, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->stroke_begin_with_brush_resource (engine, image, layer, soft, &brush, &first, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a missing point, missing settings, a non-positive size and a missing output are INVALID_ARGUMENT");
  stroke = 77;
  CHECK (api->stroke_begin_with_brush_resource (engine, 424242, layer, soft, &brush, &first, &stroke, NULL) == GLIMS_STATUS_NOT_FOUND && stroke == 0,
         "an unknown image is NOT_FOUND, out stroke reset");
  CHECK (undo_depth (image) == depth, "the refused calls pushed no undo step");
  {
    uint8_t *now = render_all (image, &w, &h);
    CHECK (now && shot && memcmp (now, shot, (size_t) w * h * 4) == 0,
           "the refused calls changed no pixels");
    free (now);
  }
  free (shot);

  /* A pixel lock refuses the resource stroke begin, as it does the
   * legacy one. */
  CHECK (api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL) == GLIMS_STATUS_OK,
         "the layer's pixels lock");
  depth = undo_depth (image);
  stroke = 77;
  status = api->stroke_begin_with_brush_resource (engine, image, layer, soft, &brush, &first, &stroke, &error);
  CHECK (status == GLIMS_STATUS_LOCKED && stroke == 0 &&
         api->stroke_begin (engine, image, layer, &brush, &first, &stroke, NULL) == GLIMS_STATUS_LOCKED && stroke == 0,
         "a pixel lock refuses both stroke begins with LOCKED, out stroke reset%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  CHECK (undo_depth (image) == depth, "the locked refusals pushed no undo step");
  CHECK (api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, 0, NULL) == GLIMS_STATUS_OK,
         "the pixel lock lifts");

  /* BUSY while a plug-in holds the engine; a large image keeps it busy
   * long enough to probe. */
  api->image_new (engine, 4000, 3000, &busy_image, NULL);
  {
    BackgroundRun run = { 0 };
    pthread_t     thread;

    run.image = busy_image;
    run.name  = "plug-in-checkerboard";
    atomic_store (&progress_active, false);
    pthread_create (&thread, NULL, background_run, &run);
    wait_for_progress (&run);
    depth = undo_depth (image);
    stroke = 77;
    CHECK (! atomic_load (&run.finished) &&
           api->stroke_begin_with_brush_resource (engine, image, layer, soft, &brush, &first, &stroke, NULL) == GLIMS_STATUS_BUSY && stroke == 0,
           "a running plug-in makes the resource stroke begin BUSY, out stroke reset");
    CHECK (undo_depth (image) == depth, "the busy refusal pushed no undo step");
    pthread_join (thread, NULL);
    CHECK (run.status == GLIMS_STATUS_OK, "the background plug-in finished (%d)", run.status);
  }
  api->image_close (engine, busy_image);

  /* The selected brushes' persistent identities are unchanged, and still
   * resolve to the same handles. */
  CHECK (api->resource_identifiers (engine, soft, &soft_name2, &soft_coll2, &soft_int2, NULL) == GLIMS_STATUS_OK &&
         api->resource_identifiers (engine, block, &block_name2, &block_coll2, &block_int2, NULL) == GLIMS_STATUS_OK &&
         soft_name2 && block_name2 &&
         strcmp (soft_name2, soft_name) == 0 && strcmp (block_name2, block_name) == 0 &&
         soft_int2 == soft_int && block_int2 == block_int &&
         ((soft_coll2 == NULL) == (soft_coll == NULL)) && (! soft_coll2 || strcmp (soft_coll2, soft_coll) == 0) &&
         ((block_coll2 == NULL) == (block_coll == NULL)) && (! block_coll2 || strcmp (block_coll2, block_coll) == 0),
         "the selected brushes' persistent identities are unchanged by the strokes");
  CHECK (api->resource_resolve (engine, GLIMS_RESOURCE_BRUSH, soft_name, soft_coll, soft_int, &resolved, NULL) == GLIMS_STATUS_OK &&
         resolved == soft &&
         api->resource_resolve (engine, GLIMS_RESOURCE_BRUSH, block_name, block_coll, block_int, &resolved, NULL) == GLIMS_STATUS_OK &&
         resolved == block,
         "the identities still resolve to the same handles");

  api->free_string (soft_name);
  api->free_string (soft_coll);
  api->free_string (block_name);
  api->free_string (block_coll);
  api->free_string (soft_name2);
  api->free_string (soft_coll2);
  api->free_string (block_name2);
  api->free_string (block_coll2);
  free (blank);
  free (legacy1);
  free (soft_full);
  free (band_blank);
  free (band_soft);
  free (band_block);
  free (band_legacy1);
  free (band_legacy2);
  free (band_other);
  free (band_open);
  api->image_close (engine, image);
  api->image_close (engine, other);
}

/* Resource thumbnails: fresh per-call previews of stock brushes,
 * patterns and gradients, fitted into the requested box, with the
 * FG/BG color contract and every refusal path. The dynamic checks use
 * a stock FG to BG gradient, whose endpoints read the per-call colors:
 * repeated same-id, same-size renders that differ only in the
 * background (then only in the foreground) prove the preview is
 * recomputed per call instead of served from a cache keyed without
 * the background. */
static int
buffer_differs (const GlimsPixelBuffer *a, const GlimsPixelBuffer *b)
{
  if (! a->pixels || ! b->pixels || a->byte_count != b->byte_count)
    return 1;

  return memcmp (a->pixels, b->pixels, a->byte_count) != 0;
}

static void
test_resource_thumbnails (void)
{
  static const struct
  {
    uint32_t    kind;
    const char *label;
  } kinds[] = {
    { GLIMS_RESOURCE_BRUSH, "brush" },
    { GLIMS_RESOURCE_PATTERN, "pattern" },
    { GLIMS_RESOURCE_GRADIENT, "gradient" },
  };
  GlimsResourceInfo rows[8];
  GlimsPixelBuffer  first = { 0 }, again = { 0 };
  GlimsPixelBuffer  a = { 0 }, b = { 0 }, c = { 0 }, d = { 0 };
  GlimsColor        red = { 1.0, 0.0, 0.0, 1.0 }, blue = { 0.0, 0.0, 1.0, 1.0 };
  GlimsColor        green = { 0.0, 1.0, 0.0, 1.0 }, yellow = { 1.0, 1.0, 0.0, 1.0 };
  GlimsColor        bad;
  GlimsResourceID   brush_id = 0, gradient_id = 0, dynamic_id = 0;
  char             *error = NULL;
  size_t            k;
  int32_t           filled = 0, i;

  /* One stock resource of each kind renders inside the box. */
  for (k = 0; k < sizeof kinds / sizeof kinds[0]; k++)
    {
      uint32_t    kind  = kinds[k].kind;
      const char *label = kinds[k].label;
      int         shown = 0, n, j;

      CHECK (api->resources (engine, kind, rows, (int32_t) (sizeof rows / sizeof rows[0]),
                             &filled) == GLIMS_STATUS_OK && filled > 0,
             "thumbnails: %s stock resources are listed (%d)", label, filled);

      n = filled < 3 ? filled : 3;
      for (i = 0; i < n; i++)
        {
          GlimsPixelBuffer buffer = { 0 };
          int32_t          w, h;
          int              nonzero = 0, covered = 0;

          if (api->resource_thumbnail (engine, rows[i].id, 32, NULL, NULL,
                                       &buffer, NULL) == GLIMS_STATUS_OK && buffer.pixels)
            shown++;

          w = buffer.bounds.width;
          h = buffer.bounds.height;
          CHECK (buffer.pixels && w >= 1 && h >= 1 && w <= 32 && h <= 32 &&
                 buffer.bounds.x == 0 && buffer.bounds.y == 0 &&
                 buffer.byte_count == (size_t) w * (size_t) h * 4,
                 "%s thumbnail %s fits 32 x 32 at its own bounds (%d x %d, %zu bytes)",
                 label, rows[i].name, w, h, buffer.byte_count);

          if (kind == GLIMS_RESOURCE_GRADIENT)
            CHECK (buffer.pixels && w == 32 && h == 16,
                   "a gradient thumbnail is exactly 32 x 16 (%d x %d)", w, h);

          for (j = 0; j < w * h && buffer.pixels; j++)
            {
              if (buffer.pixels[j * 4] || buffer.pixels[j * 4 + 1] ||
                  buffer.pixels[j * 4 + 2] || buffer.pixels[j * 4 + 3])
                nonzero = 1;
              if (buffer.pixels[j * 4 + 3])
                covered = 1;
            }
          /* Mask-only brushes recolor with the black default
           * foreground, so any byte counts as content; alpha coverage
           * still proves the RGBA buffer is real. */
          char *resource_name = NULL, *collection = NULL;
          bool internal = false;
          int empty_clipboard_brush = 0;
          if (kind == GLIMS_RESOURCE_BRUSH &&
              api->resource_identifiers (engine, rows[i].id, &resource_name, &collection, &internal, NULL)
                == GLIMS_STATUS_OK && internal && collection)
            empty_clipboard_brush = !strcmp (collection, "gimp-brush-clipboard-image") ||
                                    !strcmp (collection, "gimp-brush-clipboard-mask");
          api->free_string (resource_name);
          api->free_string (collection);
          CHECK ((nonzero && covered) || empty_clipboard_brush,
                 "%s thumbnail %s has native content or the valid empty clipboard mask", label, rows[i].name);

          if (buffer.pixels)
            api->free_pixels (buffer.pixels);
        }

      CHECK (shown == n, "every listed stock %s renders a thumbnail (%d of %d)",
             label, shown, n);
      if (kind == GLIMS_RESOURCE_BRUSH && filled > 0)
        brush_id = rows[0].id;
      if (kind == GLIMS_RESOURCE_GRADIENT && filled > 0)
        gradient_id = rows[0].id;
    }

  /* Gradients fill exactly the documented strip at any size. */
  if (gradient_id)
    {
      GlimsPixelBuffer strip = { 0 };

      CHECK (api->resource_thumbnail (engine, gradient_id, 15, NULL, NULL, &strip, NULL) ==
                 GLIMS_STATUS_OK && strip.bounds.width == 15 && strip.bounds.height == 7,
             "a gradient thumbnail is exactly 15 x 7 at max_size 15 (%d x %d)",
             strip.bounds.width, strip.bounds.height);
      if (strip.pixels)
        api->free_pixels (strip.pixels);

      CHECK (api->resource_thumbnail (engine, gradient_id, 1, NULL, NULL, &strip, NULL) ==
                 GLIMS_STATUS_OK && strip.bounds.width == 1 && strip.bounds.height == 1 &&
                 strip.byte_count == 4,
             "a gradient thumbnail is exactly 1 x 1 at max_size 1 (%zu bytes)",
             strip.byte_count);
      if (strip.pixels)
        api->free_pixels (strip.pixels);
    }

  /* Same id, same size, only the background (then only the
   * foreground) changed: the pixels must change, or the thumbnails
   * came from a preview cache that ignores the colors. */
  CHECK (api->resources (engine, GLIMS_RESOURCE_GRADIENT, rows,
                         (int32_t) (sizeof rows / sizeof rows[0]), &filled) == GLIMS_STATUS_OK,
         "thumbnails: gradients listed again for the FG/BG checks (%d)", filled);
  /* Resolve the builtin identity, whose collection is stable in all
   * four source sets; the display name is localized and ignored here.
   * A short row buffer's total count must never bound an array scan. */
  CHECK (api->resource_resolve (engine, GLIMS_RESOURCE_GRADIENT, "FG to BG",
                                 "gimp-gradient-fg-bg-rgb", true, &dynamic_id, NULL) == GLIMS_STATUS_OK,
         "the native FG/BG RGB gradient resolves by exact internal identity");
  CHECK (dynamic_id != 0, "a stock FG to BG gradient is listed");

  if (dynamic_id)
    {
      int32_t w, h;
      GlimsColor midtone = { 0.5, 0.25, 0.75, 1 };
      GlimsPixelBuffer mid = { 0 };
      GlimsStatus mid_status = api->resource_thumbnail (engine, dynamic_id, 16, &midtone, &midtone, &mid, NULL);
      CHECK (mid_status == GLIMS_STATUS_OK && mid.pixels &&
             abs ((int) mid.pixels[0] - 128) <= 1 && abs ((int) mid.pixels[1] - 64) <= 1 &&
             abs ((int) mid.pixels[2] - 191) <= 1 && mid.pixels[3] == 255,
             "thumbnail foreground/background colors are sRGB midtones (%u,%u,%u)",
             mid.pixels ? mid.pixels[0] : 0, mid.pixels ? mid.pixels[1] : 0, mid.pixels ? mid.pixels[2] : 0);
      if (mid.pixels) api->free_pixels (mid.pixels);

      CHECK (api->resource_thumbnail (engine, dynamic_id, 32, &red, &blue, &a, NULL) ==
                 GLIMS_STATUS_OK &&
             api->resource_thumbnail (engine, dynamic_id, 32, &red, &blue, &again, NULL) ==
                 GLIMS_STATUS_OK &&
             a.pixels && again.pixels && ! buffer_differs (&a, &again),
             "repeated FG/BG gradient thumbnails with the same colors agree");
      if (again.pixels)
        api->free_pixels (again.pixels);

      CHECK (api->resource_thumbnail (engine, dynamic_id, 32, &red, &green, &b, NULL) ==
                 GLIMS_STATUS_OK &&
             api->resource_thumbnail (engine, dynamic_id, 32, &yellow, &blue, &c, NULL) ==
                 GLIMS_STATUS_OK &&
             api->resource_thumbnail (engine, dynamic_id, 32, NULL, NULL, &d, NULL) ==
                 GLIMS_STATUS_OK,
             "FG/BG gradient thumbnails with changed colors render");

      CHECK (a.pixels && b.pixels && buffer_differs (&a, &b),
             "changing only the background changes the FG/BG gradient thumbnail");
      CHECK (a.pixels && c.pixels && buffer_differs (&a, &c),
             "changing only the foreground changes the FG/BG gradient thumbnail");
      CHECK (a.pixels && d.pixels && buffer_differs (&a, &d),
             "the default black/white colors differ from explicit ones");

      w = a.bounds.width;
      h = a.bounds.height;
      {
        int j, opaque = 1;

        for (j = 0; j < w * h && a.pixels; j++)
          if (a.pixels[j * 4 + 3] != 255)
            opaque = 0;
        CHECK (w == 32 && h == 16 && opaque,
               "an opaque FG/BG gradient thumbnail is 32 x 16 with alpha 255");
      }

      if (a.pixels) api->free_pixels (a.pixels);
      if (b.pixels) api->free_pixels (b.pixels);
      if (c.pixels) api->free_pixels (c.pixels);
      if (d.pixels) api->free_pixels (d.pixels);
    }

  /* Bad sizes and colors refuse with the output reset. */
  if (brush_id)
    {
      static const int32_t bad_sizes[] = { 0, -1, 513 };
      GlimsPixelBuffer     out = { 0 };
      GlimsResourceID      ids[3];
      int                  j, reset_ok = 1, refused_ok = 1;

      for (j = 0; j < 3; j++)
        {
          out.bounds    = (GlimsRect) { 1, 2, 3, 4 };
          out.pixels    = (uint8_t *) (uintptr_t) 1;
          out.byte_count = 99;
          if (api->resource_thumbnail (engine, brush_id, bad_sizes[j], NULL, NULL,
                                       &out, NULL) != GLIMS_STATUS_INVALID_ARGUMENT)
            refused_ok = 0;
          if (out.pixels || out.byte_count || out.bounds.x || out.bounds.y ||
              out.bounds.width || out.bounds.height)
            reset_ok = 0;
        }
      CHECK (refused_ok && reset_ok,
             "max_size 0, -1 and 513 are refused with the output reset");

      bad = (GlimsColor) { NAN, 0.0, 0.0, 1.0 };
      out.pixels = (uint8_t *) (uintptr_t) 1;
      out.byte_count = 99;
      refused_ok = api->resource_thumbnail (engine, brush_id, 32, &bad, NULL, &out, NULL) ==
                   GLIMS_STATUS_INVALID_ARGUMENT && ! out.pixels && ! out.byte_count;
      bad = (GlimsColor) { 0.0, 1.5, 0.0, 1.0 };
      out.pixels = (uint8_t *) (uintptr_t) 1;
      if (api->resource_thumbnail (engine, brush_id, 32, NULL, &bad, &out, NULL) !=
          GLIMS_STATUS_INVALID_ARGUMENT)
        refused_ok = 0;
      bad = (GlimsColor) { 0.0, 0.0, -0.25, 1.0 };
      out.pixels = (uint8_t *) (uintptr_t) 1;
      if (api->resource_thumbnail (engine, brush_id, 32, &bad, NULL, &out, NULL) !=
          GLIMS_STATUS_INVALID_ARGUMENT)
        refused_ok = 0;
      bad = (GlimsColor) { 0.0, 0.0, 0.0, 2.0 };
      out.pixels = (uint8_t *) (uintptr_t) 1;
      if (api->resource_thumbnail (engine, brush_id, 32, NULL, &bad, &out, NULL) !=
          GLIMS_STATUS_INVALID_ARGUMENT || out.pixels || out.byte_count)
        refused_ok = 0;
      CHECK (refused_ok,
             "NaN and out-of-range foreground/background components are refused");

      /* Refusals carry the documented error text. */
      CHECK (api->resource_thumbnail (engine, brush_id, 32, NULL, NULL, NULL, &error) ==
                 GLIMS_STATUS_INVALID_ARGUMENT && error &&
             strcmp (error, "The pixel buffer output is required.") == 0,
             "a missing pixel buffer output is refused (%s)", error ? error : "");
      api->free_string (error);
      error = NULL;
      CHECK (api->resource_thumbnail (engine, brush_id, 513, NULL, NULL, &out, &error) ==
                 GLIMS_STATUS_INVALID_ARGUMENT && error &&
             strcmp (error, "The maximum size must be between 1 and 512.") == 0,
             "the maximum size limit is reported (%s)", error ? error : "");
      api->free_string (error);
      error = NULL;
      bad = (GlimsColor) { NAN, 0.0, 0.0, 1.0 };
      CHECK (api->resource_thumbnail (engine, brush_id, 32, &bad, NULL, &out, &error) ==
                 GLIMS_STATUS_INVALID_ARGUMENT && error &&
             strcmp (error, "The foreground and background colors need "
                            "finite components inside 0...1.") == 0,
             "the color contract is reported (%s)", error ? error : "");
      api->free_string (error);
      error = NULL;

      /* Zero, out-of-range and high-bit handles never narrow to a
       * live resource; a well-shaped stale handle reports NOT_FOUND. */
      ids[0] = 0;
      ids[1] = 0xFFFFFFFFFFFFFFFFull;
      ids[2] = (UINT64_C(1) << 32) | brush_id;
      refused_ok = 1;
      reset_ok = 1;
      for (j = 0; j < 3; j++)
        {
          out.bounds     = (GlimsRect) { 1, 2, 3, 4 };
          out.pixels     = (uint8_t *) (uintptr_t) 1;
          out.byte_count = 99;
          if (api->resource_thumbnail (engine, ids[j], 32, NULL, NULL, &out, &error) !=
              GLIMS_STATUS_INVALID_ARGUMENT)
            refused_ok = 0;
          if (! error || strcmp (error, "This handle cannot name a resource.") != 0)
            refused_ok = 0;
          api->free_string (error);
          error = NULL;
          if (out.pixels || out.byte_count || out.bounds.width)
            reset_ok = 0;
        }
      out.bounds     = (GlimsRect) { 1, 2, 3, 4 };
      out.pixels     = (uint8_t *) (uintptr_t) 1;
      out.byte_count = 99;
      if (api->resource_thumbnail (engine, 0x80000000ull, 32, NULL, NULL, &out, &error) !=
          GLIMS_STATUS_INVALID_ARGUMENT)
        refused_ok = 0;
      api->free_string (error);
      error = NULL;
      CHECK (refused_ok && reset_ok,
             "zero, all-high and high-bit resource ids are refused and the output reset");

      out.bounds     = (GlimsRect) { 1, 2, 3, 4 };
      out.pixels     = (uint8_t *) (uintptr_t) 1;
      out.byte_count = 99;
      CHECK (api->resource_thumbnail (engine, 0x7FFFFFFFull, 32, NULL, NULL, &out, &error) ==
                 GLIMS_STATUS_NOT_FOUND && ! out.pixels && ! out.byte_count && ! error,
             "a well-shaped but unissued resource id reports NOT_FOUND and resets the output");

      /* Repeated allocate/free stays stable. */
      {
        int stable = 1, repeat;

        for (repeat = 0; repeat < 5; repeat++)
          {
            if (api->resource_thumbnail (engine, brush_id, 32, NULL, NULL,
                                         &again, NULL) != GLIMS_STATUS_OK || ! again.pixels)
              stable = 0;
            if (repeat == 0)
              first = again;
            else
              {
                if (buffer_differs (&first, &again))
                  stable = 0;
                if (again.pixels)
                  api->free_pixels (again.pixels);
              }
          }
        CHECK (stable && first.pixels && first.byte_count > 0,
               "five same-id thumbnails render identically and free cleanly");
        if (first.pixels)
          api->free_pixels (first.pixels);
      }
    }
}

/* Pattern fill (fill_pattern), through the facade only. The independent
 * pixel oracle is a resource_thumbnail of a stock opaque pattern at its
 * native size: a thumbnail requested at 512 comes back below 512 only
 * at the pattern's own dimensions (the preview never up-scales), so the
 * tile below is exact. The native preview and the native fill are two
 * independent render paths; opaque patterns avoid any alpha or gamma
 * ambiguity between them. */
static int
find_opaque_patterns (GlimsResourceID ids[2], GlimsPixelBuffer thumbs[2])
{
  GlimsResourceInfo *rows = NULL;
  int32_t count = 0, i;
  int     found = 0;

  if (api->resources (engine, GLIMS_RESOURCE_PATTERN, NULL, 0, &count) != GLIMS_STATUS_OK || count < 1)
    return 0;
  rows = calloc ((size_t) count, sizeof *rows);
  if (api->resources (engine, GLIMS_RESOURCE_PATTERN, rows, count, &count) != GLIMS_STATUS_OK)
    count = 0;

  for (i = 0; i < count && found < 2; i++)
    {
      GlimsPixelBuffer buf = { 0 };
      int32_t          w, h;
      int              j, opaque = 1, varied = 0;

      if (api->resource_thumbnail (engine, rows[i].id, 512, NULL, NULL, &buf, NULL) != GLIMS_STATUS_OK ||
          ! buf.pixels)
        continue;
      w = buf.bounds.width;
      h = buf.bounds.height;
      if (w < 4 || h < 4 || w >= 512 || h >= 512)
        {
          api->free_pixels (buf.pixels);
          continue;
        }
      for (j = 0; j < w * h; j++)
        {
          if (buf.pixels[j * 4 + 3] != 255)
            opaque = 0;
          if (j > 0 && memcmp (&buf.pixels[j * 4], buf.pixels, 4) != 0)
            varied = 1;
        }
      if (! opaque || ! varied || (found == 1 && ! buffer_differs (&thumbs[0], &buf)))
        {
          api->free_pixels (buf.pixels);
          continue;
        }
      ids[found]   = rows[i].id;
      thumbs[found] = buf;
      found++;
    }

  free (rows);
  return found;
}

/* The worst per-channel difference between the rendered `region` and
 * the thumbnail tiled from the drawable origin (`origin_x`, `origin_y`):
 * image pixel (x, y) must show thumbnail pixel ((x - origin_x) mod w,
 * (y - origin_y) mod h). Two native paths meet here (preview vs. fill),
 * so a small rounding difference is allowed. */
static int
tiled_region_diff (GlimsImageID image, GlimsRect region, int32_t origin_x, int32_t origin_y,
                   const GlimsPixelBuffer *thumb, int *covered_out)
{
  uint8_t *pixels;
  int32_t  tw = thumb->bounds.width, th = thumb->bounds.height;
  int32_t  x, y;
  int      worst = 0, covered = 0;

  pixels = calloc ((size_t) region.width * region.height, 4);
  if (! pixels)
    return 256;
  if (api->image_render (engine, image, 1.0, region, pixels, (size_t) region.width * 4) != GLIMS_STATUS_OK)
    {
      free (pixels);
      return 256;
    }

  for (y = 0; y < region.height; y++)
    for (x = 0; x < region.width; x++)
      {
        int px = (int) (((region.x + x - origin_x) % tw + tw) % tw);
        int py = (int) (((region.y + y - origin_y) % th + th) % th);
        const uint8_t *got  = pixels + ((size_t) y * region.width + x) * 4;
        const uint8_t *want = thumb->pixels + ((size_t) py * tw + px) * 4;
        int c, d;

        covered++;
        for (c = 0; c < 4; c++)
          if ((d = abs ((int) got[c] - (int) want[c])) > worst)
            worst = d;
      }

  free (pixels);
  *covered_out = covered;
  return worst;
}

static void
test_pattern_fill (void)
{
  GlimsResourceID          patterns[2] = { 0, 0 };
  GlimsPixelBuffer         thumbs[2]   = { { 0 }, { 0 } };
  GlimsPatternFillSettings settings    = { .struct_size = sizeof settings, .mode = GLIMS_FILL_SELECTION,
                                            .opacity = 1, .threshold = 0.1, .antialias = true };
  GlimsImageID   image = 0, scratch = 0;
  GlimsItemID    layer, layer2 = 0, mask = 0, channel = 0;
  GlimsStrokeID  stroke = 0;
  GlimsFilterID  filter = 0;
  int32_t        pw, ph, W, H, before, worst, covered, w1, h1;
  uint8_t        px[4] = { 0 };
  uint8_t       *renderA = NULL, *renderB = NULL, *renderBefore = NULL;
  char          *error = NULL;
  int            found = find_opaque_patterns (patterns, thumbs);

  CHECK (found == 2,
         "two distinct stock opaque patterns render a thumbnail at native size below 512 (%d found)", found);
  if (found != 2)
    goto out;

  pw = MAX (thumbs[0].bounds.width, thumbs[1].bounds.width);
  ph = MAX (thumbs[0].bounds.height, thumbs[1].bounds.height);
  W  = pw + 16;   /* one full tile plus overflow: the fill tiles across the image */
  H  = ph + 16;

  CHECK (api->image_new (engine, W, H, &image, NULL) == GLIMS_STATUS_OK, "pattern-fill image %dx%d", W, H);
  layer  = first_layer (image);
  before = undo_depth (image);

  /* The tiled oracle: a full-layer Selection-mode fill with pattern A. */
  CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, &error) ==
         GLIMS_STATUS_OK, "a selection-mode pattern fill runs%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (undo_depth (image) == before + 1, "the pattern fill is one undo step (%d -> %d)",
         before, undo_depth (image));
  worst = tiled_region_diff (image, (GlimsRect) { 0, 0, W, H }, 0, 0, &thumbs[0], &covered);
  CHECK (covered == W * H && worst <= 2,
         "every pixel matches the pattern thumbnail tiled from the origin (worst channel diff %d over %d px)",
         worst, covered);
  renderA = render_all (image, &w1, &h1);
  {
    int nonwhite = 0, j;
    for (j = 0; j < w1 * h1; j++)
      if (renderA[j * 4] != 255 || renderA[j * 4 + 1] != 255 || renderA[j * 4 + 2] != 255)
        nonwhite++;
    CHECK (nonwhite > 0, "the fill visibly changed the white layer (%d of %d pixels)", nonwhite, w1 * h1);
  }

  /* Undo and redo. */
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == before,
         "undo removes the pattern fill as one step");
  render_pixel (image, W / 2, H / 2, px);
  CHECK (px[0] == 255 && px[1] == 255 && px[2] == 255 && px[3] == 255,
         "after undo the layer is white again (%d,%d,%d,%d)", px[0], px[1], px[2], px[3]);
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK, "redo reapplies the fill");
  worst = tiled_region_diff (image, (GlimsRect) { 0, 0, W, H }, 0, 0, &thumbs[0], &covered);
  CHECK (worst <= 2, "after redo the tiling is back (worst %d)", worst);

  /* The second pattern fills differently and matches its own thumbnail. */
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         api->fill_pattern (engine, image, patterns[1], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
         GLIMS_STATUS_OK, "filling with the second pattern runs");
  renderB = render_all (image, &w1, &h1);
  CHECK (renderA && renderB && count_differences (renderA, renderB, (size_t) w1 * h1 * 4) > 0,
         "the two patterns fill visibly differently (%d px differ)",
         renderA && renderB ? count_differences (renderA, renderB, (size_t) w1 * h1 * 4) : -1);
  worst = tiled_region_diff (image, (GlimsRect) { 0, 0, W, H }, 0, 0, &thumbs[1], &covered);
  CHECK (worst <= 2, "the second fill matches its own thumbnail tiled (worst %d)", worst);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK, "undo after the second fill");

  /* Selection clipping: only the selected rectangle is filled. */
  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) { { 10, 10 }, { 40, 40 } }, 2, NULL) == GLIMS_STATUS_OK,
         "a rectangle is selected");
  before = undo_depth (image);
  CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
         GLIMS_STATUS_OK && undo_depth (image) == before + 1,
         "a selection-clipped pattern fill runs as one undo step");
  render_pixel (image, 20, 20, px);
  CHECK (!(px[0] == 255 && px[1] == 255 && px[2] == 255), "inside the selection the pixel changed (%d,%d,%d)", px[0], px[1], px[2]);
  render_pixel (image, 60, 50, px);
  CHECK (px[0] == 255 && px[1] == 255 && px[2] == 255, "outside the selection the pixel stayed white (%d,%d,%d)", px[0], px[1], px[2]);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == before,
         "undo removes the clipped fill");
  CHECK (api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL) == GLIMS_STATUS_OK, "the selection is cleared");

  /* SimilarColors: the bucket fill covers only the seeded region of
   * similar color — a painted line stays, and the region beyond it
   * keeps the background. */
  paint_line (image, layer, 0, W, H / 2);
  settings.mode = GLIMS_FILL_SIMILAR_COLORS;
  settings.antialias = false;   /* keep the region mask's edge hard, away from the line */
  before = undo_depth (image);
  CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 2, 2 }, &settings, NULL) ==
         GLIMS_STATUS_OK && undo_depth (image) == before + 1,
         "a similar-colors pattern fill runs as one undo step");
  render_pixel (image, W / 2, H / 2, px);
  CHECK (px[0] < 64, "the painted line keeps its color inside the filled region (%d,%d,%d)", px[0], px[1], px[2]);
  worst = tiled_region_diff (image, (GlimsRect) { 0, 0, W, H / 2 - 8 }, 0, 0, &thumbs[0], &covered);
  CHECK (worst <= 2, "the seeded area matches the tiled thumbnail (worst %d over %d px)", worst, covered);
  render_pixel (image, 2, H - 2, px);
  CHECK (px[0] == 255 && px[1] == 255 && px[2] == 255,
         "the region beyond the line is untouched (%d,%d,%d)", px[0], px[1], px[2]);
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK, "undo removes the similar-colors fill");
  settings.mode = GLIMS_FILL_SELECTION;
  settings.antialias = true;

  /* Layer offset: the pattern is tiled from the drawable's origin, so a
   * moved layer shifts it; outside its bounds the background shows. */
  CHECK (api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer2, NULL) == GLIMS_STATUS_OK && layer2 > 0,
         "a transparent layer is added and selected");
  CHECK (api->layer_move (engine, image, layer2, 12, 8) == GLIMS_STATUS_OK, "the layer moves by 12,8");
  CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) == GLIMS_STATUS_OK,
         "filling the moved layer runs");
  worst = tiled_region_diff (image, (GlimsRect) { 12, 8, W - 12, H - 8 }, 12, 8, &thumbs[0], &covered);
  CHECK (covered == (W - 12) * (H - 8) && worst <= 2,
         "the moved layer's pixels match the thumbnail tiled from its own origin (worst %d over %d px)",
         worst, covered);
  render_pixel (image, 5, 5, px);
  CHECK (px[0] == 255 && px[1] == 255 && px[2] == 255,
         "outside the moved layer's bounds the white background shows (%d,%d,%d)", px[0], px[1], px[2]);
  api->image_undo (engine, image);

  /* Alpha lock alone does not refuse, as with painting; the engine then
   * enforces it through the drawable's active components: on an opaque
   * layer the fill changes color but not alpha. A pixel lock refuses
   * outright, without touching pixels or history. */
  {
    GlimsFillSettings solid = { .struct_size = sizeof solid, .mode = GLIMS_FILL_SELECTION,
                                 .color = { 1, 0, 0, 1 }, .opacity = 1 };

    CHECK (api->fill (engine, image, (GlimsPoint) { 0, 0 }, &solid, NULL) == GLIMS_STATUS_OK,
           "the moved layer is filled solid red, so it is opaque");
  }
  CHECK (api->set_layer_locks (engine, image, layer2, GLIMS_LOCK_ALPHA, GLIMS_LOCK_ALPHA, NULL) ==
         GLIMS_STATUS_OK, "the alpha lock is set");
  renderBefore = render_all (image, &w1, &h1);
  before = undo_depth (image);
  CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
         GLIMS_STATUS_OK && undo_depth (image) == before + 1,
         "an alpha-locked layer still accepts a pattern fill (not blanket-rejected)");
  {
    uint8_t *after = render_all (image, &w1, &h1);
    int changed = renderBefore && after ? count_differences (renderBefore, after, (size_t) w1 * h1 * 4) : -1;
    int j, alpha_kept = 1;

    if (after)
      for (j = 0; j < w1 * h1; j++)
        if (after[j * 4 + 3] != 255)
          alpha_kept = 0;
    CHECK (changed > 0 && alpha_kept,
           "the alpha-locked fill changed the color but kept alpha opaque (%d px differ, alpha %s)",
           changed, alpha_kept ? "255 everywhere" : "changed");
    free (after);
  }
  api->image_undo (engine, image);
  api->image_undo (engine, image);   /* the solid red fill too */
  CHECK (api->set_layer_locks (engine, image, layer2, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL) ==
         GLIMS_STATUS_OK, "the pixel lock is set");
  before = undo_depth (image);
  {
    uint8_t *locked = render_all (image, &w1, &h1);
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_LOCKED && undo_depth (image) == before,
           "a pixel-locked target is refused with LOCKED and no undo step");
    {
      uint8_t *after = render_all (image, &w1, &h1);
      CHECK (locked && after && count_differences (locked, after, (size_t) w1 * h1 * 4) == 0,
             "the refused fill changed no pixels");
      free (after);
    }
    free (locked);
  }
  api->set_layer_locks (engine, image, layer2, GLIMS_LOCK_PIXELS | GLIMS_LOCK_ALPHA, 0, NULL);

  /* Mask routing: with mask editing on, the fill lands on the mask. */
  CHECK (api->layer_mask_add (engine, image, layer2, GLIMS_MASK_WHITE, true, &mask, NULL) == GLIMS_STATUS_OK &&
         mask != 0, "a white mask with editing on is added");
  {
    uint8_t thumbBefore[32 * 32 * 4], thumbAfter[32 * 32 * 4];
    int32_t tw = 0, th = 0;

    CHECK (api->drawable_thumbnail (engine, image, mask, 32, thumbBefore, sizeof thumbBefore, &tw, &th) ==
           GLIMS_STATUS_OK, "the mask's thumbnail renders before the fill");
    before = undo_depth (image);
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_OK && undo_depth (image) == before + 1,
           "a pattern fill on the editing mask runs as one undo step");
    CHECK (api->drawable_thumbnail (engine, image, mask, 32, thumbAfter, sizeof thumbAfter, &tw, &th) ==
           GLIMS_STATUS_OK && memcmp (thumbBefore, thumbAfter, sizeof thumbBefore) != 0,
           "the mask's thumbnail changed with the pattern");
    CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == before,
           "undo restores the mask");
    api->layer_mask_set (engine, image, layer2, GLIMS_MASK_EDITING, 0, NULL);
  }

  /* Channel routing: a selected channel is the fill target. */
  CHECK (api->select_command (engine, image, GLIMS_SELECT_ALL, 0, NULL) == GLIMS_STATUS_OK &&
         api->channel_from_selection (engine, image, "pat", &channel, NULL) == GLIMS_STATUS_OK && channel != 0,
         "the selection is saved as a selected channel");
  {
    uint8_t thumbBefore[32 * 32 * 4], thumbAfter[32 * 32 * 4];
    int32_t tw = 0, th = 0;

    CHECK (api->drawable_thumbnail (engine, image, channel, 32, thumbBefore, sizeof thumbBefore, &tw, &th) ==
           GLIMS_STATUS_OK, "the channel's thumbnail renders before the fill");
    before = undo_depth (image);
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_OK && undo_depth (image) == before + 1,
           "a pattern fill on the selected channel runs as one undo step");
    CHECK (api->drawable_thumbnail (engine, image, channel, 32, thumbAfter, sizeof thumbAfter, &tw, &th) ==
           GLIMS_STATUS_OK && memcmp (thumbBefore, thumbAfter, sizeof thumbBefore) != 0,
           "the channel's thumbnail changed with the pattern");
    api->image_undo (engine, image);
    api->channel_command (engine, image, 0, GLIMS_CHANNEL_SELECT, NULL, NULL);
    api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  }

  /* Invalid handles: range, high bits, stale, wrong kind. */
  before = undo_depth (image);
  {
    GlimsResourceInfo row;
    int32_t           n = 0;
    GlimsResourceID   brush_id = 0, gradient_id = 0;

    if (api->resources (engine, GLIMS_RESOURCE_BRUSH, &row, 1, &n) == GLIMS_STATUS_OK && n > 0)
      brush_id = row.id;
    if (api->resources (engine, GLIMS_RESOURCE_GRADIENT, &row, 1, &n) == GLIMS_STATUS_OK && n > 0)
      gradient_id = row.id;

    CHECK (api->fill_pattern (engine, image, 0, (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT &&
           api->fill_pattern (engine, image, UINT64_MAX, (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT &&
           api->fill_pattern (engine, image, (UINT64_C (1) << 32) | patterns[0], (GlimsPoint) { 0, 0 },
                              &settings, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
           api->fill_pattern (engine, image, 0x80000000ull, (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT,
           "zero, all-high, high-bit and above-range handles are refused");
    CHECK (api->fill_pattern (engine, image, 0x7FFFFFFFull, (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_NOT_FOUND,
           "a well-shaped but unissued handle reports NOT_FOUND");
    CHECK ((! brush_id || api->fill_pattern (engine, image, brush_id, (GlimsPoint) { 0, 0 }, &settings, NULL) ==
            GLIMS_STATUS_NOT_FOUND) &&
           (! gradient_id || api->fill_pattern (engine, image, gradient_id, (GlimsPoint) { 0, 0 }, &settings, NULL) ==
            GLIMS_STATUS_NOT_FOUND),
           "a brush or gradient handle is NOT_FOUND, not a pattern");
    CHECK (undo_depth (image) == before, "the refused handles changed no history");
  }

  /* Bad settings and seeds are refused, not clamped. */
  {
    GlimsPatternFillSettings bad;

    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, NULL, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "NULL settings are refused");
    bad = settings;
    bad.struct_size = sizeof (GlimsPatternFillSettings) - 1;
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &bad, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "a short settings struct is refused");
    bad = settings;
    bad.mode = 0;
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &bad, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "an unknown mode is refused");
    bad.mode = 3;
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &bad, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "mode 3 is refused");
    bad = settings;
    bad.opacity = NAN;
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &bad, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "a NaN opacity is refused");
    bad.opacity = 1.5;
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &bad, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "opacity 1.5 is refused, not clamped");
    bad.opacity = -0.1;
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &bad, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "a negative opacity is refused");
    bad = settings;
    bad.threshold = 2.0;
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &bad, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "threshold 2 is refused, not clamped");
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { NAN, 0 }, &settings, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "a NaN seed is refused");
    CHECK (api->fill_pattern (engine, -1234, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_NOT_FOUND, "an unknown image reports NOT_FOUND");
    CHECK (undo_depth (image) == before, "the bad settings changed no history");
  }

  /* BUSY: an active stroke, a filter preview and a running plug-in each
   * refuse without pixel or history changes. */
  {
    GlimsBrushSettings  brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
    GlimsStrokePoint    point = { 4, 4, 1.0, 0.0, 0.0, 0 };

    CHECK (api->stroke_begin (engine, image, layer2, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK,
           "a stroke starts");
    before = undo_depth (image);
    render_pixel (image, W / 2, H / 2, px);
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_BUSY && undo_depth (image) == before,
           "an active stroke refuses the fill with BUSY and no history change");
    {
      uint8_t px2[4];
      render_pixel (image, W / 2, H / 2, px2);
      CHECK (memcmp (px, px2, 4) == 0, "the refused fill changed no pixels");
    }
    api->stroke_end (engine, stroke);
    stroke = 0;

    CHECK (api->filter_begin (engine, image, layer2, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK,
           "a filter preview opens");
    before = undo_depth (image);
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_BUSY && undo_depth (image) == before,
           "a live filter preview refuses the fill with BUSY and no history change");
    api->filter_abort (engine, filter);
    filter = 0;

    CHECK (api->image_new (engine, 6000, 4000, &scratch, NULL) == GLIMS_STATUS_OK,
           "a big image keeps a plug-in busy");
    {
      BackgroundRun run = { 0 };
      pthread_t     thread;
      GlimsStatus   status = GLIMS_STATUS_OK;

      run.image = scratch;
      run.name  = "plug-in-checkerboard";
      atomic_store (&progress_active, false);
      pthread_create (&thread, NULL, background_run, &run);
      wait_for_progress (&run);
      {
        int was_running = ! atomic_load (&run.finished);

        if (was_running)
          {
            before = undo_depth (image);
            status = api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL);
          }
        pthread_join (thread, NULL);
        CHECK (! was_running || (status == GLIMS_STATUS_BUSY && undo_depth (image) == before),
               "while a plug-in runs, the fill reports BUSY with no history change (%d)", status);
      }
    }
    api->image_close (engine, scratch);
    scratch = 0;
  }

  /* Zero opacity and an empty selection, as the native fill behaves:
   * opacity 0 succeeds and records the undo step but changes no pixels;
   * an empty selection succeeds as a no-op with no undo step. */
  {
    settings.opacity = 0;
    before = undo_depth (image);
    render_pixel (image, W / 2, H / 2, px);
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, &error) ==
           GLIMS_STATUS_OK, "a zero-opacity fill succeeds%s%s", error ? ": " : "", error ? error : "");
    api->free_string (error);
    error = NULL;
    CHECK (undo_depth (image) == before + 1,
           "the native fill still records the undo step at opacity 0 (%d -> %d)", before, undo_depth (image));
    {
      uint8_t px2[4];
      render_pixel (image, W / 2, H / 2, px2);
      CHECK (memcmp (px, px2, 4) == 0, "opacity 0 changed no pixels");
    }
    api->image_undo (engine, image);
    settings.opacity = 1;

    /* Select None means no selection at all: the whole drawable is
     * filled, as the fill contract says. The true no-op is a selection
     * that does not intersect the drawable. */
    before = undo_depth (image);
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, NULL) ==
           GLIMS_STATUS_OK && undo_depth (image) == before + 1,
           "with no selection the whole drawable is filled as one undo step");
    api->image_undo (engine, image);

    CHECK (api->layer_move (engine, image, layer2, W + 8, H + 8) == GLIMS_STATUS_OK &&
           api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                              (GlimsPoint[]) { { 0, 0 }, { 10, 10 } }, 2, NULL) == GLIMS_STATUS_OK,
           "the target layer moves out of the canvas and a rectangle is selected");
    before = undo_depth (image);
    render_pixel (image, 5, 5, px);
    CHECK (api->fill_pattern (engine, image, patterns[0], (GlimsPoint) { 0, 0 }, &settings, &error) ==
           GLIMS_STATUS_OK && undo_depth (image) == before,
           "a selection disjoint from the drawable is a no-op: OK with no undo step%s%s",
           error ? ": " : "", error ? error : "");
    api->free_string (error);
    error = NULL;
    {
      uint8_t px2[4];
      render_pixel (image, 5, 5, px2);
      CHECK (memcmp (px, px2, 4) == 0, "the disjoint-selection fill changed no pixels");
    }
    api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
    api->layer_move (engine, image, layer2, -(W + 8), -(H + 8));
  }

  api->image_close (engine, image);

out:
  if (thumbs[0].pixels) api->free_pixels (thumbs[0].pixels);
  if (thumbs[1].pixels) api->free_pixels (thumbs[1].pixels);
  free (renderA);
  free (renderB);
  free (renderBefore);
}

/* Selected-resource gradients: the builtin FG to BG (RGB) resolved by
 * its stable internal collection, drawn through every blend space, plus
 * a second stock gradient, reverse, opacity, selection clipping, the
 * layer-offset coordinate space, mask and channel routing, locks,
 * handle and settings refusals, and BUSY while a stroke or a filter
 * session is open.
 *
 * The midpoint oracles come from the native blending rules, not from
 * observed output: at factor 0.5 a black-to-white ramp is sRGB 0.5
 * (~128) blended in the encoded components (perceptual), sRGB ~188 for
 * a linear-light blend (0.5 linear encodes near 0.735), and ~119 for a
 * CIE Lab blend (L* 50). The factor at a pixel is taken at the pixel's
 * center: drawing (0, y) -> (100, y) puts the pixel column 50 at t =
 * 0.505, so tolerances stay wide and only ordering and ranges assert. */
static void
test_resource_gradient (void)
{
  GlimsImageID                     image = 0;
  GlimsItemID                      layer, mask = 0, channel = 0, group = 0;
  GlimsResourceID                  fg_bg = 0, stock = 0, brush_id = 0;
  GlimsResourceInfo                rows[16];
  GlimsSelectOptions               sel = { .struct_size = sizeof sel,
                                           .operation = GLIMS_SELECT_REPLACE };
  GlimsResourceGradientSettings    g = { .struct_size = sizeof g,
                                         .shape = GLIMS_GRADIENT_LINEAR,
                                         .foreground = { 0, 0, 0, 1 },
                                         .background = { 1, 1, 1, 1 },
                                         .opacity = 1,
                                         .blend_space = GLIMS_GRADIENT_BLEND_RGB_PERCEPTUAL };
  GlimsBrushSettings               brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  GlimsStrokePoint                 point = { 5, 5, 1.0, 0.0, 0.0, 0 };
  GlimsStrokeID                    stroke = 0;
  GlimsFilterID                    filter = 0;
  GlimsRect                        bounds;
  GlimsStatus                      status;
  bool                             empty_sel = true;
  int32_t                          count = 0, before, i;
  uint8_t                          px[4], prev[4];
  uint8_t                         *ramp = NULL, *other = NULL;
  int32_t                          rw = 0, rh = 0;
  char                            *error = NULL;

  /* The dynamic builtin resolves by identity; the display name is
   * localized and never the key. A second stock gradient (not FG/BG)
   * and one brush handle supply the wrong-kind and differing-resource
   * checks. */
  CHECK (api->resource_resolve (engine, GLIMS_RESOURCE_GRADIENT, "FG to BG",
                                "gimp-gradient-fg-bg-rgb", true, &fg_bg, NULL) == GLIMS_STATUS_OK &&
         fg_bg != 0,
         "the FG to BG (RGB) resource resolves by its internal identity");
  CHECK (api->resources (engine, GLIMS_RESOURCE_GRADIENT, rows,
                         (int32_t) (sizeof rows / sizeof rows[0]), &count) == GLIMS_STATUS_OK &&
         count > 0,
         "stock gradients are listed for the second-resource check (%d)", count);
  for (i = 0; i < count && i < 16; i++)
    if (rows[i].id != fg_bg && ! stock)
      stock = rows[i].id;
  CHECK (stock != 0 && stock != fg_bg, "a second stock gradient is listed (%llu)",
         (unsigned long long) stock);
  CHECK (api->resources (engine, GLIMS_RESOURCE_BRUSH, rows,
                         (int32_t) (sizeof rows / sizeof rows[0]), &count) == GLIMS_STATUS_OK &&
         count > 0 && (brush_id = rows[0].id) != 0,
         "a brush handle supplies the wrong-kind check");

  api->image_new (engine, 100, 80, &image, NULL);
  layer = first_layer (image);

  /* Perceptual black -> white, left to right. Pixel centers put column
   * 50 at t = 0.505, inside the perceptual midpoint tolerance. */
  before = undo_depth (image);
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, &error) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1,
         "a selected-resource gradient draws as one undo step%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  render_pixel (image, 3, 40, px);
  CHECK (px[0] < 60, "the ramp starts near black (%d)", px[0]);
  render_pixel (image, 97, 40, px);
  CHECK (px[0] > 200, "the ramp ends near white (%d)", px[0]);
  render_pixel (image, 50, 40, px);
  CHECK (px[0] >= 115 && px[0] <= 142,
         "the perceptual midpoint is near sRGB 128 (%d)", px[0]);

  ramp = render_all (image, &rw, &rh);

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         (render_pixel (image, 50, 40, px), px[0] == 255) &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK &&
         (render_pixel (image, 50, 40, px), px[0] >= 115 && px[0] <= 142),
         "undo and redo restore and redraw the resource gradient");
  api->image_undo (engine, image);

  /* A known native fallthrough prevents correct linear-light blending.
   * Refuse the advertised mode without touching pixels or undo. */
  g.blend_space = GLIMS_GRADIENT_BLEND_RGB_LINEAR;
  before = undo_depth (image);
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, &error) == GLIMS_STATUS_UNSUPPORTED && error != NULL &&
         undo_depth (image) == before &&
         (render_pixel (image, 50, 40, px), px[0] == 255 && px[1] == 255 && px[2] == 255),
         "unsupported linear-light blending leaves pixels and undo untouched");
  api->free_string (error);
  error = NULL;

  /* CIE Lab: L* 50 lands around sRGB 119, darker than perceptual 128
   * and far below the linear midpoint. */
  g.blend_space = GLIMS_GRADIENT_BLEND_CIE_LAB;
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_OK &&
         (render_pixel (image, 50, 40, px), px[0] >= 105 && px[0] <= 135),
         "the Lab midpoint is near sRGB 119 (%d)", px[0]);
  api->image_undo (engine, image);
  g.blend_space = GLIMS_GRADIENT_BLEND_RGB_PERCEPTUAL;

  /* Reverse flips the ramp without swapping the endpoints. */
  g.reverse = true;
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_OK &&
         (render_pixel (image, 3, 40, px), px[0] > 200) &&
         (render_pixel (image, 97, 40, px), px[0] < 60),
         "reverse runs the resource's stops end to start (%d, %d)",
         red_at (image, 3, 40), px[0]);
  api->image_undo (engine, image);
  g.reverse = false;

  /* A second stock resource paints different stops: no fallback to
   * FG/BG when the handle names something else. Another grayscale
   * FG/BG sibling could render identically, so the first listed
   * gradient whose render differs from both the saved FG/BG ramp and
   * the white baseline is the witness. */
  other = render_all (image, &rw, &rh); /* all-white baseline */
  CHECK (api->resources (engine, GLIMS_RESOURCE_GRADIENT, rows,
                         (int32_t) (sizeof rows / sizeof rows[0]), &count) == GLIMS_STATUS_OK,
         "the gradients list again (%d)", count);
  stock = 0;
  for (i = 0; i < count && i < 16; i++)
    {
      int32_t  w = 0, h = 0;
      uint8_t *drawn;

      if (rows[i].id == fg_bg)
        continue;
      CHECK (api->gradient_resource (engine, image, rows[i].id,
                                     (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                     &g, NULL) == GLIMS_STATUS_OK,
             "stock gradient %s draws", rows[i].name);
      drawn = render_all (image, &w, &h);
      api->image_undo (engine, image);
      if (drawn && ramp && other && w == rw && h == rh &&
          memcmp (drawn, ramp, (size_t) w * h * 4) != 0 &&
          memcmp (drawn, other, (size_t) w * h * 4) != 0)
        {
          stock = rows[i].id;
          free (drawn);
          break;
        }
      free (drawn);
    }
  CHECK (stock != 0, "a second stock gradient renders its own stops (%llu)",
         (unsigned long long) stock);
  free (other);
  other = NULL;

  /* Opacity 0.5 blends the ramp halfway onto the white layer. */
  g.opacity = 0.5;
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_OK &&
         (render_pixel (image, 50, 40, px), px[0] > 160 && px[0] < 240),
         "half opacity blends the midpoint toward white (%d)", px[0]);
  api->image_undo (engine, image);
  g.opacity = 1.0;

  /* The selection clips the draw and survives it. */
  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) { { 0, 0 }, { 40, 80 } }, 2, &sel) == GLIMS_STATUS_OK,
         "a left strip is selected");
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_OK &&
         (render_pixel (image, 20, 40, px), px[0] < 220) &&
         (render_pixel (image, 70, 40, px), px[0] == 255) &&
         api->selection_bounds (engine, image, &empty_sel, &bounds) == GLIMS_STATUS_OK &&
         ! empty_sel && rect_equals (bounds, 0, 0, 40, 80),
         "the gradient stays inside the selection and the selection is preserved");
  api->image_undo (engine, image); /* the gradient; the strip survives */
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);

  /* Endpoints are image coordinates: the moved layer's pixels shift
   * with it, and image area outside the layer is untouched. */
  CHECK (api->layer_move (engine, image, layer, 10, 0) == GLIMS_STATUS_OK,
         "the layer moves 10 px right");
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_OK &&
         (render_pixel (image, 15, 40, px), px[0] < 150) &&
         (render_pixel (image, 5, 40, px), px[3] == 0),
         "image coordinates hit the offset layer, not the canvas edge (x15 %d, x5 alpha %d)",
         red_at (image, 15, 40), px[3]);
  api->image_undo (engine, image);
  CHECK (api->layer_move (engine, image, layer, -10, 0) == GLIMS_STATUS_OK,
         "the layer moves back");

  /* Mask editing routes the same call onto the mask: white to black
   * fades the layer out toward the right (a shaded mask still covers
   * the canvas, so the composite's falloff is the oracle). */
  g.foreground = (GlimsColor) { 1, 1, 1, 1 };
  g.background = (GlimsColor) { 0, 0, 0, 1 };
  CHECK (api->layer_mask_add (engine, image, layer, GLIMS_MASK_WHITE, false, &mask, NULL) == GLIMS_STATUS_OK &&
         mask != 0 &&
         api->layer_mask_set (engine, image, layer, GLIMS_MASK_EDITING, GLIMS_MASK_EDITING, NULL) == GLIMS_STATUS_OK,
         "a white mask is added and edited");
  before = undo_depth (image);
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         red_at (image, 10, 40) > 150 && red_at (image, 90, 40) < 80,
         "the resource gradient shades the mask it edits (%d left, %d right)",
         red_at (image, 10, 40), red_at (image, 90, 40));
  api->image_undo (engine, image);  /* the mask gradient */
  api->layer_mask_set (engine, image, layer, GLIMS_MASK_EDITING, 0, NULL);

  /* A selected channel is the edit target too: the ramp adds coverage. */
  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                            (GlimsPoint[]) { { 0, 0 }, { 20, 80 } }, 2, &sel) == GLIMS_STATUS_OK &&
         api->channel_from_selection (engine, image, "grad", &channel, NULL) == GLIMS_STATUS_OK &&
         channel != 0 &&
         api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL) == GLIMS_STATUS_OK &&
         api->channel_command (engine, image, channel, GLIMS_CHANNEL_SELECT, NULL, NULL) == GLIMS_STATUS_OK,
         "a saved channel becomes the edit target");
  before = undo_depth (image);
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_OK &&
         undo_depth (image) == before + 1 &&
         api->channel_to_selection (engine, image, channel, GLIMS_SELECT_REPLACE, NULL) == GLIMS_STATUS_OK &&
         api->selection_bounds (engine, image, &empty_sel, &bounds) == GLIMS_STATUS_OK &&
         ! empty_sel && bounds.x == 0 && bounds.width > 20,
         "the channel gradient extends its coverage as one undo step (%d,%d %dx%d)",
         bounds.x, bounds.y, bounds.width, bounds.height);
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  api->image_undo (engine, image);
  api->channel_command (engine, image, 0, GLIMS_CHANNEL_SELECT, NULL, NULL);
  api->channel_command (engine, image, channel, GLIMS_CHANNEL_DELETE, NULL, NULL);
  g.foreground = (GlimsColor) { 0, 0, 0, 1 };
  g.background = (GlimsColor) { 1, 1, 1, 1 };

  /* Locks: pixel-locked pixels refuse LOCKED with no undo; an alpha
   * lock alone does not refuse an opaque ramp. */
  CHECK (api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, GLIMS_LOCK_PIXELS, NULL) == GLIMS_STATUS_OK,
         "the layer's pixels are locked");
  before = undo_depth (image);
  render_pixel (image, 50, 40, prev);
  status = api->gradient_resource (engine, image, fg_bg,
                                   (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                   &g, &error);
  CHECK (status == GLIMS_STATUS_LOCKED && error && undo_depth (image) == before &&
         (render_pixel (image, 50, 40, px), memcmp (prev, px, sizeof px) == 0),
         "a pixel-locked layer refuses LOCKED with no undo (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  api->set_layer_locks (engine, image, layer, GLIMS_LOCK_PIXELS, 0, NULL);
  CHECK (api->set_layer_locks (engine, image, layer, GLIMS_LOCK_ALPHA, GLIMS_LOCK_ALPHA, NULL) == GLIMS_STATUS_OK &&
         api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_OK &&
         red_at (image, 50, 40) < 240,
         "an alpha-locked layer still accepts an opaque gradient");
  api->set_layer_locks (engine, image, layer, GLIMS_LOCK_ALPHA, 0, NULL);
  api->image_undo (engine, image);

  /* Handle refusals: 0 and out-of-range are INVALID_ARGUMENT; in-range
   * but stale, recycled-high-bit, and wrong-kind handles are NOT_FOUND.
   * None mutates pixels or history. */
  before = undo_depth (image);
  render_pixel (image, 50, 40, prev);
  CHECK (api->gradient_resource (engine, image, 0,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->gradient_resource (engine, image, 0xFFFFFFFFFFFFFFFFull,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->gradient_resource (engine, image, 0x80000000ull,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->gradient_resource (engine, image, (UINT64_C(1) << 32) | fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "resource handles outside the issued range are refused");
  CHECK (api->gradient_resource (engine, image, 0x7FFFFFFFull,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_NOT_FOUND &&
         api->gradient_resource (engine, image, brush_id,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_NOT_FOUND,
         "a stale or wrong-kind handle is NOT_FOUND with no fallback");
  CHECK (undo_depth (image) == before &&
         (render_pixel (image, 50, 40, px), memcmp (prev, px, sizeof px) == 0),
         "the refused handles changed no pixels and no history");

  /* Settings refusals, each with no undo step. */
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &(GlimsResourceGradientSettings) { .struct_size = 4 },
                                 NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "NULL or short settings are refused");
  g.shape = 9;
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown shape is refused");
  g.shape = GLIMS_GRADIENT_LINEAR;
  g.blend_space = 9;
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown blend space is refused");
  g.blend_space = GLIMS_GRADIENT_BLEND_RGB_PERCEPTUAL;
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 40, 40 }, (GlimsPoint) { 40, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { NAN, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "coincident and non-finite endpoints are refused");
  g.opacity = NAN;
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a non-finite opacity is refused");
  g.opacity = 1.5;
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an opacity above 1 is refused");
  g.opacity = 1.0;
  g.foreground.alpha = 0.5;
  status = api->gradient_resource (engine, image, fg_bg,
                                   (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                   &g, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && error,
         "a translucent endpoint color is refused, not ignored (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  g.foreground = (GlimsColor) { 0, 0, 0, 1 };
  g.foreground.red = NAN;
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a non-finite endpoint color is refused");
  g.foreground.red = 0;
  CHECK (undo_depth (image) == before, "the refused settings pushed no undo");

  /* A group as the paint target is a clear failure, not a draw. */
  CHECK (api->create_group (engine, image, 0, 0, "G", &group, NULL) == GLIMS_STATUS_OK && group != 0,
         "a group is created");
  status = api->gradient_resource (engine, image, fg_bg,
                                   (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                   &g, &error);
  CHECK (status == GLIMS_STATUS_FAILED && error,
         "drawing onto a group target fails clearly (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  api->layer_select (engine, image, layer);
  api->layer_command (engine, image, group, GLIMS_LAYER_DELETE, NULL, NULL);

  /* BUSY while a stroke or a filter session is open, with the pixels
   * and history untouched and the sessions left running. */
  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK,
         "a stroke begins for the busy check");
  before = undo_depth (image);
  render_pixel (image, 50, 40, prev);
  CHECK (api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_BUSY &&
         undo_depth (image) == before &&
         (render_pixel (image, 50, 40, px), memcmp (prev, px, sizeof px) == 0),
         "drawing during an open stroke is BUSY with no change");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "the stroke still ends");
  api->image_undo (engine, image); /* the stroke itself */
  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK &&
         api->gradient_resource (engine, image, fg_bg,
                                 (GlimsPoint) { 0, 40 }, (GlimsPoint) { 100, 40 },
                                 &g, NULL) == GLIMS_STATUS_BUSY &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "drawing during an open filter session is BUSY%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  free (ramp);
  api->image_close (engine, image);
}

static void
test_procedures (void)
{
  const char         *checkerboard = "plug-in-checkerboard";
  GlimsProcedureInfo *rows = NULL;
  GlimsImageID        image = 0, big = 0;
  int32_t             count = 0, filled = 0, before, width, height, i;
  const GlimsProcedureInfo *found = NULL;
  uint8_t            *pixels;
  char               *error = NULL;
  double              start;
  BackgroundRun       run = { 0 };
  pthread_t           thread;
  GlimsStatus         undo_status = GLIMS_STATUS_OK, run_status = GLIMS_STATUS_OK;

  api->image_new (engine, 64, 48, &image, NULL);

  CHECK (api->procedures (engine, image, NULL, 0, &count) == GLIMS_STATUS_OK && count > 20,
         "procedures: %d plug-in commands with menu entries", count);
  rows = calloc ((size_t) (count > 0 ? count : 1), sizeof *rows);
  CHECK (api->procedures (engine, image, rows, count, &filled) == GLIMS_STATUS_OK && filled == count,
         "procedures fills every row");
  for (i = 0; i < filled; i++)
    if (strcmp (rows[i].name, checkerboard) == 0)
      found = &rows[i];
  CHECK (found && strcmp (found->label, "Checkerboard (legacy)\xe2\x80\xa6") == 0 &&
         strncmp (found->menu_path, "<Image>/Filters/Render", 22) == 0 && found->sensitive,
         "%s: label \"%s\", menu \"%s\", runnable on an RGB layer", checkerboard,
         found ? found->label : "", found ? found->menu_path : "");
  CHECK (api->procedures (engine, 9999, NULL, 0, &count) == GLIMS_STATUS_NOT_FOUND,
         "procedures reports an unknown image");

  CHECK (api->procedure_run (engine, image, "plug-in-no-such-thing", GLIMS_RUN_WITH_LAST_VALUES, NULL) == GLIMS_STATUS_NOT_FOUND,
         "an unknown procedure is reported");
  CHECK (api->procedure_run (engine, image, checkerboard, 77, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "an unknown run mode is rejected");
  CHECK (api->procedure_cancel (engine) == GLIMS_STATUS_NOT_FOUND, "cancel with nothing running is reported");
  {
    GlimsFilterID session = 0;

    api->filter_begin (engine, image, first_layer (image), "gegl:gaussian-blur", &session, NULL);
    CHECK (api->procedure_run (engine, image, checkerboard, GLIMS_RUN_WITH_LAST_VALUES, &error) == GLIMS_STATUS_BUSY,
           "no plug-in runs while a filter preview is open (%s)", error ? error : "");
    api->free_string (error);
    error = NULL;
    api->filter_abort (engine, session);
  }

  before = undo_depth (image);
  start  = now_ms ();
  CHECK (api->procedure_run (engine, image, checkerboard, GLIMS_RUN_WITH_LAST_VALUES, &error) == GLIMS_STATUS_OK,
         "%s runs with its last values (%.0f ms)%s%s", checkerboard, now_ms () - start,
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (undo_depth (image) == before + 1, "the plug-in's work is one undo step (%d -> %d)", before, undo_depth (image));
  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixel_at (pixels, width, 5, 5)[0] != pixel_at (pixels, width, 15, 5)[0] &&
         pixel_at (pixels, width, 5, 5)[0] == pixel_at (pixels, width, 15, 15)[0],
         "the image shows 10-pixel checks (%d, %d, %d)",
         pixels ? pixel_at (pixels, width, 5, 5)[0] : -1, pixels ? pixel_at (pixels, width, 15, 5)[0] : -1,
         pixels ? pixel_at (pixels, width, 15, 15)[0] : -1);
  free (pixels);
  CHECK (atomic_load (&progress_starts) >= 1 && atomic_load (&progress_ends) == atomic_load (&progress_starts) &&
         ! atomic_load (&progress_active),
         "progress events started and ended (%d)", atomic_load (&progress_starts));
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && undo_depth (image) == before,
         "undo removes the plug-in's work");

  /* While a procedure runs, writes are refused and reads still work. A
   * large image keeps the plug-in busy long enough to probe it. */
  api->image_new (engine, 6000, 4000, &big, NULL);
  run.image = big;
  run.name  = checkerboard;
  atomic_store (&progress_active, false);
  pthread_create (&thread, NULL, background_run, &run);
  wait_for_progress (&run);
  if (! atomic_load (&run.finished))
    {
      GlimsImageInfo info;

      GlimsImageID opened = 0;

      undo_status = api->image_undo (engine, image);
      run_status  = api->procedure_run (engine, image, checkerboard, GLIMS_RUN_WITH_LAST_VALUES, NULL);
      CHECK (api->image_open (engine, "/nonexistent.png", &opened, NULL) == GLIMS_STATUS_BUSY,
             "opening a file waits for the running plug-in (BUSY)");
      CHECK (api->image_info (engine, image, &info) == GLIMS_STATUS_OK, "reads work while a plug-in runs");
    }
  pthread_join (thread, NULL);
  CHECK (undo_status == GLIMS_STATUS_BUSY && run_status == GLIMS_STATUS_BUSY && run.status == GLIMS_STATUS_OK,
         "while a plug-in runs, undo and a second run report BUSY (%d, %d; run %d)",
         undo_status, run_status, run.status);

  /* Cancel, as the progress bar's Cancel button does. */
  before = undo_depth (big);
  atomic_store (&run.finished, false);
  atomic_store (&progress_active, false);
  undo_status = GLIMS_STATUS_FAILED;
  pthread_create (&thread, NULL, background_run, &run);
  wait_for_progress (&run);
  if (! atomic_load (&run.finished))
    undo_status = api->procedure_cancel (engine);
  pthread_join (thread, NULL);
  CHECK (undo_status == GLIMS_STATUS_OK && run.status == GLIMS_STATUS_CANCELLED && undo_depth (big) == before,
         "cancelling a running plug-in returns CANCELLED and leaves no undo step (cancel %d, run %d)",
         undo_status, run.status);

  /* Plug-ins in Python and Script-Fu go through interpreters, typelibs
   * and environment the C plug-ins above do not need. */
  {
    GlimsImageID   other = 0;
    GlimsImageInfo info_before, info_after;

    api->image_new (engine, 64, 48, &other, NULL);
    api->image_info (engine, other, &info_before);
    error = NULL;
    start = now_ms ();
    CHECK (api->procedure_run (engine, other, "python-fu-foggify", GLIMS_RUN_WITH_LAST_VALUES, &error) == GLIMS_STATUS_OK &&
           api->image_info (engine, other, &info_after) == GLIMS_STATUS_OK &&
           info_after.layer_count == info_before.layer_count + 1,
           "a Python plug-in (Fog) adds its layer (%.0f ms)%s%s", now_ms () - start,
           error ? ": " : "", error ? error : "");
    api->free_string (error);
    error = NULL;

    api->image_info (engine, other, &info_before);
    start = now_ms ();
    CHECK (api->procedure_run (engine, other, "script-fu-addborder", GLIMS_RUN_WITH_LAST_VALUES, &error) == GLIMS_STATUS_OK &&
           api->image_info (engine, other, &info_after) == GLIMS_STATUS_OK &&
           info_after.width > info_before.width && info_after.height > info_before.height,
           "a Script-Fu script (Add Border) enlarges the image to %dx%d (%.0f ms)%s%s",
           info_after.width, info_after.height, now_ms () - start, error ? ": " : "", error ? error : "");
    api->free_string (error);
    api->image_close (engine, other);
  }

  free (rows);
  api->image_close (engine, big);
  api->image_close (engine, image);
}

static void
test_clear_srgb_and_readiness (const char *fixtures)
{
  GlimsImageID image = 0;
  GlimsItemID layer;
  GlimsFilterID filter = 0;
  GlimsStrokeID stroke = 0;
  GlimsColor midtone = { .5, .25, .75, 1 };
  GlimsSelectOptions options = { .struct_size = sizeof options, .antialias = false };
  GlimsPoint corners[] = { { 0, 0 }, { 1, 1 } };
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 1);
  GlimsStrokePoint point = { 1, 0, 1, 0, 0, 0 };
  uint8_t inside[4], outside[4];
  int32_t depth;
  char file[1024];

  /* The generated RGB PNG has no alpha channel. Clear therefore uses
   * the background color instead of making selected pixels transparent. */
  snprintf (file, sizeof file, "%s/profiled.png", fixtures);
  CHECK (api->image_open (engine, file, &image, NULL) == GLIMS_STATUS_OK,
         "the opaque RGB Clear color fixture opens");
  layer = first_layer (image);
  CHECK (api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE, corners, 2, &options) == GLIMS_STATUS_OK,
         "Clear's fixture selects only the first RGB pixel");
  depth = undo_depth (image);
  CHECK (api->image_clear (engine, image, &midtone, NULL) == GLIMS_STATUS_OK && undo_depth (image) == depth + 1,
         "Clear with a background color adds one undo step");
  render_pixel (image, 0, 0, inside);
  render_pixel (image, 1, 0, outside);
  CHECK (abs ((int)inside[0] - 128) <= 1 && abs ((int)inside[1] - 64) <= 1 &&
         abs ((int)inside[2] - 191) <= 1 && inside[3] == 255,
         "Clear interprets its background as sRGB midtones (%u,%u,%u,%u)",
         inside[0], inside[1], inside[2], inside[3]);
  CHECK (outside[0] == 0 && outside[1] == 255 && outside[2] == 0 && outside[3] == 255,
         "Clear preserves the RGB pixel outside the selection");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK &&
         (render_pixel (image, 0, 0, inside), inside[0] == 255 && inside[1] == 0 && inside[2] == 0) &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK,
         "Clear's sRGB background change undoes and redoes");

  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK,
         "a native preview holds the Clear target");
  depth = undo_depth (image);
  CHECK (api->image_clear (engine, image, &midtone, NULL) == GLIMS_STATUS_BUSY && undo_depth (image) == depth,
         "Clear refuses a native preview without adding history");
  if (filter) api->filter_abort (engine, filter);
  CHECK (api->stroke_begin (engine, image, layer, &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK,
         "an active stroke holds the Clear target");
  depth = undo_depth (image);
  CHECK (api->image_clear (engine, image, &midtone, NULL) == GLIMS_STATUS_BUSY && undo_depth (image) == depth,
         "Clear refuses an active stroke before editing");
  if (stroke) api->stroke_end (engine, stroke);
  api->image_close (engine, image);
}

static void
test_clipboard (void)
{
  GlimsImageID image = 0;
  GlimsPixelBuffer copied = { 0 }, merged = { 0 };
  GlimsItemID pasted = 0;
  uint8_t pixels[] = {255,0,0,255, 0,255,0,128, 0,0,255,255, 0,0,0,0};
  GlimsRect bounds = { 8, 10, 2, 2 };
  GlimsSelectOptions options = { .struct_size = sizeof options, .antialias = false };
  GlimsUndoInfo undo;
  CHECK (api->image_new (engine, 32, 32, &image, NULL) == GLIMS_STATUS_OK, "clipboard test image");
  CHECK (api->image_paste_pixels (engine, image, bounds, pixels, sizeof pixels, &pasted, NULL) == GLIMS_STATUS_OK &&
         pasted > 0 && layer_count (image) == 2, "paste creates a new RGBA layer");
  CHECK (api->image_undo_info (engine, image, &undo) == GLIMS_STATUS_OK && undo.undo_count == 1,
         "paste is one undo step");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && layer_count (image) == 1 &&
         api->image_redo (engine, image) == GLIMS_STATUS_OK && layer_count (image) == 2,
         "paste undo and redo restore the independent layer");
  CHECK (api->image_copy_pixels (engine, image, false, &copied, NULL) == GLIMS_STATUS_OK &&
         copied.bounds.x == 8 && copied.bounds.y == 10 && copied.bounds.width == 2 && copied.bounds.height == 2 &&
         copied.byte_count == sizeof pixels && memcmp (copied.pixels, pixels, sizeof pixels) == 0,
         "copy preserves layer offset, pixel order, straight alpha and extent");
  api->free_pixels (copied.pixels);
  CHECK (api->image_copy_pixels (engine, image, true, &merged, NULL) == GLIMS_STATUS_OK &&
         merged.bounds.width == 32 && merged.bounds.height == 32 && merged.pixels[3] == 255,
         "Copy Merged reads the composite rather than the selected layer");
  api->free_pixels (merged.pixels);
  api->select_shape (engine, image, GLIMS_SHAPE_ELLIPSE,
                     (GlimsPoint[]) { { 8, 10 }, { 10, 12 } }, 2, &options);
  CHECK (api->image_copy_pixels (engine, image, false, &copied, NULL) == GLIMS_STATUS_OK &&
         copied.bounds.width == 2 && copied.bounds.height == 2,
         "copy clips to selection bounds");
  api->free_pixels (copied.pixels);
  api->select_shape (engine, image, GLIMS_SHAPE_RECTANGLE,
                     (GlimsPoint[]) { { 8, 10 }, { 9, 11 } }, 2, &options);
  CHECK (api->image_clear (engine, image, NULL, NULL) == GLIMS_STATUS_OK &&
         api->image_copy_pixels (engine, image, false, &copied, NULL) == GLIMS_STATUS_OK && copied.pixels[3] == 0,
         "Clear erases selected pixels on an alpha layer");
  api->free_pixels (copied.pixels);
  api->image_undo (engine, image);
  CHECK (api->image_copy_pixels (engine, image, false, &copied, NULL) == GLIMS_STATUS_OK && copied.pixels[3] == 255,
         "Clear is undoable");
  api->free_pixels (copied.pixels);
  api->select_command (engine, image, GLIMS_SELECT_NONE, 0, NULL);
  CHECK (api->image_paste_pixels (engine, image, bounds, pixels, 1, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_paste_pixels (engine, image, (GlimsRect) {0,0,INT32_MAX,INT32_MAX}, pixels, sizeof pixels, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_copy_pixels (engine, image, false, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "clipboard rejects invalid buffers and dimensions");
  CHECK (api->image_copy_pixels (engine, -123, true, &copied, NULL) == GLIMS_STATUS_NOT_FOUND,
         "clipboard reports unknown images");
  {
    uint8_t opaque[6 * 6 * 4] = { 0 };
    for (int i = 0; i < 36; i++) { opaque[i * 4] = 255; opaque[i * 4 + 3] = 255; }
    api->image_paste_pixels (engine, image, (GlimsRect) { 8, 10, 6, 6 }, opaque, sizeof opaque, NULL, NULL);
    api->select_shape (engine, image, GLIMS_SHAPE_ELLIPSE,
                       (GlimsPoint[]) { {8, 10}, {14, 16} }, 2, &options);
    CHECK (api->image_copy_pixels (engine, image, false, &copied, NULL) == GLIMS_STATUS_OK &&
           copied.bounds.width == 6 && copied.bounds.height == 6 && copied.pixels[3] == 0 &&
           copied.pixels[(3 * 6 + 3) * 4 + 3] == 255,
           "copy carries nonrectangular selection alpha, not just its bounds");
    api->free_pixels (copied.pixels);
  }
  api->image_close (engine, image);
}

static int
supports_link_layers (void)
{
  int major = 0, minor = 0;
  sscanf (api->engine_version (engine), "%d.%d", &major, &minor);
  return major > 3 || (major == 3 && minor >= 2);
}

/* File > Open as Layers: the GIMP-made fixture lands in an open image
 * with its whole tree — order, groups, modes, masks, offsets — in one
 * undo step, above the selected layer; File > Place makes a link layer
 * on engines that have them. */
static void
test_place (const char *fixtures, const char *work)
{
  char           xcf[1024], png[1024], missing[1024], junk[1024];
  char           link_src[1024], placed_xcf[1024], dest_xcf[1024];
  GlimsImageID   dest = 0, scratch = 0, src = 0, reopened = 0, again = 0;
  GlimsLayerInfo rows[16], source_rows[16], after[16];
  GlimsItemID    added[8] = { 0 }, placed = 0, group = 0;
  GlimsItemID    layer = 0;
  GlimsStrokeID  stroke = 0;
  GlimsFilterID  filter = 0;
  GlimsStrokePoint point = { 4, 4, 1.0, 0.0, 0.0, 0 };
  GlimsBrushSettings brush = brush_for (GLIMS_PAINT_PAINTBRUSH, 9.0);
  GlimsFillSettings  red = { .struct_size = sizeof red, .mode = GLIMS_FILL_SELECTION,
                             .color = { 1, 0, 0, 1 }, .opacity = 1 };
  GlimsFillSettings  blue = { .struct_size = sizeof blue, .mode = GLIMS_FILL_SELECTION,
                              .color = { 0, 0, 1, 1 }, .opacity = 1 };
  GlimsImageInfo info;
  GlimsLayerChange rename = { .struct_size = sizeof rename, .properties = GLIMS_LAYER_NAME,
                              .name = "Base" };
  int32_t        count = 0, n = 0, src_count = 0, before, i;
  int            dx = 0, dy = 0, offsets_ok = 1, links;
  uint8_t       *pixels = NULL, *reference = NULL;
  uint8_t        corner[4] = { 0 };
  int32_t        w1, h1, w2, h2;
  char          *error = NULL;
  FILE          *file;
  BackgroundRun  run = { 0 };
  pthread_t      thread;
  GlimsStatus    status;

  snprintf (xcf, sizeof xcf, "%s/composite.xcf", fixtures);
  snprintf (png, sizeof png, "%s/composite.png", fixtures);
  snprintf (missing, sizeof missing, "%s/no-such-file.png", work);
  snprintf (junk, sizeof junk, "%s/not-an-image.txt", work);
  snprintf (link_src, sizeof link_src, "%s/link-source.png", work);
  snprintf (placed_xcf, sizeof placed_xcf, "%s/placed.xcf", work);
  snprintf (dest_xcf, sizeof dest_xcf, "%s/place-dest.xcf", work);

  links = supports_link_layers ();
  file  = fopen (junk, "w");
  if (file)
    {
      fputs ("this is not an image\n", file);
      fclose (file);
    }

  /* The fixture's own layer tree, to compare against the import. */
  CHECK (api->image_open (engine, xcf, &src, &error) == GLIMS_STATUS_OK &&
         api->image_layers (engine, src, source_rows, 16, &src_count) == GLIMS_STATUS_OK && src_count == 5,
         "the fixture's 5-layer tree is readable%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  api->image_close (engine, src);
  src = 0;
  if (src_count != 5)
    return;

  CHECK (api->image_new (engine, 320, 240, &dest, NULL) == GLIMS_STATUS_OK, "destination image 320x240");
  layer = first_layer (dest);
  CHECK (api->layer_change (engine, dest, layer, &rename, NULL) == GLIMS_STATUS_OK,
         "the destination layer is renamed to tell it from the imported one");
  before = undo_depth (dest);

  /* Above the only selected layer, at the top level, as one step. */
  CHECK (api->image_open_layers (engine, dest, xcf, added, 8, &n, &error) == GLIMS_STATUS_OK && n == 3,
         "open the fixture as layers: %d top-level items added%s%s", n, error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (n == 3 && added[0] > 0 && added[1] > 0 && added[2] > 0,
         "the call returns the top-level layer ids");
  CHECK (undo_depth (dest) == before + 1, "the whole import is one undo step (%d -> %d)",
         before, undo_depth (dest));
  CHECK (api->image_info (engine, dest, &info) == GLIMS_STATUS_OK && info.dirty &&
         info.width == 320 && info.height == 240 && info.layer_count == 6,
         "the image stays 320x240, gains 5 rows and is marked dirty");

  count = 0;
  CHECK (api->image_layers (engine, dest, rows, 16, &count) == GLIMS_STATUS_OK && count == 6,
         "the destination now has %d layers", count);
  if (count == 6)
    {
      int shape = 1;

      for (i = 0; i < 5 && shape; i++)
        if (strcmp (rows[i].name, source_rows[i].name) != 0 || rows[i].kind != source_rows[i].kind ||
            rows[i].depth != source_rows[i].depth || strcmp (rows[i].mode, source_rows[i].mode) != 0 ||
            rows[i].visible != source_rows[i].visible || rows[i].has_mask != source_rows[i].has_mask ||
            rows[i].opacity != source_rows[i].opacity)
          shape = 0;
      /* Parents: 0 stays 0, a source parent maps to its imported id. */
      for (i = 0; i < 5 && shape; i++)
        {
          GlimsItemID parent = 0;
          int         j;

          if (source_rows[i].parent != 0)
            for (j = 0; j < 5; j++)
              if (source_rows[j].id == source_rows[i].parent)
                parent = added[j];
          if (rows[i].parent != parent)
            shape = 0;
        }
      CHECK (shape, "the imported stack keeps order, names, kinds, groups, modes, masks and opacity");
      CHECK (strcmp (rows[5].name, "Base") == 0 && rows[5].parent == 0,
             "the imported stack sits above the destination's own layer");
      CHECK (rows[0].id == added[0] && rows[1].id == added[1] && rows[4].id == added[2],
             "the returned ids are the imported top-level layers");
      CHECK (rows[0].selected && rows[1].selected && rows[4].selected && ! rows[5].selected,
             "the imported layers are selected, the old one is not");

      dx = rows[0].bounds.x - source_rows[0].bounds.x;
      dy = rows[0].bounds.y - source_rows[0].bounds.y;
      for (i = 1; i < 5; i++)
        if (rows[i].bounds.x - source_rows[i].bounds.x != dx ||
            rows[i].bounds.y - source_rows[i].bounds.y != dy ||
            rows[i].bounds.width != source_rows[i].bounds.width ||
            rows[i].bounds.height != source_rows[i].bounds.height)
          offsets_ok = 0;
      CHECK (offsets_ok, "every layer keeps its size and offset relative to the others (moved %+d,%+d)",
             dx, dy);
    }

  pixels = render_all (dest, &w1, &h1);
  CHECK (pixels && w1 == 320 && h1 == 240, "the imported image renders");
  free (pixels);
  CHECK (api->image_undo (engine, dest) == GLIMS_STATUS_OK && layer_count (dest) == 1,
         "undo removes all five imported rows at once");
  CHECK (api->image_redo (engine, dest) == GLIMS_STATUS_OK && layer_count (dest) == 6,
         "redo restores them");

  /* Inserting above a chosen layer: with the bottom layer selected the
   * stack lands between it and the top layer. */
  CHECK (api->image_layers (engine, dest, rows, 16, &count) == GLIMS_STATUS_OK && count == 6 &&
         api->layer_select (engine, dest, rows[5].id) == GLIMS_STATUS_OK,
         "the destination's own layer is selected again");
  {
    GlimsStatus s = api->image_open_layers (engine, dest, xcf, NULL, 0, &n, &error);

    CHECK (s == GLIMS_STATUS_OK && n == 3, "a second import runs (%d, n=%d)%s%s",
           s, n, error ? ": " : "", error ? error : "");
  }
  api->image_layers (engine, dest, rows, 16, &count);
  /* Duplicate names get the engine's "#1" suffix; the group keeps its
   * children. */
  CHECK (count == 11 && strcmp (rows[5].name, "Glims #1") == 0 &&
         strcmp (rows[6].name, "Shapes #1") == 0 && rows[7].parent == rows[6].id &&
         rows[7].depth == 1 && strcmp (rows[9].name, "Background #1") == 0 &&
         strcmp (rows[10].name, "Base") == 0,
         "a second import with the bottom layer selected lands directly above it");
  api->free_string (error);
  error = NULL;
  api->image_undo (engine, dest);
  api->image_undo (engine, dest);

  /* With a group selected, the import becomes its children. */
  CHECK (api->create_group (engine, dest, 0, 0, "Holder", &group, NULL) == GLIMS_STATUS_OK && group > 0,
         "a group to open into");
  CHECK (api->layer_select (engine, dest, group) == GLIMS_STATUS_OK,
         "the group is selected");
  CHECK (api->image_open_layers (engine, dest, xcf, added, 8, &n, &error) == GLIMS_STATUS_OK && n == 3 &&
         api->image_layers (engine, dest, rows, 16, &count) == GLIMS_STATUS_OK && count == 7 &&
         rows[0].id == group && strcmp (rows[0].name, "Holder") == 0 &&
         rows[1].depth == 1 && rows[1].parent == group && strcmp (rows[1].name, "Glims") == 0 &&
         rows[2].depth == 1 && rows[2].parent == group && strcmp (rows[2].name, "Shapes") == 0 &&
         rows[3].depth == 2 && rows[4].depth == 2 && rows[3].parent == rows[2].id &&
         strcmp (rows[5].name, "Background") == 0 && rows[5].depth == 1 && rows[5].parent == group &&
         strcmp (rows[6].name, "Base") == 0 && rows[6].depth == 0 && rows[6].parent == 0,
         "with a group selected, the imported stack lands inside it, top first%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  api->image_close (engine, dest);
  dest = 0;

  /* A non-XCF single-layer file imports as one layer named after it. */
  CHECK (api->image_new (engine, 320, 240, &dest, NULL) == GLIMS_STATUS_OK, "destination for a PNG import");
  CHECK (api->image_open_layers (engine, dest, png, NULL, 0, &n, &error) == GLIMS_STATUS_OK && n == 1 &&
         api->image_layers (engine, dest, rows, 16, &count) == GLIMS_STATUS_OK && count == 2 &&
         strcmp (rows[0].name, "composite.png") == 0 && rows[0].kind == GLIMS_LAYER_PIXEL &&
         rows[0].bounds.width == 320 && rows[0].bounds.height == 240,
         "the PNG imports as one pixel layer named after the file%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_open (engine, png, &src, NULL) == GLIMS_STATUS_OK && src > 0,
         "the same PNG opens as an image for reference");
  pixels    = render_all (dest, &w1, &h1);
  reference = src ? render_all (src, &w2, &h2) : NULL;
  CHECK (pixels && reference && w1 == w2 && h1 == h2 &&
         count_differences (pixels, reference, (size_t) w1 * h1 * 4) == 0,
         "the imported PNG renders exactly as the file does");
  free (pixels);
  free (reference);
  api->image_close (engine, src);
  src = 0;

  /* The destination's identity is untouched: it still saves its own
   * composite, and saving doesn't undo the import. */
  CHECK (api->image_save (engine, dest, dest_xcf, &error) == GLIMS_STATUS_OK && file_size (dest_xcf) > 0,
         "the destination saves to its own XCF after the import%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_open (engine, dest_xcf, &reopened, &error) == GLIMS_STATUS_OK &&
         api->image_layers (engine, reopened, after, 16, &count) == GLIMS_STATUS_OK && count == 2 &&
         strcmp (after[0].name, "composite.png") == 0 && strcmp (after[1].name, "Background") == 0,
         "the saved file holds the destination's layers, not the source image's%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  api->image_close (engine, reopened);
  reopened = 0;

  /* Refusals change nothing: no rows added, no undo step. */
  before = undo_depth (dest);
  CHECK (api->image_open_layers (engine, dest, missing, NULL, 0, &n, &error) == GLIMS_STATUS_FAILED &&
         error && api->image_info (engine, dest, &info) == GLIMS_STATUS_OK && info.layer_count == 2 &&
         undo_depth (dest) == before,
         "a missing file fails cleanly: %s", error ? error : "(no message)");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_open_layers (engine, dest, junk, NULL, 0, &n, &error) == GLIMS_STATUS_FAILED &&
         error && api->image_info (engine, dest, &info) == GLIMS_STATUS_OK && info.layer_count == 2 &&
         undo_depth (dest) == before,
         "a file that is not an image fails cleanly: %s", error ? error : "(no message)");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_open_layers (engine, dest, "https://example.com/a.png", NULL, 0, &n, &error) ==
         GLIMS_STATUS_INVALID_ARGUMENT && error,
         "a non-native path is refused before loading: %s", error ? error : "(no message)");
  api->free_string (error);
  error = NULL;
  CHECK (api->image_open_layers (engine, dest, NULL, NULL, 0, &n, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_open_layers (engine, dest, png, NULL, 0, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_open_layers (engine, dest, png, NULL, -1, &n, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_open_layers (engine, dest, png, NULL, 4, &n, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
         api->image_open_layers (engine, -1234, png, NULL, 0, &n, NULL) == GLIMS_STATUS_NOT_FOUND,
         "invalid arguments and unknown images are reported");

  /* Busy states: an open stroke, a filter preview and a plug-in run. */
  CHECK (api->stroke_begin (engine, dest, first_layer (dest), &brush, &point, &stroke, NULL) == GLIMS_STATUS_OK,
         "a stroke starts");
  CHECK (api->image_open_layers (engine, dest, png, NULL, 0, &n, &error) == GLIMS_STATUS_BUSY && error &&
         api->image_info (engine, dest, &info) == GLIMS_STATUS_OK && info.layer_count == 2 &&
         undo_depth (dest) == before,
         "open-as-layers refuses an active stroke (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "the stroke still ends cleanly");
  stroke = 0;
  api->image_undo (engine, dest);

  CHECK (api->filter_begin (engine, dest, first_layer (dest), "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK,
         "a filter preview opens");
  CHECK (api->image_open_layers (engine, dest, png, NULL, 0, &n, &error) == GLIMS_STATUS_BUSY && error &&
         api->image_info (engine, dest, &info) == GLIMS_STATUS_OK && info.layer_count == 2,
         "open-as-layers refuses a live filter preview (%s)", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "the preview still aborts cleanly");
  filter = 0;

  CHECK (api->image_new (engine, 6000, 4000, &scratch, NULL) == GLIMS_STATUS_OK, "a big image keeps a plug-in busy");
  run.image = scratch;
  run.name  = "plug-in-checkerboard";
  atomic_store (&progress_active, false);
  pthread_create (&thread, NULL, background_run, &run);
  wait_for_progress (&run);
  status = GLIMS_STATUS_OK;
  {
    int was_running = ! atomic_load (&run.finished);

    if (was_running)
      status = api->image_open_layers (engine, dest, png, NULL, 0, &n, NULL);
    pthread_join (thread, NULL);
    CHECK (! was_running || status == GLIMS_STATUS_BUSY,
           "while a plug-in runs, open-as-layers reports BUSY (%d)", status);
  }
  CHECK (api->image_info (engine, dest, &info) == GLIMS_STATUS_OK && info.layer_count == 2,
         "the refused calls left the destination unchanged");
  api->image_close (engine, scratch);
  scratch = 0;

  /* File > Place: a real link layer that keeps its file reference. */
  CHECK (api->image_new (engine, 64, 64, &src, NULL) == GLIMS_STATUS_OK &&
         api->fill (engine, src, (GlimsPoint) { 0, 0 }, &red, NULL) == GLIMS_STATUS_OK &&
         api->image_export (engine, src, link_src, &error) == GLIMS_STATUS_OK && file_size (link_src) > 8,
         "a 64x64 red PNG is written for placing%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  api->image_close (engine, src);
  src = 0;

  /* The link goes on top of the PNG import; keep a pixel outside its
   * bounds to compare after placing. */
  {
    uint8_t px[4] = { 0 };

    api->image_render (engine, dest, 1.0, (GlimsRect) { 10, 10, 1, 1 }, px, 4);
    memcpy (corner, px, 4);
  }
  before = undo_depth (dest);
  status = api->image_place_link (engine, dest, link_src, &placed, &error);
  if (! links)
    {
      CHECK (status == GLIMS_STATUS_UNSUPPORTED && error && placed == 0 &&
             api->image_info (engine, dest, &info) == GLIMS_STATUS_OK && info.layer_count == 2 &&
             undo_depth (dest) == before,
             "this engine has no link layers: Place reports UNSUPPORTED and adds nothing (%s)",
             error ? error : "");
      api->free_string (error);
      error = NULL;
      CHECK (api->image_layers (engine, dest, rows, 16, &count) == GLIMS_STATUS_OK &&
             count == 2 && rows[0].kind != GLIMS_LAYER_LINK && rows[1].kind != GLIMS_LAYER_LINK,
             "no link or substitute layer appears");
    }
  else
    {
      int tries;

      CHECK (status == GLIMS_STATUS_OK && placed > 0,
             "Place puts the PNG in as a link layer%s%s", error ? ": " : "", error ? error : "");
      api->free_string (error);
      error = NULL;
      CHECK (undo_depth (dest) == before + 1, "placing a link is one undo step");
      CHECK (api->image_layers (engine, dest, rows, 16, &count) == GLIMS_STATUS_OK && count == 3 &&
             rows[0].id == placed && rows[0].kind == GLIMS_LAYER_LINK &&
             strcmp (rows[0].name, "link-source.png") == 0 &&
             rows[0].bounds.x == 128 && rows[0].bounds.y == 88 &&
             rows[0].bounds.width == 64 && rows[0].bounds.height == 64,
             "the link layer is genuine, named after the file and centered");
      CHECK (rows[0].selected && ! rows[1].selected, "the placed layer is selected");
      {
        uint8_t px[4] = { 0 };

        api->image_render (engine, dest, 1.0, (GlimsRect) { 160, 120, 1, 1 }, px, 4);
        CHECK (px[0] > 200 && px[1] < 50 && px[2] < 50 && px[3] == 255,
               "the link renders the file's pixels in the middle of the canvas (%d,%d,%d,%d)",
               px[0], px[1], px[2], px[3]);
        api->image_render (engine, dest, 1.0, (GlimsRect) { 10, 10, 1, 1 }, px, 4);
        CHECK (memcmp (px, corner, 4) == 0, "outside its bounds the composite is unchanged");
      }
      CHECK (api->image_undo (engine, dest) == GLIMS_STATUS_OK && layer_count (dest) == 2 &&
             api->image_redo (engine, dest) == GLIMS_STATUS_OK && layer_count (dest) == 3,
             "placing is a normal undo step");
      CHECK (api->image_layers (engine, dest, rows, 16, &count) == GLIMS_STATUS_OK &&
             rows[0].kind == GLIMS_LAYER_LINK, "redo restores the link kind, not a copy");

      CHECK (api->image_save (engine, dest, placed_xcf, &error) == GLIMS_STATUS_OK && file_size (placed_xcf) > 0,
             "the image with the link layer saves%s%s", error ? ": " : "", error ? error : "");
      api->free_string (error);
      error = NULL;
      CHECK (api->image_open (engine, placed_xcf, &reopened, &error) == GLIMS_STATUS_OK &&
             api->image_layers (engine, reopened, after, 16, &count) == GLIMS_STATUS_OK && count == 3 &&
             after[0].kind == GLIMS_LAYER_LINK && strcmp (after[0].name, "link-source.png") == 0,
             "the XCF round trip keeps a real link layer%s%s", error ? ": " : "", error ? error : "");
      api->free_string (error);
      error = NULL;
      CHECK (red_at (reopened, 160, 120) > 200,
             "the reopened link layer still renders the file");

      /* Overwrite the source: the monitor reloads the link in place. */
      CHECK (api->image_new (engine, 64, 64, &src, NULL) == GLIMS_STATUS_OK &&
             api->fill (engine, src, (GlimsPoint) { 0, 0 }, &blue, NULL) == GLIMS_STATUS_OK &&
             api->image_export (engine, src, link_src, &error) == GLIMS_STATUS_OK,
             "the source file is rewritten blue%s%s", error ? ": " : "", error ? error : "");
      api->free_string (error);
      error = NULL;
      api->image_close (engine, src);
      src = 0;
      tries = 0;
      while (tries < 100)
        {
          int r = red_at (reopened, 160, 120);
          int b = 0;
          uint8_t px[4];

          if (api->image_render (engine, reopened, 1.0, (GlimsRect) { 160, 120, 1, 1 }, px, 4) == GLIMS_STATUS_OK)
            b = px[2];
          if (r < 50 && b > 200)
            break;
          usleep (100 * 1000);
          tries++;
        }
      CHECK (tries < 100, "the monitored link layer rereads the rewritten source (%d00 ms)", tries);

      /* And a fresh open rereads it too: the stored buffer never wins. */
      CHECK (api->image_open (engine, placed_xcf, &again, NULL) == GLIMS_STATUS_OK && again > 0,
             "the saved link reopens again");
      tries = 0;
      while (tries < 100)
        {
          uint8_t px[4] = { 0 };

          if (api->image_render (engine, again, 1.0, (GlimsRect) { 160, 120, 1, 1 }, px, 4) == GLIMS_STATUS_OK &&
              px[2] > 200 && px[0] < 50)
            break;
          usleep (100 * 1000);
          tries++;
        }
      CHECK (tries < 100, "a reopened link rereads the current file, not the stored buffer (%d00 ms)", tries);
      api->image_close (engine, again);
      again = 0;
      api->image_close (engine, reopened);
      reopened = 0;

      /* Missing and invalid sources fail without touching the image. */
      before = undo_depth (dest);
      CHECK (api->image_place_link (engine, dest, missing, &placed, &error) == GLIMS_STATUS_FAILED &&
             error && placed == 0 && api->image_info (engine, dest, &info) == GLIMS_STATUS_OK &&
             info.layer_count == 3 && undo_depth (dest) == before,
             "placing a missing file fails cleanly (%s)", error ? error : "");
      api->free_string (error);
      error = NULL;
      CHECK (api->image_place_link (engine, dest, junk, &placed, &error) != GLIMS_STATUS_OK &&
             placed == 0 && api->image_info (engine, dest, &info) == GLIMS_STATUS_OK &&
             info.layer_count == 3 && undo_depth (dest) == before,
             "placing a file that is not an image fails cleanly (%s)", error ? error : "");
      api->free_string (error);
      error = NULL;
      CHECK (api->image_place_link (engine, dest, "https://example.com/a.png", &placed, &error) ==
             GLIMS_STATUS_INVALID_ARGUMENT && placed == 0,
             "placing a non-native path is refused before loading");
      api->free_string (error);
      error = NULL;
      CHECK (api->image_place_link (engine, dest, NULL, &placed, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
             api->image_place_link (engine, -1234, link_src, &placed, NULL) == GLIMS_STATUS_NOT_FOUND,
             "place reports invalid arguments and unknown images");
      CHECK (api->image_layers (engine, dest, rows, 16, &count) == GLIMS_STATUS_OK &&
             count == 3 && rows[0].kind == GLIMS_LAYER_LINK,
             "the failures left the placed link layer alone");
    }

  api->image_close (engine, dest);
}

int
main (int argc, char **argv)
{
  GlimsEngineGetAPIFunction get_api;
  GlimsEngineConfig         config = { 0 };
  char                      user_dir[1024], cache_dir[1024];
  char                     *error = NULL;
  void                     *library;
  GlimsImageID              image = 0;
  double                    start;

  if (argc != 4)
    {
      fprintf (stderr, "usage: %s LIBRARY WORK_DIR FIXTURES_DIR\n", argv[0]);
      return 2;
    }

  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (! library)
    {
      fprintf (stderr, "dlopen: %s\n", dlerror ());
      return 1;
    }
  get_api = (GlimsEngineGetAPIFunction) dlsym (library, "glims_engine_get_api");
  api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  CHECK (api && api->api_version == GLIMS_ENGINE_API_VERSION && api->struct_size >= sizeof (GlimsEngineAPI),
         "library serves facade version %u", GLIMS_ENGINE_API_VERSION);
  if (! api || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI))
    return 1;
  CHECK (get_api (GLIMS_ENGINE_API_VERSION + 1) == NULL, "library refuses an unknown facade version");

  snprintf (user_dir, sizeof user_dir, "%s/user", argv[2]);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", argv[2]);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  config.on_event        = on_event;

  start = now_ms ();
  CHECK (api->start (&config, &engine, &error) == GLIMS_STATUS_OK, "engine starts%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  if (! engine)
    return 1;
  printf ("      engine %s started in %.0f ms\n", api->engine_version (engine), now_ms () - start);
  CHECK (api->start (&config, &engine, NULL) == GLIMS_STATUS_FAILED, "a second start is refused");

  test_new_image_and_render (&image);
  if (image)
    {
      test_paint_and_undo (image);
      test_filters (image, argv[2]);
      test_filter_properties ();
      test_history_and_snapshots ();
      test_save_reopen_export (image, argv[2]);
      test_save_copy (argv[2]);
      test_image_from_pixels ();
      CHECK (api->image_close (engine, image) == GLIMS_STATUS_OK, "close image");
      CHECK (api->image_close (engine, image) == GLIMS_STATUS_NOT_FOUND, "closing twice is reported");
    }
  test_fixture (argv[3], argv[2]);
  test_place (argv[3], argv[2]);
  test_text_layers (argv[2]);
  test_paths (argv[2]);
  test_path_fill (argv[2]);
  test_path_vector_layer (argv[2]);
  test_vector_layer_style (argv[2]);

  test_vector_rasterized_roundtrip (argv[2]);
  test_vector_rasterized_open_layers (argv[2]);
  test_deleted_items ();
  test_groups_and_text_units (argv[3]);
  test_layer_structure ();
  test_layer_edit_locks ();
  test_layer_masks (argv[2]);
  test_mask_clipboard_target ();
  test_paint_tools ();
  test_selections ();
  test_editing ();
  test_clipboard ();
  test_clear_srgb_and_readiness (argv[3]);
  test_render_freshness ();
  test_transforms ();
  test_matrix_transform ();
  test_channels (argv[2]);
  test_drawable_filters (argv[2]);
  test_drawable_effects (argv[2]);
  test_filter_edit_history_gate ();
  test_filter_edit (argv[2]);
  test_color_state (argv[3], argv[2]);
  test_color_profiles (argv[3], argv[2]);
  test_profile_preserves_editable_layers (argv[3]);
  test_qmask_name_fixture (argv[3]);
  test_resources ();
  test_resource_thumbnails ();
  test_stroke_brush_resource ();

  test_pattern_fill ();

  test_resource_gradient ();
  test_procedures ();
  CHECK (atomic_load (&undo_events) > 0, "undo-changed events arrived (%d)", atomic_load (&undo_events));

  /* Quitting while a plug-in runs (a dialog left open) must not wait for
   * it: stop closes running plug-ins first. */
  {
    BackgroundRun run = { 0 };
    pthread_t     thread;
    int           running = 0;
    double        stopped;

    api->image_new (engine, 6000, 4000, &run.image, NULL);
    run.name = "plug-in-checkerboard";
    atomic_store (&progress_active, false);
    pthread_create (&thread, NULL, background_run, &run);
    wait_for_progress (&run);
    running = ! atomic_load (&run.finished);
    start = now_ms ();
    api->stop (engine);
    stopped = now_ms () - start;
    pthread_join (thread, NULL);
    CHECK (running && run.status != GLIMS_STATUS_OK && stopped < 5000,
           "stopping the engine ends a running plug-in (stopped in %.0f ms, run %d)", stopped, run.status);
  }

  /* The adapter overrides some settings for the running engine only; the
   * engine saves gimprc on exit and must not keep them. */
  {
    char  gimprc[1100], line[1024];
    FILE *file;
    int   kept = 0;

    snprintf (gimprc, sizeof gimprc, "%s/gimprc", user_dir);
    file = fopen (gimprc, "r");
    while (file && fgets (line, sizeof line, file))
      if (strstr (line, "(module-path") || strstr (line, "(tool-preset-path") ||
          strstr (line, "(mypaint-brush-path"))
        kept++;
    if (file)
      fclose (file);
    CHECK (file && kept == 0, "the saved gimprc keeps none of the run-time overrides (%d kept)", kept);
  }

  printf ("%s: %d failure%s\n", failures ? "FAILED" : "PASSED", failures, failures == 1 ? "" : "s");
  return failures ? 1 : 0;
}

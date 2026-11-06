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
  if (image)
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

/* A render right after a change must show it. Validating tiles only as
 * reads touched them returned the old pixels now and then (about one round
 * in 23 here), and they stayed that way. */
static void
test_render_freshness (void)
{
  int rounds = 60, stale = 0, r;

  for (r = 0; r < rounds; r++)
    {
      GlimsImageID      image = 0;
      GlimsItemID       layer = 0;
      GlimsFillSettings fill = { .struct_size = sizeof fill, .mode = GLIMS_FILL_SELECTION,
                                 .color = { 1, 0, 0, 1 }, .opacity = 1, .antialias = true };
      GlimsLayerChange  change = { .struct_size = sizeof change, .properties = GLIMS_LAYER_OPACITY, .opacity = 0.5 };
      uint8_t           pixel[4];

      api->image_new (engine, 100, 80, &image, NULL);
      api->layer_command (engine, image, 0, GLIMS_LAYER_NEW, &layer, NULL);
      api->fill (engine, image, (GlimsPoint) { 0, 0 }, &fill, NULL);
      api->image_render (engine, image, 1.0, (GlimsRect) { 50, 40, 1, 1 }, pixel, 4);
      api->layer_change (engine, image, layer, &change, NULL);
      api->image_render (engine, image, 1.0, (GlimsRect) { 50, 40, 1, 1 }, pixel, 4);
      if (pixel[1] < 180)
        stale++;
      api->image_close (engine, image);
    }

  CHECK (stale == 0, "renders right after %d changes all show them (%d stale)", rounds, stale);
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
test_filters (GlimsImageID image)
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
  if (! api)
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
      test_filters (image);
      test_save_reopen_export (image, argv[2]);
      CHECK (api->image_close (engine, image) == GLIMS_STATUS_OK, "close image");
      CHECK (api->image_close (engine, image) == GLIMS_STATUS_NOT_FOUND, "closing twice is reported");
    }
  test_fixture (argv[3], argv[2]);
  test_text_layers (argv[2]);
  test_paths (argv[2]);
  test_deleted_items ();
  test_groups_and_text_units (argv[3]);
  test_paint_tools ();
  test_selections ();
  test_editing ();
  test_render_freshness ();
  test_transforms ();
  test_matrix_transform ();
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

/* Slots172/173 coordinate-delivery oracle. All recorded calls also execute
 * real Core. No private stroke layout or production sample decoder is used. */
#include "tablet-stroke-v2-shims.h"
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

int main (int argc, char **argv);

G_STATIC_ASSERT (offsetof (GlimsStrokePoint, x) == 0);
G_STATIC_ASSERT (offsetof (GlimsStrokePoint, pressure) == 16);
G_STATIC_ASSERT (offsetof (GlimsStrokePoint, time_ms) == 40);
G_STATIC_ASSERT (sizeof (GlimsStrokePoint) == 48);
G_STATIC_ASSERT (offsetof (GlimsEngineAPI, stroke_begin_v2) ==
                 offsetof (GlimsEngineAPI, stroke_begin_with_capture_facts) +
                 sizeof (((GlimsEngineAPI *) 0)->stroke_begin_with_capture_facts));
G_STATIC_ASSERT (offsetof (GlimsEngineAPI, stroke_continue_v2) ==
                 offsetof (GlimsEngineAPI, stroke_begin_v2) +
                 sizeof (((GlimsEngineAPI *) 0)->stroke_begin_v2));

enum { WIDTH = 56, HEIGHT = 40, BYTES = WIDTH * HEIGHT * 4,
       EVENT_START = 1, EVENT_INIT, EVENT_MOTION, EVENT_INTERPOLATE, EVENT_FINISH };
typedef struct { gint kind; GimpCoords coords; guint32 time; GlimsResourceID brush; } Delivery;
typedef struct { GlimsImageID image; GlimsItemID layer; } Scene;
typedef struct {
  guint8 raw[BYTES], merged[BYTES];
  GlimsUndoInfo undo;
  GlimsHistoryInfo history;
  GlimsImageInfo image;
} Snapshot;

static const GlimsEngineAPI *api;
static GArray *deliveries;
static guint checks, failures;
static const GlimsBrushSettings pencil = {
  .struct_size = sizeof (GlimsBrushSettings), .tool = GLIMS_PAINT_PENCIL,
  .size = 7.5, .opacity = .79, .red = .91, .green = .16, .blue = .31,
  .pressure_size = false, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1
};
static const GlimsStrokePoint legacy_points[] = {
  { 8.5, 10.5, .4, -.2, .3, 0xfffffffeu },
  { 14.5, 13.5, .8, .5, -.4, 0xffffffffu },
  { 22.5, 20.5, .6, -.5, .2, 0 },
  { 35.5, 26.5, 1, 0, 0, 1 },
  { 43.5, 29.5, .5, .1, -.1, 1 }
};

#define CHECK(condition, title) do { \
  gboolean passed_ = (condition); checks++; \
  printf ("%s %s\n", passed_ ? "ok  " : "FAIL", title); \
  if (!passed_) failures++; fflush (stdout); \
} while (0)
#define NEED(condition, title) do { \
  gboolean ready_ = (condition); CHECK (ready_, title); \
  if (!ready_) goto cleanup; \
} while (0)

static void
record_delivery (gint kind, GimpPaintOptions *options, const GimpCoords *coords, guint32 time)
{
  GimpBrush *brush = gimp_context_get_brush (GIMP_CONTEXT (options));
  Delivery row = {kind, *coords, time, brush ? (GlimsResourceID) gimp_data_get_id (GIMP_DATA (brush)) : 0};
  g_array_append_val (deliveries, row);
}

gboolean
glims_test_tablet_start (GimpPaintCore *core, GList *drawables, GimpPaintOptions *options,
                         const GimpCoords *coords, GError **error)
{
  record_delivery (EVENT_START, options, coords, 0);
  return gimp_paint_core_start (core, drawables, options, coords, error);
}

void
glims_test_tablet_paint (GimpPaintCore *core, GList *drawables, GimpPaintOptions *options,
                         GimpPaintState state, guint32 time)
{
  gint kind = state == GIMP_PAINT_STATE_INIT ? EVENT_INIT :
              state == GIMP_PAINT_STATE_MOTION ? EVENT_MOTION : EVENT_FINISH;
  record_delivery (kind, options, &core->cur_coords, time);
  gimp_paint_core_paint (core, drawables, options, state, time);
}

void
glims_test_tablet_interpolate (GimpPaintCore *core, GList *drawables, GimpPaintOptions *options,
                               const GimpCoords *coords, guint32 time)
{
  record_delivery (EVENT_INTERPOLATE, options, coords, time);
  gimp_paint_core_interpolate (core, drawables, options, coords, time);
}

static gboolean
literal_delivery (guint index, gint kind, gdouble x, gdouble y, gdouble pressure,
                   gdouble xtilt, gdouble ytilt, guint32 time,
                   gdouble rotation, gdouble wheel, GlimsResourceID brush)
{
  if (index >= deliveries->len) return FALSE;
  const Delivery *row = &g_array_index (deliveries, Delivery, index);
  const GimpCoords *c = &row->coords;
  /* Literal native defaults, independent of GIMP_COORDS_DEFAULT_VALUES. */
  return row->kind == kind && row->time == time && row->brush == brush &&
    c->x == x && c->y == y && c->pressure == pressure && c->xtilt == xtilt && c->ytilt == ytilt &&
    fabs (c->rotation - rotation) < 1e-12 && fabs (c->wheel - wheel) < 1e-12 &&
    c->distance == 0 && c->slider == 0 && c->velocity == 0 && c->direction == 0 &&
    c->xscale == 1 && c->yscale == 1 && c->angle == 0 && !c->reflect;
}

static gboolean
seed (GlimsEngine *engine, Scene *scene)
{
  if (api->image_new (engine, WIDTH, HEIGHT, &scene->image, NULL) != GLIMS_STATUS_OK) return FALSE;
  GlimsOpenImage *open = glims_lookup_image (engine, scene->image);
  if (!open) return FALSE;
  GimpLayer *layer = gimp_layer_new (open->image, WIDTH, HEIGHT,
    gimp_image_get_layer_format (open->image, TRUE), "Tablet RGBA", 1, GIMP_LAYER_MODE_NORMAL);
  if (!layer) return FALSE;
  if (!gimp_image_add_layer (open->image, layer, NULL, 0, FALSE)) {
    g_object_unref (layer); return FALSE;
  }
  guint8 pixels[BYTES];
  for (guint y = 0; y < HEIGHT; y++) for (guint x = 0; x < WIDTH; x++) {
    gsize i = (y * WIDTH + x) * 4;
    pixels[i] = 33 + (x * 5 + y * 3) % 199;
    pixels[i + 1] = 29 + (x + y * 9) % 197;
    pixels[i + 2] = 37 + (x * 11 + y) % 187;
    pixels[i + 3] = 83 + (x * 7 + y * 5) % 120;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)),
                   GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT), 0,
                   babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE);
  scene->layer = gimp_item_get_id (GIMP_ITEM (layer));
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, WIDTH, HEIGHT);
  gimp_image_clean_all (open->image);
  gimp_image_flush (open->image);
  return TRUE;
}

static gboolean
snapshot (GlimsEngine *engine, const Scene *scene, Snapshot *out)
{
  GlimsOpenImage *open = glims_lookup_image (engine, scene->image);
  GimpDrawable *drawable = open ? glims_lookup_drawable (open, scene->layer) : NULL;
  if (!drawable) return FALSE;
  gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT),
    1, babl_format ("R'G'B'A u8"), out->raw, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  return api->image_render (engine, scene->image, 1, (GlimsRect) {0, 0, WIDTH, HEIGHT},
                           out->merged, WIDTH * 4) == GLIMS_STATUS_OK &&
    api->image_undo_info (engine, scene->image, &out->undo) == GLIMS_STATUS_OK &&
    api->image_history (engine, scene->image, NULL, 0, &out->history) == GLIMS_STATUS_OK &&
    api->image_info (engine, scene->image, &out->image) == GLIMS_STATUS_OK;
}

static gboolean
same_pixels (const Snapshot *a, const Snapshot *b)
{
  return !memcmp (a->raw, b->raw, BYTES) && !memcmp (a->merged, b->merged, BYTES);
}

static gboolean
unchanged (const Snapshot *a, const Snapshot *b)
{
  return same_pixels (a, b) && a->image.dirty == b->image.dirty &&
    a->history.revision == b->history.revision && a->history.count == b->history.count &&
    a->history.current_position == b->history.current_position &&
    a->undo.undo_count == b->undo.undo_count && a->undo.redo_count == b->undo.redo_count &&
    !strcmp (a->undo.next_undo, b->undo.next_undo) && !strcmp (a->undo.next_redo, b->undo.next_redo);
}

static void
close_scene (GlimsEngine *engine, Scene *scene)
{
  if (!scene->image) return;
  CHECK (api->image_close (engine, scene->image) == GLIMS_STATUS_OK, "owned test image closes");
  scene->image = 0;
}

static GlimsStrokeSampleV2
sample (gdouble x, gdouble y, guint32 time)
{
  return (GlimsStrokeSampleV2) { .struct_size = sizeof (GlimsStrokeSampleV2),
    .x = x, .y = y, .pressure = .7, .xtilt = -.2, .ytilt = .3, .time_ms = time };
}

static GlimsStrokePacketV2
packet (const void *samples, gsize count)
{
  return (GlimsStrokePacketV2) {sizeof (GlimsStrokePacketV2), sizeof (GlimsStrokeSampleV2),
    samples, count, count * sizeof (GlimsStrokeSampleV2)};
}

static GlimsStatus
begin (GlimsEngine *engine, const Scene *scene, const GlimsStrokePacketV2 *input, GlimsStrokeID *id)
{
  return api->stroke_begin_v2 (engine, scene->image, scene->layer, 0, &pencil, input, id, NULL);
}

static void
legacy_control (GlimsEngine *engine, GlimsResourceID inherited)
{
  Scene scene = {0}; GlimsStrokeID stroke = 0;
  Snapshot before, after, undone, redone;
  NEED (seed (engine, &scene) && snapshot (engine, &scene, &before), "V1 seeded raw and projection baseline exists");
  g_array_set_size (deliveries, 0);
  NEED (api->stroke_begin (engine, scene.image, scene.layer, &pencil, legacy_points, &stroke, NULL) == GLIMS_STATUS_OK && stroke > 0,
        "unchanged V1 begin forwards to real paint Core");
  CHECK (deliveries->len == 3 &&
    literal_delivery (0, EVENT_START, 8.5, 10.5, .4, -.2, .3, 0, 0, .5, inherited) &&
    literal_delivery (1, EVENT_INIT, 8.5, 10.5, .4, -.2, .3, 0xfffffffeu, 0, .5, inherited) &&
    literal_delivery (2, EVENT_MOTION, 8.5, 10.5, .4, -.2, .3, 0xfffffffeu, 0, .5, inherited),
    "V1 real start, INIT and MOTION retain literal default axes and UInt32 time");
  NEED (api->stroke_continue (engine, stroke, legacy_points + 1, 4) == GLIMS_STATUS_OK,
        "V1 continuation retains its public vector behavior");
  CHECK (deliveries->len == 7 &&
    literal_delivery (3, EVENT_INTERPOLATE, 14.5, 13.5, .8, .5, -.4, 0xffffffffu, 0, .5, inherited) &&
    literal_delivery (4, EVENT_INTERPOLATE, 22.5, 20.5, .6, -.5, .2, 0, 0, .5, inherited) &&
    literal_delivery (5, EVENT_INTERPOLATE, 35.5, 26.5, 1, 0, 0, 1, 0, .5, inherited) &&
    literal_delivery (6, EVENT_INTERPOLATE, 43.5, 29.5, .5, .1, -.1, 1, 0, .5, inherited),
    "V1 actual interpolation receives literal ordered base samples across wrap");
  NEED (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "V1 shared end succeeds"); stroke = 0;
  CHECK (deliveries->len == 8 && g_array_index (deliveries, Delivery, 7).kind == EVENT_FINISH &&
         g_array_index (deliveries, Delivery, 7).time == 0, "shared end retains native FINISH time zero");
  CHECK (snapshot (engine, &scene, &after) && !same_pixels (&before, &after) &&
         after.undo.undo_count == before.undo.undo_count + 1, "V1 control actually paints and creates one Undo");
  CHECK (api->image_undo (engine, scene.image) == GLIMS_STATUS_OK && snapshot (engine, &scene, &undone) &&
         same_pixels (&before, &undone), "V1 Undo restores exact raw and composite bytes");
  CHECK (api->image_redo (engine, scene.image) == GLIMS_STATUS_OK && snapshot (engine, &scene, &redone) &&
         same_pixels (&after, &redone), "V1 Redo restores exact painted bytes");
cleanup:
  if (stroke) api->stroke_end (engine, stroke);
  close_scene (engine, &scene);
}

static gboolean
has_v2 (void)
{
  return api->struct_size >= offsetof (GlimsEngineAPI, stroke_continue_v2) + sizeof api->stroke_continue_v2 &&
    api->stroke_begin_v2 && api->stroke_continue_v2;
}

static void
delivery_and_pixels (GlimsEngine *engine, GlimsResourceID inherited)
{
  Scene scene = {0}, reference = {0}; GlimsStrokeID stroke = 0, ref_stroke = 0;
  Snapshot before, after, expected, undone, redone;
  GlimsStrokeSampleV2 points[] = {
    { .struct_size = sizeof (GlimsStrokeSampleV2), .flags = 3, .x = 8.5, .y = 10.5,
      .pressure = .4, .xtilt = -.2, .ytilt = .3, .time_ms = 0xfffffffeu,
      .rotation_turns = .25, .tangential_pressure = -1 },
    { .struct_size = sizeof (GlimsStrokeSampleV2), .flags = 3, .x = 14.5, .y = 13.5,
      .pressure = .8, .xtilt = .5, .ytilt = -.4, .time_ms = 0xffffffffu,
      .rotation_turns = .75, .tangential_pressure = 1 },
    { .struct_size = sizeof (GlimsStrokeSampleV2), .flags = 1, .x = 22.5, .y = 20.5,
      .pressure = .6, .xtilt = -.5, .ytilt = .2, .time_ms = 0, .rotation_turns = .5 },
    { .struct_size = sizeof (GlimsStrokeSampleV2), .flags = 2, .x = 35.5, .y = 26.5,
      .pressure = 1, .time_ms = 1, .tangential_pressure = .5 },
    { .struct_size = sizeof (GlimsStrokeSampleV2), .x = 43.5, .y = 29.5,
      .pressure = .5, .xtilt = .1, .ytilt = -.1, .time_ms = 1 }
  };
  NEED (seed (engine, &scene) && seed (engine, &reference) && snapshot (engine, &scene, &before),
        "V2 and independent V1 images have matching textured alpha seeds");
  GlimsStrokePacketV2 first = packet (points, 1), rest = packet (points + 1, 4);
  g_array_set_size (deliveries, 0);
  NEED (begin (engine, &scene, &first, &stroke) == GLIMS_STATUS_OK && stroke > 0, "V2 first sample starts a real Core stroke");
  CHECK (deliveries->len == 3 &&
    literal_delivery (0, EVENT_START, 8.5, 10.5, .4, -.2, .3, 0, .25, 0, inherited) &&
    literal_delivery (1, EVENT_INIT, 8.5, 10.5, .4, -.2, .3, 0xfffffffeu, .25, 0, inherited) &&
    literal_delivery (2, EVENT_MOTION, 8.5, 10.5, .4, -.2, .3, 0xfffffffeu, .25, 0, inherited),
    "V2 first sample literally delivers rotation and negative tangent endpoint to Core");
  NEED (api->stroke_continue_v2 (engine, stroke, &rest, NULL) == GLIMS_STATUS_OK, "V2 wrapped continuation succeeds");
  CHECK (deliveries->len == 7 &&
    literal_delivery (3, EVENT_INTERPOLATE, 14.5, 13.5, .8, .5, -.4, 0xffffffffu, .75, 1, inherited) &&
    literal_delivery (4, EVENT_INTERPOLATE, 22.5, 20.5, .6, -.5, .2, 0, .5, .5, inherited) &&
    literal_delivery (5, EVENT_INTERPOLATE, 35.5, 26.5, 1, 0, 0, 1, 0, .75, inherited) &&
    literal_delivery (6, EVENT_INTERPOLATE, 43.5, 29.5, .5, .1, -.1, 1, 0, .5, inherited),
    "ordered Core coords independently deliver each optional axis and reset both when absent");
  NEED (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "V2 uses the ordinary shared finish path"); stroke = 0;
  CHECK (deliveries->len == 8 && g_array_index (deliveries, Delivery, 7).time == 0,
         "V2 shared finish adds one FINISH with the unchanged zero time");
  NEED (api->stroke_begin (engine, reference.image, reference.layer, &pencil, legacy_points, &ref_stroke, NULL) == GLIMS_STATUS_OK &&
    api->stroke_continue (engine, ref_stroke, legacy_points + 1, 4) == GLIMS_STATUS_OK &&
    api->stroke_end (engine, ref_stroke) == GLIMS_STATUS_OK, "independent ordinary V1 reference executes literal base points"); ref_stroke = 0;
  CHECK (snapshot (engine, &scene, &after) && snapshot (engine, &reference, &expected) &&
    same_pixels (&after, &expected) && !same_pixels (&before, &after) && after.undo.undo_count == before.undo.undo_count + 1 &&
    after.undo.undo_count == expected.undo.undo_count, "delivered optional axes preserve real Pencil pixels and one Undo without enabled dynamics");
  CHECK (api->image_undo (engine, scene.image) == GLIMS_STATUS_OK && snapshot (engine, &scene, &undone) &&
    same_pixels (&before, &undone), "V2 Undo restores exact independent raw and composite baseline");
  CHECK (api->image_redo (engine, scene.image) == GLIMS_STATUS_OK && snapshot (engine, &scene, &redone) &&
    same_pixels (&after, &redone), "V2 Redo restores exact result");
cleanup:
  if (stroke) api->stroke_end (engine, stroke);
  if (ref_stroke) api->stroke_end (engine, ref_stroke);
  close_scene (engine, &scene); close_scene (engine, &reference);
}

/* Each invalid scalar is exercised at begin and at the final position of a
 * packet whose first sample would paint. The previous-time proof follows. */
static const gchar *const bad_names[] = {
  "unknown flags", "reserved", "NaN x", "infinite y", "coordinate upper", "coordinate lower",
  "pressure below zero", "pressure above one", "NaN pressure", "x tilt below", "y tilt above",
  "infinite tilt", "rotation upper endpoint", "negative rotation", "NaN rotation",
  "tangent below", "tangent above", "infinite tangent", "absent rotation nonzero", "absent tangent nonzero",
  "short sample prefix", "sample larger than stride", "NaN y", "NaN x tilt", "NaN y tilt", "NaN tangent"
};

static void
make_bad (GlimsStrokeSampleV2 *p, guint kind)
{
  switch (kind) {
  case 0: p->flags = 4; break;
  case 1: p->reserved = 1; break;
  case 2: p->x = NAN; break;
  case 3: p->y = INFINITY; break;
  case 4: p->x = 524288.0001; break;
  case 5: p->y = -524288.0001; break;
  case 6: p->pressure = -.001; break;
  case 7: p->pressure = 1.001; break;
  case 8: p->pressure = NAN; break;
  case 9: p->xtilt = -1.001; break;
  case 10: p->ytilt = 1.001; break;
  case 11: p->xtilt = -INFINITY; break;
  case 12: p->flags = 1; p->rotation_turns = 1; break;
  case 13: p->flags = 1; p->rotation_turns = -.001; break;
  case 14: p->flags = 1; p->rotation_turns = NAN; break;
  case 15: p->flags = 2; p->tangential_pressure = -1.001; break;
  case 16: p->flags = 2; p->tangential_pressure = 1.001; break;
  case 17: p->flags = 2; p->tangential_pressure = INFINITY; break;
  case 18: p->rotation_turns = .25; break;
  case 19: p->tangential_pressure = .5; break;
  case 20: p->struct_size--; break;
  case 21: p->struct_size++; break;
  case 22: p->y = NAN; break;
  case 23: p->xtilt = NAN; break;
  case 24: p->ytilt = NAN; break;
  case 25: p->flags = 2; p->tangential_pressure = NAN; break;
  default: g_assert_not_reached ();
  }
}

static void
malformed_samples (GlimsEngine *engine)
{
  Scene scene = {0}; GlimsStrokeID stroke = 0;
  Snapshot before, after, live, recovered;
  NEED (seed (engine, &scene) && snapshot (engine, &scene, &before), "malformed samples have a clean owned baseline");
  for (guint i = 0; i < G_N_ELEMENTS (bad_names); i++) {
    GlimsStrokeSampleV2 point = sample (8.5, 10.5, 100); make_bad (&point, i);
    GlimsStrokePacketV2 input = packet (&point, 1);
    GlimsStrokeID refused = 777; guint n = deliveries->len;
    GlimsStatus status = begin (engine, &scene, &input, &refused);
    gchar *label = g_strdup_printf ("begin %s refuses before Core, pixels/history/dirty and clears output", bad_names[i]);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && refused == 0 && deliveries->len == n &&
      snapshot (engine, &scene, &after) && unchanged (&before, &after), label);
    g_free (label);
    if (status == GLIMS_STATUS_OK && refused) api->stroke_end (engine, refused);
  }
  GlimsStrokeSampleV2 first = sample (8.5, 10.5, 100);
  GlimsStrokePacketV2 first_packet = packet (&first, 1);
  NEED (begin (engine, &scene, &first_packet, &stroke) == GLIMS_STATUS_OK &&
        snapshot (engine, &scene, &live), "a real accepted V2 stroke is available for whole-vector rejection");
  for (guint i = 0; i < G_N_ELEMENTS (bad_names); i++) {
    GlimsStrokeSampleV2 points[] = {sample (28.5, 24.5, 101), sample (38.5, 29.5, 102)};
    make_bad (points + 1, i);
    GlimsStrokePacketV2 input = packet (points, 2); guint n = deliveries->len;
    GlimsStatus status = api->stroke_continue_v2 (engine, stroke, &input, NULL);
    gchar *label = g_strdup_printf ("continue final %s rejects the whole packet before any paint or state", bad_names[i]);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && deliveries->len == n &&
      snapshot (engine, &scene, &after) && unchanged (&live, &after), label);
    g_free (label);
  }
  GlimsStrokeSampleV2 middle[] = {sample (20, 20, 101), sample (25, 23, 102), sample (30, 26, 103)};
  middle[1].pressure = NAN;
  GlimsStrokePacketV2 input = packet (middle, 3); guint n = deliveries->len;
  CHECK (api->stroke_continue_v2 (engine, stroke, &input, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
    deliveries->len == n && snapshot (engine, &scene, &after) && unchanged (&live, &after),
    "a malformed middle sample cannot paint its valid prefix or suffix");
  middle[0] = sample (20, 20, 100); input = packet (middle, 1);
  CHECK (api->stroke_continue_v2 (engine, stroke, &input, NULL) == GLIMS_STATUS_OK && deliveries->len == n + 1,
    "equal original time still succeeds after every refused vector, proving no accepted-time advance");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK && snapshot (engine, &scene, &recovered) &&
    recovered.undo.undo_count == before.undo.undo_count + 1, "refused packets leave a finishable stroke with one Undo"); stroke = 0;
cleanup:
  if (stroke) api->stroke_end (engine, stroke);
  close_scene (engine, &scene);
}

static void
packet_shapes_and_times (GlimsEngine *engine)
{
  Scene scene = {0}; GlimsStrokeID stroke = 0;
  Snapshot before, live, after;
  NEED (seed (engine, &scene) && snapshot (engine, &scene, &before), "packet-shape controls have a clean baseline");
  GlimsStrokeSampleV2 point = sample (8.5, 10.5, 100);
  GlimsStrokePacketV2 normal = packet (&point, 1);
  const gchar *names[] = {"NULL packet", "short packet", "short stride", "zero stride", "NULL samples",
    "mismatched byte count", "sample count over 4096", "payload over 1 MiB", "overflowing count and stride",
    "empty begin", "multiple begin samples"};
  for (guint i = 0; i < G_N_ELEMENTS (names); i++) {
    GlimsStrokePacketV2 bad = normal;
    GlimsStrokeSampleV2 pair[] = {point, point};
    switch (i) {
    case 1: bad.struct_size--; break;
    case 2: bad.sample_stride--; bad.byte_count = bad.sample_stride; break;
    case 3: bad.sample_stride = 0; bad.byte_count = 0; break;
    case 4: bad.samples = NULL; break;
    case 5: bad.byte_count--; break;
    case 6: bad.count = 4097; bad.byte_count = bad.count * bad.sample_stride; break;
    case 7: bad.sample_stride = 1048577; bad.byte_count = bad.sample_stride; break;
    case 8: bad.count = SIZE_MAX; bad.sample_stride = UINT32_MAX; bad.byte_count = SIZE_MAX; break;
    case 9: bad.count = 0; bad.samples = NULL; bad.byte_count = 0; break;
    case 10: bad = packet (pair, 2); break;
    default: break;
    }
    GlimsStrokeID refused = 777; guint n = deliveries->len;
    GlimsStatus status = begin (engine, &scene, i == 0 ? NULL : &bad, &refused);
    gchar *label = g_strdup_printf ("%s begin refuses before paint and output publication", names[i]);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && refused == 0 && deliveries->len == n &&
      snapshot (engine, &scene, &after) && unchanged (&before, &after), label);
    g_free (label);
    if (status == GLIMS_STATUS_OK && refused) api->stroke_end (engine, refused);
  }
  guint n = deliveries->len;
  CHECK (api->stroke_begin_v2 (engine, scene.image, scene.layer, 0, &pencil, &normal, NULL, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
    deliveries->len == n && snapshot (engine, &scene, &after) && unchanged (&before, &after),
    "missing begin output refuses without creating an unowned live stroke");
  NEED (begin (engine, &scene, &normal, &stroke) == GLIMS_STATUS_OK && snapshot (engine, &scene, &live),
        "packet/time refusal controls hold one accepted stroke");
  for (guint i = 0; i < 9; i++) {
    GlimsStrokePacketV2 bad = normal;
    switch (i) {
    case 1: bad.struct_size--; break;
    case 2: bad.sample_stride--; bad.byte_count = bad.sample_stride; break;
    case 3: bad.sample_stride = 0; bad.byte_count = 0; break;
    case 4: bad.samples = NULL; break;
    case 5: bad.byte_count--; break;
    case 6: bad.count = 4097; bad.byte_count = bad.count * bad.sample_stride; break;
    case 7: bad.sample_stride = 1048577; bad.byte_count = bad.sample_stride; break;
    case 8: bad.count = SIZE_MAX; bad.sample_stride = UINT32_MAX; bad.byte_count = SIZE_MAX; break;
    default: break;
    }
    guint n = deliveries->len;
    gchar *label = g_strdup_printf ("%s continuation is atomic", names[i]);
    CHECK (api->stroke_continue_v2 (engine, stroke, i == 0 ? NULL : &bad, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
      deliveries->len == n && snapshot (engine, &scene, &after) && unchanged (&live, &after), label);
    g_free (label);
  }
  GlimsStrokePacketV2 empty = packet (NULL, 0); n = deliveries->len;
  CHECK (api->stroke_continue_v2 (engine, stroke, &empty, NULL) == GLIMS_STATUS_OK &&
    deliveries->len == n && snapshot (engine, &scene, &after) && unchanged (&live, &after),
    "canonical empty packet delivers no paint, time or image change");
  empty.samples = &point;
  CHECK (api->stroke_continue_v2 (engine, stroke, &empty, NULL) == GLIMS_STATUS_INVALID_ARGUMENT && deliveries->len == n,
    "empty packet with a non-NULL payload is not canonical");
  const guint32 backwards[] = {99, 100u + 0x80000000u};
  for (guint i = 0; i < G_N_ELEMENTS (backwards); i++) {
    GlimsStrokeSampleV2 points[] = {sample (20, 20, 101), sample (30, 25, backwards[i])};
    if (i == 1) points[1].time_ms = 101u + 0x80000000u;
    GlimsStrokePacketV2 bad = packet (points, 2);
    CHECK (api->stroke_continue_v2 (engine, stroke, &bad, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
      deliveries->len == n && snapshot (engine, &scene, &after) && unchanged (&live, &after),
      i == 0 ? "backward time after a valid prefix rejects the whole vector" : "exact half-range time delta is refused atomically");
  }
  point.time_ms = 100; normal = packet (&point, 1);
  CHECK (api->stroke_continue_v2 (engine, stroke, &normal, NULL) == GLIMS_STATUS_OK && deliveries->len == n + 1,
    "empty and malformed packets did not advance the stored time");
  point.x = 18.5; point.time_ms = 100u + 0x7fffffffu;
  CHECK (api->stroke_continue_v2 (engine, stroke, &normal, NULL) == GLIMS_STATUS_OK && deliveries->len == n + 2,
    "largest unambiguous modular forward delta is accepted");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "shape/time controls end their original accepted stroke"); stroke = 0;
cleanup:
  if (stroke) api->stroke_end (engine, stroke);
  close_scene (engine, &scene);
}

static void
future_alignment_and_limits (GlimsEngine *engine, GlimsResourceID inherited)
{
  Scene scene = {0}; GlimsStrokeID stroke = 0;
  guint8 *storage = NULL, *many = NULL;
  NEED (seed (engine, &scene), "future-prefix controls own a real pixel image");
  /* Both the packet and samples are deliberately unaligned. Non-prefix bytes
   * contain nonzero sentinels and must be ignored, never treated as fields. */
  const guint stride = sizeof (GlimsStrokeSampleV2) + 1;
  storage = g_malloc0 (1 + 3 * stride);
  GlimsStrokeSampleV2 first = sample (8.5, 10.5, 17);
  first.struct_size = stride;
  memcpy (storage + 1, &first, sizeof first); storage[sizeof first + 1] = 0xa5;
  struct { GlimsStrokePacketV2 prefix; guint8 tail[16]; } future = {
    {sizeof future, stride, storage + 1, 1, stride}, {0}
  };
  memset (future.tail, 0xb6, sizeof future.tail);
  guint8 unaligned_packet[sizeof future + 1]; memcpy (unaligned_packet + 1, &future, sizeof future);
  g_array_set_size (deliveries, 0);
  NEED (begin (engine, &scene, (const GlimsStrokePacketV2 *) (unaligned_packet + 1), &stroke) == GLIMS_STATUS_OK,
        "unaligned packet/sample known prefixes and nonzero future tails are accepted");
  CHECK (literal_delivery (0, EVENT_START, 8.5, 10.5, .7, -.2, .3, 0, 0, .5, inherited),
    "unaligned first sample forwards exact literal fields through real Core");
  GlimsStrokeSampleV2 p = sample (18.5, 16.5, 18);
  memcpy (storage + 1, &p, sizeof p); storage[sizeof p + 1] = 0xc7;
  p = sample (28.5, 22.5, 19); memcpy (storage + 1 + stride, &p, sizeof p); storage[2 * stride] = 0xd8;
  GlimsStrokePacketV2 input = {sizeof input, stride, storage + 1, 2, 2 * stride};
  CHECK (api->stroke_continue_v2 (engine, stroke, &input, NULL) == GLIMS_STATUS_OK && deliveries->len == 5 &&
    literal_delivery (3, EVENT_INTERPOLATE, 18.5, 16.5, .7, -.2, .3, 18, 0, .5, inherited) &&
    literal_delivery (4, EVENT_INTERPOLATE, 28.5, 22.5, .7, -.2, .3, 19, 0, .5, inherited),
    "odd byte stride copies each known sample in order rather than casting an array");
  memset (storage, 0xee, 1 + 3 * stride);
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "caller can overwrite packet storage after synchronous delivery"); stroke = 0;

  first = sample (8.5, 10.5, 20); input = packet (&first, 1);
  NEED (begin (engine, &scene, &input, &stroke) == GLIMS_STATUS_OK, "maximum-payload control begins normally");
  many = g_malloc (1048576);
  memset (many, 0xa7, 1048576);
  for (guint i = 0; i < 4096; i++) {
    p = sample (8.5, 10.5, 20); p.struct_size = 256;
    memcpy (many + 256 * i, &p, sizeof p);
  }
  input = (GlimsStrokePacketV2) {sizeof input, 256, many, 4096, 1048576};
  guint n = deliveries->len;
  CHECK (api->stroke_continue_v2 (engine, stroke, &input, NULL) == GLIMS_STATUS_OK && deliveries->len == n + 4096 &&
    literal_delivery (n, EVENT_INTERPOLATE, 8.5, 10.5, .7, -.2, .3, 20, 0, .5, inherited) &&
    literal_delivery (n + 4095, EVENT_INTERPOLATE, 8.5, 10.5, .7, -.2, .3, 20, 0, .5, inherited),
    "exact 4096-sample and 1-MiB payload boundary is accepted without interpreting future tails");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "maximum-payload stroke remains finishable"); stroke = 0;
  for (guint i = 0; i < 2; i++) {
    first = sample (i == 0 ? -524288 : 524288, i == 0 ? 524288 : -524288, 50);
    input = packet (&first, 1); n = deliveries->len;
    GlimsStatus status = begin (engine, &scene, &input, &stroke);
    CHECK (status == GLIMS_STATUS_OK && stroke > 0 &&
      literal_delivery (n, EVENT_START, first.x, first.y, .7, -.2, .3, 0, 0, .5, inherited),
      i == 0 ? "negative coordinate policy boundary reaches Core safely" : "positive coordinate policy boundary reaches Core safely");
    if (stroke) { CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "off-canvas boundary tap ends without a million-pixel connecting drag"); stroke = 0; }
  }
cleanup:
  if (stroke) api->stroke_end (engine, stroke);
  g_free (storage); g_free (many); close_scene (engine, &scene);
}

static void
mixed_versions_and_resource (GlimsEngine *engine, GlimsResourceID inherited)
{
  Scene scene = {0}; GlimsStrokeID stroke = 0; Snapshot live, after;
  GimpContext *context = gimp_get_user_context (engine->gimp);
  GimpBrush *original = gimp_context_get_brush (context);
  if (original) g_object_ref (original);
  NEED (seed (engine, &scene), "mixed-version and explicit-resource controls own a real image");
  GlimsStrokeSampleV2 p = sample (8.5, 10.5, 100);
  GlimsStrokePacketV2 input = packet (&p, 1);
  NEED (api->stroke_begin_v2 (engine, scene.image, scene.layer, inherited, &pencil, &input, &stroke, NULL) == GLIMS_STATUS_OK &&
    snapshot (engine, &scene, &live), "explicit resource starts one captured V2 stroke");
  guint n = deliveries->len;
  CHECK (api->stroke_continue (engine, stroke, legacy_points + 1, 1) == GLIMS_STATUS_INVALID_ARGUMENT &&
    deliveries->len == n && snapshot (engine, &scene, &after) && unchanged (&live, &after),
    "V1 continuation cannot bypass validation on a V2 stroke");
  GimpContainer *brushes = gimp_data_factory_get_container (engine->gimp->brush_factory);
  GimpBrush *other = GIMP_BRUSH (gimp_container_get_child_by_name (brushes, "2. Block 01"));
  if (other == original) other = GIMP_BRUSH (gimp_container_get_child_by_name (brushes, "2. Hardness 025"));
  NEED (GIMP_IS_BRUSH (other) && other != original, "resource pin control has a distinct installed native brush");
  gimp_context_set_brush (context, other);
  p = sample (23.5, 18.5, 101); input = packet (&p, 1); n = deliveries->len;
  CHECK (api->stroke_continue_v2 (engine, stroke, &input, NULL) == GLIMS_STATUS_OK &&
    literal_delivery (n, EVENT_INTERPOLATE, 23.5, 18.5, .7, -.2, .3, 101, 0, .5, inherited),
    "accepted V2 options keep the explicit brush after a later user-context brush choice");
  NEED (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "explicit captured V2 stroke ends once"); stroke = 0;
  gimp_context_set_brush (context, original);
  NEED (api->stroke_begin (engine, scene.image, scene.layer, &pencil, legacy_points, &stroke, NULL) == GLIMS_STATUS_OK &&
    snapshot (engine, &scene, &live), "ordinary V1 stroke remains available");
  n = deliveries->len;
  CHECK (api->stroke_continue_v2 (engine, stroke, &input, NULL) == GLIMS_STATUS_INVALID_ARGUMENT &&
    deliveries->len == n && snapshot (engine, &scene, &after) && unchanged (&live, &after),
    "V2 continuation refuses a V1 stroke before native paint");
  GlimsStrokePoint legacy = {20.5, 20.5, 2, -2, 3, 200}; n = deliveries->len;
  CHECK (api->stroke_continue (engine, stroke, &legacy, 1) == GLIMS_STATUS_OK &&
    literal_delivery (n, EVENT_INTERPOLATE, 20.5, 20.5, 1, -1, 1, 200, 0, .5, inherited),
    "V1 still clamps legacy pressure and tilt instead of inheriting strict V2 ranges");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "V1 stroke survives a refused mixed continuation"); stroke = 0;
cleanup:
  if (stroke) api->stroke_end (engine, stroke);
  if (original) { gimp_context_set_brush (context, original); g_object_unref (original); }
  close_scene (engine, &scene);
}

static GlimsStatus
run_on_engine (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GimpBrush *brush = gimp_context_get_brush (gimp_get_user_context (engine->gimp));
  GlimsResourceID inherited = brush ? (GlimsResourceID) gimp_data_get_id (GIMP_DATA (brush)) : 0;
  CHECK (inherited > 0, "native user context supplies an authentic brush resource");
  if (!inherited) return GLIMS_STATUS_FAILED;
  legacy_control (engine, inherited);
  CHECK (has_v2 (), "facade provides both appended V2 slots after the unchanged171 prefix");
  if (!has_v2 ()) {
    puts ("NOT RUN V2 coordinate, malformed, timestamp, alignment, mixed and resource groups: old171 has no V2 tail");
    return GLIMS_STATUS_OK;
  }
  delivery_and_pixels (engine, inherited);
  malformed_samples (engine);
  packet_shapes_and_times (engine);
  future_alignment_and_limits (engine, inherited);
  mixed_versions_and_resource (engine, inherited);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) { fprintf (stderr, "usage: %s WORK\n", argv[0]); return 2; }
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof (GlimsEngineAPI, stroke_begin_with_capture_facts) +
                                sizeof api->stroke_begin_with_capture_facts) return 2;
  deliveries = g_array_new (FALSE, FALSE, sizeof (Delivery));
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus status = api->start (&config, &engine, &error);
  CHECK (status == GLIMS_STATUS_OK && engine, "one real native engine starts with private settings");
  if (error) api->free_string (error);
  if (engine) {
    CHECK (glims_engine_call (engine, run_on_engine, NULL) == GLIMS_STATUS_OK, "native worker finishes the owned coordinate oracle");
    api->stop (engine); engine = NULL;
    if (has_v2 ()) {
      GlimsStrokeSampleV2 p = sample (10, 10, 0); GlimsStrokePacketV2 input = packet (&p, 1);
      GlimsStrokeID out = 777; error = (char *) "caller sentinel";
      status = api->stroke_begin_v2 (NULL, 1, 1, 0, &pencil, &input, &out, &error);
      CHECK (status == GLIMS_STATUS_NOT_RUNNING && out == 0 && error == NULL,
        "public stopped-engine begin clears output/error before refusing");
      if (error && strcmp (error, "caller sentinel")) api->free_string (error);
    }
  }
  g_array_unref (deliveries); g_free (user); g_free (cache);
  printf ("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}

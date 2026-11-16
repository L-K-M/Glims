/* Real opaque Background layer, guarded brush capture/replay and Undo. */
#define main glims_original_facts_fixture_main
#include "recorder-stroke-capture-facts-tests.c"
#undef main
#include <math.h>
#include "facade-policy.h"
#include <sys/mman.h>
#include <unistd.h>

static GlimsStatus
seed_opaque (GlimsEngine *engine, gpointer data)
{
  Scene *scene = data;
  GlimsStatus status = api->image_new (engine, WIDTH, HEIGHT, &scene->image, NULL);
  if (status != GLIMS_STATUS_OK) return status;
  GlimsOpenImage *open = glims_lookup_image (engine, scene->image);
  GList *layers = open ? gimp_image_get_layer_iter (open->image) : NULL;
  GimpDrawable *drawable = layers ? GIMP_DRAWABLE (layers->data) : NULL;
  if (!drawable || gimp_drawable_has_alpha (drawable) || !gimp_drawable_is_rgb (drawable))
    return GLIMS_STATUS_FAILED;
  guint8 pixels[BYTES];
  for (guint y = 0; y < HEIGHT; y++) for (guint x = 0; x < WIDTH; x++) {
    gsize i = (y * WIDTH + x) * 4;
    pixels[i] = (guint8) (33 + (x * 5 + y * 3) % 199);
    pixels[i + 1] = (guint8) (29 + (x + y * 9) % 197);
    pixels[i + 2] = (guint8) (37 + (x * 11 + y) % 187);
    pixels[i + 3] = 255;
  }
  GeglBuffer *buffer = gimp_drawable_get_buffer (drawable);
  gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT), 0,
                   babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (drawable, 0, 0, WIDTH, HEIGHT);
  gimp_image_clean_all (open->image);
  gimp_image_flush (open->image);
  scene->layer = gimp_item_get_id (GIMP_ITEM (drawable));
  return GLIMS_STATUS_OK;
}

static GlimsStatus
read_opaque_raw (GlimsEngine *engine, gpointer data)
{
  Snapshot *snapshot = data;
  GlimsOpenImage *open = glims_lookup_image (engine, snapshot->scene->image);
  GimpDrawable *drawable = open ? glims_lookup_drawable (open, snapshot->scene->layer) : NULL;
  if (!drawable || G_OBJECT_TYPE (drawable) != GIMP_TYPE_LAYER ||
      gimp_drawable_has_alpha (drawable) || !gimp_drawable_is_rgb (drawable))
    return GLIMS_STATUS_FAILED;
  gegl_buffer_get (gimp_drawable_get_buffer (drawable), GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT), 1,
                   babl_format ("R'G'B'A u8"), snapshot->raw, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  return GLIMS_STATUS_OK;
}

static gboolean
read_opaque (GlimsEngine *engine, const Scene *scene, Snapshot *snapshot)
{
  snapshot->scene = scene;
  return glims_engine_call (engine, read_opaque_raw, snapshot) == GLIMS_STATUS_OK &&
         api->image_render (engine, scene->image, 1, (GlimsRect) {0, 0, WIDTH, HEIGHT},
                            snapshot->merged, WIDTH * 4) == GLIMS_STATUS_OK &&
         api->image_undo_info (engine, scene->image, &snapshot->undo) == GLIMS_STATUS_OK;
}


static GlimsStatus set_background (GlimsEngine *engine, gpointer data)
{
  const double *rgb = data;
  GeglColor *color = gegl_color_new (NULL);
  gegl_color_set_rgba_with_space (color, rgb[0], rgb[1], rgb[2], 1.0, NULL);
  gimp_context_set_background (gimp_get_user_context (engine->gimp), color);
  g_object_unref (color);
  return GLIMS_STATUS_OK;
}

static GlimsStatus read_background (GlimsEngine *engine, gpointer data)
{
  double *rgb = data, alpha;
  GeglColor *color = gimp_context_get_background (gimp_get_user_context (engine->gimp));
  if (!color) return GLIMS_STATUS_FAILED;
  gegl_color_get_rgba_with_space (color, &rgb[0], &rgb[1], &rgb[2], &alpha, NULL);
  return GLIMS_STATUS_OK;
}

int main (int argc, char **argv)
{
  if (argc != 2) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL; GlimsStrokeID stroke = 0;
  Scene reference = {0}, actual = {0}, legacy = {0}, legacy_reference = {0}, selected_ref = {0}, selected_actual = {0};
  Snapshot before, expected, result, before_invalid;
  const double blue[] = {.1, .4, .7}, white[] = {1, 1, 1}, red[] = {.8, .2, .1};
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) return 2;
  GlimsBrushSettings brush = pencil;
  brush.tool = GLIMS_PAINT_ERASER;
  CHECK (api->struct_size >= offsetof (GlimsEngineAPI, brush_settings_features) + sizeof api->brush_settings_features &&
         api->brush_settings_features &&
         (api->brush_settings_features () & GLIMS_BRUSH_FEATURE_ERASER_BACKGROUND),
         "engine advertises the optional eraser background");
  NEED (glims_engine_call (engine, seed_opaque, &reference) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_opaque, &actual) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_opaque, &legacy) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_opaque, &legacy_reference) == GLIMS_STATUS_OK &&
        read_opaque (engine, &actual, &before), "independent opaque eraser scenes seeded");
  NEED (glims_engine_call (engine, set_background, (gpointer) blue) == GLIMS_STATUS_OK &&
        api->stroke_begin (engine, reference.image, reference.layer, &brush, trace, &stroke, &error) == GLIMS_STATUS_OK &&
        finish_trace (engine, &stroke) && read_opaque (engine, &reference, &expected) &&
        changed_once (&before, &expected), "native blue-background reference paints");
  NEED (glims_engine_call (engine, set_background, (gpointer) white) == GLIMS_STATUS_OK,
        "shared native context changed independently");
  brush.has_eraser_background = true;
  brush.eraser_background_red = blue[0]; brush.eraser_background_green = blue[1];
  brush.eraser_background_blue = blue[2];
  NEED (api->stroke_begin (engine, actual.image, actual.layer, &brush, trace, &stroke, &error) == GLIMS_STATUS_OK,
        "explicit background stroke starts");
  {
    double shared[3] = {0};
    CHECK (glims_engine_call (engine, read_background, shared) == GLIMS_STATUS_OK &&
           fabs (shared[0] - 1) < 1e-6 && fabs (shared[1] - 1) < 1e-6 && fabs (shared[2] - 1) < 1e-6,
           "the explicit stroke does not mutate the shared background");
  }
  NEED (glims_engine_call (engine, set_background, (gpointer) red) == GLIMS_STATUS_OK &&
        finish_trace (engine, &stroke) && read_opaque (engine, &actual, &result), "explicit background stroke paints");
  CHECK (same_image (&expected, &result), "explicit blue background matches native reference despite a context change mid-stroke");
  brush.has_eraser_background = false;
  NEED (api->stroke_begin (engine, legacy_reference.image, legacy_reference.layer, &brush, trace, &stroke, &error) == GLIMS_STATUS_OK &&
        finish_trace (engine, &stroke) && read_opaque (engine, &legacy_reference, &expected),
        "native red-background reference paints");
  brush.struct_size = offsetof (GlimsBrushSettings, has_eraser_background);
  brush.has_eraser_background = true;
  NEED (api->stroke_begin (engine, legacy.image, legacy.layer, &brush, trace, &stroke, &error) == GLIMS_STATUS_OK &&
        finish_trace (engine, &stroke) && read_opaque (engine, &legacy, &result),
        "legacy-sized eraser stroke paints");
  CHECK (same_image (&expected, &result), "legacy prefix retains Eraser and inherits its original context");
  {
    GlimsStrokeSampleV2 samples[] = {
      {.struct_size = sizeof (GlimsStrokeSampleV2), .flags = 3, .x = 9.5, .y = 10.5,
       .pressure = .5, .xtilt = -.2, .ytilt = .3, .time_ms = 0xffffffffu,
       .rotation_turns = .25, .tangential_pressure = -.5},
      {.struct_size = sizeof (GlimsStrokeSampleV2), .flags = 3, .x = 25.5, .y = 18.5,
       .pressure = .8, .xtilt = .2, .ytilt = -.3, .time_ms = 1,
       .rotation_turns = .75, .tangential_pressure = .5}
    };
    GlimsStrokePacketV2 first = {.struct_size = sizeof first, .sample_stride = sizeof samples[0],
      .samples = samples, .count = 1, .byte_count = sizeof samples[0]};
    GlimsStrokePacketV2 next = first; next.samples = samples + 1;
    brush.struct_size = sizeof brush; brush.has_eraser_background = false;
    NEED (api->image_undo (engine, reference.image) == GLIMS_STATUS_OK &&
          api->image_undo (engine, actual.image) == GLIMS_STATUS_OK &&
          glims_engine_call (engine, set_background, (gpointer) blue) == GLIMS_STATUS_OK &&
          api->stroke_begin_v2 (engine, reference.image, reference.layer, 0, &brush, &first, &stroke, &error) == GLIMS_STATUS_OK &&
          api->stroke_continue_v2 (engine, stroke, &next, &error) == GLIMS_STATUS_OK &&
          api->stroke_end (engine, stroke) == GLIMS_STATUS_OK && read_opaque (engine, &reference, &expected),
          "tablet blue-background reference paints");
    stroke = 0;
    brush.has_eraser_background = true;
    NEED (glims_engine_call (engine, set_background, (gpointer) white) == GLIMS_STATUS_OK &&
          api->stroke_begin_v2 (engine, actual.image, actual.layer, 0, &brush, &first, &stroke, &error) == GLIMS_STATUS_OK &&
          glims_engine_call (engine, set_background, (gpointer) red) == GLIMS_STATUS_OK &&
          api->stroke_continue_v2 (engine, stroke, &next, &error) == GLIMS_STATUS_OK &&
          api->stroke_end (engine, stroke) == GLIMS_STATUS_OK && read_opaque (engine, &actual, &result),
          "explicit tablet background stroke paints");
    stroke = 0;
    CHECK (same_image (&expected, &result), "tablet stroke pins blue across context changes and timestamp wrap");
  }
  {
    const size_t old_size = offsetof (GlimsBrushSettings, has_eraser_background);
    const size_t page = (size_t) getpagesize ();
    void *mapping = mmap (NULL, 2 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    NEED (mapping != MAP_FAILED && mprotect ((char *) mapping + page, page, PROT_NONE) == 0,
          "protected legacy prefix is allocated");
    GlimsBrushSettings old = pencil;
    old.tool = GLIMS_PAINT_ERASER; old.struct_size = (uint32_t) old_size;
    void *protected_prefix = (char *) mapping + page - old_size;
    memcpy (protected_prefix, &old, old_size);
    old.tool = GLIMS_PAINT_CLONE; old.source_drawable = 1234;
    memcpy (protected_prefix, &old, old_size);
    CHECK (glims_facade_brush_source (protected_prefix) == 1234,
           "legacy protected Clone prefix retains its source admission");
    old.tool = GLIMS_PAINT_ERASER;
    memcpy (protected_prefix, &old, old_size);
    GlimsBrushSettings normalized = {0};
    CHECK (glims_read_brush (protected_prefix, &normalized) && normalized.tool == GLIMS_PAINT_ERASER &&
           !normalized.has_eraser_background, "legacy prefix is read without crossing a protected page");
    stroke = 0;
    CHECK (api->stroke_begin (engine, legacy.image, legacy.layer, protected_prefix, trace, &stroke, &error) == GLIMS_STATUS_OK &&
           finish_trace (engine, &stroke), "public stroke accepts a protected legacy prefix");
    munmap (mapping, 2 * page);
  }
  {
    GlimsPoint corners[] = {{8, 8}, {40, 30}};
    GlimsSelectOptions selection = {.struct_size = sizeof selection, .operation = GLIMS_SELECT_REPLACE};
    NEED (glims_engine_call (engine, seed_opaque, &selected_ref) == GLIMS_STATUS_OK &&
          glims_engine_call (engine, seed_opaque, &selected_actual) == GLIMS_STATUS_OK &&
          api->select_shape (engine, selected_ref.image, GLIMS_SHAPE_RECTANGLE, corners, 2, &selection) == GLIMS_STATUS_OK &&
          api->select_shape (engine, selected_actual.image, GLIMS_SHAPE_RECTANGLE, corners, 2, &selection) == GLIMS_STATUS_OK,
          "matching opaque selection stroke scenes prepared");
    brush.struct_size = sizeof brush; brush.has_eraser_background = false;
    NEED (glims_engine_call (engine, set_background, (gpointer) blue) == GLIMS_STATUS_OK &&
          api->selection_stroke (engine, selected_ref.image, selected_ref.layer, 0, &brush, &error) == GLIMS_STATUS_OK &&
          read_opaque (engine, &selected_ref, &expected), "native blue selection stroke paints");
    brush.has_eraser_background = true;
    NEED (glims_engine_call (engine, set_background, (gpointer) white) == GLIMS_STATUS_OK &&
          api->selection_stroke (engine, selected_actual.image, selected_actual.layer, 0, &brush, &error) == GLIMS_STATUS_OK &&
          read_opaque (engine, &selected_actual, &result), "explicit blue selection stroke paints");
    CHECK (same_image (&expected, &result), "selection stroke preserves the explicit background across native context preparation");
  }
  brush.struct_size = sizeof brush;
  brush.eraser_background_blue = NAN;
  NEED (read_opaque (engine, &actual, &before_invalid), "invalid color witness captured");
  stroke = -1;
  CHECK (api->stroke_begin (engine, actual.image, actual.layer, &brush, trace, &stroke, &error) == GLIMS_STATUS_INVALID_ARGUMENT &&
         !stroke && read_opaque (engine, &actual, &result) && same_image (&before_invalid, &result),
         "nonfinite background refuses before pixels and history");
cleanup:
  if (stroke) api->stroke_end (engine, stroke);
  if (error) { fprintf (stderr, "%s\n", error); free_error (error); }
  if (reference.image) api->image_close (engine, reference.image);
  if (actual.image) api->image_close (engine, actual.image);
  if (legacy.image) api->image_close (engine, legacy.image);
  if (legacy_reference.image) api->image_close (engine, legacy_reference.image);
  if (selected_ref.image) api->image_close (engine, selected_ref.image);
  if (selected_actual.image) api->image_close (engine, selected_actual.image);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %u eraser background checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

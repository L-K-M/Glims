/* Default-tool capture against ordinary V1, independent RGBA image seeds. */
#define main recorder_existing_facts_main
#include "recorder-stroke-capture-facts-tests.c"
#undef main

#include "core/gimpdynamics.h"
#include "core/gimppaintinfo.h"
#include "paint/gimppaintoptions.h"

static const GlimsBrushSettings paintbrush_settings = {
  .struct_size = sizeof (GlimsBrushSettings), .tool = GLIMS_PAINT_PAINTBRUSH,
  .size = 8.5, .opacity = .79, .red = .91, .green = .16, .blue = .31,
  .pressure_size = true, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1
};

typedef struct {
  GimpPaintOptions *pencil_defaults;
  gboolean original_hard, saved, pressure;
} EquivalentOptions;

static GlimsStatus
equivalent_options (GlimsEngine *engine, gpointer data)
{
  EquivalentOptions *probe = data;
  GimpPaintInfo *paint_info = glims_paint_info_for_tool (engine->gimp, GLIMS_PAINT_PAINTBRUSH);
  GimpPaintInfo *pencil_info = glims_paint_info_for_tool (engine->gimp, GLIMS_PAINT_PENCIL);
  if (!paint_info || !pencil_info || !paint_info->paint_options || !pencil_info->paint_options)
    return GLIMS_STATUS_FAILED;
  if (!probe->saved) {
    probe->pencil_defaults = g_object_ref (pencil_info->paint_options);
    g_object_get (probe->pencil_defaults, "hard", &probe->original_hard, NULL);
    probe->saved = TRUE;
  }
  /* Pencil is a native Paintbrush subclass with a different hard default.
   * Match that option explicitly so tool identity is the only difference
   * in the fingerprint comparison, and restore the preset on the worker. */
  g_object_set (probe->pencil_defaults, "hard", paint_info->paint_options->hard, NULL);
  GlimsBrushSettings settings = paintbrush_settings;
  settings.pressure_size = probe->pressure;
  GimpPaintOptions *paint = glims_make_paint_options (engine->gimp, paint_info, &settings, NULL);
  settings.tool = GLIMS_PAINT_PENCIL;
  GimpPaintOptions *draw = glims_make_paint_options (engine->gimp, pencil_info, &settings, NULL);
  gboolean same = FALSE;
  if (paint && draw) {
    GimpContext *a = GIMP_CONTEXT (paint), *b = GIMP_CONTEXT (draw);
    GimpDynamics *stock = GIMP_DYNAMICS (gimp_container_get_child_by_name (
        gimp_data_factory_get_container (engine->gimp->dynamics_factory), "Pressure Size"));
    same = gimp_context_get_brush (a) == gimp_context_get_brush (b) &&
      gimp_context_get_paint_mode (a) == gimp_context_get_paint_mode (b) &&
      gimp_context_get_opacity (a) == gimp_context_get_opacity (b) &&
      paint->brush_size == draw->brush_size && paint->brush_angle == draw->brush_angle &&
      paint->brush_aspect_ratio == draw->brush_aspect_ratio && paint->brush_spacing == draw->brush_spacing &&
      paint->brush_hardness == draw->brush_hardness && paint->brush_force == draw->brush_force &&
      paint->hard == draw->hard && paint->use_applicator == draw->use_applicator &&
      paint->brush_lock_to_view == draw->brush_lock_to_view && paint->application_mode == draw->application_mode &&
      gimp_paint_options_are_dynamics_enabled (paint) == probe->pressure &&
      gimp_paint_options_are_dynamics_enabled (draw) == probe->pressure &&
      (!probe->pressure || (GIMP_IS_DYNAMICS (stock) && gimp_data_get_file (GIMP_DATA (stock)) &&
        gimp_context_get_dynamics (a) == stock && gimp_context_get_dynamics (b) == stock));
  }
  g_clear_object (&paint);
  g_clear_object (&draw);
  return same ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static GlimsStatus
restore_equivalent_options (GlimsEngine *engine, gpointer data)
{
  (void) engine;
  EquivalentOptions *probe = data;
  gboolean same = TRUE;
  if (probe->saved) {
    g_object_set (probe->pencil_defaults, "hard", probe->original_hard, NULL);
    same = probe->pencil_defaults->hard == probe->original_hard;
  }
  g_clear_object (&probe->pencil_defaults);
  probe->saved = FALSE;
  return same ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static gboolean
paintbrush_case (GlimsEngine *engine, const BrushIdentity *brush, EquivalentOptions *options,
                 gboolean pressure, Snapshot *golden)
{
  Scene reference = {0}, captured = {0}, replayed = {0}, penciled = {0};
  Snapshot before, expected, actual;
  gboolean reference_ready = FALSE;
  GlimsStrokeID stroke = 0;
  char *error = NULL;
  GlimsBrushSettings settings = paintbrush_settings;
  settings.pressure_size = pressure;
  GlimsBrushSettings pencil_settings = settings;
  pencil_settings.tool = GLIMS_PAINT_PENCIL;
  FactsWithTail facts = fact_box (sizeof facts, FALSE), replay = fact_box (sizeof replay, FALSE);
  FactsWithTail pencil_facts = fact_box (sizeof pencil_facts, FALSE);
  printf ("OBS default Paintbrush pressure-size=%s brush=%s\n", pressure ? "true" : "false", brush->name);

  options->pressure = pressure;
  NEED (glims_engine_call (engine, equivalent_options, options) == GLIMS_STATUS_OK,
        "Paintbrush and Pencil have identical effective scalar options and actual dynamics before capture");
  NEED (glims_engine_call (engine, seed_image, &reference) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &captured) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &replayed) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &penciled) == GLIMS_STATUS_OK &&
        read_image (engine, &reference, &before) &&
        read_image (engine, &captured, &actual) && same_image (&before, &actual) &&
        read_image (engine, &replayed, &actual) && same_image (&before, &actual) &&
        read_image (engine, &penciled, &actual) && same_image (&before, &actual),
        "ordinary V1, capture, replay and Pencil use independently identical RGBA seeds");
  NEED (api->stroke_begin (engine, reference.image, reference.layer, &settings, trace, &stroke, &error) == GLIMS_STATUS_OK &&
        !error && stroke > 0 && finish_trace (engine, &stroke) &&
        read_image (engine, &reference, &expected) && changed_once (&before, &expected),
        "ordinary inherited-brush V1 Paintbrush changes raw and merged pixels with one Undo");
  *golden = expected;
  golden->scene = NULL;
  reference_ready = TRUE;
  NEED (api->stroke_begin_with_capture_facts (engine, penciled.image, penciled.layer, brush->id,
          &pencil_settings, trace, NULL, &stroke, &pencil_facts.facts, &error) == GLIMS_STATUS_OK &&
        !error && stroke > 0 && finish_trace (engine, &stroke) &&
        matches_identity (&pencil_facts.facts, brush) && tail_intact (&pencil_facts, sizeof pencil_facts),
        "Pencil capture supplies a valid tool-distinction control with the matched native options");
  NEED (api->stroke_begin_with_capture_facts (engine, captured.image, captured.layer, 0,
          &settings, trace, NULL, &stroke, &facts.facts, &error) == GLIMS_STATUS_OK &&
        !error && stroke > 0 && finish_trace (engine, &stroke),
        "default Paintbrush live capture completes its ordinary native stroke");
  NEED (matches_identity (&facts.facts, brush) && tail_intact (&facts, sizeof facts),
        "default Paintbrush capture returns its actual inherited brush identity and supported fingerprint");
  CHECK (read_image (engine, &captured, &actual) && same_image (&expected, &actual),
         "captured Paintbrush equals independent ordinary V1 raw, merged and history");
  CHECK (strcmp (facts.facts.fingerprint, pencil_facts.facts.fingerprint),
         "Paintbrush fingerprint differs from Pencil with identical effective values");
  GlimsResourceID resolved = 0;
  NEED (api->resource_resolve (engine, GLIMS_RESOURCE_BRUSH, facts.facts.brush_name,
          facts.facts.brush_collection, facts.facts.brush_internal, &resolved, &error) == GLIMS_STATUS_OK &&
        !error && resolved == brush->id, "captured default Paintbrush identity resolves explicitly");
  NEED (refused_before_paint (engine, &replayed, &before, resolved, &pencil_settings,
                             facts.facts.fingerprint, GLIMS_STATUS_FAILED),
        "a Paintbrush fingerprint cannot replay as Pencil before pixels or history change");
  NEED (refused_before_paint (engine, &replayed, &before, resolved, &settings,
                             pencil_facts.facts.fingerprint, GLIMS_STATUS_FAILED),
        "a Pencil fingerprint cannot replay as Paintbrush before pixels or history change");
  NEED (api->stroke_begin_with_capture_facts (engine, replayed.image, replayed.layer, resolved,
          &settings, trace, facts.facts.fingerprint, &stroke, &replay.facts, &error) == GLIMS_STATUS_OK &&
        !error && stroke > 0 && finish_trace (engine, &stroke),
        "guarded default Paintbrush replay uses the explicit brush on a fresh RGBA image");
  CHECK (matches_identity (&replay.facts, brush) && tail_intact (&replay, sizeof replay) &&
         !strcmp (facts.facts.fingerprint, replay.facts.fingerprint),
         "Paintbrush replay returns the same owned identity and fingerprint");
  CHECK (read_image (engine, &replayed, &actual) && same_image (&expected, &actual),
         "Paintbrush replay exactly matches independent V1 raw, merged and one-Undo result");
  CHECK (api->image_undo (engine, replayed.image) == GLIMS_STATUS_OK &&
         read_image (engine, &replayed, &actual) && same_pixels (&before, &actual) &&
         actual.undo.undo_count == before.undo.undo_count && actual.undo.redo_count == 1,
         "one Paintbrush replay Undo restores the original raw and merged pixels");
  CHECK (api->image_redo (engine, replayed.image) == GLIMS_STATUS_OK &&
         read_image (engine, &replayed, &actual) && same_image (&expected, &actual),
         "one Paintbrush replay Redo restores exact independent V1 pixels and history");
cleanup:
  if (error) fprintf (stderr, "OBS Paintbrush capture: %s\n", error);
  if (stroke > 0) api->stroke_end (engine, stroke);
  free_error (error);
  free_facts (&facts.facts);
  free_facts (&replay.facts);
  free_facts (&pencil_facts.facts);
  Scene scenes[] = {reference, captured, replayed, penciled};
  for (gsize i = 0; i < G_N_ELEMENTS (scenes); i++)
    if (scenes[i].image) CHECK (api->image_close (engine, scenes[i].image) == GLIMS_STATUS_OK, "default Paintbrush image closes");
  return reference_ready;
}

static void
unsupported_blur_case (GlimsEngine *engine, GlimsResourceID brush)
{
  Scene scene = {0};
  Snapshot before, after, restored;
  GlimsStrokeID stroke = 0;
  char *error = NULL;
  GlimsBrushSettings settings = paintbrush_settings;
  settings.tool = GLIMS_PAINT_BLUR;
  settings.rate = 80;
  FactsWithTail facts = fact_box (sizeof facts, FALSE);
  NEED (glims_engine_call (engine, seed_image, &scene) == GLIMS_STATUS_OK && read_image (engine, &scene, &before),
        "unsupported Blur rate80 starts from an ordinary RGBA seed");
  NEED (api->stroke_begin_with_capture_facts (engine, scene.image, scene.layer, brush, &settings, trace,
          NULL, &stroke, &facts.facts, &error) == GLIMS_STATUS_OK && !error && stroke > 0,
        "unsupported Blur rate80 still admits ordinary live painting");
  CHECK (facts_empty (&facts.facts) && tail_intact (&facts, sizeof facts),
         "unsupported Blur rate80 returns nil facts and preserves the future tail");
  NEED (finish_trace (engine, &stroke), "unsupported Blur completes V1 continuation and end");
  NEED (read_image (engine, &scene, &after) && changed_once (&before, &after),
        "unsupported Blur rate80 changes raw and merged pixels with exactly one Undo");
  CHECK (api->image_undo (engine, scene.image) == GLIMS_STATUS_OK &&
         read_image (engine, &scene, &restored) && same_pixels (&before, &restored) &&
         restored.undo.undo_count == before.undo.undo_count && restored.undo.redo_count == 1,
         "unsupported Blur Undo restores the original raw and merged bytes");
  CHECK (api->image_redo (engine, scene.image) == GLIMS_STATUS_OK &&
         read_image (engine, &scene, &restored) && same_image (&after, &restored),
         "unsupported Blur Redo restores its exact changed pixels and history");
cleanup:
  if (stroke > 0) api->stroke_end (engine, stroke);
  free_error (error);
  free_facts (&facts.facts);
  if (scene.image) CHECK (api->image_close (engine, scene.image) == GLIMS_STATUS_OK, "unsupported Blur image closes");
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || !has_slot ()) return 2;
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL;
  char *error = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "native startup failed");
    free_error (error);
    g_free (user); g_free (cache);
    return 2;
  }
  BrushIdentity brushes[2] = {0};
  EquivalentOptions options = {0};
  gboolean discovered = glims_engine_call (engine, discover_brushes, brushes) == GLIMS_STATUS_OK;
  CHECK (discovered, "the engine supplies its actual inherited and a distinct installed monochrome brush");
  CHECK (has_slot (), "slot171 capture facts are available for the default Paintbrush fixture");
  if (discovered) {
    Snapshot golden[2] = {{0}};
    gboolean with_pressure = paintbrush_case (engine, &brushes[0], &options, TRUE, &golden[0]);
    gboolean without_pressure = paintbrush_case (engine, &brushes[0], &options, FALSE, &golden[1]);
    CHECK (with_pressure && without_pressure && memcmp (golden[0].raw, golden[1].raw, BYTES) &&
           memcmp (golden[0].merged, golden[1].merged, BYTES),
           "the same independent V1 Paintbrush pressure trace measurably differs when pressure size is disabled");
    unsupported_blur_case (engine, brushes[0].id);
  }
  CHECK (glims_engine_call (engine, restore_equivalent_options, &options) == GLIMS_STATUS_OK,
         "native Pencil defaults restore on the worker after the tool-distinction controls");
  api->stop (engine);
  for (gsize i = 0; i < G_N_ELEMENTS (brushes); i++) {
    g_free (brushes[i].name);
    g_free (brushes[i].collection);
  }
  g_free (user); g_free (cache);
  printf ("%s: %u default Paintbrush facts checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

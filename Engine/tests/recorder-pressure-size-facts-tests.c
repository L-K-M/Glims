/* Independent ordinary V1 pixels for the optional pressure-size capture path. */
#define main recorder_existing_facts_main
#include "recorder-stroke-capture-facts-tests.c"
#undef main

#include "core/gimpcurve.h"
#include "core/gimpdynamics.h"
#include "core/gimpdynamicsoutput.h"
#include "core/gimppaintinfo.h"
#include "paint/gimppaintoptions.h"

typedef struct {
  GimpDynamics *dynamics;
  GimpDynamicsOutput *size;
  GimpCurve *curve, *original;
  gchar *serialized;
} PressureProbe;

static GlimsStatus
discover_pressure (GlimsEngine *engine, gpointer data)
{
  PressureProbe *probe = data;
  GimpContainer *factory = gimp_data_factory_get_container (engine->gimp->dynamics_factory);
  GimpObject *stock = gimp_container_get_child_by_name (factory, "Pressure Size");
  if (!GIMP_IS_DYNAMICS (stock) || !gimp_data_get_file (GIMP_DATA (stock))) return GLIMS_STATUS_FAILED;
  probe->dynamics = g_object_ref (GIMP_DYNAMICS (stock));
  GimpDynamicsOutput *size = gimp_dynamics_get_output (probe->dynamics, GIMP_DYNAMICS_OUTPUT_SIZE);
  if (!size) return GLIMS_STATUS_FAILED;
  probe->size = g_object_ref (size);
  gboolean pressure = FALSE, random = TRUE;
  g_object_get (probe->size, "use-pressure", &pressure, "use-random", &random,
                 "pressure-curve", &probe->curve, NULL);
  if (!pressure || random || !probe->curve) return GLIMS_STATUS_FAILED;
  probe->original = GIMP_CURVE (gimp_config_duplicate (GIMP_CONFIG (probe->curve)));
  probe->serialized = gimp_config_serialize_to_string (GIMP_CONFIG (probe->dynamics), NULL);
  return probe->original && probe->serialized ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static GlimsStatus
check_local_pressure (GlimsEngine *engine, gpointer data)
{
  PressureProbe *probe = data;
  GlimsBrushSettings settings = pencil;
  settings.pressure_size = true;
  GimpPaintInfo *info = glims_paint_info_for_tool (engine->gimp, settings.tool);
  if (!info) return GLIMS_STATUS_FAILED;
  GimpPaintOptions *options = glims_make_paint_options (engine->gimp, info, &settings, NULL);
  gboolean actual = options && gimp_paint_options_are_dynamics_enabled (options) &&
    gimp_context_get_dynamics (GIMP_CONTEXT (options)) == probe->dynamics;
  g_clear_object (&options);
  return actual ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static GlimsStatus
alter_pressure_curve (GlimsEngine *engine, gpointer data)
{
  (void) engine;
  PressureProbe *probe = data;
  if (!probe->curve) return GLIMS_STATUS_FAILED;
  /* Change an actual enabled native curve, preserving a finite configuration. */
  gimp_curve_set_curve_type (probe->curve, GIMP_CURVE_FREE);
  gimp_curve_set_sample (probe->curve, 0.38, 0.1);
  gchar *changed = gimp_config_serialize_to_string (GIMP_CONFIG (probe->dynamics), NULL);
  gboolean different = changed && g_strcmp0 (changed, probe->serialized);
  g_free (changed);
  return different ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static GlimsStatus
restore_pressure (GlimsEngine *engine, gpointer data)
{
  (void) engine;
  PressureProbe *probe = data;
  if (!probe->original || !probe->curve || !probe->size) return GLIMS_STATUS_FAILED;
  gboolean copied = gimp_config_copy (GIMP_CONFIG (probe->original), GIMP_CONFIG (probe->curve), 0);
  g_object_set (probe->size, "use-random", FALSE, NULL);
  gchar *restored = gimp_config_serialize_to_string (GIMP_CONFIG (probe->dynamics), NULL);
  gboolean same = restored && !g_strcmp0 (restored, probe->serialized);
  if (!same && restored && probe->serialized) {
    gsize offset = 0;
    while (restored[offset] && probe->serialized[offset] &&
           restored[offset] == probe->serialized[offset]) offset++;
    fprintf (stderr, "OBS pressure restore copied=%d differs at %zu expected=%.100s actual=%.100s\n",
             copied, offset, probe->serialized + offset, restored + offset);
  }
  g_free (restored);
  return copied && same ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static GlimsStatus
enable_random_size (GlimsEngine *engine, gpointer data)
{
  (void) engine;
  PressureProbe *probe = data;
  gboolean random = FALSE;
  g_object_set (probe->size, "use-random", TRUE, NULL);
  g_object_get (probe->size, "use-random", &random, NULL);
  return random ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static GlimsStatus
release_pressure (GlimsEngine *engine, gpointer data)
{
  PressureProbe *probe = data;
  GlimsStatus status = restore_pressure (engine, data);
  g_clear_object (&probe->curve);
  g_clear_object (&probe->original);
  g_clear_object (&probe->size);
  g_clear_object (&probe->dynamics);
  g_clear_pointer (&probe->serialized, g_free);
  return status;
}

static void
pressure_case (GlimsEngine *engine, const BrushIdentity *brush, gboolean inherited,
               gboolean eraser, char digest[65], Snapshot *golden)
{
  Scene reference = {0}, without = {0}, captured = {0}, replayed = {0};
  Snapshot before, expected, actual;
  GlimsBrushSettings settings = pencil;
  settings.tool = eraser ? GLIMS_PAINT_ERASER : GLIMS_PAINT_PENCIL;
  settings.pressure_size = true;
  GlimsBrushSettings no_pressure = settings;
  no_pressure.pressure_size = false;
  GlimsResourceID requested = inherited ? 0 : brush->id;
  GlimsStrokeID stroke = 0;
  char *error = NULL;
  FactsWithTail facts = fact_box (sizeof facts, FALSE), replay = fact_box (sizeof replay, FALSE);
  printf ("OBS pressure-size %s %s brush\n", eraser ? "RGBA Eraser" : "Pencil", inherited ? "inherited" : "installed");

  NEED (glims_engine_call (engine, seed_image, &reference) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &without) == GLIMS_STATUS_OK &&
        read_image (engine, &reference, &before) && read_image (engine, &without, &actual) && same_image (&before, &actual),
        "independent pressure and no-pressure V1 images have identical RGBA seeds");
  GlimsStatus status = inherited
    ? api->stroke_begin (engine, reference.image, reference.layer, &settings, trace, &stroke, &error)
    : api->stroke_begin_with_brush_resource (engine, reference.image, reference.layer, requested, &settings, trace, &stroke, &error);
  NEED (status == GLIMS_STATUS_OK && !error && finish_trace (engine, &stroke) &&
        read_image (engine, &reference, &expected) && changed_once (&before, &expected),
        "ordinary pressure-size V1 changes raw and merged pixels with one Undo");
  *golden = expected;
  golden->scene = NULL;
  status = inherited
    ? api->stroke_begin (engine, without.image, without.layer, &no_pressure, trace, &stroke, &error)
    : api->stroke_begin_with_brush_resource (engine, without.image, without.layer, requested, &no_pressure, trace, &stroke, &error);
  NEED (status == GLIMS_STATUS_OK && !error && finish_trace (engine, &stroke) &&
        read_image (engine, &without, &actual) && changed_once (&before, &actual) && !same_pixels (&expected, &actual),
        "the same literal pressure trace measurably differs when pressure size is disabled");
  NEED (glims_engine_call (engine, seed_image, &captured) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &replayed) == GLIMS_STATUS_OK,
        "capture and guarded replay use separate native images");
  NEED (api->stroke_begin_with_capture_facts (engine, captured.image, captured.layer, requested,
          &settings, trace, NULL, &stroke, &facts.facts, &error) == GLIMS_STATUS_OK && stroke > 0 && !error &&
        finish_trace (engine, &stroke), "live pressure-size capture completes ordinary V1 input");
  NEED (matches_identity (&facts.facts, brush) && tail_intact (&facts, sizeof facts),
        "actual pressure-size capture yields owned brush identity and supported fingerprint");
  memcpy (digest, facts.facts.fingerprint, 65);
  CHECK (read_image (engine, &captured, &actual) && same_image (&expected, &actual),
         "captured pressure-size raw, merged and Undo result equals independent V1");
  GlimsResourceID resolved = 0;
  NEED (api->resource_resolve (engine, GLIMS_RESOURCE_BRUSH, facts.facts.brush_name,
          facts.facts.brush_collection, facts.facts.brush_internal, &resolved, &error) == GLIMS_STATUS_OK &&
        !error && resolved == brush->id, "saved pressure-size brush identity resolves explicitly");
  NEED (refused_before_paint (engine, &replayed, &before, resolved, &no_pressure, digest, GLIMS_STATUS_FAILED),
        "turning pressure size off refuses the pressure fingerprint before any paint");
  NEED (api->stroke_begin_with_capture_facts (engine, replayed.image, replayed.layer, resolved,
          &settings, trace, digest, &stroke, &replay.facts, &error) == GLIMS_STATUS_OK && !error && stroke > 0 &&
        finish_trace (engine, &stroke), "guarded pressure-size replay completes with the saved fingerprint");
  CHECK (matches_identity (&replay.facts, brush) && !strcmp (replay.facts.fingerprint, digest) &&
         tail_intact (&replay, sizeof replay), "replay returns the same actual pressure-size facts");
  CHECK (read_image (engine, &replayed, &actual) && same_image (&expected, &actual),
         "guarded pressure-size replay matches independent V1 raw, merged and history");
  CHECK (api->image_undo (engine, replayed.image) == GLIMS_STATUS_OK &&
         read_image (engine, &replayed, &actual) && same_pixels (&before, &actual) &&
         actual.undo.undo_count == before.undo.undo_count && actual.undo.redo_count == 1,
         "pressure-size Undo restores exact original raw and merged bytes");
  CHECK (api->image_redo (engine, replayed.image) == GLIMS_STATUS_OK &&
         read_image (engine, &replayed, &actual) && same_image (&expected, &actual),
         "pressure-size Redo restores exact independent V1 bytes and history");
cleanup:
  if (stroke > 0) api->stroke_end (engine, stroke);
  free_error (error);
  free_facts (&facts.facts);
  free_facts (&replay.facts);
  Scene scenes[] = {reference, without, captured, replayed};
  for (gsize i = 0; i < G_N_ELEMENTS (scenes); i++)
    if (scenes[i].image) CHECK (api->image_close (engine, scenes[i].image) == GLIMS_STATUS_OK, "pressure-size test image closes");
}

static void
mutation_cases (GlimsEngine *engine, const BrushIdentity *brush, PressureProbe *probe,
                 const char *digest, const Snapshot *golden)
{
  Scene replayed = {0}, unsupported = {0};
  Snapshot before, actual;
  GlimsStrokeID stroke = 0;
  char *error = NULL;
  GlimsBrushSettings settings = pencil;
  settings.pressure_size = true;
  FactsWithTail facts = fact_box (sizeof facts, FALSE), unrecordable = fact_box (sizeof unrecordable, FALSE);
  NEED (glims_engine_call (engine, seed_image, &replayed) == GLIMS_STATUS_OK &&
        read_image (engine, &replayed, &before), "curve-mutation replay starts from untouched seed bytes and history");
  NEED (glims_engine_call (engine, alter_pressure_curve, probe) == GLIMS_STATUS_OK,
        "the actual enabled native size pressure curve changes");
  NEED (refused_before_paint (engine, &replayed, &before, brush->id, &settings, digest, GLIMS_STATUS_FAILED),
        "changed pressure curve refuses guarded replay before any pixels or history");
  NEED (glims_engine_call (engine, restore_pressure, probe) == GLIMS_STATUS_OK,
        "restoring the curve recovers the exact original native config");
  NEED (api->stroke_begin_with_capture_facts (engine, replayed.image, replayed.layer, brush->id,
          &settings, trace, digest, &stroke, &facts.facts, &error) == GLIMS_STATUS_OK &&
        !error && stroke > 0 && finish_trace (engine, &stroke),
        "the same saved fingerprint admits replay after exact curve restoration");
  CHECK (read_image (engine, &replayed, &actual) && same_image (golden, &actual),
         "restored pressure replay matches the independent ordinary V1 oracle");
  NEED (glims_engine_call (engine, seed_image, &unsupported) == GLIMS_STATUS_OK &&
        read_image (engine, &unsupported, &before) &&
        glims_engine_call (engine, enable_random_size, probe) == GLIMS_STATUS_OK,
        "a fresh seed has actual unsupported size/use-random enabled");
  NEED (refused_before_paint (engine, &unsupported, &before, brush->id, &settings, digest, GLIMS_STATUS_FAILED),
        "unsupported random-size dynamics refuse guarded replay before pixels or history");
  NEED (api->stroke_begin_with_capture_facts (engine, unsupported.image, unsupported.layer, brush->id,
          &settings, trace, NULL, &stroke, &unrecordable.facts, &error) == GLIMS_STATUS_OK &&
        !error && stroke > 0 && finish_trace (engine, &stroke),
        "unguarded live painting still completes with unsupported random-size dynamics");
  CHECK (facts_empty (&unrecordable.facts) && tail_intact (&unrecordable, sizeof unrecordable) &&
         read_image (engine, &unsupported, &actual) && changed_once (&before, &actual),
         "unsupported live dynamics yield nil facts while changing raw/merged pixels with one Undo");
cleanup:
  if (stroke > 0) api->stroke_end (engine, stroke);
  free_error (error);
  free_facts (&facts.facts);
  free_facts (&unrecordable.facts);
  CHECK (glims_engine_call (engine, restore_pressure, probe) == GLIMS_STATUS_OK, "mutation cleanup restores the original stock dynamics config");
  if (replayed.image) CHECK (api->image_close (engine, replayed.image) == GLIMS_STATUS_OK, "curve replay image closes");
  if (unsupported.image) CHECK (api->image_close (engine, unsupported.image) == GLIMS_STATUS_OK, "unsupported dynamics image closes");
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
  PressureProbe probe = {0};
  BrushIdentity brushes[2] = {0};
  gboolean discovered = glims_engine_call (engine, discover_brushes, brushes) == GLIMS_STATUS_OK &&
                         glims_engine_call (engine, discover_pressure, &probe) == GLIMS_STATUS_OK;
  CHECK (discovered, "installed Pressure Size and distinct inherited/installed monochrome brushes exist");
  if (discovered) {
    CHECK (glims_engine_call (engine, check_local_pressure, &probe) == GLIMS_STATUS_OK,
           "pressure-size settings select the actual installed dynamics in local native paint options");
    char digests[2][65] = {{0}};
    Snapshot golden[2] = {{0}};
    pressure_case (engine, &brushes[0], TRUE, FALSE, digests[0], &golden[0]);
    pressure_case (engine, &brushes[1], FALSE, TRUE, digests[1], &golden[1]);
    if (valid_digest (digests[0]))
      mutation_cases (engine, &brushes[0], &probe, digests[0], &golden[0]);
    else
      printf ("OBS curve and unsupported-flag replay cases NOT RUN without supported pressure-size facts\n");
  }
  if (probe.dynamics)
    CHECK (glims_engine_call (engine, release_pressure, &probe) == GLIMS_STATUS_OK,
           "native pressure-size references release after exact stock restoration");
  api->stop (engine);
  for (gsize i = 0; i < G_N_ELEMENTS (brushes); i++) {
    g_free (brushes[i].name);
    g_free (brushes[i].collection);
  }
  g_free (user); g_free (cache);
  printf ("%s: %u pressure-size facts checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

/* Native Sponge Recorder capture: independent ordinary V1 reference, real
 * alpha-bearing pixels, guarded opposite-direction refusal, replay and Undo. */
#define main glims_original_facts_fixture_main
#include "recorder-stroke-capture-facts-tests.c"
#undef main

static void
sponge_case (GlimsEngine *engine, const BrushIdentity *identity, guint32 tool)
{
  Scene normal = {0}, captured = {0}, replay = {0};
  Snapshot initial, expected, actual;
  GlimsStrokeID stroke = 0; char *error = NULL;
  FactsWithTail facts = fact_box (sizeof facts, FALSE), again = fact_box (sizeof again, FALSE);
  GlimsBrushSettings brush = pencil, opposite = pencil;
  brush.tool = tool;
  opposite.tool = tool == GLIMS_PAINT_SPONGE_DESATURATE
                ? GLIMS_PAINT_SPONGE_SATURATE : GLIMS_PAINT_SPONGE_DESATURATE;
  NEED (glims_engine_call (engine, seed_image, &normal) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &captured) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &replay) == GLIMS_STATUS_OK &&
        read_image (engine, &normal, &initial) && read_image (engine, &captured, &actual) &&
        same_image (&initial, &actual) && read_image (engine, &replay, &actual) && same_image (&initial, &actual),
        "independent RGBA scenes have identical pixels and history");
  NEED (api->stroke_begin (engine, normal.image, normal.layer, &brush, trace, &stroke, &error) == GLIMS_STATUS_OK &&
        !error && stroke && finish_trace (engine, &stroke) && read_image (engine, &normal, &expected) &&
        changed_once (&initial, &expected), "ordinary Sponge paints the RGBA reference with one Undo");
  NEED (api->stroke_begin_with_capture_facts (engine, captured.image, captured.layer, identity->id,
        &brush, trace, NULL, &stroke, &facts.facts, &error) == GLIMS_STATUS_OK && !error && stroke &&
        finish_trace (engine, &stroke), "live Sponge capture completes");
  NEED (matches_identity (&facts.facts, identity) && tail_intact (&facts, sizeof facts),
        "capture returns owned brush identity and fingerprint without writing past its prefix");
  CHECK (read_image (engine, &captured, &actual) && same_image (&expected, &actual),
         "live capture matches independent ordinary raw/merged pixels and history");
  CHECK (refused_before_paint (engine, &replay, &initial, identity->id, &opposite,
                               facts.facts.fingerprint, GLIMS_STATUS_FAILED),
         "opposite Sponge direction refuses before pixels or history change");
  NEED (api->stroke_begin_with_capture_facts (engine, replay.image, replay.layer, identity->id,
        &brush, trace, facts.facts.fingerprint, &stroke, &again.facts, &error) == GLIMS_STATUS_OK &&
        !error && stroke && finish_trace (engine, &stroke), "guarded Sponge replay completes");
  CHECK (matches_identity (&again.facts, identity) && tail_intact (&again, sizeof again) &&
         !strcmp (facts.facts.fingerprint, again.facts.fingerprint) &&
         read_image (engine, &replay, &actual) && same_image (&expected, &actual),
         "replay matches identity, fingerprint, raw/merged pixels and history");
  CHECK (api->image_undo (engine, replay.image) == GLIMS_STATUS_OK && read_image (engine, &replay, &actual) &&
         same_pixels (&initial, &actual) && actual.undo.undo_count == initial.undo.undo_count && actual.undo.redo_count == 1,
         "one Undo restores original pixels");
  CHECK (api->image_redo (engine, replay.image) == GLIMS_STATUS_OK && read_image (engine, &replay, &actual) &&
         same_image (&expected, &actual), "Redo restores exact Sponge pixels and history");
cleanup:
  if (error) fprintf (stderr, "%s\n", error);
  if (stroke) api->stroke_end (engine, stroke);
  free_error (error); free_facts (&facts.facts); free_facts (&again.facts);
  Scene scenes[] = {normal, captured, replay};
  for (gsize i = 0; i < G_N_ELEMENTS (scenes); i++)
    if (scenes[i].image) CHECK (api->image_close (engine, scenes[i].image) == GLIMS_STATUS_OK, "RGBA fixture image closes");
}

int main (int argc, char **argv)
{
  if (argc != 2) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || !has_slot ()) return 2;
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL; BrushIdentity brushes[2] = {0};
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "native startup failed");
    free_error (error); g_free (user); g_free (cache); return 2;
  }
  gboolean discovered = glims_engine_call (engine, discover_brushes, brushes) == GLIMS_STATUS_OK;
  CHECK (discovered, "actual brush identities are available");
  if (discovered) {
    sponge_case (engine, &brushes[0], GLIMS_PAINT_SPONGE_DESATURATE);
    sponge_case (engine, &brushes[0], GLIMS_PAINT_SPONGE_SATURATE);
  }
  api->stop (engine);
  for (gsize i = 0; i < G_N_ELEMENTS (brushes); i++) { g_free (brushes[i].name); g_free (brushes[i].collection); }
  g_free (user); g_free (cache);
  printf ("%s: %u Sponge capture checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

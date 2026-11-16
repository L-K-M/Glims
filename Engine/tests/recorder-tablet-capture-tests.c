/* V2 capture/replay compares public calls with an independent V2 reference. */
#include <math.h>
#define main glims_original_facts_fixture_main
#include "recorder-stroke-capture-facts-tests.c"
#undef main

G_STATIC_ASSERT (offsetof (GlimsEngineAPI, stroke_begin_v2_with_capture_facts) ==
                 offsetof (GlimsEngineAPI, image_convert_layered_lab_copy) +
                 sizeof (((GlimsEngineAPI *) 0)->image_convert_layered_lab_copy));

static gboolean
has_tablet_capture (void)
{
  return api->struct_size >= offsetof (GlimsEngineAPI, stroke_begin_v2_with_capture_facts) +
                             sizeof api->stroke_begin_v2_with_capture_facts &&
         api->stroke_begin_v2_with_capture_facts != NULL;
}

static GlimsStrokePacketV2
packet (const GlimsStrokeSampleV2 *samples, size_t count)
{
  return (GlimsStrokePacketV2) { .struct_size = sizeof (GlimsStrokePacketV2),
    .sample_stride = sizeof (GlimsStrokeSampleV2), .samples = samples,
    .count = count, .byte_count = count * sizeof (GlimsStrokeSampleV2) };
}

static const GlimsStrokeSampleV2 points[] = {
  { .struct_size = sizeof (GlimsStrokeSampleV2), .flags = 3, .x = 9.5, .y = 10.5,
    .pressure = .38, .xtilt = -.2, .ytilt = .3, .time_ms = 0xfffffffeu,
    .rotation_turns = .25, .tangential_pressure = -.75 },
  { .struct_size = sizeof (GlimsStrokeSampleV2), .flags = 3, .x = 20.5, .y = 15.5,
    .pressure = .91, .xtilt = .4, .ytilt = -.6, .time_ms = 0xffffffffu,
    .rotation_turns = .75, .tangential_pressure = .8 },
  { .struct_size = sizeof (GlimsStrokeSampleV2), .flags = 3, .x = 32.5, .y = 22.5,
    .pressure = .56, .xtilt = -.5, .ytilt = .2, .time_ms = 0,
    .rotation_turns = .1, .tangential_pressure = -.2 },
  { .struct_size = sizeof (GlimsStrokeSampleV2), .flags = 0, .x = 43.5, .y = 28.5,
    .pressure = .72, .xtilt = .1, .ytilt = -.1, .time_ms = 5 }
};

static gboolean
finish_tablet (GlimsEngine *engine, GlimsStrokeID *stroke)
{
  GlimsStrokePacketV2 rest = packet (points + 1, G_N_ELEMENTS (points) - 1);
  if (api->stroke_continue_v2 (engine, *stroke, &rest, NULL) != GLIMS_STATUS_OK) return FALSE;
  if (api->stroke_end (engine, *stroke) != GLIMS_STATUS_OK) return FALSE;
  *stroke = 0;
  return TRUE;
}

static void
capture_case (GlimsEngine *engine, const BrushIdentity *identity, guint32 tool)
{
  GlimsBrushSettings brush = pencil; brush.tool = tool;
  Scene reference = {0}, captured = {0}, replay = {0};
  Snapshot before, expected, actual;
  GlimsStrokeID stroke = 0; char *error = NULL;
  FactsWithTail facts = fact_box (sizeof facts, FALSE), again = fact_box (sizeof again, FALSE);
  GlimsStrokePacketV2 first = packet (points, 1);
  NEED (glims_engine_call (engine, seed_image, &reference) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &captured) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &replay) == GLIMS_STATUS_OK &&
        read_image (engine, &reference, &before) && read_image (engine, &captured, &actual) &&
        same_image (&before, &actual) && read_image (engine, &replay, &actual) && same_image (&before, &actual),
        "independent V2 images start with identical raw and merged pixels and history");
  NEED (api->stroke_begin_v2 (engine, reference.image, reference.layer, 0, &brush, &first, &stroke, &error) == GLIMS_STATUS_OK &&
        !error && stroke && finish_tablet (engine, &stroke) && read_image (engine, &reference, &expected) &&
        changed_once (&before, &expected), "ordinary V2 reference paints with one Undo across time wrap");
  NEED (api->stroke_begin_v2_with_capture_facts (engine, captured.image, captured.layer, identity->id,
        &brush, &first, NULL, &stroke, &facts.facts, &error) == GLIMS_STATUS_OK && !error && stroke &&
        finish_tablet (engine, &stroke), "V2 live capture completes with optional axes");
  NEED (matches_identity (&facts.facts, identity) && tail_intact (&facts, sizeof facts),
        "V2 capture returns owned brush identity and fingerprint without changing its future tail");
  CHECK (read_image (engine, &captured, &actual) && same_image (&expected, &actual),
         "V2 capture equals the independent ordinary V2 pixels and history");
  {
    char wrong[65]; memset (wrong, 'a', 64); wrong[64] = '\0';
    if (!strcmp (wrong, facts.facts.fingerprint)) wrong[0] = 'b';
    FactsWithTail denied = fact_box (sizeof denied, TRUE);
    GlimsStrokeID rejected = -7; char *rejected_error = sentinel;
    GlimsStatus status = api->stroke_begin_v2_with_capture_facts (engine, replay.image, replay.layer, identity->id,
        &brush, &first, wrong, &rejected, &denied.facts, &rejected_error);
    CHECK (status == GLIMS_STATUS_FAILED && rejected == 0 && rejected_error != sentinel &&
           facts_empty (&denied.facts) && tail_intact (&denied, sizeof denied) &&
           read_image (engine, &replay, &actual) && same_image (&before, &actual),
           "mismatched V2 fingerprint refuses before pixels and history change");
    if (rejected > 0) api->stroke_end (engine, rejected);
    free_error (rejected_error); free_facts (&denied.facts);
  }
  NEED (api->stroke_begin_v2_with_capture_facts (engine, replay.image, replay.layer, identity->id,
        &brush, &first, facts.facts.fingerprint, &stroke, &again.facts, &error) == GLIMS_STATUS_OK && !error && stroke,
        "guarded V2 replay begins with the captured brush");
  CHECK (api->stroke_continue (engine, stroke, trace + 1, 1) == GLIMS_STATUS_INVALID_ARGUMENT,
         "V1 continuation is rejected on a V2 captured stroke");
  NEED (finish_tablet (engine, &stroke) && read_image (engine, &replay, &actual), "guarded V2 replay completes");
  CHECK (matches_identity (&again.facts, identity) && tail_intact (&again, sizeof again) &&
         !strcmp (facts.facts.fingerprint, again.facts.fingerprint) && same_image (&expected, &actual),
         "V2 replay matches fingerprint, raw/merged pixels and history");
  CHECK (api->image_undo (engine, replay.image) == GLIMS_STATUS_OK && read_image (engine, &replay, &actual) &&
         same_pixels (&before, &actual), "V2 replay Undo restores the original pixels");
  CHECK (api->image_redo (engine, replay.image) == GLIMS_STATUS_OK && read_image (engine, &replay, &actual) &&
         same_image (&expected, &actual), "V2 replay Redo restores the exact result");
cleanup:
  if (error) fprintf (stderr, "%s\n", error);
  if (stroke) api->stroke_end (engine, stroke);
  free_error (error); free_facts (&facts.facts); free_facts (&again.facts);
  Scene scenes[] = {reference, captured, replay};
  for (gsize i = 0; i < G_N_ELEMENTS (scenes); i++)
    if (scenes[i].image) CHECK (api->image_close (engine, scenes[i].image) == GLIMS_STATUS_OK, "V2 capture fixture image closes");
}

static gboolean
refuses_tablet (GlimsEngine *engine, Scene *scene, const Snapshot *before,
                GlimsResourceID brush, const GlimsStrokePacketV2 *input,
                const char *expected)
{
  FactsWithTail box = fact_box (sizeof box, TRUE);
  GlimsStrokeID stroke = -7; char *error = sentinel;
  GlimsStatus status = api->stroke_begin_v2_with_capture_facts (engine, scene->image, scene->layer,
      brush, &pencil, input, expected, &stroke, &box.facts, &error);
  Snapshot after;
  gboolean valid = status == GLIMS_STATUS_INVALID_ARGUMENT && stroke == 0 && error != sentinel &&
      facts_empty (&box.facts) && tail_intact (&box, sizeof box) &&
      read_image (engine, scene, &after) && same_image (before, &after);
  if (stroke > 0) api->stroke_end (engine, stroke);
  free_error (error); free_facts (&box.facts);
  return valid;
}

static void
invalid_cases (GlimsEngine *engine, const BrushIdentity *identity)
{
  Scene scene = {0}; Snapshot before;
  NEED (glims_engine_call (engine, seed_image, &scene) == GLIMS_STATUS_OK &&
        read_image (engine, &scene, &before), "validation image starts unchanged");
  GlimsStrokeSampleV2 sample = points[0];
  GlimsStrokePacketV2 input = packet (&sample, 1);
  sample.flags |= 4;
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, NULL), "unknown sample flag refuses without mutation");
  sample = points[0]; sample.reserved = 1;
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, NULL), "reserved sample data refuses without mutation");
  sample = points[0]; sample.rotation_turns = NAN;
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, NULL), "nonfinite rotation refuses without mutation");
  sample = points[0]; sample.tangential_pressure = 1.1;
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, NULL), "out-of-range tangential pressure refuses without mutation");
  sample = points[0]; sample.flags = 0;
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, NULL), "unflagged optional axes refuse without mutation");
  sample = points[0]; sample.struct_size--;
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, NULL), "short sample prefix refuses without mutation");
  sample = points[0]; input.byte_count--;
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, NULL), "wrong packet length refuses without mutation");
  input = packet (&sample, 1); input.count = 0; input.byte_count = 0;
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, NULL), "empty begin packet refuses without mutation");
  input = packet (&sample, 1); input.struct_size--;
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, NULL), "short packet prefix refuses without mutation");
  input = packet (&sample, 1);
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, "abc"), "short expected fingerprint refuses without mutation");
  char invalid[65]; memset (invalid, 'a', 64); invalid[64] = '\0'; invalid[10] = 'A';
  CHECK (refuses_tablet (engine, &scene, &before, identity->id, &input, invalid), "non-lowercase fingerprint refuses without mutation");
  memset (invalid, 'a', 64);
  CHECK (refuses_tablet (engine, &scene, &before, 0, &input, invalid), "guarded inherited brush refuses without mutation");
  {
    guint8 bytes[1 + sizeof (GlimsStrokeSampleV2) + 8]; memset (bytes, 0xa5, sizeof bytes);
    sample = points[0]; sample.struct_size = sizeof sample + 8; memcpy (bytes + 1, &sample, sizeof sample);
    input = packet (NULL, 1); input.samples = bytes + 1; input.sample_stride = sizeof sample + 8; input.byte_count = input.sample_stride;
    FactsWithTail box = fact_box (sizeof box, FALSE); GlimsStrokeID stroke = 0; char *error = NULL;
    GlimsStatus status = api->stroke_begin_v2_with_capture_facts (engine, scene.image, scene.layer, identity->id,
        &pencil, &input, NULL, &stroke, &box.facts, &error);
    CHECK (status == GLIMS_STATUS_OK && !error && stroke && matches_identity (&box.facts, identity) &&
           tail_intact (&box, sizeof box), "unaligned extended sample is accepted with its unknown tail ignored");
    if (stroke) api->stroke_end (engine, stroke);
    free_error (error); free_facts (&box.facts);
  }
cleanup:
  if (scene.image) CHECK (api->image_close (engine, scene.image) == GLIMS_STATUS_OK, "validation image closes");
}

static void
v2_output_cases (GlimsEngine *engine, gboolean stopped)
{
  uint32_t size = stopped ? sizeof (FactsWithTail)
      : offsetof (GlimsStrokeCaptureFacts, fingerprint) + sizeof (char *) - 1;
  FactsWithTail box = fact_box (size, TRUE); GlimsStrokeID stroke = -7; char *error = sentinel;
  GlimsStrokePacketV2 first = packet (points, 1);
  GlimsStatus status = api->stroke_begin_v2_with_capture_facts (engine, 1, 1, 0, &pencil,
      &first, NULL, &stroke, &box.facts, &error);
  CHECK (status == (stopped ? GLIMS_STATUS_NOT_RUNNING : GLIMS_STATUS_INVALID_ARGUMENT) &&
         stroke == 0 && !error && !box.facts.brush_internal && !box.facts.brush_name &&
         !box.facts.brush_collection && box.facts.fingerprint == (stopped ? NULL : sentinel) &&
         tail_intact (&box, size), stopped ? "stopped V2 call clears outputs and preserves future tail"
                                          : "short V2 facts prefix clears only complete fields");
  if (stroke > 0 && engine) api->stroke_end (engine, stroke);
  free_error (error); free_facts (&box.facts);
}

int main (int argc, char **argv)
{
  if (argc != 2) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api) return 2;
  CHECK (has_tablet_capture (), "V2 capture slot is present with a complete table prefix");
  if (!has_tablet_capture ()) return 1;
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
    const guint32 tools[] = { GLIMS_PAINT_PENCIL, GLIMS_PAINT_ERASER, GLIMS_PAINT_PAINTBRUSH,
                              GLIMS_PAINT_SPONGE_DESATURATE, GLIMS_PAINT_SPONGE_SATURATE };
    for (gsize i = 0; i < G_N_ELEMENTS (tools); i++) capture_case (engine, &brushes[0], tools[i]);
    invalid_cases (engine, &brushes[0]);
  }
  v2_output_cases (engine, FALSE);
  api->stop (engine);
  v2_output_cases (NULL, TRUE);
  for (gsize i = 0; i < G_N_ELEMENTS (brushes); i++) { g_free (brushes[i].name); g_free (brushes[i].collection); }
  g_free (user); g_free (cache);
  printf ("%s: %u tablet capture checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

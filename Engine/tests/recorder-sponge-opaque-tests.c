/* Real opaque Background layer, guarded Sponge capture/replay and Undo. */
#define main glims_original_facts_fixture_main
#include "recorder-stroke-capture-facts-tests.c"
#undef main

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

static void
opaque_case (GlimsEngine *engine, const BrushIdentity *identity, guint32 tool)
{
  Scene normal = {0}, captured = {0}, replay = {0}, alpha = {0};
  Snapshot initial, expected, actual, alpha_before;
  GlimsStrokeID stroke = 0; char *error = NULL;
  FactsWithTail facts = fact_box (sizeof facts, FALSE), again = fact_box (sizeof again, FALSE);
  FactsWithTail alpha_facts = fact_box (sizeof alpha_facts, FALSE);
  GlimsBrushSettings brush = pencil;
  brush.tool = tool;
  NEED (glims_engine_call (engine, seed_opaque, &normal) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_opaque, &captured) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_opaque, &replay) == GLIMS_STATUS_OK &&
        glims_engine_call (engine, seed_image, &alpha) == GLIMS_STATUS_OK &&
        read_opaque (engine, &normal, &initial) && read_opaque (engine, &captured, &actual) &&
        same_image (&initial, &actual) && read_opaque (engine, &replay, &actual) &&
        same_image (&initial, &actual) && read_image (engine, &alpha, &alpha_before),
        "independent opaque and alpha scenes are seeded");
  NEED (api->stroke_begin (engine, normal.image, normal.layer, &brush, trace, &stroke, &error) == GLIMS_STATUS_OK &&
        !error && stroke && finish_trace (engine, &stroke) && read_opaque (engine, &normal, &expected) &&
        changed_once (&initial, &expected), "ordinary opaque Sponge paints with one Undo");
  NEED (api->stroke_begin_with_capture_facts (engine, captured.image, captured.layer, identity->id,
        &brush, trace, NULL, &stroke, &facts.facts, &error) == GLIMS_STATUS_OK && !error && stroke &&
        finish_trace (engine, &stroke), "opaque Sponge capture paints");
  NEED (matches_identity (&facts.facts, identity) && tail_intact (&facts, sizeof facts),
        "opaque Sponge capture returns owned replay facts");
  CHECK (read_opaque (engine, &captured, &actual) && same_image (&expected, &actual),
         "opaque capture matches independent ordinary pixels and history");
  NEED (api->stroke_begin_with_capture_facts (engine, replay.image, replay.layer, identity->id,
        &brush, trace, facts.facts.fingerprint, &stroke, &again.facts, &error) == GLIMS_STATUS_OK &&
        !error && stroke && finish_trace (engine, &stroke), "guarded opaque replay completes");
  CHECK (matches_identity (&again.facts, identity) && !strcmp (facts.facts.fingerprint, again.facts.fingerprint) &&
         read_opaque (engine, &replay, &actual) && same_image (&expected, &actual),
         "opaque replay matches fingerprint, pixels and history");
  CHECK (refused_before_paint (engine, &alpha, &alpha_before, identity->id, &brush,
                               facts.facts.fingerprint, GLIMS_STATUS_FAILED),
         "opaque fingerprint refuses an alpha-bearing target before painting");
  NEED (api->stroke_begin_with_capture_facts (engine, alpha.image, alpha.layer, identity->id,
        &brush, trace, NULL, &stroke, &alpha_facts.facts, &error) == GLIMS_STATUS_OK &&
        !error && stroke && finish_trace (engine, &stroke) &&
        matches_identity (&alpha_facts.facts, identity), "alpha-bearing Sponge produces capture facts");
  CHECK (strcmp (facts.facts.fingerprint, alpha_facts.facts.fingerprint),
         "opaque and alpha-bearing Sponge fingerprints differ");
  {
    FactsWithTail denied = fact_box (sizeof denied, TRUE);
    GlimsStrokeID denied_stroke = -7; char *denied_error = sentinel;
    Snapshot before_denial, after_denial;
    gboolean before_ready = read_opaque (engine, &replay, &before_denial);
    GlimsStatus denied_status = api->stroke_begin_with_capture_facts (engine, replay.image, replay.layer,
        identity->id, &brush, trace, alpha_facts.facts.fingerprint, &denied_stroke, &denied.facts, &denied_error);
    CHECK (before_ready && denied_status == GLIMS_STATUS_FAILED && denied_stroke == 0 &&
           denied_error != sentinel && facts_empty (&denied.facts) && tail_intact (&denied, sizeof denied) &&
           read_opaque (engine, &replay, &after_denial) && same_image (&before_denial, &after_denial),
           "alpha-bearing fingerprint refuses an opaque target before painting");
    if (denied_stroke > 0) api->stroke_end (engine, denied_stroke);
    free_error (denied_error); free_facts (&denied.facts);
  }
  CHECK (api->image_undo (engine, replay.image) == GLIMS_STATUS_OK && read_opaque (engine, &replay, &actual) &&
         same_pixels (&initial, &actual) && actual.undo.undo_count == initial.undo.undo_count && actual.undo.redo_count == 1,
         "one Undo restores opaque pixels");
  CHECK (api->image_redo (engine, replay.image) == GLIMS_STATUS_OK && read_opaque (engine, &replay, &actual) &&
         same_image (&expected, &actual), "Redo restores opaque result");
cleanup:
  if (error) fprintf (stderr, "%s\n", error);
  if (stroke) api->stroke_end (engine, stroke);
  free_error (error); free_facts (&facts.facts); free_facts (&again.facts); free_facts (&alpha_facts.facts);
  Scene scenes[] = {normal, captured, replay, alpha};
  for (gsize i = 0; i < G_N_ELEMENTS (scenes); i++)
    if (scenes[i].image) CHECK (api->image_close (engine, scenes[i].image) == GLIMS_STATUS_OK, "opaque fixture image closes");
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
    opaque_case (engine, &brushes[0], GLIMS_PAINT_SPONGE_DESATURATE);
    opaque_case (engine, &brushes[0], GLIMS_PAINT_SPONGE_SATURATE);
  }
  api->stop (engine);
  for (gsize i = 0; i < G_N_ELEMENTS (brushes); i++) { g_free (brushes[i].name); g_free (brushes[i].collection); }
  g_free (user); g_free (cache);
  printf ("%s: %u opaque Sponge capture checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

/* Binder admission tests. Reuse the unchanged independent foreign fixture,
 * then exercise owned metadata drafts at the internal decoder/binder seam.
 * Draft mutations here are test inputs, not production DTO mutation. */
#define main foreign_fixture_main
#include "foreign-xcf-effect-fields-tests.c"
#undef main
#include "foreign-effect-state.h"
#include "core/gimpcontainer.h"
#include "file/file-open.h"
#include "operations/layer-modes/gimp-layer-modes.h"

static gboolean
automatic_fields (GimpDrawableFilter *filter)
{
  return gimp_drawable_filter_get_blend_space (filter) == GIMP_LAYER_COLOR_SPACE_AUTO &&
    gimp_drawable_filter_get_composite_space (filter) == GIMP_LAYER_COLOR_SPACE_AUTO &&
    gimp_drawable_filter_get_composite_mode (filter) == GIMP_LAYER_COMPOSITE_AUTO;
}

static GlimsStatus
admission (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  gchar *path = g_build_filename (work_dir, "foreign-explicit-effect.xcf", NULL);
  GFile *file = g_file_new_for_path (path);
  GError *gerror = NULL;
  GlimsXcfEffectFields *fields = glims_xcf_effect_fields_read (file, NULL, &gerror);
  GimpImage *image = NULL;
  GimpLayer *layer = NULL;
  GimpDrawableFilter *extra = NULL;
  GeglNode *extra_node = NULL;
  char *error = NULL;
  NEED (fields != NULL && !gerror, "binder fixture metadata reads without modifying the independent file");
  GlimsXcfEffectFieldsRecord *draft = (GlimsXcfEffectFieldsRecord *) glims_xcf_effect_fields_effect (fields, 0, 0);
  NEED (draft != NULL, "binder fixture has its sole owned effect metadata record");
  GlimsXcfEffectFieldsRecord original = *draft;
  GimpPDBStatusType status;
  gboolean vector = FALSE;
  const gchar *mime = NULL;
  image = file_open_image (engine->gimp, gimp_get_user_context (engine->gimp), NULL,
    file, 0, 0, FALSE, FALSE, NULL, GIMP_RUN_NONINTERACTIVE, &vector, &status, &mime, &gerror);
  NEED (image != NULL && !gerror && status == GIMP_PDB_SUCCESS,
        "binder fixture loads directly through native XCF before facade adoption");
  layer = GIMP_LAYER (gimp_container_get_child_by_index (gimp_image_get_layers (image), 0));
  GimpContainer *filters = gimp_drawable_get_filters (GIMP_DRAWABLE (layer));
  GimpDrawableFilter *filter = GIMP_DRAWABLE_FILTER (gimp_container_get_child_by_index (filters, 0));
  NEED (filter && automatic_fields (filter), "native baseline begins with all three reset AUTO fields");
  gfloat before[COMPONENTS], after[COMPONENTS];
  Fixture view = { .engine = engine, .image = image, .layer = layer };
  NEED (read_pixels (&view, FALSE, before), "binder snapshots exact raw source bytes");

  draft->blend_space = G_MININT32;
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_UNSUPPORTED &&
    error && automatic_fields (filter), "INT32_MIN refuses without negation or partial field mutation");
  clear_error (&error); *draft = original;
  draft->composite_mode = 777;
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_UNSUPPORTED &&
    error && automatic_fields (filter), "an invalid final field leaves earlier valid desired fields unapplied");
  clear_error (&error); *draft = original;
  draft->presence |= 1u << 31;
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_UNSUPPORTED &&
    error && automatic_fields (filter), "unknown metadata presence refuses before any setter");
  clear_error (&error); *draft = original;
  draft->opacity = NAN;
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_UNSUPPORTED &&
    error && automatic_fields (filter), "nonfinite unchanged opacity refuses atomically");
  clear_error (&error); *draft = original;
  draft->operation = "gegl:invert-linear";
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_UNSUPPORTED &&
    error && automatic_fields (filter), "an unmatched operation never receives another effect's saved fields");
  clear_error (&error); *draft = original;

  draft->blend_space = draft->composite_space = draft->composite_mode = 154222502;
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_OK && !error &&
    automatic_fields (filter), "the native writer's identical unregistered words retain its AUTO baseline");
  clear_error (&error); *draft = original;
  draft->blend_space = draft->composite_space = draft->composite_mode = 2;
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_OK && !error &&
    gimp_drawable_filter_get_blend_space (filter) == 2 &&
    gimp_drawable_filter_get_composite_space (filter) == 2 &&
    gimp_drawable_filter_get_composite_mode (filter) == 2,
    "identical registered words remain explicit and never enter the writer compatibility case");
  clear_error (&error); *draft = original;
  gimp_drawable_filter_set_mode (filter, GIMP_LAYER_MODE_MULTIPLY,
    GIMP_LAYER_COLOR_SPACE_AUTO, GIMP_LAYER_COLOR_SPACE_AUTO, GIMP_LAYER_COMPOSITE_AUTO);
  draft->blend_space = -gimp_layer_mode_get_blend_space (GIMP_LAYER_MODE_MULTIPLY);
  draft->composite_space = -gimp_layer_mode_get_composite_space (GIMP_LAYER_MODE_MULTIPLY);
  draft->composite_mode = -gimp_layer_mode_get_composite_mode (GIMP_LAYER_MODE_MULTIPLY);
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_OK && !error &&
    automatic_fields (filter), "negative saved effective defaults resolve back to native AUTO");
  clear_error (&error); *draft = original;
  draft->presence &= ~(GLIMS_XCF_FIELD_BLEND_SPACE | GLIMS_XCF_FIELD_COMPOSITE_SPACE | GLIMS_XCF_FIELD_COMPOSITE_MODE);
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_OK && !error &&
    automatic_fields (filter), "absent saved fields retain loaded native settings");
  clear_error (&error); *draft = original;

  extra_node = gegl_node_new ();
  gegl_node_set (extra_node, "operation", "gegl:exposure", NULL);
  extra = gimp_drawable_filter_new (GIMP_DRAWABLE (layer), "Unmatched last effect", extra_node, ICON);
  NEED (extra != NULL, "atomicity fixture creates a second real native filter");
  gimp_drawable_filter_set_temporary (extra, FALSE);
  gimp_drawable_add_filter (GIMP_DRAWABLE (layer), GIMP_FILTER (extra));
  gimp_container_reorder (filters, GIMP_OBJECT (extra), 1);
  NEED (gimp_container_get_n_children (filters) == 2 &&
    gimp_container_get_child_by_index (filters, 0) == GIMP_OBJECT (filter),
    "the first valid target precedes an unmatched final native filter");
  CHECK (glims_foreign_effect_fields_restore (image, fields, &error) == GLIMS_STATUS_UNSUPPORTED &&
    error && automatic_fields (filter), "whole-stack refusal leaves an already validated earlier target unchanged");
  clear_error (&error);
  gimp_drawable_remove_filter (GIMP_DRAWABLE (layer), GIMP_FILTER (extra));
  CHECK (read_pixels (&view, FALSE, after) && !memcmp (before, after, sizeof before) &&
    !gimp_image_parasite_find (image, "glims-effect-state-v1"),
    "all admission tests preserve exact source pixels and add no state carrier");
  CHECK (g_hash_table_size (engine->images) == 0,
    "the admission fixture never publishes a native image through the facade");
cleanup:
  if (extra && image && gimp_drawable_has_filter (GIMP_DRAWABLE (layer), GIMP_FILTER (extra)))
    gimp_drawable_remove_filter (GIMP_DRAWABLE (layer), GIMP_FILTER (extra));
  g_clear_object (&extra); g_clear_object (&extra_node);
  g_clear_object (&image);
  clear_error (&error); g_clear_error (&gerror);
  /* The temporary draft's borrowed substitutions were restored before free. */
  glims_xcf_effect_fields_free (fields);
  g_object_unref (file); g_free (path);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  int baseline = foreign_fixture_main (argc, argv);
  if (baseline) return baseline;
  gchar *user = g_build_filename (work_dir, "user-admission", NULL);
  gchar *cache = g_build_filename (work_dir, "cache-admission", NULL);
  GlimsEngine *engine = NULL;
  char *error = NULL;
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "admission engine startup failed");
    clear_error (&error); g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, admission, NULL) == GLIMS_STATUS_OK,
    "binder admission tests run on the real engine worker");
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

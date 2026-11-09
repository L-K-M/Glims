/*
 * resource-rename-formats-tests.c — deterministic Core-linked regression
 * harness for successful VBR/GGR rename round trips through fresh native
 * loaders, plus whitespace-refusal oracles.
 */
#include "engine-private.h"

#include "resource-rename.h"
#include "resource-mutation.h"
#include "resource-mutation-inspect.h"

#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
/* Tests deliberately use the requested C11 mode, not inherited C89 style. */
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

#include <babl/babl.h>
#include <gegl-buffer.h>

#include "core/core-enums.h"
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpbrush-load.h"
#include "core/gimpbrushpipe.h"
#include "core/gimpbrushpipe-load.h"
#include "core/gimpbrushgenerated.h"
#include "core/gimpbrushgenerated-load.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpgradient.h"
#include "core/gimpgradient-load.h"
#include "core/gimpobject.h"
#include "core/gimptempbuf.h"

int main (int argc, char **argv);

typedef struct
{
  GlimsEngine            *engine;
  const GlimsEngineAPI   *api;
  Gimp                   *gimp;
  GimpContext            *context;
  const char             *work;
  int                     failures;
} Probe;

static const GlimsEngineAPI *api;

static void
check (Probe *probe, gboolean condition, const char *fmt, ...)
{
  va_list args;

  printf (condition ? "ok    " : "FAIL  ");
  va_start (args, fmt);
  vprintf (fmt, args);
  va_end (args);
  printf ("\n");
  fflush (stdout);
  if (! condition)
    probe->failures++;
}

static void
fixture_fail (Probe *probe, const char *fmt, ...)
{
  va_list args;

  printf ("FIXTURE-FAIL  ");
  va_start (args, fmt);
  vprintf (fmt, args);
  va_end (args);
  printf ("\n");
  fflush (stdout);
  probe->failures++;
}

#define CHECK(...) check (probe, __VA_ARGS__)
#define NEED(condition, ...)                                          \
  do                                                                  \
    {                                                                 \
      gboolean needed__ = (condition);                                \
      CHECK (needed__, __VA_ARGS__);                                  \
      if (! needed__)                                                 \
        goto done;                                                    \
    }                                                                 \
  while (0)

static float
float_eq (float a, float b)
{
  return fabsf (a - b) < 0.0001f;
}

static double
double_eq (double a, double b)
{
  return fabs (a - b) < 0.000001;
}

static gboolean
same_bytes (GFile *file, const gchar *original, gsize count)
{
  gchar *now = NULL;
  gsize length = 0;
  gboolean same;

  same = g_file_load_contents (file, NULL, &now, &length, NULL, NULL) &&
         length == count &&
         (count == 0 || memcmp (now, original, count) == 0);
  g_free (now);
  return same;
}

static void
free_loaded_list (GList *list)
{
  GList *l;

  for (l = list; l; l = l->next)
    if (l->data)
      g_object_unref (l->data);
  g_list_free (list);
}

static void
test_brush_rename (Probe *probe)
{
  GimpDataFactory *factory = probe->gimp->brush_factory;
  const char *source_name = "glims-renamefmt-src-brush";
  const char *renamed_name = "Renamed \xce\xa9 Brush";
  GimpData *created = NULL;
  GlimsResourceStaging staging;
  GlimsResourceID source_id = 0;
  char *error = NULL;
  GlimsResourceMutationFacts *facts = NULL;
  gchar *guard = NULL;
  GFile *file = NULL;
  gchar *baseline = NULL;
  gsize baseline_len = 0;
  GimpData *source_data = NULL;
  GList *loaded = NULL;
  GError *gerr = NULL;
  GlimsStatus st;
  int i;

  memset (&staging, 0, sizeof staging);

  created = gimp_brush_generated_new (source_name,
                                      GIMP_BRUSH_GENERATED_DIAMOND,
                                      17.5f, 7, 0.625f, 1.75f, 30.0f);
  NEED (created != NULL, "generated brush fixture constructs");
  gimp_brush_set_spacing (GIMP_BRUSH (created), 19);

  st = glims_resource_staging_begin (factory, ".vbr", &staging, &error);
  NEED (st == GLIMS_STATUS_OK, "brush staging begins");
  st = glims_resource_save_and_publish (factory, created, source_name,
                                        &staging, &source_id, &error);
  created = NULL;
  NEED (st == GLIMS_STATUS_OK && source_id != 0,
        "generated brush publishes");

  st = glims_lookup_resource_data (probe->engine, source_id, &source_data);
  NEED (st == GLIMS_STATUS_OK && source_data != NULL,
        "published brush resolves");

  st = glims_resource_mutation_inspect (probe->engine, source_id, &facts, &error);
  NEED (st == GLIMS_STATUS_OK && facts != NULL &&
        (facts->capabilities & GLIMS_RESOURCE_MUTATION_RENAME),
        "published brush is rename-capable");
  guard = glims_resource_mutation_guard (facts);
  NEED (guard != NULL && strlen (guard) == 64,
        "brush mutation guard is a 64-hex string");

  file = g_object_ref (facts->file);
  NEED (g_file_load_contents (file, NULL, &baseline, &baseline_len, NULL, NULL),
        "brush baseline file bytes read");

  gimp_context_set_brush (probe->context, GIMP_BRUSH (source_data));

  {
    static const char *bad[] = {
      " Renamed \xce\xa9 Brush",
      "Renamed \xce\xa9 Brush ",
      "\tRenamed \xce\xa9 Brush",
      "Renamed \xce\xa9 Brush\n"
    };

    for (i = 0; i < (int) G_N_ELEMENTS (bad); i++)
      {
        char *e2 = NULL;
        GlimsStatus s;

        s = glims_resource_rename_checked (probe->engine, source_id, guard,
                                          bad[i], &e2);
        CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT,
               "brush leading/trailing whitespace rename is invalid");
        if (e2)
          api->free_string (e2);
        CHECK (same_bytes (file, baseline, baseline_len),
               "brush whitespace rename leaves saved file bytes unchanged");
      }
  }

  {
    char *e2 = NULL;

    st = glims_resource_rename_checked (probe->engine, source_id, guard,
                                        renamed_name, &e2);
    CHECK (st == GLIMS_STATUS_OK, "brush rename succeeds");
    if (e2)
      api->free_string (e2);
  }

  {
    GimpData *after = NULL;

    if (glims_lookup_resource_data (probe->engine, source_id, &after) ==
        GLIMS_STATUS_OK)
      CHECK (after == source_data, "brush source native object id remains stable");
    CHECK (gimp_context_get_brush (probe->context) == GIMP_BRUSH (source_data),
           "brush context remains stable");
    CHECK (strcmp (gimp_object_get_name (GIMP_OBJECT (source_data)),
                   renamed_name) == 0,
           "brush live name is renamed");
  }

  if (file)
    {
      GInputStream *input = G_INPUT_STREAM (g_file_read (file, NULL, &gerr));

      if (! input)
        {
          CHECK (FALSE, "brush renamed file opens");
        }
      else
        {
          loaded = gimp_brush_generated_load (probe->context, file, input,
                                              &gerr);
          g_object_unref (input);
          CHECK (loaded != NULL && loaded->data != NULL && loaded->next == NULL &&
                 gerr == NULL,
                 "fresh brush loader returns one object");
          if (loaded && loaded->data)
            {
              GimpBrushGenerated *lb = GIMP_BRUSH_GENERATED (loaded->data);

              CHECK (strcmp (gimp_object_get_name (GIMP_OBJECT (loaded->data)),
                             renamed_name) == 0,
                     "fresh brush name is exact Unicode");
              CHECK (gimp_brush_generated_get_shape (lb) ==
                     GIMP_BRUSH_GENERATED_DIAMOND,
                     "fresh brush shape preserved");
              CHECK (float_eq (gimp_brush_generated_get_radius (lb), 17.5f),
                     "fresh brush radius preserved");
              CHECK (gimp_brush_generated_get_spikes (lb) == 7,
                     "fresh brush spikes preserved");
              CHECK (float_eq (gimp_brush_generated_get_hardness (lb), 0.625f),
                     "fresh brush hardness preserved");
              CHECK (float_eq (gimp_brush_generated_get_aspect_ratio (lb),
                               1.75f),
                     "fresh brush aspect ratio preserved");
              CHECK (float_eq (gimp_brush_generated_get_angle (lb), 30.0f),
                     "fresh brush angle preserved");
              CHECK (gimp_brush_get_spacing (GIMP_BRUSH (lb)) == 19,
                     "fresh brush spacing preserved");
            }
        }
    }

  if (gerr)
    {
      g_error_free (gerr);
      gerr = NULL;
    }

done:
  if (loaded)
    free_loaded_list (loaded);
  if (guard)
    g_free (guard);
  if (baseline)
    g_free (baseline);
  if (file)
    g_object_unref (file);
  glims_resource_mutation_facts_free (facts);
  if (created)
    g_object_unref (created);
  if (error)
    api->free_string (error);
}

static void
test_gradient_rename (Probe *probe)
{
  GimpDataFactory *factory = probe->gimp->gradient_factory;
  const char *source_name = "glims-renamefmt-src-gradient";
  const char *renamed_name = "Renamed \xce\xa9 Gradient";
  GimpData *created = NULL;
  GlimsResourceStaging staging;
  GlimsResourceID source_id = 0;
  char *error = NULL;
  GlimsResourceMutationFacts *facts = NULL;
  gchar *guard = NULL;
  GFile *file = NULL;
  gchar *baseline = NULL;
  gsize baseline_len = 0;
  GimpData *source_data = NULL;
  GList *loaded = NULL;
  GError *gerr = NULL;
  GlimsStatus st;
  int i;

  memset (&staging, 0, sizeof staging);

  created = gimp_gradient_new (probe->context, source_name);
  NEED (created != NULL, "gradient fixture constructs");
  NEED (GIMP_IS_GRADIENT (created), "gradient fixture is GIMP_IS_GRADIENT");

  {
    GimpGradient *gradient = GIMP_GRADIENT (created);
    GimpGradientSegment *seg = gradient->segments;
    GeglColor *left_color;
    GeglColor *right_color;

    NEED (seg != NULL, "gradient fixture has a native segment");

    gimp_gradient_segment_set_left_pos (gradient, seg, 0.0);
    gimp_gradient_segment_set_middle_pos (gradient, seg, 0.375);
    gimp_gradient_segment_set_right_pos (gradient, seg, 1.0);

    left_color = gegl_color_new ("#336699");
    right_color = gegl_color_new ("#cc3366");
    NEED (left_color != NULL && right_color != NULL,
          "gradient fixture colors construct");
    gimp_gradient_segment_set_left_color (gradient, seg, left_color);
    gimp_gradient_segment_set_right_color (gradient, seg, right_color);
    g_object_unref (left_color);
    g_object_unref (right_color);

    gimp_gradient_segment_set_left_color_type (gradient, seg,
                                              GIMP_GRADIENT_COLOR_FOREGROUND);
    gimp_gradient_segment_set_right_color_type (gradient, seg,
                                               GIMP_GRADIENT_COLOR_BACKGROUND);
    gimp_gradient_segment_range_set_blending_function (gradient, seg, seg,
                                                      GIMP_GRADIENT_SEGMENT_CURVED);
    gimp_gradient_segment_range_set_coloring_type (gradient, seg, seg,
                                                  GIMP_GRADIENT_SEGMENT_HSV_CW);
  }

  st = glims_resource_staging_begin (factory, ".ggr", &staging, &error);
  NEED (st == GLIMS_STATUS_OK, "gradient staging begins");
  st = glims_resource_save_and_publish (factory, created, source_name,
                                        &staging, &source_id, &error);
  created = NULL;
  NEED (st == GLIMS_STATUS_OK && source_id != 0,
        "gradient publishes");

  st = glims_lookup_resource_data (probe->engine, source_id, &source_data);
  NEED (st == GLIMS_STATUS_OK && source_data != NULL,
        "published gradient resolves");

  st = glims_resource_mutation_inspect (probe->engine, source_id, &facts, &error);
  NEED (st == GLIMS_STATUS_OK && facts != NULL &&
        (facts->capabilities & GLIMS_RESOURCE_MUTATION_RENAME),
        "published gradient is rename-capable");
  guard = glims_resource_mutation_guard (facts);
  NEED (guard != NULL && strlen (guard) == 64,
        "gradient mutation guard is a 64-hex string");

  file = g_object_ref (facts->file);
  NEED (g_file_load_contents (file, NULL, &baseline, &baseline_len, NULL, NULL),
        "gradient baseline file bytes read");

  gimp_context_set_gradient (probe->context, GIMP_GRADIENT (source_data));

  {
    static const char *bad[] = {
      " Renamed \xce\xa9 Gradient",
      "Renamed \xce\xa9 Gradient ",
      "\tRenamed \xce\xa9 Gradient",
      "Renamed \xce\xa9 Gradient\r"
    };

    for (i = 0; i < (int) G_N_ELEMENTS (bad); i++)
      {
        char *e2 = NULL;
        GlimsStatus s;

        s = glims_resource_rename_checked (probe->engine, source_id, guard,
                                          bad[i], &e2);
        CHECK (s == GLIMS_STATUS_INVALID_ARGUMENT,
               "gradient leading/trailing whitespace rename is invalid");
        if (e2)
          api->free_string (e2);
        CHECK (same_bytes (file, baseline, baseline_len),
               "gradient whitespace rename leaves saved file bytes unchanged");
      }
  }

  {
    char *e2 = NULL;

    st = glims_resource_rename_checked (probe->engine, source_id, guard,
                                        renamed_name, &e2);
    CHECK (st == GLIMS_STATUS_OK, "gradient rename succeeds");
    if (e2)
      api->free_string (e2);
  }

  {
    GimpData *after = NULL;

    if (glims_lookup_resource_data (probe->engine, source_id, &after) ==
        GLIMS_STATUS_OK)
      CHECK (after == source_data,
             "gradient source native object id remains stable");
    CHECK (gimp_context_get_gradient (probe->context) ==
           GIMP_GRADIENT (source_data),
           "gradient context remains stable");
    CHECK (strcmp (gimp_object_get_name (GIMP_OBJECT (source_data)),
                   renamed_name) == 0,
           "gradient live name is renamed");
  }

  if (file)
    {
      GInputStream *input = G_INPUT_STREAM (g_file_read (file, NULL, &gerr));

      if (! input)
        {
          CHECK (FALSE, "gradient renamed file opens");
        }
      else
        {
          loaded = gimp_gradient_load (probe->context, file, input, &gerr);
          g_object_unref (input);
          CHECK (loaded != NULL && loaded->data != NULL && loaded->next == NULL &&
                 gerr == NULL,
                 "fresh gradient loader returns one object");
          if (loaded && loaded->data)
            {
              GimpGradient *lg = GIMP_GRADIENT (loaded->data);
              GimpGradientSegment *lseg = lg->segments;
              const Babl *rgba = babl_format ("R'G'B'A double");
              double left_rgba[4] = { 0, 0, 0, 0 };
              double right_rgba[4] = { 0, 0, 0, 0 };
              GeglColor *lc;
              GeglColor *rc;

              CHECK (strcmp (gimp_object_get_name (GIMP_OBJECT (loaded->data)),
                             renamed_name) == 0,
                     "fresh gradient name is exact Unicode");
              CHECK (lseg != NULL, "fresh gradient has a segment");
              if (lseg)
                {
                  CHECK (double_eq (gimp_gradient_segment_get_left_pos (lg, lseg),
                                    0.0),
                         "fresh gradient left position preserved");
                  CHECK (double_eq (gimp_gradient_segment_get_middle_pos (lg, lseg),
                                    0.375),
                         "fresh gradient middle position preserved");
                  CHECK (double_eq (gimp_gradient_segment_get_right_pos (lg, lseg),
                                    1.0),
                         "fresh gradient right position preserved");
                  CHECK (gimp_gradient_segment_get_blending_function (lg, lseg) ==
                         GIMP_GRADIENT_SEGMENT_CURVED,
                         "fresh gradient blending type preserved");
                  CHECK (gimp_gradient_segment_get_coloring_type (lg, lseg) ==
                         GIMP_GRADIENT_SEGMENT_HSV_CW,
                         "fresh gradient coloring type preserved");
                  CHECK (gimp_gradient_segment_get_left_color_type (lg, lseg) ==
                         GIMP_GRADIENT_COLOR_FOREGROUND,
                         "fresh gradient left dynamic stop type preserved");
                  CHECK (gimp_gradient_segment_get_right_color_type (lg, lseg) ==
                         GIMP_GRADIENT_COLOR_BACKGROUND,
                         "fresh gradient right dynamic stop type preserved");

                  lc = gimp_gradient_segment_get_left_color (lg, lseg);
                  rc = gimp_gradient_segment_get_right_color (lg, lseg);
                  if (lc)
                    gegl_color_get_pixel (lc, rgba, left_rgba);
                  if (rc)
                    gegl_color_get_pixel (rc, rgba, right_rgba);
                  CHECK (double_eq (left_rgba[0], 0.2) &&
                         double_eq (left_rgba[1], 0.4) &&
                         double_eq (left_rgba[2], 0.6) &&
                         double_eq (left_rgba[3], 1.0),
                         "fresh gradient left color preserved");
                  CHECK (double_eq (right_rgba[0], 0.8) &&
                         double_eq (right_rgba[1], 0.2) &&
                         double_eq (right_rgba[2], 0.4) &&
                         double_eq (right_rgba[3], 1.0),
                         "fresh gradient right color preserved");
                }
            }
        }
    }

  if (gerr)
    {
      g_error_free (gerr);
      gerr = NULL;
    }

done:
  if (loaded)
    free_loaded_list (loaded);
  if (guard)
    g_free (guard);
  if (baseline)
    g_free (baseline);
  if (file)
    g_object_unref (file);
  glims_resource_mutation_facts_free (facts);
  if (created)
    g_object_unref (created);
  if (error)
    api->free_string (error);
}

static void append_word (GByteArray *bytes, guint32 value)
{
  guint32 be = GUINT32_TO_BE (value); g_byte_array_append (bytes, (guint8 *) &be, sizeof be);
}
static void append_cell (GByteArray *bytes, const char *name, const guint8 mask[4])
{
  append_word (bytes, 28 + strlen (name) + 1); append_word (bytes, 2);
  append_word (bytes, 2); append_word (bytes, 2); append_word (bytes, 1);
  append_word (bytes, 0x47494d50); append_word (bytes, 37);
  g_byte_array_append (bytes, (const guint8 *) name, strlen (name) + 1);
  g_byte_array_append (bytes, mask, 4);
}
static void test_bitmap_pipe (Probe *probe, gboolean pipe_case)
{
  const guint8 rgba[16] = {255,0,0,255, 0,0,255,128, 0,255,0,64, 255,255,255,0};
  const guint8 masks[2][4] = {{1,2,3,4}, {252,253,254,255}};
  const char *child_names[] = {"First child", "Second child"};
  const char *name = pipe_case ? "Original pipe" : "Original bitmap";
  const char *renamed = pipe_case ? "Pipe Ω renamed" : "Bitmap Ω renamed";
  GlimsResourceID id = 0;
  GlimsResourceMutationFacts *facts = NULL;
  GlimsResourceStaging staging = {0};
  gchar *guard = NULL; char *error = NULL; GError *io_error = NULL;
  GList *created = NULL, *loaded = NULL; GInputStream *input = NULL;
  GFile *file = NULL; GByteArray *encoded = NULL;
  if (pipe_case) {
    const char header[] = "Original pipe\n2 ncells:2 cellwidth:2 cellheight:2 step:100 dim:1 cols:1 rows:1 placement:constant rank0:2 sel0:incremental\n";
    encoded = g_byte_array_new ();
    g_byte_array_append (encoded, (const guint8 *) header, sizeof header - 1);
    append_cell (encoded, child_names[0], masks[0]); append_cell (encoded, child_names[1], masks[1]);
    input = g_memory_input_stream_new_from_data (encoded->data, encoded->len, NULL);
    file = g_file_new_for_path ("/private/unused-rename-fixture.gih");
    created = gimp_brush_pipe_load (probe->context, file, input, &io_error);
    NEED (created && created->data && !created->next && !io_error, "a known two-cell native pipe parses from independent bytes");
    g_clear_object (&input); g_clear_object (&file);
    NEED (glims_resource_staging_begin (probe->gimp->brush_factory, ".gih", &staging, &error) == GLIMS_STATUS_OK,
          "the pipe fixture has owned writable staging");
    GimpData *data = created->data; g_list_free (created); created = NULL;
    NEED (glims_resource_save_and_publish (probe->gimp->brush_factory, data, name, &staging, &id, &error) == GLIMS_STATUS_OK,
          "the exact known pipe fixture is saved and published");
  } else {
    NEED (api->resource_create_pixels (probe->engine, GLIMS_RESOURCE_BRUSH, name, 2, 2, rgba, sizeof rgba, 43, &id, &error) == GLIMS_STATUS_OK,
          "the independent known RGBA bitmap brush is saved");
  }
  NEED (glims_resource_mutation_inspect (probe->engine, id, &facts, &error) == GLIMS_STATUS_OK && facts,
        "the saved bitmap/pipe has current mutation facts");
  guard = glims_resource_mutation_guard (facts); file = g_object_ref (facts->file);
  NEED (guard && glims_resource_rename_checked (probe->engine, id, guard, renamed, &error) == GLIMS_STATUS_OK,
        "the saved bitmap/pipe renames successfully");
  CHECK (strcmp (gimp_object_get_name (facts->data), renamed) == 0 && gimp_data_get_id (facts->data) == (gint) id,
         "bitmap/pipe Rename preserves the native object id and exact Unicode identity");
  input = G_INPUT_STREAM (g_file_read (file, NULL, &io_error));
  NEED (input && !io_error, "the actual renamed bitmap/pipe file opens for a fresh native loader");
  loaded = pipe_case ? gimp_brush_pipe_load (probe->context, file, input, &io_error)
                     : gimp_brush_load (probe->context, file, input, &io_error);
  NEED (loaded && loaded->data && !loaded->next && !io_error, "fresh native parsing returns exactly one renamed bitmap/pipe");
  CHECK (strcmp (gimp_object_get_name (loaded->data), renamed) == 0,
         "fresh bitmap/pipe parsing preserves the exact Unicode name");
  if (pipe_case) {
    NEED (GIMP_IS_BRUSH_PIPE (loaded->data), "the renamed resource remains a genuine brush pipe");
    GimpBrushPipe *pipe = GIMP_BRUSH_PIPE (loaded->data);
    NEED (pipe->n_brushes == 2 && pipe->dimension == 1 && pipe->rank[0] == 2 && pipe->current,
          "the renamed pipe retains both cells and its independent known rank/dimension");
    for (int cell = 0; cell < 2; cell++) {
      GimpBrush *brush = pipe->brushes[cell]; GimpTempBuf *mask = brush ? gimp_brush_get_mask (brush) : NULL;
      CHECK (brush && strcmp (gimp_object_get_name (brush), child_names[cell]) == 0 && gimp_brush_get_spacing (brush) == 37,
             "pipe cells retain their distinct independently named children and spacing");
      CHECK (mask && gimp_temp_buf_get_width (mask) == 2 && gimp_temp_buf_get_height (mask) == 2 &&
             babl_format_get_bytes_per_pixel (gimp_temp_buf_get_format (mask)) == 1 && memcmp (gimp_temp_buf_get_data (mask), masks[cell], 4) == 0,
             "all freshly loaded cell-mask bytes retain the independently known original values");
    }
  } else {
    GimpBrush *brush = GIMP_BRUSH (loaded->data);
    GimpTempBuf *mask = gimp_brush_get_mask (brush), *pixmap = gimp_brush_get_pixmap (brush);
    NEED (mask && pixmap && gimp_temp_buf_get_width (mask) == 2 && gimp_temp_buf_get_height (mask) == 2 &&
          babl_format_get_bytes_per_pixel (gimp_temp_buf_get_format (mask)) == 1 && babl_format_get_bytes_per_pixel (gimp_temp_buf_get_format (pixmap)) == 3,
          "fresh bitmap parsing retains its exact two-by-two alpha/RGB storage");
    gboolean exact = TRUE;
    const guint8 *alpha = gimp_temp_buf_get_data (mask), *rgb = gimp_temp_buf_get_data (pixmap);
    for (int p = 0; p < 4; p++)
      if (alpha[p] != rgba[p*4+3] || memcmp (rgb + p*3, rgba + p*4, 3)) exact = FALSE;
    CHECK (exact && gimp_brush_get_spacing (brush) == 43,
           "every fresh bitmap RGB/alpha value and its spacing match independent source constants");
  }
done:
  if (error) { fprintf (stderr, "bitmap/pipe fixture: %s\n", error); api->free_string (error); }
  if (io_error) { fprintf (stderr, "bitmap/pipe IO: %s\n", io_error->message); g_error_free (io_error); }
  g_list_free_full (created, g_object_unref); g_list_free_full (loaded, g_object_unref);
  g_clear_object (&input); g_clear_object (&file); if (encoded) g_byte_array_unref (encoded);
  glims_resource_mutation_facts_free (facts); g_free (guard);
}

static GlimsStatus
run_all (GlimsEngine *engine, gpointer user_data)
{
  Probe *probe = user_data;

  probe->engine = engine;
  probe->api = api;
  probe->gimp = engine->gimp;
  probe->context = gimp_context_new (probe->gimp,
                                    "Glims resource rename formats", NULL);
  if (! probe->context)
    {
      fixture_fail (probe, "private GimpContext constructs");
      return GLIMS_STATUS_FAILED;
    }

  test_brush_rename (probe);
  test_gradient_rename (probe);
  test_bitmap_pipe (probe, FALSE);
  test_bitmap_pipe (probe, TRUE);

  g_object_unref (probe->context);
  probe->context = NULL;
  return probe->failures > 0 ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngineConfig config;
  GlimsEngine *engine = NULL;
  Probe probe;
  char *error = NULL;
  char work[1024], home_dir[1024], user_dir[1024], cache_dir[1024];
  GlimsStatus status;

  if (argc != 2)
    {
      fprintf (stderr, "usage: %s WORK_DIR\n", argv[0]);
      return 2;
    }

  snprintf (work, sizeof work, "%s", argv[1]);
  snprintf (home_dir, sizeof home_dir, "%s/home", work);
  snprintf (user_dir, sizeof user_dir, "%s/user", work);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", work);
  if ((mkdir (work, 0755) < 0 && errno != EEXIST) ||
      (mkdir (home_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (user_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (cache_dir, 0755) < 0 && errno != EEXIST))
    {
      fprintf (stderr, "cannot create work dirs under %s: %s\n", work, strerror (errno));
      return 1;
    }

  memset (&probe, 0, sizeof probe);
  probe.work = work;
  memset (&config, 0, sizeof config);
  config.struct_size = sizeof config;
  config.user_directory = user_dir;
  config.cache_directory = cache_dir;
  config.on_event = NULL;

  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (api == NULL || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI))
    {
      fprintf (stderr, "glims_engine_get_api(%u) did not serve the facade\n",
               (unsigned) GLIMS_ENGINE_API_VERSION);
      return 1;
    }

  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "engine start failed: %s\n", error ? error : "unknown error");
      if (error)
        api->free_string (error);
      return 1;
    }
  if (error)
    {
      api->free_string (error);
      error = NULL;
    }

  printf ("resource-rename-formats-tests: engine %s, work %s\n",
          api->engine_version (engine), work);

  status = glims_engine_call (engine, run_all, &probe);

  api->stop (engine);
  printf ("%s: %d failure%s\n",
          probe.failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          probe.failures, probe.failures == 1 ? "" : "s");
  return status == GLIMS_STATUS_OK && probe.failures == 0 ? 0 : 1;
}
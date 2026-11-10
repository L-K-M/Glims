/* Test-only foreign XCF oracle, pinned to GIMP 3.2.8. The native writer's
 * effect varargs do not reliably encode these three fields. Patch only their
 * validated four-byte payloads in one tiny, independently configured fixture.
 * This is not a production XCF reader and does not use the Glims supplement. */
#include "engine-private.h"
#include "core/gimp.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpfilter.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimplist.h"
#include "core/gimppickable.h"
#include "file/file-open.h"
#include "file/file-save.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
#include "plug-in/gimppluginprocedure.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

#if GIMP_MAJOR_VERSION != 3 || GIMP_MINOR_VERSION != 2 || GIMP_MICRO_VERSION != 8
#error This foreign XCF oracle has only been specified for pinned GIMP 3.2.8
#endif

int main (int argc, char **argv);

#define WIDTH 4
#define HEIGHT 2
#define COMPONENTS (WIDTH * HEIGHT * 4)
#define MAX_FILE_BYTES (4u * 1024u * 1024u)
#define SENTINEL "Foreign effect sentinel 7f21c89a"
#define LAYER_NAME "Foreign alpha source"
#define OPERATION "gegl:exposure"
#define ICON "gimp-gegl"

/* Literal XCF values, specified independently of the production supplement.
 * These enum assertions deliberately keep this oracle pinned to this engine. */
G_STATIC_ASSERT (GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR == 2);
G_STATIC_ASSERT (GIMP_LAYER_COMPOSITE_CLIP_TO_LAYER == 3);
static const guint32 explicit_values[3] = { 2, 2, 3 };
static const guint32 field_properties[3] = { 37, 36, 35 };
static const gfloat source_pixels[COMPONENTS] = {
  .12f, .25f, .70f, .250f, .80f, .21f, .06f, .500f,
  .05f, .60f, .30f, .750f, .90f, .70f, .20f, 1.000f,
  .33f, .13f, .81f, .125f, .22f, .72f, .11f, .625f,
  .56f, .44f, .18f, .875f, .40f, .02f, .90f, .375f
};
static const GlimsEngineAPI *api;
static const char *work_dir;
static int checks, failures;

#define CHECK(condition, title) do { \
  gboolean passed_ = (condition); \
  checks++; \
  printf ("%s %s\n", passed_ ? "ok  " : "FAIL", title); \
  if (!passed_) failures++; \
  fflush (stdout); \
} while (0)
#define NEED(condition, title) do { \
  gboolean needed_ = (condition); CHECK (needed_, title); \
  if (!needed_) goto cleanup; \
} while (0)

typedef struct {
  GlimsEngine *engine;
  GlimsImageID id;
  GimpImage *image;
  GimpLayer *layer;
} Fixture;

typedef struct {
  const guint8 *bytes;
  gsize size, offset;
} Cursor;

typedef struct {
  guint32 version;
  gsize layer, effect, operation_version, properties_start, properties_end;
  gsize fields[3];
  guint32 values[3];
} EffectRecord;

static void
clear_error (char **error)
{
  if (*error) api->free_string (*error);
  *error = NULL;
}

static gboolean
u32 (Cursor *cursor, guint32 *value)
{
  guint32 encoded;
  if (cursor->offset > cursor->size || cursor->size - cursor->offset < 4) return FALSE;
  memcpy (&encoded, cursor->bytes + cursor->offset, 4);
  *value = GUINT32_FROM_BE (encoded);
  cursor->offset += 4;
  return TRUE;
}

static gboolean
offset64 (Cursor *cursor, gsize *value)
{
  guint64 encoded;
  if (cursor->offset > cursor->size || cursor->size - cursor->offset < 8) return FALSE;
  memcpy (&encoded, cursor->bytes + cursor->offset, 8);
  encoded = GUINT64_FROM_BE (encoded);
  if (encoded > cursor->size) return FALSE;
  *value = (gsize) encoded;
  cursor->offset += 8;
  return TRUE;
}

static gboolean
xcf_string (Cursor *cursor, const gchar **text, guint32 *length)
{
  guint32 count;
  if (!u32 (cursor, &count) || count > 512 || count > cursor->size - cursor->offset) return FALSE;
  *length = count;
  *text = count ? (const gchar *) cursor->bytes + cursor->offset : NULL;
  if (count && ((*text)[count - 1] != '\0' || memchr (*text, '\0', count - 1))) return FALSE;
  cursor->offset += count;
  return TRUE;
}

static gboolean
string_is (Cursor *cursor, const gchar *expected)
{
  const gchar *text;
  guint32 length;
  if (!xcf_string (cursor, &text, &length)) return FALSE;
  if (!expected) return length == 0;
  return length == strlen (expected) + 1 && !memcmp (text, expected, length);
}

static gboolean
skip_properties (Cursor *cursor)
{
  for (guint i = 0; i < 256; i++) {
    guint32 property, size;
    if (!u32 (cursor, &property) || !u32 (cursor, &size)) return FALSE;
    if (property == 0) return size == 0;
    if (size > cursor->size - cursor->offset) return FALSE;
    cursor->offset += size;
  }
  return FALSE;
}

static guint
occurrences (const guint8 *bytes, gsize size, const void *needle, gsize length)
{
  guint count = 0;
  if (length > size) return 0;
  for (gsize i = 0; i <= size - length; i++)
    if (!memcmp (bytes + i, needle, length)) count++;
  return count;
}

static gboolean
no_glims_namespace (const guint8 *bytes, gsize size)
{
  /* Binary-safe, including text after NUL bytes and any capitalization. */
  for (gsize i = 0; i + 5 <= size; i++)
    if (g_ascii_tolower (bytes[i]) == 'g' && g_ascii_tolower (bytes[i + 1]) == 'l' &&
        g_ascii_tolower (bytes[i + 2]) == 'i' && g_ascii_tolower (bytes[i + 3]) == 'm' &&
        g_ascii_tolower (bytes[i + 4]) == 's') return FALSE;
  return TRUE;
}

static gfloat
float_bits (guint32 bits)
{
  gfloat value;
  memcpy (&value, &bits, sizeof value);
  return value;
}

/* Accept only the exact ordinary layer/effect shape this fixture writes.
 * The layer table points at the effect; the unique sentinel is a second check,
 * never an unstructured search-and-replace address. No tile data is parsed. */
static gboolean
locate_record (const guint8 *bytes, gsize size, EffectRecord *record)
{
  Cursor cursor = { bytes, size, 14 };
  guint32 width, height, type, precision;
  gsize layer, zero, hierarchy, mask, effect;
  if (size < 30 || size > MAX_FILE_BYTES || memcmp (bytes, "gimp xcf v", 10) || bytes[13] != 0 ||
      !g_ascii_isdigit (bytes[10]) || !g_ascii_isdigit (bytes[11]) || !g_ascii_isdigit (bytes[12])) return FALSE;
  record->version = (bytes[10] - '0') * 100 + (bytes[11] - '0') * 10 + bytes[12] - '0';
  if (record->version < 22 || record->version > 23 ||
      !u32 (&cursor, &width) || width != WIDTH || !u32 (&cursor, &height) || height != HEIGHT ||
      !u32 (&cursor, &type) || type != GIMP_RGB ||
      !u32 (&cursor, &precision) || precision != GIMP_PRECISION_FLOAT_LINEAR ||
      !skip_properties (&cursor)) return FALSE;
  if (!offset64 (&cursor, &layer) || !layer ||
      !offset64 (&cursor, &zero) || zero || /* exactly one layer */
      !offset64 (&cursor, &zero) || zero || /* no channels */
      !offset64 (&cursor, &zero) || zero || /* no paths */
      layer < cursor.offset) return FALSE;
  cursor.offset = layer;
  if (!u32 (&cursor, &width) || width != WIDTH || !u32 (&cursor, &height) || height != HEIGHT ||
      !u32 (&cursor, &type) || type != GIMP_RGBA_IMAGE || !string_is (&cursor, LAYER_NAME) ||
      !skip_properties (&cursor) || !offset64 (&cursor, &hierarchy) || !hierarchy ||
      !offset64 (&cursor, &mask) || mask ||
      !offset64 (&cursor, &effect) || !effect ||
      !offset64 (&cursor, &zero) || zero || /* exactly one effect */
      hierarchy < cursor.offset || effect <= hierarchy) return FALSE;
  if (occurrences (bytes, size, SENTINEL, sizeof SENTINEL) != 1) return FALSE;
  cursor.offset = effect;
  if (!string_is (&cursor, SENTINEL) || !string_is (&cursor, ICON) ||
      !string_is (&cursor, OPERATION)) return FALSE;
  record->operation_version = cursor.offset;
  if (!string_is (&cursor, gegl_operation_get_op_version (OPERATION))) return FALSE;
  record->properties_start = cursor.offset;
  static const guint32 prefix[] = { 8, 33, 7, 37, 36, 35, 46, 44 };
  for (guint i = 0; i < G_N_ELEMENTS (prefix); i++) {
    guint32 property, length, value;
    if (!u32 (&cursor, &property) || property != prefix[i] ||
        !u32 (&cursor, &length) || length != 4) return FALSE;
    gsize payload = cursor.offset;
    if (!u32 (&cursor, &value)) return FALSE;
    if ((i == 0 && value != TRUE) || (i == 1 && float_bits (value) != .625f) ||
        (i == 2 && value != GIMP_LAYER_MODE_MULTIPLY) || (i == 6 && value != TRUE) ||
        (i == 7 && value != GIMP_FILTER_REGION_DRAWABLE)) return FALSE;
    if (i >= 3 && i <= 5) {
      record->fields[i - 3] = payload;
      record->values[i - 3] = value;
    }
  }
  guint arguments = 0;
  for (guint i = 0; i < 3; i++) {
    guint32 property, length, value_type, bits, name_length;
    const gchar *name;
    if (!u32 (&cursor, &property) || !u32 (&cursor, &length)) return FALSE;
    if (property == 0) {
      if (length || arguments != 3) return FALSE;
      record->properties_end = cursor.offset;
      if (!offset64 (&cursor, &mask) || mask != cursor.offset || mask >= size) return FALSE;
      record->layer = layer;
      record->effect = effect;
      return TRUE;
    }
    if (property != 45 || length > size - cursor.offset) return FALSE;
    Cursor argument = { bytes, cursor.offset + length, cursor.offset };
    if (!xcf_string (&argument, &name, &name_length) || !name_length ||
        !u32 (&argument, &value_type) || value_type != 3 || !u32 (&argument, &bits) ||
        argument.offset != argument.size) return FALSE;
    if (!strcmp (name, "black-level") && !(arguments & 1) && float_bits (bits) == .03125f) arguments |= 1;
    else if (!strcmp (name, "exposure") && !(arguments & 2) && float_bits (bits) == 1.25f) arguments |= 2;
    else return FALSE;
    cursor.offset += length;
  }
  return FALSE;
}

static gboolean
read_file (const gchar *path, gchar **bytes, gsize *size)
{
  GError *error = NULL;
  gboolean ok = g_file_get_contents (path, bytes, size, &error) && *size <= MAX_FILE_BYTES;
  if (!ok) fprintf (stderr, "OBS file read: %s\n", error ? error->message : "size limit");
  g_clear_error (&error);
  return ok;
}

static gboolean
create_source (GlimsEngine *engine, Fixture *fixture)
{
  fixture->engine = engine;
  fixture->image = gimp_create_image (engine->gimp, WIDTH, HEIGHT, GIMP_RGB, GIMP_PRECISION_FLOAT_LINEAR, FALSE);
  if (!fixture->image) return FALSE;
  if (glims_adopt_image (engine, fixture->image, &fixture->id) != GLIMS_STATUS_OK) {
    g_clear_object (&fixture->image);
    return FALSE;
  }
  fixture->layer = gimp_layer_new (fixture->image, WIDTH, HEIGHT,
      gimp_image_get_layer_format (fixture->image, TRUE), LAYER_NAME, 1, GIMP_LAYER_MODE_NORMAL);
  if (!fixture->layer) return FALSE;
  if (!gimp_image_add_layer (fixture->image, fixture->layer, NULL, 0, FALSE)) {
    g_clear_object (&fixture->layer);
    return FALSE;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (fixture->layer)),
      GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT), 0, babl_format ("RGBA float"), source_pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (fixture->layer), 0, 0, WIDTH, HEIGHT);
  return TRUE;
}

static gboolean
read_pixels (Fixture *fixture, gboolean effects, gfloat out[COMPONENTS])
{
  if (effects) gimp_pickable_flush (GIMP_PICKABLE (fixture->layer));
  GeglBuffer *buffer = effects ? gimp_drawable_get_buffer_with_effects (GIMP_DRAWABLE (fixture->layer))
                              : gimp_drawable_get_buffer (GIMP_DRAWABLE (fixture->layer));
  if (!buffer) return FALSE;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT), 1, babl_format ("RGBA float"),
                   out, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  if (effects) g_object_unref (buffer);
  return TRUE;
}

static gdouble
pixel_delta (const gfloat *first, const gfloat *second)
{
  gdouble delta = 0;
  for (guint i = 0; i < COMPONENTS; i++) {
    if (!isfinite (first[i]) || !isfinite (second[i])) return INFINITY;
    delta = MAX (delta, fabs (first[i] - second[i]));
  }
  return delta;
}

static void
set_explicit (GimpDrawableFilter *filter)
{
  gimp_drawable_filter_set_mode (filter, GIMP_LAYER_MODE_MULTIPLY,
      GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR, GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR,
      GIMP_LAYER_COMPOSITE_CLIP_TO_LAYER);
}

static gboolean
explicit_fields (GimpDrawableFilter *filter)
{
  return gimp_drawable_filter_get_blend_space (filter) == GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR &&
      gimp_drawable_filter_get_composite_space (filter) == GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR &&
      gimp_drawable_filter_get_composite_mode (filter) == GIMP_LAYER_COMPOSITE_CLIP_TO_LAYER;
}

static GimpDrawableFilter *
one_effect (Fixture *fixture)
{
  GlimsEffectInfo rows[2] = {{0}};
  gint32 count = 0;
  if (api->drawable_effects (fixture->engine, fixture->id, gimp_item_get_id (GIMP_ITEM (fixture->layer)),
        rows, 2, &count) != GLIMS_STATUS_OK || count != 1) return NULL;
  return glims_lookup_effect (fixture->engine, GIMP_DRAWABLE (fixture->layer), rows[0].id);
}

static gboolean
opened_fixture (GlimsEngine *engine, GlimsImageID id, Fixture *fixture)
{
  GlimsLayerInfo rows[2] = {{0}};
  gint32 count = 0;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open || api->image_layers (engine, id, rows, 2, &count) != GLIMS_STATUS_OK || count != 1) return FALSE;
  fixture->engine = engine;
  fixture->id = id;
  fixture->image = open->image;
  fixture->layer = GIMP_LAYER (glims_lookup_drawable (open, rows[0].id));
  return fixture->layer && G_OBJECT_TYPE (fixture->layer) == GIMP_TYPE_LAYER &&
      gimp_drawable_has_alpha (GIMP_DRAWABLE (fixture->layer)) &&
      gimp_image_get_width (fixture->image) == WIDTH && gimp_image_get_height (fixture->image) == HEIGHT &&
      gimp_image_get_precision (fixture->image) == GIMP_PRECISION_FLOAT_LINEAR;
}

static gboolean
native_save (Fixture *fixture, const gchar *path)
{
  GError *error = NULL;
  GFile *file = g_file_new_for_path (path);
  GimpPlugInProcedure *procedure = gimp_plug_in_manager_file_procedure_find (
      fixture->engine->gimp->plug_in_manager, GIMP_FILE_PROCEDURE_GROUP_SAVE, file, &error);
  GimpPDBStatusType status = GIMP_PDB_EXECUTION_ERROR;
  if (procedure) {
    fixture->engine->busy++;
    status = file_save (fixture->engine->gimp, fixture->image, NULL, file, procedure,
        GIMP_RUN_NONINTERACTIVE, TRUE, FALSE, FALSE, &error);
    fixture->engine->busy--;
  }
  if (error) fprintf (stderr, "OBS direct native save: %s\n", error->message);
  g_clear_error (&error);
  g_object_unref (file);
  return status == GIMP_PDB_SUCCESS;
}

static gboolean
clean_open (Fixture *fixture)
{
  GlimsUndoInfo undo = {0};
  return !gimp_image_is_dirty (fixture->image) &&
      !gimp_image_parasite_find (fixture->image, "glims-effect-state-v1") &&
      api->image_undo_info (fixture->engine, fixture->id, &undo) == GLIMS_STATUS_OK &&
      undo.undo_count == 0 && undo.redo_count == 0;
}

static gboolean
legacy_native_control (GlimsEngine *engine, const gchar *path)
{
  GFile *file = g_file_new_for_path (path);
  GimpPDBStatusType status;
  gboolean vector = FALSE;
  const gchar *mime = NULL;
  GError *error = NULL;
  engine->busy++;
  GimpImage *image = file_open_image (engine->gimp, gimp_get_user_context (engine->gimp), NULL, file,
      0, 0, FALSE, FALSE, NULL, GIMP_RUN_NONINTERACTIVE, &vector, &status, &mime, &error);
  engine->busy--;
  GList *layers = image ? gimp_image_get_layer_list (image) : NULL;
  GimpContainer *filters = layers && !layers->next
      ? gimp_drawable_get_filters (GIMP_DRAWABLE (layers->data)) : NULL;
  GList *effects = GIMP_IS_LIST (filters) ? GIMP_LIST (filters)->queue->head : NULL;
  GimpDrawableFilter *effect = effects && !effects->next && GIMP_IS_DRAWABLE_FILTER (effects->data)
      ? GIMP_DRAWABLE_FILTER (effects->data) : NULL;
  gboolean valid = image && status == GIMP_PDB_SUCCESS && !error && !vector &&
      g_strcmp0 (mime, "image/x-xcf") == 0 && effect &&
      g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (effect)), SENTINEL) == 0 &&
      g_strcmp0 (gegl_node_get_operation (gimp_drawable_filter_get_operation (effect)), OPERATION) == 0;
  if (error) fprintf (stderr, "OBS native legacy XCF open: %s\n", error->message);
  g_list_free (layers);
  g_clear_error (&error);
  g_clear_object (&image);
  g_object_unref (file);
  return valid;
}

static void
legacy_control (GlimsEngine *engine, guint version, const gchar *modern, gsize size,
                const EffectRecord *record, const gfloat expected[COMPONENTS])
{
  Fixture loaded = {0};
  GlimsImageID opened = 0;
  char *error = NULL;
  GError *file_error = NULL;
  gchar *name = g_strdup_printf ("foreign-explicit-effect-v%u.xcf", version);
  gchar *path = g_build_filename (work_dir, name, NULL);
  gchar *legacy = NULL, *reread = NULL;
  gsize reread_size = 0;
  gfloat actual[COMPONENTS];
  printf ("OBS legacy_version=%u\n", version);
  NEED (record->version == 22 && record->operation_version < record->properties_start &&
        record->properties_start < record->properties_end && record->properties_end + 8 < size,
        "legacy fixture derives from the bounded v22 effect record");
  legacy = g_memdup2 (modern, size);
  legacy[12] = '0' + (version - 20);
  // The first three strings and all properties are identical. v20/v21
  // have no fourth string. Move only the TLVs and mask-offset word, and
  // leave a gap before the untouched absolute mask location.
  gsize tail = record->properties_end + 8;
  gsize removed = record->properties_start - record->operation_version;
  memmove (legacy + record->operation_version, legacy + record->properties_start,
           tail - record->properties_start);
  memset (legacy + tail - removed, 0, removed);
  NEED (g_file_set_contents (path, legacy, (gssize) size, &file_error),
        "legacy oracle is written separately without a Glims carrier");
  NEED (legacy_native_control (engine, path), "direct GIMP open accepts the legacy record and effect");
  NEED (api->image_open (engine, path, &opened, &error) == GLIMS_STATUS_OK,
        "public image_open accepts the validated legacy effect without a Glims carrier");
  NEED (opened_fixture (engine, opened, &loaded), "legacy open retains its layer, precision and dimensions");
  GimpDrawableFilter *effect = one_effect (&loaded);
  CHECK (effect && explicit_fields (effect) && gimp_drawable_filter_get_mask (effect),
         "legacy open preserves all three explicit native fields and the effect mask");
  CHECK (clean_open (&loaded), "legacy open starts clean without a carrier or Undo history");
  CHECK (read_pixels (&loaded, FALSE, actual) && !memcmp (actual, source_pixels, sizeof actual),
         "legacy open preserves exact FLOAT_LINEAR source bytes");
  CHECK (read_pixels (&loaded, TRUE, actual) && pixel_delta (actual, expected) < 2e-4,
         "legacy rendered pixels match the independently configured native oracle");
  CHECK (read_file (path, &reread, &reread_size) && reread_size == size && !memcmp (reread, legacy, size),
         "public open does not modify the legacy source file");
cleanup:
  if (file_error) fprintf (stderr, "OBS legacy fixture write: %s\n", file_error->message);
  if (error) fprintf (stderr, "OBS legacy public open: %s\n", error);
  if (opened) api->image_close (engine, opened);
  clear_error (&error);
  g_clear_error (&file_error);
  g_free (reread);
  g_free (legacy);
  g_free (path);
  g_free (name);
}

static void
plain_control (GlimsEngine *engine)
{
  Fixture source = {0}, loaded = {0};
  GlimsImageID opened = 0;
  gchar *path = g_build_filename (work_dir, "foreign-plain-control.xcf", NULL), *bytes = NULL;
  gsize size = 0;
  gfloat values[COMPONENTS];
  char *error = NULL;
  NEED (create_source (engine, &source), "plain control creates an ordinary FLOAT_LINEAR alpha layer");
  NEED (native_save (&source, path), "plain control saves through direct native file_save");
  CHECK (read_file (path, &bytes, &size) && no_glims_namespace ((guint8 *) bytes, size),
         "plain control file has no Glims namespace");
  NEED (api->image_open (engine, path, &opened, &error) == GLIMS_STATUS_OK,
        "plain control opens through the public facade");
  NEED (opened_fixture (engine, opened, &loaded), "plain control retains exactly one ordinary alpha layer");
  GlimsEffectInfo rows[1] = {{0}};
  gint32 count = -1;
  CHECK (api->drawable_effects (engine, opened, gimp_item_get_id (GIMP_ITEM (loaded.layer)),
      rows, 1, &count) == GLIMS_STATUS_OK && count == 0, "plain control acquires no effect");
  CHECK (read_pixels (&loaded, FALSE, values) && !memcmp (values, source_pixels, sizeof values),
         "plain control preserves exact FLOAT_LINEAR source bytes");
  CHECK (clean_open (&loaded), "plain control opens clean with empty native history and no carrier");
cleanup:
  if (opened) api->image_close (engine, opened);
  if (source.id) api->image_close (engine, source.id);
  clear_error (&error);
  g_free (bytes);
  g_free (path);
}

static GlimsStatus
regression (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture source = {0}, loaded = {0};
  GlimsImageID opened = 0;
  GimpDrawableFilter *filter = NULL;
  GeglNode *node = NULL;
  gboolean committed = FALSE;
  char *error = NULL;
  GError *file_error = NULL;
  gchar *native_path = g_build_filename (work_dir, "foreign-native-unpatched.xcf", NULL);
  gchar *foreign_path = g_build_filename (work_dir, "foreign-explicit-effect.xcf", NULL);
  gchar *original = NULL, *patched = NULL, *reread = NULL;
  gsize size = 0, reread_size = 0;
  EffectRecord record = {0}, encoded = {0};
  gfloat expected[COMPONENTS], automatic[COMPONENTS], actual[COMPONENTS];
  NEED (!strcmp (api->engine_version (engine), "3.2.8"), "oracle runs only on pinned GIMP 3.2.8");
  NEED (create_source (engine, &source), "foreign fixture creates an ordinary FLOAT_LINEAR alpha layer");
  NEED (gegl_has_operation (OPERATION), "non-Curves exposure operation is installed");
  node = gegl_node_new ();
  gegl_node_set (node, "operation", OPERATION, "black-level", .03125, "exposure", 1.25, NULL);
  filter = gimp_drawable_filter_new (GIMP_DRAWABLE (source.layer), SENTINEL, node, ICON);
  NEED (filter != NULL, "foreign fixture creates its one independently configured native effect");
  gimp_drawable_filter_set_temporary (filter, FALSE);
  gimp_drawable_filter_set_opacity (filter, .625);
  gimp_drawable_filter_set_clip (filter, TRUE);
  gimp_drawable_filter_set_region (filter, GIMP_FILTER_REGION_DRAWABLE);
  set_explicit (filter);
  gimp_drawable_filter_apply (filter, NULL);
  gimp_drawable_filter_layer_mask_freeze (filter);
  committed = gimp_drawable_filter_commit (filter, TRUE, NULL, FALSE);
  NEED (committed && gimp_drawable_filter_get_mask (filter) && one_effect (&source) == filter,
        "foreign fixture commits exactly one genuine effect with its native mask");
  CHECK (explicit_fields (filter), "source independently owns the three explicit non-AUTO fields");
  NEED (read_pixels (&source, FALSE, actual) && !memcmp (actual, source_pixels, sizeof actual) &&
        read_pixels (&source, TRUE, expected), "source raw bytes and explicit effect-rendered pixels are captured before file I/O");
  gimp_drawable_filter_set_mode (filter, GIMP_LAYER_MODE_MULTIPLY, GIMP_LAYER_COLOR_SPACE_AUTO,
      GIMP_LAYER_COLOR_SPACE_AUTO, GIMP_LAYER_COMPOSITE_AUTO);
  NEED (read_pixels (&source, TRUE, automatic) && isfinite (pixel_delta (expected, automatic)) &&
        pixel_delta (expected, automatic) > .01 &&
        pixel_delta (expected, source_pixels) > .01,
        "explicit fields and effect produce independently visible pixels distinct from AUTO and raw input");
  set_explicit (filter);
  NEED (read_pixels (&source, TRUE, actual) && pixel_delta (actual, expected) < 2e-4,
        "restoring source explicit fields reproduces the captured pixel oracle");
  CHECK (!gimp_image_parasite_find (source.image, "glims-effect-state-v1"),
         "foreign source has no Glims effect supplement before native save");
  NEED (native_save (&source, native_path), "foreign source saves through direct native file_save without Glims preservation");
  CHECK (explicit_fields (filter) && read_pixels (&source, TRUE, actual) && pixel_delta (actual, expected) < 2e-4,
         "native save leaves independently configured source fields and rendered oracle unchanged");
  NEED (read_file (native_path, &original, &size), "bounded direct-native XCF bytes are available");
  NEED (no_glims_namespace ((guint8 *) original, size), "original native XCF contains no Glims namespace");
  NEED (locate_record ((guint8 *) original, size, &record),
        "unique table-referenced effect record validates name icon operation version TLV order config and one-effect shape");
  CHECK (record.fields[0] + 12 == record.fields[1] && record.fields[1] + 12 == record.fields[2] &&
         record.fields[2] + 4 <= record.properties_end,
         "only the ordered four-byte 37 36 35 payload locations are eligible for patching");
  patched = g_memdup2 (original, size);
  for (guint i = 0; i < 3; i++) {
    guint32 value = GUINT32_TO_BE (explicit_values[i]);
    memcpy (patched + record.fields[i], &value, sizeof value);
    printf ("OBS property=%u payload_offset=%zu original=0x%08x explicit=0x%08x\n",
            field_properties[i], record.fields[i], record.values[i], explicit_values[i]);
  }
  gboolean only_payloads = TRUE;
  for (gsize i = 0; i < size; i++) {
    gboolean eligible = FALSE;
    for (guint j = 0; j < 3; j++)
      if (i >= record.fields[j] && i - record.fields[j] < 4) eligible = TRUE;
    if (!eligible && original[i] != patched[i]) only_payloads = FALSE;
  }
  CHECK (only_payloads, "patch preserves every byte outside the three specified four-byte payloads");
  NEED (locate_record ((guint8 *) patched, size, &encoded) &&
        !memcmp (record.fields, encoded.fields, sizeof record.fields) &&
        !memcmp (encoded.values, explicit_values, sizeof explicit_values),
        "patched XCF revalidates identical structure and config with exact specified explicit integers");
  NEED (g_file_set_contents (foreign_path, patched, (gssize) size, &file_error),
        "independent foreign-file oracle is preserved separately from unpatched native output");
  NEED (read_file (foreign_path, &reread, &reread_size) && reread_size == size && !memcmp (reread, patched, size),
        "foreign oracle on disk exactly matches the validated patched bytes");
  gchar *before_hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (guint8 *) original, size);
  gchar *foreign_hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (guint8 *) patched, size);
  printf ("OBS native_sha256=%s foreign_sha256=%s XCF_version=%u effect_offset=%zu\n",
          before_hash, foreign_hash, record.version, record.effect);
  g_free (before_hash);
  g_free (foreign_hash);
  NEED (api->image_open (engine, foreign_path, &opened, &error) == GLIMS_STATUS_OK,
        "public image_open accepts the validated foreign XCF without a Glims carrier");
  NEED (opened_fixture (engine, opened, &loaded), "foreign reopen retains one ordinary FLOAT_LINEAR alpha layer");
  CHECK (clean_open (&loaded), "foreign reopen is clean with empty Undo/Redo and no supplement carrier");
  GimpDrawableFilter *loaded_filter = one_effect (&loaded);
  NEED (loaded_filter != NULL, "foreign reopen retains exactly one native effect");
  GeglNode *loaded_node = gimp_drawable_filter_get_operation (loaded_filter);
  gdouble black = 0, exposure = 0;
  gegl_node_get (loaded_node, "black-level", &black, "exposure", &exposure, NULL);
  CHECK (!strcmp (gegl_node_get_operation (loaded_node), OPERATION) &&
      !strcmp (gimp_object_get_name (GIMP_OBJECT (loaded_filter)), SENTINEL) && black == .03125 && exposure == 1.25 &&
      gimp_drawable_filter_get_opacity (loaded_filter) == .625 &&
      gimp_drawable_filter_get_paint_mode (loaded_filter) == GIMP_LAYER_MODE_MULTIPLY &&
      gimp_drawable_filter_get_clip (loaded_filter) &&
      gimp_drawable_filter_get_region (loaded_filter) == GIMP_FILTER_REGION_DRAWABLE,
      "operation config custom name opacity paint mode clip and region survive independently of lost fields");
  CHECK (gimp_drawable_filter_get_blend_space (loaded_filter) == GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR,
         "foreign explicit blend space survives public image_open");
  CHECK (gimp_drawable_filter_get_composite_space (loaded_filter) == GIMP_LAYER_COLOR_SPACE_RGB_NON_LINEAR,
         "foreign explicit composite space survives public image_open");
  CHECK (gimp_drawable_filter_get_composite_mode (loaded_filter) == GIMP_LAYER_COMPOSITE_CLIP_TO_LAYER,
         "foreign explicit composite mode survives public image_open");
  CHECK (read_pixels (&loaded, FALSE, actual) && !memcmp (actual, source_pixels, sizeof actual),
         "foreign reopen preserves exact raw FLOAT_LINEAR source bytes");
  gboolean pixels_read = read_pixels (&loaded, TRUE, actual);
  printf ("OBS loaded_fields=%d,%d,%d expected_fields=2,2,3 explicit_pixel_delta=%.9g AUTO_pixel_delta=%.9g\n",
      gimp_drawable_filter_get_blend_space (loaded_filter),
      gimp_drawable_filter_get_composite_space (loaded_filter),
      gimp_drawable_filter_get_composite_mode (loaded_filter),
      pixels_read ? pixel_delta (expected, actual) : -1, pixels_read ? pixel_delta (automatic, actual) : -1);
  CHECK (pixels_read && pixel_delta (actual, expected) < 2e-4,
         "foreign explicit effect-rendered pixels match the independent pre-save native oracle");
  g_clear_pointer (&reread, g_free);
  CHECK (read_file (foreign_path, &reread, &reread_size) && reread_size == size && !memcmp (reread, patched, size),
         "public open leaves the foreign byte oracle unchanged");
  CHECK (explicit_fields (filter) && read_pixels (&source, TRUE, actual) && pixel_delta (actual, expected) < 2e-4,
         "opening the foreign document leaves the original native source and oracle unchanged");
  legacy_control (engine, 20, patched, size, &encoded, expected);
  legacy_control (engine, 21, patched, size, &encoded, expected);
cleanup:
  if (file_error) fprintf (stderr, "OBS oracle write: %s\n", file_error->message);
  if (error) fprintf (stderr, "OBS public open: %s\n", error);
  if (opened) api->image_close (engine, opened);
  if (filter && !committed) gimp_drawable_filter_abort (filter);
  g_clear_object (&filter);
  g_clear_object (&node);
  if (source.id) api->image_close (engine, source.id);
  clear_error (&error);
  g_clear_error (&file_error);
  g_free (native_path);
  g_free (foreign_path);
  g_free (original);
  g_free (patched);
  g_free (reread);
  plain_control (engine);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  work_dir = argv[1];
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api) return 2;
  gchar *user = g_build_filename (work_dir, "user", NULL);
  gchar *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngine *engine = NULL;
  char *error = NULL;
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed");
    clear_error (&error);
    g_free (user);
    g_free (cache);
    return 2;
  }
  CHECK (glims_engine_call (engine, regression, NULL) == GLIMS_STATUS_OK,
         "foreign XCF regression runs on the real engine worker");
  api->stop (engine);
  g_free (user);
  g_free (cache);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

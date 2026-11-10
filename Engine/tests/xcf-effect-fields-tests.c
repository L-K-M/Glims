/* GLib/GIO-only metadata specifications. Synthetic cases deliberately contain
 * opaque hierarchy bytes; decoding must neither inspect nor render tiles.
 * The separate preserved native foreign oracle remains immutable. */
#include "xcf-effect-fields.h"
#include <glib/gstdio.h>
#include <stdio.h>
#include <string.h>

int main (int argc, char **argv);
static guint checks, failures;
static const gchar *work_dir;
#define CHECK(condition, title) do { gboolean ok_ = (condition); checks++; \
  printf ("%s %s\n", ok_ ? "ok  " : "FAIL", title); if (!ok_) failures++; } while (0)

typedef struct {
  GByteArray *bytes;
  GArray *slots;
  gsize layer_table, channel_slot, path_slot, layer_name, layer_tattoo, layer_end;
  gsize layer_mask, effect_table, effect_start, blend, composite, mode, effect_end;
  gsize effect_mask_slot, mask_start, mask_hierarchy, mask_data;
} Spec;

static void
put32 (GByteArray *bytes, guint32 value)
{
  value = GUINT32_TO_BE (value);
  g_byte_array_append (bytes, (guint8 *) &value, sizeof value);
}

static void
set32 (GByteArray *bytes, gsize position, guint32 value)
{
  value = GUINT32_TO_BE (value);
  memcpy (bytes->data + position, &value, sizeof value);
}

static guint64
get64 (GByteArray *bytes, gsize position)
{
  guint64 value;
  memcpy (&value, bytes->data + position, sizeof value);
  return GUINT64_FROM_BE (value);
}

static void
set64 (GByteArray *bytes, gsize position, guint64 value)
{
  value = GUINT64_TO_BE (value);
  memcpy (bytes->data + position, &value, sizeof value);
}

static gsize
slot (Spec *spec)
{
  gsize position = spec->bytes->len;
  guint64 zero = 0;
  g_byte_array_append (spec->bytes, (guint8 *) &zero, sizeof zero);
  g_array_append_val (spec->slots, position);
  return position;
}

static void
string (GByteArray *bytes, const gchar *value)
{
  guint32 size = (guint32) strlen (value) + 1;
  put32 (bytes, size);
  g_byte_array_append (bytes, (const guint8 *) value, size);
}

static void
property (GByteArray *bytes, guint32 id, guint32 value)
{
  put32 (bytes, id); put32 (bytes, 4); put32 (bytes, value);
}

static void
end (GByteArray *bytes)
{
  put32 (bytes, 0); put32 (bytes, 0);
}

static Spec *
spec_new (guint layers, guint effects, guint name_bytes)
{
  Spec *spec = g_new0 (Spec, 1);
  spec->bytes = g_byte_array_new ();
  spec->slots = g_array_new (FALSE, FALSE, sizeof (gsize));
  GArray *layer_slots = g_array_new (FALSE, FALSE, sizeof (gsize));
  GByteArray *bytes = spec->bytes;
  g_byte_array_append (bytes, (guint8 *) "gimp xcf v022\0", 14);
  put32 (bytes, 4); put32 (bytes, 2); put32 (bytes, 0); put32 (bytes, 600);
  end (bytes);
  spec->layer_table = bytes->len;
  for (guint i = 0; i < layers; i++) { gsize position = slot (spec); g_array_append_val (layer_slots, position); }
  slot (spec);
  spec->channel_slot = slot (spec);
  spec->path_slot = slot (spec);
  for (guint i = 0; i < layers; i++) {
    GArray *effect_slots = g_array_new (FALSE, FALSE, sizeof (gsize));
    set64 (bytes, g_array_index (layer_slots, gsize, i), bytes->len);
    put32 (bytes, 4); put32 (bytes, 2); put32 (bytes, 1);
    if (!i) spec->layer_name = bytes->len;
    gchar *name = g_strdup_printf ("Layer%u", i);
    string (bytes, name); g_free (name);
    if (!i) spec->layer_tattoo = bytes->len;
    property (bytes, 20, i + 17);
    if (!i) spec->layer_end = bytes->len;
    end (bytes);
    gsize hierarchy = slot (spec);
    gsize mask = slot (spec);
    if (!i) { spec->layer_mask = mask; spec->effect_table = bytes->len; }
    for (guint j = 0; j < effects; j++) { gsize position = slot (spec); g_array_append_val (effect_slots, position); }
    slot (spec);
    set64 (bytes, hierarchy, bytes->len);
    g_byte_array_append (bytes, (guint8 *) "H", 1);
    for (guint j = 0; j < effects; j++) {
      set64 (bytes, g_array_index (effect_slots, gsize, j), bytes->len);
      if (!i && !j) spec->effect_start = bytes->len;
      name = name_bytes ? g_strnfill (name_bytes - 1, 'n') : g_strdup_printf ("Effect%u-%u", i, j);
      string (bytes, name); g_free (name);
      string (bytes, "gimp-gegl"); string (bytes, "gegl:exposure"); string (bytes, "0:0");
      if (!i && !j) spec->mode = bytes->len;
      property (bytes, 35, 3);
      if (!i && !j) spec->blend = bytes->len;
      property (bytes, 37, 2);
      if (!i && !j) spec->composite = bytes->len;
      property (bytes, 36, 2);
      property (bytes, 7, 30); property (bytes, 33, 0x3f200000);
      property (bytes, 8, 1); property (bytes, 46, 1); property (bytes, 44, 1);
      put32 (bytes, 45); put32 (bytes, 5); g_byte_array_append (bytes, (guint8 *) "opaque", 5);
      if (!i && !j) spec->effect_end = bytes->len;
      end (bytes);
      gsize mask_slot = slot (spec);
      set64 (bytes, mask_slot, bytes->len);
      if (!i && !j) { spec->effect_mask_slot = mask_slot; spec->mask_start = bytes->len; }
      put32 (bytes, 4); put32 (bytes, 2); string (bytes, "Effect mask");
      property (bytes, 20, 300 + j); end (bytes);
      gsize mask_hierarchy = slot (spec);
      set64 (bytes, mask_hierarchy, bytes->len);
      if (!i && !j) { spec->mask_hierarchy = mask_hierarchy; spec->mask_data = bytes->len; }
      g_byte_array_append (bytes, (guint8 *) "M", 1);
    }
    g_array_unref (effect_slots);
  }
  g_array_unref (layer_slots);
  return spec;
}

static void
spec_free (Spec *spec)
{
  g_byte_array_unref (spec->bytes); g_array_unref (spec->slots); g_free (spec);
}

static GlimsXcfEffectFields *
decode_path (const gchar *path, GError **error)
{
  GFile *file = g_file_new_for_path (path);
  GlimsXcfEffectFields *fields = glims_xcf_effect_fields_read (file, NULL, error);
  g_object_unref (file);
  return fields;
}

static GlimsXcfEffectFields *
decode_bytes (const guint8 *bytes, gsize length, GError **error)
{
  gchar *path = g_build_filename (work_dir, "owned-case.xcf", NULL);
  if (!g_file_set_contents (path, (const gchar *) bytes, (gssize) length, error)) { g_free (path); return NULL; }
  GlimsXcfEffectFields *fields = decode_path (path, error);
  g_free (path);
  return fields;
}

static void
reject (Spec *spec, GlimsXcfEffectFieldsError code, const gchar *label)
{
  GError *error = NULL;
  GlimsXcfEffectFields *fields = decode_bytes (spec->bytes->data, spec->bytes->len, &error);
  CHECK (!fields && g_error_matches (error, GLIMS_XCF_EFFECT_FIELDS_ERROR, code), label);
  if (fields || !g_error_matches (error, GLIMS_XCF_EFFECT_FIELDS_ERROR, code))
    fprintf (stderr, "OBS expected=%d actual=%s\n", code, error ? error->message : "success");
  glims_xcf_effect_fields_free (fields); g_clear_error (&error); spec_free (spec);
}

static GByteArray *
insert_bytes (Spec *spec, gsize position, const guint8 *data, gsize length)
{
  GByteArray *bytes = g_byte_array_new ();
  g_byte_array_append (bytes, spec->bytes->data, (guint) position);
  g_byte_array_append (bytes, data, (guint) length);
  g_byte_array_append (bytes, spec->bytes->data + position, spec->bytes->len - (guint) position);
  for (guint i = 0; i < spec->slots->len; i++) {
    gsize old = g_array_index (spec->slots, gsize, i), next = old >= position ? old + length : old;
    guint64 value = get64 (spec->bytes, old);
    set64 (bytes, next, value >= position && value ? value + length : value);
  }
  return bytes;
}

static void
test_foreign (const gchar *path)
{
  GError *error = NULL;
  GlimsXcfEffectFields *fields = decode_path (path, &error);
  CHECK (fields && !error, "preserved native foreign XCF decodes without an engine");
  if (!fields) { fprintf (stderr, "OBS %s\n", error ? error->message : "missing result"); g_clear_error (&error); return; }
  const GlimsXcfImageFields *image = glims_xcf_effect_fields_image (fields);
  CHECK (image->version == 22 && image->width == 4 && image->height == 2 && image->base_type == 0 && image->precision == 600,
         "foreign image header remains the independently specified raw metadata");
  CHECK (glims_xcf_effect_fields_layer_count (fields) == 1 && glims_xcf_effect_fields_effect_count (fields, 0) == 1,
         "foreign file exposes exactly one ordered layer and one effect");
  const GlimsXcfLayerFields *layer = glims_xcf_effect_fields_layer (fields, 0);
  CHECK (layer && !g_strcmp0 (layer->name, "Foreign alpha source") && layer->has_tattoo && layer->tattoo &&
         layer->width == 4 && layer->height == 2 && layer->xcf_type == 1, "foreign layer owns its complete ordinary-layer metadata");
  const GlimsXcfEffectFieldsRecord *effect = glims_xcf_effect_fields_effect (fields, 0, 0);
  CHECK (effect && !g_strcmp0 (effect->name, "Foreign effect sentinel 7f21c89a") &&
         !g_strcmp0 (effect->icon, "gimp-gegl") && !g_strcmp0 (effect->operation, "gegl:exposure") &&
         effect->operation_version && *effect->operation_version, "foreign effect owns encoded name icon operation and version");
  CHECK (effect && effect->presence == 255 && effect->blend_space == 2 && effect->composite_space == 2 && effect->composite_mode == 3,
         "foreign three raw fields are literal 2 2 3 rather than native AUTO");
  CHECK (effect && effect->paint_mode == 30 && effect->opacity == .625f && effect->visible == 1 && effect->clip == 1 && effect->region == 1,
         "foreign mode opacity visibility clip and region remain raw file values");
  CHECK (effect && effect->mask_present && effect->mask_width == 4 && effect->mask_height == 2 && effect->mask_name,
         "ordinary effect-mask metadata is captured without reading mask pixels");
  CHECK (glims_xcf_effect_fields_bytes_read (fields) < 1862, "decoder skips opaque operation payload and pixel data");
  glims_xcf_effect_fields_free (fields);
  gchar *bytes = NULL, *owned = g_build_filename (work_dir, "owned-foreign-copy.xcf", NULL);
  gsize length = 0;
  gboolean copied = g_file_get_contents (path, &bytes, &length, &error) &&
      g_file_set_contents (owned, bytes, (gssize) length, &error);
  g_free (bytes);
  fields = copied ? decode_path (owned, &error) : NULL;
  g_unlink (owned);
  effect = glims_xcf_effect_fields_effect (fields, 0, 0);
  CHECK (fields && !error && effect && !g_strcmp0 (effect->name, "Foreign effect sentinel 7f21c89a") && effect->blend_space == 2,
         "decoded metadata survives input close and deletion of the owned file copy");
  glims_xcf_effect_fields_free (fields); g_clear_error (&error); g_free (owned);
}

static void
test_valid_specs (void)
{
  Spec *spec = spec_new (2, 2, 0);
  GError *error = NULL;
  GlimsXcfEffectFields *fields = decode_bytes (spec->bytes->data, spec->bytes->len, &error);
  CHECK (fields && !error && glims_xcf_effect_fields_layer_count (fields) == 2 &&
      glims_xcf_effect_fields_effect_count (fields, 0) == 2 && glims_xcf_effect_fields_effect_count (fields, 1) == 2,
      "independent metadata specification retains multiple layers and multiple effects");
  const GlimsXcfLayerFields *layer = glims_xcf_effect_fields_layer (fields, 1);
  const GlimsXcfEffectFieldsRecord *effect = glims_xcf_effect_fields_effect (fields, 1, 1);
  CHECK (layer && !strcmp (layer->name, "Layer1") && layer->tattoo == 18 && effect && !strcmp (effect->name, "Effect1-1"),
         "layer and effect DTO order follows the explicit offset tables");
  CHECK (!glims_xcf_effect_fields_layer (fields, 2) && !glims_xcf_effect_fields_effect (fields, 0, 2),
         "out-of-range metadata access is empty");
  glims_xcf_effect_fields_free (fields); g_clear_error (&error); spec_free (spec);
  spec = spec_new (1, 1, 0);
  spec->bytes->data[12] = '3';
  set32 (spec->bytes, 22, 0x12345678); set32 (spec->bytes, 26, 0x87654321);
  set32 (spec->bytes, spec->blend + 8, 0xfffffffe);
  set32 (spec->bytes, spec->composite + 8, 0x80000000);
  set32 (spec->bytes, spec->mode + 8, 0xffffffff);
  fields = decode_bytes (spec->bytes->data, spec->bytes->len, &error);
  effect = glims_xcf_effect_fields_effect (fields, 0, 0);
  const GlimsXcfImageFields *image = glims_xcf_effect_fields_image (fields);
  CHECK (fields && !error && image->version == 23 && image->base_type == 0x12345678 && image->precision == 0x87654321 &&
      effect && effect->blend_space == -2 && effect->composite_space == G_MININT32 && effect->composite_mode == -1,
      "version23 and unknown or negative raw enum words survive without GIMP casts or validation");
  glims_xcf_effect_fields_free (fields); g_clear_error (&error); spec_free (spec);
  spec = spec_new (1, 1, 0);
  set32 (spec->bytes, spec->blend, 700);
  fields = decode_bytes (spec->bytes->data, spec->bytes->len, &error);
  effect = glims_xcf_effect_fields_effect (fields, 0, 0);
  CHECK (effect && !(effect->presence & GLIMS_XCF_FIELD_BLEND_SPACE) && effect->composite_space == 2,
         "absent effect fields remain absent rather than invented defaults");
  glims_xcf_effect_fields_free (fields); g_clear_error (&error); spec_free (spec);
  spec = spec_new (1, 0, 0);
  fields = decode_bytes (spec->bytes->data, spec->bytes->len, &error);
  CHECK (fields && glims_xcf_effect_fields_layer_count (fields) == 1 && !glims_xcf_effect_fields_effect_count (fields, 0),
         "version22 ordinary layer with no effects remains explicit");
  glims_xcf_effect_fields_free (fields); g_clear_error (&error); spec_free (spec);
  spec = spec_new (1, 1, 0);
  guint8 zero[8] = {0};
  GByteArray *extra = insert_bytes (spec, spec->mask_data, zero, sizeof zero);
  fields = decode_bytes (extra->data, extra->len, &error);
  CHECK (fields && !error, "ordinary effect-mask metadata permits one explicitly empty optional effects table");
  glims_xcf_effect_fields_free (fields); g_clear_error (&error); g_byte_array_unref (extra); spec_free (spec);
}

static void
test_rejections (void)
{
  Spec *spec = spec_new (1, 1, 0);
  set64 (spec->bytes, spec->layer_table, G_MAXUINT64);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "64-bit out-of-file offset and signed seek overflow are rejected");
  spec = spec_new (1, 2, 0);
  set64 (spec->bytes, spec->effect_table + 8, get64 (spec->bytes, spec->effect_table));
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "duplicate effect metadata offsets are rejected");
  spec = spec_new (1, 1, 0);
  set64 (spec->bytes, spec->effect_mask_slot, get64 (spec->bytes, spec->layer_table));
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "effect masks cannot reuse layer metadata offsets");
  spec = spec_new (1, 1, 0);
  set64 (spec->bytes, spec->effect_table, get64 (spec->bytes, spec->layer_table) + 1);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "partially overlapping metadata record offsets are rejected");
  spec = spec_new (1, 1, 0);
  set32 (spec->bytes, spec->mode, 37);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "duplicate raw effect field properties are rejected");
  spec = spec_new (1, 1, 0);
  set32 (spec->bytes, spec->blend + 4, 8);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "raw effect fields require exactly four bytes");
  spec = spec_new (1, 1, 0);
  set32 (spec->bytes, spec->blend + 4, G_MAXUINT32);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "oversized out-of-file TLV ranges are rejected without overflow");
  spec = spec_new (1, 1, 0);
  set32 (spec->bytes, spec->layer_end, 20); set32 (spec->bytes, spec->layer_end + 4, 4);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "duplicate layer identity fields are rejected");
  spec = spec_new (1, 1, 0);
  set32 (spec->bytes, spec->effect_end + 4, 4);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "END properties cannot hide a payload");
  spec = spec_new (1, 1, 0);
  spec->bytes->data[spec->layer_name + 4] = 0;
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "embedded NUL in an encoded layer name is rejected");
  spec = spec_new (1, 1, 0);
  spec->bytes->data[spec->layer_name + 4] = 0xff;
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "invalid UTF-8 metadata names are rejected");
  spec = spec_new (1, 1, 0);
  set64 (spec->bytes, spec->layer_mask, spec->mask_start);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "ordinary-layer decoder refuses layer masks explicitly");
  spec = spec_new (1, 1, 0);
  set64 (spec->bytes, spec->channel_slot, spec->mask_start);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "ordinary-layer decoder refuses image channels explicitly");
  spec = spec_new (1, 1, 0);
  set64 (spec->bytes, spec->path_slot, spec->mask_start);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "ordinary-layer decoder refuses paths explicitly");
  const guint32 specialized[] = {29, 30, 26, 47, 48};
  for (guint i = 0; i < G_N_ELEMENTS (specialized); i++) {
    spec = spec_new (1, 1, 0); set32 (spec->bytes, spec->layer_tattoo, specialized[i]);
    reject (spec, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "groups nesting text vector and linked-layer markers are unsupported");
  }
  spec = spec_new (1, 1, 0);
  guint8 zero[8] = {0};
  GByteArray *nested = insert_bytes (spec, spec->mask_data, zero, sizeof zero);
  set64 (nested, spec->mask_data, get64 (nested, spec->layer_table));
  g_byte_array_unref (spec->bytes); spec->bytes = nested;
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "nested effects on ordinary effect masks are refused explicitly");
  spec = spec_new (1, 1, GLIMS_XCF_EFFECT_FIELDS_MAX_STRING + 1);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "individual strings above64 KiB hit the string budget");
  spec = spec_new (1, 70, GLIMS_XCF_EFFECT_FIELDS_MAX_STRING);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "cumulative actual read and owned string bytes hit8 MiB budget");
  spec = spec_new (1, GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS, 0);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "total layer/effect/mask records are capped before unbounded traversal");
  spec = spec_new (1, 1, 0);
  GByteArray *properties = g_byte_array_new ();
  for (guint i = 0; i <= GLIMS_XCF_EFFECT_FIELDS_MAX_PROPERTIES; i++) { put32 (properties, 700); put32 (properties, 0); }
  GByteArray *many = insert_bytes (spec, 30, properties->data, properties->len);
  g_byte_array_unref (properties); g_byte_array_unref (spec->bytes); spec->bytes = many;
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "global property count bounds zero-size unknown property loops");
  spec = spec_new (1, 1, 0); spec->bytes->data[12] = '1';
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "other XCF versions have an explicit unsupported error");
  spec = spec_new (1, 1, 0); spec->bytes->data[11] = 'x';
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "invalid version digits are malformed rather than unsupported");
  spec = spec_new (1, 1, 0); memset (spec->bytes->data, 'x', 9);
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_NOT_XCF, "non-XCF input has a distinct error code");
  spec = spec_new (1, 1, 0); spec->bytes->data[0] = 0x1f; spec->bytes->data[1] = 0x8b;
  reject (spec, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "compressed containers have an explicit unsupported error");
}

static void
test_truncation (void)
{
  Spec *spec = spec_new (1, 1, 0);
  gboolean all = TRUE;
  for (gsize i = 0; i < spec->bytes->len; i++) {
    GError *error = NULL;
    GlimsXcfEffectFields *fields = decode_bytes (spec->bytes->data, i, &error);
    if (fields || !error) { fprintf (stderr, "OBS accepted truncated length=%zu\n", i); all = FALSE; }
    glims_xcf_effect_fields_free (fields); g_clear_error (&error);
  }
  CHECK (all, "every truncation of the owned ordinary metadata fixture fails with cleanup");
  spec_free (spec);
}

static void
test_sparse_skip (void)
{
  Spec *spec = spec_new (1, 1, 0);
  const guint32 payload = 12u * 1024u * 1024u;
  const guint64 gap = (guint64) payload + 8;
  for (guint i = 0; i < spec->slots->len; i++) {
    gsize position = g_array_index (spec->slots, gsize, i);
    guint64 value = get64 (spec->bytes, position);
    if (value) set64 (spec->bytes, position, value + gap);
  }
  GError *error = NULL;
  gchar *path = g_build_filename (work_dir, "owned-sparse-unrelated.xcf", NULL);
  GFile *file = g_file_new_for_path (path);
  GFileOutputStream *output = g_file_replace (file, NULL, FALSE, G_FILE_CREATE_PRIVATE, NULL, &error);
  guint32 encoded[] = { GUINT32_TO_BE (700), GUINT32_TO_BE (payload) };
  gboolean success = output && g_output_stream_write_all (G_OUTPUT_STREAM (output), spec->bytes->data, 30, NULL, NULL, &error) &&
      g_output_stream_write_all (G_OUTPUT_STREAM (output), encoded, sizeof encoded, NULL, NULL, &error) &&
      g_seekable_seek (G_SEEKABLE (output), (goffset) (30 + gap), G_SEEK_SET, NULL, &error) &&
      g_output_stream_write_all (G_OUTPUT_STREAM (output), spec->bytes->data + 30, spec->bytes->len - 30, NULL, NULL, &error);
  if (output && !g_output_stream_close (G_OUTPUT_STREAM (output), NULL, success ? &error : NULL)) success = FALSE;
  g_clear_object (&output);
  GlimsXcfEffectFields *fields = success ? decode_path (path, &error) : NULL;
  const GlimsXcfEffectFieldsRecord *effect = glims_xcf_effect_fields_effect (fields, 0, 0);
  CHECK (fields && !error && effect && effect->blend_space == 2 &&
      glims_xcf_effect_fields_bytes_read (fields) < 4096,
      "sparse12 MiB unrelated TLV is bounds-checked and seek-skipped without reading or charging its payload");
  if (error) fprintf (stderr, "OBS sparse skip: %s\n", error->message);
  glims_xcf_effect_fields_free (fields); g_clear_error (&error);
  g_object_unref (file); g_free (path); spec_free (spec);
}

int
main (int argc, char **argv)
{
  if (argc != 3) return 2;
  work_dir = argv[2];
  test_foreign (argv[1]);
  test_valid_specs ();
  test_rejections ();
  test_truncation ();
  test_sparse_skip ();
  printf ("%s: %u checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}

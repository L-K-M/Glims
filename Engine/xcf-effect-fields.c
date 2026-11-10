#include "xcf-effect-fields.h"
#include <string.h>

/* File-format identifiers, not GIMP enum values or structure layouts. */
enum {
  END = 0, SELECTION = 4, FLOATING = 5, MODE = 7, VISIBLE = 8, TATTOO = 20,
  PARASITES = 21, OLD_PATHS = 23, OLD_VECTORS = 25, TEXT = 26,
  GROUP = 29, ITEM_PATH = 30, GROUP_FLAGS = 31, OPACITY = 33,
  COMPOSITE_MODE = 35, COMPOSITE_SPACE = 36, BLEND_SPACE = 37,
  REGION = 44, ARGUMENT = 45, CLIP = 46, VECTOR = 47, LINK = 48, TRANSFORM = 49
};

typedef struct {
  GlimsXcfChannelFields fields;
  GPtrArray *effects;
} Channel;

typedef struct {
  GlimsXcfLayerFields fields;
  GPtrArray *effects;
  GArray *item_path;
  Channel *mask;
} Layer;

struct GlimsXcfEffectFields {
  GlimsXcfImageFields image;
  GPtrArray *layers, *channels;
  guint64 bytes_read;
};

typedef struct { guint64 start, end; } Range;
typedef struct {
  GFileInputStream *stream;
  GCancellable *cancellable;
  GError **error;
  guint64 size, position, limit, spent, bytes_read;
  guint records, properties, offset_reads, version;
  GArray *anchors, *ranges;
  GHashTable *claimed;
} Reader;

G_DEFINE_QUARK (glims-xcf-effect-fields-error, glims_xcf_effect_fields_error)

static gboolean
fail (Reader *reader, GlimsXcfEffectFieldsError code, const gchar *message)
{
  g_set_error (reader->error, GLIMS_XCF_EFFECT_FIELDS_ERROR, code,
               "%s (metadata offset %" G_GUINT64_FORMAT ")", message, reader->position);
  return FALSE;
}

static gboolean
charge (Reader *reader, guint64 bytes)
{
  if (bytes > GLIMS_XCF_EFFECT_FIELDS_MAX_BYTES - reader->spent)
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "XCF metadata byte budget exceeded");
  reader->spent += bytes;
  return TRUE;
}

static gboolean
bounds (Reader *reader, guint64 bytes)
{
  if (reader->position > reader->limit || bytes > reader->limit - reader->position ||
      reader->position > reader->size || bytes > reader->size - reader->position)
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Truncated or overflowing XCF metadata");
  return TRUE;
}

static gboolean
read_bytes (Reader *reader, gpointer bytes, gsize count)
{
  gsize received = 0;
  if (!bounds (reader, count) || !charge (reader, count)) return FALSE;
  gboolean success = g_input_stream_read_all (G_INPUT_STREAM (reader->stream), bytes, count,
      &received, reader->cancellable, reader->error);
  reader->position += received;
  reader->bytes_read += received;
  if (!success) return FALSE;
  return received == count || fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "XCF changed or ended during metadata read");
}

static gboolean
skip_bytes (Reader *reader, guint64 count)
{
  if (!bounds (reader, count)) return FALSE;
  guint64 next = reader->position + count;
  if (!g_seekable_seek (G_SEEKABLE (reader->stream), (goffset) next, G_SEEK_SET,
                        reader->cancellable, reader->error)) return FALSE;
  reader->position = next;
  return TRUE;
}

static gboolean
read_u32 (Reader *reader, guint32 *value)
{
  guint32 encoded;
  if (!read_bytes (reader, &encoded, sizeof encoded)) return FALSE;
  *value = GUINT32_FROM_BE (encoded);
  return TRUE;
}

static gboolean
read_offset (Reader *reader, guint64 *value)
{
  guint64 encoded;
  if (++reader->offset_reads > 4 * GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS + 8)
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "XCF offset-read limit exceeded");
  if (!read_bytes (reader, &encoded, sizeof encoded)) return FALSE;
  *value = GUINT64_FROM_BE (encoded);
  if (*value && *value >= reader->size)
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "XCF object offset is outside the file");
  return TRUE;
}

static gpointer
allocate (Reader *reader, gsize bytes)
{
  if (!charge (reader, bytes)) return NULL;
  gpointer result = g_try_malloc0 (bytes);
  if (!result) g_set_error_literal (reader->error, G_IO_ERROR, G_IO_ERROR_NO_SPACE, "Cannot allocate bounded XCF metadata");
  return result;
}

static gboolean
read_string (Reader *reader, gchar **value)
{
  guint32 length;
  if (!read_u32 (reader, &length)) return FALSE;
  if (!length) { *value = NULL; return TRUE; }
  if (length > GLIMS_XCF_EFFECT_FIELDS_MAX_STRING)
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "XCF string exceeds 64 KiB");
  if (!bounds (reader, length)) return FALSE;
  gchar *text = allocate (reader, length);
  if (!text) return FALSE;
  if (!read_bytes (reader, text, length)) { g_free (text); return FALSE; }
  if (text[length - 1] != '\0' || memchr (text, '\0', length - 1) ||
      !g_utf8_validate (text, length - 1, NULL)) {
    g_free (text);
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Invalid XCF UTF-8 string");
  }
  *value = text;
  return TRUE;
}

static gboolean
claim_offset (Reader *reader, guint64 offset, gboolean metadata)
{
  if (!offset || offset >= reader->size)
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Missing or invalid XCF object offset");
  if (g_hash_table_contains (reader->claimed, &offset))
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Duplicate or reused XCF object offset");
  if (reader->anchors->len >= 2 * GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS ||
      (metadata && reader->records >= GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS))
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "XCF record/offset limit exceeded");
  for (guint i = 0; i < reader->ranges->len; i++) {
    Range range = g_array_index (reader->ranges, Range, i);
    if (offset >= range.start && offset < range.end)
      return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "XCF object reuses consumed metadata");
  }
  if (!charge (reader, sizeof (guint64) * 2 + 4 * sizeof (gpointer))) return FALSE;
  guint64 *key = g_new (guint64, 1);
  *key = offset;
  g_hash_table_add (reader->claimed, key);
  g_array_append_val (reader->anchors, offset);
  if (metadata) reader->records++;
  return TRUE;
}

static gboolean
seek_record (Reader *reader, guint64 offset)
{
  for (guint i = 0; i < reader->ranges->len; i++) {
    Range range = g_array_index (reader->ranges, Range, i);
    if (offset >= range.start && offset < range.end)
      return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "XCF record overlaps consumed metadata");
  }
  if (!g_seekable_seek (G_SEEKABLE (reader->stream), (goffset) offset, G_SEEK_SET,
                        reader->cancellable, reader->error)) return FALSE;
  reader->position = offset;
  reader->limit = reader->size;
  return TRUE;
}

static gboolean
finish_record (Reader *reader, guint64 start)
{
  Range range = { start, reader->position };
  for (guint i = 0; i < reader->ranges->len; i++) {
    Range old = g_array_index (reader->ranges, Range, i);
    if (range.start < old.end && old.start < range.end)
      return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Overlapping XCF metadata ranges");
  }
  for (guint i = 0; i < reader->anchors->len; i++) {
    guint64 anchor = g_array_index (reader->anchors, guint64, i);
    if (anchor != start && anchor >= start && anchor < range.end)
      return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "XCF metadata contains another object offset");
  }
  if (!charge (reader, sizeof range)) return FALSE;
  g_array_append_val (reader->ranges, range);
  return TRUE;
}

static void
effect_free (gpointer data)
{
  GlimsXcfEffectFieldsRecord *effect = data;
  if (!effect) return;
  g_free (effect->name); g_free (effect->icon); g_free (effect->operation);
  g_free (effect->operation_version); g_free (effect->mask_name); g_free (effect);
}

static void
channel_free (gpointer data)
{
  Channel *channel = data;
  if (!channel) return;
  g_free (channel->fields.name);
  g_ptr_array_unref (channel->effects);
  g_free (channel);
}

static void
layer_free (gpointer data)
{
  Layer *layer = data;
  g_free (layer->fields.name);
  g_ptr_array_unref (layer->effects);
  if (layer->item_path) g_array_unref (layer->item_path);
  channel_free (layer->mask);
  g_free (layer);
}

void
glims_xcf_effect_fields_free (GlimsXcfEffectFields *fields)
{
  if (!fields) return;
  g_ptr_array_unref (fields->layers);
  g_ptr_array_unref (fields->channels);
  g_free (fields);
}

typedef enum { IMAGE_PROPERTIES, LAYER_PROPERTIES, CHANNEL_PROPERTIES, EFFECT_PROPERTIES } PropertyKind;

static gboolean
parasites (Reader *reader, Layer *layer)
{
  while (reader->position < reader->limit) {
    if (++reader->properties > GLIMS_XCF_EFFECT_FIELDS_MAX_PROPERTIES)
      return fail (reader, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "XCF property limit exceeded");
    gchar *name = NULL;
    guint32 flags, length;
    if (!read_string (reader, &name)) return FALSE;
    gboolean text = name && (!strcmp (name, "gimp-text-layer") || !strcmp (name, "gimp-text-layer-xcf"));
    g_free (name);
    if (text) layer->fields.kind_flags |= GLIMS_XCF_LAYER_TEXT;
    if (!read_u32 (reader, &flags) || !read_u32 (reader, &length) || !skip_bytes (reader, length)) return FALSE;
  }
  return TRUE;
}

static gboolean
effect_property (Reader *reader, GlimsXcfEffectFieldsRecord *effect, guint32 property, guint32 size)
{
  guint32 bit;
  switch (property) {
  case BLEND_SPACE: bit = GLIMS_XCF_FIELD_BLEND_SPACE; break;
  case COMPOSITE_SPACE: bit = GLIMS_XCF_FIELD_COMPOSITE_SPACE; break;
  case COMPOSITE_MODE: bit = GLIMS_XCF_FIELD_COMPOSITE_MODE; break;
  case MODE: bit = GLIMS_XCF_FIELD_PAINT_MODE; break;
  case OPACITY: bit = GLIMS_XCF_FIELD_OPACITY; break;
  case VISIBLE: bit = GLIMS_XCF_FIELD_VISIBLE; break;
  case CLIP: bit = GLIMS_XCF_FIELD_CLIP; break;
  case REGION: bit = GLIMS_XCF_FIELD_REGION; break;
  default: return skip_bytes (reader, size);
  }
  if (size != 4 || (effect->presence & bit))
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Duplicate or incorrectly sized XCF effect field");
  guint32 word;
  gint32 signed_word;
  if (!read_u32 (reader, &word)) return FALSE;
  memcpy (&signed_word, &word, sizeof signed_word);
  effect->presence |= bit;
  switch (property) {
  case BLEND_SPACE: effect->blend_space = signed_word; break;
  case COMPOSITE_SPACE: effect->composite_space = signed_word; break;
  case COMPOSITE_MODE: effect->composite_mode = signed_word; break;
  case MODE: effect->paint_mode = signed_word; break;
  case OPACITY: memcpy (&effect->opacity, &word, sizeof word); break;
  case VISIBLE: effect->visible = word; break;
  case CLIP: effect->clip = word; break;
  case REGION: effect->region = signed_word; break;
  default: g_assert_not_reached ();
  }
  return TRUE;
}

static gboolean
properties (Reader *reader, PropertyKind kind, gpointer target)
{
  gboolean tattoo_seen = FALSE, group_flags_seen = FALSE, transform_seen = FALSE;
  guint32 markers_seen = 0;
  for (;;) {
    guint32 property, size;
    if (++reader->properties > GLIMS_XCF_EFFECT_FIELDS_MAX_PROPERTIES)
      return fail (reader, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "XCF property limit exceeded");
    if (!read_u32 (reader, &property) || !read_u32 (reader, &size)) return FALSE;
    if (property == END) {
      if (size) return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "XCF END property has a payload");
      if (kind == LAYER_PROPERTIES) {
        Layer *layer = target;
        if ((group_flags_seen && !(layer->fields.kind_flags & GLIMS_XCF_LAYER_GROUP)) ||
            (transform_seen && !(layer->fields.kind_flags & GLIMS_XCF_LAYER_LINK)))
          return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "XCF layer flags have no corresponding context marker");
      }
      return TRUE;
    }
    if (!bounds (reader, size)) return FALSE;
    guint64 previous_limit = reader->limit, end = reader->position + size;
    reader->limit = end;
    gboolean success = TRUE;
    if (kind == EFFECT_PROPERTIES) success = effect_property (reader, target, property, size);
    else if (kind != IMAGE_PROPERTIES && property == FLOATING)
      success = fail (reader, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "Nested or specialized XCF drawable metadata is unsupported");
    else if (kind == LAYER_PROPERTIES && (property == GROUP || property == TEXT || property == VECTOR || property == LINK)) {
      Layer *layer = target;
      guint32 flag = property == GROUP ? GLIMS_XCF_LAYER_GROUP : property == TEXT ? GLIMS_XCF_LAYER_TEXT :
          property == VECTOR ? GLIMS_XCF_LAYER_VECTOR : GLIMS_XCF_LAYER_LINK;
      if ((markers_seen & flag) || (property == GROUP && size != 0) || (property == TEXT && size != 4))
        success = fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Duplicate or incorrectly sized XCF layer context marker");
      else {
        markers_seen |= flag;
        layer->fields.kind_flags |= flag;
        success = skip_bytes (reader, size);
      }
    } else if (kind == LAYER_PROPERTIES && property == GROUP_FLAGS) {
      if (size != 4 || group_flags_seen) success = fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Invalid XCF group flags");
      else { group_flags_seen = TRUE; success = skip_bytes (reader, size); }
    } else if (kind == LAYER_PROPERTIES && property == TRANSFORM) {
      if (transform_seen) success = fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Duplicate XCF link transform");
      else { transform_seen = TRUE; success = skip_bytes (reader, size); }
    } else if (kind == LAYER_PROPERTIES && property == ITEM_PATH) {
      Layer *layer = target;
      if (!size || size % 4 || layer->item_path) success = fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Invalid or duplicate XCF item path");
      else if (size / 4 > GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS) success = fail (reader, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "XCF item path exceeds record limit");
      else if (!(success = charge (reader, 2 * (guint64) size))) { /* Preserve budget failure. */ }
      else {
        layer->item_path = g_array_new (FALSE, FALSE, sizeof (guint32));
        for (guint i = 0; success && i < size / 4; i++) {
          guint32 index;
          success = read_u32 (reader, &index);
          if (success) g_array_append_val (layer->item_path, index);
        }
      }
    } else if (kind == CHANNEL_PROPERTIES && (property == TEXT || property == GROUP || property == ITEM_PATH ||
        property == GROUP_FLAGS || property == VECTOR || property == LINK || property == TRANSFORM ||
        property == ARGUMENT || property == REGION || property == CLIP))
      success = fail (reader, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "Layer or effect fields occur inside channel metadata");
    else if (kind == CHANNEL_PROPERTIES && property == SELECTION) {
      GlimsXcfChannelFields *channel = target;
      if (size || channel->is_selection) success = fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Duplicate or incorrectly sized selection-channel marker");
      else channel->is_selection = TRUE;
    }
    else if (kind != IMAGE_PROPERTIES && property == TATTOO) {
      guint32 tattoo;
      if (size != 4 || tattoo_seen) success = fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Duplicate or incorrectly sized XCF tattoo");
      else if (!(success = read_u32 (reader, &tattoo))) { /* Preserve the read error. */ }
      else if (kind == LAYER_PROPERTIES) {
        Layer *layer = target;
        layer->fields.tattoo = tattoo; layer->fields.has_tattoo = TRUE;
      } else {
        GlimsXcfChannelFields *channel = target;
        channel->tattoo = tattoo; channel->has_tattoo = TRUE;
      }
      tattoo_seen = TRUE;
    } else if (kind == LAYER_PROPERTIES && property == PARASITES) success = parasites (reader, target);
    else success = skip_bytes (reader, size);
    if (success && reader->position < end) success = skip_bytes (reader, end - reader->position);
    reader->limit = previous_limit;
    if (!success) return FALSE;
  }
}

static gboolean
offset_table (Reader *reader, GArray *offsets)
{
  for (guint i = 0; i <= GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS; i++) {
    guint64 offset;
    if (!read_offset (reader, &offset)) return FALSE;
    if (!offset) return TRUE;
    if (!claim_offset (reader, offset, TRUE) || !charge (reader, sizeof offset)) return FALSE;
    g_array_append_val (offsets, offset);
  }
  return fail (reader, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "XCF offset-table limit exceeded");
}

static GlimsXcfEffectFieldsRecord *read_effect (Reader *reader, guint64 start);

static Channel *
read_channel (Reader *reader, guint64 start, gboolean allow_effects)
{
  Channel *channel = allocate (reader, sizeof *channel);
  if (!channel) return NULL;
  channel->effects = g_ptr_array_new_with_free_func (effect_free);
  GArray *effects = g_array_new (FALSE, FALSE, sizeof (guint64));
  guint64 hierarchy;
  if (!seek_record (reader, start) || !read_u32 (reader, &channel->fields.width) ||
      !read_u32 (reader, &channel->fields.height)) goto failed;
  if (!channel->fields.width || !channel->fields.height) {
    fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "XCF channel has empty dimensions"); goto failed;
  }
  if (!read_string (reader, &channel->fields.name) || !properties (reader, CHANNEL_PROPERTIES, &channel->fields) ||
      !read_offset (reader, &hierarchy) || !claim_offset (reader, hierarchy, FALSE)) goto failed;
  if (hierarchy < reader->position) {
    fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Channel hierarchy overlaps its metadata"); goto failed;
  }
  if (reader->version >= 26) {
    guint64 limit = reader->limit;
    reader->limit = hierarchy;
    gboolean valid = offset_table (reader, effects);
    reader->limit = limit;
    if (!valid) goto failed;
    if (!allow_effects && effects->len) {
      fail (reader, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "Nested effects on effect masks are unsupported"); goto failed;
    }
  } else if (!allow_effects && hierarchy != reader->position) {
    /* The pinned writer also reserves an empty channel FX table under older
     * headers. Native readers before26 ignore it; retain the existing strict
     * per-effect-mask rule without interpreting hierarchy or tile bytes. */
    guint64 nested;
    if (hierarchy - reader->position != 8) {
      fail (reader, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "Unsupported effect-mask metadata layout"); goto failed;
    }
    if (!read_offset (reader, &nested)) goto failed;
    if (nested) {
      fail (reader, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "Nested effects on effect masks are unsupported"); goto failed;
    }
  }
  if (!finish_record (reader, start)) goto failed;
  for (guint i = 0; i < effects->len; i++) {
    GlimsXcfEffectFieldsRecord *effect = read_effect (reader, g_array_index (effects, guint64, i));
    if (!effect) goto failed;
    if (!charge (reader, sizeof (gpointer))) { effect_free (effect); goto failed; }
    g_ptr_array_add (channel->effects, effect);
  }
  g_array_unref (effects);
  return channel;
failed:
  g_array_unref (effects);
  channel_free (channel);
  return NULL;
}

static GlimsXcfEffectFieldsRecord *
read_effect (Reader *reader, guint64 start)
{
  GlimsXcfEffectFieldsRecord *effect = allocate (reader, sizeof *effect);
  if (!effect) return NULL;
  guint64 mask;
  if (!seek_record (reader, start) || !read_string (reader, &effect->name) ||
      !read_string (reader, &effect->icon) || !read_string (reader, &effect->operation) ||
      !read_string (reader, &effect->operation_version) ||
      !properties (reader, EFFECT_PROPERTIES, effect) || !read_offset (reader, &mask)) goto failed;
  if (mask && !claim_offset (reader, mask, TRUE)) goto failed;
  if (!finish_record (reader, start)) goto failed;
  if (mask) {
    Channel *channel = read_channel (reader, mask, FALSE);
    if (!channel) goto failed;
    effect->mask_present = TRUE;
    effect->mask_name = g_steal_pointer (&channel->fields.name);
    effect->mask_width = channel->fields.width;
    effect->mask_height = channel->fields.height;
    effect->mask_tattoo = channel->fields.tattoo;
    effect->mask_has_tattoo = channel->fields.has_tattoo;
    channel_free (channel);
  }
  return effect;
failed:
  effect_free (effect);
  return NULL;
}

static Layer *
read_layer (Reader *reader, guint64 start)
{
  Layer *layer = allocate (reader, sizeof *layer);
  if (!layer) return NULL;
  layer->effects = g_ptr_array_new_with_free_func (effect_free);
  GArray *effects = g_array_new (FALSE, FALSE, sizeof (guint64));
  guint64 hierarchy, mask;
  if (!seek_record (reader, start) || !read_u32 (reader, &layer->fields.width) ||
      !read_u32 (reader, &layer->fields.height) || !read_u32 (reader, &layer->fields.xcf_type)) goto failed;
  if (!read_string (reader, &layer->fields.name) || !properties (reader, LAYER_PROPERTIES, layer)) goto failed;
  if ((!layer->fields.width || !layer->fields.height) && !(layer->fields.kind_flags & GLIMS_XCF_LAYER_GROUP)) {
    fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Ordinary XCF layer has empty dimensions"); goto failed;
  }
  if (!read_offset (reader, &hierarchy) ||
      (hierarchy && !claim_offset (reader, hierarchy, FALSE)) ||
      !read_offset (reader, &mask)) goto failed;
  if (!hierarchy && !(layer->fields.kind_flags & GLIMS_XCF_LAYER_GROUP)) {
    fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Ordinary XCF layer has no hierarchy"); goto failed;
  }
  if (mask && !claim_offset (reader, mask, TRUE)) goto failed;
  if (!offset_table (reader, effects) || !finish_record (reader, start)) goto failed;
  if (mask && !(layer->mask = read_channel (reader, mask, TRUE))) goto failed;
  for (guint i = 0; i < effects->len; i++) {
    GlimsXcfEffectFieldsRecord *effect = read_effect (reader, g_array_index (effects, guint64, i));
    if (!effect) goto failed;
    if (!charge (reader, sizeof (gpointer))) { effect_free (effect); goto failed; }
    g_ptr_array_add (layer->effects, effect);
  }
  g_array_unref (effects);
  return layer;
failed:
  g_array_unref (effects);
  layer_free (layer);
  return NULL;
}

static gboolean
read_image (Reader *reader, GlimsXcfEffectFields *fields)
{
  guint8 header[14] = {0};
  gsize count = (gsize) MIN (reader->size, sizeof header);
  if (!read_bytes (reader, header, count)) return FALSE;
  if ((count >= 2 && header[0] == 0x1f && header[1] == 0x8b) ||
      (count >= 3 && !memcmp (header, "BZh", 3)) ||
      (count >= 6 && !memcmp (header, "\xfd" "7zXZ\0", 6)))
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "Compressed XCF containers are unsupported");
  if (count < 9 || memcmp (header, "gimp xcf ", 9))
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_NOT_XCF, "Input is not an uncompressed XCF");
  if (count < 14 || header[13] != 0)
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Truncated or malformed XCF header");
  if (!memcmp (header + 9, "file", 4))
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "Legacy XCF versions are unsupported");
  if (header[9] != 'v' || !g_ascii_isdigit (header[10]) ||
      !g_ascii_isdigit (header[11]) || !g_ascii_isdigit (header[12]))
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "Malformed XCF version tag");
  fields->image.version = (header[10] - '0') * 100 + (header[11] - '0') * 10 + header[12] - '0';
  if (fields->image.version < 22 || fields->image.version > 26)
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "Only XCF versions 22 through 26 are supported");
  reader->version = fields->image.version;
  if (!read_u32 (reader, &fields->image.width) || !read_u32 (reader, &fields->image.height) ||
      !read_u32 (reader, &fields->image.base_type) || !read_u32 (reader, &fields->image.precision)) return FALSE;
  if (!fields->image.width || !fields->image.height)
    return fail (reader, GLIMS_XCF_EFFECT_FIELDS_MALFORMED, "XCF image has empty dimensions");
  if (!properties (reader, IMAGE_PROPERTIES, NULL)) return FALSE;
  GArray *layers = g_array_new (FALSE, FALSE, sizeof (guint64));
  GArray *channels = g_array_new (FALSE, FALSE, sizeof (guint64));
  gboolean success = FALSE;
  if (!offset_table (reader, layers) || !offset_table (reader, channels)) goto done;
  for (guint i = 0; i <= GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS; i++) {
    guint64 path;
    if (!read_offset (reader, &path)) goto done;
    if (!path) break;
    if (i == GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS) {
      fail (reader, GLIMS_XCF_EFFECT_FIELDS_BUDGET, "XCF path-offset table limit exceeded"); goto done;
    }
    if (!claim_offset (reader, path, FALSE)) goto done;
  }
  if (!finish_record (reader, 0)) goto done;
  for (guint i = 0; i < layers->len; i++) {
    Layer *layer = read_layer (reader, g_array_index (layers, guint64, i));
    if (!layer) goto done;
    if (!charge (reader, sizeof (gpointer))) { layer_free (layer); goto done; }
    g_ptr_array_add (fields->layers, layer);
  }
  for (guint i = 0; i < channels->len; i++) {
    Channel *channel = read_channel (reader, g_array_index (channels, guint64, i), TRUE);
    if (!channel) goto done;
    if (!charge (reader, sizeof (gpointer))) { channel_free (channel); goto done; }
    g_ptr_array_add (fields->channels, channel);
  }
  success = TRUE;
done:
  g_array_unref (layers);
  g_array_unref (channels);
  return success;
}

GlimsXcfEffectFields *
glims_xcf_effect_fields_read (GFile *file, GCancellable *cancellable, GError **error)
{
  if (!G_IS_FILE (file)) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "An XCF GFile is required");
    return NULL;
  }
  if (!g_file_is_native (file)) {
    g_set_error_literal (error, GLIMS_XCF_EFFECT_FIELDS_ERROR, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED,
                         "XCF metadata requires a local input file");
    return NULL;
  }
  GFileInputStream *stream = g_file_read (file, cancellable, error);
  if (!stream) return NULL;
  Reader reader = { .stream = stream, .cancellable = cancellable, .error = error };
  GlimsXcfEffectFields *fields = NULL;
  GFileInfo *info = g_file_input_stream_query_info (stream,
      G_FILE_ATTRIBUTE_STANDARD_SIZE "," G_FILE_ATTRIBUTE_STANDARD_TYPE, cancellable, error);
  if (!info) goto done;
  if (g_file_info_get_file_type (info) != G_FILE_TYPE_REGULAR ||
      !G_IS_SEEKABLE (stream) || !g_seekable_can_seek (G_SEEKABLE (stream)) || g_file_info_get_size (info) < 0) {
    fail (&reader, GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED, "XCF metadata requires a seekable regular file"); goto done;
  }
  reader.size = reader.limit = (guint64) g_file_info_get_size (info);
  reader.anchors = g_array_new (FALSE, FALSE, sizeof (guint64));
  reader.ranges = g_array_new (FALSE, FALSE, sizeof (Range));
  reader.claimed = g_hash_table_new_full (g_int64_hash, g_int64_equal, g_free, NULL);
  fields = allocate (&reader, sizeof *fields);
  if (!fields) goto done;
  fields->layers = g_ptr_array_new_with_free_func (layer_free);
  fields->channels = g_ptr_array_new_with_free_func (channel_free);
  if (!read_image (&reader, fields)) {
    glims_xcf_effect_fields_free (fields); fields = NULL;
  } else fields->bytes_read = reader.bytes_read;
done:
  g_clear_object (&info);
  if (reader.anchors) g_array_unref (reader.anchors);
  if (reader.ranges) g_array_unref (reader.ranges);
  if (reader.claimed) g_hash_table_unref (reader.claimed);
  GError *close_error = NULL;
  if (!g_input_stream_close (G_INPUT_STREAM (stream), NULL, &close_error)) {
    if (fields) { glims_xcf_effect_fields_free (fields); fields = NULL; g_propagate_error (error, close_error); }
    else g_clear_error (&close_error);
  }
  g_object_unref (stream);
  return fields;
}

const GlimsXcfImageFields *
glims_xcf_effect_fields_image (const GlimsXcfEffectFields *fields)
{
  return fields ? &fields->image : NULL;
}

guint
glims_xcf_effect_fields_layer_count (const GlimsXcfEffectFields *fields)
{
  return fields ? fields->layers->len : 0;
}

static Layer *
get_layer (const GlimsXcfEffectFields *fields, guint index)
{
  return fields && index < fields->layers->len ? g_ptr_array_index (fields->layers, index) : NULL;
}

const GlimsXcfLayerFields *
glims_xcf_effect_fields_layer (const GlimsXcfEffectFields *fields, guint index)
{
  Layer *layer = get_layer (fields, index);
  return layer ? &layer->fields : NULL;
}

const GArray *
glims_xcf_effect_fields_layer_item_path (const GlimsXcfEffectFields *fields, guint index)
{
  Layer *layer = get_layer (fields, index);
  return layer ? layer->item_path : NULL;
}

guint
glims_xcf_effect_fields_effect_count (const GlimsXcfEffectFields *fields, guint index)
{
  Layer *layer = get_layer (fields, index);
  return layer ? layer->effects->len : 0;
}

const GlimsXcfEffectFieldsRecord *
glims_xcf_effect_fields_effect (const GlimsXcfEffectFields *fields, guint index, guint effect)
{
  Layer *layer = get_layer (fields, index);
  return layer && effect < layer->effects->len ? g_ptr_array_index (layer->effects, effect) : NULL;
}

const GlimsXcfChannelFields *
glims_xcf_effect_fields_layer_mask (const GlimsXcfEffectFields *fields, guint index)
{
  Layer *layer = get_layer (fields, index);
  return layer && layer->mask ? &layer->mask->fields : NULL;
}

guint
glims_xcf_effect_fields_layer_mask_effect_count (const GlimsXcfEffectFields *fields, guint index)
{
  Layer *layer = get_layer (fields, index);
  return layer && layer->mask ? layer->mask->effects->len : 0;
}

const GlimsXcfEffectFieldsRecord *
glims_xcf_effect_fields_layer_mask_effect (const GlimsXcfEffectFields *fields, guint index, guint effect)
{
  Layer *layer = get_layer (fields, index);
  return layer && layer->mask && effect < layer->mask->effects->len
    ? g_ptr_array_index (layer->mask->effects, effect) : NULL;
}

static Channel *
get_channel (const GlimsXcfEffectFields *fields, guint index)
{
  return fields && index < fields->channels->len ? g_ptr_array_index (fields->channels, index) : NULL;
}

guint
glims_xcf_effect_fields_channel_count (const GlimsXcfEffectFields *fields)
{
  return fields ? fields->channels->len : 0;
}

const GlimsXcfChannelFields *
glims_xcf_effect_fields_channel (const GlimsXcfEffectFields *fields, guint index)
{
  Channel *channel = get_channel (fields, index);
  return channel ? &channel->fields : NULL;
}

guint
glims_xcf_effect_fields_channel_effect_count (const GlimsXcfEffectFields *fields, guint index)
{
  Channel *channel = get_channel (fields, index);
  return channel ? channel->effects->len : 0;
}

const GlimsXcfEffectFieldsRecord *
glims_xcf_effect_fields_channel_effect (const GlimsXcfEffectFields *fields, guint index, guint effect)
{
  Channel *channel = get_channel (fields, index);
  return channel && effect < channel->effects->len ? g_ptr_array_index (channel->effects, effect) : NULL;
}

guint64
glims_xcf_effect_fields_bytes_read (const GlimsXcfEffectFields *fields)
{
  return fields ? fields->bytes_read : 0;
}

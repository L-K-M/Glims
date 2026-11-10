/* Strict, bounded data-only format. Native correspondence is checked separately. */
#include "effect-archive.h"
#include <string.h>

static gboolean
invalid (GError **error, const char *message)
{
  g_set_error_literal (error, G_KEY_FILE_ERROR, G_KEY_FILE_ERROR_INVALID_VALUE, message);
  return FALSE;
}

static gboolean
hash_valid (const char *text)
{
  if (!text || strlen (text) != 64) return FALSE;
  for (guint i = 0; i < 64; i++)
    if (!(text[i] >= '0' && text[i] <= '9') && !(text[i] >= 'a' && text[i] <= 'f'))
      return FALSE;
  return TRUE;
}

static gboolean
symbol_valid (const char *text)
{
  if (!text || !*text || strlen (text) > 96) return FALSE;
  for (const char *p = text; *p; p++)
    if (!g_ascii_isalnum (*p) && *p != '-' && *p != '_') return FALSE;
  return TRUE;
}

void
glims_effect_archive_record_free (gpointer data)
{
  GlimsEffectArchiveRecord *record = data;
  if (!record) return;
  g_free (record->fingerprint);
  g_free (record->blend_space);
  g_free (record->composite_space);
  g_free (record->composite_mode);
  g_free (record);
}

GlimsEffectArchive *
glims_effect_archive_new (void)
{
  GlimsEffectArchive *archive = g_new0 (GlimsEffectArchive, 1);
  archive->records = g_ptr_array_new_with_free_func (glims_effect_archive_record_free);
  return archive;
}

void
glims_effect_archive_free (GlimsEffectArchive *archive)
{
  if (!archive) return;
  g_free (archive->scope);
  g_ptr_array_unref (archive->records);
  g_free (archive);
}

static gboolean
record_valid (const GlimsEffectArchiveRecord *r)
{
  return r && r->tattoo && r->index < GLIMS_EFFECT_ARCHIVE_MAX_RECORDS &&
    hash_valid (r->fingerprint) && symbol_valid (r->blend_space) &&
    symbol_valid (r->composite_space) && symbol_valid (r->composite_mode) &&
    r->identities <= GLIMS_EFFECT_ARCHIVE_NO_CURVES;
}

static gboolean
unique_target (const GlimsEffectArchive *archive, guint index)
{
  const GlimsEffectArchiveRecord *a = g_ptr_array_index (archive->records, index);
  for (guint i = 0; i < index; i++) {
    const GlimsEffectArchiveRecord *b = g_ptr_array_index (archive->records, i);
    if (a->tattoo == b->tattoo && a->index == b->index) return FALSE;
  }
  return TRUE;
}

static gboolean
archive_valid (const GlimsEffectArchive *archive, GError **error)
{
  if (!archive || !archive->records || !hash_valid (archive->scope) ||
      archive->records->len > GLIMS_EFFECT_ARCHIVE_MAX_RECORDS)
    return invalid (error, "Invalid or oversized Glims effect archive.");
  for (guint i = 0; i < archive->records->len; i++)
    if (!record_valid (g_ptr_array_index (archive->records, i)) || !unique_target (archive, i))
      return invalid (error, "Invalid or duplicate Glims effect archive record.");
  return TRUE;
}

gboolean
glims_effect_archive_encode (const GlimsEffectArchive *archive,
                             gchar **bytes, gsize *length, GError **error)
{
  *bytes = NULL; *length = 0;
  if (!archive_valid (archive, error)) return FALSE;
  GKeyFile *file = g_key_file_new ();
  g_key_file_set_uint64 (file, "archive", "version", 1);
  g_key_file_set_uint64 (file, "archive", "count", archive->records->len);
  g_key_file_set_string (file, "archive", "scope", archive->scope);
  for (guint i = 0; i < archive->records->len; i++) {
    const GlimsEffectArchiveRecord *r = g_ptr_array_index (archive->records, i);
    gchar group[32]; g_snprintf (group, sizeof group, "effect%u", i);
    g_key_file_set_uint64 (file, group, "tattoo", r->tattoo);
    g_key_file_set_uint64 (file, group, "index", r->index);
    g_key_file_set_string (file, group, "fingerprint", r->fingerprint);
    g_key_file_set_string (file, group, "blend", r->blend_space);
    g_key_file_set_string (file, group, "composite-space", r->composite_space);
    g_key_file_set_string (file, group, "composite-mode", r->composite_mode);
    g_key_file_set_uint64 (file, group, "identities", r->identities);
  }
  gchar *data = g_key_file_to_data (file, length, error);
  g_key_file_unref (file);
  if (!data) return FALSE;
  if (*length > GLIMS_EFFECT_ARCHIVE_MAX_BYTES) {
    g_free (data); *length = 0;
    return invalid (error, "The Glims effect archive exceeds its size limit.");
  }
  *bytes = data;
  return TRUE;
}

static gboolean
keys_exact (GKeyFile *file, const char *group, const char *const *expected, gsize count)
{
  gsize actual = 0; gchar **keys = g_key_file_get_keys (file, group, &actual, NULL);
  gboolean valid = keys && actual == count;
  for (gsize i = 0; valid && i < count; i++)
    valid = g_key_file_has_key (file, group, expected[i], NULL);
  g_strfreev (keys);
  return valid;
}

static gboolean
read_uint (GKeyFile *file, const char *group, const char *key, guint32 *out)
{
  GError *error = NULL;
  guint64 value = g_key_file_get_uint64 (file, group, key, &error);
  gboolean valid = !error && value <= G_MAXUINT32;
  g_clear_error (&error);
  if (valid) *out = (guint32) value;
  return valid;
}

/* GKeyFile merges repeated group sections, including empty repetitions.
 * Reject those in the original bounded text before that information is lost. */
static gboolean
groups_unique (const void *bytes, gsize length)
{
  gchar *text = g_strndup (bytes, length);
  gchar **lines = g_strsplit (text, "\n", -1);
  GHashTable *seen = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  gboolean unique = TRUE;
  for (guint i = 0; unique && lines[i]; i++) {
    gchar *line = g_strstrip (lines[i]); gsize size = strlen (line);
    if (size >= 2 && line[0] == '[' && line[size - 1] == ']') {
      gchar *group = g_strndup (line + 1, size - 2);
      unique = g_hash_table_add (seen, group);
    }
  }
  g_hash_table_unref (seen); g_strfreev (lines); g_free (text);
  return unique;
}

GlimsEffectArchive *
glims_effect_archive_decode (const void *bytes, gsize length, GError **error)
{
  static const char *const header_keys[] = {"version", "count", "scope"};
  static const char *const record_keys[] = {"tattoo", "index", "fingerprint", "blend",
                                          "composite-space", "composite-mode", "identities"};
  if (!bytes || !length || length > GLIMS_EFFECT_ARCHIVE_MAX_BYTES || memchr (bytes, 0, length)) {
    invalid (error, "Invalid or oversized Glims effect archive data."); return NULL;
  }
  if (!groups_unique (bytes, length)) {
    invalid (error, "Duplicate Glims effect archive group."); return NULL;
  }
  GKeyFile *file = g_key_file_new ();
  GlimsEffectArchive *archive = NULL;
  guint32 version = 0, count = 0; gsize group_count = 0;
  if (!g_key_file_load_from_data (file, bytes, length, G_KEY_FILE_NONE, error)) goto done;
  gchar **groups = g_key_file_get_groups (file, &group_count);
  g_strfreev (groups);
  if (!keys_exact (file, "archive", header_keys, G_N_ELEMENTS (header_keys)) ||
      !read_uint (file, "archive", "version", &version) || version != 1 ||
      !read_uint (file, "archive", "count", &count) || count > GLIMS_EFFECT_ARCHIVE_MAX_RECORDS ||
      group_count != (gsize) count + 1) {
    invalid (error, "Unknown version or invalid Glims effect archive header."); goto done;
  }
  archive = glims_effect_archive_new ();
  archive->scope = g_key_file_get_string (file, "archive", "scope", NULL);
  for (guint i = 0; i < count; i++) {
    gchar group[32]; g_snprintf (group, sizeof group, "effect%u", i);
    if (!keys_exact (file, group, record_keys, G_N_ELEMENTS (record_keys))) {
      invalid (error, "Invalid Glims effect archive keys."); goto failed;
    }
    GlimsEffectArchiveRecord *r = g_new0 (GlimsEffectArchiveRecord, 1);
    g_ptr_array_add (archive->records, r);
    if (!read_uint (file, group, "tattoo", &r->tattoo) ||
        !read_uint (file, group, "index", &r->index) ||
        !read_uint (file, group, "identities", &r->identities)) {
      invalid (error, "Invalid Glims effect archive integer."); goto failed;
    }
    r->fingerprint = g_key_file_get_string (file, group, "fingerprint", NULL);
    r->blend_space = g_key_file_get_string (file, group, "blend", NULL);
    r->composite_space = g_key_file_get_string (file, group, "composite-space", NULL);
    r->composite_mode = g_key_file_get_string (file, group, "composite-mode", NULL);
  }
  if (!archive_valid (archive, error)) goto failed;
  goto done;
failed:
  glims_effect_archive_free (archive); archive = NULL;
done:
  g_key_file_unref (file);
  return archive;
}

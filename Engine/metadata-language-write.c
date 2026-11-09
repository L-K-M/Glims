/* Detached single-language edit preparation. No facade or image commit. */
#include "engine-private.h"
#include "metadata-language.h"
#include "metadata-language-write.h"
#include "metadata-normalization.h"
#include "metadata-preservation.h"
#include "metadata-inventory.h"
#include "core/gimpimage.h"
#include "core/gimpimage-metadata.h"
#include <string.h>

static GlimsStatus
unsupported (char **error, const char *message)
{
  if (error) *error = g_strdup (message);
  return GLIMS_STATUS_UNSUPPORTED;
}

/* Admission precedes ANY metadata duplication. Registry-only type lookup
 * cannot prove an imported value's actual type. Non-LangAlt native vectors
 * therefore refuse empty values and LangAlt-looking pretty strings as well
 * as unregistered/nested properties. This is intentionally conservative. */
static GlimsStatus
read_maps (GimpMetadata *metadata, GHashTable **out, char **error)
{
  char **tags = gexiv2_metadata_get_xmp_tags (GEXIV2_METADATA (metadata));
  GHashTable *maps = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, (GDestroyNotify) g_ptr_array_unref);
  GlimsStatus status = GLIMS_STATUS_OK;
  gsize full_count = 0;
  guint i;
  *out = NULL;
  status = glims_metadata_xmp_entry_count (GEXIV2_METADATA (metadata), &full_count, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (full_count != (tags ? g_strv_length (tags) : 0))
    { status = unsupported (error, "Empty XMP entries cannot be enumerated for a lossless metadata copy."); goto done; }
  if (tags && g_strv_length (tags) > 4096)
    { status = unsupported (error, "Too many XMP properties to verify safely."); goto done; }
  for (i = 0; tags && tags[i]; i++)
    {
      const char *dot = g_str_has_prefix (tags[i], "Xmp.") ? strchr (tags[i] + 4, '.') : NULL;
      const char *type;
      GError *failure = NULL;
      if (!dot || dot == tags[i] + 4 || !dot[1] || strpbrk (dot + 1, ".[]/:?"))
        { status = unsupported (error, "Nested XMP properties cannot be verified for this edit."); goto done; }
      type = gexiv2_metadata_try_get_tag_type (tags[i], &failure);
      if (!type || failure)
        {
          g_clear_error (&failure);
          status = unsupported (error, "Unregistered XMP properties cannot be verified for this edit.");
          goto done;
        }
      if (!strcmp (type, "LangAlt"))
        {
          GPtrArray *pairs = NULL;
          status = glims_metadata_language_read (metadata, tags[i], &pairs, error);
          if (status != GLIMS_STATUS_OK) goto done;
          g_hash_table_insert (maps, g_strdup (tags[i]), pairs);
        }
      else
        {
          char **values;
          guint j;
          gboolean admitted = !strcmp (type, "XmpText") || !strcmp (type, "XmpBag") ||
                              !strcmp (type, "XmpSeq") || !strcmp (type, "XmpAlt");
          if (!admitted)
            { status = unsupported (error, "This XMP value kind cannot be verified for this edit."); goto done; }
          values = gexiv2_metadata_try_get_tag_multiple (GEXIV2_METADATA (metadata), tags[i], &failure);
          if (!values || failure)
            {
              status = glims_fail (error, g_steal_pointer (&failure), "An unrelated XMP value could not be read.");
              g_strfreev (values);
              goto done;
            }
          admitted = values[0] && g_strv_length (values) <= 256;
          for (j = 0; admitted && values[j]; j++)
            admitted = *values[j] && strlen (values[j]) <= 1024 * 1024 && g_utf8_validate (values[j], -1, NULL)
                       && !g_str_has_prefix (values[j], "lang=");
          g_strfreev (values);
          if (!admitted)
            { status = unsupported (error, "An empty or ambiguous unrelated XMP value cannot be preserved safely."); goto done; }
        }
    }
  *out = maps;
  maps = NULL;
done:
  if (maps) g_hash_table_unref (maps);
  g_strfreev (tags);
  return status;
}

static const char *
pair_text (GPtrArray *pairs, const char *language)
{
  guint i;
  for (i = 0; pairs && i < pairs->len; i++)
    {
      GlimsMetadataLanguagePair *pair = g_ptr_array_index (pairs, i);
      if (!strcmp (pair->language, language)) return pair->text;
    }
  return NULL;
}

static gboolean
maps_equal (GHashTable *before, GHashTable *after, const char *root, const char *language, const char *text)
{
  GHashTableIter iter;
  gpointer key, value;
  if (g_hash_table_size (before) != g_hash_table_size (after)) return FALSE;
  g_hash_table_iter_init (&iter, before);
  while (g_hash_table_iter_next (&iter, &key, &value))
    {
      GPtrArray *old = value, *now = g_hash_table_lookup (after, key);
      guint i;
      if (!now || old->len != now->len) return FALSE;
      for (i = 0; i < old->len; i++)
        {
          GlimsMetadataLanguagePair *pair = g_ptr_array_index (old, i);
          const char *expected = root && !strcmp (root, key) && !strcmp (language, pair->language) ? text : pair->text;
          if (g_strcmp0 (pair_text (now, pair->language), expected)) return FALSE;
        }
    }
  return TRUE;
}

static gboolean
verified_copy (GimpMetadata *baseline, GimpMetadata *candidate, GHashTable *maps)
{
  GHashTable *actual = NULL;
  gboolean valid = candidate && glims_metadata_equal_native (baseline, candidate) &&
                   read_maps (candidate, &actual, NULL) == GLIMS_STATUS_OK && maps_equal (maps, actual, NULL, NULL, NULL);
  if (actual) g_hash_table_unref (actual);
  return valid;
}

GlimsStatus
glims_metadata_language_prepare (GimpImage *image, const char *root, const char *language, const char *text,
                                  GimpMetadata **out, char **error)
{
  GimpMetadata *current, *copy = NULL, *normalized = NULL, *restored = NULL, *roundtrip = NULL;
  GPtrArray *target = NULL;
  GHashTable *maps = NULL, *changed = NULL;
  GError *failure = NULL;
  GlimsStatus status;
  const char *old_text;
  char *assignment = NULL, *restore_assignment = NULL;
  if (out) *out = NULL;
  if (!image || !out || !root || !language || !*language || !text || !*text ||
      strlen (language) > 255 || strlen (text) > 1024 * 1024 ||
      !g_utf8_validate (language, -1, NULL) || !g_utf8_validate (text, -1, NULL))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  current = gimp_image_get_metadata (image);
  if (!current) return GLIMS_STATUS_NOT_FOUND;
  status = glims_metadata_language_read (current, root, &target, error);
  if (status != GLIMS_STATUS_OK) goto done;
  old_text = pair_text (target, language);
  if (!old_text) { status = GLIMS_STATUS_NOT_FOUND; goto done; }
  if (!strcmp (old_text, text)) { status = GLIMS_STATUS_OK; goto done; }
  status = read_maps (current, &maps, error);
  if (status != GLIMS_STATUS_OK) goto done;
  copy = gimp_metadata_duplicate (current);
  if (!verified_copy (current, copy, maps)) goto cannot_preserve;
  /* Refuse a source whose own image facts would change on native install
   * or Undo. Do not discover that change after attachment. */
  normalized = gimp_metadata_duplicate (copy);
  if (!verified_copy (copy, normalized, maps)) goto cannot_preserve;
  status = glims_metadata_normalize_private_copy (image, normalized, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (!verified_copy (current, normalized, maps)) goto cannot_preserve;
  assignment = g_strdup_printf ("lang=\"%s\" %s", language, text);
  if (!gexiv2_metadata_try_set_tag_string (GEXIV2_METADATA (copy), root, assignment, &failure) || failure)
    { status = glims_fail (error, g_steal_pointer (&failure), "The language text could not be prepared."); goto done; }
  status = read_maps (copy, &changed, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (!maps_equal (maps, changed, root, language, text)) goto cannot_preserve;
  roundtrip = gimp_metadata_duplicate (copy);
  if (!verified_copy (copy, roundtrip, changed)) goto cannot_preserve;
  status = glims_metadata_normalize_private_copy (image, roundtrip, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (!verified_copy (copy, roundtrip, changed)) goto cannot_preserve;
  /* Restore just the old text on a disposable candidate. A full native
   * comparison must then equal the original, including unrelated data. */
  restored = gimp_metadata_duplicate (copy);
  if (!verified_copy (copy, restored, changed)) goto cannot_preserve;
  restore_assignment = g_strdup_printf ("lang=\"%s\" %s", language, old_text);
  if (!gexiv2_metadata_try_set_tag_string (GEXIV2_METADATA (restored), root, restore_assignment, &failure) || failure)
    { status = glims_fail (error, g_steal_pointer (&failure), "Unrelated metadata could not be verified."); goto done; }
  if (!verified_copy (current, restored, maps)) goto cannot_preserve;
  *out = copy;
  copy = NULL;
  status = GLIMS_STATUS_OK;
  goto done;
cannot_preserve:
  status = unsupported (error, "This language edit cannot preserve all metadata through normalization, Undo and save; the image was left untouched.");
done:
  if (target) g_ptr_array_unref (target);
  if (maps) g_hash_table_unref (maps);
  if (changed) g_hash_table_unref (changed);
  if (copy) g_object_unref (copy);
  if (normalized) g_object_unref (normalized);
  if (restored) g_object_unref (restored);
  if (roundtrip) g_object_unref (roundtrip);
  g_free (assignment);
  g_free (restore_assignment);
  g_clear_error (&failure);
  return status;
}

/*
 * Facade slots 139/140: the public READ-ONLY language-alternative
 * (XMP LangAlt) map. The parser stays private and sealed in
 * Engine/metadata-language.c; this file only borrows the image's own
 * metadata, delegates to the accepted reader and translates its owned
 * pairs into the facade's own array. No writer, no generic-metadata
 * policy change, no BUSY gate: a read is allowed at any time.
 */
#include "engine-private.h"
#include "metadata-language.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-metadata.h"

GlimsStatus
glims_image_metadata_languages (GlimsEngine                  *e,
                                GlimsImageID                  image,
                                const char                   *root,
                                GlimsMetadataLanguageValue **out,
                                int32_t                      *out_count,
                                char                        **error)
{
  GlimsOpenImage *open;
  GimpMetadata   *metadata;
  GPtrArray      *pairs = NULL;
  GlimsMetadataLanguageValue *values;
  GlimsStatus     status;
  guint           i, n;

  if (out)
    *out = NULL;
  if (out_count)
    *out_count = 0;
  if (! out || ! out_count || ! root)
    {
      if (error)
        *error = strdup ("Needs an out array, a count and a root tag.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  open = glims_lookup_image (e, image);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  /* Borrowed; NULL when the image carries no metadata at all. Absent
   * metadata is NOT_FOUND and never creates any. */
  metadata = gimp_image_get_metadata (open->image);
  if (! metadata)
    {
      if (error)
        *error = strdup ("The image carries no metadata.");
      return GLIMS_STATUS_NOT_FOUND;
    }

  status = glims_metadata_language_read (metadata, root, &pairs, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* Translate the reader's owned pairs into the facade's own array. The
   * strings are copied (the reader's array owns its own copies); a
   * partial allocation frees everything it made and publishes nothing.
   * The calloc'd terminator pair stays all-NULL (both fields). */
  n = pairs->len;
  values = calloc ((gsize) n + 1, sizeof *values);
  if (! values)
    {
      if (error)
        *error = strdup ("The language-alternative array could not be allocated.");
      g_ptr_array_unref (pairs);
      return GLIMS_STATUS_FAILED;
    }
  for (i = 0; i < n; i++)
    {
      GlimsMetadataLanguagePair *pair = g_ptr_array_index (pairs, i);

      values[i].language = strdup (pair->language);
      values[i].text = strdup (pair->text);
      if (! values[i].language || ! values[i].text)
        {
          guint j;

          if (error)
            *error = strdup ("A language-alternative string could not be copied.");
          for (j = 0; j <= i; j++)
            {
              free (values[j].language);
              free (values[j].text);
            }
          free (values);
          g_ptr_array_unref (pairs);
          return GLIMS_STATUS_FAILED;
        }
    }
  g_ptr_array_unref (pairs);

  *out = values;
  *out_count = (int32_t) n;
  return GLIMS_STATUS_OK;
}

void
glims_metadata_languages_free (GlimsMetadataLanguageValue *values)
{
  GlimsMetadataLanguageValue *p;

  if (! values)
    return;
  for (p = values; p->language || p->text; p++)
    {
      free (p->language);
      free (p->text);
    }
  free (values);
}

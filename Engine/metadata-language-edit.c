/*
 * Facade slot 141: the WRITE path for one registered XMP LangAlt root
 * property. The preflight (detached copy + normalization + preservation
 * + roundtrip fidelity) is the sealed Engine/metadata-language-write.c;
 * this file only looks the image up, runs that preflight and, when it
 * produced an owned copy, applies it through the one native setter.
 * No frontend copy or normalization fiddling.
 */
#include "engine-private.h"
#include "metadata-language-write.h"

#include "core/gimpimage.h"
#include "core/gimpimage-metadata.h"

GlimsStatus
glims_image_metadata_edit_language (GlimsEngine     *engine,
                                    GlimsImageID     image,
                                    const char      *root,
                                    const char      *language,
                                    const char      *text,
                                    char           **error)
{
  GlimsOpenImage *open;
  GimpMetadata   *copy = NULL;
  GlimsStatus     status;

  open = glims_lookup_image (engine, image);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  /* The preflight owns every refusal: unknown/nested/empty or ambiguous
   * XMP representations, a missing root/language key, invalid arguments
   * and any copy that cannot be preserved through Undo and save. A
   * refusal leaves the image untouched and *out NULL. */
  status = glims_metadata_language_prepare (open->image, root, language, text,
                                            &copy, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* OK + NULL copy is an exact no-op: return BEFORE the readiness gate,
   * with no undo and no history, even while a stroke, a filter preview
   * or a plug-in holds the image. */
  if (! copy)
    return GLIMS_STATUS_OK;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    {
      g_object_unref (copy);
      return status;
    }

  /* The single native setter: takes its own reference on the copy and
   * pushes exactly one GIMP_UNDO_IMAGE_METADATA step (the copy is never
   * the image's own object), then runs the documented normalization.
   * The adapter's local reference ends here. */
  gimp_image_set_metadata (open->image, copy, TRUE);
  g_object_unref (copy);

  return GLIMS_STATUS_OK;
}

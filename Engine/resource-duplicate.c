/*
 * Saved-resource duplication (facade slot 131, resource_duplicate): one
 * current brush, pattern or gradient of the engine's own resource
 * catalogs is copied through the engine's per-class copy
 * (gimp_data_duplicate, transfer full, NULL when the class cannot be
 * copied), named with the requested label, persisted with the same
 * checked staging pipeline as resource_create_pixels
 * (glims_resource_save_and_publish) into the configured writable data
 * folder under the duplicated subclass's own native extension
 * (gimp_data_get_extension: .gbr/.vbr/.gih/.pat/.ggr), and only then
 * published to the factory of the source's own kind.
 *
 * Source-only semantics, verified against all four engine trees
 * (identical declarations and class vfuncs in 3.2.8, 3.2.0, 3.0.8 and
 * master): gimp_data_duplicate() (gimpdata.c) runs the class duplicate
 * or copy vfunc — gimp_brush_copy deep-copies the owned mask/pixmap
 * TempBufs, gimp_brush_generated_copy copies the parametric fields,
 * gimp_brush_pipe_copy duplicates each child brush into owned objects,
 * gimp_brush_clipboard_duplicate produces a plain bitmap brush,
 * gimp_pattern_copy deep-copies the mask TempBuf, gimp_gradient_copy
 * deep-copies every segment including its colors and stop types — then
 * clears the file and name and sets writable from the class's save
 * vfunc. No source field is mutated, no payload is shared with the
 * source, no global context or clipboard is read or changed, and the
 * gradient's dynamic FG/BG stop types stay native (never flattened).
 * The source itself need not be writable: a built-in read-only
 * resource is duplicatable when gimp_data_is_duplicatable() says so
 * and the private copy is saveable. The factory convenience
 * gimp_data_factory_data_duplicate is NOT used: it saves unchecked and
 * publishes despite a failed save (gimpdatafactory.c).
 *
 * The source handle is resolved exactly once per call through
 * glims_lookup_resource_data() (the same narrow admission as
 * lookup_resource(): INVALID_ARGUMENT for 0 and out-of-native-range
 * handles before any narrowing, NOT_FOUND for stale, foreign or
 * non-current-factory members). The factory convenience admission of
 * the create path is reused for the BUSY gate. No image, undo history,
 * selection, context or clipboard is touched, and the source is never
 * renamed, saved, deleted or dirtied. `outID` is zeroed first and on
 * every failure.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpbrushpipe.h"
#include "core/gimpbrushgenerated.h"
#include "core/gimpcontainer.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpobject.h"
#include "core/gimpgradient.h"
#include "core/gimppattern.h"
#include "core/gimptempbuf.h"

GlimsStatus
glims_resource_duplicate (GlimsEngine     *e,
                           GlimsResourceID  sourceID,
                           const char      *name,
                           GlimsResourceID *outID,
                           char           **error)
{
  GimpDataFactory      *factory;
  GimpContainer        *container;
  GimpData             *source = NULL;
  GimpData             *copy   = NULL;
  GlimsResourceStaging  staging;
  GlimsStatus           status;

  if (outID)
    *outID = 0;

  /* Admission, all before any mutation — the same order as
   * resource_create_pixels. */
  if (! outID)
    {
      if (error)
        *error = strdup ("The id output is required.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (! glims_valid_resource_name (name))
    {
      if (error)
        *error = strdup ("The resource name must be nonempty UTF-8 without control "
                         "characters, at most 255 bytes.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* No image argument: refuse the engine-global busy flag and ANY
   * active stroke or filter session, on any image. */
  if (e->busy > 0 ||
      g_hash_table_size (e->strokes) > 0 ||
      g_hash_table_size (e->filters) > 0)
    return GLIMS_STATUS_BUSY;

  /* Resolve the source once, with the shared typed admission: 0 and
   * out-of-native-range handles (high bits, above G_MAXINT) are
   * INVALID_ARGUMENT, stale/foreign/non-current-factory members
   * NOT_FOUND. The borrowed source is only read below. */
  status = glims_lookup_resource_data (e, sourceID, &source);
  if (status == GLIMS_STATUS_INVALID_ARGUMENT)
    {
      if (error)
        *error = strdup ("This handle cannot name a resource.");
      return status;
    }
  if (status != GLIMS_STATUS_OK)
    {
      if (error)
        *error = strdup ("No current brush, pattern or gradient carries this handle.");
      return status;
    }

  /* Native capability first: a class without a copy/duplicate vfunc
   * (e.g. a MyPaint brush) is refused actionably, and an empty pipe
   * brush would crash the native pipe copy (pipe->current deref), so
   * it is refused here too. The source's writability is NOT required:
   * a built-in read-only resource may still be duplicatable. */
  if (! gimp_data_is_duplicatable (source) ||
      (GIMP_IS_BRUSH_PIPE (source) && GIMP_BRUSH_PIPE (source)->n_brushes < 1))
    {
      if (error)
        *error = strdup ("The engine cannot duplicate this resource: its kind has no "
                         "native copy, or it is an empty pipe.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  factory   = glims_factory_for_resource (e->gimp, source);
  container = gimp_data_factory_get_container (factory);

  /* Exact same-kind name collision refused before any filesystem
   * mutation; the unique-names container would silently uniquify. */
  if (glims_resource_name_taken (container, name))
    return glims_fail (error, NULL, "A resource with this name already exists.");

  /* The owned private copy: per-class copy semantics, cleared file and
   * name, writable iff the class has a save vfunc. The source is only
   * read, never mutated. */
  copy = gimp_data_duplicate (source);
  if (! copy)
    {
      if (error)
        *error = strdup ("The engine could not copy this resource.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* The private copy must be saveable for a SAVED duplicate. */
  if (! gimp_data_is_writable (copy))
    {
      g_object_unref (copy);
      if (error)
        *error = strdup ("The duplicated resource cannot be saved by the engine.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* The VBR and GGR loaders strip surrounding ASCII whitespace from names.
   * A successful native save would therefore change identity on restart. */
  if ((GIMP_IS_BRUSH_GENERATED (copy) || GIMP_IS_GRADIENT (copy)) &&
      (g_ascii_isspace (name[0]) || g_ascii_isspace (name[strlen (name) - 1])))
    {
      g_object_unref (copy);
      if (error) *error = strdup ("This resource format cannot preserve spaces at the start or end of its name.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* PAT writes raw bytes and only stores a component count. Its loader
   * reconstructs exactly these four encodings, with no profile/precision
   * metadata. Clipboard patterns can use arbitrary formats: refusing them
   * preserves their source rather than saving an unloadable or reinterpreted
   * copy. Bitmap pixel creation already produces canonical RGBA u8. */
  if (GIMP_IS_PATTERN (copy))
    {
      GimpTempBuf *mask = GIMP_PATTERN (copy)->mask;
      const Babl *format = mask ? gimp_temp_buf_get_format (mask) : NULL;
      if (! format || (format != babl_format ("Y' u8") &&
                       format != babl_format ("Y'A u8") &&
                       format != babl_format ("R'G'B' u8") &&
                       format != babl_format ("R'G'B'A u8")))
        {
          g_object_unref (copy);
          if (error) *error = strdup ("This pattern's pixel format cannot be preserved in a saved PAT file.");
          return GLIMS_STATUS_UNSUPPORTED;
        }
    }

  /* The requested name is copied into the private object (this marks
   * it dirty, which the checked save below persists). */
  gimp_object_set_name (GIMP_OBJECT (copy), name);

  /* Stage into a unique owned hidden subdirectory of the configured
   * writable folder, with the duplicated subclass's OWN native
   * extension — .gbr for a bitmap brush, .vbr for a generated one,
   * .gih for a pipe, .pat, .ggr — exactly what its save vfunc writes
   * and its loader matches. */
  status = glims_resource_staging_begin (factory, gimp_data_get_extension (copy),
                                         &staging, error);
  if (status != GLIMS_STATUS_OK)
    {
      g_object_unref (copy);
      return status;
    }

  /* Checked save, no-overwrite promotion, exact-name publication —
   * the pipeline shared with resource_create_pixels. It owns `copy` on
   * every path from here on. */
  return glims_resource_save_and_publish (factory, copy, name, &staging, outID, error);
}

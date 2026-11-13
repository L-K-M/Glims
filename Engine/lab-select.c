/* Typed Lab selection admission. Geometry writes only the image's root mask;
 * authoritative Lab axes are neither sampled nor converted. */
#include "engine-private.h"
#include "plate-storage.h"
#include "lab-layer-storage.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"

static GlimsStatus
selection_refusal (GlimsStatus status, char **error, const char *message)
{
  if (error) *error = g_strdup (message);
  return status;
}

static GlimsStatus
lab_selection_ready (GlimsEngine *engine, GlimsImageID id, char **error)
{
  if (!engine) return GLIMS_STATUS_NOT_RUNNING;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;

  if (!open->component_document || open->component_mode != GLIMS_PLATE_MODE_LAB)
    return selection_refusal (GLIMS_STATUS_UNSUPPORTED, error,
                               "Choose a valid native Lab document for this selection.");
  if (open->component_layout == GLIMS_COMPONENT_LAYOUT_LAYERED_LAB)
    {
      g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
      if (!storage) return GLIMS_STATUS_FAILED;
      if (glims_lab_layer_storage_read (open->image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
        return selection_refusal (GLIMS_STATUS_UNSUPPORTED, error,
                                   "The layered Lab document's storage is invalid.");
    }
  else
    {
      GlimsPlateStorage storage;
      if (!glims_plate_storage_read_open (open, &storage) ||
          storage.map.mode != GLIMS_PLATE_MODE_LAB || storage.map.count != 3)
        return selection_refusal (GLIMS_STATUS_UNSUPPORTED, error,
                                   "Choose a valid native Lab document for this selection.");
    }

  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (!gimp_image_undo_is_enabled (open->image) ||
      gimp_image_get_undo_group_count (open->image))
    return selection_refusal (GLIMS_STATUS_BUSY, error,
                               "Finish the current Undo operation before changing the selection.");
  return GLIMS_STATUS_OK;
}

static gboolean
read_lab_options (const GlimsLabSelectOptions *input, GlimsSelectOptions *out)
{
  if (!input) return FALSE;
  uint32_t size;
  memcpy (&size, input, sizeof size);
  const size_t required = offsetof (GlimsLabSelectOptions, corner_radius) +
                          sizeof (((GlimsLabSelectOptions *) 0)->corner_radius);
  if (size < required) return FALSE;

  GlimsLabSelectOptions options = { 0 };
  memcpy (&options, input, required);
  if (options.operation > GLIMS_SELECT_INTERSECT || options.antialias > 1 ||
      !isfinite (options.feather) || options.feather < 0 ||
      options.feather > GLIMS_LAB_SELECT_RADIUS_LIMIT ||
      !isfinite (options.corner_radius) || options.corner_radius < 0 ||
      options.corner_radius > GLIMS_LAB_SELECT_RADIUS_LIMIT)
    return FALSE;

  *out = (GlimsSelectOptions) { .struct_size = sizeof *out,
    .operation = options.operation, .antialias = options.antialias != 0,
    .feather = options.feather, .corner_radius = options.corner_radius };
  return TRUE;
}

static gboolean
valid_lab_geometry (uint32_t shape, const GlimsPoint *points, size_t count)
{
  for (size_t i = 0; i < count; i++)
    if (!isfinite (points[i].x) || !isfinite (points[i].y) ||
        fabs (points[i].x) > GLIMS_LAB_SELECT_COORDINATE_LIMIT ||
        fabs (points[i].y) > GLIMS_LAB_SELECT_COORDINATE_LIMIT)
      return FALSE;

  if (shape == GLIMS_SHAPE_POLYGON) return TRUE;

  /* Check the legacy shape path's exact rounding before it casts to gint.
   * Keep off-canvas geometry intact; clipping ellipse bounds changes shape. */
  double x = floor (MIN (points[0].x, points[1].x));
  double y = floor (MIN (points[0].y, points[1].y));
  double right = ceil (MAX (points[0].x, points[1].x));
  double bottom = ceil (MAX (points[0].y, points[1].y));
  return x >= G_MININT && y >= G_MININT &&
         right <= G_MAXINT && bottom <= G_MAXINT &&
         right - x >= 1 && right - x <= G_MAXINT &&
         bottom - y >= 1 && bottom - y <= G_MAXINT;
}

GlimsStatus
glims_image_select_lab_shape (GlimsEngine *engine, GlimsImageID image,
                              uint32_t shape, const GlimsPoint *points,
                              size_t count, const GlimsLabSelectOptions *options,
                              char **error)
{
  if (error) *error = NULL;
  GlimsSelectOptions settings;
  if (!points || !read_lab_options (options, &settings))
    return selection_refusal (GLIMS_STATUS_INVALID_ARGUMENT, error,
                               "Use complete Lab selection settings with finite, supported values.");
  switch (shape)
    {
    case GLIMS_SHAPE_RECTANGLE:
    case GLIMS_SHAPE_ELLIPSE:
      if (count == 2) break;
      return selection_refusal (GLIMS_STATUS_INVALID_ARGUMENT, error,
                                 "A rectangle or ellipse needs exactly two opposite corners.");
    case GLIMS_SHAPE_POLYGON:
      if (count >= 3 && count <= GLIMS_LAB_SELECT_MAX_POINTS) break;
      return selection_refusal (GLIMS_STATUS_INVALID_ARGUMENT, error,
                                 "A Lab polygon selection needs 3 to 65536 vertices.");
    default:
      return selection_refusal (GLIMS_STATUS_INVALID_ARGUMENT, error,
                                 "Choose a rectangle, ellipse or polygon selection.");
    }

  GlimsStatus status = lab_selection_ready (engine, image, error);
  if (status != GLIMS_STATUS_OK) return status;

  /* At most 65536 two-double points. Copy before any typed access so callers
   * may use unaligned input. No borrowed storage survives this call. */
  GlimsPoint *owned = g_try_malloc_n (count, sizeof *owned);
  if (!owned)
    return selection_refusal (GLIMS_STATUS_FAILED, error,
                               "There is not enough memory for the selection outline.");
  memcpy (owned, points, count * sizeof *owned);
  if (!valid_lab_geometry (shape, owned, count))
    {
      g_free (owned);
      return selection_refusal (GLIMS_STATUS_INVALID_ARGUMENT, error,
                                 "Use finite selection coordinates within the supported range and positive bounds.");
    }

  /* No callbacks or nested main loop run between validation and the shared
   * mask operation. Native selection Undo/flush behavior remains unchanged. */
  status = glims_select_shape (engine, image, shape, owned, count, &settings);
  g_free (owned);
  return status;
}

GlimsStatus
glims_image_select_lab_command (GlimsEngine *engine, GlimsImageID image,
                                uint32_t command, char **error)
{
  if (error) *error = NULL;
  if (command != GLIMS_SELECT_ALL && command != GLIMS_SELECT_NONE &&
      command != GLIMS_SELECT_INVERT)
    return selection_refusal (GLIMS_STATUS_UNSUPPORTED, error,
                               "Lab documents support Select All, None and Invert here.");
  GlimsStatus status = lab_selection_ready (engine, image, error);
  if (status != GLIMS_STATUS_OK) return status;
  return glims_select_command (engine, image, command, 0.0, error);
}

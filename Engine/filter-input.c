/* Read-only filter inputs own detached tiles, never a live drawable graph. */
#include "filter-input.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimppickable.h"
#include "gegl/gimp-gegl-utils.h"

GlimsStatus
glims_filter_input_snapshot (GlimsEngine *engine, GlimsOpenImage *open,
                             GlimsItemID id, GeglNode **out, char **error)
{
  GimpDrawable *source;
  GeglBuffer *live = NULL, *snapshot = NULL;
  GeglNode *node = NULL;
  GlimsStatus status;
  if (out) *out = NULL;
  if (!out || !open || id <= 0) return GLIMS_STATUS_INVALID_ARGUMENT;
  /* An indexed image can mutate a shared Babl palette after a tile copy. */
  if (gimp_image_get_base_type (open->image) == GIMP_INDEXED) return GLIMS_STATUS_UNSUPPORTED;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  source = glims_lookup_drawable (open, id);
  if (!source) return GLIMS_STATUS_NOT_FOUND;
  g_object_ref (source);
  gimp_pickable_flush (GIMP_PICKABLE (source));
  live = gimp_drawable_get_buffer_with_effects (source); /* OWNED */
  if (!live) { status = glims_fail (error, NULL, "The source pixels could not be read."); goto done; }
  const GeglRectangle *extent = gegl_buffer_get_extent (live);
  gint bpp = babl_format_get_bytes_per_pixel (gegl_buffer_get_format (live));
  if (extent->width <= 0 || extent->height <= 0 || bpp <= 0 ||
      (uint64_t) extent->width * (uint64_t) extent->height > GLIMS_MAX_PIXEL_BUFFER_BYTES / (uint64_t) bpp) {
    status = glims_fail (error, NULL, "The source exceeds the 512 MiB pixel snapshot limit."); goto done;
  }
#if GIMP_CHECK_VERSION (3, 3, 0)
  snapshot = gimp_gegl_buffer_dup (live, NULL);
#else
  snapshot = gimp_gegl_buffer_dup (live);
#endif
  /* Dup validates graph-backed source tiles and separates storage through COW.
   * Release the live graph before a target preview can depend on this input. */
  g_clear_object (&live);
  if (!snapshot) { status = glims_fail (error, NULL, "The source pixels could not be copied."); goto done; }
  node = gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", snapshot, NULL);
  if (!node) { status = glims_fail (error, NULL, "The filter source could not be created."); goto done; }
  *out = node; node = NULL;
  status = GLIMS_STATUS_OK;
done:
  g_clear_object (&node); g_clear_object (&snapshot); g_clear_object (&live);
  g_object_unref (source);
  return status;
}

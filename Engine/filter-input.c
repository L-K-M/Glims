/* Read-only filter inputs own detached tiles, never a live drawable graph. */
#include "filter-input.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimppickable.h"
#include "gegl/gimp-gegl-utils.h"

static GlimsStatus
source_buffer (GimpDrawable *source, GeglBuffer **out, char **error)
{
  gimp_pickable_flush (GIMP_PICKABLE (source));
  *out = gimp_drawable_get_buffer_with_effects (source); /* OWNED */
  if (!*out) return glims_fail (error, NULL, "The source pixels could not be read.");
  return GLIMS_STATUS_OK;
}

/* Check division before multiplication. The byte count is the same native
 * format/extent policy as the original 512 MiB single-source snapshot limit. */
static gboolean
buffer_bytes (GeglBuffer *buffer, uint64_t remaining, uint64_t *bytes)
{
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  gint bpp = babl_format_get_bytes_per_pixel (gegl_buffer_get_format (buffer));
  if (extent->width <= 0 || extent->height <= 0 || bpp <= 0 ||
      (uint64_t) extent->width * (uint64_t) extent->height > remaining / (uint64_t) bpp)
    return FALSE;
  *bytes = (uint64_t) extent->width * (uint64_t) extent->height * (uint64_t) bpp;
  return TRUE;
}

/* The caller owns live and releases every live graph before preview attachment.
 * Dup validates graph-backed tiles and separates storage through COW. */
static GlimsStatus
copy_source_buffer (GeglBuffer *live, GeglNode **out, char **error)
{
  GeglBuffer *snapshot;
#if GIMP_CHECK_VERSION (3, 3, 0)
  snapshot = gimp_gegl_buffer_dup (live, NULL);
#else
  snapshot = gimp_gegl_buffer_dup (live);
#endif
  if (!snapshot) return glims_fail (error, NULL, "The source pixels could not be copied.");
  GeglNode *node = gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", snapshot, NULL);
  g_object_unref (snapshot);
  if (!node) return glims_fail (error, NULL, "The filter source could not be created.");
  *out = node;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_input_snapshot (GlimsEngine *engine, GlimsOpenImage *open,
                             GlimsItemID id, GeglNode **out, char **error)
{
  GimpDrawable *source;
  GeglBuffer *live = NULL;
  GlimsStatus status;
  uint64_t bytes;
  if (out) *out = NULL;
  if (!out || !open || id <= 0) return GLIMS_STATUS_INVALID_ARGUMENT;
  /* An indexed image can mutate a shared Babl palette after a tile copy. */
  if (gimp_image_get_base_type (open->image) == GIMP_INDEXED) return GLIMS_STATUS_UNSUPPORTED;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  source = glims_lookup_drawable (open, id);
  if (!source) return GLIMS_STATUS_NOT_FOUND;
  g_object_ref (source);
  status = source_buffer (source, &live, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (!buffer_bytes (live, GLIMS_MAX_PIXEL_BUFFER_BYTES, &bytes)) {
    status = glims_fail (error, NULL, "The source exceeds the 512 MiB pixel snapshot limit."); goto done;
  }
  status = copy_source_buffer (live, out, error);
done:
  g_clear_object (&live);
  g_object_unref (source);
  return status;
}

GlimsStatus
glims_filter_input_snapshot_pair (GlimsEngine *engine, GlimsOpenImage *open,
                                  GlimsItemID x_id, GlimsItemID y_id,
                                  GeglNode **x_out, GeglNode **y_out, char **error)
{
  GimpDrawable *sources[2];
  GeglBuffer *live[2] = {NULL, NULL};
  GeglNode *nodes[2] = {NULL, NULL};
  uint64_t remaining = GLIMS_MAX_PIXEL_BUFFER_BYTES;
  GlimsStatus status;
  if (x_out) *x_out = NULL;
  if (y_out) *y_out = NULL;
  if (!x_out || !y_out || x_out == y_out || !open || x_id <= 0 || y_id <= 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (gimp_image_get_base_type (open->image) == GIMP_INDEXED) return GLIMS_STATUS_UNSUPPORTED;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  sources[0] = glims_lookup_drawable (open, x_id);
  sources[1] = glims_lookup_drawable (open, y_id);
  if (!sources[0] || !sources[1]) return GLIMS_STATUS_NOT_FOUND;
  g_object_ref (sources[0]); g_object_ref (sources[1]);
  guint count = sources[0] == sources[1] ? 1 : 2;
  /* Hold both validated identities and refuse reentrant edits/close while
   * their native effects materialize. No target preview exists at this point. */
  engine->busy++;
  for (guint i = 0; i < count; i++) {
    uint64_t bytes;
    status = source_buffer (sources[i], &live[i], error);
    if (status != GLIMS_STATUS_OK) goto done;
    if (!buffer_bytes (live[i], remaining, &bytes)) {
      status = glims_fail (error, NULL, "The captured sources exceed the 512 MiB pixel snapshot limit."); goto done;
    }
    remaining -= bytes;
  }
  /* Validate the full pair's budget before copying either source. This avoids
   * materializing the first input when the second makes the pair too large. */
  for (guint i = 0; i < count; i++) {
    status = copy_source_buffer (live[i], &nodes[i], error);
    if (status != GLIMS_STATUS_OK) goto done;
  }
  if (count == 1) nodes[1] = g_object_ref (nodes[0]);
  *x_out = nodes[0]; nodes[0] = NULL;
  *y_out = nodes[1]; nodes[1] = NULL;
done:
  for (guint i = 0; i < 2; i++) {
    g_clear_object (&nodes[i]); g_clear_object (&live[i]);
    g_object_unref (sources[i]);
  }
  engine->busy--;
  return status;
}

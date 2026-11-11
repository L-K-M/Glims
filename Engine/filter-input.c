/* Read-only filter inputs own detached tiles, never a live drawable graph. */
#include "filter-input.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimppickable.h"
#include "gegl/gimp-gegl-utils.h"
#include "gegl-operations-util.h"
#include <math.h>

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

/* Oilify's native mask-radius range is 1..100. Its Composer3 bbox unions
 * all inputs. It grows the requested rectangle by this halo and uses gint
 * for the padded pixel count and the four-channel indexing/allocation math.
 * See GEGL operations/common-gpl3+/oilify.c and gegl-operation-composer3.c. */
enum { OILIFY_MAX_RADIUS = 100, OILIFY_SCAN_PIXELS = 1024 };
typedef struct { gint64 left, top, right, bottom; } OilifyBox;

static gboolean
oilify_native_integer (gint64 value)
{
  return value >= G_MININT && value <= G_MAXINT;
}

static void
oilify_include_rect (OilifyBox *box, const GeglRectangle *rect, gint64 dx, gint64 dy)
{
  if (rect->width <= 0 || rect->height <= 0) return;
  gint64 x = (gint64) rect->x + dx, y = (gint64) rect->y + dy;
  box->left = MIN (box->left, x); box->top = MIN (box->top, y);
  box->right = MAX (box->right, x + rect->width);
  box->bottom = MAX (box->bottom, y + rect->height);
}

static gboolean
oilify_safe_box (const OilifyBox *box)
{
  gint64 width = box->right - box->left + 2 * OILIFY_MAX_RADIUS;
  gint64 height = box->bottom - box->top + 2 * OILIFY_MAX_RADIUS;
  return oilify_native_integer (box->left - OILIFY_MAX_RADIUS) &&
         oilify_native_integer (box->top - OILIFY_MAX_RADIUS) &&
         oilify_native_integer (box->right + OILIFY_MAX_RADIUS) &&
         oilify_native_integer (box->bottom + OILIFY_MAX_RADIUS) &&
         width > 0 && height > 0 && width <= (G_MAXINT / 4) / height;
}

static gboolean
oilify_target_placement (GimpDrawable *target, const GeglRectangle *extent)
{
  GimpItem *item = GIMP_ITEM (target);
  GimpImage *image = gimp_item_get_image (item);
  gint64 x = gimp_item_get_offset_x (item), y = gimp_item_get_offset_y (item);
  /* The native mask path negates the offsets, and mask_intersect shifts
   * selection bounds from image coordinates into the item before clipping. */
  return oilify_native_integer (-x) && oilify_native_integer (-y) &&
         oilify_native_integer ((gint64) gimp_image_get_width (image) - x) &&
         oilify_native_integer ((gint64) gimp_image_get_height (image) - y) &&
         oilify_native_integer (x + gimp_item_get_width (item)) &&
         oilify_native_integer (y + gimp_item_get_height (item)) &&
         oilify_native_integer (x + extent->x) && oilify_native_integer (y + extent->y) &&
         oilify_native_integer (x + extent->x + extent->width) &&
         oilify_native_integer (y + extent->y + extent->height);
}

static gboolean
oilify_finite_rect (GeglBuffer *buffer, const GeglRectangle *rect,
                    const Babl *format, gint components)
{
  if (rect->width <= 0 || rect->height <= 0) return TRUE;
  gfloat values[4 * OILIFY_SCAN_PIXELS];
  for (gint y = 0; y < rect->height; y++) {
    for (gint x = 0; x < rect->width; ) {
      gint count = MIN (OILIFY_SCAN_PIXELS, rect->width - x);
      GeglRectangle row = {rect->x + x, rect->y + y, count, 1};
      gegl_buffer_get (buffer, &row, 1.0, format, values, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      for (gint i = 0; i < count * components; i++)
        if (!isfinite (values[i])) return FALSE;
      x += count;
    }
  }
  return TRUE;
}

static gboolean
oilify_finite_buffer (GeglBuffer *buffer, const Babl *format, gint components)
{
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  const GeglRectangle *abyss = gegl_buffer_get_abyss (buffer);
  /* Subbuffer abyss coordinates can extend beyond its nominal extent. */
  return oilify_finite_rect (buffer, extent, format, components) &&
         (gegl_rectangle_equal (extent, abyss) || oilify_finite_rect (buffer, abyss, format, components));
}

static GlimsStatus
oilify_unsupported (char **error, const gchar *reason)
{
  if (error) *error = g_strdup (reason);
  return GLIMS_STATUS_UNSUPPORTED;
}

static gboolean
oilify_integer_range (const gchar *name, gint minimum, gint maximum)
{
  GParamSpec *spec = gegl_operation_find_property ("gegl:oilify", name);
  return spec && G_IS_PARAM_SPEC_INT (spec) && G_PARAM_SPEC_INT (spec)->minimum == minimum &&
         G_PARAM_SPEC_INT (spec)->maximum == maximum;
}

GlimsStatus
glims_filter_input_oilify_prepare (GlimsEngine *engine, GlimsOpenImage *open,
                                  GimpDrawable *target, GlimsItemID radius_id,
                                  GlimsItemID exponent_id, GeglNode **radius_out,
                                  GeglNode **exponent_out, char **error)
{
  GlimsItemID ids[2] = {radius_id, exponent_id};
  GimpDrawable *sources[2] = {NULL, NULL};
  GeglBuffer *live[2] = {NULL, NULL}, *raw = NULL, *snapshot = NULL;
  GeglNode *nodes[2] = {NULL, NULL};
  uint64_t remaining = GLIMS_MAX_PIXEL_BUFFER_BYTES;
  GlimsStatus status = GLIMS_STATUS_OK;
  *radius_out = *exponent_out = NULL;
  if (!oilify_integer_range ("mask-radius", 1, OILIFY_MAX_RADIUS) ||
      !oilify_integer_range ("exponent", 1, 20) || !oilify_integer_range ("intensities", 8, 256))
    return oilify_unsupported (error, "This engine's Oilify parameter ranges are not supported.");

  for (guint i = 0; i < 2; i++) {
    if (ids[i] && !(sources[i] = glims_lookup_drawable (open, ids[i]))) {
      if (error) *error = g_strdup ("An Oilify map is no longer attached to this image.");
      return GLIMS_STATUS_NOT_FOUND;
    }
  }
  gboolean alias = sources[0] && sources[0] == sources[1];
  g_object_ref (target);
  for (guint i = 0; i < 2; i++) if (sources[i]) g_object_ref (sources[i]);
  engine->busy++;
  /* The inactive preview is placed at the raw-input end of the stack
   * before enabling it. Existing target effects run downstream of Oilify. */
  raw = gimp_drawable_get_buffer (target);
  if (!raw) { status = glims_fail (error, NULL, "The Oilify target pixels could not be read."); goto done; }
  g_object_ref (raw);
  const GeglRectangle extent = *gegl_buffer_get_extent (raw);
  const GeglRectangle abyss = *gegl_buffer_get_abyss (raw);
  const Babl *raw_format = gegl_buffer_get_format (raw);
  if (extent.width <= 0 || extent.height <= 0 || !oilify_target_placement (target, &extent)) {
    status = oilify_unsupported (error, "The Oilify target is outside the supported native geometry."); goto done;
  }
  GeglRectangle area = {0};
  if (!gimp_item_mask_intersect (GIMP_ITEM (target), &area.x, &area.y, &area.width, &area.height) ||
      area.width <= 0 || area.height <= 0) {
    if (error) *error = g_strdup ("The selection does not intersect the Oilify target.");
    status = GLIMS_STATUS_INVALID_ARGUMENT; goto done;
  }

  /* Cover both the translated input during attachment and the selection
   * crop after freezing, including any native extents of the auxiliary pads.
   * Keep the whole envelope in gint for GEGL's bbox union and halo math. */
  OilifyBox box = {G_MAXINT64, G_MAXINT64, G_MININT64, G_MININT64};
  oilify_include_rect (&box, &extent, 0, 0);
  oilify_include_rect (&box, &abyss, 0, 0);
  oilify_include_rect (&box, &extent, -(gint64) area.x, -(gint64) area.y);
  oilify_include_rect (&box, &abyss, -(gint64) area.x, -(gint64) area.y);
  oilify_include_rect (&box, GEGL_RECTANGLE (0, 0, area.width, area.height), 0, 0);
  for (guint i = 0; i < 2; i++) {
    uint64_t bytes;
    if (!sources[i] || (i == 1 && alias)) continue;
    status = source_buffer (sources[i], &live[i], error);
    if (status != GLIMS_STATUS_OK) goto done;
    if (!buffer_bytes (live[i], remaining, &bytes)) {
      status = glims_fail (error, NULL, "The captured sources exceed the 512 MiB pixel snapshot limit."); goto done;
    }
    remaining -= bytes;
    oilify_include_rect (&box, gegl_buffer_get_extent (live[i]), 0, 0);
    oilify_include_rect (&box, gegl_buffer_get_abyss (live[i]), 0, 0);
  }
  if (!oilify_safe_box (&box)) {
    status = oilify_unsupported (error, "The Oilify input bounds and radius exceed native pixel arithmetic."); goto done;
  }
  const Babl *space = babl_format_get_space (raw_format);
  const Babl *luma = babl_format_with_space ("Y float", space);
  for (guint i = 0; i < 2; i++) {
    if (!live[i]) continue;
    status = copy_source_buffer (live[i], &nodes[i], error);
    if (status != GLIMS_STATUS_OK) goto done;
    gegl_node_get (nodes[i], "buffer", &snapshot, NULL);
    if (!snapshot ||
        !gegl_rectangle_equal (gegl_buffer_get_extent (snapshot), gegl_buffer_get_extent (live[i])) ||
        !gegl_rectangle_equal (gegl_buffer_get_abyss (snapshot), gegl_buffer_get_abyss (live[i]))) {
      status = oilify_unsupported (error, "The Oilify map snapshot did not preserve its native bounds."); goto done;
    }
    if (!oilify_finite_buffer (snapshot, luma, 1)) {
      status = oilify_unsupported (error, "Oilify requires finite luminance in each map."); goto done;
    }
    g_clear_object (&snapshot);
  }
  /* Effect-backed map reads can enter native work. The target must still be
   * the buffer whose geometry and working space we checked. */
  GeglRectangle current_area = {0};
  if (gimp_drawable_get_buffer (target) != raw || gegl_buffer_get_format (raw) != raw_format ||
      !gegl_rectangle_equal (&extent, gegl_buffer_get_extent (raw)) ||
      !gegl_rectangle_equal (&abyss, gegl_buffer_get_abyss (raw)) || !oilify_target_placement (target, &extent) ||
      !gimp_item_mask_intersect (GIMP_ITEM (target), &current_area.x, &current_area.y, &current_area.width, &current_area.height) ||
      !gegl_rectangle_equal (&area, &current_area)) {
    if (error) *error = g_strdup ("The Oilify target changed while capturing its maps.");
    status = GLIMS_STATUS_BUSY; goto done;
  }
  const Babl *rgba = babl_format_with_space ("RGBA float", space);
  if (!oilify_finite_buffer (raw, rgba, 4) || !oilify_finite_buffer (raw, luma, 1)) {
    status = oilify_unsupported (error, "Oilify requires finite target color, alpha and luminance samples."); goto done;
  }
  if (alias) nodes[1] = g_object_ref (nodes[0]);
  *radius_out = nodes[0]; nodes[0] = NULL;
  *exponent_out = nodes[1]; nodes[1] = NULL;
done:
  g_clear_object (&snapshot);
  g_clear_object (&raw);
  for (guint i = 0; i < 2; i++) {
    g_clear_object (&nodes[i]); g_clear_object (&live[i]);
    if (sources[i]) g_object_unref (sources[i]);
  }
  g_object_unref (target);
  engine->busy--;
  return status;
}

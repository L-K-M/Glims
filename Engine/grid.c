/*
 * The image's display grid: read as the current state, applied as one
 * native undo step. Runs on the engine thread.
 *
 * The native API is app/core/gimpgrid.h and app/core/gimpimage-grid.c:
 * gimp_image_get_grid returns the image's own (borrowed) GimpGrid and
 * gimp_image_set_grid(image, grid, TRUE) compares the two configs with
 * gimp_config_is_equal_to — an identical config returns with no undo —
 * and otherwise pushes exactly one "Grid" undo step
 * (gimp_image_undo_push_image_grid, GIMP_DIRTY_IMAGE_META) and syncs
 * the properties into the image's grid. The adapter clones the current
 * grid with gimp_config_duplicate, so the unexposed properties
 * (spacing-unit, offset-unit) are retained, validates the whole request
 * against the native GParamSpecDouble bounds before any g_object_set
 * (the native setters clamp, which would hide invalid input), and only
 * then applies the exposed properties on the clone. Colors are set on
 * freshly created GeglColor objects through
 * gegl_color_set_rgba_with_space with a NULL space — non-linear sRGB —
 * so the engine's shared default color objects are never mutated; the
 * native color setter duplicates the passed object into the grid, so
 * the adapter's own references are released right after g_object_set.
 * Readback uses gegl_color_get_rgba_with_space with a NULL space too.
 */
#include "engine-private.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-grid.h"
#include "core/gimpgrid.h"

/* The facade style a native grid reports, mapped by name: the engine's
 * enum value never leaves the adapter. 0 for a value outside the
 * engine's enum (cannot happen with a well-formed GimpGrid). */
static uint32_t
facade_grid_style (GimpGridStyle style)
{
  switch (style)
    {
    case GIMP_GRID_DOTS:          return GLIMS_GRID_DOTS;
    case GIMP_GRID_INTERSECTIONS: return GLIMS_GRID_INTERSECTIONS;
    case GIMP_GRID_ON_OFF_DASH:   return GLIMS_GRID_ON_OFF_DASH;
    case GIMP_GRID_DOUBLE_DASH:   return GLIMS_GRID_DOUBLE_DASH;
    case GIMP_GRID_SOLID:         return GLIMS_GRID_SOLID;
    default:                      return 0;
    }
}

/* The engine style of a facade value, or FALSE for an unknown one. */
static gboolean
engine_grid_style (uint32_t       value,
                   GimpGridStyle *style)
{
  switch (value)
    {
    case GLIMS_GRID_DOTS:          *style = GIMP_GRID_DOTS;          return TRUE;
    case GLIMS_GRID_INTERSECTIONS: *style = GIMP_GRID_INTERSECTIONS; return TRUE;
    case GLIMS_GRID_ON_OFF_DASH:   *style = GIMP_GRID_ON_OFF_DASH;   return TRUE;
    case GLIMS_GRID_DOUBLE_DASH:   *style = GIMP_GRID_DOUBLE_DASH;   return TRUE;
    case GLIMS_GRID_SOLID:         *style = GIMP_GRID_SOLID;         return TRUE;
    default:                                                        return FALSE;
    }
}

/* The exact native bounds of a grid double property, read from the
 * class's GParamSpec so an engine change is caught here, not silently
 * clamped by g_object_set. */
static gboolean
grid_double_bounds (GimpGrid   *grid,
                    const gchar *name,
                    gdouble     *minimum,
                    gdouble     *maximum)
{
  GParamSpec *pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (grid), name);

  if (! pspec || ! G_IS_PARAM_SPEC_DOUBLE (pspec))
    return FALSE;

  *minimum = G_PARAM_SPEC_DOUBLE (pspec)->minimum;
  *maximum = G_PARAM_SPEC_DOUBLE (pspec)->maximum;
  return TRUE;
}

/* A facade color is valid when every component, alpha included, is
 * finite and inside 0 ... 1. */
static gboolean
valid_grid_color (const GlimsColor *color)
{
  return isfinite (color->red)   && color->red   >= 0.0 && color->red   <= 1.0 &&
         isfinite (color->green) && color->green >= 0.0 && color->green <= 1.0 &&
         isfinite (color->blue)  && color->blue  >= 0.0 && color->blue  <= 1.0 &&
         isfinite (color->alpha) && color->alpha >= 0.0 && color->alpha <= 1.0;
}

/* A freshly created, owned GeglColor holding `color` as non-linear sRGB
 * (a NULL space is sRGB in gegl_color_set_rgba_with_space). */
static GeglColor *
grid_color (const GlimsColor *color)
{
  GeglColor *gegl_color = gegl_color_new (NULL);

  gegl_color_set_rgba_with_space (gegl_color,
                                  color->red, color->green, color->blue, color->alpha,
                                  NULL);
  return gegl_color;
}

GlimsStatus
glims_image_grid (GlimsEngine *engine,
                  GlimsImageID id,
                  GlimsGrid   *out,
                  char       **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpGrid       *grid;
  gdouble         x, y;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! out || out->struct_size < sizeof (GlimsGrid))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Borrowed, read-only: the image's own grid, never released here. */
  grid = gimp_image_get_grid (open->image);
  if (! grid)
    return glims_fail (error, NULL, "The image has no grid.");

  out->struct_size = sizeof (GlimsGrid);
  out->style       = facade_grid_style (gimp_grid_get_style (grid));

  gimp_grid_get_spacing (grid, &x, &y);
  out->spacing_x = x;
  out->spacing_y = y;

  gimp_grid_get_offset (grid, &x, &y);
  out->offset_x = x;
  out->offset_y = y;

  /* Borrowed colors, read in non-linear sRGB (NULL space). */
  gegl_color_get_rgba_with_space (gimp_grid_get_fgcolor (grid),
                                  &out->foreground.red, &out->foreground.green,
                                  &out->foreground.blue, &out->foreground.alpha,
                                  NULL);
  gegl_color_get_rgba_with_space (gimp_grid_get_bgcolor (grid),
                                  &out->background.red, &out->background.green,
                                  &out->background.blue, &out->background.alpha,
                                  NULL);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_set_grid (GlimsEngine     *engine,
                      GlimsImageID     id,
                      const GlimsGrid *request,
                      char           **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpGrid       *current, *clone;
  GimpGridStyle   style;
  GeglColor      *fg, *bg;
  GlimsStatus     status;
  gdouble         minimum, maximum;

  /* Whole-input validation before anything is touched; every refusal
   * below leaves pixels, history and the dirty flag alone. */
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! request || request->struct_size < sizeof (GlimsGrid))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (! engine_grid_style (request->style, &style))
    {
      glims_fail (error, NULL, "The grid style is unknown.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  current = gimp_image_get_grid (open->image);   /* borrowed */
  if (! current)
    return glims_fail (error, NULL, "The image has no grid.");

  /* Spacings: finite, strictly positive (the facade's own rule, stricter
   * than the native 0.0 minimum) and inside the native property bounds.
   * Offsets: finite and inside the native signed range. The bounds come
   * from the engine's own GParamSpecDouble, so a native change is
   * refused here rather than clamped into a partial mutation. */
  if (! grid_double_bounds (current, "xspacing", &minimum, &maximum))
    return glims_fail (error, NULL, "The engine's grid has no xspacing property.");
  if (! isfinite (request->spacing_x) || request->spacing_x <= 0.0 ||
      request->spacing_x < minimum || request->spacing_x > maximum)
    {
      glims_fail (error, NULL, "The grid's horizontal spacing is outside its valid range.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (! grid_double_bounds (current, "yspacing", &minimum, &maximum))
    return glims_fail (error, NULL, "The engine's grid has no yspacing property.");
  if (! isfinite (request->spacing_y) || request->spacing_y <= 0.0 ||
      request->spacing_y < minimum || request->spacing_y > maximum)
    {
      glims_fail (error, NULL, "The grid's vertical spacing is outside its valid range.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (! grid_double_bounds (current, "xoffset", &minimum, &maximum))
    return glims_fail (error, NULL, "The engine's grid has no xoffset property.");
  if (! isfinite (request->offset_x) ||
      request->offset_x < minimum || request->offset_x > maximum)
    {
      glims_fail (error, NULL, "The grid's horizontal offset is outside its valid range.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (! grid_double_bounds (current, "yoffset", &minimum, &maximum))
    return glims_fail (error, NULL, "The engine's grid has no yoffset property.");
  if (! isfinite (request->offset_y) ||
      request->offset_y < minimum || request->offset_y > maximum)
    {
      glims_fail (error, NULL, "The grid's vertical offset is outside its valid range.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (! valid_grid_color (&request->foreground) || ! valid_grid_color (&request->background))
    {
      glims_fail (error, NULL, "The grid colors must be finite sRGB values between 0 and 1, alpha included.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* Clone the image's own grid, so the unexposed properties (the units)
   * are retained, and apply only the exposed ones. All inputs are
   * validated by now, so g_object_set cannot clamp anything. */
  clone = GIMP_GRID (gimp_config_duplicate (GIMP_CONFIG (current)));
  fg = grid_color (&request->foreground);
  bg = grid_color (&request->background);
  g_object_set (clone,
                "style",    style,
                "fgcolor",  fg,
                "bgcolor",  bg,
                "xspacing", request->spacing_x,
                "yspacing", request->spacing_y,
                "xoffset",  request->offset_x,
                "yoffset",  request->offset_y,
                NULL);
  /* The native color setter duplicated both colors into the clone; the
   * adapter's own references end here. */
  g_object_unref (fg);
  g_object_unref (bg);

  /* An identical grid is a no-op with no undo — checked before the
   * readiness gate, like guide_put's same-position move. */
  if (gimp_config_is_equal_to (GIMP_CONFIG (current), GIMP_CONFIG (clone)))
    {
      g_object_unref (clone);
      return GLIMS_STATUS_OK;
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    {
      g_object_unref (clone);
      return status;
    }

  /* One native call: a changed grid is exactly one "Grid" undo step and
   * the sync into the image's grid is native semantics (it re-checks
   * equality, so this cannot double-push). The clone is only borrowed
   * by the call. */
  gimp_image_set_grid (open->image, clone, TRUE);
  g_object_unref (clone);

  return GLIMS_STATUS_OK;
}

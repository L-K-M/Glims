/*
 * Internal two-endpoint gradient creation (engine-private only; no facade
 * slot yet — slots 136/137 stay reserved and a public gradient-create
 * slot is added later by another change). One static two-stop gradient:
 * a privately owned GimpGradient with exactly ONE segment, positions
 * left 0 / middle 0.5 / right 1, stored segment type
 * GIMP_GRADIENT_SEGMENT_LINEAR, coloring GIMP_GRADIENT_SEGMENT_RGB and
 * BOTH endpoint color types GIMP_GRADIENT_COLOR_FIXED. (The stored
 * LINEAR/RGB segment fields are not the separate
 * GIMP_GRADIENT_BLEND_*_ sampling-space enum used when sampling.)
 *
 * The endpoints are explicit captured GlimsColor sRGB+alpha values, never
 * context-dynamic FG/BG stops: each becomes an owned GeglColor through
 * gegl_color_set_rgba_with_space(..., NULL) — NULL space is babl's
 * default sRGB for R'G'B'A float, i.e. the facade's sRGB contract; plain
 * gegl_color_set_rgba() would store linear light and misinterpret the
 * facade values. The gradient is built with gimp_gradient_new(NULL, name):
 * all four engine trees (3.2.8, 3.2.0, 3.0.8, master) ignore the context
 * argument there and create exactly one segment, so NULL keeps the global
 * and user context entirely out of this call. The new gradient is
 * NON-internal (only gimp_data_make_internal sets that), so the checked
 * save can persist it.
 *
 * Persistence reuses the checked pipeline of resource-create.c /
 * resource-duplicate.c unchanged: glims_resource_staging_begin() with the
 * native .ggr extension, then glims_resource_save_and_publish(), which
 * owns the gradient on every path (checked gimp_data_save, no-overwrite
 * no-fallback promotion, exact-name publication, positive native id).
 * No gimp_data_factory_data_new convenience (unchecked save). Admission is
 * all before any mutation: required outputs zeroed on every failure, name
 * through glims_valid_resource_name plus the GGR edge-whitespace refusal
 * (the loader g_strstrip()s the name, so such a name would change identity
 * on reload), endpoint components finite 0...1, the same BUSY gate as
 * resource-duplicate (global busy flag plus ANY open stroke/filter on any
 * image), and the exact-name duplicate refusal (FAILED, no uniquify).
 * No image, undo history, context, clipboard or other catalog is touched.
 */
#include "engine-private.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpgradient.h"
#include "core/gimpgradient-load.h"

/* Every component finite and inside 0 ... 1, the GlimsColor contract. */
static gboolean
valid_endpoint (const GlimsColor *color)
{
  const gdouble rgba[4] = { color->red, color->green, color->blue, color->alpha };
  gint i;

  for (i = 0; i < 4; i++)
    if (! isfinite (rgba[i]) || rgba[i] < 0.0 || rgba[i] > 1.0)
      return FALSE;

  return TRUE;
}

/* One owned color interpreting the facade's sRGB+alpha endpoint. NULL
 * space is babl's default sRGB for "R'G'B'A float" (gegl-color.c:
 * babl_format_with_space(..., NULL)); plain gegl_color_set_rgba() would
 * store linear light instead. */
static GeglColor *
endpoint_color (const GlimsColor *color)
{
  GeglColor *result = gegl_color_new (NULL);

  if (result)
    gegl_color_set_rgba_with_space (result, color->red, color->green,
                                    color->blue, color->alpha, NULL);

  return result;
}

GlimsStatus
glims_resource_create_gradient (GlimsEngine      *engine,
                                const char       *name,
                                const GlimsColor *left,
                                const GlimsColor *right,
                                GlimsResourceID  *out,
                                char            **error)
{
  GimpDataFactory      *factory;
  GimpContainer        *container;
  GimpGradient         *gradient;
  GimpGradientSegment  *seg;
  GeglColor            *left_color;
  GeglColor            *right_color;
  GlimsResourceStaging  staging;
  GlimsStatus           status;

  if (out)
    *out = 0;

  /* Admission, all before any mutation. */
  if (! engine || ! name || ! left || ! right || ! out)
    {
      if (error)
        *error = strdup ("The engine, name, both endpoints and the id output "
                         "are required.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (! glims_valid_resource_name (name))
    {
      if (error)
        *error = strdup ("The resource name must be nonempty UTF-8 without control "
                         "characters, at most 255 bytes.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* The GGR loader strips surrounding ASCII whitespace from the name
   * (gimpgradient-load.c, g_strstrip on the "Name:" line), so a name with
   * an edge space would change identity on reload — refused here. */
  if (g_ascii_isspace (name[0]) || g_ascii_isspace (name[strlen (name) - 1]))
    {
      if (error)
        *error = strdup ("This resource format cannot preserve spaces at the "
                         "start or end of its name.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (! valid_endpoint (left) || ! valid_endpoint (right))
    {
      if (error)
        *error = strdup ("The endpoint colors need finite components inside 0...1.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* No image argument: refuse the engine-global busy flag and ANY active
   * stroke or filter session, on any image — exactly resource-duplicate's
   * gate, before anything is created or persisted. */
  if (engine->busy > 0 ||
      g_hash_table_size (engine->strokes) > 0 ||
      g_hash_table_size (engine->filters) > 0)
    return GLIMS_STATUS_BUSY;

  factory   = engine->gimp->gradient_factory;
  container = gimp_data_factory_get_container (factory);

  /* Exact name collision against the current gradient factory; the
   * unique-names container would silently uniquify — refused instead. */
  if (glims_resource_name_taken (container, name))
    return glims_fail (error, NULL, "A resource with this name already exists.");

  /* One privately owned, NON-internal gradient. gimp_gradient_new()
   * ignores its context argument in all four engine trees (only the name
   * is checked) and creates exactly one segment, so NULL is valid and no
   * global/user context is involved. */
  gradient = GIMP_GRADIENT (gimp_gradient_new (NULL, name));
  seg      = gradient ? gradient->segments : NULL;
  if (! gradient || ! seg || seg->next)
    {
      g_clear_object (&gradient);
      return glims_fail (error, NULL, "The engine did not create one empty segment.");
    }

  left_color  = endpoint_color (left);
  right_color = endpoint_color (right);
  if (! left_color || ! right_color)
    {
      g_clear_object (&left_color);
      g_clear_object (&right_color);
      g_object_unref (gradient);
      return glims_fail (error, NULL, "Not enough memory for the endpoint colors.");
    }

  /* Direct field assignment on the new private object only (the same rule
   * as pattern->mask in resource-create.c): the native set_left/right_color
   * setters blend the range in place and borrow their color arguments.
   * Direct assignment here transfers each private owned reference once. gimp_gradient_finalize() ->
   * gimp_gradient_segment_free() releases both endpoint colors exactly
   * once when the gradient is released. */
  g_clear_object (&seg->left_color);
  seg->left_color = left_color;
  g_clear_object (&seg->right_color);
  seg->right_color = right_color;

  /* Exactly one static segment: positions 0 / 0.5 / 1, stored blending
   * LINEAR, coloring RGB, both endpoint color types FIXED (never the
   * context-dynamic FG/BG stop types). */
  seg->left             = 0.0;
  seg->middle           = 0.5;
  seg->right            = 1.0;
  seg->type             = GIMP_GRADIENT_SEGMENT_LINEAR;
  seg->color            = GIMP_GRADIENT_SEGMENT_RGB;
  seg->left_color_type  = GIMP_GRADIENT_COLOR_FIXED;
  seg->right_color_type = GIMP_GRADIENT_COLOR_FIXED;

  status = glims_resource_staging_begin (factory, GIMP_GRADIENT_FILE_EXTENSION,
                                         &staging, error);
  if (status != GLIMS_STATUS_OK)
    {
      g_object_unref (gradient);
      return status;
    }

  /* The checked persistence pipeline owns `gradient` on every path from
   * here on; on failure it releases it and cleans the staging. */
  return glims_resource_save_and_publish (factory, GIMP_DATA (gradient), name,
                                          &staging, out, error);
}

#include "lab-layer-brush-facts.h"
#include "brush-fingerprint.h"
#include "stroke-dynamics-fingerprint.h"

#include "core/gimpbrush.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpimage.h"
#include "core/gimpimage-symmetry.h"
#include "core/gimpsymmetry.h"
#include "paint/gimppaintoptions.h"

#include <lcms2.h>
#include <math.h>
#include <string.h>

/* Capture the actual native configuration before the first dab. The hash is
 * independent of session IDs and logical roots; the Recorder binds those
 * separately and checks them again before replay. */
gboolean
glims_lab_layer_brush_capture_facts (GlimsEngine *engine, GimpImage *image,
                                     GimpPaintOptions *options,
                                     const GlimsLabLayerBrushSettings *settings,
                                     GlimsStrokeCaptureFacts *facts)
{
  if (!engine || !GIMP_IS_IMAGE (image) || !GIMP_IS_PAINT_OPTIONS (options) ||
      !settings || settings->struct_size < sizeof *settings ||
      !facts || facts->struct_size < sizeof *facts)
    return FALSE;
  const gdouble colors[] = { settings->color.red, settings->color.green,
                             settings->color.blue, settings->color.alpha,
                             settings->opacity, settings->hardness };
  for (guint i = 0; i < G_N_ELEMENTS (colors); i++)
    if (!isfinite (colors[i]) || colors[i] < 0 || colors[i] > 1) return FALSE;
  if (!isfinite (settings->size) || settings->size < 1 || settings->size > 10000)
    return FALSE;

  GimpContext *context = GIMP_CONTEXT (options);
  GimpSymmetry *symmetry = gimp_image_get_active_symmetry (image);
  if (!symmetry || G_OBJECT_TYPE (symmetry) != GIMP_TYPE_SYMMETRY ||
      gimp_image_get_floating_selection (image) ||
      gimp_context_get_paint_mode (context) != GIMP_LAYER_MODE_NORMAL ||
      options->expand_use || options->jitter_options->use_jitter ||
      options->smoothing_options->use_smoothing || options->use_applicator ||
      options->brush_lock_to_view || options->application_mode != GIMP_PAINT_CONSTANT)
    return FALSE;

  gboolean enabled = gimp_paint_options_are_dynamics_enabled (options);
  g_autofree gchar *dynamics = enabled ?
    glims_stroke_dynamics_fingerprint (TRUE, gimp_context_get_dynamics (context)) : NULL;
  if (enabled && !dynamics) return FALSE;
  GimpBrush *brush = gimp_context_get_brush (context);
  if (!brush) return FALSE;
  gint id = gimp_data_get_id (GIMP_DATA (brush));
  GimpBrush *member = NULL;
  if (id <= 0 || glims_lookup_brush (engine, (GlimsResourceID) id, &member) != GLIMS_STATUS_OK ||
      member != brush) return FALSE;
  g_autofree gchar *content = glims_brush_fingerprint (brush);
  if (!content) return FALSE;

  const gdouble values[] = { settings->color.red, settings->color.green, settings->color.blue,
    settings->color.alpha, settings->opacity, settings->size, settings->hardness,
    gimp_context_get_opacity (context), options->brush_size, options->brush_angle,
    options->brush_aspect_ratio, options->brush_spacing, options->brush_hardness,
    options->brush_force };
  for (guint i = 0; i < G_N_ELEMENTS (values); i++)
    if (!isfinite (values[i])) return FALSE;
  GlimsStrokeCaptureFacts captured = { .struct_size = sizeof captured };
  if (glims_resource_identifiers (engine, (GlimsResourceID) id, &captured.brush_name,
                                  &captured.brush_collection, &captured.brush_internal,
                                  NULL) != GLIMS_STATUS_OK ||
      !captured.brush_name || !*captured.brush_name)
    {
      g_free (captured.brush_name);
      g_free (captured.brush_collection);
      return FALSE;
    }
  static const gchar domain[] = "glims-layered-lab-brush-configuration-v1";
  g_autoptr(GChecksum) hash = g_checksum_new (G_CHECKSUM_SHA256);
  g_checksum_update (hash, (const guchar *) domain, sizeof domain);
  /* Native brush geometry can change across engine versions. */
  static const gchar engine_version[] = GIMP_VERSION;
  g_checksum_update (hash, (const guchar *) engine_version, sizeof engine_version);
  gint gegl_major, gegl_minor, gegl_micro, babl_major, babl_minor, babl_micro;
  gegl_get_version (&gegl_major, &gegl_minor, &gegl_micro);
  babl_get_version (&babl_major, &babl_minor, &babl_micro);
  gchar dependencies[96];
  g_snprintf (dependencies, sizeof dependencies, "%d.%d.%d/%d.%d.%d/%d",
              gegl_major, gegl_minor, gegl_micro, babl_major, babl_minor,
              babl_micro, cmsGetEncodedCMMversion ());
  g_checksum_update (hash, (const guchar *) dependencies, strlen (dependencies) + 1);
  g_checksum_update (hash, (const guchar *) content, strlen (content) + 1);
  const guint8 flags[] = { options->hard != FALSE, enabled != FALSE };
  g_checksum_update (hash, flags, sizeof flags);
  for (guint i = 0; i < G_N_ELEMENTS (values); i++)
    {
      gchar number[G_ASCII_DTOSTR_BUF_SIZE];
      /* Signed zero has identical paint behavior and may be normalized by
       * a saved Recorder file; canonicalize it before hashing. */
      g_ascii_dtostr (number, sizeof number, values[i] == 0 ? 0 : values[i]);
      g_checksum_update (hash, (const guchar *) number, strlen (number) + 1);
    }
  if (dynamics) g_checksum_update (hash, (const guchar *) dynamics, strlen (dynamics) + 1);
  captured.fingerprint = g_strdup (g_checksum_get_string (hash));
  captured.struct_size = facts->struct_size;
  *facts = captured;
  return TRUE;
}

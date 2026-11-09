/* Shared engine-thread TRC coherence and immutable point-config replacement. */
#include "point-config-trc.h"
#include <stdarg.h>
#include <string.h>

static GlimsStatus point_error (GlimsStatus status, char **error,
                               const char *format, ...) G_GNUC_PRINTF (3, 4);
static GlimsStatus
point_error (GlimsStatus status, char **error, const char *format, ...)
{
  if (error) {
    va_list args;
    va_start (args, format);
    gchar *message = g_strdup_vprintf (format, args);
    va_end (args);
    *error = strdup (message);
    g_free (message);
  }
  return status;
}

static gboolean
valid_spec (const GlimsPointConfigTRCSpec *spec)
{
  return spec && spec->operation_name && spec->display_name &&
         g_type_is_a (spec->operation_type, GIMP_TYPE_OPERATION_POINT_FILTER) &&
         g_type_is_a (spec->config_type, G_TYPE_OBJECT);
}

static gboolean
known_trc (gint trc)
{
  return trc == GIMP_TRC_LINEAR || trc == GIMP_TRC_NON_LINEAR || trc == GIMP_TRC_PERCEPTUAL;
}

gboolean
glims_point_config_trc_property (GObject *object)
{
  if (!G_IS_OBJECT (object)) return FALSE;
  GParamSpec *spec = g_object_class_find_property (G_OBJECT_GET_CLASS (object), "trc");
  return spec && G_IS_PARAM_SPEC_ENUM (spec) &&
         G_PARAM_SPEC_VALUE_TYPE (spec) == GIMP_TYPE_TRC_TYPE &&
         (spec->flags & G_PARAM_READWRITE) == G_PARAM_READWRITE;
}

#if GIMP_CHECK_VERSION (3, 2, 0)
static gboolean
binding_matches (GBinding *binding, GObject *config, GimpOperationPointFilter *point)
{
  GObject *source, *target;
  gboolean matches;
  if (!binding || !G_IS_BINDING (binding)) return FALSE;
  if ((g_binding_get_flags (binding) & ~G_BINDING_SYNC_CREATE) != 0) return FALSE;
  if (g_strcmp0 (g_binding_get_source_property (binding), "trc") ||
      g_strcmp0 (g_binding_get_target_property (binding), "trc")) return FALSE;
  source = g_binding_dup_source (binding); /* owned endpoint witnesses */
  target = g_binding_dup_target (binding);
  matches = source == config && target == G_OBJECT (point);
  g_clear_object (&source);
  g_clear_object (&target);
  return matches;
}
#endif

GlimsStatus
glims_point_config_trc_check (GeglNode *node, const GlimsPointConfigTRCSpec *spec,
                              gboolean allow_empty, GimpOperationPointFilter **out,
                              char **error)
{
  GeglOperation *operation;
  GimpOperationPointFilter *point;
  if (out) *out = NULL;
  if (!out || !valid_spec (spec))
    return point_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A point configuration specification and output are required.");
  if (!GEGL_IS_NODE (node))
    return point_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A filter operation is required.");
  if (g_strcmp0 (gegl_node_get_operation (node), spec->operation_name))
    return point_error (GLIMS_STATUS_UNSUPPORTED, error, "These settings are only available for %s.", spec->display_name);
  operation = gegl_node_get_gegl_operation (node); /* borrowed from node */
  if (!operation || G_OBJECT_TYPE (operation) != spec->operation_type)
    return point_error (GLIMS_STATUS_FAILED, error, "The native %s operation is invalid.", spec->display_name);
  point = GIMP_OPERATION_POINT_FILTER (operation);
  if (!glims_point_config_trc_property (G_OBJECT (point)))
    return point_error (GLIMS_STATUS_UNSUPPORTED, error, "The native %s operation has an incompatible TRC property.", spec->display_name);
  if (!known_trc (point->trc))
    return point_error (GLIMS_STATUS_FAILED, error, "The native %s operation TRC is invalid.", spec->display_name);
  if (point->config) {
    gint trc;
    if (G_OBJECT_TYPE (point->config) != spec->config_type)
      return point_error (GLIMS_STATUS_FAILED, error, "The native %s configuration has the wrong type.", spec->display_name);
    if (!glims_point_config_trc_property (point->config))
      return point_error (GLIMS_STATUS_UNSUPPORTED, error, "The native %s configuration has an incompatible TRC property.", spec->display_name);
    /* Exact Levels/Curves getters read the backing field, not a channel cursor. */
    g_object_get (point->config, "trc", &trc, NULL);
    if (!known_trc (trc))
      return point_error (GLIMS_STATUS_FAILED, error, "The native %s configuration TRC is invalid.", spec->display_name);
    if ((gint) point->trc != trc)
      return point_error (GLIMS_STATUS_UNSUPPORTED, error, "This %s effect has inconsistent operation and configuration TRCs and cannot be edited safely.", spec->display_name);
  } else if (!allow_empty) {
    return point_error (GLIMS_STATUS_FAILED, error, "The filter has no %s configuration.", spec->display_name);
  }
#if GIMP_CHECK_VERSION (3, 2, 0)
  if (point->config ? !binding_matches (point->trc_binding, point->config, point)
                    : point->trc_binding != NULL)
    return point_error (GLIMS_STATUS_UNSUPPORTED, error, "The native %s TRC binding is incompatible.", spec->display_name);
#endif
  *out = point;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_point_config_trc_install (GimpOperationPointFilter *point, GObject *candidate,
                                const GlimsPointConfigTRCSpec *spec, char **error)
{
  gint trc;
#if GIMP_CHECK_VERSION (3, 2, 0)
  GBinding *staged, *old;
#endif
  if (!valid_spec (spec))
    return point_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "A point configuration specification is required.");
  if (!GIMP_IS_OPERATION_POINT_FILTER (point) || G_OBJECT_TYPE (point) != spec->operation_type)
    return point_error (GLIMS_STATUS_FAILED, error, "The native %s operation is invalid.", spec->display_name);
  if (!G_IS_OBJECT (candidate) || G_OBJECT_TYPE (candidate) != spec->config_type ||
      !glims_point_config_trc_property (candidate))
    return point_error (GLIMS_STATUS_FAILED, error, "The replacement %s configuration is invalid.", spec->display_name);
  g_object_get (candidate, "trc", &trc, NULL);
  if (!known_trc (trc))
    return point_error (GLIMS_STATUS_FAILED, error, "The replacement %s configuration is invalid.", spec->display_name);
  if (point->config == candidate) return GLIMS_STATUS_OK;
#if GIMP_CHECK_VERSION (3, 2, 0)
  /* DEFAULT does not update the point while the old config is installed. */
  staged = g_object_bind_property (candidate, "trc", point, "trc", G_BINDING_DEFAULT);
  if (!staged)
    return point_error (GLIMS_STATUS_FAILED, error, "The %s TRC binding could not be created.", spec->display_name);
  /* Target still has its old TRC. Validate endpoints, not candidate equality. */
  if (!binding_matches (staged, candidate, point)) {
    g_binding_unbind (staged);
    return point_error (GLIMS_STATUS_FAILED, error, "The staged %s TRC binding is invalid.", spec->display_name);
  }
  old = point->trc_binding;
  point->trc_binding = NULL;
  if (old) g_binding_unbind (old);
#endif
  /* Native setters duplicate a config ref (3.0:105, 3.2+:108). Ordinary refs
   * avoid that setter; GLib binding owns its initial ref, so do not unref it. */
  g_set_object (&point->config, candidate);
#if GIMP_CHECK_VERSION (3, 2, 0)
  point->trc_binding = staged; /* borrowed, compatible with native clear */
#endif
  g_object_set (point, "trc", trc, NULL);
  g_object_notify (G_OBJECT (point), "config");
  return GLIMS_STATUS_OK;
}

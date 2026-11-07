/*
 * Live filter sessions on a drawable. Runs on the engine thread.
 *
 * The engine keeps preview, commit and abort in GimpDrawableFilter (core),
 * but the undo bookkeeping of a non-destructive commit lives in GIMP's GTK
 * filter tool (app/tools/gimpfiltertool.c, gimp_filter_tool_commit). That
 * sequence is reproduced here for a new, non-destructive filter; editing an
 * existing filter is not supported yet.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo-push.h"
#include "core/gimpitem.h"

typedef struct
{
  GimpImage          *image;
  GimpDrawable       *drawable;
  GeglNode           *operation;
  GimpDrawableFilter *filter;
} GlimsFilter;

void
glims_filters_free (gpointer data)
{
  GlimsFilter *session = data;

  /* An open session the app never finished is aborted. */
  if (session->filter)
    gimp_drawable_filter_abort (session->filter);

  g_clear_object (&session->filter);
  g_clear_object (&session->operation);
  g_clear_object (&session->drawable);
  g_clear_object (&session->image);
  g_free (session);
}

gboolean
glims_filters_active_for_image (GlimsEngine *engine, GimpImage *image)
{
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init (&iter, engine->filters);
  while (g_hash_table_iter_next (&iter, NULL, &value))
    {
      GlimsFilter *session = value;
      if (session->image == image && session->filter) return TRUE;
    }
  return FALSE;
}

void
glims_filters_abort_for_image (GlimsEngine *engine, GimpImage *image)
{
  GHashTableIter iter;
  gpointer value;

  g_hash_table_iter_init (&iter, engine->filters);
  while (g_hash_table_iter_next (&iter, NULL, &value))
    {
      GlimsFilter *session = value;
      if (session->image == image)
        g_hash_table_iter_remove (&iter);
    }
}

GlimsStatus
glims_filter_begin (GlimsEngine    *engine,
                    GlimsImageID    image_id,
                    GlimsItemID     drawable_id,
                    const char     *operation,
                    GlimsFilterID  *out,
                    char          **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, image_id);
  GimpDrawable   *drawable;
  GlimsFilter    *session;
  gint            id;
  GlimsStatus     status;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! operation || ! out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  drawable = glims_lookup_drawable (open, drawable_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;
  status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;

  if (! gegl_has_operation (operation))
    {
      if (error)
        *error = strdup ("The engine has no such filter.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  session = g_new0 (GlimsFilter, 1);
  session->image     = g_object_ref (open->image);
  session->drawable  = g_object_ref (drawable);
  session->operation = gegl_node_new_child (NULL, "operation", operation, NULL);
  /* The undo step and the filter's name in the layer's filter list use the
   * operation's title ("Gaussian Blur"), as GIMP's filter tools do
   * (gimp_tool_get_undo_desc in app/tools). */
  {
    const gchar *title = gegl_operation_get_key (operation, "title");

    session->filter = gimp_drawable_filter_new (drawable, title ? title : operation,
                                                session->operation, NULL);
  }

  gimp_drawable_filter_apply (session->filter, NULL);
  gimp_drawable_filter_set_preview (session->filter, TRUE);
  gimp_image_flush (open->image);

  id = glims_next_session_id (engine);
  g_hash_table_insert (engine->filters, GINT_TO_POINTER (id), session);
  *out = id;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_set_double (GlimsEngine   *engine,
                         GlimsFilterID  id,
                         const char    *property,
                         double         value)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  GParamSpec  *pspec;
  GValue       number = G_VALUE_INIT;
  GValue       typed  = G_VALUE_INIT;

  if (! session)
    return GLIMS_STATUS_NOT_FOUND;
  if (! property)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  pspec = gegl_node_find_property (session->operation, property);
  if (! pspec)
    return GLIMS_STATUS_NOT_FOUND;

  /* Accept a number for any numeric property; GLib converts and the param
   * spec clamps to its range. */
  g_value_init (&number, G_TYPE_DOUBLE);
  g_value_set_double (&number, value);
  g_value_init (&typed, G_PARAM_SPEC_VALUE_TYPE (pspec));
  if (! g_value_transform (&number, &typed))
    {
      g_value_unset (&typed);
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  g_param_value_validate (pspec, &typed);
  gegl_node_set_property (session->operation, property, &typed);
  g_value_unset (&typed);

  gimp_drawable_filter_apply (session->filter, NULL);
  gimp_image_flush (session->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_commit (GlimsEngine    *engine,
                     GlimsFilterID   id,
                     char          **error)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  GimpDrawableFilter *filter;

  if (! session)
    return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  filter = session->filter;

  /* gimp_filter_tool_commit(), non-destructive branch, new filter. */
  gimp_drawable_filter_layer_mask_freeze (filter);
  gimp_drawable_filter_abort (filter);
  gimp_drawable_filter_apply (filter, NULL);
  if (! gimp_drawable_filter_commit (filter, TRUE, NULL, FALSE))
    return glims_fail (error, NULL, "The filter could not be applied.");

  gimp_image_undo_push_filter_add (session->image,
                                   gimp_object_get_name (GIMP_OBJECT (filter)),
                                   session->drawable, filter);

  gimp_drawable_update (session->drawable, 0, 0, -1, -1);
  gimp_image_flush (session->image);

  /* The drawable's filter stack keeps the committed filter. */
  g_clear_object (&session->filter);
  g_hash_table_remove (engine->filters, GINT_TO_POINTER (id));

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_abort (GlimsEngine   *engine,
                    GlimsFilterID  id)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  GimpImage   *image;

  if (! session)
    return GLIMS_STATUS_NOT_FOUND;

  image = g_object_ref (session->image);
  g_hash_table_remove (engine->filters, GINT_TO_POINTER (id));
  gimp_image_flush (image);
  g_object_unref (image);

  return GLIMS_STATUS_OK;
}

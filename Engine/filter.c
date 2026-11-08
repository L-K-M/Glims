/*
 * Live filter sessions on a drawable. Runs on the engine thread.
 *
 * The engine keeps preview, commit and abort in GimpDrawableFilter (core),
 * but the undo bookkeeping of a commit lives in GIMP's GTK filter tool
 * (app/tools/gimpfiltertool.c, gimp_filter_tool_commit). That sequence is
 * reproduced here for a new filter — non-destructive where the drawable's
 * XCF serialization keeps it, merged into the pixels elsewhere; editing
 * an existing filter is not supported yet.
 */
#include "engine-private.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpimage.h"
#include "core/gimpimage-quick-mask.h"
#include "core/gimpimage-undo-push.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayermask.h"

GlimsStatus
glims_filter_check_edit (GlimsEngine *engine, GlimsFilterID id, char **error)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));

  if (! session || ! gimp_item_is_attached (GIMP_ITEM (session->drawable)))
    return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  return glims_check_item_locks (GIMP_ITEM (session->drawable), GLIMS_LOCK_PIXELS, error);
}

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

/* Whether a session may point at `drawable`, and how commit leaves it.
 * TRUE keeps the filter on the drawable's stack as its own undo step;
 * FALSE merges the result into the pixels with the drawable's own undo.
 *
 * GIMP's filter tool (app/tools/gimpfiltertool.c gimp_filter_tool_commit)
 * forces destructive commits on layer masks in every version, and the
 * Quick Mask's channel must merge too: exiting the mask would otherwise
 * strand a live filter on the channel the toggle removes. A saved
 * channel keeps its filters non-destructively only where XCF serializes
 * channel effects — 3.2.6 and later (upstream 9bcb0ad5e8 "core, xcf:
 * Save channel filters in XCF"); on earlier engines only the raw
 * channel buffer is saved, so Apply has to merge for the result to
 * persist. Layers stay non-destructive everywhere. The image's
 * selection mask is not a filter target. */
static gboolean
filter_commit_policy (GimpImage    *image,
                      GimpDrawable *drawable,
                      gboolean     *non_destructive,
                      char        **error)
{
  if (GIMP_IS_LAYER (drawable))
    {
      *non_destructive = TRUE;
      return TRUE;
    }

  if (GIMP_IS_LAYER_MASK (drawable))
    {
      *non_destructive = FALSE;
      return TRUE;
    }

  if (GIMP_IS_CHANNEL (drawable))
    {
      if (gimp_item_get_container (GIMP_ITEM (drawable)) !=
          gimp_image_get_channels (image))
        {
          glims_fail (error, NULL,
                      "Filters cannot be applied to the selection mask.");
          return FALSE;
        }

      if (gimp_image_get_quick_mask_state (image) &&
          GIMP_CHANNEL (drawable) == gimp_image_get_quick_mask (image))
        {
          *non_destructive = FALSE;
        }
      else
        {
#if GIMP_CHECK_VERSION (3, 2, 6)
          *non_destructive = TRUE;
#else
          *non_destructive = FALSE;
#endif
        }
      return TRUE;
    }

  glims_fail (error, NULL,
              "Filters can only be applied to layers, layer masks and channels.");
  return FALSE;
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
  gboolean        non_destructive;
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
  if (! filter_commit_policy (open->image, drawable, &non_destructive, error))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;

  if (! glims_filter_operation_allowed (operation))
    {
      if (error)
        *error = strdup ("That operation cannot be used as an image filter.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  session = g_new0 (GlimsFilter, 1);
  session->image           = g_object_ref (open->image);
  session->drawable        = g_object_ref (drawable);
  session->non_destructive = non_destructive;
  session->operation = gegl_node_new_child (NULL, "operation", operation, NULL);
  /* The undo step and the filter's name in the layer's filter list use the
   * operation's title ("Gaussian Blur"), as GIMP's filter tools do
   * (gimp_tool_get_undo_desc in app/tools). */
  {
    const gchar *title = gegl_operation_get_key (operation, "title");

    session->filter = gimp_drawable_filter_new (drawable, title ? title : operation,
                                                session->operation, NULL);
  }

  /* A live preview sits on the drawable's stack but is not a committed
   * effect: mark it temporary, as the engine's tools do with their
   * editing filters — XCF skips temporary filters, and drawable_effects
   * counts only committed ones. Commit flips the flag back. */
  gimp_drawable_filter_set_temporary (session->filter, TRUE);
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
  GlimsStatus  status = glims_filter_check_edit (engine, id, NULL);

  if (status != GLIMS_STATUS_OK) return status;
  if (! property || ! isfinite (value))
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
  GlimsStatus status = glims_filter_check_edit (engine, id, error);

  if (status != GLIMS_STATUS_OK) return status;

  filter = session->filter;

  /* gimp_filter_tool_commit(), new filter: the selection-mask hookup
   * freezes first either way. The abort/re-apply and the filter-add
   * undo step belong to the non-destructive branch only; a destructive
   * commit merges through gimp_drawable_merge_filter, which pushes the
   * drawable's own undo. */
  gimp_drawable_filter_layer_mask_freeze (filter);
  if (session->non_destructive)
    {
      gimp_drawable_filter_abort (filter);
      gimp_drawable_filter_apply (filter, NULL);
    }
  if (! gimp_drawable_filter_commit (filter, session->non_destructive, NULL, FALSE))
    return glims_fail (error, NULL, "The filter could not be applied.");

  if (session->non_destructive)
    {
      /* Committed now: no longer a temporary preview. */
      gimp_drawable_filter_set_temporary (filter, FALSE);
      gimp_image_undo_push_filter_add (session->image,
                                       gimp_object_get_name (GIMP_OBJECT (filter)),
                                       session->drawable, filter);
    }

  gimp_drawable_update (session->drawable, 0, 0, -1, -1);
  gimp_image_flush (session->image);

  /* A non-destructive commit leaves the filter on the drawable's stack;
   * a merged one was consumed by it. Either way the session is over. */
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

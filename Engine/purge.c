/* Edit > Purge: free undo histories and the engine's clipboard state
 * without touching pixels. Runs on the engine thread.
 *
 * The classic editor's Purge frees memory; none of its targets can be
 * undone, so the interface confirms first. Every affected image is
 * preflighted before anything is freed, so a busy document cannot leave
 * a half-purged set. Upstream gimp_image_undo_free emits UNDO_FREE, which
 * image.c already turns into GLIMS_EVENT_UNDO_CHANGED; no second event is
 * emitted here. Upstream also keeps a dirty image dirty, which is left as
 * it is.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpimage-undo.h"

#define GLIMS_PURGE_KNOWN (GLIMS_PURGE_UNDO | GLIMS_PURGE_CLIPBOARD | GLIMS_PURGE_HISTORIES)

/* The image may be purged now: the same readiness an edit needs, so a
 * stroke, filter, plug-in, progress callback or open undo group keeps its
 * history. Matches Engine/lab-layer-fill.c. */
static gboolean
purge_image_ready (GlimsEngine *engine,
                   GimpImage   *image)
{
  return engine->busy == 0 && engine->progress == NULL &&
         g_hash_table_size (engine->strokes) == 0 &&
         g_hash_table_size (engine->filters) == 0 &&
         gimp_image_undo_is_enabled (image) &&
         gimp_image_get_undo_group_count (image) == 0;
}

GlimsStatus
glims_edit_purge (GlimsEngine *engine,
                  GlimsImageID image,
                  uint32_t     targets,
                  char       **error)
{
  GlimsOpenImage *open = NULL;
  GPtrArray      *history_images = NULL;
  GHashTableIter  iter;
  gpointer        value;
  GlimsStatus     status = GLIMS_STATUS_OK;

  if (error) *error = NULL;
  if (targets == 0 || (targets & ~GLIMS_PURGE_KNOWN))
    {
      if (error) *error = strdup ("Choose what to purge.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if ((targets & GLIMS_PURGE_UNDO) == 0 && image != 0)
    {
      if (error) *error = strdup ("Only Purge Undo names an image.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (targets & GLIMS_PURGE_UNDO)
    {
      open = image != 0 ? glims_lookup_image (engine, image) : NULL;
      if (! open) return GLIMS_STATUS_NOT_FOUND;
    }

  history_images = g_ptr_array_new ();
  if (targets & GLIMS_PURGE_HISTORIES)
    {
      g_hash_table_iter_init (&iter, engine->images);
      while (g_hash_table_iter_next (&iter, NULL, &value))
        g_ptr_array_add (history_images, ((GlimsOpenImage *) value)->image);
    }
  else if (targets & GLIMS_PURGE_UNDO)
    g_ptr_array_add (history_images, open->image);

  /* Preflight every target image before freeing any of them. */
  for (guint i = 0; i < history_images->len; i++)
    if (! purge_image_ready (engine, g_ptr_array_index (history_images, i)))
      {
        if (error) *error = strdup ("Finish the current operation before purging.");
        status = GLIMS_STATUS_BUSY;
        goto done;
      }

  for (guint i = 0; i < history_images->len; i++)
    gimp_image_undo_free (g_ptr_array_index (history_images, i));

  if (targets & GLIMS_PURGE_CLIPBOARD)
    {
      gimp_set_clipboard_image (engine->gimp, NULL);
      gimp_set_clipboard_buffer (engine->gimp, NULL);
      gimp_container_clear (engine->gimp->named_buffers);
    }

done:
  g_ptr_array_unref (history_images);
  return status;
}

/* Native undo history and independent image snapshots. Engine thread only. */
#include "engine-private.h"

#include <string.h>

#include "core/gimpcontainer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimpimage-undo.h"
#include "core/gimpundostack.h"

GlimsStatus
glims_image_history (GlimsEngine *engine, GlimsImageID id,
                     GlimsHistoryRow *rows, int32_t capacity, GlimsHistoryInfo *info)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpUndoStack *undos, *redos;
  gint n_undos, n_redos, i;

  if (! open) return GLIMS_STATUS_NOT_FOUND;
  if (! info || capacity < 0) return GLIMS_STATUS_INVALID_ARGUMENT;

  undos = gimp_image_get_undo_stack (open->image);
  redos = gimp_image_get_redo_stack (open->image);
  n_undos = gimp_undo_stack_get_depth (undos);
  n_redos = gimp_undo_stack_get_depth (redos);
  *info = (GlimsHistoryInfo) { open->history_revision, n_undos + n_redos + 1, n_undos };
  for (i = 0; rows && i < MIN (capacity, info->count); i++)
    {
      const gchar *name = "Earliest State";
      GimpObject *undo = NULL;

      if (i > 0 && i <= n_undos)
        undo = gimp_container_get_child_by_index (undos->undos, n_undos - i);
      else if (i > n_undos)
        undo = gimp_container_get_child_by_index (redos->undos, i - n_undos - 1);
      if (undo) name = gimp_object_get_name (undo);
      memset (&rows[i], 0, sizeof rows[i]);
      rows[i].position = i;
      g_strlcpy (rows[i].name, name ? name : "Edit", sizeof rows[i].name);
    }
  return GLIMS_STATUS_OK;
}

/* The image may be edited now: no plug-in, stroke session or filter
 * preview is running against it. Refusing here keeps live sessions
 * intact. */
GlimsStatus
glims_edit_ready (GlimsEngine *engine, GlimsOpenImage *open, char **error)
{
  if (engine->busy > 0 || g_hash_table_size (engine->strokes) > 0 ||
      glims_filters_active_for_image (engine, open->image))
    {
      if (error) *error = strdup ("Finish the stroke or close the filter dialog first.");
      return GLIMS_STATUS_BUSY;
    }
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_history_move (GlimsEngine *engine, GlimsImageID id,
                          uint64_t revision, int32_t position, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsHistoryInfo info;
  GlimsStatus status;
  gint i;

  if (! open) return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  glims_image_history (engine, id, NULL, 0, &info);
  if (revision != info.revision || position < 0 || position >= info.count)
    {
      if (error) *error = strdup ("The image history changed. Select the state again.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  /* Each popped state can thaw a link layer — a file reload that runs a
   * load plug-in and its nested main loop — so busy is held across the
   * whole walk. */
  engine->busy++;
  for (i = info.current_position; i > position; i--)
    if (! gimp_image_undo (open->image))
      {
        engine->busy--;
        return glims_fail (error, NULL, "The image could not reach the selected history state.");
      }
  for (i = info.current_position; i < position; i++)
    if (! gimp_image_redo (open->image))
      {
        engine->busy--;
        return glims_fail (error, NULL, "The image could not reach the selected history state.");
      }
  engine->busy--;
  gimp_image_flush (open->image);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_duplicate (GlimsEngine *engine, GlimsImageID id,
                       GlimsImageID *result, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpImage *copy;
  GlimsStatus status;

  if (result) *result = 0;
  if (! open) return GLIMS_STATUS_NOT_FOUND;
  if (! result) return GLIMS_STATUS_INVALID_ARGUMENT;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  copy = gimp_image_duplicate (open->image);
  if (! copy) return glims_fail (error, NULL, "The image snapshot could not be created.");
  GlimsStatus adopted = glims_adopt_image (engine, copy, result);
  if (adopted != GLIMS_STATUS_OK) g_object_unref (copy);
  return adopted;
}

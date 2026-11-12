/*
 * File > Open as Layers and File > Place: importing a file's layers into
 * an image that is already open. Runs on the engine thread.
 *
 * Both go through the engine's own layer import: file_open_layers loads
 * the file into a temporary image (or, for a link, builds a link layer
 * over a GimpLink) and converts the items for the destination image;
 * gimp_image_add_layers then inserts them above the selected layer,
 * centers the imported stack on the canvas, wraps the insert in one
 * undo group and selects the result — exactly what GIMP's own open
 * dialog does (app/dialogs/file-open-dialog.c
 * file_open_dialog_open_layers). The temporary image is unreffed inside
 * file_open_layers, so nothing of it reaches the facade's image table.
 */
#include "engine-private.h"
#include "tiff-import.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"

#include "file/file-open.h"

#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
#include "plug-in/gimppluginprocedure.h"

#include "gimp-intl.h"

/* Shared by Open as Layers and Place. On success the new layer ids are
 * written to `layers` (top first, up to `capacity`) and `count` reports
 * how many were added. */
static GlimsStatus
import_file_layers (GlimsEngine  *engine,
                    GlimsImageID  id,
                    const char   *path,
                    gboolean      as_link,
                    const char   *undo_desc,
                    GlimsItemID  *layers,
                    int32_t       capacity,
                    int32_t      *count,
                    char        **error)
{
  GlimsOpenImage    *open;
  GFile             *file;
  GimpPlugInProcedure *file_proc;
  GList             *new_layers;
  GList             *iter;
  GimpPDBStatusType  status = GIMP_PDB_EXECUTION_ERROR;
  GError            *gerror = NULL;
  GlimsStatus        ready;
  int32_t            n;
  GlimsVectorLoadGuard *vector_guard;
  g_autoptr(GFile) tiff_source = NULL;

  if (count)
    *count = 0;

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! path || ! count || capacity < 0 || (! layers && capacity > 0))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  ready = glims_edit_ready (engine, open, error);
  if (ready != GLIMS_STATUS_OK)
    return ready;

  /* g_file_new_for_path would take a URI as a plain filename (which the
   * loader then reports as missing); a URI is not a filesystem path, and
   * link layers require a native file outright. */
  if (strstr (path, "://") != NULL)
    {
      if (error)
        *error = strdup ("Use a filesystem path, not a URI.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  file = g_file_new_for_path (path);
  if (! g_file_is_native (file))
    {
      g_object_unref (file);
      if (error)
        *error = strdup ("Only local file paths can be opened as layers.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* Resolve the loader first: when the destination was saved and the
   * file has no loader, the link path's circular-reference check calls
   * gimp_plug_in_procedure_is_xcf_load on a NULL procedure and logs a
   * CRITICAL before failing anyway. Passing the procedure in reports the
   * same failure without it. */
  file_proc = gimp_plug_in_manager_file_procedure_find (engine->gimp->plug_in_manager,
                                                      GIMP_FILE_PROCEDURE_GROUP_OPEN,
                                                      file, &gerror);
  if (! file_proc)
    {
      g_object_unref (file);
      return glims_fail (error, gerror, "The file could not be opened as layers.");
    }

  /* A live link must retain its original path for later reloads. Raster
   * layer import can use the same private TIFF preparation as Open. */
  if (!as_link && !g_strcmp0 (gimp_object_get_name (file_proc), "file-tiff-load") &&
      !glims_tiff_import_prepare (file, &tiff_source, &gerror))
    {
      g_object_unref (file);
      return glims_fail (error, gerror, "The TIFF file could not be prepared for import.");
    }

  /* Non-XCF formats load through a plug-in, which nests a main loop. */
  engine->busy++;
  vector_guard = glims_vector_load_guard_begin (engine, open->image);
#if GIMP_CHECK_VERSION (3, 2, 0)
  new_layers = file_open_layers (engine->gimp, gimp_get_user_context (engine->gimp),
                                 NULL, open->image, FALSE, as_link,
                                 tiff_source ? tiff_source : file,
                                 GIMP_RUN_NONINTERACTIVE, file_proc, &status, &gerror);
#else
  new_layers = file_open_layers (engine->gimp, gimp_get_user_context (engine->gimp),
                                 NULL, open->image, FALSE,
                                 tiff_source ? tiff_source : file,
                                 GIMP_RUN_NONINTERACTIVE, file_proc, &status, &gerror);
#endif
  engine->busy--;

  glims_tiff_import_prepared_cleanup (tiff_source);
  g_object_unref (file);

  if (! new_layers)
    {
      glims_vector_load_guard_end (vector_guard);
      if (status == GIMP_PDB_CANCEL)
        {
          g_clear_error (&gerror);
          return GLIMS_STATUS_CANCELLED;
        }
      return glims_fail (error, gerror, "The file could not be opened as layers.");
    }

  /* Inserts above the selected layer (or inside it when it is a group),
   * shifts the imported stack so it is centered on the canvas, wraps the
   * whole insert in one undo group and selects the new layers. */
  gimp_image_add_layers (open->image, new_layers, GIMP_IMAGE_ACTIVE_PARENT, -1,
                         0, 0,
                         gimp_image_get_width (open->image),
                         gimp_image_get_height (open->image),
                         undo_desc);
  glims_vector_load_guard_end (vector_guard);

  n = 0;
  for (iter = new_layers; iter; iter = iter->next)
    {
      if (layers && n < capacity)
        layers[n] = gimp_item_get_id (GIMP_ITEM (iter->data));
      n++;
    }
  *count = n;

  g_list_free (new_layers);
  g_clear_error (&gerror);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_open_layers (GlimsEngine  *engine,
                         GlimsImageID  id,
                         const char   *path,
                         GlimsItemID  *layers,
                         int32_t       capacity,
                         int32_t      *count,
                         char        **error)
{
  return import_file_layers (engine, id, path, FALSE, _("Open as Layers"),
                             layers, capacity, count, error);
}

GlimsStatus
glims_image_place_link (GlimsEngine  *engine,
                        GlimsImageID  id,
                        const char   *path,
                        GlimsItemID  *layer,
                        char        **error)
{
  if (layer)
    *layer = 0;

#if GIMP_CHECK_VERSION (3, 2, 0)
  {
    GlimsItemID placed = 0;
    int32_t     count  = 0;
    GlimsStatus status;

    status = import_file_layers (engine, id, path, TRUE, _("Place"),
                                 &placed, 1, &count, error);
    if (status != GLIMS_STATUS_OK)
      return status;
    if (count < 1)
      return glims_fail (error, NULL, "Placing the file produced no layer.");

    if (layer)
      *layer = placed;
    return GLIMS_STATUS_OK;
  }
#else
  /* Link layers arrived in GIMP 3.2; placing on an older engine must
   * not degrade to a raster copy. */
  if (! glims_lookup_image (engine, id))
    return GLIMS_STATUS_NOT_FOUND;
  if (! path)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (error)
    *error = strdup ("This engine cannot place linked layers; link layers need GIMP 3.2.");
  return GLIMS_STATUS_UNSUPPORTED;
#endif
}

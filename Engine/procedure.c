/*
 * Plug-in procedures: listing those with menu entries and running one on an
 * image the way GIMP's own menus do (app/actions/plug-in-commands.c and
 * procedure-commands.c, procedure_commands_get_display_args), minus the
 * display, which Glims does not have.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpparamspecs.h"
#include "core/gimpprogress.h"

#include "pdb/gimppdb.h"
#include "pdb/gimpprocedure.h"

#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginprocedure.h"

/* GIMP keeps this check private to app/actions/procedure-commands.c. */
static gboolean
is_run_mode_param (GParamSpec *pspec)
{
  return G_IS_PARAM_SPEC_ENUM (pspec) && pspec->value_type == GIMP_TYPE_RUN_MODE;
}

/* The procedure's entry in the image window's menus ("<Image>/..."), or
 * NULL. Entries in the layer, channel or path context menus take those
 * items instead of the image's selected drawables, so they are not offered. */
static const gchar *
image_menu_path (GimpPlugInProcedure *proc)
{
  GList *list;

  for (list = proc->menu_paths; list; list = list->next)
    if (g_str_has_prefix (list->data, "<Image>/"))
      return list->data;

  return NULL;
}

/* Procedures the image menus offer: an image menu entry, and (run-mode,
 * image, ...) arguments. */
static gboolean
is_image_procedure (GimpProcedure *procedure)
{
  GimpPlugInProcedure *proc;

  if (! GIMP_IS_PLUG_IN_PROCEDURE (procedure))
    return FALSE;

  proc = GIMP_PLUG_IN_PROCEDURE (procedure);

  return (! proc->file_proc        &&
          proc->menu_label         &&
          image_menu_path (proc)   &&
          procedure->num_args >= 2 &&
          is_run_mode_param (procedure->args[0]) &&
          GIMP_IS_PARAM_SPEC_IMAGE (procedure->args[1]));
}

/* "_Sparkle..." becomes "Sparkle…", the macOS form of a command that asks
 * for settings first. */
static gchar *
menu_title (GimpPlugInProcedure *proc)
{
  gchar *title = gimp_strip_uline (proc->menu_label);
  gsize  length = strlen (title);

  if (length >= 3 && strcmp (title + length - 3, "...") == 0)
    {
      gchar *ellipsized;

      title[length - 3] = '\0';
      ellipsized = g_strconcat (title, "\342\200\246", NULL);
      g_free (title);
      title = ellipsized;
    }

  return title;
}

GlimsStatus
glims_procedures (GlimsEngine        *engine,
                  GlimsImageID        id,
                  GlimsProcedureInfo *rows,
                  int32_t             capacity,
                  int32_t            *count)
{
  GimpImage *image = NULL;
  GSList    *iter;
  int32_t    n     = 0;

  if (! count || capacity < 0 || (capacity > 0 && ! rows))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  if (id)
    {
      GlimsOpenImage *open = glims_lookup_image (engine, id);

      if (! open)
        return GLIMS_STATUS_NOT_FOUND;

      image = open->image;
    }

  for (iter = engine->gimp->plug_in_manager->plug_in_procedures; iter; iter = iter->next)
    {
      GimpProcedure       *procedure = iter->data;
      GimpPlugInProcedure *proc;

      if (! is_image_procedure (procedure))
        continue;

      proc = GIMP_PLUG_IN_PROCEDURE (procedure);

      if (n < capacity)
        {
          GlimsProcedureInfo *row    = &rows[n];
          const gchar        *reason = NULL;
          const gchar        *blurb  = gimp_procedure_get_blurb (procedure);
          gchar              *title  = menu_title (proc);

          memset (row, 0, sizeof (*row));
          g_strlcpy (row->name, gimp_object_get_name (procedure), sizeof (row->name));
          g_strlcpy (row->label, title, sizeof (row->label));
          g_strlcpy (row->menu_path, image_menu_path (proc), sizeof (row->menu_path));
          g_strlcpy (row->blurb, blurb ? blurb : "", sizeof (row->blurb));
          row->sensitive = gimp_procedure_get_sensitive (procedure,
                                                         image ? GIMP_OBJECT (image) : NULL,
                                                         &reason);
          g_free (title);
        }

      n++;
    }

  *count = n;

  return GLIMS_STATUS_OK;
}

/* The arguments GIMP's menus pass: run mode, image, the selected drawables,
 * and nothing else, so the plug-in uses its own defaults or last values
 * for the rest. */
static GimpValueArray *
image_arguments (GimpProcedure  *procedure,
                 GimpImage      *image,
                 GimpRunMode     run_mode,
                 GError        **error)
{
  GimpValueArray *args   = gimp_procedure_get_arguments (procedure);
  gint            n_args = 0;
  GList          *drawables;

  g_value_set_enum (gimp_value_array_index (args, n_args++), run_mode);
  g_value_set_object (gimp_value_array_index (args, n_args++), image);

  drawables = gimp_image_get_selected_drawables (image);

  if (gimp_value_array_length (args) > n_args &&
      GIMP_IS_PARAM_SPEC_DRAWABLE (procedure->args[n_args]))
    {
      /* A deprecated single-drawable plug-in. */
      if (! drawables)
        {
          g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                               "Select a layer first.");
          g_list_free (drawables);
          gimp_value_array_unref (args);
          return NULL;
        }

      g_value_set_object (gimp_value_array_index (args, n_args++), drawables->data);
    }
  else if (gimp_value_array_length (args) > n_args &&
           GIMP_IS_PARAM_SPEC_CORE_OBJECT_ARRAY (procedure->args[n_args]))
    {
      gint           n_drawables = g_list_length (drawables);
      GimpDrawable **array       = g_new0 (GimpDrawable *, n_drawables + 1);
      GList         *list;
      gint           i;

      for (list = drawables, i = 0; list; list = list->next, i++)
        array[i] = list->data;

      g_value_set_boxed (gimp_value_array_index (args, n_args++), (GObject **) array);
      g_free (array);
    }

  g_list_free (drawables);
  gimp_value_array_truncate (args, n_args);

  return args;
}

GlimsStatus
glims_procedure_run (GlimsEngine   *engine,
                     GlimsImageID   id,
                     const char    *name,
                     uint32_t       run_mode,
                     char         **error)
{
  GlimsOpenImage    *open = glims_lookup_image (engine, id);
  GimpProcedure     *procedure;
  GimpImage         *image;
  GimpValueArray    *args;
  GimpValueArray    *return_vals;
  GlimsProgress     *progress;
  GimpPDBStatusType  pdb_status;
  GimpRunMode        gimp_run_mode;
  const gchar       *reason = NULL;
  GError            *gerror = NULL;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! name)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  switch (run_mode)
    {
    case GLIMS_RUN_INTERACTIVE:      gimp_run_mode = GIMP_RUN_INTERACTIVE;     break;
    case GLIMS_RUN_WITH_LAST_VALUES: gimp_run_mode = GIMP_RUN_WITH_LAST_VALS;  break;
    default:                         return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  /* A stroke or filter preview left open would keep changing the image
   * the plug-in reads, from inside its run. */
  if (g_hash_table_size (engine->strokes) > 0 || g_hash_table_size (engine->filters) > 0)
    {
      glims_fail (error, NULL, "Finish the stroke or close the filter dialog first.");
      return GLIMS_STATUS_BUSY;
    }

  procedure = gimp_pdb_lookup_procedure (engine->gimp->pdb, name);
  if (! procedure || ! is_image_procedure (procedure))
    return GLIMS_STATUS_NOT_FOUND;

  if (! gimp_procedure_get_sensitive (procedure, GIMP_OBJECT (open->image), &reason))
    return glims_fail (error, NULL, reason ? reason : "This command does not work on the selected layers.");

  /* The app may close the image while the plug-in runs (the engine keeps
   * serving calls in a nested loop); `open` may be freed by then. */
  image = g_object_ref (open->image);
  open  = NULL;

  args = image_arguments (procedure, image, gimp_run_mode, &gerror);
  if (! args)
    {
      g_object_unref (image);
      return glims_fail (error, gerror, "The command could not be started.");
    }

  /* A progress object per run: GIMP ends a plug-in's progress when its
   * process has quit, which can be after this call returned and a next run
   * started. Ending this run's own object here keeps that late end from
   * reaching the next run. */
  progress = glims_progress_new (engine);
  engine->progress = progress;

  engine->busy++;
  return_vals = gimp_procedure_execute (procedure, engine->gimp,
                                        gimp_get_user_context (engine->gimp),
                                        GIMP_PROGRESS (progress),
                                        args, &gerror);
  engine->busy--;

  if (gimp_progress_is_active (GIMP_PROGRESS (progress)))
    gimp_progress_end (GIMP_PROGRESS (progress));
  engine->progress = NULL;
  g_object_unref (progress);

  gimp_value_array_unref (args);

  pdb_status = return_vals ? g_value_get_enum (gimp_value_array_index (return_vals, 0))
                           : GIMP_PDB_EXECUTION_ERROR;
  g_clear_pointer (&return_vals, gimp_value_array_unref);

  /* Shows what the plug-in changed; GIMP's menus flush the displays here. */
  gimp_image_flush (image);
  g_object_unref (image);

  switch (pdb_status)
    {
    case GIMP_PDB_SUCCESS:
      g_clear_error (&gerror);
      return GLIMS_STATUS_OK;

    case GIMP_PDB_CANCEL:
      g_clear_error (&gerror);
      return GLIMS_STATUS_CANCELLED;

    default:
      return glims_fail (error, gerror, "The plug-in failed.");
    }
}

GlimsStatus
glims_procedure_cancel (GlimsEngine *engine)
{
  if (! engine->progress || ! gimp_progress_is_active (GIMP_PROGRESS (engine->progress)))
    return GLIMS_STATUS_NOT_FOUND;

  gimp_progress_cancel (GIMP_PROGRESS (engine->progress));

  return GLIMS_STATUS_OK;
}

/* Script-Fu expands the already-expanded gimprc query result once more.
 * Keep the workaround inside the adapter and only for the bundled clients. */
#include "engine-private.h"
#include "script-fu-path-fix.h"

#ifdef __APPLE__
#include <libproc.h>
#include <stdlib.h>
#include <string.h>

#include "config/gimprc.h"
#include "core/gimp.h"
#include "pdb/gimppdb.h"
#include "pdb/gimpprocedure.h"
#include "plug-in/gimpplugin.h"
#include "plug-in/gimppluginmanager.h"

typedef struct {
  GimpProcedure *original;
  gchar *dollar_var;
  gchar *tilde_var;
  gboolean dollar_set;
  gboolean tilde_set;
  gchar *executables[3];
} ScriptFuPathFix;

static void
script_fu_path_fix_free (gpointer data)
{
  ScriptFuPathFix *fix = data;
  if (fix->dollar_set) g_unsetenv (fix->dollar_var);
  if (fix->tilde_set) g_unsetenv (fix->tilde_var);
  g_free (fix->dollar_var);
  g_free (fix->tilde_var);
  for (guint i = 0; i < G_N_ELEMENTS (fix->executables); i++)
    free (fix->executables[i]);
  g_clear_object (&fix->original);
  g_free (fix);
}

static gboolean
is_bundled_script_fu (Gimp *gimp, ScriptFuPathFix *fix)
{
  GimpPlugIn *plug_in = gimp->plug_in_manager->current_plug_in;
  char path[PROC_PIDPATHINFO_MAXSIZE];
  if (!plug_in || plug_in->pid <= 0 || proc_pidpath (plug_in->pid, path, sizeof path) <= 0)
    return FALSE;
  for (guint i = 0; i < G_N_ELEMENTS (fix->executables); i++)
    if (fix->executables[i] && strcmp (path, fix->executables[i]) == 0)
      return TRUE;
  return FALSE;
}

static GimpValueArray *
script_fu_gimprc_query (GimpProcedure *procedure, Gimp *gimp, GimpContext *context,
                        GimpProgress *progress, const GimpValueArray *args, GError **error)
{
  ScriptFuPathFix *fix = g_object_get_data (G_OBJECT (gimp), "glims-script-fu-path-fix");
  const gchar *token = g_value_get_string (gimp_value_array_index (args, 0));
  GimpPlugIn *plug_in = gimp->plug_in_manager->current_plug_in;
  guint queries = plug_in ? GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (plug_in),
                                                                  "glims-script-path-queries")) : 0;
  if (!fix || g_strcmp0 (token, "script-fu-path") || !is_bundled_script_fu (gimp, fix) || queries >= 3)
    {
      GimpValueArray *pass = gimp_procedure_get_return_values (procedure, TRUE, NULL);
      g_value_set_enum (gimp_value_array_index (pass, 0), GIMP_PDB_PASS_THROUGH);
      return pass;
    }

  /* In each supported bundled Script-Fu, C initialization asks once for the
   * search path and twice for init directories, before any Scheme code can
   * call the PDB. Later queries belong to scripts and retain the public PDB
   * result unchanged. Keep this in sync with upstream on engine updates. */
  g_object_set_data (G_OBJECT (plug_in), "glims-script-path-queries", GUINT_TO_POINTER (queries + 1));

  GimpValueArray *result = gimp_procedure_execute (fix->original, gimp, context, progress,
                                                    (GimpValueArray *) args, error);
  if (!result || g_value_get_enum (gimp_value_array_index (result, 0)) != GIMP_PDB_SUCCESS ||
      gimp_value_array_length (result) < 2)
    return result;

  GValue *value = gimp_value_array_index (result, 1);
  const gchar *path = g_value_get_string (value);
  gchar *raw = NULL;
  g_object_get (gimp->edit_config, "script-fu-path", &raw, NULL);
  gchar *expanded = raw ? gimp_config_path_expand (raw, FALSE, NULL) : NULL;
  /* If the first expansion failed, preserve GIMP's existing error behavior. */
  if (path && expanded && strcmp (path, expanded) == 0 &&
      (strchr (path, '~') || strstr (path, "${")))
    {
      GString *encoded = g_string_new (NULL);
      for (const gchar *p = path; *p; p++)
        {
          if (*p == '~') g_string_append_printf (encoded, "${%s}", fix->tilde_var);
          else if (*p == '$' && p[1] == '{') g_string_append_printf (encoded, "${%s}", fix->dollar_var);
          else g_string_append_c (encoded, *p);
        }
      g_value_take_string (value, g_string_free (encoded, FALSE));
    }
  g_free (expanded);
  g_free (raw);
  return result;
}

void
glims_script_fu_path_fix_install (Gimp *gimp, const gchar *contents)
{
  if (!contents) return;
  /* The three-query initialization sequence was checked in these engine
   * versions only. New versions must be reviewed and tested before opt-in. */
  if (GIMP_MAJOR_VERSION != 3 ||
      !((GIMP_MINOR_VERSION == 0 && GIMP_MICRO_VERSION == 8) ||
        (GIMP_MINOR_VERSION == 2 && (GIMP_MICRO_VERSION == 0 || GIMP_MICRO_VERSION == 8)) ||
        (GIMP_MINOR_VERSION == 3 && GIMP_MICRO_VERSION == 1)))
    return;
  GimpProcedure *original = gimp_pdb_lookup_procedure (gimp->pdb, "gimp-gimprc-query");
  if (!original) return;
  ScriptFuPathFix *fix = g_new0 (ScriptFuPathFix, 1);
  gchar *uuid = g_uuid_string_random ();
  for (gchar *p = uuid; *p; p++) if (*p == '-') *p = '_';
  fix->dollar_var = g_strconcat ("GLIMS_SCRIPT_DOLLAR_", uuid, NULL);
  fix->tilde_var = g_strconcat ("GLIMS_SCRIPT_TILDE_", uuid, NULL);
  g_free (uuid);
  if (g_getenv (fix->dollar_var) || g_getenv (fix->tilde_var))
    { script_fu_path_fix_free (fix); return; }
  fix->dollar_set = g_setenv (fix->dollar_var, "$", FALSE);
  fix->tilde_set = g_setenv (fix->tilde_var, "~", FALSE);
  if (!fix->dollar_set || !fix->tilde_set)
    { script_fu_path_fix_free (fix); return; }
  const gchar *paths[] = { "lib/gimp/3.0/plug-ins/script-fu/script-fu",
                           "lib/gimp/3.0/plug-ins/script-fu-server/script-fu-server",
                           "MacOS/gimp-script-fu-interpreter-3.0" };
  for (guint i = 0; i < G_N_ELEMENTS (paths); i++)
    {
      gchar *path = g_build_filename (contents, paths[i], NULL);
      fix->executables[i] = realpath (path, NULL);
      g_free (path);
    }
  fix->original = g_object_ref (original);
  GimpProcedure *override = gimp_procedure_create_override (original, script_fu_gimprc_query);
  g_object_set_data_full (G_OBJECT (gimp), "glims-script-fu-path-fix", fix, script_fu_path_fix_free);
  gimp_pdb_register_procedure (gimp->pdb, override);
  g_object_unref (override);
}
#else
void glims_script_fu_path_fix_install (Gimp *gimp, const gchar *contents)
{ (void) gimp; (void) contents; }
#endif

/*
 * Engine lifecycle, the engine thread, and the facade table.
 *
 * GIMP's engine is not thread-safe and runs its own GLib main loop (plug-in
 * calls even nest loops). It therefore lives on one dedicated thread that
 * owns GLib's default main context. Facade calls from any other thread are
 * queued onto that context and wait for their result, so a nested loop
 * blocks only the engine thread, never the app's main thread.
 *
 * Start-up follows GIMP's own app/app.c (app_run and app_activate_callback)
 * for the console build, minus what a host app must not do: no command-line
 * parsing, no signal handlers, no crash dialogs, no update check over the
 * network, and no change to the process locale.
 */
#include "engine-private.h"
#include "facade-policy.h"
#include "plate-preview.h"
#include "lab-layer-preview.h"
#include "lab-layer-storage.h"
#include "lab-layer-fill.h"
#include "lab-transform.h"
#include "display-sample.h"
#include "component-document.h"
#include "operation-posterize.h"
#include "operation-selective-color.h"
#include "resource-mutation.h"
#include "resource-rename.h"
#include "layer-delete.h"
#include "layer-fit.h"
#include "layer-rasterize.h"
#include "layer-restore.h"
#include "curves-config.h"
#include "filter-histogram.h"
#include "filter-input.h"
#include "startup-helper.h"
#include "script-fu-path-fix.h"

#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <glib/gstdio.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "libgimpbase/gimpbase-private.h"

#include "config/gimprc.h"

#include "gegl/gimp-gegl.h"

#include "core/gimp.h"
#include "core/gimp-user-install.h"
#include "core/gimpgrid.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimpprojection.h"

#include "paint/gimppaintcore.h"
#include "plug-in/gimpplugin.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/plug-in-rc.h"
#include "paint/gimppaintoptions.h"

#include "errors.h"
#include "gimpconsoleapp.h"
#include "language.h"
#include "sanity.h"

/* Paths of the engine build this library was linked against, passed by
 * scripts/build-adapter.sh. Plug-ins are separate processes and need them
 * to find GIMP's GObject introspection data. */
#if ! defined (GLIMS_ENGINE_TYPELIB_PATH) || ! defined (GLIMS_ENGINE_BIN_PATH)
#error "GLIMS_ENGINE_TYPELIB_PATH and GLIMS_ENGINE_BIN_PATH must be defined by the build"
#endif

/* ---- Calls onto the engine thread ------------------------------------- */

typedef struct
{
  GlimsEngine     *engine;
  GlimsEngineFunc  func;
  gpointer         data;
  GlimsStatus      status;
  gboolean         done;
  gboolean         allow_during_stop;
} GlimsCall;

static gboolean
call_dispatch (gpointer user_data)
{
  GlimsCall *call   = user_data;
  gboolean   nested = g_main_depth () > 1;
  gboolean   execute;

  g_mutex_lock (&call->engine->lock);
  execute = call->allow_during_stop || ! call->engine->stopping;
  g_mutex_unlock (&call->engine->lock);

  /* A dispatch at main depth > 1 means the engine thread sits inside a
   * nested main loop — a plug-in call or another long operation that
   * iterates the context, such as a link layer reloading its changed
   * file. Not every native path raises `busy` itself (the link monitor's
   * reload runs with no facade call around it), so raise it for this
   * call's duration: mutation gates refuse while reads and cancellation
   * remain deliverable. Nesting itself never blocks RPC dispatch. */

  if (execute)
    {
      if (nested)
        call->engine->busy++;
      call->status = call->func (call->engine, call->data);
      if (nested)
        call->engine->busy--;
    }
  else
    {
      /* Accepted but not started: shutdown must not launch another long
       * operation after its plug-in cancellation sweep. */
      call->status = GLIMS_STATUS_NOT_RUNNING;
    }

  g_mutex_lock (&call->engine->lock);
  call->done = TRUE;
  g_cond_broadcast (&call->engine->cond);
  g_mutex_unlock (&call->engine->lock);

  return G_SOURCE_REMOVE;
}

static GlimsStatus
call_on_engine (GlimsEngine     *engine,
                GlimsEngineFunc  func,
                gpointer         data,
                gboolean         allow_during_stop,
                gint             priority)
{
  GlimsCall   call = { engine, func, data, GLIMS_STATUS_FAILED, FALSE,
                       allow_during_stop };
  GSource    *source;
  guint       source_id;
  GlimsStatus status;

  if (! engine)
    return GLIMS_STATUS_NOT_RUNNING;

  /* Engine-internal continuations stay on their enclosing call's stack.
   * They must not queue onto themselves or fail halfway through cleanup.
   * Public event callbacks still may not call back into the engine. */
  if (g_thread_self () == engine->thread)
    return engine->gimp ? func (engine, data) : GLIMS_STATUS_NOT_RUNNING;

  g_mutex_lock (&engine->lock);
  if ((! allow_during_stop && engine->stopping) || ! engine->gimp)
    {
      g_mutex_unlock (&engine->lock);
      return GLIMS_STATUS_NOT_RUNNING;
    }

  if (! allow_during_stop)
    engine->registered_callers++;

  /* Attach while holding admission: stop must see both the registered
   * caller and its queued source. Unlike invoke_full(), attach never calls
   * inline under this mutex. Preserve ordinary RPCs' default priority. */
  source = g_idle_source_new ();
  g_source_set_priority (source, priority);
  g_source_set_callback (source, call_dispatch, &call, NULL);
  source_id = g_source_attach (source, NULL);
  g_source_unref (source);
  if (! source_id)
    {
      if (! allow_during_stop)
        engine->registered_callers--;
      g_cond_broadcast (&engine->cond);
      g_mutex_unlock (&engine->lock);
      return GLIMS_STATUS_FAILED;
    }

  while (! call.done)
    g_cond_wait (&engine->cond, &engine->lock);

  status = call.status;
  if (! allow_during_stop)
    {
      engine->registered_callers--;
      g_cond_broadcast (&engine->cond);
    }
  g_mutex_unlock (&engine->lock);

  /* No engine access after acknowledgement: stop may now release it. */
  return status;
}

GlimsStatus
glims_engine_call (GlimsEngine     *engine,
                   GlimsEngineFunc  func,
                   gpointer         data)
{
  return call_on_engine (engine, func, data, FALSE, G_PRIORITY_DEFAULT);
}

/* ---- Shared helpers ---------------------------------------------------- */

void
glims_emit (GlimsEngine         *engine,
            GlimsEventKind       kind,
            GimpImage           *image,
            const GeglRectangle *rect,
            const gchar         *text)
{
  GlimsEvent event = { 0 };

  if (! engine->on_event)
    return;

  event.kind  = kind;
  event.image = image ? gimp_image_get_id (image) : 0;
  if (rect)
    {
      event.rect.x      = rect->x;
      event.rect.y      = rect->y;
      event.rect.width  = rect->width;
      event.rect.height = rect->height;
    }
  event.text = text;

  engine->on_event (engine->event_context, &event);
}

void
glims_emit_progress (GlimsEngine *engine,
                     gboolean     active,
                     gdouble      value,
                     const gchar *text)
{
  GlimsEvent event = { 0 };

  if (! engine->on_event)
    return;

  event.kind   = GLIMS_EVENT_PROGRESS;
  event.text   = text;
  event.value  = value;
  event.active = active ? true : false;

  engine->on_event (engine->event_context, &event);
}

GlimsStatus
glims_fail (char        **error,
            GError       *gerror,
            const gchar  *fallback)
{
  if (error)
    *error = strdup (gerror && gerror->message ? gerror->message : fallback);

  g_clear_error (&gerror);

  return GLIMS_STATUS_FAILED;
}

gint
glims_next_session_id (GlimsEngine *engine)
{
  return ++engine->next_session_id;
}

/* ---- Messages ---------------------------------------------------------- */

/* GIMP routes user-facing messages (warnings from plug-ins, file errors)
 * through this hook when console_messages is off. */
static void
show_message (Gimp                *gimp,
              GObject             *handler,
              GimpMessageSeverity  severity,
              const gchar         *domain,
              const gchar         *message)
{
  GlimsEngine *engine = g_object_get_data (G_OBJECT (gimp), "glims-engine");
  gchar       *text   = g_strdup_printf ("%s: %s", domain ? domain : "Engine", message);

  if (engine)
    glims_emit (engine, GLIMS_EVENT_MESSAGE, NULL, NULL, text);
  else
    g_printerr ("%s\n", text);

  g_free (text);
}

/* ---- Plug-in dialogs ---------------------------------------------------- */

/* GIMP's interface hands plug-ins its icon theme (app/gui/icon-themes.c);
 * without one their dialogs show no icons. */
static GFile *
get_icon_theme_dir (Gimp *gimp)
{
  GlimsEngine *engine = g_object_get_data (G_OBJECT (gimp), "glims-engine");

  return engine ? engine->icon_theme_dir : NULL;
}

static GFile *
find_icon_theme_dir (Gimp *gimp)
{
  gchar *name = NULL;
  GFile *dir;

  g_object_get (gimp->config, "icon-theme", &name, NULL);
  dir = gimp_data_directory_file ("icons", name ? name : "Default", NULL);
  g_free (name);

  if (g_file_query_file_type (dir, G_FILE_QUERY_INFO_NONE, NULL) != G_FILE_TYPE_DIRECTORY)
    {
      g_object_unref (dir);
      dir = gimp_data_directory_file ("icons", "Default", NULL);
    }

  return dir;
}

/* Plug-in dialogs style themselves from theme.css in the user directory
 * (gimp_ui_init in libgimp/gimpui.c), which GIMP's interface rewrites on
 * every start (themes_theme_change_notify in app/gui/themes.c). Glims
 * writes the same imports for GIMP's Default theme in its light scheme,
 * the closest to Glims's own look. */
static void
write_plug_in_theme (void)
{
  gchar       *candidates[3];
  GString     *css = g_string_new (NULL);
  GFile       *theme_css;
  GError      *error = NULL;
  gint         i;

  candidates[0] = g_build_filename (gimp_data_directory (), "themes", "Default", "gimp-light.css", NULL);
  candidates[1] = g_build_filename (gimp_sysconf_directory (), "gimp.css", NULL);
  candidates[2] = g_build_filename (gimp_directory (), "gimp.css", NULL);

  g_string_append (css,
                   "/* theme.css for GIMP plug-in dialogs, written by Glims on every\n"
                   " * engine start. Edit gimp.css in this folder instead. */\n\n");

  for (i = 0; i < G_N_ELEMENTS (candidates); i++)
    {
      if (g_file_test (candidates[i], G_FILE_TEST_IS_REGULAR))
        {
          gchar *uri = g_filename_to_uri (candidates[i], NULL, NULL);

          if (uri)
            g_string_append_printf (css, "@import url(\"%s\");\n", uri);
          g_free (uri);
        }
      g_free (candidates[i]);
    }

  g_string_append (css, "\n* { -gtk-icon-style: symbolic; }\n");

  theme_css = gimp_directory_file ("theme.css", NULL);
  if (! g_file_replace_contents (theme_css, css->str, css->len, NULL, FALSE,
                                 G_FILE_CREATE_NONE, NULL, NULL, &error))
    {
      g_printerr ("Glims: could not write %s: %s\n", g_file_peek_path (theme_css), error->message);
      g_clear_error (&error);
    }

  g_object_unref (theme_css);
  g_string_free (css, TRUE);
}

typedef struct {
  Gimp *gimp;
  GSList *plugin_defs; /* owned references, retained until restore returns */
} StartupRegistryCapture;

static GPrivate startup_registry_capture = G_PRIVATE_INIT (NULL);

static void
init_status (const gchar *text1,
             const gchar *text2,
             gdouble      percentage)
{
  StartupRegistryCapture *capture = g_private_get (&startup_registry_capture);
  /* GIMP releases plug-in definitions immediately after restore. Its final
   * plug-in-init status callback runs before it writes and releases them. */
  if (capture && !text1 && text2 && !*text2 && percentage == 1.0 &&
      capture->gimp->plug_in_manager && capture->gimp->plug_in_manager->plug_in_defs)
    {
      g_slist_free_full (capture->plugin_defs, g_object_unref);
      capture->plugin_defs = NULL;
      for (GSList *item = capture->gimp->plug_in_manager->plug_in_defs; item; item = item->next)
        capture->plugin_defs = g_slist_prepend (capture->plugin_defs, g_object_ref (item->data));
      capture->plugin_defs = g_slist_reverse (capture->plugin_defs);
    }
  if (g_getenv ("GLIMS_STARTUP_TRACE"))
    g_printerr ("startup %.6f %s | %s | %.3f\n",
                g_get_monotonic_time () / 1000000.0,
                text1 ? text1 : "", text2 ? text2 : "", percentage);
}

/* ---- Where the engine's files are -------------------------------------- */

/* Inside Glims.app, scripts/bundle-engine.py puts this library in
 * Contents/Frameworks and the engine beside it in Contents/lib, share and
 * etc. Returns Contents in that layout, or NULL for a development build,
 * which uses the engine's install tree through its compiled-in paths. */
static gchar *
bundle_contents (void)
{
  Dl_info  info;
  gchar   *frameworks;
  gchar   *contents;
  gchar   *plug_ins;
  gboolean bundled;

  if (! dladdr ((const void *) glims_engine_get_api, &info) || ! info.dli_fname)
    return NULL;

  frameworks = g_path_get_dirname (info.dli_fname);
  contents   = g_path_get_dirname (frameworks);
  plug_ins   = g_build_filename (contents, "lib", "gimp", "3.0", "plug-ins", NULL);
  bundled    = (g_str_has_suffix (frameworks, "/Frameworks") &&
                g_file_test (plug_ins, G_FILE_TEST_IS_DIR));

  g_free (frameworks);
  g_free (plug_ins);
  if (bundled)
    return contents;

  g_free (contents);
  return NULL;
}

static void
set_path (const gchar *variable,
          const gchar *contents,
          const gchar *relative)
{
  gchar *path = g_build_filename (contents, relative, NULL);

  g_setenv (variable, path, TRUE);
  g_free (path);
}

static void
prepend_to_path (const gchar *directory)
{
  const gchar *path = g_getenv ("PATH");

  if (! path || ! strstr (path, directory))
    {
      gchar *joined = g_strconcat (directory, path ? ":" : "", path ? path : "", NULL);

      g_setenv ("PATH", joined, TRUE);
      g_free (joined);
    }
}

/* The single version folder under Contents/<relative>, e.g. Python's 3.13. */
static gchar *
only_subdirectory (const gchar *contents,
                   const gchar *relative)
{
  gchar       *parent = g_build_filename (contents, relative, NULL);
  GDir        *dir    = g_dir_open (parent, 0, NULL);
  const gchar *name;
  gchar       *found  = NULL;

  while (dir && (name = g_dir_read_name (dir)))
    if (g_ascii_isdigit (name[0]))
      {
        g_free (found);
        found = g_build_filename (parent, name, NULL);
      }

  if (dir)
    g_dir_close (dir);
  g_free (parent);

  return found;
}

/* gdk-pixbuf wants absolute loader paths; the bundle ships the cache with
 * a placeholder for Contents/lib, filled in here. */
static void
write_pixbuf_loaders (GlimsEngine *engine,
                      const gchar *contents)
{
  gchar  *template = g_build_filename (contents, "lib", "gdk-pixbuf-2.0", "2.10.0",
                                       "loaders.cache.in", NULL);
  gchar  *text     = NULL;
  gchar  *lib      = g_build_filename (contents, "lib", NULL);
  gchar  *cache    = g_build_filename (engine->cache_directory, "gdk-pixbuf-loaders.cache", NULL);

  if (g_file_get_contents (template, &text, NULL, NULL))
    {
      gchar  **parts  = g_strsplit (text, "@GLIMS_LIB@", -1);
      gchar   *filled = g_strjoinv (lib, parts);

      g_mkdir_with_parents (engine->cache_directory, 0700);
      if (g_file_set_contents (cache, filled, -1, NULL))
        g_setenv ("GDK_PIXBUF_MODULE_FILE", cache, TRUE);

      g_strfreev (parts);
      g_free (filled);
      g_free (text);
    }

  g_free (template);
  g_free (lib);
  g_free (cache);
}

/* Points the engine, and the plug-ins it starts (they inherit this
 * environment), at the bundle: what GIMP's own app/main.c does for its
 * relocatable macOS build, which Glims does not link. */
static void
use_bundle (GlimsEngine *engine,
            const gchar *contents)
{
  gchar *macos = g_build_filename (contents, "MacOS", NULL);
  gchar *python;
  gchar *ghostscript;

  set_path ("GIMP3_DATADIR",      contents, "share/gimp/3.0");
  set_path ("GIMP3_SYSCONFDIR",   contents, "etc/gimp/3.0");
  set_path ("GIMP3_PLUGINDIR",    contents, "lib/gimp/3.0");
  set_path ("GIMP3_LOCALEDIR",    contents, "share/locale");
  /* GEGL 0.4.72 and babl 0.1.128 find their modules beside their
   * libraries, but older releases (GIMP 3.0.8's) use compiled-in paths. */
  set_path ("GEGL_PATH",          contents, "lib/gegl-0.4");
  set_path ("BABL_PATH",          contents, "lib/babl-0.1");
  set_path ("GI_TYPELIB_PATH",    contents, "lib/girepository-1.0");
  set_path ("XDG_DATA_DIRS",      contents, "share");
  set_path ("GSETTINGS_SCHEMA_DIR", contents, "share/glib-2.0/schemas");
  set_path ("GIO_MODULE_DIR",     contents, "lib/gio/modules");
  set_path ("GTK_PATH",           contents, "lib/gtk-3.0");
  set_path ("FONTCONFIG_PATH",    contents, "etc/fonts");
  set_path ("LIBTHAI_DICTDIR",    contents, "share/libthai");
  g_setenv ("GTK_IM_MODULE", "quartz", TRUE);
  g_setenv ("PYTHONDONTWRITEBYTECODE", "1", TRUE);

  python = only_subdirectory (contents, "lib/Python.framework/Versions");
  if (python)
    g_setenv ("PYTHONHOME", python, TRUE);

  ghostscript = only_subdirectory (contents, "share/ghostscript");
  if (ghostscript)
    {
      gchar *init = g_build_filename (ghostscript, "Resource", "Init", NULL);

      g_setenv ("GS_LIB", init, TRUE);
      g_free (init);
    }

  /* Python and the Script-Fu interpreter, for "#!/usr/bin/env" plug-ins. */
  prepend_to_path (macos);
  write_pixbuf_loaders (engine, contents);

  g_free (macos);
  g_free (python);
  g_free (ghostscript);
}

/* Settings whose defaults name the build machine's dependency prefix: the
 * MyPaint brush folder (MYPAINT_BRUSHES_DIR, ".../share/mypaint-data/<version>/
 * brushes", 1.0 for GIMP 3.0 and 2.0 for 3.2) is moved into the bundle. */
static void
use_bundle_config (Gimp        *gimp,
                   const gchar *contents)
{
  gchar  *path     = NULL;
  gchar **elements;
  gint    i;

  g_object_get (gimp->config, "mypaint-brush-path", &path, NULL);
  elements = g_strsplit (path ? path : "", G_SEARCHPATH_SEPARATOR_S, -1);

  for (i = 0; elements[i]; i++)
    {
      const gchar *data = strstr (elements[i], "/share/mypaint-data/");

      if (data)
        {
          gchar *moved = g_strconcat (contents, data, NULL);

          g_free (elements[i]);
          elements[i] = moved;
        }
    }

  g_free (path);
  path = g_strjoinv (G_SEARCHPATH_SEPARATOR_S, elements);
  g_object_set (gimp->config, "mypaint-brush-path", path, NULL);

  g_strfreev (elements);
  g_free (path);
}

/* ---- Interface checks -------------------------------------------------- */

/* The compiler checks the engine functions the adapter calls, and
 * scripts/interface-diff.py their prototypes. GObject signals and properties
 * are looked up by name at run time, so an engine update that renames one
 * or changes a signal's arguments would otherwise fail silently. Every name
 * the adapter uses is checked here before the engine is declared started. */
static void
check_signal (GString     *problems,
              GType        type,
              const gchar *name,
              guint        n_params)
{
  /* Signals are registered in class_init; make sure it has run. */
  gpointer     klass = g_type_class_ref (type);
  GSignalQuery query;
  guint        id = g_signal_lookup (name, type);

  if (! id)
    g_string_append_printf (problems, "\n  signal %s::%s is missing", g_type_name (type), name);
  else
    {
      g_signal_query (id, &query);
      if (query.n_params != n_params)
        g_string_append_printf (problems, "\n  signal %s::%s has %u arguments, the adapter expects %u",
                                g_type_name (type), name, query.n_params, n_params);
    }
  g_type_class_unref (klass);
}

static void
check_property (GString     *problems,
                GType        type,
                const gchar *name,
                GType        value_type)
{
  GObjectClass *klass = g_type_class_ref (type);
  GParamSpec   *pspec = g_object_class_find_property (klass, name);

  if (! pspec)
    g_string_append_printf (problems, "\n  property %s:%s is missing", g_type_name (type), name);
  else if (! g_type_is_a (G_PARAM_SPEC_VALUE_TYPE (pspec), value_type))
    g_string_append_printf (problems, "\n  property %s:%s is a %s, the adapter expects %s",
                            g_type_name (type), name, g_type_name (G_PARAM_SPEC_VALUE_TYPE (pspec)),
                            g_type_name (value_type));
  g_type_class_unref (klass);
}

static gboolean
check_engine_interface (Gimp    *gimp,
                        GError **error)
{
  GString *problems = g_string_new (NULL);
  gboolean ok;

  check_signal (problems, GIMP_TYPE_PROJECTION, "update", 5);
  check_signal (problems, GIMP_TYPE_IMAGE, "undo-event", 2);
  check_signal (problems, GIMP_TYPE_IMAGE, "selected-layers-changed", 0);
  check_signal (problems, GIMP_TYPE_IMAGE, "mask-changed", 0);
  check_signal (problems, GIMP_TYPE_IMAGE, "size-changed", 0);
  check_signal (problems, GIMP_TYPE_IMAGE, "guide-added", 1);
  check_signal (problems, GIMP_TYPE_IMAGE, "guide-removed", 1);
  check_signal (problems, GIMP_TYPE_IMAGE, "guide-moved", 1);
  check_property (problems, GIMP_TYPE_GRID, "style", GIMP_TYPE_GRID_STYLE);
  check_property (problems, GIMP_TYPE_GRID, "fgcolor", GEGL_TYPE_COLOR);
  check_property (problems, GIMP_TYPE_GRID, "bgcolor", GEGL_TYPE_COLOR);
  check_property (problems, GIMP_TYPE_GRID, "xspacing", G_TYPE_DOUBLE);
  check_property (problems, GIMP_TYPE_GRID, "yspacing", G_TYPE_DOUBLE);
  check_property (problems, GIMP_TYPE_GRID, "spacing-unit", GIMP_TYPE_UNIT);
  check_property (problems, GIMP_TYPE_GRID, "xoffset", G_TYPE_DOUBLE);
  check_property (problems, GIMP_TYPE_GRID, "yoffset", G_TYPE_DOUBLE);
  check_property (problems, GIMP_TYPE_GRID, "offset-unit", GIMP_TYPE_UNIT);
  check_property (problems, GIMP_TYPE_PAINT_OPTIONS, "brush-size", G_TYPE_DOUBLE);
  check_property (problems, GIMP_TYPE_PAINT_CORE, "undo-desc", G_TYPE_STRING);
  check_property (problems, G_OBJECT_TYPE (gimp->edit_config), "prev-language", G_TYPE_STRING);
  check_property (problems, G_OBJECT_TYPE (gimp->edit_config), "config-version", G_TYPE_STRING);
  check_property (problems, G_OBJECT_TYPE (gimp->config), "icon-theme", G_TYPE_STRING);
  check_property (problems, G_OBJECT_TYPE (gimp->config), "module-path", G_TYPE_STRING);
  check_property (problems, G_OBJECT_TYPE (gimp->config), "tool-preset-path", G_TYPE_STRING);
  check_property (problems, G_OBJECT_TYPE (gimp->config), "tool-preset-path-writable", G_TYPE_STRING);
  check_property (problems, G_OBJECT_TYPE (gimp->config), "mypaint-brush-path", G_TYPE_STRING);
  check_property (problems, G_OBJECT_TYPE (gegl_config ()), "use-opencl", G_TYPE_BOOLEAN);
  check_property (problems, G_OBJECT_TYPE (gegl_config ()), "application-license", G_TYPE_STRING);

  ok = problems->len == 0;
  if (! ok)
    g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                 "The engine's interface changed; the adapter needs updating:%s", problems->str);
  g_string_free (problems, TRUE);

  return ok;
}

/* ---- Start-up and shut-down (engine thread) --------------------------- */

/* Resolve exactly the registry path that GIMP's plug-in manager will read. */
static GFile *
configured_plugin_cache (Gimp *gimp)
{
  gchar *path = NULL;
  gchar *expanded = NULL;
  GFile *configured = NULL;
  g_object_get (gimp->config, "pluginrc-path", &path, NULL);
  if (!path)
    configured = gimp_directory_file ("pluginrc", NULL);
  else if ((expanded = gimp_config_path_expand (path, TRUE, NULL)))
    configured = g_path_is_absolute (expanded) ? g_file_new_for_path (expanded)
                                                : gimp_directory_file (expanded, NULL);
  g_free (expanded);
  g_free (path);
  return configured;
}

/* Parse the selected registry from one already-open descriptor. The
 * nonblocking open and fstat refuse FIFOs and other special files even when a
 * symlink changes concurrently; GIMP's ordinary path handles every refusal. */
static gboolean
configured_plugin_cache_unusable (Gimp *gimp)
{
  GFile *file = configured_plugin_cache (gimp);
  gchar *path = file ? g_file_get_path (file) : NULL;
  int fd = path ? open (path, O_RDONLY | O_NONBLOCK | O_CLOEXEC) : -1;
  gboolean unusable = FALSE;
  struct stat statbuf;
  if (fd >= 0 && fstat (fd, &statbuf) == 0 && S_ISREG (statbuf.st_mode) &&
      statbuf.st_size >= 0 && statbuf.st_size <= 16 * 1024 * 1024)
    {
      gchar *fd_path = g_strdup_printf ("/dev/fd/%d", fd);
      GFile *snapshot = g_file_new_for_path (fd_path);
      GError *parse_error = NULL;
      GSList *defs = plug_in_rc_parse (gimp, snapshot, &parse_error);
      unusable = defs == NULL;
      g_slist_free_full (defs, g_object_unref);
      g_clear_error (&parse_error);
      g_object_unref (snapshot);
      g_free (fd_path);
    }
  if (fd >= 0) close (fd);
  g_free (path);
  g_clear_object (&file);
  return unusable;
}

/* The bundle contains registries captured for specific engine and language
 * identities. Seed the missing selected registry only on an exact match. GIMP
 * still checks every executable's path/mtime and runs init
 * procedures, so changed and user-installed plug-ins are discovered normally.
 * Existing registries and preferences always belong to the user. */
/* The macOS language identity omits gettext environment overrides. Bind the
 * host seed to the exact environment in which the packager queried it. */
static gint
startup_environment_name_compare (gconstpointer a, gconstpointer b)
{
  return g_strcmp0 (*(const gchar * const *) a, *(const gchar * const *) b);
}

static gchar *
startup_locale_environment_fingerprint (void)
{
  gchar **environment_names = g_listenv ();
  GPtrArray *names = g_ptr_array_new_with_free_func (g_free);
  g_ptr_array_add (names, g_strdup ("LANG"));
  g_ptr_array_add (names, g_strdup ("LANGUAGE"));
  for (guint i = 0; environment_names[i]; i++)
    if (g_str_has_prefix (environment_names[i], "LC_"))
      g_ptr_array_add (names, g_strdup (environment_names[i]));
  g_strfreev (environment_names);
  g_ptr_array_sort (names, startup_environment_name_compare);
  GChecksum *checksum = g_checksum_new (G_CHECKSUM_SHA256);
  for (guint i = 0; i < names->len; i++)
    {
      const gchar *name = g_ptr_array_index (names, i);
      const gchar *value = g_getenv (name);
      const guchar present = value != NULL;
      g_checksum_update (checksum, (const guchar *) name, strlen (name) + 1);
      g_checksum_update (checksum, &present, 1);
      if (value)
        g_checksum_update (checksum, (const guchar *) value, strlen (value) + 1);
    }
  gchar *fingerprint = g_strdup (g_checksum_get_string (checksum));
  g_checksum_free (checksum);
  g_ptr_array_free (names, TRUE);
  return fingerprint;
}

static gboolean
startup_locale_environment_is_clean (void)
{
  gchar **names = g_listenv ();
  gboolean clean = TRUE;
  for (guint i = 0; names[i]; i++)
    if (g_str_equal (names[i], "LANG") || g_str_equal (names[i], "LANGUAGE") ||
        g_str_has_prefix (names[i], "LC_"))
      { clean = FALSE; break; }
  g_strfreev (names);
  return clean;
}

static gboolean
startup_checksum_seed_file (GChecksum *sum, const gchar *path, const gchar *tag)
{
  struct stat st;
  gchar *data = NULL;
  gsize length = 0;
  guchar present = 0;
  if (g_lstat (path, &st) == 0)
    {
      if (!S_ISREG (st.st_mode) || st.st_size < 0 || st.st_size > 16 * 1024 * 1024 ||
          !g_file_get_contents (path, &data, &length, NULL) || length > 16 * 1024 * 1024)
        { g_free (data); return FALSE; }
      present = 1;
    }
  else if (errno != ENOENT) return FALSE;
  g_checksum_update (sum, (const guchar *) tag, strlen (tag) + 1);
  g_checksum_update (sum, &present, 1);
  if (present)
    {
      guint64 size = GUINT64_TO_BE ((guint64) length);
      g_checksum_update (sum, (const guchar *) &size, sizeof size);
      g_checksum_update (sum, (const guchar *) data, length);
    }
  g_free (data);
  return TRUE;
}

/* Locale overrides are not part of GIMP's prev-language setting. Keep their
 * registries separate so a later launch cannot reuse labels queried under a
 * different environment. The private directory also keeps the user's chosen
 * pluginrc untouched. GIMP still discovers changed/user plug-ins normally. */
static gchar *
startup_override_registry_path (const gchar *cache_directory,
                                const gchar *contents,
                                const gchar *language,
                                const gchar *user_directory,
                                const gchar *selected_registry)
{
  struct stat st;
  if (!cache_directory || !contents || !language || !user_directory || !selected_registry) return NULL;
  g_autofree gchar *base = g_build_filename (cache_directory, "glims-pluginrc-environments", NULL);
  if (g_mkdir (base, 0700) != 0 && errno != EEXIST) return NULL;
  if (g_lstat (base, &st) != 0 || !S_ISDIR (st.st_mode) || st.st_uid != getuid () ||
      (st.st_mode & 077) != 0) return NULL;
  g_autofree gchar *fingerprint = startup_locale_environment_fingerprint ();
  GChecksum *sum = g_checksum_new (G_CHECKSUM_SHA256);
  const gchar *parts[] = { GIMP_VERSION, language, contents, user_directory, selected_registry, fingerprint };
  for (guint i = 0; i < G_N_ELEMENTS (parts); i++)
    g_checksum_update (sum, (const guchar *) parts[i], strlen (parts[i]) + 1);
  /* Both the host and matching localized seeds affect registry provenance. */
  g_autofree gchar *escaped_language = g_strescape (language, NULL);
  g_autofree gchar *localized_key = g_compute_checksum_for_string (G_CHECKSUM_SHA256, escaped_language, -1);
  const gchar *leaves[] = { "identity", "environment", "pluginrc" };
  for (guint i = 0; i < G_N_ELEMENTS (leaves); i++)
    {
      g_autofree gchar *host_path = g_build_filename (contents, "Resources", "Engine-Startup", leaves[i], NULL);
      g_autofree gchar *localized_path = g_build_filename (contents, "Resources", "Engine-Startup",
                                                           "localized", localized_key, leaves[i], NULL);
      g_autofree gchar *host_tag = g_strconcat ("host/", leaves[i], NULL);
      g_autofree gchar *localized_tag = g_strconcat ("localized/", leaves[i], NULL);
      if (!startup_checksum_seed_file (sum, host_path, host_tag) ||
          !startup_checksum_seed_file (sum, localized_path, localized_tag))
        { g_checksum_free (sum); return NULL; }
    }
  g_autofree gchar *digest = g_strdup (g_checksum_get_string (sum));
  g_checksum_free (sum);
  g_autofree gchar *directory = g_build_filename (base, digest, NULL);
  if (g_mkdir (directory, 0700) != 0 && errno != EEXIST) return NULL;
  if (g_lstat (directory, &st) != 0 || !S_ISDIR (st.st_mode) || st.st_uid != getuid () ||
      (st.st_mode & 077) != 0) return NULL;
  gchar *path = g_build_filename (directory, "pluginrc", NULL);
  if (g_lstat (path, &st) == 0)
    {
      if (!S_ISREG (st.st_mode) || st.st_uid != getuid ()) { g_free (path); return NULL; }
    }
  else if (errno != ENOENT) { g_free (path); return NULL; }
  return path;
}

/* A selected registry predating Glims's environment tracking has unknown
 * provenance. Remember only byte-exact registries that this engine actually
 * produced in this locale, scoped to this profile and bundled engine. */
static gchar *
startup_registry_digest (GFile *file)
{
  gchar *path = file ? g_file_get_path (file) : NULL;
  int fd = path ? open (path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) : -1;
  struct stat before, after;
  GChecksum *sum = NULL;
  gchar *digest = NULL;
  if (fd >= 0 && fstat (fd, &before) == 0 && S_ISREG (before.st_mode) &&
      before.st_size >= 0 && before.st_size <= 16 * 1024 * 1024)
    {
      guint8 buffer[16384];
      ssize_t n;
      sum = g_checksum_new (G_CHECKSUM_SHA256);
      while ((n = read (fd, buffer, sizeof buffer)) > 0)
        g_checksum_update (sum, buffer, (gsize) n);
      if (n == 0 && fstat (fd, &after) == 0 && before.st_dev == after.st_dev &&
          before.st_ino == after.st_ino && before.st_size == after.st_size &&
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
        digest = g_strdup (g_checksum_get_string (sum));
    }
  if (sum) g_checksum_free (sum);
  if (fd >= 0) close (fd);
  g_free (path);
  return digest;
}

static gchar *
startup_registry_marker (GlimsEngine *engine, const gchar *contents,
                         const gchar *language, const gchar *digest)
{
  if (!digest) return NULL;
  g_autofree gchar *path = startup_override_registry_path (engine->cache_directory, contents, language,
                                                           engine->user_directory, "<selected-registry-verification>");
  if (!path) return NULL;
  g_autofree gchar *directory = g_path_get_dirname (path);
  g_autofree gchar *name = g_strconcat ("verified-", digest, NULL);
  return g_build_filename (directory, name, NULL);
}

static gboolean
startup_registry_is_verified (GlimsEngine *engine, const gchar *contents,
                              const gchar *language, GFile *selected)
{
  g_autofree gchar *digest = startup_registry_digest (selected);
  g_autofree gchar *marker = startup_registry_marker (engine, contents, language, digest);
  struct stat st;
  return marker && g_lstat (marker, &st) == 0 && S_ISREG (st.st_mode) && st.st_uid == getuid ();
}

/* Compare a fresh serialization of the engine's actual catalogue with the
 * selected file before attesting it. Another process may have replaced the
 * file during restore; matching the engine's values prevents blessing a
 * concurrently written registry from another environment. */
static void
startup_verify_selected_registry (GlimsEngine *engine, const gchar *contents,
                                  const gchar *language, GFile *selected, GSList *plugin_defs)
{
  if (!plugin_defs) return;
  g_autofree gchar *cache = startup_override_registry_path (engine->cache_directory, contents, language,
                                                            engine->user_directory, "<selected-registry-verification>");
  if (!cache) return;
  g_autofree gchar *directory = g_path_get_dirname (cache);
  g_autofree gchar *path = g_build_filename (directory, "witness-XXXXXX", NULL);
  int witness_fd = g_mkstemp_full (path, O_RDWR | O_CLOEXEC, 0600);
  if (witness_fd < 0) return;
  close (witness_fd);
  GFile *witness = g_file_new_for_path (path);
  if (plug_in_rc_write (plugin_defs, witness, NULL))
    {
      g_autofree gchar *actual = startup_registry_digest (selected);
      g_autofree gchar *expected = startup_registry_digest (witness);
      if (actual && expected && g_str_equal (actual, expected))
        {
          g_autofree gchar *marker = startup_registry_marker (engine, contents, language, actual);
          int fd = marker ? open (marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600) : -1;
          if (fd >= 0) close (fd);
        }
    }
  g_file_delete (witness, NULL, NULL);
  g_object_unref (witness);
}

static gboolean
seed_bundle_plugin_cache (const gchar *contents,
                          const gchar *language,
                          GFile       *destination)
{
  gboolean seeded = FALSE;
  gboolean identity_matches;
  gchar *metadata_path, *metadata = NULL, *escaped, *expected, *directory, *digest;
  GFile *source;

  if (! contents || ! language)
    return FALSE;

  escaped = g_strescape (language, NULL);
  expected = g_strdup_printf ("%s\n%s\n", GIMP_VERSION, escaped);
  directory = g_build_filename (contents, "Resources", "Engine-Startup", NULL);
  metadata_path = g_build_filename (directory, "identity", NULL);
  /* Preserve the original packager-host seed. Additional locales are keyed
   * by a digest of the escaped identity, never by an untrusted path string. */
  identity_matches = g_file_get_contents (metadata_path, &metadata, NULL, NULL) &&
                     g_strcmp0 (metadata, expected) == 0;
  if (identity_matches)
    {
      gchar *environment_path = g_build_filename (directory, "environment", NULL);
      gchar *actual_environment = NULL;
      gchar *fingerprint = startup_locale_environment_fingerprint ();
      gchar *expected_environment = g_strconcat (fingerprint, "\n", NULL);
      identity_matches = g_file_get_contents (environment_path, &actual_environment, NULL, NULL) &&
                         g_strcmp0 (actual_environment, expected_environment) == 0;
      g_free (expected_environment);
      g_free (fingerprint);
      g_free (actual_environment);
      g_free (environment_path);
    }
  /* On macOS the preferred-language list does not include explicit gettext
   * locale overrides. These extra seeds are captured without such overrides;
   * using one with different environment settings could show stale labels. */
  if (!identity_matches && startup_locale_environment_is_clean ())
    {
      g_clear_pointer (&metadata, g_free);
      g_free (metadata_path);
      g_free (directory);
      digest = g_compute_checksum_for_string (G_CHECKSUM_SHA256, escaped, -1);
      directory = g_build_filename (contents, "Resources", "Engine-Startup", "localized", digest, NULL);
      g_free (digest);
      metadata_path = g_build_filename (directory, "identity", NULL);
      identity_matches = g_file_get_contents (metadata_path, &metadata, NULL, NULL) &&
                         g_strcmp0 (metadata, expected) == 0;
    }
  if (identity_matches)
    {
      source = g_file_new_build_filename (directory, "pluginrc", NULL);
      gchar *registry = NULL;
      gsize length = 0;
      if (g_file_load_contents (source, NULL, &registry, &length, NULL, NULL))
        {
          /* File parameter defaults can contain bundle URIs. Preserve binary
           * registry payloads (such as icons) while relocating only our token. */
          const gchar token[] = "@GLIMS_BUNDLE_URI@";
          gchar *uri = g_filename_to_uri (contents, NULL, NULL);
          gchar *quoted_uri = uri ? g_strescape (uri, NULL) : NULL;
          GString *expanded = g_string_sized_new (length);
          for (gsize i = 0; quoted_uri && i < length; )
            {
              if (length - i >= sizeof token - 1 &&
                  memcmp (registry + i, token, sizeof token - 1) == 0)
                {
                  g_string_append (expanded, quoted_uri);
                  i += sizeof token - 1;
                }
              else
                g_string_append_c (expanded, registry[i++]);
            }
          /* Exclusive create preserves existing caches, including symlinks
           * and a concurrent first launch. A failed write is never accepted. */
          GFileOutputStream *output = quoted_uri
            ? g_file_create (destination, G_FILE_CREATE_PRIVATE, NULL, NULL) : NULL;
          if (output)
            {
              seeded = g_output_stream_write_all (G_OUTPUT_STREAM (output), expanded->str,
                                                   expanded->len, NULL, NULL, NULL);
              if (! g_output_stream_close (G_OUTPUT_STREAM (output), NULL, NULL))
                seeded = FALSE;
              g_object_unref (output);
              /* If writing failed, do not unlink by name: another process
               * may already have replaced the file we created. GIMP can
               * reject a partial cache and query missing plug-ins normally. */
            }
          g_string_free (expanded, TRUE);
          g_free (quoted_uri);
          g_free (uri);
          g_free (registry);
        }
      g_object_unref (source);
    }
  g_free (expected);
  g_free (escaped);
  g_free (metadata);
  g_free (metadata_path);
  g_free (directory);
  return seeded;
}

static gboolean
engine_initialize (GlimsEngine  *engine,
                   GError      **error)
{
  Gimp        *gimp;
  GFile       *gimpdir;
  const gchar *abort_message;
  const gchar *current_language;
  gchar       *prev_language = NULL;
  gchar       *original_pluginrc_path = NULL;
  gchar       *temporary_registry_dir = NULL;
  gchar       *temporary_registry_path = NULL;
  gchar       *override_registry_path = NULL;
  GFile       *selected_for_verification = NULL;
  gboolean     temporary_registry_active = FALSE;
  gboolean     preserve_previous_language = FALSE;
  GError      *font_error    = NULL;
  gchar       *contents;

  /* The engine's settings and caches live in Glims-owned directories; the
   * user's own GIMP settings and ~/.cache are never touched. GLib reads
   * these once, so they are set before anything asks for them. */
  g_setenv ("GIMP3_DIRECTORY", engine->user_directory, TRUE);
  g_setenv ("XDG_CACHE_HOME", engine->cache_directory, TRUE);

  contents = bundle_contents ();
  if (contents)
    {
      use_bundle (engine, contents);
      /* Prepare the same native font caches in a small child. Its config
       * retains user font roots and discovers downloaded macOS font assets
       * through CoreText, avoiding scans of unrelated system asset trees.
       * If preparation fails, keep native discovery as the fallback. */
      gchar *helper = g_build_filename (contents, "MacOS", "glims-font-cache", NULL);
      gchar *base = g_build_filename (contents, "etc", "fonts", "fonts-glims.conf", NULL);
      gchar *config = g_build_filename (engine->cache_directory, "fonts.conf", NULL);
      const gchar *argv[] = { helper, base, config, NULL };
      if (g_file_test (helper, G_FILE_TEST_IS_EXECUTABLE))
        {
          if (glims_run_startup_helper (engine->cache_directory, argv, 3000))
            g_setenv ("FONTCONFIG_FILE", config, TRUE);
          else
            g_printerr ("Glims: font cache preparation failed; loading fonts directly.\n");
        }
      g_free (config);
      g_free (base);
      g_free (helper);
    }
  else
    {
      /* A development build: plug-ins need the install tree's typelibs,
       * and script plug-ins ("#!/usr/bin/env <interpreter>") its bin. */
      if (! g_getenv ("GI_TYPELIB_PATH"))
        g_setenv ("GI_TYPELIB_PATH", GLIMS_ENGINE_TYPELIB_PATH, TRUE);
      prepend_to_path (GLIMS_ENGINE_BIN_PATH);
    }

  /* gimp-console's main() names the program; GLib and GIMP derive paths
   * from that name, so a host that does not set one must get one. */
  if (! g_get_prgname ())
    g_set_prgname ("glims");

  gimp_env_init (FALSE);

  /* As app_libs_init() and GEGL's option-group hook do. */
  g_object_set (gegl_config (),
                "use-opencl",          FALSE,
                "application-license", "GPL3",
                NULL);
  gegl_init (NULL, NULL);

  gimp = gimp_new ("Glims",
                   NULL,                     /* session name */
                   NULL,                     /* default folder */
                   FALSE,                    /* be verbose */
                   FALSE,                    /* no data */
                   FALSE,                    /* no fonts */
                   FALSE,                    /* no interface: see below */
                   TRUE,                     /* use shared memory with plug-ins */
                   TRUE,                     /* use CPU acceleration */
                   FALSE,                    /* console messages: use the hook */
                   FALSE,                    /* show playground */
                   FALSE,                    /* show debug menu */
                   GIMP_STACK_TRACE_NEVER,
                   GIMP_PDB_COMPAT_ON);

  /* no_interface is off although GIMP's GTK interface is absent: with it
   * on, the engine drops plug-ins' progress reports and parent-window
   * requests (app/pdb/progress-cmds.c), so their dialogs float free and
   * cannot be cancelled. Its other effects are handled below: the GTK
   * modules and the tool presets it would load are disabled, and the
   * remaining gui hooks stay unset, which GIMP treats as "no such window"
   * (core/gimp-gui.c). */
  g_object_set_data (G_OBJECT (gimp), "glims-engine", engine);
  gimp->gui.show_message       = show_message;
  gimp->gui.get_icon_theme_dir = get_icon_theme_dir;

  /* Core code reaches gimp->app; it is never run. */
  engine->app = gimp_console_app_new (gimp, FALSE, FALSE, NULL, NULL, NULL);
  gimp->app   = engine->app;
  engine->gimp = gimp;

  gimp_cpu_accel_set_use (TRUE);

  gimpdir = gimp_directory_file (NULL);
  if (g_file_query_file_type (gimpdir, G_FILE_QUERY_INFO_NONE, NULL) != G_FILE_TYPE_DIRECTORY)
    {
      GimpUserInstall *install;
#if GIMP_MAJOR_VERSION == 3 && GIMP_MINOR_VERSION == 2 && GIMP_MICRO_VERSION == 0
      /* 3.2.0's migration scan passes an absent SNAP to g_file_test(). An
       * empty value takes the non-Snap path without changing existing values.
       * Only the constructor scans old installations; restore it immediately. */
      gboolean restore_absent_snap = g_getenv ("SNAP") == NULL;

      if (restore_absent_snap)
        g_setenv ("SNAP", "", TRUE);
#endif

      install = gimp_user_install_new (G_OBJECT (gimp), FALSE);

#if GIMP_MAJOR_VERSION == 3 && GIMP_MINOR_VERSION == 2 && GIMP_MICRO_VERSION == 0
      if (restore_absent_snap)
        g_unsetenv ("SNAP");
#endif

      gimp_user_install_run (install, 1);
      gimp_user_install_free (install);
    }
  g_object_unref (gimpdir);

  gimp_load_config (gimp, NULL, NULL);

  /* GIMP's modules (color selectors, display filters, MIDI controllers)
   * are GTK widgets; with no_interface off, gimp_restore() would load them
   * into this process. GIMP's tool presets describe the options of its
   * GTK tools and cannot load without them (gimp_tool_options_check_tool_info
   * fails and the engine crashes). Empty search paths load neither. GIMP
   * copies every change of the running configuration into the one it
   * saves (gimp_global_config_notify, connected with edit_config as its
   * data); that copy is blocked here, so gimprc keeps the user's values. */
  g_signal_handlers_block_matched (gimp->config, G_SIGNAL_MATCH_DATA,
                                   0, 0, NULL, NULL, gimp->edit_config);
  g_object_set (gimp->config,
                "module-path",               "",
                "tool-preset-path",          "",
                "tool-preset-path-writable", "",
                NULL);
  if (contents)
    use_bundle_config (gimp, contents);
  g_signal_handlers_unblock_matched (gimp->config, G_SIGNAL_MATCH_DATA,
                                     0, 0, NULL, NULL, gimp->edit_config);

  engine->icon_theme_dir = find_icon_theme_dir (gimp);
  write_plug_in_theme ();

  /* gimp-console gets this path from gimp_init_signal_handlers(); the
   * adapter installs no signal handlers, so it names the file itself. */
  {
    gchar *backtrace_file = g_build_filename (gimp_directory (), "CrashLog",
                                              "glims-backtrace.txt", NULL);

    errors_init (gimp, "glims", FALSE, GIMP_STACK_TRACE_NEVER, backtrace_file);
    g_free (backtrace_file);
  }

  abort_message = sanity_check_late ();
  if (abort_message)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, abort_message);
      g_free (contents);
      return FALSE;
    }

  gimp_gegl_init (gimp);
  glims_operation_selective_color_register ();

  /* The adapter's own operations register the way GIMP's do inside
   * gimp_gegl_init(): the held class reference puts the type in GEGL's
   * operation lookup before gimp_restore() and the plug-in catalogs
   * enumerate operations. */
  glims_operation_posterize_register ();

  current_language = language_init (NULL, NULL);

  gimp_initialize (gimp, init_status);

  glims_script_fu_path_fix_install (gimp, contents);

  g_object_get (gimp->edit_config, "prev-language", &prev_language, NULL);
  gimp->query_all = (prev_language == NULL ||
                     g_strcmp0 (prev_language, current_language) != 0);
  {
      gboolean language_changed = prev_language &&
                                  g_strcmp0 (prev_language, current_language) != 0;
      GFile *selected = configured_plugin_cache (gimp);
      gboolean override_active = contents && !startup_locale_environment_is_clean ();
      gboolean selected_exists = selected && g_file_query_exists (selected, NULL);
      gboolean selected_verified = !override_active && contents && selected_exists &&
        startup_registry_is_verified (engine, contents, current_language, selected);
      gboolean selected_unverified = !override_active && contents && selected_exists && !selected_verified;
      if (!override_active && contents && selected && (!selected_exists || selected_verified))
        selected_for_verification = g_object_ref (selected);
      if (override_active)
        {
          gchar *selected_path = selected ? g_file_get_path (selected) : NULL;
          override_registry_path = startup_override_registry_path (engine->cache_directory, contents, current_language,
                                                                   engine->user_directory, selected_path);
          g_free (selected_path);
          gchar *config_path = override_registry_path ? g_filename_to_utf8 (override_registry_path, -1, NULL, NULL, NULL) : NULL;
          gchar *expanded = config_path ? gimp_config_path_expand (config_path, TRUE, NULL) : NULL;
          if (expanded && g_strcmp0 (expanded, override_registry_path) == 0)
            {
              GFile *file = g_file_new_for_path (override_registry_path);
              gboolean exists = g_file_query_exists (file, NULL);
              g_object_get (gimp->config, "pluginrc-path", &original_pluginrc_path, NULL);
              g_object_set (gimp->config, "pluginrc-path", config_path, NULL);
              temporary_registry_active = TRUE; /* restore config after discovery */
              preserve_previous_language = language_changed;
              if (!exists)
                {
                  gboolean seeded = seed_bundle_plugin_cache (contents, current_language, file);
                  gimp->query_all = !seeded;
                  if (seeded && g_getenv ("GLIMS_STARTUP_TRACE"))
                    g_printerr ("Glims: seeded bundled command cache\n");
                }
              else
                gimp->query_all = configured_plugin_cache_unusable (gimp);
              g_object_unref (file);
            }
          else
            {
              /* Do not let an override overwrite the selected registry: a
               * later clean launch would otherwise reuse the wrong labels. */
              temporary_registry_dir = g_dir_make_tmp ("glims-pluginrc-XXXXXX", NULL);
              temporary_registry_path = temporary_registry_dir
                ? g_build_filename (temporary_registry_dir, "pluginrc", NULL) : NULL;
              g_clear_pointer (&config_path, g_free);
              g_clear_pointer (&expanded, g_free);
              config_path = temporary_registry_path
                ? g_filename_to_utf8 (temporary_registry_path, -1, NULL, NULL, NULL) : NULL;
              expanded = config_path ? gimp_config_path_expand (config_path, TRUE, NULL) : NULL;
              if (temporary_registry_path && (!expanded || g_strcmp0 (expanded, temporary_registry_path) != 0))
                {
                  const gchar *tmpdir = g_getenv ("TMPDIR");
                  gchar *directory_name = g_path_get_basename (temporary_registry_dir);
                  g_clear_pointer (&config_path, g_free);
                  g_clear_pointer (&expanded, g_free);
                  if (tmpdir && *tmpdir)
                    {
                      config_path = g_strdup_printf ("${TMPDIR}%s%s/pluginrc",
                                                     g_str_has_suffix (tmpdir, "/") ? "" : "/",
                                                     directory_name);
                      expanded = gimp_config_path_expand (config_path, TRUE, NULL);
                    }
                  g_free (directory_name);
                }
              if (expanded && g_strcmp0 (expanded, temporary_registry_path) == 0)
                {
                  g_object_get (gimp->config, "pluginrc-path", &original_pluginrc_path, NULL);
                  g_object_set (gimp->config, "pluginrc-path", config_path, NULL);
                  temporary_registry_active = TRUE;
                  preserve_previous_language = language_changed;
                  gimp->query_all = TRUE;
                }
              else
                {
                  if (temporary_registry_dir) g_rmdir (temporary_registry_dir);
                  g_free (temporary_registry_path);
                  g_free (temporary_registry_dir);
                  g_free (override_registry_path);
                  g_free (config_path);
                  g_free (expanded);
                  g_clear_object (&selected);
                  g_free (prev_language);
                  g_free (contents);
                  g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                                       "Could not create a safe command cache for the locale override.");
                  return FALSE;
                }
            }
          g_free (expanded);
          g_free (config_path);
        }
      else if (selected && !selected_exists)
        {
          if (seed_bundle_plugin_cache (contents, current_language, selected))
            {
              gimp->query_all = FALSE;
              if (g_getenv ("GLIMS_STARTUP_TRACE"))
                g_printerr ("Glims: seeded bundled command cache\n");
            }
        }
      else if (selected &&
               ((!language_changed && (configured_plugin_cache_unusable (gimp) || selected_unverified)) ||
                (language_changed &&
                 g_file_query_file_type (selected, G_FILE_QUERY_INFO_NONE, NULL) == G_FILE_TYPE_REGULAR)))
        {
          temporary_registry_dir = g_dir_make_tmp ("glims-pluginrc-XXXXXX", NULL);
          if (temporary_registry_dir)
            {
              temporary_registry_path = g_build_filename (temporary_registry_dir, "pluginrc", NULL);
              GFile *file = g_file_new_for_path (temporary_registry_path);
              /* GIMP treats '~' and ${tokens} specially in config paths.
               * Use this temporary path only if that parser resolves it back
               * to the exact filesystem name, including filename encoding. */
              gchar *config_path = g_filename_to_utf8 (temporary_registry_path, -1, NULL, NULL, NULL);
              gchar *expanded = config_path ? gimp_config_path_expand (config_path, TRUE, NULL) : NULL;
              if (!expanded || g_strcmp0 (expanded, temporary_registry_path) != 0)
                {
                  const gchar *tmpdir = g_getenv ("TMPDIR");
                  gchar *directory_name = g_path_get_basename (temporary_registry_dir);

                  /* GIMP substitutes the value of TMPDIR once, without
                   * interpreting special characters inside that value. */
                  g_clear_pointer (&config_path, g_free);
                  g_clear_pointer (&expanded, g_free);
                  if (tmpdir && *tmpdir)
                    {
                      config_path = g_strdup_printf ("${TMPDIR}%s%s/pluginrc",
                                                     g_str_has_suffix (tmpdir, "/") ? "" : "/",
                                                     directory_name);
                      expanded = gimp_config_path_expand (config_path, TRUE, NULL);
                    }
                  g_free (directory_name);
                }
              if (expanded && g_strcmp0 (expanded, temporary_registry_path) == 0 &&
                  seed_bundle_plugin_cache (contents, current_language, file))
                {
                  g_object_get (gimp->config, "pluginrc-path", &original_pluginrc_path, NULL);
                  g_object_set (gimp->config, "pluginrc-path", config_path, NULL);
                  gimp->query_all = FALSE;
                  temporary_registry_active = TRUE;
                  /* The selected registry still contains the old language.
                   * Retain its tag so later launches also use a fresh seed. */
                  preserve_previous_language = language_changed;
                  if (g_getenv ("GLIMS_STARTUP_TRACE"))
                    g_printerr ("Glims: using temporary bundled command cache\n");
                }
              g_free (expanded);
              g_free (config_path);
              g_object_unref (file);
            }
        }
      /* If a private seeded registry could not be prepared, never silently
       * reuse an unverified selected registry's potentially stale labels. */
      if (selected_unverified && !temporary_registry_active)
        gimp->query_all = TRUE;
      g_clear_object (&selected);
  }
  g_free (prev_language);

  StartupRegistryCapture registry_capture = { gimp, NULL };
  if (selected_for_verification && !temporary_registry_active)
    g_private_set (&startup_registry_capture, &registry_capture);
  gimp_restore (gimp, init_status, &font_error);
  g_private_set (&startup_registry_capture, NULL);
  if (selected_for_verification && !temporary_registry_active)
    startup_verify_selected_registry (engine, contents, current_language, selected_for_verification,
                                      registry_capture.plugin_defs);
  g_slist_free_full (registry_capture.plugin_defs, g_object_unref);
  g_clear_object (&selected_for_verification);
  g_free (contents);
  if (temporary_registry_active)
    g_object_set (gimp->config, "pluginrc-path", original_pluginrc_path, NULL);
  if (temporary_registry_path) g_unlink (temporary_registry_path);
  if (temporary_registry_dir) g_rmdir (temporary_registry_dir);
  g_free (original_pluginrc_path);
  g_free (temporary_registry_path);
  g_free (temporary_registry_dir);
  g_free (override_registry_path);
  if (font_error)
    {
      show_message (gimp, NULL, GIMP_MESSAGE_WARNING, NULL, font_error->message);
      g_clear_error (&font_error);
    }

  gimp_rc_set_autosave (GIMP_RC (gimp->edit_config), TRUE);

  g_object_set (gimp->edit_config, "config-version", GIMP_VERSION, NULL);
  if (!preserve_previous_language)
    g_object_set (gimp->edit_config, "prev-language", current_language, NULL);

  gimp->initialized = TRUE;

  return check_engine_interface (gimp, error);
}

static void
engine_shutdown (GlimsEngine *engine)
{
  Gimp *gimp = engine->gimp;
  GimpRc *edit_config = GIMP_RC (gimp->edit_config);

  g_hash_table_remove_all (engine->filters);
  g_hash_table_remove_all (engine->strokes);
  g_hash_table_remove_all (engine->images);

  /* Saving constructs a default RC that needs the live user context.
   * Stop future autosaves and flush the exact pending source before
   * gimp_exit() clears that context. Do not dispatch unrelated work. */
  gimp_rc_set_autosave (edit_config, FALSE);
  if (edit_config->save_idle_id)
    {
      g_source_remove (edit_config->save_idle_id);
      edit_config->save_idle_id = 0;
      gimp_rc_save (edit_config);
    }

  gimp_exit (gimp, TRUE);

  gimp_gegl_exit (gimp);
  errors_exit ();

  while (g_main_context_pending (NULL))
    g_main_context_iteration (NULL, TRUE);

  g_clear_object (&engine->icon_theme_dir);
  g_clear_object (&engine->app);
  engine->gimp = NULL;
  g_object_unref (gimp);

  gegl_exit ();
}

static gpointer
engine_thread (gpointer user_data)
{
  GlimsEngine  *engine  = user_data;
  GMainContext *context = g_main_context_default ();
  GError       *error   = NULL;
  gboolean      ok;

  if (! g_main_context_acquire (context))
    {
      g_mutex_lock (&engine->lock);
      engine->start_error = g_strdup ("GLib's default main context is owned by another thread.");
      engine->started     = TRUE;
      g_cond_broadcast (&engine->cond);
      g_mutex_unlock (&engine->lock);
      return NULL;
    }

  ok = engine_initialize (engine, &error);
  if (ok)
    engine->loop = g_main_loop_new (context, FALSE);

  g_mutex_lock (&engine->lock);
  if (! ok)
    engine->start_error = g_strdup (error ? error->message : "The engine failed to start.");
  engine->started = TRUE;
  g_cond_broadcast (&engine->cond);
  g_mutex_unlock (&engine->lock);
  g_clear_error (&error);

  if (ok)
    {
      g_main_loop_run (engine->loop);
      engine_shutdown (engine);
      g_clear_pointer (&engine->loop, g_main_loop_unref);
    }

  g_main_context_release (context);

  return NULL;
}

/* ---- Facade: lifecycle ------------------------------------------------- */

static void
open_image_free (gpointer data)
{
  GlimsOpenImage *open = data;

  if (open->image)
    gimp_projection_stop_rendering (gimp_image_get_projection (open->image));
  glims_display_sample_free (open->display_sample);
  glims_ink_snapshot_free (open->ink_snapshot);
  glims_lab_snapshot_free (open->lab_snapshot);
  glims_item_sets_free (open->item_sets);
  glims_lab_layer_preview_free (open->layered_lab_preview);
  glims_plate_preview_free (open->component_preview);
  g_clear_pointer (&open->component_cmyk_profile, g_bytes_unref);
  g_clear_pointer (&open->component_profile_label, g_free);
  for (guint i = 0; i < G_N_ELEMENTS (open->component_planes); i++)
    if (open->component_planes[i])
      {
        if (open->component_updates[i])
          g_signal_handler_disconnect (open->component_planes[i], open->component_updates[i]);
        g_clear_object (&open->component_planes[i]);
      }

  if (open->image)
    {
      GimpProjection *projection = gimp_image_get_projection (open->image);

      if (open->projection_update_handler)
        g_signal_handler_disconnect (projection, open->projection_update_handler);
      if (open->undo_event_handler)
        g_signal_handler_disconnect (open->image, open->undo_event_handler);
      if (open->layers_changed_handler)
        g_signal_handler_disconnect (open->image, open->layers_changed_handler);
      if (open->mask_changed_handler)
        g_signal_handler_disconnect (open->image, open->mask_changed_handler);
      if (open->size_changed_handler)
        g_signal_handler_disconnect (open->image, open->size_changed_handler);
      if (open->channels_changed_handler)
        g_signal_handler_disconnect (open->image, open->channels_changed_handler);
      if (open->component_active_handler)
        g_signal_handler_disconnect (open->image, open->component_active_handler);
      if (open->component_visible_handler)
        g_signal_handler_disconnect (open->image, open->component_visible_handler);
      if (open->quick_mask_changed_handler)
        g_signal_handler_disconnect (open->image, open->quick_mask_changed_handler);
      if (open->guide_added_handler)
        g_signal_handler_disconnect (open->image, open->guide_added_handler);
      if (open->guide_removed_handler)
        g_signal_handler_disconnect (open->image, open->guide_removed_handler);
      if (open->guide_moved_handler)
        g_signal_handler_disconnect (open->image, open->guide_moved_handler);

      glims_track_image_links (open->image);
      g_object_unref (open->image);
    }

  g_free (open);
}

static gboolean started_once = FALSE;

static GlimsStatus
api_start (const GlimsEngineConfig  *config,
           GlimsEngine             **out,
           char                    **error)
{
  GlimsEngine *engine;

  if (! out || ! config || config->struct_size < sizeof (GlimsEngineConfig) ||
      ! config->user_directory || ! config->cache_directory)
    {
      if (error)
        *error = strdup ("Invalid engine configuration.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* GEGL and GIMP's type system cannot be initialised twice. */
  if (started_once)
    {
      if (error)
        *error = strdup ("The engine can only be started once per process.");
      return GLIMS_STATUS_FAILED;
    }
  started_once = TRUE;

  engine = g_new0 (GlimsEngine, 1);
  engine->on_event        = config->on_event;
  engine->event_context   = config->event_context;
  engine->user_directory  = g_strdup (config->user_directory);
  engine->cache_directory = g_strdup (config->cache_directory);
  engine->images  = g_hash_table_new_full (g_direct_hash, g_direct_equal, NULL, open_image_free);
  engine->strokes = g_hash_table_new_full (g_direct_hash, g_direct_equal, NULL, glims_strokes_free);
  engine->filters = g_hash_table_new_full (g_direct_hash, g_direct_equal, NULL, glims_filters_free);
  g_mutex_init (&engine->lock);
  g_cond_init (&engine->cond);

  g_mkdir_with_parents (engine->cache_directory, 0700);

  engine->thread = g_thread_new ("glims-engine", engine_thread, engine);

  g_mutex_lock (&engine->lock);
  while (! engine->started)
    g_cond_wait (&engine->cond, &engine->lock);
  g_mutex_unlock (&engine->lock);

  if (engine->start_error)
    {
      if (error)
        *error = strdup (engine->start_error);
      g_thread_join (engine->thread);
      g_free (engine->start_error);
      g_free (engine->user_directory);
      g_free (engine->cache_directory);
      g_free (engine);
      return GLIMS_STATUS_FAILED;
    }

  *out = engine;

  return GLIMS_STATUS_OK;
}

static GlimsStatus
cancel_open_plug_ins (GlimsEngine *engine,
                     gpointer     data)
{
  GimpPlugInManager *manager = engine->gimp->plug_in_manager;

  /* A running plug-in (a dialog left open) holds the engine thread in a
   * nested loop, so the main loop would not end until the user closed it.
   * Close every plug-in first, as gimp_plug_in_manager_exit() does on
   * GIMP's own exit. Their nested loops unwind while the outer loop stays
   * alive for accepted RPCs and their external callers to finish. */
  while (manager->open_plug_ins)
    gimp_plug_in_close (manager->open_plug_ins->data, TRUE);

  return GLIMS_STATUS_OK;
}

static GlimsStatus
quit_loop (GlimsEngine *engine,
           gpointer     data)
{
  g_main_loop_quit (engine->loop);

  return GLIMS_STATUS_OK;
}

static void
api_stop (GlimsEngine *engine)
{
  if (! engine)
    return;

  /* The sole external owner has stopped submitting new calls. Waiting on
   * this thread lets an enclosing plug-in RPC unwind its nested loop; doing
   * the drain inside that loop's cancellation callback would deadlock. */
  g_mutex_lock (&engine->lock);
  engine->stopping = TRUE;
  g_mutex_unlock (&engine->lock);

  call_on_engine (engine, cancel_open_plug_ins, NULL, TRUE, G_PRIORITY_HIGH);

  g_mutex_lock (&engine->lock);
  while (engine->registered_callers)
    g_cond_wait (&engine->cond, &engine->lock);
  g_mutex_unlock (&engine->lock);

  call_on_engine (engine, quit_loop, NULL, TRUE, G_PRIORITY_DEFAULT);
  g_thread_join (engine->thread);

  g_hash_table_unref (engine->images);
  g_hash_table_unref (engine->strokes);
  g_hash_table_unref (engine->filters);
  g_mutex_clear (&engine->lock);
  g_cond_clear (&engine->cond);
  g_free (engine->user_directory);
  g_free (engine->cache_directory);
  g_free (engine);
}

static void
api_free_string (char *string)
{
  free (string);
}

static const char *
api_engine_version (GlimsEngine *engine)
{
  return GIMP_VERSION;
}

/* ---- Facade: marshalled calls ------------------------------------------
 * Each facade function packs its arguments, runs the matching glims_*
 * function on the engine thread and returns its status. */

typedef struct
{
  GlimsImageID      image;
  GlimsItemID       item;
  GlimsEffectID     effect;
  int32_t           width, height;
  const char       *string;
  double            number;
  GlimsRect         area;
  uint8_t          *pixels;
  size_t            stride;
  int32_t           capacity;
  int32_t          *count;
  void             *out;
  const void       *in;
  const void       *in2;
  void             *in_out;
  double            number2;
  uint64_t          revision;
  uint64_t          token;      /* full 64-bit saved-set identity; never narrowed */
  GlimsResourceID   resource;   /* full 64-bit handle; never narrowed */
  size_t            n;
  char            **error;
} GlimsArgs;

#define MARSHAL(name, body)                                             \
  static GlimsStatus name##_on_engine (GlimsEngine *e, gpointer data)  \
  {                                                                     \
    GlimsArgs *a = data;                                                \
    body                                                                \
  }

MARSHAL (image_new,    return glims_image_new (e, a->width, a->height, a->out, a->error);)
MARSHAL (image_open,   return glims_image_open (e, a->string, a->out, a->error);)
MARSHAL (image_close,  return glims_image_close (e, a->image);)
MARSHAL (image_info,   return glims_image_info (e, a->image, a->out);)
MARSHAL (image_render, return glims_image_render (e, a->image, a->number, a->area, a->pixels, a->stride);)
MARSHAL (image_render_to_profile, return glims_image_render_to_profile (e, a->image, a->number, a->area,
                                                                          a->in, a->n, a->pixels, a->stride, a->error);)
MARSHAL (image_item_sets, return glims_image_item_sets (e, a->image, a->out, a->capacity, a->count);)
MARSHAL (image_item_set_members, return glims_image_item_set_members (e, a->image, a->token, a->out,
                                                                       a->capacity, a->count);)
MARSHAL (image_item_set_edit, return glims_image_item_set_edit (e, a->image, (uint32_t) a->width,
                                                                (uint32_t) a->height, a->token, a->string,
                                                                a->in, a->capacity, (uint64_t *) a->out,
                                                                a->error);)
MARSHAL (image_save,   return glims_image_save (e, a->image, a->string, a->error);)
MARSHAL (image_save_copy, return glims_image_save_copy (e, a->image, a->string, a->error);)
MARSHAL (image_export, return glims_image_export (e, a->image, a->string, a->error);)
MARSHAL (image_layers, return glims_image_layers (e, a->image, a->out, a->capacity, a->count);)
MARSHAL (image_undo_info, return glims_image_undo_info (e, a->image, a->out);)
MARSHAL (image_undo,   return glims_image_undo (e, a->image);)
MARSHAL (image_redo,   return glims_image_redo (e, a->image);)
MARSHAL (stroke_begin, {
  const GlimsBrushSettings *brush = a->in;
  return glims_stroke_begin (e, a->image, a->item, brush, a->in2, a->out, a->error); })
MARSHAL (stroke_continue, return glims_stroke_continue (e, a->item, a->in, a->n);)
MARSHAL (stroke_end,   return glims_stroke_end (e, a->item);)
MARSHAL (filter_begin, return glims_filter_begin (e, a->image, a->item, a->string, a->out, a->error);)
MARSHAL (filter_set_double, return glims_filter_set_double (e, a->item, a->string, a->number);)
MARSHAL (filter_commit, return glims_filter_commit (e, a->item, a->error);)
MARSHAL (filter_abort, return glims_filter_abort (e, a->item);)
MARSHAL (procedures,   return glims_procedures (e, a->image, a->out, a->capacity, a->count);)
MARSHAL (select_shape, return glims_select_shape (e, a->image, (uint32_t) a->width, a->in, a->n, a->in2);)
MARSHAL (select_color, {
  const GlimsPoint *point = a->in;
  return glims_select_color (e, a->image, *point, a->in2, a->error); })
MARSHAL (select_command, return glims_select_command (e, a->image, (uint32_t) a->width, a->number, a->error);)
MARSHAL (selection_bounds, return glims_selection_bounds (e, a->image, a->out, a->in_out);)
MARSHAL (selection_outline, return glims_selection_outline (e, a->image, a->out, a->capacity, a->count);)
MARSHAL (fill, {
  const GlimsPoint *point = a->in;
  return glims_fill (e, a->image, *point, a->in2, a->error); })
MARSHAL (fill_pattern, {
  const GlimsPoint *seed = a->in;
  return glims_fill_pattern (e, a->image, a->resource, *seed, a->in2, a->error); })
MARSHAL (gradient, {
  const GlimsPoint *points = a->in;
  return glims_gradient (e, a->image, points[0], points[1], a->in2, a->error); })
MARSHAL (layer_select, return glims_layer_select (e, a->image, a->item);)
MARSHAL (layer_command, return glims_layer_command (e, a->image, a->item, (uint32_t) a->width, a->out, a->error);)
MARSHAL (layer_change, return glims_layer_change (e, a->image, a->item, a->in, a->error);)
MARSHAL (layer_move, return glims_layer_move (e, a->image, a->item, a->number, a->number2);)
MARSHAL (image_crop, return glims_image_crop (e, a->image, a->area, a->error);)
MARSHAL (image_transform, return glims_image_transform (e, a->image, (uint32_t) a->width);)
MARSHAL (layer_transform, return glims_layer_transform (e, a->image, a->item, (uint32_t) a->width);)
MARSHAL (image_scale, return glims_image_scale (e, a->image, a->width, a->height, a->error);)
MARSHAL (fonts, return glims_fonts (e, a->out);)
MARSHAL (text_layer_new, return glims_text_layer_new (e, a->image, a->string, a->in,
                                                      (GlimsPoint) { a->number, a->number2 },
                                                      a->out, a->error);)
MARSHAL (text_layer_new_captured, return glims_text_layer_new_captured (e, a->image, a->in, a->string, a->in2,
                                                                        (GlimsPoint) { a->number, a->number2 },
                                                                        a->out, a->error);)
MARSHAL (text_layer_get, return glims_text_layer_get (e, a->image, a->item, a->out, a->in_out);)
MARSHAL (text_layer_set, return glims_text_layer_set (e, a->image, a->item, a->string, a->in,
                                                      a->error);)
MARSHAL (layer_transform_matrix, return glims_layer_transform_matrix (e, a->image, a->item, a->in,
                                                                      (uint32_t) a->width, a->error);)
MARSHAL (layer_transform_matrix_captured, return glims_layer_transform_matrix_captured (
           e, a->image, a->item, a->in, a->error);)
MARSHAL (image_transform_preview, return glims_image_transform_preview (
           e, a->image, a->item, a->in, a->out, a->error);)
MARSHAL (image_resize_canvas, return glims_image_resize_canvas (e, a->image, a->area.width, a->area.height,
                                                                a->area.x, a->area.y, a->in, a->error);)
MARSHAL (procedure_run, return glims_procedure_run (e, a->image, a->string, (uint32_t) a->width, a->error);)
MARSHAL (paths, return glims_paths (e, a->image, a->out, a->capacity, a->count);)
MARSHAL (path_change, return glims_path_change (e, a->image, a->item, a->in, a->error);)
MARSHAL (path_delete, return glims_path_delete (e, a->image, a->item);)
MARSHAL (path_to_selection, return glims_path_to_selection (e, a->image, a->item, a->in);)
MARSHAL (path_stroke, return glims_path_stroke (e, a->image, a->item, (GlimsItemID) a->width, a->in,
                                                a->error);)
MARSHAL (layer_state,  return glims_layer_state (e, a->image, a->item, a->out);)
MARSHAL (create_group, return glims_create_group (e, a->image, a->item, a->width, a->string, a->out,
                                                  a->error);)
MARSHAL (reparent_layer, return glims_reparent_layer (e, a->image, a->item, (GlimsItemID) a->width,
                                                      a->height, a->error);)
MARSHAL (set_layer_locks, return glims_set_layer_locks (e, a->image, a->item, (uint32_t) a->width,
                                                        (uint32_t) a->height, a->error);)
MARSHAL (filter_operations, return glims_filter_operations (e, a->out, a->capacity, a->count);)
MARSHAL (filter_operation_properties, return glims_filter_operation_properties (e, a->string, a->out,
                                                                                a->capacity, a->count);)
MARSHAL (filter_enum_choices, return glims_filter_enum_choices (e, a->string, a->in, a->out,
                                                                a->capacity, a->count);)
MARSHAL (filter_get_property, return glims_filter_get_property (e, a->item, a->string, a->out);)
MARSHAL (filter_set_property, return glims_filter_set_property (e, a->item, a->string, a->in);)
MARSHAL (image_history, return glims_image_history (e, a->image, a->out, a->capacity, a->in_out);)
MARSHAL (image_history_move, return glims_image_history_move (e, a->image, a->revision, a->width, a->error);)
MARSHAL (image_duplicate, return glims_image_duplicate (e, a->image, a->out, a->error);)
MARSHAL (layer_mask,   return glims_layer_mask (e, a->image, a->item, a->out);)
MARSHAL (layer_mask_add, return glims_layer_mask_add (e, a->image, a->item, (uint32_t) a->width,
                                                      a->height != 0, a->out, a->error);)
MARSHAL (layer_mask_set, return glims_layer_mask_set (e, a->image, a->item, (uint32_t) a->width,
                                                      (uint32_t) a->height, a->error);)
MARSHAL (layer_mask_apply, return glims_layer_mask_apply (e, a->image, a->item, (uint32_t) a->width,
                                                          a->error);)
MARSHAL (layer_mask_to_selection, return glims_layer_mask_to_selection (e, a->image, a->item,
                                                                        (uint32_t) a->width, a->error);)
MARSHAL (drawable_thumbnail, return glims_drawable_thumbnail (e, a->image, a->item, a->width,
                                                              a->pixels, a->n, a->count,
                                                              (int32_t *) a->in_out);)
MARSHAL (image_components, return glims_image_components (e, a->image, a->out);)
MARSHAL (image_set_components, {
  const uint32_t *masks = a->in;
  return glims_image_set_components (e, a->image, masks[0], masks[1], masks[2], masks[3],
                                     a->error); })
MARSHAL (image_channels, return glims_image_channels (e, a->image, a->out, a->capacity, a->count);)
MARSHAL (channel_from_selection, return glims_channel_from_selection (e, a->image, a->string,
                                                                      a->out, a->error);)
MARSHAL (channel_change, return glims_channel_change (e, a->image, a->item, a->in, a->error);)
MARSHAL (channel_command, return glims_channel_command (e, a->image, a->item, (uint32_t) a->width,
                                                        a->out, a->error);)
MARSHAL (channel_to_selection, return glims_channel_to_selection (e, a->image, a->item,
                                                                  (uint32_t) a->width, a->error);)
MARSHAL (image_quick_mask, return glims_image_quick_mask (e, a->image, a->out);)
MARSHAL (image_set_quick_mask, return glims_image_set_quick_mask (e, a->image, a->width != 0,
                                                                  a->error);)
MARSHAL (drawable_effects, return glims_drawable_effects (e, a->image, a->item, a->out,
                                                          a->capacity, a->count);)
MARSHAL (effect_change, return glims_effect_change (e, a->image, a->item, a->effect,
                                                    a->in, a->error);)
MARSHAL (effect_command, return glims_effect_command (e, a->image, a->item, a->effect,
                                                      (uint32_t) a->width, a->error);)
MARSHAL (image_open_layers, return glims_image_open_layers (e, a->image, a->string, a->out,
                                                            a->capacity, a->count, a->error);)
MARSHAL (image_place_link, return glims_image_place_link (e, a->image, a->string,
                                                          a->out, a->error);)
MARSHAL (filter_edit_begin, return glims_filter_edit_begin (e, a->image, a->item, a->effect,
                                                            a->out, a->error);)
MARSHAL (image_color_info, return glims_image_color_info (e, a->image, a->out);)
MARSHAL (image_convert_mode, return glims_image_convert_mode (e, a->image, (uint32_t) a->width,
                                                              a->error);)
MARSHAL (image_convert_precision, return glims_image_convert_precision (e, a->image,
                                                                       (uint32_t) a->width,
                                                                       (uint32_t) a->height,
                                                                       a->error);)
MARSHAL (path_fill, return glims_path_fill (e, a->image, a->item, (GlimsItemID) a->width, a->in,
                                            a->error);)
MARSHAL (path_to_vector_layer, return glims_path_to_vector_layer (e, a->image, a->item, a->string,
                                                                  a->out, a->error);)
MARSHAL (image_assign_profile, return glims_image_assign_profile (e, a->image, a->string,
                                                                   a->error);)
MARSHAL (image_convert_profile, return glims_image_convert_profile (e, a->image, a->string,
                                                                     (uint32_t) a->width,
                                                                     a->height != 0, a->error);)
MARSHAL (image_convert_profile_rasterizing, return glims_image_convert_profile_rasterizing
            (e, a->image, a->string, (uint32_t) a->width, a->height != 0, a->error);)
MARSHAL (resources, return glims_resources (e, (uint32_t) a->width, a->out, a->capacity, a->count);)
MARSHAL (vector_layer_style_get, return glims_vector_layer_style_get (e, a->image, a->item,
                                                                      (GlimsVectorStyle *) a->in_out, a->error);)
MARSHAL (vector_layer_style_set, return glims_vector_layer_style_set (e, a->image, a->item,
                                                                      a->in, a->error);)

/* A path's geometry takes more arguments than GlimsArgs holds. */
typedef struct
{
  GlimsImageID          image;
  GlimsItemID           path;
  const char           *name;
  GlimsSubpath         *subpaths;
  const GlimsSubpath   *subpaths_in;
  int32_t               subpath_capacity;
  int32_t              *subpath_count;
  GlimsPathPoint       *points;
  const GlimsPathPoint *points_in;
  int32_t               point_capacity;
  int32_t              *point_count;
  GlimsItemID          *result;
  char                **error;
} GlimsPathArgs;

static GlimsStatus
path_get_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsPathArgs *a = data;

  return glims_path_get (e, a->image, a->path, a->subpaths, a->subpath_capacity, a->subpath_count,
                         a->points, a->point_capacity, a->point_count);
}

static GlimsStatus
path_set_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsPathArgs *a = data;

  return glims_path_set (e, a->image, a->path, a->name, a->subpaths_in, a->subpath_capacity,
                         a->points_in, a->point_capacity, a->result, a->error);
}

/* The resource identity calls take more arguments than GlimsArgs holds. */
typedef struct
{
  GlimsResourceID   id;
  uint32_t          kind;
  const char       *name;
  const char       *collection;
  bool              internal;
  char            **out_name;
  char            **out_collection;
  bool             *out_internal;
  GlimsResourceID  *out_id;
  int32_t           max_size;
  const GlimsColor *foreground;
  const GlimsColor *background;
  GlimsPixelBuffer *pixels;
  char            **error;
} GlimsResourceArgs;

static GlimsStatus
resource_identifiers_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceArgs *a = data;

  return glims_resource_identifiers (e, a->id, a->out_name, a->out_collection,
                                     a->out_internal, a->error);
}

static GlimsStatus
resource_resolve_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceArgs *a = data;

  return glims_resource_resolve (e, a->kind, a->name, a->collection, a->internal,
                                 a->out_id, a->error);
}

/* stroke_begin_with_brush_resource carries a full 64-bit resource handle,
 * so it gets its own args struct with a typed uint64_t field; the id never
 * travels in one of GlimsArgs' 32-bit fields. */
typedef struct
{
  GlimsImageID              image;
  GlimsItemID               item;
  GlimsResourceID           brush;
  const GlimsBrushSettings *brush_settings;
  const GlimsStrokePoint   *first;
  GlimsStrokeID            *out;
  char                    **error;
} GlimsStrokeResourceArgs;

static GlimsStatus
stroke_begin_with_brush_resource_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsStrokeResourceArgs *a = data;

  return glims_stroke_begin_with_brush_resource (e, a->image, a->item, a->brush,
                                                 a->brush_settings, a->first, a->out, a->error);
}

typedef struct
{
  GlimsImageID             image;
  GlimsItemID              drawable;
  GlimsResourceID          brush_resource;
  const GlimsBrushSettings *brush;
  const GlimsStrokePoint   *first;
  const char              *expected_fingerprint;
  GlimsStrokeID            stroke;
  GlimsStrokeCaptureFacts  facts;
  char                   **error;
} GlimsStrokeCaptureArgs;

static GlimsStatus
stroke_begin_with_capture_facts_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsStrokeCaptureArgs *a = data;

  return glims_stroke_begin_with_capture_facts (e, a->image, a->drawable, a->brush_resource,
                                                a->brush, a->first, a->expected_fingerprint,
                                                &a->stroke, &a->facts, a->error);
}

typedef struct
{
  GlimsImageID image;
  GlimsItemID drawable;
  GlimsResourceID brush_resource;
  const GlimsBrushSettings *brush;
  const GlimsStrokePacketV2 *packet;
  GlimsStrokeID stroke;
  char **error;
} GlimsStrokeV2Args;

static GlimsStatus
stroke_begin_v2_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsStrokeV2Args *a = data;
  return glims_stroke_begin_v2 (e, a->image, a->drawable, a->brush_resource,
                                a->brush, a->packet, &a->stroke, a->error);
}

static GlimsStatus
stroke_continue_v2_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsStrokeV2Args *a = data;
  return glims_stroke_continue_v2 (e, a->stroke, a->packet, a->error);
}

/* selection_stroke carries a full 64-bit resource handle besides the
 * brush settings, so it gets its own args struct; the id never travels
 * in one of GlimsArgs' 32-bit fields. */
typedef struct
{
  GlimsImageID              image;
  GlimsItemID               drawable;
  GlimsResourceID           brush;
  const GlimsBrushSettings *settings;
  char                    **error;
} GlimsSelectionStrokeArgs;

static GlimsStatus
selection_stroke_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsSelectionStrokeArgs *a = data;

  return glims_selection_stroke (e, a->image, a->drawable, a->brush, a->settings, a->error);
}

static GlimsStatus
resource_thumbnail_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceArgs *a = data;

  return glims_resource_thumbnail (e, a->id, a->max_size, a->foreground, a->background,
                                   a->pixels, a->error);
}

/* resource_create_pixels carries the pixel pointer with its byte count
 * and a full 64-bit out handle, so it gets its own args struct; the id
 * never travels in one of GlimsArgs' 32-bit fields. */
typedef struct
{
  uint32_t          kind;
  const char       *name;
  int32_t           width, height;
  const uint8_t    *pixels;
  size_t            byte_count;
  uint32_t          brush_spacing;
  GlimsResourceID  *out_id;
  char            **error;
} GlimsResourceCreateArgs;

static GlimsStatus
resource_create_pixels_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceCreateArgs *a = data;

  return glims_resource_create_pixels (e, a->kind, a->name, a->width, a->height,
                                       a->pixels, a->byte_count, a->brush_spacing,
                                       a->out_id, a->error);
}

/* The resource gradient call keeps the full 64-bit resource handle and
 * both endpoints besides its settings — more than GlimsArgs holds. */
typedef struct
{
  GlimsImageID                          image;
  GlimsResourceID                       gradient;
  GlimsPoint                            from, to;
  const GlimsResourceGradientSettings  *settings;
  char                                **error;
} GlimsGradientResourceArgs;

static GlimsStatus
gradient_resource_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsGradientResourceArgs *a = data;

  return glims_gradient_resource (e, a->image, a->gradient, a->from, a->to,
                                  a->settings, a->error);
}

static GlimsStatus
procedure_cancel_on_engine (GlimsEngine *e, gpointer data)
{
  return glims_procedure_cancel (e);
}

static GlimsStatus
api_image_new (GlimsEngine *e, int32_t width, int32_t height, GlimsImageID *image, char **error)
{
  GlimsArgs a = { .width = width, .height = height, .out = image, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_new,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            image_new_on_engine, &a, error);
}

static GlimsStatus
api_image_open (GlimsEngine *e, const char *path, GlimsImageID *image, char **error)
{
  GlimsArgs a = { .string = path, .out = image, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_open,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            image_open_on_engine, &a, error);
}

static GlimsStatus
api_image_close (GlimsEngine *e, GlimsImageID image)
{
  GlimsArgs a = { .image = image };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_close,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_close_on_engine, &a, NULL);
}

static GlimsStatus
api_image_info (GlimsEngine *e, GlimsImageID image, GlimsImageInfo *info)
{
  GlimsArgs a = { .image = image, .out = info };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_info,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_info_on_engine, &a, NULL);
}

static GlimsStatus
api_image_render (GlimsEngine *e, GlimsImageID image, double scale, GlimsRect area,
                  uint8_t *pixels, size_t stride)
{
  GlimsArgs a = { .image = image, .number = scale, .area = area, .pixels = pixels, .stride = stride };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_render,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_render_on_engine, &a, NULL);
}

static GlimsStatus
api_image_render_to_profile (GlimsEngine *e, GlimsImageID image, double scale, GlimsRect area,
                             const uint8_t *destination_icc, size_t destination_icc_length,
                             uint8_t *pixels, size_t stride, char **error)
{
  GlimsArgs a = { .image = image, .number = scale, .area = area,
                  .in = destination_icc, .n = destination_icc_length,
                  .pixels = pixels, .stride = stride, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_render_to_profile,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_render_to_profile_on_engine, &a, error);
}

/* Read slots: zero the count in the bridge too, so a dispatch without a
 * running engine (NOT_RUNNING) still resets the output. */
static GlimsStatus
api_image_item_sets (GlimsEngine *e, GlimsImageID image, GlimsItemSetInfo *rows,
                     int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = rows, .capacity = capacity, .count = count };
  if (count) *count = 0;
  return glims_facade_call (e, GLIMS_FACADE_OP_image_item_sets,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_item_sets_on_engine, &a, NULL);
}

static GlimsStatus
api_image_item_set_members (GlimsEngine *e, GlimsImageID image, uint64_t token,
                            GlimsItemID *members, int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .token = token, .out = members, .capacity = capacity, .count = count };
  if (count) *count = 0;
  return glims_facade_call (e, GLIMS_FACADE_OP_image_item_set_members,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_item_set_members_on_engine, &a, NULL);
}

/* Zero the out token in the bridge too, so a dispatch without a running
 * engine (NOT_RUNNING) still resets the output. */
static GlimsStatus
api_image_item_set_edit (GlimsEngine *e, GlimsImageID image, uint32_t operation, uint32_t kind,
                         uint64_t token, const char *name, const GlimsItemID *members,
                         int32_t count, uint64_t *outToken, char **error)
{
  GlimsArgs a = { .image = image, .width = (int32_t) operation, .height = (int32_t) kind,
                  .token = token, .string = name, .in = members, .capacity = count,
                  .out = outToken, .error = error };
  if (outToken) *outToken = 0;
  return glims_facade_call (e, GLIMS_FACADE_OP_image_item_set_edit,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_item_set_edit_on_engine, &a, error);
}

static GlimsStatus
api_image_save (GlimsEngine *e, GlimsImageID image, const char *path, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_save,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_save_on_engine, &a, error);
}

static GlimsStatus
api_image_save_copy (GlimsEngine *e, GlimsImageID image, const char *path, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_save_copy,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_save_copy_on_engine, &a, error);
}

static GlimsStatus
api_image_export (GlimsEngine *e, GlimsImageID image, const char *path, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_export,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_export_on_engine, &a, error);
}

static GlimsStatus
api_image_layers (GlimsEngine *e, GlimsImageID image, GlimsLayerInfo *layers,
                  int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = layers, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_layers,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_layers_on_engine, &a, NULL);
}

static GlimsStatus
api_image_undo_info (GlimsEngine *e, GlimsImageID image, GlimsUndoInfo *info)
{
  GlimsArgs a = { .image = image, .out = info };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_undo_info,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_undo_info_on_engine, &a, NULL);
}

static GlimsStatus
api_image_undo (GlimsEngine *e, GlimsImageID image)
{
  GlimsArgs a = { .image = image };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_undo,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_undo_on_engine, &a, NULL);
}

static GlimsStatus
api_image_redo (GlimsEngine *e, GlimsImageID image)
{
  GlimsArgs a = { .image = image };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_redo,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_redo_on_engine, &a, NULL);
}

static GlimsStatus
api_stroke_begin (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                  const GlimsBrushSettings *brush, const GlimsStrokePoint *first,
                  GlimsStrokeID *stroke, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in = brush, .in2 = first,
                  .out = stroke, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_stroke_begin,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { glims_facade_brush_source (brush), 0 } },
                            stroke_begin_on_engine, &a, error);
}

static GlimsStatus
api_stroke_continue (GlimsEngine *e, GlimsStrokeID stroke, const GlimsStrokePoint *points, size_t count)
{
  GlimsArgs a = { .item = stroke, .in = points, .n = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_stroke_continue,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_STROKE, stroke, { 0, 0 } },
                            stroke_continue_on_engine, &a, NULL);
}

static GlimsStatus
api_stroke_end (GlimsEngine *e, GlimsStrokeID stroke)
{
  GlimsArgs a = { .item = stroke };
  return glims_facade_call (e, GLIMS_FACADE_OP_stroke_end,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_STROKE, stroke, { 0, 0 } },
                            stroke_end_on_engine, &a, NULL);
}

static GlimsStatus
api_stroke_begin_v2 (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                     GlimsResourceID brush_resource, const GlimsBrushSettings *brush,
                     const GlimsStrokePacketV2 *packet, GlimsStrokeID *out, char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  if (!out) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsStrokeV2Args a = {.image = image, .drawable = drawable, .brush_resource = brush_resource,
                        .brush = brush, .packet = packet, .error = error};
  GlimsStatus status = glims_facade_call (e, GLIMS_FACADE_OP_stroke_begin_v2,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { glims_facade_brush_source (brush), 0 } },
                            stroke_begin_v2_on_engine, &a, error);
  if (status == GLIMS_STATUS_OK) *out = a.stroke;
  return status;
}

static GlimsStatus
api_stroke_continue_v2 (GlimsEngine *e, GlimsStrokeID stroke,
                        const GlimsStrokePacketV2 *packet, char **error)
{
  if (error) *error = NULL;
  GlimsStrokeV2Args a = {.stroke = stroke, .packet = packet, .error = error};
  return glims_facade_call (e, GLIMS_FACADE_OP_stroke_continue_v2,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_STROKE, stroke, { 0, 0 } },
                            stroke_continue_v2_on_engine, &a, error);
}

static GlimsStatus
api_stroke_begin_with_brush_resource (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                      GlimsResourceID brush, const GlimsBrushSettings *settings,
                                      const GlimsStrokePoint *first, GlimsStrokeID *stroke,
                                      char **error)
{
  GlimsStrokeResourceArgs a = { .image = image, .item = layer, .brush = brush,
                                .brush_settings = settings, .first = first,
                                .out = stroke, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_stroke_begin_with_brush_resource,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { glims_facade_brush_source (settings), 0 } },
                            stroke_begin_with_brush_resource_on_engine, &a, error);
}

/* Clear only complete known fields within the caller's declared prefix. */
static gboolean
clear_stroke_capture_facts (GlimsStrokeCaptureFacts *facts)
{
  if (!facts)
    return FALSE;

  size_t size = facts->struct_size;
  if (size >= offsetof (GlimsStrokeCaptureFacts, brush_internal) + sizeof facts->brush_internal)
    facts->brush_internal = false;
  if (size >= offsetof (GlimsStrokeCaptureFacts, brush_name) + sizeof facts->brush_name)
    facts->brush_name = NULL;
  if (size >= offsetof (GlimsStrokeCaptureFacts, brush_collection) + sizeof facts->brush_collection)
    facts->brush_collection = NULL;
  if (size < offsetof (GlimsStrokeCaptureFacts, fingerprint) + sizeof facts->fingerprint)
    return FALSE;
  facts->fingerprint = NULL;
  return TRUE;
}

static GlimsStatus
api_stroke_begin_with_capture_facts (GlimsEngine *e, GlimsImageID image,
                                     GlimsItemID drawable, GlimsResourceID brush_resource,
                                     const GlimsBrushSettings *brush,
                                     const GlimsStrokePoint *first,
                                     const char *expected_fingerprint,
                                     GlimsStrokeID *out,
                                     GlimsStrokeCaptureFacts *facts, char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  gboolean facts_ready = clear_stroke_capture_facts (facts);
  if (!out || !brush || !first || !facts_ready)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* The caller's layout never reaches the worker. Transfer owned fields
   * only after the synchronous call has acknowledged success. */
  GlimsStrokeCaptureArgs a = { .image = image, .drawable = drawable,
                               .brush_resource = brush_resource, .brush = brush, .first = first,
                               .expected_fingerprint = expected_fingerprint,
                               .facts = { .struct_size = sizeof (GlimsStrokeCaptureFacts) },
                               .error = error };
  GlimsStatus status = glims_facade_call (e, GLIMS_FACADE_OP_stroke_begin_with_capture_facts,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { glims_facade_brush_source (brush), 0 } },
                            stroke_begin_with_capture_facts_on_engine, &a, error);
  if (status == GLIMS_STATUS_OK)
    {
      *out = a.stroke;
      facts->brush_internal = a.facts.brush_internal;
      facts->brush_name = a.facts.brush_name;
      facts->brush_collection = a.facts.brush_collection;
      facts->fingerprint = a.facts.fingerprint;
    }
  else
    {
      api_free_string (a.facts.brush_name);
      api_free_string (a.facts.brush_collection);
      api_free_string (a.facts.fingerprint);
    }
  return status;
}

static GlimsStatus
api_filter_begin (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                  const char *operation, GlimsFilterID *filter, char **error)
{
  GlimsArgs a = { .image = image, .item = drawable, .string = operation, .out = filter, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_begin,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            filter_begin_on_engine, &a, error);
}

static GlimsStatus
api_filter_set_double (GlimsEngine *e, GlimsFilterID filter, const char *property, double value)
{
  GlimsArgs a = { .item = filter, .string = property, .number = value };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_set_double,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_set_double_on_engine, &a, NULL);
}

static GlimsStatus
api_filter_commit (GlimsEngine *e, GlimsFilterID filter, char **error)
{
  GlimsArgs a = { .item = filter, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_commit,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_commit_on_engine, &a, error);
}

static GlimsStatus
api_filter_abort (GlimsEngine *e, GlimsFilterID filter)
{
  GlimsArgs a = { .item = filter };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_abort,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_abort_on_engine, &a, NULL);
}

static GlimsStatus
api_procedures (GlimsEngine *e, GlimsImageID image, GlimsProcedureInfo *procedures,
                int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = procedures, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_procedures,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            procedures_on_engine, &a, NULL);
}

static GlimsStatus
api_procedure_run (GlimsEngine *e, GlimsImageID image, const char *name, uint32_t run_mode,
                   char **error)
{
  GlimsArgs a = { .image = image, .string = name, .width = (int32_t) run_mode, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_procedure_run,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_ALL_IMAGES, image, { 0, 0 } },
                            procedure_run_on_engine, &a, error);
}

static GlimsStatus
api_procedure_cancel (GlimsEngine *e)
{
  return glims_facade_call (e, GLIMS_FACADE_OP_procedure_cancel,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            procedure_cancel_on_engine, NULL, NULL);
}

static GlimsStatus
api_select_shape (GlimsEngine *e, GlimsImageID image, uint32_t shape, const GlimsPoint *points,
                  size_t count, const GlimsSelectOptions *options)
{
  GlimsArgs a = { .image = image, .width = (int32_t) shape, .in = points, .n = count, .in2 = options };
  return glims_facade_call (e, GLIMS_FACADE_OP_select_shape,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            select_shape_on_engine, &a, NULL);
}

static GlimsStatus
api_select_color (GlimsEngine *e, GlimsImageID image, GlimsPoint point,
                  const GlimsSelectOptions *options, char **error)
{
  GlimsArgs a = { .image = image, .in = &point, .in2 = options, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_select_color,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            select_color_on_engine, &a, error);
}

static GlimsStatus
api_select_command (GlimsEngine *e, GlimsImageID image, uint32_t command, double radius, char **error)
{
  GlimsArgs a = { .image = image, .width = (int32_t) command, .number = radius, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_select_command,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            select_command_on_engine, &a, error);
}

static GlimsStatus
api_selection_bounds (GlimsEngine *e, GlimsImageID image, bool *empty, GlimsRect *bounds)
{
  GlimsArgs a = { .image = image, .out = empty, .in_out = bounds };
  return glims_facade_call (e, GLIMS_FACADE_OP_selection_bounds,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            selection_bounds_on_engine, &a, NULL);
}

static GlimsStatus
api_selection_outline (GlimsEngine *e, GlimsImageID image, GlimsSegment *segments,
                       int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = segments, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_selection_outline,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            selection_outline_on_engine, &a, NULL);
}

static GlimsStatus
api_fill (GlimsEngine *e, GlimsImageID image, GlimsPoint point, const GlimsFillSettings *settings,
          char **error)
{
  GlimsArgs a = { .image = image, .in = &point, .in2 = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_fill,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            fill_on_engine, &a, error);
}

static GlimsStatus
api_fill_pattern (GlimsEngine *e, GlimsImageID image, GlimsResourceID pattern, GlimsPoint seed,
                  const GlimsPatternFillSettings *settings, char **error)
{
  GlimsArgs a = { .image = image, .resource = pattern, .in = &seed, .in2 = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_fill_pattern,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            fill_pattern_on_engine, &a, error);
}

static GlimsStatus
api_gradient (GlimsEngine *e, GlimsImageID image, GlimsPoint from, GlimsPoint to,
              const GlimsGradientSettings *settings, char **error)
{
  GlimsPoint points[2] = { from, to };
  GlimsArgs  a = { .image = image, .in = points, .in2 = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_gradient,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            gradient_on_engine, &a, error);
}

static GlimsStatus
api_layer_select (GlimsEngine *e, GlimsImageID image, GlimsItemID layer)
{
  GlimsArgs a = { .image = image, .item = layer };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_select,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_select_on_engine, &a, NULL);
}

static GlimsStatus
api_layer_command (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t command,
                   GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) command, .out = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_command,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_command_on_engine, &a, error);
}

static GlimsStatus
api_layer_change (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, const GlimsLayerChange *change,
                  char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in = change, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_change,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_change_on_engine, &a, error);
}

static GlimsStatus
api_layer_move (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, double dx, double dy)
{
  GlimsArgs a = { .image = image, .item = layer, .number = dx, .number2 = dy };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_move,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_move_on_engine, &a, NULL);
}

static GlimsStatus
api_image_crop (GlimsEngine *e, GlimsImageID image, GlimsRect rect, char **error)
{
  GlimsArgs a = { .image = image, .area = rect, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_crop,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_crop_on_engine, &a, error);
}

static GlimsStatus
api_image_transform (GlimsEngine *e, GlimsImageID image, uint32_t transform)
{
  GlimsArgs a = { .image = image, .width = (int32_t) transform };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_transform,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_transform_on_engine, &a, NULL);
}

static GlimsStatus
api_layer_transform (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t transform)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) transform };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_transform,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_transform_on_engine, &a, NULL);
}

static GlimsStatus
api_image_scale (GlimsEngine *e, GlimsImageID image, int32_t width, int32_t height, char **error)
{
  GlimsArgs a = { .image = image, .width = width, .height = height, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_scale,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_scale_on_engine, &a, error);
}

static GlimsStatus
api_image_resize_canvas (GlimsEngine *e, GlimsImageID image, int32_t width, int32_t height,
                         int32_t offset_x, int32_t offset_y, const GlimsColor *fill, char **error)
{
  GlimsArgs a = { .image = image, .area = { offset_x, offset_y, width, height }, .in = fill, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_resize_canvas,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_resize_canvas_on_engine, &a, error);
}

static GlimsStatus
api_layer_transform_matrix (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                            const GlimsMatrix *matrix, uint32_t interpolation, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in = matrix, .width = (int32_t) interpolation,
                  .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_transform_matrix,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_transform_matrix_on_engine, &a, error);
}

static GlimsStatus
api_fonts (GlimsEngine *e, char **names)
{
  GlimsArgs a = { .out = names };
  return glims_facade_call (e, GLIMS_FACADE_OP_fonts,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            fonts_on_engine, &a, NULL);
}

static GlimsStatus
api_layer_transform_matrix_captured (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                     const GlimsLayerTransformRequest *request, char **error)
{
  GlimsLayerTransformRequest copy;
  uint32_t size;
  GlimsArgs a = { .image = image, .item = layer, .in = &copy, .error = error };
  if (error) *error = NULL;
  if (! request) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&size, request, sizeof size);
  if (size < sizeof copy) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&copy, request, sizeof copy);
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_transform_matrix_captured,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_transform_matrix_captured_on_engine, &a, error);
}

static GlimsStatus
api_image_transform_preview (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                              const GlimsLayerTransformRequest *request,
                              GlimsImageID *result, char **error)
{
  GlimsLayerTransformRequest copy;
  uint32_t size;
  GlimsArgs a = { .image = image, .item = layer, .in = &copy, .out = result, .error = error };
  if (error) *error = NULL;
  if (result) *result = 0;
  if (! result || ! request) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&size, request, sizeof size);
  if (size < sizeof copy) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&copy, request, sizeof copy);
  return glims_facade_call (e, GLIMS_FACADE_OP_image_transform_preview,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_transform_preview_on_engine, &a, error);
}

static GlimsStatus
api_text_layer_new (GlimsEngine *e, GlimsImageID image, const char *text,
                    const GlimsTextSettings *settings, GlimsPoint position,
                    GlimsItemID *layer, char **error)
{
  GlimsArgs a = { .image = image, .string = text, .in = settings, .number = position.x,
                  .number2 = position.y, .out = layer, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_text_layer_new,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            text_layer_new_on_engine, &a, error);
}

static GlimsStatus
api_text_layer_new_captured (GlimsEngine *e, GlimsImageID image,
                             const GlimsFloatingState *expected,
                             const char *text,
                             const GlimsTextSettings *settings,
                             GlimsPoint position,
                             GlimsItemID *out, char **error)
{
  GlimsArgs a = { .image = image, .string = text, .in = expected, .in2 = settings,
                  .number = position.x, .number2 = position.y, .out = out, .error = error };
  if (error)
    *error = NULL;
  if (out)
    *out = 0;
  if (! out)
    {
      glims_fail (error, NULL, "The text layer result is required.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (! e)
    return GLIMS_STATUS_NOT_RUNNING;
  return glims_facade_call (e, GLIMS_FACADE_OP_text_layer_new_captured,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            text_layer_new_captured_on_engine, &a, error);
}

static GlimsStatus
api_text_layer_get (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, char **text,
                    GlimsTextSettings *settings)
{
  GlimsArgs a = { .image = image, .item = layer, .out = text, .in_out = settings };
  return glims_facade_call (e, GLIMS_FACADE_OP_text_layer_get,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            text_layer_get_on_engine, &a, NULL);
}

static GlimsStatus
api_text_layer_set (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, const char *text,
                    const GlimsTextSettings *settings, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .string = text, .in = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_text_layer_set,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            text_layer_set_on_engine, &a, error);
}

static GlimsStatus
api_paths (GlimsEngine *e, GlimsImageID image, GlimsPathInfo *rows, int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = rows, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_paths,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            paths_on_engine, &a, NULL);
}

static GlimsStatus
api_path_get (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
              GlimsSubpath *subpaths, int32_t subpath_capacity, int32_t *subpath_count,
              GlimsPathPoint *points, int32_t point_capacity, int32_t *point_count)
{
  GlimsPathArgs a = { .image = image, .path = path, .subpaths = subpaths,
                      .subpath_capacity = subpath_capacity, .subpath_count = subpath_count,
                      .points = points, .point_capacity = point_capacity,
                      .point_count = point_count };
  return glims_facade_call (e, GLIMS_FACADE_OP_path_get,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            path_get_on_engine, &a, NULL);
}

static GlimsStatus
api_path_set (GlimsEngine *e, GlimsImageID image, GlimsItemID path, const char *name,
              const GlimsSubpath *subpaths, int32_t subpath_count,
              const GlimsPathPoint *points, int32_t point_count,
              GlimsItemID *result, char **error)
{
  GlimsPathArgs a = { .image = image, .path = path, .name = name, .subpaths_in = subpaths,
                      .subpath_capacity = subpath_count, .points_in = points,
                      .point_capacity = point_count, .result = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_path_set,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            path_set_on_engine, &a, error);
}

static GlimsStatus
api_path_change (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                 const GlimsPathChange *change, char **error)
{
  GlimsArgs a = { .image = image, .item = path, .in = change, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_path_change,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            path_change_on_engine, &a, error);
}

static GlimsStatus
api_path_delete (GlimsEngine *e, GlimsImageID image, GlimsItemID path)
{
  GlimsArgs a = { .image = image, .item = path };
  return glims_facade_call (e, GLIMS_FACADE_OP_path_delete,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            path_delete_on_engine, &a, NULL);
}

static GlimsStatus
api_path_to_selection (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                       const GlimsSelectOptions *options)
{
  GlimsArgs a = { .image = image, .item = path, .in = options };
  return glims_facade_call (e, GLIMS_FACADE_OP_path_to_selection,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            path_to_selection_on_engine, &a, NULL);
}

static GlimsStatus
api_path_stroke (GlimsEngine *e, GlimsImageID image, GlimsItemID path, GlimsItemID layer,
                 const GlimsLineSettings *settings, char **error)
{
  GlimsArgs a = { .image = image, .item = path, .width = layer, .in = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_path_stroke,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            path_stroke_on_engine, &a, error);
}

MARSHAL (image_copy_pixels, return glims_image_copy_pixels (e, a->image, a->width, a->out, a->error);)
MARSHAL (image_clear, return glims_image_clear (e, a->image, a->in, a->error);)
MARSHAL (image_paste_pixels, return glims_image_paste_pixels (e, a->image, a->area, a->in, a->n, a->out, a->error);)
MARSHAL (image_from_pixels, return glims_image_from_pixels (e, a->width, a->height, a->in, a->n, a->out, a->error);)

static GlimsStatus
api_image_copy_pixels (GlimsEngine *e, GlimsImageID image, bool merged, GlimsPixelBuffer *out, char **error)
{
  GlimsArgs a = { .image = image, .width = merged, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_copy_pixels,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_copy_pixels_on_engine, &a, error);
}

static GlimsStatus
api_image_clear (GlimsEngine *e, GlimsImageID image, const GlimsColor *background, char **error)
{
  GlimsArgs a = { .image = image, .in = background, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_clear,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_clear_on_engine, &a, error);
}

static GlimsStatus
api_image_paste_pixels (GlimsEngine *e, GlimsImageID image, GlimsRect bounds, const uint8_t *pixels,
                        size_t count, GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .area = bounds, .in = pixels, .n = count, .out = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_paste_pixels,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_paste_pixels_on_engine, &a, error);
}

static void api_free_pixels (uint8_t *pixels) { g_free (pixels); }

static GlimsStatus
api_image_from_pixels (GlimsEngine *e, int32_t width, int32_t height, const uint8_t *pixels,
                       size_t count, GlimsImageID *result, char **error)
{
  GlimsArgs a = { .width = width, .height = height, .in = pixels, .n = count, .out = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_from_pixels,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            image_from_pixels_on_engine, &a, error);
}

static GlimsStatus
api_layer_state (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, GlimsLayerState *state)
{
  GlimsArgs a = { .image = image, .item = layer, .out = state };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_state,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_state_on_engine, &a, NULL);
}

static GlimsStatus
api_create_group (GlimsEngine *e, GlimsImageID image, GlimsItemID parent, int32_t index,
                  const char *name, GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .item = parent, .width = index, .string = name, .out = result,
                  .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_create_group,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            create_group_on_engine, &a, error);
}

static GlimsStatus
api_reparent_layer (GlimsEngine *e, GlimsImageID image, GlimsItemID item, GlimsItemID new_parent,
                    int32_t index, char **error)
{
  GlimsArgs a = { .image = image, .item = item, .width = new_parent, .height = index, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_reparent_layer,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            reparent_layer_on_engine, &a, error);
}

static GlimsStatus
api_set_layer_locks (GlimsEngine *e, GlimsImageID image, GlimsItemID item, uint32_t mask,
                     uint32_t values, char **error)
{
  GlimsArgs a = { .image = image, .item = item, .width = (int32_t) mask, .height = (int32_t) values,
                  .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_set_layer_locks,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            set_layer_locks_on_engine, &a, error);
}

static GlimsStatus
api_filter_operations (GlimsEngine *e, GlimsOperationInfo *rows, int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .out = rows, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_operations,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            filter_operations_on_engine, &a, NULL);
}

static GlimsStatus
api_filter_operation_properties (GlimsEngine *e, const char *operation, GlimsFilterProperty *rows,
                                 int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .string = operation, .out = rows, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_operation_properties,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            filter_operation_properties_on_engine, &a, NULL);
}

static GlimsStatus
api_filter_enum_choices (GlimsEngine *e, const char *operation, const char *property,
                         GlimsFilterEnumChoice *rows, int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .string = operation, .in = property, .out = rows, .capacity = capacity,
                  .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_enum_choices,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            filter_enum_choices_on_engine, &a, NULL);
}

static GlimsStatus
api_filter_get_property (GlimsEngine *e, GlimsFilterID filter, const char *property,
                         GlimsFilterValue *value)
{
  GlimsArgs a = { .item = filter, .string = property, .out = value };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_get_property,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_get_property_on_engine, &a, NULL);
}

static GlimsStatus
api_filter_set_property (GlimsEngine *e, GlimsFilterID filter, const char *property,
                         const GlimsFilterValue *value)
{
  GlimsArgs a = { .item = filter, .string = property, .in = value };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_set_property,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_set_property_on_engine, &a, NULL);
}

static GlimsStatus
api_image_history (GlimsEngine *e, GlimsImageID image, GlimsHistoryRow *rows,
                    int32_t capacity, GlimsHistoryInfo *info)
{
  GlimsArgs a = { .image = image, .out = rows, .capacity = capacity, .in_out = info };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_history,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_history_on_engine, &a, NULL);
}

static GlimsStatus
api_image_history_move (GlimsEngine *e, GlimsImageID image, uint64_t revision,
                         int32_t position, char **error)
{
  GlimsArgs a = { .image = image, .revision = revision, .width = position, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_history_move,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_history_move_on_engine, &a, error);
}

static GlimsStatus
api_image_duplicate (GlimsEngine *e, GlimsImageID image, GlimsImageID *result, char **error)
{
  GlimsArgs a = { .image = image, .out = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_duplicate,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_duplicate_on_engine, &a, error);
}

static GlimsStatus
api_layer_mask (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, GlimsMaskState *state)
{
  GlimsArgs a = { .image = image, .item = layer, .out = state };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_mask,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_mask_on_engine, &a, NULL);
}

static GlimsStatus
api_layer_mask_add (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t source,
                    bool edit, GlimsItemID *mask, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) source, .height = edit,
                  .out = mask, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_mask_add,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_mask_add_on_engine, &a, error);
}

static GlimsStatus
api_layer_mask_set (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t flags,
                    uint32_t values, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) flags, .height = (int32_t) values,
                  .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_mask_set,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_mask_set_on_engine, &a, error);
}

static GlimsStatus
api_layer_mask_apply (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t mode,
                      char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) mode, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_mask_apply,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_mask_apply_on_engine, &a, error);
}

static GlimsStatus
api_layer_mask_to_selection (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                             uint32_t operation, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) operation, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_mask_to_selection,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_mask_to_selection_on_engine, &a, error);
}

static GlimsStatus
api_drawable_thumbnail (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable, int32_t max_size,
                        uint8_t *pixels, size_t byte_count, int32_t *width, int32_t *height)
{
  GlimsArgs a = { .image = image, .item = drawable, .width = max_size, .pixels = pixels,
                  .n = byte_count, .count = width, .in_out = height };
  return glims_facade_call (e, GLIMS_FACADE_OP_drawable_thumbnail,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            drawable_thumbnail_on_engine, &a, NULL);
}

static GlimsStatus
api_image_components (GlimsEngine *e, GlimsImageID image, GlimsComponentState *state)
{
  GlimsArgs a = { .image = image, .out = state };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_components,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_components_on_engine, &a, NULL);
}

static GlimsStatus
api_image_set_components (GlimsEngine *e, GlimsImageID image, uint32_t active_mask,
                          uint32_t active_values, uint32_t visible_mask, uint32_t visible_values,
                          char **error)
{
  const uint32_t masks[4] = { active_mask, active_values, visible_mask, visible_values };
  GlimsArgs a = { .image = image, .in = masks, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_set_components,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_set_components_on_engine, &a, error);
}

static GlimsStatus
api_image_channels (GlimsEngine *e, GlimsImageID image, GlimsChannelInfo *channels,
                    int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = channels, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_channels,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_channels_on_engine, &a, NULL);
}

static GlimsStatus
api_channel_from_selection (GlimsEngine *e, GlimsImageID image, const char *name,
                            GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .string = name, .out = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_channel_from_selection,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            channel_from_selection_on_engine, &a, error);
}

static GlimsStatus
api_channel_change (GlimsEngine *e, GlimsImageID image, GlimsItemID channel,
                    const GlimsChannelChange *change, char **error)
{
  GlimsArgs a = { .image = image, .item = channel, .in = change, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_channel_change,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            channel_change_on_engine, &a, error);
}

static GlimsStatus
api_channel_command (GlimsEngine *e, GlimsImageID image, GlimsItemID channel, uint32_t command,
                     GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .item = channel, .width = (int32_t) command, .out = result,
                  .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_channel_command,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            channel_command_on_engine, &a, error);
}

static GlimsStatus
api_channel_to_selection (GlimsEngine *e, GlimsImageID image, GlimsItemID channel,
                          uint32_t operation, char **error)
{
  GlimsArgs a = { .image = image, .item = channel, .width = (int32_t) operation, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_channel_to_selection,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            channel_to_selection_on_engine, &a, error);
}

static GlimsStatus
api_image_quick_mask (GlimsEngine *e, GlimsImageID image, GlimsQuickMaskState *state)
{
  GlimsArgs a = { .image = image, .out = state };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_quick_mask,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_quick_mask_on_engine, &a, NULL);
}

static GlimsStatus
api_image_set_quick_mask (GlimsEngine *e, GlimsImageID image, bool enabled, char **error)
{
  GlimsArgs a = { .image = image, .width = enabled, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_set_quick_mask,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_set_quick_mask_on_engine, &a, error);
}

static GlimsStatus
api_drawable_effects (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                      GlimsEffectInfo *rows, int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .item = drawable, .out = rows,
                  .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_drawable_effects,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            drawable_effects_on_engine, &a, NULL);
}

static GlimsStatus
api_effect_change (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                   GlimsEffectID effect, const GlimsEffectChange *change, char **error)
{
  GlimsArgs a = { .image = image, .item = drawable, .effect = effect,
                  .in = change, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_effect_change,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            effect_change_on_engine, &a, error);
}

static GlimsStatus
api_effect_command (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                    GlimsEffectID effect, uint32_t command, char **error)
{
  GlimsArgs a = { .image = image, .item = drawable, .effect = effect,
                  .width = (int32_t) command, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_effect_command,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            effect_command_on_engine, &a, error);
}

static GlimsStatus
api_image_open_layers (GlimsEngine *e, GlimsImageID image, const char *path,
                       GlimsItemID *layers, int32_t capacity, int32_t *count, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .out = layers,
                  .capacity = capacity, .count = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_open_layers,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_open_layers_on_engine, &a, error);
}

static GlimsStatus
api_image_place_link (GlimsEngine *e, GlimsImageID image, const char *path,
                      GlimsItemID *layer, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .out = layer, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_place_link,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_place_link_on_engine, &a, error);
}

static GlimsStatus
api_filter_edit_begin (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                       GlimsEffectID effect, GlimsFilterID *filter, char **error)
{
  GlimsArgs a = { .image = image, .item = drawable, .effect = effect,
                  .out = filter, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_edit_begin,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            filter_edit_begin_on_engine, &a, error);
}

static GlimsStatus
api_image_color_info (GlimsEngine *e, GlimsImageID image, GlimsColorInfo *info)
{
  GlimsArgs a = { .image = image, .out = info };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_color_info,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_color_info_on_engine, &a, NULL);
}

static GlimsStatus
api_image_convert_mode (GlimsEngine *e, GlimsImageID image, uint32_t mode, char **error)
{
  GlimsArgs a = { .image = image, .width = (int32_t) mode, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_convert_mode,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_convert_mode_on_engine, &a, error);
}

static GlimsStatus
api_image_convert_precision (GlimsEngine *e, GlimsImageID image, uint32_t component,
                             uint32_t trc, char **error)
{
  GlimsArgs a = { .image = image, .width = (int32_t) component, .height = (int32_t) trc,
                  .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_convert_precision,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_convert_precision_on_engine, &a, error);
}

static GlimsStatus
api_path_fill (GlimsEngine *e, GlimsImageID image, GlimsItemID path, GlimsItemID drawable,
               const GlimsPathFillSettings *settings, char **error)
{
  GlimsArgs a = { .image = image, .item = path, .width = drawable, .in = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_path_fill,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            path_fill_on_engine, &a, error);
}

static GlimsStatus
api_path_to_vector_layer (GlimsEngine *e, GlimsImageID image, GlimsItemID path, const char *name,
                          GlimsItemID *layer, char **error)
{
  GlimsArgs a = { .image = image, .item = path, .string = name, .out = layer, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_path_to_vector_layer,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            path_to_vector_layer_on_engine, &a, error);
}

static GlimsStatus
api_image_assign_profile (GlimsEngine *e, GlimsImageID image, const char *path, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_assign_profile,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_assign_profile_on_engine, &a, error);
}

static GlimsStatus
api_image_convert_profile (GlimsEngine *e, GlimsImageID image, const char *path,
                           uint32_t intent, bool black_point_compensation, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .width = (int32_t) intent,
                  .height = black_point_compensation, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_convert_profile,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_convert_profile_on_engine, &a, error);
}

static GlimsStatus
api_image_convert_profile_rasterizing (GlimsEngine *e, GlimsImageID image, const char *path,
                                       uint32_t intent, bool black_point_compensation, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .width = (int32_t) intent,
                  .height = black_point_compensation, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_convert_profile_rasterizing,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_convert_profile_rasterizing_on_engine, &a, error);
}

static GlimsStatus
api_resources (GlimsEngine *e, uint32_t kind, GlimsResourceInfo *rows, int32_t capacity,
               int32_t *count)
{
  GlimsArgs a = { .width = (int32_t) kind, .out = rows, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_resources,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resources_on_engine, &a, NULL);
}

static GlimsStatus
api_resource_identifiers (GlimsEngine *e, GlimsResourceID id, char **name, char **collection,
                          bool *internal, char **error)
{
  GlimsResourceArgs a = { .id = id, .out_name = name, .out_collection = collection,
                          .out_internal = internal, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_resource_identifiers,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resource_identifiers_on_engine, &a, error);
}

static GlimsStatus
api_resource_resolve (GlimsEngine *e, uint32_t kind, const char *name, const char *collection,
                      bool internal, GlimsResourceID *outID, char **error)
{
  GlimsResourceArgs a = { .kind = kind, .name = name, .collection = collection,
                          .internal = internal, .out_id = outID, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_resource_resolve,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resource_resolve_on_engine, &a, error);
}

static GlimsStatus
api_resource_thumbnail (GlimsEngine *e, GlimsResourceID id, int32_t max_size,
                        const GlimsColor *foreground, const GlimsColor *background,
                        GlimsPixelBuffer *out, char **error)
{
  GlimsResourceArgs a = { .id = id, .max_size = max_size, .foreground = foreground,
                          .background = background, .pixels = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_resource_thumbnail,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resource_thumbnail_on_engine, &a, error);
}

static GlimsStatus
api_vector_layer_style_get (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                            GlimsVectorStyle *style, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in_out = style, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_vector_layer_style_get,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            vector_layer_style_get_on_engine, &a, error);
}

static GlimsStatus
api_vector_layer_style_set (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                            const GlimsVectorStyleChange *change, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in = change, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_vector_layer_style_set,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            vector_layer_style_set_on_engine, &a, error);
}

MARSHAL (image_guides, return glims_image_guides (e, a->image, a->out, a->capacity, a->count);)
MARSHAL (guide_put, return glims_guide_put (e, a->image, a->in, a->out, a->error);)
MARSHAL (guide_remove, return glims_guide_remove (e, a->image, a->width, a->error);)
MARSHAL (layer_source_info, return glims_layer_source_info (e, a->image, a->item, a->out, a->error);)
MARSHAL (image_pick_layer, { const GlimsPoint *point = a->in; return glims_image_pick_layer (e, a->image, *point, a->out); })
MARSHAL (image_convert_indexed, return glims_image_convert_indexed (e, a->image, a->in,
                                                                    a->in2, a->capacity, a->error);)
MARSHAL (image_grid, return glims_image_grid (e, a->image, a->out, a->error);)
MARSHAL (image_set_grid, return glims_image_set_grid (e, a->image, a->in, a->error);)
MARSHAL (image_floating_selection, return glims_image_floating_selection (e, a->image, a->out);)
MARSHAL (image_paste_into, return glims_image_paste_into (e, a->image, a->item, a->area,
                                                          a->pixels, a->n, a->out, a->error);)
MARSHAL (floating_command, return glims_floating_command (e, a->image, a->item, (uint32_t) a->width,
                                                          a->out, a->error);)
MARSHAL (selection_float, return glims_selection_float (e, a->image, a->item, (uint32_t) a->width,
                                                         a->out, a->error);)
MARSHAL (image_select_layers, return glims_image_select_layers (e, a->image,
                                                                (const GlimsItemID *) a->in,
                                                                a->n, a->error);)
MARSHAL (image_selected_layers, return glims_image_selected_layers (e, a->image,
                                                                    (GlimsItemID *) a->out,
                                                                    a->capacity, a->count);)
MARSHAL (image_select_items, return glims_image_select_items (e, a->image, (uint32_t) a->width,
                                                              (const GlimsItemID *) a->in,
                                                              a->capacity, a->error);)
MARSHAL (image_selected_items, return glims_image_selected_items (e, a->image, (uint32_t) a->width,
                                                                  (GlimsItemID *) a->out,
                                                                  a->capacity, a->count);)
MARSHAL (image_metadata_tags, return glims_image_metadata_tags (e, a->image, (uint32_t) a->width,
                                                                 (char ***) a->out, a->count, a->error);)
MARSHAL (image_metadata_values, return glims_image_metadata_values (e, a->image, a->string,
                                                                    (char ***) a->out, a->count, a->error);)
MARSHAL (image_metadata_edit, return glims_image_metadata_edit (e, a->image, a->string,
                                                                (uint32_t) a->width,
                                                                (const char *const *) a->in,
                                                                a->capacity, a->error);)
MARSHAL (image_metadata_tag_info, return glims_image_metadata_tag_info (e, a->image, a->string,
                                                                         (GlimsMetadataTagInfo *) a->in_out,
                                                                         a->error);)
MARSHAL (image_metadata_languages, return glims_image_metadata_languages (e, a->image, a->string,
                                                                            (GlimsMetadataLanguageValue **) a->out,
                                                                            a->count, a->error);)

static GlimsStatus
api_image_guides (GlimsEngine *e, GlimsImageID image, GlimsGuideInfo *rows,
                  int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = rows, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_guides,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_guides_on_engine, &a, NULL);
}

static GlimsStatus
api_guide_put (GlimsEngine *e, GlimsImageID image, const GlimsGuideInfo *guide,
               GlimsGuideID *result, char **error)
{
  GlimsArgs a = { .image = image, .in = guide, .out = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_guide_put,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            guide_put_on_engine, &a, error);
}

static GlimsStatus
api_guide_remove (GlimsEngine *e, GlimsImageID image, GlimsGuideID guide, char **error)
{
  GlimsArgs a = { .image = image, .width = guide, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_guide_remove,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            guide_remove_on_engine, &a, error);
}

static GlimsStatus
api_layer_source_info (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                       GlimsLayerSourceInfo *out, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_layer_source_info,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            layer_source_info_on_engine, &a, error);
}

static GlimsStatus
api_image_pick_layer (GlimsEngine *e, GlimsImageID image, GlimsPoint point, GlimsItemID *out)
{
  GlimsArgs a = { .image = image, .in = &point, .out = out };
  if (out)
    *out = 0;
  if (!out) return GLIMS_STATUS_INVALID_ARGUMENT;
  return glims_facade_call (e, GLIMS_FACADE_OP_image_pick_layer,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_pick_layer_on_engine, &a, NULL);
}

static GlimsStatus
api_image_convert_indexed (GlimsEngine *e, GlimsImageID image,
                           const GlimsIndexedSettings *settings,
                           const GlimsColor *colors, int32_t color_count, char **error)
{
  GlimsArgs a = { .image = image, .in = settings, .in2 = colors,
                  .capacity = color_count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_convert_indexed,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_convert_indexed_on_engine, &a, error);
}

static GlimsStatus
api_image_grid (GlimsEngine *e, GlimsImageID image, GlimsGrid *out, char **error)
{
  GlimsArgs a = { .image = image, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_grid,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_grid_on_engine, &a, error);
}

static GlimsStatus
api_image_set_grid (GlimsEngine *e, GlimsImageID image, const GlimsGrid *grid, char **error)
{
  GlimsArgs a = { .image = image, .in = grid, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_set_grid,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_set_grid_on_engine, &a, error);
}

static GlimsStatus
api_selection_stroke (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                      GlimsResourceID brush, const GlimsBrushSettings *settings, char **error)
{
  GlimsSelectionStrokeArgs a = { .image = image, .drawable = drawable, .brush = brush,
                                 .settings = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_selection_stroke,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { glims_facade_brush_source (settings), 0 } },
                            selection_stroke_on_engine, &a, error);
}

static GlimsStatus
api_gradient_resource (GlimsEngine *e, GlimsImageID image, GlimsResourceID gradient,
                       GlimsPoint from, GlimsPoint to,
                       const GlimsResourceGradientSettings *settings, char **error)
{
  GlimsGradientResourceArgs a = { .image = image, .gradient = gradient, .from = from, .to = to,
                                  .settings = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_gradient_resource,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            gradient_resource_on_engine, &a, error);
}

static GlimsStatus
api_image_floating_selection (GlimsEngine *e, GlimsImageID image, GlimsFloatingState *out)
{
  GlimsArgs a = { .image = image, .out = out };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_floating_selection,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_floating_selection_on_engine, &a, NULL);
}

static GlimsStatus
api_image_paste_into (GlimsEngine *e, GlimsImageID image, GlimsItemID target, GlimsRect bounds,
                      const uint8_t *pixels, size_t byte_count, GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .item = target, .area = bounds, .pixels = pixels,
                  .n = byte_count, .out = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_paste_into,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_paste_into_on_engine, &a, error);
}

static GlimsStatus
api_floating_command (GlimsEngine *e, GlimsImageID image, GlimsItemID expected, uint32_t command,
                      GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .item = expected, .width = command, .out = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_floating_command,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            floating_command_on_engine, &a, error);
}

static GlimsStatus
api_selection_float (GlimsEngine *e, GlimsImageID image, GlimsItemID target, uint32_t mode,
                     GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .item = target, .width = (int32_t) mode, .out = result, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_selection_float,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            selection_float_on_engine, &a, error);
}

static GlimsStatus
api_image_select_layers (GlimsEngine *e, GlimsImageID image, const GlimsItemID *layers,
                         size_t count, char **error)
{
  GlimsArgs a = { .image = image, .in = layers, .n = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_select_layers,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_select_layers_on_engine, &a, error);
}

static GlimsStatus
api_image_selected_layers (GlimsEngine *e, GlimsImageID image, GlimsItemID *ids,
                           int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = ids, .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_selected_layers,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_selected_layers_on_engine, &a, NULL);
}

static GlimsStatus
api_image_select_items (GlimsEngine *e, GlimsImageID image, uint32_t kind,
                        const GlimsItemID *items, int32_t count, char **error)
{
  GlimsArgs a = { .image = image, .width = (int32_t) kind, .in = items,
                  .capacity = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_select_items,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_select_items_on_engine, &a, error);
}

static GlimsStatus
api_image_selected_items (GlimsEngine *e, GlimsImageID image, uint32_t kind,
                          GlimsItemID *out, int32_t capacity, int32_t *count)
{
  /* *count is reset to 0 on every failure, including a NULL engine
   * refused inside glims_engine_call. */
  if (count)
    *count = 0;
  GlimsArgs a = { .image = image, .width = (int32_t) kind, .out = out,
                  .capacity = capacity, .count = count };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_selected_items,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_selected_items_on_engine, &a, NULL);
}

static GlimsStatus
api_image_metadata_tags (GlimsEngine *e, GlimsImageID image, uint32_t domain,
                         char ***result, int32_t *count, char **error)
{
  if (result) *result = NULL;
  if (count) *count = 0;
  GlimsArgs a = { .image = image, .width = (int32_t) domain, .out = result,
                  .count = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_metadata_tags,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_metadata_tags_on_engine, &a, error);
}

static GlimsStatus
api_image_metadata_values (GlimsEngine *e, GlimsImageID image, const char *tag,
                           char ***result, int32_t *count, char **error)
{
  if (result) *result = NULL;
  if (count) *count = 0;
  GlimsArgs a = { .image = image, .string = tag, .out = result,
                  .count = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_metadata_values,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_metadata_values_on_engine, &a, error);
}

static GlimsStatus
api_image_metadata_edit (GlimsEngine *e, GlimsImageID image, const char *tag,
                         uint32_t operation, const char *const *values,
                         int32_t count, char **error)
{
  GlimsArgs a = { .image = image, .string = tag, .width = (int32_t) operation,
                  .in = values, .capacity = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_metadata_edit,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_metadata_edit_on_engine, &a, error);
}

static GlimsStatus
api_image_metadata_tag_info (GlimsEngine *e, GlimsImageID image, const char *tag,
                             GlimsMetadataTagInfo *outInfo, char **error)
{
  if (outInfo && outInfo->struct_size >= sizeof *outInfo)
    {
      memset (outInfo, 0, sizeof *outInfo);
      outInfo->struct_size = sizeof *outInfo;
    }
  GlimsArgs a = { .image = image, .string = tag, .in_out = outInfo, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_metadata_tag_info,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_metadata_tag_info_on_engine, &a, error);
}

static GlimsStatus
api_image_metadata_languages (GlimsEngine *e, GlimsImageID image, const char *root,
                              GlimsMetadataLanguageValue **out, int32_t *out_count,
                              char **error)
{
  /* Both outputs are cleared before dispatch: a NULL engine returns
   * NOT_RUNNING and still leaves a prefilled out/count at NULL/0. */
  if (out)
    *out = NULL;
  if (out_count)
    *out_count = 0;
  GlimsArgs a = { .image = image, .string = root, .out = out,
                  .count = out_count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_metadata_languages,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_metadata_languages_on_engine, &a, error);
}

static void
api_metadata_languages_free (GlimsMetadataLanguageValue *values)
{
  glims_metadata_languages_free (values);
}

/* Slot 141 carries three borrowed C strings that must stay alive only
 * for the synchronous engine call. A dedicated Args struct keeps them
 * distinct from the generic GlimsArgs string/vector slots, so no pointer
 * is narrowed or reinterpreted. */
typedef struct
{
  GlimsImageID  image;
  const char   *root;
  const char   *language;
  const char   *text;
  char        **error;
} GlimsMetadataLanguageEditArgs;

static GlimsStatus
image_metadata_edit_language_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsMetadataLanguageEditArgs *a = data;

  return glims_image_metadata_edit_language (e, a->image, a->root, a->language,
                                             a->text, a->error);
}

static GlimsStatus
api_image_metadata_edit_language (GlimsEngine *e, GlimsImageID image, const char *root,
                                  const char *language, const char *text, char **error)
{
  GlimsMetadataLanguageEditArgs a = { .image = image, .root = root,
                                      .language = language, .text = text,
                                      .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_metadata_edit_language,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_metadata_edit_language_on_engine, &a, error);
}

static GlimsStatus
api_resource_create_pixels (GlimsEngine *e, uint32_t kind, const char *name,
                            int32_t width, int32_t height,
                            const uint8_t *pixels, size_t byte_count,
                            uint32_t brush_spacing, GlimsResourceID *outID, char **error)
{
  if (outID) *outID = 0;
  GlimsResourceCreateArgs a = { .kind = kind, .name = name, .width = width, .height = height,
                                .pixels = pixels, .byte_count = byte_count,
                                .brush_spacing = brush_spacing, .out_id = outID, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_resource_create_pixels,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resource_create_pixels_on_engine, &a, error);
}

/* No engine state is involved: free directly, like free_string. */
static void
api_free_metadata_strings (char **strings)
{
  glims_free_metadata_strings (strings);
}

typedef struct {
  GlimsImageID image;
  GlimsItemID parent;
  int32_t index;
  const char *operation, *name;
  GlimsItemID *layer;
  GlimsEffectID *effect;
  char **error;
} GlimsAdjustmentArgs;

static GlimsStatus
adjustment_layer_new_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsAdjustmentArgs *a = data;
  return glims_adjustment_layer_new (e, a->image, a->parent, a->index,
                                     a->operation, a->name, a->layer, a->effect, a->error);
}

static GlimsStatus
api_adjustment_layer_new (GlimsEngine *e, GlimsImageID image, GlimsItemID parent,
    int32_t index, const char *operation, const char *name,
    GlimsItemID *layer, GlimsEffectID *effect, char **error)
{
  if (layer) *layer = 0;
  if (effect) *effect = 0;
  GlimsAdjustmentArgs a = { image, parent, index, operation, name, layer, effect, error };
  return glims_facade_call (e, GLIMS_FACADE_OP_adjustment_layer_new,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            adjustment_layer_new_on_engine, &a, error);
}

/* resource_duplicate carries the full 64-bit source handle besides the
 * 64-bit out handle, so it gets its own args struct; neither id ever
 * travels in one of GlimsArgs' 32-bit fields. */
typedef struct
{
  GlimsResourceID  source;
  const char      *name;
  GlimsResourceID *out_id;
  char           **error;
} GlimsResourceDuplicateArgs;

static GlimsStatus
resource_duplicate_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceDuplicateArgs *a = data;

  return glims_resource_duplicate (e, a->source, a->name, a->out_id, a->error);
}

static GlimsStatus
api_resource_duplicate (GlimsEngine *e, GlimsResourceID sourceID, const char *name,
                        GlimsResourceID *outID, char **error)
{
  /* Zero the output in the bridge too, so a dispatch without a running
   * engine (NOT_RUNNING) still clears a prefilled handle. */
  if (outID) *outID = 0;
  GlimsResourceDuplicateArgs a = { .source = sourceID, .name = name,
                                   .out_id = outID, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_resource_duplicate,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resource_duplicate_on_engine, &a, error);
}

/* resource_create_gradient carries the two endpoint colors besides the
 * full 64-bit out handle, so it gets its own args struct; the required
 * pointer arguments are passed through untouched (validated inside the
 * creator, never pre-dereferenced here). */
typedef struct
{
  const char       *name;
  const GlimsColor *left;
  const GlimsColor *right;
  GlimsResourceID  *out;
  char            **error;
} GlimsResourceCreateGradientArgs;

static GlimsStatus
resource_create_gradient_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceCreateGradientArgs *a = data;

  return glims_resource_create_gradient (e, a->name, a->left, a->right, a->out, a->error);
}

static GlimsStatus
api_resource_create_gradient (GlimsEngine *e, const char *name,
                              const GlimsColor *left, const GlimsColor *right,
                              GlimsResourceID *out, char **error)
{
  /* Zero the output in the bridge too, so a dispatch without a running
   * engine (NOT_RUNNING) still clears a prefilled handle. */
  if (out) *out = 0;
  GlimsResourceCreateGradientArgs a = { .name = name, .left = left, .right = right,
                                        .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_resource_create_gradient,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resource_create_gradient_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  const GlimsItemID *sources;
  int32_t count;
  GlimsItemID *copies;
  char **error;
} GlimsDuplicateLayersArgs;

static GlimsStatus
image_duplicate_layers_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsDuplicateLayersArgs *a = data;
  return glims_image_duplicate_layers (e, a->image, a->sources, a->count, a->copies, a->error);
}

static GlimsStatus
api_image_duplicate_layers (GlimsEngine *e, GlimsImageID image, const GlimsItemID *sources,
                            int32_t count, GlimsItemID *copies, char **error)
{
  GlimsDuplicateLayersArgs a = { .image = image, .sources = sources, .count = count,
                                  .copies = copies, .error = error };
  gboolean invoked = FALSE;
  GlimsStatus status = glims_facade_call_reporting_admission (e, GLIMS_FACADE_OP_image_duplicate_layers,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_duplicate_layers_on_engine, &a, error, &invoked);
  /* The backend captures overlapping sources before clearing copies, and
   * may return a useful partial prefix after a late Core failure. */
  if (!invoked && copies && count >= 1 && count <= 256)
    memset (copies, 0, (size_t) count * sizeof *copies);
  return status;
}

typedef struct {
  GlimsResourceID id;
  uint32_t *flags;
  char **guard, **reason, **error;
  const char *expected_guard, *name;
} GlimsResourceMutationArgs;
static GlimsStatus resource_mutation_info_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceMutationArgs *a = data;
  return glims_resource_mutation_info (e, a->id, a->flags, a->guard, a->reason, a->error);
}
static GlimsStatus resource_rename_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceMutationArgs *a = data;
  return glims_resource_rename_checked (e, a->id, a->expected_guard, a->name, a->error);
}
static GlimsStatus resource_delete_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceMutationArgs *a = data;
  return glims_resource_delete_checked (e, a->id, a->expected_guard, a->error);
}
static GlimsStatus api_resource_mutation_info (GlimsEngine *e, GlimsResourceID id, uint32_t *flags,
                                               char **guard, char **reason, char **error)
{
  if (flags) *flags = 0;
  if (guard) *guard = NULL;
  if (reason) *reason = NULL;
  GlimsResourceMutationArgs a = { .id = id, .flags = flags, .guard = guard, .reason = reason, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_resource_mutation_info,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resource_mutation_info_on_engine, &a, error);
}
static GlimsStatus api_resource_rename (GlimsEngine *e, GlimsResourceID id, const char *guard, const char *name, char **error)
{
  GlimsResourceMutationArgs a = { .id = id, .expected_guard = guard, .name = name, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_resource_rename,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resource_rename_on_engine, &a, error);
}
static GlimsStatus api_resource_delete (GlimsEngine *e, GlimsResourceID id, const char *guard, char **error)
{
  GlimsResourceMutationArgs a = { .id = id, .expected_guard = guard, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_resource_delete,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            resource_delete_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  const GlimsItemID *layers;
  int32_t count;
  char **error;
} GlimsDeleteLayersArgs;
static GlimsStatus image_delete_layers_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsDeleteLayersArgs *a = data;
  return glims_image_delete_layers (e, a->image, a->layers, (size_t) a->count, a->error);
}
static GlimsStatus api_image_delete_layers (GlimsEngine *e, GlimsImageID image,
                                           const GlimsItemID *layers, int32_t count, char **error)
{
  GlimsDeleteLayersArgs a = { .image = image, .layers = layers, .count = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_delete_layers,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_delete_layers_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  GlimsItemID target, source;
  const char *operation;
  GlimsFilterID *out;
  char **error;
} GlimsFilterSourceArgs;
static GlimsStatus filter_begin_with_source_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsFilterSourceArgs *a = data;
  return glims_filter_begin_with_source (e, a->image, a->target, a->operation, a->source, a->out, a->error);
}
static GlimsStatus api_filter_begin_with_source (GlimsEngine *e, GlimsImageID image,
                                                GlimsItemID target, const char *operation,
                                                GlimsItemID source, GlimsFilterID *out, char **error)
{
  if (out) *out = 0;
  GlimsFilterSourceArgs a = { .image = image, .target = target, .source = source,
                              .operation = operation, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_begin_with_source,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { source, 0 } },
                            filter_begin_with_source_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  GlimsItemID target, x_source, y_source;
  GlimsFilterID *out;
  char **error;
} GlimsDisplaceSourcesArgs;
static GlimsStatus displace_sources_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsDisplaceSourcesArgs *a = data;
  return glims_filter_begin_displace_with_sources (e, a->image, a->target,
                                                   a->x_source, a->y_source,
                                                   a->out, a->error);
}
static GlimsStatus api_filter_begin_displace_with_sources (GlimsEngine *e,
                                                           GlimsImageID image,
                                                           GlimsItemID target,
                                                           GlimsItemID x_source,
                                                           GlimsItemID y_source,
                                                           GlimsFilterID *out,
                                                           char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  if (!out) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsDisplaceSourcesArgs args = { .image = image, .target = target,
                                   .x_source = x_source, .y_source = y_source,
                                   .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_begin_displace_with_sources,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { x_source, y_source } },
                            displace_sources_on_engine, &args, error);
}

typedef struct {
  GlimsImageID image;
  GlimsItemID target, radius_source, exponent_source;
  GlimsFilterID *out;
  char **error;
} GlimsOilifySourcesArgs;
static GlimsStatus oilify_sources_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsOilifySourcesArgs *a = data;
  return glims_filter_begin_oilify_with_sources (e, a->image, a->target,
                                                 a->radius_source, a->exponent_source,
                                                 a->out, a->error);
}
static GlimsStatus api_filter_begin_oilify_with_sources (GlimsEngine *e,
                                                        GlimsImageID image,
                                                        GlimsItemID target,
                                                        GlimsItemID radius_source,
                                                        GlimsItemID exponent_source,
                                                        GlimsFilterID *out,
                                                        char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  if (!out) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOilifySourcesArgs args = { .image = image, .target = target,
                                 .radius_source = radius_source, .exponent_source = exponent_source,
                                 .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_begin_oilify_with_sources,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { radius_source, exponent_source } },
                            oilify_sources_on_engine, &args, error);
}

typedef struct {
  GlimsFilterID filter;
  GlimsBrightnessContrastSettings *out;
  const GlimsBrightnessContrastSettings *settings;
  char **error;
} GlimsBrightnessContrastArgs;
static GlimsStatus filter_brightness_contrast_get_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsBrightnessContrastArgs *a = data;
  return glims_filter_brightness_contrast_get (e, a->filter, a->out, a->error);
}
static GlimsStatus filter_brightness_contrast_set_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsBrightnessContrastArgs *a = data;
  return glims_filter_brightness_contrast_set (e, a->filter, a->settings, a->error);
}
static GlimsStatus api_filter_brightness_contrast_get (GlimsEngine *e, GlimsFilterID filter,
                                                      GlimsBrightnessContrastSettings *out, char **error)
{
  if (out && out->struct_size >= sizeof *out) out->brightness = out->contrast = 0;
  GlimsBrightnessContrastArgs a = { .filter = filter, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_brightness_contrast_get,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_brightness_contrast_get_on_engine, &a, error);
}
static GlimsStatus api_filter_brightness_contrast_set (GlimsEngine *e, GlimsFilterID filter,
                                                           const GlimsBrightnessContrastSettings *settings, char **error)
{
  GlimsBrightnessContrastArgs a = { .filter = filter, .settings = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_brightness_contrast_set,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_brightness_contrast_set_on_engine, &a, error);
}

typedef struct {
  GlimsFilterID filter;
  GlimsColorBalanceSettings *out;
  const GlimsColorBalanceSettings *settings;
  char **error;
} GlimsColorBalanceArgs;
static GlimsStatus filter_color_balance_get_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsColorBalanceArgs *a = data;
  return glims_filter_color_balance_get (e, a->filter, a->out, a->error);
}
static GlimsStatus filter_color_balance_set_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsColorBalanceArgs *a = data;
  return glims_filter_color_balance_set (e, a->filter, a->settings, a->error);
}
static GlimsStatus api_filter_color_balance_get (GlimsEngine *e, GlimsFilterID filter,
                                                GlimsColorBalanceSettings *out, char **error)
{
  if (out && out->struct_size >= sizeof *out) {
    out->preserve_luminosity = 0;
    out->shadows = out->midtones = out->highlights = (GlimsColorBalanceRange) {0};
  }
  GlimsColorBalanceArgs a = { .filter = filter, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_color_balance_get,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_color_balance_get_on_engine, &a, error);
}
static GlimsStatus api_filter_color_balance_set (GlimsEngine *e, GlimsFilterID filter,
                                                const GlimsColorBalanceSettings *settings, char **error)
{
  GlimsColorBalanceArgs a = { .filter = filter, .settings = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_color_balance_set,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_color_balance_set_on_engine, &a, error);
}

typedef struct {
  GlimsFilterID filter;
  GlimsHueSaturationSettings *out;
  const GlimsHueSaturationSettings *settings;
  char **error;
} GlimsHueSaturationArgs;
static GlimsStatus filter_hue_saturation_get_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsHueSaturationArgs *a = data;
  return glims_filter_hue_saturation_get (e, a->filter, a->out, a->error);
}
static GlimsStatus filter_hue_saturation_set_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsHueSaturationArgs *a = data;
  return glims_filter_hue_saturation_set (e, a->filter, a->settings, a->error);
}
static GlimsStatus api_filter_hue_saturation_get (GlimsEngine *e, GlimsFilterID filter,
                                                GlimsHueSaturationSettings *out, char **error)
{
  if (out && out->struct_size >= sizeof *out) {
    out->overlap = 0;
    out->master = out->red = out->yellow = out->green = out->cyan = out->blue = out->magenta =
      (GlimsHueSaturationRange) {0};
  }
  GlimsHueSaturationArgs a = { .filter = filter, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_hue_saturation_get,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_hue_saturation_get_on_engine, &a, error);
}
static GlimsStatus api_filter_hue_saturation_set (GlimsEngine *e, GlimsFilterID filter,
                                                const GlimsHueSaturationSettings *settings, char **error)
{
  GlimsHueSaturationArgs a = { .filter = filter, .settings = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_hue_saturation_set,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_hue_saturation_set_on_engine, &a, error);
}

typedef struct {
  GlimsFilterID filter;
  GlimsLevelsSettings *out;
  const GlimsLevelsSettings *settings;
  char **error;
} GlimsLevelsArgs;
static GlimsStatus filter_levels_get_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsLevelsArgs *a = data;
  return glims_filter_levels_get (e, a->filter, a->out, a->error);
}
static GlimsStatus filter_levels_set_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsLevelsArgs *a = data;
  return glims_filter_levels_set (e, a->filter, a->settings, a->error);
}
static GlimsStatus api_filter_levels_get (GlimsEngine *e, GlimsFilterID filter,
                                                GlimsLevelsSettings *out, char **error)
{
  if (out && out->struct_size >= sizeof *out) {
    out->trc = out->clamp_input = out->clamp_output = 0;
    out->value = out->red = out->green = out->blue = out->alpha = (GlimsLevelsChannel) {0};
  }
  GlimsLevelsArgs a = { .filter = filter, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_levels_get,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_levels_get_on_engine, &a, error);
}
static GlimsStatus api_filter_levels_set (GlimsEngine *e, GlimsFilterID filter,
                                                const GlimsLevelsSettings *settings, char **error)
{
  GlimsLevelsArgs a = { .filter = filter, .settings = settings, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_levels_set,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_levels_set_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  const GlimsItemID *layers;
  int32_t count;
  char **error;
} GlimsFitLayersArgs;
static GlimsStatus image_fit_layers_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsFitLayersArgs *a = data;
  return glims_image_fit_layers_to_image (e, a->image, a->layers, (size_t) a->count, a->error);
}
static GlimsStatus api_image_fit_layers_to_image (GlimsEngine *e, GlimsImageID image,
                                                 const GlimsItemID *layers, int32_t count, char **error)
{
  GlimsFitLayersArgs a = { .image = image, .layers = layers, .count = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_fit_layers_to_image,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_fit_layers_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  const GlimsItemID *layers;
  int32_t count;
  char **error;
} GlimsRasterizeLayersArgs;
static GlimsStatus image_rasterize_layers_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsRasterizeLayersArgs *a = data;
  return glims_image_rasterize_layers (e, a->image, a->layers, (size_t) a->count, a->error);
}
static GlimsStatus api_image_rasterize_layers (GlimsEngine *e, GlimsImageID image,
                                             const GlimsItemID *layers, int32_t count, char **error)
{
  GlimsRasterizeLayersArgs a = { .image = image, .layers = layers, .count = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_rasterize_layers,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_rasterize_layers_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  const GlimsItemID *layers;
  int32_t count;
  char **error;
} GlimsRestoreLayersArgs;
static GlimsStatus image_restore_layer_sources_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsRestoreLayersArgs *a = data;
  return glims_image_restore_layer_sources (e, a->image, a->layers, (size_t) a->count, a->error);
}
static GlimsStatus api_image_restore_layer_sources (GlimsEngine *e, GlimsImageID image,
                                                    const GlimsItemID *layers, int32_t count, char **error)
{
  if (error) *error = NULL;
  /* Reject signed negative/oversized counts before conversion or vector access. */
  if (!layers || count < 1 || count > 256) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsRestoreLayersArgs a = { .image = image, .layers = layers, .count = count, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_restore_layer_sources,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_restore_layer_sources_on_engine, &a, error);
}

typedef struct {
  GlimsFilterID filter;
  const GlimsCurveEdit *edit;
  const GlimsCurvesSnapshot *settings;
  uint32_t trc;
  GlimsCurvesSnapshot *out;
  char **error;
} GlimsCurvesArgs;
static GlimsStatus filter_curves_get_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsCurvesArgs *a = data;
  return glims_filter_curves_get (e, a->filter, a->out, a->error);
}
static GlimsStatus filter_curves_edit_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsCurvesArgs *a = data;
  return glims_filter_curves_edit (e, a->filter, a->edit, a->out, a->error);
}
static GlimsStatus filter_curves_set_trc_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsCurvesArgs *a = data;
  return glims_filter_curves_set_trc (e, a->filter, a->trc, a->out, a->error);
}
static GlimsStatus filter_curves_set_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsCurvesArgs *a = data;
  return glims_filter_curves_set (e, a->filter, a->settings, a->error);
}
typedef struct {
  GlimsImageID image;
  const char *path;
  GlimsExportSettings settings;
  const uint8_t *icc;
  size_t icc_length;
  char **error;
} GlimsExportArgs;
static GlimsStatus image_export_configured_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsExportArgs *a = data;
  if (a->icc)
    return glims_image_export_psd_cmyk (e, a->image, a->path, &a->settings,
                                        a->icc, a->icc_length, a->error);
  return glims_image_export_configured (e, a->image, a->path, &a->settings, a->error);
}
static gboolean copy_export_settings (GlimsExportSettings *copy,
                                        const GlimsExportSettings *settings)
{
  uint32_t size;
  const size_t prefix = offsetof (GlimsExportSettings, psd_layout);
  const size_t tail_end = prefix + sizeof copy->psd_layout;
  if (!settings) return FALSE;
  memcpy (&size, settings, sizeof size);
  if (size < prefix || (size > prefix && size < tail_end)) return FALSE;
  memset (copy, 0, sizeof *copy);
  memcpy (copy, settings, MIN (size, sizeof *copy));
  return copy->format != GLIMS_EXPORT_PSD || size >= tail_end;
}
static GlimsStatus api_image_export_configured (GlimsEngine *e, GlimsImageID image,
                                                const char *path,
                                                const GlimsExportSettings *settings,
                                                char **error)
{
  GlimsExportArgs a = { .image = image, .path = path, .error = error };
  if (error) *error = NULL;
  if (!path || !*path || !copy_export_settings (&a.settings, settings))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  return glims_facade_call (e, GLIMS_FACADE_OP_image_export_configured,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_export_configured_on_engine, &a, error);
}
static GlimsStatus api_image_export_psd_cmyk (GlimsEngine *e, GlimsImageID image,
                                             const char *path,
                                             const GlimsExportSettings *settings,
                                             const uint8_t *icc, size_t length, char **error)
{
  GlimsExportArgs a = { .image = image, .path = path, .icc = icc,
                       .icc_length = length, .error = error };
  if (error) *error = NULL;
  if (!path || !*path || !copy_export_settings (&a.settings, settings) ||
      a.settings.format != GLIMS_EXPORT_PSD || !icc || !length || length > 4 * 1024 * 1024)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  return glims_facade_call (e, GLIMS_FACADE_OP_image_export_psd_cmyk,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_export_configured_on_engine, &a, error);
}

static GlimsStatus api_filter_curves_set (GlimsEngine *e, GlimsFilterID filter,
                                         const GlimsCurvesSnapshot *settings, char **error)
{
  GlimsCurvesSnapshot copy;
  uint32_t size;
  if (error) *error = NULL;
  if (!settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&size, settings, sizeof size);
  if (size < sizeof copy) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&copy, settings, sizeof copy);
  GlimsCurvesArgs a = { .filter = filter, .settings = &copy, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_curves_set,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_curves_set_on_engine, &a, error);
}
static GlimsStatus api_filter_curves_get (GlimsEngine *e, GlimsFilterID filter,
                                         GlimsCurvesSnapshot *out, char **error)
{
  glims_curves_snapshot_clear (out);
  GlimsCurvesArgs a = { .filter = filter, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_curves_get,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_curves_get_on_engine, &a, error);
}
static GlimsStatus api_filter_curves_edit (GlimsEngine *e, GlimsFilterID filter,
                                          const GlimsCurveEdit *edit,
                                          GlimsCurvesSnapshot *out, char **error)
{
  glims_curves_snapshot_clear (out);
  GlimsCurvesArgs a = { .filter = filter, .edit = edit, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_curves_edit,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_curves_edit_on_engine, &a, error);
}
static GlimsStatus api_filter_curves_set_trc (GlimsEngine *e, GlimsFilterID filter,
                                             uint32_t trc, GlimsCurvesSnapshot *out,
                                             char **error)
{
  glims_curves_snapshot_clear (out);
  GlimsCurvesArgs a = { .filter = filter, .trc = trc, .out = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_curves_set_trc,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_curves_set_trc_on_engine, &a, error);
}

typedef struct {
  GlimsFilterID filter;
  GlimsHistogramSnapshot *histogram;
  GlimsLevelsSettings *levels;
  char **error;
} GlimsHistogramArgs;
static GlimsStatus filter_histogram_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsHistogramArgs *a = data;
  return glims_filter_input_histogram (e, a->filter, a->histogram, a->error);
}
static GlimsStatus filter_levels_auto_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsHistogramArgs *a = data;
  return glims_filter_levels_auto (e, a->filter, a->levels, a->error);
}
static GlimsStatus api_filter_input_histogram (GlimsEngine *e, GlimsFilterID filter,
                                              GlimsHistogramSnapshot *out, char **error)
{
  glims_histogram_snapshot_clear (out);
  GlimsHistogramArgs a = { .filter = filter, .histogram = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_input_histogram,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_histogram_on_engine, &a, error);
}
static GlimsStatus api_filter_levels_auto (GlimsEngine *e, GlimsFilterID filter,
                                          GlimsLevelsSettings *out, char **error)
{
  if (out && out->struct_size >= sizeof *out) {
    out->trc = out->clamp_input = out->clamp_output = 0;
    out->value = out->red = out->green = out->blue = out->alpha = (GlimsLevelsChannel) {0};
  }
  GlimsHistogramArgs a = { .filter = filter, .levels = out, .error = error };
  return glims_facade_call (e, GLIMS_FACADE_OP_filter_levels_auto,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_FILTER, filter, { 0, 0 } },
                            filter_levels_auto_on_engine, &a, error);
}

/* Two ICC blobs keep their full size_t lengths across synchronous dispatch;
 * no borrowed pointer or profile escapes the completed call. */
typedef struct {
  GlimsImageID image;
  double scale;
  GlimsRect area;
  const uint8_t *destination_icc;
  size_t destination_icc_length;
  const uint8_t *proof_icc;
  size_t proof_icc_length;
  const GlimsProofSettings *settings;
  uint8_t *pixels;
  size_t stride;
  char **error;
} GlimsProofRenderArgs;

static GlimsStatus
image_render_proofed_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsProofRenderArgs *a = data;
  return glims_image_render_proofed (e, a->image, a->scale, a->area,
                                    a->destination_icc, a->destination_icc_length,
                                    a->proof_icc, a->proof_icc_length, a->settings,
                                    a->pixels, a->stride, a->error);
}

static GlimsStatus
api_image_render_proofed (GlimsEngine *e, GlimsImageID image, double scale, GlimsRect area,
                          const uint8_t *destination_icc, size_t destination_icc_length,
                          const uint8_t *proof_icc, size_t proof_icc_length,
                          const GlimsProofSettings *settings,
                          uint8_t *pixels, size_t stride, char **error)
{
  GlimsProofRenderArgs a = { image, scale, area, destination_icc, destination_icc_length,
                            proof_icc, proof_icc_length, settings, pixels, stride, error };
  if (error)
    *error = NULL;
  return glims_facade_call (e, GLIMS_FACADE_OP_image_render_proofed,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_render_proofed_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  int32_t x, y;
  GlimsSampledColor *out;
  char **error;
} GlimsSampleColorArgs;

static GlimsStatus
image_sample_color_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsSampleColorArgs *a = data;
  return glims_image_sample_color (e, a->image, a->x, a->y, a->out, a->error);
}

static GlimsStatus
api_image_sample_color (GlimsEngine *e, GlimsImageID image, int32_t x, int32_t y,
                        GlimsSampledColor *out, char **error)
{
  if (error) *error = NULL;
  if (! out) return GLIMS_STATUS_INVALID_ARGUMENT;
  *out = (GlimsSampledColor) {0};
  GlimsSampleColorArgs a = {image, x, y, out, error};
  return glims_facade_call (e, GLIMS_FACADE_OP_image_sample_color,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_sample_color_on_engine, &a, error);
}

typedef struct {
  int32_t width, height;
  uint32_t component, channel_count;
  GlimsImageID *result;
  char **error;
} MultichannelNewArgs;

static GlimsStatus
image_new_multichannel_on_engine (GlimsEngine *e, gpointer data)
{
  MultichannelNewArgs *a = data;
  return glims_image_new_multichannel (e, a->width, a->height, a->component,
                                       a->channel_count, a->result, a->error);
}

static GlimsStatus
api_image_new_multichannel (GlimsEngine *e, int32_t width, int32_t height,
                            uint32_t component, uint32_t channel_count,
                            GlimsImageID *result, char **error)
{
  if (error) *error = NULL;
  if (result) *result = 0;
  MultichannelNewArgs a = { width, height, component, channel_count, result, error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_new_multichannel,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            image_new_multichannel_on_engine, &a, error);
}

typedef struct {
  const char *path;
  GlimsImageID *result;
  char **error;
} CmykImportArgs;

static GlimsStatus
image_import_native_cmyk_psd_on_engine (GlimsEngine *engine, gpointer data)
{
  CmykImportArgs *args = data;
  return glims_image_import_native_cmyk_psd (engine, args->path, args->result, args->error);
}

static GlimsStatus
api_image_import_native_cmyk_psd (GlimsEngine *engine, const char *path,
                                  GlimsImageID *result, char **error)
{
  if (result) *result = 0;
  if (error) *error = NULL;
  CmykImportArgs args = { path, result, error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_import_native_cmyk_psd,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
    image_import_native_cmyk_psd_on_engine, &args, error);
}

typedef struct {
  int32_t width, height;
  uint32_t component;
  const uint8_t *icc;
  size_t size;
  GlimsImageID *result;
  char **error;
} CmykNewArgs;

static GlimsStatus
image_new_cmyk_on_engine (GlimsEngine *e, gpointer data)
{
  CmykNewArgs *a = data;
  return glims_image_new_cmyk (e, a->width, a->height, a->component,
                              a->icc, a->size, a->result, a->error);
}

static GlimsStatus
api_image_new_cmyk (GlimsEngine *e, int32_t width, int32_t height,
                     uint32_t component, const uint8_t *icc, size_t size,
                     GlimsImageID *result, char **error)
{
  if (error) *error = NULL;
  if (result) *result = 0;
  CmykNewArgs a = { width, height, component, icc, size, result, error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_new_cmyk,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            image_new_cmyk_on_engine, &a, error);
}

typedef struct {
  int32_t width, height;
  uint32_t component;
  GlimsImageID *result;
  char **error;
} LabNewArgs;

static GlimsStatus
image_new_lab_on_engine (GlimsEngine *e, gpointer data)
{
  LabNewArgs *a = data;
  return glims_image_new_lab (e, a->width, a->height, a->component,
                              a->result, a->error);
}

static GlimsStatus
api_image_new_lab (GlimsEngine *e, int32_t width, int32_t height,
                   uint32_t component, GlimsImageID *result, char **error)
{
  if (error) *error = NULL;
  if (result) *result = 0;
  LabNewArgs a = { width, height, component, result, error };
  return glims_facade_call (e, GLIMS_FACADE_OP_image_new_lab,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_NONE, 0, { 0, 0 } },
                            image_new_lab_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  const char *path;
  char **error;
} NativeCmykExportArgs;

static GlimsStatus
image_export_native_cmyk_psd_on_engine (GlimsEngine *engine, gpointer data)
{
  NativeCmykExportArgs *a = data;
  return glims_image_export_native_cmyk_psd (engine, a->image, a->path, a->error);
}

static GlimsStatus
api_image_export_native_cmyk_psd (GlimsEngine *engine, GlimsImageID image,
                                  const char *path, char **error)
{
  if (error) *error = NULL;
  NativeCmykExportArgs a = { image, path, error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_export_native_cmyk_psd,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_export_native_cmyk_psd_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  GlimsItemID channel;
  uint32_t operation;
  double intensity, opacity;
  char **error;
} InkEditArgs;

static GlimsStatus
image_edit_ink_on_engine (GlimsEngine *engine, gpointer data)
{
  InkEditArgs *a = data;
  return glims_image_edit_ink (engine, a->image, a->channel, a->operation,
                               a->intensity, a->opacity, a->error);
}

static GlimsStatus
api_image_edit_ink (GlimsEngine *engine, GlimsImageID image, GlimsItemID channel,
                    uint32_t operation, double intensity, double opacity, char **error)
{
  if (error) *error = NULL;
  InkEditArgs a = { image, channel, operation, intensity, opacity, error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_edit_ink,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_edit_ink_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  GlimsItemID channel;
  const GlimsInkLevelsSettings *settings;
  char **error;
} InkLevelsArgs;

static GlimsStatus
image_levels_ink_on_engine (GlimsEngine *engine, gpointer data)
{
  InkLevelsArgs *a = data;
  return glims_image_levels_ink (engine, a->image, a->channel, a->settings, a->error);
}

static GlimsStatus
api_image_levels_ink (GlimsEngine *engine, GlimsImageID image, GlimsItemID channel,
                      const GlimsInkLevelsSettings *settings, char **error)
{
  if (error) *error = NULL;
  InkLevelsArgs a = { image, channel, settings, error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_levels_ink,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_levels_ink_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  GlimsItemID channel;
  uint64_t token;
  uint64_t *result_token;
  GlimsImageID *copy;
  const GlimsInkLevelsSettings *settings;
  char **error;
} InkSnapshotArgs;

static GlimsStatus
image_ink_snapshot_begin_on_engine (GlimsEngine *engine, gpointer data)
{
  InkSnapshotArgs *a = data;
  return glims_image_ink_snapshot_begin (engine, a->image, a->channel, a->result_token, a->error);
}

static GlimsStatus
api_image_ink_snapshot_begin (GlimsEngine *engine, GlimsImageID image,
                           GlimsItemID channel, uint64_t *token, char **error)
{
  if (error) *error = NULL;
  if (token) *token = 0;
  InkSnapshotArgs a = { .image = image, .channel = channel, .result_token = token, .error = error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_ink_snapshot_begin,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_ink_snapshot_begin_on_engine, &a, error);
}

static GlimsStatus
image_ink_snapshot_levels_on_engine (GlimsEngine *engine, gpointer data)
{
  InkSnapshotArgs *a = data;
  return glims_image_ink_snapshot_levels (engine, a->image, a->token, a->settings, a->copy, a->error);
}

static GlimsStatus
api_image_ink_snapshot_levels (GlimsEngine *engine, GlimsImageID image,
                           uint64_t token, const GlimsInkLevelsSettings *settings, GlimsImageID *copy, char **error)
{
  if (error) *error = NULL;
  if (copy) *copy = 0;
  InkSnapshotArgs a = { .image = image, .token = token, .settings = settings, .copy = copy, .error = error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_ink_snapshot_levels,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_ink_snapshot_levels_on_engine, &a, error);
}

static GlimsStatus
image_ink_snapshot_apply_on_engine (GlimsEngine *engine, gpointer data)
{
  InkSnapshotArgs *a = data;
  return glims_image_ink_snapshot_apply (engine, a->image, a->token, a->settings, a->error);
}

static GlimsStatus
api_image_ink_snapshot_apply (GlimsEngine *engine, GlimsImageID image,
                           uint64_t token, const GlimsInkLevelsSettings *settings, char **error)
{
  if (error) *error = NULL;
  InkSnapshotArgs a = { .image = image, .token = token, .settings = settings, .error = error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_ink_snapshot_apply,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_ink_snapshot_apply_on_engine, &a, error);
}

static GlimsStatus
image_ink_snapshot_end_on_engine (GlimsEngine *engine, gpointer data)
{
  InkSnapshotArgs *a = data;
  return glims_image_ink_snapshot_end (engine, a->image, a->token);
}

static GlimsStatus
api_image_ink_snapshot_end (GlimsEngine *engine, GlimsImageID image,
                           uint64_t token)
{
  InkSnapshotArgs a = { .image = image, .token = token };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_ink_snapshot_end,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_ink_snapshot_end_on_engine, &a, NULL);
}

typedef struct {
  GlimsImageID image;
  GlimsItemID channel;
  uint64_t token;
  const GlimsInkCurvesSettings *settings;
  GlimsImageID *copy;
  char **error;
} InkCurvesArgs;

static GlimsStatus
image_curves_ink_on_engine (GlimsEngine *engine, gpointer data)
{
  InkCurvesArgs *a = data;
  return glims_image_curves_ink (engine, a->image, a->channel, a->settings, a->error);
}

static GlimsStatus
api_image_curves_ink (GlimsEngine *engine, GlimsImageID image, GlimsItemID channel,
                      const GlimsInkCurvesSettings *settings, char **error)
{
  if (error) *error = NULL;
  InkCurvesArgs a = { .image = image, .channel = channel, .settings = settings, .error = error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_curves_ink,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_curves_ink_on_engine, &a, error);
}

static GlimsStatus
image_ink_snapshot_curves_on_engine (GlimsEngine *engine, gpointer data)
{
  InkCurvesArgs *a = data;
  return glims_image_ink_snapshot_curves (engine, a->image, a->token, a->settings, a->copy, a->error);
}

static GlimsStatus
api_image_ink_snapshot_curves (GlimsEngine *engine, GlimsImageID image, uint64_t token,
                               const GlimsInkCurvesSettings *settings, GlimsImageID *copy, char **error)
{
  if (error) *error = NULL;
  if (copy) *copy = 0;
  InkCurvesArgs a = { .image = image, .token = token, .settings = settings, .copy = copy, .error = error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_ink_snapshot_curves,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_ink_snapshot_curves_on_engine, &a, error);
}

static GlimsStatus
image_ink_snapshot_apply_curves_on_engine (GlimsEngine *engine, gpointer data)
{
  InkCurvesArgs *a = data;
  return glims_image_ink_snapshot_apply_curves (engine, a->image, a->token, a->settings, a->error);
}

static GlimsStatus
api_image_ink_snapshot_apply_curves (GlimsEngine *engine, GlimsImageID image, uint64_t token,
                                     const GlimsInkCurvesSettings *settings, char **error)
{
  if (error) *error = NULL;
  InkCurvesArgs a = { .image = image, .token = token, .settings = settings, .error = error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_ink_snapshot_apply_curves,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_ink_snapshot_apply_curves_on_engine, &a, error);
}

static GlimsStatus
image_ink_channel_identity_on_engine (GlimsEngine *engine, gpointer data)
{
  GlimsArgs *a = data;
  return glims_image_ink_channel_identity (engine, a->image, a->item, a->out);
}

static GlimsStatus
api_image_ink_channel_identity (GlimsEngine *engine, GlimsImageID image,
                                GlimsItemID channel,
                                GlimsInkChannelIdentity *out)
{
  GlimsArgs a = { .image = image, .item = channel, .out = out };
  GlimsStatus status;

  if (! out)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Preserve caller struct_size/tail on accepted capacity. Clear the known
   * payload on every failure, including admission/NOT_RUNNING, without trusting
   * arbitrary caller-declared sizes for memset. */
  if (out->struct_size >= sizeof (*out))
    {
      GlimsInkChannelIdentity temp = { 0 };

      temp.struct_size = out->struct_size;
      memcpy (out, &temp, sizeof temp);
    }
  else
    {
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = glims_facade_call (engine, GLIMS_FACADE_OP_image_ink_channel_identity,
                              (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                              image_ink_channel_identity_on_engine, &a, NULL);
  if (status != GLIMS_STATUS_OK)
    {
      GlimsInkChannelIdentity temp = { 0 };

      temp.struct_size = out->struct_size;
      memcpy (out, &temp, sizeof temp);
    }
  return status;
}

static GlimsStatus
image_lab_axes_on_engine (GlimsEngine *engine, gpointer data)
{
  GlimsArgs *a = data;
  return glims_image_lab_axes (engine, a->image, a->out);
}

static GlimsStatus
api_image_lab_axes (GlimsEngine *engine, GlimsImageID image, GlimsLabAxes *out)
{
  if (!out || out->struct_size < sizeof (*out))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsLabAxes empty = { .struct_size = out->struct_size };
  memcpy (out, &empty, sizeof empty);
  GlimsArgs a = { .image = image, .out = out };
  GlimsStatus status = glims_facade_call (engine, GLIMS_FACADE_OP_image_lab_axes,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_lab_axes_on_engine, &a, NULL);
  if (status != GLIMS_STATUS_OK)
    memcpy (out, &empty, sizeof empty);
  return status;
}

typedef struct {
  GlimsImageID image;
  GlimsLabFillSettings settings;
  char **error;
} LabFillArgs;

static GlimsStatus
image_fill_lab_on_engine (GlimsEngine *engine, gpointer data)
{
  LabFillArgs *a = data;
  return glims_image_fill_lab (engine, a->image, &a->settings, a->error);
}

static GlimsStatus
api_image_fill_lab (GlimsEngine *engine, GlimsImageID image,
                    const GlimsLabFillSettings *settings, char **error)
{
  if (error) *error = NULL;
  if (!settings || settings->struct_size < sizeof *settings)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  LabFillArgs a = { image, *settings, error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_fill_lab,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_fill_lab_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  GlimsResourceID brush;
  GlimsLabBrushSettings settings;
  const GlimsStrokePacketV2 *packet;
  GlimsStrokeID stroke;
  char **error;
} LabStrokeArgs;

static GlimsStatus
stroke_begin_lab_on_engine (GlimsEngine *engine, gpointer data)
{
  LabStrokeArgs *a = data;
  return glims_stroke_begin_lab (engine, a->image, a->brush, &a->settings,
                                 a->packet, &a->stroke, a->error);
}

static GlimsStatus
api_stroke_begin_lab (GlimsEngine *engine, GlimsImageID image, GlimsResourceID brush,
                      const GlimsLabBrushSettings *settings,
                      const GlimsStrokePacketV2 *packet, GlimsStrokeID *out, char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  if (!out || !settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  uint32_t size;
  memcpy (&size, settings, sizeof size);
  if (size < sizeof *settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  LabStrokeArgs a = { .image = image, .brush = brush, .packet = packet, .error = error };
  memcpy (&a.settings, settings, sizeof a.settings);
  GlimsStatus status = glims_facade_call (engine, GLIMS_FACADE_OP_stroke_begin_lab,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    stroke_begin_lab_on_engine, &a, error);
  if (status == GLIMS_STATUS_OK) *out = a.stroke;
  return status;
}

static GlimsStatus
stroke_cancel_lab_on_engine (GlimsEngine *engine, gpointer data)
{
  return glims_stroke_cancel_lab (engine, *(GlimsStrokeID *) data);
}

typedef struct {
  LabStrokeArgs begin;
  const char *expected;
  GlimsStrokeCaptureFacts facts;
} LabStrokeCaptureArgs;

static GlimsStatus
stroke_begin_lab_capture_on_engine (GlimsEngine *engine, gpointer data)
{
  LabStrokeCaptureArgs *a = data;
  return glims_stroke_begin_lab_with_capture_facts (engine, a->begin.image,
    a->begin.brush, &a->begin.settings, a->begin.packet, a->expected,
    &a->begin.stroke, &a->facts, a->begin.error);
}

static GlimsStatus
api_stroke_begin_lab_with_capture_facts (GlimsEngine *engine, GlimsImageID image,
    GlimsResourceID brush, const GlimsLabBrushSettings *settings,
    const GlimsStrokePacketV2 *packet, const char *expected_fingerprint,
    GlimsStrokeID *out, GlimsStrokeCaptureFacts *facts, char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  if (!facts) return GLIMS_STATUS_INVALID_ARGUMENT;
  uint32_t facts_size;
  memcpy (&facts_size, facts, sizeof facts_size);
  if (facts_size < sizeof *facts) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsStrokeCaptureFacts empty = { .struct_size = facts_size };
  memcpy (facts, &empty, sizeof empty);
  if (!out || !settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  uint32_t settings_size;
  memcpy (&settings_size, settings, sizeof settings_size);
  if (settings_size < sizeof *settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  LabStrokeCaptureArgs a = {
    .begin = { .image = image, .brush = brush, .packet = packet, .error = error },
    .expected = expected_fingerprint, .facts = { .struct_size = sizeof a.facts }
  };
  memcpy (&a.begin.settings, settings, sizeof a.begin.settings);
  GlimsStatus status = glims_facade_call (engine, GLIMS_FACADE_OP_stroke_begin_lab_with_capture_facts,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    stroke_begin_lab_capture_on_engine, &a, error);
  if (status == GLIMS_STATUS_OK)
    {
      *out = a.begin.stroke;
      a.facts.struct_size = facts_size;
      memcpy (facts, &a.facts, sizeof a.facts);
    }
  else
    {
      g_free (a.facts.brush_name);
      g_free (a.facts.brush_collection);
      g_free (a.facts.fingerprint);
    }
  return status;
}

static GlimsStatus
api_stroke_cancel_lab (GlimsEngine *engine, GlimsStrokeID stroke)
{
  return glims_facade_call (engine, GLIMS_FACADE_OP_stroke_cancel_lab,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_STROKE, stroke, { 0, 0 } },
    stroke_cancel_lab_on_engine, &stroke, NULL);
}

typedef struct {
  GlimsImageID image;
  uint32_t shape;
  const GlimsPoint *points;
  size_t count;
  const GlimsLabSelectOptions *options;
  char **error;
} LabSelectShapeArgs;

static GlimsStatus
image_select_lab_shape_on_engine (GlimsEngine *engine, gpointer data)
{
  LabSelectShapeArgs *a = data;
  return glims_image_select_lab_shape (engine, a->image, a->shape, a->points,
                                       a->count, a->options, a->error);
}

static GlimsStatus
api_image_select_lab_shape (GlimsEngine *engine, GlimsImageID image,
                            uint32_t shape, const GlimsPoint *points, size_t count,
                            const GlimsLabSelectOptions *options, char **error)
{
  if (error) *error = NULL;
  LabSelectShapeArgs a = { image, shape, points, count, options, error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_select_lab_shape,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_select_lab_shape_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  uint32_t command;
  char **error;
} LabSelectCommandArgs;

static GlimsStatus
image_select_lab_command_on_engine (GlimsEngine *engine, gpointer data)
{
  LabSelectCommandArgs *a = data;
  return glims_image_select_lab_command (engine, a->image, a->command, a->error);
}

static GlimsStatus
api_image_select_lab_command (GlimsEngine *engine, GlimsImageID image,
                              uint32_t command, char **error)
{
  if (error) *error = NULL;
  LabSelectCommandArgs a = { image, command, error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_select_lab_command,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_select_lab_command_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  const GlimsLabCopySettings *settings;
  GlimsImageID *result;
  char **error;
} LabCopyArgs;

static GlimsStatus
image_convert_lab_copy_on_engine (GlimsEngine *engine, gpointer data)
{
  LabCopyArgs *a = data;
  return glims_image_convert_lab_copy (engine, a->image, a->settings, a->result, a->error);
}

static GlimsStatus
api_image_convert_lab_copy (GlimsEngine *engine, GlimsImageID image,
                            const GlimsLabCopySettings *settings,
                            GlimsImageID *result, char **error)
{
  if (result) *result = 0;
  if (error) *error = NULL;
  if (!result) return GLIMS_STATUS_INVALID_ARGUMENT;
  LabCopyArgs a = { image, settings, result, error };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_convert_lab_copy,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_convert_lab_copy_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  GlimsLabCurvesSettings settings;
  char **error;
} LabCurvesArgs;

static GlimsStatus
image_curves_lab_on_engine (GlimsEngine *engine, gpointer data)
{
  LabCurvesArgs *a = data;
  return glims_image_curves_lab (engine, a->image, &a->settings, a->error);
}

static GlimsStatus
api_image_curves_lab (GlimsEngine *engine, GlimsImageID image,
                      const GlimsLabCurvesSettings *settings, char **error)
{
  if (error) *error = NULL;
  if (!settings || settings->struct_size < sizeof *settings)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  LabCurvesArgs a = { .image = image, .error = error };
  memcpy (&a.settings, settings, sizeof a.settings);
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_curves_lab,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_curves_lab_on_engine, &a, error);
}

typedef struct {
  GlimsImageID image;
  GlimsLabSnapshotTarget target;
  uint64_t token;
  uint64_t *result_token;
  GlimsLabCurvesSettings settings;
  GlimsImageID *result_image;
  char **error;
} LabSnapshotArgs;

static GlimsStatus
image_lab_snapshot_begin_on_engine (GlimsEngine *engine, gpointer data)
{
  LabSnapshotArgs *a = data;
  return glims_image_lab_snapshot_begin (engine, a->image, &a->target, a->result_token, a->error);
}

static GlimsStatus
api_image_lab_snapshot_begin (GlimsEngine *engine, GlimsImageID image,
                              const GlimsLabSnapshotTarget *target,
                              uint64_t *token, char **error)
{
  if (error) *error = NULL;
  if (token) *token = 0;
  if (!target || target->struct_size < sizeof *target)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  LabSnapshotArgs a = { .image = image, .result_token = token, .error = error };
  memcpy (&a.target, target, sizeof a.target);
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_lab_snapshot_begin,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_lab_snapshot_begin_on_engine, &a, error);
}

static GlimsStatus
image_lab_snapshot_curves_on_engine (GlimsEngine *engine, gpointer data)
{
  LabSnapshotArgs *a = data;
  return glims_image_lab_snapshot_curves (engine, a->image, a->token, &a->settings,
                                          a->result_image, a->error);
}

static GlimsStatus
api_image_lab_snapshot_curves (GlimsEngine *engine, GlimsImageID image, uint64_t token,
                               const GlimsLabCurvesSettings *settings,
                               GlimsImageID *result, char **error)
{
  if (error) *error = NULL;
  if (result) *result = 0;
  if (!result || !settings || settings->struct_size < sizeof *settings)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  LabSnapshotArgs a = { .image = image, .token = token, .result_image = result, .error = error };
  memcpy (&a.settings, settings, sizeof a.settings);
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_lab_snapshot_curves,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_lab_snapshot_curves_on_engine, &a, error);
}

static GlimsStatus
image_lab_snapshot_apply_curves_on_engine (GlimsEngine *engine, gpointer data)
{
  LabSnapshotArgs *a = data;
  return glims_image_lab_snapshot_apply_curves (engine, a->image, a->token,
                                                &a->settings, a->error);
}

static GlimsStatus
api_image_lab_snapshot_apply_curves (GlimsEngine *engine, GlimsImageID image, uint64_t token,
                                     const GlimsLabCurvesSettings *settings, char **error)
{
  if (error) *error = NULL;
  if (!settings || settings->struct_size < sizeof *settings)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  LabSnapshotArgs a = { .image = image, .token = token, .error = error };
  memcpy (&a.settings, settings, sizeof a.settings);
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_lab_snapshot_apply_curves,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_lab_snapshot_apply_curves_on_engine, &a, error);
}

static GlimsStatus
image_lab_snapshot_end_on_engine (GlimsEngine *engine, gpointer data)
{
  LabSnapshotArgs *a = data;
  return glims_image_lab_snapshot_end (engine, a->image, a->token);
}

static GlimsStatus
api_image_lab_snapshot_end (GlimsEngine *engine, GlimsImageID image, uint64_t token)
{
  LabSnapshotArgs a = { .image = image, .token = token };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_lab_snapshot_end,
                            (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
                            image_lab_snapshot_end_on_engine, &a, NULL);
}

typedef struct {
  GlimsImageID image;
  GlimsResourceID brush;
  GlimsInkStrokeTarget target;
  GlimsBrushSettings settings;
  GlimsStrokePacketV2 packet;
  const char *expected;
  GlimsStrokeID stroke;
  GlimsStrokeCaptureFacts facts;
  char **error;
} InkStrokeCaptureArgs;

static GlimsStatus
stroke_begin_ink_with_capture_facts_on_engine (GlimsEngine *engine, gpointer data)
{
  InkStrokeCaptureArgs *a = data;
  return glims_stroke_begin_ink_with_capture_facts (engine, a->image, a->brush,
    &a->target, &a->settings, &a->packet, a->expected,
    &a->stroke, &a->facts, a->error);
}

static GlimsStatus
api_stroke_begin_ink_with_capture_facts (GlimsEngine *engine, GlimsImageID image,
    GlimsResourceID brush, const GlimsInkStrokeTarget *target,
    const GlimsBrushSettings *settings, const GlimsStrokePacketV2 *first,
    const char *expected_fingerprint, GlimsStrokeID *result,
    GlimsStrokeCaptureFacts *facts, char **error)
{
  if (result) *result = 0;
  if (error) *error = NULL;
  if (!facts) return GLIMS_STATUS_INVALID_ARGUMENT;
  uint32_t facts_size;
  memcpy (&facts_size, facts, sizeof facts_size);
  if (facts_size < sizeof *facts) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsStrokeCaptureFacts empty = { .struct_size = facts_size };
  memcpy (facts, &empty, sizeof empty);
  if (!result || !target || !settings || !first)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  uint32_t target_size, settings_size, packet_size;
  memcpy (&target_size, target, sizeof target_size);
  if (target_size < sizeof *target) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&settings_size, settings, sizeof settings_size);
  if (settings_size < sizeof *settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&packet_size, first, sizeof packet_size);
  if (packet_size < sizeof *first) return GLIMS_STATUS_INVALID_ARGUMENT;

  InkStrokeCaptureArgs a = {
    .image = image, .brush = brush, .expected = expected_fingerprint,
    .facts = { .struct_size = sizeof a.facts }, .error = error
  };
  memcpy (&a.target, target, sizeof a.target);
  memcpy (&a.settings, settings, sizeof a.settings);
  memcpy (&a.packet, first, sizeof a.packet);
  /* The borrowed samples remain immutable until this synchronous call returns;
   * the local header exposes only the copied known prefix to native validation. */
  a.packet.struct_size = sizeof a.packet;
  GlimsStatus status = glims_facade_call (engine, GLIMS_FACADE_OP_stroke_begin_ink_with_capture_facts,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    stroke_begin_ink_with_capture_facts_on_engine, &a, error);
  if (status == GLIMS_STATUS_OK)
    {
      *result = a.stroke;
      a.facts.struct_size = facts_size;
      memcpy (facts, &a.facts, sizeof a.facts);
    }
  else
    {
      g_free (a.facts.brush_name);
      g_free (a.facts.brush_collection);
      g_free (a.facts.fingerprint);
    }
  return status;
}

static GlimsStatus
stroke_cancel_ink_on_engine (GlimsEngine *engine, gpointer data)
{
  return glims_stroke_cancel_ink (engine, *(GlimsStrokeID *) data);
}

static GlimsStatus
api_stroke_cancel_ink (GlimsEngine *engine, GlimsStrokeID stroke)
{
  return glims_facade_call (engine, GLIMS_FACADE_OP_stroke_cancel_ink,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_STROKE, stroke, { 0, 0 } },
    stroke_cancel_ink_on_engine, &stroke, NULL);
}

typedef struct {
  GlimsImageID image;
  uint64_t token;
  GlimsLabLevelsSettings settings;
  GlimsImageID *result;
  char **error;
} LabLevelsArgs;

static gboolean
copy_lab_levels_settings (const GlimsLabLevelsSettings *source, GlimsLabLevelsSettings *copy)
{
  if (!source) return FALSE;
  uint32_t size;
  const unsigned char *bytes = (const unsigned char *) (const void *) source;
  memcpy (&size, bytes, sizeof size);
  if (size < sizeof *copy) return FALSE;
  memcpy (copy, bytes, sizeof *copy);
  copy->struct_size = sizeof *copy;
  return TRUE;
}

static GlimsStatus
image_levels_lab_on_engine (GlimsEngine *engine, gpointer data)
{
  LabLevelsArgs *a = data;
  return glims_image_levels_lab (engine, a->image, &a->settings, a->error);
}

static GlimsStatus
api_image_levels_lab (GlimsEngine *engine, GlimsImageID image,
                      const GlimsLabLevelsSettings *settings, char **error)
{
  if (error) *error = NULL;
  LabLevelsArgs a = { .image = image, .error = error };
  if (!copy_lab_levels_settings (settings, &a.settings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_levels_lab,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_levels_lab_on_engine, &a, error);
}

static GlimsStatus
image_lab_snapshot_levels_on_engine (GlimsEngine *engine, gpointer data)
{
  LabLevelsArgs *a = data;
  return glims_image_lab_snapshot_levels (engine, a->image, a->token, &a->settings,
                                          a->result, a->error);
}

static GlimsStatus
api_image_lab_snapshot_levels (GlimsEngine *engine, GlimsImageID image, uint64_t token,
                               const GlimsLabLevelsSettings *settings,
                               GlimsImageID *result, char **error)
{
  if (error) *error = NULL;
  if (result) *result = 0;
  LabLevelsArgs a = { .image = image, .token = token, .result = result, .error = error };
  if (!result || !copy_lab_levels_settings (settings, &a.settings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_lab_snapshot_levels,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_lab_snapshot_levels_on_engine, &a, error);
}

static GlimsStatus
image_lab_snapshot_apply_levels_on_engine (GlimsEngine *engine, gpointer data)
{
  LabLevelsArgs *a = data;
  return glims_image_lab_snapshot_apply_levels (engine, a->image, a->token, &a->settings, a->error);
}

static GlimsStatus
api_image_lab_snapshot_apply_levels (GlimsEngine *engine, GlimsImageID image, uint64_t token,
                                     const GlimsLabLevelsSettings *settings, char **error)
{
  if (error) *error = NULL;
  LabLevelsArgs a = { .image = image, .token = token, .error = error };
  if (!copy_lab_levels_settings (settings, &a.settings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_lab_snapshot_apply_levels,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_lab_snapshot_apply_levels_on_engine, &a, error);
}

typedef struct { GlimsImageID image; GlimsImageStorageInfo *info; } ImageStorageArgs;

static GlimsStatus
image_storage_info_on_engine (GlimsEngine *engine, gpointer data)
{
  ImageStorageArgs *args = data;
  GlimsOpenImage *open = glims_lookup_image (engine, args->image);
  uint32_t size;
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (!args->info) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&size, args->info, sizeof size);
  if (size < sizeof (GlimsImageStorageInfo)) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsImageStorageInfo info = { .struct_size = size };
  switch (open->component_layout)
    {
    case GLIMS_COMPONENT_LAYOUT_ORDINARY: info.layout = GLIMS_IMAGE_LAYOUT_ORDINARY; break;
    case GLIMS_COMPONENT_LAYOUT_FLAT: info.layout = GLIMS_IMAGE_LAYOUT_FLAT_COMPONENT; break;
    case GLIMS_COMPONENT_LAYOUT_LAYERED_LAB:
      info.layout = GLIMS_IMAGE_LAYOUT_LAYERED_LAB;
      info.flags = GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES | GLIMS_IMAGE_STORAGE_LAYER_RENAME |
                   GLIMS_IMAGE_STORAGE_LAYER_DUPLICATE | GLIMS_IMAGE_STORAGE_LAYER_CREATE |
                   GLIMS_IMAGE_STORAGE_LAYER_DELETE | GLIMS_IMAGE_STORAGE_LAYER_REORDER |
                   GLIMS_IMAGE_STORAGE_LAB_SELECTIONS | GLIMS_IMAGE_STORAGE_LAB_LAYER_COLOR_FILL |
                   GLIMS_IMAGE_STORAGE_LAB_LAYER_BRUSH;
      break;
    default: return GLIMS_STATUS_UNSUPPORTED;
    }
  memcpy (args->info, &info, sizeof info);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
api_image_storage_info (GlimsEngine *engine, GlimsImageID image, GlimsImageStorageInfo *info)
{
  ImageStorageArgs args = { image, info };
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_storage_info,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_storage_info_on_engine, &args, NULL);
}

typedef struct {
  GlimsImageID image;
  GlimsItemID root;
  GlimsLabLayerIdentity *out;
} LabLayerIdentityArgs;

static GlimsStatus
image_lab_layer_identity_on_engine (GlimsEngine *engine, gpointer data)
{
  LabLayerIdentityArgs *args = data;
  GlimsOpenImage *open = glims_lookup_image (engine, args->image);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (args->root <= 0) return GLIMS_STATUS_INVALID_ARGUMENT;
  if (open->component_layout != GLIMS_COMPONENT_LAYOUT_LAYERED_LAB)
    return GLIMS_STATUS_UNSUPPORTED;
  g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
  if (!storage) return GLIMS_STATUS_FAILED;
  if (glims_lab_layer_storage_read (open->image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    return GLIMS_STATUS_UNSUPPORTED;
  for (guint i = 0; i < storage->map.count; i++)
    if (gimp_item_get_id (GIMP_ITEM (storage->layers[i].group)) == args->root)
      {
        guint index = storage->layers[i].map_index;
        if (index >= storage->map.count) return GLIMS_STATUS_UNSUPPORTED;
        memcpy (args->out->uuid, storage->map.entries[index].group, sizeof args->out->uuid);
        return GLIMS_STATUS_OK;
      }
  return GLIMS_STATUS_NOT_FOUND;
}

static GlimsStatus
api_image_lab_layer_identity (GlimsEngine *engine, GlimsImageID image,
                              GlimsItemID root, GlimsLabLayerIdentity *out)
{
  uint32_t size;
  if (!out) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&size, out, sizeof size);
  if (size < sizeof (GlimsLabLayerIdentity)) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsLabLayerIdentity result = { .struct_size = size };
  memcpy (out, &result, sizeof result);
  LabLayerIdentityArgs args = { image, root, &result };
  GlimsStatus status = glims_facade_call (engine, GLIMS_FACADE_OP_image_lab_layer_identity,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_lab_layer_identity_on_engine, &args, NULL);
  if (status == GLIMS_STATUS_OK) memcpy (out, &result, sizeof result);
  return status;
}

typedef struct {
  GlimsImageID image;
  GlimsLabLayerFillSettings settings;
  char **error;
} LabLayerFillArgs;

static GlimsStatus
image_fill_lab_layer_on_engine (GlimsEngine *engine, gpointer data)
{
  LabLayerFillArgs *args = data;
  GlimsOpenImage *open = glims_lookup_image (engine, args->image);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (open->component_layout != GLIMS_COMPONENT_LAYOUT_LAYERED_LAB)
    return GLIMS_STATUS_UNSUPPORTED;
  g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
  if (!storage) return GLIMS_STATUS_FAILED;
  if (glims_lab_layer_storage_read (open->image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    return GLIMS_STATUS_UNSUPPORTED;
  for (guint i = 0; i < storage->map.count; i++)
    if (gimp_item_get_id (GIMP_ITEM (storage->layers[i].group)) == args->settings.root)
      {
        guint map_index = storage->layers[i].map_index;
        if (map_index >= storage->map.count ||
            memcmp (storage->map.entries[map_index].group, args->settings.uuid, 16))
          {
            if (args->error) *args->error = g_strdup ("The captured Lab layer has changed. Select it again.");
            return GLIMS_STATUS_INVALID_ARGUMENT;
          }
        gboolean changed = FALSE;
        GlimsStatus status = glims_lab_layer_fill (engine, open->image, storage->layers[i].group,
          args->settings.lightness, args->settings.a, args->settings.b,
          args->settings.opacity, &changed, args->error);
        if (args->error && !*args->error && status == GLIMS_STATUS_INVALID_ARGUMENT)
          *args->error = g_strdup ("The Lab color or selected layer changed. Check the values and select the layer again.");
        else if (args->error && !*args->error && status == GLIMS_STATUS_BUSY)
          *args->error = g_strdup ("Finish the current operation before filling this layer.");
        return status;
      }
  if (args->error) *args->error = g_strdup ("The captured Lab layer no longer exists.");
  return GLIMS_STATUS_NOT_FOUND;
}

static GlimsStatus
api_image_fill_lab_layer (GlimsEngine *engine, GlimsImageID image,
                          const GlimsLabLayerFillSettings *settings, char **error)
{
  if (error) *error = NULL;
  uint32_t size;
  if (!settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&size, settings, sizeof size);
  if (size < sizeof (GlimsLabLayerFillSettings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  LabLayerFillArgs args = { .image = image, .error = error };
  memcpy (&args.settings, settings, sizeof args.settings);
  guint8 zero_uuid[16] = { 0 };
  if (args.settings.root <= 0 || !memcmp (args.settings.uuid, zero_uuid, sizeof zero_uuid))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_fill_lab_layer,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_fill_lab_layer_on_engine, &args, error);
}

typedef struct {
  GlimsImageID image;
  GlimsLabLayerColorFillSettings settings;
  char **error;
} LabLayerColorFillArgs;

static GlimsStatus
image_fill_lab_layer_srgb_on_engine (GlimsEngine *engine, gpointer data)
{
  LabLayerColorFillArgs *args = data;
  const double channels[3] = { args->settings.color.red, args->settings.color.green,
                               args->settings.color.blue };
  float linear[3], lab[3];
  for (guint i = 0; i < 3; i++)
    linear[i] = (float) (channels[i] <= 0.04045 ? channels[i] / 12.92 :
                         pow ((channels[i] + 0.055) / 1.055, 2.4));
  GlimsLabTransform *transform = glims_lab_transform_new ();
  if (!transform) return GLIMS_STATUS_FAILED;
  gboolean converted = glims_lab_transform_from_linear_rgb (transform, linear, 1, lab);
  glims_lab_transform_free (transform);
  if (!converted) return GLIMS_STATUS_FAILED;
  LabLayerFillArgs fill = { .image = args->image, .error = args->error };
  fill.settings.struct_size = sizeof fill.settings;
  fill.settings.root = args->settings.root;
  memcpy (fill.settings.uuid, args->settings.uuid, sizeof fill.settings.uuid);
  fill.settings.lightness = CLAMP ((double)lab[0], 0, 100);
  fill.settings.a = CLAMP ((double)lab[1], -128, 127);
  fill.settings.b = CLAMP ((double)lab[2], -128, 127);
  fill.settings.opacity = args->settings.opacity * args->settings.color.alpha;
  return image_fill_lab_layer_on_engine (engine, &fill);
}

static GlimsStatus
api_image_fill_lab_layer_srgb (GlimsEngine *engine, GlimsImageID image,
                               const GlimsLabLayerColorFillSettings *settings, char **error)
{
  if (error) *error = NULL;
  uint32_t size;
  if (!settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&size, settings, sizeof size);
  if (size < sizeof (GlimsLabLayerColorFillSettings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  LabLayerColorFillArgs args = { .image = image, .error = error };
  memcpy (&args.settings, settings, sizeof args.settings);
  const double values[] = { args.settings.color.red, args.settings.color.green,
                            args.settings.color.blue, args.settings.color.alpha,
                            args.settings.opacity };
  guint8 zero_uuid[16] = { 0 };
  if (args.settings.root <= 0 || !memcmp (args.settings.uuid, zero_uuid, sizeof zero_uuid))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  for (guint i = 0; i < G_N_ELEMENTS (values); i++)
    if (!isfinite (values[i]) || values[i] < 0 || values[i] > 1)
      return GLIMS_STATUS_INVALID_ARGUMENT;
  return glims_facade_call (engine, GLIMS_FACADE_OP_image_fill_lab_layer_srgb,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    image_fill_lab_layer_srgb_on_engine, &args, error);
}

typedef struct {
  GlimsImageID image;
  GlimsResourceID brush;
  GlimsLabLayerBrushSettings settings;
  const GlimsStrokePacketV2 *packet;
  GlimsStrokeID stroke;
  char **error;
} LabLayerStrokeArgs;

static GlimsStatus
stroke_begin_lab_layer_on_engine (GlimsEngine *engine, gpointer data)
{
  LabLayerStrokeArgs *args = data;
  return glims_stroke_begin_lab_layer (engine, args->image, args->brush,
                                      &args->settings, args->packet, &args->stroke, args->error);
}

static GlimsStatus
api_stroke_begin_lab_layer (GlimsEngine *engine, GlimsImageID image, GlimsResourceID brush,
                            const GlimsLabLayerBrushSettings *settings,
                            const GlimsStrokePacketV2 *packet, GlimsStrokeID *out, char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  if (!out || !settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  uint32_t size;
  memcpy (&size, settings, sizeof size);
  if (size < sizeof *settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  LabLayerStrokeArgs args = { .image = image, .brush = brush, .packet = packet, .error = error };
  memcpy (&args.settings, settings, sizeof args.settings);
  GlimsStatus status = glims_facade_call (engine, GLIMS_FACADE_OP_stroke_begin_lab_layer,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_IMAGE, image, { 0, 0 } },
    stroke_begin_lab_layer_on_engine, &args, error);
  if (status == GLIMS_STATUS_OK) *out = args.stroke;
  return status;
}

static GlimsStatus
stroke_cancel_lab_layer_on_engine (GlimsEngine *engine, gpointer data)
{
  return glims_stroke_cancel_lab_layer (engine, *(GlimsStrokeID *) data);
}

static GlimsStatus
api_stroke_cancel_lab_layer (GlimsEngine *engine, GlimsStrokeID stroke)
{
  return glims_facade_call (engine, GLIMS_FACADE_OP_stroke_cancel_lab_layer,
    (GlimsFacadeTarget) { GLIMS_FACADE_TARGET_STROKE, stroke, { 0, 0 } },
    stroke_cancel_lab_layer_on_engine, &stroke, NULL);
}

static const GlimsEngineAPI api_v1 = {
  .api_version = GLIMS_ENGINE_API_VERSION,
  .struct_size = sizeof (GlimsEngineAPI),
#define GLIMS_FACADE(name, wrapper, target, policy) .name = wrapper,
#include "facade-operations.def"
#undef GLIMS_FACADE
};

__attribute__ ((visibility ("default")))
const GlimsEngineAPI *
glims_engine_get_api (uint32_t api_version)
{
  if (api_version != GLIMS_ENGINE_API_VERSION)
    return NULL;

  return &api_v1;
}

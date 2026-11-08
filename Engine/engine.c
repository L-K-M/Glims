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

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

#include "libgimpbase/gimpbase-private.h"

#include "config/gimprc.h"

#include "gegl/gimp-gegl.h"

#include "core/gimp.h"
#include "core/gimp-user-install.h"
#include "core/gimpgrid.h"
#include "core/gimpimage.h"
#include "core/gimpprojection.h"

#include "paint/gimppaintcore.h"
#include "plug-in/gimpplugin.h"
#include "plug-in/gimppluginmanager.h"
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
} GlimsCall;

static gboolean
call_dispatch (gpointer user_data)
{
  GlimsCall *call = user_data;
  /* A dispatch at main depth > 1 means the engine thread sits inside a
   * nested main loop — a plug-in call or another long operation that
   * iterates the context, such as a link layer reloading its changed
   * file. Not every native path raises `busy` itself (the link monitor's
   * reload runs with no facade call around it), so raise it for this
   * call's duration: mutation gates refuse while reads and cancellation
   * remain deliverable. This does not discard or block RPC dispatch. */
  gboolean   nested = g_main_depth () > 1;

  if (nested)
    call->engine->busy++;
  call->status = call->func (call->engine, call->data);
  if (nested)
    call->engine->busy--;

  g_mutex_lock (&call->engine->lock);
  call->done = TRUE;
  g_cond_broadcast (&call->engine->cond);
  g_mutex_unlock (&call->engine->lock);

  return G_SOURCE_REMOVE;
}

GlimsStatus
glims_engine_call (GlimsEngine     *engine,
                   GlimsEngineFunc  func,
                   gpointer         data)
{
  GlimsCall call = { engine, func, data, GLIMS_STATUS_FAILED, FALSE };

  if (! engine || ! engine->gimp)
    return GLIMS_STATUS_NOT_RUNNING;

  /* Already on the engine thread (an event callback that calls back in, or
   * a call made while a nested loop runs): run directly. */
  if (g_thread_self () == engine->thread)
    return func (engine, data);

  g_main_context_invoke_full (NULL, G_PRIORITY_DEFAULT, call_dispatch, &call, NULL);

  g_mutex_lock (&engine->lock);
  while (! call.done)
    g_cond_wait (&engine->cond, &engine->lock);
  g_mutex_unlock (&engine->lock);

  return call.status;
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

static void
init_status_noop (const gchar *text1,
                  const gchar *text2,
                  gdouble      percentage)
{
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

static gboolean
engine_initialize (GlimsEngine  *engine,
                   GError      **error)
{
  Gimp        *gimp;
  GFile       *gimpdir;
  const gchar *abort_message;
  const gchar *current_language;
  gchar       *prev_language = NULL;
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
      GimpUserInstall *install = gimp_user_install_new (G_OBJECT (gimp), FALSE);

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
  g_free (contents);

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
      return FALSE;
    }

  gimp_gegl_init (gimp);

  current_language = language_init (NULL, NULL);

  gimp_initialize (gimp, init_status_noop);

  g_object_get (gimp->edit_config, "prev-language", &prev_language, NULL);
  gimp->query_all = (prev_language == NULL ||
                     g_strcmp0 (prev_language, current_language) != 0);
  g_free (prev_language);

  gimp_restore (gimp, init_status_noop, &font_error);
  if (font_error)
    {
      show_message (gimp, NULL, GIMP_MESSAGE_WARNING, NULL, font_error->message);
      g_clear_error (&font_error);
    }

  gimp_rc_set_autosave (GIMP_RC (gimp->edit_config), TRUE);

  g_object_set (gimp->edit_config,
                "config-version", GIMP_VERSION,
                "prev-language",  current_language,
                NULL);

  gimp->initialized = TRUE;

  return check_engine_interface (gimp, error);
}

static void
engine_shutdown (GlimsEngine *engine)
{
  Gimp *gimp = engine->gimp;

  g_hash_table_remove_all (engine->filters);
  g_hash_table_remove_all (engine->strokes);
  g_hash_table_remove_all (engine->images);

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
quit_loop (GlimsEngine *engine,
           gpointer     data)
{
  GimpPlugInManager *manager = engine->gimp->plug_in_manager;

  /* A running plug-in (a dialog left open) holds the engine thread in a
   * nested loop, so the main loop would not end until the user closed it.
   * Close every plug-in first, as gimp_plug_in_manager_exit() does on
   * GIMP's own exit; that ends their loops and the call that waits. */
  while (manager->open_plug_ins)
    gimp_plug_in_close (manager->open_plug_ins->data, TRUE);

  g_main_loop_quit (engine->loop);

  return GLIMS_STATUS_OK;
}

static void
api_stop (GlimsEngine *engine)
{
  if (! engine)
    return;

  glims_engine_call (engine, quit_loop, NULL);
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
MARSHAL (text_layer_get, return glims_text_layer_get (e, a->image, a->item, a->out, a->in_out);)
MARSHAL (text_layer_set, return glims_text_layer_set (e, a->image, a->item, a->string, a->in,
                                                      a->error);)
MARSHAL (layer_transform_matrix, return glims_layer_transform_matrix (e, a->image, a->item, a->in,
                                                                      (uint32_t) a->width, a->error);)
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

static GlimsStatus
resource_thumbnail_on_engine (GlimsEngine *e, gpointer data)
{
  GlimsResourceArgs *a = data;

  return glims_resource_thumbnail (e, a->id, a->max_size, a->foreground, a->background,
                                   a->pixels, a->error);
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
  return glims_engine_call (e, image_new_on_engine, &a);
}

static GlimsStatus
api_image_open (GlimsEngine *e, const char *path, GlimsImageID *image, char **error)
{
  GlimsArgs a = { .string = path, .out = image, .error = error };
  return glims_engine_call (e, image_open_on_engine, &a);
}

static GlimsStatus
api_image_close (GlimsEngine *e, GlimsImageID image)
{
  GlimsArgs a = { .image = image };
  return glims_engine_call (e, image_close_on_engine, &a);
}

static GlimsStatus
api_image_info (GlimsEngine *e, GlimsImageID image, GlimsImageInfo *info)
{
  GlimsArgs a = { .image = image, .out = info };
  return glims_engine_call (e, image_info_on_engine, &a);
}

static GlimsStatus
api_image_render (GlimsEngine *e, GlimsImageID image, double scale, GlimsRect area,
                  uint8_t *pixels, size_t stride)
{
  GlimsArgs a = { .image = image, .number = scale, .area = area, .pixels = pixels, .stride = stride };
  return glims_engine_call (e, image_render_on_engine, &a);
}

static GlimsStatus
api_image_save (GlimsEngine *e, GlimsImageID image, const char *path, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .error = error };
  return glims_engine_call (e, image_save_on_engine, &a);
}

static GlimsStatus
api_image_save_copy (GlimsEngine *e, GlimsImageID image, const char *path, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .error = error };
  return glims_engine_call (e, image_save_copy_on_engine, &a);
}

static GlimsStatus
api_image_export (GlimsEngine *e, GlimsImageID image, const char *path, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .error = error };
  return glims_engine_call (e, image_export_on_engine, &a);
}

static GlimsStatus
api_image_layers (GlimsEngine *e, GlimsImageID image, GlimsLayerInfo *layers,
                  int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = layers, .capacity = capacity, .count = count };
  return glims_engine_call (e, image_layers_on_engine, &a);
}

static GlimsStatus
api_image_undo_info (GlimsEngine *e, GlimsImageID image, GlimsUndoInfo *info)
{
  GlimsArgs a = { .image = image, .out = info };
  return glims_engine_call (e, image_undo_info_on_engine, &a);
}

static GlimsStatus
api_image_undo (GlimsEngine *e, GlimsImageID image)
{
  GlimsArgs a = { .image = image };
  return glims_engine_call (e, image_undo_on_engine, &a);
}

static GlimsStatus
api_image_redo (GlimsEngine *e, GlimsImageID image)
{
  GlimsArgs a = { .image = image };
  return glims_engine_call (e, image_redo_on_engine, &a);
}

static GlimsStatus
api_stroke_begin (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                  const GlimsBrushSettings *brush, const GlimsStrokePoint *first,
                  GlimsStrokeID *stroke, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in = brush, .in2 = first,
                  .out = stroke, .error = error };
  return glims_engine_call (e, stroke_begin_on_engine, &a);
}

static GlimsStatus
api_stroke_continue (GlimsEngine *e, GlimsStrokeID stroke, const GlimsStrokePoint *points, size_t count)
{
  GlimsArgs a = { .item = stroke, .in = points, .n = count };
  return glims_engine_call (e, stroke_continue_on_engine, &a);
}

static GlimsStatus
api_stroke_end (GlimsEngine *e, GlimsStrokeID stroke)
{
  GlimsArgs a = { .item = stroke };
  return glims_engine_call (e, stroke_end_on_engine, &a);
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
  return glims_engine_call (e, stroke_begin_with_brush_resource_on_engine, &a);
}

static GlimsStatus
api_filter_begin (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                  const char *operation, GlimsFilterID *filter, char **error)
{
  GlimsArgs a = { .image = image, .item = drawable, .string = operation, .out = filter, .error = error };
  return glims_engine_call (e, filter_begin_on_engine, &a);
}

static GlimsStatus
api_filter_set_double (GlimsEngine *e, GlimsFilterID filter, const char *property, double value)
{
  GlimsArgs a = { .item = filter, .string = property, .number = value };
  return glims_engine_call (e, filter_set_double_on_engine, &a);
}

static GlimsStatus
api_filter_commit (GlimsEngine *e, GlimsFilterID filter, char **error)
{
  GlimsArgs a = { .item = filter, .error = error };
  return glims_engine_call (e, filter_commit_on_engine, &a);
}

static GlimsStatus
api_filter_abort (GlimsEngine *e, GlimsFilterID filter)
{
  GlimsArgs a = { .item = filter };
  return glims_engine_call (e, filter_abort_on_engine, &a);
}

static GlimsStatus
api_procedures (GlimsEngine *e, GlimsImageID image, GlimsProcedureInfo *procedures,
                int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = procedures, .capacity = capacity, .count = count };
  return glims_engine_call (e, procedures_on_engine, &a);
}

static GlimsStatus
api_procedure_run (GlimsEngine *e, GlimsImageID image, const char *name, uint32_t run_mode,
                   char **error)
{
  GlimsArgs a = { .image = image, .string = name, .width = (int32_t) run_mode, .error = error };
  return glims_engine_call (e, procedure_run_on_engine, &a);
}

static GlimsStatus
api_procedure_cancel (GlimsEngine *e)
{
  return glims_engine_call (e, procedure_cancel_on_engine, NULL);
}

static GlimsStatus
api_select_shape (GlimsEngine *e, GlimsImageID image, uint32_t shape, const GlimsPoint *points,
                  size_t count, const GlimsSelectOptions *options)
{
  GlimsArgs a = { .image = image, .width = (int32_t) shape, .in = points, .n = count, .in2 = options };
  return glims_engine_call (e, select_shape_on_engine, &a);
}

static GlimsStatus
api_select_color (GlimsEngine *e, GlimsImageID image, GlimsPoint point,
                  const GlimsSelectOptions *options, char **error)
{
  GlimsArgs a = { .image = image, .in = &point, .in2 = options, .error = error };
  return glims_engine_call (e, select_color_on_engine, &a);
}

static GlimsStatus
api_select_command (GlimsEngine *e, GlimsImageID image, uint32_t command, double radius, char **error)
{
  GlimsArgs a = { .image = image, .width = (int32_t) command, .number = radius, .error = error };
  return glims_engine_call (e, select_command_on_engine, &a);
}

static GlimsStatus
api_selection_bounds (GlimsEngine *e, GlimsImageID image, bool *empty, GlimsRect *bounds)
{
  GlimsArgs a = { .image = image, .out = empty, .in_out = bounds };
  return glims_engine_call (e, selection_bounds_on_engine, &a);
}

static GlimsStatus
api_selection_outline (GlimsEngine *e, GlimsImageID image, GlimsSegment *segments,
                       int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = segments, .capacity = capacity, .count = count };
  return glims_engine_call (e, selection_outline_on_engine, &a);
}

static GlimsStatus
api_fill (GlimsEngine *e, GlimsImageID image, GlimsPoint point, const GlimsFillSettings *settings,
          char **error)
{
  GlimsArgs a = { .image = image, .in = &point, .in2 = settings, .error = error };
  return glims_engine_call (e, fill_on_engine, &a);
}

static GlimsStatus
api_fill_pattern (GlimsEngine *e, GlimsImageID image, GlimsResourceID pattern, GlimsPoint seed,
                  const GlimsPatternFillSettings *settings, char **error)
{
  GlimsArgs a = { .image = image, .resource = pattern, .in = &seed, .in2 = settings, .error = error };
  return glims_engine_call (e, fill_pattern_on_engine, &a);
}

static GlimsStatus
api_gradient (GlimsEngine *e, GlimsImageID image, GlimsPoint from, GlimsPoint to,
              const GlimsGradientSettings *settings, char **error)
{
  GlimsPoint points[2] = { from, to };
  GlimsArgs  a = { .image = image, .in = points, .in2 = settings, .error = error };
  return glims_engine_call (e, gradient_on_engine, &a);
}

static GlimsStatus
api_layer_select (GlimsEngine *e, GlimsImageID image, GlimsItemID layer)
{
  GlimsArgs a = { .image = image, .item = layer };
  return glims_engine_call (e, layer_select_on_engine, &a);
}

static GlimsStatus
api_layer_command (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t command,
                   GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) command, .out = result, .error = error };
  return glims_engine_call (e, layer_command_on_engine, &a);
}

static GlimsStatus
api_layer_change (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, const GlimsLayerChange *change,
                  char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in = change, .error = error };
  return glims_engine_call (e, layer_change_on_engine, &a);
}

static GlimsStatus
api_layer_move (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, double dx, double dy)
{
  GlimsArgs a = { .image = image, .item = layer, .number = dx, .number2 = dy };
  return glims_engine_call (e, layer_move_on_engine, &a);
}

static GlimsStatus
api_image_crop (GlimsEngine *e, GlimsImageID image, GlimsRect rect, char **error)
{
  GlimsArgs a = { .image = image, .area = rect, .error = error };
  return glims_engine_call (e, image_crop_on_engine, &a);
}

static GlimsStatus
api_image_transform (GlimsEngine *e, GlimsImageID image, uint32_t transform)
{
  GlimsArgs a = { .image = image, .width = (int32_t) transform };
  return glims_engine_call (e, image_transform_on_engine, &a);
}

static GlimsStatus
api_layer_transform (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t transform)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) transform };
  return glims_engine_call (e, layer_transform_on_engine, &a);
}

static GlimsStatus
api_image_scale (GlimsEngine *e, GlimsImageID image, int32_t width, int32_t height, char **error)
{
  GlimsArgs a = { .image = image, .width = width, .height = height, .error = error };
  return glims_engine_call (e, image_scale_on_engine, &a);
}

static GlimsStatus
api_image_resize_canvas (GlimsEngine *e, GlimsImageID image, int32_t width, int32_t height,
                         int32_t offset_x, int32_t offset_y, const GlimsColor *fill, char **error)
{
  GlimsArgs a = { .image = image, .area = { offset_x, offset_y, width, height }, .in = fill, .error = error };
  return glims_engine_call (e, image_resize_canvas_on_engine, &a);
}

static GlimsStatus
api_layer_transform_matrix (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                            const GlimsMatrix *matrix, uint32_t interpolation, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in = matrix, .width = (int32_t) interpolation,
                  .error = error };
  return glims_engine_call (e, layer_transform_matrix_on_engine, &a);
}

static GlimsStatus
api_fonts (GlimsEngine *e, char **names)
{
  GlimsArgs a = { .out = names };
  return glims_engine_call (e, fonts_on_engine, &a);
}

static GlimsStatus
api_text_layer_new (GlimsEngine *e, GlimsImageID image, const char *text,
                    const GlimsTextSettings *settings, GlimsPoint position,
                    GlimsItemID *layer, char **error)
{
  GlimsArgs a = { .image = image, .string = text, .in = settings, .number = position.x,
                  .number2 = position.y, .out = layer, .error = error };
  return glims_engine_call (e, text_layer_new_on_engine, &a);
}

static GlimsStatus
api_text_layer_get (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, char **text,
                    GlimsTextSettings *settings)
{
  GlimsArgs a = { .image = image, .item = layer, .out = text, .in_out = settings };
  return glims_engine_call (e, text_layer_get_on_engine, &a);
}

static GlimsStatus
api_text_layer_set (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, const char *text,
                    const GlimsTextSettings *settings, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .string = text, .in = settings, .error = error };
  return glims_engine_call (e, text_layer_set_on_engine, &a);
}

static GlimsStatus
api_paths (GlimsEngine *e, GlimsImageID image, GlimsPathInfo *rows, int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = rows, .capacity = capacity, .count = count };
  return glims_engine_call (e, paths_on_engine, &a);
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
  return glims_engine_call (e, path_get_on_engine, &a);
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
  return glims_engine_call (e, path_set_on_engine, &a);
}

static GlimsStatus
api_path_change (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                 const GlimsPathChange *change, char **error)
{
  GlimsArgs a = { .image = image, .item = path, .in = change, .error = error };
  return glims_engine_call (e, path_change_on_engine, &a);
}

static GlimsStatus
api_path_delete (GlimsEngine *e, GlimsImageID image, GlimsItemID path)
{
  GlimsArgs a = { .image = image, .item = path };
  return glims_engine_call (e, path_delete_on_engine, &a);
}

static GlimsStatus
api_path_to_selection (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                       const GlimsSelectOptions *options)
{
  GlimsArgs a = { .image = image, .item = path, .in = options };
  return glims_engine_call (e, path_to_selection_on_engine, &a);
}

static GlimsStatus
api_path_stroke (GlimsEngine *e, GlimsImageID image, GlimsItemID path, GlimsItemID layer,
                 const GlimsLineSettings *settings, char **error)
{
  GlimsArgs a = { .image = image, .item = path, .width = layer, .in = settings, .error = error };
  return glims_engine_call (e, path_stroke_on_engine, &a);
}

MARSHAL (image_copy_pixels, return glims_image_copy_pixels (e, a->image, a->width, a->out, a->error);)
MARSHAL (image_clear, return glims_image_clear (e, a->image, a->in, a->error);)
MARSHAL (image_paste_pixels, return glims_image_paste_pixels (e, a->image, a->area, a->in, a->n, a->out, a->error);)
MARSHAL (image_from_pixels, return glims_image_from_pixels (e, a->width, a->height, a->in, a->n, a->out, a->error);)

static GlimsStatus
api_image_copy_pixels (GlimsEngine *e, GlimsImageID image, bool merged, GlimsPixelBuffer *out, char **error)
{
  GlimsArgs a = { .image = image, .width = merged, .out = out, .error = error };
  return glims_engine_call (e, image_copy_pixels_on_engine, &a);
}

static GlimsStatus
api_image_clear (GlimsEngine *e, GlimsImageID image, const GlimsColor *background, char **error)
{
  GlimsArgs a = { .image = image, .in = background, .error = error };
  return glims_engine_call (e, image_clear_on_engine, &a);
}

static GlimsStatus
api_image_paste_pixels (GlimsEngine *e, GlimsImageID image, GlimsRect bounds, const uint8_t *pixels,
                        size_t count, GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .area = bounds, .in = pixels, .n = count, .out = result, .error = error };
  return glims_engine_call (e, image_paste_pixels_on_engine, &a);
}

static void api_free_pixels (uint8_t *pixels) { g_free (pixels); }

static GlimsStatus
api_image_from_pixels (GlimsEngine *e, int32_t width, int32_t height, const uint8_t *pixels,
                       size_t count, GlimsImageID *result, char **error)
{
  GlimsArgs a = { .width = width, .height = height, .in = pixels, .n = count, .out = result, .error = error };
  return glims_engine_call (e, image_from_pixels_on_engine, &a);
}

static GlimsStatus
api_layer_state (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, GlimsLayerState *state)
{
  GlimsArgs a = { .image = image, .item = layer, .out = state };
  return glims_engine_call (e, layer_state_on_engine, &a);
}

static GlimsStatus
api_create_group (GlimsEngine *e, GlimsImageID image, GlimsItemID parent, int32_t index,
                  const char *name, GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .item = parent, .width = index, .string = name, .out = result,
                  .error = error };
  return glims_engine_call (e, create_group_on_engine, &a);
}

static GlimsStatus
api_reparent_layer (GlimsEngine *e, GlimsImageID image, GlimsItemID item, GlimsItemID new_parent,
                    int32_t index, char **error)
{
  GlimsArgs a = { .image = image, .item = item, .width = new_parent, .height = index, .error = error };
  return glims_engine_call (e, reparent_layer_on_engine, &a);
}

static GlimsStatus
api_set_layer_locks (GlimsEngine *e, GlimsImageID image, GlimsItemID item, uint32_t mask,
                     uint32_t values, char **error)
{
  GlimsArgs a = { .image = image, .item = item, .width = (int32_t) mask, .height = (int32_t) values,
                  .error = error };
  return glims_engine_call (e, set_layer_locks_on_engine, &a);
}

static GlimsStatus
api_filter_operations (GlimsEngine *e, GlimsOperationInfo *rows, int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .out = rows, .capacity = capacity, .count = count };
  return glims_engine_call (e, filter_operations_on_engine, &a);
}

static GlimsStatus
api_filter_operation_properties (GlimsEngine *e, const char *operation, GlimsFilterProperty *rows,
                                 int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .string = operation, .out = rows, .capacity = capacity, .count = count };
  return glims_engine_call (e, filter_operation_properties_on_engine, &a);
}

static GlimsStatus
api_filter_enum_choices (GlimsEngine *e, const char *operation, const char *property,
                         GlimsFilterEnumChoice *rows, int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .string = operation, .in = property, .out = rows, .capacity = capacity,
                  .count = count };
  return glims_engine_call (e, filter_enum_choices_on_engine, &a);
}

static GlimsStatus
api_filter_get_property (GlimsEngine *e, GlimsFilterID filter, const char *property,
                         GlimsFilterValue *value)
{
  GlimsArgs a = { .item = filter, .string = property, .out = value };
  return glims_engine_call (e, filter_get_property_on_engine, &a);
}

static GlimsStatus
api_filter_set_property (GlimsEngine *e, GlimsFilterID filter, const char *property,
                         const GlimsFilterValue *value)
{
  GlimsArgs a = { .item = filter, .string = property, .in = value };
  return glims_engine_call (e, filter_set_property_on_engine, &a);
}

static GlimsStatus
api_image_history (GlimsEngine *e, GlimsImageID image, GlimsHistoryRow *rows,
                    int32_t capacity, GlimsHistoryInfo *info)
{
  GlimsArgs a = { .image = image, .out = rows, .capacity = capacity, .in_out = info };
  return glims_engine_call (e, image_history_on_engine, &a);
}

static GlimsStatus
api_image_history_move (GlimsEngine *e, GlimsImageID image, uint64_t revision,
                         int32_t position, char **error)
{
  GlimsArgs a = { .image = image, .revision = revision, .width = position, .error = error };
  return glims_engine_call (e, image_history_move_on_engine, &a);
}

static GlimsStatus
api_image_duplicate (GlimsEngine *e, GlimsImageID image, GlimsImageID *result, char **error)
{
  GlimsArgs a = { .image = image, .out = result, .error = error };
  return glims_engine_call (e, image_duplicate_on_engine, &a);
}

static GlimsStatus
api_layer_mask (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, GlimsMaskState *state)
{
  GlimsArgs a = { .image = image, .item = layer, .out = state };
  return glims_engine_call (e, layer_mask_on_engine, &a);
}

static GlimsStatus
api_layer_mask_add (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t source,
                    bool edit, GlimsItemID *mask, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) source, .height = edit,
                  .out = mask, .error = error };
  return glims_engine_call (e, layer_mask_add_on_engine, &a);
}

static GlimsStatus
api_layer_mask_set (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t flags,
                    uint32_t values, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) flags, .height = (int32_t) values,
                  .error = error };
  return glims_engine_call (e, layer_mask_set_on_engine, &a);
}

static GlimsStatus
api_layer_mask_apply (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t mode,
                      char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) mode, .error = error };
  return glims_engine_call (e, layer_mask_apply_on_engine, &a);
}

static GlimsStatus
api_layer_mask_to_selection (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                             uint32_t operation, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .width = (int32_t) operation, .error = error };
  return glims_engine_call (e, layer_mask_to_selection_on_engine, &a);
}

static GlimsStatus
api_drawable_thumbnail (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable, int32_t max_size,
                        uint8_t *pixels, size_t byte_count, int32_t *width, int32_t *height)
{
  GlimsArgs a = { .image = image, .item = drawable, .width = max_size, .pixels = pixels,
                  .n = byte_count, .count = width, .in_out = height };
  return glims_engine_call (e, drawable_thumbnail_on_engine, &a);
}

static GlimsStatus
api_image_components (GlimsEngine *e, GlimsImageID image, GlimsComponentState *state)
{
  GlimsArgs a = { .image = image, .out = state };
  return glims_engine_call (e, image_components_on_engine, &a);
}

static GlimsStatus
api_image_set_components (GlimsEngine *e, GlimsImageID image, uint32_t active_mask,
                          uint32_t active_values, uint32_t visible_mask, uint32_t visible_values,
                          char **error)
{
  const uint32_t masks[4] = { active_mask, active_values, visible_mask, visible_values };
  GlimsArgs a = { .image = image, .in = masks, .error = error };
  return glims_engine_call (e, image_set_components_on_engine, &a);
}

static GlimsStatus
api_image_channels (GlimsEngine *e, GlimsImageID image, GlimsChannelInfo *channels,
                    int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = channels, .capacity = capacity, .count = count };
  return glims_engine_call (e, image_channels_on_engine, &a);
}

static GlimsStatus
api_channel_from_selection (GlimsEngine *e, GlimsImageID image, const char *name,
                            GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .string = name, .out = result, .error = error };
  return glims_engine_call (e, channel_from_selection_on_engine, &a);
}

static GlimsStatus
api_channel_change (GlimsEngine *e, GlimsImageID image, GlimsItemID channel,
                    const GlimsChannelChange *change, char **error)
{
  GlimsArgs a = { .image = image, .item = channel, .in = change, .error = error };
  return glims_engine_call (e, channel_change_on_engine, &a);
}

static GlimsStatus
api_channel_command (GlimsEngine *e, GlimsImageID image, GlimsItemID channel, uint32_t command,
                     GlimsItemID *result, char **error)
{
  GlimsArgs a = { .image = image, .item = channel, .width = (int32_t) command, .out = result,
                  .error = error };
  return glims_engine_call (e, channel_command_on_engine, &a);
}

static GlimsStatus
api_channel_to_selection (GlimsEngine *e, GlimsImageID image, GlimsItemID channel,
                          uint32_t operation, char **error)
{
  GlimsArgs a = { .image = image, .item = channel, .width = (int32_t) operation, .error = error };
  return glims_engine_call (e, channel_to_selection_on_engine, &a);
}

static GlimsStatus
api_image_quick_mask (GlimsEngine *e, GlimsImageID image, GlimsQuickMaskState *state)
{
  GlimsArgs a = { .image = image, .out = state };
  return glims_engine_call (e, image_quick_mask_on_engine, &a);
}

static GlimsStatus
api_image_set_quick_mask (GlimsEngine *e, GlimsImageID image, bool enabled, char **error)
{
  GlimsArgs a = { .image = image, .width = enabled, .error = error };
  return glims_engine_call (e, image_set_quick_mask_on_engine, &a);
}

static GlimsStatus
api_drawable_effects (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                      GlimsEffectInfo *rows, int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .item = drawable, .out = rows,
                  .capacity = capacity, .count = count };
  return glims_engine_call (e, drawable_effects_on_engine, &a);
}

static GlimsStatus
api_effect_change (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                   GlimsEffectID effect, const GlimsEffectChange *change, char **error)
{
  GlimsArgs a = { .image = image, .item = drawable, .effect = effect,
                  .in = change, .error = error };
  return glims_engine_call (e, effect_change_on_engine, &a);
}

static GlimsStatus
api_effect_command (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                    GlimsEffectID effect, uint32_t command, char **error)
{
  GlimsArgs a = { .image = image, .item = drawable, .effect = effect,
                  .width = (int32_t) command, .error = error };
  return glims_engine_call (e, effect_command_on_engine, &a);
}

static GlimsStatus
api_image_open_layers (GlimsEngine *e, GlimsImageID image, const char *path,
                       GlimsItemID *layers, int32_t capacity, int32_t *count, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .out = layers,
                  .capacity = capacity, .count = count, .error = error };
  return glims_engine_call (e, image_open_layers_on_engine, &a);
}

static GlimsStatus
api_image_place_link (GlimsEngine *e, GlimsImageID image, const char *path,
                      GlimsItemID *layer, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .out = layer, .error = error };
  return glims_engine_call (e, image_place_link_on_engine, &a);
}

static GlimsStatus
api_filter_edit_begin (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                       GlimsEffectID effect, GlimsFilterID *filter, char **error)
{
  GlimsArgs a = { .image = image, .item = drawable, .effect = effect,
                  .out = filter, .error = error };
  return glims_engine_call (e, filter_edit_begin_on_engine, &a);
}

static GlimsStatus
api_image_color_info (GlimsEngine *e, GlimsImageID image, GlimsColorInfo *info)
{
  GlimsArgs a = { .image = image, .out = info };
  return glims_engine_call (e, image_color_info_on_engine, &a);
}

static GlimsStatus
api_image_convert_mode (GlimsEngine *e, GlimsImageID image, uint32_t mode, char **error)
{
  GlimsArgs a = { .image = image, .width = (int32_t) mode, .error = error };
  return glims_engine_call (e, image_convert_mode_on_engine, &a);
}

static GlimsStatus
api_image_convert_precision (GlimsEngine *e, GlimsImageID image, uint32_t component,
                             uint32_t trc, char **error)
{
  GlimsArgs a = { .image = image, .width = (int32_t) component, .height = (int32_t) trc,
                  .error = error };
  return glims_engine_call (e, image_convert_precision_on_engine, &a);
}

static GlimsStatus
api_path_fill (GlimsEngine *e, GlimsImageID image, GlimsItemID path, GlimsItemID drawable,
               const GlimsPathFillSettings *settings, char **error)
{
  GlimsArgs a = { .image = image, .item = path, .width = drawable, .in = settings, .error = error };
  return glims_engine_call (e, path_fill_on_engine, &a);
}

static GlimsStatus
api_path_to_vector_layer (GlimsEngine *e, GlimsImageID image, GlimsItemID path, const char *name,
                          GlimsItemID *layer, char **error)
{
  GlimsArgs a = { .image = image, .item = path, .string = name, .out = layer, .error = error };
  return glims_engine_call (e, path_to_vector_layer_on_engine, &a);
}

static GlimsStatus
api_image_assign_profile (GlimsEngine *e, GlimsImageID image, const char *path, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .error = error };
  return glims_engine_call (e, image_assign_profile_on_engine, &a);
}

static GlimsStatus
api_image_convert_profile (GlimsEngine *e, GlimsImageID image, const char *path,
                           uint32_t intent, bool black_point_compensation, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .width = (int32_t) intent,
                  .height = black_point_compensation, .error = error };
  return glims_engine_call (e, image_convert_profile_on_engine, &a);
}

static GlimsStatus
api_image_convert_profile_rasterizing (GlimsEngine *e, GlimsImageID image, const char *path,
                                       uint32_t intent, bool black_point_compensation, char **error)
{
  GlimsArgs a = { .image = image, .string = path, .width = (int32_t) intent,
                  .height = black_point_compensation, .error = error };
  return glims_engine_call (e, image_convert_profile_rasterizing_on_engine, &a);
}

static GlimsStatus
api_resources (GlimsEngine *e, uint32_t kind, GlimsResourceInfo *rows, int32_t capacity,
               int32_t *count)
{
  GlimsArgs a = { .width = (int32_t) kind, .out = rows, .capacity = capacity, .count = count };
  return glims_engine_call (e, resources_on_engine, &a);
}

static GlimsStatus
api_resource_identifiers (GlimsEngine *e, GlimsResourceID id, char **name, char **collection,
                          bool *internal, char **error)
{
  GlimsResourceArgs a = { .id = id, .out_name = name, .out_collection = collection,
                          .out_internal = internal, .error = error };
  return glims_engine_call (e, resource_identifiers_on_engine, &a);
}

static GlimsStatus
api_resource_resolve (GlimsEngine *e, uint32_t kind, const char *name, const char *collection,
                      bool internal, GlimsResourceID *outID, char **error)
{
  GlimsResourceArgs a = { .kind = kind, .name = name, .collection = collection,
                          .internal = internal, .out_id = outID, .error = error };
  return glims_engine_call (e, resource_resolve_on_engine, &a);
}

static GlimsStatus
api_resource_thumbnail (GlimsEngine *e, GlimsResourceID id, int32_t max_size,
                        const GlimsColor *foreground, const GlimsColor *background,
                        GlimsPixelBuffer *out, char **error)
{
  GlimsResourceArgs a = { .id = id, .max_size = max_size, .foreground = foreground,
                          .background = background, .pixels = out, .error = error };
  return glims_engine_call (e, resource_thumbnail_on_engine, &a);
}

static GlimsStatus
api_vector_layer_style_get (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                            GlimsVectorStyle *style, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in_out = style, .error = error };
  return glims_engine_call (e, vector_layer_style_get_on_engine, &a);
}

static GlimsStatus
api_vector_layer_style_set (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                            const GlimsVectorStyleChange *change, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .in = change, .error = error };
  return glims_engine_call (e, vector_layer_style_set_on_engine, &a);
}

MARSHAL (image_guides, return glims_image_guides (e, a->image, a->out, a->capacity, a->count);)
MARSHAL (guide_put, return glims_guide_put (e, a->image, a->in, a->out, a->error);)
MARSHAL (guide_remove, return glims_guide_remove (e, a->image, a->width, a->error);)
MARSHAL (layer_source_info, return glims_layer_source_info (e, a->image, a->item, a->out, a->error);)
MARSHAL (image_convert_indexed, return glims_image_convert_indexed (e, a->image, a->in,
                                                                    a->in2, a->capacity, a->error);)
MARSHAL (image_grid, return glims_image_grid (e, a->image, a->out, a->error);)
MARSHAL (image_set_grid, return glims_image_set_grid (e, a->image, a->in, a->error);)

static GlimsStatus
api_image_guides (GlimsEngine *e, GlimsImageID image, GlimsGuideInfo *rows,
                  int32_t capacity, int32_t *count)
{
  GlimsArgs a = { .image = image, .out = rows, .capacity = capacity, .count = count };
  return glims_engine_call (e, image_guides_on_engine, &a);
}

static GlimsStatus
api_guide_put (GlimsEngine *e, GlimsImageID image, const GlimsGuideInfo *guide,
               GlimsGuideID *result, char **error)
{
  GlimsArgs a = { .image = image, .in = guide, .out = result, .error = error };
  return glims_engine_call (e, guide_put_on_engine, &a);
}

static GlimsStatus
api_guide_remove (GlimsEngine *e, GlimsImageID image, GlimsGuideID guide, char **error)
{
  GlimsArgs a = { .image = image, .width = guide, .error = error };
  return glims_engine_call (e, guide_remove_on_engine, &a);
}

static GlimsStatus
api_layer_source_info (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                       GlimsLayerSourceInfo *out, char **error)
{
  GlimsArgs a = { .image = image, .item = layer, .out = out, .error = error };
  return glims_engine_call (e, layer_source_info_on_engine, &a);
}

static GlimsStatus
api_image_convert_indexed (GlimsEngine *e, GlimsImageID image,
                           const GlimsIndexedSettings *settings,
                           const GlimsColor *colors, int32_t color_count, char **error)
{
  GlimsArgs a = { .image = image, .in = settings, .in2 = colors,
                  .capacity = color_count, .error = error };
  return glims_engine_call (e, image_convert_indexed_on_engine, &a);
}

static GlimsStatus
api_image_grid (GlimsEngine *e, GlimsImageID image, GlimsGrid *out, char **error)
{
  GlimsArgs a = { .image = image, .out = out, .error = error };
  return glims_engine_call (e, image_grid_on_engine, &a);
}

static GlimsStatus
api_image_set_grid (GlimsEngine *e, GlimsImageID image, const GlimsGrid *grid, char **error)
{
  GlimsArgs a = { .image = image, .in = grid, .error = error };
  return glims_engine_call (e, image_set_grid_on_engine, &a);
}

static GlimsStatus
api_gradient_resource (GlimsEngine *e, GlimsImageID image, GlimsResourceID gradient,
                       GlimsPoint from, GlimsPoint to,
                       const GlimsResourceGradientSettings *settings, char **error)
{
  GlimsGradientResourceArgs a = { .image = image, .gradient = gradient, .from = from, .to = to,
                                  .settings = settings, .error = error };
  return glims_engine_call (e, gradient_resource_on_engine, &a);
}

static const GlimsEngineAPI api_v1 = {
  .api_version       = GLIMS_ENGINE_API_VERSION,
  .struct_size       = sizeof (GlimsEngineAPI),
  .start             = api_start,
  .stop              = api_stop,
  .free_string       = api_free_string,
  .engine_version    = api_engine_version,
  .image_new         = api_image_new,
  .image_open        = api_image_open,
  .image_close       = api_image_close,
  .image_info        = api_image_info,
  .image_render      = api_image_render,
  .image_save        = api_image_save,
  .image_export      = api_image_export,
  .image_layers      = api_image_layers,
  .image_undo_info   = api_image_undo_info,
  .image_undo        = api_image_undo,
  .image_redo        = api_image_redo,
  .stroke_begin      = api_stroke_begin,
  .stroke_continue   = api_stroke_continue,
  .stroke_end        = api_stroke_end,
  .filter_begin      = api_filter_begin,
  .filter_set_double = api_filter_set_double,
  .filter_commit     = api_filter_commit,
  .filter_abort      = api_filter_abort,
  .procedures        = api_procedures,
  .procedure_run     = api_procedure_run,
  .procedure_cancel  = api_procedure_cancel,
  .select_shape      = api_select_shape,
  .select_color      = api_select_color,
  .select_command    = api_select_command,
  .selection_bounds  = api_selection_bounds,
  .selection_outline = api_selection_outline,
  .fill              = api_fill,
  .gradient          = api_gradient,
  .layer_select      = api_layer_select,
  .layer_command     = api_layer_command,
  .layer_change      = api_layer_change,
  .layer_move        = api_layer_move,
  .image_crop        = api_image_crop,
  .image_transform   = api_image_transform,
  .layer_transform   = api_layer_transform,
  .image_scale       = api_image_scale,
  .image_resize_canvas = api_image_resize_canvas,
  .layer_transform_matrix = api_layer_transform_matrix,
  .fonts             = api_fonts,
  .text_layer_new    = api_text_layer_new,
  .text_layer_get    = api_text_layer_get,
  .text_layer_set    = api_text_layer_set,
  .paths             = api_paths,
  .path_get          = api_path_get,
  .path_set          = api_path_set,
  .path_change       = api_path_change,
  .path_delete       = api_path_delete,
  .path_to_selection = api_path_to_selection,
  .path_stroke       = api_path_stroke,
  .image_copy_pixels = api_image_copy_pixels,
  .free_pixels       = api_free_pixels,
  .image_clear       = api_image_clear,
  .image_paste_pixels = api_image_paste_pixels,
  .image_save_copy    = api_image_save_copy,
  .image_from_pixels  = api_image_from_pixels,
  .layer_state       = api_layer_state,
  .create_group      = api_create_group,
  .reparent_layer    = api_reparent_layer,
  .set_layer_locks   = api_set_layer_locks,
  .filter_operations = api_filter_operations,
  .filter_operation_properties = api_filter_operation_properties,
  .filter_enum_choices = api_filter_enum_choices,
  .filter_get_property = api_filter_get_property,
  .filter_set_property = api_filter_set_property,
  .image_history = api_image_history,
  .image_history_move = api_image_history_move,
  .image_duplicate = api_image_duplicate,
  .layer_mask = api_layer_mask,
  .layer_mask_add = api_layer_mask_add,
  .layer_mask_set = api_layer_mask_set,
  .layer_mask_apply = api_layer_mask_apply,
  .layer_mask_to_selection = api_layer_mask_to_selection,
  .drawable_thumbnail = api_drawable_thumbnail,
  .image_components = api_image_components,
  .image_set_components = api_image_set_components,
  .image_channels = api_image_channels,
  .channel_from_selection = api_channel_from_selection,
  .channel_change = api_channel_change,
  .channel_command = api_channel_command,
  .channel_to_selection = api_channel_to_selection,
  .image_quick_mask = api_image_quick_mask,
  .image_set_quick_mask = api_image_set_quick_mask,
  .drawable_effects = api_drawable_effects,
  .effect_change = api_effect_change,
  .effect_command = api_effect_command,
  .image_open_layers = api_image_open_layers,
  .image_place_link = api_image_place_link,
  .filter_edit_begin = api_filter_edit_begin,
  .image_color_info = api_image_color_info,
  .image_convert_mode = api_image_convert_mode,
  .image_convert_precision = api_image_convert_precision,
  .path_fill = api_path_fill,
  .path_to_vector_layer = api_path_to_vector_layer,
  .resources = api_resources,
  .resource_identifiers = api_resource_identifiers,
  .resource_resolve = api_resource_resolve,
  .image_assign_profile = api_image_assign_profile,
  .image_convert_profile = api_image_convert_profile,
  .image_convert_profile_rasterizing = api_image_convert_profile_rasterizing,
  .resource_thumbnail = api_resource_thumbnail,
  .vector_layer_style_get = api_vector_layer_style_get,
  .vector_layer_style_set = api_vector_layer_style_set,
  .stroke_begin_with_brush_resource = api_stroke_begin_with_brush_resource,

  .fill_pattern = api_fill_pattern,


  .gradient_resource = api_gradient_resource,
  .image_guides    = api_image_guides,
  .guide_put       = api_guide_put,
  .guide_remove    = api_guide_remove,
  .layer_source_info = api_layer_source_info,
  .image_convert_indexed = api_image_convert_indexed,
  .image_grid        = api_image_grid,
  .image_set_grid    = api_image_set_grid,
};

__attribute__ ((visibility ("default")))
const GlimsEngineAPI *
glims_engine_get_api (uint32_t api_version)
{
  if (api_version != GLIMS_ENGINE_API_VERSION)
    return NULL;

  return &api_v1;
}

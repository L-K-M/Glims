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

#include <stdlib.h>
#include <string.h>

#include "libgimpbase/gimpbase-private.h"

#include "config/gimprc.h"

#include "gegl/gimp-gegl.h"

#include "core/gimp.h"
#include "core/gimp-user-install.h"
#include "core/gimpimage.h"

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

  call->status = call->func (call->engine, call->data);

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

static void
init_status_noop (const gchar *text1,
                  const gchar *text2,
                  gdouble      percentage)
{
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

  /* The engine's settings and caches live in Glims-owned directories; the
   * user's own GIMP settings and ~/.cache are never touched. GLib reads
   * these once, so they are set before anything asks for them. */
  g_setenv ("GIMP3_DIRECTORY", engine->user_directory, TRUE);
  g_setenv ("XDG_CACHE_HOME", engine->cache_directory, TRUE);
  if (! g_getenv ("GI_TYPELIB_PATH"))
    g_setenv ("GI_TYPELIB_PATH", GLIMS_ENGINE_TYPELIB_PATH, TRUE);

  /* Script plug-ins start with "#!/usr/bin/env <interpreter>", and those
   * interpreters live in the engine's bin directory. */
  {
    const gchar *path = g_getenv ("PATH");

    if (! path || ! strstr (path, GLIMS_ENGINE_BIN_PATH))
      {
        gchar *joined = g_strconcat (GLIMS_ENGINE_BIN_PATH, path ? ":" : "", path ? path : "", NULL);

        g_setenv ("PATH", joined, TRUE);
        g_free (joined);
      }
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
                   TRUE,                     /* no interface: Glims is the interface */
                   TRUE,                     /* use shared memory with plug-ins */
                   TRUE,                     /* use CPU acceleration */
                   FALSE,                    /* console messages: use the hook */
                   FALSE,                    /* show playground */
                   FALSE,                    /* show debug menu */
                   GIMP_STACK_TRACE_NEVER,
                   GIMP_PDB_COMPAT_ON);

  g_object_set_data (G_OBJECT (gimp), "glims-engine", engine);
  gimp->gui.show_message = show_message;

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

  return TRUE;
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
};

__attribute__ ((visibility ("default")))
const GlimsEngineAPI *
glims_engine_get_api (uint32_t api_version)
{
  if (api_version != GLIMS_ENGINE_API_VERSION)
    return NULL;

  return &api_v1;
}

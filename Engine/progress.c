/*
 * The adapter's progress object: what GIMP's display window is to the GTK
 * interface. The plug-in manager reports a running plug-in's progress
 * through it, and its Cancel request reaches the plug-in through it.
 *
 * It also gives plug-ins a parent window handle. On macOS, libgimpui only
 * keeps a plug-in's dialog in front of its host, and hides it when the host
 * is deactivated, when a handle exists (gimp_window_transient_on_mapped in
 * libgimp/gimpui.c); without one the dialog is an unrelated window. Quartz
 * cannot parent windows across processes, so the handle's bytes are never
 * read there; any non-empty handle works.
 */
#include "engine-private.h"

#include <unistd.h>

#include "core/gimpprogress.h"

/* Plug-ins report progress far more often than the interface can show it. */
#define EMIT_INTERVAL_US (50 * G_TIME_SPAN_MILLISECOND)

struct _GlimsProgress
{
  GObject      parent_instance;

  GlimsEngine *engine;
  gboolean     active;
  gdouble      value;
  gchar       *text;
  gint64       last_emit;
};

static void glims_progress_iface_init (GimpProgressInterface *iface);

G_DEFINE_TYPE_WITH_CODE (GlimsProgress, glims_progress, G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (GIMP_TYPE_PROGRESS,
                                                glims_progress_iface_init))

static void
glims_progress_finalize (GObject *object)
{
  GlimsProgress *progress = GLIMS_PROGRESS (object);

  g_free (progress->text);

  G_OBJECT_CLASS (glims_progress_parent_class)->finalize (object);
}

static void
glims_progress_class_init (GlimsProgressClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = glims_progress_finalize;
}

static void
glims_progress_init (GlimsProgress *progress)
{
}

static void
emit_progress (GlimsProgress *progress,
               gboolean       force)
{
  gint64 now = g_get_monotonic_time ();

  if (! force && now - progress->last_emit < EMIT_INTERVAL_US)
    return;

  progress->last_emit = now;
  glims_emit_progress (progress->engine, progress->active, progress->value, progress->text);
}

static GimpProgress *
glims_progress_start (GimpProgress *gimp_progress,
                      gboolean      cancellable,
                      const gchar  *message)
{
  GlimsProgress *progress = GLIMS_PROGRESS (gimp_progress);

  /* As GIMP's own progress widgets: one operation at a time; NULL tells
   * the caller it must not end the operation it did not start. */
  if (progress->active)
    return NULL;

  progress->active = TRUE;
  progress->value  = 0.0;
  g_free (progress->text);
  progress->text   = g_strdup (message);
  emit_progress (progress, TRUE);

  return gimp_progress;
}

static void
glims_progress_end (GimpProgress *gimp_progress)
{
  GlimsProgress *progress = GLIMS_PROGRESS (gimp_progress);

  if (! progress->active)
    return;

  progress->active = FALSE;
  progress->value  = 0.0;
  g_clear_pointer (&progress->text, g_free);
  emit_progress (progress, TRUE);
}

static gboolean
glims_progress_is_active (GimpProgress *gimp_progress)
{
  return GLIMS_PROGRESS (gimp_progress)->active;
}

static void
glims_progress_set_text (GimpProgress *gimp_progress,
                         const gchar  *message)
{
  GlimsProgress *progress = GLIMS_PROGRESS (gimp_progress);

  if (! progress->active)
    return;

  g_free (progress->text);
  progress->text = g_strdup (message);
  emit_progress (progress, TRUE);
}

static void
glims_progress_set_value (GimpProgress *gimp_progress,
                          gdouble       percentage)
{
  GlimsProgress *progress = GLIMS_PROGRESS (gimp_progress);

  if (! progress->active)
    return;

  progress->value = CLAMP (percentage, 0.0, 1.0);
  emit_progress (progress, progress->value >= 1.0);
}

static gdouble
glims_progress_get_value (GimpProgress *gimp_progress)
{
  GlimsProgress *progress = GLIMS_PROGRESS (gimp_progress);

  return progress->value < 0.0 ? 0.0 : progress->value;
}

static void
glims_progress_pulse (GimpProgress *gimp_progress)
{
  GlimsProgress *progress = GLIMS_PROGRESS (gimp_progress);

  if (! progress->active)
    return;

  progress->value = -1.0;
  emit_progress (progress, FALSE);
}

static GBytes *
glims_progress_get_window_id (GimpProgress *gimp_progress)
{
  pid_t pid = getpid ();

  return g_bytes_new (&pid, sizeof (pid));
}

static void
glims_progress_iface_init (GimpProgressInterface *iface)
{
  iface->start         = glims_progress_start;
  iface->end           = glims_progress_end;
  iface->is_active     = glims_progress_is_active;
  iface->set_text      = glims_progress_set_text;
  iface->set_value     = glims_progress_set_value;
  iface->get_value     = glims_progress_get_value;
  iface->pulse         = glims_progress_pulse;
#if GIMP_CHECK_VERSION (3, 3, 0)
  /* Renamed after 3.2 (upstream ed668b3e2d, "consistently name window handle"). */
  iface->get_window_handle = glims_progress_get_window_id;
#else
  iface->get_window_id = glims_progress_get_window_id;
#endif
  /* No message handler: plug-in messages reach the interface through
   * show_message() like every other engine message. */
}

GlimsProgress *
glims_progress_new (GlimsEngine *engine)
{
  GlimsProgress *progress = g_object_new (GLIMS_TYPE_PROGRESS, NULL);

  progress->engine = engine;

  return progress;
}

/* Test-only bounded NDJSON sink at the real paint boundary. No facade slots
 * or production diagnostics. Only a private paint.c has renamed call sites. */
#include "tablet-v2-ui-telemetry.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include <errno.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

enum { MAX_ROWS = 1024, MAX_BYTES = 1024 * 1024 };
static gint trace_fd = -1;
static guint rows;
static gsize written;
static gboolean failed;

static gboolean
write_all (const gchar *text, gsize length)
{
  while (length)
    {
      ssize_t n = write (trace_fd, text, length);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return FALSE;
      text += n; length -= (gsize) n;
    }
  return TRUE;
}

static void
record (const gchar *kind, GList *drawables, const GimpCoords *coords, guint32 time)
{
  if (failed) return;
  if (trace_fd < 0)
    {
      const gchar *path = g_getenv ("GLIMS_TABLET_V2_TELEMETRY");
      /* No tracing outside the explicit focused fixture. Do not create or
       * truncate paths; Swift owns a new 0600 regular file before painting. */
      if (!path) return;
      trace_fd = g_open (path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0);
      struct stat st;
      if (trace_fd < 0 || fstat (trace_fd, &st) || !S_ISREG (st.st_mode) ||
          st.st_nlink != 1 || (st.st_mode & 077) || st.st_size != 0)
        {
          if (trace_fd >= 0) close (trace_fd);
          trace_fd = -1; failed = TRUE; return;
        }
    }
  if (rows >= MAX_ROWS || written >= MAX_BYTES - 4096)
    {
      static const gchar marker[] = "{\"kind\":\"overflow\"}\n";
      if (written <= MAX_BYTES - (sizeof marker - 1))
        (void) write_all (marker, sizeof marker - 1);
      failed = TRUE; return;
    }
  GimpItem *item = drawables ? GIMP_ITEM (drawables->data) : NULL;
  GimpImage *image = item ? gimp_item_get_image (item) : NULL;
  const gchar *names[] = {"x", "y", "pressure", "xtilt", "ytilt", "rotation", "wheel",
    "distance", "slider", "velocity", "direction", "xscale", "yscale", "angle"};
  const gdouble values[] = {coords->x, coords->y, coords->pressure, coords->xtilt, coords->ytilt,
    coords->rotation, coords->wheel, coords->distance, coords->slider, coords->velocity,
    coords->direction, coords->xscale, coords->yscale, coords->angle};
  GString *line = g_string_sized_new (1024);
  g_string_append_printf (line, "{\"sequence\":%u,\"kind\":\"%s\",\"image\":%d,\"drawable\":%d,\"time\":%u",
    rows + 1, kind, image ? gimp_image_get_id (image) : 0, item ? gimp_item_get_id (item) : 0, time);
  for (guint i = 0; i < G_N_ELEMENTS (values); i++)
    {
      if (!isfinite (values[i])) { failed = TRUE; break; }
      gchar number[G_ASCII_DTOSTR_BUF_SIZE];
      g_ascii_dtostr (number, sizeof number, values[i]);
      g_string_append_printf (line, ",\"%s\":%s", names[i], number);
    }
  g_string_append_printf (line, ",\"reflect\":%s}\n", coords->reflect ? "true" : "false");
  if (!failed && line->len <= 4096 && write_all (line->str, line->len))
    { rows++; written += line->len; }
  else failed = TRUE;
  g_string_free (line, TRUE);
}

gboolean
glims_test_tablet_ui_start (GimpPaintCore *core, GList *drawables, GimpPaintOptions *options,
                           const GimpCoords *coords, GError **error)
{
  record ("start", drawables, coords, 0);
  return gimp_paint_core_start (core, drawables, options, coords, error);
}

void
glims_test_tablet_ui_paint (GimpPaintCore *core, GList *drawables, GimpPaintOptions *options,
                           GimpPaintState state, guint32 time)
{
  const gchar *kind = state == GIMP_PAINT_STATE_INIT ? "init" :
                     state == GIMP_PAINT_STATE_MOTION ? "motion" : "finish";
  record (kind, drawables, &core->cur_coords, time);
  gimp_paint_core_paint (core, drawables, options, state, time);
}

void
glims_test_tablet_ui_interpolate (GimpPaintCore *core, GList *drawables, GimpPaintOptions *options,
                                 const GimpCoords *coords, guint32 time)
{
  record ("interpolate", drawables, coords, time);
  gimp_paint_core_interpolate (core, drawables, options, coords, time);
}

__attribute__((destructor)) static void
close_telemetry (void)
{
  if (trace_fd >= 0) close (trace_fd);
}

/* Explicit preserving PSD import. A private immutable spool supplies both
 * inspection and sample decoding; only a fully prepared native image is adopted. */
#include "engine-private.h"
#include "component-document.h"
#include "cmyk-psd-reader.h"
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpprogress.h"
#include <errno.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  GlimsEngine *engine;
  GlimsProgress *progress;
  GFileIOStream *spool;
  GeglBuffer *planes[4];
  guint64 completed, total;
  gint64 last_service;
  gboolean cancelled;
  guint bytes_per_sample;
  GError *io_error;
} CmykImport;

static void
cancel_import (GimpProgress *unused, gpointer data)
{
  ((CmykImport *) data)->cancelled = TRUE;
}

static gboolean
continue_import (CmykImport *state)
{
  gint64 now = g_get_monotonic_time ();
  if (now - state->last_service >= 10 * G_TIME_SPAN_MILLISECOND ||
      state->completed == state->total)
    {
      gimp_progress_set_value (GIMP_PROGRESS (state->progress),
                                (double) state->completed / MAX (state->total, 1));
      for (guint i = 0; i < 4; i++)
        {
          if (!g_main_context_iteration (NULL, FALSE)) break;
          if (g_get_monotonic_time () - now >= 5 * G_TIME_SPAN_MILLISECOND) break;
        }
      state->last_service = g_get_monotonic_time ();
    }
  g_mutex_lock (&state->engine->lock);
  state->cancelled |= state->engine->stopping;
  g_mutex_unlock (&state->engine->lock);
  return !state->cancelled;
}

static void
io_failure (CmykImport *state, const char *message)
{
  gint saved_errno = errno;
  if (!state->io_error)
    g_set_error (&state->io_error, G_IO_ERROR, g_io_error_from_errno (saved_errno),
                 "%s: %s", message, g_strerror (saved_errno));
}

static gboolean
same_source (const struct stat *a, const struct stat *b)
{
  if (!S_ISREG (b->st_mode) || a->st_dev != b->st_dev || a->st_ino != b->st_ino ||
      a->st_size != b->st_size) return FALSE;
#if defined(__APPLE__)
  return a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec &&
         a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
         a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec &&
         a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
#else
  return a->st_mtim.tv_sec == b->st_mtim.tv_sec && a->st_mtim.tv_nsec == b->st_mtim.tv_nsec &&
         a->st_ctim.tv_sec == b->st_ctim.tv_sec && a->st_ctim.tv_nsec == b->st_ctim.tv_nsec;
#endif
}

static GFileIOStream *
private_spool (GError **error)
{
  g_autofree gchar *directory = g_dir_make_tmp ("glims-cmyk-import-XXXXXX", error);
  if (!directory) return NULL;
  struct stat info;
  if (g_lstat (directory, &info) || !S_ISDIR (info.st_mode) ||
      info.st_uid != geteuid () || (info.st_mode & 077))
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                           "Cannot verify private CMYK import staging.");
      g_rmdir (directory);
      return NULL;
    }
  g_autofree gchar *path = g_build_filename (directory, "source.psd", NULL);
  g_autoptr(GFile) file = g_file_new_for_path (path);
  g_autoptr(GFileIOStream) stream = g_file_create_readwrite (file, G_FILE_CREATE_PRIVATE, NULL, error);
  if (!stream) { g_rmdir (directory); return NULL; }
  gboolean removed_file = g_file_delete (file, NULL, error);
  gboolean removed_directory = g_rmdir (directory) == 0;
  if (!removed_file) return NULL;
  if (!removed_directory)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                           "Cannot retire the private CMYK import staging directory.");
      return NULL;
    }
  return g_steal_pointer (&stream);
}

static gboolean
stage_source (CmykImport *state, int fd, const char *path, const struct stat *before)
{
  guint8 bytes[65536];
  guint64 remaining = (guint64) before->st_size;
  GOutputStream *output = g_io_stream_get_output_stream (G_IO_STREAM (state->spool));
  while (remaining)
    {
      if (!continue_import (state)) return FALSE;
      ssize_t count = read (fd, bytes, (size_t) MIN (remaining, sizeof bytes));
      if (count < 0 && errno == EINTR) continue;
      if (count < 0) { io_failure (state, "Cannot read the CMYK PSD source"); return FALSE; }
      if (!count)
        {
          g_set_error_literal (&state->io_error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                               "The CMYK PSD source was truncated while reading.");
          return FALSE;
        }
      if (!g_output_stream_write_all (output, bytes, (gsize) count, NULL, NULL, &state->io_error)) return FALSE;
      remaining -= count;
      state->completed += count;
    }
  struct stat after, named;
  if (fstat (fd, &after) || g_stat (path, &named))
    { io_failure (state, "Cannot recheck the CMYK PSD source"); return FALSE; }
  if (!same_source (before, &after) || !same_source (before, &named))
    {
      g_set_error_literal (&state->io_error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                           "The CMYK PSD source changed while reading. Try again after it finishes saving.");
      return FALSE;
    }
  return g_output_stream_flush (output, NULL, &state->io_error);
}

static bool
read_snapshot (void *data, uint64_t offset, void *bytes, size_t count)
{
  CmykImport *state = data;
  if (!continue_import (state)) return false;
  if (offset > G_MAXINT64 || !g_seekable_seek (G_SEEKABLE (state->spool), (goffset) offset,
                                             G_SEEK_SET, NULL, &state->io_error)) return false;
  gsize got = 0;
  if (!g_input_stream_read_all (g_io_stream_get_input_stream (G_IO_STREAM (state->spool)),
                                bytes, count, &got, NULL, &state->io_error)) return false;
  if (got != count)
    {
      g_set_error_literal (&state->io_error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                           "The private CMYK PSD snapshot is incomplete.");
      return false;
    }
  return true;
}

static bool
emit_ink (void *data, uint32_t channel, uint32_t y, uint32_t x,
          uint32_t count, const void *samples)
{
  CmykImport *state = data;
  if (!continue_import (state)) return false;
  GeglBuffer *plane = state->planes[channel];
  gegl_buffer_set (plane, GEGL_RECTANGLE (x, y, count, 1), 0,
                    gegl_buffer_get_format (plane), samples, GEGL_AUTO_ROWSTRIDE);
  state->completed += (guint64) count * state->bytes_per_sample;
  return true;
}

static GlimsStatus
parser_failure (CmykImport *state, GlimsCmykPsdInputStatus parsed, char **error)
{
  if (state->cancelled) return GLIMS_STATUS_CANCELLED;
  if (state->io_error) return glims_fail (error, g_steal_pointer (&state->io_error), "The CMYK PSD could not be read.");
  if (parsed == GLIMS_CMYK_PSD_INPUT_NOT_PSD || parsed == GLIMS_CMYK_PSD_INPUT_OTHER_MODE ||
      parsed == GLIMS_CMYK_PSD_INPUT_UNSUPPORTED)
    {
      if (error) *error = g_strdup ("Preserving CMYK import requires a flat RAW or RLE 8-bit or 16-bit PSD with four process inks and only one embedded CMYK profile. Other metadata, layers and ZIP compression are not supported.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  return glims_fail (error, NULL, "The CMYK PSD has malformed or incomplete data.");
}

GlimsStatus
glims_image_import_native_cmyk_psd (GlimsEngine *engine, const char *path,
                                    GlimsImageID *result, char **error)
{
  if (result) *result = 0;
  if (error) *error = NULL;
  if (!path || !g_path_is_absolute (path) || !result) return GLIMS_STATUS_INVALID_ARGUMENT;
  if (!engine) return GLIMS_STATUS_NOT_RUNNING;
  if (engine->busy || engine->progress || g_hash_table_size (engine->strokes) ||
      g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;

  CmykImport state = { .engine = engine };
  GlimsStatus status = GLIMS_STATUS_FAILED;
  GimpImage *candidate = NULL;
  guint8 *icc = NULL;
  GlimsCmykPsdInput input;
  struct stat before;
  int fd = g_open (path, O_RDONLY | O_CLOEXEC | O_NONBLOCK, 0);
  if (fd < 0) { io_failure (&state, "Cannot open the CMYK PSD source"); goto cleanup; }
  if (fstat (fd, &before)) { io_failure (&state, "Cannot inspect the CMYK PSD source"); goto cleanup; }
  if (!S_ISREG (before.st_mode) || before.st_size < 0 ||
      (guint64) before.st_size > GLIMS_CMYK_PSD_MAX_FILE)
    {
      if (error) *error = g_strdup ("Choose a regular CMYK PSD file smaller than 2 GiB.");
      status = GLIMS_STATUS_UNSUPPORTED;
      goto cleanup;
    }
  state.total = MAX ((guint64) before.st_size * 2, 1);
  state.spool = private_spool (&state.io_error);
  if (!state.spool) goto cleanup;
  engine->busy++;
  state.progress = glims_progress_new (engine);
  engine->progress = state.progress;
  gulong cancel_handler = g_signal_connect (state.progress, "cancel", G_CALLBACK (cancel_import), &state);
  gimp_progress_start (GIMP_PROGRESS (state.progress), TRUE, "Importing CMYK inks");

  if (!stage_source (&state, fd, path, &before)) goto finish_progress;
  int closing_fd = fd; fd = -1;
  if (close (closing_fd)) { io_failure (&state, "Cannot close the CMYK PSD source"); goto finish_progress; }
  GlimsCmykPsdInputStatus parsed = glims_cmyk_psd_inspect (read_snapshot, &state, before.st_size, &input);
  if (parsed != GLIMS_CMYK_PSD_INPUT_OK)
    { status = parser_failure (&state, parsed, error); goto finish_progress; }
  icc = g_try_malloc (input.icc_size);
  if (!icc)
    { status = glims_fail (error, NULL, "There is not enough memory for the CMYK profile."); goto finish_progress; }
  if (!read_snapshot (&state, input.icc_offset, icc, input.icc_size)) goto finish_progress;

  /* Preparation is synchronous and explicitly dispatches no events. Release
   * only this operation's guard around that private constructor's busy check;
   * queued calls cannot run until the guard is restored below. Full profile
   * admission happens before the constructor allocates native image storage. */
  engine->busy--;
  status = glims_component_image_prepare (engine, input.width, input.height,
             input.depth == 8 ? GLIMS_COLOR_COMPONENT_U8 : GLIMS_COLOR_COMPONENT_U16,
             4, GLIMS_PLATE_MODE_CMYK, icc, input.icc_size, &candidate, error);
  engine->busy++;
  if (status != GLIMS_STATUS_OK) goto finish_progress;
  GlimsPlateStorage storage;
  if (glims_plate_storage_read (candidate, &storage) != GLIMS_PLATE_STORAGE_VALID)
    { status = glims_fail (error, NULL, "The imported CMYK storage could not be prepared."); goto finish_progress; }
  for (guint c = 0; c < 4; c++)
    state.planes[c] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (storage.planes[c])));
  gimp_image_undo_disable (candidate);
  state.bytes_per_sample = input.depth / 8;
  state.total = (guint64) before.st_size + (guint64) input.width * input.height * 4 * state.bytes_per_sample;
  parsed = glims_cmyk_psd_decode (read_snapshot, &state, &input, emit_ink, &state);
  if (parsed != GLIMS_CMYK_PSD_INPUT_OK)
    { status = parser_failure (&state, parsed, error); goto finish_progress; }
  if (!g_io_stream_close (G_IO_STREAM (state.spool), NULL, &state.io_error))
    { status = GLIMS_STATUS_FAILED; goto finish_progress; }
  if (!continue_import (&state)) { status = GLIMS_STATUS_CANCELLED; goto finish_progress; }
  GFile *imported = g_file_new_for_path (path);
  gimp_image_set_imported_file (candidate, imported);
  g_object_unref (imported);
  gimp_image_undo_enable (candidate);
  gimp_image_clean_all (candidate);
  status = glims_adopt_image (engine, candidate, result);
  if (status == GLIMS_STATUS_OK) candidate = NULL;
  else if (error) *error = g_strdup ("The imported CMYK document could not be opened.");

finish_progress:
  if (state.cancelled) status = GLIMS_STATUS_CANCELLED;
  g_signal_handler_disconnect (state.progress, cancel_handler);
  gimp_progress_end (GIMP_PROGRESS (state.progress));
  engine->progress = NULL;
  g_clear_object (&state.progress);
  engine->busy--;
cleanup:
  if (fd >= 0 && close (fd) && status != GLIMS_STATUS_CANCELLED)
    io_failure (&state, "Cannot close the CMYK PSD source");
  if (state.io_error)
    {
      if (status != GLIMS_STATUS_CANCELLED && (!error || !*error))
        status = glims_fail (error, g_steal_pointer (&state.io_error), "The CMYK PSD could not be read.");
      else g_clear_error (&state.io_error);
    }
  for (guint c = 0; c < 4; c++) g_clear_object (&state.planes[c]);
  g_clear_object (&candidate);
  g_clear_object (&state.spool);
  g_free (icc);
  return status;
}

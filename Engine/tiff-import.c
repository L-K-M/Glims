/* The non-interactive TIFF loader decodes every directory in the main IFD
 * chain as a layer, so an embedded reduced-resolution IFD can enlarge the
 * image (a 256 px tagged thumbnail beside a 64 px page becomes a 256 px
 * canvas). Upstream registers no page-selection argument that the file-open
 * path can reach; its reduced-IFD classification only feeds the interactive
 * page selector. Post-load pruning would have to guess which loaded layer
 * came from which directory, so instead the source chain is scanned for
 * directories explicitly tagged NewSubfileType FILETYPE_REDUCEDIMAGE, the
 * file is copied once into a private staging directory, and only those
 * directories are unlinked from the copy's chain with libtiff's
 * TIFFUnlinkDirectory. The staged copy is what the unmodified loader then
 * decodes; the original is never written.
 *
 * Only directories whose NewSubfileType is exactly FILETYPE_REDUCEDIMAGE
 * are removed, matching the loader's own interactive classifier
 * (file-tiff-load.c, which filters only pages with no other FILETYPE bits).
 * FILETYPE_PAGE or mask combinations and unmarked small pages are ordinary
 * pages, and a chain where every directory is tagged reduced is left
 * untouched rather than emptied. No raster data is decoded or re-encoded:
 * unlinking patches only the next-IFD link field of the preceding
 * directory, or the header's first-IFD offset for directory one, so tag
 * values, pixel offsets and metadata in the copy stay as written. Classic
 * TIFF and BigTIFF in either byte order take the same path through libtiff.
 *
 * The chain is inspected on the private copy itself before unlinking, so a
 * source that changed between the first scan and the copy cannot move the
 * wrong directory. The walk is bounded at 4096 directories; libtiff's
 * IFD-loop detection plus a local offset set refuse cyclic or truncated
 * chains. libtiff diagnostics are captured per open through
 * TIFFOpenOptions handlers rather than the process-global handlers, and a
 * single-allocation bound limits corrupt tag counts. After unlinking the
 * staged copy is reopened and re-scanned: it must hold exactly the ordinary
 * directories and no tagged reduced ones, or staging fails.
 */
#include "tiff-import.h"

#include <errno.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <sys/stat.h>
#include <tiffio.h>
#include <unistd.h>

/* A TIFF with more main-chain directories than this is treated as
 * malformed rather than walked further. */
#define GLIMS_TIFF_MAX_DIRECTORIES 4096
/* libtiff reads whole tag arrays while parsing a directory. The bound
 * keeps a corrupt count from forcing an absurd allocation yet stays far
 * above the tag payloads real files carry (profiles, offset tables). */
#define GLIMS_TIFF_MAX_SINGLE_ALLOC ((tmsize_t) 256 * 1024 * 1024)
#define GLIMS_TIFF_STAGE_PREFIX "glims-tiff-"

typedef struct
{
  guint    directories;  /* main-chain directories read */
  guint    reduced;      /* of those, tagged exactly FILETYPE_REDUCEDIMAGE */
  GArray  *reduced_dirs; /* guint chain positions, or NULL to skip */
} GlimsTiffScan;

static int
capture_tiff_error (TIFF *tif, void *data, const char *module,
                    const char *format, va_list args)
{
  GString *log = data;
  (void) tif;
  if (log)
    {
      if (log->len > 0) g_string_append (log, "; ");
      g_string_append_printf (log, "%s: ", module ? module : "libtiff");
      g_string_append_vprintf (log, format, args);
    }
  return 1; /* handled; never fall through to the global handlers */
}

/* The log must stay alive until the returned handle is closed: libtiff can
 * report through the handler on any later call, including TIFFClose. */
static TIFF *
open_tiff (const char *path, const char *mode, GString *log)
{
  TIFFOpenOptions *options;
  TIFF            *tif;

  options = TIFFOpenOptionsAlloc ();
  if (!options) return NULL;
  TIFFOpenOptionsSetErrorHandlerExtR (options, capture_tiff_error, log);
  TIFFOpenOptionsSetWarningHandlerExtR (options, capture_tiff_error, NULL);
  TIFFOpenOptionsSetMaxSingleMemAlloc (options, GLIMS_TIFF_MAX_SINGLE_ALLOC);
  tif = TIFFOpenExt (path, mode, options);
  TIFFOpenOptionsFree (options);
  return tif;
}

/* Walk the main IFD chain of an open handle. Counts directories and, when
 * scan->reduced_dirs is set, records the 0-based chain positions of those
 * whose NewSubfileType is exactly FILETYPE_REDUCEDIMAGE. A directory that
 * cannot be read while the chain promises another one, a repeated offset,
 * or a chain past the bound is a malformed file. */
static gboolean
scan_chain (TIFF *tif, GlimsTiffScan *scan, GString *log, GError **error)
{
  g_autoptr(GHashTable) seen = NULL;
  gboolean  more_pending = TRUE;
  guint64   offset;
  uint32_t  file_type;
  guint     i;

  seen = g_hash_table_new (g_direct_hash, g_direct_equal);
  scan->directories = 0;
  scan->reduced = 0;

  for (i = 0; i < GLIMS_TIFF_MAX_DIRECTORIES; i++)
    {
      if (!TIFFSetDirectory (tif, i))
        {
          /* A clean end only when the last directory read pointed nowhere. */
          if (i == 0 || more_pending)
            {
              g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                           "TIFF directory %u is unreadable or loops%s%s", i,
                           log->len ? ": " : "", log->len ? log->str : "");
              return FALSE;
            }
          break;
        }

      offset = TIFFCurrentDirOffset (tif);
      if (!g_hash_table_add (seen, GUINT_TO_POINTER ((guintptr) offset)))
        {
          g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                       "TIFF directory chain loops back to offset %"
                       G_GUINT64_FORMAT, offset);
          return FALSE;
        }

      file_type = 0;
      if (TIFFGetField (tif, TIFFTAG_SUBFILETYPE, &file_type) &&
          file_type == FILETYPE_REDUCEDIMAGE)
        {
          scan->reduced++;
          if (scan->reduced_dirs)
            g_array_append_val (scan->reduced_dirs, i);
        }

      scan->directories = i + 1;
      more_pending = !TIFFLastDirectory (tif);
    }

  if (more_pending)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE,
                   "TIFF directory chain exceeds %u directories",
                   (guint) GLIMS_TIFF_MAX_DIRECTORIES);
      return FALSE;
    }
  return TRUE;
}

/* Cheap magic check before libtiff is involved: the four signatures are
 * classic and BigTIFF TIFF in either byte order. A file too short or
 * unreadable is not recognizable and is left to the loader's own error,
 * and only regular files reach libtiff at all. */
static gboolean
is_probably_tiff (const gchar *path)
{
  guint8      prefix[4];
  ssize_t     count;
  gboolean    little_endian, big_endian;
  guint       version;
  struct stat status;
  int         fd;

  if (g_stat (path, &status) != 0 || !S_ISREG (status.st_mode)) return FALSE;
  fd = g_open (path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
  if (fd < 0) return FALSE;
  do
    count = read (fd, prefix, sizeof prefix);
  while (count < 0 && errno == EINTR);
  close (fd);
  if (count < (ssize_t) sizeof prefix) return FALSE;
  little_endian = prefix[0] == 'I' && prefix[1] == 'I';
  big_endian = prefix[0] == 'M' && prefix[1] == 'M';
  if (!little_endian && !big_endian) return FALSE;
  version = little_endian
      ? (guint) prefix[2] | ((guint) prefix[3] << 8)
      : ((guint) prefix[2] << 8) | (guint) prefix[3];
  return version == TIFF_VERSION_CLASSIC || version == TIFF_VERSION_BIG;
}

/* Copy source into a fresh private staging directory, re-scan the copy's
 * chain, and unlink only its directories tagged exactly
 * FILETYPE_REDUCEDIMAGE. The copy is returned even when its own scan finds
 * nothing to remove: it is the file the inspection actually verified. */
static gboolean
stage_reduced_removed (GFile *source, const gchar *source_path,
                       GFile **prepared, GError **error)
{
  g_autofree gchar *dir         = NULL;
  g_autofree gchar *name        = NULL;
  g_autofree gchar *staged_path = NULL;
  g_autoptr(GFile)  staged      = NULL;
  struct stat       status;
  gboolean          keep = FALSE;

  dir = g_dir_make_tmp ("glims-tiff-XXXXXX", error);
  if (!dir) return FALSE;
  if (g_lstat (dir, &status) != 0 || !S_ISDIR (status.st_mode) ||
      status.st_uid != geteuid () || (status.st_mode & 077) != 0)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                           "Cannot verify private TIFF staging directory");
      g_rmdir (dir);
      return FALSE;
    }

  name = g_path_get_basename (source_path);
  staged_path = g_build_filename (dir, name, NULL);
  staged = g_file_new_for_path (staged_path);

  if (!g_file_copy (source, staged, G_FILE_COPY_NONE, NULL, NULL, NULL, error))
    goto out;
  /* TIFFUnlinkDirectory patches the file in place, so the private copy
   * must be owner-writable even when the source was read-only. */
  if (g_chmod (staged_path, 0600) != 0)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "Could not make the staged TIFF copy writable: %s",
                   g_strerror (errno));
      goto out;
    }

  {
    g_autoptr(GString) log     = NULL;
    g_autoptr(GArray)  reduced = NULL;
    GlimsTiffScan      scan;
    gboolean           unlinked;
    gboolean           ok;
    TIFF              *tif;
    guint              k;

    log = g_string_new (NULL);
    tif = open_tiff (staged_path, "r+", log);
    if (!tif)
      {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                     "The staged TIFF copy cannot be opened%s%s",
                     log->len ? ": " : "", log->len ? log->str : "");
        goto out;
      }

    reduced = g_array_new (FALSE, FALSE, sizeof (guint));
    scan.directories = 0;
    scan.reduced = 0;
    scan.reduced_dirs = reduced;
    unlinked = FALSE;
    ok = scan_chain (tif, &scan, log, error);
    /* Unlink only while an ordinary directory survives: never empty the
     * chain. Positions before an unlinked one are unchanged by it, so the
     * marked directories come out highest index first.
     * TIFFUnlinkDirectory numbers directories from 1. */
    if (ok && scan.reduced < scan.directories)
      for (k = reduced->len; k-- > 0; )
        {
          guint position = g_array_index (reduced, guint, k);
          if (!TIFFUnlinkDirectory (tif, (tdir_t) position + 1))
            {
              g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                           "Could not unlink TIFF directory %u in the "
                           "staged copy%s%s", position,
                           log->len ? ": " : "", log->len ? log->str : "");
              ok = FALSE;
              break;
            }
          unlinked = TRUE;
        }
    TIFFClose (tif);
    if (!ok) goto out;

    if (unlinked)
      {
        GlimsTiffScan after;
        TIFF         *verify;

        /* Re-scan the rewritten chain instead of trusting the unlink
         * calls: the loader receives exactly the file verified here. */
        verify = open_tiff (staged_path, "r", log);
        if (!verify)
          {
            g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                         "The staged TIFF copy cannot be verified%s%s",
                         log->len ? ": " : "", log->len ? log->str : "");
            goto out;
          }
        after.directories = 0;
        after.reduced = 0;
        after.reduced_dirs = NULL;
        ok = scan_chain (verify, &after, log, error);
        TIFFClose (verify);
        if (!ok) goto out;
        if (after.reduced != 0 ||
            after.directories != scan.directories - scan.reduced)
          {
            g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                         "The staged TIFF copy failed verification");
            goto out;
          }
      }
  }

  keep = TRUE;
  *prepared = g_steal_pointer (&staged);

out:
  if (!keep)
    {
      g_unlink (staged_path);
      g_rmdir (dir);
    }
  return keep;
}

gboolean
glims_tiff_import_prepare (GFile *source, GFile **prepared, GError **error)
{
  g_autofree gchar *path = NULL;
  g_autoptr(GString) log = NULL;
  GlimsTiffScan      scan;
  gboolean           ok;
  TIFF              *tif;

  g_return_val_if_fail (G_IS_FILE (source), FALSE);
  g_return_val_if_fail (prepared != NULL, FALSE);
  *prepared = NULL;

  /* Files without a local path cannot be scanned or staged; the caller
   * proceeds with the source as it always has. Ordinary file errors are
   * the loader's to report, so an unreadable or too-short file ends the
   * check here the same way. */
  path = g_file_get_path (source);
  if (!path || !is_probably_tiff (path)) return TRUE;

  log = g_string_new (NULL);
  tif = open_tiff (path, "r", log);
  if (!tif)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                   "The TIFF file cannot be inspected%s%s",
                   log->len ? ": " : "", log->len ? log->str : "");
      return FALSE;
    }
  scan.directories = 0;
  scan.reduced = 0;
  scan.reduced_dirs = NULL;
  ok = scan_chain (tif, &scan, log, error);
  TIFFClose (tif);
  if (!ok) return FALSE;

  /* Nothing tagged reduced, or nothing ordinary that would survive:
   * staged unlinks must never leave an empty chain. */
  if (scan.reduced == 0 || scan.reduced == scan.directories) return TRUE;

  return stage_reduced_removed (source, path, prepared, error);
}

void
glims_tiff_import_prepared_cleanup (GFile *prepared)
{
  g_autofree gchar *path     = NULL;
  g_autofree gchar *dir      = NULL;
  g_autofree gchar *dir_name = NULL;

  if (!prepared) return;
  path = g_file_get_path (prepared);
  if (!path) return;
  dir = g_path_get_dirname (path);
  dir_name = g_path_get_basename (dir);
  /* Only a file inside a staging directory this utility created is
   * removed; rmdir then takes the empty private directory. */
  if (!g_str_has_prefix (dir_name, GLIMS_TIFF_STAGE_PREFIX)) return;
  g_unlink (path);
  g_rmdir (dir);
}

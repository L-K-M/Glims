/* Shared local-file transaction for the private CMYK and Bitmap PSD
 * serializers. Pure C11/POSIX; no GLib/GIMP dependency.
 */
#define _POSIX_C_SOURCE 200809L

#include "cmyk-psd-file.h"
#include "bitmap-psd-file.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define GLIMS_CMYK_PSD_FILE_WRITE_CHUNK 65536u
#define GLIMS_CMYK_PSD_FILE_TEMP_RETRIES 64u
#define GLIMS_CMYK_PSD_FILE_RANDOM_BYTES 16u
#define GLIMS_CMYK_PSD_FILE_ENTROPY_RETRIES 64u
#define GLIMS_CMYK_PSD_FILE_CLEANUP_RETRIES 64u

struct glims_cmyk_psd_file_write_ctx {
  int fd;
  GlimsCmykPsdContinue proceed;
  void *proceed_context;
  bool cancelled;
  bool io_failed;
  int io_errno;
};

static bool
proceed_ok (GlimsCmykPsdContinue proceed, void *proceed_context)
{
  if (proceed == NULL)
    return true;
  return proceed (proceed_context);
}

static void
set_io_error (struct glims_cmyk_psd_file_write_ctx *ctx, int err)
{
  if (ctx == NULL || ctx->io_failed)
    return;
  ctx->io_failed = true;
  ctx->io_errno = (err != 0) ? err : EIO;
}

static bool
write_callback (void *context, const uint8_t *bytes, size_t size)
{
  struct glims_cmyk_psd_file_write_ctx *ctx = context;

  if (ctx == NULL || ctx->fd < 0)
    return false;
  if (ctx->cancelled || ctx->io_failed)
    return false;
  if (size == 0)
    return true;
  if (bytes == NULL)
    {
      set_io_error (ctx, EINVAL);
      return false;
    }

  size_t off = 0;
  while (off < size)
    {
      if (!proceed_ok (ctx->proceed, ctx->proceed_context))
        {
          ctx->cancelled = true;
          return false;
        }

      size_t remaining = size - off;
      size_t chunk = remaining > GLIMS_CMYK_PSD_FILE_WRITE_CHUNK
                       ? (size_t) GLIMS_CMYK_PSD_FILE_WRITE_CHUNK
                       : remaining;

      ssize_t n = write (ctx->fd, bytes + off, chunk);
      if (n < 0)
        {
          if (errno == EINTR)
            continue;
          set_io_error (ctx, errno);
          return false;
        }
      if (n == 0)
        {
          set_io_error (ctx, EIO);
          return false;
        }

      off += (size_t) n;
    }

  return true;
}

static bool
is_absolute_nonempty_filename (const char *path)
{
  if (path == NULL || path[0] != '/')
    return false;
  /* absolute nonempty regular filename syntax validation before any output */
  if (path[1] == '\0')
    return false; /* root is not a regular filename */

  size_t len = strlen (path);
  if (len == 0)
    return false;
  if (path[len - 1] == '/')
    return false; /* trailing slash */

  const char *base = strrchr (path, '/');
  base = (base == NULL) ? path : base + 1;
  if (base[0] == '\0')
    return false; /* empty basename */
  if (strcmp (base, ".") == 0 || strcmp (base, "..") == 0)
    return false;

  return true;
}

static GlimsCmykPsdFileStatus
status_from_codec (GlimsCmykPsdStatus st)
{
  switch (st)
    {
    case GLIMS_CMYK_PSD_READ_FAILED:
      return GLIMS_CMYK_PSD_FILE_READ_FAILED;
    case GLIMS_CMYK_PSD_OK:
      return GLIMS_CMYK_PSD_FILE_OK;
    case GLIMS_CMYK_PSD_INVALID:
    case GLIMS_CMYK_PSD_WRITE_FAILED:
    default:
      return GLIMS_CMYK_PSD_FILE_INVALID;
    }
}

static bool
fill_random (uint8_t *buf, size_t len, int *err_out)
{
  if (buf == NULL || len == 0)
    {
      if (err_out)
        *err_out = EINVAL;
      return false;
    }

  int fd = open ("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0)
    {
      if (err_out)
        *err_out = (errno != 0) ? errno : EIO;
      return false;
    }

  size_t off = 0;
  unsigned interruptions = 0;
  while (off < len)
    {
      ssize_t n = read (fd, buf + off, len - off);
      if (n < 0)
        {
          if (errno == EINTR && interruptions++ < GLIMS_CMYK_PSD_FILE_ENTROPY_RETRIES)
            continue;
          if (err_out)
            *err_out = (errno != 0) ? errno : EIO;
          (void) close (fd);
          return false;
        }
      if (n == 0)
        {
          if (err_out)
            *err_out = EIO;
          (void) close (fd);
          return false;
        }
      off += (size_t) n;
    }

  /* Do not retry close: the descriptor may already have been released. */
  if (close (fd) != 0)
    {
      if (err_out) *err_out = errno ? errno : EIO;
      return false;
    }
  if (err_out)
    *err_out = 0;
  return true;
}

static void
hex_encode (const uint8_t *src, size_t len, char *out)
{
  static const char hex[] = "0123456789abcdef";
  for (size_t i = 0; i < len; i++)
    {
      out[i * 2] = hex[(src[i] >> 4) & 0xF];
      out[i * 2 + 1] = hex[src[i] & 0xF];
    }
  out[len * 2] = '\0';
}

static int
open_temp_exclusive (int dirfd, const char *destination,
                     char *name_out, size_t name_out_size)
{
  uint8_t rnd[GLIMS_CMYK_PSD_FILE_RANDOM_BYTES];
  char hex[GLIMS_CMYK_PSD_FILE_RANDOM_BYTES * 2 + 1];
  int flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC;
#ifdef O_NOFOLLOW
  flags |= O_NOFOLLOW;
#endif

  for (unsigned attempt = 0; attempt < GLIMS_CMYK_PSD_FILE_TEMP_RETRIES; attempt++)
    {
      int rerr = 0;
      if (!fill_random (rnd, sizeof rnd, &rerr))
        {
          errno = rerr ? rerr : EIO;
          return -1;
        }
      hex_encode (rnd, sizeof rnd, hex);
      int n = snprintf (name_out, name_out_size, ".glims-cmyk-%s.tmp", hex);
      if (n < 0 || (size_t) n >= name_out_size)
        {
          errno = ENAMETOOLONG;
          return -1;
        }
      if (strcmp (name_out, destination) == 0)
        continue;

      int fd = openat (dirfd, name_out, flags, 0600);
      if (fd >= 0)
        return fd;
      if (errno == EEXIST)
        continue;
      if (errno == EINTR)
        {
          /* retry same attempt not required; bounded overall */
          continue;
        }
      return -1;
    }

  errno = EEXIST;
  return -1;
}

static bool
fsync_fd (struct glims_cmyk_psd_file_write_ctx *ctx, int *err_out)
{
  for (;;)
    {
      if (!proceed_ok (ctx->proceed, ctx->proceed_context))
        {
          ctx->cancelled = true;
          return false;
        }
      if (fsync (ctx->fd) == 0)
        {
          if (err_out)
            *err_out = 0;
          return true;
        }
      if (errno == EINTR)
        continue;
      if (err_out)
        *err_out = (errno != 0) ? errno : EIO;
      return false;
    }
}

static bool
close_no_retry (int fd, int *err_out)
{
  if (fd < 0)
    {
      if (err_out)
        *err_out = EBADF;
      return false;
    }
  if (close (fd) == 0)
    {
      if (err_out)
        *err_out = 0;
      return true;
    }
  /* avoid unsafe close retry on EINTR: fd state unspecified, may be reused */
  if (err_out)
    *err_out = (errno != 0) ? errno : EIO;
  return false;
}

static GlimsCmykPsdFileStatus
check_existing_target (int dirfd, const char *basename, mode_t *out_mode,
                       bool *out_exists, int *out_errno)
{
  struct stat st;
  if (out_exists)
    *out_exists = false;
  if (out_mode)
    *out_mode = 0;
  if (out_errno)
    *out_errno = 0;

  if (fstatat (dirfd, basename, &st, AT_SYMLINK_NOFOLLOW) != 0)
    {
      if (errno == ENOENT)
        {
          if (out_exists)
            *out_exists = false;
          return GLIMS_CMYK_PSD_FILE_OK;
        }
      if (out_errno)
        *out_errno = (errno != 0) ? errno : EIO;
      return GLIMS_CMYK_PSD_FILE_IO_FAILED;
    }

  if (out_exists)
    *out_exists = true;

  if (S_ISLNK (st.st_mode))
    {
      if (out_errno)
        *out_errno = ELOOP;
      return GLIMS_CMYK_PSD_FILE_INVALID;
    }
  if (!S_ISREG (st.st_mode))
    {
      if (out_errno)
        *out_errno = EINVAL;
      return GLIMS_CMYK_PSD_FILE_INVALID;
    }

  if (out_mode)
    *out_mode = st.st_mode & 0777;
  return GLIMS_CMYK_PSD_FILE_OK;
}

typedef GlimsCmykPsdStatus (*PsdSerialize) (void *context, GlimsCmykPsdWrite write,
                                           void *write_context);

/* Both serializers use the same proven destination transaction. Each public
 * wrapper validates its own immutable spec and source before entering. */
static GlimsCmykPsdFileStatus
psd_write_file (const char *path, GlimsCmykPsdContinue proceed,
                void *proceed_context, PsdSerialize serialize,
                void *serialize_context, int *os_error)
{
  if (os_error != NULL)
    *os_error = 0;
  if (!serialize || !is_absolute_nonempty_filename (path))
    return GLIMS_CMYK_PSD_FILE_INVALID;

  const char *slash = strrchr (path, '/');
  const char *basename = (slash != NULL) ? (slash + 1) : path;
  if (basename == NULL || basename[0] == '\0')
    return GLIMS_CMYK_PSD_FILE_INVALID;

  size_t dir_len = (slash == path) ? 1u : (size_t) (slash - path);
  if (dir_len == 0 || dir_len >= PATH_MAX)
    return GLIMS_CMYK_PSD_FILE_INVALID;

  char dirpath[PATH_MAX];
  memcpy (dirpath, path, dir_len);
  dirpath[dir_len] = '\0';

  if (!proceed_ok (proceed, proceed_context))
    return GLIMS_CMYK_PSD_FILE_CANCELLED;

  /* Open destination parent directory and hold dirfd for entire transaction. */
  int dirfd = open (dirpath, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (dirfd < 0)
    {
      if (os_error != NULL)
        *os_error = (errno != 0) ? errno : EIO;
      return GLIMS_CMYK_PSD_FILE_IO_FAILED;
    }

  GlimsCmykPsdFileStatus status = GLIMS_CMYK_PSD_FILE_OK;
  int first_errno = 0;
  int cleanup_errno = 0;
  bool have_temp = false;
  char temp_name[64];
  temp_name[0] = '\0';
  int temp_fd = -1;
  bool target_exists = false;
  mode_t preserved_mode = 0600;
  bool published = false;

  int terr = 0;
  status = check_existing_target (dirfd, basename, &preserved_mode, &target_exists, &terr);
  if (status != GLIMS_CMYK_PSD_FILE_OK)
    {
      if (os_error != NULL)
        *os_error = terr ? terr : (status == GLIMS_CMYK_PSD_FILE_INVALID ? EINVAL : EIO);
      (void) close_no_retry (dirfd, NULL);
      return status;
    }

  if (!proceed_ok (proceed, proceed_context))
    {
      (void) close_no_retry (dirfd, NULL);
      return GLIMS_CMYK_PSD_FILE_CANCELLED;
    }

  temp_fd = open_temp_exclusive (dirfd, basename, temp_name, sizeof temp_name);
  if (temp_fd < 0)
    {
      if (os_error != NULL)
        *os_error = (errno != 0) ? errno : EIO;
      (void) close_no_retry (dirfd, NULL);
      return GLIMS_CMYK_PSD_FILE_IO_FAILED;
    }
  have_temp = true;

  struct glims_cmyk_psd_file_write_ctx wctx;
  memset (&wctx, 0, sizeof wctx);
  wctx.fd = temp_fd;
  wctx.proceed = proceed;
  wctx.proceed_context = proceed_context;
  wctx.cancelled = false;
  wctx.io_failed = false;
  wctx.io_errno = 0;

  GlimsCmykPsdStatus cst = serialize (serialize_context, write_callback, &wctx);

  if (cst == GLIMS_CMYK_PSD_OK)
    {
      /* success path continues below */
    }
  else if (cst == GLIMS_CMYK_PSD_WRITE_FAILED)
    {
      if (wctx.cancelled)
        status = GLIMS_CMYK_PSD_FILE_CANCELLED;
      else if (wctx.io_failed)
        {
          status = GLIMS_CMYK_PSD_FILE_IO_FAILED;
          first_errno = wctx.io_errno ? wctx.io_errno : EIO;
        }
      else
        {
          /* writer returned false without classified reason: treat as IO */
          status = GLIMS_CMYK_PSD_FILE_IO_FAILED;
          first_errno = EIO;
        }
    }
  else
    {
      /* INVALID or READ_FAILED: distinguish codec states */
      status = status_from_codec (cst);
    }

  if (status == GLIMS_CMYK_PSD_FILE_OK)
    {
      /* Apply final ordinary permission mode as needed. */
      mode_t final_mode = target_exists ? preserved_mode : 0600;
      if (fchmod (temp_fd, final_mode) != 0)
        {
          status = GLIMS_CMYK_PSD_FILE_IO_FAILED;
          first_errno = (errno != 0) ? errno : EIO;
        }
    }

  if (status == GLIMS_CMYK_PSD_FILE_OK)
    {
      int serr = 0;
      if (!fsync_fd (&wctx, &serr))
        {
          status = wctx.cancelled ? GLIMS_CMYK_PSD_FILE_CANCELLED
                                 : GLIMS_CMYK_PSD_FILE_IO_FAILED;
          first_errno = wctx.cancelled ? 0 : (serr ? serr : EIO);
        }
    }

  if (status == GLIMS_CMYK_PSD_FILE_OK)
    {
      int cerr = 0;
      if (!close_no_retry (temp_fd, &cerr))
        {
          status = GLIMS_CMYK_PSD_FILE_IO_FAILED;
          first_errno = cerr ? cerr : EIO;
        }
      temp_fd = -1;
    }
  else
    {
      if (temp_fd >= 0)
        {
          int cerr = 0;
          if (!close_no_retry (temp_fd, &cerr))
            cleanup_errno = cerr;
          temp_fd = -1;
        }
    }

  if (status == GLIMS_CMYK_PSD_FILE_OK)
    {
      /* final proceed check before promotion */
      if (!proceed_ok (proceed, proceed_context))
        status = GLIMS_CMYK_PSD_FILE_CANCELLED;
    }

  if (status == GLIMS_CMYK_PSD_FILE_OK)
    {
      /* Before commit recheck target for symlink/nonregular if appropriate.
       * No CAS promise: regular replacement last writer wins. */
      int terr2 = 0;
      GlimsCmykPsdFileStatus rst = check_existing_target (dirfd, basename, NULL, NULL, &terr2);
      if (rst != GLIMS_CMYK_PSD_FILE_OK)
        {
          status = rst;
          first_errno = terr2 ? terr2 : (rst == GLIMS_CMYK_PSD_FILE_INVALID ? EINVAL : EIO);
        }
      else
        {
          /* Preserve the mode captured at admission. No pathname-based
           * metadata changes after the temporary was synced and closed. */
          if (renameat (dirfd, temp_name, dirfd, basename) != 0)
            {
              status = GLIMS_CMYK_PSD_FILE_IO_FAILED;
              first_errno = (errno != 0) ? errno : EIO;
            }
          else
            {
              published = true;
              have_temp = false; /* consumed by rename */
            }
        }
    }

  if (!published && have_temp)
    {
      /* Abort/unlink temp on every precommit failure, preserving destination.
       * Same dirfd for cleanup. If cleanup failure occurs, preserve original
       * meaningful failure. */
      int removed;
      unsigned attempts = 0;
      do
        removed = unlinkat (dirfd, temp_name, 0);
      while (removed != 0 && errno == EINTR &&
             ++attempts < GLIMS_CMYK_PSD_FILE_CLEANUP_RETRIES);
      if (removed != 0 && errno != ENOENT)
        {
          /* Retain the primary status but make incomplete cleanup visible
           * when it is the only available operating-system error. */
          cleanup_errno = errno ? errno : EIO;
        }
    }

  /* Directory fd cleanup. No callback or reported failure after successful rename. */
  {
    int derr = 0;
    if (!close_no_retry (dirfd, &derr))
      {
        if (!published)
          {
            /* preserve original meaningful failure if any */
            if (status == GLIMS_CMYK_PSD_FILE_OK)
              {
                status = GLIMS_CMYK_PSD_FILE_IO_FAILED;
                first_errno = derr ? derr : EIO;
              }
            else if (!cleanup_errno)
              cleanup_errno = derr ? derr : EIO;
          }
        /* after successful rename, ignore close cleanup issues in reported result */
      }
  }

  if (published)
    {
      /* A successful rename is always reported OK. */
      if (os_error != NULL)
        *os_error = 0;
      return GLIMS_CMYK_PSD_FILE_OK;
    }

  if (os_error != NULL)
    {
      if (status == GLIMS_CMYK_PSD_FILE_IO_FAILED)
        *os_error = first_errno ? first_errno : EIO;
      else
        *os_error = cleanup_errno;
    }

  return status;
}


typedef struct {
  const GlimsCmykPsdSpec *spec;
  GlimsCmykPsdRead read;
  void *read_context;
} CmykPsdSource;

static GlimsCmykPsdStatus
serialize_cmyk (void *context, GlimsCmykPsdWrite write, void *write_context)
{
  CmykPsdSource *source = context;
  return glims_cmyk_psd_write (source->spec, source->read, source->read_context,
                               write, write_context);
}

GlimsCmykPsdFileStatus
glims_cmyk_psd_write_file (const GlimsCmykPsdSpec *spec,
                           GlimsCmykPsdRead read, void *read_context,
                           const char *path, GlimsCmykPsdContinue proceed,
                           void *proceed_context, int *os_error)
{
  uint64_t size;
  if (os_error) *os_error = 0;
  if (!read || !is_absolute_nonempty_filename (path) ||
      glims_cmyk_psd_size (spec, &size) != GLIMS_CMYK_PSD_OK)
    return GLIMS_CMYK_PSD_FILE_INVALID;
  CmykPsdSource source = { spec, read, read_context };
  return psd_write_file (path, proceed, proceed_context, serialize_cmyk, &source, os_error);
}

typedef struct {
  const GlimsBitmapPsdSpec *spec;
  GlimsBitmapPsdRead read;
  void *read_context;
  bool invalid_pixel;
} BitmapPsdSource;

static GlimsCmykPsdStatus
serialize_bitmap (void *context, GlimsCmykPsdWrite write, void *write_context)
{
  BitmapPsdSource *source = context;
  GlimsBitmapPsdStatus status = glims_bitmap_psd_write (source->spec, source->read,
      source->read_context, write, write_context);
  switch (status)
    {
    case GLIMS_BITMAP_PSD_OK: return GLIMS_CMYK_PSD_OK;
    case GLIMS_BITMAP_PSD_READ_FAILED: return GLIMS_CMYK_PSD_READ_FAILED;
    case GLIMS_BITMAP_PSD_WRITE_FAILED: return GLIMS_CMYK_PSD_WRITE_FAILED;
    case GLIMS_BITMAP_PSD_INVALID_PIXEL: source->invalid_pixel = true; return GLIMS_CMYK_PSD_INVALID;
    case GLIMS_BITMAP_PSD_INVALID: default: return GLIMS_CMYK_PSD_INVALID;
    }
}

GlimsBitmapPsdFileStatus
glims_bitmap_psd_write_file (const GlimsBitmapPsdSpec *spec,
                             GlimsBitmapPsdRead read, void *read_context,
                             const char *path, GlimsBitmapPsdContinue proceed,
                             void *proceed_context, int *os_error)
{
  uint64_t size;
  if (os_error) *os_error = 0;
  if (!read || !is_absolute_nonempty_filename (path) ||
      glims_bitmap_psd_size (spec, &size) != GLIMS_BITMAP_PSD_OK)
    return GLIMS_BITMAP_PSD_FILE_INVALID;
  BitmapPsdSource source = { spec, read, read_context, false };
  GlimsCmykPsdFileStatus status = psd_write_file (path, proceed, proceed_context,
                                                 serialize_bitmap, &source, os_error);
  if (source.invalid_pixel) return GLIMS_BITMAP_PSD_FILE_INVALID_PIXEL;
  switch (status)
    {
    case GLIMS_CMYK_PSD_FILE_OK: return GLIMS_BITMAP_PSD_FILE_OK;
    case GLIMS_CMYK_PSD_FILE_READ_FAILED: return GLIMS_BITMAP_PSD_FILE_READ_FAILED;
    case GLIMS_CMYK_PSD_FILE_IO_FAILED: return GLIMS_BITMAP_PSD_FILE_IO_FAILED;
    case GLIMS_CMYK_PSD_FILE_CANCELLED: return GLIMS_BITMAP_PSD_FILE_CANCELLED;
    case GLIMS_CMYK_PSD_FILE_INVALID: default: return GLIMS_BITMAP_PSD_FILE_INVALID;
    }
}

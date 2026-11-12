/* Local-file transaction for the private native CMYK PSD serializer. */
#ifndef GLIMS_CMYK_PSD_FILE_H
#define GLIMS_CMYK_PSD_FILE_H
#include "cmyk-psd-codec.h"

typedef enum {
  GLIMS_CMYK_PSD_FILE_OK,
  GLIMS_CMYK_PSD_FILE_INVALID,
  GLIMS_CMYK_PSD_FILE_READ_FAILED,
  GLIMS_CMYK_PSD_FILE_IO_FAILED,
  GLIMS_CMYK_PSD_FILE_CANCELLED
} GlimsCmykPsdFileStatus;

/* Optional cooperative cancellation/progress callback. False cancels before
 * publication. Called before output, during bounded writes and immediately
 * before promotion; may be called more often than source reads. No callback
 * runs after the destination has been replaced. */
typedef bool (*GlimsCmykPsdContinue) (void *context);

/* path is an absolute local filename. All borrowed inputs remain alive and
 * immutable throughout. Invalid specs/paths/callbacks fail before output.
 * Stream into a private, exclusive temporary in the opened destination
 * directory, sync and close it successfully, then publish atomically. Refuse
 * symlinks and nonregular destinations; never follow the destination itself.
 * Failure/cancellation leaves an existing destination intact and attempts to
 * remove our temporary; filesystem errors can prevent cleanup. Existing regular
 * files may be replaced (last writer wins);
 * caller owns any cross-process coordination. Preserve ordinary permission
 * bits on replacement; new files are private. No guarantee of directory-entry
 * durability after power loss. A successful rename is always reported OK.
 * Clears *os_error on entry; supplies errno for IO failures when available.
 * Does not mutate images or retain pointers. */
GlimsCmykPsdFileStatus glims_cmyk_psd_write_file (
    const GlimsCmykPsdSpec *spec, GlimsCmykPsdRead read, void *read_context,
    const char *path, GlimsCmykPsdContinue proceed, void *proceed_context,
    int *os_error);
#endif

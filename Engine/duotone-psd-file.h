/* Atomic local-file transaction for a flat Duotone PSD. */
#ifndef GLIMS_DUOTONE_PSD_FILE_H
#define GLIMS_DUOTONE_PSD_FILE_H
#include "duotone-psd-codec.h"
typedef enum {
  GLIMS_DUOTONE_PSD_FILE_OK,
  GLIMS_DUOTONE_PSD_FILE_INVALID,
  GLIMS_DUOTONE_PSD_FILE_READ_FAILED,
  GLIMS_DUOTONE_PSD_FILE_IO_FAILED,
  GLIMS_DUOTONE_PSD_FILE_CANCELLED
} GlimsDuotonePsdFileStatus;
typedef bool (*GlimsDuotonePsdContinue) (void *context);
/* Absolute local path only. Writes to a private sibling, then syncs and
 * atomically promotes after all callbacks and cancellation checks succeed.
 * Refuses symlinks and nonregular targets. Failure keeps an existing target;
 * filesystem errors may prevent temporary cleanup. Existing ordinary mode bits
 * are retained, new files are private. No callback runs after promotion.
 * Inputs remain immutable for the call. Clears *os_error on entry. */
GlimsDuotonePsdFileStatus glims_duotone_psd_write_file (
    const GlimsDuotonePsdSpec *spec, GlimsDuotonePsdRead read, void *read_context,
    const char *path, GlimsDuotonePsdContinue proceed, void *proceed_context,
    int *os_error);
#endif

/* Atomic local-file publication for the private Bitmap PSD serializer. */
#ifndef GLIMS_BITMAP_PSD_FILE_H
#define GLIMS_BITMAP_PSD_FILE_H
#include "bitmap-psd-codec.h"

typedef enum {
  GLIMS_BITMAP_PSD_FILE_OK,
  GLIMS_BITMAP_PSD_FILE_INVALID,
  GLIMS_BITMAP_PSD_FILE_INVALID_PIXEL,
  GLIMS_BITMAP_PSD_FILE_READ_FAILED,
  GLIMS_BITMAP_PSD_FILE_IO_FAILED,
  GLIMS_BITMAP_PSD_FILE_CANCELLED
} GlimsBitmapPsdFileStatus;

typedef bool (*GlimsBitmapPsdContinue) (void *context);
/* Writes to a private temporary in the destination directory and promotes
 * only after all pixels, sync and cancellation checks succeed. Refuses
 * symlinks and nonregular targets. Failure leaves an existing target intact;
 * cleanup errors can leave the temporary behind. Existing regular targets
 * retain their ordinary permission bits; new files are private. No callbacks
 * run after successful promotion. Inputs remain immutable for the call.
 * Clears *os_error on entry and reports an OS error when one is available. */
GlimsBitmapPsdFileStatus glims_bitmap_psd_write_file (
    const GlimsBitmapPsdSpec *spec, GlimsBitmapPsdRead read, void *read_context,
    const char *path, GlimsBitmapPsdContinue proceed, void *proceed_context,
    int *os_error);
#endif

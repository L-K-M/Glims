#ifndef GLIMS_XCF_GZIP_H
#define GLIMS_XCF_GZIP_H

#include <gio/gio.h>

/* Decode exactly one complete gzip member. The caller owns both streams
 * and must discard partial output after any failure. */
gboolean glims_xcf_gzip_decode (GInputStream *input, GOutputStream *output,
                               guint64 input_limit, guint64 output_limit,
                               GError **error);

#endif

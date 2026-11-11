#ifndef GLIMS_XCF_GZIP_H
#define GLIMS_XCF_GZIP_H

#include <gio/gio.h>

/* Decode exactly one complete gzip member. The caller owns both streams
 * and must discard partial output after any failure. */
gboolean glims_xcf_gzip_decode (GInputStream *input, GOutputStream *output,
                               guint64 input_limit, guint64 output_limit,
                               GError **error);

/* For a gzip source with a non-XCF prefix, stop before staging its payload
 * and return TRUE with is_xcf false. Probe across members if necessary to
 * identify the format. Refuse an undecided prefix at EOF, and require
 * exactly one member for XCF. */
gboolean glims_xcf_gzip_decode_xcf (GInputStream *input, GOutputStream *output,
                                   guint64 input_limit, guint64 output_limit,
                                   gboolean *is_xcf, GError **error);
#endif

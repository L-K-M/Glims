#ifndef GLIMS_XCF_COMPRESSED_H
#define GLIMS_XCF_COMPRESSED_H

#include <gio/gio.h>

typedef enum {
  GLIMS_XCF_COMPRESSION_GZIP,
  GLIMS_XCF_COMPRESSION_BZIP2,
  GLIMS_XCF_COMPRESSION_XZ
} GlimsXcfCompression;

/* Probe decoded bytes before staging. Non-XCF content returns TRUE with
 * is_xcf false for the ordinary loader. XCF requires one complete stream;
 * XZ may have its format-defined, four-byte-aligned zero Stream Padding.
 * Both byte limits include all consumed input/output. Discard partial
 * output on failure. The caller owns both streams. */
gboolean glims_xcf_compressed_decode_xcf (GInputStream *input, GOutputStream *output,
                                         GlimsXcfCompression compression,
                                         guint64 input_limit, guint64 output_limit,
                                         gboolean *is_xcf, GError **error);

#endif

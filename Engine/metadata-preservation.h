#ifndef GLIMS_METADATA_PRESERVATION_H
#define GLIMS_METADATA_PRESERVATION_H
#include <glib.h>
typedef struct _GimpMetadata GimpMetadata;
/* Complete native metadata comparison used by generic metadata editing.
 * Protected EXIF image facts permit native integer-width normalization
 * with identical value strings. Other EXIF values remain raw comparisons;
 * IPTC multiplicity and generated XMP structure/values must match. */
gboolean glims_metadata_equal_native (GimpMetadata *left, GimpMetadata *right);
#endif

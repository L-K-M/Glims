#ifndef GLIMS_METADATA_INVENTORY_H
#define GLIMS_METADATA_INVENTORY_H
#include <glib.h>
#include "glims_engine.h"
typedef struct _GExiv2Metadata GExiv2Metadata;
G_BEGIN_DECLS
/* Counts ALL current entries, including zero-count values omitted by the
 * public GExiv2 list. Exact dependency versions are checked before private
 * layout access. A count different from the public list forbids copying. */
GlimsStatus glims_metadata_xmp_entry_count (GExiv2Metadata *metadata, gsize *out, char **error);
/* EXIF and IPTC public lists also filter zero-count values. Refuse any
 * such native entry before trusting the generic serialization comparer. */
GlimsStatus glims_metadata_empty_entry_count (GExiv2Metadata *metadata, gsize *out, char **error);
G_END_DECLS
#endif

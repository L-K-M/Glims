#ifndef GLIMS_METADATA_XMP_H
#define GLIMS_METADATA_XMP_H
#include <glib.h>

/* Owned structural comparison string, NULL for unverifiable packets. */
gchar *glims_metadata_xmp_structure (const gchar *packet);
#endif

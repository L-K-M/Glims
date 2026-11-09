#ifndef GLIMS_METADATA_LANGUAGE_WRITE_H
#define GLIMS_METADATA_LANGUAGE_WRITE_H
#include "glims_engine.h"
typedef struct _GimpImage GimpImage;
typedef struct _GimpMetadata GimpMetadata;
/* Engine-thread preflight only. Changes one EXISTING exact language key
 * on a detached copy. Never attaches, changes history or authorizes a write.
 * OK+NULL is an exact no-op; OK+owned copy requires caller readiness and
 * one native metadata setter. All refusal paths leave *out NULL and the
 * image untouched. Conservative admission refuses unknown/nested/empty or
 * ambiguous XMP representations and non-stable native normalization facts. */
GlimsStatus glims_metadata_language_prepare (GimpImage *image, const char *root,
                                             const char *language, const char *text,
                                             GimpMetadata **out, char **error);
#endif

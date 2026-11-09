/* Engine-internal read-only XMP LangAlt reader; see docs/metadata-language-read.md
 * and metadata-language.c. No facade slot, no writer; reads never modify metadata. */
#ifndef GLIMS_METADATA_LANGUAGE_H
#define GLIMS_METADATA_LANGUAGE_H

#include <glib.h>
#include "glims_engine.h"

G_BEGIN_DECLS

typedef struct _GimpMetadata GimpMetadata;

/* One owned (language, text) pair: the language spelling is preserved
 * exactly (case folding only for uniqueness); the text is the exact
 * rdf:li content, no trimming. */
typedef struct
{
  char *language;
  char *text;
} GlimsMetadataLanguagePair;

/* Reads the registered XMP LangAlt root property `root` (plain
 * "Xmp.<group>.<property>") from borrowed `metadata`. Success: *out is a
 * new GPtrArray of owned pairs (free function set; the caller only
 * g_ptr_array_unref()s it). *out is NULL first and on every failure.
 * Statuses: INVALID_ARGUMENT (NULL ptr, malformed root), NOT_FOUND
 * (unregistered/absent), UNSUPPORTED (wrong kind/ambiguous), FAILED
 * (native error, owned message). */
GlimsStatus glims_metadata_language_read (GimpMetadata *metadata, const char *root,
                                          GPtrArray **out, char **error);

G_END_DECLS

#endif /* GLIMS_METADATA_LANGUAGE_H */

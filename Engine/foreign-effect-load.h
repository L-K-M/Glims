#ifndef GLIMS_FOREIGN_EFFECT_LOAD_H
#define GLIMS_FOREIGN_EFFECT_LOAD_H
#include "engine-private.h"

#define GLIMS_FOREIGN_SOURCE_ATTRIBUTES \
  "standard::size,etag::value,time::modified,time::modified-usec,unix::device,unix::inode"

/* Success with no spool leaves the regular native loader in charge.
 * gzip_source prevents effect recovery through that fallback. */
gboolean glims_foreign_gzip_spool (GFile *file, GFileInfo *before,
                                  GFileIOStream **staged, gboolean *gzip_source,
                                  GError **error);

GlimsStatus glims_foreign_effects_load (GimpImage *image, GFile *file,
                                       const gchar *mime_type, GFileInfo *before,
                                       GFileIOStream *spool, gboolean gzip_source,
                                       char **error);
#endif

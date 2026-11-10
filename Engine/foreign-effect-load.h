#ifndef GLIMS_FOREIGN_EFFECT_LOAD_H
#define GLIMS_FOREIGN_EFFECT_LOAD_H
#include "engine-private.h"

#define GLIMS_FOREIGN_SOURCE_ATTRIBUTES \
  "standard::size,etag::value,time::modified,time::modified-usec,unix::device,unix::inode"

GlimsStatus glims_foreign_effects_load (GimpImage *image, GFile *file,
                                       const gchar *mime_type, GFileInfo *before,
                                       char **error);
#endif

#ifndef GLIMS_FILTER_INPUT_H
#define GLIMS_FILTER_INPUT_H
#include "engine-private.h"

/* Engine thread. Returns an owned standalone buffer-source with a detached
 * native-format snapshot. No source item or live projection is retained. */
GlimsStatus glims_filter_input_snapshot (GlimsEngine *, GlimsOpenImage *,
                                         GlimsItemID, GeglNode **, char **);
GlimsStatus glims_filter_begin_with_source (GlimsEngine *, GlimsImageID,
                                           GlimsItemID, const char *, GlimsItemID,
                                           GlimsFilterID *, char **);
#endif

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
/* Both explicit roles are validated before copying; distinct sources share
 * the existing snapshot byte budget. Outputs are independently owned refs,
 * including when both roles share one detached source node. */
GlimsStatus glims_filter_input_snapshot_pair (GlimsEngine *, GlimsOpenImage *,
                                              GlimsItemID, GlimsItemID,
                                              GeglNode **, GeglNode **, char **);
GlimsStatus glims_filter_begin_displace_with_sources (GlimsEngine *, GlimsImageID,
                                                     GlimsItemID, GlimsItemID,
                                                     GlimsItemID, GlimsFilterID *, char **);

/* Engine thread, after target admission. Zero ids leave those roles absent.
 * Validates the raw bottom-of-stack target and the detached map samples in
 * its working space before transferring any source node to the caller. */
GlimsStatus glims_filter_input_oilify_prepare (GlimsEngine *, GlimsOpenImage *,
                                              GimpDrawable *, GlimsItemID, GlimsItemID,
                                              GeglNode **, GeglNode **, char **);
GlimsStatus glims_filter_begin_oilify_with_sources (GlimsEngine *, GlimsImageID,
                                                   GlimsItemID, GlimsItemID,
                                                   GlimsItemID, GlimsFilterID *, char **);
#endif

#ifndef GLIMS_FILTER_HISTOGRAM_H
#define GLIMS_FILTER_HISTOGRAM_H
#include "engine-private.h"

void glims_histogram_snapshot_clear (GlimsHistogramSnapshot *out);
void glims_histogram_snapshot_free (GlimsHistogramSnapshot *out);
/* Engine thread only. Returns owned fresh histogram and borrowed session.
 * Rejects stale/unsupported sessions before synchronous native calculation. */
GlimsStatus glims_filter_input_histogram_native (GlimsEngine *engine, GlimsFilterID filter,
                                                 GimpHistogram **out_histogram,
                                                 GlimsFilter **out_session,
                                                 uint32_t *out_trc, char **error);
GlimsStatus glims_filter_input_histogram (GlimsEngine *engine, GlimsFilterID filter,
                                         GlimsHistogramSnapshot *out, char **error);
#endif

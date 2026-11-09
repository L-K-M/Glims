#ifndef GLIMS_LEVELS_CONFIG_H
#define GLIMS_LEVELS_CONFIG_H

#include "engine-private.h"

/* Engine thread only. Exact gimp:levels. Copy preserves an immutable
 * installed config ref; Set duplicates privately before changing values. */
gboolean    glims_levels_config_is_operation (GeglNode *node);
GlimsStatus glims_levels_config_prepare      (GeglNode *node, char **error);
GlimsStatus glims_levels_config_copy         (GeglNode *destination, GeglNode *source,
                                              char **error);
GlimsStatus glims_levels_config_get          (GeglNode *node,
                                              GlimsLevelsSettings *out,
                                              char **error);
GlimsStatus glims_levels_config_set          (GeglNode *node,
                                              const GlimsLevelsSettings *settings,
                                              gboolean *changed, char **error);

#endif /* GLIMS_LEVELS_CONFIG_H */

#ifndef GLIMS_COLOR_BALANCE_CONFIG_H
#define GLIMS_COLOR_BALANCE_CONFIG_H

#include "engine-private.h"

/* Engine thread only. Exact gimp:color-balance. Copy preserves an immutable
 * installed config ref; Set duplicates privately before changing values. */
gboolean    glims_color_balance_config_is_operation (GeglNode *node);
GlimsStatus glims_color_balance_config_prepare (GeglNode *node, char **error);
GlimsStatus glims_color_balance_config_copy (GeglNode *destination, GeglNode *source,
                                             char **error);
GlimsStatus glims_color_balance_config_get (GeglNode *node,
                                            GlimsColorBalanceSettings *out,
                                            char **error);
GlimsStatus glims_color_balance_config_set (GeglNode *node,
                                            const GlimsColorBalanceSettings *settings,
                                            gboolean *changed, char **error);

#endif

#ifndef GLIMS_HUE_SATURATION_CONFIG_H
#define GLIMS_HUE_SATURATION_CONFIG_H

#include "engine-private.h"

/* Engine thread only. Exact gimp:hue-saturation. Copy preserves an immutable
 * installed config ref; Set duplicates privately before changing values. */
gboolean    glims_hue_saturation_config_is_operation (GeglNode *node);
GlimsStatus glims_hue_saturation_config_prepare (GeglNode *node, char **error);
GlimsStatus glims_hue_saturation_config_copy (GeglNode *destination, GeglNode *source,
                                              char **error);
GlimsStatus glims_hue_saturation_config_get (GeglNode *node,
                                             GlimsHueSaturationSettings *out,
                                             char **error);
GlimsStatus glims_hue_saturation_config_set (GeglNode *node,
                                             const GlimsHueSaturationSettings *settings,
                                             gboolean *changed, char **error);

#endif

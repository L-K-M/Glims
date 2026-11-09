#ifndef GLIMS_FILTER_CONFIG_H
#define GLIMS_FILTER_CONFIG_H

#include "engine-private.h"

/* Engine thread only. Installed configs are immutable; Copy shares an owned
 * reference, while Set duplicates privately before replacing the pair. */
gboolean    glims_filter_config_is_brightness_contrast (GeglNode *node);
GlimsStatus glims_filter_config_prepare (GeglNode *node, char **error);
GlimsStatus glims_filter_config_copy (GeglNode *destination, GeglNode *source,
                                      char **error);
GlimsStatus glims_filter_config_get (GeglNode *node,
                                     GlimsBrightnessContrastSettings *out,
                                     char **error);
GlimsStatus glims_filter_config_set (GeglNode *node,
                                     const GlimsBrightnessContrastSettings *settings,
                                     gboolean *changed, char **error);

#endif

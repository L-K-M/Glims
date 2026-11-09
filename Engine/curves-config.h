#ifndef GLIMS_CURVES_CONFIG_H
#define GLIMS_CURVES_CONFIG_H

#include "engine-private.h"

gboolean glims_curves_config_is_operation (GeglNode *node);
GlimsStatus glims_curves_config_validate (GeglNode *node, char **error);
GlimsStatus glims_curves_config_prepare (GeglNode *node, char **error);
GlimsStatus glims_curves_config_copy (GeglNode *destination, GeglNode *source, char **error);
void glims_curves_snapshot_clear (GlimsCurvesSnapshot *out);
void glims_curves_snapshot_free (GlimsCurvesSnapshot *out);
GlimsStatus glims_curves_config_get (GeglNode *node, GlimsCurvesSnapshot *out, char **error);
GlimsStatus glims_curves_config_edit (GeglNode *node, const GlimsCurveEdit *edit,
                                     GlimsCurvesSnapshot *out, gboolean *changed,
                                     char **error);
GlimsStatus glims_curves_config_set_trc (GeglNode *node, uint32_t trc,
                                        GlimsCurvesSnapshot *out, gboolean *changed,
                                        char **error);

#endif

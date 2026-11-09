#ifndef GLIMS_POINT_CONFIG_TRC_H
#define GLIMS_POINT_CONFIG_TRC_H

#include "engine-private.h"
#include "operations/operations-types.h"
#include "operations/gimpoperationpointfilter.h"

/* Private engine-thread seam for exact native point operations with a TRC.
 * Construct specs at call time: native GType macros call get_type(). */
typedef struct {
  const char *operation_name;
  const char *display_name;
  GType operation_type;
  GType config_type;
} GlimsPointConfigTRCSpec;

gboolean glims_point_config_trc_property (GObject *object);
/* Pure validation; returns a borrowed point from node, NULL on failure. */
GlimsStatus glims_point_config_trc_check (GeglNode *node,
                                        const GlimsPointConfigTRCSpec *spec,
                                        gboolean allow_empty,
                                        GimpOperationPointFilter **out,
                                        char **error);
/* Point was checked above; caller validates the complete private candidate.
 * Caller retains its local ref. DEFAULT binding is staged before teardown;
 * no compensation refs or native setters, one final config notification. */
GlimsStatus glims_point_config_trc_install (GimpOperationPointFilter *point,
                                          GObject *candidate,
                                          const GlimsPointConfigTRCSpec *spec,
                                          char **error);

#endif /* GLIMS_POINT_CONFIG_TRC_H */

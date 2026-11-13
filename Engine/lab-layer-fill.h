#ifndef GLIMS_LAB_LAYER_FILL_H
#define GLIMS_LAB_LAYER_FILL_H
#include "engine-private.h"

/* Private serialized fill of one selected logical Lab root. The caller must
 * exclude native mutation and nested engine dispatch for the whole call.
 * Four candidate planes are staged before one native Undo group publishes
 * them; ordinary failures and a zero-coverage result do not change history.
 * If publication succeeds but the native Undo group cannot close, failure
 * still reports *changed and emits canvas damage; its error explains that
 * the Undo group did not finish.
 * No public facade or UI capability is enabled by this helper. */
GlimsStatus glims_lab_layer_fill (GlimsEngine *engine, GimpImage *image,
                                  GimpLayer *root, double lightness,
                                  double a, double b, double opacity,
                                  gboolean *changed, char **error);
#endif

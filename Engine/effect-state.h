#ifndef GLIMS_EFFECT_STATE_H
#define GLIMS_EFFECT_STATE_H
#include "engine-private.h"
typedef struct GlimsEffectSaveState GlimsEffectSaveState;
GlimsStatus glims_effect_state_save_begin (GimpImage *image, GlimsEffectSaveState **state,
                                          char **error);
void glims_effect_state_save_end (GlimsEffectSaveState *state);
GlimsStatus glims_effect_state_load (GimpImage *image, char **error);
#endif

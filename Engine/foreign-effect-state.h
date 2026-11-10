#ifndef GLIMS_FOREIGN_EFFECT_STATE_H
#define GLIMS_FOREIGN_EFFECT_STATE_H
#include "engine-private.h"
#include "xcf-effect-fields.h"

/* Engine thread, synchronously before adopting a natively loaded image.
 * Only ordinary version22/23 layers/effects are admitted. Validate the whole
 * decoded structure before restoring the three XCF composite fields; never
 * write pixels, masks, history or a supplemental state carrier. The caller
 * owns image/fields throughout the call and must bind them to the same file.
 * Refusal is UNSUPPORTED with an optional owned reason, and changes nothing. */
GlimsStatus glims_foreign_effect_fields_restore (GimpImage *image,
                                                const GlimsXcfEffectFields *fields,
                                                char **error);
#endif

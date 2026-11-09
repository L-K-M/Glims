#ifndef GLIMS_METADATA_NORMALIZATION_H
#define GLIMS_METADATA_NORMALIZATION_H

#include "glims_engine.h"

typedef struct _GimpImage GimpImage;
typedef struct _GimpMetadata GimpMetadata;

/*
 * Normalize a caller-owned, detached GimpMetadata copy from `image`'s own
 * state, mirroring the post-install normalization gimp_image_set_metadata
 * runs (app/core/gimpimage-metadata.c: gimp_image_metadata_update_pixel_size,
 * _bits_per_sample, _resolution, _colorspace; identical in all four engine
 * sets at lines 87-101, 104-135, 138-154 and 157-189).
 *
 * The image's own metadata is borrowed only for the alias check and is never
 * modified. `copy` is never attached, no Undo step is pushed, the image is
 * not changed and no write is authorized.
 *
 * Caller contract (serialized engine thread): conservatively admit ALL
 * original LangAlt maps before duplicating, then independently verify the
 * complete metadata and all maps after the normalization/copy roundtrip.
 * The native gimp_metadata_set_* setters return void and swallow errors, so
 * GLIMS_STATUS_OK only means the four normalization requests completed on
 * the copy. It is not preservation proof and not permission to install the
 * copy, push Undo or write.
 *
 * Returns INVALID_ARGUMENT for a NULL image/copy or a copy aliasing the
 * image's own metadata, UNSUPPORTED for an unknown component type, FAILED
 * when the Adobe RGB profile cannot be constructed. `error` is owned by the
 * caller; pass NULL to ignore it.
 */
GlimsStatus glims_metadata_normalize_private_copy (GimpImage    *image,
                                                   GimpMetadata *copy,
                                                   char        **error);

#endif

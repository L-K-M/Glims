/* Engine-thread-only preparation and factories for component documents. */
#ifndef GLIMS_COMPONENT_DOCUMENT_H
#define GLIMS_COMPONENT_DOCUMENT_H

#include "engine-private.h"

/* Prepares validated native component storage without publishing it through
 * the facade. Uses the same dimensions, component, map, profile and busy
 * checks as the public factories; `mode` is a private GLIMS_PLATE_MODE_* value.
 * Applies UUIDs, names, initial pixels, empty history and clean state.
 * Clears *result and *error on entry when supplied. On success *result owns
 * one GimpImage reference; the caller must unref it on abandonment or failed
 * adoption. glims_adopt_image consumes that reference only on success.
 * No dispatch, progress callback or event pumping occurs here. Prepare before
 * taking a long-operation busy guard, on the engine thread, and retain the
 * owned image until publication or cleanup. */
GlimsStatus glims_component_image_prepare (GlimsEngine  *engine,
                                           int32_t       width,
                                           int32_t       height,
                                           uint32_t      component,
                                           uint32_t      channel_count,
                                           uint32_t      mode,
                                           const guint8 *icc,
                                           gsize         icc_size,
                                           GimpImage   **result,
                                           char        **error);

/* Creates and adopts a flat Multichannel document of `channel_count`
 * authoritative scalar ink planes (1..GLIMS_PLATE_LIMIT), each initially
 * paper. `component` is a facade GlimsColorComponent: only U8, U16 and
 * FLOAT are accepted, mapped onto the private plate-map storage values.
 * Dimensions are 1..GIMP_MAX_IMAGE_SIZE. Stable UUID identities and the
 * default ink definitions persist through the plate map; display names
 * are applied through native item rename without Undo entries or dirty
 * state. On entry *result is set to 0 and *error to NULL when supplied.
 * On success the engine owns the image and *result its id. On failure
 * nothing is published and every owned temporary is released. */
GlimsStatus glims_image_new_multichannel (GlimsEngine *engine,
                                          int32_t      width,
                                          int32_t      height,
                                          uint32_t     component,
                                          uint32_t     channel_count,
                                          GlimsImageID *result,
                                          char       **error);

/* Same native scalar storage, with exactly four C/M/Y/K planes and a required
 * immutable CMYK source profile copied into the native XCF metadata. */
GlimsStatus glims_image_new_cmyk (GlimsEngine *engine, int32_t width, int32_t height,
                                  uint32_t component, const guint8 *icc, gsize size,
                                  GlimsImageID *result, char **error);

/* Three physical D50 L/a/b planes, initially neutral white. Integer storage
 * uses the private Lab encoding; float storage contains physical Lab values.
 * No externally supplied profile or ink interpretation is involved. */
GlimsStatus glims_image_new_lab (GlimsEngine *engine, int32_t width, int32_t height,
                                 uint32_t component, GlimsImageID *result,
                                 char **error);

#endif

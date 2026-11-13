/* Private bounded pure-C Lab layer map v2 codec. This metadata does not enable
 * or admit layered Lab; it is a staged storage format only. */
#ifndef GLIMS_LAB_LAYER_MAP_H
#define GLIMS_LAB_LAYER_MAP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_LAB_LAYER_LIMIT 256u
#define GLIMS_LAB_LAYER_MAP_HEADER_SIZE 40u
#define GLIMS_LAB_LAYER_MAP_ENTRY_SIZE 80u
#define GLIMS_LAB_LAYER_MAP_MAX_SIZE \
    (GLIMS_LAB_LAYER_MAP_HEADER_SIZE + \
     GLIMS_LAB_LAYER_LIMIT * GLIMS_LAB_LAYER_MAP_ENTRY_SIZE)

enum { GLIMS_LAB_LAYER_MAP_VERSION_V2 = 2 };
enum { GLIMS_LAB_LAYER_MAP_MODE_LAB = 3 };
enum { GLIMS_LAB_LAYER_MAP_STORAGE_U8 = 1 };
enum { GLIMS_LAB_LAYER_MAP_ENCODING_LAB_D50 = 2 };

typedef struct {
    uint8_t group[16];
    uint8_t l[16];
    uint8_t a[16];
    uint8_t b[16];
    uint8_t alpha[16];
} GlimsLabLayerEntry;

typedef struct {
    uint32_t width, height, count, mode, storage, encoding;
    GlimsLabLayerEntry entries[GLIMS_LAB_LAYER_LIMIT];
} GlimsLabLayerMap;

/* Typed pointers must be properly aligned. Byte buffers may be unaligned.
 * Only count active entries participate in validation. Their group and plane
 * UUIDs must all be nonzero and globally distinct. */
bool glims_lab_layer_map_validate(const GlimsLabLayerMap *map);
/* The map object, bytes[0..capacity), and written object must not overlap.
 * Failure leaves bytes unchanged and sets *written to zero, if supplied.
 * Success publishes exactly 40 + 80 * count staged bytes, leaving spare
 * capacity untouched. A written pointer is required. */
bool glims_lab_layer_map_encode(const GlimsLabLayerMap *map, uint8_t *bytes,
                                size_t capacity, size_t *written);
/* Failure clears the entire supplied destination, including padding.
 * A null output map refuses. Success copies the entire staged owned struct,
 * with inactive entries zeroed. Input bytes may overlap the output map:
 * all input is consumed before publication or failure clearing. */
bool glims_lab_layer_map_decode(const uint8_t *bytes, size_t length,
                                GlimsLabLayerMap *map);
#endif

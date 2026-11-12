/* Private persisted component identities. This metadata is not sufficient to
 * admit a document: its native planes must also satisfy the storage contract. */
#ifndef GLIMS_PLATE_MAP_H
#define GLIMS_PLATE_MAP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_PLATE_LIMIT 32u
#define GLIMS_PLATE_MAP_HEADER_SIZE 40u
#define GLIMS_PLATE_MAP_ENTRY_SIZE 40u
#define GLIMS_PLATE_MAP_MAX_SIZE (GLIMS_PLATE_MAP_HEADER_SIZE + GLIMS_PLATE_LIMIT * GLIMS_PLATE_MAP_ENTRY_SIZE)

enum { GLIMS_PLATE_MODE_MULTICHANNEL = 1 };
enum { GLIMS_PLATE_STORAGE_U8 = 1, GLIMS_PLATE_STORAGE_U16 = 2,
       GLIMS_PLATE_STORAGE_FLOAT = 3 };
enum { GLIMS_PLATE_ENCODING_INTENSITY = 1 }; /* 0 = full ink, 1 = paper */

typedef struct {
    uint8_t uuid[16];
    double ink_rgb[3];
} GlimsPlateEntry;

typedef struct {
    uint32_t width, height, count, mode, storage, encoding;
    GlimsPlateEntry entries[GLIMS_PLATE_LIMIT];
} GlimsPlateMap;

bool glims_plate_map_validate(const GlimsPlateMap *map);
/* Failure leaves bytes unchanged and sets *written to zero, if supplied. */
bool glims_plate_map_encode(const GlimsPlateMap *map, uint8_t *bytes,
                            size_t capacity, size_t *written);
/* Failure clears the entire supplied destination, including padding. */
bool glims_plate_map_decode(const uint8_t *bytes, size_t length,
                            GlimsPlateMap *map);
#endif

#include "lab-layer-map.h"
#include <limits.h>
#include <string.h>

_Static_assert(CHAR_BIT == 8, "Lab layer maps require octets");

static const uint8_t glims_lab_layer_map_magic[8] = {
    'G', 'L', 'I', 'M', 'S', 'P', 'M', '1'
};

static uint32_t glims_lab_layer_map_read_u32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void glims_lab_layer_map_write_u32(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)(value & 0xffu);
    p[1] = (uint8_t)((value >> 8) & 0xffu);
    p[2] = (uint8_t)((value >> 16) & 0xffu);
    p[3] = (uint8_t)((value >> 24) & 0xffu);
}

static bool glims_lab_layer_map_uuid_nonzero(const uint8_t uuid[16])
{
    unsigned any = 0;
    for (unsigned i = 0; i < 16; i++) {
        any |= uuid[i];
    }
    return any != 0;
}

static bool glims_lab_layer_map_uuid_eq(const uint8_t a[16], const uint8_t b[16])
{
    return memcmp(a, b, 16) == 0;
}

static const uint8_t *glims_lab_layer_map_entry_role(const GlimsLabLayerEntry *entry,
                                                     unsigned role)
{
    switch (role) {
    case 0: return entry->group;
    case 1: return entry->l;
    case 2: return entry->a;
    case 3: return entry->b;
    default: return entry->alpha;
    }
}

bool glims_lab_layer_map_validate(const GlimsLabLayerMap *map)
{
    if (!map) {
        return false;
    }
    if (!map->width || map->width > (uint32_t)INT32_MAX ||
        !map->height || map->height > (uint32_t)INT32_MAX ||
        map->count > GLIMS_LAB_LAYER_LIMIT) {
        return false;
    }
    if (map->mode != GLIMS_LAB_LAYER_MAP_MODE_LAB ||
        map->storage != GLIMS_LAB_LAYER_MAP_STORAGE_U8 ||
        map->encoding != GLIMS_LAB_LAYER_MAP_ENCODING_LAB_D50) {
        return false;
    }

    /* All UUIDs active across ALL entries/roles must be nonzero and globally
     * distinct. Bounded simple all-prior comparisons (max 1280 IDs). */
    for (uint32_t i = 0; i < map->count; i++) {
        for (unsigned r = 0; r < 5; r++) {
            const uint8_t *id = glims_lab_layer_map_entry_role(&map->entries[i], r);
            if (!glims_lab_layer_map_uuid_nonzero(id)) {
                return false;
            }
            for (uint32_t j = 0; j < i; j++) {
                for (unsigned s = 0; s < 5; s++) {
                    if (glims_lab_layer_map_uuid_eq(
                            id, glims_lab_layer_map_entry_role(&map->entries[j], s))) {
                        return false;
                    }
                }
            }
            for (unsigned s = 0; s < r; s++) {
                if (glims_lab_layer_map_uuid_eq(
                        id, glims_lab_layer_map_entry_role(&map->entries[i], s))) {
                    return false;
                }
            }
        }
    }
    return true;
}

bool glims_lab_layer_map_encode(const GlimsLabLayerMap *map, uint8_t *bytes,
                                size_t capacity, size_t *written)
{
    if (written) {
        *written = 0;
    }
    if (!written || !bytes || !glims_lab_layer_map_validate(map)) {
        return false;
    }
    /* Validation bounds count to 256 before any extent arithmetic. */
    size_t length = GLIMS_LAB_LAYER_MAP_HEADER_SIZE +
                    (size_t)map->count * GLIMS_LAB_LAYER_MAP_ENTRY_SIZE;
    if (capacity < length) {
        return false;
    }

    /* Stage full encoding before publishing output. */
    uint8_t encoded[GLIMS_LAB_LAYER_MAP_MAX_SIZE];
    memset(encoded, 0, sizeof encoded);
    memcpy(encoded, glims_lab_layer_map_magic, sizeof glims_lab_layer_map_magic);
    glims_lab_layer_map_write_u32(encoded + 8, GLIMS_LAB_LAYER_MAP_VERSION_V2);
    glims_lab_layer_map_write_u32(encoded + 12, map->width);
    glims_lab_layer_map_write_u32(encoded + 16, map->height);
    glims_lab_layer_map_write_u32(encoded + 20, map->count);
    glims_lab_layer_map_write_u32(encoded + 24, map->mode);
    glims_lab_layer_map_write_u32(encoded + 28, map->storage);
    glims_lab_layer_map_write_u32(encoded + 32, map->encoding);
    glims_lab_layer_map_write_u32(encoded + 36, 0u);
    for (uint32_t i = 0; i < map->count; i++) {
        uint8_t *entry = encoded + GLIMS_LAB_LAYER_MAP_HEADER_SIZE +
                         (size_t)i * GLIMS_LAB_LAYER_MAP_ENTRY_SIZE;
        memcpy(entry + 0, map->entries[i].group, 16);
        memcpy(entry + 16, map->entries[i].l, 16);
        memcpy(entry + 32, map->entries[i].a, 16);
        memcpy(entry + 48, map->entries[i].b, 16);
        memcpy(entry + 64, map->entries[i].alpha, 16);
    }
    memcpy(bytes, encoded, length);
    *written = length;
    return true;
}

bool glims_lab_layer_map_decode(const uint8_t *bytes, size_t length,
                                GlimsLabLayerMap *map)
{
    GlimsLabLayerMap decoded;
    memset(&decoded, 0, sizeof decoded);
    if (!map) {
        return false;
    }
    if (!bytes || length < GLIMS_LAB_LAYER_MAP_HEADER_SIZE ||
        memcmp(bytes, glims_lab_layer_map_magic, sizeof glims_lab_layer_map_magic) != 0 ||
        glims_lab_layer_map_read_u32(bytes + 8) != GLIMS_LAB_LAYER_MAP_VERSION_V2 ||
        glims_lab_layer_map_read_u32(bytes + 36) != 0u) {
        goto invalid;
    }
    decoded.width = glims_lab_layer_map_read_u32(bytes + 12);
    decoded.height = glims_lab_layer_map_read_u32(bytes + 16);
    decoded.count = glims_lab_layer_map_read_u32(bytes + 20);
    decoded.mode = glims_lab_layer_map_read_u32(bytes + 24);
    decoded.storage = glims_lab_layer_map_read_u32(bytes + 28);
    decoded.encoding = glims_lab_layer_map_read_u32(bytes + 32);

    if (decoded.count > GLIMS_LAB_LAYER_LIMIT) {
        goto invalid;
    }
    {
        size_t expected = GLIMS_LAB_LAYER_MAP_HEADER_SIZE +
                          (size_t)decoded.count * GLIMS_LAB_LAYER_MAP_ENTRY_SIZE;
        if (length != expected) {
            goto invalid;
        }
    }

    for (uint32_t i = 0; i < decoded.count; i++) {
        const uint8_t *entry = bytes + GLIMS_LAB_LAYER_MAP_HEADER_SIZE +
                               (size_t)i * GLIMS_LAB_LAYER_MAP_ENTRY_SIZE;
        memcpy(decoded.entries[i].group, entry + 0, 16);
        memcpy(decoded.entries[i].l, entry + 16, 16);
        memcpy(decoded.entries[i].a, entry + 32, 16);
        memcpy(decoded.entries[i].b, entry + 48, 16);
        memcpy(decoded.entries[i].alpha, entry + 64, 16);
    }
    if (!glims_lab_layer_map_validate(&decoded)) {
        goto invalid;
    }
    /* Success copies whole staged struct. */
    memcpy(map, &decoded, sizeof decoded);
    return true;

invalid:
    memset(map, 0, sizeof *map);
    return false;
}

#include "plate-map.h"
#include <float.h>
#include <limits.h>
#include <string.h>

_Static_assert(CHAR_BIT == 8 && sizeof(double) == 8 && FLT_RADIX == 2 &&
               DBL_MANT_DIG == 53 && DBL_MAX_EXP == 1024 && DBL_MIN_EXP == -1021,
               "Plate maps require IEEE 754 binary64 doubles and octets");

static const uint8_t magic[8] = { 'G', 'L', 'I', 'M', 'S', 'P', 'M', '1' };
static const uint64_t one_bits = UINT64_C(0x3ff0000000000000);
static const uint64_t negative_zero_bits = UINT64_C(0x8000000000000000);

static uint32_t read_u32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t read_u64(const uint8_t *p)
{
    uint64_t value = 0;
    for (unsigned i = 0; i < 8; i++) value |= (uint64_t)p[i] << (8 * i);
    return value;
}

static void write_integer(uint8_t *p, uint64_t value, unsigned size)
{
    for (unsigned i = 0; i < size; i++) p[i] = (uint8_t)(value >> (8 * i));
}

static uint64_t color_bits(const double *color)
{
    uint64_t bits;
    memcpy(&bits, color, sizeof bits);
    return bits;
}

bool glims_plate_map_validate(const GlimsPlateMap *map)
{
    if (!map || !map->width || map->width > INT32_MAX ||
        !map->height || map->height > INT32_MAX ||
        !map->count || map->count > GLIMS_PLATE_LIMIT)
        return false;

    if (map->mode == GLIMS_PLATE_MODE_CMYK) {
        if (map->count != 4 || map->encoding != GLIMS_PLATE_ENCODING_INTENSITY)
            return false;
    } else if (map->mode == GLIMS_PLATE_MODE_MULTICHANNEL) {
        if (map->encoding != GLIMS_PLATE_ENCODING_INTENSITY)
            return false;
    } else if (map->mode == GLIMS_PLATE_MODE_LAB) {
        if (map->count != 3 || map->encoding != GLIMS_PLATE_ENCODING_LAB_D50)
            return false;
    } else {
        return false;
    }

    if (map->storage < GLIMS_PLATE_STORAGE_U8 || map->storage > GLIMS_PLATE_STORAGE_FLOAT)
        return false;

    for (uint32_t i = 0; i < map->count; i++) {
        const GlimsPlateEntry *entry = &map->entries[i];
        unsigned nonzero = 0;
        for (unsigned j = 0; j < sizeof entry->uuid; j++) nonzero |= entry->uuid[j];
        if (!nonzero) return false;
        for (uint32_t j = 0; j < i; j++)
            if (!memcmp(entry->uuid, map->entries[j].uuid, sizeof entry->uuid))
                return false;
        for (unsigned j = 0; j < 3; j++) {
            /* Bit checks reject signaling NaNs without evaluating them. Lab
             * reserves these fields; existing ink modes also admit host -0. */
            uint64_t bits = color_bits(&entry->ink_rgb[j]);
            if (map->mode == GLIMS_PLATE_MODE_LAB) {
                if (bits != 0) return false;
            } else if (bits > one_bits && bits != negative_zero_bits) return false;
        }
    }
    return true;
}

bool glims_plate_map_encode(const GlimsPlateMap *map, uint8_t *bytes,
                            size_t capacity, size_t *written)
{
    if (written) *written = 0;
    if (!written || !bytes || !glims_plate_map_validate(map)) return false;
    size_t length = GLIMS_PLATE_MAP_HEADER_SIZE +
                    GLIMS_PLATE_MAP_ENTRY_SIZE * map->count;
    if (capacity < length) return false;

    /* Stage before copying so failed encodes never partially modify output. */
    uint8_t encoded[GLIMS_PLATE_MAP_MAX_SIZE] = {0};
    memcpy(encoded, magic, sizeof magic);
    const uint32_t fields[] = {1, map->width, map->height, map->count,
                              map->mode, map->storage, map->encoding, 0};
    for (unsigned i = 0; i < sizeof fields / sizeof fields[0]; i++)
        write_integer(encoded + 8 + 4 * i, fields[i], 4);
    for (uint32_t i = 0; i < map->count; i++) {
        uint8_t *entry = encoded + GLIMS_PLATE_MAP_HEADER_SIZE + GLIMS_PLATE_MAP_ENTRY_SIZE * i;
        memcpy(entry, map->entries[i].uuid, 16);
        for (unsigned j = 0; j < 3; j++) {
            uint64_t bits = color_bits(&map->entries[i].ink_rgb[j]);
            if (bits == negative_zero_bits) bits = 0;
            write_integer(entry + 16 + 8 * j, bits, 8);
        }
    }
    memcpy(bytes, encoded, length);
    *written = length;
    return true;
}

bool glims_plate_map_decode(const uint8_t *bytes, size_t length, GlimsPlateMap *map)
{
    GlimsPlateMap decoded = {0};
    if (!map) return false;
    if (!bytes || length < GLIMS_PLATE_MAP_HEADER_SIZE ||
        memcmp(bytes, magic, sizeof magic) || read_u32(bytes + 8) != 1 ||
        read_u32(bytes + 36) != 0)
        goto invalid;
    decoded.width = read_u32(bytes + 12);
    decoded.height = read_u32(bytes + 16);
    decoded.count = read_u32(bytes + 20);
    decoded.mode = read_u32(bytes + 24);
    decoded.storage = read_u32(bytes + 28);
    decoded.encoding = read_u32(bytes + 32);
    if (!decoded.count || decoded.count > GLIMS_PLATE_LIMIT ||
        length != GLIMS_PLATE_MAP_HEADER_SIZE + GLIMS_PLATE_MAP_ENTRY_SIZE * decoded.count)
        goto invalid;
    for (uint32_t i = 0; i < decoded.count; i++) {
        const uint8_t *entry = bytes + GLIMS_PLATE_MAP_HEADER_SIZE + GLIMS_PLATE_MAP_ENTRY_SIZE * i;
        memcpy(decoded.entries[i].uuid, entry, 16);
        for (unsigned j = 0; j < 3; j++) {
            uint64_t bits = read_u64(entry + 16 + 8 * j);
            if (bits > one_bits) goto invalid;
            memcpy(&decoded.entries[i].ink_rgb[j], &bits, sizeof bits);
        }
    }
    if (!glims_plate_map_validate(&decoded)) goto invalid;
    memcpy(map, &decoded, sizeof decoded);
    return true;

invalid:
    memset(map, 0, sizeof *map);
    return false;
}

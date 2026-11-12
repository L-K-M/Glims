#ifndef GLIMS_LAB_SAMPLES_H
#define GLIMS_LAB_SAMPLES_H

#include <stdbool.h>
#include <stddef.h>

/*
 * Private, bounded candidate Lab sample codec. This does not enable Lab
 * documents, rendering, storage, or edits. It only converts explicit physical
 * Lab rows between encoded sample bytes and physical doubles.
 */

typedef enum {
  GLIMS_LAB_ROLE_L = 0,
  GLIMS_LAB_ROLE_A = 1,
  GLIMS_LAB_ROLE_B = 2
} GlimsLabRole;

typedef enum {
  GLIMS_LAB_FORMAT_U8 = 0,
  GLIMS_LAB_FORMAT_U16 = 1,
  GLIMS_LAB_FORMAT_FLOAT = 2
} GlimsLabFormat;

/*
 * Decode one row of count encoded samples for role/format into count unaligned
 * physical doubles.
 *
 * U8:    L = 100*q/255, chroma = q - 128.
 * U16:   L = 100*q/65535, chroma = q/257 - 128 (ICC v4; neutral 32896).
 * Float: raw physical binary32 loaded with memcpy and converted to double; all
 *        finite extended binary32 values are accepted and -0.0 is preserved.
 *
 * On success all destination doubles are written and true is returned. On any
 * invalid argument, invalid enum, invalid encoded value, overflow, or overlap,
 * no destination bytes are written and false is returned. Count 0 accepts NULL
 * buffers but still requires valid enums. U16 samples use native byte order.
 * Source memory must remain unchanged, and all borrowed buffers remain alive,
 * until the call returns. No source/destination overlap or allocation is used.
 */
bool glims_lab_decode_row(GlimsLabRole role,
                          GlimsLabFormat format,
                          size_t count,
                          const void *source,
                          void *destination);

/*
 * Encode one row of count unaligned physical doubles for role/format into count
 * encoded sample bytes.
 *
 * U8/U16 accept only finite values in nominal ranges L in [0,100], chroma in
 * [-128,127], and quantize to the exact mathematical nearest integer code with
 * half values rounded up, relative to the represented input double (not a
 * rounded intermediate).
 *
 * Float accepts finite values whose magnitude is <= FLT_MAX. Values are stored
 * by C conversion to float (finite underflow follows that cast), preserving
 * -0.0. All finite binary32 values decode/encode as exact round trips.
 *
 * Validation is performed over every sample before any output is written. Late
 * bad input leaves all destination bytes unchanged. Overlap between source and
 * destination ranges is forbidden, including equal pointers, and is rejected
 * before any write. Count 0 accepts NULL buffers with valid enums. The same
 * borrowed-memory lifetime and source immutability rules as decode apply.
 */
bool glims_lab_encode_row(GlimsLabRole role,
                          GlimsLabFormat format,
                          size_t count,
                          const void *source,
                          void *destination);

/* Bytes per encoded sample for format, or 0 for an invalid format. */
size_t glims_lab_sample_size(GlimsLabFormat format);

#endif

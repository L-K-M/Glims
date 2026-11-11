#include "xcf-compressed.h"
#include "xcf-gzip.h"
#include <bzlib.h>
#include <lzma.h>
#include <string.h>

static gboolean
finish_input (GInputStream *input, GlimsXcfCompression compression,
              const guint8 *unread, gsize unread_size,
              guint64 input_limit, guint64 *input_bytes, GError **error)
{
  guint64 padding = unread_size;
  guint8 bytes[4096];
  for (;;) {
    for (gsize i = 0; i < unread_size; i++) {
      if (compression != GLIMS_XCF_COMPRESSION_XZ || unread[i] != 0) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                             "Data follows the compressed XCF stream");
        return FALSE;
      }
    }
    guint64 remaining = input_limit - *input_bytes;
    gsize capacity = remaining >= sizeof bytes ? sizeof bytes : (gsize) remaining + 1;
    gssize count = g_input_stream_read (input, bytes, capacity, NULL, error);
    if (count < 0) return FALSE;
    if ((guint64) count > remaining) {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE,
                           "Compressed XCF input limit exceeded");
      return FALSE;
    }
    if (!count) break;
    *input_bytes += (guint64) count;
    padding += (guint64) count;
    unread = bytes;
    unread_size = (gsize) count;
  }
  if (compression == GLIMS_XCF_COMPRESSION_XZ && padding % 4 != 0) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                         "XZ Stream Padding must contain a multiple of four zero bytes");
    return FALSE;
  }
  return TRUE;
}

gboolean
glims_xcf_compressed_decode_xcf (GInputStream *input, GOutputStream *output,
                                  GlimsXcfCompression compression,
                                  guint64 input_limit, guint64 output_limit,
                                  gboolean *is_xcf, GError **error)
{
  if (!is_xcf) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                         "The compressed XCF probe needs a format result");
    return FALSE;
  }
  *is_xcf = FALSE;
  if (compression == GLIMS_XCF_COMPRESSION_GZIP)
    return glims_xcf_gzip_decode_xcf (input, output, input_limit, output_limit, is_xcf, error);
  if (compression != GLIMS_XCF_COMPRESSION_BZIP2 && compression != GLIMS_XCF_COMPRESSION_XZ) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                         "Unknown XCF compression format");
    return FALSE;
  }

  bz_stream bzip = {0};
  lzma_stream xz = LZMA_STREAM_INIT;
  gboolean uses_bzip = compression == GLIMS_XCF_COMPRESSION_BZIP2;
  if (uses_bzip) {
    /* Bzip2's small mode bounds its decoder workspace without depending
     * on the decoded file size. The header still limits blocks to 900k. */
    if (BZ2_bzDecompressInit (&bzip, 0, 1) != BZ_OK) {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                           "Could not initialize bzip2 decoding");
      return FALSE;
    }
  } else if (lzma_stream_decoder (&xz, G_GUINT64_CONSTANT (512) * 1024 * 1024,
                                   LZMA_TELL_UNSUPPORTED_CHECK) != LZMA_OK) {
    lzma_end (&xz);
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                         "Could not initialize XZ decoding");
    return FALSE;
  }

  static const guint8 magic[] = "gimp xcf ";
  const gsize magic_size = sizeof magic - 1;
  guint8 incoming[32 * 1024], outgoing[32 * 1024];
  const guint8 *next = incoming;
  gsize available = 0, matched = 0;
  guint64 input_bytes = 0, output_bytes = 0;
  gboolean eof = FALSE, complete = FALSE;
  for (;;) {
    if (!available && !eof) {
      guint64 remaining = input_limit - input_bytes;
      gsize capacity = remaining >= sizeof incoming ? sizeof incoming : (gsize) remaining + 1;
      gssize count = g_input_stream_read (input, incoming, capacity, NULL, error);
      if (count < 0) break;
      if ((guint64) count > remaining) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE,
                             "Compressed XCF input limit exceeded");
        break;
      }
      input_bytes += (guint64) count;
      next = incoming;
      available = (gsize) count;
      eof = count == 0;
    }

    guint64 remaining = output_limit - output_bytes;
    gsize capacity = remaining >= sizeof outgoing ? sizeof outgoing : (gsize) remaining + 1;
    if (!*is_xcf) capacity = MIN (capacity, magic_size - matched);
    gsize before = available, unused = capacity;
    gboolean ended = FALSE, valid = FALSE;
    if (uses_bzip) {
      bzip.next_in = (char *) next;
      bzip.avail_in = (unsigned int) available;
      bzip.next_out = (char *) outgoing;
      bzip.avail_out = (unsigned int) capacity;
      int status = BZ2_bzDecompress (&bzip);
      next = (const guint8 *) bzip.next_in;
      available = bzip.avail_in;
      unused = bzip.avail_out;
      ended = status == BZ_STREAM_END;
      valid = status == BZ_OK || ended;
    } else {
      xz.next_in = next;
      xz.avail_in = available;
      xz.next_out = outgoing;
      xz.avail_out = capacity;
      lzma_ret status = lzma_code (&xz, eof ? LZMA_FINISH : LZMA_RUN);
      next = xz.next_in;
      available = xz.avail_in;
      unused = xz.avail_out;
      ended = status == LZMA_STREAM_END;
      valid = status == LZMA_OK || ended;
      if (status == LZMA_MEMLIMIT_ERROR) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                             "The XZ stream needs more than 512 MiB of decoder memory");
        break;
      }
    }
    gsize produced = capacity - unused;
    if (!valid || (!ended && before == available && !produced)) {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                           "Invalid or incomplete compressed XCF stream");
      break;
    }
    if (produced > remaining) {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE,
                           "Decoded XCF limit exceeded");
      break;
    }
    output_bytes += produced;
    if (!*is_xcf) {
      if (memcmp (outgoing, magic + matched, produced)) {
        /* The original loader owns unrelated compressed image formats. */
        complete = TRUE;
        break;
      }
      matched += produced;
      *is_xcf = matched == magic_size;
      if (*is_xcf && !g_output_stream_write_all (output, magic, magic_size, NULL, NULL, error)) break;
    } else if (produced && !g_output_stream_write_all (output, outgoing, produced, NULL, NULL, error)) {
      break;
    }
    if (!ended) continue;
    if (!*is_xcf) {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                           "The decoded compressed header is incomplete");
      break;
    }
    complete = finish_input (input, compression, next, available,
                              input_limit, &input_bytes, error);
    break;
  }
  if (uses_bzip) BZ2_bzDecompressEnd (&bzip);
  else lzma_end (&xz);
  return complete;
}

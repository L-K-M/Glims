#include "xcf-gzip.h"
#include <zlib.h>

gboolean
glims_xcf_gzip_decode (GInputStream *input, GOutputStream *output,
                       guint64 input_limit, guint64 output_limit,
                       GError **error)
{
  z_stream stream = {0};
  if (inflateInit2 (&stream, MAX_WBITS + 16) != Z_OK) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not initialize gzip decoding");
    return FALSE;
  }

  guint8 incoming[32 * 1024], outgoing[32 * 1024];
  guint64 input_bytes = 0, output_bytes = 0;
  gboolean eof = FALSE, complete = FALSE;
  for (;;) {
    if (!stream.avail_in && !eof) {
      guint64 remaining = input_limit - input_bytes;
      /* One sentinel byte distinguishes EOF at the exact limit from excess. */
      gsize capacity = remaining >= sizeof incoming ? sizeof incoming : (gsize) remaining + 1;
      gssize received = g_input_stream_read (input, incoming, capacity, NULL, error);
      if (received < 0) break;
      if ((guint64) received > remaining) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE, "Gzip input limit exceeded");
        break;
      }
      eof = received == 0;
      input_bytes += (guint64) received;
      stream.next_in = incoming;
      stream.avail_in = (uInt) received;
    }

    guint64 remaining = output_limit - output_bytes;
    gsize capacity = remaining >= sizeof outgoing ? sizeof outgoing : (gsize) remaining + 1;
    stream.next_out = outgoing;
    stream.avail_out = (uInt) capacity;
    uInt available = stream.avail_in;
    int result = inflate (&stream, Z_NO_FLUSH);
    gsize produced = capacity - stream.avail_out;
    if (result != Z_STREAM_END &&
        (result != Z_OK || (available == stream.avail_in && !produced))) {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Invalid or incomplete gzip member");
      break;
    }
    if (produced > remaining) {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE, "Decoded gzip limit exceeded");
      break;
    }
    if (produced && !g_output_stream_write_all (output, outgoing, produced, NULL, NULL, error)) break;
    output_bytes += produced;
    if (result != Z_STREAM_END) continue;

    /* inflate validates the gzip trailer. Reject other bytes even when the
     * next member or tail begins beyond the last buffered read. */
    gssize trailing = stream.avail_in;
    if (!trailing && !eof)
      trailing = g_input_stream_read (input, incoming, 1, NULL, error);
    if (trailing < 0) break;
    if (trailing) {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Data follows the gzip member");
      break;
    }
    complete = TRUE;
    break;
  }

  inflateEnd (&stream);
  return complete;
}

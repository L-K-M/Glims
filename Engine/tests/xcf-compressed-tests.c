#include "xcf-compressed.h"
#include <bzlib.h>
#include <lzma.h>
#include <stdio.h>
#include <string.h>

static int checks, failures;
#define CHECK(condition, message) do { \
  gboolean passed = (condition); checks++; failures += !passed; \
  printf ("%s %s\n", passed ? "ok  " : "FAIL", message); \
} while (0)

typedef struct {
  gboolean success, is_xcf, has_error;
  GBytes *bytes;
} Decoded;

static GBytes *
encode (GlimsXcfCompression compression, const guint8 *input, gsize length)
{
  gsize capacity = compression == GLIMS_XCF_COMPRESSION_BZIP2
      ? length + length / 100 + 601 : lzma_stream_buffer_bound (length);
  guint8 *bytes = g_malloc (capacity);
  if (compression == GLIMS_XCF_COMPRESSION_BZIP2) {
    unsigned int count = (unsigned int) capacity;
    if (BZ2_bzBuffToBuffCompress ((char *) bytes, &count, (char *) input,
                                  (unsigned int) length, 1, 0, 0) != BZ_OK) {
      g_free (bytes);
      return NULL;
    }
    capacity = count;
  } else {
    size_t count = 0;
    if (lzma_easy_buffer_encode (0, LZMA_CHECK_CRC64, NULL, input, length,
                                  bytes, &count, capacity) != LZMA_OK) {
      g_free (bytes);
      return NULL;
    }
    capacity = count;
  }
  return g_bytes_new_take (bytes, capacity);
}

static Decoded
decode (GlimsXcfCompression compression, const guint8 *input, gsize length,
         guint64 input_limit, guint64 output_limit)
{
  GInputStream *source = g_memory_input_stream_new_from_data (input, length, NULL);
  GOutputStream *output = g_memory_output_stream_new_resizable ();
  GError *error = NULL;
  Decoded result = {0};
  result.success = glims_xcf_compressed_decode_xcf (source, output, compression,
                                                   input_limit, output_limit,
                                                   &result.is_xcf, &error);
  result.has_error = error != NULL;
  result.bytes = g_bytes_new (g_memory_output_stream_get_data (G_MEMORY_OUTPUT_STREAM (output)),
                              g_memory_output_stream_get_data_size (G_MEMORY_OUTPUT_STREAM (output)));
  g_clear_error (&error);
  g_object_unref (output);
  g_object_unref (source);
  return result;
}

static void
expect_refusal (GlimsXcfCompression compression, const guint8 *bytes, gsize length,
                 guint64 input_limit, guint64 output_limit, const char *message)
{
  Decoded decoded = decode (compression, bytes, length, input_limit, output_limit);
  CHECK (!decoded.success && decoded.has_error, message);
  g_bytes_unref (decoded.bytes);
}

static void
exercise (GlimsXcfCompression compression)
{
  /* These are codec bytes, not a complete image fixture. The real native
   * foreign-XCF fixture separately checks adoption and effect fidelity. */
  static const guint8 plain[] = "gimp xcf v026\0small codec payload";
  GBytes *encoded = encode (compression, plain, sizeof plain);
  CHECK (encoded != NULL, "an independent encoder creates the small input");
  if (!encoded) return;
  gsize size = 0;
  const guint8 *bytes = g_bytes_get_data (encoded, &size);
  Decoded exact = decode (compression, bytes, size, size, sizeof plain);
  gsize decoded_size = 0;
  const guint8 *decoded_bytes = g_bytes_get_data (exact.bytes, &decoded_size);
  CHECK (exact.success && exact.is_xcf && !exact.has_error && decoded_size == sizeof plain
          && !memcmp (decoded_bytes, plain, sizeof plain),
         "exact input/output limits preserve every decoded byte");
  g_bytes_unref (exact.bytes);

  expect_refusal (compression, bytes, size, size - 1, sizeof plain,
                   "one byte over the compressed input budget refuses");
  expect_refusal (compression, bytes, size, size, sizeof plain - 1,
                   "one byte over the decoded output budget refuses");
  expect_refusal (compression, bytes, size - 3, size, sizeof plain,
                   "an incomplete compression trailer refuses");

  guint8 *changed = g_memdup2 (bytes, size);
  /* Bzip2's first block CRC follows BZhN and the six-byte block marker.
   * XZ's footer CRC occupies the first four bytes of its twelve-byte footer. */
  changed[compression == GLIMS_XCF_COMPRESSION_BZIP2 ? 10 : size - 12] ^= 1;
  expect_refusal (compression, changed, size, size, sizeof plain,
                   "a changed native CRC refuses before adoption");
  g_free (changed);

  GByteArray *tail = g_byte_array_sized_new (size * 2);
  g_byte_array_append (tail, bytes, size);
  static const guint8 garbage[] = { 'x' };
  g_byte_array_append (tail, garbage, sizeof garbage);
  expect_refusal (compression, tail->data, tail->len, tail->len, sizeof plain,
                   "non-padding trailing bytes refuse");
  g_byte_array_set_size (tail, size);
  g_byte_array_append (tail, bytes, size);
  expect_refusal (compression, tail->data, tail->len, tail->len, sizeof plain * 2,
                   "a second compression stream refuses");

  if (compression == GLIMS_XCF_COMPRESSION_XZ) {
    static const guint8 zeros[4] = {0};
    g_byte_array_set_size (tail, size);
    g_byte_array_append (tail, zeros, sizeof zeros);
    Decoded padded = decode (compression, tail->data, tail->len, tail->len, sizeof plain);
    CHECK (padded.success && padded.is_xcf && !padded.has_error &&
            g_bytes_get_size (padded.bytes) == sizeof plain,
           "valid four-byte XZ Stream Padding is accepted");
    g_bytes_unref (padded.bytes);
    g_byte_array_set_size (tail, size + 1);
    expect_refusal (compression, tail->data, tail->len, tail->len, sizeof plain,
                     "unaligned XZ Stream Padding refuses");
  }
  g_byte_array_unref (tail);

  static const guint8 other[] = "unrelated compressed content";
  GBytes *non_xcf = encode (compression, other, sizeof other);
  CHECK (non_xcf != NULL, "an independent encoder creates unrelated content");
  if (non_xcf) {
    gsize length;
    const guint8 *data = g_bytes_get_data (non_xcf, &length);
    Decoded probe = decode (compression, data, length, length, sizeof other);
    CHECK (probe.success && !probe.is_xcf && !probe.has_error && !g_bytes_get_size (probe.bytes),
           "a decisive non-XCF prefix delegates without staging bytes");
    g_bytes_unref (probe.bytes);
    g_bytes_unref (non_xcf);
  }

  static const guint8 short_header[] = { 'g', 'i', 'm', 'p', ' ' };
  GBytes *short_stream = encode (compression, short_header, sizeof short_header);
  CHECK (short_stream != NULL, "an independent encoder creates a short undecided prefix");
  if (short_stream) {
    gsize length;
    const guint8 *data = g_bytes_get_data (short_stream, &length);
    expect_refusal (compression, data, length, length, sizeof short_header,
                     "a complete stream with an undecided XCF prefix refuses");
    g_bytes_unref (short_stream);
  }
  g_bytes_unref (encoded);
}

int main (void)
{
  exercise (GLIMS_XCF_COMPRESSION_BZIP2);
  exercise (GLIMS_XCF_COMPRESSION_XZ);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures ? 1 : 0;
}

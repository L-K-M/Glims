#include "xcf-gzip.h"
#include <string.h>

/* A literal single-member gzip for the 20 bytes below, generated separately
 * from the adapter. The trailer begins at byte 32. */
static const guint8 member[] = {
  0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
  0xf3, 0xce, 0xcb, 0x2f, 0xcf, 0x53, 0x88, 0x70, 0x76, 0x53,
  0xc8, 0x4d, 0x2d, 0x49, 0x4c, 0x49, 0x2c, 0x49, 0xd4, 0xe3,
  0x02, 0x00, 0xbd, 0xf4, 0x76, 0x38, 0x14, 0x00, 0x00, 0x00
};
static const char expected[] = "Known XCF metadata.\n";
static const guint8 empty_member[] = {
  0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
  0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};
/* Separately compressed "gimp " and "xcf file\0" form a complete XCF
 * header only when their decoded members are concatenated. */
static const guint8 split_xcf[] = {
  0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
  0x4b, 0xcf, 0xcc, 0x2d, 0x50, 0x00, 0x00, 0x84, 0xe5, 0x40,
  0xff, 0x05, 0x00, 0x00, 0x00,
  0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
  0xab, 0x48, 0x4e, 0x53, 0x48, 0xcb, 0xcc, 0x49, 0x65, 0x00,
  0x00, 0x10, 0x39, 0xc7, 0x15, 0x09, 0x00, 0x00, 0x00
};

static void
exact_limits (void)
{
  g_autoptr(GInputStream) input = g_memory_input_stream_new_from_data (member, sizeof member, NULL);
  g_autoptr(GOutputStream) output = g_memory_output_stream_new_resizable ();
  g_autoptr(GError) error = NULL;
  g_assert_true (glims_xcf_gzip_decode (input, output, sizeof member, sizeof expected - 1, &error));
  g_assert_no_error (error);
  g_assert_cmpuint (g_memory_output_stream_get_data_size (G_MEMORY_OUTPUT_STREAM (output)), ==, sizeof expected - 1);
  g_assert_cmpmem (g_memory_output_stream_get_data (G_MEMORY_OUTPUT_STREAM (output)), sizeof expected - 1,
                   expected, sizeof expected - 1);
}

static void
refuses (const guint8 *bytes, gsize size, guint64 input_limit, guint64 output_limit,
         gint code)
{
  g_autoptr(GInputStream) input = g_memory_input_stream_new_from_data (bytes, size, NULL);
  g_autoptr(GOutputStream) output = g_memory_output_stream_new_resizable ();
  g_autoptr(GError) error = NULL;
  g_assert_false (glims_xcf_gzip_decode (input, output, input_limit, output_limit, &error));
  g_assert_error (error, G_IO_ERROR, code);
  g_assert_cmpuint (g_memory_output_stream_get_data_size (G_MEMORY_OUTPUT_STREAM (output)), <=, output_limit);
}

static void
input_limit (void)
{
  refuses (member, sizeof member, sizeof member - 1, 128, G_IO_ERROR_MESSAGE_TOO_LARGE);
}

static void
output_limit (void)
{
  refuses (member, sizeof member, 128, sizeof expected - 2, G_IO_ERROR_MESSAGE_TOO_LARGE);
}

static void
bad_crc (void)
{
  guint8 bad[sizeof member];
  memcpy (bad, member, sizeof bad);
  bad[sizeof bad - 8] ^= 1;
  refuses (bad, sizeof bad, 128, 128, G_IO_ERROR_INVALID_DATA);
}

static void
truncated_trailer (void)
{
  refuses (member, sizeof member - 1, 128, 128, G_IO_ERROR_INVALID_DATA);
}

static void
trailing_byte (void)
{
  guint8 with_tail[sizeof member + 1] = {0};
  memcpy (with_tail, member, sizeof member);
  refuses (with_tail, sizeof with_tail, 128, 128, G_IO_ERROR_INVALID_DATA);
}

static void
concatenated_members (void)
{
  guint8 pair[2 * sizeof member];
  memcpy (pair, member, sizeof member);
  memcpy (pair + sizeof member, member, sizeof member);
  refuses (pair, sizeof pair, 128, 128, G_IO_ERROR_INVALID_DATA);
}

static void
plain_bytes (void)
{
  refuses ((const guint8 *) expected, sizeof expected - 1, 128, 128, G_IO_ERROR_INVALID_DATA);
}

static void
unrelated_gzip (void)
{
  g_autoptr(GInputStream) input = g_memory_input_stream_new_from_data (member, sizeof member, NULL);
  g_autoptr(GOutputStream) output = g_memory_output_stream_new_resizable ();
  g_autoptr(GError) error = NULL;
  gboolean is_xcf = TRUE;
  g_assert_true (glims_xcf_gzip_decode_xcf (input, output, sizeof member, 128, &is_xcf, &error));
  g_assert_no_error (error);
  g_assert_false (is_xcf);
  g_assert_cmpuint (g_memory_output_stream_get_data_size (G_MEMORY_OUTPUT_STREAM (output)), ==, 0);
}

static void
empty_then_unrelated (void)
{
  guint8 pair[sizeof empty_member + sizeof member];
  memcpy (pair, empty_member, sizeof empty_member);
  memcpy (pair + sizeof empty_member, member, sizeof member);
  g_autoptr(GInputStream) input = g_memory_input_stream_new_from_data (pair, sizeof pair, NULL);
  g_autoptr(GOutputStream) output = g_memory_output_stream_new_resizable ();
  g_autoptr(GError) error = NULL;
  gboolean is_xcf = TRUE;
  g_assert_true (glims_xcf_gzip_decode_xcf (input, output, sizeof pair, 128, &is_xcf, &error));
  g_assert_no_error (error);
  g_assert_false (is_xcf);
  g_assert_cmpuint (g_memory_output_stream_get_data_size (G_MEMORY_OUTPUT_STREAM (output)), ==, 0);
}

static void
split_xcf_prefix (void)
{
  g_autoptr(GInputStream) input = g_memory_input_stream_new_from_data (split_xcf, sizeof split_xcf, NULL);
  g_autoptr(GOutputStream) output = g_memory_output_stream_new_resizable ();
  g_autoptr(GError) error = NULL;
  gboolean is_xcf = FALSE;
  g_assert_false (glims_xcf_gzip_decode_xcf (input, output, sizeof split_xcf, 128, &is_xcf, &error));
  g_assert_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA);
  g_assert_true (is_xcf);
  g_assert_cmpuint (g_memory_output_stream_get_data_size (G_MEMORY_OUTPUT_STREAM (output)), ==, 0);
}

static void
incomplete_xcf_prefix (void)
{
  /* The first complete gzip member decodes only to "gimp ". */
  g_autoptr(GInputStream) input = g_memory_input_stream_new_from_data (split_xcf, 25, NULL);
  g_autoptr(GOutputStream) output = g_memory_output_stream_new_resizable ();
  g_autoptr(GError) error = NULL;
  gboolean is_xcf = FALSE;
  if (glims_xcf_gzip_decode_xcf (input, output, 25, 128, &is_xcf, &error) ||
      !g_error_matches (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA) ||
      g_memory_output_stream_get_data_size (G_MEMORY_OUTPUT_STREAM (output)) != 0) {
    g_test_message ("An undecided partial header must not reach native format detection.");
    g_test_fail ();
  }
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/xcf-gzip/exact-limits", exact_limits);
  g_test_add_func ("/xcf-gzip/input-limit", input_limit);
  g_test_add_func ("/xcf-gzip/output-limit", output_limit);
  g_test_add_func ("/xcf-gzip/invalid-crc", bad_crc);
  g_test_add_func ("/xcf-gzip/truncated-trailer", truncated_trailer);
  g_test_add_func ("/xcf-gzip/trailing-byte", trailing_byte);
  g_test_add_func ("/xcf-gzip/concatenated-members", concatenated_members);
  g_test_add_func ("/xcf-gzip/plain-bytes", plain_bytes);
  g_test_add_func ("/xcf-gzip/unrelated-member", unrelated_gzip);
  g_test_add_func ("/xcf-gzip/empty-then-unrelated", empty_then_unrelated);
  g_test_add_func ("/xcf-gzip/split-xcf-prefix", split_xcf_prefix);
  g_test_add_func ("/xcf-gzip/incomplete-xcf-prefix", incomplete_xcf_prefix);
  return g_test_run ();
}

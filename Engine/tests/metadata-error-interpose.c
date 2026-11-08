/* Test-only fault injection. Retain the injected GError until explicit
 * cleanup so duplicate frees are counted without crashing the process. */
#include <gexiv2/gexiv2.h>
#include <string.h>

static GError *injected;
static unsigned releases;

static gboolean
inject_set (GExiv2Metadata *self, const gchar *tag, const gchar *value, GError **error)
{
  if (!strcmp (tag, "Exif.Image.Artist") && !strcmp (value, "glims-error-ownership-test"))
    {
      g_set_error_literal (error, g_quark_from_static_string ("glims-metadata-test"), 1,
                           "Injected metadata setter failure");
      injected = *error;
      releases = 0;
      return FALSE;
    }
  return gexiv2_metadata_try_set_tag_string (self, tag, value, error);
}

static void
count_error_free (GError *error)
{
  if (error && error == injected) { releases++; return; }
  g_error_free (error);
}

static void
count_clear_error (GError **error)
{
  if (error && *error && *error == injected)
    { releases++; *error = NULL; return; }
  g_clear_error (error);
}

unsigned glims_test_error_releases (void) { return releases; }
void glims_test_release_injected_error (void)
{
  GError *error = injected;
  injected = NULL;
  if (error) g_error_free (error);
}

/* dyld does not interpose references originating in this replacement
 * image; the calls above reach the original implementations. */
#define INTERPOSE(replacement, original) \
  __attribute__((used, section("__DATA,__interpose"))) \
  static const struct { const void *replacement_address; const void *original_address; } \
  interpose_##original = { (const void *)&replacement, (const void *)&original }
INTERPOSE(inject_set, gexiv2_metadata_try_set_tag_string);
INTERPOSE(count_error_free, g_error_free);

INTERPOSE(count_clear_error, g_clear_error);

#include "metadata-inventory.h"
#include <gexiv2/gexiv2.h>
#include <exiv2/exiv2.hpp>
#include <cstdio>
#include <cstring>

static int mode, failures;
// Object-level overrides let the bridge's two version checks be tested
// without swapping installed libraries or touching an assumed layout.
extern "C" gint gexiv2_get_version () { return mode == 1 ? 1408 : 1407; }
namespace Exiv2 { uint32_t versionNumber () { return EXIV2_MAKE_VERSION (0, 28, mode == 2 ? 10 : 9); } }
#define CHECK(c, text) do { std::printf("%s %s\n", (c) ? "ok  " : (failures++, "FAIL"), text); } while (0)

int main ()
{
  GExiv2Metadata *metadata = gexiv2_metadata_new ();
  GObject *unrelated = G_OBJECT (g_object_new (G_TYPE_OBJECT, nullptr));
  char *error = nullptr;
  gsize count = 91;
  mode = 1;
  CHECK (glims_metadata_xmp_entry_count (reinterpret_cast<GExiv2Metadata *> (unrelated), &count, &error) == GLIMS_STATUS_UNSUPPORTED && count == 0,
         "GExiv2 runtime mismatch refuses before inspecting the object's private layout");
  g_clear_pointer (&error, g_free);
  count = 91;
  CHECK (glims_metadata_empty_entry_count (reinterpret_cast<GExiv2Metadata *> (unrelated), &count, &error) == GLIMS_STATUS_UNSUPPORTED && count == 0,
         "all-domain inventory shares the pre-access GExiv2 version guard");
  g_clear_pointer (&error, g_free);
  mode = 2; count = 91;
  CHECK (glims_metadata_xmp_entry_count (reinterpret_cast<GExiv2Metadata *> (unrelated), &count, &error) == GLIMS_STATUS_UNSUPPORTED && count == 0,
         "Exiv2 runtime mismatch refuses before inspecting the object's private layout");
  g_clear_pointer (&error, g_free);
  count = 91;
  CHECK (glims_metadata_empty_entry_count (reinterpret_cast<GExiv2Metadata *> (unrelated), &count, &error) == GLIMS_STATUS_UNSUPPORTED && count == 0,
         "all-domain inventory shares the pre-access Exiv2 version guard");
  g_clear_pointer (&error, g_free);
  mode = 0;
  CHECK (glims_metadata_xmp_entry_count (nullptr, &count, &error) == GLIMS_STATUS_INVALID_ARGUMENT && count == 0,
         "NULL metadata clears the output and refuses");
  CHECK (glims_metadata_xmp_entry_count (metadata, nullptr, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "NULL output refuses");
  const char *packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
    "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
    "<dc:title><rdf:Alt><rdf:li xml:lang=\"fr\">Salut</rdf:li></rdf:Alt></dc:title>"
    "<dc:rights><rdf:Alt/></dc:rights></rdf:Description></rdf:RDF></x:xmpmeta>";
  GError *native_error = nullptr;
  gboolean loaded = gexiv2_metadata_open_buf (metadata, reinterpret_cast<const guint8 *> (packet), std::strlen (packet), &native_error);
  CHECK (loaded && !native_error, "loads the known zero-entry map fixture");
  if (loaded) {
    char **tags = gexiv2_metadata_get_xmp_tags (metadata);
    CHECK (glims_metadata_xmp_entry_count (metadata, &count, &error) == GLIMS_STATUS_OK && count == 2 && tags && g_strv_length (tags) == 1,
           "complete native count sees both entries while the public list omits the empty one");
    CHECK (glims_metadata_empty_entry_count (metadata, &count, &error) == GLIMS_STATUS_OK && count > 0,
           "all-domain zero-entry inventory detects the hidden map");
    g_strfreev (tags);
  }
  g_clear_pointer (&error, g_free);
  g_clear_error (&native_error);
  g_object_unref (unrelated);
  g_object_unref (metadata);
  return failures != 0;
}

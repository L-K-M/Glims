/* Adapter-private XCF supplement. No native enum values/layouts on disk. */
#ifndef GLIMS_EFFECT_ARCHIVE_H
#define GLIMS_EFFECT_ARCHIVE_H
#include <glib.h>

#define GLIMS_EFFECT_ARCHIVE_MAX_BYTES (1024u * 1024u)
#define GLIMS_EFFECT_ARCHIVE_MAX_RECORDS 4096u
#define GLIMS_EFFECT_ARCHIVE_NO_CURVES 32u

typedef struct {
  guint32 tattoo;
  guint32 index;
  gchar *fingerprint;
  gchar *blend_space;
  gchar *composite_space;
  gchar *composite_mode;
  guint32 identities; /* five bits, or NO_CURVES */
} GlimsEffectArchiveRecord;

typedef struct {
  gchar *scope;
  GPtrArray *records; /* owned GlimsEffectArchiveRecord* */
} GlimsEffectArchive;

GlimsEffectArchive *glims_effect_archive_new (void);
void glims_effect_archive_free (GlimsEffectArchive *archive);
void glims_effect_archive_record_free (gpointer record);
gboolean glims_effect_archive_encode (const GlimsEffectArchive *archive,
                                      gchar **bytes, gsize *length, GError **error);
GlimsEffectArchive *glims_effect_archive_decode (const void *bytes, gsize length,
                                                GError **error);
#endif

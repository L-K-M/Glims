/* Read-only XCF metadata, independent of GIMP and the public facade.
 * Version22/23, ordinary layers and their ordinary effect masks only.
 * All returned records/strings belong to the result, never the input stream. */
#ifndef GLIMS_XCF_EFFECT_FIELDS_H
#define GLIMS_XCF_EFFECT_FIELDS_H
#include <gio/gio.h>

#define GLIMS_XCF_EFFECT_FIELDS_MAX_BYTES (8u * 1024u * 1024u)
#define GLIMS_XCF_EFFECT_FIELDS_MAX_STRING (64u * 1024u)
#define GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS 4096u
#define GLIMS_XCF_EFFECT_FIELDS_MAX_PROPERTIES 65536u

typedef enum {
  GLIMS_XCF_EFFECT_FIELDS_NOT_XCF,
  GLIMS_XCF_EFFECT_FIELDS_UNSUPPORTED,
  GLIMS_XCF_EFFECT_FIELDS_MALFORMED,
  GLIMS_XCF_EFFECT_FIELDS_BUDGET
} GlimsXcfEffectFieldsError;

#define GLIMS_XCF_EFFECT_FIELDS_ERROR (glims_xcf_effect_fields_error_quark ())
GQuark glims_xcf_effect_fields_error_quark (void);

typedef enum {
  GLIMS_XCF_FIELD_BLEND_SPACE = 1u << 0,
  GLIMS_XCF_FIELD_COMPOSITE_SPACE = 1u << 1,
  GLIMS_XCF_FIELD_COMPOSITE_MODE = 1u << 2,
  GLIMS_XCF_FIELD_PAINT_MODE = 1u << 3,
  GLIMS_XCF_FIELD_OPACITY = 1u << 4,
  GLIMS_XCF_FIELD_VISIBLE = 1u << 5,
  GLIMS_XCF_FIELD_CLIP = 1u << 6,
  GLIMS_XCF_FIELD_REGION = 1u << 7
} GlimsXcfEffectFieldPresence;

typedef struct {
  guint32 version, width, height, base_type, precision;
} GlimsXcfImageFields;

typedef struct {
  gchar *name;
  guint32 tattoo, width, height, xcf_type;
  gboolean has_tattoo;
} GlimsXcfLayerFields;

typedef struct {
  gchar *name, *icon, *operation, *operation_version;
  guint32 presence;
  gint32 paint_mode, blend_space, composite_space, composite_mode, region;
  gfloat opacity;
  guint32 visible, clip; /* Raw words, not normalized booleans. */
  gboolean mask_present;
  gchar *mask_name;
  guint32 mask_width, mask_height, mask_tattoo;
  gboolean mask_has_tattoo;
} GlimsXcfEffectFieldsRecord;

typedef struct GlimsXcfEffectFields GlimsXcfEffectFields;

/* Opens a seekable regular local file read-only and closes it before return.
 * GIO transport failures retain G_IO_ERROR; format/scope/budget failures use
 * this module's error domain. Unknown raw native enum values are preserved.
 * No tile/hierarchy pixels are read; unrelated TLV payloads are range-checked
 * and seek-skipped. The byte budget covers reads and owned metadata storage,
 * not skipped payloads or file length. Total properties/offsets are bounded.
 * A failure returns NULL and frees the complete partial result. */
GlimsXcfEffectFields *glims_xcf_effect_fields_read (GFile *file,
                                                  GCancellable *cancellable,
                                                  GError **error);
void glims_xcf_effect_fields_free (GlimsXcfEffectFields *fields);
const GlimsXcfImageFields *glims_xcf_effect_fields_image (const GlimsXcfEffectFields *fields);
guint glims_xcf_effect_fields_layer_count (const GlimsXcfEffectFields *fields);
const GlimsXcfLayerFields *glims_xcf_effect_fields_layer (const GlimsXcfEffectFields *fields, guint layer);
guint glims_xcf_effect_fields_effect_count (const GlimsXcfEffectFields *fields, guint layer);
const GlimsXcfEffectFieldsRecord *glims_xcf_effect_fields_effect (const GlimsXcfEffectFields *fields,
                                                               guint layer, guint effect);
guint64 glims_xcf_effect_fields_bytes_read (const GlimsXcfEffectFields *fields);
#endif

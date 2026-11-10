/* XCF omits Curves bypass and resets effect composite fields. Preserve only
 * supplemental state whose complete saved stack/config still corresponds.
 * Native source reference and the format contract are in docs/xcf-effects.md. */
#include "effect-state.h"
#include "effect-archive.h"
#include "curves-config.h"
#include "core/gimpcontainer.h"
#include "core/gimpcurve.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpfilter.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplist.h"
#include "operations/operations-types.h"
#include "operations/gimpcurvesconfig.h"
#include "operations/gimpoperationpointfilter.h"
#include <string.h>

#define CARRIER "glims-effect-state-v1"
struct GlimsEffectSaveState {
  GimpImage *image; /* save caller keeps the live image alive */
  GimpParasite *previous;
};
typedef struct {
  GimpDrawableFilter *filter; /* borrowed during synchronous worker call */
  GlimsEffectArchiveRecord *record; /* owned by archive */
} Target;

static GlimsStatus
fail (char **error, const char *message)
{
  if (error) *error = g_strdup (message);
  return GLIMS_STATUS_UNSUPPORTED;
}

static void
field (GChecksum *sum, const char *text)
{
  gchar size[32]; gsize length = text ? strlen (text) : 0;
  g_snprintf (size, sizeof size, "%zu:", length);
  g_checksum_update (sum, (const guchar *) size, strlen (size));
  if (length) g_checksum_update (sum, (const guchar *) text, length);
}

static void
number (GChecksum *sum, gint64 value)
{
  gchar text[32]; g_snprintf (text, sizeof text, "%" G_GINT64_FORMAT, value);
  field (sum, text);
}

static gchar *
enum_symbol (GType type, gint value)
{
  GEnumClass *klass = g_type_class_ref (type);
  GEnumValue *entry = g_enum_get_value (klass, value);
  gchar *symbol = entry ? g_strdup (entry->value_nick) : NULL;
  g_type_class_unref (klass);
  return symbol;
}

static gboolean
enum_value (GType type, const char *symbol, gint *value)
{
  GEnumClass *klass = g_type_class_ref (type);
  GEnumValue *entry = g_enum_get_value_by_nick (klass, symbol);
  if (entry) *value = entry->value;
  g_type_class_unref (klass);
  return entry != NULL;
}

/* Source-only serde into a separately owned config matches XCF's config
 * representation, including omission of Curves identity. No source setter. */
static gchar *
canonical_config (GeglNode *node)
{
  GeglOperation *operation = gegl_node_get_gegl_operation (node);
  if (!operation) return NULL;
  GParamSpec *spec = g_object_class_find_property (G_OBJECT_GET_CLASS (operation), "config");
  if (!spec || !g_type_is_a (spec->value_type, GIMP_TYPE_CONFIG)) return NULL;
  GObject *source = NULL;
  gegl_node_get (node, "config", &source, NULL);
  if (!source || !GIMP_IS_CONFIG (source)) { g_clear_object (&source); return NULL; }
  gchar *serialized = gimp_config_serialize_to_string (GIMP_CONFIG (source), NULL);
  gchar *normalized = NULL; GError *error = NULL;
  if (serialized && strlen (serialized) <= GLIMS_EFFECT_ARCHIVE_MAX_BYTES) {
    GObject *copy = g_object_new (G_OBJECT_TYPE (source), NULL);
    if (gimp_config_deserialize_string (GIMP_CONFIG (copy), serialized, -1, NULL, &error))
      normalized = gimp_config_serialize_to_string (GIMP_CONFIG (copy), NULL);
    g_object_unref (copy);
  }
  g_clear_error (&error); g_free (serialized); g_object_unref (source);
  if (normalized && strlen (normalized) > GLIMS_EFFECT_ARCHIVE_MAX_BYTES)
    g_clear_pointer (&normalized, g_free);
  return normalized;
}

static gchar *
filter_fingerprint (GimpDrawableFilter *filter, guint32 *identities)
{
  GeglNode *node = gimp_drawable_filter_get_operation (filter);
  const char *operation = gegl_node_get_operation (node);
  /* Native Curve serde's GParamSpec admits exactly256 samples. Refuse
   * unsupported source representations before invoking that serializer. */
  if (glims_curves_config_is_operation (node) &&
      glims_curves_config_validate (node, NULL) != GLIMS_STATUS_OK) return NULL;
  gchar *config = canonical_config (node);
  if (!config) return NULL;
  *identities = GLIMS_EFFECT_ARCHIVE_NO_CURVES;
  if (glims_curves_config_is_operation (node)) {
    GeglOperation *native = gegl_node_get_gegl_operation (node);
    if (!GIMP_IS_OPERATION_POINT_FILTER (native)) { g_free (config); return NULL; }
    GimpOperationPointFilter *point = GIMP_OPERATION_POINT_FILTER (native);
    if (!point->config || G_OBJECT_TYPE (point->config) != GIMP_TYPE_CURVES_CONFIG) { g_free (config); return NULL; }
    GimpCurvesConfig *curves = GIMP_CURVES_CONFIG (point->config);
    *identities = 0;
    /* Native serde owns every admitted point/sample; only its omitted
     * bypass is read separately. Validation above precedes serialization. */
    for (guint i = 0; i < 5; i++) {
      GimpCurve *curve = curves->curve[i];
      if (!curve || G_OBJECT_TYPE (curve) != GIMP_TYPE_CURVE ||
          (curve->identity != FALSE && curve->identity != TRUE)) { g_free (config); return NULL; }
      for (guint j = 0; j < i; j++) if (curve == curves->curve[j]) { g_free (config); return NULL; }
      if (curve->identity) *identities |= 1u << i;
    }
  }
  GChecksum *sum = g_checksum_new (G_CHECKSUM_SHA256);
  field (sum, operation); field (sum, config);
  gboolean custom_name = FALSE;
  g_object_get (filter, "custom-name", &custom_name, NULL);
  const gchar *name = gimp_object_get_name (GIMP_OBJECT (filter));
  GeglOperation *native = gegl_node_get_gegl_operation (node);
  const gchar *title = gegl_operation_class_get_key (GEGL_OPERATION_GET_CLASS (native), "title");
  /* Native construction reclassifies empty/default-title names as ordinary
   * names even when the writer serialized an explicit custom-name flag. */
  custom_name = custom_name && name && *name && g_strcmp0 (name, title) != 0;
  number (sum, custom_name);
  field (sum, custom_name ? name : NULL);
  number (sum, gimp_filter_get_active (GIMP_FILTER (filter)));
  gchar opacity[G_ASCII_DTOSTR_BUF_SIZE];
  field (sum, g_ascii_dtostr (opacity, sizeof opacity, (gfloat) gimp_drawable_filter_get_opacity (filter)));
  GimpLayerMode paint_mode = gimp_drawable_filter_get_paint_mode (filter);
  /* Native XCF deliberately writes this historical alias as Softlight. */
  if (paint_mode == GIMP_LAYER_MODE_OVERLAY_LEGACY) paint_mode = GIMP_LAYER_MODE_SOFTLIGHT_LEGACY;
  gchar *mode = enum_symbol (GIMP_TYPE_LAYER_MODE, paint_mode);
  field (sum, mode); g_free (mode);
  number (sum, gimp_drawable_filter_get_clip (filter));
  number (sum, gimp_drawable_filter_get_region (filter));
  gchar *digest = g_strdup (g_checksum_get_string (sum));
  g_checksum_free (sum); g_free (config);
  return digest;
}

static gboolean
supplement_same (const GlimsEffectArchiveRecord *a, const GlimsEffectArchiveRecord *b)
{
  return a->identities == b->identities && !g_strcmp0 (a->blend_space, b->blend_space) &&
    !g_strcmp0 (a->composite_space, b->composite_space) && !g_strcmp0 (a->composite_mode, b->composite_mode);
}

static gboolean
archive_unambiguous (const GlimsEffectArchive *archive)
{
  for (guint i = 0; i < archive->records->len; i++) {
    const GlimsEffectArchiveRecord *a = g_ptr_array_index (archive->records, i);
    for (guint j = 0; j < i; j++) {
      const GlimsEffectArchiveRecord *b = g_ptr_array_index (archive->records, j);
      if (a->tattoo == b->tattoo && !strcmp (a->fingerprint, b->fingerprint) && !supplement_same (a, b))
        return FALSE;
    }
  }
  return TRUE;
}

static GlimsStatus
capture (GimpImage *image, GlimsEffectArchive **out, GPtrArray **targets_out, char **error)
{
  GlimsEffectArchive *archive = glims_effect_archive_new ();
  GPtrArray *targets = g_ptr_array_new_with_free_func (g_free);
  GChecksum *scope = g_checksum_new (G_CHECKSUM_SHA256);
  GHashTable *tattoos = g_hash_table_new (g_direct_hash, g_direct_equal);
  GList *items = gimp_image_get_layer_list (image);
  items = g_list_concat (items, gimp_image_get_channel_list (image));
  GlimsStatus status = GLIMS_STATUS_OK;
  number (scope, gimp_image_get_width (image)); number (scope, gimp_image_get_height (image));
  gchar *precision = enum_symbol (GIMP_TYPE_PRECISION, gimp_image_get_precision (image));
  gchar *base = enum_symbol (GIMP_TYPE_IMAGE_BASE_TYPE, gimp_image_get_base_type (image));
  field (scope, precision); field (scope, base); g_free (precision); g_free (base);
  for (GList *it = items; it; it = it->next) {
    GimpDrawable *drawable = GIMP_DRAWABLE (it->data); GimpItem *item = GIMP_ITEM (drawable);
    guint32 tattoo = gimp_item_get_tattoo (item); gint x, y; guint index = 0;
    if (GIMP_IS_LAYER (drawable) && gimp_layer_get_mask (GIMP_LAYER (drawable))) {
      GimpDrawable *mask = GIMP_DRAWABLE (gimp_layer_get_mask (GIMP_LAYER (drawable)));
      GimpContainer *mask_filters = gimp_drawable_get_filters (mask);
      for (GList *f = GIMP_LIST (mask_filters)->queue->head; f; f = f->next)
        if (GIMP_IS_DRAWABLE_FILTER (f->data) && !gimp_drawable_filter_get_temporary (f->data)) {
          status = fail (error, "Effects on layer masks cannot yet preserve all XCF state. Merge or remove them before saving."); goto done;
        }
    }
    if (!tattoo || !g_hash_table_add (tattoos, GUINT_TO_POINTER (tattoo))) {
      status = fail (error, "The image has ambiguous drawable identities and cannot preserve effect state."); goto done;
    }
    number (scope, tattoo); number (scope, gimp_item_get_width (item)); number (scope, gimp_item_get_height (item));
    gimp_item_get_offset (item, &x, &y); number (scope, x); number (scope, y);
    GimpContainer *filters = gimp_drawable_get_filters (drawable);
    for (GList *f = GIMP_LIST (filters)->queue->head; f; f = f->next) {
      if (!GIMP_IS_DRAWABLE_FILTER (f->data) || gimp_drawable_filter_get_temporary (f->data)) continue;
      GimpDrawableFilter *filter = f->data;
      GeglNode *operation_node = gimp_drawable_filter_get_operation (filter);
      if (!operation_node || !gegl_node_get_gegl_operation (operation_node) ||
          !gimp_drawable_filter_get_mask (filter)) {
        status = fail (error, "This effect cannot be written by the native XCF format. Merge or remove it before saving."); goto done;
      }
      if (index >= GLIMS_EFFECT_ARCHIVE_MAX_RECORDS || archive->records->len >= GLIMS_EFFECT_ARCHIVE_MAX_RECORDS) {
        status = fail (error, "The effect stack exceeds the supported XCF preservation limit."); goto done;
      }
      guint32 identities = GLIMS_EFFECT_ARCHIVE_NO_CURVES;
      gchar *fingerprint = filter_fingerprint (filter, &identities);
      number (scope, index++);
      if (!fingerprint) {
        /* Ordinary unconfigured GEGL effects use native XCF unchanged. A
         * nondefault supplemental field must never be silently discarded. */
        field (scope, gegl_node_get_operation (gimp_drawable_filter_get_operation (filter)));
        if (gimp_drawable_filter_get_blend_space (filter) != GIMP_LAYER_COLOR_SPACE_AUTO ||
            gimp_drawable_filter_get_composite_space (filter) != GIMP_LAYER_COLOR_SPACE_AUTO ||
            gimp_drawable_filter_get_composite_mode (filter) != GIMP_LAYER_COMPOSITE_AUTO ||
            glims_curves_config_is_operation (gimp_drawable_filter_get_operation (filter))) {
          status = fail (error, "This effect configuration cannot yet be preserved safely in XCF."); goto done;
        }
        continue;
      }
      field (scope, fingerprint);
      GlimsEffectArchiveRecord *r = g_new0 (GlimsEffectArchiveRecord, 1);
      r->tattoo = tattoo; r->index = index - 1; r->fingerprint = fingerprint; r->identities = identities;
      r->blend_space = enum_symbol (GIMP_TYPE_LAYER_COLOR_SPACE, gimp_drawable_filter_get_blend_space (filter));
      r->composite_space = enum_symbol (GIMP_TYPE_LAYER_COLOR_SPACE, gimp_drawable_filter_get_composite_space (filter));
      r->composite_mode = enum_symbol (GIMP_TYPE_LAYER_COMPOSITE_MODE, gimp_drawable_filter_get_composite_mode (filter));
      g_ptr_array_add (archive->records, r);
      Target *target = g_new0 (Target, 1); target->filter = filter; target->record = r; g_ptr_array_add (targets, target);
    }
    number (scope, index);
  }
  archive->scope = g_strdup (g_checksum_get_string (scope));
  *out = archive; *targets_out = targets; archive = NULL; targets = NULL;
done:
  g_list_free (items); g_hash_table_unref (tattoos); g_checksum_free (scope);
  glims_effect_archive_free (archive); if (targets) g_ptr_array_unref (targets);
  return status;
}

void
glims_effect_state_save_end (GlimsEffectSaveState *state)
{
  if (!state) return;
  if (state->previous) {
    gimp_image_parasite_attach (state->image, state->previous, FALSE);
    gimp_parasite_free (state->previous);
  } else gimp_image_parasite_detach (state->image, CARRIER, FALSE);
  g_free (state);
}

GlimsStatus
glims_effect_state_save_begin (GimpImage *image, GlimsEffectSaveState **out, char **error)
{
  *out = NULL; GlimsEffectArchive *archive = NULL; GPtrArray *targets = NULL;
  GlimsStatus status = capture (image, &archive, &targets, error);
  if (status != GLIMS_STATUS_OK) return status;
  /* Identical visible configs with distinct lost state cannot be reliably
   * paired after external reordering. Refuse before changing the live image. */
  if (!archive_unambiguous (archive)) {
    status = fail (error, "Identical effects have different supplemental state. Change an effect name before saving."); goto done;
  }
  gchar *bytes = NULL; gsize length = 0; GError *gerror = NULL;
  if (!glims_effect_archive_encode (archive, &bytes, &length, &gerror)) {
    status = glims_fail (error, gerror, "The effect state could not be saved."); goto done;
  }
  GlimsEffectSaveState *state = g_new0 (GlimsEffectSaveState, 1); state->image = image;
  const GimpParasite *old = gimp_image_parasite_find (image, CARRIER);
  state->previous = old ? gimp_parasite_copy (old) : NULL;
  if (archive->records->len) {
    GimpParasite *parasite = gimp_parasite_new (CARRIER, GIMP_PARASITE_PERSISTENT, length, bytes);
    gimp_image_parasite_attach (image, parasite, FALSE); gimp_parasite_free (parasite);
  } else gimp_image_parasite_detach (image, CARRIER, FALSE);
  g_free (bytes); *out = state;
done:
  glims_effect_archive_free (archive); g_ptr_array_unref (targets);
  return status;
}

GlimsStatus
glims_effect_state_load (GimpImage *image, char **error)
{
  const GimpParasite *parasite = gimp_image_parasite_find (image, CARRIER);
  if (!parasite) return GLIMS_STATUS_OK;
  guint32 length = 0; const void *bytes = gimp_parasite_get_data (parasite, &length);
  GError *gerror = NULL;
  GlimsEffectArchive *saved = glims_effect_archive_decode (bytes, length, &gerror);
  if (!saved) return glims_fail (error, gerror, "The XCF effect-state supplement is invalid.");
  if (!archive_unambiguous (saved)) {
    glims_effect_archive_free (saved);
    return fail (error, "The XCF supplement contains ambiguous effect state and cannot be restored safely.");
  }
  GlimsEffectArchive *current = NULL; GPtrArray *targets = NULL;
  GlimsStatus status = capture (image, &current, &targets, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (strcmp (saved->scope, current->scope) || saved->records->len != current->records->len) {
    status = fail (error, "The XCF effect supplement no longer matches its image. Open an unchanged copy."); goto done;
  }
  /* Complete resolution/validation precedes the first native mutation. */
  for (guint i = 0; i < saved->records->len; i++) {
    GlimsEffectArchiveRecord *a = g_ptr_array_index (saved->records, i), *b = g_ptr_array_index (current->records, i);
    gint value;
    if (a->tattoo != b->tattoo || a->index != b->index || strcmp (a->fingerprint, b->fingerprint) ||
        (a->identities == GLIMS_EFFECT_ARCHIVE_NO_CURVES) != (b->identities == GLIMS_EFFECT_ARCHIVE_NO_CURVES) ||
        !enum_value (GIMP_TYPE_LAYER_COLOR_SPACE, a->blend_space, &value) ||
        !enum_value (GIMP_TYPE_LAYER_COLOR_SPACE, a->composite_space, &value) ||
        !enum_value (GIMP_TYPE_LAYER_COMPOSITE_MODE, a->composite_mode, &value)) {
      status = fail (error, "The XCF effect supplement contains an unmatched or unsupported effect."); goto done;
    }
  }
  for (guint i = 0; i < saved->records->len; i++) {
    GlimsEffectArchiveRecord *r = g_ptr_array_index (saved->records, i);
    Target *target = g_ptr_array_index (targets, i); gint blend = 0, space = 0, mode = 0;
    enum_value (GIMP_TYPE_LAYER_COLOR_SPACE, r->blend_space, &blend);
    enum_value (GIMP_TYPE_LAYER_COLOR_SPACE, r->composite_space, &space);
    enum_value (GIMP_TYPE_LAYER_COMPOSITE_MODE, r->composite_mode, &mode);
    if (r->identities != GLIMS_EFFECT_ARCHIVE_NO_CURVES) {
      GeglNode *node = gimp_drawable_filter_get_operation (target->filter);
      GimpOperationPointFilter *point = GIMP_OPERATION_POINT_FILTER (gegl_node_get_gegl_operation (node));
      GimpCurvesConfig *curves = GIMP_CURVES_CONFIG (point->config);
      for (guint c = 0; c < 5; c++) curves->curve[c]->identity = (r->identities & (1u << c)) != 0;
      g_object_notify (G_OBJECT (point), "config");
    }
    gimp_drawable_filter_set_mode (target->filter, gimp_drawable_filter_get_paint_mode (target->filter), blend, space, mode);
  }
  gimp_image_parasite_detach (image, CARRIER, FALSE);
done:
  glims_effect_archive_free (saved); glims_effect_archive_free (current);
  if (targets) g_ptr_array_unref (targets);
  return status;
}

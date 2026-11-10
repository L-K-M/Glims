/* Restore only the native XCF effect fields that xcf_load_effect_props resets
 * to AUTO. File identity/decoding and image adoption belong to the caller.
 * Native source references and normalization rules are recorded in the audit. */
#include "foreign-effect-state.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpdrawablefiltermask.h"
#include "core/gimpfilter.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayermask.h"
#include "core/gimplist.h"
#include "core/gimpviewable.h"
#include "gegl/gimp-babl.h"
#include "gegl/gimp-babl-compat.h"
#include "operations/operations-enums.h"
#include "operations/layer-modes/gimp-layer-modes.h"
#include "text/gimptextlayer.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplinklayer.h"
#include "path/gimpvectorlayer.h"
#endif
#include <math.h>

typedef struct {
  GimpDrawableFilter *filter; /* Borrowed from image during this synchronous call. */
  GimpLayerMode paint_mode;
  GimpLayerColorSpace blend_space, composite_space;
  GimpLayerCompositeMode composite_mode;
} Target;

static GlimsStatus
refuse (char **error, const char *reason)
{
  if (error) *error = g_strdup (reason);
  return GLIMS_STATUS_UNSUPPORTED;
}

static gboolean
enum_valid (GType type, gint value)
{
  GEnumClass *klass = g_type_class_ref (type);
  gboolean valid = g_enum_get_value (klass, value) != NULL;
  g_type_class_unref (klass);
  return valid;
}

/* xcf-load.c's layer property loader records AUTO as the negated effective
 * value. Preserve AUTO only while the loaded paint mode still maps to it.
 * Reject INT32_MIN before negation and validate the concrete native enum. */
static gboolean
resolve_field (gint32 raw, GType type, gint effective, gint automatic, gint *out)
{
  if (raw == G_MININT32) return FALSE;
  gint value = raw < 0 ? -raw : raw;
  if (!enum_valid (type, value)) return FALSE;
  *out = raw < 0 && value == effective ? automatic : value;
  return TRUE;
}

/* The pinned native effect writer passes one vararg to a property writer
 * that consumes two. Its three properties can therefore contain the same
 * unregistered word instead of any saved enum. Those words have no native
 * interpretation: retain the loader's AUTO values, as ordinary XCF opening
 * did before recovery. Never use this compatibility case for a registered
 * value, mixed words, missing fields or an already explicit loaded setting. */
static gboolean
writer_omitted_fields (const GlimsXcfEffectFieldsRecord *record,
                       gint blend, gint composite, gint combination)
{
  const guint32 all = GLIMS_XCF_FIELD_BLEND_SPACE | GLIMS_XCF_FIELD_COMPOSITE_SPACE |
                      GLIMS_XCF_FIELD_COMPOSITE_MODE;
  gint32 raw = record->blend_space;
  if ((record->presence & all) != all || raw == G_MININT32 ||
      raw != record->composite_space || raw != record->composite_mode ||
      blend != GIMP_LAYER_COLOR_SPACE_AUTO || composite != GIMP_LAYER_COLOR_SPACE_AUTO ||
      combination != GIMP_LAYER_COMPOSITE_AUTO)
    return FALSE;
  gint value = raw < 0 ? -raw : raw;
  return !enum_valid (GIMP_TYPE_LAYER_COLOR_SPACE, value) &&
         !enum_valid (GIMP_TYPE_LAYER_COMPOSITE_MODE, value);
}

static gboolean
mask_matches (GimpImage *image, GimpDrawableFilter *filter,
              const GlimsXcfEffectFieldsRecord *record)
{
  GimpDrawableFilterMask *mask = gimp_drawable_filter_get_mask (filter);
  /* Native load converts a saved channel to a filter-mask object; freeze
   * synthesizes an image-sized selection copy if no mask was serialized.
   * Conversion assigns a new tattoo, and set_filter renames/repositions it.
   * Those normalized identities must not be compared with the raw channel. */
  guint32 width = record->mask_present ? record->mask_width : (guint32) gimp_image_get_width (image);
  guint32 height = record->mask_present ? record->mask_height : (guint32) gimp_image_get_height (image);
  if (!mask || G_OBJECT_TYPE (mask) != GIMP_TYPE_DRAWABLE_FILTER_MASK ||
      gimp_drawable_filter_mask_get_filter (mask) != filter ||
      gimp_item_get_image (GIMP_ITEM (mask)) != image ||
      (guint32) gimp_item_get_width (GIMP_ITEM (mask)) != width ||
      (guint32) gimp_item_get_height (GIMP_ITEM (mask)) != height)
    return FALSE;
  GimpContainer *filters = gimp_drawable_get_filters (GIMP_DRAWABLE (mask));
  if (!GIMP_IS_LIST (filters)) return FALSE;
  for (GList *it = GIMP_LIST (filters)->queue->head; it; it = it->next)
    if (GIMP_IS_DRAWABLE_FILTER (it->data) && !gimp_drawable_filter_get_temporary (it->data))
      return FALSE; /* Nested effect-mask effects are outside the decoder. */
  return TRUE;
}

static gboolean
effect_matches (GimpImage *image, GimpDrawableFilter *filter,
                const GlimsXcfEffectFieldsRecord *record, Target *target)
{
  const guint32 known = GLIMS_XCF_FIELD_BLEND_SPACE | GLIMS_XCF_FIELD_COMPOSITE_SPACE |
    GLIMS_XCF_FIELD_COMPOSITE_MODE | GLIMS_XCF_FIELD_PAINT_MODE | GLIMS_XCF_FIELD_OPACITY |
    GLIMS_XCF_FIELD_VISIBLE | GLIMS_XCF_FIELD_CLIP | GLIMS_XCF_FIELD_REGION;
  GeglNode *node = gimp_drawable_filter_get_operation (filter);
  if (!record || (record->presence & ~known) || !node || !gegl_node_get_gegl_operation (node) ||
      !record->operation || !*record->operation ||
      g_strcmp0 (record->operation, gegl_node_get_operation (node)) ||
      g_strcmp0 (record->operation_version, gegl_operation_get_op_version (record->operation)))
    return FALSE;
  const gchar *name = record->name && *record->name ? record->name
    : gegl_operation_get_key (record->operation, "title");
  const gchar *icon = record->icon ? record->icon : "gimp-gegl";
  if (g_strcmp0 (name, gimp_object_get_name (GIMP_OBJECT (filter))) ||
      g_strcmp0 (icon, gimp_viewable_get_icon_name (GIMP_VIEWABLE (filter))) ||
      !mask_matches (image, filter, record))
    return FALSE;

  GimpLayerMode mode = gimp_drawable_filter_get_paint_mode (filter);
  if (!enum_valid (GIMP_TYPE_LAYER_MODE, mode)) return FALSE;
  if (record->presence & GLIMS_XCF_FIELD_PAINT_MODE) {
    if (!enum_valid (GIMP_TYPE_LAYER_MODE, record->paint_mode)) return FALSE;
    GimpLayerMode saved = record->paint_mode;
    if (saved == GIMP_LAYER_MODE_OVERLAY_LEGACY) saved = GIMP_LAYER_MODE_SOFTLIGHT_LEGACY;
    if (saved != mode) return FALSE;
  }
  if ((record->presence & GLIMS_XCF_FIELD_OPACITY) &&
      (!isfinite (record->opacity) || record->opacity < 0 || record->opacity > 1 ||
       record->opacity != (gfloat) gimp_drawable_filter_get_opacity (filter)))
    return FALSE;
  if ((record->presence & GLIMS_XCF_FIELD_VISIBLE) &&
      (record->visible > 1 || record->visible != (guint32) gimp_filter_get_active (GIMP_FILTER (filter))))
    return FALSE;
  if ((record->presence & GLIMS_XCF_FIELD_CLIP) &&
      (record->clip > 1 || record->clip != (guint32) gimp_drawable_filter_get_clip (filter)))
    return FALSE;
  if ((record->presence & GLIMS_XCF_FIELD_REGION) &&
      (!enum_valid (GIMP_TYPE_FILTER_REGION, record->region) ||
       record->region != (gint) gimp_drawable_filter_get_region (filter)))
    return FALSE;

  gint blend = gimp_drawable_filter_get_blend_space (filter);
  gint composite = gimp_drawable_filter_get_composite_space (filter);
  gint combination = gimp_drawable_filter_get_composite_mode (filter);
  if (!enum_valid (GIMP_TYPE_LAYER_COLOR_SPACE, blend) ||
      !enum_valid (GIMP_TYPE_LAYER_COLOR_SPACE, composite) ||
      !enum_valid (GIMP_TYPE_LAYER_COMPOSITE_MODE, combination)) return FALSE;
  if (writer_omitted_fields (record, blend, composite, combination)) {
    *target = (Target) { filter, mode, blend, composite, combination };
    return TRUE;
  }
  if ((record->presence & GLIMS_XCF_FIELD_BLEND_SPACE) &&
      !resolve_field (record->blend_space, GIMP_TYPE_LAYER_COLOR_SPACE,
                     gimp_layer_mode_get_blend_space (mode), GIMP_LAYER_COLOR_SPACE_AUTO, &blend))
    return FALSE;
  if ((record->presence & GLIMS_XCF_FIELD_COMPOSITE_SPACE) &&
      !resolve_field (record->composite_space, GIMP_TYPE_LAYER_COLOR_SPACE,
                     gimp_layer_mode_get_composite_space (mode), GIMP_LAYER_COLOR_SPACE_AUTO, &composite))
    return FALSE;
  if ((record->presence & GLIMS_XCF_FIELD_COMPOSITE_MODE) &&
      !resolve_field (record->composite_mode, GIMP_TYPE_LAYER_COMPOSITE_MODE,
                     gimp_layer_mode_get_composite_mode (mode), GIMP_LAYER_COMPOSITE_AUTO, &combination))
    return FALSE;
  *target = (Target) { filter, mode, blend, composite, combination };
  return TRUE;
}

typedef const GlimsXcfEffectFieldsRecord * (*EffectAt) (const GlimsXcfEffectFields *, guint, guint);

static gboolean
append_targets (GimpImage *image, GimpDrawable *drawable,
                const GlimsXcfEffectFields *fields, guint index,
                guint expected, EffectAt record_at, GArray *targets)
{
  GimpContainer *filters = gimp_drawable_get_filters (drawable);
  if (!GIMP_IS_LIST (filters)) return FALSE;
  guint effect = 0;
  /* Native XCF writes queue-head order, prepends decoded FilterData, then
   * commits each reversed entry at the stack head, restoring that order. */
  for (GList *it = GIMP_LIST (filters)->queue->head; it; it = it->next) {
    if (!GIMP_IS_DRAWABLE_FILTER (it->data) || gimp_drawable_filter_get_temporary (it->data)) continue;
    Target target;
    if (effect >= expected || targets->len >= GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS ||
        gimp_drawable_filter_get_drawable (it->data) != drawable ||
        !effect_matches (image, it->data, record_at (fields, index, effect), &target))
      return FALSE;
    g_array_append_val (targets, target);
    effect++;
  }
  return effect == expected;
}

static guint32
layer_kind (GimpLayer *layer)
{
  guint32 flags = 0;
  if (GIMP_IS_GROUP_LAYER (layer)) flags |= GLIMS_XCF_LAYER_GROUP;
  if (GIMP_IS_TEXT_LAYER (layer)) flags |= GLIMS_XCF_LAYER_TEXT;
#if GIMP_CHECK_VERSION (3, 2, 0)
  if (GIMP_IS_VECTOR_LAYER (layer)) flags |= GLIMS_XCF_LAYER_VECTOR;
  if (GIMP_IS_LINK_LAYER (layer)) flags |= GLIMS_XCF_LAYER_LINK;
#endif
  return flags;
}

static gboolean
layer_path_matches (GimpItem *item, const GArray *saved)
{
  if (!saved) return gimp_item_get_parent (item) == NULL;
  GList *path = gimp_item_get_path (item);
  gboolean same = g_list_length (path) == saved->len;
  guint i = 0;
  for (GList *it = path; same && it; it = it->next, i++)
    same = GPOINTER_TO_UINT (it->data) == g_array_index (saved, guint32, i);
  g_list_free (path);
  return same;
}

static gboolean
channel_matches (GimpChannel *channel, const GlimsXcfChannelFields *saved,
                 gboolean normalized_name)
{
  return channel && saved &&
    (!saved->has_tattoo || saved->tattoo == gimp_item_get_tattoo (GIMP_ITEM (channel))) &&
    saved->width == (guint32) gimp_item_get_width (GIMP_ITEM (channel)) &&
    saved->height == (guint32) gimp_item_get_height (GIMP_ITEM (channel)) &&
    (normalized_name || !g_strcmp0 (saved->name, gimp_object_get_name (GIMP_OBJECT (channel))));
}

GlimsStatus
glims_foreign_effect_fields_restore (GimpImage *image, const GlimsXcfEffectFields *fields, char **error)
{
  if (error) *error = NULL;
  if (!GIMP_IS_IMAGE (image) || !fields)
    return refuse (error, "The foreign XCF effect metadata has no matching loaded image.");
  const GlimsXcfImageFields *saved = glims_xcf_effect_fields_image (fields);
  if (!saved || saved->version < 22 || saved->version > 26 ||
      saved->base_type > G_MAXINT || saved->precision > G_MAXINT ||
      !enum_valid (GIMP_TYPE_IMAGE_BASE_TYPE, (gint) saved->base_type) ||
      !enum_valid (GIMP_TYPE_PRECISION, (gint) saved->precision) ||
      saved->width != (guint32) gimp_image_get_width (image) ||
      saved->height != (guint32) gimp_image_get_height (image) ||
      saved->base_type != (guint32) gimp_image_get_base_type (image) ||
      saved->precision != (guint32) gimp_image_get_precision (image))
    return refuse (error, "The foreign XCF image dimensions, color model or precision do not match its metadata.");
  if (gimp_image_get_floating_selection (image))
    return refuse (error, "Resolve the floating selection before preserving this file's effect settings.");
  guint count = glims_xcf_effect_fields_layer_count (fields);
  GList *layers = gimp_image_get_layer_list (image);
  GArray *targets = g_array_new (FALSE, FALSE, sizeof (Target));
  GlimsStatus status = GLIMS_STATUS_UNSUPPORTED;
  if (count > GLIMS_XCF_EFFECT_FIELDS_MAX_RECORDS || g_list_length (layers) != count) {
    refuse (error, "The foreign XCF's loaded layer count does not match its metadata."); goto done;
  }
  guint index = 0;
  for (GList *it = layers; it; it = it->next, index++) {
    GimpObject *object = it->data;
    const GlimsXcfLayerFields *layer = glims_xcf_effect_fields_layer (fields, index);
    if (!GIMP_IS_LAYER (object) || !layer ||
        (layer->has_tattoo && layer->tattoo != gimp_item_get_tattoo (GIMP_ITEM (object))) ||
        g_strcmp0 (layer->name, gimp_object_get_name (object)) ||
        layer->kind_flags != layer_kind (GIMP_LAYER (object)) ||
        !layer_path_matches (GIMP_ITEM (object), glims_xcf_effect_fields_layer_item_path (fields, index)) ||
        layer->width != (guint32) gimp_item_get_width (GIMP_ITEM (object)) ||
        layer->height != (guint32) gimp_item_get_height (GIMP_ITEM (object)) ||
        layer->xcf_type > G_MAXINT || !enum_valid (GIMP_TYPE_IMAGE_TYPE, (gint) layer->xcf_type) ||
        layer->xcf_type != (guint32) gimp_babl_format_get_image_type (gimp_drawable_get_format (GIMP_DRAWABLE (object)))) {
      refuse (error, "A foreign XCF layer's order, type, name, tattoo or dimensions do not match the loaded image."); goto done;
    }
    if (!append_targets (image, GIMP_DRAWABLE (object), fields, index,
                          glims_xcf_effect_fields_effect_count (fields, index),
                          glims_xcf_effect_fields_effect, targets)) {
      refuse (error, "A foreign XCF effect's order, operation, unchanged settings or mask do not match the loaded image."); goto done;
    }
    GimpLayerMask *mask = gimp_layer_get_mask (GIMP_LAYER (object));
    const GlimsXcfChannelFields *mask_fields = glims_xcf_effect_fields_layer_mask (fields, index);
    /* Native set_layer gives masks the localized owner's name, retaining
     * the raw tattoo/dimensions. Compare the owner rather than that name. */
    if ((mask != NULL) != (mask_fields != NULL) ||
        (mask && (gimp_layer_mask_get_layer (mask) != GIMP_LAYER (object) ||
          !channel_matches (GIMP_CHANNEL (mask), mask_fields, TRUE) ||
          !append_targets (image, GIMP_DRAWABLE (mask), fields, index,
                           glims_xcf_effect_fields_layer_mask_effect_count (fields, index),
                           glims_xcf_effect_fields_layer_mask_effect, targets)))) {
      refuse (error, "A foreign XCF layer mask or its effects do not match the loaded image."); goto done;
    }
  }
  GimpContainer *channels = gimp_image_get_channels (image);
  guint channel_index = 0;
  gboolean saw_selection = FALSE;
  for (guint i = 0; i < glims_xcf_effect_fields_channel_count (fields); i++) {
    const GlimsXcfChannelFields *record = glims_xcf_effect_fields_channel (fields, i);
    GimpChannel *channel = NULL;
    if (record && record->is_selection) {
      if (saw_selection) { refuse (error, "The foreign XCF contains duplicate selection records."); goto done; }
      saw_selection = TRUE;
      channel = gimp_image_get_mask (image);
    } else if (channel_index < (guint) gimp_container_get_n_children (channels))
      channel = GIMP_CHANNEL (gimp_container_get_child_by_index (channels, channel_index++));
    if (!channel_matches (channel, record, record && record->is_selection) ||
        !append_targets (image, GIMP_DRAWABLE (channel), fields, i,
                          glims_xcf_effect_fields_channel_effect_count (fields, i),
                          glims_xcf_effect_fields_channel_effect, targets)) {
      refuse (error, "A foreign XCF channel or its effects do not match the loaded image."); goto done;
    }
  }
  if (channel_index != (guint) gimp_container_get_n_children (channels)) {
    refuse (error, "The foreign XCF's loaded channel count does not match its metadata."); goto done;
  }

  /* No setter runs until every layer/effect has validated. The native setter
   * has no failure path and pushes no Undo; retain the loaded paint mode. */
  for (guint i = 0; i < targets->len; i++) {
    const Target *target = &g_array_index (targets, Target, i);
    gimp_drawable_filter_set_mode (target->filter, target->paint_mode,
                                   target->blend_space, target->composite_space,
                                   target->composite_mode);
  }
  status = GLIMS_STATUS_OK;
done:
  g_list_free (layers);
  g_array_unref (targets);
  return status;
}

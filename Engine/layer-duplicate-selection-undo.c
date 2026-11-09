/* Selection-only companion to the native layer-add group. Construct-time
 * weak snapshots make the final multi-selection survive group Redo. */
#include "engine-private.h"
#include "layer-duplicate-selection-undo.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpobject.h"
#include "core/gimpundo.h"

typedef struct { guint count; GWeakRef *items; } SelectionSnapshot;
typedef struct { GimpUndo parent_instance; SelectionSnapshot before, after; } GlimsLayerSelectionUndo;
typedef struct { GimpUndoClass parent_class; } GlimsLayerSelectionUndoClass;

#define GLIMS_TYPE_LAYER_SELECTION_UNDO (glims_layer_selection_undo_get_type ())
#define SELECTION_UNDO(obj) ((GlimsLayerSelectionUndo *) (obj))
G_DEFINE_TYPE (GlimsLayerSelectionUndo, glims_layer_selection_undo, GIMP_TYPE_UNDO)
enum { PROP_0, PROP_BEFORE, PROP_AFTER };

static void
snapshot_clear (SelectionSnapshot *snapshot)
{
  for (guint i = 0; i < snapshot->count; i++)
    g_weak_ref_clear (&snapshot->items[i]);
  g_clear_pointer (&snapshot->items, g_free);
  snapshot->count = 0;
}

static void
snapshot_copy (SelectionSnapshot *snapshot, GPtrArray *layers)
{
  snapshot_clear (snapshot);
  if (!layers || !layers->len) return;
  snapshot->count = layers->len;
  /* Every GWeakRef has a fixed address from initialization to clear. */
  snapshot->items = g_new0 (GWeakRef, snapshot->count);
  for (guint i = 0; i < snapshot->count; i++)
    g_weak_ref_init (&snapshot->items[i], g_ptr_array_index (layers, i));
}

static void
selection_pop (GimpUndo *undo, GimpUndoMode mode, GimpUndoAccumulator *accum)
{
  GlimsLayerSelectionUndo *self = SELECTION_UNDO (undo);
  SelectionSnapshot *snapshot = mode == GIMP_UNDO_MODE_UNDO ? &self->before : &self->after;
  GList *layers = NULL;
  GIMP_UNDO_CLASS (glims_layer_selection_undo_parent_class)->pop (undo, mode, accum);
  for (guint i = 0; i < snapshot->count; i++) {
    GObject *object = g_weak_ref_get (&snapshot->items[i]);
    if (!object) continue;
    if (GIMP_IS_LAYER (object) && gimp_item_get_image (GIMP_ITEM (object)) == undo->image &&
        gimp_item_is_attached (GIMP_ITEM (object)))
      layers = g_list_prepend (layers, object);
    else
      g_object_unref (object);
  }
  layers = g_list_reverse (layers);
  /* Core compares membership without order. Match edit.c's established
   * selection policy: clear only for a reorder of the same live members. */
  {
    GList *current = gimp_image_get_selected_layers (undo->image);
    if (g_list_length (layers) > 1 && g_list_length (current) == g_list_length (layers)) {
      GHashTable *members = g_hash_table_new (g_direct_hash, g_direct_equal);
      gboolean same_members = TRUE, same_order = TRUE;
      for (GList *it = layers; it; it = it->next) g_hash_table_add (members, it->data);
      for (GList *it = current, *next = layers; it; it = it->next, next = next->next) {
        if (!g_hash_table_contains (members, it->data)) same_members = FALSE;
        if (it->data != next->data) same_order = FALSE;
      }
      if (same_members && !same_order && !gimp_image_get_floating_selection (undo->image))
        gimp_image_set_selected_layers (undo->image, NULL);
      g_hash_table_unref (members);
    }
  }
  gimp_image_set_selected_layers (undo->image, layers);
  /* These nodes and temporary strong references are ours. Native getter
   * lists elsewhere are borrowed and are never freed by this helper. */
  g_list_free_full (layers, g_object_unref);
}

static void
selection_free (GimpUndo *undo, GimpUndoMode mode)
{
  GlimsLayerSelectionUndo *self = SELECTION_UNDO (undo);
  snapshot_clear (&self->before); snapshot_clear (&self->after);
  GIMP_UNDO_CLASS (glims_layer_selection_undo_parent_class)->free (undo, mode);
}

static void
selection_finalize (GObject *object)
{
  GlimsLayerSelectionUndo *self = SELECTION_UNDO (object);
  snapshot_clear (&self->before); snapshot_clear (&self->after);
  G_OBJECT_CLASS (glims_layer_selection_undo_parent_class)->finalize (object);
}

static gint64
selection_memsize (GimpObject *object, gint64 *gui_size)
{
  GlimsLayerSelectionUndo *self = SELECTION_UNDO (object);
  /* Parent accounting includes the actual subclass instance shell. Weak
   * references retain no item payload; only our fixed arrays are added. */
  gint64 count = (gint64) self->before.count + (gint64) self->after.count;
  return GIMP_OBJECT_CLASS (glims_layer_selection_undo_parent_class)->get_memsize (object, gui_size)
         + count * (gint64) sizeof (GWeakRef);
}

static void
selection_set_property (GObject *object, guint id, const GValue *value, GParamSpec *pspec)
{
  GlimsLayerSelectionUndo *self = SELECTION_UNDO (object);
  switch (id) {
  case PROP_BEFORE: snapshot_copy (&self->before, g_value_get_boxed (value)); break;
  case PROP_AFTER: snapshot_copy (&self->after, g_value_get_boxed (value)); break;
  default: G_OBJECT_WARN_INVALID_PROPERTY_ID (object, id, pspec); break;
  }
}

static void
glims_layer_selection_undo_class_init (GlimsLayerSelectionUndoClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  GimpUndoClass *undo_class = GIMP_UNDO_CLASS (klass);
  object_class->set_property = selection_set_property;
  object_class->finalize = selection_finalize;
  GIMP_OBJECT_CLASS (klass)->get_memsize = selection_memsize;
  undo_class->pop = selection_pop;
  undo_class->free = selection_free;
  g_object_class_install_property (object_class, PROP_BEFORE,
    g_param_spec_boxed ("before-layers", NULL, NULL, G_TYPE_PTR_ARRAY,
      G_PARAM_WRITABLE | G_PARAM_CONSTRUCT_ONLY | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (object_class, PROP_AFTER,
    g_param_spec_boxed ("after-layers", NULL, NULL, G_TYPE_PTR_ARRAY,
      G_PARAM_WRITABLE | G_PARAM_CONSTRUCT_ONLY | G_PARAM_STATIC_STRINGS));
}

static void
glims_layer_selection_undo_init (GlimsLayerSelectionUndo *self) { (void) self; }

static gboolean
valid_layers (GimpImage *image, GPtrArray *layers)
{
  if (!layers) return FALSE;
  for (guint i = 0; i < layers->len; i++) {
    GimpItem *item = g_ptr_array_index (layers, i);
    if (!GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image || !gimp_item_is_attached (item)) return FALSE;
    for (guint j = 0; j < i; j++)
      if (g_ptr_array_index (layers, j) == item) return FALSE;
  }
  return TRUE;
}

GimpUndo *
glims_layer_duplicate_selection_undo_push (GimpImage *image, GPtrArray *before, GPtrArray *after)
{
  if (!GIMP_IS_IMAGE (image) || !valid_layers (image, before) ||
      !valid_layers (image, after) || !after->len || !gimp_image_undo_is_enabled (image)) return NULL;
  /* Like item-sets-undo.c, the metadata category accepts this custom
   * GimpUndo subtype. NONE adds no dirty step; the outer layer-add group
   * owns structure accounting. Both snapshots exist before notifications
   * or history expiry can observe the newly constructed record. */
  return gimp_image_undo_push (image, GLIMS_TYPE_LAYER_SELECTION_UNDO,
    GIMP_UNDO_IMAGE_METADATA, "Duplicate layer selection", GIMP_DIRTY_NONE,
    "before-layers", before, "after-layers", after, NULL);
}

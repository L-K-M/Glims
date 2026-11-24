/*
 * Clipping groups: Layer > Group with Previous, Ungroup and Merge Group.
 * Runs on the engine thread.
 *
 * A clipping group is the model GIMP's own PSD loader builds: a layer
 * group whose bottom child is the base and whose other children carry
 * GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP (plug-ins/file-psd/psd-load.c
 * add_clipping_group). The group itself is in normal mode, so its content
 * composites over transparency inside the group and a clipped child sees
 * only the group's own pixels, the base. The facade owns the role report
 * (slot 259) and the three commands (slot 260).
 *
 * Composite facts this file relies on, from
 * app/operations/layer-modes/gimpoperationlayermode-composite.c: the
 * clip-to-backdrop composite writes out[ALPHA] = in[ALPHA] and blends the
 * layer's own result into the backdrop, so a clipped layer keeps the
 * base's alpha while its opacity and blend mode still apply.
 */
#include "engine-private.h"

#include <string.h>

#include "operations/operations-enums.h"
#include "operations/layer-modes/gimp-layer-modes.h"

#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-merge.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpitemstack.h"
#include "core/gimplayer.h"
#include "core/gimpobject.h"
#include "core/gimpviewable.h"

#include "gimp-intl.h"

typedef struct {
  GlimsLayerClipping *rows;
  int32_t             capacity;
  int32_t             count;
} ClippingWalk;

/* The group's bottom child when `group` is a clipping group, else NULL.
 * A clipping group is a normal-mode layer group whose bottom child is a
 * non-group layer with a composite mode other than CLIP_TO_BACKDROP and
 * with at least one other child in CLIP_TO_BACKDROP. */
static GimpLayer *
clipping_group_base (GimpLayer *group)
{
  GimpContainer *children;
  GimpLayer     *bottom;
  gint           n;

  if (! GIMP_IS_GROUP_LAYER (group))
    return NULL;
  if (gimp_layer_get_mode (group) != GIMP_LAYER_MODE_NORMAL)
    return NULL;

  children = gimp_viewable_get_children (GIMP_VIEWABLE (group));
  if (! children)
    return NULL;
  n = gimp_container_get_n_children (children);
  if (n < 2)
    return NULL;

  bottom = GIMP_LAYER (gimp_container_get_child_by_index (children, n - 1));
  if (! bottom || GIMP_IS_GROUP_LAYER (bottom))
    return NULL;
  if (gimp_layer_get_composite_mode (bottom) == GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP)
    return NULL;

  for (gint i = 0; i < n - 1; i++)
    {
      GimpLayer *child = GIMP_LAYER (gimp_container_get_child_by_index (children, i));

      if (child && gimp_layer_get_composite_mode (child) == GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP)
        return bottom;
    }

  return NULL;
}

static void
walk_clipping (GimpContainer *container,
               GimpLayer      *parent,
               ClippingWalk   *walk)
{
  GList *iter;

  for (iter = gimp_item_stack_get_item_iter (GIMP_ITEM_STACK (container)); iter; iter = iter->next)
    {
      GimpLayer *layer = iter->data;
      GimpLayer *group = NULL;
      GimpLayer *base  = NULL;
      uint32_t   role  = GLIMS_CLIPPING_NONE;

      if (clipping_group_base (layer))
        {
          role  = GLIMS_CLIPPING_GROUP;
          group = layer;
          base  = clipping_group_base (layer);
        }
      else if (parent && clipping_group_base (parent))
        {
          group = parent;
          base  = clipping_group_base (parent);
          if (layer == base)
            role = GLIMS_CLIPPING_BASE;
          else if (gimp_layer_get_composite_mode (layer) == GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP)
            role = GLIMS_CLIPPING_CLIPPED;
          else
            group = base = NULL;
        }

      if (walk->count < walk->capacity && walk->rows &&
          walk->rows[walk->count].struct_size >= sizeof (GlimsLayerClipping))
        {
          GlimsLayerClipping *row = &walk->rows[walk->count];

          memset (row, 0, sizeof (*row));
          row->struct_size = sizeof (*row);
          row->layer       = gimp_item_get_id (GIMP_ITEM (layer));
          row->role        = role;
          row->base        = base ? gimp_item_get_id (GIMP_ITEM (base)) : 0;
          row->group       = group ? gimp_item_get_id (GIMP_ITEM (group)) : 0;
        }
      walk->count++;

      if (GIMP_IS_GROUP_LAYER (layer))
        walk_clipping (gimp_viewable_get_children (GIMP_VIEWABLE (layer)), layer, walk);
    }
}

GlimsStatus
glims_image_layer_clipping (GlimsEngine       *engine,
                            GlimsImageID       id,
                            GlimsLayerClipping *rows,
                            int32_t            capacity,
                            int32_t           *count)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  ClippingWalk    walk;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  walk.rows     = rows;
  walk.capacity = rows ? capacity : 0;
  walk.count    = 0;
  walk_clipping (gimp_image_get_layers (open->image), NULL, &walk);
  *count = walk.count;

  return GLIMS_STATUS_OK;
}

/* The image, its ordinary layout and a quiet engine, for every command. */
static GlimsStatus
clipping_admission (GlimsEngine   *engine,
                    GlimsOpenImage *open,
                    uint32_t        command,
                    char          **error)
{
  if (command < GLIMS_CLIPPING_GROUP_WITH_PREVIOUS ||
      command > GLIMS_CLIPPING_MERGE_GROUP)
    {
      if (error) *error = g_strdup ("Unknown clipping command.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (open->component_layout != GLIMS_COMPONENT_LAYOUT_ORDINARY)
    {
      if (error) *error = g_strdup ("Clipping groups are available for ordinary layered images only.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (glims_edit_ready (engine, open, error) != GLIMS_STATUS_OK)
    return GLIMS_STATUS_BUSY;
  if (gimp_image_get_floating_selection (open->image))
    {
      if (error) *error = g_strdup ("Anchor or cancel the floating selection before changing clipping groups.");
      return GLIMS_STATUS_BUSY;
    }
  if (! gimp_image_undo_is_enabled (open->image) ||
      gimp_image_get_undo_group_count (open->image))
    {
      if (error) *error = g_strdup ("Finish the current edit and enable Undo before changing clipping groups.");
      return GLIMS_STATUS_BUSY;
    }
  if (gimp_image_get_base_type (open->image) == GIMP_INDEXED)
    {
      if (error) *error = g_strdup ("Convert the image to RGB or grayscale before changing clipping groups.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  return GLIMS_STATUS_OK;
}

/* The layer `id` of `image`, or with 0 the first selected layer. */
static GimpLayer *
find_clipping_layer (GimpImage   *image,
                     GlimsItemID  id)
{
  if (id == 0)
    {
      GList *selected = gimp_image_get_selected_layers (image);
      return selected ? GIMP_LAYER (selected->data) : NULL;
    }

  {
    GimpItem *item = gimp_item_get_by_id (image->gimp, id);

    if (! item || ! GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image ||
        ! gimp_item_is_attached (item))
      return NULL;
    return GIMP_LAYER (item);
  }
}

/* Whether `layer` is a genuine editable text, link or vector layer, as
 * the rasterize admission decides. A rasterized instance reports PIXEL. */
static GlimsStatus
refuse_editable_source (GimpLayer *layer, const char *action, char **error)
{
  switch (glims_layer_kind (layer))
    {
    case GLIMS_LAYER_PIXEL:
      return GLIMS_STATUS_OK;
    case GLIMS_LAYER_GROUP:
      if (error) *error = g_strdup_printf ("A layer group cannot %s.", action);
      return GLIMS_STATUS_FAILED;
    default:
      if (error) *error = g_strdup_printf ("Rasterize the text, link or vector layer before you %s.", action);
      return GLIMS_STATUS_FAILED;
    }
}

/* The clipping group `layer` belongs to, and its base. `layer` may be the
 * group, its base or a clipped child; anything else refuses. */
static gboolean
clipping_membership (GimpLayer  *layer,
                     GimpLayer **group,
                     GimpLayer **base)
{
  GimpLayer *found_group = NULL;
  GimpLayer *found_base  = NULL;

  if (GIMP_IS_GROUP_LAYER (layer) && (found_base = clipping_group_base (layer)))
    found_group = layer;
  else
    {
      GimpLayer *parent = gimp_layer_get_parent (layer);

      if (parent && (found_base = clipping_group_base (parent)))
        found_group = parent;
    }

  if (! found_group)
    return FALSE;
  if (layer != found_group && layer != found_base &&
      gimp_layer_get_composite_mode (layer) != GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP)
    return FALSE;

  *group = found_group;
  *base  = found_base;
  return TRUE;
}

/* Move `child` out of `group` to directly above the group in the group's
 * parent, then reset its composite mode to AUTO. */
static GlimsStatus
release_out_of_group (GimpImage *image,
                      GimpLayer *child,
                      GimpLayer *group,
                      char     **error)
{
  GimpLayer     *parent   = gimp_layer_get_parent (group);
  GimpContainer *siblings = parent ? gimp_viewable_get_children (GIMP_VIEWABLE (parent))
                                   : gimp_image_get_layers (image);
  gint           index;

  index = gimp_container_get_child_index (siblings, GIMP_OBJECT (group));
  if (index < 0)
    {
      if (error) *error = g_strdup ("The clipping group's place in the layer tree was lost.");
      return GLIMS_STATUS_FAILED;
    }
  if (! gimp_image_reorder_item (image, GIMP_ITEM (child), parent ? GIMP_ITEM (parent) : NULL, index, TRUE, NULL))
    {
      if (error) *error = g_strdup ("The released layer could not be moved out of the clipping group.");
      return GLIMS_STATUS_FAILED;
    }
  gimp_layer_set_composite_mode (child, GIMP_LAYER_COMPOSITE_AUTO, TRUE);
  return GLIMS_STATUS_OK;
}

/* Move `base` out to the group's own position and remove the empty group. */
static GlimsStatus
dissolve_empty_group (GimpImage *image,
                      GimpLayer *group,
                      GimpLayer *base,
                      char     **error)
{
  GimpLayer     *parent   = gimp_layer_get_parent (group);
  GimpContainer *siblings = parent ? gimp_viewable_get_children (GIMP_VIEWABLE (parent))
                                   : gimp_image_get_layers (image);
  gint           index;

  index = gimp_container_get_child_index (siblings, GIMP_OBJECT (group));
  if (index < 0)
    {
      if (error) *error = g_strdup ("The clipping group's place in the layer tree was lost.");
      return GLIMS_STATUS_FAILED;
    }
  if (! gimp_image_reorder_item (image, GIMP_ITEM (base), parent ? GIMP_ITEM (parent) : NULL, index, TRUE, NULL))
    {
      if (error) *error = g_strdup ("The base layer could not be moved out of the clipping group.");
      return GLIMS_STATUS_FAILED;
    }
  gimp_image_remove_layer (image, group, TRUE, NULL);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
group_with_previous (GlimsEngine *engine,
                     GimpImage   *image,
                     GimpLayer   *layer,
                     GlimsItemID *result,
                     char       **error)
{
  GimpLayer     *parent;
  GimpContainer *siblings;
  GimpLayer     *base = NULL;
  GimpLayer     *base_group = NULL;
  GimpLayer     *group = NULL;
  gint           index, n, target;
  GList         *selected;
  GlimsStatus    status;

  (void) engine;
  if (result) *result = 0;

  parent   = gimp_layer_get_parent (layer);
  siblings = parent ? gimp_viewable_get_children (GIMP_VIEWABLE (parent))
                    : gimp_image_get_layers (image);
  n        = gimp_container_get_n_children (siblings);
  index    = gimp_container_get_child_index (siblings, GIMP_OBJECT (layer));
  if (index < 0 || index + 1 >= n)
    {
      if (error) *error = g_strdup ("There is no layer below to clip to.");
      return GLIMS_STATUS_FAILED;
    }
  base = GIMP_LAYER (gimp_container_get_child_by_index (siblings, index + 1));

  status = refuse_editable_source (layer, "be clipped", error);
  if (status != GLIMS_STATUS_OK) return status;
  /* Directly above a clipping group, the layer joins that group above its
   * top clipped layer, as the classic command extends a clip. */
  if (clipping_group_base (base))
    {
      base_group = base;
      base = NULL;
    }
  else
    {
      status = refuse_editable_source (base, "clip another layer", error);
      if (status != GLIMS_STATUS_OK) return status;
    }

  if (gimp_layer_get_composite_mode (layer) == GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP)
    {
      if (error) *error = g_strdup ("The layer is already clipped.");
      return GLIMS_STATUS_FAILED;
    }
  if (! gimp_layer_mode_is_composite_mode_mutable (gimp_layer_get_mode (layer)))
    {
      if (error) *error = g_strdup ("This layer's blend mode cannot be clipped.");
      return GLIMS_STATUS_FAILED;
    }

  status = glims_check_item_locks (GIMP_ITEM (layer), GLIMS_LOCK_POSITION, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = glims_check_item_locks (GIMP_ITEM (base ? base : base_group), GLIMS_LOCK_POSITION, error);
  if (status != GLIMS_STATUS_OK) return status;

  if (base && GIMP_IS_GROUP_LAYER (gimp_layer_get_parent (base)) &&
      clipping_group_base (gimp_layer_get_parent (base)))
    base_group = gimp_layer_get_parent (base);

  selected = g_list_copy (gimp_image_get_selected_layers (image));

  if (! gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_IMAGE_ITEM_REORDER, "Group with Previous"))
    {
      g_list_free (selected);
      if (error) *error = g_strdup ("The image history could not group the clipping change.");
      return GLIMS_STATUS_FAILED;
    }

  if (base_group)
    {
      /* The base or a clipped child of a clipping group: move the layer
       * into that group directly above the base. */
      GimpContainer *group_children = gimp_viewable_get_children (GIMP_VIEWABLE (base_group));
      gint           base_index  = base ? gimp_container_get_child_index (group_children, GIMP_OBJECT (base)) : 0;
      gint           layer_index = gimp_container_get_child_index (group_children, GIMP_OBJECT (layer));

      /* Above the layer below it, or at the top when joining from outside. */
      target = base_index;
      if (layer_index >= 0 && layer_index < base_index)
        target = base_index - 1;
      if (! gimp_image_reorder_item (image, GIMP_ITEM (layer), GIMP_ITEM (base_group),
                                     target, TRUE, NULL))
        {
          gimp_image_undo_group_end (image);
          g_list_free (selected);
          if (error) *error = g_strdup ("The layer could not be moved into the clipping group.");
          return GLIMS_STATUS_FAILED;
        }
      group = base_group;
    }
  else
    {
      /* A fresh group at the base's position, the base at its bottom and
       * the layer above it. */
      GimpLayer     *base_parent   = gimp_layer_get_parent (base);
      GimpContainer *base_siblings = base_parent ? gimp_viewable_get_children (GIMP_VIEWABLE (base_parent))
                                                 : gimp_image_get_layers (image);
      gint           base_index    = gimp_container_get_child_index (base_siblings, GIMP_OBJECT (base));

      group = gimp_group_layer_new (image);
      if (! group)
        {
          gimp_image_undo_group_end (image);
          g_list_free (selected);
          if (error) *error = g_strdup ("The clipping group could not be created.");
          return GLIMS_STATUS_FAILED;
        }
      gimp_layer_set_mode (group, GIMP_LAYER_MODE_NORMAL, FALSE);
      if (! gimp_item_rename (GIMP_ITEM (group), "Clipping Group", NULL))
        {
          g_object_unref (group);
          gimp_image_undo_group_end (image);
          g_list_free (selected);
          if (error) *error = g_strdup ("The clipping group could not be named.");
          return GLIMS_STATUS_FAILED;
        }
      if (! gimp_image_add_layer (image, group, base_parent, base_index, TRUE))
        {
          g_object_unref (group);
          gimp_image_undo_group_end (image);
          g_list_free (selected);
          if (error) *error = g_strdup ("The clipping group could not be added.");
          return GLIMS_STATUS_FAILED;
        }
      if (! gimp_image_reorder_item (image, GIMP_ITEM (base), GIMP_ITEM (group), 0, TRUE, NULL))
        {
          gimp_image_undo_group_end (image);
          g_list_free (selected);
          if (error) *error = g_strdup ("The base layer could not be moved into the clipping group.");
          return GLIMS_STATUS_FAILED;
        }
      if (! gimp_image_reorder_item (image, GIMP_ITEM (layer), GIMP_ITEM (group), 0, TRUE, NULL))
        {
          gimp_image_undo_group_end (image);
          g_list_free (selected);
          if (error) *error = g_strdup ("The layer could not be moved into the clipping group.");
          return GLIMS_STATUS_FAILED;
        }
    }

  gimp_layer_set_composite_mode (layer, GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP, TRUE);

  gimp_image_set_selected_layers (image, selected);
  g_list_free (selected);
  gimp_image_undo_group_end (image);
  gimp_image_flush (image);

  if (result) *result = gimp_item_get_id (GIMP_ITEM (group));
  return GLIMS_STATUS_OK;
}

static GlimsStatus
ungroup (GlimsEngine *engine,
         GimpImage   *image,
         GimpLayer   *layer,
         char       **error)
{
  GimpLayer     *group = NULL;
  GimpLayer     *base  = NULL;
  GimpContainer *children;
  gint           n, layer_index = -1, base_index;
  gint           first_remaining = 0;
  gboolean       release_all;
  gboolean       dissolve;
  GPtrArray     *released;
  GlimsStatus    status;

  (void) engine;
  if (! clipping_membership (layer, &group, &base))
    {
      if (error) *error = g_strdup ("Choose a clipping group, its base or one of its clipped layers.");
      return GLIMS_STATUS_FAILED;
    }

  children = gimp_viewable_get_children (GIMP_VIEWABLE (group));
  n        = gimp_container_get_n_children (children);
  base_index = gimp_container_get_child_index (children, GIMP_OBJECT (base));
  if (base_index < 0)
    {
      if (error) *error = g_strdup ("The clipping group's base layer was lost.");
      return GLIMS_STATUS_FAILED;
    }
  release_all = (layer == group || layer == base);
  if (! release_all)
    layer_index = gimp_container_get_child_index (children, GIMP_OBJECT (layer));

  released = g_ptr_array_new ();
  first_remaining = n;
  for (gint i = 0; i < n - 1; i++)
    {
      GimpLayer *child = GIMP_LAYER (gimp_container_get_child_by_index (children, i));
      gboolean   take  = FALSE;

      if (gimp_layer_get_composite_mode (child) != GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP)
        continue;
      if (release_all)
        take = TRUE;
      else if (i <= layer_index)
        take = TRUE;

      if (take)
        g_ptr_array_add (released, child);
      else if (first_remaining == n)
        first_remaining = i;
    }

  dissolve = (first_remaining == n);
  if (dissolve)
    {
      /* The group would disappear; never take a layer with it that the
       * command does not release. */
      for (gint i = 0; i < n - 1; i++)
        {
          GimpLayer *child = GIMP_LAYER (gimp_container_get_child_by_index (children, i));
          gboolean   is_released = FALSE;

          for (guint j = 0; j < released->len; j++)
            if (g_ptr_array_index (released, j) == child)
              {
                is_released = TRUE;
                break;
              }
          if (! is_released)
            {
              g_ptr_array_free (released, TRUE);
              if (error) *error = g_strdup ("The clipping group has layers that are not clipped to its base.");
              return GLIMS_STATUS_FAILED;
            }
        }
    }

  for (guint j = 0; j < released->len; j++)
    {
      GimpLayer *child = g_ptr_array_index (released, j);

      if (! gimp_layer_mode_is_composite_mode_mutable (gimp_layer_get_mode (child)))
        {
          g_ptr_array_free (released, TRUE);
          if (error) *error = g_strdup ("A clipped layer's blend mode cannot change composite mode.");
          return GLIMS_STATUS_FAILED;
        }
    }

  /* Position locks refuse a move, as they do for Group with Previous:
   * the released layers move, and when the group dissolves its base moves
   * and the group itself goes. Layers that stay put are not checked. */
  for (guint j = 0; j < released->len; j++)
    {
      status = glims_check_item_locks (GIMP_ITEM (g_ptr_array_index (released, j)),
                                       GLIMS_LOCK_POSITION, error);
      if (status != GLIMS_STATUS_OK)
        {
          g_ptr_array_free (released, TRUE);
          return status;
        }
    }
  if (dissolve)
    {
      status = glims_check_item_locks (GIMP_ITEM (base), GLIMS_LOCK_POSITION, error);
      if (status == GLIMS_STATUS_OK)
        status = glims_check_item_locks (GIMP_ITEM (group), GLIMS_LOCK_POSITION, error);
      if (status != GLIMS_STATUS_OK)
        {
          g_ptr_array_free (released, TRUE);
          return status;
        }
    }

  if (! gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_IMAGE_ITEM_REORDER, "Ungroup"))
    {
      g_ptr_array_free (released, TRUE);
      if (error) *error = g_strdup ("The image history could not group the ungroup.");
      return GLIMS_STATUS_FAILED;
    }

  for (guint j = 0; j < released->len; j++)
    {
      GimpLayer *child = g_ptr_array_index (released, j);

      status = release_out_of_group (image, child, group, error);
      if (status != GLIMS_STATUS_OK)
        {
          gimp_image_undo_group_end (image);
          g_ptr_array_free (released, TRUE);
          return status;
        }
    }

  if (dissolve)
    {
      status = dissolve_empty_group (image, group, base, error);
      if (status != GLIMS_STATUS_OK)
        {
          gimp_image_undo_group_end (image);
          g_ptr_array_free (released, TRUE);
          return status;
        }
    }

  g_ptr_array_free (released, TRUE);
  gimp_image_undo_group_end (image);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

static GlimsStatus
merge_group (GlimsEngine *engine,
             GimpImage   *image,
             GimpLayer   *layer,
             GlimsItemID *result,
             char       **error)
{
  GimpLayer     *group = NULL;
  GimpLayer     *base  = NULL;
  GimpLayer     *merged;
  GimpContainer *children;
  gint           n;
  gchar         *base_name;
  GList         *selection;
  GlimsStatus    status;

  (void) engine;
  if (result) *result = 0;

  if (! clipping_membership (layer, &group, &base))
    {
      if (error) *error = g_strdup ("Choose a clipping group or one of its layers.");
      return GLIMS_STATUS_FAILED;
    }

  children = gimp_viewable_get_children (GIMP_VIEWABLE (group));
  n = gimp_container_get_n_children (children);

  /* Any member locked against pixel or position changes refuses. */
  for (gint i = 0; i < n; i++)
    {
      GimpLayer *child = GIMP_LAYER (gimp_container_get_child_by_index (children, i));

      status = glims_check_item_locks (GIMP_ITEM (child),
                                      GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
      if (status != GLIMS_STATUS_OK) return status;
    }
  status = glims_check_item_locks (GIMP_ITEM (group),
                                   GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
  if (status != GLIMS_STATUS_OK) return status;

  base_name = g_strdup (gimp_object_get_name (GIMP_OBJECT (base)));

  if (! gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_IMAGE_LAYERS_MERGE, "Merge Clipping Group"))
    {
      g_free (base_name);
      if (error) *error = g_strdup ("The image history could not group the merged group.");
      return GLIMS_STATUS_FAILED;
    }

  merged = gimp_image_merge_group_layer (image, GIMP_GROUP_LAYER (group));
  if (! merged)
    {
      g_free (base_name);
      gimp_image_undo_group_end (image);
      if (error) *error = g_strdup ("The clipping group could not be merged.");
      return GLIMS_STATUS_FAILED;
    }
  if (! gimp_item_rename (GIMP_ITEM (merged), base_name, NULL))
    {
      g_free (base_name);
      gimp_image_undo_group_end (image);
      if (error) *error = g_strdup ("The merged layer could not take the base layer's name.");
      return GLIMS_STATUS_FAILED;
    }
  g_free (base_name);

  selection = g_list_prepend (NULL, merged);
  gimp_image_set_selected_layers (image, selection);
  g_list_free (selection);

  gimp_image_undo_group_end (image);
  gimp_image_flush (image);

  if (result) *result = gimp_item_get_id (GIMP_ITEM (merged));
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_clipping_edit (GlimsEngine  *engine,
                           GlimsImageID  id,
                           GlimsItemID   layer_id,
                           uint32_t      command,
                           GlimsItemID  *result,
                           char        **error)
{
  GlimsOpenImage *open;
  GimpImage      *image;
  GimpLayer      *layer;
  GlimsStatus     status;

  if (error) *error = NULL;
  if (result) *result = 0;

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  status = clipping_admission (engine, open, command, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  image = open->image;
  layer = find_clipping_layer (image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;

  switch (command)
    {
    case GLIMS_CLIPPING_GROUP_WITH_PREVIOUS:
      return group_with_previous (engine, image, layer, result, error);
    case GLIMS_CLIPPING_UNGROUP:
      return ungroup (engine, image, layer, error);
    case GLIMS_CLIPPING_MERGE_GROUP:
      return merge_group (engine, image, layer, result, error);
    default:
      /* clipping_admission already refused anything else. */
      if (error) *error = g_strdup ("Unknown clipping command.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
}

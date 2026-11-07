/*
 * The layer tree's structure: layer groups, moving layers between
 * groups, and the layers' locks. Runs on the engine thread.
 *
 * Groups are made as GIMP's own New Layer Group command makes them
 * (app/actions/layers-commands.c layers_new_group_cmd_callback):
 * gimp_group_layer_new + gimp_image_add_layer, which selects them and is
 * one undo step. Moving layers goes through gimp_image_reorder_item, the
 * same core function the PDB's reorder and the layer dock's drag use
 * (app/core/gimpimage.c, app/core/gimpitemtree.c); unlike them the facade
 * refuses out-of-range positions instead of clamping them. Lock changes
 * are the native lock setters inside one undo group, the way the layer
 * dock wraps them (app/widgets/gimpitemtreeview.c
 * gimp_item_tree_view_lock_toggled).
 */
#include "engine-private.h"

#include <string.h>

#include "operations/layer-modes/gimp-layer-modes.h"

#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpviewable.h"

#include "gimp-intl.h"

/* The lock bits the facade knows. */
#define GLIMS_LOCK_ALL (GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION | GLIMS_LOCK_ALPHA)

/* The image, if it may be changed now. */
static GimpImage *
writable_image (GlimsEngine  *engine,
                GlimsImageID  id,
                GlimsStatus  *status)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);

  *status = GLIMS_STATUS_OK;
  if (! open)
    *status = GLIMS_STATUS_NOT_FOUND;
  else if (engine->busy > 0)
    *status = GLIMS_STATUS_BUSY;

  return *status == GLIMS_STATUS_OK ? open->image : NULL;
}

/* The layer `id` of `image`, or with 0 the first selected layer. Layer
 * groups are layers too, so this finds them. */
static GimpLayer *
find_layer (GimpImage   *image,
            GlimsItemID  id)
{
  GimpItem *item;

  if (id == 0)
    {
      GList     *selected = gimp_image_get_selected_layers (image);
      GimpLayer *layer    = selected ? selected->data : NULL;

      return layer;
    }

  item = gimp_item_get_by_id (image->gimp, id);
  if (! GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image || ! gimp_item_is_attached (item))
    return NULL;

  return GIMP_LAYER (item);
}

/* A `parent` id of `image`: NULL for the top level, the group for a
 * group id, and `status` says why not for anything else. */
static GimpLayer *
find_parent (GimpImage   *image,
             GlimsItemID  id,
             GlimsStatus *status)
{
  GimpLayer *layer;

  *status = GLIMS_STATUS_OK;
  if (id == 0)
    return NULL;

  layer = find_layer (image, id);
  if (! layer)
    *status = GLIMS_STATUS_NOT_FOUND;
  else if (! GIMP_IS_GROUP_LAYER (layer))
    *status = GLIMS_STATUS_INVALID_ARGUMENT;

  return *status == GLIMS_STATUS_OK ? layer : NULL;
}

GlimsStatus
glims_layer_state (GlimsEngine     *engine,
                   GlimsImageID     id,
                   GlimsItemID      layer_id,
                   GlimsLayerState *state)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpLayer      *layer;
  GimpItem       *item;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! state)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  layer = find_layer (open->image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;
  item = GIMP_ITEM (layer);

  memset (state, 0, sizeof (*state));
  if (gimp_item_get_lock_content (item))
    state->locks |= GLIMS_LOCK_PIXELS;
  if (gimp_item_get_lock_position (item))
    state->locks |= GLIMS_LOCK_POSITION;
  if (gimp_layer_get_lock_alpha (layer))
    state->locks |= GLIMS_LOCK_ALPHA;
  if (gimp_item_is_content_locked (item, NULL))
    state->locked |= GLIMS_LOCK_PIXELS;
  if (gimp_item_is_position_locked (item, NULL))
    state->locked |= GLIMS_LOCK_POSITION;
  if (gimp_layer_is_alpha_locked (layer, NULL))
    state->locked |= GLIMS_LOCK_ALPHA;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_create_group (GlimsEngine  *engine,
                    GlimsImageID  id,
                    GlimsItemID   parent_id,
                    int32_t       index,
                    const char   *name,
                    GlimsItemID  *result,
                    char        **error)
{
  GlimsStatus    status;
  GimpImage     *image = writable_image (engine, id, &status);
  GimpLayer     *parent;
  GimpLayer     *group;
  GimpContainer *children;
  GError        *gerror = NULL;

  if (! image)
    return status;

  parent = find_parent (image, parent_id, &status);
  if (status == GLIMS_STATUS_INVALID_ARGUMENT)
    {
      glims_fail (error, NULL, "The parent is not a layer group.");
      return status;
    }
  if (status != GLIMS_STATUS_OK)
    return status;

  children = parent ? gimp_viewable_get_children (GIMP_VIEWABLE (parent))
                    : gimp_image_get_layers (image);
  if (index < 0 || index > gimp_container_get_n_children (children))
    {
      glims_fail (error, NULL, "The index is out of range.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  group = gimp_group_layer_new (image);
  gimp_layer_set_mode (group, GIMP_LAYER_MODE_PASS_THROUGH, FALSE);
  if (name && *name &&
      ! gimp_item_rename (GIMP_ITEM (group), name, &gerror))
    {
      g_object_unref (group);
      return glims_fail (error, gerror, "The group could not be renamed.");
    }
  if (! gimp_image_add_layer (image, group, parent, index, TRUE))
    {
      g_object_unref (group);
      return glims_fail (error, NULL, "The group could not be added.");
    }
  gimp_image_flush (image);

  if (result)
    *result = gimp_item_get_id (GIMP_ITEM (group));

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_reparent_layer (GlimsEngine  *engine,
                      GlimsImageID  id,
                      GlimsItemID   item_id,
                      GlimsItemID   parent_id,
                      int32_t       index,
                      char        **error)
{
  GlimsStatus    status;
  GimpImage     *image = writable_image (engine, id, &status);
  GimpItem      *item;
  GimpLayer     *parent;
  GimpContainer *children;
  gint           n_items;

  if (! image)
    return status;

  item = (GimpItem *) find_layer (image, item_id);
  if (! item)
    return GLIMS_STATUS_NOT_FOUND;

  parent = find_parent (image, parent_id, &status);
  if (status == GLIMS_STATUS_INVALID_ARGUMENT)
    {
      glims_fail (error, NULL, "The parent is not a layer group.");
      return status;
    }
  if (status != GLIMS_STATUS_OK)
    return status;

  if (item == (GimpItem *) parent ||
      (parent && gimp_viewable_is_ancestor (GIMP_VIEWABLE (item), GIMP_VIEWABLE (parent))))
    {
      glims_fail (error, NULL, "A layer cannot be moved into itself or its own group.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  children = parent ? gimp_viewable_get_children (GIMP_VIEWABLE (parent))
                    : gimp_image_get_layers (image);
  n_items  = gimp_container_get_n_children (children);
  /* A move inside the same container frees the item's own slot first, so
   * one fewer position exists (app/core/gimpitemtree.c
   * gimp_item_tree_reorder_item). */
  if (children == gimp_item_get_container (item))
    n_items--;
  if (index < 0 || index > n_items)
    {
      glims_fail (error, NULL, "The index is out of range.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* Already there: no change and no undo step. */
  if ((GimpItem *) parent == gimp_item_get_parent (item) &&
      index == gimp_item_get_index (item))
    return GLIMS_STATUS_OK;

  if (! gimp_image_reorder_item (image, item, (GimpItem *) parent, index, TRUE, NULL))
    return glims_fail (error, NULL, "The layer could not be moved.");
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_set_layer_locks (GlimsEngine  *engine,
                       GlimsImageID  id,
                       GlimsItemID   item_id,
                       uint32_t      mask,
                       uint32_t      values,
                       char        **error)
{
  GlimsStatus  status;
  GimpImage   *image = writable_image (engine, id, &status);
  GimpLayer   *layer;
  GimpItem    *item;
  GimpUndoType undo_type;
  const gchar *undo_name;
  uint32_t     current, changing;

  if (! image)
    return status;
  if (! mask || mask & ~GLIMS_LOCK_ALL || values & ~GLIMS_LOCK_ALL)
    {
      glims_fail (error, NULL, "The mask names a lock the engine has no bit for.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  layer = find_layer (image, item_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;
  item = GIMP_ITEM (layer);

  current  = gimp_item_get_lock_content (item)   ? GLIMS_LOCK_PIXELS   : 0;
  current |= gimp_item_get_lock_position (item)  ? GLIMS_LOCK_POSITION : 0;
  current |= gimp_layer_get_lock_alpha (layer)   ? GLIMS_LOCK_ALPHA    : 0;
  changing = mask & (current ^ values);

  /* A request that changes nothing adds no undo step; an empty undo
   * group would still be one. */
  if (! changing)
    return GLIMS_STATUS_OK;

  /* One name and undo type per call, as the layer dock's lock toggles
   * use for one lock at a time (app/widgets/gimpitemtreeview.c
   * gimp_item_tree_view_lock_toggled, app/actions/layers-commands.c
   * layers_lock_alpha_cmd_callback); a mixed change is a generic group. */
  undo_name = _("Change layer locks");
  undo_type = GIMP_UNDO_GROUP_MISC;
  if (changing == GLIMS_LOCK_PIXELS)
    {
      undo_type = GIMP_UNDO_GROUP_ITEM_LOCK_CONTENTS;
      undo_name = values & GLIMS_LOCK_PIXELS ? _("Lock content") : _("Unlock content");
    }
  else if (changing == GLIMS_LOCK_POSITION)
    {
      undo_type = GIMP_UNDO_GROUP_ITEM_LOCK_POSITION;
      undo_name = values & GLIMS_LOCK_POSITION ? _("Lock position") : _("Unlock position");
    }
  else if (changing == GLIMS_LOCK_ALPHA)
    {
      undo_type = GIMP_UNDO_GROUP_LAYER_LOCK_ALPHA;
      undo_name = values & GLIMS_LOCK_ALPHA ? _("Lock alpha channels") : _("Unlock alpha channels");
    }

  {
    gboolean group = gimp_image_undo_group_start (image, undo_type, undo_name);

    if (mask & GLIMS_LOCK_PIXELS)
      gimp_item_set_lock_content (item, (values & GLIMS_LOCK_PIXELS) != 0, TRUE);
    if (mask & GLIMS_LOCK_POSITION)
      gimp_item_set_lock_position (item, (values & GLIMS_LOCK_POSITION) != 0, TRUE);
    if (mask & GLIMS_LOCK_ALPHA)
      gimp_layer_set_lock_alpha (layer, (values & GLIMS_LOCK_ALPHA) != 0, TRUE);
    if (group)
      gimp_image_undo_group_end (image);
  }
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

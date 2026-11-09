/* Engine-thread preflight: prepare a batch of layer duplicates without
 * attaching, mutating history, selection or pixels. */
#include "engine-private.h"
#include "layer-duplicate-prepare.h"

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"

#include <stdlib.h>

GlimsStatus
glims_layer_duplicate_prepare (GlimsEngine              *engine,
                              GlimsImageID              image,
                              const GlimsItemID        *sources,
                              size_t                    count,
                              GlimsLayerDuplicatePlan **out,
                              char                    **error)
{
  GlimsOpenImage *open;
  GlimsLayerDuplicatePlan *plan = NULL;
  GimpItem **items = NULL;
  GlimsStatus status;
  size_t i, j;
  if (out)
    *out = NULL;

  /* Argument validation. */
  if (!out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (count > 0 && !sources)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (count == 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (count > 256)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  for (i = 0; i < count; i++)
    if (sources[i] <= 0)
      return GLIMS_STATUS_INVALID_ARGUMENT;
  for (i = 0; i < count; i++)
    for (j = i + 1; j < count; j++)
      if (sources[i] == sources[j])
        return GLIMS_STATUS_INVALID_ARGUMENT;

  open = glims_lookup_image (engine, image);
  if (!open)
    return GLIMS_STATUS_NOT_FOUND;

  items = g_new0 (GimpItem *, count);

  /* Resolve ALL sources before ANY clone. */
  for (i = 0; i < count; i++)
    {
      GimpItem *item = gimp_item_get_by_id (open->image->gimp, sources[i]);

      if (!item)
        {
          status = GLIMS_STATUS_NOT_FOUND;
          goto fail;
        }
      if (gimp_item_get_image (item) != open->image)
        {
          status = GLIMS_STATUS_NOT_FOUND;
          goto fail;
        }
      if (!gimp_item_is_attached (item))
        {
          status = GLIMS_STATUS_NOT_FOUND;
          goto fail;
        }
      if (!GIMP_IS_LAYER (item))
        {
          if (error)
            *error = g_strdup ("The requested item is not an attached layer.");
          status = GLIMS_STATUS_NOT_FOUND;
          goto fail;
        }
      if (G_OBJECT_TYPE (item) != GIMP_TYPE_LAYER)
        {
          status = GLIMS_STATUS_UNSUPPORTED;
          if (error)
            *error = g_strdup ("Group or structured layers cannot be duplicated.");
          goto fail;
        }

      items[i] = item;
    }

  /* Gates. */
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    goto fail;
  if (gimp_image_get_floating_selection (open->image))
    {
      if (error)
        *error = g_strdup ("Resolve the floating selection before duplicating layers.");
      status = GLIMS_STATUS_BUSY;
      goto fail;
    }
  if (!gimp_image_undo_is_enabled (open->image))
    {
      if (error)
        *error = g_strdup ("Layers cannot be duplicated while Undo is disabled.");
      status = GLIMS_STATUS_BUSY;
      goto fail;
    }

  plan = calloc (1, sizeof *plan);
  if (!plan)
    {
      status = GLIMS_STATUS_FAILED;
      if (error)
        *error = g_strdup ("Out of memory.");
      goto fail;
    }
  plan->sources = g_ptr_array_new_with_free_func (g_object_unref);
  plan->copies = g_ptr_array_new_with_free_func (g_object_unref);

  /* Clone all sources. */
  for (i = 0; i < count; i++)
    {
      GimpItem *item = items[i];
      GimpLayer *layer = GIMP_LAYER (item);
      GimpLayer *copy;

      g_ptr_array_add (plan->sources, g_object_ref (item));

      copy = GIMP_LAYER (gimp_item_duplicate (GIMP_ITEM (layer),
                                              G_TYPE_FROM_INSTANCE (layer)));
      if (!copy)
        {
          if (error)
            *error = g_strdup ("The layer could not be duplicated.");
          status = GLIMS_STATUS_FAILED;
          goto fail;
        }
      copy = GIMP_LAYER (g_object_ref_sink (copy));

      if (copy == layer ||
          G_OBJECT_TYPE (copy) != G_OBJECT_TYPE (layer) ||
          gimp_item_get_image (GIMP_ITEM (copy)) != open->image ||
          gimp_item_is_attached (GIMP_ITEM (copy)))
        {
          g_object_unref (copy);
          if (error)
            *error = g_strdup ("The layer duplicate failed validation.");
          status = GLIMS_STATUS_FAILED;
          goto fail;
        }

      g_ptr_array_add (plan->copies, copy);
    }

  g_free (items);
  items = NULL;

  if (out)
    *out = plan;
  return GLIMS_STATUS_OK;

fail:
  if (plan)
    {
      if (plan->sources) g_ptr_array_unref (plan->sources);
      if (plan->copies) g_ptr_array_unref (plan->copies);
      free (plan);
    }
  g_free (items);
  if (out) *out = NULL;
  return status;
}

void
glims_layer_duplicate_plan_free (GlimsLayerDuplicatePlan *plan)
{
  if (!plan)
    return;
  if (plan->sources)
    g_ptr_array_unref (plan->sources);
  if (plan->copies)
    g_ptr_array_unref (plan->copies);
  free (plan);
}

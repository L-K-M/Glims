/*
 * READ-ONLY facade slots 133/134: image_item_sets lists an image's fixed
 * saved sets (token, facade kind, live member count, display name) and
 * image_item_set_members resolves the current attached member ids of one
 * token. Both are plain reads: they run on the engine thread, are allowed
 * while the image is busy (no edit-readiness gate), and never change the
 * selection, the image, its history, its dirty flag or any pixel. All
 * identity handling lives in the item-set manager (item-sets.c); this
 * file only looks the image up and validates the outputs.
 */
#include "engine-private.h"

#include "core/gimpimage.h"

GlimsStatus
glims_image_item_sets (GlimsEngine *e, GlimsImageID image,
                       GlimsItemSetInfo *rows, int32_t capacity, int32_t *count)
{
  GlimsOpenImage *open;

  if (count)
    *count = 0;                   /* defensive reset, also on NOT_RUNNING */
  if (! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  open = glims_lookup_image (e, image);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  return glims_item_sets_list (open->item_sets, rows, capacity, count);
}

GlimsStatus
glims_image_item_set_members (GlimsEngine *e, GlimsImageID image, uint64_t token,
                              GlimsItemID *members, int32_t capacity, int32_t *count)
{
  GlimsOpenImage *open;

  if (count)
    *count = 0;                   /* defensive reset, also on NOT_RUNNING */
  if (! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (token == 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  open = glims_lookup_image (e, image);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  return glims_item_sets_members_of (open->item_sets, token, members, capacity, count);
}

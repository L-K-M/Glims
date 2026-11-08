/*
 * Image guides: the ordinary full-image rulers, listed and edited by id.
 * Runs on the engine thread.
 *
 * The native API is app/core/gimpimage-guides.h and app/core/gimpguide.h:
 * gimp_image_add_hguide/add_vguide create with push_undo, move and remove
 * take push_undo too, gimp_image_get_guides returns the image's own list
 * and gimp_image_get_guide resolves a GimpAuxItem id. Custom tool-owned
 * guides (gimp_guide_is_custom, e.g. layer edge guides) carry the
 * engine's own semantics — no undo for their move/remove — so the facade
 * never lists them and refuses to mutate them. The "guide-added",
 * "guide-removed" and "guide-moved" signals each carry the one
 * GimpGuide pointer; image.c forwards them as GLIMS_EVENT_GUIDES with
 * the image id only.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-guides.h"
#include "core/gimpguide.h"
#include "core/gimpauxitem.h"

/* The facade orientation a native guide reports, mapped by name: the
 * engine's enum value never leaves the adapter. */
static uint32_t
facade_orientation (GimpGuide *guide)
{
  return gimp_guide_get_orientation (guide) == GIMP_ORIENTATION_VERTICAL
         ? GLIMS_GUIDE_VERTICAL : GLIMS_GUIDE_HORIZONTAL;
}

/* The largest position a guide of `orientation` may hold on `image`. */
static gint
guide_limit (GimpImage *image,
             uint32_t   orientation)
{
  return orientation == GLIMS_GUIDE_VERTICAL
         ? gimp_image_get_width (image) : gimp_image_get_height (image);
}

/* The ordinary (not custom tool-owned) guide `id` names on `image`, or
 * NULL. GimpAuxItem ids are guint32; a negative facade id can never name
 * one. */
static GimpGuide *
lookup_guide (GimpImage   *image,
              GlimsGuideID id)
{
  GimpGuide *guide;

  if (id <= 0)
    return NULL;

  guide = gimp_image_get_guide (image, (guint32) id);
  if (! guide || gimp_guide_is_custom (guide))
    return NULL;

  return guide;
}

GlimsStatus
glims_image_guides (GlimsEngine    *engine,
                    GlimsImageID    id,
                    GlimsGuideInfo *rows,
                    int32_t         capacity,
                    int32_t        *count)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GList          *iter;
  int32_t         total = 0, i = 0;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! count || capacity < 0 || (! rows && capacity > 0))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  for (iter = gimp_image_get_guides (open->image); iter; iter = iter->next)
    {
      GimpGuide *guide = iter->data;

      if (gimp_guide_is_custom (guide))
        continue;
      if (rows && i < capacity)
        {
          rows[i].id          = (GlimsGuideID) gimp_aux_item_get_id (GIMP_AUX_ITEM (guide));
          rows[i].orientation = facade_orientation (guide);
          rows[i].position    = gimp_guide_get_position (guide);
        }
      i++;
      total++;
    }

  *count = total;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_guide_put (GlimsEngine          *engine,
                 GlimsImageID          id,
                 const GlimsGuideInfo *request,
                 GlimsGuideID         *result,
                 char                **error)
{
  GlimsOpenImage *open;
  GimpGuide      *guide;
  GlimsStatus     status;

  if (result)
    *result = 0;

  if (! request || request->id < 0 ||
      (request->orientation != GLIMS_GUIDE_HORIZONTAL &&
       request->orientation != GLIMS_GUIDE_VERTICAL))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  if (request->position < 0 || request->position > guide_limit (open->image,
                                                                request->orientation))
    {
      glims_fail (error, NULL, "The guide position is outside the image.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  guide = NULL;
  if (request->id != 0)
    {
      guide = lookup_guide (open->image, request->id);
      if (! guide)
        return GLIMS_STATUS_NOT_FOUND;
      if (facade_orientation (guide) != request->orientation)
        {
          glims_fail (error, NULL, "A guide cannot change its orientation.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      if (gimp_guide_get_position (guide) == request->position)
        {
          /* A move to the same position is a no-op with no undo step. */
          if (result)
            *result = request->id;
          return GLIMS_STATUS_OK;
        }
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  if (! guide)
    {
      guide = request->orientation == GLIMS_GUIDE_HORIZONTAL
              ? gimp_image_add_hguide (open->image, request->position, TRUE)
              : gimp_image_add_vguide (open->image, request->position, TRUE);
    }
  else
    {
      gimp_image_move_guide (open->image, guide, request->position, TRUE);
    }

  /* Guide ids count up from 1 per engine; a value that does not fit the
   * facade's int32 id can only come from an engine that issued more
   * than two billion guides. */
  if (result)
    *result = (GlimsGuideID) gimp_aux_item_get_id (GIMP_AUX_ITEM (guide));

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_guide_remove (GlimsEngine  *engine,
                    GlimsImageID  id,
                    GlimsGuideID  guide_id,
                    char        **error)
{
  GlimsOpenImage *open;
  GimpGuide      *guide;
  GlimsStatus     status;

  if (guide_id <= 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  guide = lookup_guide (open->image, guide_id);
  if (! guide)
    return GLIMS_STATUS_NOT_FOUND;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  gimp_image_remove_guide (open->image, guide, TRUE);

  return GLIMS_STATUS_OK;
}

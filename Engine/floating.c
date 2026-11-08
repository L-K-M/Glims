/* Floating selections: the floating-state read, Paste Into (the engine's
 * own gimp_edit_paste with GIMP_PASTE_TYPE_FLOATING_INTO) and the three
 * resolution verbs (anchor, to-layer, discard), each driven verbatim
 * through the GUI-free core paths GIMP's own actions use
 * (app/actions/edit-commands.c, app/actions/layers-commands.c).
 *
 * Core guarantees relied on here, verified identical in all four engine
 * trees (GIMP_3_0_8, GIMP_3_2_0, GIMP_3_2_8, master): FLOATING_INTO wraps
 * the whole paste in one "Paste" undo group and never clears the image
 * selection (unlike FLOATING); floating_sel_attach silently anchors an
 * already-existing floating selection first, so this file refuses that
 * case before any native call; floating_sel_to_layer fails — before its
 * undo group opens — for mask/channel-attached floating selections;
 * gimp_image_remove_layer on a floating layer is the one-step "Remove
 * Floating Selection" discard; XCF saves and reloads the attachment.
 * Runs on the engine thread.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpbuffer.h"
#include "core/gimpchannel.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimp-edit.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-floating-selection.h"
#include "core/gimplayermask.h"
#include "core/gimpselection.h"

/* The facade target kind of the drawable a floating selection is (or
 * would be) attached to. A layer mask derives from the channel class, so
 * the mask check comes first. */
static uint32_t
target_kind_of (GimpDrawable *target)
{
  if (GIMP_IS_LAYER_MASK (target))
    return GLIMS_FLOATING_TARGET_LAYER_MASK;
  if (GIMP_IS_CHANNEL (target))
    return GLIMS_FLOATING_TARGET_CHANNEL;
  return GLIMS_FLOATING_TARGET_LAYER;
}

GlimsStatus
glims_image_floating_selection (GlimsEngine       *engine,
                                GlimsImageID       id,
                                GlimsFloatingState *out)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpLayer      *fs;
  GimpDrawable   *target;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! out || out->struct_size < sizeof (GlimsFloatingState))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  memset (out, 0, sizeof *out);
  out->struct_size = sizeof *out;

  fs = gimp_image_get_floating_selection (open->image);
  if (fs)
    {
      target = gimp_layer_get_floating_sel_drawable (fs);

      out->active      = true;
      out->floating    = gimp_item_get_id (GIMP_ITEM (fs));
      out->target      = target ? gimp_item_get_id (GIMP_ITEM (target)) : 0;
      out->target_kind = target ? target_kind_of (target) : 0;
    }

  return GLIMS_STATUS_OK;
}

/* The drawable to attach a floating selection to: `id` 0 is the image's
 * selected drawable — the same accessor gimp_edit_paste's callers use —
 * and an explicit id must name an attached drawable of this image. */
static GimpDrawable *
paste_target (GlimsOpenImage  *open,
              GlimsItemID      id,
              GlimsStatus     *status,
              char           **error)
{
  GimpImage    *image = open->image;
  GimpDrawable *drawable;

  if (id == 0)
    {
      GList *selected = gimp_image_get_selected_drawables (image);

      drawable = selected ? selected->data : NULL;
      g_list_free (selected);
      if (! drawable)
        *status = glims_fail (error, NULL, "Select a layer, mask or channel to paste into.");
      return drawable;
    }

  drawable = glims_lookup_drawable (open, id);
  if (! drawable)
    *status = GLIMS_STATUS_NOT_FOUND;
  return drawable;
}

GlimsStatus
glims_image_paste_into (GlimsEngine  *engine,
                        GlimsImageID  id,
                        GlimsItemID   target_id,
                        GlimsRect     bounds,
                        const uint8_t *pixels,
                        size_t        byte_count,
                        GlimsItemID  *result,
                        char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpImage      *image;
  GimpDrawable   *target;
  GimpChannel    *mask;
  GeglBuffer     *buffer;
  GimpBuffer     *paste_buffer;
  GimpContext    *context;
  GList          *drawables;
  GList          *pasted;
  GlimsStatus     status;
  size_t          bytes;
  gint            x, y, w, h;

  if (result) *result = 0;
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  image = open->image;

  /* The whole request is validated before any mutation. */
  if (! pixels || ! glims_pixel_bytes (bounds.width, bounds.height, &bytes) || bytes != byte_count ||
      bounds.x < -GIMP_MAX_IMAGE_SIZE || bounds.x > GIMP_MAX_IMAGE_SIZE ||
      bounds.y < -GIMP_MAX_IMAGE_SIZE || bounds.y > GIMP_MAX_IMAGE_SIZE)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Mandatory: an existing floating selection must be resolved first —
   * floating_sel_attach would silently anchor it inside the "Paste"
   * undo group. */
  if (gimp_image_get_floating_selection (image))
    return glims_fail (error, NULL,
                        "A floating selection is already active; anchor it, turn it into a layer or discard it first.");

  target = paste_target (open, target_id, &status, error);
  if (! target)
    return status;

  /* The selection mask itself is the clip, never the target; a group or
   * a content-locked target would make core silently downgrade to a new
   * layer (gimp_edit_paste_get_layers) — refused here instead, this call
   * never silently becomes a plain Paste. */
  if (target == GIMP_DRAWABLE (gimp_image_get_mask (image)))
    return glims_fail (error, NULL, "The selection itself cannot be the paste target.");
  if (GIMP_IS_GROUP_LAYER (target))
    return glims_fail (error, NULL, "Cannot paste into a layer group; choose one of its layers, its mask or a channel.");
  if (GIMP_IS_LAYER (target))
    {
      uint32_t editable = glims_layer_editable_source_kind (GIMP_LAYER (target));

      if (editable != 0)
        {
          if (error)
            *error = strdup ("The target is a genuine editable text, link or vector layer; "
                             "rasterize it before pasting into the selection.");
          return GLIMS_STATUS_REQUIRES_RASTERIZE;
        }
    }
  else if (GIMP_IS_CHANNEL (target) && ! GIMP_IS_LAYER_MASK (target))
    {
      /* Only channels of the image's channel list are valid targets:
       * saved channels and the Quick Mask's channel. The selection mask
       * is not in that container and was refused above already. */
      if (gimp_item_get_container (GIMP_ITEM (target)) != gimp_image_get_channels (image))
        return glims_fail (error, NULL, "Only a saved channel of this image can be the paste target.");
    }
  else if (! GIMP_IS_LAYER_MASK (target))
    return glims_fail (error, NULL, "The paste target must be a layer, a layer mask or a saved channel.");

  status = glims_check_item_locks (GIMP_ITEM (target), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* A real selection is required, and it must intersect the target —
   * core would otherwise create a floating selection that covers
   * nothing. Select All counts as a full (non-empty) selection, as the
   * core treats it. */
  mask = gimp_image_get_mask (image);
  if (gimp_channel_is_empty (mask))
    return glims_fail (error, NULL, "There is no selection to paste into.");
  if (! gimp_item_mask_intersect (GIMP_ITEM (target), &x, &y, &w, &h) || w < 1 || h < 1)
    return glims_fail (error, NULL, "The selection does not overlap the paste target.");

  /* A private per-call pixel buffer; copy_pixels=TRUE duplicates, so the
   * caller's memory is only read here and never retained. No color
   * profile is attached: the payload is plain sRGB and core converts it
   * to the target's format with alpha and precision inside
   * gimp_edit_paste (gimp_drawable_get_format_with_alpha). */
  buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, bounds.width, bounds.height),
                            babl_format ("R'G'B'A u8"));
  gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, bounds.width, bounds.height), 0,
                   babl_format ("R'G'B'A u8"), pixels, bounds.width * 4);
  paste_buffer = gimp_buffer_new (buffer, "Pasted Layer", 0, 0, TRUE);
  g_object_unref (buffer);

  context = gimp_context_new (engine->gimp, "Glims Paste Into", gimp_get_user_context (engine->gimp));

  drawables = g_list_prepend (NULL, target);
  /* As the PDB's own Paste Into invoker passes no viewport: with a
   * selection present, core centers the floating layer on the target's
   * bounds intersected with the selection. FLOATING_INTO (unlike
   * FLOATING) does not clear the selection. */
  pasted = gimp_edit_paste (image, drawables, GIMP_OBJECT (paste_buffer),
                            GIMP_PASTE_TYPE_FLOATING_INTO, context, FALSE,
                            -1, -1, -1, -1);
  g_list_free (drawables);
  g_object_unref (context);
  g_object_unref (paste_buffer);

  if (! pasted)
    return glims_fail (error, NULL, "The engine could not paste into the selection.");

  /* The returned list is the caller-owned container; the layer objects
   * belong to the image. A buffer paste yields exactly one layer, the
   * floating selection. */
  if (result)
    *result = gimp_item_get_id (GIMP_ITEM (pasted->data));
  g_list_free (pasted);

  gimp_image_flush (image);
  return GLIMS_STATUS_OK;
}

/* Floats the current selection off `target` through the GUI-free
 * gimp_selection_float (app/core/gimpselection.c), the same core path
 * GIMP's own Select > Float uses (app/actions/select-commands.c
 * select_float; app/pdb/selection-cmds.c): one FS_FLOAT undo group,
 * native extract (cut for GLIMS_FLOAT_MOVE, copy for GLIMS_FLOAT_COPY),
 * the selection cleared, and a new layer in the target's own format,
 * profile and selection-intersection bounds attached at offset 0.
 * Unlike FLOATING_INTO's paste, the core attach (floating_sel_attach)
 * would silently anchor an already-existing floating selection inside
 * the undo group, so that case is refused here before any native call.
 * The returned layer is owned by the image; it is never unref'd. */
GlimsStatus
glims_selection_float (GlimsEngine  *engine,
                       GlimsImageID  id,
                       GlimsItemID   target_id,
                       uint32_t      mode,
                       GlimsItemID  *result,
                       char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpImage      *image;
  GimpDrawable   *target;
  GimpChannel    *mask;
  GimpContext    *context;
  GimpLayer      *fs;
  GList          *drawables;
  GList          *selected;
  GError         *gerror = NULL;
  GlimsStatus     status;
  uint32_t        locks = GLIMS_LOCK_PIXELS;
  gboolean        cut;
  gint            x, y, w, h;

  if (result) *result = 0;
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  image = open->image;

  switch (mode)
    {
    case GLIMS_FLOAT_MOVE:
      cut = TRUE;
      break;
    case GLIMS_FLOAT_COPY:
      cut = FALSE;
      break;
    default:
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* Mandatory: an existing floating selection must be resolved first —
   * floating_sel_attach would silently anchor it inside the "Float
   * Selection" undo group. */
  if (gimp_image_get_floating_selection (image))
    return glims_fail (error, NULL,
                        "A floating selection is already active; anchor it, turn it into a layer or discard it first.");

  /* Target admission, same as image_paste_into's, with one float-only
   * rule: `target` 0 takes the image's selected drawable only when
   * exactly one drawable is selected. */
  if (target_id == 0)
    {
      selected = gimp_image_get_selected_drawables (image);
      if (! selected)
        {
          g_list_free (selected);
          return glims_fail (error, NULL, "Select a layer, mask or channel to float.");
        }
      if (g_list_length (selected) > 1)
        {
          g_list_free (selected);
          return glims_fail (error, NULL,
                             "More than one drawable is selected; name the float target explicitly.");
        }
      target = selected->data;
      g_list_free (selected);
    }
  else
    {
      target = glims_lookup_drawable (open, target_id);
      if (! target)
        return GLIMS_STATUS_NOT_FOUND;
    }

  /* The selection mask itself is never the float source; a group or a
   * content-locked target would make core fail or misbehave — refused
   * here instead. */
  if (target == GIMP_DRAWABLE (gimp_image_get_mask (image)))
    return glims_fail (error, NULL, "The selection itself cannot be the float target.");
  if (GIMP_IS_GROUP_LAYER (target))
    return glims_fail (error, NULL, "Cannot float from a layer group; choose one of its layers, its mask or a channel.");
  if (GIMP_IS_LAYER (target))
    {
      uint32_t editable = glims_layer_editable_source_kind (GIMP_LAYER (target));

      if (editable != 0)
        {
          if (error)
            *error = strdup ("The target is a genuine editable text, link or vector layer; "
                             "rasterize it before floating the selection.");
          return GLIMS_STATUS_REQUIRES_RASTERIZE;
        }
    }
  else if (GIMP_IS_CHANNEL (target) && ! GIMP_IS_LAYER_MASK (target))
    {
      /* Only channels of the image's channel list are valid targets:
       * saved channels and the Quick Mask's channel. The selection mask
       * is not in that container and was refused above already. */
      if (gimp_item_get_container (GIMP_ITEM (target)) != gimp_image_get_channels (image))
        return glims_fail (error, NULL, "Only a saved channel of this image can be the float target.");
    }
  else if (! GIMP_IS_LAYER_MASK (target))
    return glims_fail (error, NULL, "The float target must be a layer, a layer mask or a saved channel.");

  /* MOVE cuts through the target's pixels and its alpha channel (the
   * hole is transparent), so it checks the content lock and — on a
   * drawable with alpha, as image_clear and the eraser do — the alpha
   * lock. COPY is non-destructive: no locks beyond the readiness check
   * above. */
  if (cut)
    {
      if (gimp_drawable_has_alpha (target))
        locks |= GLIMS_LOCK_ALPHA;
      status = glims_check_item_locks (GIMP_ITEM (target), locks, error);
      if (status != GLIMS_STATUS_OK)
        return status;
    }

  /* A real selection is required, and it must intersect the target —
   * the core's own region check (gimp_item_mask_bounds over the
   * drawables) would fail the same way inside the undo group. Select
   * All counts as a full (non-empty) selection, as the core treats it. */
  mask = gimp_image_get_mask (image);
  if (gimp_channel_is_empty (mask))
    return glims_fail (error, NULL, "There is no selection to float.");
  if (! gimp_item_mask_intersect (GIMP_ITEM (target), &x, &y, &w, &h) || w < 1 || h < 1)
    return glims_fail (error, NULL, "The selection does not overlap the float target.");

  /* A private per-call context inheriting the user's settings; the
   * shared user context is never mutated. Offsets 0: the floating layer
   * lands exactly on the extracted region, and layer_move moves it once
   * the selection is cleared. */
  context = gimp_context_new (engine->gimp, "Glims Float Selection", gimp_get_user_context (engine->gimp));
  drawables = g_list_prepend (NULL, target);
  fs = gimp_selection_float (GIMP_SELECTION (mask), drawables, context, cut, 0, 0, &gerror);
  g_list_free (drawables);
  g_object_unref (context);

  if (! fs)
    return glims_fail (error, gerror, "The selection could not be floated.");

  /* The returned floating layer belongs to the image; no unref. */
  if (result)
    *result = gimp_item_get_id (GIMP_ITEM (fs));

  gimp_image_flush (image);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_floating_command (GlimsEngine  *engine,
                        GlimsImageID  id,
                        GlimsItemID   expected,
                        uint32_t      command,
                        GlimsItemID  *result,
                        char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpImage      *image;
  GimpLayer      *fs;
  GError         *gerror = NULL;
  GlimsStatus     status;

  if (result) *result = 0;
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  image = open->image;

  switch (command)
    {
    case GLIMS_FLOATING_ANCHOR:
    case GLIMS_FLOATING_TO_LAYER:
    case GLIMS_FLOATING_DISCARD:
      break;
    default:
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* `expected` must name the floating selection that is actually active
   * in this image — 0 and stale or foreign ids never fall back to
   * whichever floating selection happens to be active. */
  if (expected == 0)
    {
      if (error)
        *error = strdup ("Name the floating selection to resolve, as image_floating_selection reports it; "
                         "0 never falls back to the active one.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  fs = gimp_image_get_floating_selection (image);
  if (! fs)
    {
      if (error)
        *error = strdup ("There is no floating selection in this image.");
      return GLIMS_STATUS_NOT_FOUND;
    }
  if (gimp_item_get_id (GIMP_ITEM (fs)) != expected)
    {
      if (error)
        *error = strdup ("The named floating selection is not the one active in this image.");
      return GLIMS_STATUS_NOT_FOUND;
    }

  switch (command)
    {
    case GLIMS_FLOATING_ANCHOR:
      /* Locks may have changed since the paste. Anchoring writes the
       * attachment's pixels; the other resolution verbs do not. */
      {
        GimpDrawable *target = gimp_layer_get_floating_sel_drawable (fs);
        if (! target)
          return glims_fail (error, NULL, "The floating selection has no target to anchor into.");
        status = glims_check_item_locks (GIMP_ITEM (target), GLIMS_LOCK_PIXELS, error);
        if (status != GLIMS_STATUS_OK)
          return status;
      }
      /* One "Anchor Floating Selection" undo step, merged into the
       * attached target. */
      floating_sel_anchor (fs);
      break;

    case GLIMS_FLOATING_TO_LAYER:
      /* One "Floating Selection to Layer" undo step; fails — before its
       * undo group opens, so with no mutation — for a floating selection
       * attached to a layer mask or channel. */
      if (! floating_sel_to_layer (fs, &gerror))
        return glims_fail (error, gerror, "The floating selection could not become a layer.");
      if (result)
        *result = expected;
      break;

    case GLIMS_FLOATING_DISCARD:
      /* One "Remove Floating Selection" undo step; the pixels stay as
       * they were before the paste. */
      gimp_image_remove_layer (image, fs, TRUE, NULL);
      break;

    default:
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  gimp_image_flush (image);
  return GLIMS_STATUS_OK;
}

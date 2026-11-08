/*
 * The image's color components, saved selection channels and Quick
 * Mask. All of it is the engine's own state and behavior, following
 * the channels dock's commands (app/actions/channels-commands.c),
 * Select > Save to Channel (app/actions/select-commands.c) and the
 * Quick Mask toggle (app/actions/image-commands.c
 * image_quick_mask_cmd_callback). Runs on the engine thread.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-quick-mask.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"

#include "gimp-intl.h"

#define GLIMS_COMPONENT_ALL (GLIMS_COMPONENT_RED | GLIMS_COMPONENT_GREEN | \
                             GLIMS_COMPONENT_BLUE | GLIMS_COMPONENT_ALPHA | \
                             GLIMS_COMPONENT_GRAY | GLIMS_COMPONENT_INDEXED)

/* ---- Components ------------------------------------------------------- */

/* The engine component of one facade bit. */
static GimpChannelType
component_type (uint32_t bit)
{
  switch (bit)
    {
    case GLIMS_COMPONENT_RED:     return GIMP_CHANNEL_RED;
    case GLIMS_COMPONENT_GREEN:   return GIMP_CHANNEL_GREEN;
    case GLIMS_COMPONENT_BLUE:    return GIMP_CHANNEL_BLUE;
    case GLIMS_COMPONENT_ALPHA:   return GIMP_CHANNEL_ALPHA;
    case GLIMS_COMPONENT_GRAY:    return GIMP_CHANNEL_GRAY;
    case GLIMS_COMPONENT_INDEXED: return GIMP_CHANNEL_INDEXED;
    default:                      return GIMP_CHANNEL_RED;  /* unreachable */
    }
}

/* The components the image's color model actually has, as the component
 * editor lists them (app/widgets/gimpcomponenteditor.c
 * gimp_component_editor_set_image): the model's own components, plus
 * alpha once the image has any. */
static uint32_t
supported_components (GimpImage *image)
{
  uint32_t supported = 0;

  switch (gimp_image_get_base_type (image))
    {
    case GIMP_RGB:
      supported = GLIMS_COMPONENT_RED | GLIMS_COMPONENT_GREEN | GLIMS_COMPONENT_BLUE;
      break;
    case GIMP_GRAY:
      supported = GLIMS_COMPONENT_GRAY;
      break;
    case GIMP_INDEXED:
      supported = GLIMS_COMPONENT_INDEXED;
      break;
    }
  if (gimp_image_has_alpha (image))
    supported |= GLIMS_COMPONENT_ALPHA;

  return supported;
}

/* The channel `id` in `image`'s channel list, or NULL. The container
 * check also rules out the selection mask and layer masks: both are
 * channels, but not rows of the channel list. */
static GimpChannel *
find_channel (GimpImage   *image,
              GlimsItemID  id)
{
  GimpItem *item = gimp_item_get_by_id (image->gimp, id);

  if (! GIMP_IS_CHANNEL (item) || gimp_item_get_image (item) != image ||
      gimp_item_get_container (item) != gimp_image_get_channels (image))
    return NULL;

  return GIMP_CHANNEL (item);
}

GlimsStatus
glims_image_components (GlimsEngine         *engine,
                        GlimsImageID         id,
                        GlimsComponentState *state)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  uint32_t        supported;
  gint            i;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! state)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  memset (state, 0, sizeof (*state));
  switch (gimp_image_get_base_type (open->image))
    {
    case GIMP_RGB:     state->mode = GLIMS_COMPONENT_MODE_RGB;     break;
    case GIMP_GRAY:    state->mode = GLIMS_COMPONENT_MODE_GRAY;    break;
    case GIMP_INDEXED: state->mode = GLIMS_COMPONENT_MODE_INDEXED; break;
    }

  supported = supported_components (open->image);
  state->supported = supported;
  for (i = 0; i < 6; i++)
    {
      uint32_t bit = 1u << i;

      if (! (supported & bit))
        continue;
      if (gimp_image_get_component_active (open->image, component_type (bit)))
        state->active |= bit;
      if (gimp_image_get_component_visible (open->image, component_type (bit)))
        state->visible |= bit;
    }

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_set_components (GlimsEngine  *engine,
                            GlimsImageID  id,
                            uint32_t      active_mask,
                            uint32_t      active_values,
                            uint32_t      visible_mask,
                            uint32_t      visible_values,
                            char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsStatus     status;
  gint            i;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if ((active_mask | active_values | visible_mask | visible_values) & ~GLIMS_COMPONENT_ALL)
    {
      glims_fail (error, NULL, "A mask names a component the engine has no bit for.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if ((active_mask | visible_mask) & ~supported_components (open->image))
    {
      glims_fail (error, NULL, "The image's color model has no such component.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* The component editor's eye and active toggles
   * (gimp_component_editor_*_toggled). These are not undo steps; the
   * active mask also unselects any selected channel, as
   * gimp_image_set_component_active does. */
  for (i = 0; i < 6; i++)
    {
      uint32_t        bit  = 1u << i;
      GimpChannelType type;

      if (! ((active_mask | visible_mask) & bit))
        continue;
      type = component_type (bit);
      if (active_mask & bit)
        gimp_image_set_component_active (open->image, type, (active_values & bit) != 0);
      if (visible_mask & bit)
        gimp_image_set_component_visible (open->image, type, (visible_values & bit) != 0);
    }
  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

/* ---- Channels --------------------------------------------------------- */

/* The engine locates the Quick Mask's channel by the reserved name
 * GIMP_IMAGE_QUICK_MASK_NAME, not by identity: adding a channel under
 * it, or renaming a channel to or from it, toggles the mask through the
 * container's add/remove/name-changed handlers (app/core/gimpimage.c).
 * `name` is reported after the same normalization the engine applies to
 * renames and adds — trailing whitespace is chomped by
 * gimp_item_tree_uniquefy_name. */
static gboolean
quick_mask_name (const char *name)
{
  gchar   *copy;
  gboolean matches;

  if (! name)
    return FALSE;

  copy    = g_strchomp (g_strdup (name));
  matches = g_strcmp0 (copy, GIMP_IMAGE_QUICK_MASK_NAME) == 0;
  g_free (copy);

  return matches;
}

GlimsStatus
glims_image_channels (GlimsEngine      *engine,
                      GlimsImageID      id,
                      GlimsChannelInfo *rows,
                      int32_t           capacity,
                      int32_t          *count)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpChannel    *quick_mask;
  GList          *channels, *selected, *iter;
  int32_t         i = 0;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! count || capacity < 0 || (! rows && capacity > 0))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  channels = gimp_image_get_channel_list (open->image);
  /* The engine's own selected list, not a copy: do not free. */
  selected  = gimp_image_get_selected_channels (open->image);
  quick_mask = gimp_image_get_quick_mask_state (open->image)
    ? gimp_image_get_quick_mask (open->image) : NULL;

  *count = g_list_length (channels);
  for (iter = channels; iter && i < capacity; iter = iter->next, i++)
    {
      GimpChannel      *channel = iter->data;
      GlimsChannelInfo *row = &rows[i];
      gdouble           r, g, b, a;

      memset (row, 0, sizeof (*row));
      row->id         = gimp_item_get_id (GIMP_ITEM (channel));
      g_strlcpy (row->name, gimp_object_get_name (GIMP_OBJECT (channel)), sizeof row->name);
      row->visible    = gimp_item_get_visible (GIMP_ITEM (channel)) != FALSE;
      row->selected   = g_list_find (selected, channel) != NULL;
      row->quick_mask = channel == quick_mask;
      gegl_color_get_rgba (gimp_channel_get_color (channel), &r, &g, &b, &a);
      row->opacity = a;
      row->color   = (GlimsColor) { r, g, b, a };
    }
  g_list_free (channels);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_channel_from_selection (GlimsEngine  *engine,
                              GlimsImageID  id,
                              const char   *name,
                              GlimsItemID  *result,
                              char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsStatus     status;
  GimpChannel    *channel;
  GError         *gerror = NULL;

  if (result)
    *result = 0;
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* A channel created under the reserved name would be adopted as the
   * live mask by the container's add handler — toggling the mask on
   * without a lifecycle and consuming the channel when it turns off.
   * Refuse it before any mutation. */
  if (quick_mask_name (name))
    {
      glims_fail (error, NULL,
                  "The Quick Mask's channel name is reserved.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* Select > Save to Channel (select_save_cmd_callback): a copy of the
   * selection mask, invisible by default, added with undo. */
  channel = GIMP_CHANNEL (gimp_item_duplicate (GIMP_ITEM (gimp_image_get_mask (open->image)),
                                               GIMP_TYPE_CHANNEL));
  gimp_item_set_visible (GIMP_ITEM (channel), FALSE, FALSE);
  if (name && *name &&
      ! gimp_item_rename (GIMP_ITEM (channel), name, &gerror))
    {
      g_object_unref (channel);
      return glims_fail (error, gerror, "The channel could not be renamed.");
    }
  if (! gimp_image_add_channel (open->image, channel, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE))
    {
      g_object_unref (channel);
      return glims_fail (error, NULL, "The channel could not be added.");
    }
  gimp_image_flush (open->image);

  if (result)
    *result = gimp_item_get_id (GIMP_ITEM (channel));

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_channel_change (GlimsEngine              *engine,
                      GlimsImageID              id,
                      GlimsItemID               channel_id,
                      const GlimsChannelChange *change,
                      char                    **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsStatus     status;
  GimpChannel    *channel;
  GError         *gerror = NULL;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! change || change->struct_size < sizeof (GlimsChannelChange) ||
      change->properties & ~(GLIMS_CHANNEL_NAME | GLIMS_CHANNEL_VISIBLE |
                             GLIMS_CHANNEL_OPACITY | GLIMS_CHANNEL_COLOR))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  channel = find_channel (open->image, channel_id);
  if (! channel)
    return GLIMS_STATUS_NOT_FOUND;

  /* The name decides which channel is the Quick Mask's, so renaming
   * across it is a lifecycle change, not an attribute edit: an ordinary
   * channel renamed to it would be adopted (and consumed on exit); the
   * live mask's channel renamed away would strand the mode — the
   * name-changed handler turns the mask off without the toggle's
   * selection conversion. Renaming the mask to its own name stays a
   * no-op; renaming a legacy channel away from the name while the mask
   * is off stays allowed. */
  if (change->properties & GLIMS_CHANNEL_NAME)
    {
      if (gimp_image_get_quick_mask_state (open->image) &&
          channel == gimp_image_get_quick_mask (open->image))
        {
          if (! quick_mask_name (change->name))
            {
              glims_fail (error, NULL,
                          "The Quick Mask's channel keeps its reserved name.");
              return GLIMS_STATUS_INVALID_ARGUMENT;
            }
        }
      else if (quick_mask_name (change->name))
        {
          glims_fail (error, NULL,
                      "The Quick Mask's channel name is reserved.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
    }

  /* The dock's attribute edits (channels_edit_attributes_cmd_callback):
   * each native setter pushes its own undo. */
  if ((change->properties & GLIMS_CHANNEL_NAME) &&
      ! gimp_item_rename (GIMP_ITEM (channel), change->name, &gerror))
    return glims_fail (error, gerror, "The channel could not be renamed.");
  if (change->properties & GLIMS_CHANNEL_VISIBLE)
    gimp_item_set_visible (GIMP_ITEM (channel), change->visible, TRUE);
  if (change->properties & GLIMS_CHANNEL_COLOR)
    {
      GeglColor *color = gegl_color_new (NULL);

      gegl_color_set_rgba_with_space (color,
                                      CLAMP (change->color.red,   0.0, 1.0),
                                      CLAMP (change->color.green, 0.0, 1.0),
                                      CLAMP (change->color.blue,  0.0, 1.0),
                                      CLAMP (change->color.alpha, 0.0, 1.0),
                                      NULL);
      gimp_channel_set_color (channel, color, TRUE);
      g_object_unref (color);
    }
  if (change->properties & GLIMS_CHANNEL_OPACITY)
    gimp_channel_set_opacity (channel, CLAMP (change->opacity, 0.0, 1.0), TRUE);

  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_channel_command (GlimsEngine  *engine,
                       GlimsImageID  id,
                       GlimsItemID   channel_id,
                       uint32_t      command,
                       GlimsItemID  *result,
                       char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpChannel    *channel;
  GlimsStatus     status;

  if (result)
    *result = 0;
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (command != GLIMS_CHANNEL_SELECT && command != GLIMS_CHANNEL_DUPLICATE &&
      command != GLIMS_CHANNEL_DELETE)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Selecting another edit target is not a change, so like layer_select
   * it stays allowed while a session runs. */
  if (command == GLIMS_CHANNEL_SELECT)
    {
      if (channel_id == 0)
        {
          /* Back to the layers the channel selection replaced. */
          gimp_image_unset_selected_channels (open->image);
          return GLIMS_STATUS_OK;
        }
      channel = find_channel (open->image, channel_id);
      if (! channel)
        return GLIMS_STATUS_NOT_FOUND;
      {
        GList *channels = g_list_prepend (NULL, channel);

        gimp_image_set_selected_channels (open->image, channels);
        g_list_free (channels);
      }
      return GLIMS_STATUS_OK;
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  channel = find_channel (open->image, channel_id);
  if (! channel)
    return GLIMS_STATUS_NOT_FOUND;

  switch (command)
    {
    case GLIMS_CHANNEL_DUPLICATE:
      /* The dock's Duplicate (channels_duplicate_cmd_callback). */
      {
        GimpChannel *copy = GIMP_CHANNEL (gimp_item_duplicate (GIMP_ITEM (channel),
                                                               GIMP_TYPE_CHANNEL));

        gimp_image_add_channel (open->image, copy, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE);
        if (result)
          *result = gimp_item_get_id (GIMP_ITEM (copy));
      }
      break;

    case GLIMS_CHANNEL_DELETE:
      /* The Quick Mask's channel belongs to the mask state; it leaves
       * the list when the mask turns off. */
      if (gimp_image_get_quick_mask_state (open->image) &&
          channel == gimp_image_get_quick_mask (open->image))
        {
          glims_fail (error, NULL, "The Quick Mask cannot be deleted; turn it off instead.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      gimp_image_remove_channel (open->image, channel, TRUE, NULL);
      break;
    }
  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_channel_to_selection (GlimsEngine  *engine,
                            GlimsImageID  id,
                            GlimsItemID   channel_id,
                            uint32_t      operation,
                            char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsStatus     status;
  GimpChannel    *channel;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (operation > GLIMS_SELECT_INTERSECT)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  channel = find_channel (open->image, channel_id);
  if (! channel)
    return GLIMS_STATUS_NOT_FOUND;

  /* The dock's Channel to Selection (channels_to_selection_cmd_callback),
   * honoring the channel's offset as gimp_item_to_selection does. */
  gimp_image_undo_group_start (open->image, GIMP_UNDO_GROUP_DRAWABLE_MOD,
                               C_("undo-type", "Channel to Selection"));
  gimp_item_to_selection (GIMP_ITEM (channel), glims_channel_op (operation),
                          TRUE, FALSE, 0.0, 0.0);
  gimp_image_undo_group_end (open->image);
  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

/* ---- Quick Mask -------------------------------------------------------- */

GlimsStatus
glims_image_quick_mask (GlimsEngine         *engine,
                        GlimsImageID         id,
                        GlimsQuickMaskState *state)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GeglColor      *color;
  gdouble         r, g, b, a;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! state)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  memset (state, 0, sizeof (*state));
  state->enabled  = gimp_image_get_quick_mask_state (open->image);
  state->inverted = gimp_image_get_quick_mask_inverted (open->image);
  color = gimp_image_get_quick_mask_color (open->image);
  gegl_color_get_rgba (color, &r, &g, &b, &a);
  state->color = (GlimsColor) { r, g, b, a };

  if (state->enabled)
    {
      GimpChannel *mask = gimp_image_get_quick_mask (open->image);

      if (mask)
        state->channel = gimp_item_get_id (GIMP_ITEM (mask));
    }

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_set_quick_mask (GlimsEngine  *engine,
                            GlimsImageID  id,
                            gboolean      enabled,
                            char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsStatus     status;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* A channel already holding the reserved name while the mask is off
   * would make the toggle adopt it, and the exit consume it. The name
   * guards keep that state unreachable through the facade; refuse it if
   * it ever arrives anyway — the channel can still be renamed away or
   * deleted while the mask is off. */
  if (enabled && ! gimp_image_get_quick_mask_state (open->image) &&
      gimp_image_get_channel_by_name (open->image, GIMP_IMAGE_QUICK_MASK_NAME))
    {
      glims_fail (error, NULL,
                  "A channel already holds the Quick Mask's reserved name.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* The Quick Mask button (image_quick_mask_cmd_callback). The engine
   * moves the selection into the mask's channel or back, swaps the edit
   * target, and wraps the whole toggle in one undo step
   * (app/core/gimpimage-quick-mask.c). */
  gimp_image_set_quick_mask_state (open->image, enabled);
  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

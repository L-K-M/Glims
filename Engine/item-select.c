/* Batch item selection of any kind (facade slots 136/137): the ordered,
 * transient whole-list write/read of the selected layers, channels or
 * paths through the engine's own gimp_image_set/get_selected_* family.
 * The full contract is in glims_engine.h. Runs on the engine thread. */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"

/* GIMP 3.2 moved app/vectors to app/path; the files kept their names. */
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimppath.h"
#else
#include "vectors/gimppath.h"
#endif

static gboolean
kind_valid (uint32_t kind)
{
  return kind == GLIMS_ITEM_SET_LAYER || kind == GLIMS_ITEM_SET_CHANNEL ||
         kind == GLIMS_ITEM_SET_PATH;
}

static GlimsStatus
invalid (char **error, const char *message)
{
  glims_fail (error, NULL, message);
  return GLIMS_STATUS_INVALID_ARGUMENT;
}

/* The image's selected items of `kind` — BORROWED, never freed here. */
static GList *
selected_of_kind (GimpImage *image, uint32_t kind)
{
  switch (kind)
    {
    case GLIMS_ITEM_SET_LAYER:   return gimp_image_get_selected_layers (image);
    case GLIMS_ITEM_SET_CHANNEL: return gimp_image_get_selected_channels (image);
    default:                     return gimp_image_get_selected_paths (image);
    }
}

/* The native whole-list setter of `kind`; it copies the passed list. */
static void
set_selected_of_kind (GimpImage *image, uint32_t kind, GList *list)
{
  switch (kind)
    {
    case GLIMS_ITEM_SET_LAYER:   gimp_image_set_selected_layers (image, list);   break;
    case GLIMS_ITEM_SET_CHANNEL: gimp_image_set_selected_channels (image, list); break;
    default:                     gimp_image_set_selected_paths (image, list);    break;
    }
}

/* An owned list of all items of `kind` (free with g_list_free). */
static GList *
list_of_kind (GimpImage *image, uint32_t kind)
{
  switch (kind)
    {
    case GLIMS_ITEM_SET_LAYER:   return gimp_image_get_layer_list (image);
    case GLIMS_ITEM_SET_CHANNEL: return gimp_image_get_channel_list (image);
    default:                     return gimp_image_get_path_list (image);
    }
}

/* Resolves one requested id to a CURRENT, ATTACHED item of `image` of
 * exactly `kind`; on refusal sets *status and the message. */
static GimpItem *
resolve_item (GimpImage *image, uint32_t kind, GlimsItemID item_id,
              GlimsStatus *status, char **error)
{
  GimpItem *item = gimp_item_get_by_id (image->gimp, item_id);
  const char *wrong = NULL;

  if (! item || gimp_item_get_image (item) != image || ! gimp_item_is_attached (item))
    {
      *status = GLIMS_STATUS_NOT_FOUND;
      glims_fail (error, NULL, "A requested item is stale, detached or belongs to another image.");
      return NULL;
    }

  switch (kind)
    {
    case GLIMS_ITEM_SET_LAYER:
      /* Groups are layers and pass. */
      if (! GIMP_IS_LAYER (item))
        wrong = "The id names a mask, channel or path, not a layer.";
      break;
    case GLIMS_ITEM_SET_CHANNEL:
      /* Masks are channels but not rows of the image's channel list. */
      if (! GIMP_IS_CHANNEL (item) ||
          gimp_item_get_container (item) != gimp_image_get_channels (image))
        wrong = "The id names a layer, path or mask, not a channel of the image's channel list.";
      break;
    default:
      if (! GIMP_IS_PATH (item))
        wrong = "The id names a layer, channel or mask, not a path.";
      break;
    }
  if (wrong)
    {
      *status = GLIMS_STATUS_INVALID_ARGUMENT;
      glims_fail (error, NULL, wrong);
      return NULL;
    }

  return item;
}

GlimsStatus
glims_image_select_items (GlimsEngine       *engine,
                          GlimsImageID       id,
                          uint32_t           kind,
                          const GlimsItemID *items,
                          int32_t            count,
                          char             **error)
{
  GlimsOpenImage *open;
  GimpImage      *image;
  GimpItem      **resolved = NULL;
  GHashTable     *seen = NULL;
  GList          *list = NULL;
  GList          *selected;
  GimpLayer      *floating;
  GlimsStatus     status = GLIMS_STATUS_OK;
  int32_t         i;
  gboolean        applied = FALSE;

  if (! engine)
    return GLIMS_STATUS_NOT_RUNNING;
  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  image = open->image;

  if (! kind_valid (kind))
    {
      glims_fail (error, NULL, "Unknown item kind; use GLIMS_ITEM_SET_LAYER, _CHANNEL or _PATH.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (count < 0 || (count > 0 && ! items))
    {
      glims_fail (error, NULL, count < 0 ? "A negative item count." : "A NULL item list needs count 0.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = glims_edit_ready (engine, open, error);  /* a write: readiness first */
  if (status != GLIMS_STATUS_OK)
    return status;

  if (count > 0)
    {
      GList *available = list_of_kind (image, kind);
      guint  available_count = g_list_length (available);
      g_list_free (available);
      if ((guint) count > available_count)
        {
          status = invalid (error, "The requested selection contains more ids than the image has of this kind.");
          goto out;
        }

      resolved = g_new (GimpItem *, count);
      seen     = g_hash_table_new (g_direct_hash, g_direct_equal);
      for (i = 0; i < count && status == GLIMS_STATUS_OK; i++)
        {
          GlimsItemID item_id = items[i];

          if (item_id == 0)
            status = invalid (error, "The item list contains the id 0, which names no item.");
          else if (g_hash_table_contains (seen, GINT_TO_POINTER (item_id)))
            status = invalid (error, "The item list repeats an id.");
          else
            {
              GimpItem *item = resolve_item (image, kind, item_id, &status, error);
              if (item)
                {
                  g_hash_table_add (seen, GINT_TO_POINTER (item_id));
                  resolved[i] = item;
                }
            }
        }
      if (status != GLIMS_STATUS_OK)
        goto out;
    }

  /* Floating-selection policy per kind, before any mutation; the FS is
   * never anchored here. Layers keep slot 122's gate (under an FS only
   * exactly [floating] passes). A NON-EMPTY channel list under an FS is
   * refused with a reason; an empty one is allowed. Paths: no FS gate. */
  floating = gimp_image_get_floating_selection (image);
  if (floating && kind == GLIMS_ITEM_SET_LAYER &&
      ! (count == 1 && resolved[0] == GIMP_ITEM (floating)))
    {
      status = glims_fail (error, NULL, "A floating selection is active; resolve it before changing the layer selection.");
      goto out;
    }
  if (floating && kind == GLIMS_ITEM_SET_CHANNEL && count > 0)
    {
      status = glims_fail (error, NULL, "A floating selection is active; the engine would silently ignore a channel selection. Resolve it first.");
      goto out;
    }

  for (i = count; i > 0; i--)  /* prepend keeps the caller's order */
    list = g_list_prepend (list, resolved[i - 1]);

  /* The engine compares membership, ignoring order, so a pure reorder is
   * dropped as "unchanged": force it with a clear-then-apply now that all
   * preflight checks have passed. */
  selected = selected_of_kind (image, kind);
  if (count > 1 && g_list_length (selected) == (guint) count)
    {
      GList   *iter;
      gboolean same_members = TRUE, same_order = TRUE;

      for (iter = selected, i = 0; iter; iter = iter->next, i++)
        {
          if (! g_hash_table_contains (seen, GINT_TO_POINTER (gimp_item_get_id (iter->data))))
            same_members = FALSE;
          if (iter->data != resolved[i])
            same_order = FALSE;
        }
      if (same_members && ! same_order)
        set_selected_of_kind (image, kind, NULL);
    }

  /* Apply. count 0 clears the selection: layers/paths via the empty
   * setter (layers FS-gated above), channels via
   * gimp_image_unset_selected_channels, which also restores the replaced
   * layer stack (the old channel-0 semantics). The native call copies the
   * list; the adapter's is freed once here. */
  if (count == 0 && kind == GLIMS_ITEM_SET_CHANNEL)
    gimp_image_unset_selected_channels (image);
  else
    set_selected_of_kind (image, kind, list);
  g_list_free (list);

  /* Postcondition: read-back must be the exact list in order. */
  applied  = TRUE;
  selected = selected_of_kind (image, kind);
  if (g_list_length (selected) != (guint) count)
    applied = FALSE;
  else
    {
      GList *iter;

      for (iter = selected, i = 0; iter; iter = iter->next, i++)
        if (iter->data != resolved[i])
          {
            applied = FALSE;
            break;
          }
    }

out:
  g_free (resolved);
  if (seen)
    g_hash_table_destroy (seen);
  if (status != GLIMS_STATUS_OK)
    return status;
  if (! applied)
    return glims_fail (error, NULL, "The engine did not apply the requested selection.");

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_selected_items (GlimsEngine  *engine,
                            GlimsImageID  id,
                            uint32_t      kind,
                            GlimsItemID  *out,
                            int32_t       capacity,
                            int32_t      *count)
{
  GlimsOpenImage *open;
  GList          *selected;
  GList          *iter;
  int32_t         fill, n;

  /* *count reset on every failure, including a NULL engine below. */
  if (count)
    *count = 0;
  if (! engine)
    return GLIMS_STATUS_NOT_RUNNING;
  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! kind_valid (kind))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (! count || capacity < 0 || (capacity > 0 && ! out))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* The item tree's borrowed selected list, never freed; ids copied out
   * immediately. Plain read — no readiness gate. */
  selected = selected_of_kind (open->image, kind);
  *count = (int32_t) g_list_length (selected);
  fill   = out ? capacity : 0;
  for (iter = selected, n = 0; iter && n < fill; iter = iter->next, n++)
    out[n] = gimp_item_get_id (GIMP_ITEM (iter->data));

  return GLIMS_STATUS_OK;
}

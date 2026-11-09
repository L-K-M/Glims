/*
 * EDIT facade slot 135: image_item_set_edit — one undoable edit (CREATE /
 * REPLACE / RENAME / REMOVE) of one fixed saved set, addressed by its
 * CURRENT identity token (slots 133/134), never by name. Runs on the
 * engine thread. All validation (op/kind ranges, strict field relevance,
 * the full-name contract, member ids), the edit-readiness gate and the
 * token-exhaustion preflight happen BEFORE any mutation, so every refused
 * or failed call preserves state, history and dirty exactly. The mutation
 * reuses the accepted commands (item-sets-undo.c); outToken is zeroed at
 * entry and on every failure, and on success holds the resulting set's
 * token (fresh after a mutation, current after a no-op; 0 after REMOVE).
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimpitemlist.h"
#include "core/gimplayer.h"
#include "core/gimpobject.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimppath.h"
#else
#include "vectors/gimppath.h"
#endif

#define GLIMS_ITEM_SET_NAME_MAX_BYTES 255u

static GlimsStatus
fail (char **error, const char *message)
{
  if (error) *error = g_strdup (message);
  return GLIMS_STATUS_INVALID_ARGUMENT;
}

/* The native item kind of a facade kind; 0 for an unknown kind. */
static GType
kind_gtype (uint32_t kind)
{
  switch (kind)
    {
    case GLIMS_ITEM_SET_LAYER:   return GIMP_TYPE_LAYER;
    case GLIMS_ITEM_SET_CHANNEL: return GIMP_TYPE_CHANNEL;
    case GLIMS_ITEM_SET_PATH:    return GIMP_TYPE_PATH;
    default:                     return 0;
    }
}

/* Full-name contract: nonempty, valid UTF-8, no control characters, at
 * most 255 bytes. A NUL-terminated C string cannot carry an embedded NUL;
 * the Swift side preflights that. */
static GlimsStatus
validate_name (const char *name, char **error)
{
  const char *p;

  if (! name || *name == '\0')
    return fail (error, "A saved set needs a nonempty name.");
  if (strlen (name) > GLIMS_ITEM_SET_NAME_MAX_BYTES)
    return fail (error, "A saved-set name is at most 255 bytes.");
  if (! g_utf8_validate (name, -1, NULL))
    return fail (error, "A saved-set name must be valid UTF-8.");
  for (p = name; *p; p = g_utf8_next_char (p))
    if (g_unichar_iscntrl (g_utf8_get_char (p)))
      return fail (error, "A saved-set name must not contain control characters.");
  return GLIMS_STATUS_OK;
}

/* Resolves the member id list into `out` (caller-allocated, `count` slots):
 * every id positive (0 never means the current selection), live, attached
 * to this image, of the set's kind, and unique. */
static GlimsStatus
resolve_members (GlimsEngine *e, GimpImage *image, GType kind,
                 const GlimsItemID *ids, int32_t count, GimpItem **out, char **error)
{
  for (int32_t i = 0; i < count; i++)
    {
      GimpItem *item;

      if (ids[i] <= 0)
        return fail (error, "A saved-set member id must be positive.");
      item = gimp_item_get_by_id (e->gimp, ids[i]);
      if (! item || ! GIMP_IS_ITEM (item))
        return fail (error, "A saved-set member id names no live item.");
      if (gimp_item_get_image (item) != image)
        return fail (error, "A saved-set member belongs to another image.");
      if (! gimp_item_is_attached (item))
        return fail (error, "A saved-set member is not attached to the image.");
      if (! g_type_is_a (G_OBJECT_TYPE (item), kind))
        return fail (error, "A saved-set member is not an item of the set's kind.");
      for (int32_t j = 0; j < i; j++)
        if (out[j] == item)
          return fail (error, "A saved-set member is listed twice.");
      out[i] = item;
    }
  return GLIMS_STATUS_OK;
}

/* Borrowed fixed (non-pattern) set of `kind` with exactly this full name. */
static GimpItemList *
find_fixed_by_name (GimpImage *image, GType kind, const char *name)
{
  for (GList *iter = gimp_image_get_stored_item_sets (image, kind); iter; iter = iter->next)
    {
      GimpItemList *native = iter->data;
      if (! gimp_item_list_is_pattern (native, NULL) &&
          g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (native)), name) == 0)
        return native;
    }
  return NULL;
}

GlimsStatus
glims_image_item_set_edit (GlimsEngine *e, GlimsImageID image, uint32_t operation,
                           uint32_t kind, uint64_t token, const char *name,
                           const GlimsItemID *members, int32_t count,
                           uint64_t *outToken, char **error)
{
  GlimsOpenImage *open;
  GlimsItemSets *manager;
  GType gkind;
  GlimsStatus status;
  GimpItemList *native = NULL;
  GimpItem *items = NULL;
  gchar *set_name = NULL;      /* owned full name of the token's set */
  const char *result_name;

  if (outToken)
    *outToken = 0;

  if (operation < GLIMS_ITEM_SET_EDIT_CREATE || operation > GLIMS_ITEM_SET_EDIT_REMOVE)
    return fail (error, "Unknown saved-set edit operation.");
  gkind = kind_gtype (kind);
  if (! gkind)
    return fail (error, "Unknown saved-set kind.");
  if (count < 0 || (count > 0 && members == NULL))
    return fail (error, "A saved-set member list needs count 0 or a valid array.");
  switch (operation)
    {
    case GLIMS_ITEM_SET_EDIT_CREATE:
      if (token != 0)
        return fail (error, "CREATE takes token 0.");
      break;
    case GLIMS_ITEM_SET_EDIT_REPLACE:
      if (token == 0 || name != NULL)
        return fail (error, "REPLACE takes a current token and explicit members only.");
      break;
    case GLIMS_ITEM_SET_EDIT_RENAME:
      if (token == 0 || count != 0)
        return fail (error, "RENAME takes a current token and the desired name only.");
      break;
    default: /* REMOVE */
      if (token == 0 || name != NULL || count != 0)
        return fail (error, "REMOVE takes a current token only.");
      break;
    }
  if (operation == GLIMS_ITEM_SET_EDIT_CREATE || operation == GLIMS_ITEM_SET_EDIT_RENAME)
    {
      status = validate_name (name, error);
      if (status != GLIMS_STATUS_OK)
        return status;
    }

  open = glims_lookup_image (e, image);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  /* Write gate first: refuse while a stroke, filter preview or plug-in
   * holds the image, before any state is touched. */
  status = glims_edit_ready (e, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  manager = open->item_sets;
  if (! manager)
    {
      if (error) *error = g_strdup ("The image has no saved-set manager.");
      return GLIMS_STATUS_FAILED;   /* fail closed */
    }


  if (operation != GLIMS_ITEM_SET_EDIT_CREATE)
    {
      /* Identity by token only, within this image AND kind; foreign, stale
       * or expired tokens resolve to nothing and are never retargeted. */
      native = glims_item_sets_resolve (manager, token, gkind);
      if (! native)
        return GLIMS_STATUS_NOT_FOUND;
      set_name = g_strdup (gimp_object_get_name (GIMP_OBJECT (native)));
      g_object_unref (native);
    }

  if (operation == GLIMS_ITEM_SET_EDIT_CREATE || operation == GLIMS_ITEM_SET_EDIT_REPLACE)
    {
      items = g_new (GimpItem *, count > 0 ? count : 1);
      status = resolve_members (e, open->image, gkind, members, count, items, error);
      if (status != GLIMS_STATUS_OK)
        {
          g_free (items);
          g_free (set_name);
          return status;
        }
    }

  /* Preflight identity exhaustion before ANY mutation: CREATE/REPLACE/
   * RENAME mint a fresh token for the resulting set and fail closed at
   * UINT64_MAX. */
  if (operation != GLIMS_ITEM_SET_EDIT_REMOVE && glims_item_sets_token_exhausted (manager))
    {
      if (error) *error = g_strdup ("The engine's saved-set identity space is exhausted.");
      g_free (items);
      g_free (set_name);
      return GLIMS_STATUS_FAILED;
    }

  switch (operation)
    {
    case GLIMS_ITEM_SET_EDIT_CREATE:
      status = glims_item_sets_create (open->image, gkind, name, items, count, error);
      result_name = name;
      break;
    case GLIMS_ITEM_SET_EDIT_REPLACE:
      status = glims_item_sets_replace (open->image, gkind, set_name, items, count, error);
      result_name = set_name;
      break;
    case GLIMS_ITEM_SET_EDIT_RENAME:
      status = glims_item_sets_rename (open->image, gkind, set_name, name, error);
      result_name = name;
      break;
    default:
      status = glims_item_sets_remove (open->image, gkind, set_name, error);
      result_name = NULL;
      break;
    }

  g_free (items);
  g_free (set_name);
  if (status != GLIMS_STATUS_OK)
    return status;

  if (operation != GLIMS_ITEM_SET_EDIT_REMOVE && outToken)
    {
      GimpItemList *result = find_fixed_by_name (open->image, gkind, result_name);
      *outToken = result ? glims_item_sets_token_of (manager, result) : 0;
    }
  return GLIMS_STATUS_OK;
}

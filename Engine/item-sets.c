/*
 * Preserve fixed item-set identities across structural edits. Native item
 * lists watch only root containers and can restore nonmembers on Undo.
 * Our mirror holds weak identities, never detached items or raw stale IDs.
 * All callbacks and accesses run on the engine thread.
 */
#include "engine-private.h"

#include "core/core-enums.h"
#include "core/gimpcontainer.h"
#include "core/gimpchannel.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimpitemlist.h"
#include "core/gimplayer.h"
#include "core/gimpobject.h"
#include "core/gimpundo.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimppath.h"
#else
#include "vectors/gimppath.h"
#endif
#include "core/gimpviewable.h"

typedef struct
{
  GWeakRef object;
} WeakItem;

typedef struct
{
  GWeakRef   native;
  GType      kind;
  GPtrArray *members;             /* WeakItem*, original membership order */
  uint64_t   token;               /* facade identity (slots 133/134), from the
                                   * engine's monotonic counter; 0 = none
                                   * (counter exhausted: fail closed). Stable
                                   * across quiet live-member replacement
                                   * (rebuild_sets keeps this FixedSet); the
                                   * whole struct — and so the token — dies
                                   * when the set is removed or undo-replaced,
                                   * which expires the token for good. */
  gboolean   seen;
} FixedSet;

typedef struct
{
  GWeakRef container;
  gulong   added;
  gulong   removed;
} ContainerWatch;

struct GlimsItemSets
{
  GimpImage  *image;              /* borrowed; manager dies before image */
  GlimsEngine *engine;            /* borrowed; the engine outlives its images;
                                   * source of the monotonic token counter */
  GPtrArray  *sets;               /* FixedSet* */
  GPtrArray  *watches;            /* ContainerWatch* */
  gulong      sets_changed;
  gulong      undo_event;
  gboolean    rebuilding;
};

static void rebuild_sets (GlimsItemSets *manager);
static void watch_container (GlimsItemSets *manager, GimpContainer *container);

#define ITEM_SETS_DATA_KEY "glims-owned-item-set-manager"

static void
weak_item_free (gpointer data)
{
  WeakItem *item = data;
  g_weak_ref_clear (&item->object);
  g_free (item);
}

static void
fixed_set_free (gpointer data)
{
  FixedSet *set = data;
  g_weak_ref_clear (&set->native);
  g_ptr_array_unref (set->members);
  g_free (set);
}

static void
container_watch_free (gpointer data)
{
  ContainerWatch *watch = data;
  GObject *container = g_weak_ref_get (&watch->container);
  if (container)
    {
      g_signal_handler_disconnect (container, watch->added);
      g_signal_handler_disconnect (container, watch->removed);
      g_object_unref (container);
    }
  g_weak_ref_clear (&watch->container);
  g_free (watch);
}

/* Build an address set only from the image's current owned tree. Native
 * get_items() pointers must match this before any cast or dereference. */
static GHashTable *
live_items (GlimsItemSets *manager)
{
  GHashTable *live = g_hash_table_new (g_direct_hash, g_direct_equal);
  GList *lists[3] = { gimp_image_get_layer_list (manager->image),
                      gimp_image_get_channel_list (manager->image),
                      gimp_image_get_path_list (manager->image) };
  for (guint i = 0; i < G_N_ELEMENTS (lists); i++)
    {
      for (GList *iter = lists[i]; iter; iter = iter->next)
        g_hash_table_add (live, iter->data);
      g_list_free (lists[i]);
    }
  return live;
}

static FixedSet *
find_set (GlimsItemSets *manager, GimpItemList *native)
{
  for (guint i = 0; i < manager->sets->len; i++)
    {
      FixedSet *set = g_ptr_array_index (manager->sets, i);
      GObject *object = g_weak_ref_get (&set->native);
      gboolean matches = object == (GObject *) native;
      g_clear_object (&object);
      if (matches)
        return set;
    }
  return NULL;
}

/* The next facade identity token for a newly adopted fixed set, from the
 * engine's monotonic counter. Fail closed at exhaustion: 0 means "no
 * identity", is never issued otherwise and is never reused; the set is
 * still listed (with token 0) and slot 134 refuses to resolve it. */
static uint64_t
next_set_token (GlimsItemSets *manager)
{
  if (! manager->engine || manager->engine->next_item_set_token == G_MAXUINT64)
    return 0;
  manager->engine->next_item_set_token += 1;
  return manager->engine->next_item_set_token;
}

/* Import only new set objects. Re-reading an existing native object's
 * members after Undo would adopt the very corruption the mirror avoids.
 * At initial adoption, file loading has finished and members are live. */
static void
sync_definitions (GlimsItemSets *manager, GType kind)
{
  GHashTable *live = live_items (manager);
  for (guint i = 0; i < manager->sets->len; i++)
    {
      FixedSet *set = g_ptr_array_index (manager->sets, i);
      if (set->kind == kind)
        set->seen = FALSE;
    }
  for (GList *iter = gimp_image_get_stored_item_sets (manager->image, kind);
       iter; iter = iter->next)
    {
      GimpItemList *native = iter->data;
      FixedSet *set;
      if (gimp_item_list_is_pattern (native, NULL))
        continue;
      set = find_set (manager, native);
      if (! set)
        {
          GList *members = gimp_item_list_get_items (native, NULL);
          set = g_new0 (FixedSet, 1);
          g_weak_ref_init (&set->native, native);
          set->kind = kind;
          set->token = next_set_token (manager);
          set->members = g_ptr_array_new_with_free_func (weak_item_free);
          for (GList *member = members; member; member = member->next)
            {
              if (g_hash_table_contains (live, member->data))
                {
                  WeakItem *weak = g_new0 (WeakItem, 1);
                  g_weak_ref_init (&weak->object, member->data);
                  g_ptr_array_add (set->members, weak);
                }
            }
          g_list_free (members);
          g_ptr_array_add (manager->sets, set);
        }
      set->seen = TRUE;
    }
  for (guint i = 0; i < manager->sets->len; )
    {
      FixedSet *set = g_ptr_array_index (manager->sets, i);
      if (set->kind == kind && ! set->seen)
        g_ptr_array_remove_index (manager->sets, i);
      else
        i++;
    }
  g_hash_table_unref (live);
}

static void
sets_changed (GimpImage *image, GType kind, GlimsItemSets *manager)
{
  (void) image;
  if (! manager->rebuilding)
    sync_definitions (manager, kind);
}

/* Undo/redo pops and stack expiry/purge can change which members are live
 * (a saved-set undo restores definitions; a layer undo detaches or
 * reattaches members; expiry finalizes them). Rebuild the replacements so
 * exposed membership is again exactly the live members; the mirror keeps
 * detached-but-alive members weakly known for Undo and drops finalized
 * ones. Quiet: store/unlink add no undo step and no dirty flag. */
static void
undo_event (GimpImage *image, GimpUndoEvent event, GimpUndo *undo, GlimsItemSets *manager)
{
  (void) image;
  (void) undo;
  switch (event)
    {
    case GIMP_UNDO_EVENT_UNDO:
    case GIMP_UNDO_EVENT_REDO:
    case GIMP_UNDO_EVENT_UNDO_EXPIRED:
    case GIMP_UNDO_EVENT_REDO_EXPIRED:
    case GIMP_UNDO_EVENT_UNDO_FREE:
      rebuild_sets (manager);
      break;

    default:
      break;
    }
}

static void
container_changed (GimpContainer *container, GimpObject *item, GlimsItemSets *manager)
{
  GimpContainer *children;
  (void) container;
  children = gimp_viewable_get_children (GIMP_VIEWABLE (item));
  if (children)
    watch_container (manager, children);
  rebuild_sets (manager);
}

static void
watch_container (GlimsItemSets *manager, GimpContainer *container)
{
  for (guint i = 0; i < manager->watches->len; )
    {
      ContainerWatch *watch = g_ptr_array_index (manager->watches, i);
      GObject *current = g_weak_ref_get (&watch->container);
      gboolean matches = current == (GObject *) container;
      if (! current)
        {
          g_ptr_array_remove_index (manager->watches, i);
          continue;
        }
      g_object_unref (current);
      if (matches)
        return;
      i++;
    }
  ContainerWatch *watch = g_new0 (ContainerWatch, 1);
  g_weak_ref_init (&watch->container, container);
  /* Native fixed-set callbacks run first. Replacement must follow them,
   * including the root-add callback that can reinsert a nonmember. */
  watch->added = g_signal_connect_after (container, "add", G_CALLBACK (container_changed), manager);
  watch->removed = g_signal_connect_after (container, "remove", G_CALLBACK (container_changed), manager);
  g_ptr_array_add (manager->watches, watch);
  for (gint i = 0; i < gimp_container_get_n_children (container); i++)
    {
      GimpObject *item = gimp_container_get_child_by_index (container, i);
      GimpContainer *children = gimp_viewable_get_children (GIMP_VIEWABLE (item));
      if (children)
        watch_container (manager, children);
    }
}

static void
rebuild_sets (GlimsItemSets *manager)
{
  const GType kinds[] = { GIMP_TYPE_LAYER, GIMP_TYPE_CHANNEL, GIMP_TYPE_PATH };
  GHashTable *live;
  if (manager->rebuilding || manager->sets->len == 0)
    return;
  manager->rebuilding = TRUE;
  live = live_items (manager);
  for (guint kind = 0; kind < G_N_ELEMENTS (kinds); kind++)
    {
      GPtrArray *replacements = g_ptr_array_new_with_free_func (g_object_unref);
      GList *order = gimp_image_get_stored_item_sets (manager->image, kinds[kind]);
      for (GList *iter = order; iter; iter = iter->next)
        {
          GimpItemList *native = iter->data;
          FixedSet *set = find_set (manager, native);
          if (! set)
            {
              /* Pattern definitions keep their native computed behavior. */
              g_ptr_array_add (replacements, g_object_ref (native));
              continue;
            }
          GList *members = NULL;
          for (guint i = 0; i < set->members->len; )
            {
              WeakItem *weak = g_ptr_array_index (set->members, i);
              GObject *object = g_weak_ref_get (&weak->object);
              if (! object)
                {
                  g_ptr_array_remove_index (set->members, i);
                  continue;
                }
              if (g_hash_table_contains (live, object))
                members = g_list_prepend (members, object);
              /* The current tree owns attached objects; detached objects
               * are never added to the replacement or held by the mirror. */
              g_object_unref (object);
              i++;
            }
          members = g_list_reverse (members);
          /* named_new(NULL) means "current selection". Construct directly
           * so a genuinely empty set stays empty. No private layouts. */
          GimpItemList *replacement = g_object_new (GIMP_TYPE_ITEM_LIST,
            "image", manager->image, "name", gimp_object_get_name (native),
            "is-pattern", FALSE, "item-type", kinds[kind], "items", members, NULL);
          g_list_free (members);
          g_weak_ref_set (&set->native, replacement);
          g_ptr_array_add (replacements, replacement);
        }
      /* store_item_set prepends. Re-store every definition in reverse
       * order, patterns included, to preserve the whole native ordering. */
      for (guint i = replacements->len; i > 0; i--)
        gimp_image_store_item_set (manager->image,
          g_object_ref (g_ptr_array_index (replacements, i - 1)));
      g_ptr_array_unref (replacements);
    }
  g_hash_table_unref (live);
  manager->rebuilding = FALSE;
}

GlimsItemSets *
glims_item_sets_new (GlimsEngine *engine, GimpImage *image)
{
  const GType kinds[] = { GIMP_TYPE_LAYER, GIMP_TYPE_CHANNEL, GIMP_TYPE_PATH };
  GlimsItemSets *manager = g_new0 (GlimsItemSets, 1);
  manager->image = image;
  manager->engine = engine;
  manager->sets = g_ptr_array_new_with_free_func (fixed_set_free);
  manager->watches = g_ptr_array_new_with_free_func (container_watch_free);
  for (guint i = 0; i < G_N_ELEMENTS (kinds); i++)
    sync_definitions (manager, kinds[i]);
  watch_container (manager, gimp_image_get_layers (image));
  watch_container (manager, gimp_image_get_channels (image));
  watch_container (manager, gimp_image_get_paths (image));
  manager->sets_changed = g_signal_connect (image, "item-sets-changed", G_CALLBACK (sets_changed), manager);
  manager->undo_event = g_signal_connect (image, "undo-event", G_CALLBACK (undo_event), manager);
  g_object_set_data (G_OBJECT (image), ITEM_SETS_DATA_KEY, manager);
  return manager;
}

void
glims_item_sets_free (GlimsItemSets *manager)
{
  if (! manager)
    return;
  g_object_set_data (G_OBJECT (manager->image), ITEM_SETS_DATA_KEY, NULL);
  g_signal_handler_disconnect (manager->image, manager->sets_changed);
  g_signal_handler_disconnect (manager->image, manager->undo_event);
  g_ptr_array_unref (manager->watches);
  g_ptr_array_unref (manager->sets);
  g_free (manager);
}

GlimsItemSets *
glims_item_sets_lookup (GimpImage *image)
{
  return g_object_get_data (G_OBJECT (image), ITEM_SETS_DATA_KEY);
}

/* Snapshot all still-alive identities, including detached objects owned by
 * deletion Undo. The exposed native list intentionally contains only attached
 * members and cannot represent the definition that a later Undo must restore.
 * This array owns refs; the manager continues to hold only weak refs. */
GPtrArray *
glims_item_sets_copy_members (GlimsItemSets *manager, GimpItemList *native)
{
  FixedSet *set = find_set (manager, native);
  GPtrArray *members = g_ptr_array_new_with_free_func (g_object_unref);
  g_return_val_if_fail (set != NULL, members);
  for (guint i = 0; i < set->members->len; i++)
    {
      WeakItem *weak = g_ptr_array_index (set->members, i);
      GObject *object = g_weak_ref_get (&weak->object);
      if (object) g_ptr_array_add (members, object);
    }
  return members;
}

/* store_item_set emits its signal synchronously and imports a live-only
 * definition. Replace that imported mirror with the snapshot's full weak
 * definition before the final refresh reconstructs the exposed live list. */
void
glims_item_sets_restore_members (GlimsItemSets *manager, GimpItemList *native,
                                 const GPtrArray *members)
{
  FixedSet *set = find_set (manager, native);
  g_return_if_fail (set != NULL);
  g_ptr_array_set_size (set->members, 0);
  for (guint i = 0; i < members->len; i++)
    {
      WeakItem *weak = g_new0 (WeakItem, 1);
      g_weak_ref_init (&weak->object, g_ptr_array_index (members, i));
      g_ptr_array_add (set->members, weak);
    }
}

void
glims_item_sets_refresh (GlimsItemSets *manager)
{
  rebuild_sets (manager);
}

/* ---- READ-ONLY facade queries (slots 133/134) --------------------------
 * Plain reads on the engine thread: no busy gate, no mutation, no
 * dirty/history/selection change. The only references taken are transient
 * weak-ref gets, released before returning; nothing is retained. */

/* The facade kind of a manager kind; the GType never leaves the adapter. */
static uint32_t
facade_kind (GType kind)
{
  if (kind == GIMP_TYPE_LAYER)
    return GLIMS_ITEM_SET_LAYER;
  if (kind == GIMP_TYPE_CHANNEL)
    return GLIMS_ITEM_SET_CHANNEL;
  if (kind == GIMP_TYPE_PATH)
    return GLIMS_ITEM_SET_PATH;
  return 0;
}

/* Copies `text` into `buffer` as a display label: valid UTF-8, truncated
 * at most to `size` - 1 bytes, never inside a multi-byte character, always
 * NUL-terminated. Display only — never an identity. */
static void
copy_display_name (char *buffer, size_t size, const gchar *text)
{
  gchar *valid = g_utf8_make_valid (text ? text : "", -1);
  size_t length = strlen (valid);

  if (length > size - 1)
    {
      length = size - 1;
      while (length > 0 && (valid[length] & 0xC0) == 0x80)
        length--;
    }

  memcpy (buffer, valid, length);
  buffer[length] = '\0';
  g_free (valid);
}

/* Walks the mirror's weak members and reports only the ones that are
 * alive AND currently attached to the manager's image: deleted or
 * detached weak members are skipped. Fills `out` up to `capacity` with
 * their item ids in stored membership order and returns the total live
 * count. `out` NULL means count-only. Transient refs only. */
static guint
live_members (GlimsItemSets *manager, FixedSet *set, GlimsItemID *out, int32_t capacity)
{
  guint count = 0;

  for (guint i = 0; i < set->members->len; i++)
    {
      WeakItem *weak = g_ptr_array_index (set->members, i);
      GObject *object = g_weak_ref_get (&weak->object);

      if (! object)
        continue;                 /* finalized: a deleted weak member */
      if (GIMP_IS_ITEM (object) &&
          gimp_item_get_image (GIMP_ITEM (object)) == manager->image &&
          gimp_item_is_attached (GIMP_ITEM (object)))
        {
          if (out && count < (guint) capacity)
            out[count] = gimp_item_get_id (GIMP_ITEM (object));
          count++;
        }
      g_object_unref (object);
    }
  return count;
}

static FixedSet *
find_set_by_token (GlimsItemSets *manager, uint64_t token)
{
  for (guint i = 0; i < manager->sets->len; i++)
    {
      FixedSet *set = g_ptr_array_index (manager->sets, i);
      /* Tokens are unique per engine, so a token owned by another image of
       * this engine — or issued by a foreign engine — simply matches no
       * set here and is refused by the caller as NOT_FOUND. */
      if (set->token != 0 && set->token == token)
        return set;
    }
  return NULL;
}

GlimsStatus
glims_item_sets_list (GlimsItemSets *manager, GlimsItemSetInfo *rows,
                      int32_t capacity, int32_t *count)
{
  const GType kinds[] = { GIMP_TYPE_LAYER, GIMP_TYPE_CHANNEL, GIMP_TYPE_PATH };
  int32_t cap, total = 0;

  if (! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *count = 0;
  if (! manager)
    return GLIMS_STATUS_FAILED;   /* no manager: fail closed */

  cap = rows ? capacity : 0;
  for (guint k = 0; k < G_N_ELEMENTS (kinds); k++)
    {
      /* Stored-list order per kind, kinds in GlimsItemSetKind order;
       * pattern definitions are computed, never listed. */
      for (GList *iter = gimp_image_get_stored_item_sets (manager->image, kinds[k]);
           iter; iter = iter->next)
        {
          GimpItemList *native = iter->data;
          FixedSet *set;

          if (gimp_item_list_is_pattern (native, NULL))
            continue;
          set = find_set (manager, native);
          if (! set)
            continue;
          if (total < cap)
            {
              GlimsItemSetInfo *row = &rows[total];

              memset (row, 0, sizeof (*row));
              row->token = set->token;
              row->kind = facade_kind (set->kind);
              row->member_count = (int32_t) live_members (manager, set, NULL, 0);
              copy_display_name (row->display_name, sizeof (row->display_name),
                                 gimp_object_get_name (GIMP_OBJECT (native)));
            }
          total++;
        }
    }
  *count = total;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_item_sets_members_of (GlimsItemSets *manager, uint64_t token,
                            GlimsItemID *out, int32_t capacity, int32_t *count)
{
  FixedSet *set;

  if (! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *count = 0;
  if (token == 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;  /* never issued; no identity */
  if (! manager)
    return GLIMS_STATUS_FAILED;            /* no manager: fail closed */

  set = find_set_by_token (manager, token);
  if (! set)
    return GLIMS_STATUS_NOT_FOUND;         /* foreign, stale or expired */

  *count = (int32_t) live_members (manager, set, out, out ? capacity : 0);
  return GLIMS_STATUS_OK;
}

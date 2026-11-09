/*
 * Native undo steps for explicit saved-set edits (CREATE/REPLACE/RENAME/
 * REMOVE). Each command is one atomic GimpUndo of the adapter-owned subtype
 * GlimsItemSetsUndo, pushed in the internal image-metadata category
 * (GIMP_UNDO_IMAGE_METADATA with GIMP_DIRTY_IMAGE_META — the category GIMP's
 * own metadata/grid/guide undos use; source-verified that no engine consumer
 * switches on that category for non-GimpImageUndo objects, and the push
 * predicate accepts any GimpUndo subtype). The undo owns deep before/after
 * snapshots of the image's whole stored-set list of the affected item kind,
 * including strong member references — what Undo explicitly requires to
 * restore member identity; the item-set manager itself stays weak (see
 * Engine/item-sets.c). Pop restores through the public store/unlink API,
 * which is quiet (no undo step, no dirty flag); the wrapper balances dirty
 * from the dirty mask.
 *
 * Engine-internal only: no facade slot, no API-version change. All entry
 * points run on the engine thread.
 */
#include "engine-private.h"

#include "core/core-enums.h"
#include "core/gimpchannel.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
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

/* ---- owned snapshots --------------------------------------------------- */

typedef struct
{
  gchar           *name;        /* owned; for pattern sets this is the pattern */
  gboolean         is_pattern;
  GimpSelectMethod method;      /* valid when is_pattern */
  GPtrArray       *members;     /* owned GObject* refs in stored order; fixed sets only */
} GlimsSetDef;

typedef struct
{
  GType      kind;
  GPtrArray *defs;              /* GlimsSetDef*, stored-list order */
} GlimsSetSnapshot;

static void
set_def_free (gpointer data)
{
  GlimsSetDef *def = data;
  g_free (def->name);
  g_ptr_array_unref (def->members);
  g_free (def);
}

static void
snapshot_free (gpointer data)
{
  GlimsSetSnapshot *snap = data;
  if (! snap)
    return;
  g_ptr_array_unref (snap->defs);
  g_free (snap);
}

/* Native Undo limits use get_memsize(), so count the owned definitions,
 * not just the subclass's object shell. As with GimpLayerUndo, attached
 * items belong to the live image's accounting; detached items retained
 * solely for restoration must also be counted. Deduplicate those objects
 * across both snapshots of this step. Container sizes are estimates, like
 * the native core's other collection accounting. */
static gint64
snapshot_memsize (const GlimsSetSnapshot *snap, GHashTable *counted, gint64 *gui_size)
{
  gint64 size;
  if (! snap) return 0;
  size = sizeof (*snap) + sizeof (GPtrArray) + snap->defs->len * sizeof (gpointer);
  for (guint i = 0; i < snap->defs->len; i++)
    {
      GlimsSetDef *def = g_ptr_array_index (snap->defs, i);
      size += sizeof (*def) + (def->name ? strlen (def->name) + 1 : 0)
              + sizeof (GPtrArray) + def->members->len * sizeof (gpointer);
      for (guint j = 0; j < def->members->len; j++)
        {
          GimpItem *item = g_ptr_array_index (def->members, j);
          if (! gimp_item_is_attached (item) && g_hash_table_add (counted, item))
            size += gimp_object_get_memsize (GIMP_OBJECT (item), gui_size);
        }
    }
  return size;
}

/* Deep copy of the image's whole stored-set list of `kind`, in stored-list
 * order. Members are strong-reffed: the snapshot must keep them alive across
 * a member's own deletion undo, so a later pop can restore the same live
 * identity. Released by the undo's free handler on expiry/purge. */
static GlimsSetSnapshot *
capture_snapshot (GimpImage *image, GType kind)
{
  GlimsSetSnapshot *snap = g_new0 (GlimsSetSnapshot, 1);

  snap->kind = kind;
  snap->defs = g_ptr_array_new_with_free_func (set_def_free);
  for (GList *iter = gimp_image_get_stored_item_sets (image, kind); iter; iter = iter->next)
    {
      GimpItemList    *native = iter->data;
      GlimsSetDef     *def = g_new0 (GlimsSetDef, 1);
      GimpSelectMethod method = 0;

      def->name = g_strdup (gimp_object_get_name (native));
      def->is_pattern = gimp_item_list_is_pattern (native, &method);
      def->method = method;
      def->members = g_ptr_array_new_with_free_func (g_object_unref);
      if (! def->is_pattern)
        {
          g_ptr_array_unref (def->members);
          def->members = glims_item_sets_copy_members (glims_item_sets_lookup (image), native);
        }
      g_ptr_array_add (snap->defs, def);
    }
  return snap;
}

/* Restore the whole stored-set list of the snapshot's kind through the
 * public API. store_item_set prepends, so store in reverse to keep the
 * stored-list order. store/unlink emit item-sets-changed (the manager
 * re-syncs) but add no undo step and no dirty flag. */
static void
restore_snapshot (GimpImage *image, const GlimsSetSnapshot *snap)
{
  GList *current = g_list_copy (gimp_image_get_stored_item_sets (image, snap->kind));

  for (GList *iter = current; iter; iter = iter->next)
    gimp_image_unlink_item_set (image, iter->data);
  g_list_free (current);

  for (guint i = snap->defs->len; i > 0; i--)
    {
      GlimsSetDef  *def = g_ptr_array_index (snap->defs, i - 1);
      GimpItemList *set;

      if (def->is_pattern)
        {
          set = g_object_new (GIMP_TYPE_ITEM_LIST,
                              "image",         image,
                              "name",          def->name,
                              "is-pattern",    TRUE,
                              "select-method", def->method,
                              "item-type",     snap->kind,
                              NULL);
        }
      else
        {
          GList *items = NULL;
          for (guint m = 0; m < def->members->len; m++)
            {
              GimpItem *member = g_ptr_array_index (def->members, m);
              if (gimp_item_get_image (member) == image && gimp_item_is_attached (member))
                items = g_list_prepend (items, member);
            }
          items = g_list_reverse (items);
          /* items=NULL is an explicit empty set (the xcf-load route);
           * never named_new(NULL), which captures the active selection. */
          set = g_object_new (GIMP_TYPE_ITEM_LIST,
                              "image",      image,
                              "name",       def->name,
                              "is-pattern", FALSE,
                              "item-type",  snap->kind,
                              "items",      items,
                              NULL);
          g_list_free (items);
        }
      gimp_image_store_item_set (image, set); /* transfer full */
      if (! def->is_pattern)
        glims_item_sets_restore_members (glims_item_sets_lookup (image), set, def->members);
    }
  glims_item_sets_refresh (glims_item_sets_lookup (image));
}

/* ---- the undo subtype --------------------------------------------------- */

typedef struct _GlimsItemSetsUndo      GlimsItemSetsUndo;
typedef struct _GlimsItemSetsUndoClass GlimsItemSetsUndoClass;

struct _GlimsItemSetsUndo
{
  GimpUndo          parent_instance;
  GlimsSetSnapshot *before;       /* owned; construct-only */
  GlimsSetSnapshot *after;        /* owned; construct-only */
};

struct _GlimsItemSetsUndoClass
{
  GimpUndoClass parent_class;
};

#define GLIMS_TYPE_ITEM_SETS_UNDO (glims_item_sets_undo_get_type ())
#define GLIMS_ITEM_SETS_UNDO(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST ((obj), GLIMS_TYPE_ITEM_SETS_UNDO, GlimsItemSetsUndo))

G_DEFINE_TYPE (GlimsItemSetsUndo, glims_item_sets_undo, GIMP_TYPE_UNDO)

enum
{
  PROP_0,
  PROP_BEFORE,
  PROP_AFTER
};

static gint64
glims_item_sets_undo_get_memsize (GimpObject *object, gint64 *gui_size)
{
  GlimsItemSetsUndo *self = GLIMS_ITEM_SETS_UNDO (object);
  GHashTable *counted = g_hash_table_new (g_direct_hash, g_direct_equal);
  gint64 size = snapshot_memsize (self->before, counted, gui_size)
                + snapshot_memsize (self->after, counted, gui_size);
  g_hash_table_unref (counted);
  return size + GIMP_OBJECT_CLASS (glims_item_sets_undo_parent_class)->get_memsize (object, gui_size);
}

static void
glims_item_sets_undo_pop (GimpUndo *undo, GimpUndoMode undo_mode, GimpUndoAccumulator *accum)
{
  GlimsItemSetsUndo *self = GLIMS_ITEM_SETS_UNDO (undo);

  GIMP_UNDO_CLASS (glims_item_sets_undo_parent_class)->pop (undo, undo_mode, accum);

  restore_snapshot (undo->image,
                    undo_mode == GIMP_UNDO_MODE_UNDO ? self->before : self->after);
}

static void
glims_item_sets_undo_free (GimpUndo *undo, GimpUndoMode undo_mode)
{
  GlimsItemSetsUndo *self = GLIMS_ITEM_SETS_UNDO (undo);

  /* Stack teardown releases the owned snapshots (and with them the strong
   * member refs) before the object is unreffed. */
  if (self->before)
    {
      snapshot_free (self->before);
      self->before = NULL;
    }
  if (self->after)
    {
      snapshot_free (self->after);
      self->after = NULL;
    }

  GIMP_UNDO_CLASS (glims_item_sets_undo_parent_class)->free (undo, undo_mode);
}

static void
glims_item_sets_undo_finalize (GObject *object)
{
  GlimsItemSetsUndo *self = GLIMS_ITEM_SETS_UNDO (object);

  /* Defensive only: the stack always emits "free" before unreffing. */
  if (self->before)
    {
      snapshot_free (self->before);
      self->before = NULL;
    }
  if (self->after)
    {
      snapshot_free (self->after);
      self->after = NULL;
    }

  G_OBJECT_CLASS (glims_item_sets_undo_parent_class)->finalize (object);
}

static void
glims_item_sets_undo_set_property (GObject *object, guint property_id,
                                   const GValue *value, GParamSpec *pspec)
{
  GlimsItemSetsUndo *self = GLIMS_ITEM_SETS_UNDO (object);

  switch (property_id)
    {
    case PROP_BEFORE:
      self->before = g_value_get_pointer (value); /* takes ownership */
      break;
    case PROP_AFTER:
      self->after = g_value_get_pointer (value); /* takes ownership */
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
      break;
    }
}

static void
glims_item_sets_undo_get_property (GObject *object, guint property_id,
                                   GValue *value, GParamSpec *pspec)
{
  GlimsItemSetsUndo *self = GLIMS_ITEM_SETS_UNDO (object);

  switch (property_id)
    {
    case PROP_BEFORE:
      g_value_set_pointer (value, self->before);
      break;
    case PROP_AFTER:
      g_value_set_pointer (value, self->after);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
      break;
    }
}

static void
glims_item_sets_undo_class_init (GlimsItemSetsUndoClass *klass)
{
  GObjectClass      *object_class = G_OBJECT_CLASS (klass);
  GimpObjectClass   *gimp_object_class = GIMP_OBJECT_CLASS (klass);
  GimpUndoClass     *undo_class = GIMP_UNDO_CLASS (klass);

  object_class->finalize = glims_item_sets_undo_finalize;
  object_class->set_property = glims_item_sets_undo_set_property;
  object_class->get_property = glims_item_sets_undo_get_property;
  gimp_object_class->get_memsize = glims_item_sets_undo_get_memsize;

  undo_class->pop = glims_item_sets_undo_pop;
  undo_class->free = glims_item_sets_undo_free;

  /* The snapshots are established at construction, before the push can
   * expire the new undo (gimp_image_undo_push may free it right after
   * pushing when the stack is over its limits). */
  g_object_class_install_property (object_class, PROP_BEFORE,
                                   g_param_spec_pointer ("before", NULL, NULL,
                                                         G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY));
  g_object_class_install_property (object_class, PROP_AFTER,
                                   g_param_spec_pointer ("after", NULL, NULL,
                                                         G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY));
}

static void
glims_item_sets_undo_init (GlimsItemSetsUndo *self)
{
  self->before = NULL;
  self->after = NULL;
}

/* ---- command preflight helpers ------------------------------------------ */

static gboolean
valid_kind (GType kind)
{
  return kind == GIMP_TYPE_LAYER || kind == GIMP_TYPE_CHANNEL || kind == GIMP_TYPE_PATH;
}

static GHashTable *
live_items_for_kind (GimpImage *image, GType kind)
{
  GList *list = NULL;
  GHashTable *live;

  if (kind == GIMP_TYPE_LAYER)
    list = gimp_image_get_layer_list (image);
  else if (kind == GIMP_TYPE_CHANNEL)
    list = gimp_image_get_channel_list (image);
  else
    list = gimp_image_get_path_list (image);

  live = g_hash_table_new (g_direct_hash, g_direct_equal);
  for (GList *iter = list; iter; iter = iter->next)
    g_hash_table_add (live, iter->data);
  g_list_free (list);
  return live;
}

/* Borrowed set, or NULL. Fixed (non-pattern) sets only: pattern definitions
 * are computed, not edited by these commands. */
static GimpItemList *
find_fixed_set (GimpImage *image, GType kind, const char *name)
{
  for (GList *iter = gimp_image_get_stored_item_sets (image, kind); iter; iter = iter->next)
    {
      GimpItemList *native = iter->data;
      if (! gimp_item_list_is_pattern (native, NULL) &&
          g_strcmp0 (gimp_object_get_name (native), name) == 0)
        return native;
    }
  return NULL;
}

static GlimsStatus
validate_members (GimpImage *image, GType kind, GimpItem *const *members, size_t count,
                  GHashTable *live, char **error)
{
  for (size_t i = 0; i < count; i++)
    {
      GimpItem *item = members[i];

      /* Compare pointer values with the owned live tree before type checks:
       * an invalid/detached input must never be dereferenced as a GObject. */
      if (! g_hash_table_contains (live, item))
        {
          if (error) *error = g_strdup ("A saved-set member is not attached to the image.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      if (! GIMP_IS_ITEM (item) || ! g_type_is_a (G_OBJECT_TYPE (item), kind))
        {
          if (error)
            *error = g_strdup ("A saved-set member is not an item of the set's kind.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      if (gimp_item_get_image (item) != image)
        {
          if (error)
            *error = g_strdup ("A saved-set member belongs to another image.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      for (size_t j = 0; j < i; j++)
        if (members[j] == item)
          {
            if (error)
              *error = g_strdup ("A saved-set member is listed twice.");
            return GLIMS_STATUS_INVALID_ARGUMENT;
          }
    }
  return GLIMS_STATUS_OK;
}

/* Multiset equality between the set's current exposed members and the
 * validated request (duplicates were already rejected, so length plus
 * subset implies equality). */
static gboolean
members_equal_current (GimpImage *image, GimpItemList *set, GimpItem *const *members, size_t count)
{
  GPtrArray *items = glims_item_sets_copy_members (glims_item_sets_lookup (image), set);
  gboolean equal = items->len == count;

  for (guint m = 0; equal && m < items->len; m++)
    {
      gboolean found = FALSE;
      for (size_t i = 0; i < count; i++)
        if (members[i] == g_ptr_array_index (items, m))
          {
            found = TRUE;
            break;
          }
      if (! found)
        equal = FALSE;
    }
  g_ptr_array_unref (items);
  return equal;
}

typedef enum
{
  GLIMS_SET_OP_CREATE,
  GLIMS_SET_OP_REPLACE,
  GLIMS_SET_OP_RENAME,
  GLIMS_SET_OP_REMOVE
} GlimsSetOp;

/* One atomic undoable edit. Preflight (validation, no-op detection, frozen
 * check) happens before any mutation, so a refused command preserves state,
 * history and dirty exactly. A successful command mutates through the quiet
 * public store/unlink API and then pushes exactly one undo step holding the
 * owned before/after snapshots. */
static GlimsStatus
run_set_command (GimpImage *image, GType kind, const char *name, const char *new_name,
                 GimpItem *const *members, size_t member_count,
                 GlimsSetOp operation, char **error)
{
  GHashTable       *live;
  GimpItemList     *existing;
  GlimsStatus       status;
  GlimsSetSnapshot *before_push, *after_push;
  const gchar      *undo_name;

  if (! image || ! glims_item_sets_lookup (image) ||
      ! valid_kind (kind) || name == NULL || *name == '\0')
    {
      if (error)
        *error = g_strdup ("A saved set needs a supported item kind and a name.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if ((operation == GLIMS_SET_OP_CREATE || operation == GLIMS_SET_OP_REPLACE) &&
      member_count > 0 && members == NULL)
    {
      if (error)
        *error = g_strdup ("A saved-set member list needs count 0 or a valid array.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (operation == GLIMS_SET_OP_RENAME && (new_name == NULL || *new_name == '\0'))
    {
      if (error)
        *error = g_strdup ("A saved-set rename needs a new name.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  live = live_items_for_kind (image, kind);
  if (operation == GLIMS_SET_OP_CREATE || operation == GLIMS_SET_OP_REPLACE)
    {
      status = validate_members (image, kind, members, member_count, live, error);
      if (status != GLIMS_STATUS_OK)
        {
          g_hash_table_unref (live);
          return status;
        }
    }


  existing = find_fixed_set (image, kind, name);
  switch (operation)
    {
    case GLIMS_SET_OP_CREATE:
      if (existing)
        {
          g_hash_table_unref (live);
          if (error)
            *error = g_strdup_printf ("A saved set named \"%s\" already exists.", name);
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      break;

    case GLIMS_SET_OP_REPLACE:
      if (! existing)
        {
          g_hash_table_unref (live);
          if (error)
            *error = g_strdup_printf ("No saved set named \"%s\".", name);
          return GLIMS_STATUS_NOT_FOUND;
        }
      /* No-op: identical definition. No undo step, no dirty, no mutation. */
      if (members_equal_current (image, existing, members, member_count))
        {
          g_hash_table_unref (live);
          return GLIMS_STATUS_OK;
        }
      break;

    case GLIMS_SET_OP_RENAME:
      if (! existing)
        {
          g_hash_table_unref (live);
          if (error)
            *error = g_strdup_printf ("No saved set named \"%s\".", name);
          return GLIMS_STATUS_NOT_FOUND;
        }
      /* No-op: same name. */
      if (g_strcmp0 (name, new_name) == 0)
        {
          g_hash_table_unref (live);
          return GLIMS_STATUS_OK;
        }
      if (find_fixed_set (image, kind, new_name))
        {
          g_hash_table_unref (live);
          if (error)
            *error = g_strdup_printf ("A saved set named \"%s\" already exists.", new_name);
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      break;

    case GLIMS_SET_OP_REMOVE:
      if (! existing)
        {
          g_hash_table_unref (live);
          if (error)
            *error = g_strdup_printf ("No saved set named \"%s\".", name);
          return GLIMS_STATUS_NOT_FOUND;
        }
      break;
    }

  /* Frozen preflight: refuse before mutating. A push while frozen would
   * still mark the image dirty (gimp_image_undo_push dirties before its
   * freeze check), so the check must happen here, not after the fact. */
  if (! gimp_image_undo_is_enabled (image))
    {
      g_hash_table_unref (live);
      if (error)
        *error = g_strdup ("The image's undo stack is frozen.");
      return GLIMS_STATUS_FAILED;
    }

  /* The undo owns these snapshots even if native limits immediately expire
   * the pushed step. No borrowed Undo pointer is read or retained. */
  before_push = capture_snapshot (image, kind);

  switch (operation)
    {
    case GLIMS_SET_OP_CREATE:
    case GLIMS_SET_OP_REPLACE:
      {
        GList *items = NULL;
        for (size_t i = 0; i < member_count; i++)
          items = g_list_prepend (items, members[i]);
        items = g_list_reverse (items);
        {
          GimpItemList *set = g_object_new (GIMP_TYPE_ITEM_LIST,
                                            "image",      image,
                                            "name",       name,
                                            "is-pattern", FALSE,
                                            "item-type",  kind,
                                            "items",      items,
                                            NULL);
          gimp_image_store_item_set (image, set); /* replaces same name+kind */
        }
        g_list_free (items);
      }
      break;

    case GLIMS_SET_OP_RENAME:
      {
        GPtrArray *definition = glims_item_sets_copy_members (glims_item_sets_lookup (image), existing);
        GList *items = gimp_item_list_get_items (existing, NULL);
        GimpItemList *set = g_object_new (GIMP_TYPE_ITEM_LIST,
                                          "image",      image,
                                          "name",       new_name,
                                          "is-pattern", FALSE,
                                          "item-type",  kind,
                                          "items",      items,
                                          NULL);
        gimp_image_store_item_set (image, set);
        glims_item_sets_restore_members (glims_item_sets_lookup (image), set, definition);
        gimp_image_unlink_item_set (image, existing);
        glims_item_sets_refresh (glims_item_sets_lookup (image));
        g_ptr_array_unref (definition);
        g_list_free (items);
      }
      break;

    case GLIMS_SET_OP_REMOVE:
      gimp_image_unlink_item_set (image, existing);
      break;
    }

  after_push = capture_snapshot (image, kind);

  switch (operation)
    {
    case GLIMS_SET_OP_CREATE:  undo_name = "Create saved set";  break;
    case GLIMS_SET_OP_REPLACE: undo_name = "Replace saved set"; break;
    case GLIMS_SET_OP_RENAME:  undo_name = "Rename saved set";  break;
    default:                   undo_name = "Remove saved set";  break;
    }

  gimp_image_undo_push (image, GLIMS_TYPE_ITEM_SETS_UNDO,
                               GIMP_UNDO_IMAGE_METADATA, undo_name,
                               GIMP_DIRTY_IMAGE_META,
                               "before", before_push,
                               "after",  after_push,
                               NULL);
  /* Native undo limits may immediately expire this new step. As with
   * native editing commands, the edit remains successful and dirty; there
   * is no FAILED result after mutation and no attempt to reconstruct dirty
   * or redo state. Frozen-stack refusal was preflighted before mutation. */
  g_hash_table_unref (live);
  return GLIMS_STATUS_OK;
}

/* ---- public (adapter-internal) commands ---------------------------------- */

GlimsStatus
glims_item_sets_create (GimpImage *image, GType kind, const char *name,
                        GimpItem *const *members, size_t member_count, char **error)
{
  return run_set_command (image, kind, name, NULL, members, member_count,
                          GLIMS_SET_OP_CREATE, error);
}

GlimsStatus
glims_item_sets_replace (GimpImage *image, GType kind, const char *name,
                         GimpItem *const *members, size_t member_count, char **error)
{
  return run_set_command (image, kind, name, NULL, members, member_count,
                          GLIMS_SET_OP_REPLACE, error);
}

GlimsStatus
glims_item_sets_rename (GimpImage *image, GType kind, const char *name,
                        const char *new_name, char **error)
{
  return run_set_command (image, kind, name, new_name, NULL, 0,
                          GLIMS_SET_OP_RENAME, error);
}

GlimsStatus
glims_item_sets_remove (GimpImage *image, GType kind, const char *name, char **error)
{
  return run_set_command (image, kind, name, NULL, NULL, 0,
                          GLIMS_SET_OP_REMOVE, error);
}

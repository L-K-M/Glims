/*
 * Management of a drawable's committed non-destructive effects — the
 * filters the stack keeps, as opposed to the live previews filter.c
 * holds. Runs on the engine thread.
 *
 * Behavior is ported from the engine's own filter code and effects
 * editor at pinned commit 7addd2b77efb798bbdc4dbf2b082e786a48478ced:
 *
 *   - listing walks the drawable's filter stack head first, the order
 *     the effects editor shows (gimpdrawabletreeview-filters.c), and
 *     only non-temporary filters count as committed — the same
 *     predicate xcf-save.c uses to decide what to serialize;
 *   - removal is gimp_drawable_filters_editor_remove_clicked: a
 *     filter-remove undo step, then gimp_drawable_filter_abort;
 *   - merging one effect is drawable_merge_filter_invoker
 *     (app/pdb/drawable-cmds.c): the filter moves to the bottom of the
 *     stack first so only its own node reaches the pixels, then a
 *     destructive commit bakes it; here the whole thing sits in one
 *     undo group behind the filter-remove step, so undo restores both
 *     the pixels and the effect with its id;
 *   - reorders and attribute changes use GlimsEffectUndo below.
 */
#include "engine-private.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimp-memsize.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpfilter.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpimage-undo-push.h"
#include "core/gimpitem.h"
#include "core/gimplist.h"
#include "core/gimpundo.h"
#include "core/gimpviewable.h"

#include "text/gimptextlayer.h"

#include "gegl/gimp-gegl-utils.h"

#include "gimp-intl.h"

/* The undo record for effect moves and attribute changes. Reorders swap
 * the stored stack index the way GimpItemPropUndo does for layers
 * (gimpitempropundo.c); the engine's own GimpDrawableFilterUndo stores
 * the index but never swaps it back, so its redo cannot move a filter
 * again — the swap here makes undo and redo both work. Attribute changes
 * swap name, enabled and opacity the way master's drawable-filter undo
 * swaps visibility (gimpdrawablefilterundo.c); the released engines have
 * no visibility undo at all. */
enum
{
  GLIMS_EFFECT_UNDO_PROP_0,
  GLIMS_EFFECT_UNDO_PROP_FILTER
};

struct _GlimsEffectUndo
{
  GimpUndo            parent_instance;

  GimpDrawableFilter *filter;
  gint                row_index;
  gchar              *name;
  gboolean            custom_name;
  gboolean            active;
  gdouble             opacity;
};

typedef struct _GlimsEffectUndo      GlimsEffectUndo;
typedef struct _GlimsEffectUndoClass GlimsEffectUndoClass;

struct _GlimsEffectUndoClass
{
  GimpUndoClass parent_class;
};

#define GLIMS_TYPE_EFFECT_UNDO (glims_effect_undo_get_type ())
#define GLIMS_EFFECT_UNDO(obj) (G_TYPE_CHECK_INSTANCE_CAST ((obj), GLIMS_TYPE_EFFECT_UNDO, GlimsEffectUndo))

GType glims_effect_undo_get_type (void) G_GNUC_CONST;

static void  glims_effect_undo_constructed  (GObject             *object);
static void  glims_effect_undo_set_property (GObject             *object,
                                             guint                property_id,
                                             const GValue        *value,
                                             GParamSpec          *pspec);
static void  glims_effect_undo_get_property (GObject             *object,
                                             guint                property_id,
                                             GValue              *value,
                                             GParamSpec          *pspec);
static gint64 glims_effect_undo_get_memsize (GimpObject          *object,
                                             gint64              *gui_size);
static void  glims_effect_undo_pop          (GimpUndo            *undo,
                                             GimpUndoMode         undo_mode,
                                             GimpUndoAccumulator *accum);
static void  glims_effect_undo_free         (GimpUndo            *undo,
                                             GimpUndoMode         undo_mode);

G_DEFINE_TYPE (GlimsEffectUndo, glims_effect_undo, GIMP_TYPE_UNDO)

#define parent_class glims_effect_undo_parent_class

static void
glims_effect_undo_class_init (GlimsEffectUndoClass *klass)
{
  GObjectClass    *object_class      = G_OBJECT_CLASS (klass);
  GimpObjectClass *gimp_object_class = GIMP_OBJECT_CLASS (klass);
  GimpUndoClass   *undo_class        = GIMP_UNDO_CLASS (klass);

  object_class->constructed      = glims_effect_undo_constructed;
  object_class->set_property     = glims_effect_undo_set_property;
  object_class->get_property     = glims_effect_undo_get_property;

  gimp_object_class->get_memsize = glims_effect_undo_get_memsize;

  undo_class->pop                = glims_effect_undo_pop;
  undo_class->free               = glims_effect_undo_free;

  g_object_class_install_property (object_class, GLIMS_EFFECT_UNDO_PROP_FILTER,
                                   g_param_spec_object ("filter", NULL, NULL,
                                                        GIMP_TYPE_DRAWABLE_FILTER,
                                                        GIMP_PARAM_READWRITE |
                                                        G_PARAM_CONSTRUCT_ONLY));
}

static void
glims_effect_undo_init (GlimsEffectUndo *undo)
{
}

static void
glims_effect_undo_constructed (GObject *object)
{
  GlimsEffectUndo *effect_undo = GLIMS_EFFECT_UNDO (object);
  GimpUndo        *undo        = GIMP_UNDO (object);
  GimpDrawable    *drawable;

  G_OBJECT_CLASS (parent_class)->constructed (object);

  gimp_assert (GIMP_IS_DRAWABLE_FILTER (effect_undo->filter) &&
               ! gimp_drawable_filter_get_temporary (effect_undo->filter));

  drawable = gimp_drawable_filter_get_drawable (effect_undo->filter);
  if (! drawable)
    return;

  if (undo->undo_type == GIMP_UNDO_FILTER_REORDER)
    {
      effect_undo->row_index =
        gimp_container_get_child_index (gimp_drawable_get_filters (drawable),
                                        GIMP_OBJECT (effect_undo->filter));
    }
  else
    {
      g_object_get (effect_undo->filter,
                    "custom-name", &effect_undo->custom_name,
                    NULL);
      effect_undo->name    = g_strdup (gimp_object_get_name (GIMP_OBJECT (effect_undo->filter)));
      effect_undo->active  = gimp_filter_get_active (GIMP_FILTER (effect_undo->filter));
      effect_undo->opacity = gimp_drawable_filter_get_opacity (effect_undo->filter);
    }
}

static void
glims_effect_undo_set_property (GObject      *object,
                                guint         property_id,
                                const GValue *value,
                                GParamSpec   *pspec)
{
  GlimsEffectUndo *effect_undo = GLIMS_EFFECT_UNDO (object);

  switch (property_id)
    {
    case GLIMS_EFFECT_UNDO_PROP_FILTER:
      effect_undo->filter = g_value_dup_object (value);
      break;

    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
      break;
    }
}

static void
glims_effect_undo_get_property (GObject    *object,
                                guint       property_id,
                                GValue     *value,
                                GParamSpec *pspec)
{
  GlimsEffectUndo *effect_undo = GLIMS_EFFECT_UNDO (object);

  switch (property_id)
    {
    case GLIMS_EFFECT_UNDO_PROP_FILTER:
      g_value_set_object (value, effect_undo->filter);
      break;

    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
      break;
    }
}

static gint64
glims_effect_undo_get_memsize (GimpObject *object,
                               gint64     *gui_size)
{
  GlimsEffectUndo *effect_undo = GLIMS_EFFECT_UNDO (object);
  gint64           memsize     = 0;

  memsize += gimp_object_get_memsize (GIMP_OBJECT (effect_undo->filter), NULL);
  memsize += sizeof (gint) + sizeof (gboolean) * 2 + sizeof (gdouble);
  memsize += gimp_string_get_memsize (effect_undo->name);

  return memsize + GIMP_OBJECT_CLASS (parent_class)->get_memsize (object, gui_size);
}

static void
glims_effect_undo_pop (GimpUndo            *undo,
                       GimpUndoMode         undo_mode,
                       GimpUndoAccumulator *accum)
{
  GlimsEffectUndo    *effect_undo = GLIMS_EFFECT_UNDO (undo);
  GimpDrawableFilter *filter      = effect_undo->filter;
  GimpDrawable       *drawable    = gimp_drawable_filter_get_drawable (filter);
  GimpImage          *image       = NULL;
  GimpChannel        *selection   = NULL;

  GIMP_UNDO_CLASS (parent_class)->pop (undo, undo_mode, accum);

  if (drawable)
    image = gimp_item_get_image (GIMP_ITEM (drawable));

  if (image)
    {
      /* Temporarily remove selection so filters can be applied correctly */
      selection =
        GIMP_CHANNEL (gimp_item_duplicate (GIMP_ITEM (gimp_image_get_mask (image)),
                                           GIMP_TYPE_CHANNEL));
      gimp_channel_clear (gimp_image_get_mask (image), NULL, FALSE);
    }

  if (undo->undo_type == GIMP_UNDO_FILTER_REORDER)
    {
      if (drawable)
        {
          GimpContainer *stack = gimp_drawable_get_filters (drawable);
          gint           index;

          index = gimp_container_get_child_index (stack, GIMP_OBJECT (filter));
          gimp_container_reorder (stack, GIMP_OBJECT (filter),
                                  effect_undo->row_index);
          effect_undo->row_index = index;

          gimp_drawable_update (drawable, 0, 0, -1, -1);
        }
    }
  else if (undo->undo_type == GIMP_UNDO_FILTER_MODIFIED)
    {
      gchar    *name;
      gboolean  custom_name;
      gboolean  active;
      gdouble   opacity;

      name        = g_strdup (gimp_object_get_name (GIMP_OBJECT (filter)));
      g_object_get (filter,
                    "custom-name", &custom_name,
                    NULL);
      active      = gimp_filter_get_active (GIMP_FILTER (filter));
      opacity     = gimp_drawable_filter_get_opacity (filter);

      g_object_set (filter,
                    "name",        effect_undo->name,
                    "custom-name", effect_undo->custom_name,
                    NULL);
      gimp_filter_set_active (GIMP_FILTER (filter), effect_undo->active);
      gimp_drawable_filter_set_opacity (filter, effect_undo->opacity);

      g_free (effect_undo->name);
      effect_undo->name        = name;
      effect_undo->custom_name = custom_name;
      effect_undo->active      = active;
      effect_undo->opacity     = opacity;

      if (drawable)
        {
          gimp_drawable_filter_apply (filter, NULL);
          gimp_drawable_update (drawable, 0, 0, -1, -1);
        }
    }

  if (image)
    {
      GeglBuffer *buffer;

      /* Restore selection after undo or redo */
#if GIMP_CHECK_VERSION (3, 3, 0)
      buffer = gimp_gegl_buffer_dup (gimp_drawable_get_buffer (GIMP_DRAWABLE (selection)),
                                     GIMP_DRAWABLE (gimp_image_get_mask (image)));
#else
      buffer = gimp_gegl_buffer_dup (gimp_drawable_get_buffer (GIMP_DRAWABLE (selection)));
#endif
      gimp_drawable_set_buffer (GIMP_DRAWABLE (gimp_image_get_mask (image)),
                                FALSE, NULL, buffer);
      g_object_unref (buffer);
      g_object_unref (selection);
    }
}

static void
glims_effect_undo_free (GimpUndo     *undo,
                        GimpUndoMode  undo_mode)
{
  GlimsEffectUndo *effect_undo = GLIMS_EFFECT_UNDO (undo);

  g_clear_object (&effect_undo->filter);
  g_free (effect_undo->name);

  GIMP_UNDO_CLASS (parent_class)->free (undo, undo_mode);
}

/* The effect `effect_id` names on `drawable`: a filter that exists, is
 * attached to that drawable's stack, and is committed — not a temporary
 * preview and not only held by the undo stack after a removal. The id
 * table returns removed filters too while undo keeps them alive, so the
 * stack membership test is what proves the effect is live. filter.c
 * uses this for edit sessions. */
GimpDrawableFilter *
glims_lookup_effect (GlimsEngine  *engine,
                     GimpDrawable *drawable,
                     GlimsEffectID effect_id)
{
  GimpDrawableFilter *filter;

  filter = gimp_drawable_filter_get_by_id (engine->gimp, effect_id);
  if (! filter ||
      gimp_drawable_filter_get_drawable (filter) != drawable ||
      gimp_drawable_filter_get_temporary (filter) ||
      ! gimp_drawable_has_filter (drawable, GIMP_FILTER (filter)))
    {
      return NULL;
    }

  return filter;
}

GlimsStatus
glims_drawable_effects (GlimsEngine    *engine,
                        GlimsImageID    id,
                        GlimsItemID     drawable_id,
                        GlimsEffectInfo *rows,
                        int32_t         capacity,
                        int32_t        *count)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpDrawable   *drawable;
  GimpContainer  *filters;
  GList          *iter;
  int32_t         i = 0, total = 0;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! count || capacity < 0 || (! rows && capacity > 0))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  drawable = glims_lookup_drawable (open, drawable_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;

  filters = gimp_drawable_get_filters (drawable);
  for (iter = GIMP_LIST (filters)->queue->head; iter; iter = iter->next)
    {
      GimpObject *child = iter->data;

      if (! GIMP_IS_DRAWABLE_FILTER (child) ||
          gimp_drawable_filter_get_temporary (GIMP_DRAWABLE_FILTER (child)))
        continue;

      if (i < capacity)
        {
          GlimsEffectInfo    *row = &rows[i];
          GimpDrawableFilter *filter = GIMP_DRAWABLE_FILTER (child);
          gchar              *operation = NULL;

          memset (row, 0, sizeof (*row));
          row->id = gimp_drawable_filter_get_id (filter);
          g_strlcpy (row->name, gimp_object_get_name (child), sizeof (row->name));
          gegl_node_get (gimp_drawable_filter_get_operation (filter),
                         "operation", &operation, NULL);
          if (operation)
            {
              g_strlcpy (row->operation, operation, sizeof (row->operation));
              g_free (operation);
            }
          row->enabled = gimp_filter_get_active (GIMP_FILTER (filter)) != FALSE;
          row->opacity = gimp_drawable_filter_get_opacity (filter);
          i++;
        }
      total++;
    }

  *count = total;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_effect_change (GlimsEngine              *engine,
                     GlimsImageID              id,
                     GlimsItemID               drawable_id,
                     GlimsEffectID             effect_id,
                     const GlimsEffectChange  *change,
                     char                    **error)
{
  GlimsOpenImage     *open = glims_lookup_image (engine, id);
  GlimsStatus         status;
  GimpDrawable       *drawable;
  GimpDrawableFilter *filter;
  gchar              *name = NULL;
  gboolean            custom_name, enabled;
  gdouble             opacity;
  gboolean            changed = FALSE, pixels_changed = FALSE;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! change || change->struct_size < sizeof (GlimsEffectChange) ||
      change->properties & ~(GLIMS_EFFECT_NAME | GLIMS_EFFECT_ENABLED |
                             GLIMS_EFFECT_OPACITY))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if ((change->properties & GLIMS_EFFECT_OPACITY) &&
      (! isfinite (change->opacity) || change->opacity < 0.0 ||
       change->opacity > 1.0))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  drawable = glims_lookup_drawable (open, drawable_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;

  filter = glims_lookup_effect (engine, drawable, effect_id);
  if (! filter)
    return GLIMS_STATUS_NOT_FOUND;

  /* Resolve every requested property before touching anything. */
  if (change->properties & GLIMS_EFFECT_NAME)
    {
      if (change->name[0])
        {
          name        = g_strndup (change->name, sizeof (change->name) - 1);
          custom_name = TRUE;
        }
      else
        {
          /* Empty restores the operation's default title, the same
           * "no custom name" state a filter starts with. */
          gchar *operation = NULL;

          gegl_node_get (gimp_drawable_filter_get_operation (filter),
                         "operation", &operation, NULL);
          if (operation)
            {
              const gchar *title = gegl_operation_get_key (operation, "title");

              name = g_strdup (title ? title : operation);
              g_free (operation);
            }
          custom_name = FALSE;
        }
      {
        gboolean current_custom = FALSE;

        g_object_get (filter, "custom-name", &current_custom, NULL);
        if (custom_name != current_custom ||
            g_strcmp0 (name, gimp_object_get_name (GIMP_OBJECT (filter))) != 0)
          changed = TRUE;
      }
    }
  enabled = (change->properties & GLIMS_EFFECT_ENABLED)
    ? change->enabled != FALSE
    : gimp_filter_get_active (GIMP_FILTER (filter));
  if (enabled != gimp_filter_get_active (GIMP_FILTER (filter)))
    changed = pixels_changed = TRUE;
  opacity = (change->properties & GLIMS_EFFECT_OPACITY)
    ? change->opacity
    : gimp_drawable_filter_get_opacity (filter);
  if (opacity != gimp_drawable_filter_get_opacity (filter))
    changed = pixels_changed = TRUE;

  if (changed)
    {
      /* One undo step for the whole call; the record swaps every
       * attribute back and forth. */
      if (! gimp_image_undo_push (open->image, GLIMS_TYPE_EFFECT_UNDO,
                                  GIMP_UNDO_FILTER_MODIFIED,
                                  _("Edit filter"), GIMP_DIRTY_ITEM_META,
                                  "filter", filter, NULL))
        {
          g_free (name);
          return glims_fail (error, NULL, "The image's undo history is unavailable.");
        }

      if (change->properties & GLIMS_EFFECT_NAME)
        g_object_set (filter,
                      "name",        name,
                      "custom-name", custom_name,
                      NULL);
      gimp_filter_set_active (GIMP_FILTER (filter), enabled);
      gimp_drawable_filter_set_opacity (filter, opacity);
      if (pixels_changed)
        gimp_drawable_filter_apply (filter, NULL);
    }
  g_free (name);

  gimp_image_flush (open->image);
  return GLIMS_STATUS_OK;
}

/* Move the effect to `target`, as a single undo step. Callers have
 * already decided the move is legal and not a no-op. */
static gboolean
effect_reorder (GimpImage          *image,
                GimpDrawable       *drawable,
                GimpDrawableFilter *filter,
                gint                target)
{
  if (! gimp_image_undo_push (image, GLIMS_TYPE_EFFECT_UNDO,
                              GIMP_UNDO_FILTER_REORDER,
                              _("Reorder filter"), GIMP_DIRTY_DRAWABLE,
                              "filter", filter, NULL))
    return FALSE;

  gimp_container_reorder (gimp_drawable_get_filters (drawable),
                          GIMP_OBJECT (filter), target);
  gimp_drawable_update (drawable, 0, 0, -1, -1);
  return TRUE;
}

GlimsStatus
glims_effect_command (GlimsEngine   *engine,
                      GlimsImageID   id,
                      GlimsItemID    drawable_id,
                      GlimsEffectID  effect_id,
                      uint32_t       command,
                      char         **error)
{
  GlimsOpenImage     *open = glims_lookup_image (engine, id);
  GlimsStatus         status;
  GimpDrawable       *drawable;
  GimpDrawableFilter *filter;
  GimpContainer      *filters;
  gint                index, n_children, target;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (command < GLIMS_EFFECT_REMOVE || command > GLIMS_EFFECT_TO_BOTTOM)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  drawable = glims_lookup_drawable (open, drawable_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;

  filter = glims_lookup_effect (engine, drawable, effect_id);
  if (! filter)
    return GLIMS_STATUS_NOT_FOUND;

  filters    = gimp_drawable_get_filters (drawable);
  index      = gimp_container_get_child_index (filters, GIMP_OBJECT (filter));
  n_children = gimp_container_get_n_children (filters);

  switch (command)
    {
    case GLIMS_EFFECT_REMOVE:
      /* gimp_drawable_filters_editor_remove_clicked: the undo holds the
       * filter alive and puts it back with its id and position. */
      if (! gimp_image_undo_push_filter_remove (open->image, _("Remove filter"),
                                                drawable, filter))
        return glims_fail (error, NULL, "The image's undo history is unavailable.");
      gimp_drawable_filter_abort (filter);
      break;

    case GLIMS_EFFECT_MERGE:
      {
        gboolean success;

        /* The merge button's rules (gimpdrawabletreeview-filters.c
         * gimp_drawable_filters_editor_set_sensitive): no groups and no
         * structured pixel content — text, link and vector layers would
         * lose it — and the PDB merge checks the group case the same
         * way (gimp_pdb_item_is_not_group). */
        if (gimp_viewable_get_children (GIMP_VIEWABLE (drawable)))
          {
            glims_fail (error, NULL,
                        "Effects on a layer group cannot be merged.");
            return GLIMS_STATUS_INVALID_ARGUMENT;
          }
#if GIMP_CHECK_VERSION (3, 2, 0)
        if (gimp_item_is_rasterizable (GIMP_ITEM (drawable)))
#else
        if (gimp_item_is_text_layer (GIMP_ITEM (drawable)))
#endif
          {
            glims_fail (error, NULL,
                        "Effects on a text, link or vector layer cannot be merged.");
            return GLIMS_STATUS_INVALID_ARGUMENT;
          }
        /* An inactive effect is out of the stack's graph, so its node
         * has no real input to bake. */
        if (! gimp_filter_get_active (GIMP_FILTER (filter)))
          {
            glims_fail (error, NULL,
                        "A disabled effect has nothing to merge.");
            return GLIMS_STATUS_INVALID_ARGUMENT;
          }
        status = glims_check_item_locks (GIMP_ITEM (drawable),
                                         GLIMS_LOCK_PIXELS, error);
        if (status != GLIMS_STATUS_OK)
          return status;

        /* drawable_merge_filter_invoker applies the effect at the
         * bottom of the stack so only its own node reaches the pixels,
         * then commits destructively. The filter-remove step is pushed
         * first (before the move), in the same undo group, so undo
         * restores the pixels and the effect with its id and place. */
        if (! gimp_image_undo_group_start (open->image, GIMP_UNDO_GROUP_DRAWABLE,
                                           _("Merge filter")))
          return glims_fail (error, NULL, "The image's undo history is unavailable.");
        if (! gimp_image_undo_push_filter_remove (open->image, _("Merge filter"),
                                                  drawable, filter))
          {
            gimp_image_undo_group_end (open->image);
            return glims_fail (error, NULL, "The image's undo history is unavailable.");
          }
        gimp_drawable_filter_apply (filter, NULL);
        if (n_children > 1)
          gimp_container_reorder (filters, GIMP_OBJECT (filter),
                                  n_children - 1);
        gimp_drawable_filter_layer_mask_freeze (filter);
        success = gimp_drawable_filter_commit (filter, FALSE, NULL, FALSE);
        gimp_image_undo_group_end (open->image);
        gimp_drawable_filters_changed (drawable);
        if (! success)
          return glims_fail (error, NULL, "The effect could not be merged.");
        break;
      }

    case GLIMS_EFFECT_RAISE:
    case GLIMS_EFFECT_LOWER:
    case GLIMS_EFFECT_TO_TOP:
    case GLIMS_EFFECT_TO_BOTTOM:
      {
        /* Like gimp_drawable_raise_filter / lower_filter a mask-less
         * filter cannot move; one is not a committed effect anyway. */
        if (! gimp_drawable_filter_get_mask (filter))
          return glims_fail (error, NULL, "The effect cannot be moved.");

        /* lower_filter refuses to move below a stack member that is not
         * a drawable filter (the floating selection's entry, which sits
         * at the bottom); raise moves unconditionally. TO_BOTTOM lands
         * just above such a run rather than crossing it. */
        switch (command)
          {
          case GLIMS_EFFECT_RAISE:
            target = index - 1;
            break;
          case GLIMS_EFFECT_LOWER:
            target = index + 1;
            if (target < n_children &&
                ! GIMP_IS_DRAWABLE_FILTER (
                  gimp_container_get_child_by_index (filters, target)))
              return GLIMS_STATUS_OK;
            break;
          case GLIMS_EFFECT_TO_TOP:
            target = 0;
            break;
          default:
            for (target = index + 1;
                 target < n_children &&
                 GIMP_IS_DRAWABLE_FILTER (
                   gimp_container_get_child_by_index (filters, target));
                 target++)
              ;
            target--;
            break;
          }
        if (target < 0 || target >= n_children || target == index)
          return GLIMS_STATUS_OK;   /* already at the end, a no-op */

        if (! effect_reorder (open->image, drawable, filter, target))
          return glims_fail (error, NULL, "The image's undo history is unavailable.");
        break;
      }
    }

  gimp_image_flush (open->image);
  return GLIMS_STATUS_OK;
}

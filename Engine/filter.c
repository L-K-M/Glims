/*
 * Live filter sessions on a drawable. Runs on the engine thread.
 *
 * The engine keeps preview, commit and abort in GimpDrawableFilter (core),
 * but the undo bookkeeping of a commit lives in GIMP's GTK filter tool
 * (app/tools/gimpfiltertool.c, gimp_filter_tool_commit). That sequence is
 * reproduced here for a new filter — non-destructive where the drawable's
 * XCF serialization keeps it, merged into the pixels elsewhere. Editing
 * an already committed effect follows the tool's existing-filter flow
 * (pinned commit 7addd2b77efb798bbdc4dbf2b082e786a48478ced): the effect
 * is parked inactive while a shadow filter, seeded with its parameters
 * and applied with its own mask at its stack index, holds the preview;
 * commit writes the shadow's state back into the effect behind a native
 * filter-modified undo, abort drops the shadow. One deviation: the
 * effect's enabled state is restored from the session, where the tool
 * unconditionally reactivates it.
 */
#include "engine-private.h"
#include "filter-input.h"
#include "filter-config.h"
#include "color-balance-config.h"
#include "hue-saturation-config.h"
#include "levels-config.h"
#include "curves-config.h"
#include "filter-histogram.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpfilter.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpimage-quick-mask.h"
#include "core/gimpimage-undo-push.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayermask.h"

#include "gimp-intl.h"

static gboolean
uses_owned_config (GeglNode *node)
{
  return glims_filter_config_is_brightness_contrast (node) ||
         glims_color_balance_config_is_operation (node) ||
         glims_hue_saturation_config_is_operation (node) ||
         glims_levels_config_is_operation (node) ||
         glims_curves_config_is_operation (node);
}

static GlimsStatus
copy_owned_config (GeglNode *destination, GeglNode *source, char **error)
{
  if (glims_color_balance_config_is_operation (source))
    return glims_color_balance_config_copy (destination, source, error);
  if (glims_hue_saturation_config_is_operation (source))
    return glims_hue_saturation_config_copy (destination, source, error);
  if (glims_levels_config_is_operation (source))
    return glims_levels_config_copy (destination, source, error);
  if (glims_curves_config_is_operation (source))
    return glims_curves_config_copy (destination, source, error);
  return glims_filter_config_copy (destination, source, error);
}


GlimsStatus
glims_filter_check_edit (GlimsEngine *engine, GlimsFilterID id, char **error)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));

  if (! session || ! gimp_item_is_attached (GIMP_ITEM (session->drawable)))
    return GLIMS_STATUS_NOT_FOUND;
  if (session->existing &&
      ! gimp_drawable_has_filter (session->drawable, GIMP_FILTER (session->existing)))
    return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  return glims_check_item_locks (GIMP_ITEM (session->drawable), GLIMS_LOCK_PIXELS, error);
}

void
glims_filters_free (gpointer data)
{
  GlimsFilter *session = data;

  /* An open session the app never finished is aborted. An edit
   * session's parked effect then goes back to the state it had when the
   * session began — the shadow is gone and nothing was recorded. */
  if (session->filter)
    gimp_drawable_filter_abort (session->filter);
  if (session->existing)
    {
      gimp_filter_set_active (GIMP_FILTER (session->existing),
                              session->existing_active);
      if (gimp_item_is_attached (GIMP_ITEM (session->drawable)))
        gimp_drawable_update (session->drawable, 0, 0, -1, -1);
    }

  g_clear_object (&session->filter);
  g_clear_object (&session->existing);
  g_clear_object (&session->operation);
  g_clear_object (&session->aux_source);
  g_clear_object (&session->drawable);
  g_clear_object (&session->image);
  g_free (session);
}

gboolean
glims_filters_active_for_image (GlimsEngine *engine, GimpImage *image)
{
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init (&iter, engine->filters);
  while (g_hash_table_iter_next (&iter, NULL, &value))
    {
      GlimsFilter *session = value;
      if (session->image == image && session->filter) return TRUE;
    }
  return FALSE;
}

void
glims_filters_abort_for_image (GlimsEngine *engine, GimpImage *image)
{
  GHashTableIter iter;
  gpointer value;

  g_hash_table_iter_init (&iter, engine->filters);
  while (g_hash_table_iter_next (&iter, NULL, &value))
    {
      GlimsFilter *session = value;
      if (session->image == image)
        g_hash_table_iter_remove (&iter);
    }
}

/* Whether a session may point at `drawable`, and how commit leaves it.
 * TRUE keeps the filter on the drawable's stack as its own undo step;
 * FALSE merges the result into the pixels with the drawable's own undo.
 *
 * GIMP's filter tool (app/tools/gimpfiltertool.c gimp_filter_tool_commit)
 * forces destructive commits on layer masks in every version, and the
 * Quick Mask's channel must merge too: exiting the mask would otherwise
 * strand a live filter on the channel the toggle removes. A saved
 * channel keeps its filters non-destructively only where XCF serializes
 * channel effects — 3.2.6 and later (upstream 9bcb0ad5e8 "core, xcf:
 * Save channel filters in XCF"); on earlier engines only the raw
 * channel buffer is saved, so Apply has to merge for the result to
 * persist. Layers stay non-destructive everywhere. The image's
 * selection mask is not a filter target. */
static gboolean
filter_commit_policy (GimpImage    *image,
                      GimpDrawable *drawable,
                      gboolean     *non_destructive,
                      char        **error)
{
  if (GIMP_IS_LAYER (drawable))
    {
      *non_destructive = TRUE;
      return TRUE;
    }

  if (GIMP_IS_LAYER_MASK (drawable))
    {
      *non_destructive = FALSE;
      return TRUE;
    }

  if (GIMP_IS_CHANNEL (drawable))
    {
      if (gimp_item_get_container (GIMP_ITEM (drawable)) !=
          gimp_image_get_channels (image))
        {
          glims_fail (error, NULL,
                      "Filters cannot be applied to the selection mask.");
          return FALSE;
        }

      if (gimp_image_get_quick_mask_state (image) &&
          GIMP_CHANNEL (drawable) == gimp_image_get_quick_mask (image))
        {
          *non_destructive = FALSE;
        }
      else
        {
#if GIMP_CHECK_VERSION (3, 2, 6)
          *non_destructive = TRUE;
#else
          *non_destructive = FALSE;
#endif
        }
      return TRUE;
    }

  glims_fail (error, NULL,
              "Filters can only be applied to layers, layer masks and channels.");
  return FALSE;
}

static GlimsStatus
source_merge_history_ready (GimpImage *image, char **error)
{
  if (!gimp_image_undo_is_enabled (image) || gimp_image_get_undo_group_count (image)) {
    if (error) *error = g_strdup ("Finish the current edit and enable Undo before applying this filter.");
    return GLIMS_STATUS_BUSY;
  }
  return GLIMS_STATUS_OK;
}

static GlimsStatus
filter_begin_internal (GlimsEngine    *engine,
                    GlimsImageID    image_id,
                    GlimsItemID     drawable_id,
                    const char     *operation,
                    GeglNode       *aux_source,
                    GlimsFilterID  *out,
                    char          **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, image_id);
  GimpDrawable   *drawable;
  GlimsFilter    *session;
  gboolean        non_destructive;
  gint            id;
  GlimsStatus     status;

  if (out) *out = 0;
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! operation || ! out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  if (!strcmp (operation, "gimp:brightness-contrast") || !strcmp (operation, "gimp:color-balance") ||
      !strcmp (operation, "gimp:hue-saturation") || !strcmp (operation, "gimp:levels") ||
      !strcmp (operation, "gimp:curves")) {
    status = glims_edit_ready (engine, open, error);
    if (status != GLIMS_STATUS_OK) return status;
    status = source_merge_history_ready (open->image, error);
    if (status != GLIMS_STATUS_OK) return status;
  }

  drawable = glims_lookup_drawable (open, drawable_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;
  if (! filter_commit_policy (open->image, drawable, &non_destructive, error))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;

  if (! glims_filter_operation_allowed (operation))
    {
      if (error)
        *error = strdup ("That operation cannot be used as an image filter.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  session = g_new0 (GlimsFilter, 1);
  session->image           = g_object_ref (open->image);
  session->drawable        = g_object_ref (drawable);
  session->non_destructive = non_destructive;
  session->operation = gegl_node_new_child (NULL, "operation", operation, NULL);
  if (!session->operation) {
    glims_filters_free (session);
    return glims_fail (error, NULL, "The filter operation could not be created.");
  }
  status = glims_filter_config_prepare (session->operation, error);
  if (status != GLIMS_STATUS_OK) { glims_filters_free (session); return status; }
  status = glims_color_balance_config_prepare (session->operation, error);
  if (status != GLIMS_STATUS_OK) { glims_filters_free (session); return status; }
  status = glims_hue_saturation_config_prepare (session->operation, error);
  if (status != GLIMS_STATUS_OK) { glims_filters_free (session); return status; }
  status = glims_levels_config_prepare (session->operation, error);
  if (status != GLIMS_STATUS_OK) { glims_filters_free (session); return status; }
  status = glims_curves_config_prepare (session->operation, error);
  if (status != GLIMS_STATUS_OK) { glims_filters_free (session); return status; }
  if (aux_source) {
    if (!gegl_node_connect_to (aux_source, "output", session->operation, "aux")) {
      glims_filters_free (session);
      return glims_fail (error, NULL, "The height map could not be connected.");
    }
    session->aux_source = g_object_ref (aux_source);
    session->non_destructive = FALSE;
  }
  /* The undo step and the filter's name in the layer's filter list use the
   * operation's title ("Gaussian Blur"), as GIMP's filter tools do
   * (gimp_tool_get_undo_desc in app/tools). */
  {
    const gchar *title = gegl_operation_get_key (operation, "title");

    session->filter = gimp_drawable_filter_new (drawable, title ? title : operation,
                                                session->operation, NULL);
  }

  if (!session->filter) {
    glims_filters_free (session);
    return glims_fail (error, NULL, "The filter preview could not be created.");
  }
  if (aux_source) g_object_set (session->filter, "to-be-merged", TRUE, NULL);

  /* A live preview sits on the drawable's stack but is not a committed
   * effect: mark it temporary, as the engine's tools do with their
   * editing filters — XCF skips temporary filters, and drawable_effects
   * counts only committed ones. Commit flips the flag back. */
  gimp_drawable_filter_set_temporary (session->filter, TRUE);
  gimp_drawable_filter_apply (session->filter, NULL);
  gimp_drawable_filter_set_preview (session->filter, TRUE);
  if (aux_source) {
    /* Native merged previews sit below existing committed effects. */
    GimpContainer *filters = gimp_drawable_get_filters (drawable);
    gint count = gimp_container_get_n_children (filters);
    if (gimp_container_have (filters, GIMP_OBJECT (session->filter)))
      gimp_container_reorder (filters, GIMP_OBJECT (session->filter), count - 1);
    gimp_drawable_update (drawable, 0, 0, -1, -1);
  }
  gimp_image_flush (open->image);

  id = glims_next_session_id (engine);
  g_hash_table_insert (engine->filters, GINT_TO_POINTER (id), session);
  *out = id;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_begin (GlimsEngine *engine, GlimsImageID image, GlimsItemID drawable,
                    const char *operation, GlimsFilterID *out, char **error)
{
  return filter_begin_internal (engine, image, drawable, operation, NULL, out, error);
}

GlimsStatus
glims_filter_begin_with_source (GlimsEngine *engine, GlimsImageID image,
                                GlimsItemID target, const char *operation,
                                GlimsItemID source, GlimsFilterID *out, char **error)
{
  GlimsOpenImage *open;
  GimpDrawable *drawable;
  GeglNode *snapshot = NULL;
  GlimsStatus status;
  if (out) *out = 0;
  if (!out || !operation || target <= 0 || source <= 0) return GLIMS_STATUS_INVALID_ARGUMENT;
  if (strcmp (operation, "gegl:bump-map")) return GLIMS_STATUS_UNSUPPORTED;
  open = glims_lookup_image (engine, image);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = source_merge_history_ready (open->image, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (gimp_image_get_floating_selection (open->image)) return GLIMS_STATUS_BUSY;
  if (gimp_image_get_base_type (open->image) == GIMP_INDEXED) return GLIMS_STATUS_UNSUPPORTED;
  drawable = glims_lookup_drawable (open, target);
  if (!drawable) return GLIMS_STATUS_NOT_FOUND;
  if (!GIMP_IS_LAYER (drawable) || GIMP_IS_GROUP_LAYER (drawable) ||
      glims_layer_editable_source_kind (GIMP_LAYER (drawable))) {
    if (error) *error = g_strdup ("Bump Map needs a pixel layer. Rasterize the editable source first.");
    return GLIMS_STATUS_UNSUPPORTED;
  }
  status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = glims_filter_input_snapshot (engine, open, source, &snapshot, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = filter_begin_internal (engine, image, target, operation, snapshot, out, error);
  g_object_unref (snapshot);
  return status;
}

/* Opens a live session that edits the committed effect `effect_id`: the
 * effect keeps its place, id and committed state while a temporary
 * shadow of the same operation previews in its slot. The returned id is
 * a filter session id like filter_begin's — property reads and writes,
 * commit and abort all work on the shadow — never an effect id. */
GlimsStatus
glims_filter_edit_begin (GlimsEngine   *engine,
                         GlimsImageID   image_id,
                         GlimsItemID    drawable_id,
                         GlimsEffectID  effect_id,
                         GlimsFilterID *out,
                         char         **error)
{
  GlimsOpenImage     *open = glims_lookup_image (engine, image_id);
  GimpDrawable       *drawable;
  GimpDrawableFilter *existing;
  GeglNode           *existing_node;
  GimpContainer      *filters;
  gchar              *operation;
  GParamSpec        **pspecs;
  guint               n_pspecs;
  GlimsFilter        *session;
  gint                id, index;
  GlimsStatus         status;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *out = 0;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  drawable = glims_lookup_drawable (open, drawable_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;

  /* Only a committed effect of this drawable can be edited — a stale,
   * foreign, removed or preview id is NOT_FOUND, as for effect_change. */
  existing = glims_lookup_effect (engine, drawable, effect_id);
  if (! existing)
    return GLIMS_STATUS_NOT_FOUND;

  status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;

  /* A filter without its own GEGL operation (a graph node read from an
   * XCF) has no properties to edit — the same reason
   * gimp_drawable_filter_duplicate() refuses it. */
  existing_node = gimp_drawable_filter_get_operation (existing);
  gegl_node_get (existing_node, "operation", &operation, NULL);
  if (! operation || ! strcmp (operation, "GraphNode"))
    {
      g_free (operation);
      if (error)
        *error = strdup ("That effect has no editable parameters.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (!strcmp (operation, "gimp:brightness-contrast") || !strcmp (operation, "gimp:color-balance") ||
      !strcmp (operation, "gimp:hue-saturation") || !strcmp (operation, "gimp:levels") ||
      !strcmp (operation, "gimp:curves")) {
    status = source_merge_history_ready (open->image, error);
    if (status != GLIMS_STATUS_OK) { g_free (operation); return status; }
  }

  session = g_new0 (GlimsFilter, 1);
  session->image           = g_object_ref (open->image);
  session->drawable        = g_object_ref (drawable);
  session->existing        = g_object_ref (existing);
  session->existing_active = gimp_filter_get_active (GIMP_FILTER (existing));
  session->non_destructive = TRUE;

  /* The shadow session, as gimp_filter_tool_get_operation() and
   * create_filter() build it: a new node seeded with every one of the
   * effect's parameters, owned by a new filter that inherits the
   * effect's blend and clipping state. The effect itself is untouched
   * until everything below has succeeded. */
  session->operation = gegl_node_new_child (NULL, "operation", operation, NULL);
  pspecs = gegl_operation_list_properties (operation, &n_pspecs);
  g_free (operation);
  for (guint i = 0; i < n_pspecs; i++)
    {
      GValue value = G_VALUE_INIT;

      if ((pspecs[i]->flags & G_PARAM_READWRITE) != G_PARAM_READWRITE)
        continue;
      /* The owned config hook installs its TRC and binding together. Generic
       * copying must not create an intermediate operation/config mismatch. */
      if (!strcmp (pspecs[i]->name, "trc") &&
          (glims_levels_config_is_operation (session->operation) ||
           glims_curves_config_is_operation (session->operation)))
        continue;
      if (!strcmp (pspecs[i]->name, "config") &&
          uses_owned_config (session->operation)) {
        status = copy_owned_config (session->operation, existing_node, error);
        if (status != GLIMS_STATUS_OK) {
          g_free (pspecs); glims_filters_free (session); return status;
        }
        continue;
      }
      g_value_init (&value, pspecs[i]->value_type);
      gegl_node_get_property (existing_node, pspecs[i]->name, &value);
      gegl_node_set_property (session->operation, pspecs[i]->name, &value);
      g_value_unset (&value);
    }
  g_free (pspecs);

  session->filter = gimp_drawable_filter_new (
    drawable, gimp_object_get_name (GIMP_OBJECT (existing)),
    session->operation, NULL);
  if (! session->filter)
    {
      /* Can't happen for an operation an effect was committed from. */
      glims_filters_free (session);
      return glims_fail (error, NULL, "That effect cannot be edited.");
    }
  gimp_drawable_filter_set_opacity (session->filter,
                                    gimp_drawable_filter_get_opacity (existing));
  gimp_drawable_filter_set_mode (session->filter,
                                 gimp_drawable_filter_get_paint_mode (existing),
                                 gimp_drawable_filter_get_blend_space (existing),
                                 gimp_drawable_filter_get_composite_space (existing),
                                 gimp_drawable_filter_get_composite_mode (existing));
  gimp_drawable_filter_set_region (session->filter,
                                   gimp_drawable_filter_get_region (existing));
  gimp_drawable_filter_set_clip (session->filter,
                                 gimp_drawable_filter_get_clip (existing));

  /* Capture the effect's mask before the shadow goes on the stack.
   * This prevents selection restoration from retargeting the mask;
   * preview_apply also supplies its bounds while core computes the crop. */
  {
    GimpDrawableFilterMask *mask = gimp_drawable_filter_get_mask (existing);

    if (mask)
      g_object_set (session->filter, "mask", mask, NULL);


    gimp_filter_set_active (GIMP_FILTER (existing), FALSE);
    glims_filter_preview_apply (session);
    gimp_drawable_filter_set_preview (session->filter, TRUE);

    /* The shadow then takes the effect's own slot (apply put it on
     * top) and is marked temporary so it can never be mistaken for a
     * committed effect or serialized. */
    filters = gimp_drawable_get_filters (drawable);
    index = gimp_container_get_child_index (filters, GIMP_OBJECT (existing));
    gimp_container_reorder (filters, GIMP_OBJECT (session->filter), index);

    gimp_drawable_filter_set_temporary (session->filter, TRUE);
  }

  gimp_drawable_update (drawable, 0, 0, -1, -1);
  gimp_image_flush (open->image);

  id = glims_next_session_id (engine);
  g_hash_table_insert (engine->filters, GINT_TO_POINTER (id), session);
  *out = id;

  return GLIMS_STATUS_OK;
}

/* A parked effect's captured selection defines its crop as well as
 * its applicator mask. Core sync_mask() calls item_mask_intersect(),
 * which consults the image's current selection even with a frozen mask.
 * Use the tool's temporary selection swap on every re-apply, not just
 * when the shadow starts, or an unrelated live selection crops it away. */
void
glims_filter_preview_apply (GlimsFilter *session)
{
  if (session->existing)
    {
      GimpDrawableFilterMask *mask = gimp_drawable_filter_get_mask (session->existing);

      gimp_drawable_filter_apply_with_mask (session->filter,
                                            mask ? GIMP_CHANNEL (mask) : NULL, NULL);
    }
  else
    gimp_drawable_filter_apply (session->filter, NULL);
  glims_adjustment_projection_changed (session->image);
}

GlimsStatus
glims_filter_set_double (GlimsEngine   *engine,
                         GlimsFilterID  id,
                         const char    *property,
                         double         value)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  GParamSpec  *pspec;
  GValue       number = G_VALUE_INIT;
  GValue       typed  = G_VALUE_INIT;
  GlimsStatus  status = glims_filter_check_edit (engine, id, NULL);

  if (status != GLIMS_STATUS_OK) return status;
  if (! property || ! isfinite (value))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  pspec = gegl_node_find_property (session->operation, property);
  if (! pspec)
    return GLIMS_STATUS_NOT_FOUND;

  /* Accept a number for any numeric property; GLib converts and the param
   * spec clamps to its range. */
  g_value_init (&number, G_TYPE_DOUBLE);
  g_value_set_double (&number, value);
  g_value_init (&typed, G_PARAM_SPEC_VALUE_TYPE (pspec));
  if (! g_value_transform (&number, &typed))
    {
      g_value_unset (&typed);
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  g_param_value_validate (pspec, &typed);
  gegl_node_set_property (session->operation, property, &typed);
  g_value_unset (&typed);

  glims_filter_preview_apply (session);
  gimp_image_flush (session->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_brightness_contrast_get (GlimsEngine *engine, GlimsFilterID id,
                                     GlimsBrightnessContrastSettings *out, char **error)
{
  GlimsFilter *session;
  if (!out || out->struct_size < sizeof *out) return GLIMS_STATUS_INVALID_ARGUMENT;
  out->brightness = out->contrast = 0;
  session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  if (!session) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  return glims_filter_config_get (session->operation, out, error);
}

GlimsStatus
glims_filter_brightness_contrast_set (GlimsEngine *engine, GlimsFilterID id,
                                     const GlimsBrightnessContrastSettings *settings, char **error)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  gboolean changed = FALSE;
  GlimsStatus status = glims_filter_check_edit (engine, id, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = glims_filter_config_set (session->operation, settings, &changed, error);
  if (status == GLIMS_STATUS_OK && changed) {
    glims_filter_preview_apply (session);
    gimp_image_flush (session->image);
  }
  return status;
}

GlimsStatus
glims_filter_color_balance_get (GlimsEngine *engine, GlimsFilterID id,
                                GlimsColorBalanceSettings *out, char **error)
{
  GlimsFilter *session;
  if (!out || out->struct_size < sizeof *out) return GLIMS_STATUS_INVALID_ARGUMENT;
  out->preserve_luminosity = 0;
  out->shadows = out->midtones = out->highlights = (GlimsColorBalanceRange) {0};
  session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  if (!session) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  return glims_color_balance_config_get (session->operation, out, error);
}

GlimsStatus
glims_filter_color_balance_set (GlimsEngine *engine, GlimsFilterID id,
                                const GlimsColorBalanceSettings *settings, char **error)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  gboolean changed = FALSE;
  GlimsStatus status = glims_filter_check_edit (engine, id, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = glims_color_balance_config_set (session->operation, settings, &changed, error);
  if (status == GLIMS_STATUS_OK && changed) {
    glims_filter_preview_apply (session);
    gimp_image_flush (session->image);
  }
  return status;
}

GlimsStatus
glims_filter_hue_saturation_get (GlimsEngine *engine, GlimsFilterID id,
                                GlimsHueSaturationSettings *out, char **error)
{
  GlimsFilter *session;
  if (!out || out->struct_size < sizeof *out) return GLIMS_STATUS_INVALID_ARGUMENT;
  out->overlap = 0;
  out->master = out->red = out->yellow = out->green = out->cyan = out->blue = out->magenta =
    (GlimsHueSaturationRange) {0};
  session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  if (!session) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  return glims_hue_saturation_config_get (session->operation, out, error);
}

GlimsStatus
glims_filter_hue_saturation_set (GlimsEngine *engine, GlimsFilterID id,
                                const GlimsHueSaturationSettings *settings, char **error)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  gboolean changed = FALSE;
  GlimsStatus status = glims_filter_check_edit (engine, id, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = glims_hue_saturation_config_set (session->operation, settings, &changed, error);
  if (status == GLIMS_STATUS_OK && changed) {
    glims_filter_preview_apply (session);
    gimp_image_flush (session->image);
  }
  return status;
}

GlimsStatus
glims_filter_levels_get (GlimsEngine *engine, GlimsFilterID id,
                                GlimsLevelsSettings *out, char **error)
{
  GlimsFilter *session;
  if (!out || out->struct_size < sizeof *out) return GLIMS_STATUS_INVALID_ARGUMENT;
  out->trc = out->clamp_input = out->clamp_output = 0;
  out->value = out->red = out->green = out->blue = out->alpha = (GlimsLevelsChannel) {0};
  session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  if (!session) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  return glims_levels_config_get (session->operation, out, error);
}

GlimsStatus
glims_filter_levels_set (GlimsEngine *engine, GlimsFilterID id,
                                const GlimsLevelsSettings *settings, char **error)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  gboolean changed = FALSE;
  GlimsStatus status = glims_filter_check_edit (engine, id, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = glims_levels_config_set (session->operation, settings, &changed, error);
  if (status == GLIMS_STATUS_OK && changed) {
    glims_filter_preview_apply (session);
    gimp_image_flush (session->image);
  }
  return status;
}

GlimsStatus
glims_filter_curves_get (GlimsEngine *engine, GlimsFilterID id,
                         GlimsCurvesSnapshot *out, char **error)
{
  GlimsFilter *session;
  if (!out || out->struct_size < sizeof *out) return GLIMS_STATUS_INVALID_ARGUMENT;
  glims_curves_snapshot_clear (out);
  session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  if (!session) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  return glims_curves_config_get (session->operation, out, error);
}

GlimsStatus
glims_filter_curves_edit (GlimsEngine *engine, GlimsFilterID id,
                          const GlimsCurveEdit *edit, GlimsCurvesSnapshot *out,
                          char **error)
{
  GlimsFilter *session;
  gboolean changed = FALSE;
  GlimsStatus status;
  if (!out || out->struct_size < sizeof *out) return GLIMS_STATUS_INVALID_ARGUMENT;
  glims_curves_snapshot_clear (out);
  status = glims_filter_check_edit (engine, id, error);
  if (status != GLIMS_STATUS_OK) return status;
  session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  status = glims_curves_config_edit (session->operation, edit, out, &changed, error);
  if (status == GLIMS_STATUS_OK && changed) {
    glims_filter_preview_apply (session);
    gimp_image_flush (session->image);
  }
  return status;
}

GlimsStatus
glims_filter_curves_set_trc (GlimsEngine *engine, GlimsFilterID id, uint32_t trc,
                             GlimsCurvesSnapshot *out, char **error)
{
  GlimsFilter *session;
  gboolean changed = FALSE;
  GlimsStatus status;
  if (!out || out->struct_size < sizeof *out) return GLIMS_STATUS_INVALID_ARGUMENT;
  glims_curves_snapshot_clear (out);
  status = glims_filter_check_edit (engine, id, error);
  if (status != GLIMS_STATUS_OK) return status;
  session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  status = glims_curves_config_set_trc (session->operation, trc, out, &changed, error);
  if (status == GLIMS_STATUS_OK && changed) {
    glims_filter_preview_apply (session);
    gimp_image_flush (session->image);
  }
  return status;
}

GlimsStatus
glims_filter_levels_auto (GlimsEngine *engine, GlimsFilterID id,
                          GlimsLevelsSettings *out, char **error)
{
  GlimsFilter *session;
  GimpHistogram *histogram = NULL;
  uint32_t trc;
  gboolean changed = FALSE;
  GlimsStatus status;
  if (!out || out->struct_size < sizeof *out) return GLIMS_STATUS_INVALID_ARGUMENT;
  out->trc = out->clamp_input = out->clamp_output = 0;
  out->value = out->red = out->green = out->blue = out->alpha = (GlimsLevelsChannel) {0};
  status = glims_filter_check_edit (engine, id, error);
  if (status != GLIMS_STATUS_OK) return status;
  session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  if (!glims_levels_config_is_operation (session->operation)) return GLIMS_STATUS_UNSUPPORTED;
  status = glims_filter_input_histogram_native (engine, id, &histogram, &session, &trc, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = glims_levels_config_auto (session->operation, histogram,
                                     gimp_drawable_is_rgb (session->drawable), out,
                                     &changed, error);
  g_object_unref (histogram);
  if (status == GLIMS_STATUS_OK && changed) {
    glims_filter_preview_apply (session);
    gimp_image_flush (session->image);
  }
  return status;
}

GlimsStatus
glims_filter_commit (GlimsEngine    *engine,
                     GlimsFilterID   id,
                     char          **error)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  GimpDrawableFilter *filter;
  GlimsStatus status = glims_filter_check_edit (engine, id, error);

  if (status != GLIMS_STATUS_OK) return status;
  if (session->aux_source || uses_owned_config (session->operation)) {
    status = source_merge_history_ready (session->image, error);
    if (status != GLIMS_STATUS_OK) return status;
  }

  /* Validate before either commit path can freeze masks or change history.
   * This also refuses externally altered/new configs without consuming the
   * preview, so a caller can still abort it safely. */
  if (glims_levels_config_is_operation (session->operation)) {
    GlimsLevelsSettings checked = { .struct_size = sizeof checked };
    status = glims_levels_config_get (session->operation, &checked, error);
    if (status != GLIMS_STATUS_OK) return status;
  }

  if (glims_curves_config_is_operation (session->operation)) {
    status = glims_curves_config_validate (session->operation, error);
    if (status != GLIMS_STATUS_OK) return status;
  }

  if (session->existing)
    {
      /* gimp_filter_tool_commit(), existing filter: the undo step
       * snapshots the effect before the shadow's parameters and blend
       * state are written into it, then the shadow is dropped and the
       * effect resumes its own slot, id and enabled state — nothing is
       * added or moved. */
      GimpDrawableFilter *existing      = session->existing;
      GimpDrawableFilter *preview       = session->filter;
      GeglNode           *existing_node = gimp_drawable_filter_get_operation (existing);
      GParamSpec        **specs;
      gchar              *operation_name = NULL;
      guint               n_specs;

      if (glims_filter_config_is_brightness_contrast (session->operation)) {
        GlimsBrightnessContrastSettings checked = { .struct_size = sizeof checked };
        status = glims_filter_config_get (session->operation, &checked, error);
        if (status != GLIMS_STATUS_OK) return status;
        status = glims_filter_config_get (existing_node, &checked, error);
        if (status != GLIMS_STATUS_OK) return status;
      }
      if (glims_color_balance_config_is_operation (session->operation)) {
        GlimsColorBalanceSettings checked = { .struct_size = sizeof checked };
        status = glims_color_balance_config_get (session->operation, &checked, error);
        if (status != GLIMS_STATUS_OK) return status;
        status = glims_color_balance_config_get (existing_node, &checked, error);
        if (status != GLIMS_STATUS_OK) return status;
      }
      if (glims_hue_saturation_config_is_operation (session->operation)) {
        GlimsHueSaturationSettings checked = { .struct_size = sizeof checked };
        status = glims_hue_saturation_config_get (session->operation, &checked, error);
        if (status != GLIMS_STATUS_OK) return status;
        status = glims_hue_saturation_config_get (existing_node, &checked, error);
        if (status != GLIMS_STATUS_OK) return status;
      }
      if (glims_levels_config_is_operation (session->operation)) {
        GlimsLevelsSettings checked = { .struct_size = sizeof checked };
        status = glims_levels_config_get (existing_node, &checked, error);
        if (status != GLIMS_STATUS_OK) return status;
      }

      if (glims_curves_config_is_operation (session->operation)) {
        status = glims_curves_config_validate (existing_node, error);
        if (status != GLIMS_STATUS_OK) return status;
      }

      if (! gimp_image_undo_push_filter_modified (session->image, _("Edit filter"),
                                                  session->drawable, existing))
        return glims_fail (error, NULL, "The image's undo history is unavailable.");

      gegl_node_get (session->operation, "operation", &operation_name, NULL);
      specs = gegl_operation_list_properties (operation_name, &n_specs);
      g_free (operation_name);
      for (guint i = 0; i < n_specs; i++)
        {
          GValue value = G_VALUE_INIT;

          if ((specs[i]->flags & G_PARAM_READWRITE) != G_PARAM_READWRITE)
            continue;
          if (!strcmp (specs[i]->name, "trc") &&
              (glims_levels_config_is_operation (session->operation) ||
               glims_curves_config_is_operation (session->operation)))
            continue;
          if (!strcmp (specs[i]->name, "config") &&
              uses_owned_config (session->operation)) {
            status = copy_owned_config (existing_node, session->operation, error);
            if (status != GLIMS_STATUS_OK) { g_free (specs); return status; }
            continue;
          }
          g_value_init (&value, specs[i]->value_type);
          gegl_node_get_property (session->operation, specs[i]->name, &value);
          gegl_node_set_property (existing_node, specs[i]->name, &value);
          g_value_unset (&value);
        }
      g_free (specs);

      gimp_drawable_filter_set_opacity (existing,
                                        gimp_drawable_filter_get_opacity (preview));
      gimp_drawable_filter_set_mode (existing,
                                     gimp_drawable_filter_get_paint_mode (preview),
                                     gimp_drawable_filter_get_blend_space (preview),
                                     gimp_drawable_filter_get_composite_space (preview),
                                     gimp_drawable_filter_get_composite_mode (preview));
      gimp_drawable_filter_set_region (existing,
                                       gimp_drawable_filter_get_region (preview));
      gimp_drawable_filter_set_clip (existing,
                                     gimp_drawable_filter_get_clip (preview));

      /* The shadow is spent: freeze its mask tracking, take it off the
       * stack, then hand the effect its enabled state back. */
      gimp_drawable_filter_layer_mask_freeze (preview);
      gimp_drawable_filter_abort (preview);
      g_clear_object (&session->filter);

      gimp_filter_set_active (GIMP_FILTER (existing), session->existing_active);
      g_clear_object (&session->existing);
      gimp_drawable_filters_changed (session->drawable);
      gimp_drawable_update (session->drawable, 0, 0, -1, -1);
      glims_adjustment_projection_changed (session->image);
      gimp_image_flush (session->image);

      g_hash_table_remove (engine->filters, GINT_TO_POINTER (id));
      return GLIMS_STATUS_OK;
    }

  filter = session->filter;

  /* gimp_filter_tool_commit(), new filter: the selection-mask hookup
   * freezes first either way. The abort/re-apply and the filter-add
   * undo step belong to the non-destructive branch only; a destructive
   * commit merges through gimp_drawable_merge_filter, which pushes the
   * drawable's own undo. */
  gimp_drawable_filter_layer_mask_freeze (filter);
  if (session->non_destructive)
    {
      gimp_drawable_filter_abort (filter);
      gimp_drawable_filter_apply (filter, NULL);
    }
  if (! gimp_drawable_filter_commit (filter, session->non_destructive, NULL, FALSE))
    return glims_fail (error, NULL, "The filter could not be applied.");

  if (session->non_destructive)
    {
      /* Committed now: no longer a temporary preview. */
      gimp_drawable_filter_set_temporary (filter, FALSE);
      gimp_image_undo_push_filter_add (session->image,
                                       gimp_object_get_name (GIMP_OBJECT (filter)),
                                       session->drawable, filter);
    }

  gimp_drawable_update (session->drawable, 0, 0, -1, -1);
  gimp_image_flush (session->image);

  /* A non-destructive commit leaves the filter on the drawable's stack;
   * a merged one was consumed by it. Either way the session is over. */
  g_clear_object (&session->filter);
  g_hash_table_remove (engine->filters, GINT_TO_POINTER (id));

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_filter_abort (GlimsEngine   *engine,
                    GlimsFilterID  id)
{
  GlimsFilter *session = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (id));
  GimpImage   *image;

  if (! session)
    return GLIMS_STATUS_NOT_FOUND;

  image = g_object_ref (session->image);
  g_hash_table_remove (engine->filters, GINT_TO_POINTER (id));
  gimp_image_flush (image);
  g_object_unref (image);

  return GLIMS_STATUS_OK;
}

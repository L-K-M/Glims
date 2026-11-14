#include "facade-policy.h"
#include "plate-storage.h"
#include "lab-layer-storage.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include <string.h>

typedef enum { POLICY_DIRECT, POLICY_GLOBAL, POLICY_CLEANUP, POLICY_ORDINARY, POLICY_COMPONENT, POLICY_COMPONENT_STROKE } Policy;
typedef struct { const char *name; GlimsFacadeTargetKind kind; Policy policy; } Descriptor;
static const Descriptor descriptors[GLIMS_FACADE_OPERATION_COUNT] = {
#define GLIMS_FACADE(name, wrapper, target, policy) \
  [GLIMS_FACADE_OP_##name] = { #name, GLIMS_FACADE_TARGET_##target, POLICY_##policy },
#include "facade-operations.def"
#undef GLIMS_FACADE
};

typedef struct {
  GlimsFacadeOperation operation;
  GlimsFacadeTarget target;
  GlimsEngineFunc func;
  gpointer data;
  char **error;
  gboolean *invoked;
} FacadeCall;

/* Layered Lab permits only qualified root properties and their history,
 * selection, viewing and XCF saving. Other mutations need explicit admission. */
static gboolean
layered_lab_operation_allowed (GlimsFacadeOperation operation)
{
  switch (operation)
    {
    case GLIMS_FACADE_OP_image_info:
    case GLIMS_FACADE_OP_image_layers:
    case GLIMS_FACADE_OP_image_color_info:
    case GLIMS_FACADE_OP_image_storage_info:
    case GLIMS_FACADE_OP_image_select_lab_shape:
    case GLIMS_FACADE_OP_image_select_lab_command:
    case GLIMS_FACADE_OP_image_lab_layer_identity:
    case GLIMS_FACADE_OP_image_fill_lab_layer:
    case GLIMS_FACADE_OP_image_render:
    case GLIMS_FACADE_OP_image_render_to_profile:
    case GLIMS_FACADE_OP_image_save:
    case GLIMS_FACADE_OP_image_save_copy:
    case GLIMS_FACADE_OP_image_undo_info:
    case GLIMS_FACADE_OP_image_undo:
    case GLIMS_FACADE_OP_image_redo:
    case GLIMS_FACADE_OP_image_history:
    case GLIMS_FACADE_OP_selection_bounds:
    case GLIMS_FACADE_OP_selection_outline:
    case GLIMS_FACADE_OP_paths:
    case GLIMS_FACADE_OP_image_quick_mask:
    case GLIMS_FACADE_OP_image_guides:
    case GLIMS_FACADE_OP_image_grid:
    case GLIMS_FACADE_OP_image_floating_selection:
    case GLIMS_FACADE_OP_image_selected_layers:
    case GLIMS_FACADE_OP_image_selected_items:
    case GLIMS_FACADE_OP_layer_select:
    case GLIMS_FACADE_OP_image_select_layers:
    case GLIMS_FACADE_OP_layer_change:
    case GLIMS_FACADE_OP_layer_command:
      return TRUE;
    default:
      return FALSE;
    }
}

static GlimsStatus
layered_lab_admission (GlimsOpenImage *open, GlimsFacadeOperation operation)
{
  if (!layered_lab_operation_allowed (operation)) return GLIMS_STATUS_UNSUPPORTED;
  g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
  if (!storage) return GLIMS_STATUS_FAILED;
  return glims_lab_layer_storage_read (open->image, storage) == GLIMS_LAB_LAYER_STORAGE_VALID
    ? GLIMS_STATUS_OK : GLIMS_STATUS_UNSUPPORTED;
}

/* Lab shares native scalar storage, not ink editing semantics. New component
 * operations must be admitted explicitly rather than inherit permission. */
static gboolean
component_lab_operation_allowed (GlimsFacadeOperation operation)
{
  switch (operation)
    {
    case GLIMS_FACADE_OP_image_info:
    case GLIMS_FACADE_OP_image_layers:
    case GLIMS_FACADE_OP_image_color_info:
    case GLIMS_FACADE_OP_image_storage_info:
    case GLIMS_FACADE_OP_image_lab_axes:
    case GLIMS_FACADE_OP_image_fill_lab:
    case GLIMS_FACADE_OP_image_curves_lab:
    case GLIMS_FACADE_OP_image_levels_lab:
    case GLIMS_FACADE_OP_image_lab_snapshot_levels:
    case GLIMS_FACADE_OP_image_lab_snapshot_apply_levels:
    case GLIMS_FACADE_OP_image_lab_snapshot_begin:
    case GLIMS_FACADE_OP_image_lab_snapshot_curves:
    case GLIMS_FACADE_OP_image_lab_snapshot_apply_curves:
    case GLIMS_FACADE_OP_image_lab_snapshot_end:
    case GLIMS_FACADE_OP_stroke_begin_lab:
    case GLIMS_FACADE_OP_stroke_begin_lab_with_capture_facts:
    case GLIMS_FACADE_OP_image_select_lab_shape:
    case GLIMS_FACADE_OP_image_select_lab_command:
    case GLIMS_FACADE_OP_image_convert_lab_copy:
    case GLIMS_FACADE_OP_channel_command:
    case GLIMS_FACADE_OP_image_render:
    case GLIMS_FACADE_OP_image_render_to_profile:
    case GLIMS_FACADE_OP_image_save:
    case GLIMS_FACADE_OP_image_save_copy:
    case GLIMS_FACADE_OP_image_undo_info:
    case GLIMS_FACADE_OP_image_history:
    case GLIMS_FACADE_OP_image_undo:
    case GLIMS_FACADE_OP_image_redo:
    case GLIMS_FACADE_OP_image_history_move:
    case GLIMS_FACADE_OP_selection_bounds:
    case GLIMS_FACADE_OP_selection_outline:
    case GLIMS_FACADE_OP_paths:
    case GLIMS_FACADE_OP_image_quick_mask:
    case GLIMS_FACADE_OP_image_guides:
    case GLIMS_FACADE_OP_image_grid:
    case GLIMS_FACADE_OP_image_floating_selection:
    case GLIMS_FACADE_OP_image_selected_layers:
    case GLIMS_FACADE_OP_image_selected_items:
      return TRUE;
    default:
      return FALSE;
    }
}

static gboolean
stroke_references_lab_image (GlimsEngine *engine, GlimsStrokeID id)
{
  GHashTableIter iter;
  gpointer value;

  /* Retained source drawables matter as well as the destination. The adopted
   * mode remains authoritative even if persistent metadata is damaged. */
  g_hash_table_iter_init (&iter, engine->images);
  while (g_hash_table_iter_next (&iter, NULL, &value))
    {
      GlimsOpenImage *open = value;
      if (open->component_document && open->component_mode == GLIMS_PLATE_MODE_LAB &&
          glims_stroke_references_image (engine, id, open->image))
        return TRUE;
    }
  return FALSE;
}

static gboolean
component_image (GlimsEngine *engine, GimpImage *image)
{
  GlimsOpenImage *open = image ? glims_lookup_image (engine, gimp_image_get_id (image)) : NULL;
  return open && open->component_document;
}

static gboolean
target_is_component (GlimsEngine *engine, GlimsFacadeTarget target)
{
  switch (target.kind)
    {
    case GLIMS_FACADE_TARGET_IMAGE:
      {
        GlimsOpenImage *open = glims_lookup_image (engine, target.id);
        if (open && open->component_document) return TRUE;
        break;
      }
    case GLIMS_FACADE_TARGET_FILTER:
      {
        GlimsFilter *filter = g_hash_table_lookup (engine->filters, GINT_TO_POINTER (target.id));
        if (filter && component_image (engine, filter->image)) return TRUE;
        break;
      }
    case GLIMS_FACADE_TARGET_STROKE:
      {
        GHashTableIter iter;
        gpointer value;
        g_hash_table_iter_init (&iter, engine->images);
        while (g_hash_table_iter_next (&iter, NULL, &value))
          {
            GlimsOpenImage *open = value;
            if (open->component_document && glims_stroke_references_image (engine, target.id, open->image))
              return TRUE;
          }
        break;
      }
    case GLIMS_FACADE_TARGET_ALL_IMAGES:
      {
        GHashTableIter iter;
        gpointer value;
        g_hash_table_iter_init (&iter, engine->images);
        while (g_hash_table_iter_next (&iter, NULL, &value))
          if (((GlimsOpenImage *) value)->component_document) return TRUE;
        break;
      }
    case GLIMS_FACADE_TARGET_NONE:
      break;
    default:
      return TRUE;
    }
  for (unsigned i = 0; i < G_N_ELEMENTS (target.sources); i++)
    if (target.sources[i])
      {
        GimpItem *item = gimp_item_get_by_id (engine->gimp, target.sources[i]);
        if (item && component_image (engine, gimp_item_get_image (item))) return TRUE;
      }
  return FALSE;
}

static GlimsStatus
dispatch (GlimsEngine *engine, gpointer data)
{
  FacadeCall *call = data;
  const Descriptor *descriptor = &descriptors[call->operation];
  /* No new operation can inherit permission merely because its arguments
   * look image-free. The manifest binds its expected resolver and policy. */
  if (call->target.kind != descriptor->kind || descriptor->policy == POLICY_DIRECT)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (descriptor->policy == POLICY_ORDINARY && target_is_component (engine, call->target))
    {
      GlimsOpenImage *open = call->target.kind == GLIMS_FACADE_TARGET_IMAGE
        ? glims_lookup_image (engine, call->target.id) : NULL;
      if (open && open->component_layout == GLIMS_COMPONENT_LAYOUT_LAYERED_LAB &&
          (call->operation == GLIMS_FACADE_OP_layer_select ||
           call->operation == GLIMS_FACADE_OP_image_select_layers ||
           call->operation == GLIMS_FACADE_OP_layer_change ||
           call->operation == GLIMS_FACADE_OP_layer_command) &&
          !call->target.sources[0] && !call->target.sources[1])
        {
          GlimsStatus status = layered_lab_admission (open, call->operation);
          if (status != GLIMS_STATUS_OK)
            {
              if (call->error) *call->error = strdup ("The layered Lab storage is damaged or unavailable.");
              return status;
            }
          if (call->invoked) *call->invoked = TRUE;
          return call->func (engine, call->data);
        }
      if (call->error) *call->error = strdup ("This command is not available for component documents.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (descriptor->policy == POLICY_COMPONENT)
    {
      /* Qualified destination operations never grant cross-image source
       * access. The backend still validates its own typed arguments. */
      for (guint i = 0; i < G_N_ELEMENTS (call->target.sources); i++)
        {
          GimpItem *item = gimp_item_get_by_id (engine->gimp, call->target.sources[i]);
          if (item && component_image (engine, gimp_item_get_image (item)))
            return GLIMS_STATUS_UNSUPPORTED;
        }
      GlimsOpenImage *open = glims_lookup_image (engine, call->target.id);
      if (open && open->component_document)
        {
          if (open->component_layout == GLIMS_COMPONENT_LAYOUT_LAYERED_LAB)
            {
              GlimsStatus status = layered_lab_admission (open, call->operation);
              if (status != GLIMS_STATUS_OK)
                {
                  if (call->error) *call->error = strdup ("This command is unavailable or the layered Lab storage is invalid.");
                  return status;
                }
              if (call->invoked) *call->invoked = TRUE;
              return call->func (engine, call->data);
            }
          GlimsPlateStorage storage;
          if (!glims_plate_storage_read_open (open, &storage))
            {
              if (call->error) *call->error = strdup ("The document's component storage is damaged or unsupported.");
              return GLIMS_STATUS_UNSUPPORTED;
            }
          if (storage.map.mode == GLIMS_PLATE_MODE_LAB &&
              !component_lab_operation_allowed (call->operation))
            {
              if (call->error) *call->error = strdup ("This command is not available for Lab component documents.");
              return GLIMS_STATUS_UNSUPPORTED;
            }
        }
    }
  if (descriptor->policy == POLICY_COMPONENT_STROKE)
    {
      /* Typed ink continuation validates and cancels its own captured target,
       * including damaged storage. Early policy rejection would strand it. */
      if (call->operation == GLIMS_FACADE_OP_stroke_continue_v2 &&
          glims_stroke_is_ink (engine, call->target.id))
        {
          if (call->invoked) *call->invoked = TRUE;
          return call->func (engine, call->data);
        }
      if (stroke_references_lab_image (engine, call->target.id))
        {
          /* Typed Lab continuation owns target revalidation and whole-stroke
           * cancellation on failure. Do not strand it behind storage admission. */
          if (call->operation == GLIMS_FACADE_OP_stroke_continue_v2 &&
              glims_stroke_is_lab (engine, call->target.id))
            {
              if (call->invoked) *call->invoked = TRUE;
              return call->func (engine, call->data);
            }
          if (call->error) *call->error = strdup ("This command is not available for Lab component documents.");
          return GLIMS_STATUS_UNSUPPORTED;
        }
      if (target_is_component (engine, call->target))
        {
          GlimsStatus status = glims_stroke_component_ready (engine, call->target.id);
          if (status != GLIMS_STATUS_OK) return status;
        }
    }
  if (call->invoked) *call->invoked = TRUE;
  return call->func (engine, call->data);
}

GlimsStatus
glims_facade_call (GlimsEngine *engine, GlimsFacadeOperation operation,
                   GlimsFacadeTarget target, GlimsEngineFunc func, gpointer data, char **error)
{
  return glims_facade_call_reporting_admission (engine, operation, target, func, data, error, NULL);
}

GlimsStatus
glims_facade_call_reporting_admission (GlimsEngine *engine, GlimsFacadeOperation operation,
                                      GlimsFacadeTarget target, GlimsEngineFunc func, gpointer data,
                                      char **error, gboolean *invoked)
{
  if (invoked) *invoked = FALSE;
  if ((unsigned) operation >= GLIMS_FACADE_OPERATION_COUNT || !func)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  FacadeCall call = { operation, target, func, data, error, invoked };
  return glims_engine_call (engine, dispatch, &call);
}

GlimsItemID
glims_facade_brush_source (const GlimsBrushSettings *settings)
{
  if (!settings || settings->struct_size < sizeof *settings ||
      (settings->tool != GLIMS_PAINT_CLONE && settings->tool != GLIMS_PAINT_HEAL)) return 0;
  return settings->source_drawable;
}

GlimsFacadeTargetKind
glims_facade_target_kind (GlimsFacadeOperation operation)
{
  return (unsigned) operation < GLIMS_FACADE_OPERATION_COUNT ? descriptors[operation].kind : -1;
}

const char *
glims_facade_operation_name (GlimsFacadeOperation operation)
{
  return (unsigned) operation < GLIMS_FACADE_OPERATION_COUNT ? descriptors[operation].name : NULL;
}

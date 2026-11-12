/* Numeric ink edits stage a complete result before native Undo/publication.
 * No RGB color conversion or native background-color Clear is involved. */
#include "engine-private.h"
#include "plate-storage.h"
#include "component-curves.h"
#include "component-scalar.h"
#include "component-levels.h"
#include "lab-fill.h"
#include "lab-curves.h"

#include <math.h>
#include <string.h>
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimpitem.h"
#include "core/gimpprogress.h"

/* The calculated cache holds one render. Its kind tag keeps Levels and
 * Curves values from ever being compared or served across requests. */
typedef enum {
  INK_SNAPSHOT_CALC_LEVELS,
  INK_SNAPSHOT_CALC_CURVES,
  INK_SNAPSHOT_CALC_LAB_CURVES
} InkSnapshotCalc;

typedef struct _GlimsInkSnapshot {
  guint64 token;
  GlimsItemID target;
  guint target_index;
  guint8 target_uuid[16];
  /* Not adopted or exposed through an image ID. Only derived work copies
   * enter engine->images; callers cannot change this immutable baseline. */
  GimpImage *frozen;
  /* One private calculated image avoids repeating the full-plane edit for
   * each viewport. Public results are duplicates, never this cached image. */
  GimpImage *calculated;
  InkSnapshotCalc calculated_kind;
  GlimsComponentLevels calculated_levels;
  GlimsComponentCurve calculated_curve;
} GlimsInkSnapshot;

void
glims_ink_snapshot_free (GlimsInkSnapshot *snapshot)
{
  if (!snapshot) return;
  g_object_unref (snapshot->frozen);
  g_clear_object (&snapshot->calculated);
  g_free (snapshot);
}

typedef struct {
  GlimsEngine *engine;
  GlimsProgress *progress;
  guint64 completed, total;
  gint64 last_service;
  gboolean cancelled;
} InkEditProgress;

static void
cancel_edit (GimpProgress *progress, gpointer data)
{
  ((InkEditProgress *) data)->cancelled = TRUE;
}

static gboolean
continue_edit (InkEditProgress *state)
{
  gint64 now = g_get_monotonic_time ();
  if (now - state->last_service >= 10 * G_TIME_SPAN_MILLISECOND ||
      state->completed == state->total)
    {
      gimp_progress_set_value (GIMP_PROGRESS (state->progress),
                                (double) state->completed / state->total);
      for (guint i = 0; i < 4; i++)
        {
          if (!g_main_context_iteration (NULL, FALSE)) break;
          if (g_get_monotonic_time () - now >= 5 * G_TIME_SPAN_MILLISECOND) break;
        }
      state->last_service = g_get_monotonic_time ();
    }
  g_mutex_lock (&state->engine->lock);
  gboolean stopping = state->engine->stopping;
  g_mutex_unlock (&state->engine->lock);
  return !state->cancelled && !stopping;
}

static GimpDrawable *
selected_ink (GlimsOpenImage *open, GlimsItemID id, const GlimsPlateStorage *storage)
{
  GList *selected = gimp_image_get_selected_channels (open->image);
  if (!id || !selected || selected->next) return NULL;
  for (guint i = 0; i < storage->map.count; i++)
    if (selected->data == storage->planes[i] &&
        gimp_item_get_id (GIMP_ITEM (storage->planes[i])) == id)
      return GIMP_DRAWABLE (storage->planes[i]);
  return NULL;
}

static gboolean
snapshot_metadata_matches (GlimsOpenImage *open, const GlimsInkSnapshot *snapshot,
                           GlimsPlateStorage *current, GlimsPlateStorage *frozen)
{
  guint8 a[GLIMS_PLATE_MAP_MAX_SIZE], b[GLIMS_PLATE_MAP_MAX_SIZE];
  size_t a_size, b_size;
  if (!glims_plate_storage_read_open (open, current) ||
      glims_plate_storage_read (snapshot->frozen, frozen) != GLIMS_PLATE_STORAGE_VALID ||
      !glims_plate_map_encode (&current->map, a, sizeof a, &a_size) ||
      !glims_plate_map_encode (&frozen->map, b, sizeof b, &b_size) ||
      a_size != b_size || memcmp (a, b, a_size) ||
      current->profile_size != frozen->profile_size ||
      (current->profile_size && memcmp (current->profile, frozen->profile, current->profile_size)) ||
      snapshot->target_index >= current->map.count ||
      memcmp (current->map.entries[snapshot->target_index].uuid, snapshot->target_uuid, 16) ||
      selected_ink (open, snapshot->target, current) !=
        GIMP_DRAWABLE (current->planes[snapshot->target_index]))
    return FALSE;
  for (guint i = 0; i < current->map.count; i++)
    if (current->visible[i] != frozen->visible[i] ||
        g_strcmp0 (gimp_object_get_name (current->planes[i]),
                   gimp_object_get_name (frozen->planes[i])))
      return FALSE;
  return TRUE;
}

/* No version counter in the facade covers both scalar samples and selection.
 * Compare exact native bytes under busy ownership, including hidden inks. */
static GlimsStatus
snapshot_pixels_match (GlimsOpenImage *open, const GlimsInkSnapshot *snapshot,
                       InkEditProgress *state, char **error)
{
  GlimsPlateStorage current, frozen;
  GeglBuffer *live[GLIMS_PLATE_LIMIT + 1] = { NULL };
  GeglBuffer *saved[GLIMS_PLATE_LIMIT + 1] = { NULL };
  GlimsStatus status;
  if (!snapshot_metadata_matches (open, snapshot, &current, &frozen)) goto stale;
  guint32 source[4096], baseline[4096];
  /* Resolve and own every buffer before the first cooperative dispatch.
   * Borrowed storage plane pointers never cross that dispatch boundary. */
  for (guint plane = 0; plane <= current.map.count; plane++)
    {
      GimpDrawable *a = plane < current.map.count ? GIMP_DRAWABLE (current.planes[plane]) :
                         GIMP_DRAWABLE (gimp_image_get_mask (open->image));
      GimpDrawable *b = plane < frozen.map.count ? GIMP_DRAWABLE (frozen.planes[plane]) :
                         GIMP_DRAWABLE (gimp_image_get_mask (snapshot->frozen));
      live[plane] = g_object_ref (gimp_drawable_get_buffer (a));
      saved[plane] = g_object_ref (gimp_drawable_get_buffer (b));
    }
  for (guint plane = 0; plane <= current.map.count; plane++)
    {
      const Babl *format = gegl_buffer_get_format (live[plane]);
      gint size = babl_format_get_bytes_per_pixel (format);
      if (format != gegl_buffer_get_format (saved[plane]) || size < 1 || size > 4) goto stale;
      for (guint y = 0; y < current.map.height; y++)
        for (guint x = 0; x < current.map.width; )
          {
            if (!continue_edit (state)) { status = GLIMS_STATUS_CANCELLED; goto finish; }
            guint count = MIN (4096, current.map.width - x);
            GeglRectangle row = { (gint) x, (gint) y, (gint) count, 1 };
            gegl_buffer_get (live[plane], &row, 1, format, source,
                              GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
            gegl_buffer_get (saved[plane], &row, 1, format, baseline,
                              GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
            if (memcmp (source, baseline, count * size)) goto stale;
            state->completed += count;
            x += count;
          }
    }
  status = GLIMS_STATUS_OK;
  goto finish;
stale:
  if (error) *error = g_strdup ("The image changed after this preview began. Close the adjustment and try again.");
  status = GLIMS_STATUS_INVALID_ARGUMENT;
finish:
  for (guint i = 0; i < G_N_ELEMENTS (live); i++)
    {
      g_clear_object (&live[i]);
      g_clear_object (&saved[i]);
    }
  return status;
}

typedef bool (*InkRow) (GlimsComponentScalarFormat format, const void *settings,
                        size_t count, const void *source, const float *mask,
                        void *destination, bool *changed);

static gboolean
lab_target_matches (const GlimsPlateStorage *storage,
                     const GlimsLabFillSettings *settings, GimpDrawable *target)
{
  return storage->map.mode == GLIMS_PLATE_MODE_LAB && storage->map.count == 3 &&
         settings->role <= GLIMS_LAB_AXIS_B &&
         GIMP_DRAWABLE (storage->planes[settings->role]) == target &&
         !memcmp (storage->map.entries[settings->role].uuid, settings->uuid, 16);
}

static GlimsStatus
apply_component (GlimsEngine *engine, GlimsImageID id, GlimsItemID channel,
           const char *title, gboolean skip_calculation,
           InkRow calculate, const void *settings, const GlimsInkSnapshot *snapshot,
           const GlimsLabFillSettings *lab, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;

  GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open (open, &storage) ||
      ((storage.map.mode == GLIMS_PLATE_MODE_LAB) != (lab != NULL)))
    {
      if (error) *error = g_strdup (lab ? "Select a Lab document for this command." :
                                          "Select a native ink document for this command.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  GimpDrawable *target = selected_ink (open, channel, &storage);
  if (!target || (lab && !lab_target_matches (&storage, lab, target)))
    {
      if (error) *error = g_strdup (lab ? "The selected Lab channel changed. Select it again and retry." :
                                          "The selected ink changed. Select one ink channel and try again.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  status = glims_check_item_locks (GIMP_ITEM (target), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;

  GlimsComponentScalarFormat format;
  switch (storage.map.storage)
    {
    case GLIMS_PLATE_STORAGE_U8: format = GLIMS_COMPONENT_SCALAR_U8; break;
    case GLIMS_PLATE_STORAGE_U16: format = GLIMS_COMPONENT_SCALAR_U16; break;
    case GLIMS_PLATE_STORAGE_FLOAT: format = GLIMS_COMPONENT_SCALAR_FLOAT; break;
    default: return GLIMS_STATUS_UNSUPPORTED;
    }
  bool validation_changed;
  if (!calculate (format, settings, 0, NULL, NULL, NULL, &validation_changed))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (skip_calculation) return GLIMS_STATUS_OK;

  GeglRectangle region = { 0, 0, 0, 0 };
  if (!gimp_item_mask_intersect (GIMP_ITEM (target), &region.x, &region.y,
                                  &region.width, &region.height))
    {
      if (!snapshot) return GLIMS_STATUS_OK;
      region = (GeglRectangle) { 0, 0, 0, 0 };
    }
  GimpChannel *selection = gimp_image_get_mask (open->image);
  gboolean masked = !gimp_channel_is_empty (selection);

  /* Own every native object used after dispatch. Busy gates other edits;
   * the candidate and selection snapshot contain no borrowed storage state. */
  engine->busy++;
  GimpImage *image = g_object_ref (open->image);
  g_object_ref (target);
  GeglBuffer *source = g_object_ref (gimp_drawable_get_buffer (target));
  GeglBuffer *candidate = gegl_buffer_dup (source);
  GeglBuffer *mask = masked ? gegl_buffer_dup (gimp_drawable_get_buffer (GIMP_DRAWABLE (selection))) : NULL;
  const Babl *native_format = gegl_buffer_get_format (source);
  InkEditProgress state = { .engine = engine,
    .total = (guint64) region.width * region.height };
  if (snapshot)
    state.total += ((guint64) storage.map.count + 1) * storage.map.width * storage.map.height;
  state.progress = glims_progress_new (engine);
  engine->progress = state.progress;
  gulong cancel_handler = g_signal_connect (state.progress, "cancel", G_CALLBACK (cancel_edit), &state);
  gimp_progress_start (GIMP_PROGRESS (state.progress), TRUE, "%s", title);

  if (snapshot)
    {
      status = snapshot_pixels_match (open, snapshot, &state, error);
      if (status != GLIMS_STATUS_OK) goto finish;
    }

  /* At most 4096 samples per scalar/selection read. Staged GEGL tiles use
   * copy-on-write and its existing cache/spill policy; no whole-image malloc. */
  uint32_t input[4096], output[4096];
  float coverage[4096];
  gboolean changed = FALSE;
  GeglRectangle damage = { 0, 0, 0, 0 };
  for (gint y = region.y; y < region.y + region.height; y++)
    for (gint x = region.x; x < region.x + region.width; )
      {
        if (!continue_edit (&state)) { status = GLIMS_STATUS_CANCELLED; goto finish; }
        gint count = MIN (4096, region.x + region.width - x);
        GeglRectangle row = { x, y, count, 1 };
        gegl_buffer_get (source, &row, 1, native_format, input,
                          GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        if (mask)
          gegl_buffer_get (mask, &row, 1, babl_format ("Y float"), coverage,
                            GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        bool row_changed = false;
        if (!calculate (format, settings, count, input,
                         mask ? coverage : NULL, output, &row_changed))
          {
            if (error) *error = g_strdup (lab ?
              "The Lab edit contains invalid samples or produces an unrepresentable value. No pixels were changed." :
              "The ink edit contains invalid samples or produces an unrepresentable value. No pixels were changed.");
            status = GLIMS_STATUS_INVALID_ARGUMENT;
            goto finish;
          }
        if (row_changed)
          {
            gegl_buffer_set (candidate, &row, 0, native_format, output, GEGL_AUTO_ROWSTRIDE);
            if (changed) gegl_rectangle_bounding_box (&damage, &damage, &row);
            else damage = row;
            changed = TRUE;
          }
        state.completed += count;
        x += count;
      }

  if (!continue_edit (&state)) { status = GLIMS_STATUS_CANCELLED; goto finish; }
  if (changed || snapshot)
    {
      /* Re-resolve after nested dispatch, then publish without yielding.
       * The existing native drawable Undo snapshots exact scalar bytes before
       * the copy. Selection is already applied once in the candidate. */
      GlimsOpenImage *current = glims_lookup_image (engine, id);
      GlimsPlateStorage current_storage;
      if (!current || current->image != image ||
          !glims_plate_storage_read_open (current, &current_storage) ||
          selected_ink (current, channel, &current_storage) != target ||
          (lab && !lab_target_matches (&current_storage, lab, target)) ||
          (!lab && current_storage.map.mode == GLIMS_PLATE_MODE_LAB) ||
          gimp_drawable_get_buffer (target) != source)
        {
          if (error) *error = g_strdup (lab ? "The selected Lab channel changed before the Lab edit could finish." :
                                              "The selected ink changed before the edit could finish.");
          status = GLIMS_STATUS_INVALID_ARGUMENT;
          goto finish;
        }
      if (snapshot)
        {
          GlimsPlateStorage baseline;
          if (!snapshot_metadata_matches (current, snapshot, &current_storage, &baseline))
            {
              if (error) *error = g_strdup ("The image changed before the adjustment could be applied.");
              status = GLIMS_STATUS_INVALID_ARGUMENT;
              goto finish;
            }
        }
      status = glims_check_item_locks (GIMP_ITEM (target), GLIMS_LOCK_PIXELS, error);
      if (status != GLIMS_STATUS_OK) goto finish;
      if (changed)
        {
          gimp_drawable_push_undo (target, title, NULL, damage.x, damage.y, damage.width, damage.height);
          gegl_buffer_copy (candidate, &damage, GEGL_ABYSS_NONE, source, &damage);
          gimp_drawable_update (target, damage.x, damage.y, damage.width, damage.height);
          gimp_image_flush (image);
        }
    }
  status = GLIMS_STATUS_OK;

finish:
  g_signal_handler_disconnect (state.progress, cancel_handler);
  gimp_progress_end (GIMP_PROGRESS (state.progress));
  engine->progress = NULL;
  g_object_unref (state.progress);
  g_clear_object (&mask);
  g_object_unref (candidate);
  g_object_unref (source);
  g_object_unref (target);
  g_object_unref (image);
  engine->busy--;
  return status;
}

static GlimsStatus
apply_ink (GlimsEngine *engine, GlimsImageID id, GlimsItemID channel,
           const char *title, gboolean skip_calculation,
           InkRow calculate, const void *settings, const GlimsInkSnapshot *snapshot,
           char **error)
{
  return apply_component (engine, id, channel, title, skip_calculation,
                           calculate, settings, snapshot, NULL, error);
}

static bool
lab_fill_row (GlimsComponentScalarFormat format, const void *settings,
              size_t count, const void *source, const float *mask,
              void *destination, bool *changed)
{
  const GlimsLabFillSettings *fill = settings;
  const GlimsLabRole roles[] = { GLIMS_LAB_ROLE_L, GLIMS_LAB_ROLE_A, GLIMS_LAB_ROLE_B };
  GlimsLabFormat lab_format;
  switch (format)
    {
    case GLIMS_COMPONENT_SCALAR_U8: lab_format = GLIMS_LAB_FORMAT_U8; break;
    case GLIMS_COMPONENT_SCALAR_U16: lab_format = GLIMS_LAB_FORMAT_U16; break;
    case GLIMS_COMPONENT_SCALAR_FLOAT: lab_format = GLIMS_LAB_FORMAT_FLOAT; break;
    default: return false;
    }
  if (fill->role > GLIMS_LAB_AXIS_B) return false;
  return glims_lab_fill_row (roles[fill->role], lab_format, fill->value, fill->opacity,
                              count, source, mask, destination, changed);
}

GlimsStatus
glims_image_fill_lab (GlimsEngine *engine, GlimsImageID id,
                      const GlimsLabFillSettings *settings, char **error)
{
  if (error) *error = NULL;
  if (!settings || settings->struct_size < sizeof *settings || settings->axis <= 0 ||
      settings->role > GLIMS_LAB_AXIS_B || !isfinite (settings->value) ||
      !isfinite (settings->opacity) || settings->opacity < 0 || settings->opacity > 1)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  /* Own the immutable request across cooperative progress callbacks. The UUID
   * and role bind this handle to the document's canonical captured axis. */
  GlimsLabFillSettings fill = *settings;
  return apply_component (engine, id, fill.axis, "Fill Lab Channel", fill.opacity == 0,
                           lab_fill_row, &fill, NULL, &fill, error);
}

static bool
lab_curves_row (GlimsComponentScalarFormat format, const void *settings,
                size_t count, const void *source, const float *mask,
                void *destination, bool *changed)
{
  const GlimsLabCurvesSettings *curves = settings;
  GlimsLabFormat lab_format;
  switch (format)
    {
    case GLIMS_COMPONENT_SCALAR_U8: lab_format = GLIMS_LAB_FORMAT_U8; break;
    case GLIMS_COMPONENT_SCALAR_U16: lab_format = GLIMS_LAB_FORMAT_U16; break;
    case GLIMS_COMPONENT_SCALAR_FLOAT: lab_format = GLIMS_LAB_FORMAT_FLOAT; break;
    default: return false;
    }
  if (curves->role > GLIMS_LAB_AXIS_B) return false;
  GlimsLabCurve curve;
  memcpy (curve.samples, curves->samples, sizeof curve.samples);
  return glims_lab_curves_row ((GlimsLabRole[]) { GLIMS_LAB_ROLE_L, GLIMS_LAB_ROLE_A, GLIMS_LAB_ROLE_B }[curves->role],
                               lab_format, &curve, count, source, mask, destination, changed);
}

GlimsStatus
glims_image_curves_lab (GlimsEngine *engine, GlimsImageID id,
                        const GlimsLabCurvesSettings *settings, char **error)
{
  if (error) *error = NULL;
  if (!settings || settings->struct_size < sizeof *settings || settings->axis <= 0 ||
      settings->role > GLIMS_LAB_AXIS_B)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  for (guint i = 0; i < G_N_ELEMENTS (settings->samples); i++)
    if (!isfinite (settings->samples[i]) || settings->samples[i] < 0 || settings->samples[i] > 1)
      return GLIMS_STATUS_INVALID_ARGUMENT;
  /* Own the immutable request across cooperative progress callbacks. The UUID
   * and role bind this handle to the document's canonical captured axis. The
   * Lab Fill binding checks only axis/role/uuid, so reuse it as an explicit
   * identity bridge without widening ink/fill semantics. */
  GlimsLabCurvesSettings curves = *settings;
  GlimsLabFillSettings identity = { 0 };
  identity.struct_size = sizeof identity;
  identity.axis = curves.axis;
  identity.role = curves.role;
  memcpy (identity.uuid, curves.uuid, sizeof identity.uuid);
  identity.value = curves.role == GLIMS_LAB_AXIS_LIGHTNESS ? 0 : -128;
  identity.opacity = 1;
  /* Even identity must validate affected source samples and selection masks. */
  return apply_component (engine, id, curves.axis, "Curves Lab", FALSE,
                          lab_curves_row, &curves, NULL, &identity, error);
}

typedef struct {
  GlimsComponentScalarOperation operation;
  double intensity, opacity;
} ScalarEdit;

static bool
scalar_row (GlimsComponentScalarFormat format, const void *settings,
            size_t count, const void *source, const float *mask,
            void *destination, bool *changed)
{
  const ScalarEdit *s = settings;
  return glims_component_scalar_row (format, s->operation, s->intensity, s->opacity,
                                     count, source, mask, destination, changed);
}

static bool
levels_row (GlimsComponentScalarFormat format, const void *settings,
            size_t count, const void *source, const float *mask,
            void *destination, bool *changed)
{
  return glims_component_levels_row (format, settings, count, source, mask,
                                     destination, changed);
}

static bool
curves_row (GlimsComponentScalarFormat format, const void *settings,
            size_t count, const void *source, const float *mask,
            void *destination, bool *changed)
{
  return glims_component_curves_row (format, settings, count, source, mask,
                                     destination, changed);
}

GlimsStatus
glims_image_edit_ink (GlimsEngine *engine, GlimsImageID id, GlimsItemID channel,
                      uint32_t operation, double intensity, double opacity, char **error)
{
  if (error) *error = NULL;
  if (!channel || operation > GLIMS_INK_EDIT_INVERT ||
      !isfinite (intensity) || intensity < 0 || intensity > 1 ||
      !isfinite (opacity) || opacity < 0 || opacity > 1 ||
      (operation == GLIMS_INK_EDIT_CLEAR && (intensity != 1 || opacity != 1)) ||
      (operation == GLIMS_INK_EDIT_INVERT && (intensity != 0 || opacity != 1)))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  const char *title = operation == GLIMS_INK_EDIT_FILL ? "Fill Ink" :
                      operation == GLIMS_INK_EDIT_CLEAR ? "Clear Ink" : "Invert Ink";
  const ScalarEdit settings = {
    operation == GLIMS_INK_EDIT_INVERT ? GLIMS_COMPONENT_SCALAR_INVERT : GLIMS_COMPONENT_SCALAR_FILL,
    intensity, opacity
  };
  return apply_ink (engine, id, channel, title, opacity == 0, scalar_row, &settings, NULL, error);
}

static gboolean
read_levels (const GlimsInkLevelsSettings *settings, GlimsComponentLevels *values)
{
  if (!settings || settings->struct_size < sizeof *settings) return FALSE;
  *values = (GlimsComponentLevels) {
    settings->value.low_input, settings->value.high_input, settings->value.gamma,
    settings->value.low_output, settings->value.high_output,
    settings->clamp_input, settings->clamp_output
  };
  bool changed;
  return glims_component_levels_row (GLIMS_COMPONENT_SCALAR_U8, values, 0,
                                      NULL, NULL, NULL, &changed);
}

GlimsStatus
glims_image_levels_ink (GlimsEngine *engine, GlimsImageID id, GlimsItemID channel,
                        const GlimsInkLevelsSettings *settings, char **error)
{
  if (error) *error = NULL;
  GlimsComponentLevels values;
  if (!channel || !read_levels (settings, &values))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  return apply_ink (engine, id, channel, "Levels Ink", FALSE, levels_row, &values, NULL, error);
}

static gboolean
read_curves (const GlimsInkCurvesSettings *settings, GlimsComponentCurve *values)
{
  G_STATIC_ASSERT (GLIMS_CURVE_SAMPLE_COUNT == GLIMS_COMPONENT_CURVE_SAMPLES);
  if (!settings || settings->struct_size < sizeof *settings) return FALSE;
  /* Own the borrowed immutable table before any nested dispatch. */
  memcpy (values->samples, settings->samples, sizeof values->samples);
  bool changed;
  return glims_component_curves_row (GLIMS_COMPONENT_SCALAR_U8, values, 0,
                                     NULL, NULL, NULL, &changed);
}

GlimsStatus
glims_image_curves_ink (GlimsEngine *engine, GlimsImageID id, GlimsItemID channel,
                        const GlimsInkCurvesSettings *settings, char **error)
{
  if (error) *error = NULL;
  GlimsComponentCurve values;
  if (!channel || !read_curves (settings, &values))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  return apply_ink (engine, id, channel, "Curves Ink", FALSE, curves_row, &values, NULL, error);
}

GlimsStatus
glims_image_ink_snapshot_begin (GlimsEngine *engine, GlimsImageID id,
                                GlimsItemID channel, uint64_t *token, char **error)
{
  if (error) *error = NULL;
  if (token) *token = 0;
  if (!channel || !token) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (open->ink_snapshot || open->lab_snapshot || g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;
  if (engine->next_ink_snapshot_token == G_MAXUINT64)
    return GLIMS_STATUS_FAILED;
  GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open (open, &storage) ||
      storage.map.mode == GLIMS_PLATE_MODE_LAB) return GLIMS_STATUS_UNSUPPORTED;
  GimpDrawable *target = selected_ink (open, channel, &storage);
  if (!target) return GLIMS_STATUS_INVALID_ARGUMENT;
  status = glims_check_item_locks (GIMP_ITEM (target), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;
  engine->busy++;
  GimpImage *frozen = gimp_image_duplicate (open->image);
  engine->busy--;
  if (!frozen) return glims_fail (error, NULL, "The ink preview could not be prepared.");
  GlimsInkSnapshot *snapshot = g_new0 (GlimsInkSnapshot, 1);
  snapshot->frozen = frozen;
  snapshot->target = channel;
  for (guint i = 0; i < storage.map.count; i++)
    if (GIMP_DRAWABLE (storage.planes[i]) == target) snapshot->target_index = i;
  memcpy (snapshot->target_uuid, storage.map.entries[snapshot->target_index].uuid, 16);
  GlimsPlateStorage a, b;
  if (!snapshot_metadata_matches (open, snapshot, &a, &b))
    {
      glims_ink_snapshot_free (snapshot);
      return glims_fail (error, NULL, "The ink preview could not preserve the source document.");
    }
  snapshot->token = ++engine->next_ink_snapshot_token;
  open->ink_snapshot = snapshot;
  *token = snapshot->token;
  return GLIMS_STATUS_OK;
}

static GlimsInkSnapshot *
find_snapshot (GlimsOpenImage *open, uint64_t token)
{
  return open && token && open->ink_snapshot && open->ink_snapshot->token == token
           ? open->ink_snapshot : NULL;
}

static gboolean
same_levels (const GlimsComponentLevels *a, const GlimsComponentLevels *b)
{
  return a->low_input == b->low_input && a->high_input == b->high_input &&
         a->gamma == b->gamma && a->low_output == b->low_output &&
         a->high_output == b->high_output && a->clamp_input == b->clamp_input &&
         a->clamp_output == b->clamp_output;
}

/* Compare cache only within the same calculation kind: a Levels hit never
 * serves a Curves request or vice versa. Values is the owned request copy. */
static gboolean
same_calculated (const GlimsInkSnapshot *snapshot, InkSnapshotCalc kind,
                 const void *values)
{
  if (snapshot->calculated_kind != kind) return FALSE;
  return kind == INK_SNAPSHOT_CALC_CURVES
           ? !memcmp (&snapshot->calculated_curve, values,
                      sizeof snapshot->calculated_curve)
           : same_levels (&snapshot->calculated_levels, values);
}

static void
store_calculated (GlimsInkSnapshot *snapshot, InkSnapshotCalc kind,
                  const void *values)
{
  snapshot->calculated_kind = kind;
  if (kind == INK_SNAPSHOT_CALC_CURVES)
    snapshot->calculated_curve = *(const GlimsComponentCurve *) values;
  else
    snapshot->calculated_levels = *(const GlimsComponentLevels *) values;
}

/* Shared preview body: values is the caller's owned stack copy, valid across
 * the nested apply_ink dispatch. Both kinds share ownership and cleanup. */
static GlimsStatus
ink_snapshot_render (GlimsEngine *engine,
                     GlimsInkSnapshot *snapshot, const char *title,
                     InkRow calculate, const void *values,
                     InkSnapshotCalc kind, GlimsImageID *result, char **error)
{
  gboolean cached = snapshot->calculated &&
                    same_calculated (snapshot, kind, values);
  engine->busy++;
  GimpImage *copy = gimp_image_duplicate (cached ? snapshot->calculated : snapshot->frozen);
  engine->busy--;
  if (!copy) return glims_fail (error, NULL, "The ink preview could not be rendered.");
  GlimsImageID copy_id = 0;
  GlimsStatus status = glims_adopt_image (engine, copy, &copy_id);
  if (status != GLIMS_STATUS_OK) { g_object_unref (copy); return status; }
  GlimsPlateStorage storage;
  GlimsOpenImage *copy_open = glims_lookup_image (engine, copy_id);
  if (!glims_plate_storage_read_open (copy_open, &storage) ||
      snapshot->target_index >= storage.map.count ||
      memcmp (storage.map.entries[snapshot->target_index].uuid, snapshot->target_uuid, 16))
    status = GLIMS_STATUS_UNSUPPORTED;
  else if (!cached)
    {
      GlimsItemID target = gimp_item_get_id (GIMP_ITEM (storage.planes[snapshot->target_index]));
      status = apply_ink (engine, copy_id, target, title, FALSE,
                          calculate, values, NULL, error);
    }
  if (status != GLIMS_STATUS_OK) glims_release_image (engine, copy_id);
  else
    {
      if (!cached)
        {
          engine->busy++;
          GimpImage *calculated = gimp_image_duplicate (copy);
          engine->busy--;
          /* A cache allocation failure does not invalidate the owned result. */
          if (calculated)
            {
              g_clear_object (&snapshot->calculated);
              snapshot->calculated = calculated;
              store_calculated (snapshot, kind, values);
            }
        }
      *result = copy_id;
    }
  return status;
}

GlimsStatus
glims_image_ink_snapshot_levels (GlimsEngine *engine, GlimsImageID id,
                                 uint64_t token, const GlimsInkLevelsSettings *settings,
                                 GlimsImageID *result, char **error)
{
  if (error) *error = NULL;
  if (result) *result = 0;
  GlimsComponentLevels values;
  if (!result || !read_levels (settings, &values)) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsInkSnapshot *snapshot = find_snapshot (open, token);
  if (!snapshot) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;
  return ink_snapshot_render (engine, snapshot, "Preview Levels",
                              levels_row, &values, INK_SNAPSHOT_CALC_LEVELS,
                              result, error);
}

GlimsStatus
glims_image_ink_snapshot_curves (GlimsEngine *engine, GlimsImageID id,
                                 uint64_t token, const GlimsInkCurvesSettings *settings,
                                 GlimsImageID *result, char **error)
{
  if (error) *error = NULL;
  if (result) *result = 0;
  GlimsComponentCurve values;
  if (!result || !read_curves (settings, &values)) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsInkSnapshot *snapshot = find_snapshot (open, token);
  if (!snapshot) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;
  return ink_snapshot_render (engine, snapshot, "Preview Curves",
                              curves_row, &values, INK_SNAPSHOT_CALC_CURVES,
                              result, error);
}

/* Success (including a no-op) consumes the token; errors retain it. */
static GlimsStatus
ink_snapshot_apply (GlimsEngine *engine, GlimsImageID id, uint64_t token,
                    const char *title, InkRow calculate, const void *values,
                    char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsInkSnapshot *snapshot = find_snapshot (open, token);
  if (!snapshot) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = apply_ink (engine, id, snapshot->target, title, FALSE,
                                  calculate, values, snapshot, error);
  if (status == GLIMS_STATUS_OK)
    {
      open->ink_snapshot = NULL;
      glims_ink_snapshot_free (snapshot);
    }
  return status;
}

GlimsStatus
glims_image_ink_snapshot_apply (GlimsEngine *engine, GlimsImageID id,
                                uint64_t token, const GlimsInkLevelsSettings *settings,
                                char **error)
{
  if (error) *error = NULL;
  GlimsComponentLevels values;
  if (!read_levels (settings, &values)) return GLIMS_STATUS_INVALID_ARGUMENT;
  return ink_snapshot_apply (engine, id, token, "Levels Ink",
                             levels_row, &values, error);
}

GlimsStatus
glims_image_ink_snapshot_apply_curves (GlimsEngine *engine, GlimsImageID id,
                                       uint64_t token, const GlimsInkCurvesSettings *settings,
                                       char **error)
{
  if (error) *error = NULL;
  GlimsComponentCurve values;
  if (!read_curves (settings, &values)) return GLIMS_STATUS_INVALID_ARGUMENT;
  return ink_snapshot_apply (engine, id, token, "Curves Ink",
                             curves_row, &values, error);
}

GlimsStatus
glims_image_ink_snapshot_end (GlimsEngine *engine, GlimsImageID id, uint64_t token)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsInkSnapshot *snapshot = find_snapshot (open, token);
  if (!snapshot) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy) return GLIMS_STATUS_BUSY;
  open->ink_snapshot = NULL;
  glims_ink_snapshot_free (snapshot);
  return GLIMS_STATUS_OK;
}

/* ---- Immutable Lab Curves previews (component snapshot, not ink) ---- */

/* Both modes share frozen-state ownership and the staged transaction. The
 * public Lab target and physical curve calculation remain distinct. */
typedef struct _GlimsLabSnapshot {
  GlimsInkSnapshot base;
} GlimsLabSnapshot;

void
glims_lab_snapshot_free (GlimsLabSnapshot *snapshot)
{
  if (!snapshot) return;
  g_clear_object (&snapshot->base.frozen);
  g_clear_object (&snapshot->base.calculated);
  g_free (snapshot);
}

static GlimsLabSnapshot *
find_lab_snapshot (GlimsOpenImage *open, uint64_t token)
{
  return open && token && open->lab_snapshot && open->lab_snapshot->base.token == token
           ? open->lab_snapshot : NULL;
}

static gboolean
lab_snapshot_target_matches (const GlimsPlateStorage *storage, GlimsItemID axis,
                            guint index, GlimsLabAxisRole role, const guint8 uuid[16])
{
  return storage->map.mode == GLIMS_PLATE_MODE_LAB && storage->map.count == 3 &&
         index < 3 && (guint) role == index && axis > 0 &&
         gimp_item_get_id (GIMP_ITEM (storage->planes[index])) == axis &&
         !memcmp (storage->map.entries[index].uuid, uuid, 16);
}

static gboolean
selected_lab_axis (GlimsOpenImage *open, GlimsItemID id, const GlimsPlateStorage *storage,
                   guint *index)
{
  GList *selected = gimp_image_get_selected_channels (open->image);
  if (!id || !selected || selected->next) return FALSE;
  for (guint i = 0; i < storage->map.count; i++)
    if (selected->data == storage->planes[i] &&
        gimp_item_get_id (GIMP_ITEM (storage->planes[i])) == id)
      {
        if (index) *index = i;
        return TRUE;
      }
  return FALSE;
}

static gboolean
lab_snapshot_metadata_matches (GlimsOpenImage *open, const GlimsLabSnapshot *snapshot,
                               GlimsPlateStorage *current, GlimsPlateStorage *frozen)
{
  return snapshot_metadata_matches (open, &snapshot->base, current, frozen) &&
         current->map.mode == GLIMS_PLATE_MODE_LAB && current->map.count == 3;
}

static gboolean
lab_settings_valid (const GlimsLabCurvesSettings *settings)
{
  if (!settings || settings->struct_size < sizeof *settings || settings->axis <= 0 ||
      settings->role > GLIMS_LAB_AXIS_B)
    return FALSE;
  for (guint i = 0; i < G_N_ELEMENTS (settings->samples); i++)
    if (!isfinite (settings->samples[i]) || settings->samples[i] < 0 || settings->samples[i] > 1)
      return FALSE;
  return TRUE;
}

static gboolean
lab_settings_match_snapshot (const GlimsLabSnapshot *snapshot,
                             const GlimsLabCurvesSettings *settings)
{
  return snapshot && settings && settings->axis == snapshot->base.target &&
         settings->role == (uint32_t) snapshot->base.target_index &&
         !memcmp (settings->uuid, snapshot->base.target_uuid, sizeof snapshot->base.target_uuid);
}

static gboolean
same_lab_curve_cache (const GlimsLabSnapshot *snapshot,
                      const GlimsLabCurvesSettings *settings)
{
  return snapshot->base.calculated &&
         snapshot->base.calculated_kind == INK_SNAPSHOT_CALC_LAB_CURVES &&
         !memcmp (settings->samples, snapshot->base.calculated_curve.samples,
                  sizeof settings->samples);
}

static GlimsStatus
lab_snapshot_render (GlimsEngine *engine, GlimsLabSnapshot *snapshot,
                     const GlimsLabCurvesSettings *settings,
                     GlimsImageID *result, char **error)
{
  gboolean cached = snapshot->base.calculated && same_lab_curve_cache (snapshot, settings);
  engine->busy++;
  GimpImage *copy = gimp_image_duplicate (cached ? snapshot->base.calculated : snapshot->base.frozen);
  engine->busy--;
  if (!copy) return glims_fail (error, NULL, "The adjustment preview could not be rendered.");
  GlimsImageID copy_id = 0;
  GlimsStatus status = glims_adopt_image (engine, copy, &copy_id);
  if (status != GLIMS_STATUS_OK) { g_object_unref (copy); return status; }
  GlimsPlateStorage storage;
  GlimsOpenImage *copy_open = glims_lookup_image (engine, copy_id);
  if (!copy_open || !glims_plate_storage_read_open (copy_open, &storage) ||
      storage.map.mode != GLIMS_PLATE_MODE_LAB || storage.map.count != 3 ||
      snapshot->base.target_index >= storage.map.count ||
      memcmp (storage.map.entries[snapshot->base.target_index].uuid, snapshot->base.target_uuid, 16))
    status = GLIMS_STATUS_UNSUPPORTED;
  else if (!cached)
    {
      GlimsLabCurvesSettings render = *settings;
      GlimsItemID target = gimp_item_get_id (GIMP_ITEM (storage.planes[snapshot->base.target_index]));
      /* Remap to the private copy's handle only after UUID+role verification. */
      render.axis = target;
      status = glims_image_curves_lab (engine, copy_id, &render, error);
    }
  if (status != GLIMS_STATUS_OK) glims_release_image (engine, copy_id);
  else
    {
      if (!cached)
        {
          engine->busy++;
          GimpImage *calculated = gimp_image_duplicate (copy);
          engine->busy--;
          if (calculated)
            {
              g_clear_object (&snapshot->base.calculated);
              snapshot->base.calculated = calculated;
              snapshot->base.calculated_kind = INK_SNAPSHOT_CALC_LAB_CURVES;
              memcpy (snapshot->base.calculated_curve.samples, settings->samples,
                        sizeof settings->samples);
            }
        }
      *result = copy_id;
    }
  return status;
}

static GlimsStatus
lab_snapshot_apply_component (GlimsEngine *engine, GlimsImageID id,
                              const GlimsLabSnapshot *snapshot,
                              const GlimsLabCurvesSettings *settings,
                              char **error)
{
  GlimsLabFillSettings identity = { .struct_size = sizeof identity,
    .axis = settings->axis, .role = settings->role, .opacity = 1 };
  memcpy (identity.uuid, settings->uuid, sizeof identity.uuid);
  return apply_component (engine, id, settings->axis, "Curves Lab", FALSE,
                           lab_curves_row, settings, &snapshot->base, &identity, error);
}

GlimsStatus
glims_image_lab_snapshot_begin (GlimsEngine *engine, GlimsImageID id,
                                const GlimsLabSnapshotTarget *target,
                                uint64_t *token, char **error)
{
  if (error) *error = NULL;
  if (token) *token = 0;
  if (!target || !token || target->struct_size < sizeof *target || target->axis <= 0 ||
      target->role > GLIMS_LAB_AXIS_B)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (open->ink_snapshot || open->lab_snapshot || g_hash_table_size (engine->filters))
    return GLIMS_STATUS_BUSY;
  if (engine->next_ink_snapshot_token == G_MAXUINT64)
    return GLIMS_STATUS_FAILED;
  GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open (open, &storage) || storage.map.mode != GLIMS_PLATE_MODE_LAB)
    return GLIMS_STATUS_UNSUPPORTED;
  guint index = 0;
  if (!selected_lab_axis (open, target->axis, &storage, &index) ||
      !lab_snapshot_target_matches (&storage, target->axis, index,
                                    (GlimsLabAxisRole) target->role, target->uuid))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  status = glims_check_item_locks (GIMP_ITEM (storage.planes[index]), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;
  engine->busy++;
  GimpImage *frozen = gimp_image_duplicate (open->image);
  engine->busy--;
  if (!frozen) return glims_fail (error, NULL, "The adjustment preview could not be prepared.");
  GlimsLabSnapshot *snapshot = g_new0 (GlimsLabSnapshot, 1);
  snapshot->base.frozen = frozen;
  snapshot->base.target = target->axis;
  snapshot->base.target_index = index;
  memcpy (snapshot->base.target_uuid, target->uuid, sizeof snapshot->base.target_uuid);
  GlimsPlateStorage a, b;
  if (!lab_snapshot_metadata_matches (open, snapshot, &a, &b))
    {
      glims_lab_snapshot_free (snapshot);
      return glims_fail (error, NULL, "The adjustment preview could not preserve the source document.");
    }
  snapshot->base.token = ++engine->next_ink_snapshot_token;
  open->lab_snapshot = snapshot;
  *token = snapshot->base.token;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_lab_snapshot_curves (GlimsEngine *engine, GlimsImageID id, uint64_t token,
                                 const GlimsLabCurvesSettings *settings,
                                 GlimsImageID *result, char **error)
{
  if (error) *error = NULL;
  if (result) *result = 0;
  if (!result || !lab_settings_valid (settings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsLabSnapshot *snapshot = find_lab_snapshot (open, token);
  if (!snapshot) return GLIMS_STATUS_NOT_FOUND;
  if (!lab_settings_match_snapshot (snapshot, settings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;
  return lab_snapshot_render (engine, snapshot, settings, result, error);
}

GlimsStatus
glims_image_lab_snapshot_apply_curves (GlimsEngine *engine, GlimsImageID id, uint64_t token,
                                       const GlimsLabCurvesSettings *settings, char **error)
{
  if (error) *error = NULL;
  if (!lab_settings_valid (settings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsLabSnapshot *snapshot = find_lab_snapshot (open, token);
  if (!snapshot) return GLIMS_STATUS_NOT_FOUND;
  if (!lab_settings_match_snapshot (snapshot, settings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsStatus status = lab_snapshot_apply_component (engine, id, snapshot, settings, error);
  if (status == GLIMS_STATUS_OK)
    {
      open->lab_snapshot = NULL;
      glims_lab_snapshot_free (snapshot);
    }
  return status;
}

GlimsStatus
glims_image_lab_snapshot_end (GlimsEngine *engine, GlimsImageID id, uint64_t token)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsLabSnapshot *snapshot = find_lab_snapshot (open, token);
  if (!snapshot) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy) return GLIMS_STATUS_BUSY;
  open->lab_snapshot = NULL;
  glims_lab_snapshot_free (snapshot);
  return GLIMS_STATUS_OK;
}

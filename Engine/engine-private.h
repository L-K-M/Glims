/*
 * Internal declarations of the Glims engine adapter. This is the only code in
 * Glims that includes GIMP's app/ headers (AGENTS.md, "The adapter is the
 * seam"). Everything here runs on the engine thread unless noted.
 */
#ifndef GLIMS_ENGINE_PRIVATE_H
#define GLIMS_ENGINE_PRIVATE_H

#include "config.h"

#include <gio/gio.h>
#include <gegl.h>
#include <gdk-pixbuf/gdk-pixbuf.h>

#include "libgimpbase/gimpbase.h"
#include "libgimpconfig/gimpconfig.h"

#include "core/core-types.h"

#include "glims_engine.h"

/* progress.c: the engine's progress and parent-window provider for
 * plug-ins (implements GimpProgress). */
#define GLIMS_TYPE_PROGRESS (glims_progress_get_type ())
G_DECLARE_FINAL_TYPE (GlimsProgress, glims_progress, GLIMS, PROGRESS, GObject)

struct GlimsEngine
{
  /* Set before the engine thread starts; read-only afterwards. */
  GThread            *thread;
  GlimsEventCallback  on_event;
  void               *event_context;
  gchar              *user_directory;
  gchar              *cache_directory;

  /* Start-up handshake, guarded by `lock`. */
  GMutex              lock;
  GCond               cond;
  gboolean            started;
  gchar              *start_error;

  /* Engine-thread state. */
  GMainLoop          *loop;
  Gimp               *gimp;
  GApplication       *app;
  GHashTable         *images;    /* image id -> GlimsOpenImage* */
  GHashTable         *strokes;   /* stroke id -> GlimsStroke* */
  GHashTable         *filters;   /* filter id -> GlimsFilter* */
  gint                next_session_id;
  gint                busy;      /* > 0 while a plug-in call runs */
  GlimsProgress      *progress;  /* the running procedure's, or NULL */
  GFile              *icon_theme_dir;
};

/* An image the app holds open. */
typedef struct
{
  GimpImage *image;
  GlimsEngine *engine;
  gulong     projection_update_handler;
  gulong     undo_event_handler;
  gulong     layers_changed_handler;
  gulong     mask_changed_handler;
  gulong     size_changed_handler;
  gulong     channels_changed_handler;
  gulong     component_active_handler;
  gulong     component_visible_handler;
  gulong     quick_mask_changed_handler;
  guint64    history_revision;
} GlimsOpenImage;

/* A live filter session, owned by `filters` until commit or abort.
 * filter-properties.c reads its members too. `non_destructive` is how
 * commit leaves the drawable — the filter on its stack, or merged into
 * its pixels. An edit session (`filter_edit_begin`) additionally parks
 * the committed `existing` effect while its shadow `filter` previews:
 * commit writes the shadow's parameters into `existing`, and either
 * path restores `existing_active` — NULL for a new filter. */
typedef struct
{
  GimpImage          *image;
  GimpDrawable       *drawable;
  GeglNode           *operation;
  GimpDrawableFilter *filter;
  gboolean            non_destructive;
  GimpDrawableFilter *existing;
  gboolean            existing_active;
} GlimsFilter;

typedef GlimsStatus (*GlimsEngineFunc) (GlimsEngine *engine, gpointer data);

/* Runs `func` on the engine thread and waits for it. Safe from any thread. */
GlimsStatus      glims_engine_call       (GlimsEngine *engine, GlimsEngineFunc func, gpointer data);

void             glims_emit              (GlimsEngine *engine, GlimsEventKind kind,
                                          GimpImage *image, const GeglRectangle *rect,
                                          const gchar *text);
void             glims_emit_progress     (GlimsEngine *engine, gboolean active,
                                          gdouble value, const gchar *text);
GlimsStatus      glims_fail              (char **error, GError *gerror, const gchar *fallback);
GlimsOpenImage * glims_lookup_image      (GlimsEngine *engine, GlimsImageID id);
GlimsStatus      glims_adopt_image       (GlimsEngine *engine, GimpImage *image, GlimsImageID *id);
void             glims_release_image     (GlimsEngine *engine, GlimsImageID id);
GimpDrawable   * glims_lookup_drawable   (GlimsOpenImage *open, GlimsItemID id);
GlimsStatus      glims_check_item_locks  (GimpItem *item, uint32_t locks, char **error);
gint             glims_next_session_id   (GlimsEngine *engine);
GlimsStatus      glims_edit_ready        (GlimsEngine *engine, GlimsOpenImage *open, char **error);

/* image.c */
GlimsStatus glims_image_new        (GlimsEngine *e, int32_t w, int32_t h, GlimsImageID *out, char **error);
GlimsStatus glims_image_open       (GlimsEngine *e, const char *path, GlimsImageID *out, char **error);
GlimsStatus glims_image_close      (GlimsEngine *e, GlimsImageID id);
GlimsStatus glims_image_info       (GlimsEngine *e, GlimsImageID id, GlimsImageInfo *info);
GlimsStatus glims_image_render     (GlimsEngine *e, GlimsImageID id, double scale, GlimsRect area,
                                    uint8_t *pixels, size_t stride);
GlimsStatus glims_image_save       (GlimsEngine *e, GlimsImageID id, const char *path, char **error);
GlimsStatus glims_image_save_copy  (GlimsEngine *e, GlimsImageID id, const char *path, char **error);
GlimsStatus glims_image_export     (GlimsEngine *e, GlimsImageID id, const char *path, char **error);
GlimsStatus glims_image_layers     (GlimsEngine *e, GlimsImageID id, GlimsLayerInfo *layers,
                                    int32_t capacity, int32_t *count);
GlimsStatus glims_image_undo_info  (GlimsEngine *e, GlimsImageID id, GlimsUndoInfo *info);
GlimsStatus glims_image_undo       (GlimsEngine *e, GlimsImageID id);
GlimsStatus glims_image_redo       (GlimsEngine *e, GlimsImageID id);

/* paint.c */
GlimsStatus glims_stroke_begin     (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                    const GlimsBrushSettings *brush, const GlimsStrokePoint *first,
                                    GlimsStrokeID *out, char **error);
GlimsStatus glims_stroke_continue  (GlimsEngine *e, GlimsStrokeID id,
                                    const GlimsStrokePoint *points, size_t count);
GlimsStatus glims_stroke_end       (GlimsEngine *e, GlimsStrokeID id);
void        glims_strokes_free     (gpointer stroke);

/* filter.c */
gboolean glims_filters_active_for_image (GlimsEngine *, GimpImage *);
void glims_filters_abort_for_image (GlimsEngine *, GimpImage *);
GlimsStatus glims_filter_check_edit (GlimsEngine *, GlimsFilterID, char **error);
GlimsStatus glims_filter_begin     (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                                    const char *operation, GlimsFilterID *out, char **error);
GlimsStatus glims_filter_edit_begin(GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                                    GlimsEffectID effect, GlimsFilterID *out, char **error);
void        glims_filter_preview_apply (GlimsFilter *session);
GlimsStatus glims_filter_set_double(GlimsEngine *e, GlimsFilterID id, const char *property, double value);
GlimsStatus glims_filter_commit    (GlimsEngine *e, GlimsFilterID id, char **error);
GlimsStatus glims_filter_abort     (GlimsEngine *e, GlimsFilterID id);
void        glims_filters_free     (gpointer filter);

/* effects.c */
GimpDrawableFilter * glims_lookup_effect (GlimsEngine *engine, GimpDrawable *drawable,
                                          GlimsEffectID effect_id);
GlimsStatus glims_drawable_effects (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                                    GlimsEffectInfo *rows, int32_t capacity, int32_t *count);
GlimsStatus glims_effect_change    (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                                    GlimsEffectID effect, const GlimsEffectChange *change,
                                    char **error);
GlimsStatus glims_effect_command   (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                                    GlimsEffectID effect, uint32_t command, char **error);

/* place.c */
GlimsStatus glims_image_open_layers (GlimsEngine *e, GlimsImageID image, const char *path,
                                     GlimsItemID *layers, int32_t capacity, int32_t *count,
                                     char **error);
GlimsStatus glims_image_place_link  (GlimsEngine *e, GlimsImageID image, const char *path,
                                     GlimsItemID *layer, char **error);

/* filter-properties.c */
gboolean glims_filter_operation_allowed (const gchar *operation);
GlimsStatus glims_filter_operations (GlimsEngine *e, GlimsOperationInfo *rows,
                                     int32_t capacity, int32_t *count);
GlimsStatus glims_filter_operation_properties (GlimsEngine *e, const char *operation,
                                               GlimsFilterProperty *rows, int32_t capacity,
                                               int32_t *count);
GlimsStatus glims_filter_enum_choices (GlimsEngine *e, const char *operation,
                                       const char *property, GlimsFilterEnumChoice *rows,
                                       int32_t capacity, int32_t *count);
GlimsStatus glims_filter_get_property (GlimsEngine *e, GlimsFilterID id,
                                       const char *property, GlimsFilterValue *value);
GlimsStatus glims_filter_set_property (GlimsEngine *e, GlimsFilterID id,
                                       const char *property, const GlimsFilterValue *value);

/* history.c */
GlimsStatus glims_image_history (GlimsEngine *, GlimsImageID, GlimsHistoryRow *,
                                 int32_t, GlimsHistoryInfo *);
GlimsStatus glims_image_history_move (GlimsEngine *, GlimsImageID, uint64_t,
                                      int32_t, char **);
GlimsStatus glims_image_duplicate (GlimsEngine *, GlimsImageID, GlimsImageID *, char **);

/* layer-mask.c */
GlimsStatus glims_layer_mask      (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                   GlimsMaskState *state);
GlimsStatus glims_layer_mask_add  (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                   uint32_t source, gboolean edit, GlimsItemID *mask, char **error);
GlimsStatus glims_layer_mask_set  (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                   uint32_t flags, uint32_t values, char **error);
GlimsStatus glims_layer_mask_apply(GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                   uint32_t mode, char **error);
GlimsStatus glims_layer_mask_to_selection (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                           uint32_t operation, char **error);
GlimsStatus glims_drawable_thumbnail (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                                      int32_t max_size, uint8_t *pixels, size_t byte_count,
                                      int32_t *width, int32_t *height);

/* channels.c */
GlimsStatus glims_image_components (GlimsEngine *e, GlimsImageID image,
                                    GlimsComponentState *state);
GlimsStatus glims_image_set_components (GlimsEngine *e, GlimsImageID image,
                                        uint32_t active_mask, uint32_t active_values,
                                        uint32_t visible_mask, uint32_t visible_values,
                                        char **error);
GlimsStatus glims_image_channels (GlimsEngine *e, GlimsImageID image,
                                  GlimsChannelInfo *rows, int32_t capacity, int32_t *count);
GlimsStatus glims_channel_from_selection (GlimsEngine *e, GlimsImageID image,
                                          const char *name, GlimsItemID *result, char **error);
GlimsStatus glims_channel_change (GlimsEngine *e, GlimsImageID image, GlimsItemID channel,
                                  const GlimsChannelChange *change, char **error);
GlimsStatus glims_channel_command (GlimsEngine *e, GlimsImageID image, GlimsItemID channel,
                                   uint32_t command, GlimsItemID *result, char **error);
GlimsStatus glims_channel_to_selection (GlimsEngine *e, GlimsImageID image, GlimsItemID channel,
                                        uint32_t operation, char **error);
GlimsStatus glims_image_quick_mask (GlimsEngine *e, GlimsImageID image,
                                    GlimsQuickMaskState *state);
GlimsStatus glims_image_set_quick_mask (GlimsEngine *e, GlimsImageID image,
                                        gboolean enabled, char **error);

/* progress.c */
GlimsProgress * glims_progress_new (GlimsEngine *engine);

/* select.c */
GlimsStatus glims_select_shape     (GlimsEngine *e, GlimsImageID image, uint32_t shape,
                                    const GlimsPoint *points, size_t count,
                                    const GlimsSelectOptions *options);
GlimsStatus glims_select_color     (GlimsEngine *e, GlimsImageID image, GlimsPoint point,
                                    const GlimsSelectOptions *options, char **error);
GlimsStatus glims_select_command   (GlimsEngine *e, GlimsImageID image, uint32_t command,
                                    double radius, char **error);
GlimsStatus glims_selection_bounds (GlimsEngine *e, GlimsImageID image, bool *empty, GlimsRect *bounds);
GlimsStatus glims_selection_outline(GlimsEngine *e, GlimsImageID image, GlimsSegment *segments,
                                    int32_t capacity, int32_t *count);
GimpChannelOps glims_channel_op   (uint32_t operation);  /* a GlimsSelectOperation */

/* path.c */
GlimsStatus glims_paths            (GlimsEngine *e, GlimsImageID image, GlimsPathInfo *rows,
                                    int32_t capacity, int32_t *count);
GlimsStatus glims_path_get         (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                                    GlimsSubpath *subpaths, int32_t subpath_capacity,
                                    int32_t *subpath_count, GlimsPathPoint *points,
                                    int32_t point_capacity, int32_t *point_count);
GlimsStatus glims_path_set         (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                                    const char *name, const GlimsSubpath *subpaths,
                                    int32_t subpath_count, const GlimsPathPoint *points,
                                    int32_t point_count, GlimsItemID *result, char **error);
GlimsStatus glims_path_change      (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                                    const GlimsPathChange *change, char **error);
GlimsStatus glims_path_delete      (GlimsEngine *e, GlimsImageID image, GlimsItemID path);
GlimsStatus glims_path_to_selection(GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                                    const GlimsSelectOptions *options);
GlimsStatus glims_path_stroke      (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                                    GlimsItemID layer, const GlimsLineSettings *settings,
                                    char **error);
GlimsStatus glims_path_fill        (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                                    GlimsItemID drawable, const GlimsPathFillSettings *settings,
                                    char **error);
GlimsStatus glims_path_to_vector_layer (GlimsEngine *e, GlimsImageID image, GlimsItemID path,
                                        const char *name, GlimsItemID *layer, char **error);

/* edit.c */
GlimsStatus glims_fill             (GlimsEngine *e, GlimsImageID image, GlimsPoint point,
                                    const GlimsFillSettings *settings, char **error);
GlimsStatus glims_gradient         (GlimsEngine *e, GlimsImageID image, GlimsPoint from, GlimsPoint to,
                                    const GlimsGradientSettings *settings, char **error);
GlimsStatus glims_layer_select     (GlimsEngine *e, GlimsImageID image, GlimsItemID layer);
GlimsStatus glims_layer_command    (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                    uint32_t command, GlimsItemID *result, char **error);
GlimsStatus glims_layer_change     (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                    const GlimsLayerChange *change, char **error);
GlimsStatus glims_layer_move       (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                    double dx, double dy);
GlimsStatus glims_image_crop       (GlimsEngine *e, GlimsImageID image, GlimsRect rect, char **error);
GlimsStatus glims_image_transform  (GlimsEngine *e, GlimsImageID image, uint32_t transform);
GlimsStatus glims_layer_transform  (GlimsEngine *e, GlimsImageID image, GlimsItemID layer, uint32_t transform);
GlimsStatus glims_fonts          (GlimsEngine *e, char **names);
GlimsStatus glims_text_layer_new (GlimsEngine *e, GlimsImageID image, const char *text,
                                  const GlimsTextSettings *settings, GlimsPoint position,
                                  GlimsItemID *layer, char **error);
GlimsStatus glims_text_layer_get (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                  char **text, GlimsTextSettings *settings);
GlimsStatus glims_text_layer_set (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                  const char *text, const GlimsTextSettings *settings,
                                  char **error);
GlimsStatus glims_layer_transform_matrix (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                          const GlimsMatrix *matrix, uint32_t interpolation,
                                          char **error);
GlimsStatus glims_image_scale      (GlimsEngine *e, GlimsImageID image, int32_t width, int32_t height,
                                    char **error);
GlimsStatus glims_image_resize_canvas (GlimsEngine *e, GlimsImageID image, int32_t width, int32_t height,
                                       int32_t offset_x, int32_t offset_y, const GlimsColor *fill,
                                       char **error);

/* clipboard.c */
GlimsStatus glims_image_copy_pixels (GlimsEngine *, GlimsImageID, gboolean, GlimsPixelBuffer *, char **);
GlimsStatus glims_image_clear (GlimsEngine *, GlimsImageID, const GlimsColor *, char **);
GlimsStatus glims_image_paste_pixels (GlimsEngine *, GlimsImageID, GlimsRect, const uint8_t *, size_t, GlimsItemID *, char **);
GlimsStatus glims_image_from_pixels (GlimsEngine *, int32_t, int32_t, const uint8_t *, size_t, GlimsImageID *, char **);
/* layer-structure.c */
GlimsStatus glims_layer_state      (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                    GlimsLayerState *state);
GlimsStatus glims_create_group     (GlimsEngine *e, GlimsImageID image, GlimsItemID parent,
                                    int32_t index, const char *name, GlimsItemID *result,
                                    char **error);
GlimsStatus glims_reparent_layer   (GlimsEngine *e, GlimsImageID image, GlimsItemID item,
                                    GlimsItemID new_parent, int32_t index, char **error);
GlimsStatus glims_set_layer_locks  (GlimsEngine *e, GlimsImageID image, GlimsItemID item,
                                    uint32_t mask, uint32_t values, char **error);

/* procedure.c */
GlimsStatus glims_procedures       (GlimsEngine *e, GlimsImageID image, GlimsProcedureInfo *rows,
                                    int32_t capacity, int32_t *count);
GlimsStatus glims_procedure_run    (GlimsEngine *e, GlimsImageID image, const char *name,
                                    uint32_t run_mode, char **error);
GlimsStatus glims_procedure_cancel (GlimsEngine *e);

/* color.c */
GlimsStatus glims_image_color_info        (GlimsEngine *e, GlimsImageID image,
                                           GlimsColorInfo *info);
GlimsStatus glims_image_convert_mode      (GlimsEngine *e, GlimsImageID image,
                                           uint32_t mode, char **error);
GlimsStatus glims_image_convert_precision (GlimsEngine *e, GlimsImageID image,
                                           uint32_t component, uint32_t trc, char **error);

#endif /* GLIMS_ENGINE_PRIVATE_H */

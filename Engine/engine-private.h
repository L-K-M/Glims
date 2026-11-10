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

  /* Per-engine monotonic source of saved-set identity tokens (facade
   * slots 133/134): incremented for every adopted fixed set, never
   * reused, never reset. 0 is never issued. At UINT64_MAX the allocation
   * fails closed (no identity is handed out, none is reused). */
  guint64             next_item_set_token;
};

typedef struct GlimsItemSets GlimsItemSets;
/* The manager allocates each fixed set's facade identity token from the
 * engine's monotonic counter, so it needs the engine it belongs to. */
GlimsItemSets * glims_item_sets_new  (GlimsEngine *engine, GimpImage *image);
void            glims_item_sets_free (GlimsItemSets *manager);
GlimsItemSets * glims_item_sets_lookup (GimpImage *image); /* borrowed */
GPtrArray *     glims_item_sets_copy_members (GlimsItemSets *manager, GimpItemList *native);
void            glims_item_sets_restore_members (GlimsItemSets *manager, GimpItemList *native,
                                                 const GPtrArray *members);
void            glims_item_sets_refresh (GlimsItemSets *manager);
/* READ-ONLY manager queries behind facade slots 133/134. Both are plain
 * reads: no busy gate, no mutation, no dirty/history/selection change,
 * no strong retention beyond the call. `rows`/`out` may be NULL with
 * capacity 0 (count-only). List: every fixed (non-pattern) set, kinds in
 * GlimsItemSetKind order, stored-list order within a kind; each row gets
 * the set's stable token, facade kind, live attached member count and
 * display-truncated name. Members: the current attached item ids of the
 * one set `token` names in this manager — token 0 or a token this image
 * does not own (foreign image, foreign engine, stale or expired) is
 * NOT_FOUND, never retargeted. */
GlimsStatus     glims_item_sets_list (GlimsItemSets *manager, GlimsItemSetInfo *rows,
                                      int32_t capacity, int32_t *count);
GlimsStatus     glims_item_sets_members_of (GlimsItemSets *manager, uint64_t token,
                                            GlimsItemID *out, int32_t capacity, int32_t *count);
/* item-sets-read.c: facade slots 133/134 (image_item_sets,
 * image_item_set_members). */
GlimsStatus     glims_image_item_sets (GlimsEngine *e, GlimsImageID image,
                                       GlimsItemSetInfo *rows, int32_t capacity, int32_t *count);
GlimsStatus     glims_image_item_set_members (GlimsEngine *e, GlimsImageID image, uint64_t token,
                                              GlimsItemID *members, int32_t capacity, int32_t *count);

/* item-sets-undo.c: atomic native undo steps for explicit saved-set edits.
 * Engine-internal commands (no facade slot); run on the engine thread.
 * Each mutating command pushes exactly one GimpUndo with owned before/after
 * snapshots; no-op and refused (frozen/error) calls change nothing. */
GlimsStatus glims_item_sets_create  (GimpImage *image, GType kind, const char *name,
                                     GimpItem *const *members, size_t member_count, char **error);
GlimsStatus glims_item_sets_replace (GimpImage *image, GType kind, const char *name,
                                     GimpItem *const *members, size_t member_count, char **error);
GlimsStatus glims_item_sets_rename  (GimpImage *image, GType kind, const char *name,
                                     const char *new_name, char **error);
GlimsStatus glims_item_sets_remove  (GimpImage *image, GType kind, const char *name, char **error);

/* item-sets.c, EDIT-facade (slot 135) support: token-exhaustion preflight
 * (TRUE at UINT64_MAX; token-minting edits fail closed before any
 * mutation), token resolution within one image AND kind (borrowed native
 * set; NULL for foreign/stale/expired/wrong-kind), token of a native set. */
gboolean        glims_item_sets_token_exhausted (GlimsItemSets *manager);
GimpItemList *  glims_item_sets_resolve (GlimsItemSets *manager, uint64_t token, GType kind);
uint64_t        glims_item_sets_token_of (GlimsItemSets *manager, GimpItemList *native);

/* item-sets-edit.c: facade slot 135 (image_item_set_edit), one undoable
 * CREATE/REPLACE/RENAME/REMOVE of one fixed saved set by its current
 * token. Engine thread; all validation and the edit-readiness gate happen
 * before any mutation. outToken: zeroed at entry and on failure, the
 * resulting set's token on CREATE/REPLACE/RENAME success (fresh after a
 * mutation, current after a no-op), 0 on REMOVE. */
GlimsStatus     glims_image_item_set_edit (GlimsEngine *e, GlimsImageID image,
                                           uint32_t operation, uint32_t kind,
                                           uint64_t token, const char *name,
                                           const GlimsItemID *members, int32_t count,
                                           uint64_t *outToken, char **error);

/* An image the app holds open. */
typedef struct
{
  GimpImage *image;
  GlimsEngine *engine;
  GlimsItemSets *item_sets;
  gulong     projection_update_handler;
  gulong     undo_event_handler;
  gulong     layers_changed_handler;
  gulong     mask_changed_handler;
  gulong     size_changed_handler;
  gulong     channels_changed_handler;
  gulong     component_active_handler;
  gulong     component_visible_handler;
  gulong     quick_mask_changed_handler;
  gulong     guide_added_handler;
  gulong     guide_removed_handler;
  gulong     guide_moved_handler;
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
  GeglNode           *aux_source; /* owned detached snapshot node, new sessions only */
} GlimsFilter;

typedef GlimsStatus (*GlimsEngineFunc) (GlimsEngine *engine, gpointer data);

/* Runs `func` on the engine thread and waits for it. Safe from any thread. */
GlimsStatus      glims_engine_call       (GlimsEngine *engine, GlimsEngineFunc func, gpointer data);

void             glims_emit              (GlimsEngine *engine, GlimsEventKind kind,
                                          GimpImage *image, const GeglRectangle *rect,
                                          const gchar *text);
void             glims_emit_progress     (GlimsEngine *engine, gboolean active,
                                          gdouble value, const gchar *text);
/* Consumes gerror. Transfer a caller-owned variable with g_steal_pointer. */
GlimsStatus      glims_fail              (char **error, GError *gerror, const gchar *fallback);
GlimsOpenImage * glims_lookup_image      (GlimsEngine *engine, GlimsImageID id);
GlimsStatus      glims_adopt_image       (GlimsEngine *engine, GimpImage *image, GlimsImageID *id);
void             glims_release_image     (GlimsEngine *engine, GlimsImageID id);
void             glims_track_image_links (GimpImage *image);
GimpDrawable   * glims_lookup_drawable   (GlimsOpenImage *open, GlimsItemID id);
GlimsStatus      glims_check_item_locks  (GimpItem *item, uint32_t locks, char **error);
gint             glims_next_session_id   (GlimsEngine *engine);
GlimsStatus      glims_edit_ready        (GlimsEngine *engine, GlimsOpenImage *open, char **error);

/* The largest pixel buffer the facade accepts, and its overflow-safe
 * width*height*4 computation (clipboard.c, floating.c). */
#define GLIMS_MAX_PIXEL_BUFFER_BYTES ((uint64_t) 512 * 1024 * 1024)
gboolean         glims_pixel_bytes       (int width, int height, size_t *bytes);

/* image.c */
GlimsStatus glims_image_new        (GlimsEngine *e, int32_t w, int32_t h, GlimsImageID *out, char **error);
GlimsStatus glims_image_open       (GlimsEngine *e, const char *path, GlimsImageID *out, char **error);
/* Scoped compatibility guard for native 3.2.0 vector loading. */
typedef struct GlimsVectorLoadGuard GlimsVectorLoadGuard;
GlimsVectorLoadGuard *glims_vector_load_guard_begin (GlimsEngine *e, GimpImage *destination);
void glims_vector_load_guard_end (GlimsVectorLoadGuard *guard);
GlimsStatus glims_image_close      (GlimsEngine *e, GlimsImageID id);
GlimsStatus glims_image_info       (GlimsEngine *e, GlimsImageID id, GlimsImageInfo *info);
GlimsStatus glims_image_render     (GlimsEngine *e, GlimsImageID id, double scale, GlimsRect area,
                                    uint8_t *pixels, size_t stride);
/* Shared lazy projection preparation for one synchronous area read,
 * used by both renderers (image.c, display-render.c): validates `scale`
 * and `area` (finite 0 < scale <= MAX_RENDER_SCALE, width/height >= 1),
 * hands pending projection work over as invalid tiles (stop the chunk
 * renderer, flush_now(FALSE)) and validates the requested area when the
 * read is scaled or goes through GEGL's 1x1 hot-tile shortcut. On
 * GLIMS_STATUS_OK, *buffer_out is the projection buffer to read from.
 * Borrowed buffer; the image keeps it alive. */
GlimsStatus glims_projection_prepare_read (GlimsOpenImage *open, double scale, GlimsRect area,
                                           GeglBuffer **buffer_out);

/* display-render.c: conservative adapter caps for slots132/164
 * (image_render_to_profile/image_render_proofed), documented in glims_engine.h and
 * docs/display-destination-render.md. The ICC cap keeps the length well
 * inside LCMS's 32-bit size domain; the temp cap bounds the per-call
 * scratch allocation (rows are processed in chunks of at most this
 * size); the output cap is the shared GLIMS_MAX_PIXEL_BUFFER_BYTES. */
#define GLIMS_MAX_ICC_PROFILE_BYTES   ((size_t) 16 * 1024 * 1024)
#define GLIMS_RENDER_TEMP_CHUNK_BYTES ((size_t) 16 * 1024 * 1024)
GlimsStatus glims_image_render_to_profile (GlimsEngine *e, GlimsImageID id, double scale, GlimsRect area,
                                           const uint8_t *destination_icc, size_t destination_icc_length,
                                           uint8_t *pixels, size_t stride, char **error);
GlimsStatus glims_image_render_proofed (GlimsEngine *e, GlimsImageID id, double scale, GlimsRect area,
                                       const uint8_t *destination_icc, size_t destination_icc_length,
                                       const uint8_t *proof_icc, size_t proof_icc_length,
                                       const GlimsProofSettings *settings,
                                       uint8_t *pixels, size_t stride, char **error);
GlimsStatus glims_image_save       (GlimsEngine *e, GlimsImageID id, const char *path, char **error);
GlimsStatus glims_image_save_copy  (GlimsEngine *e, GlimsImageID id, const char *path, char **error);
GlimsStatus glims_image_export     (GlimsEngine *e, GlimsImageID id, const char *path, char **error);
GlimsStatus glims_image_layers     (GlimsEngine *e, GlimsImageID id, GlimsLayerInfo *layers,
                                    int32_t capacity, int32_t *count);
/* The facade kind of one layer; rasterized text/link/vector instances
 * report PIXEL, their content is pixels. */
GlimsLayerKind glims_layer_kind    (GimpLayer *layer);
GlimsStatus glims_image_undo_info  (GlimsEngine *e, GlimsImageID id, GlimsUndoInfo *info);
GlimsStatus glims_image_undo       (GlimsEngine *e, GlimsImageID id);
GlimsStatus glims_image_redo       (GlimsEngine *e, GlimsImageID id);

/* paint.c */
GlimsStatus glims_stroke_begin     (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                    const GlimsBrushSettings *brush, const GlimsStrokePoint *first,
                                    GlimsStrokeID *out, char **error);
/* As glims_stroke_begin, but the stroke paints with the brush the
 * `brush` resource handle names; resolved only here, at begin. */
GlimsStatus glims_stroke_begin_with_brush_resource (GlimsEngine *e, GlimsImageID image,
                                                    GlimsItemID layer, GlimsResourceID brush,
                                                    const GlimsBrushSettings *settings,
                                                    const GlimsStrokePoint *first,
                                                    GlimsStrokeID *out, char **error);
GlimsStatus glims_stroke_continue  (GlimsEngine *e, GlimsStrokeID id,
                                    const GlimsStrokePoint *points, size_t count);
GlimsStatus glims_stroke_end       (GlimsEngine *e, GlimsStrokeID id);
void        glims_strokes_free     (gpointer stroke);

/* Shared brush-stroke setup, also used by select.c's selection_stroke.
 * GimpPaintOptions lives in paint/, outside core-types.h. */
typedef struct _GimpPaintOptions GimpPaintOptions;
/* The caller's settings with the fields its struct_size lacks at
 * defaults; FALSE for a missing/short struct or an unknown tool. */
gboolean         glims_read_brush          (const GlimsBrushSettings *brush,
                                            GlimsBrushSettings       *settings);
/* The paint info behind a GlimsPaintTool, or NULL when the engine lacks
 * the tool. */
GimpPaintInfo *  glims_paint_info_for_tool (Gimp *gimp, uint32_t tool);
/* The tool's own options with the brush pinned: `brush_resource` is the
 * stroke's own selected brush, or NULL to inherit the user context's
 * brush. Owned reference. */
GimpPaintOptions *glims_make_paint_options (Gimp                     *gimp,
                                            GimpPaintInfo            *info,
                                            const GlimsBrushSettings *brush,
                                            GimpBrush                *brush_resource);
/* The tool-specific options (rate, flow, exposure, clone source, ...). */
void             glims_set_tool_options    (GimpPaintOptions         *options,
                                            const GlimsBrushSettings *brush,
                                            GimpDrawable             *source);

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
GlimsStatus glims_filter_brightness_contrast_get (GlimsEngine *, GlimsFilterID,
                                                 GlimsBrightnessContrastSettings *, char **);
GlimsStatus glims_filter_brightness_contrast_set (GlimsEngine *, GlimsFilterID,
                                                 const GlimsBrightnessContrastSettings *, char **);
GlimsStatus glims_filter_color_balance_get (GlimsEngine *, GlimsFilterID,
                                           GlimsColorBalanceSettings *, char **);
GlimsStatus glims_filter_color_balance_set (GlimsEngine *, GlimsFilterID,
                                           const GlimsColorBalanceSettings *, char **);
GlimsStatus glims_filter_hue_saturation_get (GlimsEngine *, GlimsFilterID,
                                            GlimsHueSaturationSettings *, char **);
GlimsStatus glims_filter_hue_saturation_set (GlimsEngine *, GlimsFilterID,
                                            const GlimsHueSaturationSettings *, char **);
GlimsStatus glims_filter_levels_get (GlimsEngine *, GlimsFilterID, GlimsLevelsSettings *, char **);
GlimsStatus glims_filter_levels_set (GlimsEngine *, GlimsFilterID, const GlimsLevelsSettings *, char **);
GlimsStatus glims_filter_levels_auto (GlimsEngine *, GlimsFilterID, GlimsLevelsSettings *, char **);
GlimsStatus glims_filter_curves_get (GlimsEngine *, GlimsFilterID, GlimsCurvesSnapshot *, char **);
GlimsStatus glims_filter_curves_edit (GlimsEngine *, GlimsFilterID, const GlimsCurveEdit *, GlimsCurvesSnapshot *, char **);
GlimsStatus glims_filter_curves_set_trc (GlimsEngine *, GlimsFilterID, uint32_t, GlimsCurvesSnapshot *, char **);
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
/* Strokes the selection's boundary on `drawable` (0: the selected
 * layer) with the brush settings' paint tool; `brush` 0 inherits the
 * user context's brush, a non-zero handle is resolved strictly. */
GlimsStatus glims_selection_stroke (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                                    GlimsResourceID brush, const GlimsBrushSettings *settings,
                                    char **error);
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

/* vector-style.c */
GlimsStatus glims_vector_layer_style_get (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                          GlimsVectorStyle *style, char **error);
GlimsStatus glims_vector_layer_style_set (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                          const GlimsVectorStyleChange *change, char **error);

/* edit.c */
GlimsStatus glims_fill             (GlimsEngine *e, GlimsImageID image, GlimsPoint point,
                                    const GlimsFillSettings *settings, char **error);
GlimsStatus glims_fill_pattern     (GlimsEngine *e, GlimsImageID image, GlimsResourceID pattern,
                                    GlimsPoint seed, const GlimsPatternFillSettings *settings,
                                    char **error);
GlimsStatus glims_gradient         (GlimsEngine *e, GlimsImageID image, GlimsPoint from, GlimsPoint to,
                                    const GlimsGradientSettings *settings, char **error);
GlimsStatus glims_gradient_resource (GlimsEngine *e, GlimsImageID image, GlimsResourceID gradient,
                                    GlimsPoint from, GlimsPoint to,
                                    const GlimsResourceGradientSettings *settings, char **error);
GlimsStatus glims_layer_select     (GlimsEngine *e, GlimsImageID image, GlimsItemID layer);
/* The whole selected-layer list: an exact, ordered, transient write
 * (no undo/dirty/pixel change; refuses anything but [floating] while a
 * floating selection is active) and a borrowed-order read allowed at
 * any time. */
GlimsStatus glims_image_select_layers (GlimsEngine *e, GlimsImageID image,
                                       const GlimsItemID *layers, size_t count, char **error);
GlimsStatus glims_image_selected_layers (GlimsEngine *e, GlimsImageID image,
                                         GlimsItemID *ids, int32_t capacity, int32_t *count);
/* Slots 136/137: the batch item selection of any kind (GlimsItemSetKind).
 * Select: an exact, ordered, transient write of the whole selected list
 * of `kind` (edit-ready gated; per-kind floating-selection policy; count 0
 * clears — channels through gimp_image_unset_selected_channels to restore
 * the old layer stack). Read: a borrowed-order plain read allowed at any
 * time; *count reset to 0 on every failure. */
GlimsStatus glims_image_select_items (GlimsEngine *e, GlimsImageID image, uint32_t kind,
                                      const GlimsItemID *items, int32_t count, char **error);
GlimsStatus glims_image_selected_items (GlimsEngine *e, GlimsImageID image, uint32_t kind,
                                        GlimsItemID *out, int32_t capacity, int32_t *count);
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

/* floating.c */
GlimsStatus glims_image_floating_selection (GlimsEngine *e, GlimsImageID image,
                                             GlimsFloatingState *out);
GlimsStatus glims_image_paste_into (GlimsEngine *e, GlimsImageID image, GlimsItemID target,
                                    GlimsRect bounds, const uint8_t *pixels, size_t byte_count,
                                    GlimsItemID *result, char **error);
GlimsStatus glims_floating_command (GlimsEngine *e, GlimsImageID image, GlimsItemID expected,
                                    uint32_t command, GlimsItemID *result, char **error);
/* Floats the current selection off `target` (0: the single selected
 * drawable) as a floating selection, as one native FS_FLOAT undo step;
 * `mode` is a GlimsFloatMode. */
GlimsStatus glims_selection_float (GlimsEngine *e, GlimsImageID image, GlimsItemID target,
                                   uint32_t mode, GlimsItemID *result, char **error);
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
GlimsStatus glims_image_convert_indexed   (GlimsEngine *e, GlimsImageID image,
                                           const GlimsIndexedSettings *settings,
                                           const GlimsColor *colors, int32_t color_count,
                                           char **error);

/* color-profile.c */
GlimsStatus glims_image_assign_profile (GlimsEngine *e, GlimsImageID image,
                                        const char *path, char **error);
GlimsStatus glims_image_convert_profile (GlimsEngine *e, GlimsImageID image,
                                         const char *path, uint32_t intent,
                                         bool black_point_compensation, char **error);

GlimsStatus glims_image_convert_profile_rasterizing (GlimsEngine *e, GlimsImageID image,
                                                     const char *path, uint32_t intent,
                                                     bool black_point_compensation, char **error);

/* guides.c */
GlimsStatus glims_image_guides (GlimsEngine *e, GlimsImageID image,
                                GlimsGuideInfo *rows, int32_t capacity, int32_t *count);
GlimsStatus glims_guide_put    (GlimsEngine *e, GlimsImageID image,
                                const GlimsGuideInfo *guide, GlimsGuideID *result, char **error);
GlimsStatus glims_guide_remove (GlimsEngine *e, GlimsImageID image,
                                GlimsGuideID guide, char **error);

/* grid.c */
GlimsStatus glims_image_grid     (GlimsEngine *e, GlimsImageID image, GlimsGrid *out, char **error);
GlimsStatus glims_image_set_grid (GlimsEngine *e, GlimsImageID image,
                                  const GlimsGrid *grid, char **error);

/* metadata.c */
GlimsStatus glims_image_metadata_tags   (GlimsEngine *e, GlimsImageID image, uint32_t domain,
                                         char ***result, int32_t *count, char **error);
GlimsStatus glims_image_metadata_values (GlimsEngine *e, GlimsImageID image, const char *tag,
                                         char ***result, int32_t *count, char **error);
GlimsStatus glims_image_metadata_edit   (GlimsEngine *e, GlimsImageID image, const char *tag,
                                         uint32_t operation, const char *const *values,
                                         int32_t count, char **error);
void        glims_free_metadata_strings (char **strings);
/* READ-ONLY descriptor of one registered tag (slot 128); a plain read
 * with no edit-readiness gate, never creates or installs metadata. */
GlimsStatus glims_image_metadata_tag_info (GlimsEngine *e, GlimsImageID image, const char *tag,
                                           GlimsMetadataTagInfo *outInfo, char **error);

/* metadata-language-facade.c: facade slots 139/140. A plain read of one
 * registered XMP LangAlt root property through the accepted private
 * reader (Engine/metadata-language.c); no writer, no BUSY gate, never
 * creates metadata. */
GlimsStatus glims_image_metadata_languages (GlimsEngine *e, GlimsImageID image, const char *root,
                                            GlimsMetadataLanguageValue **out,
                                            int32_t *out_count, char **error);
void        glims_metadata_languages_free (GlimsMetadataLanguageValue *values);
/* metadata-language-edit.c: facade slot 141. The WRITE path for one
 * registered XMP LangAlt root property: looks the image up, delegates
 * to the sealed Engine/metadata-language-write.c preflight and applies
 * the owned copy through the one native setter. OK+NULL copy is an
 * exact no-op before the readiness gate. */
GlimsStatus glims_image_duplicate_layers (GlimsEngine *e, GlimsImageID image,
                                           const GlimsItemID *sources, int32_t count,
                                           GlimsItemID *copies, char **error);
GlimsStatus glims_image_metadata_edit_language (GlimsEngine *e, GlimsImageID image, const char *root,
                                                const char *language, const char *text, char **error);

/* layer-source.c */
GlimsStatus glims_layer_source_info (GlimsEngine *e, GlimsImageID image, GlimsItemID layer,
                                     GlimsLayerSourceInfo *out, char **error);
/* The facade source kind when `layer` is a genuine editable text, link
 * or vector layer (the only targets Paste Into refuses with
 * REQUIRES_RASTERIZE), 0 for anything else — pixel, group, or a
 * structured class already behaving as pixels. */
uint32_t    glims_layer_editable_source_kind (GimpLayer *layer);
/* Rasterizes a genuine editable text/link/vector layer as one native undo
 * step; an already rasterized instance is a no-op. Readiness and locks
 * are the caller's. */
GlimsStatus glims_layer_rasterize   (GimpImage *image, GimpLayer *layer, char **error);
/* Nonmutating batch admission, including known missing/empty retained link
 * file/content. Does not access external files or prove rendering succeeds. */
GlimsStatus glims_layer_restore_source_admit (GimpLayer *layer, char **error);
/* Restores a rasterized text/link/vector layer from its retained source as
 * one native undo step, discarding pixel edits; an already editable
 * instance is a no-op, pixel/group/missing-source layers are UNSUPPORTED
 * before any mutation. Readiness and locks are the caller's. */
GlimsStatus glims_layer_restore_source (GimpImage *image, GimpLayer *layer, char **error);

/* resource.c */
GlimsStatus glims_lookup_gradient      (GlimsEngine *e, GlimsResourceID id,
                                        GimpGradient **out);
GlimsStatus glims_resources            (GlimsEngine *e, uint32_t kind,
                                        GlimsResourceInfo *rows, int32_t capacity,
                                        int32_t *count);
GlimsStatus glims_resource_identifiers (GlimsEngine *e, GlimsResourceID id,
                                        char **name, char **collection, bool *internal,
                                        char **error);
GlimsStatus glims_resource_resolve     (GlimsEngine *e, uint32_t kind, const char *name,
                                        const char *collection, bool internal,
                                        GlimsResourceID *outID, char **error);
GlimsStatus glims_resource_thumbnail   (GlimsEngine *e, GlimsResourceID id, int32_t max_size,
                                        const GlimsColor *foreground,
                                        const GlimsColor *background,
                                        GlimsPixelBuffer *out, char **error);
/* Resolves a facade handle to a live GimpBrush of this engine's own brush
 * factory, reusing lookup_resource()'s id validation: INVALID_ARGUMENT
 * for 0, out-of-native-range or non-brush handles, NOT_FOUND for stale
 * handles or brushes absent from the current factory. */
GlimsStatus glims_lookup_brush         (GlimsEngine *e, GlimsResourceID id, GimpBrush **out);

/* The live pattern a facade handle names, for fill_pattern: the generic
 * resource admission plus the pattern kind. Borrowed reference; the
 * caller never mutates or releases it. */
GlimsStatus glims_lookup_pattern       (GlimsEngine *e, GlimsResourceID id, GimpPattern **out);

/* resource-create.c */
/* Creates one saved bitmap brush or pattern from owned straight-alpha
 * RGBA pixels (facade slot 129, resource_create_pixels): validates every
 * input before any mutation, builds a private resource, saves it with a
 * checked gimp_data_save into a unique hidden staging subdirectory of
 * the chosen writable save folder, promotes it to a unique UUID final
 * file, reassociates it, and only then publishes it to the factory
 * after an exact-name membership check. `outID` is zeroed first and on
 * every failure. No image, history, context or clipboard is touched. */
GlimsStatus glims_resource_create_pixels (GlimsEngine *e, uint32_t kind, const char *name,
                                           int32_t width, int32_t height,
                                           const uint8_t *pixels, size_t byte_count,
                                           uint32_t brush_spacing, GlimsResourceID *outID,
                                           char **error);

/* The narrowly exposed generic resource lookup shared by the resource
 * files: lookup_resource()'s id validation (INVALID_ARGUMENT for 0 and
 * out-of-native-range handles before any narrowing, NOT_FOUND for
 * stale, foreign or non-current-factory handles) with the borrowed
 * live GimpData of any of the three kinds. The result is borrowed for
 * the calling engine-thread call only. */
GlimsStatus glims_lookup_resource_data (GlimsEngine *e, GlimsResourceID id,
                                         GimpData **out);
/* The factory of this engine that owns `data`'s kind (brush, pattern or
 * gradient), or NULL when `data` is none of them. */
GimpDataFactory *glims_factory_for_resource (Gimp *gimp, GimpData *data);

/* resource-create.c, shared by the pixel-create and duplicate paths.
 * The resource label contract of resource_create_pixels /
 * resource_duplicate: nonempty valid UTF-8, at most 255 bytes, no
 * control characters. */
gboolean    glims_valid_resource_name (const char *name);
/* Exact name collision against the current factory membership. */
gboolean    glims_resource_name_taken (GimpContainer *container, const gchar *name);

/* One resource call's owned staging state inside the configured save
 * folder. `extension` is not owned and must outlive the staging (a
 * #define literal or the class's static extension string). */
typedef struct
{
  GFile        *save_dir;         /* configured writable folder */
  GFile        *staging_dir;      /* unique hidden staging dir, or NULL */
  GFile        *staging_file;     /* staging file inside it, or NULL */
  GFile        *final_file;       /* promoted UUID final file, or NULL */
  gchar        *uuid;             /* names the staging dir and final file */
  const gchar  *extension;        /* the resource's own native extension */
  gboolean      staging_created;  /* mkdir succeeded: cleanup owns the paths */
  gboolean      promoted;         /* move succeeded: the final file is ours */
} GlimsResourceStaging;

/* Chooses the configured writable/search native save folder and creates
 * this call's unique OWNED hidden staging subdirectory and staging file
 * inside it. On failure `staging` is left zeroed. */
GlimsStatus glims_resource_staging_begin (GimpDataFactory      *factory,
                                          const gchar          *extension,
                                          GlimsResourceStaging *staging,
                                          char                **error);
/* The checked persistence pipeline both creation paths share: associate
 * the staging file, checked gimp_data_save(), promote to a unique UUID
 * final file by a no-overwrite, no-fallback move, reassociate, then
 * publish to the factory after an exact-name membership check and verify
 * membership, exact name and a positive native id. The call owns `data`
 * on every path: on success the container's reference remains and the
 * local one is dropped; on failure `data` is released. The staging is
 * always cleaned up: only this call's own actually-created staging
 * paths and, on failure only, the promoted final file are deleted.
 * `outID` receives the new handle on success only. */
GlimsStatus glims_resource_save_and_publish (GimpDataFactory      *factory,
                                              GimpData             *data,
                                              const gchar          *name,
                                              GlimsResourceStaging *staging,
                                              GlimsResourceID      *outID,
                                              char                **error);
/* Deletes the staged file/dir and, unless `keep_final`, the promoted
 * final file — only when this call actually created them (a preexisting
 * sentinel path always survives) — then releases every owned member. */
void        glims_resource_staging_cleanup (GlimsResourceStaging *staging,
                                            gboolean              keep_final);

/* resource-duplicate.c */
/* Duplicates one current brush, pattern or gradient (facade slot 131,
 * resource_duplicate): resolves `sourceID` once through
 * glims_lookup_resource_data(), checks the native duplicatable
 * capability and the private copy's saveability, duplicates with
 * gimp_data_duplicate() into an owned private object, names it, and
 * persists+publishes it through glims_resource_save_and_publish(). The
 * source is never mutated. `outID` is zeroed first and on every
 * failure. */
GlimsStatus glims_resource_duplicate (GlimsEngine *e, GlimsResourceID sourceID,
                                      const char *name, GlimsResourceID *outID,
                                      char **error);

/* resource-gradient-create.c */
/* INTERNAL-ONLY two-endpoint gradient creation — no facade slot, no API
 * table entry (slots 136/137 stay reserved; a public gradient-create slot
 * is added later by another change). Engine thread only (call through
 * glims_engine_call). Creates ONE privately owned, NON-internal
 * GimpGradient with exactly one segment (positions 0 / 0.5 / 1, stored
 * type GIMP_GRADIENT_SEGMENT_LINEAR, coloring GIMP_GRADIENT_SEGMENT_RGB,
 * both endpoint color types GIMP_GRADIENT_COLOR_FIXED) whose endpoint
 * colors are the captured GlimsColor sRGB+alpha values interpreted through
 * gegl_color_set_rgba_with_space(..., NULL) — never context-dynamic FG/BG
 * — and persists it through glims_resource_staging_begin() +
 * glims_resource_save_and_publish() with the native .ggr extension, after
 * the shared admission: `out` required and zeroed first and on every
 * failure, NULL engine/name/left/right/out INVALID_ARGUMENT, the
 * glims_valid_resource_name contract plus the GGR leading/trailing
 * ASCII-whitespace refusal, endpoint components finite 0...1, the
 * resource-duplicate BUSY gate (global busy plus any open stroke/filter),
 * and the exact-name duplicate refusal (FAILED, no uniquify). On success
 * `out` receives the positive current-factory native id. No image, undo,
 * context, clipboard or other catalog is touched. */
GlimsStatus glims_resource_create_gradient (GlimsEngine *engine, const char *name,
                                            const GlimsColor *left, const GlimsColor *right,
                                            GlimsResourceID *out, char **error);


GlimsStatus glims_adjustment_layer_new (GlimsEngine *engine, GlimsImageID image,
    GlimsItemID parent, int32_t index, const char *operation, const char *name,
    GlimsItemID *layer, GlimsEffectID *effect, char **error);

void glims_adjustment_projection_changed (GimpImage *image);

#endif /* GLIMS_ENGINE_PRIVATE_H */

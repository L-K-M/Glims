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
};

/* An image the app holds open. */
typedef struct
{
  GimpImage *image;
  GlimsEngine *engine;
  gulong     projection_update_handler;
  gulong     undo_event_handler;
  gulong     layers_changed_handler;
} GlimsOpenImage;

typedef GlimsStatus (*GlimsEngineFunc) (GlimsEngine *engine, gpointer data);

/* Runs `func` on the engine thread and waits for it. Safe from any thread. */
GlimsStatus      glims_engine_call       (GlimsEngine *engine, GlimsEngineFunc func, gpointer data);

void             glims_emit              (GlimsEngine *engine, GlimsEventKind kind,
                                          GimpImage *image, const GeglRectangle *rect,
                                          const gchar *text);
GlimsStatus      glims_fail              (char **error, GError *gerror, const gchar *fallback);
GlimsOpenImage * glims_lookup_image      (GlimsEngine *engine, GlimsImageID id);
GlimsStatus      glims_adopt_image       (GlimsEngine *engine, GimpImage *image, GlimsImageID *id);
void             glims_release_image     (GlimsEngine *engine, GlimsImageID id);
GimpDrawable   * glims_lookup_drawable   (GlimsOpenImage *open, GlimsItemID id);
gint             glims_next_session_id   (GlimsEngine *engine);

/* image.c */
GlimsStatus glims_image_new        (GlimsEngine *e, int32_t w, int32_t h, GlimsImageID *out, char **error);
GlimsStatus glims_image_open       (GlimsEngine *e, const char *path, GlimsImageID *out, char **error);
GlimsStatus glims_image_close      (GlimsEngine *e, GlimsImageID id);
GlimsStatus glims_image_info       (GlimsEngine *e, GlimsImageID id, GlimsImageInfo *info);
GlimsStatus glims_image_render     (GlimsEngine *e, GlimsImageID id, double scale, GlimsRect area,
                                    uint8_t *pixels, size_t stride);
GlimsStatus glims_image_save       (GlimsEngine *e, GlimsImageID id, const char *path, char **error);
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
GlimsStatus glims_filter_begin     (GlimsEngine *e, GlimsImageID image, GlimsItemID drawable,
                                    const char *operation, GlimsFilterID *out, char **error);
GlimsStatus glims_filter_set_double(GlimsEngine *e, GlimsFilterID id, const char *property, double value);
GlimsStatus glims_filter_commit    (GlimsEngine *e, GlimsFilterID id, char **error);
GlimsStatus glims_filter_abort     (GlimsEngine *e, GlimsFilterID id);
void        glims_filters_free     (gpointer filter);

#endif /* GLIMS_ENGINE_PRIVATE_H */

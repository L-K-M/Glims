/*
 * The Glims engine facade: the only interface between the Swift app and the
 * C adapter in Engine/, which hosts GIMP's engine.
 *
 * Rules (AGENTS.md, "Architecture boundaries"):
 *   - Only Glims-owned types cross this boundary. No GIMP, GLib or GEGL
 *     types, enum values or struct layouts.
 *   - The adapter library exports one symbol, glims_engine_get_api(). The
 *     app loads the library at run time and asks for the version it was
 *     built against; a change that is not purely additive bumps
 *     GLIMS_ENGINE_API_VERSION.
 *   - Every function is safe to call from any thread. Each runs on the
 *     engine thread and returns when it is done, so long operations (file
 *     export runs a plug-in) must not be called from the main thread.
 *   - Strings returned through `char **error` are owned by the caller and
 *     released with free_string(). Pass NULL to ignore them.
 *
 * One engine per process: GIMP's engine cannot be started again after it
 * stopped.
 */
#ifndef GLIMS_ENGINE_H
#define GLIMS_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GLIMS_ENGINE_API_VERSION 1u

typedef struct GlimsEngine GlimsEngine;

/* Handles. They are the engine's own image and item ids; 0 means none. */
typedef int32_t GlimsImageID;
typedef int32_t GlimsItemID;
typedef int32_t GlimsStrokeID;
typedef int32_t GlimsFilterID;

typedef enum GlimsStatus {
  GLIMS_STATUS_OK               = 0,
  GLIMS_STATUS_INVALID_ARGUMENT = 1,
  GLIMS_STATUS_NOT_FOUND        = 2,
  GLIMS_STATUS_FAILED           = 3, /* the engine reported an error */
  GLIMS_STATUS_BUSY             = 4, /* a long operation holds the image */
  GLIMS_STATUS_NOT_RUNNING      = 5
} GlimsStatus;

typedef struct GlimsRect {
  int32_t x, y, width, height;
} GlimsRect;

typedef enum GlimsEventKind {
  GLIMS_EVENT_PROJECTION_CHANGED = 1, /* image, rect in image pixels */
  GLIMS_EVENT_LAYERS_CHANGED     = 2, /* image */
  GLIMS_EVENT_UNDO_CHANGED       = 3, /* image */
  GLIMS_EVENT_MESSAGE            = 4  /* text */
} GlimsEventKind;

typedef struct GlimsEvent {
  uint32_t      kind;
  GlimsImageID  image;
  GlimsRect     rect;
  const char   *text; /* valid during the callback only */
} GlimsEvent;

/* Called on the engine thread. It must return quickly and must not call
 * back into the engine; hand the event to your own thread instead. */
typedef void (*GlimsEventCallback) (void *context, const GlimsEvent *event);

typedef struct GlimsEngineConfig {
  uint32_t            struct_size;      /* sizeof (GlimsEngineConfig) */
  const char         *user_directory;   /* engine settings; created when missing */
  const char         *cache_directory;  /* caches of the engine's libraries */
  GlimsEventCallback  on_event;         /* may be NULL */
  void               *event_context;
} GlimsEngineConfig;

typedef enum GlimsLayerKind {
  GLIMS_LAYER_PIXEL  = 1,
  GLIMS_LAYER_GROUP  = 2,
  GLIMS_LAYER_TEXT   = 3,
  GLIMS_LAYER_LINK   = 4,
  GLIMS_LAYER_VECTOR = 5
} GlimsLayerKind;

/* One row of the layer tree, top of the stack first, depth-first. */
typedef struct GlimsLayerInfo {
  GlimsItemID id;
  GlimsItemID parent;        /* 0 at the top level */
  int32_t     depth;         /* 0 at the top level */
  uint32_t    kind;          /* GlimsLayerKind */
  char        name[256];     /* UTF-8, truncated */
  char        mode[64];      /* blend mode nick, e.g. "normal" */
  bool        visible;
  bool        has_mask;
  bool        selected;
  double      opacity;       /* 0 ... 1 */
  GlimsRect   bounds;        /* in image pixels */
  int32_t     filter_count;  /* non-destructive filters on the layer */
} GlimsLayerInfo;

typedef struct GlimsImageInfo {
  int32_t width;
  int32_t height;
  int32_t layer_count;      /* all layers, groups included */
  bool    dirty;
  char    precision[64];    /* e.g. "u8-perceptual" */
} GlimsImageInfo;

typedef struct GlimsUndoInfo {
  int32_t undo_count;
  int32_t redo_count;
  char    next_undo[256];   /* name of the step undo would revert, or "" */
  char    next_redo[256];
} GlimsUndoInfo;

typedef struct GlimsBrushSettings {
  uint32_t struct_size;     /* sizeof (GlimsBrushSettings) */
  double   size;            /* diameter in image pixels */
  double   opacity;         /* 0 ... 1 */
  double   red, green, blue;/* sRGB, 0 ... 1 */
  bool     pressure_size;   /* pen pressure scales the size */
} GlimsBrushSettings;

typedef struct GlimsStrokePoint {
  double   x, y;            /* image pixels */
  double   pressure;        /* 0 ... 1; 1 for a mouse */
  double   xtilt, ytilt;    /* -1 ... 1 */
  uint32_t time_ms;
} GlimsStrokePoint;

typedef struct GlimsEngineAPI {
  uint32_t api_version;     /* GLIMS_ENGINE_API_VERSION of the library */
  uint32_t struct_size;     /* sizeof (GlimsEngineAPI) of the library */

  GlimsStatus  (*start)            (const GlimsEngineConfig *config,
                                    GlimsEngine            **engine,
                                    char                   **error);
  void         (*stop)             (GlimsEngine *engine);
  void         (*free_string)      (char *string);
  /* "3.2.0" and so on; valid while the engine runs. */
  const char * (*engine_version)   (GlimsEngine *engine);

  GlimsStatus  (*image_new)        (GlimsEngine *engine, int32_t width, int32_t height,
                                    GlimsImageID *image, char **error);
  GlimsStatus  (*image_open)       (GlimsEngine *engine, const char *path,
                                    GlimsImageID *image, char **error);
  GlimsStatus  (*image_close)      (GlimsEngine *engine, GlimsImageID image);
  GlimsStatus  (*image_info)       (GlimsEngine *engine, GlimsImageID image,
                                    GlimsImageInfo *info);
  /* Renders the composited image at `scale` (1.0 = one image pixel per
   * output pixel). `area` is in scaled pixel coordinates. Writes
   * area.width * area.height pixels of premultiplied 8-bit sRGB RGBA. */
  GlimsStatus  (*image_render)     (GlimsEngine *engine, GlimsImageID image,
                                    double scale, GlimsRect area,
                                    uint8_t *pixels, size_t stride);
  /* Saves the layered native file (XCF). */
  GlimsStatus  (*image_save)       (GlimsEngine *engine, GlimsImageID image,
                                    const char *path, char **error);
  /* Exports by file extension through the engine's file plug-ins. */
  GlimsStatus  (*image_export)     (GlimsEngine *engine, GlimsImageID image,
                                    const char *path, char **error);
  /* Fills up to `capacity` rows; `count` receives the total. */
  GlimsStatus  (*image_layers)     (GlimsEngine *engine, GlimsImageID image,
                                    GlimsLayerInfo *layers, int32_t capacity,
                                    int32_t *count);
  GlimsStatus  (*image_undo_info)  (GlimsEngine *engine, GlimsImageID image,
                                    GlimsUndoInfo *info);
  GlimsStatus  (*image_undo)       (GlimsEngine *engine, GlimsImageID image);
  GlimsStatus  (*image_redo)       (GlimsEngine *engine, GlimsImageID image);

  /* A paint stroke with the engine's paintbrush. One undo step per stroke. */
  GlimsStatus  (*stroke_begin)     (GlimsEngine *engine, GlimsImageID image,
                                    GlimsItemID layer,
                                    const GlimsBrushSettings *brush,
                                    const GlimsStrokePoint *first,
                                    GlimsStrokeID *stroke, char **error);
  GlimsStatus  (*stroke_continue)  (GlimsEngine *engine, GlimsStrokeID stroke,
                                    const GlimsStrokePoint *points, size_t count);
  GlimsStatus  (*stroke_end)       (GlimsEngine *engine, GlimsStrokeID stroke);

  /* A live filter session: the filter previews while it is open. Commit
   * adds it to the layer as one non-destructive undo step; abort leaves
   * no trace. */
  GlimsStatus  (*filter_begin)     (GlimsEngine *engine, GlimsImageID image,
                                    GlimsItemID drawable, const char *operation,
                                    GlimsFilterID *filter, char **error);
  GlimsStatus  (*filter_set_double)(GlimsEngine *engine, GlimsFilterID filter,
                                    const char *property, double value);
  GlimsStatus  (*filter_commit)    (GlimsEngine *engine, GlimsFilterID filter,
                                    char **error);
  GlimsStatus  (*filter_abort)     (GlimsEngine *engine, GlimsFilterID filter);
} GlimsEngineAPI;

/* Returns NULL when the library cannot serve `api_version`. */
const GlimsEngineAPI *glims_engine_get_api (uint32_t api_version);
typedef const GlimsEngineAPI *(*GlimsEngineGetAPIFunction) (uint32_t api_version);

#ifdef __cplusplus
}
#endif

#endif /* GLIMS_ENGINE_H */

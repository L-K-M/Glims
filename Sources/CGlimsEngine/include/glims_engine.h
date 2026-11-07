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
 *     GLIMS_ENGINE_API_VERSION. Within a version, functions, struct fields
 *     and enum values are only ever appended; the table's struct_size tells
 *     which functions a library has.
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
  GLIMS_STATUS_NOT_RUNNING      = 5,
  GLIMS_STATUS_CANCELLED        = 6  /* the user cancelled, e.g. a plug-in dialog */
} GlimsStatus;

typedef struct GlimsRect {
  int32_t x, y, width, height;
} GlimsRect;

typedef enum GlimsEventKind {
  GLIMS_EVENT_PROJECTION_CHANGED = 1, /* image, rect in image pixels */
  GLIMS_EVENT_LAYERS_CHANGED     = 2, /* image */
  GLIMS_EVENT_UNDO_CHANGED       = 3, /* image */
  GLIMS_EVENT_MESSAGE            = 4, /* text */
  GLIMS_EVENT_PROGRESS           = 5, /* text (may be NULL), value, active */
  GLIMS_EVENT_SELECTION_CHANGED  = 6, /* image */
  GLIMS_EVENT_SIZE_CHANGED       = 7  /* image: its width or height changed */
} GlimsEventKind;

typedef struct GlimsEvent {
  uint32_t      kind;
  GlimsImageID  image;
  GlimsRect     rect;
  const char   *text;   /* valid during the callback only */
  double        value;  /* PROGRESS: 0 ... 1, or -1 while the amount is unknown */
  bool          active; /* PROGRESS: false once the operation has ended */
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

/* The engine's paint tools; each paints with GIMP's own paint core. */
typedef enum GlimsPaintTool {
  GLIMS_PAINT_PAINTBRUSH = 0,
  GLIMS_PAINT_PENCIL     = 1,  /* hard-edged, no antialiasing */
  GLIMS_PAINT_AIRBRUSH   = 2,  /* keeps painting while the pointer rests */
  GLIMS_PAINT_ERASER     = 3,
  GLIMS_PAINT_SMUDGE     = 4,
  GLIMS_PAINT_BLUR       = 5,
  GLIMS_PAINT_SHARPEN    = 6,
  GLIMS_PAINT_DODGE      = 7,
  GLIMS_PAINT_BURN       = 8,
  GLIMS_PAINT_CLONE      = 9,  /* copies from source_drawable */
  GLIMS_PAINT_HEAL       = 10  /* like clone, blended into the target */
} GlimsPaintTool;

/* The tonal range dodge and burn act on. */
typedef enum GlimsToneRange {
  GLIMS_TONES_MIDTONES   = 0,
  GLIMS_TONES_SHADOWS    = 1,
  GLIMS_TONES_HIGHLIGHTS = 2
} GlimsToneRange;

typedef struct GlimsBrushSettings {
  uint32_t struct_size;     /* sizeof (GlimsBrushSettings) */
  double   size;            /* diameter in image pixels */
  double   opacity;         /* 0 ... 1 */
  double   red, green, blue;/* sRGB, 0 ... 1 */
  bool     pressure_size;   /* pen pressure scales the size */

  /* Paint tools. A caller whose struct_size ends before these paints with
   * the paintbrush. A negative number means the engine's default. */
  uint32_t    tool;            /* GlimsPaintTool */
  double      hardness;        /* 0 ... 1, the brush edge */
  double      rate;            /* 0 ... 100: airbrush stamps, smudge pickup, blur and sharpen strength */
  double      flow;            /* 0 ... 100: airbrush and smudge paint flow */
  double      exposure;        /* 0 ... 100: dodge and burn strength */
  uint32_t    tones;           /* GlimsToneRange, dodge and burn */
  bool        anti_erase;      /* eraser: restore erased opacity instead */
  GlimsItemID source_drawable; /* clone and heal: what to copy from (any open image) */
  double      source_x;        /* clone and heal: the source point, in the source's */
  double      source_y;        /* image pixels; the stroke's first point copies it */
} GlimsBrushSettings;

typedef struct GlimsStrokePoint {
  double   x, y;            /* image pixels */
  double   pressure;        /* 0 ... 1; 1 for a mouse */
  double   xtilt, ytilt;    /* -1 ... 1 */
  uint32_t time_ms;
} GlimsStrokePoint;

/* Selections. */
typedef enum GlimsSelectOperation {
  GLIMS_SELECT_REPLACE   = 0,
  GLIMS_SELECT_ADD       = 1,
  GLIMS_SELECT_SUBTRACT  = 2,
  GLIMS_SELECT_INTERSECT = 3
} GlimsSelectOperation;

typedef enum GlimsSelectShape {
  GLIMS_SHAPE_RECTANGLE = 1,  /* points: two opposite corners */
  GLIMS_SHAPE_ELLIPSE   = 2,  /* points: two opposite corners of its bounds */
  GLIMS_SHAPE_POLYGON   = 3   /* points: three or more vertices */
} GlimsSelectShape;

typedef enum GlimsSelectCommand {
  GLIMS_SELECT_ALL        = 1,
  GLIMS_SELECT_NONE       = 2,
  GLIMS_SELECT_INVERT     = 3,
  GLIMS_SELECT_FEATHER    = 4,  /* radius */
  GLIMS_SELECT_GROW       = 5,  /* radius */
  GLIMS_SELECT_SHRINK     = 6,  /* radius */
  GLIMS_SELECT_BORDER     = 7,  /* radius */
  GLIMS_SELECT_SHARPEN    = 8,
  GLIMS_SELECT_FROM_ALPHA = 9   /* the active layer's opacity */
} GlimsSelectCommand;

typedef struct GlimsSelectOptions {
  uint32_t struct_size;    /* sizeof (GlimsSelectOptions) */
  uint32_t operation;      /* GlimsSelectOperation */
  bool     antialias;
  double   feather;        /* radius in image pixels; 0 for a hard edge */
  double   corner_radius;  /* rectangles: rounded corners; 0 for square */
  double   threshold;      /* color selections: 0 ... 1 */
  bool     contiguous;     /* color: the area around the point, or every
                            * pixel of that color */
  bool     sample_merged;  /* color: compare the composite image, not the
                            * active layer */
} GlimsSelectOptions;

typedef struct GlimsPoint {
  double x, y;             /* image pixels */
} GlimsPoint;

/* One edge of the selection outline, on pixel corners. */
typedef struct GlimsSegment {
  int32_t x1, y1, x2, y2;
} GlimsSegment;

/* Editing. */
typedef struct GlimsColor {
  double red, green, blue, alpha; /* sRGB, 0 ... 1 */
} GlimsColor;

typedef enum GlimsFillMode {
  GLIMS_FILL_SIMILAR_COLORS = 1,  /* the area of similar color around the point */
  GLIMS_FILL_SELECTION      = 2   /* the selection, or the whole layer */
} GlimsFillMode;

typedef struct GlimsFillSettings {
  uint32_t   struct_size;    /* sizeof (GlimsFillSettings) */
  uint32_t   mode;           /* GlimsFillMode */
  GlimsColor color;
  double     opacity;        /* 0 ... 1 */
  double     threshold;      /* similar colors: 0 ... 1 */
  bool       sample_merged;  /* similar colors: compare the composite image */
  bool       antialias;
} GlimsFillSettings;

typedef enum GlimsGradientShape {
  GLIMS_GRADIENT_LINEAR   = 0,
  GLIMS_GRADIENT_BILINEAR = 1,
  GLIMS_GRADIENT_RADIAL   = 2
} GlimsGradientShape;

typedef struct GlimsGradientSettings {
  uint32_t   struct_size;    /* sizeof (GlimsGradientSettings) */
  uint32_t   shape;          /* GlimsGradientShape */
  GlimsColor from, to;
  double     opacity;        /* 0 ... 1 */
} GlimsGradientSettings;

typedef enum GlimsLayerCommand {
  GLIMS_LAYER_NEW        = 1,  /* transparent, image-sized, above the layer */
  GLIMS_LAYER_DUPLICATE  = 2,
  GLIMS_LAYER_DELETE     = 3,
  GLIMS_LAYER_RAISE      = 4,
  GLIMS_LAYER_LOWER      = 5,
  GLIMS_LAYER_TO_TOP     = 6,
  GLIMS_LAYER_TO_BOTTOM  = 7,
  GLIMS_LAYER_MERGE_DOWN = 8,
  GLIMS_LAYER_FLATTEN    = 9   /* the whole image into one layer */
} GlimsLayerCommand;

/* Which fields of GlimsLayerChange apply. */
typedef enum GlimsLayerProperty {
  GLIMS_LAYER_NAME    = 1 << 0,
  GLIMS_LAYER_VISIBLE = 1 << 1,
  GLIMS_LAYER_OPACITY = 1 << 2,
  GLIMS_LAYER_MODE    = 1 << 3
} GlimsLayerProperty;

typedef struct GlimsLayerChange {
  uint32_t struct_size;      /* sizeof (GlimsLayerChange) */
  uint32_t properties;       /* GlimsLayerProperty bits */
  char     name[256];        /* UTF-8 */
  bool     visible;
  double   opacity;          /* 0 ... 1 */
  char     mode[64];         /* blend mode nick, as GlimsLayerInfo reports it */
} GlimsLayerChange;

typedef enum GlimsTransform {
  GLIMS_TRANSFORM_ROTATE_90       = 1,  /* clockwise */
  GLIMS_TRANSFORM_ROTATE_180      = 2,
  GLIMS_TRANSFORM_ROTATE_270      = 3,  /* clockwise, i.e. 90 counter-clockwise */
  GLIMS_TRANSFORM_FLIP_HORIZONTAL = 4,
  GLIMS_TRANSFORM_FLIP_VERTICAL   = 5
} GlimsTransform;

typedef enum GlimsInterpolation {
  GLIMS_INTERPOLATION_DEFAULT = 0,  /* the engine's preference */
  GLIMS_INTERPOLATION_NONE    = 1,
  GLIMS_INTERPOLATION_LINEAR  = 2,
  GLIMS_INTERPOLATION_CUBIC   = 3,
  GLIMS_INTERPOLATION_NOHALO  = 4,
  GLIMS_INTERPOLATION_LOHALO  = 5
} GlimsInterpolation;

/* A transform of image pixel coordinates, row-major, applied to column
 * vectors (x, y, 1): x' = m[0][0] x + m[0][1] y + m[0][2]. */
typedef struct GlimsMatrix {
  double m[3][3];
} GlimsMatrix;

typedef enum GlimsJustify {
  GLIMS_JUSTIFY_LEFT   = 1,
  GLIMS_JUSTIFY_RIGHT  = 2,
  GLIMS_JUSTIFY_CENTER = 3,
  GLIMS_JUSTIFY_FILL   = 4
} GlimsJustify;

/* A text layer's look. Sizes and spacings are in image pixels. */
typedef struct GlimsTextSettings {
  uint32_t   struct_size;     /* sizeof (GlimsTextSettings) */
  char       font[256];       /* a name from fonts(), UTF-8 */
  double     size;            /* > 0 */
  GlimsColor color;
  uint32_t   justify;         /* GlimsJustify */
  double     line_spacing;    /* added between lines; may be negative */
  double     letter_spacing;  /* added between letters; may be negative */
  bool       antialias;
} GlimsTextSettings;

/* One anchor of a path with its two handles, in image pixels. A handle on
 * its anchor makes a sharp corner. */
typedef struct GlimsPathPoint {
  GlimsPoint in;       /* the handle toward the previous anchor */
  GlimsPoint anchor;
  GlimsPoint out;      /* the handle toward the next anchor */
} GlimsPathPoint;

/* One subpath: the next `count` points of the path's point list. A closed
 * subpath runs from its last point back to its first. */
typedef struct GlimsSubpath {
  int32_t count;       /* >= 1 */
  bool    closed;
} GlimsSubpath;

/* One row of the Paths list, top first. */
typedef struct GlimsPathInfo {
  GlimsItemID id;
  char        name[256];     /* UTF-8, truncated */
  bool        visible;
  bool        selected;
} GlimsPathInfo;

typedef struct GlimsPathChange {
  uint32_t    struct_size;   /* sizeof (GlimsPathChange) */
  const char *name;          /* NULL keeps the name */
  int32_t     visible;       /* -1 keeps it, 0 hides, 1 shows */
  bool        select;        /* makes it the selected path */
} GlimsPathChange;

/* How path_stroke draws a path: a line of one color. */
typedef struct GlimsLineSettings {
  uint32_t   struct_size;    /* sizeof (GlimsLineSettings) */
  double     width;          /* image pixels, > 0 */
  GlimsColor color;
  bool       antialias;
} GlimsLineSettings;

typedef enum GlimsRunMode {
  GLIMS_RUN_INTERACTIVE      = 1, /* the plug-in may show its dialog */
  GLIMS_RUN_WITH_LAST_VALUES = 2  /* repeat with the last settings, no dialog */
} GlimsRunMode;

/* A plug-in procedure with a menu entry that works on an image. */
typedef struct GlimsProcedureInfo {
  char name[128];        /* procedure name, e.g. "plug-in-sparkle" */
  char label[256];       /* menu label without mnemonics; ends in "…" when
                          * the plug-in asks for settings first */
  char menu_path[256];   /* engine menu path, e.g. "<Image>/Filters/Light and Shadow" */
  char blurb[512];       /* one-line description */
  bool sensitive;        /* runnable on the given image's selected layers */
} GlimsProcedureInfo;

/* Owned straight-alpha sRGB bytes. Release pixels with free_pixels(). */
typedef struct GlimsPixelBuffer {
  GlimsRect bounds;
  uint8_t  *pixels;
  size_t    byte_count;
} GlimsPixelBuffer;

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

  /* A paint stroke with one of the engine's paint tools (the brush
   * settings' tool). One undo step per stroke. */
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

  /* Plug-in procedures. They run in their own processes; interactive runs
   * may show the plug-in's own dialog window.
   *
   * procedures() lists those with an entry in the image window's menus
   * ("<Image>/...") that work on an image, in registration order. With an image, `sensitive` says whether each can
   * run on its selected layers. Fills up to `capacity` rows; `count`
   * receives the total. */
  GlimsStatus  (*procedures)       (GlimsEngine *engine, GlimsImageID image,
                                    GlimsProcedureInfo *procedures, int32_t capacity,
                                    int32_t *count);
  /* Runs a procedure on the image's selected layers, as the engine's own
   * menus do, and returns when the plug-in has finished: interactively
   * that includes the time its dialog is open, so never call this on the
   * main thread. Meanwhile reads (render, info, layers) keep working, but
   * calls that open, change or write images (image_open, strokes, filters,
   * undo, redo, save, export, another procedure_run) report BUSY, so a
   * plug-in dialog acts as a modal filter dialog. BUSY too while a stroke
   * or filter session is open. Progress arrives as PROGRESS events.
   * CANCELLED when the user cancelled. */
  GlimsStatus  (*procedure_run)    (GlimsEngine *engine, GlimsImageID image,
                                    const char *name, uint32_t run_mode,
                                    char **error);
  /* Asks the running procedure to stop, as a progress Cancel button does.
   * NOT_FOUND when none is running. */
  GlimsStatus  (*procedure_cancel) (GlimsEngine *engine);

  /* Selections. Each change is one undo step and sends SELECTION_CHANGED;
   * painting, fills and filters then stay inside the selection. NULL
   * options mean replace, antialiased, no feather. */
  GlimsStatus  (*select_shape)     (GlimsEngine *engine, GlimsImageID image,
                                    uint32_t shape, const GlimsPoint *points,
                                    size_t count, const GlimsSelectOptions *options);
  /* Selects by the color at `point`, around it (contiguous) or everywhere. */
  GlimsStatus  (*select_color)     (GlimsEngine *engine, GlimsImageID image,
                                    GlimsPoint point, const GlimsSelectOptions *options,
                                    char **error);
  GlimsStatus  (*select_command)   (GlimsEngine *engine, GlimsImageID image,
                                    uint32_t command, double radius, char **error);
  GlimsStatus  (*selection_bounds) (GlimsEngine *engine, GlimsImageID image,
                                    bool *empty, GlimsRect *bounds);
  /* The outline as edges on pixel corners, in image pixels, for marching
   * ants. Fills up to `capacity`; `count` receives the total. */
  GlimsStatus  (*selection_outline)(GlimsEngine *engine, GlimsImageID image,
                                    GlimsSegment *segments, int32_t capacity,
                                    int32_t *count);

  /* Editing. Each change is one undo step; fills and gradients act on the
   * selected layer and stay inside the selection. */
  GlimsStatus  (*fill)             (GlimsEngine *engine, GlimsImageID image,
                                    GlimsPoint point, const GlimsFillSettings *settings,
                                    char **error);
  GlimsStatus  (*gradient)         (GlimsEngine *engine, GlimsImageID image,
                                    GlimsPoint from, GlimsPoint to,
                                    const GlimsGradientSettings *settings, char **error);
  /* Makes `layer` the selected layer, which plug-ins, fills, gradients and
   * the Layer commands act on. */
  GlimsStatus  (*layer_select)     (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer);
  /* `layer` 0 means the selected layer. `result` (may be NULL) receives
   * the new layer of NEW, DUPLICATE, MERGE_DOWN and FLATTEN. */
  GlimsStatus  (*layer_command)    (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                    uint32_t command, GlimsItemID *result, char **error);
  GlimsStatus  (*layer_change)     (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                    const GlimsLayerChange *change, char **error);
  GlimsStatus  (*layer_move)       (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                    double dx, double dy);
  /* Crops the image and its layers to `rect` (image pixels); SIZE_CHANGED follows. */
  GlimsStatus  (*image_crop)       (GlimsEngine *engine, GlimsImageID image, GlimsRect rect,
                                    char **error);

  /* Transforms. Each is one undo step; image-wide ones send SIZE_CHANGED
   * when the size changes. */
  GlimsStatus  (*image_transform)  (GlimsEngine *engine, GlimsImageID image, uint32_t transform);
  /* Around the layer's center; `layer` 0 means the selected layer. */
  GlimsStatus  (*layer_transform)  (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                    uint32_t transform);
  /* Scales the image and all its layers (Image Size). */
  GlimsStatus  (*image_scale)      (GlimsEngine *engine, GlimsImageID image, int32_t width,
                                    int32_t height, char **error);
  /* Changes the canvas (Canvas Size); the old image lands at `offset`.
   * Image-sized layers grow and fill the new area with `fill`. */
  GlimsStatus  (*image_resize_canvas)(GlimsEngine *engine, GlimsImageID image, int32_t width,
                                    int32_t height, int32_t offset_x, int32_t offset_y,
                                    const GlimsColor *fill, char **error);
  /* Applies `matrix` to `layer` (0: the selected layer) as one undo step,
   * as the engine's transform tools do; the layer grows to hold the
   * result. `interpolation` is a GlimsInterpolation. INVALID_ARGUMENT for
   * a matrix that is not finite or flattens the layer. */
  GlimsStatus  (*layer_transform_matrix)(GlimsEngine *engine, GlimsImageID image,
                                    GlimsItemID layer, const GlimsMatrix *matrix,
                                    uint32_t interpolation, char **error);

  /* Text. The font names text settings take, one per line, sorted; free
   * with free_string. Waits for the engine to finish loading its fonts. */
  GlimsStatus  (*fonts)            (GlimsEngine *engine, char **names);
  /* Adds a text layer with its top-left at `position` (image pixels) above
   * the selected layer and selects it, as one undo step. `layer` (may be
   * NULL) receives it. NOT_FOUND for an unknown font. */
  GlimsStatus  (*text_layer_new)   (GlimsEngine *engine, GlimsImageID image, const char *text,
                                    const GlimsTextSettings *settings, GlimsPoint position,
                                    GlimsItemID *layer, char **error);
  /* A text layer's plain text (free with free_string) and settings.
   * NOT_FOUND when `layer` is not a text layer. */
  GlimsStatus  (*text_layer_get)   (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                    char **text, GlimsTextSettings *settings);
  /* Changes a text layer's text and settings as one undo step; NULL text
   * keeps the text, NULL settings keep the look. */
  GlimsStatus  (*text_layer_set)   (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                    const char *text, const GlimsTextSettings *settings,
                                    char **error);

  /* Paths. The image's paths, top first; `count` receives how many there
   * are, `rows` at most `capacity` of them. */
  GlimsStatus  (*paths)            (GlimsEngine *engine, GlimsImageID image,
                                    GlimsPathInfo *rows, int32_t capacity, int32_t *count);
  /* A path's subpaths and points. `subpath_count` and `point_count`
   * receive the full counts; the arrays (either may be NULL) receive at
   * most their capacity. NOT_FOUND for an unknown path. */
  GlimsStatus  (*path_get)         (GlimsEngine *engine, GlimsImageID image, GlimsItemID path,
                                    GlimsSubpath *subpaths, int32_t subpath_capacity,
                                    int32_t *subpath_count, GlimsPathPoint *points,
                                    int32_t point_capacity, int32_t *point_count);
  /* Replaces a path's subpaths as one undo step. With `path` 0, adds a new
   * path named `name` (NULL: the engine's default name) above the selected
   * path and selects it, as one undo step. `result` (may be NULL) receives
   * the path. The subpath counts must add up to `point_count`. */
  GlimsStatus  (*path_set)         (GlimsEngine *engine, GlimsImageID image, GlimsItemID path,
                                    const char *name, const GlimsSubpath *subpaths,
                                    int32_t subpath_count, const GlimsPathPoint *points,
                                    int32_t point_count, GlimsItemID *result, char **error);
  /* Renames, shows or hides, or selects a path. Renaming and showing or
   * hiding are undo steps; selecting is not. */
  GlimsStatus  (*path_change)      (GlimsEngine *engine, GlimsImageID image, GlimsItemID path,
                                    const GlimsPathChange *change, char **error);
  /* Deletes a path as one undo step. */
  GlimsStatus  (*path_delete)      (GlimsEngine *engine, GlimsImageID image, GlimsItemID path);
  /* Makes the area the path encloses the selection, combined by
   * `options->operation`, with its antialias and feather, as one undo
   * step. Open subpaths count as closed. */
  GlimsStatus  (*path_to_selection)(GlimsEngine *engine, GlimsImageID image, GlimsItemID path,
                                    const GlimsSelectOptions *options);
  /* Draws the path as a line on `layer` (0: the selected layer), inside
   * the selection if there is one, as one undo step. */
  GlimsStatus  (*path_stroke)      (GlimsEngine *engine, GlimsImageID image, GlimsItemID path,
                                    GlimsItemID layer, const GlimsLineSettings *settings,
                                    char **error);
  /* System clipboard. Copy honors the selection, or copies the whole
   * active layer / merged image when no selection exists. Copy is not an
   * undo step. Clear and Paste each make one undo step. Paste creates an
   * independent layer at bounds.x/y, ignoring the current selection. */
  GlimsStatus (*image_copy_pixels)(GlimsEngine *, GlimsImageID, bool merged,
                                   GlimsPixelBuffer *, char **error);
  void        (*free_pixels)(uint8_t *pixels);
  GlimsStatus (*image_clear)(GlimsEngine *, GlimsImageID, const GlimsColor *background, char **error);
  GlimsStatus (*image_paste_pixels)(GlimsEngine *, GlimsImageID, GlimsRect bounds,
                                    const uint8_t *pixels, size_t byte_count,
                                    GlimsItemID *result, char **error);
} GlimsEngineAPI;

/* Returns NULL when the library cannot serve `api_version`. */
const GlimsEngineAPI *glims_engine_get_api (uint32_t api_version);
typedef const GlimsEngineAPI *(*GlimsEngineGetAPIFunction) (uint32_t api_version);

#ifdef __cplusplus
}
#endif

#endif /* GLIMS_ENGINE_H */

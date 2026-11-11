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
typedef int32_t GlimsEffectID;

typedef enum GlimsStatus {
  GLIMS_STATUS_OK               = 0,
  GLIMS_STATUS_INVALID_ARGUMENT = 1,
  GLIMS_STATUS_NOT_FOUND        = 2,
  GLIMS_STATUS_FAILED           = 3, /* the engine reported an error */
  GLIMS_STATUS_BUSY             = 4, /* a long operation holds the image */
  GLIMS_STATUS_NOT_RUNNING      = 5,
  GLIMS_STATUS_CANCELLED        = 6, /* the user cancelled, e.g. a plug-in dialog */
  GLIMS_STATUS_LOCKED           = 7, /* a layer or ancestor protects this edit */
  GLIMS_STATUS_UNSUPPORTED      = 8, /* the engine version cannot do this */
  GLIMS_STATUS_REQUIRES_RASTERIZE = 9 /* explicit consent is needed to turn editable layers into pixels */
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
  GLIMS_EVENT_SIZE_CHANGED       = 7, /* image: its width or height changed */
  GLIMS_EVENT_CHANNELS_CHANGED   = 8, /* image: channel list, selected channel,
                                       * components or Quick Mask */
  GLIMS_EVENT_GUIDES             = 9  /* image: a guide was added, removed or
                                       * moved; re-read image_guides */
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

/* A layer's structured-content source, as layer_source_info reports it.
 * `source_kind` is a GlimsLayerKind naming the layer's own class, so a
 * rasterized text, link or vector layer keeps TEXT/LINK/VECTOR here while
 * GlimsLayerInfo.kind already reports PIXEL for it. `is_rasterized` says
 * the layer's editable predicate is currently off and its content is
 * pixels: a text layer whose pixels were edited (its "modified" flag),
 * a link layer that stopped monitoring its file, or a rasterized vector
 * layer. `has_source` says the layer still carries its structured
 * source: a retained GimpText, an associated path, or the file link,
 * which a link layer keeps after monitoring stops. An ordinary pixel or
 * group layer reports source_kind PIXEL/GROUP with both flags false. */
typedef struct GlimsLayerSourceInfo {
  uint32_t struct_size;    /* sizeof (GlimsLayerSourceInfo) */
  uint32_t source_kind;    /* GlimsLayerKind */
  bool     is_rasterized;
  bool     has_source;
} GlimsLayerSourceInfo;

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

/* History positions are ordered from the earliest retained state (0) to
 * the last redo state. A revision is valid for this open image only and
 * changes whenever its native undo/redo history changes. */
typedef struct GlimsHistoryInfo {
  uint64_t revision;
  int32_t  count;             /* includes the earliest retained state */
  int32_t  current_position;
} GlimsHistoryInfo;

typedef struct GlimsHistoryRow {
  int32_t position;
  char    name[256];          /* action that produced this state */
} GlimsHistoryRow;

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

/* Owned optional axes for V2 samples, independent of platform event enums. */
typedef enum GlimsStrokeSampleFlags {
  GLIMS_STROKE_SAMPLE_HAS_ROTATION            = 1u << 0,
  GLIMS_STROKE_SAMPLE_HAS_TANGENTIAL_PRESSURE = 1u << 1
} GlimsStrokeSampleFlags;

typedef struct GlimsStrokeSampleV2 {
  uint32_t struct_size;       /* known prefix <= struct_size <= sample_stride */
  uint32_t flags;             /* GlimsStrokeSampleFlags; no unknown bits */
  double   x, y;             /* image pixels, finite within -524288 ... 524288 */
  double   pressure;         /* finite 0 ... 1 */
  double   xtilt, ytilt;      /* finite -1 ... 1 */
  uint32_t time_ms;
  uint32_t reserved;          /* zero */
  double   rotation_turns;    /* finite 0 <= value < 1; zero when absent */
  double   tangential_pressure; /* finite -1 ... 1; zero when absent */
} GlimsStrokeSampleV2;

typedef struct GlimsStrokePacketV2 {
  uint32_t    struct_size;    /* at least sizeof(GlimsStrokePacketV2) */
  uint32_t    sample_stride;  /* at least sizeof(GlimsStrokeSampleV2) */
  const void *samples;        /* arbitrary alignment; immutable until return */
  size_t      count;          /* at most 4096 */
  size_t      byte_count;     /* count * sample_stride, at most 1 MiB */
} GlimsStrokePacketV2;

/* Owned facts for a supported deterministic V1 stroke. Initialize to zero
 * except struct_size. Free each non-NULL string with free_string. */
typedef struct GlimsStrokeCaptureFacts {
  uint32_t struct_size;
  bool     brush_internal;
  char    *brush_name;
  char    *brush_collection; /* NULL and empty are distinct resource identities */
  char    *fingerprint;      /* 64 lowercase hexadecimal characters when present */
} GlimsStrokeCaptureFacts;

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

/* How fill_pattern paints: the pattern `pattern` tiled from the drawable's
 * origin, instead of a solid color. It carries no color fields of its
 * own. */
typedef struct GlimsPatternFillSettings {
  uint32_t struct_size;    /* sizeof (GlimsPatternFillSettings) */
  uint32_t mode;           /* GlimsFillMode */
  double   opacity;        /* 0 ... 1 */
  double   threshold;      /* similar colors: 0 ... 1 */
  bool     sample_merged;  /* similar colors: compare the composite image */
  bool     antialias;
} GlimsPatternFillSettings;

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

/* The color space a selected-resource gradient blends its stops in.
 * These are the facade's own values for the engine's gradient blend
 * color spaces; the native enum never crosses this boundary. */
typedef enum GlimsGradientBlendSpace {
  GLIMS_GRADIENT_BLEND_RGB_PERCEPTUAL = 0,  /* sRGB-encoded components */
  GLIMS_GRADIENT_BLEND_RGB_LINEAR     = 1,  /* reserved; currently UNSUPPORTED */
  GLIMS_GRADIENT_BLEND_CIE_LAB        = 2   /* CIE L*a*b* */
} GlimsGradientBlendSpace;

/* A gradient drawn with a selected gradient resource: `foreground` and
 * `background` feed the resource's foreground/background stop types,
 * like the FG and BG wells do for the engine's own tools. Both are
 * opaque: their alpha must be exactly 1 and is rejected otherwise, since
 * the engine's FG/BG context is opaque and transparent stop types (such
 * as FG-to-transparent) are the resource's own business. */
typedef struct GlimsResourceGradientSettings {
  uint32_t   struct_size;    /* sizeof (GlimsResourceGradientSettings) */
  uint32_t   shape;          /* GlimsGradientShape */
  GlimsColor foreground;     /* sRGB 0 ... 1, alpha exactly 1 */
  GlimsColor background;     /* sRGB 0 ... 1, alpha exactly 1 */
  double     opacity;        /* 0 ... 1, finite */
  bool       reverse;        /* the resource's stops run end to start */
  uint32_t   blend_space;    /* GlimsGradientBlendSpace */
} GlimsResourceGradientSettings;

typedef enum GlimsLayerCommand {
  GLIMS_LAYER_NEW        = 1,  /* transparent, image-sized, above the layer */
  GLIMS_LAYER_DUPLICATE  = 2,
  GLIMS_LAYER_DELETE     = 3,
  GLIMS_LAYER_RAISE      = 4,
  GLIMS_LAYER_LOWER      = 5,
  GLIMS_LAYER_TO_TOP     = 6,
  GLIMS_LAYER_TO_BOTTOM  = 7,
  GLIMS_LAYER_MERGE_DOWN = 8,
  GLIMS_LAYER_FLATTEN    = 9,  /* the whole image into one layer */
  /* FIT resizes the layer to the image bounds keeping its content in
   * place; TRIM crops it to its content. Both are for pixel layers
   * (rasterized text/link/vector instances included): a group or a
   * genuine editable layer reports UNSUPPORTED with a reason, and an
   * already fitting, already tight or empty layer is a no-op. */
  GLIMS_LAYER_FIT_TO_IMAGE     = 10,
  GLIMS_LAYER_TRIM_TO_CONTENT  = 11,
  /* Turns a genuine editable text, link or vector layer pixel-behaving
   * while it keeps its structured source, as one undo step ("Rasterize
   * Text/Link/Vector Layer"); the rendered pixels, bounds and selection
   * are unchanged. A layer of one of those classes that already behaves
   * as pixels — a painted-over text, an unmonitored link, a rasterized
   * vector — is a no-op that pushes no undo, whether or not its source
   * survived. Ordinary pixel layers and groups report UNSUPPORTED with
   * a reason; an explicit layer id that names no attached layer of the
   * image is NOT_FOUND. PIXELS or POSITION locks of the layer or a group
   * around it refuse with LOCKED; stroke, filter and plug-in activity
   * with BUSY. */
  GLIMS_LAYER_RASTERIZE        = 12,
  /* The inverse of RASTERIZE for layers that still retain their
   * structured source: discards the pixel edits and regenerates the
   * content from the retained text, link or vector source as one undo
   * step, preserving the selection, the item id, the source kind and a
   * mask attachment. Only retained text/vector/link classes restore:
   * ordinary pixel layers, groups and structured layers whose source is
   * gone report UNSUPPORTED before any mutation, an explicit layer id
   * that names no attached layer of the image is NOT_FOUND, and an
   * already editable instance is a no-op that pushes no undo. The same
   * readiness and inherited PIXELS|POSITION locks as RASTERIZE gate it
   * (LOCKED, BUSY). A link layer reloads its file when the file is
   * readable; on a read failure it keeps its retained source buffer and
   * resumes monitoring — a missing file is not an error. */
  GLIMS_LAYER_RESTORE_SOURCE   = 13
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

/* The locks a layer or group can hold; `mask` and `values` of
 * set_layer_locks and the fields of GlimsLayerState are these bits. */
typedef enum GlimsLayerLock {
  GLIMS_LOCK_PIXELS   = 1 << 0,  /* the layer's pixels cannot change */
  GLIMS_LOCK_POSITION = 1 << 1,  /* the layer cannot move or transform */
  GLIMS_LOCK_ALPHA    = 1 << 2   /* the alpha channel cannot change */
} GlimsLayerLock;

/* A layer's or group's lock state. `locks` is the item's own locks;
 * `locked` is what the engine enforces on it: an ancestor group's lock
 * counts too, and for a group the PIXELS and POSITION bits also cover a
 * locked descendant, as the engine's lock rules do. Bits are
 * GlimsLayerLock. */
typedef struct GlimsLayerState {
  uint32_t locks;
  uint32_t locked;
} GlimsLayerState;

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

/* How path_fill fills a path: a solid color, the engine's foreground
 * fill. No pattern and no fill rule of its own; the core's scan
 * converter decides coverage. */
typedef struct GlimsPathFillSettings {
  uint32_t   struct_size;    /* sizeof (GlimsPathFillSettings) */
  GlimsColor color;          /* sRGB, 0 ... 1; its alpha multiplies the fill */
  double     opacity;        /* 0 ... 1 */
  bool       antialias;      /* the fill edge */
} GlimsPathFillSettings;

/* A vector layer's stroke cap, as the engine's own line caps. Facade-owned
 * values; the engine's enum never crosses this boundary. */
typedef enum GlimsVectorCapStyle {
  GLIMS_VECTOR_CAP_BUTT   = 1,
  GLIMS_VECTOR_CAP_ROUND  = 2,
  GLIMS_VECTOR_CAP_SQUARE = 3
} GlimsVectorCapStyle;

/* A vector layer's stroke join. */
typedef enum GlimsVectorJoinStyle {
  GLIMS_VECTOR_JOIN_MITER = 1,
  GLIMS_VECTOR_JOIN_ROUND = 2,
  GLIMS_VECTOR_JOIN_BEVEL = 3
} GlimsVectorJoinStyle;

/* Which fields of GlimsVectorStyleChange apply. */
typedef enum GlimsVectorStyleProperty {
  GLIMS_VECTOR_STYLE_ENABLE_FILL      = 1 << 0,
  GLIMS_VECTOR_STYLE_FILL_COLOR       = 1 << 1,
  GLIMS_VECTOR_STYLE_FILL_ANTIALIAS   = 1 << 2,
  GLIMS_VECTOR_STYLE_ENABLE_STROKE    = 1 << 3,
  GLIMS_VECTOR_STYLE_STROKE_COLOR     = 1 << 4,
  GLIMS_VECTOR_STYLE_STROKE_ANTIALIAS = 1 << 5,
  GLIMS_VECTOR_STYLE_STROKE_WIDTH     = 1 << 6,
  GLIMS_VECTOR_STYLE_STROKE_CAP       = 1 << 7,
  GLIMS_VECTOR_STYLE_STROKE_JOIN      = 1 << 8,
  GLIMS_VECTOR_STYLE_STROKE_MITER     = 1 << 9
} GlimsVectorStyleProperty;

/* A genuine vector layer's native fill/stroke style, as
 * vector_layer_style_get reports it. Solid paint only: a layer whose
 * native fill or stroke is a pattern reports UNSUPPORTED instead of
 * converting it. The fields are exactly what XCF persists for a vector
 * layer (PROP_VECTOR_LAYER): enable flags, solid colors, antialias, and
 * stroke width, cap, join and miter limit. Opacity, paint mode, unit,
 * dash offset, feather and stroke method are not persisted by XCF and are
 * deliberately not exposed. Colors are explicit sRGB RGBA per call; the
 * engine keeps a context color's alpha opaque natively, as its own PDB
 * and XCF load do. `stroke_width` is in image pixels. */
typedef struct GlimsVectorStyle {
  uint32_t   struct_size;        /* sizeof (GlimsVectorStyle) */
  bool       enable_fill;
  GlimsColor fill_color;         /* sRGB, 0 ... 1 */
  bool       fill_antialias;
  bool       enable_stroke;
  GlimsColor stroke_color;       /* sRGB, 0 ... 1 */
  bool       stroke_antialias;
  double     stroke_width;       /* image pixels, > 0 */
  uint32_t   stroke_cap;         /* GlimsVectorCapStyle */
  uint32_t   stroke_join;        /* GlimsVectorJoinStyle */
  double     stroke_miter_limit;
} GlimsVectorStyle;

/* A requested change to a vector layer's style; the bits of `properties`
 * (GlimsVectorStyleProperty) say which fields apply, the rest keep their
 * state. */
typedef struct GlimsVectorStyleChange {
  uint32_t   struct_size;        /* sizeof (GlimsVectorStyleChange) */
  uint32_t   properties;         /* GlimsVectorStyleProperty bits */
  bool       enable_fill;
  GlimsColor fill_color;         /* finite sRGB components, 0 ... 1 */
  bool       fill_antialias;
  bool       enable_stroke;
  GlimsColor stroke_color;       /* finite sRGB components, 0 ... 1 */
  bool       stroke_antialias;
  double     stroke_width;       /* image pixels, finite, 0 < w <= 2000 */
  uint32_t   stroke_cap;         /* GlimsVectorCapStyle */
  uint32_t   stroke_join;        /* GlimsVectorJoinStyle */
  double     stroke_miter_limit; /* finite, 0 ... 100 */
} GlimsVectorStyleChange;

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

/* Filter operations and their parameters, for native filter forms.
 * The kinds the facade carries; a property of any other kind reports
 * GLIMS_FILTER_VALUE_UNSUPPORTED and cannot be read or written. */
typedef enum GlimsFilterValueKind {
  GLIMS_FILTER_VALUE_UNSUPPORTED = 0,
  GLIMS_FILTER_VALUE_NUMBER      = 1,  /* real number, `number` */
  GLIMS_FILTER_VALUE_INTEGER     = 2,  /* whole number, `integer` */
  GLIMS_FILTER_VALUE_BOOL        = 3,  /* `boolean` */
  GLIMS_FILTER_VALUE_ENUM        = 4,  /* choice nick in `string` */
  GLIMS_FILTER_VALUE_STRING      = 5,  /* text in `string` */
  GLIMS_FILTER_VALUE_COLOR       = 6   /* `color`, sRGB */
} GlimsFilterValueKind;

/* Whether a native property form can drive an operation. */
typedef enum GlimsFilterOpSupport {
  GLIMS_FILTER_OP_SUPPORTED  = 0,  /* filter_begin plus typed properties */
  GLIMS_FILTER_OP_AUX_INPUT  = 1,  /* takes a second, auxiliary input */
  GLIMS_FILTER_OP_CONFIG     = 2   /* settings on a config object (Curves & co.) */
} GlimsFilterOpSupport;

/* One row of the filter_operations() list, sorted by name. */
typedef struct GlimsOperationInfo {
  char     name[128];       /* e.g. "gegl:gaussian-blur" */
  char     title[256];      /* e.g. "Gaussian Blur" */
  char     categories[256]; /* the engine's ':'-separated categories */
  char     blurb[512];      /* one-line description */
  uint32_t support;         /* GlimsFilterOpSupport */
} GlimsOperationInfo;

/* One editable property of an operation, in declaration order. Fields
 * that a kind does not use are zero. Numeric bounds are the absolute
 * limits; the ui_* fields are the engine's suggested form range (the
 * bounds when unset). */
typedef struct GlimsFilterProperty {
  char       name[128];      /* e.g. "std-dev-x" */
  char       label[256];     /* the property's human name */
  char       blurb[512];     /* longer description */
  char       unit[64];       /* a unit hint like "pixel-distance"; "" when none */
  uint32_t   kind;           /* GlimsFilterValueKind */
  double     min, max;       /* NUMBER/INTEGER: absolute bounds */
  double     ui_min, ui_max; /* suggested form range */
  double     ui_step_small, ui_step_big; /* suggested steps; 0 when unset */
  double     ui_gamma;       /* non-linear slider mapping; 1.0 when linear */
  int32_t    ui_digits;      /* suggested decimals; -1 for the default */
  double     default_number; /* NUMBER/INTEGER default */
  bool       default_bool;
  char       default_string[256]; /* ENUM's default nick; STRING's default */
  GlimsColor default_color;
  int32_t    choice_count;   /* ENUM: number of valid nicks */
} GlimsFilterProperty;

/* One valid value of an ENUM property: `nick` is what
 * filter_set_property() accepts and filter_get_property() returns. */
typedef struct GlimsFilterEnumChoice {
  char nick[64];
  char label[256];
} GlimsFilterEnumChoice;

/* A typed property value of an open filter session, for
 * filter_get_property() and filter_set_property(). `kind` picks the
 * field; the setter requires it to match the property's own kind. */
typedef struct GlimsFilterValue {
  uint32_t   kind;         /* GlimsFilterValueKind, never UNSUPPORTED */
  double     number;       /* NUMBER: finite, inside `min`...`max` */
  int64_t    integer;      /* INTEGER: inside `min`...`max` */
  bool       boolean;      /* BOOL */
  char       string[256];  /* ENUM nick; STRING text (truncated on get) */
  GlimsColor color;        /* COLOR: finite components inside 0...1 */
} GlimsFilterValue;

/* Own normalized settings, independent of native config object layouts. */
typedef struct GlimsBrightnessContrastSettings {
  uint32_t struct_size;
  double brightness;        /* finite -1..1; default 0 */
  double contrast;          /* finite -1..1; default 0 */
} GlimsBrightnessContrastSettings;

typedef struct GlimsColorBalanceRange {
  double cyan_red;           /* finite -1..1; positive adds red */
  double magenta_green;      /* finite -1..1; positive adds green */
  double yellow_blue;        /* finite -1..1; positive adds blue */
} GlimsColorBalanceRange;

typedef struct GlimsColorBalanceSettings {
  uint32_t struct_size;
  uint32_t preserve_luminosity; /* exactly 0 or 1; default 1 */
  GlimsColorBalanceRange shadows;
  GlimsColorBalanceRange midtones;
  GlimsColorBalanceRange highlights;
} GlimsColorBalanceSettings;

typedef struct GlimsHueSaturationRange {
  double hue;               /* finite -1..1, normalized 180-degree shift */
  double saturation;        /* finite -1..1 */
  double lightness;         /* finite -1..1 */
} GlimsHueSaturationRange;

typedef struct GlimsHueSaturationSettings {
  uint32_t struct_size;
  double overlap;           /* finite 0..1; default 0 */
  GlimsHueSaturationRange master;
  GlimsHueSaturationRange red;
  GlimsHueSaturationRange yellow;
  GlimsHueSaturationRange green;
  GlimsHueSaturationRange cyan;
  GlimsHueSaturationRange blue;
  GlimsHueSaturationRange magenta;
} GlimsHueSaturationSettings;

typedef struct GlimsLevelsChannel {
  double low_input;         /* finite 0..1; default 0 */
  double high_input;        /* finite 0..1; default 1 */
  double gamma;             /* finite 0.1..10; default 1 */
  double low_output;        /* finite 0..1; default 0 */
  double high_output;       /* finite 0..1; default 1 */
} GlimsLevelsChannel;

typedef struct GlimsLevelsSettings {
  uint32_t struct_size;
  uint32_t trc;             /* GlimsColorTRC: LINEAR/NONLINEAR/PERCEPTUAL; default LINEAR */
  uint32_t clamp_input;     /* exactly 0 or 1; default 0 */
  uint32_t clamp_output;    /* exactly 0 or 1; default 0 */
  GlimsLevelsChannel value;
  GlimsLevelsChannel red;
  GlimsLevelsChannel green;
  GlimsLevelsChannel blue;
  GlimsLevelsChannel alpha;
} GlimsLevelsSettings;

/* Owned Curves data, independent of native enums and object layouts. */
typedef enum GlimsCurveChannel {
  GLIMS_CURVE_CHANNEL_VALUE = 1,
  GLIMS_CURVE_CHANNEL_RED = 2,
  GLIMS_CURVE_CHANNEL_GREEN = 3,
  GLIMS_CURVE_CHANNEL_BLUE = 4,
  GLIMS_CURVE_CHANNEL_ALPHA = 5
} GlimsCurveChannel;

typedef enum GlimsCurveKind {
  GLIMS_CURVE_KIND_UNKNOWN = 0,
  GLIMS_CURVE_KIND_SMOOTH = 1,
  GLIMS_CURVE_KIND_FREE = 2
} GlimsCurveKind;

typedef enum GlimsCurvePointKind {
  GLIMS_CURVE_POINT_SMOOTH = 1,
  GLIMS_CURVE_POINT_CORNER = 2
} GlimsCurvePointKind;

/* Adapter resource limits, not limits of native Core's point representation. */
#define GLIMS_CURVE_MAX_POINTS 65536u
#define GLIMS_CURVE_SAMPLE_COUNT 256u

typedef struct GlimsCurvePoint {
  double x;
  double y;
  uint32_t kind;             /* GlimsCurvePointKind */
} GlimsCurvePoint;

typedef struct GlimsCurveState {
  uint32_t kind;             /* GlimsCurveKind */
  uint32_t identity;         /* exactly 0 or 1; native HDR bypass state */
  uint32_t point_count;
  GlimsCurvePoint *points;   /* owned, including hidden Free-mode points */
  uint32_t sample_count;     /* exactly GLIMS_CURVE_SAMPLE_COUNT */
  double *samples;           /* owned native generated/Free samples */
} GlimsCurveState;

typedef struct GlimsCurvesSnapshot {
  uint32_t struct_size;
  uint32_t trc;              /* GlimsColorTRC; new effects default PERCEPTUAL */
  GlimsCurveState value;
  GlimsCurveState red;
  GlimsCurveState green;
  GlimsCurveState blue;
  GlimsCurveState alpha;
} GlimsCurvesSnapshot;

typedef enum GlimsCurveEditMode {
  GLIMS_CURVE_EDIT_SMOOTH_POINTS = 1,
  GLIMS_CURVE_EDIT_FREE_SAMPLES = 2,
  GLIMS_CURVE_EDIT_RESET = 3
} GlimsCurveEditMode;

typedef struct GlimsCurveEdit {
  uint32_t struct_size;
  uint32_t channel;          /* GlimsCurveChannel */
  uint32_t mode;             /* GlimsCurveEditMode */
  uint32_t point_count;      /* Smooth: 0..MAX, finite ordered x/y in 0..1 */
  const GlimsCurvePoint *points;
  uint32_t sample_count;     /* Free: exactly SAMPLE_COUNT, finite 0..1 */
  const double *samples;
} GlimsCurveEdit;

/* Input histogram channels, independent of native enum ordering. */
typedef enum GlimsHistogramChannelFlag {
  GLIMS_HISTOGRAM_VALUE = 1u << 0,
  GLIMS_HISTOGRAM_RED = 1u << 1,
  GLIMS_HISTOGRAM_GREEN = 1u << 2,
  GLIMS_HISTOGRAM_BLUE = 1u << 3,
  GLIMS_HISTOGRAM_ALPHA = 1u << 4,
  GLIMS_HISTOGRAM_LUMINANCE = 1u << 5
} GlimsHistogramChannelFlag;

#define GLIMS_HISTOGRAM_MAX_BINS 4096u

typedef struct GlimsHistogramSnapshot {
  uint32_t struct_size;
  uint32_t trc;              /* owned GlimsColorTRC from the filter config */
  uint32_t bin_count;        /* native256(u8)/1024(other);0 for no intersection */
  uint32_t channels;         /* GlimsHistogramChannelFlag bitset */
  double *value;
  double *red;
  double *green;
  double *blue;
  double *alpha;
  double *luminance;
} GlimsHistogramSnapshot;

/* A layer's mask flags: ENABLED gates the mask's effect on the
 * composite; EDITING makes the mask the target of painting, fills and
 * gradients while its layer is the only selected one; SHOWING displays
 * the mask itself instead of the composite. The bits layer_mask_set's
 * `flags` names and `values` carries. */
typedef enum GlimsMaskFlag {
  GLIMS_MASK_ENABLED = 1 << 0,
  GLIMS_MASK_EDITING = 1 << 1,
  GLIMS_MASK_SHOWING = 1 << 2
} GlimsMaskFlag;

/* What a new layer mask is made from, as the engine's Add Layer Mask
 * choices. */
typedef enum GlimsMaskSource {
  GLIMS_MASK_WHITE          = 1,  /* fully opaque mask */
  GLIMS_MASK_BLACK          = 2,  /* fully transparent mask */
  GLIMS_MASK_ALPHA          = 3,  /* the layer's alpha channel */
  GLIMS_MASK_ALPHA_TRANSFER = 4,  /* the layer's alpha; the layer turns opaque */
  GLIMS_MASK_SELECTION      = 5,  /* the current selection */
  GLIMS_MASK_GRAYSCALE      = 6   /* a grayscale copy of the layer */
} GlimsMaskSource;

/* What layer_mask_apply does with a mask. */
typedef enum GlimsMaskApply {
  GLIMS_MASK_APPLY   = 1,  /* bakes the mask into the layer, then removes it */
  GLIMS_MASK_DISCARD = 2   /* removes the mask without applying it */
} GlimsMaskApply;

/* A layer's mask state; `mask` is the mask's drawable id, usable as the
 * drawable argument of stroke_begin and drawable_thumbnail, or 0 when
 * the layer has no mask. */
typedef struct GlimsMaskState {
  GlimsItemID mask;
  bool        enabled;
  bool        editing;
  bool        showing;
} GlimsMaskState;

/* The components of the image's color model: the bits image_components
 * reports and image_set_components takes. RED/GREEN/BLUE apply to RGB
 * images, GRAY to grayscale, INDEXED to indexed; ALPHA applies wherever
 * the image currently has an alpha component. */
typedef enum GlimsComponent {
  GLIMS_COMPONENT_RED     = 1 << 0,
  GLIMS_COMPONENT_GREEN   = 1 << 1,
  GLIMS_COMPONENT_BLUE    = 1 << 2,
  GLIMS_COMPONENT_ALPHA   = 1 << 3,
  GLIMS_COMPONENT_GRAY    = 1 << 4,
  GLIMS_COMPONENT_INDEXED = 1 << 5
} GlimsComponent;

/* The image's color model, as image_components reports it. */
typedef enum GlimsComponentMode {
  GLIMS_COMPONENT_MODE_RGB     = 1,
  GLIMS_COMPONENT_MODE_GRAY    = 2,
  GLIMS_COMPONENT_MODE_INDEXED = 3
} GlimsComponentMode;

/* `supported` is the components the image's model actually has;
 * `active` the ones painting and fills write to; `visible` the ones the
 * composite shows. `active` and `visible` cover `supported` bits only. */
typedef struct GlimsComponentState {
  uint32_t mode;       /* GlimsComponentMode */
  uint32_t supported;  /* GlimsComponent bits */
  uint32_t active;
  uint32_t visible;
} GlimsComponentState;

/* One row of the image's channel list, top first: saved selection
 * channels plus the Quick Mask's channel while it is on. `id` is a
 * drawable id, valid for stroke_begin, drawable_thumbnail and the
 * channel calls. A channel stores single-component coverage; `color`
 * and `opacity` describe only how it renders as an overlay. */
typedef struct GlimsChannelInfo {
  GlimsItemID id;
  char        name[256];   /* UTF-8, truncated */
  bool        visible;     /* composited over the image as an overlay:
                            * channels saved from a selection tint the
                            * masked-out region with `color`, like the
                            * Quick Mask does */
  bool        selected;    /* a selected channel is the edit target,
                            * in preference to the selected layers */
  bool        quick_mask;  /* the Quick Mask's own channel */
  double      opacity;     /* overlay opacity, 0 ... 1 — the color's alpha */
  GlimsColor  color;       /* overlay color; its alpha IS `opacity` */
} GlimsChannelInfo;

/* Which fields of GlimsChannelChange apply. */
typedef enum GlimsChannelProperty {
  GLIMS_CHANNEL_NAME    = 1 << 0,
  GLIMS_CHANNEL_VISIBLE = 1 << 1,
  GLIMS_CHANNEL_OPACITY = 1 << 2,
  GLIMS_CHANNEL_COLOR   = 1 << 3
} GlimsChannelProperty;

typedef struct GlimsChannelChange {
  uint32_t   struct_size;  /* sizeof (GlimsChannelChange) */
  uint32_t   properties;   /* GlimsChannelProperty bits */
  char       name[256];    /* UTF-8; empty restores the default name */
  bool       visible;
  double     opacity;      /* 0 ... 1 */
  GlimsColor color;
} GlimsChannelChange;

typedef enum GlimsChannelCommand {
  GLIMS_CHANNEL_SELECT    = 1,  /* make it the image's selected channel; a
                                 * `channel` of 0 selects the layers again */
  GLIMS_CHANNEL_DUPLICATE = 2,  /* `result` (may be NULL) receives the copy */
  GLIMS_CHANNEL_DELETE    = 3   /* INVALID_ARGUMENT on the Quick Mask's channel */
} GlimsChannelCommand;

/* Whether the image's selection is being shown and edited as a mask,
 * that mask's channel id (0 while off) and its overlay style. */
typedef struct GlimsQuickMaskState {
  bool        enabled;
  GlimsItemID channel;   /* the mask channel, a valid drawable id, while enabled */
  bool        inverted;
  GlimsColor  color;     /* overlay color; alpha is its opacity */
} GlimsQuickMaskState;

/* One row of a drawable's committed filter stack, top first — the order
 * the engine's own layer effects editor shows, in which the top effect
 * is applied last. `id` is the engine's drawable-filter id: stable for
 * the filter's life while the image is open, including across undo and
 * redo of a removal or reorder; a reopened file always gets new ids.
 * Only committed effects are listed — a live filter_begin preview is
 * not one, and neither is an effect that is merely held by the undo
 * stack. Drawables that cannot keep effects (layer masks, the Quick
 * Mask's channel, and channels on engines whose XCF does not serialize
 * them) report an empty list. */
typedef struct GlimsEffectInfo {
  GlimsEffectID id;
  char          name[256];      /* UTF-8, truncated; the operation's
                                 * default title unless renamed */
  char          operation[128]; /* e.g. "gegl:value-invert" */
  bool          enabled;        /* the effect's on/off switch; a disabled
                                 * effect stays on the stack but does
                                 * not change the drawable */
  double        opacity;        /* 0 ... 1 */
} GlimsEffectInfo;

/* Which fields of GlimsEffectChange apply. */
typedef enum GlimsEffectProperty {
  GLIMS_EFFECT_NAME    = 1 << 0,
  GLIMS_EFFECT_ENABLED = 1 << 1,
  GLIMS_EFFECT_OPACITY = 1 << 2
} GlimsEffectProperty;

typedef struct GlimsEffectChange {
  uint32_t struct_size;  /* sizeof (GlimsEffectChange) */
  uint32_t properties;   /* GlimsEffectProperty bits */
  char     name[256];    /* UTF-8; empty restores the operation's default name */
  bool     enabled;
  double   opacity;      /* 0 ... 1 */
} GlimsEffectChange;

typedef enum GlimsEffectCommand {
  GLIMS_EFFECT_REMOVE    = 1,  /* drop the effect from the stack; undo
                                * restores it with its id and position */
  GLIMS_EFFECT_MERGE     = 2,  /* bake the effect into the drawable's
                                * pixels and drop it; other effects stay
                                * non-destructive. INVALID_ARGUMENT on
                                * layers whose pixels are structured
                                * content (groups, text, link and vector
                                * layers), and on disabled effects */
  GLIMS_EFFECT_RAISE     = 3,  /* one step toward the top of the stack */
  GLIMS_EFFECT_LOWER     = 4,  /* one step toward the bottom */
  GLIMS_EFFECT_TO_TOP    = 5,
  GLIMS_EFFECT_TO_BOTTOM = 6
} GlimsEffectCommand;

/* The image's color model, as image_color_info reports it and
 * image_convert_mode takes. Facade-owned values only; the engine's own
 * enum never crosses this boundary. */
typedef enum GlimsColorMode {
  GLIMS_COLOR_MODE_UNKNOWN   = 0,
  GLIMS_COLOR_MODE_RGB       = 1,
  GLIMS_COLOR_MODE_GRAYSCALE = 2,
  GLIMS_COLOR_MODE_INDEXED   = 3
} GlimsColorMode;

/* The component type of the image's precision. */
typedef enum GlimsColorComponent {
  GLIMS_COLOR_COMPONENT_UNKNOWN = 0,
  GLIMS_COLOR_COMPONENT_U8      = 1,
  GLIMS_COLOR_COMPONENT_U16     = 2,
  GLIMS_COLOR_COMPONENT_U32     = 3,
  GLIMS_COLOR_COMPONENT_HALF    = 4,
  GLIMS_COLOR_COMPONENT_FLOAT   = 5,
  GLIMS_COLOR_COMPONENT_DOUBLE  = 6
} GlimsColorComponent;

/* The transfer curve of the image's precision. */
typedef enum GlimsColorTRC {
  GLIMS_COLOR_TRC_UNKNOWN    = 0,
  GLIMS_COLOR_TRC_LINEAR     = 1,
  GLIMS_COLOR_TRC_NONLINEAR  = 2,
  GLIMS_COLOR_TRC_PERCEPTUAL = 3
} GlimsColorTRC;

/* Rendering intents owned by the facade, not native engine enum values. */
typedef enum GlimsProfileIntent {
  GLIMS_PROFILE_PERCEPTUAL = 1,
  GLIMS_PROFILE_RELATIVE_COLORIMETRIC = 2,
  GLIMS_PROFILE_SATURATION = 3,
  GLIMS_PROFILE_ABSOLUTE_COLORIMETRIC = 4
} GlimsProfileIntent;

/* Display-only soft proofing options. These are facade-owned values;
 * native color-transform flags and rendering-intent values never cross
 * the facade. A separate render slot means proofing is enabled. */
typedef enum GlimsProofFlags {
  GLIMS_PROOF_BLACK_POINT_COMPENSATION = 1u
} GlimsProofFlags;

typedef struct GlimsProofSettings {
  uint32_t struct_size;     /* >= sizeof(GlimsProofSettings); future tail ignored */
  uint32_t proof_intent;    /* GlimsProfileIntent */
  uint32_t display_intent;  /* GlimsProfileIntent */
  uint32_t flags;           /* GlimsProofFlags; unknown bits are invalid */
} GlimsProofSettings;

/* The image's color state. Caller-owned: image_color_info fills the
 * struct in place; the fixed buffers are UTF-8, truncated, and need no
 * release. `component` and `trc` together are the image's precision;
 * GlimsImageInfo.precision keeps reporting it as the engine's nick
 * string (e.g. "u8-perceptual"). `profile_label` is the effective
 * profile's label — the image's own when it has one, the engine's
 * builtin fallback otherwise — and `profile_embedded` says whether an
 * ICC profile travels with the image (and so with its files). */
typedef struct GlimsColorInfo {
  uint32_t mode;             /* GlimsColorMode */
  uint32_t component;        /* GlimsColorComponent */
  uint32_t trc;              /* GlimsColorTRC */
  bool     profile_embedded;
  char     profile_label[256];  /* UTF-8, truncated; "" when none */
} GlimsColorInfo;

/* The palette an indexed conversion builds, as image_convert_indexed's
 * settings name it. Facade-owned values; the engine's
 * GimpConvertPaletteType never crosses this boundary. */
typedef enum GlimsIndexedPalette {
  GLIMS_INDEXED_PALETTE_GENERATED = 1,  /* quantize to the image's own
                                         * colors, at most `max_colors` */
  GLIMS_INDEXED_PALETTE_WEB       = 2,  /* the fixed 216-color web palette */
  GLIMS_INDEXED_PALETTE_MONO      = 3,  /* black and white */
  GLIMS_INDEXED_PALETTE_CUSTOM    = 4   /* the call's own `colors` list */
} GlimsIndexedPalette;

/* How an indexed conversion dithers, as image_convert_indexed's
 * settings name it. Facade-owned values; the engine's
 * GimpConvertDitherType never crosses this boundary. FIXED is the
 * engine's built-in positioned (ordered) matrix. */
typedef enum GlimsIndexedDither {
  GLIMS_INDEXED_DITHER_NONE         = 1,
  GLIMS_INDEXED_DITHER_FS           = 2,  /* Floyd-Steinberg */
  GLIMS_INDEXED_DITHER_FS_LOW_BLEED = 3,  /* Floyd-Steinberg, reduced bleeding */
  GLIMS_INDEXED_DITHER_FIXED        = 4   /* positioned/ordered matrix */
} GlimsIndexedDither;

/* What image_convert_indexed does when the image holds a genuine
 * editable text, vector or link layer the conversion would rasterize. */
typedef enum GlimsIndexedPreservation {
  GLIMS_INDEXED_PRESERVE_EDITABLE = 1,  /* refuse; nothing changes */
  GLIMS_INDEXED_ALLOW_RASTERIZE   = 2   /* rasterize them inside the
                                         * conversion's one undo step;
                                         * their sources are retained */
} GlimsIndexedPreservation;

/* How image_convert_indexed quantizes, validated as a whole before any
 * mutation. `max_colors` applies only to GENERATED (2 ... 256) and is
 * ignored otherwise. `remove_unused` asks the engine to drop unused and
 * duplicate colormap entries; the engine honors it for WEB and CUSTOM
 * and ignores it for GENERATED and MONO. `dither_alpha` also dithers
 * partially transparent pixels. `dither_text` quantizes genuine text
 * layers' pixels with dithering like any raster layer; with it false a
 * text layer is re-rendered in indexed format and stays editable.
 * `preservation` is a GlimsIndexedPreservation. */
typedef struct GlimsIndexedSettings {
  uint32_t struct_size;        /* sizeof (GlimsIndexedSettings) */
  uint32_t palette;            /* GlimsIndexedPalette */
  int32_t  max_colors;
  bool     remove_unused;
  uint32_t dither;             /* GlimsIndexedDither */
  bool     dither_alpha;
  bool     dither_text;
  uint32_t preservation;       /* GlimsIndexedPreservation */
} GlimsIndexedSettings;

/* Brushes, patterns and gradients. These are the facade's own kind
 * values; the engine's own enums never cross this boundary. */
typedef enum GlimsResourceKind {
  GLIMS_RESOURCE_BRUSH    = 1,
  GLIMS_RESOURCE_PATTERN  = 2,
  GLIMS_RESOURCE_GRADIENT = 3
} GlimsResourceKind;

/* A handle to one brush, pattern or gradient. It is opaque and valid
 * only for the running engine that issued it in this session: a handle
 * carried across a restart resolves to nothing. 0 means none. */
typedef uint64_t GlimsResourceID;

/* A handle to one of an image's guides, issued by guide_put and reported
 * by image_guides. It names the guide while the image keeps it, including
 * across undo and redo of its removal or move; a reopened file always
 * gets new ids. 0 means none, and guide_put takes it to create. */
typedef int32_t GlimsGuideID;

/* Which axis an image guide sits on. Facade-owned values mapped to the
 * engine's orientation constants inside the adapter; the native enum
 * never crosses this boundary. A guide's orientation is fixed at
 * creation — guide_put never reorients an existing guide. */
typedef enum GlimsGuideOrientation {
  GLIMS_GUIDE_HORIZONTAL = 1,  /* a horizontal line, `position` on the y axis */
  GLIMS_GUIDE_VERTICAL   = 2   /* a vertical line, `position` on the x axis */
} GlimsGuideOrientation;

/* One row of the image_guides() list, and the change guide_put()
 * applies. `position` is in image pixels on the guide's axis: the y
 * coordinate of a horizontal guide, the x coordinate of a vertical one. */
typedef struct GlimsGuideInfo {
  GlimsGuideID id;
  uint32_t     orientation;  /* GlimsGuideOrientation */
  int32_t      position;     /* 0 ... image height (horizontal) or
                              * 0 ... image width (vertical) */
} GlimsGuideInfo;

/* How the image's display grid renders its lines. Facade-owned values
 * mapped to the engine's named GimpGridStyle constants inside the
 * adapter; the native enum value never crosses this boundary. */
typedef enum GlimsGridStyle {
  GLIMS_GRID_DOTS          = 1,  /* dots at the intersections */
  GLIMS_GRID_INTERSECTIONS = 2,  /* crosshairs at the intersections */
  GLIMS_GRID_ON_OFF_DASH   = 3,  /* single dashed lines */
  GLIMS_GRID_DOUBLE_DASH   = 4,  /* double dashed lines (bgcolor shows) */
  GLIMS_GRID_SOLID         = 5   /* solid lines */
} GlimsGridStyle;

/* The image's display grid, as image_grid reports it and image_set_grid
 * applies. Size-versioned: the caller sets `struct_size` to
 * sizeof (GlimsGrid) before a call and the adapter refuses a smaller
 * one. Spacings and offsets are in the grid's own (unexposed) unit —
 * the engine's default on a fresh image — as the native "xspacing",
 * "yspacing", "xoffset" and "yoffset" properties hold them; the
 * native bounds apply: spacings must be finite and > 0 up to the
 * native maximum, offsets finite inside the native signed range.
 * The colors are non-linear sRGB, 0 ... 1, alpha included. */
typedef struct GlimsGrid {
  uint32_t   struct_size;   /* sizeof (GlimsGrid) */
  uint32_t   style;         /* GlimsGridStyle */
  double     spacing_x;     /* > 0, <= the native "xspacing" maximum */
  double     spacing_y;     /* > 0, <= the native "yspacing" maximum */
  double     offset_x;      /* inside the native "xoffset" signed range */
  double     offset_y;      /* inside the native "yoffset" signed range */
  GlimsColor foreground;    /* sRGB 0 ... 1, alpha included */
  GlimsColor background;    /* sRGB 0 ... 1, alpha included; double-dash only */
} GlimsGrid;

/* One row of the resources() list, in the engine's own order. */
typedef struct GlimsResourceInfo {
  GlimsResourceID id;
  uint32_t        kind;      /* GlimsResourceKind */
  char            name[256]; /* display label, UTF-8, truncated at a
                              * character boundary */
} GlimsResourceInfo;

/* What a floating selection (a Paste Into result before it resolves) is
 * attached to. Facade-owned values mapped to the engine's own classes
 * inside the adapter; the native classes never cross this boundary. */
typedef enum GlimsFloatingTargetKind {
  GLIMS_FLOATING_TARGET_LAYER      = 1,  /* a layer (a plain pixel layer or an already rasterized text/link/vector instance) */
  GLIMS_FLOATING_TARGET_LAYER_MASK = 2,  /* a layer's mask */
  GLIMS_FLOATING_TARGET_CHANNEL    = 3   /* a saved channel (or the Quick Mask's channel) */
} GlimsFloatingTargetKind;

/* The image's floating-selection state, as image_floating_selection
 * reports it. Size-versioned: the caller sets `struct_size` to
 * sizeof (GlimsFloatingState) before a call and the adapter refuses a
 * smaller one. */
typedef struct GlimsFloatingState {
  uint32_t     struct_size;   /* sizeof (GlimsFloatingState) */
  bool         active;       /* a floating selection exists */
  GlimsItemID  floating;     /* the floating layer's id; 0 when !active */
  GlimsItemID  target;       /* the drawable it is attached to; 0 when !active */
  uint32_t     target_kind;  /* GlimsFloatingTargetKind; 0 when !active */
} GlimsFloatingState;

/* How floating_command resolves a floating selection. Facade-owned
 * values; the native verbs are mapped inside the adapter only. */
typedef enum GlimsFloatingCommand {
  GLIMS_FLOATING_ANCHOR   = 1,  /* merge the floating layer into its target */
  GLIMS_FLOATING_TO_LAYER = 2,  /* detach it as an independent layer */
  GLIMS_FLOATING_DISCARD  = 3   /* remove it without merging */
} GlimsFloatingCommand;

/* How selection_float takes the selected pixels off their target:
 * MOVE cuts them out of it (the target keeps a transparent hole where
 * the selection was), COPY leaves the target's pixels untouched.
 * Facade-owned values; the native cut_image boolean never crosses this
 * boundary. */
typedef enum GlimsFloatMode {
  GLIMS_FLOAT_MOVE = 1,
  GLIMS_FLOAT_COPY = 2
} GlimsFloatMode;

/* An image-metadata domain (EXIF, IPTC or XMP), as image_metadata_tags
 * takes it. Facade-owned values; the native domain prefixes never cross
 * this boundary. */
typedef enum GlimsMetadataDomain {
  GLIMS_METADATA_EXIF = 1,  /* tags named "Exif.…" */
  GLIMS_METADATA_IPTC = 2,  /* tags named "Iptc.…" */
  GLIMS_METADATA_XMP  = 3   /* tags named "Xmp.…" */
} GlimsMetadataDomain;

/* What image_metadata_edit does to one tag. Facade-owned values. */
typedef enum GlimsMetadataEdit {
  GLIMS_METADATA_SET    = 1,  /* replace the tag's whole value list */
  GLIMS_METADATA_REMOVE = 2   /* erase the tag */
} GlimsMetadataEdit;

/* How many values one registered tag holds natively, as
 * image_metadata_tag_info classifies it. Facade-owned values; the native
 * type names never cross this boundary as enums — the native type name
 * itself is reported as the bounded `type_name` string of
 * GlimsMetadataTagInfo. */
typedef enum GlimsMetadataValueKind {
  GLIMS_METADATA_VALUE_SINGLE     = 1, /* one value: every Exif tag, non-repeatable Iptc, XmpText */
  GLIMS_METADATA_VALUE_REPEATABLE = 2, /* repeatable Iptc: many values, no container */
  GLIMS_METADATA_VALUE_BAG        = 3, /* XmpBag: unordered array */
  GLIMS_METADATA_VALUE_SEQ        = 4, /* XmpSeq: ordered array */
  GLIMS_METADATA_VALUE_ALT        = 5, /* XmpAlt: unordered alternatives */
  GLIMS_METADATA_VALUE_LANG_ALT   = 6  /* LangAlt: xml:lang-qualified alternatives */
} GlimsMetadataValueKind;

/* The TYPE/FORMAT policy of one tag, as image_metadata_tag_info reports
 * it in GlimsMetadataTagInfo.format_policy. These bits mirror exactly
 * the refusals image_metadata_edit makes before any mutation: a tag the
 * native setter rewrites from the image's own state and a LangAlt tag
 * refuse both operations (no bits); an XMP container (Bag/Seq/Alt) the
 * image does not hold cannot be SET (a new container needs a chosen
 * array type) but REMOVE stays allowed as a no-op. The bits express
 * TYPE/FORMAT POLICY ONLY: an actual edit can still refuse with BUSY,
 * LOCKED, a copy-preservation guard or other native validation, so a set
 * bit never promises a write will succeed. */
typedef enum GlimsMetadataFormatPolicy {
  GLIMS_METADATA_FORMAT_SUPPORTS_SET    = 1 << 0,
  GLIMS_METADATA_FORMAT_SUPPORTS_REMOVE = 1 << 1
} GlimsMetadataFormatPolicy;

/* Capacities, including the NUL terminator, of GlimsMetadataTagInfo's
 * bounded UTF-8 strings. The adapter truncates them at most to
 * capacity - 1 bytes, never inside a multi-byte UTF-8 character, and
 * always NUL-terminates; native bytes that are not valid UTF-8 are
 * refused, never copied. */
#define GLIMS_METADATA_TAG_INFO_LABEL_CAPACITY       256u
#define GLIMS_METADATA_TAG_INFO_DESCRIPTION_CAPACITY 512u
#define GLIMS_METADATA_TAG_INFO_TYPE_NAME_CAPACITY   64u

/* A READ-ONLY descriptor of one registered metadata tag, as
 * image_metadata_tag_info reports it (slot 128). Set struct_size to
 * sizeof (GlimsMetadataTagInfo) before the call; the adapter refuses a
 * NULL or smaller struct before writing anything and resets the struct
 * to a safe all-zero descriptor on every later failure. */
typedef struct GlimsMetadataTagInfo {
  uint32_t struct_size;       /* sizeof (GlimsMetadataTagInfo) */
  bool     present;           /* the image's metadata currently holds the tag */
  bool     supports_multiple; /* the tag can hold several values natively */
  uint32_t value_kind;        /* GlimsMetadataValueKind */
  uint32_t format_policy;     /* GlimsMetadataFormatPolicy bits; policy only, see above */
  char     label[GLIMS_METADATA_TAG_INFO_LABEL_CAPACITY];            /* native tag label, UTF-8, bounded */
  char     description[GLIMS_METADATA_TAG_INFO_DESCRIPTION_CAPACITY];/* native tag description, UTF-8, bounded */
  char     type_name[GLIMS_METADATA_TAG_INFO_TYPE_NAME_CAPACITY];    /* native type name, UTF-8, bounded */
} GlimsMetadataTagInfo;

/* One owned (language, text) pair of a language-alternative (XMP LangAlt)
 * map, as image_metadata_languages (slot 139) reports it. The language
 * spelling is preserved exactly (case folding only for uniqueness); the
 * text is the exact rdf:li content, no trimming. Facade-owned; no GLib
 * or GIMP types cross this boundary. The array returned by slot 139 is
 * `count` of these plus one all-NULL sentinel pair, released with slot
 * 140 (never free_string). */
typedef struct GlimsMetadataLanguageValue {
  char *language;
  char *text;
} GlimsMetadataLanguageValue;

/* Saved sets (the engine's stored item sets), READ-ONLY. The facade lists
 * the FIXED (non-pattern) sets only, of three kinds, and resolves members
 * through an opaque identity token — never through a name, a pointer or
 * a native type. All values here are the facade's own; no GType, struct
 * layout or raw pointer ever crosses this boundary. */
typedef enum GlimsItemSetKind {
  GLIMS_ITEM_SET_LAYER   = 1,
  GLIMS_ITEM_SET_CHANNEL = 2,
  GLIMS_ITEM_SET_PATH    = 3
} GlimsItemSetKind;

/* One row of image_item_sets (slot 133). */
typedef struct GlimsItemSetInfo {
  uint64_t token;             /* opaque stable identity of this set within
                               * the engine; 0 is never issued. Tokens are
                               * NOT names: a set recreated under the same
                               * name gets a new token, and an expired
                               * token is never retargeted. */
  uint32_t kind;              /* GlimsItemSetKind */
  int32_t  member_count;      /* LIVE members: members currently attached to
                               * this image right now (deleted or detached
                               * weak members are not counted) */
  char     display_name[256]; /* UTF-8, truncated at a character boundary for
                               * display only; the name is never the identity
                               * — resolve members through `token` */
} GlimsItemSetInfo;

/* One edit operation of image_item_set_edit (slot 135); see the slot's
 * comment below for the per-op argument contract. Facade-owned. */
typedef enum GlimsItemSetEditOp {
  GLIMS_ITEM_SET_EDIT_CREATE  = 1,
  GLIMS_ITEM_SET_EDIT_REPLACE = 2,
  GLIMS_ITEM_SET_EDIT_RENAME  = 3,
  GLIMS_ITEM_SET_EDIT_REMOVE  = 4
} GlimsItemSetEditOp;

typedef enum GlimsResourceMutationFlag {
  GLIMS_RESOURCE_CAN_RENAME = 1u << 0,
  GLIMS_RESOURCE_CAN_DELETE = 1u << 1
} GlimsResourceMutationFlag;

typedef struct GlimsEngineAPI {
  uint32_t api_version;     /* GLIMS_ENGINE_API_VERSION of the library */
  uint32_t struct_size;     /* sizeof (GlimsEngineAPI) of the library */

  GlimsStatus  (*start)            (const GlimsEngineConfig *config,
                                    GlimsEngine            **engine,
                                    char                   **error);
  /* One external owner calls stop once, after preventing new engine-call
   * submissions. Already registered callers drain before their control
   * storage is freed. Do not race a new call's initial entry with stop;
   * the engine pointer is invalid after stop returns. Event callbacks
   * must not call stop (or any other engine function). */
  void         (*stop)             (GlimsEngine *engine);
  void         (*free_string)      (char *string);
  /* "3.2.0" and so on; valid while the engine runs. */
  const char * (*engine_version)   (GlimsEngine *engine);

  GlimsStatus  (*image_new)        (GlimsEngine *engine, int32_t width, int32_t height,
                                    GlimsImageID *image, char **error);
  GlimsStatus  (*image_open)       (GlimsEngine *engine, const char *path,
                                    GlimsImageID *image, char **error);
  /* BUSY while a native file load owns a nested engine loop. The image
   * stays alive on refusal; retry after the load unwinds. */
  GlimsStatus  (*image_close)      (GlimsEngine *engine, GlimsImageID image);
  GlimsStatus  (*image_info)       (GlimsEngine *engine, GlimsImageID image,
                                    GlimsImageInfo *info);
  /* Renders the composited image at `scale` (1.0 = one image pixel per
   * output pixel). `area` is in scaled pixel coordinates. Writes
   * area.width * area.height pixels of premultiplied 8-bit sRGB RGBA.
   * Supported scale: 2^-20 ... 32. Unscaled request edges must be within
   * +/- 2^26 pixels to bound GEGL sampling arithmetic. */
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
   * applies it as one undo step; abort leaves no trace. `drawable` may
   * be a layer, a layer mask, a saved channel or the Quick Mask's
   * channel; the image's selection mask reports INVALID_ARGUMENT.
   * Commit keeps the filter on the drawable non-destructively where XCF
   * keeps such filters — layers, and saved channels on GIMP 3.2.6+,
   * whose XCF writer serializes channel effects — and merges it into
   * the pixels elsewhere: layer masks, the Quick Mask's channel, and
   * saved channels on earlier engines. Either way the result is one
   * undo step and survives save and reopen. */
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
  /* Native layered copy without changing the source image's file,
   * imported/exported identity, dirty state or undo history. */
  GlimsStatus (*image_save_copy)(GlimsEngine *, GlimsImageID, const char *path, char **error);
  /* One alpha layer, no synthetic white background and an empty undo stack.
   * The new image is unsaved; pixel limits match image_paste_pixels. */
  GlimsStatus (*image_from_pixels)(GlimsEngine *, int32_t width, int32_t height,
                                   const uint8_t *pixels, size_t byte_count, GlimsImageID *, char **error);

  /* The layer tree's structure: groups, moving layers between groups,
   * and the layers' locks. `layer`/`item` 0 means the selected layer;
   * `parent`/`new_parent` 0 the image's top level, otherwise a group of
   * the same image. */
  /* `state` receives the layer's own and its effective locks. */
  GlimsStatus  (*layer_state)      (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                    GlimsLayerState *state);
  /* Adds a layer group named `name` (NULL: the engine's default name) at
   * `index` among `parent`'s children, pass-through and selected, as one
   * undo step. `result` (may be NULL) receives it. NOT_FOUND for a
   * `parent` that is not an attached layer of the image; INVALID_ARGUMENT
   * for a `parent` that is not a group or an out-of-range `index`. */
  GlimsStatus  (*create_group)     (GlimsEngine *engine, GlimsImageID image, GlimsItemID parent,
                                    int32_t index, const char *name, GlimsItemID *result,
                                    char **error);
  /* Moves `item` to `index` among `new_parent`'s children as one undo
   * step; undo and redo restore the exact position. NOT_FOUND for an
   * `item` or `new_parent` that is not an attached layer of the image;
   * INVALID_ARGUMENT when `new_parent` is `item` or its descendant, not
   * a group, or `index` is out of range. */
  GlimsStatus  (*reparent_layer)   (GlimsEngine *engine, GlimsImageID image, GlimsItemID item,
                                    GlimsItemID new_parent, int32_t index, char **error);
  /* Sets the GlimsLayerLock bits selected by `mask` to `values`'s bits
   * as one undo step; locks outside `mask` keep their state.
   * INVALID_ARGUMENT for an empty `mask` or bits that are no lock. */
  GlimsStatus  (*set_layer_locks)  (GlimsEngine *engine, GlimsImageID image, GlimsItemID item,
                                    uint32_t mask, uint32_t values, char **error);

  /* Filter discovery and typed live parameters, for native filter forms.
   *
   * The operations that can back a non-destructive filter, sorted by
   * name. `support` says whether a native form can drive the operation;
   * auxiliary-input and config-object operations are listed but flagged
   * as unsupported. `count` receives the total. */
  GlimsStatus  (*filter_operations)(GlimsEngine *engine, GlimsOperationInfo *rows,
                                    int32_t capacity, int32_t *count);
  /* One operation's editable properties in declaration order; pads and
   * read-only properties are omitted. `count` receives the total.
   * INVALID_ARGUMENT for an unknown operation or one that cannot back a
   * non-destructive filter. */
  GlimsStatus  (*filter_operation_properties)(GlimsEngine *engine, const char *operation,
                                              GlimsFilterProperty *rows, int32_t capacity,
                                              int32_t *count);
  /* An ENUM property's valid nicks and labels; `count` receives the
   * total. NOT_FOUND for an unknown property; INVALID_ARGUMENT when the
   * property is not an enum. */
  GlimsStatus  (*filter_enum_choices)(GlimsEngine *engine, const char *operation,
                                      const char *property, GlimsFilterEnumChoice *rows,
                                      int32_t capacity, int32_t *count);
  /* Reads one property of an open filter session; `value->kind` receives
   * the property's kind. NOT_FOUND for an unknown property or a finished
   * session; INVALID_ARGUMENT for a pad, read-only or unsupported-kind
   * property. */
  GlimsStatus  (*filter_get_property)(GlimsEngine *engine, GlimsFilterID filter,
                                      const char *property, GlimsFilterValue *value);
  /* Sets one property of an open filter session; the preview updates.
   * `value->kind` must match the property's kind. Numbers must be finite
   * and inside the absolute bounds, integers inside them too, enum nicks
   * one of filter_enum_choices() and color channels finite inside
   * 0...1. NOT_FOUND for an unknown property or a finished session;
   * INVALID_ARGUMENT for pad, read-only or unsupported-kind properties
   * and failed validation; BUSY while a plug-in runs; LOCKED if the
   * target acquires a pixel lock. No undo step is added;
   * filter_commit() covers the session's changes as one. */
  GlimsStatus  (*filter_set_property)(GlimsEngine *engine, GlimsFilterID filter,
                                      const char *property, const GlimsFilterValue *value);

  /* Reads a consistent history snapshot; rows may be NULL to query count.
   * The first row is the earliest state still retained by the engine. */
  GlimsStatus  (*image_history) (GlimsEngine *engine, GlimsImageID image,
                                 GlimsHistoryRow *rows, int32_t capacity, GlimsHistoryInfo *info);
  /* Moves through native undo/redo to a state from image_history(). A stale
   * revision or invalid position is refused without changing the image.
   * BUSY while editing, a preview or a plug-in is active. */
  GlimsStatus  (*image_history_move) (GlimsEngine *engine, GlimsImageID image,
                                      uint64_t revision, int32_t position, char **error);
  /* Creates an independent unsaved image snapshot, including native layer
   * structure, filters, channels, paths and color state, with no undo history.
   * Source file identity, pixels and history remain unchanged. BUSY during
   * pending edits, a preview or a plug-in. */
  GlimsStatus  (*image_duplicate) (GlimsEngine *engine, GlimsImageID image,
                                   GlimsImageID *result, char **error);

  /* Layer masks. `layer` 0 means the selected layer. Adding a mask,
   * setting its flags and applying or discarding it are each one undo
   * step, except that EDITING alone adds none (the engine keeps no undo
   * for the edit target). Mask changes report BUSY while a stroke, a
   * filter preview or a plug-in is running. */
  /* Reads `layer`'s mask state; `state->mask` is 0 when it has none. */
  GlimsStatus  (*layer_mask)      (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                   GlimsMaskState *state);
  /* Adds a mask made from `source` (a GlimsMaskSource) to `layer`;
   * `mask` (may be NULL) receives its drawable id. With `edit` the mask
   * also becomes the edit target of painting, fills and gradients while
   * `layer` stays the only selected layer. FAILED when `layer` already
   * has a mask or is empty, INVALID_ARGUMENT for an unknown `source`. */
  GlimsStatus  (*layer_mask_add)  (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                   uint32_t source, bool edit, GlimsItemID *mask, char **error);
  /* Sets the GlimsMaskFlag bits named by `flags` to `values`'s bits;
   * flags outside `flags` keep their state. INVALID_ARGUMENT for an
   * empty `flags` or bits that are no mask flag; FAILED with no mask. */
  GlimsStatus  (*layer_mask_set)  (GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                   uint32_t flags, uint32_t values, char **error);
  /* Applies `layer`'s mask into the layer or discards it (`mode` is a
   * GlimsMaskApply). INVALID_ARGUMENT for APPLY on a group or a text,
   * link or vector layer, or for an unknown `mode`; LOCKED when a pixel
   * lock of the layer or a group containing it protects APPLY; FAILED
   * when `layer` has no mask. */
  GlimsStatus  (*layer_mask_apply)(GlimsEngine *engine, GlimsImageID image, GlimsItemID layer,
                                   uint32_t mode, char **error);
  /* Combines `layer`'s mask into the selection by `operation` (a
   * GlimsSelectOperation), as one undo step honoring the mask's offset.
   * FAILED when `layer` has no mask. */
  GlimsStatus  (*layer_mask_to_selection)(GlimsEngine *engine, GlimsImageID image,
                                          GlimsItemID layer, uint32_t operation, char **error);

  /* Renders `drawable` (a layer, layer mask or channel id) scaled down
   * to fit `max_size` x `max_size` image pixels, keeping its aspect
   * ratio and never up-scaling it. `width` and `height` receive the
   * written size; `pixels` receives `width * height * 4` bytes of
   * straight-alpha 8-bit sRGB RGBA, or may be NULL to query the size.
   * `max_size` is 1 ... 256. A layer group's thumbnail shows its
   * composited children, a mask's its gray levels as opaque gray. */
  GlimsStatus  (*drawable_thumbnail)(GlimsEngine *engine, GlimsImageID image,
                                     GlimsItemID drawable, int32_t max_size,
                                     uint8_t *pixels, size_t byte_count,
                                     int32_t *width, int32_t *height);

  /* Image components and channels: the color components of the image's
   * model, its saved selection channels, and the Quick Mask. All of it
   * is the engine's own state and behavior; CHANNELS_CHANGED reports
   * changes to the list, the selected channel, components and the Quick
   * Mask. Channel writes report BUSY while a stroke, a filter preview or
   * a plug-in is running; reads and channel selection are always
   * allowed. */
  /* `state` receives the components the image's color model has and
   * their active and visible masks. */
  GlimsStatus  (*image_components)     (GlimsEngine *engine, GlimsImageID image,
                                        GlimsComponentState *state);
  /* Sets the active and visible components the masks name to `values`'s
   * bits; bits outside the masks keep their state. Component changes are
   * not undo steps in the engine. Changing `active` unselects any
   * selected channel, back to layers (as the engine's component toggles
   * do). INVALID_ARGUMENT for mask bits that are no component or that
   * the image's color model lacks. */
  GlimsStatus  (*image_set_components) (GlimsEngine *engine, GlimsImageID image,
                                        uint32_t active_mask, uint32_t active_values,
                                        uint32_t visible_mask, uint32_t visible_values,
                                        char **error);
  /* The image's saved channels (and the Quick Mask's channel while it
   * is on); `count` receives the total. A visible channel composites
   * over the image: the engine's projection tints the channel's
   * masked-out region with its `color` and `opacity`, so image_render
   * shows it. */
  GlimsStatus  (*image_channels)       (GlimsEngine *engine, GlimsImageID image,
                                        GlimsChannelInfo *channels, int32_t capacity,
                                        int32_t *count);
  /* Saves the current selection as a new channel (Select > Save to
   * Channel): invisible by default, selected, one undo step. `name` may
   * be NULL or empty for the engine's default. The Quick Mask's channel
   * name is reserved — it is how the engine finds the mask — and is
   * INVALID_ARGUMENT here, after the engine's own normalization. */
  GlimsStatus  (*channel_from_selection)(GlimsEngine *engine, GlimsImageID image,
                                         const char *name, GlimsItemID *result, char **error);
  /* Changes a channel's name, visibility or overlay style; each applied
   * property is its own undo step. `color`'s alpha is the same overlay
   * opacity `opacity` sets: COLOR without OPACITY changes the opacity
   * through it, and OPACITY wins when both bits are set. The Quick
   * Mask's reserved channel name is refused for ordinary channels, and
   * renaming the mask's own channel is refused while the mask is on. */
  GlimsStatus  (*channel_change)       (GlimsEngine *engine, GlimsImageID image,
                                        GlimsItemID channel, const GlimsChannelChange *change,
                                        char **error);
  /* SELECT makes `channel` the image's selected channel — painting,
   * fills, gradients, copy and clear then act on it, not on the layers;
   * `channel` 0 returns the target to the layers. Selection itself is
   * not an undo step. DUPLICATE copies the channel and selects the copy,
   * DELETE removes it; each is one undo step. INVALID_ARGUMENT for an
   * unknown `command`. */
  GlimsStatus  (*channel_command)      (GlimsEngine *engine, GlimsImageID image,
                                        GlimsItemID channel, uint32_t command,
                                        GlimsItemID *result, char **error);
  /* Combines the channel into the selection by `operation` (a
   * GlimsSelectOperation), honoring the channel's offset, as one undo
   * step. INVALID_ARGUMENT for an unknown `operation`. */
  GlimsStatus  (*channel_to_selection) (GlimsEngine *engine, GlimsImageID image,
                                        GlimsItemID channel, uint32_t operation, char **error);
  /* The image's Quick Mask state. */
  GlimsStatus  (*image_quick_mask)     (GlimsEngine *engine, GlimsImageID image,
                                        GlimsQuickMaskState *state);
  /* Turns the Quick Mask on or off, as one undo step. Enabling moves the
   * current selection into the mask's channel and selects it as the
   * edit target; disabling converts the mask back to the selection and
   * restores the previously selected drawables. While it is on the
   * selection itself is empty and the composite shows the mask's red
   * overlay over the unselected area, as the core projects it. */
  GlimsStatus  (*image_set_quick_mask) (GlimsEngine *engine, GlimsImageID image,
                                        bool enabled, char **error);
  /* The drawable's committed non-destructive effects, top first as the
   * layer effects editor shows them; `count` receives the total. `rows`
   * may be NULL with `capacity` 0 to only count. */
  GlimsStatus  (*drawable_effects)     (GlimsEngine *engine, GlimsImageID image,
                                        GlimsItemID drawable, GlimsEffectInfo *rows,
                                        int32_t capacity, int32_t *count);
  /* Changes an effect's name, enabled state or opacity, as one undo
   * step no matter how many of the flagged properties actually differ.
   * Setting values the effect already holds changes nothing and pushes
   * no undo. */
  GlimsStatus  (*effect_change)        (GlimsEngine *engine, GlimsImageID image,
                                        GlimsItemID drawable, GlimsEffectID effect,
                                        const GlimsEffectChange *change, char **error);
  /* Runs one GlimsEffectCommand on the effect, as one undo step. The
   * effect id must name a committed effect of `drawable` — a stale,
   * foreign or preview id is NOT_FOUND and changes nothing. Move
   * commands that are already satisfied are no-ops that push no undo;
   * other invalid commands and errors leave everything untouched.
   * MERGE keeps the drawable's other effects non-destructive but is
   * refused where the drawable's pixels are structured content or its
   * content is locked. */
  GlimsStatus  (*effect_command)       (GlimsEngine *engine, GlimsImageID image,
                                        GlimsItemID drawable, GlimsEffectID effect,
                                        uint32_t command, char **error);

  /* File > Open as Layers: every layer of the file at `path` lands in
   * `image` above the selected layer — its own order, offsets relative
   * to the other imported layers, blend modes, masks and groups kept —
   * with the imported stack centered on the canvas, as one undo step,
   * and the imported layers selected. `layers` (may be NULL) receives
   * up to `capacity` of the added layer ids, top first; `count`
   * receives how many were added. The image's file identity, imported
   * file, precision and dirty state change only through the edit
   * itself, and the temporary load image leaves nothing behind.
   * Loading runs the engine's file plug-ins, so never call this on the
   * main thread; BUSY while a stroke, a filter preview or a plug-in
   * holds the engine. INVALID_ARGUMENT for a non-native path;
   * CANCELLED when the load is cancelled; a failed load adds nothing. */
  GlimsStatus  (*image_open_layers)    (GlimsEngine *engine, GlimsImageID image,
                                        const char *path,
                                        GlimsItemID *layers, int32_t capacity,
                                        int32_t *count, char **error);
  /* File > Place: puts `path` into `image` as a genuine link layer — it
   * keeps a reference to the source file, re-renders when the file
   * changes and round-trips through XCF as a link — above the selected
   * layer, centered on the canvas, as one undo step. `layer` (may be
   * NULL) receives it. Engines without link layers (before GIMP 3.2)
   * report UNSUPPORTED and change nothing; the call never degrades to
   * a raster copy. Same readiness, path, busy and failure rules as
   * image_open_layers. */
  GlimsStatus  (*image_place_link)     (GlimsEngine *engine, GlimsImageID image,
                                        const char *path, GlimsItemID *layer,
                                        char **error);

  /* Opens a live filter session that edits the committed effect
   * `effect` of `drawable`, as the layer effects editor's parameter
   * dialog does: the session's filter_get_property reads the effect's
   * current parameters and filter_set_property/filter_set_double
   * preview new ones through the effect's own captured mask at its
   * stack position. filter_commit writes the parameters back into the
   * same effect — id, name, blend and opacity state, enabled state and
   * list position kept — as one filter-modified undo step; filter_abort
   * restores the effect untouched and pushes no undo. `effect` must be
   * a committed effect id from drawable_effects — a stale, foreign,
   * removed or preview id is NOT_FOUND, as is a detached drawable —
   * and `filter` receives a GlimsFilterID session id, not an effect
   * id. The image keeps the same readiness rules as effect_change:
   * BUSY while a stroke, a filter session or a plug-in owns it. */
  GlimsStatus  (*filter_edit_begin)    (GlimsEngine *engine, GlimsImageID image,
                                        GlimsItemID drawable, GlimsEffectID effect,
                                        GlimsFilterID *filter, char **error);

  /* Image color state and conversions. image_color_info is a read and
   * always allowed, also during a stroke, a preview or a plug-in. The
   * conversions follow the same readiness rules as the other edits —
   * BUSY while a stroke, a filter session or a plug-in owns the image
   * — and validate everything before mutating: each call is one engine
   * core conversion with its own undo group, so one undo step, never a
   * partial change. A request that would change nothing is a no-op that
   * pushes no undo. Both preserve the file identity and the layers,
   * masks and channels, mark the image dirty as usual, and fire the
   * engine's own UNDO_CHANGED / LAYERS_CHANGED / CHANNELS_CHANGED events.
   *
   * image_convert_mode takes a GlimsColorMode and supports RGB and
   * grayscale, including from indexed; conversion TO indexed is
   * UNSUPPORTED here — indexed needs palette and dither policy, which
   * image_convert_indexed takes — while an indexed image's info still
   * reports accurately.
   * image_convert_precision takes a GlimsColorComponent and a
   * GlimsColorTRC, converts with no dithering, and supports the
   * combinations the engine accepts: every component/TRC pair for RGB
   * and grayscale images, and only u8 non-linear for indexed
   * (UNSUPPORTED otherwise). Unknown enum values are
   * INVALID_ARGUMENT; an unknown image NOT_FOUND. */
  GlimsStatus  (*image_color_info)        (GlimsEngine *engine, GlimsImageID image,
                                           GlimsColorInfo *info);
  GlimsStatus  (*image_convert_mode)      (GlimsEngine *engine, GlimsImageID image,
                                           uint32_t mode, char **error);
  GlimsStatus  (*image_convert_precision) (GlimsEngine *engine, GlimsImageID image,
                                           uint32_t component, uint32_t trc, char **error);

  /* Fills the area `path` encloses on `drawable` with a solid color, as
   * the engine's own Fill Path does (gimp_item_fill over GimpFillOptions;
   * app/actions/items-commands.c). `drawable` is a layer, a layer mask
   * or a channel of the image (0: the selected drawable, which is the
   * layer's mask while mask editing is on, or a selected channel); the
   * fill stays inside the selection and honors the drawable's mask, its
   * active components and its pixel locks (LOCKED, also when a group
   * around it holds them). One undo step ("Fill Path"). The fill is the
   * settings' color at `opacity` with `antialias`; on a drawable without
   * an alpha channel the fill is opaque, as the core makes it. The path,
   * the selection and the image's file identity are unchanged. NOT_FOUND
   * for an unknown image, path or drawable id, also one from another
   * image; INVALID_ARGUMENT for NULL or short settings, a non-finite
   * color or an opacity outside 0 ... 1; FAILED for a group as the
   * target and for a path with no fillable geometry ("Not enough points
   * to fill"), both without touching the image; BUSY while a stroke, a
   * filter session or a plug-in holds the image. */
  GlimsStatus  (*path_fill)               (GlimsEngine *engine, GlimsImageID image,
                                           GlimsItemID path, GlimsItemID drawable,
                                           const GlimsPathFillSettings *settings, char **error);
  /* Makes a genuine vector layer from `path`, as Paths > New Vector
   * Layer does (gimp_vector_layer_new plus gimp_image_add_layer;
   * app/actions/paths-commands.c path_to_vector_layer_cmd_callback):
   * above the selected layer, itself selected, rendered, one undo step.
   * `name` (NULL: the path's name, which the core copies to the layer)
   * sets the layer's name; `layer` (may be NULL) receives the layer.
   * Engines without vector layers (before GIMP 3.2) report UNSUPPORTED
   * and change nothing; the call never degrades to a raster copy.
   *
   * Ownership: while the image is open the layer's options hold the same
   * path object, not a clone, so editing the path re-renders the layer;
   * XCF stores the path once in the image's path list and the layer
   * references it by tattoo, re-associated on load, so the layer
   * survives save and reopen as structured content and keeps reporting
   * GLIMS_LAYER_VECTOR. Deleting the path detaches it from the layer
   * (the core clears the options' path). NOT_FOUND for an unknown image
   * or path; INVALID_ARGUMENT for a bad `name`; BUSY while a stroke, a
   * filter session or a plug-in holds the image. */
  GlimsStatus  (*path_to_vector_layer)    (GlimsEngine *engine, GlimsImageID image,
                                           GlimsItemID path, const char *name,
                                           GlimsItemID *layer, char **error);

  /* Brushes, patterns and gradients: what a resource chooser lists,
   * and the persistent identity that restores a saved choice after a
   * restart. All of these are reads: they change nothing and are
   * allowed at any time.
   *
   * resources() lists the engine's resources of `kind` (a
   * GlimsResourceKind) in the engine's own order; the interface sorts
   * as it likes. Only names and handles are collected; nothing is
   * rendered. `rows` receives up to `capacity` rows, `count` the total.
   * INVALID_ARGUMENT for an unknown `kind`, a missing `count`, a
   * negative `capacity`, or `rows` missing while `capacity` is
   * positive. */
  GlimsStatus  (*resources)            (GlimsEngine *engine, uint32_t kind,
                                        GlimsResourceInfo *rows, int32_t capacity,
                                        int32_t *count);
  /* The persistent identity of the resource `id` names: the triplet to
   * store and later feed to resource_resolve(). `name` and `collection`
   * are owned strings (free with free_string) and `internal` says
   * whether the resource is the engine's built-in data. A NULL
   * `collection` is a value of its own, not an empty collection: pass
   * back exactly what was received. The identity survives restarting
   * the engine; nothing else is promised, since moving or renaming the
   * underlying file changes it. INVALID_ARGUMENT when `id` is 0 or
   * outside the range of the issued handles (such a value can never
   * name a resource) or when an output is missing; NOT_FOUND for a
   * validly shaped handle that no longer resolves: stale, or issued
   * by another engine; FAILED when the resource has no usable identity
   * (a missing or invalid name, or a collection that is not UTF-8),
   * with all outputs reset. */
  GlimsStatus  (*resource_identifiers) (GlimsEngine *engine, GlimsResourceID id,
                                        char **name, char **collection, bool *internal,
                                        char **error);
  /* The handle of the resource of `kind` that the identity (name,
   * collection, internal) names, as resource_identifiers() reported
   * it; `outID` receives 0 when the identity resolves to nothing. The
   * match is exactly the engine's own: `collection` (NULL and "" are
   * distinct) and `internal` must agree, and for non-internal
   * resources the name too. An internal resource's name is not
   * compared (its display name is localized), and there is no
   * name-only fallback for the rest. `name` must be nonempty UTF-8,
   * and `collection`, when given, UTF-8. INVALID_ARGUMENT for an
   * unknown `kind`, an invalid `name` or `collection`, or a missing
   * `outID`; NOT_FOUND when no resource of `kind` carries the
   * identity. */
  GlimsStatus  (*resource_resolve)     (GlimsEngine *engine, uint32_t kind,
                                        const char *name, const char *collection,
                                        bool internal, GlimsResourceID *outID,
                                        char **error);
  /* Assign an ICC profile without converting pixel component values, or
   * discard embedded/hidden profiles when path is NULL. Non-NULL paths
   * must be absolute, nonempty UTF-8 paths to valid ICC profiles compatible
   * with the image model. A native single undo group, no mutation on refusal;
   * BUSY during strokes/previews/plugin work. Discarding an already builtin
   * profile and assigning an equal profile are no-ops. */
  GlimsStatus (*image_assign_profile) (GlimsEngine *engine, GlimsImageID image,
                                       const char *path, char **error);
  /* Convert pixels to preserve appearance in the destination ICC profile.
   * NULL path chooses the image model/precision's builtin profile. The own
   * GlimsProfileIntent mapping and explicit black-point compensation apply
   * only to this conversion. Same path/compatibility, undo and busy rules as
   * assignment; converting to an equal effective profile is a no-op.
   * A non-no-op that would rasterize editable text/vector/link layers
   * reports REQUIRES_RASTERIZE without changing anything. The caller can
   * obtain consent and use image_convert_profile_rasterizing instead.
   * Indexed images report UNSUPPORTED: their native palette conversion
   * ignores intent/BPC. Convert to RGB first. Assignment remains supported. */
  GlimsStatus (*image_convert_profile) (GlimsEngine *engine, GlimsImageID image,
                                        const char *path, uint32_t intent,
                                        bool black_point_compensation,
                                        char **error);
  /* Explicitly permits the native conversion to rasterize editable text,
   * vector and link layers. The caller must obtain consent first. The
   * complete conversion remains one undo step; undo restores editability.
   * Equal-profile no-ops still rasterize nothing. All other conversion
   * validation and indexed-image restrictions apply. */
  GlimsStatus (*image_convert_profile_rasterizing) (GlimsEngine *engine, GlimsImageID image,
                                                    const char *path, uint32_t intent,
                                                    bool black_point_compensation, char **error);
  /* An owned thumbnail of the resource `id` names, rendered fresh on
   * every call and fitted inside a `max_size` x `max_size` box
   * (1 ... 512). `foreground` and `background` are optional explicit
   * colors (finite components inside 0 ... 1) for previews that react
   * to them: the foreground recolors mask-only brushes, and both feed
   * gradients with foreground/background segments. Native FG/BG contexts
   * are opaque; the resource supplies alpha through its brush mask or
   * transparent gradient stops. NULL uses the
   * engine's canonical black foreground and white background. The
   * colors apply to this call only; no user or global context is read
   * or changed. `out` receives a straight-alpha sRGB RGBA buffer of
   * byte_count = width * height * 4 (release with free_pixels) and is
   * reset first, on every failure too. Brushes and patterns keep their
   * source aspect and are never scaled up, so a small resource comes
   * back at its native size; gradients render exactly
   * max_size x max (1, max_size / 2). INVALID_ARGUMENT for a missing
   * `out`, a `max_size` outside 1 ... 512, a color component that is
   * not finite or outside 0 ... 1, or an `id` of 0 or outside the
   * range of the issued handles (such a value can never name a
   * resource); NOT_FOUND for a validly shaped handle that no longer
   * resolves: stale, or issued by another engine; FAILED when the
   * engine cannot render a thumbnail, with `out` reset. */
  GlimsStatus  (*resource_thumbnail)   (GlimsEngine *engine, GlimsResourceID id,
                                        int32_t max_size,
                                        const GlimsColor *foreground,
                                        const GlimsColor *background,
                                        GlimsPixelBuffer *out, char **error);
  /* A genuine vector layer's native fill/stroke style (GIMP 3.2+).
   * vector_layer_style_get is a read: it fills `style` from the layer's
   * own options and is always allowed, also during a stroke, a preview
   * or a plug-in. NOT_FOUND for an unknown image or a layer id that is
   * not a genuine (not rasterized) vector layer of the image;
   * UNSUPPORTED before GIMP 3.2 and when the layer's native fill or
   * stroke is a pattern — the pattern is reported, never converted.
   *
   * vector_layer_style_set applies the flagged fields of `change` as
   * exactly one native undo step ("Change Vector Layer Style") around a
   * whole-options snapshot (gimp_image_undo_push_vector_layer with no
   * property), preserving every unflagged setting, the layer's name and
   * auto-rename policy and the same path association; the style change
   * re-renders the layer. All guards run before any mutation: BUSY
   * while a stroke, a filter preview or a plug-in holds the image,
   * INVALID_ARGUMENT for a malformed change or non-finite colors, a
   * width outside 0 ... 2000 or an unknown cap/join, NOT_FOUND for an
   * unknown image or non-vector layer, LOCKED when a pixel lock of the
   * layer or a group around it protects it, UNSUPPORTED before GIMP 3.2
   * or for a native pattern style. A change that would alter nothing is
   * a no-op that pushes no undo. */
  GlimsStatus  (*vector_layer_style_get)  (GlimsEngine *engine, GlimsImageID image,
                                           GlimsItemID layer, GlimsVectorStyle *style,
                                           char **error);
  GlimsStatus  (*vector_layer_style_set)  (GlimsEngine *engine, GlimsImageID image,
                                           GlimsItemID layer, const GlimsVectorStyleChange *change,
                                           char **error);

  /* A paint stroke that paints with one specific brush: the resource
   * `brush` names, a handle from resources() of GLIMS_RESOURCE_BRUSH.
   * Otherwise exactly stroke_begin(): the same stroke_continue and
   * stroke_end drive it, one undo step per stroke, the same readiness,
   * lock and busy rules, and a refused call sets `stroke` to 0 and
   * changes no image or history. The brush is resolved only here, at
   * begin: INVALID_ARGUMENT for a zero handle, one outside the native
   * id range or one that names another resource kind, NOT_FOUND for a
   * stale handle or a brush this engine's brush factory no longer
   * holds. The stroke's own paint options define the brush property
   * locally and hold the selected brush for the whole stroke, so later
   * changes to the caller's settings or to the shared user context
   * never retarget it, and neither the user context nor any factory
   * resource is mutated. Painting stays the engine's own paint core,
   * so colored brushes keep their native semantics. */
  GlimsStatus  (*stroke_begin_with_brush_resource) (GlimsEngine *engine, GlimsImageID image,
                                                    GlimsItemID layer, GlimsResourceID brush,
                                                    const GlimsBrushSettings *settings,
                                                    const GlimsStrokePoint *first,
                                                    GlimsStrokeID *stroke, char **error);

  /* Fills the selected drawable (the active layer, its mask while mask
   * editing is on, or a selected channel — the same target `fill` uses)
   * with the pattern `pattern`, tiled from the drawable's origin, as one
   * undo step ("Fill with Pattern" / "Bucket Fill"). GLIMS_FILL_SELECTION
   * fills the selection, or the whole drawable without one, through the
   * engine's own edit fill; GLIMS_FILL_SIMILAR_COLORS fills the area of
   * similar color around `seed` through its bucket fill, with the seed
   * in image coordinates (translated internally when sampling one drawable). The fill stays inside
   * the selection, honors the drawable's mask, active components and
   * pixel locks (LOCKED, also when a group around it holds them; an
   * alpha lock alone does not refuse, as with painting), and blends at
   * `opacity` exactly as a solid fill does. The pattern is used as the
   * engine holds it — no hidden default-pattern fallback: a handle that
   * does not resolve to a live pattern of this engine is refused.
   *
   * `pattern` is revalidated on every call: 0, a value above the native
   * id range or one with high bits set is INVALID_ARGUMENT (it can never
   * name a resource), a well-shaped but stale or foreign handle, or one
   * that names a brush or gradient instead of a pattern, is NOT_FOUND.
   * INVALID_ARGUMENT for NULL or short settings, an unknown `mode`, a
   * non-finite `seed`, or an `opacity`/`threshold` outside 0 ... 1 (they
   * are refused, not clamped); NOT_FOUND for an unknown image; BUSY while
   * a stroke, a filter session or a plug-in holds the image, with no
   * pixel or undo change. With no selection the whole drawable is
   * filled, as `fill` does; a selection that does not intersect the
   * drawable is a no-op that succeeds without an undo step. `opacity` 0
   * succeeds, changes no pixels and still records the undo step, as the
   * engine's own fill does. The shared user context is never changed:
   * the pattern lives on a private per-call context. */
  GlimsStatus  (*fill_pattern)         (GlimsEngine *engine, GlimsImageID image,
                                        GlimsResourceID pattern, GlimsPoint seed,
                                        const GlimsPatternFillSettings *settings,
                                        char **error);


  /* Draws a gradient with the gradient resource `gradient` names, from
   * `from` to `to` in image pixels, as one undo step, on the selected
   * drawable (the selected layer, its mask while mask editing is on, or
   * a selected channel), clipped by the selection. Unlike gradient(),
   * which always paints the built-in foreground-to-background ramp, the
   * stops come from the resource; there is no fallback when the handle
   * does not resolve. `settings` is required and validated as a whole:
   * struct_size, a known shape and blend space, finite endpoints that
   * are not the same point, finite 0 ... 1 color components with alpha
   * exactly 1, and a finite 0 ... 1 opacity. A per-call context carries
   * the colors: no user or global context is read or changed and the
   * resource itself is never mutated. The engine renders one "Gradient"
   * undo step when it draws. Two native edge cases are inherited
   * verbatim: a selection disjoint from the drawable draws nothing and
   * pushes no undo (the engine returns early), while an opacity of 0
   * still runs the full render and pushes an undo step with no visible
   * change. INVALID_ARGUMENT for missing or invalid settings, endpoints
   * or colors, or a `gradient` of 0 or outside the issued handle
   * range; NOT_FOUND for a stale or foreign handle or one that is not a
   * gradient; BUSY while a plug-in, stroke or filter session holds the
   * image; LOCKED for protected pixels; UNSUPPORTED for RGB_LINEAR:
   * supported native engines cannot blend those stops correctly in
   * linear light (RGB_PERCEPTUAL and CIE_LAB remain available). FAILED
   * with `error` for a drawable that cannot be painted (a group, or no selection). */
  GlimsStatus  (*gradient_resource)     (GlimsEngine *engine, GlimsImageID image,
                                        GlimsResourceID gradient,
                                        GlimsPoint from, GlimsPoint to,
                                        const GlimsResourceGradientSettings *settings,
                                        char **error);

  /* Image guides: the ordinary full-image rulers the user drags out,
   * listed and edited by id. Custom tool-owned guides (such as layer
   * edge guides some engines create) are never listed and refuse
   * guide_put and guide_remove. `rows` receives up to `capacity` rows
   * in the engine's own order, `count` the total; `rows` may be NULL
   * with `capacity` 0 to only count. INVALID_ARGUMENT for a missing
   * `count`, a negative `capacity`, or `rows` missing while `capacity`
   * is positive; NOT_FOUND for an unknown image. A read: allowed at
   * any time. */
  GlimsStatus  (*image_guides)          (GlimsEngine *engine, GlimsImageID image,
                                         GlimsGuideInfo *rows, int32_t capacity,
                                         int32_t *count);
  /* With `guide->id` 0, adds a guide of `guide->orientation` at
   * `guide->position` as one undo step ("Add Horizontal/Vertical
   * Guide"); `result` (may be NULL) receives its id. With a nonzero
   * `guide->id`, moves that existing ordinary guide to `guide->position`
   * as one undo step ("Move Guide"); `guide->orientation` must be the
   * guide's own — a put that would reorient is refused, not applied.
   * A move to the position the guide already holds is a no-op that
   * pushes no undo. Everything is validated before any mutation:
   * INVALID_ARGUMENT for a missing `guide`, an unknown `orientation`,
   * a negative or out-of-range `position` (0 ... image height for
   * horizontal, 0 ... image width for vertical) or a negative `id`;
   * NOT_FOUND for an unknown image or an `id` that names no ordinary
   * guide of this image — stale, foreign or custom tool-owned;
   * BUSY while a stroke, a filter session or a plug-in holds the
   * image. Guide changes are metadata: they never touch the image's
   * pixels or its selection, and pixel locks do not refuse them.
   * GLIMS_EVENT_GUIDES follows each applied change. */
  GlimsStatus  (*guide_put)             (GlimsEngine *engine, GlimsImageID image,
                                         const GlimsGuideInfo *guide,
                                         GlimsGuideID *result, char **error);
  /* Removes the ordinary guide `guide` names, as one undo step
   * ("Remove Guide"); undo restores it at its position and
   * orientation. Same readiness and refusal rules as guide_put:
   * NOT_FOUND for an unknown image or a stale, foreign or custom
   * tool-owned id, INVALID_ARGUMENT for `guide` <= 0, BUSY while a
   * stroke, a filter session or a plug-in holds the image.
   * GLIMS_EVENT_GUIDES follows. */
  GlimsStatus  (*guide_remove)          (GlimsEngine *engine, GlimsImageID image,
                                         GlimsGuideID guide, char **error);

  /* The layer's structured-source state (GlimsLayerSourceInfo): its own
   * class kind, whether it currently behaves as pixels and whether its
   * text, link or path source survived. A read: allowed at any time.
   * `layer` 0 means the selected layer. `out` is validated by its
   * struct_size before it is written: INVALID_ARGUMENT for a missing
   * `out` or one whose struct_size is too small; NOT_FOUND for an
   * unknown image or a `layer` that names no attached layer of the
   * image — stale, foreign or closed — including a 0 `layer` while
   * nothing is selected. */
  GlimsStatus  (*layer_source_info)     (GlimsEngine *engine, GlimsImageID image,
                                         GlimsItemID layer, GlimsLayerSourceInfo *out,
                                         char **error);

  /* Converts the whole image to indexed color as exactly one native
   * undo step ("Convert Image to Indexed"; the core's
   * gimp_image_convert_indexed, app/core/gimpimage-convert-indexed.c),
   * with `settings` (a GlimsIndexedSettings) deciding the palette, the
   * dithering and the editable-layer policy. For
   * GLIMS_INDEXED_PALETTE_CUSTOM, `colors`/`color_count` name the
   * caller-owned palette: 1 ... 256 opaque sRGB colors, read only
   * during this synchronous call and never retained. `colors` is
   * ignored — and may be NULL — for every other palette mode.
   *
   * An already indexed image is a no-op that pushes no undo (the core
   * refuses it). The source must hold 8-bit non-linear precision
   * exactly — the only precision indexed images allow — and a flat
   * layer stack: anything else is UNSUPPORTED without a mutation, the
   * same gates the engine's own image menu and PDB invoker apply.
   * With GLIMS_INDEXED_PRESERVE_EDITABLE, a genuine editable vector or
   * link layer (the quantize path always rasterizes them) or a genuine
   * editable text layer while `dither_text` is on answers
   * REQUIRES_RASTERIZE before anything changes; the caller can obtain
   * consent and retry with GLIMS_INDEXED_ALLOW_RASTERIZE, which keeps
   * the structured sources (a retained GimpText, the path, the link)
   * inside the same single undo step. With `dither_text` off a text
   * layer stays editable under both policies.
   *
   * Everything is validated before any mutation: INVALID_ARGUMENT for
   * missing or short settings, an unknown palette, dither or
   * preservation value, `max_colors` outside 2 ... 256 for GENERATED, a
   * missing or empty `colors` list or one over 256 entries for CUSTOM,
   * or a non-finite, out-of-range or non-opaque palette color;
   * NOT_FOUND for an unknown image; UNSUPPORTED for a non-u8-non-linear
   * precision or a layer stack containing a group; REQUIRES_RASTERIZE
   * under the preservation rules above; BUSY while a stroke, a filter
   * session or a plug-in holds the image; FAILED with `error` when the
   * core reports one. Refusals change no pixels and push no undo; undo
   * of a successful call restores the RGB or grayscale pixels, the
   * color mode and every layer's structured kind. */
  GlimsStatus  (*image_convert_indexed) (GlimsEngine *engine, GlimsImageID image,
                                         const GlimsIndexedSettings *settings,
                                         const GlimsColor *colors, int32_t color_count,
                                         char **error);

  /* The image's display grid (a GlimsGrid), as a plain read of the
   * current engine state: allowed at any time, also while a stroke,
   * a filter session or a plug-in holds the image, and it mutates
   * nothing. `out` is validated by its struct_size before it is
   * written: INVALID_ARGUMENT for a missing `out` or one whose
   * struct_size is too small; NOT_FOUND for an unknown image — stale
   * or closed. The colors come back as non-linear sRGB with alpha. */
  GlimsStatus  (*image_grid)     (GlimsEngine *engine, GlimsImageID image,
                                  GlimsGrid *out, char **error);

  /* Applies `grid` to the image through the core's
   * gimp_image_set_grid(image, grid, TRUE): a changed grid is exactly
   * one native undo step ("Grid") and an identical grid is a no-op
   * that pushes no undo. The engine's own unexposed grid properties
   * (the spacing and offset units) are retained. Everything is
   * validated before any mutation, so the native property clamps can
   * neither hide invalid input nor leave a partial change:
   * INVALID_ARGUMENT for a missing `grid`, a short struct, an unknown
   * `style`, a non-finite spacing/offset, a spacing that is zero,
   * negative or beyond the native property maximum, an offset outside
   * the native signed range, or a non-finite or out-of-range color
   * component (alpha included); NOT_FOUND for an unknown image; BUSY
   * while a stroke, a filter session or a plug-in holds the image.
   * Refusals change no pixels, push no undo and leave the dirty state
   * alone; grid changes are metadata and never touch the image's
   * pixels or its selection. The applied change is followed by the
   * usual UNDO_CHANGED event — no new event kind. */
  GlimsStatus  (*image_set_grid) (GlimsEngine *engine, GlimsImageID image,
                                  const GlimsGrid *grid, char **error);

  /* Strokes the image's selection boundary on `drawable` with a paint
   * tool, through the native core path: gimp_item_stroke() on the
   * image's mask, whose GimpSelection stroke vfunc suspends the
   * selection for the call and resumes it after. The stroke therefore
   * straddles the boundary — pixels on both sides of it change — and
   * the selection mask itself is never modified; the pixels change as
   * exactly one undo step ("Stroke Selection", pushed by
   * gimp_item_stroke with push_undo TRUE). The stroke is painted with
   * the brush settings' tool via the stroke options' paint method
   * (GIMP_STROKE_PAINT_METHOD), on a temporary context that inherits
   * the user context; neither the shared user context nor any factory
   * resource is mutated.
   *
   * `drawable` follows path_stroke's admission exactly: 0 is the
   * image's selected layer; an explicit id must be an attached layer
   * of this image. A layer group, a layer mask or a channel id is
   * refused with FAILED, never silently replaced by another drawable.
   * `brush` is a full-width resource handle: 0 keeps the established
   * convention of stroke_begin — the stroke inherits the user
   * context's current brush; a non-zero handle is resolved strictly
   * through the resource admission (INVALID_ARGUMENT for an
   * out-of-native-range handle or one of another resource kind,
   * NOT_FOUND for a stale handle no longer in the engine's brush
   * factory) and a failed resolve never falls back to a default
   * brush. `settings` is a GlimsBrushSettings, validated in full
   * before any mutation.
   *
   * Everything is validated before any mutation, so refusals change
   * no pixels and push no undo: INVALID_ARGUMENT for a missing or
   * short `settings`, an unknown `tool`, a non-finite or
   * non-positive `size`, a non-finite `opacity` or color component,
   * and for the malformed `brush` handles above; NOT_FOUND for an
   * unknown image or a stale brush handle; FAILED with `error` for an
   * empty selection ("There is no selection to stroke.", checked
   * before the native undo group opens), for a target that is no
   * layer of the image, a group, or a core-reported failure; BUSY
   * while a stroke, a filter session or a plug-in holds the image
   * (glims_edit_ready); LOCKED when the target's effective pixel
   * lock refuses the stroke — plus the alpha lock for the eraser on
   * a layer with alpha, as stroke_begin does. The selection is left
   * unchanged in every case, success included; the usual
   * UNDO_CHANGED event follows a successful stroke — no new event
   * kind. */
  GlimsStatus  (*selection_stroke) (GlimsEngine *engine, GlimsImageID image,
                                    GlimsItemID drawable, GlimsResourceID brush,
                                    const GlimsBrushSettings *settings, char **error);

  /* The image's floating-selection state (a GlimsFloatingState): a plain
   * read of the current engine state, allowed at any time, also while a
   * stroke, a filter session or a plug-in holds the image; it mutates
   * nothing. `out` is validated by its struct_size before it is written:
   * INVALID_ARGUMENT for a missing `out` or one whose struct_size is too
   * small; NOT_FOUND for an unknown image — stale or closed. With no
   * floating selection, `out` reports active=false and zero ids. */
  GlimsStatus  (*image_floating_selection) (GlimsEngine *engine, GlimsImageID image,
                                             GlimsFloatingState *out);

  /* Pastes the caller's straight-alpha 8-bit sRGB RGBA `pixels` INTO the
   * existing selection of `image`, attached to `target`, through the
   * engine's own gimp_edit_paste with GIMP_PASTE_TYPE_FLOATING_INTO: the
   * result is a floating selection — one layer, exactly one undo step
   * ("Paste") — whose preview is clipped to the selection while the
   * target's own pixels stay unchanged until a floating_command resolves
   * it. The selection itself is never modified or cleared. `target` 0
   * means the image's selected drawable (the same accessor the engine's
   * own Paste uses); an explicit id must name an attached layer, layer
   * mask or saved channel of this image. `result` (may be NULL) receives
   * the floating layer's id. `pixels` is only read during this
   * synchronous call.
   *
   * Everything is validated before any native call, so every refusal
   * changes no pixels, pushes no undo and leaves the floating state
   * alone: INVALID_ARGUMENT for missing pixels, a `byte_count` that is
   * not exactly bounds.width * bounds.height * 4, non-positive or
   * over-maximum dimensions, or an out-of-range `bounds` offset;
   * NOT_FOUND for an unknown image, or a `target` id that is stale,
   * foreign, detached or names no drawable of the image; FAILED with
   * `error` when a floating selection already exists (the engine's
   * attach would silently anchor it inside the "Paste" undo group —
   * refused instead), when there is no selection or it does not
   * intersect the target, when the target is a layer group, the
   * selection mask itself or not a channel of the image's channel list,
   * or when the core paste fails; LOCKED when the target's — or an
   * ancestor group's — pixels are locked (the engine would silently
   * downgrade to a new layer, which this call never does); and
   * REQUIRES_RASTERIZE for a genuine editable text, link or vector layer
   * target — an actionable refusal asking for explicit rasterize consent
   * (GLIMS_LAYER_RASTERIZE); plain pixel layers and already rasterized
   * instances are accepted. BUSY while a stroke, a filter session or a
   * plug-in holds the image. The pixels are copied into a private
   * per-call buffer (nothing of the caller's is retained, no color
   * profile is attached) and the returned layer list is released. The
   * floating layer is placed centered on the target's bounds intersected
   * with the selection, exactly as the engine's own Paste Into does. */
  GlimsStatus  (*image_paste_into) (GlimsEngine *engine, GlimsImageID image, GlimsItemID target,
                                    GlimsRect bounds, const uint8_t *pixels, size_t byte_count,
                                    GlimsItemID *result, char **error);

  /* Resolves the image's floating selection with `command` (a
   * GlimsFloatingCommand), each exactly one native undo step: ANCHOR
   * merges the floating layer into its attached target ("Anchor Floating
   * Selection"), TO_LAYER detaches it as an independent layer ("Floating
   * Selection to Layer"; `result` receives its id, the same as
   * `expected`) and DISCARD removes it without merging ("Remove Floating
   * Selection"). `expected` must name the floating selection that is
   * actually active in `image`, as image_floating_selection reports it:
   * 0 is INVALID_ARGUMENT and a stale, foreign or otherwise non-matching
   * id is NOT_FOUND — neither ever falls back to whichever floating
   * selection happens to be active. NOT_FOUND also when the image has no
   * floating selection at all, or is unknown; INVALID_ARGUMENT for an
   * unknown `command`; FAILED with `error` for TO_LAYER on a floating
   * selection attached to a layer mask or channel (the engine refuses
   * those) — with no mutation. BUSY while a stroke, a filter session or
   * a plug-in holds the image. Refusals change no pixels, push no undo
   * and leave the floating selection active. */
  GlimsStatus  (*floating_command) (GlimsEngine *engine, GlimsImageID image, GlimsItemID expected,
                                    uint32_t command, GlimsItemID *result, char **error);

  /* Floats the current selection of `image` into a floating selection,
   * through the engine's own GUI-free gimp_selection_float: the selected
   * region is extracted from `target` (cut for GLIMS_FLOAT_MOVE, copied
   * for GLIMS_FLOAT_COPY), the selection is cleared, and a new layer
   * holding the extracted region — same format, profile and bounds as
   * the selection's intersection with the target, at offset 0 — is
   * attached to `target` as the floating selection. Exactly one native
   * undo step ("Float Selection"); undo restores the target's pixels
   * (MOVE) and the selection. `result` (may be NULL) receives the
   * floating layer's id, which is image-owned and needs no release; the
   * existing layer_move moves it once the selection is cleared.
   * `target` 0 means the image's selected drawable, but only when
   * exactly one drawable is selected — zero or several selected
   * drawables are refused; an explicit id must name an attached layer,
   * layer mask or saved channel of this image. The layer/mask/channel
   * admission is image_paste_into's: the selection mask itself and
   * layer groups are refused, and a genuine editable text, link or
   * vector layer target reports REQUIRES_RASTERIZE (never an implicit
   * rasterization).
   *
   * Everything is validated before any native call, so every refusal
   * changes no pixels, pushes no undo, clears no selection and leaves
   * the floating state alone: INVALID_ARGUMENT for an unknown `mode`;
   * NOT_FOUND for an unknown image or a stale, foreign or detached
   * `target` id; FAILED with `error` when a floating selection already
   * exists (the native attach would silently anchor it), when there is
   * no selection or it does not intersect the target, when the target
   * is the selection mask itself, a layer group, or not a channel of
   * the image's channel list, or when the core float fails; LOCKED for
   * MOVE when the target's — or an ancestor group's — pixels are
   * locked, plus the alpha lock when the target has an alpha channel
   * (the cut punches through it, as image_clear does; COPY is
   * non-destructive and checks no locks beyond readiness);
   * REQUIRES_RASTERIZE for a genuine editable text/link/vector target;
   * BUSY while a stroke, a filter session or a plug-in holds the image.
   * The temporary drawable list, context and error are released on
   * every path. */
  GlimsStatus  (*selection_float) (GlimsEngine *engine, GlimsImageID image, GlimsItemID target,
                                   uint32_t mode, GlimsItemID *result, char **error);

  /* Selects exactly `layers` — an ordered array of `count` layer ids of
   * `image` — as the image's whole selected-layer list (slot 122), the
   * multi-layer counterpart of layer_select, through the engine's own
   * gimp_image_set_selected_layers. Layer groups are layers and may be
   * listed. The selection is transient: it pushes no undo step, marks
   * the image not dirty, and changes no pixels, no selection mask and no
   * mask pixel data. A change sends LAYERS_CHANGED (the engine's
   * "selected-layers-changed" signal, as layer_select's does); a request
   * identical to the current selection is a no-op with no event. The
   * engine keeps the caller's order verbatim — the first id is the
   * active layer plug-ins, fills and gradients act on — and the adapter
   * verifies the postcondition (the exact list, in order) after the call
   * and reports FAILED if the engine silently did not apply it.
   *
   * `count` 0 (with `layers` NULL) clears the selection — the engine
   * permits an empty selection — except while a floating selection is
   * active. Everything is validated before any mutation, so every
   * refusal leaves the current selection untouched: INVALID_ARGUMENT
   * for a NULL `layers` with `count` > 0, for the id 0 (it names no
   * layer), for a repeated id, or for an id that names a mask, channel
   * or path of the image (those are drawables/items, not layers);
   * NOT_FOUND for an unknown image, or an id that is stale, foreign
   * (another image) or detached. While a floating selection is active
   * the engine's setter silently ignores every request except the
   * identical [floating] list — this call refuses those explicitly with
   * FAILED (never anchoring the floating selection) and accepts the
   * identical [floating] list, which is a no-op. Readiness is
   * layer_select's: NOT_FOUND for an unknown image, and no BUSY gate —
   * the selection may change while a stroke, a filter session or a
   * plug-in holds the image. Note on the native call's list ownership:
   * gimp_image_set_selected_layers copies the passed list, so the
   * adapter frees its own list exactly once after the call.
   *
   * One genuine native side effect to know about: when the selection
   * actually changes to more than one layer, the engine clears the
   * edit-mask flag (GlimsMaskState.editing) of every selected layer that
   * has a mask — "we cannot edit masks with multiple selected layers",
   * exactly as the engine's own layer dock does. That flag is transient
   * edit state, not mask data: mask pixels, and the mask's enabled and
   * showing flags, are never touched, and no undo or dirty follows. */
  GlimsStatus  (*image_select_layers) (GlimsEngine *engine, GlimsImageID image,
                                       const GlimsItemID *layers, size_t count,
                                       char **error);

  /* Reads the image's selected layer ids, in the engine's own order —
   * the order image_select_layers last set, first id (the active layer)
   * first (slot 123), from gimp_image_get_selected_layers, whose
   * returned list is BORROWED and never freed by the adapter (the
   * owned-list variant, gimp_image_get_selected_drawables, is not used
   * here). Fills up to `capacity` ids; `count` receives the total.
   * `ids` may be NULL with `capacity` 0 to only count. A plain read,
   * allowed at any time — also while a stroke, a filter session or a
   * plug-in holds the image; it mutates nothing. NOT_FOUND for an
   * unknown image; INVALID_ARGUMENT for a missing `count` or a
   * negative `capacity`. */
  GlimsStatus  (*image_selected_layers)(GlimsEngine *engine, GlimsImageID image,
                                        GlimsItemID *ids, int32_t capacity,
                                        int32_t *count);

  /* Image metadata (EXIF/IPTC/XMP), slots 124-128. All tags are named by
   * their native dotted string ("Exif.Photo.DateTimeOriginal",
   * "Iptc.Application2.Keywords", "Xmp.xmp.CreatorTool", …); only
   * Glims-owned enums and UTF-8 strings cross this boundary, never the
   * engine's enums, structs or XML.
   *
   * The reads (slots 124, 125 and 128) are plain reads of the borrowed
   * image metadata: allowed at any time, also while a stroke, a filter
   * session or a plug-in holds the image, and they never create metadata
   * or mutate the image or its history. The two string-vector results
   * are OWNED by the caller: a NULL-terminated array of `count`
   * NUL-terminated UTF-8 strings (never truncated), released with
   * free_metadata_strings. An image with no metadata, or no tag of the
   * asked domain, yields an honest EMPTY owned vector: a valid array
   * whose first entry is NULL with `count` 0 — never a NULL `result` on
   * success. On every failure `result` is set to NULL and `count` to 0.
   *
   * INVALID_ARGUMENT for a missing `result`/`count`, an unknown `domain`,
   * or a `tag` that is NULL, empty, not valid UTF-8 or carries no
   * "Exif."/"Iptc."/"Xmp." prefix; NOT_FOUND for an unknown image, and for
   * a well-formed but unregistered `tag` (the native registry decides);
   * FAILED with the native message when the native read itself fails. */
  /* The tag names present on the image's metadata in `domain` (a
   * GlimsMetadataDomain), in the engine's own order (slot 124). */
  GlimsStatus  (*image_metadata_tags)   (GlimsEngine *engine, GlimsImageID image,
                                          uint32_t domain, char ***result,
                                          int32_t *count, char **error);
  /* The value list of the single `tag` (slot 125): `count` strings, in
   * the native order, duplicates included — the vector is never
   * flattened or deduplicated. A registered tag that is absent yields
   * the empty owned vector. Language-alternative (XMP LangAlt) tags
   * return the native labeled fragments (for example `lang="fr" Salut`),
   * not plain text and not a lossless language/value structure; the
   * separators between fragments can be ambiguous. */
  GlimsStatus  (*image_metadata_values) (GlimsEngine *engine, GlimsImageID image,
                                          const char *tag, char ***result,
                                          int32_t *count, char **error);
  /* Sets or removes ONE `tag` (slot 126); there is no wildcard or group
   * form, so no accidental bulk edit. `operation` is a GlimsMetadataEdit.
   *
   * Mutation rules: the whole request is validated and applied on a
   * PRIVATE duplicate of the image's metadata (a new empty metadata when
   * the image has none); the original is only replaced through the
   * native single setter after the edit succeeded and actually changes
   * the tag, so a success is exactly ONE native undo step and every
   * refusal leaves the image, its metadata and its history untouched.
   * BUSY while a stroke, a filter preview or a plug-in holds the image,
   * or native Undo is disabled/frozen (checked before any mutation).
   *
   * SET replaces the tag's whole value list with `values` (count >= 1,
   * each a non-NULL valid UTF-8 string; count 0 is INVALID_ARGUMENT — an
   * empty set is not a value, use REMOVE to erase). Setting the values
   * the tag already holds, in the same order, is a no-op that succeeds
   * with zero undo. A tag that holds a single value natively (every
   * Exif tag, non-repeatable Iptc, XmpText) refuses count > 1 with
   * INVALID_ARGUMENT rather than silently keeping only the last value;
   * multi-value tags (repeatable Iptc, Xmp Bag/Seq/Alt) keep every entry
   * in order, duplicates included. XMP language alternatives (LangAlt)
   * and NEW Xmp container tags (Bag/Seq/Alt absent from the image) are
   * UNSUPPORTED: a plain string vector cannot carry xml:lang qualifiers
   * or choose a container type faithfully. Tags the native setter
   * rewrites from the image's own state on every metadata change
   * (Exif.Image.ImageWidth/ImageLength, Exif.Photo.PixelXDimension/
   * PixelYDimension, Exif.Image.BitsPerSample, Exif.Image.XResolution/
   * YResolution/ResolutionUnit, Exif.Photo.ColorSpace, Xmp.exif.ColorSpace,
   * Exif.Iop.InteroperabilityIndex, Exif.Nikon3.ColorSpace,
   * Exif.Canon.ColorSpace) are UNSUPPORTED for both operations, so no
   * requested value can be overridden by that normalization.
   * REMOVE takes no values (`values` NULL, `count` 0, else
   * INVALID_ARGUMENT) and erases the tag; removing a tag the image does
   * not hold is a no-op with zero undo. Unknown tags are NOT_FOUND with
   * the native registry's message; a native set/clear failure is FAILED
   * with the native error, applied only to the private copy. Metadata
   * not targeted — other tags, arrays and language alternatives — is
   * preserved by the native duplicate, and unknown-to-us metadata stays
   * opaque in the core object rather than being reconstructed. */
  GlimsStatus  (*image_metadata_edit)   (GlimsEngine *engine, GlimsImageID image,
                                          const char *tag, uint32_t operation,
                                          const char *const *values, int32_t count,
                                          char **error);
  /* Releases a string vector returned by image_metadata_tags or
   * image_metadata_values (slot 127); NULL is allowed. Never use
   * free_string on these. */
  void         (*free_metadata_strings) (char **strings);

  /* A READ-ONLY descriptor of the single registered `tag` (slot 128):
   * whether the image's metadata holds it, whether the tag supports
   * multiple values natively, its GlimsMetadataValueKind, its
   * GlimsMetadataFormatPolicy bits and its bounded native label,
   * description and type name in `outInfo`.
   *
   * Like the other metadata reads this is a plain read: allowed at any
   * time, also while a stroke, a filter preview or a plug-in holds the
   * image (no busy gate), and it never creates metadata, never installs
   * anything on the image and never mutates the image, its metadata, its
   * history or its pixels — an image with no metadata is still a pure
   * query (a private empty metadata object answers presence and
   * multiple-value questions and is released inside the call).
   *
   * Set outInfo->struct_size to sizeof (GlimsMetadataTagInfo) before the
   * call. INVALID_ARGUMENT for a NULL `outInfo`, a struct_size smaller
   * than sizeof (GlimsMetadataTagInfo) — refused before anything is
   * written — or a `tag` that is NULL, empty, not valid UTF-8 or carries
   * no "Exif."/"Iptc."/"Xmp." prefix; NOT_FOUND for an unknown image, and
   * for a well-formed but unregistered `tag` (the native registry
   * decides); FAILED with the native message when a native read itself
   * fails, or when a native registry string is not valid UTF-8 (invalid
   * native bytes are never copied). On every failure the struct is
   * reset to a safe all-zero descriptor (when its size check passed) and
   * no write goes past the caller's declared struct size. The requested
   * `tag` string itself is never truncated; only label, description and
   * type_name are bounded, UTF-8-safe truncated and NUL-terminated.
   * format_policy is TYPE/FORMAT POLICY ONLY — an actual
   * image_metadata_edit can still refuse (BUSY, LOCKED, copy
   * preservation, native validation); a set bit never promises a write
   * succeeds. */
  GlimsStatus  (*image_metadata_tag_info) (GlimsEngine *engine, GlimsImageID image,
                                           const char *tag, GlimsMetadataTagInfo *outInfo,
                                           char **error);

  /* Creates ONE saved bitmap resource from owned pixels and publishes it
   * to the engine's own resource catalog (slot 129): a bitmap brush
   * (resourceKind GLIMS_RESOURCE_BRUSH) or a pattern
   * (GLIMS_RESOURCE_PATTERN) built from `pixels`, written to the
   * engine's configured writable data folder and added to the factory,
   * with its new handle in `outID`. The call takes no image: it changes
   * no image, no undo history, no context and no clipboard.
   *
   * `name` is the resource label: nonempty valid UTF-8 with no embedded
   * NUL and no control characters, at most 255 UTF-8 bytes so it fits
   * the native 256-byte label; a resource of the same `kind` already
   * carrying this exact name is refused (FAILED), never silently
   * uniquified. `width` and `height` are 1 ... 10000 each (the native
   * resource dimension bound). `pixels` (`constRGBAbytes`) holds exactly
   * `byte_count` = width * height * 4 straight-alpha R'G'B'A u8 bytes,
   * checked with overflow-safe arithmetic before anything is mutated;
   * a NULL `pixels` or a mismatched `byte_count` is INVALID_ARGUMENT.
   * `brushSpacing` is 1 ... 1000 for a brush and must be 0 for a
   * pattern. GLIMS_RESOURCE_GRADIENT is UNSUPPORTED (no pixel-to-
   * gradient conversion exists); any other `kind` is
   * INVALID_ARGUMENT.
   *
   * BUSY while the engine is busy or ANY stroke or filter session is
   * active, not just on one image. `outID` is set to 0 first and again
   * on EVERY failure (including a missing output or error path); on
   * success it is the new resource's positive opaque handle, usable
   * with resources(), resource_identifiers(), resource_resolve(),
   * resource_thumbnail(), stroke_begin_with_brush_resource() and
   * fill_pattern() like any catalog handle. */
  GlimsStatus  (*resource_create_pixels) (GlimsEngine *engine, uint32_t kind,
                                          const char *name, int32_t width, int32_t height,
                                          const uint8_t *pixels, size_t byte_count,
                                          uint32_t brush_spacing, GlimsResourceID *outID,
                                          char **error);
  /* Slot 130: add an empty pass-through group with one default-parameter
   * non-destructive filter, as one native undo group. Creation is committed;
   * edit its returned effect through the existing filter-edit lifecycle.
   * Explicit parent/index; NULL name uses the native group name. Outputs
   * are reset on failure. No active stroke/preview/floating selection.
   * Only allowed one-input operations with generic parameters are accepted;
   * custom native configuration objects require a separate creation flow.
   * Indexed images are UNSUPPORTED; convert to RGB/grayscale first. */
  GlimsStatus (*adjustment_layer_new) (GlimsEngine *engine, GlimsImageID image,
      GlimsItemID parent, int32_t index, const char *operation, const char *name,
      GlimsItemID *layer, GlimsEffectID *effect, char **error);

  /* Duplicates ONE saved brush, pattern or gradient (slot 131): the
   * current resource `sourceID` names is copied through the engine's
   * own per-class copy (gimp_data_duplicate), given the requested
   * `name`, saved to the engine's configured writable data folder with
   * its native subclass extension (.gbr/.vbr/.gih/.pat/.ggr as the
   * core decides) and published to the factory of its own kind, with
   * the new handle in `outID`. The source determines its own kind; no
   * `kind` argument. The call takes no image: it changes no image, no
   * undo history, no selection, no context and no clipboard, and the
   * source itself is never renamed, saved, deleted or dirtied.
   *
   * The source need not be writable: a built-in read-only resource is
   * duplicatable when the engine's own capability check allows it and
   * the private copy is saveable. A resource whose class has no native
   * copy (or an empty native pipe) reports UNSUPPORTED with a reason.
   *
   * `name` follows exactly resource_create_pixels's label contract:
   * nonempty valid UTF-8, no embedded NUL, no Unicode control
   * characters, at most 255 UTF-8 bytes. A resource of the source's
   * own kind already carrying this exact name is refused (FAILED)
   * before any filesystem mutation — never silently uniquified.
   *
   * BUSY while the engine is busy or ANY stroke or filter session is
   * active, not just on one image. `outID` is set to 0 first and again
   * on EVERY failure (including a missing output, engine-null
   * dispatch rejection, and every refusal); on success it is the new
   * resource's positive opaque handle, distinct from `sourceID`, and
   * usable with resources(), resource_identifiers(), resource_resolve(),
   * resource_thumbnail() and the brush/pattern/gradient consumers like
   * any catalog handle. INVALID_ARGUMENT for a missing `outID`, an
   * invalid `name`, or a `sourceID` of 0 or outside the issued handle
   * range (high bits set, or above the native id maximum — such a
   * value can never name a resource); NOT_FOUND for a validly shaped
   * handle that no longer resolves: stale, or issued by another
   * engine, or no longer a member of this engine's current factory;
   * UNSUPPORTED when the native class cannot be duplicated or the
   * private copy cannot be saved; FAILED with `error` on a name
   * collision or a checked persistence failure (a failed save never
   * reports success). */
  GlimsStatus  (*resource_duplicate) (GlimsEngine *engine, GlimsResourceID sourceID,
                                      const char *name, GlimsResourceID *outID,
                                      char **error);

  /* Slot 132: like image_render, but the pixels are converted into the
   * EXACT RGB destination ICC profile `destination_icc` names instead of
   * sRGB. Renders the composited image at `scale` (1.0 = one image pixel
   * per output pixel), `area` in scaled pixel coordinates, exactly as
   * image_render does (same lazy projection reads and area handling), and
   * writes area.width * area.height pixels of PREMULTIPLIED 8-bit RGBA in
   * the destination profile's own RGB space; `stride` is the output row
   * stride in bytes and must be at least area.width * 4. The returned
   * buffer must be tagged with a color space built from these same ICC
   * bytes; image_render's sRGB output must never be retagged instead.
   *
   * The source side uses the image's actual working space: its effective
   * color profile (the image's own, or the engine's builtin fallback for
   * its model) and the projection's own format and precision. Pixels are
   * read unassociated at source precision and color-transformed
   * straight, then premultiplied once for the output; alpha 0, partial
   * and full alpha are handled deterministically. Grayscale images render
   * through their gray source format and profile; an indexed image's
   * RGB projection is handled like RGB. The transform policy is fixed:
   * relative colorimetric SDR, no proofing, no gamut flags, no user
   * settings.
   *
   * `destination_icc` is immutable caller-owned memory, copied by the
   * native profile construction during this synchronous call; no pointer
   * into it is retained afterwards. NULL or zero `destination_icc_length`
   * is INVALID_ARGUMENT, as are lengths above the adapter's ICC cap
   * (16 MiB) and any non-finite or out-of-range scale (2^-20 ... 32),
   * unscaled request edges outside +/-2^26, area, stride or
   * total output size above the adapter's pixel-buffer cap
   * (512 MiB, GLIMS_MAX_PIXEL_BUFFER_BYTES). Malformed ICC data is FAILED
   * with `error`; a valid but non-RGB ICC profile is UNSUPPORTED. There
   * is never a silent sRGB fallback inside this call: the caller chooses
   * the fallback (typically image_render) outside. Native profile,
   * transform and temporary buffers are created, used and released per
   * call on the engine thread; nothing is cached and no image, profile,
   * history, dirty or pixel state is read-write touched — this is a read
   * like image_render and is allowed while the image is not write-ready.
   * NOT_FOUND for an unknown image, exactly like image_render. */
  GlimsStatus  (*image_render_to_profile) (GlimsEngine *engine, GlimsImageID image,
                                           double scale, GlimsRect area,
                                           const uint8_t *destination_icc, size_t destination_icc_length,
                                           uint8_t *pixels, size_t stride, char **error);

  /* Slot 133: the image's FIXED saved sets (stored item sets), read-only.
   * Lists every non-pattern stored set of every kind (layers, channels,
   * paths), in the engine's stored-list order per kind, kinds in
   * GlimsItemSetKind order. Fills up to `capacity` rows; `count` receives
   * the total. `rows` may be NULL with capacity 0 for a count-only read.
   *
   * This is a plain read, like image_layers: allowed at any time, also
   * while a stroke, a filter preview or a plug-in holds the image (no
   * busy gate), and it never changes the selection, the image, its
   * history, its dirty flag or any pixel; it holds no new strong
   * reference beyond the call. Pattern sets are computed definitions and
   * are never listed.
   *
   * Each row's `token` is the set's stable opaque identity within this
   * engine (allocated from a per-engine monotonic counter, never reused):
   * it stays the same across quiet live-member rebuilds of the same set,
   * and it EXPIRES when the set is explicitly removed or replaced through
   * an undoable edit — an expired token is never retargeted, and a set
   * recreated under the same name gets a fresh token. `display_name` is
   * display-only and may be truncated; only `token` resolves members
   * (slot 134). `member_count` is the LIVE attached member count.
   *
   * INVALID_ARGUMENT for a NULL `count` or a negative `capacity` (with a
   * non-NULL `count`, `*count` is reset to 0 first, as on every failure);
   * NOT_FOUND for an unknown image. On every failure `*count` is 0 and no
   * row is written. */
  GlimsStatus  (*image_item_sets) (GlimsEngine *engine, GlimsImageID image,
                                   GlimsItemSetInfo *rows, int32_t capacity,
                                   int32_t *count);
  /* Slot 134: the CURRENT ATTACHED member ids of the one saved set that
   * `token` names in this image (as listed by slot 133). Fills up to
   * `capacity` ids in the set's stored membership order; `count` receives
   * the total live count. `members` may be NULL with capacity 0 for a
   * count-only read. Members are the ids of items currently attached to
   * this image only: weak members that were deleted or detached are
   * skipped, and an empty set reports count 0. The read captures the
   * image id and the token only — no pointer, no name lookup, no strong
   * retention beyond the call.
   *
   * Plain read, like slot 133: allowed while the image is busy, no
   * selection/mutation/dirty/history change. The token is resolved only
   * within this image's own sets: a token issued for another image (or
   * by another engine) is refused, and so is a stale or expired token —
   * never retargeted to a same-named set.
   *
   * INVALID_ARGUMENT for token 0 (never issued), a NULL `count` or a
   * negative `capacity` (`*count` reset to 0 first when it is non-NULL);
   * NOT_FOUND for an unknown image or a token that names no live set of
   * this image. On every failure `*count` is 0 and no id is written. */
  GlimsStatus  (*image_item_set_members) (GlimsEngine *engine, GlimsImageID image,
                                          uint64_t token, GlimsItemID *members,
                                          int32_t capacity, int32_t *count);
  /* Slot 135: ONE undoable edit of one of the image's fixed saved sets.
   * `operation` is a GlimsItemSetEditOp, `kind` a GlimsItemSetKind; both are
   * the facade's own enums, unknown values are INVALID_ARGUMENT.
   * CREATE (token 0) takes the full new `name` and the EXPLICIT `members`
   * (`count` 0 with `members` NULL is an empty set). REPLACE, RENAME and
   * REMOVE take the CURRENT `token` of a set of this image and kind, as
   * listed by slot 133: a foreign, stale or expired token is NOT_FOUND and
   * never retargeted — the set is never resolved through a name or the
   * display label. Field relevance is strict: REPLACE passes only `members`
   * (`name` NULL), RENAME only the desired full `name` (count 0), REMOVE
   * neither; any other combination, `count` < 0 or `members` NULL with
   * `count` > 0 is INVALID_ARGUMENT. `name` is the FULL name: nonempty
   * valid UTF-8, no control characters, at most 255 bytes, as a
   * NUL-terminated C string (an embedded NUL cannot be expressed here).
   * Members are item ids, each > 0 (0 never means "the current selection"),
   * currently attached to this image, of the set's kind, and unique.
   * This is a WRITE: it requires edit readiness (BUSY while a stroke, filter
   * preview or plug-in holds the image) and refuses before any mutation when
   * the undo stack is frozen; every refused or failed call preserves state,
   * history and the dirty flag exactly. A successful mutating call is one
   * native undo step and dirties the image (native stack limits may expire
   * the new step immediately — the edit stays applied, as with other native
   * commands). A no-op (identical REPLACE members, same-name RENAME) returns
   * OK with no undo step and no dirty change.
   * `outToken` (may be NULL) is reset to 0 before dispatch and on every
   * failure. On success CREATE/REPLACE/RENAME receive the resulting set's
   * token — fresh after a mutation (the old token expires for good), the
   * current one after a no-op; REMOVE receives 0. At token-counter
   * exhaustion (UINT64_MAX) CREATE/REPLACE/RENAME are refused (FAILED,
   * outToken 0) in preflight before ANY mutation. NOT_FOUND for an unknown
   * image or a token this image+kind does not own; NOT_RUNNING for a NULL
   * engine. On every failure nothing is mutated. */
  GlimsStatus  (*image_item_set_edit) (GlimsEngine *engine, GlimsImageID image,
                                       uint32_t operation, uint32_t kind,
                                       uint64_t token, const char *name,
                                       const GlimsItemID *members, int32_t count,
                                       uint64_t *outToken, char **error);

  /* Slot 136: selects exactly `items` — an ordered array of `count` item
   * ids of `image`, all of `kind` — as the image's whole selected list of
   * that kind, the batch generalization of image_select_layers (slot 122)
   * to all three kinds, through the engine's own
   * gimp_image_set_selected_layers / _channels / _paths. `kind` is a
   * GlimsItemSetKind (LAYER/CHANNEL/PATH): the facade's own enum only,
   * never a GType or ABI value. Transient: no undo step, no dirty flag,
   * no pixel, selection-mask or mask-data change; a floating selection is
   * never auto-anchored. A change sends the kind's normal selection
   * event; an identical request is a no-op with no event. The caller's
   * order is kept verbatim (first id = active item) and verified by
   * read-back; because the engine compares membership ignoring order, a
   * pure reorder is forced with a clear-then-apply after preflight.
   *
   * An empty LAYER list is INVALID_ARGUMENT at this batch endpoint.
   * `count` 0 clears CHANNEL/PATH selection: channels via gimp_image_unset_selected_channels,
   * which also restores the layer stack the channel selection replaced
   * (the old channel-0 semantics); paths via the empty path setter.
   *
   * The whole input is validated before any mutation, so every refusal
   * leaves the selection untouched: INVALID_ARGUMENT for an unknown
   * `kind`, a negative `count`, a NULL `items` with `count` > 0, any nonpositive id,
   * a repeated id, or an id of another kind (for CHANNEL also the
   * image selection/per-layer masks: not rows of the channel list).
   * The enabled Quick Mask is an actual channel row and is allowed; NOT_FOUND for an unknown image or a stale, foreign or detached
   * id. This is a WRITE: it requires edit readiness and refuses with BUSY
   * before any mutation while a stroke, a filter preview or a plug-in
   * holds the image.
   *
   * Floating-selection policy per kind: LAYER keeps slot 122's gate —
   * under an active floating selection every request except exactly
   * [floating] is refused FAILED (never anchoring it; [floating] is a
   * no-op); a NON-EMPTY CHANNEL list is refused FAILED with an explicit
   * reason (the native setter would silently ignore it), an EMPTY one is
   * allowed; PATH selection is allowed (paths are independent of the
   * drawables). For layers, a selection changing to more than one layer
   * clears the edit-mask flag of every selected masked layer — slot 122's
   * native mask policy, reused unchanged; mask pixels and the mask's
   * enabled and showing flags are never touched. */
  GlimsStatus  (*image_select_items) (GlimsEngine *engine, GlimsImageID image,
                                      uint32_t kind, const GlimsItemID *items,
                                      int32_t count, char **error);

  /* Slot 137: reads the image's selected item ids of `kind` (a
   * GlimsItemSetKind), in the engine's own order — the order
   * image_select_items last set, active item first — from
   * gimp_image_get_selected_layers / _channels / _paths, whose returned
   * lists are BORROWED: never freed, the ids copied out immediately.
   * Fills up to `capacity` ids; `count` receives the total. `out` may be
   * NULL with `capacity` 0 to only count. A plain read, allowed at any
   * time — also while the image is busy; it mutates nothing.
   * INVALID_ARGUMENT for an unknown `kind`, a NULL `count` or a negative
   * `capacity`, or NULL `out` with positive capacity; NOT_FOUND for an unknown image. On EVERY failure —
   * including a NULL engine (NOT_RUNNING) — `*count` is reset to 0 and
   * no id is written. */
  GlimsStatus  (*image_selected_items) (GlimsEngine *engine, GlimsImageID image,
                                        uint32_t kind, GlimsItemID *out,
                                        int32_t capacity, int32_t *count);

  /* Slot 138: creates ONE saved gradient: a static two-endpoint gradient
   * with exactly one segment (positions 0 / 0.5 / 1, linear, RGB, both
   * endpoint color types fixed) whose endpoints are the captured `left`
   * and `right` sRGB+alpha colors — never context-dynamic FG/BG stops —
   * saved to the engine's configured writable data folder as .ggr and
   * published to the gradient factory, with the new handle in `out`.
   * The call takes no image: it changes no image, no undo history, no
   * selection, no context and no clipboard.
   *
   * `name` follows the resource label contract: nonempty valid UTF-8, no
   * embedded NUL, no Unicode control characters, at most 255 UTF-8 bytes,
   * and no ASCII whitespace at either edge (the .ggr loader strips it,
   * which would change the name's identity on reload). `left` and `right`
   * need every component (alpha included) finite and inside 0 ... 1.
   * A NULL `engine` never reaches the creator: dispatch returns
   * NOT_RUNNING (and still clears `out`); NULL `name`, `left`, `right`
   * or `out` are INVALID_ARGUMENT. BUSY while the engine is busy or ANY stroke or
   * filter session is active. FAILED on an exact same-kind name collision
   * (never silently uniquified) or a checked persistence failure.
   * `out` is set to 0 first and again on EVERY failure — including a NULL
   * engine dispatch (NOT_RUNNING) — and on success is the new resource's
   * positive opaque handle, usable with resources(), resource_identifiers(),
   * resource_resolve(), resource_thumbnail() and gradient consumers like
   * any catalog handle. */
  GlimsStatus (*resource_create_gradient)(GlimsEngine *engine, const char *name,
                                          const GlimsColor *left, const GlimsColor *right,
                                          GlimsResourceID *out, char **error);

  /* Slot 139: reads the image's registered XMP LangAlt root property
   * `root` (plain "Xmp.<group>.<property>") as an owned language map.
   * `out` receives `count` GlimsMetadataLanguageValue pairs plus one
   * all-NULL sentinel pair (both fields NULL); release the array with
   * metadata_languages_free (slot 140). The language spelling is
   * preserved exactly and the text is the exact rdf:li content, in the
   * engine's own map order; duplicate case-folded language keys cannot
   * be produced by the native map.
   *
   * A plain read, like image_metadata_values: allowed at any time, also
   * while a stroke, a filter session or a plug-in holds the image (no
   * busy gate), and it never creates metadata, never installs anything
   * on the image and never mutates the image, its metadata, its history
   * or its pixels. The image's own metadata is borrowed; an image with
   * no metadata is NOT_FOUND and no metadata object is created.
   *
   * Both outputs are cleared before dispatch: a NULL engine returns
   * NOT_RUNNING and still leaves a prefilled `out`/`out_count` at
   * NULL/0. INVALID_ARGUMENT for a NULL `out`, `out_count` or `root`;
   * NOT_FOUND for an unknown image, an absent or unregistered root and
   * an image with no metadata; UNSUPPORTED for a root that is not a
   * plain XMP property, a wrong native kind or any unsupported
   * representation (the private reader decides); FAILED with the native
   * message when a native read itself fails. On every failure `out` is
   * NULL and `out_count` 0; `error` follows the usual free_string rule.
   * An image closed after the read is unaffected. */
  GlimsStatus (*image_metadata_languages) (GlimsEngine *engine, GlimsImageID image,
                                          const char *root, GlimsMetadataLanguageValue **out,
                                          int32_t *out_count, char **error);
  /* Slot 140: releases a GlimsMetadataLanguageValue array returned by
   * image_metadata_languages (slot 139). NULL is allowed. It takes no
   * engine and no count: it walks the array until the all-NULL language
   * sentinel pair, freeing both strings of every pair and the array
   * itself. Never use free_string on these. */
  void (*metadata_languages_free) (GlimsMetadataLanguageValue *values);
  /* Slot 141: changes ONE existing language key of the registered XMP
   * LangAlt root property `root` (plain "Xmp.<group>.<property>"),
   * replacing its exact rdf:li text with `text`. The key must already
   * exist in the map, with the exact `language` spelling reported by
   * image_metadata_languages (slot 139); `text` must be nonempty valid
   * UTF-8 with no embedded NUL. No frontend copy or normalization
   * fiddling: the engine runs the sealed preflight (detached copy,
   * normalization, unrelated-tag and roundtrip preservation) and refuses
   * a copy that cannot survive Undo and save.
   *
   * Every refusal leaves the image, its metadata, its history and its
   * pixels untouched. An exact no-op — the key already holds `text` —
   * returns OK with NO undo, NO history and NO readiness gate, even
   * while a stroke, a filter preview or a plug-in holds the image. A
   * changed edit checks stroke/preview/plug-in readiness and that native
   * Undo is enabled (BUSY on refusal), then applies one native setter, which pushes exactly one
   * undo step.
   *
   * For a valid image, INVALID_ARGUMENT for a NULL/empty/non-UTF-8
   * argument, an invalid metadata domain prefix, a language exceeding
   * 255 bytes or text exceeding 1 MiB. NOT_FOUND for an unknown image, an image with no
   * metadata, an absent or unregistered root or a missing exact
   * `language` key; UNSUPPORTED for a non-plain or wrong-kind root,
   * an ambiguous or non-preservable representation; FAILED with the native message when a native
   * operation itself fails; BUSY while a stroke, a filter preview or a
   * plug-in holds the image, or Undo is disabled/frozen (a changed edit
   * only). On every failure
   * `error` follows the usual free_string rule.
   *
   * The generic image_metadata_edit (slot 126) SET/REMOVE stay
   * UNSUPPORTED for LangAlt tags; slots 139/140 remain read-only. */
  GlimsStatus (*image_metadata_edit_language) (GlimsEngine *engine, GlimsImageID image,
                                               const char *root, const char *language,
                                               const char *text, char **error);
  /* Slot142: duplicates1..256 explicit, ordered, positive unique plain
   * pixel-layer ids. Copies are placed immediately above each source in
   * its actual parent; locks are preserved and do not refuse copying.
   * Groups/structured subclasses are UNSUPPORTED. Wrong-kind, foreign,
   * detached/dead ids or image are NOT_FOUND. Malformed arrays/count/ids
   * are INVALID_ARGUMENT. Stroke/filter/plug-in work, floating selection
   * or disabled/frozen Undo is BUSY. All ordinary preflight refusals leave
   * image/tree/selection/history untouched, before any insertion.
   *
   * `copies` is caller-owned storage for count ids. For valid count and
   * non-NULL output it is cleared before preflight; input/output may
   * overlap. Success returns new ids in INPUT order, selects that ordered
   * vector, and pushes one native layer-add Undo group (subject to native
   * history retention). Undo restores the prior layer selection; Redo
   * restores the complete copy selection, including its order.
   *
   * An unexpected Core failure after insertion can leave a positive id
   * prefix followed by zeros, as one recoverable Undo operation. FAILED
   * is therefore NOT a no-change promise: callers must refresh image
   * state on failure as well as success. `error` uses free_string. */
  GlimsStatus (*image_duplicate_layers) (GlimsEngine *engine, GlimsImageID image,
                                        const GlimsItemID *sources, int32_t count,
                                        GlimsItemID *copies, char **error);
  /* Slots 143–145: manage explicitly selected, saved user resources.
   * No image/Undo/clipboard changes. Only regular local native-format files
   * directly in configured writable/search folders are eligible; internal,
   * shared, unsaved and stock resources remain read-only. These capabilities
   * describe current native/file facts, never Glims authorship.
   *
   * Info is read-only. Required outputs are initialized to 0/NULL; flags
   * bit 1 permits Rename, bit 2 Delete. Eligible resources return an opaque
   * observed-state guard; ineligible current resources return flags 0 and
   * a reason. guard/reason/error are owned strings using free_string.
   * Rename/Delete require that exact guard and revalidate current membership
   * and file identity/version. Stale guards are NOT_FOUND; ineligible files
   * UNSUPPORTED; malformed input INVALID_ARGUMENT; native work on any image
   * BUSY. Flags and guards must never be persisted across engine sessions.
   *
   * Rename validates names like resource_duplicate, including VBR/GGR edge
   * whitespace and PAT encoding restrictions, then saves privately and replaces
   * the same file before changing the live name. Exact same-name is a no-op.
   * Delete removes the disk file before catalog membership; native context
   * fallback may run. These are outside image Undo. After any result callers
   * must reconcile catalog state: a rare post-commit failure is FAILED, not
   * an unchanged-state promise. No concurrent external-writer transaction or
   * power-loss durability guarantee is made. */
  GlimsStatus (*resource_mutation_info) (GlimsEngine *engine, GlimsResourceID id,
                                         uint32_t *flags, char **guard, char **reason,
                                         char **error);
  GlimsStatus (*resource_rename) (GlimsEngine *engine, GlimsResourceID id,
                                  const char *guard, const char *name, char **error);
  GlimsStatus (*resource_delete) (GlimsEngine *engine, GlimsResourceID id,
                                  const char *guard, char **error);
  /* Slot 146: captured plain pixel-layer deletion, 1..256 distinct positive
   * IDs attached to this image. Validate the whole vector before mutation;
   * groups, structured subclasses and masks with live effects are UNSUPPORTED.
   * BUSY for active work, floating selections, disabled/frozen Undo or an open
   * native Undo group. Native layer locks do not prevent removing a layer.
   * One native Undo group, subject to native history retention. Surviving
   * selected layers retain their order; if none survive, select the first
   * remaining layer-tree row, or no layer in an empty image. Undo restores the
   * complete prior selection and native objects; Redo restores the survivor
   * selection. Ordinary reported failures precede the first removal. */
  GlimsStatus (*image_delete_layers) (GlimsEngine *engine, GlimsImageID image,
                                      const GlimsItemID *layers, int32_t count,
                                      char **error);
  /* Slot 147: begin a new merge-only preview with a detached native-format
   * snapshot of a same-image drawable's pixels and committed effects. Supports
   * gegl:bump-map (height map), gegl:variable-blur (blur mask),
   * gegl:gaussian-blur-selective (contrast reference), and
   * gegl:negative-darkroom (dodge/burn map), and gegl:lens-blur (radius map)
   * through their single aux pad; all other operations are UNSUPPORTED.
   * Lens Blur alone accepts source0 as explicit None (uniform blur). Its map
   * must convert to finite unit-range luminance in both linear and perceptual
   * views in the source's working space, allowing eight upper float ULPs for
   * conversion roundoff; pixels are never clamped. Both mapped and
   * None sessions validate native geometry, radius arithmetic and a bounded
   * aggregate scratch allocation before attachment and every changed setting.
   * Unsafe settings are refused before mutation. Imported Lens effects are
   * not admitted for parameter editing. All other operations require a
   * positive source ID. target must be a pixel-behaving layer, including a previously
   * rasterized source. Groups and editable sources are not merge targets.
   * Indexed images are UNSUPPORTED. Existing work/floating selections, disabled
   * or frozen Undo and an open native Undo group are BUSY. Merge rechecks Undo
   * readiness before changing target pixels; a refusal leaves the preview open.
   * The snapshot is bounded by GLIMS_MAX_PIXEL_BUFFER_BYTES (512 MiB), owns no
   * live source graph and remains independent of later source changes. Source
   * offsets are those of its native buffer; no item-offset translation is added.
   * Abort changes no stored pixels/history. Commit merges into target pixels as
   * one native Undo; auxiliary connections are not persisted as an XCF effect.
   * out is zero on failure, including a nonrunning engine. */
  GlimsStatus (*filter_begin_with_source) (GlimsEngine *engine, GlimsImageID image,
                                           GlimsItemID target, const char *operation,
                                           GlimsItemID source, GlimsFilterID *out,
                                           char **error);
  /* Slots148-149: settings of a live gimp:brightness-contrast preview only.
   * Set validates the complete pair before replacing its immutable config;
   * preview changes add no Undo. Apply/Cancel use the existing lifecycle.
   * A same-value Set is an OK no-op. Other operations are UNSUPPORTED.
   * Get requires struct_size >= sizeof(GlimsBrightnessContrastSettings);
   * fields are reset on failure when the supplied sized output is valid. */
  GlimsStatus (*filter_brightness_contrast_get) (GlimsEngine *engine,
                                               GlimsFilterID filter,
                                               GlimsBrightnessContrastSettings *out,
                                               char **error);
  GlimsStatus (*filter_brightness_contrast_set) (GlimsEngine *engine,
                                               GlimsFilterID filter,
                                               const GlimsBrightnessContrastSettings *settings,
                                               char **error);
  /* Slots150-151: a complete gimp:color-balance preview value. Get/Set
   * follow the sized-output and immutable replacement rules of slots148-149.
   * All nine corrections are validated before any change. The range picker
   * is UI state; it never changes an installed config to read another range.
   * Preserve-luminosity means native HSL lightness. The native operation
   * works in nonlinear sRGB and clamps before restoring lightness. */
  GlimsStatus (*filter_color_balance_get) (GlimsEngine *engine, GlimsFilterID filter,
                                         GlimsColorBalanceSettings *out, char **error);
  GlimsStatus (*filter_color_balance_set) (GlimsEngine *engine, GlimsFilterID filter,
                                         const GlimsColorBalanceSettings *settings,
                                         char **error);
  /* Slots 152/153: complete native Hue/Saturation settings. All 21
   * corrections and overlap default to zero. Reads do not change the native
   * range cursor; changed writes replace a private immutable configuration.
   * Hue and saturation/lightness contributions combine Master and local
   * ranges with the native fixed-sRGB HSL rules, including overlap. */
  GlimsStatus (*filter_hue_saturation_get) (GlimsEngine *engine, GlimsFilterID filter,
                                          GlimsHueSaturationSettings *out, char **error);
  GlimsStatus (*filter_hue_saturation_set) (GlimsEngine *engine, GlimsFilterID filter,
                                          const GlimsHueSaturationSettings *settings,
                                          char **error);
  /* Slots154/155: complete native Levels configuration. Equal/inverted
   * input/output endpoints are valid; no implicit sorting or sum clamp.
   * TRC is the existing owned GlimsColorTRC enum. A legacy operation/config
   * TRC mismatch is unsupported, with no live normalization on Get/Copy.
   * Get requires struct_size >= sizeof(GlimsLevelsSettings); failures zero
   * the owned fields, preserving struct_size and any future tail. Set
   * validates the complete value before mutation; numeric equality is a
   * no-op, including signed-zero equality. Native channel cursors and base
   * operation settings are preserved by complete-value replacement. */
  GlimsStatus (*filter_levels_get) (GlimsEngine *engine, GlimsFilterID filter,
                                   GlimsLevelsSettings *out, char **error);
  GlimsStatus (*filter_levels_set) (GlimsEngine *engine, GlimsFilterID filter,
                                   const GlimsLevelsSettings *settings, char **error);
  /* Slot156: resize every explicitly captured pixel-behaving layer to the
   * image bounds with transparent fill, including its native layer mask.
   * Requires 1..256 distinct positive IDs. All sources, locks, attachment,
   * readiness and Undo admission are checked before the first mutation.
   * Editable sources and groups are UNSUPPORTED; no implicit rasterization.
   * Ordered native selection/tree order are preserved. An all-no-op batch
   * adds no history; otherwise one outer native Undo covers the batch. */
  GlimsStatus (*image_fit_layers_to_image) (GlimsEngine *engine, GlimsImageID image,
                                           const GlimsItemID *layers, int32_t count,
                                           char **error);
  /* Slots157..160: owned all-channel Curves snapshots and immutable patches.
   * Out must be zero-initialized except struct_size >= sizeof(snapshot).
   * Failure clears owned fields, preserving struct_size and any future tail.
   * Free releases only facade allocations; it requires no engine thread.
   * Edit/TRC Set allocate their complete authoritative result BEFORE changing
   * the live config. On success, even a numeric no-op returns a snapshot.
   * Smooth points are authoritative; Core generates their sample table.
   * Free samples are authoritative; Reset restores native channel identity.
   * Unused edit arrays/counts must be NULL/zero. Input is validated in full;
   * no implicit sorting/clamping. Other channels/base metadata remain exact.
   * Native tables outside the common 256-sample domain are UNSUPPORTED.
   * A legacy config/operation TRC mismatch is refused without normalization.
   * Caller must free each successful snapshot before reusing its storage. */
  GlimsStatus (*filter_curves_get) (GlimsEngine *engine, GlimsFilterID filter,
                                   GlimsCurvesSnapshot *out, char **error);
  void (*free_curves_snapshot) (GlimsCurvesSnapshot *snapshot);
  GlimsStatus (*filter_curves_edit) (GlimsEngine *engine, GlimsFilterID filter,
                                    const GlimsCurveEdit *edit,
                                    GlimsCurvesSnapshot *out, char **error);
  GlimsStatus (*filter_curves_set_trc) (GlimsEngine *engine, GlimsFilterID filter,
                                       uint32_t trc, GlimsCurvesSnapshot *out,
                                       char **error);
  /* Slots161..163: captured Levels/Curves input histogram and Levels Auto.
   * Histogram reads pre-filter drawable pixels, in the config TRC, weighted
   * by the image selection and source alpha. It excludes layer-mask/opacity
   * composition. Bins contain actual finite fractional/signed native weights;
   * out-of-range source alpha is not silently normalized. Absent channel
   * pointers are NULL; present channels own bin_count doubles (NULL if zero).
   * Requires a live attached filter session, no engine busy operation. Reads
   * remain available under pixel locks; Auto obeys ordinary edit admission.
   * Snapshot Out starts zeroed except struct_size; Free needs no engine and
   * preserves size/future tail. Get failures clear owned fields without any
   * image/history mutation. Caller frees a successful snapshot before reuse.
   * Auto uses the same fresh input histogram and native0.006-tail stretch:
   * RGB resets Value and stretches RGB; gray stretches Value. It preserves
   * alpha/TRC/clamps/native cursor/base settings. Its authoritative full
   * Levels result is generated/validated before immutable installation. */
  GlimsStatus (*filter_input_histogram) (GlimsEngine *engine, GlimsFilterID filter,
                                        GlimsHistogramSnapshot *out, char **error);
  void (*free_histogram_snapshot) (GlimsHistogramSnapshot *snapshot);
  GlimsStatus (*filter_levels_auto) (GlimsEngine *engine, GlimsFilterID filter,
                                    GlimsLevelsSettings *out, char **error);
  /* Slot164: display-only ICC soft proofing. The source is the image's
   * effective profile; destination_icc must be RGB, while proof_icc may
   * be any valid ICC profile accepted by the native proofing constructor.
   * Both ICC blobs are nonempty, at most 16 MiB, copied synchronously, and
   * never retained. Settings must have the complete known prefix; both
   * intents are GlimsProfileIntent and only the owned BPC flag is valid.
   * NULL/short settings, invalid intents/flags, ICC lengths and render
   * bounds are refused before writing caller output. Malformed ICC or an
   * unsupported native transform fails explicitly, without an unproofed
   * fallback. Output uses the same exact destination-profile premultiplied
   * RGBA u8 and bounds/stride rules as slot132. Conversion runs on straight
   * float colors, preserving alpha before one final premultiplication.
   * This is a synchronous engine-thread read: no image/profile/selection,
   * history/dirty or saved simulation settings change, and write-readiness
   * is not required. Profiles/transforms are per-call, never cached. Use
   * unchanged slot132 when proofing is disabled. No gamut, paper-white or
   * black-simulation option is implied by this slot. */
  GlimsStatus (*image_render_proofed) (GlimsEngine *engine, GlimsImageID image,
                                      double scale, GlimsRect area,
                                      const uint8_t *destination_icc, size_t destination_icc_length,
                                      const uint8_t *proof_icc, size_t proof_icc_length,
                                      const GlimsProofSettings *settings,
                                      uint8_t *pixels, size_t stride, char **error);
  /* Slot165: rasterize the captured ordered vector of 1..256 distinct positive
   * layer ids in this image. Every member must be attached, retain a text,
   * link or vector source, and have effective PIXELS/POSITION locks clear.
   * Rasterized structured members with retained sources are eligible no-ops;
   * ordinary pixel layers, groups, masks, channels and missing sources refuse.
   * Requires write readiness, no floating selection, enabled/unfrozen Undo
   * and no open Undo group. The entire vector is validated and strongly held
   * before mutation; ordinary refusals change nothing. Changed members share
   * one native "Rasterize Layers" Undo group. An all-no-op request leaves
   * history/dirty state unchanged. Pixels, source data, identities, topology,
   * offsets, masks/effects and ordered selection stay with their layers.
   * Unexpected Core failure may leave a changed prefix in that one Undo;
   * failure reports this explicitly and refreshes authoritative image state,
   * rather than promising rollback. The vector is borrowed only for this
   * synchronous call and never retained. */
  GlimsStatus (*image_rasterize_layers) (GlimsEngine *engine, GlimsImageID image,
                                        const GlimsItemID *layers, int32_t count,
                                        char **error);
  /* Slot166: restore the captured ordered vector of 1..256 distinct positive
   * attached same-image layer ids from retained text/link/vector sources.
   * Ordinary pixels, groups, masks/channels and missing sources refuse. Every
   * member, including already-editable no-ops, must pass effective PIXELS and
   * POSITION locks, write readiness, no floating selection, enabled/unfrozen
   * Undo and zero open Undo groups. Known missing/empty retained link file or
   * buffer is refused using in-memory facts; admission never stats/loads files.
   * The whole vector is validated and strongly held before mutation. Changed
   * members share one native Restore Layer Sources Undo; all-no-op requests
   * change no history/dirty state. Identities, topology and ordered selection
   * stay with the layers, but regeneration may resize/reposition pixels and
   * masks or rename layers. Links reload current external content; Undo/Redo
   * is not an immutable linked-file snapshot. Void native setters do not
   * report rendering success: postchecks confirm retained source kind and
   * editable behavior, not pixel correctness. Detected Core/load/monitor
   * failure may leave changes inside the one Undo group; errors explicitly
   * warn some layers may have changed/use Undo and refresh authoritative state,
   * with no rollback promise. Ordinary admission refusals change nothing.
   * The vector is borrowed for this synchronous engine-thread call only. */
  GlimsStatus (*image_restore_layer_sources) (GlimsEngine *engine, GlimsImageID image,
                                             const GlimsItemID *layers, int32_t count,
                                             char **error);
  /* Slot167: read-only layer pick at `point` in image coordinates. Uses the
   * engine's own gimp_image_pick_layer hit test (topmost layer with sampled
   * opacity strictly above that engine's native threshold). Reviewed stable
   * GIMP3.0.8/3.2.0/3.2.8 use 0.25; reviewed master3.3.1 at
   * 5374deeec14a0366df4b17b6e5c6f9aff63db2ca uses 0.001. No threshold is
   * inferred for unreviewed builds. Core honors visibility, raw pixel alpha,
   * applied layer masks and offsets; groups follow the engine's native
   * pick behavior.
   * Coordinates are truncated toward zero and the truncated value must fit in
   * a signed 32-bit sample coordinate. Non-finite/out-of-range coordinates,
   * missing `out`, or any sample-minus-layer-offset subtraction that cannot
   * fit that range are INVALID_ARGUMENT. The arithmetic check covers Core's
   * actual layer traversal, including groups and children; it does not clamp
   * to image bounds or approximate a hit. Ordinary finite out-of-canvas points
   * remain valid when those conversions are safe. *out
   * is set to 0 before every failure path (including public dispatch) and on
   * a miss, otherwise to the positive item id of the hit layer. Unknown/stale
   * image is NOT_FOUND. Refuses with BUSY while another engine operation holds
   * the engine busy. This is a read-only image/tree/selection/history/dirty
   * query, but not a promise that the Core pick never performs I/O or buffer
   * reads. */
  GlimsStatus (*image_pick_layer) (GlimsEngine *engine, GlimsImageID image,
                                   GlimsPoint point, GlimsItemID *out);
  /* Slot168: create a text layer while atomically consuming the exact
   * captured floating selection state. The public wrapper sets *out to 0
   * and clears *error before dispatch (absent out is INVALID_ARGUMENT);
   * failures leave *out 0, including late partial failures, so callers
   * must reload actual state. The expected state is mandatory and copied
   * by its known prefix only: a well-formed active state names a positive
   * floating selection, its attachment and a known owned target kind
   * (layer, layer mask or saved/Quick Mask channel); an inactive state
   * must be all zero. A NULL, short or inconsistent state is
   * INVALID_ARGUMENT. The call compares the full expected
   * active/floating/target/kind fields against the fresh native state
   * before mutation and again immediately before mutation after detached
   * layout preparation, refusing mismatches with NOT_FOUND and no
   * retargeting or fallback. A stale/foreign/intervening float is
   * refused even when the expected state is inactive.
   *
   * Admission requires an explicit image, no engine-busy/stroke/filter
   * preview activity, enabled/unfrozen Undo with no open Undo group, and
   * a valid active target of the image with the matching drawable class
   * and effective PIXELS locks satisfied (inherited). Text, settings and
   * font are validated as text_layer_new does; position.x/y must be
   * finite and floor(position + 0.5) must fit in a signed 32-bit coordinate
   * (the existing rounding policy, not GUI truncation). Rendered text
   * offset-plus-size and the conservative union of text, current physical
   * drawable/bounding rectangles and the image/zero extent must also have
   * representable signed coordinates and spans. Unrepresentable geometry
   * is INVALID_ARGUMENT before Undo/anchor; safe off-canvas positions are
   * valid. This domain check can refuse contrived extreme spans across
   * unrelated layers; it does not predict or retarget ACTIVE_PARENT.
   * Detached text preparation and
   * layout happen before the outer undo group or anchor; a layout
   * failure leaves no image mutation. The mutation raises a balanced busy
   * fence, rechecks native state and runs in exactly one outer native
   * Text "Add Text Layer" undo group: it anchors the captured active
   * floating selection (if any), sets the prepared offset, adds the
   * prepared layer with ACTIVE_PARENT at index -1 and selects it, then
   * closes the group and flushes. Anchor is a native void merge with no
   * rollback guarantee.
   *
   * After a successful anchor, an unexpected insertion/group-end failure
   * reports FAILED with an explicit image-may-have-changed/inspect-Undo
   * message, leaves *out 0 and does not claim unchanged state, atomic
   * rollback or guaranteed pixel success. It attempts to close its opened
   * group and flushes actual state on that path; the call never ends a group
   * it did not start. Inactive expected state is valid only when the image truly
   * has no floating selection and creates normally with legacy
   * ACTIVE_PARENT placement. */
  GlimsStatus (*text_layer_new_captured) (GlimsEngine *engine, GlimsImageID image,
                                          const GlimsFloatingState *expected,
                                          const char *text,
                                          const GlimsTextSettings *settings,
                                          GlimsPoint position,
                                          GlimsItemID *out, char **error);
  /* Slot169: begin a merge-only gegl:displace preview with two captured
   * same-image drawable sources. Explicit positive target, x_source and
   * y_source ids are mandatory. X supplies horizontal/radial displacement
   * and Y vertical/angular displacement; the operation's amount properties
   * can disable either axis. No optional map or arbitrary pad name is accepted.
   * Sources may be the same drawable or the target. Both source identities
   * are validated and their native-format pixels/committed effects detached
   * before a target preview is attached. Native buffer coordinates are kept;
   * no item-offset translation is added. Distinct captured buffers share the
   * existing 512 MiB GLIMS_MAX_PIXEL_BUFFER_BYTES snapshot budget; the same
   * source in both roles shares one snapshot and is charged once.
   * Target/rasterization, indexed-image, floating-selection, work/lock and
   * Undo readiness follow slot147. Abort changes no stored pixels/history;
   * Apply merges as one native Undo, without a persistent auxiliary effect.
   * A refused commit leaves the preview cancelable. Both captured inputs live
   * until the session ends, independently of later source edits or deletion.
   * *out is zero on every failure, including public dispatch on a stopped
   * engine; ordinary admission failures leave pixels and history unchanged. */
  GlimsStatus (*filter_begin_displace_with_sources) (GlimsEngine *engine,
                                                    GlimsImageID image,
                                                    GlimsItemID target,
                                                    GlimsItemID x_source,
                                                    GlimsItemID y_source,
                                                    GlimsFilterID *out,
                                                    char **error);

  /* Slot170: start an owned, merge-only Oilify preview on a pixel layer.
   * Positive radius/exponent ids refer to attached same-image drawables.
   * Zero leaves that pad absent; two zero ids give plain Oilify. Distinct
   * sources share the 512 MiB snapshot budget, with identical ids charged
   * once. Detached native-format inputs retain their buffer coordinates.
   * Native halo and sample arithmetic and converted target RGBA/luminance
   * and map luminance must validate before attachment. The current selection
   * is frozen before preview; no implicit rasterization or persisted effect.
   * Abort preserves stored pixels/history; Apply merges with one native Undo.
   * On failure *out is zero. Generic legacy filter routes keep their contract. */
  GlimsStatus (*filter_begin_oilify_with_sources) (GlimsEngine *engine,
                                                  GlimsImageID image,
                                                  GlimsItemID target,
                                                  GlimsItemID radius_source,
                                                  GlimsItemID exponent_source,
                                                  GlimsFilterID *out,
                                                  char **error);

  /* Slot171: atomically begin a live V1 stroke and capture owned facts about
   * the brush and effective paint configuration actually used at first paint.
   * brush_resource zero chooses the actual inherited brush. With no expected
   * fingerprint, unsupported capture does not prevent live painting; on
   * success *out is a stroke and facts->fingerprint can be NULL. When an
   * expected fingerprint is supplied, a positive explicit brush resource
   * and an exact supported fingerprint match are required before first paint.
   * All failures clear *out and the supported facts fields; struct_size and
   * any future tail remain unchanged. Finish with the ordinary V1 end call. */
  GlimsStatus (*stroke_begin_with_capture_facts) (GlimsEngine *engine,
                                                  GlimsImageID image,
                                                  GlimsItemID drawable,
                                                  GlimsResourceID brush_resource,
                                                  const GlimsBrushSettings *brush,
                                                  const GlimsStrokePoint *first,
                                                  const char *expected_fingerprint,
                                                  GlimsStrokeID *out,
                                                  GlimsStrokeCaptureFacts *facts,
                                                  char **error);

  /* Slot172: begin a V2 stroke with exactly one sample. Resource zero keeps
   * the inherited-brush convention; a positive resource is resolved/pinned
   * once as in stroke_begin_with_brush_resource. Finish with stroke_end.
   * Coordinates and mandatory base axes follow the ranges above. Optional
   * rotation maps to native turns; tangential pressure maps to native wheel
   * (value + 1) / 2. Absent axes use fresh rotation 0 / wheel 0.5 defaults.
   * This transports coordinates; it does not enable tablet brush dynamics.
   *
   * Both V2 entries copy aligned known prefixes and ignore future tail bytes;
   * no caller memory is retained after the synchronous call. Unknown flags,
   * nonzero reserved/absent-axis values, nonfinite/out-of-range fields,
   * malformed sizes/strides/counts or payloads over the limits are refused
   * before native paint, timestamp, pixel or history mutation. The packet's
   * sample_stride applies even to an empty packet. Empty continuation is
   * canonical only with NULL samples and zero byte_count; it is a no-op.
   *
   * First time_ms is arbitrary. Later samples, including packet boundaries,
   * require unsigned modular (next - previous) <= 0x7fffffff. Equal times
   * and forward UInt32 wrap are valid. A whole packet validates before any
   * sample is delivered or the accepted time changes. This is invalid-input
   * atomicity, not rollback of an unexpected native paint failure.
   * V1/V2 continuation on the other input version is INVALID_ARGUMENT with
   * no paint/time mutation. V1 layout and valid V1 behavior are unchanged.
   * Every failed begin clears *out (including stopped-engine dispatch);
   * public entry clears *error when supplied. */
  GlimsStatus (*stroke_begin_v2) (GlimsEngine *engine,
                                  GlimsImageID image,
                                  GlimsItemID drawable,
                                  GlimsResourceID brush_resource,
                                  const GlimsBrushSettings *brush,
                                  const GlimsStrokePacketV2 *packet,
                                  GlimsStrokeID *out, char **error);
  /* Slot173: deliver a validated packet to an existing V2 stroke. */
  GlimsStatus (*stroke_continue_v2) (GlimsEngine *engine,
                                     GlimsStrokeID stroke,
                                     const GlimsStrokePacketV2 *packet,
                                     char **error);
} GlimsEngineAPI;

/* Returns NULL when the library cannot serve `api_version`. */
const GlimsEngineAPI *glims_engine_get_api (uint32_t api_version);
typedef const GlimsEngineAPI *(*GlimsEngineGetAPIFunction) (uint32_t api_version);

#ifdef __cplusplus
}
#endif

#endif /* GLIMS_ENGINE_H */

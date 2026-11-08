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
  GLIMS_STATUS_UNSUPPORTED      = 8  /* the engine version cannot do this */
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
  GLIMS_EVENT_CHANNELS_CHANGED   = 8  /* image: channel list, selected channel,
                                       * components or Quick Mask */
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
   * UNSUPPORTED for now (palette and dither policy need a later slice),
   * while an indexed image's info still reports accurately.
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
} GlimsEngineAPI;

/* Returns NULL when the library cannot serve `api_version`. */
const GlimsEngineAPI *glims_engine_get_api (uint32_t api_version);
typedef const GlimsEngineAPI *(*GlimsEngineGetAPIFunction) (uint32_t api_version);

#ifdef __cplusplus
}
#endif

#endif /* GLIMS_ENGINE_H */

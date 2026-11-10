/*
 * Images: creation, opening, rendering of the composited image, saving and
 * exporting, the layer tree and the undo history. Runs on the engine thread.
 */
#include "engine-private.h"
#include "effect-state.h"
#include "foreign-effect-load.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-fill.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitemstack.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplinklayer.h"
#if ! GIMP_CHECK_VERSION (3, 3, 0)
#include "libgimpmath/gimpmath.h"
#include "core/gimplink.h"
#include "core/gimplinklayerundo.h"
#include "core/gimpitemundo.h"
#endif
#endif
#include "core/gimppickable.h"
#include "core/gimpprojection.h"

#include <cairo.h>

#include "gegl/gimptilehandlervalidate.h"
#include "core/gimpundostack.h"

#include "file/file-open.h"
#include "file/file-save.h"

#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimpvectorlayer.h"
#endif

#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
#include "plug-in/gimppluginprocedure.h"

#include "text/gimptextlayer.h"

/* The largest render scale the facade accepts (3200%). */
#define MAX_RENDER_SCALE 32.0
/* Bound GEGL's float scale and signed sampling-factor/coordinate arithmetic.
 * This still covers images far beyond GIMP's 524288-pixel dimension limit. */
#define MIN_RENDER_SCALE (1.0 / 1048576.0)
#define MAX_RENDER_SAMPLE_COORD 67108864.0

/* GIMP 3.2's link finalizer leaves a pending changed idle with a bare
 * link pointer (gimplink.c). Master cancels it natively. Register cleanup
 * on actual object death, not image close: undo records and other owners
 * can keep a link alive, and cancelling a surviving link's idle would
 * leave its private source id stale and silence future file changes. */
#if GIMP_CHECK_VERSION (3, 2, 0) && ! GIMP_CHECK_VERSION (3, 3, 0)
static void
link_finalized (gpointer data, GObject *dead_link)
{
  (void) data;
  while (g_source_remove_by_user_data (dead_link))
    ;
}

static void
track_link (GimpLink *link)
{
  if (link && ! g_object_get_data (G_OBJECT (link), "glims-link-idle-cleanup"))
    {
      g_object_set_data (G_OBJECT (link), "glims-link-idle-cleanup", GINT_TO_POINTER (1));
      g_object_weak_ref (G_OBJECT (link), link_finalized, NULL);
    }
}

static void
track_link_owners (GimpObject *object, GHashTable *visited)
{
  GimpContainer *children = NULL;

  if (! object || ! g_hash_table_add (visited, object))
    return;
  if (GIMP_IS_LINK_LAYER (object))
    track_link (gimp_link_layer_get_link (GIMP_LINK_LAYER (object)));
  if (GIMP_IS_LINK_LAYER_UNDO (object))
    track_link (GIMP_LINK_LAYER_UNDO (object)->link);
  if (GIMP_IS_ITEM_UNDO (object))
    track_link_owners (GIMP_OBJECT (GIMP_ITEM_UNDO (object)->item), visited);
  if (GIMP_IS_UNDO_STACK (object))
    children = GIMP_UNDO_STACK (object)->undos;
  else if (GIMP_IS_GROUP_LAYER (object))
    children = gimp_viewable_get_children (GIMP_VIEWABLE (object));
  if (children)
    for (gint i = 0; i < gimp_container_get_n_children (children); i++)
      track_link_owners (gimp_container_get_child_by_index (children, i), visited);
}
#endif

void
glims_track_image_links (GimpImage *image)
{
#if GIMP_CHECK_VERSION (3, 2, 0) && ! GIMP_CHECK_VERSION (3, 3, 0)
  GHashTable *visited = g_hash_table_new (g_direct_hash, g_direct_equal);
  GList *layers = gimp_image_get_layer_list (image);

  for (GList *iter = layers; iter; iter = iter->next)
    track_link_owners (iter->data, visited);
  track_link_owners (GIMP_OBJECT (gimp_image_get_undo_stack (image)), visited);
  track_link_owners (GIMP_OBJECT (gimp_image_get_redo_stack (image)), visited);
  g_list_free (layers);
  g_hash_table_unref (visited);
#else
  (void) image;
#endif
}

/* ---- Open images ------------------------------------------------------- */

GlimsOpenImage *
glims_lookup_image (GlimsEngine  *engine,
                    GlimsImageID  id)
{
  return g_hash_table_lookup (engine->images, GINT_TO_POINTER (id));
}

GimpDrawable *
glims_lookup_drawable (GlimsOpenImage *open,
                       GlimsItemID     id)
{
  GimpItem *item = gimp_item_get_by_id (open->engine->gimp, id);

  /* A deleted item keeps its id while the undo stack holds it; it is no
   * longer part of the image (gimp_item_is_attached), as GIMP's own
   * procedures check (app/pdb/gimppdb-utils.c). */
  if (! item || ! GIMP_IS_DRAWABLE (item) || gimp_item_get_image (item) != open->image ||
      ! gimp_item_is_attached (item))
    return NULL;

  return GIMP_DRAWABLE (item);
}

static void
projection_update (GimpProjection *projection,
                   gboolean        now,
                   gint            x,
                   gint            y,
                   gint            width,
                   gint            height,
                   GlimsOpenImage *open)
{
  GeglRectangle rect = { x, y, width, height };

  glims_emit (open->engine, GLIMS_EVENT_PROJECTION_CHANGED, open->image, &rect, NULL);
}

static void
undo_event (GimpImage      *image,
            GimpUndoEvent   event,
            GimpUndo       *undo,
            GlimsOpenImage *open)
{
  glims_track_image_links (image);
  if (event == GIMP_UNDO_EVENT_UNDO || event == GIMP_UNDO_EVENT_REDO)
    glims_adjustment_projection_changed (image);
  open->history_revision++;
  glims_emit (open->engine, GLIMS_EVENT_UNDO_CHANGED, image, NULL, NULL);
  glims_emit (open->engine, GLIMS_EVENT_LAYERS_CHANGED, image, NULL, NULL);
  glims_emit (open->engine, GLIMS_EVENT_CHANNELS_CHANGED, image, NULL, NULL);
}

static void
selected_layers_changed (GimpImage      *image,
                         GlimsOpenImage *open)
{
  glims_emit (open->engine, GLIMS_EVENT_LAYERS_CHANGED, image, NULL, NULL);
}

/* Takes over the caller's reference to `image`. */
static void
size_changed (GimpImage      *image,
              GlimsOpenImage *open)
{
  glims_emit (open->engine, GLIMS_EVENT_SIZE_CHANGED, image, NULL, NULL);
}

static void
mask_changed (GimpImage      *image,
              GlimsOpenImage *open)
{
  glims_emit (open->engine, GLIMS_EVENT_SELECTION_CHANGED, image, NULL, NULL);
}

static void
channels_changed (GimpImage      *image,
                  GlimsOpenImage *open)
{
  glims_emit (open->engine, GLIMS_EVENT_CHANNELS_CHANGED, image, NULL, NULL);
}

/* "component-*-changed" carries the component between image and user data. */
static void
component_changed (GimpImage       *image,
                   GimpChannelType  type,
                   GlimsOpenImage  *open)
{
  glims_emit (open->engine, GLIMS_EVENT_CHANNELS_CHANGED, image, NULL, NULL);
}

/* "guide-added", "guide-removed" and "guide-moved" each carry the one
 * GimpGuide; the event reports only the image — re-read image_guides. */
static void
guide_changed (GimpImage      *image,
               GimpGuide      *guide,
               GlimsOpenImage *open)
{
  glims_emit (open->engine, GLIMS_EVENT_GUIDES, image, NULL, NULL);
}

GlimsStatus
glims_adopt_image (GlimsEngine  *engine,
                   GimpImage    *image,
                   GlimsImageID *id)
{
  GlimsOpenImage *open = g_new0 (GlimsOpenImage, 1);

  open->image  = image;
  open->engine = engine;
  open->item_sets = glims_item_sets_new (engine, image);
  glims_track_image_links (image);
  open->history_revision = 1;
  open->projection_update_handler =
    g_signal_connect (gimp_image_get_projection (image), "update",
                      G_CALLBACK (projection_update), open);
  open->undo_event_handler =
    g_signal_connect (image, "undo-event", G_CALLBACK (undo_event), open);
  open->layers_changed_handler =
    g_signal_connect (image, "selected-layers-changed", G_CALLBACK (selected_layers_changed), open);
  open->mask_changed_handler =
    g_signal_connect (image, "mask-changed", G_CALLBACK (mask_changed), open);
  open->size_changed_handler =
    g_signal_connect (image, "size-changed", G_CALLBACK (size_changed), open);
  open->channels_changed_handler =
    g_signal_connect (image, "selected-channels-changed", G_CALLBACK (channels_changed), open);
  open->component_active_handler =
    g_signal_connect (image, "component-active-changed", G_CALLBACK (component_changed), open);
  open->component_visible_handler =
    g_signal_connect (image, "component-visibility-changed", G_CALLBACK (component_changed), open);
  open->quick_mask_changed_handler =
    g_signal_connect (image, "quick-mask-changed", G_CALLBACK (channels_changed), open);
  open->guide_added_handler =
    g_signal_connect (image, "guide-added", G_CALLBACK (guide_changed), open);
  open->guide_removed_handler =
    g_signal_connect (image, "guide-removed", G_CALLBACK (guide_changed), open);
  open->guide_moved_handler =
    g_signal_connect (image, "guide-moved", G_CALLBACK (guide_changed), open);

  g_hash_table_insert (engine->images, GINT_TO_POINTER (gimp_image_get_id (image)), open);

  if (id)
    *id = gimp_image_get_id (image);

  return GLIMS_STATUS_OK;
}

void
glims_release_image (GlimsEngine  *engine,
                     GlimsImageID  id)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);

  /* Sessions own image/drawable refs. Do not let an unfinished preview
   * retain a closed image or block subsequent plug-in commands. */
  if (open)
    glims_filters_abort_for_image (engine, open->image);
  g_hash_table_remove (engine->images, GINT_TO_POINTER (id));
}

/* ---- Creating, opening, closing ---------------------------------------- */

GlimsStatus
glims_image_new (GlimsEngine   *engine,
                 int32_t        width,
                 int32_t        height,
                 GlimsImageID  *out,
                 char         **error)
{
  GimpImage *image;
  GimpLayer *layer;

  if (! out || width < 1 || height < 1 ||
      width > GIMP_MAX_IMAGE_SIZE || height > GIMP_MAX_IMAGE_SIZE)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  image = gimp_create_image (engine->gimp, width, height, GIMP_RGB,
                             GIMP_PRECISION_U8_NON_LINEAR, FALSE);

  /* A new image starts with a white background and an empty history. */
  gimp_image_undo_disable (image);
  layer = gimp_layer_new (image, width, height,
                          gimp_image_get_layer_format (image, FALSE),
                          "Background", GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL);
  gimp_image_add_layer (image, layer, NULL, 0, FALSE);
  gimp_drawable_fill (GIMP_DRAWABLE (layer), gimp_get_user_context (engine->gimp), GIMP_FILL_WHITE);
  gimp_image_undo_enable (image);
  gimp_image_clean_all (image);

  return glims_adopt_image (engine, image, out);
}

GlimsStatus
glims_image_open (GlimsEngine   *engine,
                  const char    *path,
                  GlimsImageID  *out,
                  char         **error)
{
  GFile             *file;
  GimpImage         *image;
  GimpPDBStatusType  status;
  gboolean           handles_vector = FALSE;
  const gchar       *mime_type      = NULL;
  GError            *gerror         = NULL;
  GlimsVectorLoadGuard *vector_guard;

  if (! path || ! out)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Loading a non-XCF file runs a plug-in; not inside another one's run. */
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  file = g_file_new_for_path (path);

  GFileInfo *source_info = g_file_query_info (file, GLIMS_FOREIGN_SOURCE_ATTRIBUTES,
                                             G_FILE_QUERY_INFO_NONE, NULL, NULL);

  /* Loading a non-XCF file runs a plug-in, which nests a main loop. */
  engine->busy++;
  vector_guard = glims_vector_load_guard_begin (engine, NULL);
#if GIMP_CHECK_VERSION (3, 2, 0)
  image = file_open_image (engine->gimp, gimp_get_user_context (engine->gimp), NULL, file,
                           0, 0, FALSE, FALSE, NULL, GIMP_RUN_NONINTERACTIVE,
                           &handles_vector, &status, &mime_type, &gerror);
#else
  /* GIMP 3.0 has no vector aspect-ratio option and no vector-handling report. */
  image = file_open_image (engine->gimp, gimp_get_user_context (engine->gimp), NULL, file,
                           0, 0, FALSE, NULL, GIMP_RUN_NONINTERACTIVE,
                           &status, &mime_type, &gerror);
  (void) handles_vector;
#endif
  glims_vector_load_guard_end (vector_guard);
  engine->busy--;

  if (! image)
    {
      g_clear_object (&source_info);
      g_object_unref (file);
      return glims_fail (error, gerror, "The file could not be opened.");
    }

  g_clear_error (&gerror);

  GlimsStatus restore_status = glims_foreign_effects_load (image, file, mime_type,
                                                          source_info, error);
  if (restore_status == GLIMS_STATUS_OK)
    restore_status = glims_effect_state_load (image, error);
  g_clear_object (&source_info);
  g_object_unref (file);
  if (restore_status != GLIMS_STATUS_OK)
    {
      g_object_unref (image);
      return restore_status;
    }

  return glims_adopt_image (engine, image, out);
}

GlimsStatus
glims_image_close (GlimsEngine  *engine,
                   GlimsImageID  id)
{
  if (! glims_lookup_image (engine, id))
    return GLIMS_STATUS_NOT_FOUND;

  /* A monitored link can enter a file plug-in's nested loop without an
   * app-owned job. Never free its image from that loop. Callers retry. */
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  glims_release_image (engine, id);

  return GLIMS_STATUS_OK;
}

/* ---- Layers ------------------------------------------------------------ */

typedef struct
{
  GlimsLayerInfo *rows;
  int32_t         capacity;
  int32_t         count;
  GList          *selected;
} LayerWalk;

/* Shared with edit.c, whose resize commands decide from the kind
 * whether a layer's content is pixels they may reshape. */
GlimsLayerKind
glims_layer_kind (GimpLayer *layer)
{
  GimpItem *item = GIMP_ITEM (layer);

  if (gimp_item_is_text_layer (item))
    return GLIMS_LAYER_TEXT;
#if GIMP_CHECK_VERSION (3, 2, 0)
  /* Link and vector layers arrived in GIMP 3.2. */
  /* A rasterized instance retains its native class and source metadata,
   * but its current content is pixels, like a modified text layer. */
  if (gimp_item_is_link_layer (item))
    return GLIMS_LAYER_LINK;
  if (gimp_item_is_vector_layer (item))
    return GLIMS_LAYER_VECTOR;
#endif
  if (GIMP_IS_GROUP_LAYER (layer))
    return GLIMS_LAYER_GROUP;

  return GLIMS_LAYER_PIXEL;
}

static void
walk_layers (GimpContainer *container,
             GlimsItemID    parent,
             int32_t        depth,
             LayerWalk     *walk)
{
  GList *iter;

  for (iter = gimp_item_stack_get_item_iter (GIMP_ITEM_STACK (container)); iter; iter = iter->next)
    {
      GimpLayer *layer = iter->data;
      GimpItem  *item  = GIMP_ITEM (layer);

      if (walk->count < walk->capacity)
        {
          GlimsLayerInfo *row  = &walk->rows[walk->count];
          const gchar    *nick = NULL;
          gint            x, y;

          memset (row, 0, sizeof (*row));
          row->id     = gimp_item_get_id (item);
          row->parent = parent;
          row->depth  = depth;
          row->kind   = glims_layer_kind (layer);
          g_strlcpy (row->name, gimp_object_get_name (GIMP_OBJECT (layer)), sizeof (row->name));
          if (gimp_enum_get_value (GIMP_TYPE_LAYER_MODE, gimp_layer_get_mode (layer),
                                   NULL, &nick, NULL, NULL))
            g_strlcpy (row->mode, nick, sizeof (row->mode));
          row->visible  = gimp_item_get_visible (item);
          row->has_mask = gimp_layer_get_mask (layer) != NULL;
          row->selected = g_list_find (walk->selected, layer) != NULL;
          row->opacity  = gimp_layer_get_opacity (layer);
          gimp_item_get_offset (item, &x, &y);
          row->bounds.x      = x;
          row->bounds.y      = y;
          row->bounds.width  = gimp_item_get_width (item);
          row->bounds.height = gimp_item_get_height (item);
          row->filter_count  =
            gimp_container_get_n_children (gimp_drawable_get_filters (GIMP_DRAWABLE (layer)));
        }
      walk->count++;

      if (GIMP_IS_GROUP_LAYER (layer))
        walk_layers (gimp_viewable_get_children (GIMP_VIEWABLE (layer)),
                     gimp_item_get_id (item), depth + 1, walk);
    }
}

GlimsStatus
glims_image_layers (GlimsEngine    *engine,
                    GlimsImageID    id,
                    GlimsLayerInfo *rows,
                    int32_t         capacity,
                    int32_t        *count)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  LayerWalk       walk = { rows, rows ? capacity : 0, 0, NULL };

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! count || capacity < 0)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  walk.selected = gimp_image_get_selected_layers (open->image);
  walk_layers (gimp_image_get_layers (open->image), 0, 0, &walk);
  *count = walk.count;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_info (GlimsEngine    *engine,
                  GlimsImageID    id,
                  GlimsImageInfo *info)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  const gchar    *nick = NULL;
  int32_t         layers = 0;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! info)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  memset (info, 0, sizeof (*info));
  info->width  = gimp_image_get_width (open->image);
  info->height = gimp_image_get_height (open->image);
  glims_image_layers (engine, id, NULL, 0, &layers);
  info->layer_count = layers;
  info->dirty = gimp_image_is_dirty (open->image) != 0;
  if (gimp_enum_get_value (GIMP_TYPE_PRECISION, gimp_image_get_precision (open->image),
                           NULL, &nick, NULL, NULL))
    g_strlcpy (info->precision, nick, sizeof (info->precision));

  return GLIMS_STATUS_OK;
}

/* ---- Rendering --------------------------------------------------------- */

/* Renders, at full resolution, whatever is invalid under `area` (scaled
 * pixels) in GIMP's projection buffer. Reads at a smaller scale come from
 * GEGL's mipmap levels, which are built from level 0 (full resolution), so
 * level 0 must be current first; GIMP's own display does the same work in
 * idle chunks before drawing. */
static void
validate_area (GeglBuffer *buffer,
               double      scale,
               GlimsRect   area)
{
  GimpTileHandlerValidate *validate = gimp_tile_handler_validate_get_assigned (buffer);
  const GeglRectangle     *extent   = gegl_buffer_get_extent (buffer);
  GeglRectangle            full;

  if (! validate)
    return;

  /* Intersect in floating point before narrowing. Tiny positive scales
   * can produce infinite divided edges; the buffer extent remains bounded. */
  double left = MAX (floor ((double) area.x / scale), (double) extent->x);
  double top = MAX (floor ((double) area.y / scale), (double) extent->y);
  double right = MIN (ceil (((double) area.x + area.width) / scale),
                      (double) extent->x + extent->width);
  double bottom = MIN (ceil (((double) area.y + area.height) / scale),
                       (double) extent->y + extent->height);
  if (! (right > left && bottom > top)) return;
  full.x = (gint) left;
  full.y = (gint) top;
  full.width = (gint) (right - left);
  full.height = (gint) (bottom - top);

  /* Renders the invalid parts of the area, synchronously, as GIMP's chunk
   * renderer does. */
  gimp_tile_handler_validate_validate (validate, buffer, &full, TRUE, FALSE);
}

/* Shared by both renderers (glims_image_render, display-render.c):
 * validates `scale` and `area`, then prepares the projection buffer for
 * one synchronous read of `area` at `scale`. */
GlimsStatus
glims_projection_prepare_read (GlimsOpenImage  *open,
                               double           scale,
                               GlimsRect        area,
                               GeglBuffer     **buffer_out)
{
  GimpProjection *projection;
  GeglBuffer     *buffer;

  if (! (scale >= MIN_RENDER_SCALE) || scale > MAX_RENDER_SCALE ||
      area.width < 1 || area.height < 1)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  double sampling_scale = (double) (float) scale;
  if (fabs ((double) area.x / sampling_scale) > MAX_RENDER_SAMPLE_COORD ||
      fabs ((double) area.y / sampling_scale) > MAX_RENDER_SAMPLE_COORD ||
      fabs (((double) area.x + area.width) / sampling_scale) > MAX_RENDER_SAMPLE_COORD ||
      fabs (((double) area.y + area.height) / sampling_scale) > MAX_RENDER_SAMPLE_COORD)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Hand pending updates to the projection as invalid tiles without
   * rendering them; reading the buffer then renders only the tiles this
   * area needs. That is what makes the visible area appear first, as in
   * GIMP's own display, instead of compositing the whole image up front. */
  projection = gimp_image_get_projection (open->image);

  /* Pending work can sit in two places: the update region, and GIMP's idle
   * chunk renderer, which takes the update region over and renders it
   * piece by piece without first marking its tiles invalid. Reads only
   * render invalid tiles, so stop the chunk renderer (it hands its
   * remaining area back to the update region) and turn the whole update
   * region into invalid tiles. The reads below then render exactly the
   * tiles they touch; the rest stays invalid until something reads it.
   * The buffer is allocated on first use, which queues the whole image. */
  buffer = gimp_pickable_get_buffer (GIMP_PICKABLE (projection));
  gimp_projection_stop_rendering (projection);
  gimp_projection_flush_now (projection, FALSE);

  /* At 1:1, ordinary reads ask GimpTileHandlerValidate for each tile and
   * render straight into it. Explicit area validation instead blits through
   * an intermediate buffer and is much slower on a cold viewport.
   *
   * Keep explicit validation for GEGL's 1 x 1 shortcut: gegl_buffer_get_pixel
   * in gegl/buffer/gegl-buffer-access.c reuses a hot tile without consulting
   * the validate handler, so it can return pixels from before a change.
   * Scaled reads also need level 0 current before GEGL builds its mipmaps.
   * No GEGL/GIMP source changes or private cache access are needed. */
  if (scale != 1.0 || (area.width == 1 && area.height == 1))
    validate_area (buffer, scale, area);

  *buffer_out = buffer;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_render (GlimsEngine  *engine,
                    GlimsImageID  id,
                    double        scale,
                    GlimsRect     area,
                    uint8_t      *pixels,
                    size_t        stride)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GeglBuffer     *buffer;
  GeglRectangle   rect = { area.x, area.y, area.width, area.height };
  GlimsStatus     status;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! pixels)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_projection_prepare_read (open, scale, area, &buffer);
  if (status != GLIMS_STATUS_OK)
    return status;
  if (stride < (size_t) area.width * 4)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Babl converts from the image's working space to sRGB. Display profiles
   * are not applied yet. */
  /* GEGL's special one-column conversion uses stack scratch proportional
   * to its height. Bound each such call, including the legacy renderer. */
  for (gint row = 0; row < area.height; )
    {
      gint rows = area.width == 1 ? MIN (256, area.height - row) : area.height;
      rect.y = area.y + row;
      rect.height = rows;
      if (scale == 1.0 && area.width == 1 && rows == 1)
        validate_area (buffer, scale, (GlimsRect) { area.x, rect.y, 1, 1 });
      gegl_buffer_get (buffer, &rect, scale, babl_format ("R'aG'aB'aA u8"),
                       pixels + (size_t) row * stride, (gint) stride, GEGL_ABYSS_NONE);
      row += rows;
    }

  return GLIMS_STATUS_OK;
}

/* ---- Saving and exporting ---------------------------------------------- */

typedef enum
{
  SAVE_DOCUMENT,
  SAVE_COPY,
  EXPORT_IMAGE
} FileWritePurpose;

static GlimsStatus
save_with_group (GlimsEngine            *engine,
                 GlimsImageID            id,
                 const char             *path,
                 FileWritePurpose        purpose,
                 char                  **error)
{
  GlimsOpenImage      *open = glims_lookup_image (engine, id);
  GimpPlugInProcedure *proc;
  GimpPDBStatusType    status;
  GFile               *file;
  GError              *gerror = NULL;
  gboolean             saving = (purpose != EXPORT_IMAGE);
  GimpFileProcedureGroup group = saving ? GIMP_FILE_PROCEDURE_GROUP_SAVE : GIMP_FILE_PROCEDURE_GROUP_EXPORT;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! path)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;
  if (saving && glims_filters_active_for_image (engine, open->image))
    {
      if (error) *error = g_strdup ("Apply or cancel the filter preview before saving.");
      return GLIMS_STATUS_BUSY;
    }

  file = g_file_new_for_path (path);
  proc = gimp_plug_in_manager_file_procedure_find (engine->gimp->plug_in_manager, group, file, &gerror);
  if (! proc)
    {
      g_object_unref (file);
      return glims_fail (error, gerror, "No file format handles this file name.");
    }

  GlimsEffectSaveState *effect_state = NULL;
  if (saving)
    {
      GlimsStatus capture_status = glims_effect_state_save_begin (open->image, &effect_state, error);
      if (capture_status != GLIMS_STATUS_OK)
        {
          g_object_unref (file);
          return capture_status;
        }
    }

  /* Exporting runs a plug-in, which nests a main loop. */
  engine->busy++;
  status = file_save (engine->gimp, open->image, NULL, file, proc, GIMP_RUN_NONINTERACTIVE,
                      purpose == SAVE_DOCUMENT, /* change saved state */
                      FALSE,           /* export back to the imported file */
                      ! saving,        /* export forward */
                      &gerror);
  engine->busy--;
  glims_effect_state_save_end (effect_state);

  g_object_unref (file);

  if (status != GIMP_PDB_SUCCESS)
    return glims_fail (error, gerror, saving ? "The image could not be saved." : "The image could not be exported.");

  g_clear_error (&gerror);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_save (GlimsEngine  *engine,
                  GlimsImageID  id,
                  const char   *path,
                  char        **error)
{
  return save_with_group (engine, id, path, SAVE_DOCUMENT, error);
}

GlimsStatus
glims_image_save_copy (GlimsEngine *engine, GlimsImageID id, const char *path, char **error)
{
  return save_with_group (engine, id, path, SAVE_COPY, error);
}

GlimsStatus
glims_image_export (GlimsEngine  *engine,
                    GlimsImageID  id,
                    const char   *path,
                    char        **error)
{
  return save_with_group (engine, id, path, EXPORT_IMAGE, error);
}

/* ---- Undo -------------------------------------------------------------- */

GlimsStatus
glims_image_undo_info (GlimsEngine   *engine,
                       GlimsImageID   id,
                       GlimsUndoInfo *info)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpUndoStack  *undo_stack;
  GimpUndoStack  *redo_stack;
  GimpUndo       *top;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! info)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  memset (info, 0, sizeof (*info));
  undo_stack = gimp_image_get_undo_stack (open->image);
  redo_stack = gimp_image_get_redo_stack (open->image);
  info->undo_count = gimp_undo_stack_get_depth (undo_stack);
  info->redo_count = gimp_undo_stack_get_depth (redo_stack);

  top = gimp_undo_stack_peek (undo_stack);
  if (top)
    g_strlcpy (info->next_undo, gimp_object_get_name (GIMP_OBJECT (top)), sizeof (info->next_undo));
  top = gimp_undo_stack_peek (redo_stack);
  if (top)
    g_strlcpy (info->next_redo, gimp_object_get_name (GIMP_OBJECT (top)), sizeof (info->next_redo));

  return GLIMS_STATUS_OK;
}

static GlimsStatus
undo_or_redo (GlimsEngine  *engine,
              GlimsImageID  id,
              gboolean      undo)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  gboolean        done;
  GlimsStatus     status;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, NULL);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* Popping an undo or redo can thaw a link layer — a file reload that
   * runs a load plug-in and its nested main loop — so hold busy for the
   * duration. */
  engine->busy++;
  done = undo ? gimp_image_undo (open->image) : gimp_image_redo (open->image);
  engine->busy--;
  gimp_image_flush (open->image);

  return done ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

GlimsStatus
glims_image_undo (GlimsEngine  *engine,
                  GlimsImageID  id)
{
  return undo_or_redo (engine, id, TRUE);
}

GlimsStatus
glims_image_redo (GlimsEngine  *engine,
                  GlimsImageID  id)
{
  return undo_or_redo (engine, id, FALSE);
}

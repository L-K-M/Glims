/*
 * Structured layer sources: the layer_source_info read and the explicit
 * GLIMS_LAYER_RASTERIZE command. Runs on the engine thread.
 *
 * Source kind is the layer's own class, so a rasterized text, link or
 * vector instance keeps TEXT/LINK/VECTOR here while image_layers already
 * reports it PIXEL (glims_layer_kind uses the editable predicates). The
 * editable predicates themselves come from the core: a text layer is
 * editable until its pixels were modified, a link layer while it
 * monitors its file, a vector layer until it is rasterized
 * (app/core/gimpitem.c gimp_item_is_rasterized computes the same
 * class-plus-negated-predicate pair).
 *
 * Rasterizing keeps the source and the pixels: on GIMP 3.2+ the classes
 * implement GimpRasterizable and gimp_rasterizable_rasterize
 * (app/core/gimprasterizable.c) pushes the one "Rasterize ..." undo group
 * and flips the flag — text and vector keep their GimpText and path
 * (their set_rasterized handlers only act on restore), a link is frozen
 * (gimp_link_freeze), which keeps the GimpLink but stops the monitor.
 * On GIMP 3.0.8 only text exists, and the native rasterization is the
 * modified flag: gimptextlayer.c's set_buffer path wraps
 * gimp_image_undo_push_text_layer_modified plus "modified"=TRUE in one
 * undo group, leaving the GimpText and the buffer alone — reproduced
 * here verbatim. gimp_text_layer_discard is never used: it would
 * destroy the retained source.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpimage-undo-push.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpgrouplayer.h"

#include "text/gimptextlayer.h"

#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplinklayer.h"
#include "core/gimprasterizable.h"
#include "path/gimpvectorlayer.h"
#endif

#include "gimp-intl.h"

/* The facade source kind of `layer`'s own class, independent of whether
 * it currently behaves as pixels. */
static uint32_t
source_kind_of (GimpLayer *layer)
{
  GimpItem *item = GIMP_ITEM (layer);

  if (GIMP_IS_TEXT_LAYER (item))
    return GLIMS_LAYER_TEXT;
#if GIMP_CHECK_VERSION (3, 2, 0)
  /* Link and vector layers arrived in GIMP 3.2. */
  if (GIMP_IS_LINK_LAYER (item))
    return GLIMS_LAYER_LINK;
  if (GIMP_IS_VECTOR_LAYER (item))
    return GLIMS_LAYER_VECTOR;
#endif
  if (GIMP_IS_GROUP_LAYER (layer))
    return GLIMS_LAYER_GROUP;

  return GLIMS_LAYER_PIXEL;
}

/* The class's current editable predicate: the core's own
 * gimp_item_is_text/link/vector_layer, which report FALSE once the layer
 * behaves as pixels. For a link that means the monitor stopped — the
 * generic rasterizable flag can lag that state and is not consulted. */
static gboolean
source_is_editable (GimpLayer *layer,
                    uint32_t   kind)
{
  GimpItem *item = GIMP_ITEM (layer);

  switch (kind)
    {
    case GLIMS_LAYER_TEXT:
      return gimp_item_is_text_layer (item);
#if GIMP_CHECK_VERSION (3, 2, 0)
    case GLIMS_LAYER_LINK:
      return gimp_item_is_link_layer (item);
    case GLIMS_LAYER_VECTOR:
      return gimp_item_is_vector_layer (item);
#endif
    default:
      return FALSE;
    }
}

/* Whether the layer still carries its structured source: the retained
 * GimpText, the associated path, or the file link, which outlives the
 * monitor. Only meaningful for a structured class. */
static gboolean
source_is_retained (GimpLayer *layer,
                    uint32_t   kind)
{
  switch (kind)
    {
    case GLIMS_LAYER_TEXT:
      return gimp_text_layer_get_text (GIMP_TEXT_LAYER (layer)) != NULL;
#if GIMP_CHECK_VERSION (3, 2, 0)
    case GLIMS_LAYER_LINK:
      return gimp_link_layer_get_link (GIMP_LINK_LAYER (layer)) != NULL;
    case GLIMS_LAYER_VECTOR:
      return gimp_vector_layer_get_path (GIMP_VECTOR_LAYER (layer)) != NULL;
#endif
    default:
      return FALSE;
    }
}

/* The attached layer `id` of `image` — also a group — or with 0 the
 * first selected layer, or NULL. A stale or foreign id and a detached
 * item resolve to NULL. */
static GimpLayer *
find_source_layer (GimpImage   *image,
                   GlimsItemID  id)
{
  GimpItem *item;

  if (id == 0)
    {
      GList *selected = gimp_image_get_selected_layers (image);

      return selected ? selected->data : NULL;
    }

  item = gimp_item_get_by_id (image->gimp, id);
  if (! GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image ||
      ! gimp_item_is_attached (item))
    return NULL;

  return GIMP_LAYER (item);
}

GlimsStatus
glims_layer_source_info (GlimsEngine           *engine,
                         GlimsImageID           id,
                         GlimsItemID            layer_id,
                         GlimsLayerSourceInfo  *out,
                         char                 **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpLayer      *layer;

  (void) error;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! out || out->struct_size < sizeof (GlimsLayerSourceInfo))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  layer = find_source_layer (open->image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;

  memset (out, 0, sizeof (*out));
  out->struct_size   = sizeof (*out);
  out->source_kind   = source_kind_of (layer);
  out->is_rasterized = (out->source_kind == GLIMS_LAYER_TEXT ||
                        out->source_kind == GLIMS_LAYER_LINK ||
                        out->source_kind == GLIMS_LAYER_VECTOR) &&
                       ! source_is_editable (layer, out->source_kind);
  out->has_source    = source_is_retained (layer, out->source_kind);

  return GLIMS_STATUS_OK;
}

uint32_t
glims_layer_editable_source_kind (GimpLayer *layer)
{
  uint32_t kind = source_kind_of (layer);

  switch (kind)
    {
    case GLIMS_LAYER_TEXT:
    case GLIMS_LAYER_LINK:
    case GLIMS_LAYER_VECTOR:
      return source_is_editable (layer, kind) ? kind : 0;
    default:
      return 0;
    }
}

/* Rasterizes `layer` of `image` as one native undo step when it is a
 * genuine editable text, link or vector layer; an already rasterized
 * instance is a no-op without history. The caller has checked the
 * image's readiness and the layer's PIXELS|POSITION locks. */
GlimsStatus
glims_layer_rasterize (GimpImage  *image,
                       GimpLayer  *layer,
                       char      **error)
{
  uint32_t kind = source_kind_of (layer);

  switch (kind)
    {
    case GLIMS_LAYER_TEXT:
    case GLIMS_LAYER_LINK:
    case GLIMS_LAYER_VECTOR:
      if (! source_is_editable (layer, kind))
        {
          /* Already pixel-behaving — painted text, an unmonitored link
           * or a rasterized vector — with or without its source: no
           * undo step, nothing changes. */
          return GLIMS_STATUS_OK;
        }
#if GIMP_CHECK_VERSION (3, 2, 0)
      /* "Rasterize Text/Link/Vector Layer": one undo group around the
       * rasterizable undo record; the pixels and the source stay. */
      gimp_rasterizable_rasterize (GIMP_RASTERIZABLE (layer), TRUE);
#else
      /* Only text exists before 3.2: the set_buffer path's own
       * modified-undo plus "modified"=TRUE, which leaves the GimpText
       * and the buffer untouched. */
      gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_DRAWABLE_MOD,
                                   _("Rasterize Text Layer"));
      gimp_image_undo_push_text_layer_modified (image, NULL,
                                                GIMP_TEXT_LAYER (layer));
      g_object_set (layer, "modified", TRUE, NULL);
      gimp_image_undo_group_end (image);
#endif
      return GLIMS_STATUS_OK;

    case GLIMS_LAYER_GROUP:
      glims_fail (error, NULL,
                  "A layer group has no raster source; merge it or rasterize the layers inside it.");
      return GLIMS_STATUS_UNSUPPORTED;

    default:
      glims_fail (error, NULL,
                  "This layer is already ordinary pixels; only text, link and vector layers rasterize.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
}

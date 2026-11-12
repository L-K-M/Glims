/* Private Lab brush core fixture. Native seed/raw snapshots are independent
 * oracles; tested writes use only the private physical brush core. */
#include "engine-private.h"
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplist.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#include <float.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define W 96
#define H 48
#define PIXELS (W * H)
#define AXES 3
#define MAX_BYTES (PIXELS * sizeof(float))

static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c, msg) do { gboolean pass = !!(c); checks++; \
  printf("%s %s\n", pass ? "ok" : "FAIL", msg); \
  if (!pass) failures++; fflush(stdout); } while (0)

typedef struct {
  GlimsImageID id;
  GlimsItemID ids[AXES];
  uint32_t component;
  size_t bytes, sample_size;
  float mask[PIXELS];
  unsigned role, scenario;
} Scene;

typedef struct {
  Scene *scene;
  guint8 raw[AXES][MAX_BYTES];
  float mask[PIXELS];
  GBytes *map, *profile, *uuid[AXES], *visibility[AXES];
  char *names[AXES]; /* full native source names, not truncated oracle capture */
  uint32_t selected[AXES];
  GlimsItemID order[AXES], selection[AXES];
  guint selected_count;
  gboolean native_visible[AXES], locked[AXES];
  int undo, redo, layers;
  GimpPrecision precision;
  guint64 revision;
  guint component_mode;
  gboolean dirty;
  GFile *files[4];
} Snapshot;

static GBytes *parasite_bytes(const GimpParasite *p) {
  guint32 size = 0;
  const void *data = p ? gimp_parasite_get_data(p, &size) : NULL;
  return data ? g_bytes_new(data, size) : NULL;
}
static gboolean bytes_equal(GBytes *a, GBytes *b) {
  return (!a || !b) ? a == b : g_bytes_equal(a, b);
}
static void release_snapshot(Snapshot *s) {
  if (!s) return;
  g_clear_pointer(&s->map, g_bytes_unref);
  g_clear_pointer(&s->profile, g_bytes_unref);
  for (unsigned i = 0; i < AXES; i++) {
    g_clear_pointer(&s->uuid[i], g_bytes_unref);
    g_clear_pointer(&s->visibility[i], g_bytes_unref);
    g_free(s->names[i]); s->names[i] = NULL;
    g_clear_object(&s->files[i]);
  }
  g_clear_object(&s->files[3]);
}

static GlimsStatus capture_native(GlimsEngine *engine, gpointer data) {
  Snapshot *s = data;
  Scene *scene = s->scene;
  GlimsOpenImage *open = glims_lookup_image(engine, scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image = open->image;
  GlimsPlateStorage storage;
  gboolean valid = glims_plate_storage_read_open(open, &storage);
  for (unsigned a = 0; a < AXES; a++) {
    if (!scene->ids[a]) {
      if (!valid || storage.map.count != AXES) return GLIMS_STATUS_FAILED;
      scene->ids[a] = gimp_item_get_id(GIMP_ITEM(storage.planes[a]));
    }
    GimpItem *item = gimp_item_get_by_id(engine->gimp, scene->ids[a]);
    if (!item || !GIMP_IS_CHANNEL(item) || gimp_item_get_image(item) != image)
      return GLIMS_STATUS_FAILED;
    GimpDrawable *drawable = GIMP_DRAWABLE(item);
    if ((size_t)babl_format_get_bytes_per_pixel(gimp_drawable_get_format(drawable)) != scene->sample_size ||
        babl_format_get_n_components(gimp_drawable_get_format(drawable)) != 1) return GLIMS_STATUS_FAILED;
    gegl_buffer_get(gimp_drawable_get_buffer(drawable), GEGL_RECTANGLE(0, 0, W, H),
                    1, gimp_drawable_get_format(drawable), s->raw[a],
                    GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    s->names[a] = g_strdup(gimp_object_get_name(item)); /* full native name */
    s->uuid[a] = parasite_bytes(gimp_item_parasite_find(item, GLIMS_PLATE_UUID_PARASITE));
    s->visibility[a] = parasite_bytes(gimp_item_parasite_find(item, GLIMS_PLATE_VISIBLE_PARASITE));
    s->native_visible[a] = gimp_item_get_visible(item);
    s->locked[a] = gimp_item_get_lock_content(item);
  }
  s->map = parasite_bytes(gimp_image_parasite_find(image, GLIMS_PLATE_MAP_PARASITE));
  s->profile = parasite_bytes(gimp_image_parasite_find(image, GLIMS_PLATE_PROFILE_PARASITE));
  GList *order = gimp_image_get_channel_list(image);
  guint index = 0;
  for (GList *it = order; it && index < AXES; it = it->next)
    s->order[index++] = gimp_item_get_id(GIMP_ITEM(it->data));
  g_list_free(order);
  if (index != AXES) return GLIMS_STATUS_FAILED;
  gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(gimp_image_get_mask(image))),
                  GEGL_RECTANGLE(0, 0, W, H), 1, babl_format("Y float"), s->mask,
                  GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  for (unsigned a = 0; a < AXES; a++) s->selected[a] = 0;
  for (GList *it = gimp_image_get_selected_channels(image); it; it = it->next) {
    GlimsItemID sid = gimp_item_get_id(GIMP_ITEM(it->data));
    if (s->selected_count >= AXES) return GLIMS_STATUS_FAILED;
    s->selection[s->selected_count++] = sid;
    for (unsigned a = 0; a < AXES; a++)
      if (sid == scene->ids[a]) s->selected[a] = 1;
  }
  s->undo = gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image));
  s->redo = gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image));
  s->revision = open->history_revision;
  s->component_mode = open->component_mode;
  s->dirty = gimp_image_is_dirty(image);
  s->layers = gimp_container_get_n_children(gimp_image_get_layers(image));
  s->precision = gimp_image_get_precision(image);
  s->files[0] = gimp_image_get_file(image);
  s->files[1] = gimp_image_get_imported_file(image);
  s->files[2] = gimp_image_get_exported_file(image);
  s->files[3] = gimp_image_get_save_a_copy_file(image);
  for (unsigned i = 0; i < 4; i++) if (s->files[i]) g_object_ref(s->files[i]);
  return GLIMS_STATUS_OK;
}
static gboolean capture(GlimsEngine *engine, Scene *scene, Snapshot *s) {
  memset(s, 0, sizeof *s); s->scene = scene;
  gboolean ok = glims_engine_call(engine, capture_native, s) == GLIMS_STATUS_OK;
  CHECK(ok, "capture independent raw axes, metadata and native history");
  return ok;
}
static gboolean same_pixels(const Scene *scene, const Snapshot *a, const Snapshot *b) {
  for (unsigned i = 0; i < AXES; i++)
    if (memcmp(a->raw[i], b->raw[i], scene->bytes)) return FALSE;
  return TRUE;
}
static gboolean same_metadata(const Snapshot *a, const Snapshot *b) {
  if (!bytes_equal(a->map, b->map) || !bytes_equal(a->profile, b->profile) ||
      memcmp(a->mask, b->mask, sizeof a->mask) ||
      memcmp(a->order, b->order, sizeof a->order) ||
      a->selected_count != b->selected_count ||
      memcmp(a->selection, b->selection, sizeof a->selection) ||
      memcmp(a->native_visible, b->native_visible, sizeof a->native_visible) ||
      memcmp(a->locked, b->locked, sizeof a->locked) ||
      a->component_mode != b->component_mode ||
      a->layers != b->layers || a->precision != b->precision ||
      memcmp(a->selected, b->selected, sizeof a->selected)) return FALSE;
  for (unsigned i = 0; i < AXES; i++) {
    if (!bytes_equal(a->uuid[i], b->uuid[i]) ||
        !bytes_equal(a->visibility[i], b->visibility[i])) return FALSE;
    if ((!a->names[i] || !b->names[i]) ? a->names[i] != b->names[i] : strcmp(a->names[i], b->names[i]))
      return FALSE;
  }
  for (unsigned i = 0; i < 4; i++)
    if ((!a->files[i] || !b->files[i]) ? a->files[i] != b->files[i]
                                      : !g_file_equal(a->files[i], b->files[i])) return FALSE;
  return TRUE;
}
static gboolean same_history(const Snapshot *a, const Snapshot *b) {
  return a->undo == b->undo && a->redo == b->redo && a->revision == b->revision && a->dirty == b->dirty;
}


#include <math.h>
#include "lab-brush-core.h"
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpbrush-private.h"
#include "core/gimpbrushgenerated.h"
#include "core/gimpbrushpipe.h"
#include "core/gimpcontext.h"
#include "core/gimppaintinfo.h"
#include "core/gimpsymmetry.h"
#include "core/gimptempbuf.h"
#include "core/gimpviewable.h"
#include "paint/gimpbrushcore.h"
#include "paint/gimppaintoptions.h"

enum { HARD, HALF, SOFT, ZERO_OPACITY, OUTSIDE, CANCEL, LATE_NAN, BYTE_MASK, PIPE_MASK, PIPE_CANCEL };

static double physical(const Scene *s, unsigned role, const guint8 *raw, unsigned i) {
  if (s->sample_size == 1) return role == 0 ? 100.0*raw[i]/255.0 : (double)raw[i]-128.0;
  if (s->sample_size == 2) {
    guint16 q; memcpy(&q,raw+2*i,2);
    return role == 0 ? 100.0*q/65535.0 : (double)q/257.0-128.0;
  }
  float value; memcpy(&value,raw+4*i,4); return value;
}
static gboolean sample_literal(const Scene *s,const guint8 *raw,unsigned i,gboolean half) {
  if (s->sample_size == 1) return raw[i] == (s->role==0 ? (half?64:255) : (half?144:192));
  if (s->sample_size == 2) {
    guint16 q; memcpy(&q,raw+2*i,2);
    return q == (s->role==0 ? (half?16384:65535) : (half?37008:49344));
  }
  float value; memcpy(&value,raw+4*i,4);
  return value == (s->role==0 ? (half?25.0f:100.0f) : (half?16.0f:64.0f));
}
static gboolean center_literal(const Scene *s,const guint8 *raw,gboolean half) {
  return sample_literal(s,raw,24*W+16,half);
}
static GlimsStatus seed_native(GlimsEngine *engine,gpointer data) {
  Scene *s=data; GlimsOpenImage *open=glims_lookup_image(engine,s->id); GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open,&storage) || storage.map.count!=3) return GLIMS_STATUS_FAILED;
  guint8 *raw=g_malloc(MAX_BYTES); float *mask=g_new(float,PIXELS);
  for (unsigned a=0;a<3;a++) {
    GimpDrawable *d=GIMP_DRAWABLE(storage.planes[a]); s->ids[a]=gimp_item_get_id(GIMP_ITEM(d));
    for(unsigned i=0;i<PIXELS;i++) {
      if(s->sample_size==1) raw[i]=a?128:0;
      else if(s->sample_size==2) { guint16 q=a?32896:0; memcpy(raw+2*i,&q,2); }
      else { float q=0; memcpy(raw+4*i,&q,4); }
    }
    if(a==s->role && s->sample_size==4) {
      const guint32 nan=UINT32_C(0x7fc12345), minus_zero=UINT32_C(0x80000000);
      memcpy(raw,&nan,4); memcpy(raw+4,&minus_zero,4);
      if(s->scenario==LATE_NAN) memcpy(raw+4*(24*W+80),&nan,4);
      if(s->scenario==ZERO_OPACITY) memcpy(raw+4*(24*W+16),&nan,4);
    }
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),0,
                    gimp_drawable_get_format(d),raw,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d,0,0,W,H);
    const char *names[]={"axis named b", "axis named L", "axis named a"};
    gimp_object_set_name(GIMP_OBJECT(d),names[a]);
  }
  for(unsigned i=0;i<PIXELS;i++) mask[i]=(s->scenario==HALF || s->scenario==CANCEL)?0.5f:1.0f;
  GimpDrawable *selection=GIMP_DRAWABLE(gimp_image_get_mask(open->image));
  gegl_buffer_set(gimp_drawable_get_buffer(selection),GEGL_RECTANGLE(0,0,W,H),0,
                  babl_format("Y float"),mask,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(selection,0,0,W,H);
  gboolean nonempty=!gimp_channel_is_empty(GIMP_CHANNEL(selection));
  GList *selected=g_list_append(NULL,storage.planes[s->role]);
  gimp_image_set_selected_channels(open->image,selected); g_list_free(selected);
  GFile *file=g_file_new_for_uri("file:///private-lab-brush-source.xcf");
  gimp_image_set_file(open->image,file); gimp_image_set_imported_file(open->image,file);
  gimp_image_set_exported_file(open->image,file); gimp_image_set_save_a_copy_file(open->image,file);
  g_object_unref(file);
  gimp_image_undo_free(open->image); gimp_image_clean_all(open->image);
  /* Dirty, nonempty Undo and Redo witnesses make no-op/cancel preservation real. */
  GimpDrawable *other=GIMP_DRAWABLE(storage.planes[2]);
  guint8 sample[4];
  for(unsigned edit=0;edit<2;edit++) {
    if(s->sample_size==1) sample[0]=(guint8)(17+edit*25);
    else if(s->sample_size==2) { guint16 q=(guint16)((17+edit*25)*257); memcpy(sample,&q,2); }
    else { float q=edit?42.0f:0.375f; memcpy(sample,&q,4); }
    gimp_drawable_push_undo(other,"Fixture physical edit",NULL,W-1,H-1,1,1);
    gegl_buffer_set(gimp_drawable_get_buffer(other),GEGL_RECTANGLE(W-1,H-1,1,1),0,
                    gimp_drawable_get_format(other),sample,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(other,W-1,H-1,1,1);
  }
  gboolean undone=gimp_image_undo(open->image);
  g_free(raw); g_free(mask);
  return nonempty && undone ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}
static Scene *create_scene(GlimsEngine *engine,uint32_t component,unsigned role,unsigned scenario) {
  Scene *s=g_new0(Scene,1); s->component=component; s->role=role; s->scenario=scenario;
  s->sample_size=component==GLIMS_COLOR_COMPONENT_U8?1:component==GLIMS_COLOR_COMPONENT_U16?2:4;
  s->bytes=PIXELS*s->sample_size;
  char *error=NULL;
  GlimsStatus status=api->image_new_lab(engine,W,H,component,&s->id,&error);
  CHECK(status==GLIMS_STATUS_OK && s->id,"create real public Lab image for private writer");
  if(error) fprintf(stderr,"create: %s\n",error); api->free_string(error);
  if(status!=GLIMS_STATUS_OK || !s->id) {g_free(s); return NULL;}
  if(glims_engine_call(engine,seed_native,s)!=GLIMS_STATUS_OK) {
    CHECK(FALSE,"independent seed succeeds"); api->image_close(engine,s->id); g_free(s); return NULL;
  }
  return s;
}
static GimpBrush *private_brush(gboolean bytes) {
  if(!bytes) return GIMP_BRUSH(gimp_brush_generated_new("Private Lab core test",
      GIMP_BRUSH_GENERATED_CIRCLE,10,2,1.0,1.0,0));
  /* Same constructor/setup as upstream gimpbrush-load.c, no resource/global edits. */
  GimpBrush *brush=g_object_new(GIMP_TYPE_BRUSH,"name","Private byte mask",
                                "mime-type","image/x-gimp-gbr",NULL);
  brush->priv->mask=gimp_temp_buf_new(11,11,babl_format("Y u8"));
  memset(gimp_temp_buf_get_data(brush->priv->mask),255,121);
  brush->priv->x_axis.x=5.5; brush->priv->x_axis.y=0;
  brush->priv->y_axis.x=0; brush->priv->y_axis.y=5.5;
  brush->priv->spacing=15;
  return brush;
}
/* Real native pipe with two distinct, same-sized monochrome members. Setup
 * mirrors gimpbrushpipe-load.c: the parent borrows the first member's mask.
 * Default set_params(NULL) gives deterministic incremental selection. */
static GimpBrush *private_pipe(void) {
  GimpBrushPipe *pipe=g_object_new(GIMP_TYPE_BRUSH_PIPE,"name","Private two-member Lab pipe",
                                   "mime-type","image/x-gimp-gih",NULL);
  pipe->n_brushes=2;pipe->brushes=g_new0(GimpBrush*,2);
  for(unsigned member=0;member<2;member++) {
    pipe->brushes[member]=private_brush(TRUE);
    guint8 *mask=gimp_temp_buf_get_data(pipe->brushes[member]->priv->mask);
    memset(mask,0,121);
    for(unsigned k=0;k<11;k++)mask[member?11*k+5:11*5+k]=255;
  }
  if(!gimp_brush_pipe_set_params(pipe,NULL)){g_object_unref(pipe);return NULL;}
  pipe->current=pipe->brushes[0];
  GimpBrush *brush=GIMP_BRUSH(pipe);
  brush->priv->spacing=pipe->current->priv->spacing;
  brush->priv->x_axis=pipe->current->priv->x_axis;
  brush->priv->y_axis=pipe->current->priv->y_axis;
  brush->priv->mask=pipe->current->priv->mask;
  brush->priv->pixmap=pipe->current->priv->pixmap;
  return brush;
}
static GlimsStatus paint_native(GlimsEngine *engine,gpointer data) {
  Scene *s=data; GlimsOpenImage *open=glims_lookup_image(engine,s->id); GlimsPlateStorage storage;
  if(!open || !glims_plate_storage_read_open(open,&storage)) return GLIMS_STATUS_FAILED;
  GimpDrawable *drawable=GIMP_DRAWABLE(storage.planes[s->role]);
  gboolean is_pipe=s->scenario==PIPE_MASK || s->scenario==PIPE_CANCEL;
  GimpBrush *brush=is_pipe?private_pipe():private_brush(s->scenario==BYTE_MASK);
  GimpPaintInfo *info=glims_paint_info_for_tool(engine->gimp,GLIMS_PAINT_PAINTBRUSH);
  if(!brush || !info) {g_clear_object(&brush); return GLIMS_STATUS_FAILED;}
  gboolean soft=s->scenario==SOFT;
  GlimsBrushSettings settings={.struct_size=sizeof settings,.size=soft?23:11,
    .opacity=1,.tool=GLIMS_PAINT_PAINTBRUSH,.hardness=soft?.5:1,
    .rate=-1,.flow=-1,.exposure=-1};
  GimpPaintOptions *options=glims_make_paint_options(engine->gimp,info,&settings,brush);
  g_object_set(options,"brush-spacing",.15,"brush-angle",soft?.17:0,
      "brush-aspect-ratio",soft?3.0:0.0,"brush-hardness",soft?.5:1.0,
      "hard",!soft && s->scenario!=BYTE_MASK,"use-applicator",FALSE,NULL);
  gimp_paint_options_enable_dynamics(options,FALSE);
  double opacity=s->scenario==ZERO_OPACITY?0:s->scenario==HALF?.5:1;
  GlimsLabFormat format=s->sample_size==1?GLIMS_LAB_FORMAT_U8:s->sample_size==2?GLIMS_LAB_FORMAT_U16:GLIMS_LAB_FORMAT_FLOAT;
  GimpPaintCore *core=glims_lab_brush_core_new((GlimsLabRole)s->role,format,s->role?64:100,opacity);
  if(!core) {g_object_unref(options);g_object_unref(brush);return GLIMS_STATUS_FAILED;}
  GList *drawables=g_list_prepend(NULL,drawable);
  gpointer weak_core=core,weak_options=options,weak_brush=brush;
  gpointer weak_members[2]={NULL,NULL};
  if(is_pipe)for(unsigned i=0;i<2;i++){weak_members[i]=GIMP_BRUSH_PIPE(brush)->brushes[i];
    g_object_add_weak_pointer(G_OBJECT(weak_members[i]),&weak_members[i]);}
  g_object_add_weak_pointer(G_OBJECT(core),&weak_core);
  g_object_add_weak_pointer(G_OBJECT(options),&weak_options);
  g_object_add_weak_pointer(G_OBJECT(brush),&weak_brush);
  GeglBuffer *selection=gimp_drawable_get_buffer(GIMP_DRAWABLE(gimp_image_get_mask(open->image)));
  g_object_ref(selection); guint selection_refs=G_OBJECT(selection)->ref_count;
  CHECK(!gimp_viewable_preview_is_frozen(GIMP_VIEWABLE(drawable)),"target preview initially unfrozen");
  GimpCoords first=GIMP_COORDS_DEFAULT_VALUES;
  first.x=s->scenario==OUTSIDE?-64:soft?12.25:16.5;
  first.y=s->scenario==OUTSIDE?-64:soft?20.75:24.5; first.pressure=1;
  GError *error=NULL;
  gboolean started=gimp_paint_core_start(core,drawables,options,&first,&error);
  CHECK(started,"physical core starts on explicit scalar Lab axis");
  if(error) fprintf(stderr,"start: %s\n",error->message);g_clear_error(&error);
  if(started) {
    CHECK(core->mask_buffer==selection,"nonempty selection held by native stroke core");
    core->last_coords=first;
    gimp_paint_core_paint(core,drawables,options,GIMP_PAINT_STATE_INIT,1);
    gimp_paint_core_paint(core,drawables,options,GIMP_PAINT_STATE_MOTION,1);
    CHECK(glims_lab_brush_core_error(core)==NULL,"first dab has no physical-kernel error");
    guint8 *after_first=g_malloc(s->bytes),*after_second=g_malloc(s->bytes);
    gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,W,H),1,
                    gimp_drawable_get_format(drawable),after_first,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    if(is_pipe) {
      GimpBrushPipe *pipe=GIMP_BRUSH_PIPE(brush);
      CHECK(GIMP_IS_BRUSH_PIPE(brush) && GIMP_BRUSH_CORE(core)->main_brush==brush,
        "actual native pipe drives the brush core");
      CHECK(pipe->current==pipe->brushes[1],"native incremental pipe selects vertical member for first dab");
      CHECK(sample_literal(s,after_first,21*W+16,FALSE) && physical(s,s->role,after_first,24*W+19)==0,
        "first pipe dab writes vertical arm and leaves horizontal arm unchanged");
      core->cur_coords=first;core->cur_coords.x=48.5;
      gimp_paint_core_paint(core,drawables,options,GIMP_PAINT_STATE_MOTION,20);
      CHECK(glims_lab_brush_core_error(core)==NULL && pipe->current==pipe->brushes[0],
        "next native pipe dab switches to horizontal member");
      gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,W,H),1,
        gimp_drawable_get_format(drawable),after_second,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      CHECK(sample_literal(s,after_second,24*W+51,FALSE) && physical(s,s->role,after_second,21*W+48)==0,
        "second pipe dab writes horizontal arm and leaves vertical arm unchanged");
      CHECK(sample_literal(s,after_second,21*W+16,FALSE),"changing pipe member retains first physical dab");
    }
    if(s->scenario==HALF) CHECK(center_literal(s,after_first,TRUE),"one hard dab applies quantized selection and physical opacity once");
    if(soft || s->scenario==HALF) {
      GimpCoords end=first; end.x=soft?83.75:20.5; end.y=soft?27.25:first.y;
      gimp_paint_core_interpolate(core,drawables,options,&end,33);
      CHECK(glims_lab_brush_core_error(core)==NULL,"native interpolated dabs remain valid");
      gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,W,H),1,
                      gimp_drawable_get_format(drawable),after_second,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      CHECK(memcmp(after_first,after_second,s->bytes)!=0,"interpolation actually publishes additional covered pixels");
      if(s->scenario==HALF) CHECK(center_literal(s,after_second,TRUE),"overlapping hard dabs reuse stroke original; opacity is not accumulated");
    }
    if(s->scenario==LATE_NAN) {
      CHECK(core->x1!=core->x2 && core->y1!=core->y2,"first finite dab really changed pixels before later failure");
      core->cur_coords=first; core->cur_coords.x=80.5;
      gimp_paint_core_paint(core,drawables,options,GIMP_PAINT_STATE_MOTION,34);
      CHECK(glims_lab_brush_core_error(core)!=NULL,"later affected NaN produces a sticky writer error");
      gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,W,H),1,
                      gimp_drawable_get_format(drawable),after_second,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      CHECK(memcmp(after_first,after_second,s->bytes)==0,"failing later dab publishes no partial rows");
    }
    CHECK(core->paint_buffer==NULL && core->applicators==NULL,"physical writes never create RGB paint buffer/applicator");
    gimp_paint_core_paint(core,drawables,options,GIMP_PAINT_STATE_FINISH,35);
    gboolean damaged=core->x1!=core->x2 && core->y1!=core->y2;
    gboolean abort=s->scenario==CANCEL || s->scenario==PIPE_CANCEL || s->scenario==LATE_NAN || s->scenario==ZERO_OPACITY || s->scenario==OUTSIDE;
    if(abort && damaged) gimp_paint_core_cancel(core,drawables);
    else gimp_paint_core_finish(core,drawables,!abort);
    CHECK(!gimp_viewable_preview_is_frozen(GIMP_VIEWABLE(drawable)),"changed cancel or zero-damage finish thaws exactly once");
    if(s->scenario==CANCEL || s->scenario==PIPE_CANCEL) CHECK(damaged,"cancel witness contains a successfully published dab");
    if(s->scenario==ZERO_OPACITY || s->scenario==OUTSIDE) CHECK(!damaged,"zero/outside stroke declares no damage");
    g_free(after_first);g_free(after_second);
  }
  gimp_paint_core_cleanup(core);
  CHECK(g_hash_table_size(core->undo_buffers)==0 && !core->canvas_buffer && !core->paint_buffer,
        "native cleanup releases owned undo/canvas/paint buffers");
  g_list_free(drawables);g_object_unref(core);g_object_unref(options);g_object_unref(brush);
  CHECK(!weak_core && !weak_options && !weak_brush,"private core/options/brush all finalize");
  if(is_pipe)CHECK(!weak_members[0] && !weak_members[1],"both native pipe member brushes finalize");
  CHECK(G_OBJECT(selection)->ref_count==selection_refs,"nonempty selection buffer reference count restored after finalization");
  g_object_unref(selection);
  return started?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
}

static void exercise(GlimsEngine *engine,uint32_t component,unsigned role,unsigned scenario) {
  printf("TRIAL component=%u role=%u scenario=%u\n",component,role,scenario);fflush(stdout);
  Scene *s=create_scene(engine,component,role,scenario);if(!s)return;
  Snapshot *before=g_new0(Snapshot,1),*after=g_new0(Snapshot,1),*undone=g_new0(Snapshot,1),*redone=g_new0(Snapshot,1);
  if(!capture(engine,s,before))goto done;
  CHECK(before->undo==1 && before->redo==1 && before->dirty,"fixture begins with genuine Undo, Redo and dirty state");
  if(scenario==HALF && component==GLIMS_COLOR_COMPONENT_FLOAT)
    CHECK(before->mask[24*W+16]==.5f,"float selection half-mask is exactly representable");
  CHECK(glims_engine_call(engine,paint_native,s)==GLIMS_STATUS_OK,"private physical core callback completed");
  if(!capture(engine,s,after))goto done;
  CHECK(same_metadata(before,after),"all metadata, UUIDs, selection, names and file identities remain exact");
  gboolean others=TRUE;
  for(unsigned a=0;a<AXES;a++)if(a!=role && memcmp(before->raw[a],after->raw[a],s->bytes))others=FALSE;
  CHECK(others,"both other authoritative axes are unchanged");
  gboolean aborted=scenario==PIPE_CANCEL || scenario==ZERO_OPACITY || scenario==OUTSIDE || scenario==CANCEL || scenario==LATE_NAN;
  if(aborted) {
    CHECK(same_pixels(s,before,after),"no-op/cancel restores every source byte including nonfinite payloads");
    CHECK(same_history(before,after),"no-op/cancel preserves exact existing Undo/Redo/revision/dirty state");
  } else {
    CHECK(!same_pixels(s,before,after),"committed physical stroke changed actual samples");
    CHECK(after->undo==before->undo+1 && after->redo==0,"one changed stroke contributes exactly one native Undo step");
    if(scenario==HARD || scenario==BYTE_MASK || scenario==PIPE_MASK) CHECK(center_literal(s,after->raw[role],FALSE),"fully covered center equals independent physical endpoint bytes");
    if(scenario==HALF) CHECK(center_literal(s,after->raw[role],TRUE),"half-selection half-opacity center equals fixed endpoint literal");
    unsigned changed=0,fractional=0;gboolean bounds=TRUE;
    for(unsigned i=0;i<PIXELS;i++) {
      if(!memcmp(before->raw[role]+i*s->sample_size,after->raw[role]+i*s->sample_size,s->sample_size))continue;
      changed++;
      double old=physical(s,role,before->raw[role],i),value=physical(s,role,after->raw[role],i),target=role?64:100;
      if(!isfinite(value) || value<fmin(old,target) || value>fmax(old,target))bounds=FALSE;
      if(value>fmin(old,target) && value<fmax(old,target))fractional++;
    }
    CHECK(changed>0 && bounds,"all changed physical samples remain inside original/target interval");
    if(scenario==SOFT)CHECK(changed>20 && fractional>10,"soft interpolation creates genuinely fractional physical coverage");
    if(s->sample_size==4)CHECK(!memcmp(before->raw[role],after->raw[role],8),"NaN payload and negative zero outside coverage remain exact");
    CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"one public Undo succeeds");
    if(capture(engine,s,undone))CHECK(same_pixels(s,before,undone) && same_metadata(before,undone),"one Undo restores exact original axes and metadata");
    CHECK(api->image_redo(engine,s->id)==GLIMS_STATUS_OK,"one public Redo succeeds");
    if(capture(engine,s,redone))CHECK(same_pixels(s,after,redone) && same_metadata(after,redone),"one Redo restores exact committed axes and metadata");
  }
done:
  release_snapshot(before);release_snapshot(after);release_snapshot(undone);release_snapshot(redone);
  g_free(before);g_free(after);g_free(undone);g_free(redone);
  CHECK(api->image_close(engine,s->id)==GLIMS_STATUS_OK,"owned image closes after native core cleanup");g_free(s);
}

/* Optional observation, deliberately no wall-time assertion. Same 64 small
 * native dabs on canvases whose areas differ by >300x. Creation, stroke-start
 * snapshots and first-mask costs are kept separate from subsequent dabs. */
typedef struct {GlimsImageID image;int width,height,trial;} TimingTrial;
static GlimsStatus seed_timing_canvas(GlimsEngine *engine,gpointer data) {
  TimingTrial *trial=data;GlimsOpenImage *open=glims_lookup_image(engine,trial->image);
  GlimsPlateStorage storage;
  if(!open || !glims_plate_storage_read_open(open,&storage))return GLIMS_STATUS_FAILED;
  GimpDrawable *target=GIMP_DRAWABLE(storage.planes[0]);
  const Babl *format=gimp_drawable_get_format(target);
  if(babl_format_get_bytes_per_pixel(format)!=1 || babl_format_get_n_components(format)!=1)
    return GLIMS_STATUS_FAILED;
  /* Materialize the whole authoritative target using one bounded row buffer.
   * Values 1..254 ensure both stroke endpoints actually change to black. */
  guint8 *row=g_malloc(trial->width);
  for(int y=0;y<trial->height;y++) {
    for(int x=0;x<trial->width;x++)row[x]=(guint8)(1+(13*x+7*y)%254);
    gegl_buffer_set(gimp_drawable_get_buffer(target),GEGL_RECTANGLE(0,y,trial->width,1),0,
      format,row,GEGL_AUTO_ROWSTRIDE);
  }
  g_free(row);gimp_drawable_update(target,0,0,trial->width,trial->height);
  return GLIMS_STATUS_OK;
}
static GlimsStatus time_small_stroke(GlimsEngine *engine,gpointer data) {
  TimingTrial *trial=data;GlimsOpenImage *open=glims_lookup_image(engine,trial->image);
  GlimsPlateStorage storage;
  if(!open || !glims_plate_storage_read_open(open,&storage))return GLIMS_STATUS_FAILED;
  GimpDrawable *drawable=GIMP_DRAWABLE(storage.planes[0]);
  GList *drawables=g_list_prepend(NULL,drawable);
  gimp_image_set_selected_channels(open->image,drawables);
  const Babl *format=gimp_drawable_get_format(drawable);
  guint8 before=0,painted=255,restored=0;
  gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(64,64,1,1),1,
    format,&before,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(before==11,"timing trial starts with independent patterned U8 Lightness sample");
  int depth=gimp_undo_stack_get_depth(gimp_image_get_undo_stack(open->image));
  GimpBrush *brush=private_brush(FALSE);
  GimpPaintInfo *info=glims_paint_info_for_tool(engine->gimp,GLIMS_PAINT_PAINTBRUSH);
  if(!brush || !info){g_clear_object(&brush);g_list_free(drawables);return GLIMS_STATUS_FAILED;}
  GlimsBrushSettings settings={.struct_size=sizeof settings,.size=11,.opacity=1,
    .tool=GLIMS_PAINT_PAINTBRUSH,.hardness=1,.rate=-1,.flow=-1,.exposure=-1};
  GimpPaintOptions *options=glims_make_paint_options(engine->gimp,info,&settings,brush);
  g_object_set(options,"brush-spacing",.15,"brush-angle",0.0,"brush-aspect-ratio",0.0,
    "brush-hardness",1.0,"hard",TRUE,"use-applicator",FALSE,NULL);
  gimp_paint_options_enable_dynamics(options,FALSE);
  GimpPaintCore *core=glims_lab_brush_core_new(GLIMS_LAB_ROLE_L,GLIMS_LAB_FORMAT_U8,0,1);
  if(!core){g_object_unref(options);g_object_unref(brush);g_list_free(drawables);return GLIMS_STATUS_FAILED;}
  GimpCoords first=GIMP_COORDS_DEFAULT_VALUES;first.x=64.5;first.y=64.5;first.pressure=1;
  GError *error=NULL;gint64 start=g_get_monotonic_time();
  gboolean started=gimp_paint_core_start(core,drawables,options,&first,&error);
  if(!started){if(error)fprintf(stderr,"timing start: %s\n",error->message);g_clear_error(&error);
    gimp_paint_core_cleanup(core);g_object_unref(core);g_object_unref(options);g_object_unref(brush);
    g_list_free(drawables);return GLIMS_STATUS_FAILED;}
  core->last_coords=first;
  gimp_paint_core_paint(core,drawables,options,GIMP_PAINT_STATE_INIT,1);
  gint64 initialized=g_get_monotonic_time();
  gimp_paint_core_paint(core,drawables,options,GIMP_PAINT_STATE_MOTION,1);
  gint64 first_done=g_get_monotonic_time();
  for(unsigned i=1;i<64 && !glims_lab_brush_core_error(core);i++) {
    core->cur_coords=first;core->cur_coords.x+=8*(i%8);core->cur_coords.y+=8*(i/8);
    gimp_paint_core_paint(core,drawables,options,GIMP_PAINT_STATE_MOTION,i+1);
  }
  gint64 dabs_done=g_get_monotonic_time();
  gboolean valid=glims_lab_brush_core_error(core)==NULL;
  CHECK(valid,"timing stroke completes all physical dabs without error");
  gimp_paint_core_paint(core,drawables,options,GIMP_PAINT_STATE_FINISH,65);
  if(valid)gimp_paint_core_finish(core,drawables,TRUE);
  else if(core->x1!=core->x2 && core->y1!=core->y2)gimp_paint_core_cancel(core,drawables);
  else gimp_paint_core_finish(core,drawables,FALSE);
  gimp_paint_core_cleanup(core);
  g_object_unref(core);g_object_unref(options);g_object_unref(brush);g_list_free(drawables);
  gint64 finished=g_get_monotonic_time();
  printf("AREA_TIMING {\"width\":%d,\"height\":%d,\"trial\":%d,\"dabs\":64,\"size\":11,"
    "\"start_init_us\":%" G_GINT64_FORMAT ",\"first_dab_us\":%" G_GINT64_FORMAT
    ",\"remaining_63_dabs_us\":%" G_GINT64_FORMAT ",\"finish_cleanup_us\":%" G_GINT64_FORMAT "}\n",
    trial->width,trial->height,trial->trial,initialized-start,first_done-initialized,
    dabs_done-first_done,finished-dabs_done);fflush(stdout);
  if(valid) {
    gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(64,64,1,1),1,
      format,&painted,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    guint8 last=255;gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(120,120,1,1),1,
      format,&last,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    CHECK(painted==0 && last==0,"timing includes real first and last physical pixel writes");
    CHECK(gimp_undo_stack_get_depth(gimp_image_get_undo_stack(open->image))==depth+1,
      "timing stroke creates exactly one native Undo");
    CHECK(gimp_image_undo(open->image),"undo timing stroke outside measured interval");
    gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(64,64,1,1),1,
      format,&restored,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    CHECK(restored==before,"timing Undo restores source before repeated trial");
  }
  return valid?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
}
static void area_timing(GlimsEngine *engine) {
  const int widths[]={256,6000},heights[]={256,4000};GlimsImageID images[2]={0};
  for(unsigned i=0;i<2;i++) {
    char *error=NULL;gint64 started=g_get_monotonic_time();
    GlimsStatus result=api->image_new_lab(engine,widths[i],heights[i],GLIMS_COLOR_COMPONENT_U8,&images[i],&error);
    printf("AREA_CREATE width=%d height=%d elapsed_us=%" G_GINT64_FORMAT "\n",widths[i],heights[i],g_get_monotonic_time()-started);
    CHECK(result==GLIMS_STATUS_OK && images[i],"create bounded timing canvas");
    if(error)fprintf(stderr,"timing image: %s\n",error);api->free_string(error);
    if(images[i]) {
      TimingTrial seed={images[i],widths[i],heights[i],0};started=g_get_monotonic_time();
      CHECK(glims_engine_call(engine,seed_timing_canvas,&seed)==GLIMS_STATUS_OK,"materialize complete nonuniform timing target");
      printf("AREA_SEED width=%d height=%d elapsed_us=%" G_GINT64_FORMAT "\n",widths[i],heights[i],g_get_monotonic_time()-started);
    }
  }
  /* Interleave dimensions and reverse order on the middle trial. */
  for(unsigned repeat=0;repeat<3;repeat++)for(unsigned order=0;order<2;order++) {
    unsigned i=repeat==1?1-order:order;if(!images[i])continue;
    TimingTrial trial={images[i],widths[i],heights[i],(int)repeat};
    CHECK(glims_engine_call(engine,time_small_stroke,&trial)==GLIMS_STATUS_OK,"bounded timing callback succeeds");
  }
  for(unsigned i=0;i<2;i++)if(images[i])CHECK(api->image_close(engine,images[i])==GLIMS_STATUS_OK,"close owned timing canvas");
}
int main(int argc,char **argv) {
  if(argc!=2 && !(argc==3 && !strcmp(argv[2],"--area-timing")))return 2;
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api || api->struct_size<offsetof(GlimsEngineAPI,image_fill_lab)+sizeof api->image_fill_lab || !api->image_new_lab)return 2;
  char *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL),*error=NULL;
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;
  GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);
  if(status!=GLIMS_STATUS_OK || !engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}
  api->free_string(error);
  const uint32_t components[]={GLIMS_COLOR_COMPONENT_U8,GLIMS_COLOR_COMPONENT_U16,GLIMS_COLOR_COMPONENT_FLOAT};
  for(unsigned c=0;c<3;c++) {
    for(unsigned role=0;role<3;role++) {exercise(engine,components[c],role,HARD);exercise(engine,components[c],role,HALF);}
    exercise(engine,components[c],1,SOFT);exercise(engine,components[c],1,BYTE_MASK);
    exercise(engine,components[c],1,PIPE_MASK);exercise(engine,components[c],1,PIPE_CANCEL);
    exercise(engine,components[c],0,ZERO_OPACITY);exercise(engine,components[c],0,OUTSIDE);exercise(engine,components[c],1,CANCEL);
  }
  exercise(engine,GLIMS_COLOR_COMPONENT_FLOAT,0,LATE_NAN);
  if(argc==3)area_timing(engine);
  api->stop(engine);printf("checks=%u failures=%u\n",checks,failures);return failures?1:0;
}

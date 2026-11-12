/* Independent slots195/196 fixture. Native callbacks seed/capture raw state;
 * selection writes always use the public facade. No display/projection oracle. */
#include "engine-private.h"
#include "plate-storage.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#include "core/gimpparasitelist.h"
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpbrushgenerated.h"
#include "core/gimpcontext.h"
#include <float.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define W 64
#define H 48
#define N (W * H)
#define AXES 3
#define MAX_BYTES (N * sizeof(float))
#define WAIT_US (10 * G_TIME_SPAN_SECOND)
static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c, label) do { gboolean ok_ = !!(c); checks++; \
  printf("%s %s\n", ok_ ? "ok" : "FAIL", label); \
  if (!ok_) failures++; fflush(stdout); } while (0)

typedef struct {
  GlimsImageID id;
  GlimsItemID ids[AXES];
  guint8 uuids[AXES][16];
  uint32_t component;
  size_t sample_size, bytes;
  unsigned mask_kind; /* 0: empty/no selection, 1: patterned, 2: full */
  unsigned bad; /* 1/2: late NaN/Inf source, 3: masked NaN, 4/5: late bad mask */
} Scene;
typedef struct {
  Scene *scene;
  guint8 raw[AXES][MAX_BYTES];
  float mask[N];
  guint8 mask_raw[MAX_BYTES];
  size_t mask_bytes;
  GBytes *map, *profile, *uuid[AXES], *visibility[AXES];
  char *names[AXES];
  GFile *files[4];
  GlimsItemID order[AXES], selected[AXES];
  guint selected_count, component_mode;
  gboolean locks[AXES], native_visible[AXES], dirty;
  int undo, redo, layers;
  GimpPrecision precision;
  guint64 revision;
} Snapshot;

static GBytes *parasite_copy(const GimpParasite *p) {
  guint32 size = 0; const void *data = p ? gimp_parasite_get_data(p, &size) : NULL;
  return data ? g_bytes_new(data, size) : NULL;
}
static gboolean same_bytes(GBytes *a, GBytes *b) {
  return (!a || !b) ? a == b : g_bytes_equal(a, b);
}
static void snapshot_free(Snapshot *s) {
  if (!s) return;
  g_clear_pointer(&s->map, g_bytes_unref); g_clear_pointer(&s->profile, g_bytes_unref);
  for (unsigned a = 0; a < AXES; a++) {
    g_clear_pointer(&s->uuid[a], g_bytes_unref);
    g_clear_pointer(&s->visibility[a], g_bytes_unref); g_free(s->names[a]);
  }
  for (unsigned i = 0; i < 4; i++) g_clear_object(&s->files[i]);
  g_free(s);
}
static GlimsStatus capture_native(GlimsEngine *engine, gpointer data) {
  Snapshot *s = data; Scene *scene = s->scene;
  GlimsOpenImage *open = glims_lookup_image(engine, scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image = open->image;
  for (unsigned a = 0; a < AXES; a++) {
    /* Cached IDs intentionally permit independent capture of damaged maps. */
    GimpItem *item = gimp_item_get_by_id(engine->gimp, scene->ids[a]);
    if (!item || !GIMP_IS_CHANNEL(item) || !gimp_item_is_attached(item) ||
        gimp_item_get_image(item) != image) return GLIMS_STATUS_FAILED;
    GimpDrawable *d = GIMP_DRAWABLE(item);
    const Babl *format = gimp_drawable_get_format(d);
    if (babl_format_get_n_components(format) != 1 ||
        (size_t)babl_format_get_bytes_per_pixel(format) != scene->sample_size)
      return GLIMS_STATUS_FAILED;
    gegl_buffer_get(gimp_drawable_get_buffer(d), GEGL_RECTANGLE(0,0,W,H), 1,
                    format, s->raw[a], GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    s->uuid[a] = parasite_copy(gimp_item_parasite_find(item, GLIMS_PLATE_UUID_PARASITE));
    s->visibility[a] = parasite_copy(gimp_item_parasite_find(item, GLIMS_PLATE_VISIBLE_PARASITE));
    s->names[a] = g_strdup(gimp_object_get_name(item));
    s->locks[a] = gimp_item_get_lock_content(item);
    s->native_visible[a] = gimp_item_get_visible(item);
  }
  s->map = parasite_copy(gimp_image_parasite_find(image, GLIMS_PLATE_MAP_PARASITE));
  s->profile = parasite_copy(gimp_image_parasite_find(image, GLIMS_PLATE_PROFILE_PARASITE));
  gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(gimp_image_get_mask(image))),
                  GEGL_RECTANGLE(0,0,W,H), 1, babl_format("Y float"), s->mask,
                  GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(image));
  const Babl *mask_format=gimp_drawable_get_format(mask);
  size_t mask_sample=(size_t)babl_format_get_bytes_per_pixel(mask_format);
  if(mask_sample>4 || babl_format_get_n_components(mask_format)!=1)return GLIMS_STATUS_FAILED;
  s->mask_bytes=N*mask_sample;
  gegl_buffer_get(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(0,0,W,H),1,mask_format,
    s->mask_raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  GList *order = gimp_image_get_channel_list(image); unsigned count = 0;
  for (GList *it = order; it; it = it->next) {
    if (count >= AXES) { g_list_free(order); return GLIMS_STATUS_FAILED; }
    s->order[count++] = gimp_item_get_id(GIMP_ITEM(it->data));
  }
  g_list_free(order); if (count != AXES) return GLIMS_STATUS_FAILED;
  for (GList *it = gimp_image_get_selected_channels(image); it; it = it->next) {
    if (s->selected_count >= AXES) return GLIMS_STATUS_FAILED;
    s->selected[s->selected_count++] = gimp_item_get_id(GIMP_ITEM(it->data));
  }
  s->undo = gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image));
  s->redo = gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image));
  s->revision = open->history_revision; s->dirty = gimp_image_is_dirty(image);
  s->component_mode = open->component_mode;
  s->precision = gimp_image_get_precision(image);
  s->layers = gimp_container_get_n_children(gimp_image_get_layers(image));
  s->files[0] = gimp_image_get_file(image); s->files[1] = gimp_image_get_imported_file(image);
  s->files[2] = gimp_image_get_exported_file(image); s->files[3] = gimp_image_get_save_a_copy_file(image);
  for (unsigned i = 0; i < 4; i++) if (s->files[i]) g_object_ref(s->files[i]);
  return GLIMS_STATUS_OK;
}
static Snapshot *capture(GlimsEngine *engine, Scene *scene) {
  Snapshot *s = g_new0(Snapshot, 1); s->scene = scene;
  gboolean ok = glims_engine_call(engine, capture_native, s) == GLIMS_STATUS_OK;
  CHECK(ok, "capture independent raw Lab planes, metadata and history");
  if (!ok) { snapshot_free(s); return NULL; }
  return s;
}
static gboolean pixels_equal(const Scene *scene, const Snapshot *a, const Snapshot *b) {
  for (unsigned i = 0; i < AXES; i++) if (memcmp(a->raw[i], b->raw[i], scene->bytes)) return FALSE;
  return TRUE;
}
static gboolean history_equal(const Snapshot *a, const Snapshot *b) {
  return a->undo == b->undo && a->redo == b->redo && a->revision == b->revision && a->dirty == b->dirty;
}
static gboolean metadata_equal(const Snapshot *a, const Snapshot *b) {
  if (!same_bytes(a->map,b->map) || !same_bytes(a->profile,b->profile) ||
      memcmp(a->order,b->order,sizeof a->order) ||
      a->selected_count != b->selected_count || memcmp(a->selected,b->selected,sizeof a->selected) ||
      memcmp(a->locks,b->locks,sizeof a->locks) || memcmp(a->native_visible,b->native_visible,sizeof a->native_visible) ||
      a->component_mode != b->component_mode || a->precision != b->precision || a->layers != b->layers) return FALSE;
  for (unsigned i=0;i<AXES;i++)
    if (!same_bytes(a->uuid[i],b->uuid[i]) || !same_bytes(a->visibility[i],b->visibility[i]) ||
        g_strcmp0(a->names[i],b->names[i])) return FALSE;
  for (unsigned i=0;i<4;i++)
    if ((!a->files[i] || !b->files[i]) ? a->files[i]!=b->files[i] : !g_file_equal(a->files[i],b->files[i])) return FALSE;
  return TRUE;
}
static gboolean mask_equal(const Snapshot *a,const Snapshot *b) {
  return a->mask_bytes==b->mask_bytes && !memcmp(a->mask_raw,b->mask_raw,a->mask_bytes) &&
    !memcmp(a->mask,b->mask,sizeof a->mask);
}
static gboolean source_equal(const Scene *s, const Snapshot *a, const Snapshot *b) {
  return pixels_equal(s,a,b) && mask_equal(a,b) && metadata_equal(a,b) && history_equal(a,b);
}


static GlimsStatus seed_native(GlimsEngine *engine,gpointer data) {
  Scene *s=data;GlimsOpenImage *open=glims_lookup_image(engine,s->id);GlimsPlateStorage storage;
  if(!open || !glims_plate_storage_read_open(open,&storage) || storage.map.count!=3)return GLIMS_STATUS_FAILED;
  guint8 *raw=g_malloc(MAX_BYTES);
  for(unsigned a=0;a<3;a++) {
    GimpDrawable *d=GIMP_DRAWABLE(storage.planes[a]);GimpItem *item=GIMP_ITEM(d);s->ids[a]=gimp_item_get_id(item);
    memcpy(s->uuids[a],storage.map.entries[a].uuid,16);
    for(unsigned i=0;i<N;i++) {
      if(s->sample_size==1)raw[i]=a?128+a*10+i%13:0;
      else if(s->sample_size==2){guint16 value=a?(128+a*10+i%13)*257:0;memcpy(raw+2*i,&value,2);}
      else {float value=a?(float)((int)(i%17)-8)*(a==1?1.f:-.5f):0;memcpy(raw+4*i,&value,4);}
    }
    if(a==2 && s->sample_size==4) {
      guint32 nan=UINT32_C(0x7fc12345),negzero=UINT32_C(0x80000000);
      memcpy(raw+12,&nan,4);memcpy(raw+16,&negzero,4);
    }
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),0,gimp_drawable_get_format(d),raw,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d,0,0,W,H);
    const char *names[]={"Not a role L","Not a role b","Not a role a"};gimp_object_set_name(GIMP_OBJECT(item),names[a]);
  }
  g_free(raw);
  GList *selected=g_list_append(NULL,storage.planes[0]);gimp_image_set_selected_channels(open->image,selected);g_list_free(selected);
  GFile *file=g_file_new_for_uri("file:///lab-selection-source.xcf");
  gimp_image_set_file(open->image,file);gimp_image_set_imported_file(open->image,file);
  gimp_image_set_exported_file(open->image,file);gimp_image_set_save_a_copy_file(open->image,file);g_object_unref(file);
  gimp_image_undo_free(open->image);gimp_image_clean_all(open->image);
  /* Native baseline has genuine nonempty Undo and Redo and dirty state. */
  GimpDrawable *d=GIMP_DRAWABLE(storage.planes[2]);guint8 values[2][4]={{17},{42}};
  if(s->sample_size==2){guint16 a=17*257,b=42*257;memcpy(values[0],&a,2);memcpy(values[1],&b,2);}
  if(s->sample_size==4){float a=.375f,b=42.f;memcpy(values[0],&a,4);memcpy(values[1],&b,4);}
  for(unsigned i=0;i<2;i++) {
    gimp_drawable_push_undo(d,"Fixture axis witness",NULL,W-1,H-1,1,1);
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(W-1,H-1,1,1),0,gimp_drawable_get_format(d),values[i],GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d,W-1,H-1,1,1);
  }
  return gimp_image_undo(open->image)?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
}
static Scene *create_scene(GlimsEngine *engine,uint32_t component) {
  Scene *s=g_new0(Scene,1);s->component=component;s->sample_size=component==GLIMS_COLOR_COMPONENT_U8?1:component==GLIMS_COLOR_COMPONENT_U16?2:4;s->bytes=N*s->sample_size;
  char *error=NULL;GlimsStatus status=api->image_new_lab(engine,W,H,component,&s->id,&error);
  CHECK(status==GLIMS_STATUS_OK && s->id,"create real native Lab selection fixture");api->free_string(error);
  if(status!=GLIMS_STATUS_OK || !s->id){g_free(s);return NULL;}
  if(glims_engine_call(engine,seed_native,s)!=GLIMS_STATUS_OK){CHECK(FALSE,"independent seed succeeds");api->image_close(engine,s->id);g_free(s);return NULL;}
  return s;
}
static void close_scene(GlimsEngine *engine,Scene *s){if(s){if(s->id)CHECK(api->image_close(engine,s->id)==GLIMS_STATUS_OK,"close owned selection fixture");g_free(s);}}
static GlimsLabSelectOptions options(uint32_t operation) {
  return (GlimsLabSelectOptions){.struct_size=sizeof(GlimsLabSelectOptions),.operation=operation,.antialias=0};
}
static GlimsStatus shape(GlimsEngine *engine,Scene *s,uint32_t kind,const GlimsPoint *points,size_t count,const GlimsLabSelectOptions *settings) {
  char *error=NULL;GlimsStatus result=api->image_select_lab_shape(engine,s->id,kind,points,count,settings,&error);
  if(error)fprintf(stderr,"shape: %s\n",error);api->free_string(error);return result;
}
static GlimsStatus command(GlimsEngine *engine,Scene *s,uint32_t value) {
  char *error=NULL;GlimsStatus result=api->image_select_lab_command(engine,s->id,value,&error);
  if(error)fprintf(stderr,"command: %s\n",error);api->free_string(error);return result;
}
static gboolean binary_mask(const Snapshot *s){for(unsigned i=0;i<N;i++)if(s->mask[i]!=0 && s->mask[i]!=1)return FALSE;return TRUE;}
static gboolean rectangle_mask(const Snapshot *s,int x1,int y1,int x2,int y2) {
  for(int y=0;y<H;y++)for(int x=0;x<W;x++)if(s->mask[y*W+x]!=(x>=x1 && x<x2 && y>=y1 && y<y2?1.f:0.f))return FALSE;
  return TRUE;
}
static void unchanged_axes(const Scene *s,const Snapshot *before,const Snapshot *after) {
  if(before && after)CHECK(pixels_equal(s,before,after)&&metadata_equal(before,after),
    "selection leaves exact raw axes, NaN payloads, identities, locks and file state unchanged");
}
static void check_change(GlimsEngine *engine,Scene *s,const Snapshot *before,const Snapshot *after) {
  if(!before || !after)return;
  unchanged_axes(s,before,after);
  CHECK(!mask_equal(before,after),"accepted selection changes actual native root mask");
  CHECK(after->undo==before->undo+1 && after->redo==0,"one changed selection creates one native Undo");
  CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"Undo selection succeeds");Snapshot *undone=capture(engine,s);
  if(undone)CHECK(mask_equal(before,undone)&&pixels_equal(s,before,undone)&&metadata_equal(before,undone),"Undo restores exact mask and authoritative source");
  snapshot_free(undone);CHECK(api->image_redo(engine,s->id)==GLIMS_STATUS_OK,"Redo selection succeeds");Snapshot *redone=capture(engine,s);
  if(redone)CHECK(mask_equal(after,redone)&&pixels_equal(s,after,redone)&&metadata_equal(after,redone),"Redo restores exact selected mask and source");snapshot_free(redone);
}
static void bounds_rectangle(GlimsEngine *engine,Scene *s,int x,int y,int w,int h) {
  bool empty=true;GlimsRect bounds={0};CHECK(api->selection_bounds(engine,s->id,&empty,&bounds)==GLIMS_STATUS_OK && !empty &&
    bounds.x==x && bounds.y==y && bounds.width==w && bounds.height==h,"public bounds agree with literal mask after cached full-mask changes");
  GlimsSegment edges[1024];int32_t count=0;
  CHECK(api->selection_outline(engine,s->id,edges,1024,&count)==GLIMS_STATUS_OK && count>0 && count<=1024,"native selected mask has actual marching-ant segments");
  gboolean sane=TRUE;for(int i=0;i<count && i<1024;i++)if(edges[i].x1<x || edges[i].x1>x+w || edges[i].x2<x || edges[i].x2>x+w ||
      edges[i].y1<y || edges[i].y1>y+h || edges[i].y2<y || edges[i].y2>y+h)sane=FALSE;
  CHECK(sane,"all rectangle ants lie within exact selection boundary");
}
static void shapes_and_operations(GlimsEngine *engine,uint32_t component) {
  printf("SHAPES component=%u\n",component);Scene *s=create_scene(engine,component);if(!s)return;
  GlimsLabSelectOptions opt=options(GLIMS_SELECT_REPLACE);GlimsPoint rect[]={{10,8},{30,24}};
  CHECK(command(engine,s,GLIMS_SELECT_ALL)==GLIMS_STATUS_OK,"Select All enters full-mask cache state");
  Snapshot *before=capture(engine,s);CHECK(shape(engine,s,GLIMS_SHAPE_RECTANGLE,rect,2,&opt)==GLIMS_STATUS_OK,"replace full mask with rectangle");
  Snapshot *after=capture(engine,s);if(after)CHECK(rectangle_mask(after,10,8,30,24),"every rectangle mask sample equals literal inside1/outside0");
  check_change(engine,s,before,after);bounds_rectangle(engine,s,10,8,20,16);snapshot_free(before);snapshot_free(after);
  before=capture(engine,s);CHECK(command(engine,s,GLIMS_SELECT_INVERT)==GLIMS_STATUS_OK,"invert rectangle after full-to-shape cache transition");after=capture(engine,s);
  if(before && after){gboolean exact=TRUE;for(unsigned i=0;i<N;i++)if(after->mask[i]!=1.f-before->mask[i])exact=FALSE;CHECK(exact,"Invert is literal complement of every binary mask sample");}
  check_change(engine,s,before,after);snapshot_free(before);snapshot_free(after);
  before=capture(engine,s);CHECK(command(engine,s,GLIMS_SELECT_NONE)==GLIMS_STATUS_OK,"Select None succeeds");after=capture(engine,s);
  if(after)CHECK(rectangle_mask(after,0,0,0,0),"None clears all mask samples");check_change(engine,s,before,after);snapshot_free(before);snapshot_free(after);
  bool empty=false;GlimsRect bounds={0};CHECK(api->selection_bounds(engine,s->id,&empty,&bounds)==GLIMS_STATUS_OK && empty,"None reports empty selection bounds");
  for(uint32_t operation=GLIMS_SELECT_REPLACE;operation<=GLIMS_SELECT_INTERSECT;operation++) {
    CHECK(shape(engine,s,GLIMS_SHAPE_RECTANGLE,rect,2,&opt)==GLIMS_STATUS_OK,"establish operation base rectangle");before=capture(engine,s);
    GlimsPoint second[]={{20,16},{40,32}};GlimsLabSelectOptions combined=options(operation);
    CHECK(shape(engine,s,GLIMS_SHAPE_RECTANGLE,second,2,&combined)==GLIMS_STATUS_OK,"combine rectangle with owned selection operation");after=capture(engine,s);
    if(after){gboolean exact=TRUE;for(int y=0;y<H;y++)for(int x=0;x<W;x++) {
      gboolean a=x>=10&&x<30&&y>=8&&y<24,b=x>=20&&x<40&&y>=16&&y<32;
      gboolean wanted=operation==GLIMS_SELECT_REPLACE?b:operation==GLIMS_SELECT_ADD?a||b:operation==GLIMS_SELECT_SUBTRACT?a&&!b:a&&b;
      if(after->mask[y*W+x]!=(wanted?1.f:0.f))exact=FALSE;
    }CHECK(exact,"Replace/Add/Subtract/Intersect match independent binary set oracle");}
    check_change(engine,s,before,after);snapshot_free(before);snapshot_free(after);
  }
  /* Standalone hard masks are witnesses for independent Boolean combination.
   * Polygon B is also constrained by the literal full-mask oracle above. */
  for(unsigned kind=GLIMS_SHAPE_ELLIPSE;kind<=GLIMS_SHAPE_POLYGON;kind++) {
    GlimsPoint bpoints[]={{20,16},{40,16},{40,32},{20,32}};
    GlimsPoint bellipse[]={{20,16},{40,32}};const GlimsPoint *bp=kind==GLIMS_SHAPE_ELLIPSE?bellipse:bpoints;
    size_t count=kind==GLIMS_SHAPE_ELLIPSE?2:4;
    CHECK(shape(engine,s,kind,bp,count,&opt)==GLIMS_STATUS_OK,"rasterize independent standalone hard shape witness");
    Snapshot *bmask=capture(engine,s);
    if(bmask)CHECK(binary_mask(bmask),"standalone hard shape witness is binary");
    for(unsigned op=0;op<=GLIMS_SELECT_INTERSECT;op++) {
      CHECK(shape(engine,s,GLIMS_SHAPE_RECTANGLE,rect,2,&opt)==GLIMS_STATUS_OK,"reset operation source mask");before=capture(engine,s);
      GlimsLabSelectOptions combine=options(op);CHECK(shape(engine,s,kind,bp,count,&combine)==GLIMS_STATUS_OK,"ellipse/polygon accepts each set operation");after=capture(engine,s);
      if(before&&after&&bmask){gboolean exact=TRUE;for(unsigned i=0;i<N;i++) {
        gboolean a=before->mask[i]==1,b=bmask->mask[i]==1;
        gboolean expected=op==0?b:op==1?a||b:op==2?a&&!b:a&&b;
        if(after->mask[i]!=(expected?1.f:0.f))exact=FALSE;
      }CHECK(exact,"ellipse/polygon combination matches independent Boolean oracle");}
      check_change(engine,s,before,after);snapshot_free(before);snapshot_free(after);
    }
    snapshot_free(bmask);
  }
  GlimsPoint offscreen[]={{-8,-6},{14,10}};before=capture(engine,s);
  CHECK(shape(engine,s,GLIMS_SHAPE_RECTANGLE,offscreen,2,&opt)==GLIMS_STATUS_OK,"off-canvas rectangle rasterizes without changing geometry");after=capture(engine,s);
  if(after)CHECK(rectangle_mask(after,0,0,14,10),"off-canvas rectangle clips only at image edges");check_change(engine,s,before,after);snapshot_free(before);snapshot_free(after);
  GlimsPoint ellipse[]={{8,8},{40,32}};before=capture(engine,s);CHECK(shape(engine,s,GLIMS_SHAPE_ELLIPSE,ellipse,2,&opt)==GLIMS_STATUS_OK,"hard ellipse accepted");after=capture(engine,s);
  if(after)CHECK(binary_mask(after)&&after->mask[20*W+24]==1&&after->mask[8*W+8]==0&&after->mask[40*W+50]==0,"ellipse has literal solid center/empty corners and hard binary boundary");
  check_change(engine,s,before,after);snapshot_free(before);snapshot_free(after);
  GlimsPoint polygon[]={{6,5},{22,5},{22,19},{6,19}};before=capture(engine,s);
  CHECK(shape(engine,s,GLIMS_SHAPE_POLYGON,polygon,4,&opt)==GLIMS_STATUS_OK,"closed quadrilateral lasso accepted");after=capture(engine,s);
  if(after)CHECK(rectangle_mask(after,6,5,22,19),"polygon raster matches independent literal rectangle mask");check_change(engine,s,before,after);snapshot_free(before);snapshot_free(after);
  for(unsigned smooth=0;smooth<3;smooth++) {
    GlimsLabSelectOptions soft=opt;soft.antialias=1;if(smooth==1)soft.feather=2;if(smooth==2)soft.corner_radius=6;
    before=capture(engine,s);CHECK(shape(engine,s,smooth==2?GLIMS_SHAPE_RECTANGLE:GLIMS_SHAPE_ELLIPSE,ellipse,2,&soft)==GLIMS_STATUS_OK,"AA/feather/rounded mask geometry accepted");after=capture(engine,s);
    if(after){unsigned partial=0;gboolean finite=TRUE;for(unsigned i=0;i<N;i++){float v=after->mask[i];if(!isfinite(v)||v<0||v>1)finite=FALSE;if(v>0&&v<1)partial++;}
      CHECK(finite&&partial>0,"AA/feather/rounded geometry produces bounded genuine fractional coverage");}
    check_change(engine,s,before,after);snapshot_free(before);snapshot_free(after);
  }
  /* A valid outside-only shape is a successful native no-op mask; history is native-defined. */
  CHECK(command(engine,s,GLIMS_SELECT_NONE)==GLIMS_STATUS_OK,"clear before outside-only geometry");before=capture(engine,s);
  GlimsPoint outside[]={{-30,-30},{-10,-10}};CHECK(shape(engine,s,GLIMS_SHAPE_RECTANGLE,outside,2,&opt)==GLIMS_STATUS_OK,"valid outside-only shape succeeds");after=capture(engine,s);
  if(before&&after)CHECK(mask_equal(before,after)&&pixels_equal(s,before,after)&&metadata_equal(before,after),"outside-only no-op preserves mask and all source bytes");snapshot_free(before);snapshot_free(after);
  close_scene(engine,s);
}

static void verify_roundtrip(GlimsEngine *engine,Scene *s,const char *work) {
  GlimsLabSelectOptions opt=options(GLIMS_SELECT_REPLACE);opt.antialias=1;opt.feather=1.5;
  GlimsPoint points[]={{9,7},{41,35}};CHECK(shape(engine,s,GLIMS_SHAPE_ELLIPSE,points,2,&opt)==GLIMS_STATUS_OK,"prepare fractional selection for XCF");
  Snapshot *before=capture(engine,s);char *path=g_strdup_printf("%s/lab-selection-%u.xcf",work,s->component),*error=NULL;
  GlimsImageID reopened=0;GlimsStatus result=api->image_save(engine,s->id,path,&error);
  CHECK(result==GLIMS_STATUS_OK,"save native Lab selection and samples");api->free_string(error);error=NULL;
  if(result!=GLIMS_STATUS_OK)goto done;
  Snapshot *saved=capture(engine,s);if(before&&saved)CHECK(mask_equal(before,saved)&&pixels_equal(s,before,saved),"saving does not alter mask or axis bytes");snapshot_free(saved);
  result=api->image_open(engine,path,&reopened,&error);CHECK(result==GLIMS_STATUS_OK&&reopened,"reopen selected Lab XCF");api->free_string(error);
  if(reopened){GlimsLabAxes axes={.struct_size=sizeof axes};Scene copy=*s;copy.id=reopened;
    gboolean valid=api->image_lab_axes(engine,reopened,&axes)==GLIMS_STATUS_OK&&axes.count==3&&axes.component==s->component;
    for(unsigned i=0;i<3&&valid;i++){valid=axes.axes[i].role==i&&!memcmp(axes.axes[i].uuid,s->uuids[i],16);copy.ids[i]=axes.axes[i].id;}
    CHECK(valid,"reopened document retains role, UUID and precision without relying on native ID equality");
    if(valid&&before){Snapshot *actual=capture(engine,&copy);if(actual){gboolean exact=mask_equal(before,actual)&&pixels_equal(s,before,actual)&&same_bytes(before->map,actual->map)&&same_bytes(before->profile,actual->profile);
      for(unsigned a=0;a<3;a++)exact=exact&&same_bytes(before->uuid[a],actual->uuid[a])&&same_bytes(before->visibility[a],actual->visibility[a])&&g_strcmp0(before->names[a],actual->names[a])==0&&before->locks[a]==actual->locks[a];
      CHECK(exact,"XCF retains exact raw selection, all axes including NaN and identity metadata");}snapshot_free(actual);}
    CHECK(api->image_close(engine,reopened)==GLIMS_STATUS_OK,"close owned reopened selected document");}
done:snapshot_free(before);g_free(path);
}
static GlimsStatus install_brush(GlimsEngine *engine,gpointer unused) {
  (void)unused;GimpBrush *brush=GIMP_BRUSH(gimp_brush_generated_new("Private Lab selection fixture brush",GIMP_BRUSH_GENERATED_CIRCLE,10,2,1,1,0));
  if(!brush)return GLIMS_STATUS_FAILED;gimp_context_set_brush(gimp_get_user_context(engine->gimp),brush);g_object_unref(brush);return GLIMS_STATUS_OK;
}
static GlimsStatus fill_lightness(GlimsEngine *engine,Scene *s) {
  GlimsLabFillSettings fill={.struct_size=sizeof fill,.axis=s->ids[0],.role=0,.value=100,.opacity=1};memcpy(fill.uuid,s->uuids[0],16);
  char *error=NULL;GlimsStatus result=api->image_fill_lab(engine,s->id,&fill,&error);if(error)fprintf(stderr,"fill: %s\n",error);api->free_string(error);return result;
}
static GlimsStatus start_brush(GlimsEngine *engine,Scene *s,double x,double y,double size,GlimsStrokeID *stroke) {
  GlimsLabBrushSettings settings={.struct_size=sizeof settings,.axis=s->ids[0],.role=0,.value=100,.opacity=1,.size=size,.hardness=1};memcpy(settings.uuid,s->uuids[0],16);
  GlimsStrokeSampleV2 point={.struct_size=sizeof point,.x=x,.y=y,.pressure=1,.time_ms=1};
  GlimsStrokePacketV2 input={.struct_size=sizeof input,.sample_stride=sizeof point,.samples=&point,.count=1,.byte_count=sizeof point};char *error=NULL;
  GlimsStatus result=api->stroke_begin_lab(engine,s->id,0,&settings,&input,stroke,&error);
  if(error)fprintf(stderr,"brush: %s\n",error);api->free_string(error);return result;
}
static gboolean lightness_literal(const Scene *s,const guint8 *raw,unsigned index,gboolean white) {
  if(s->sample_size==1)return raw[index]==(white?255:0);
  if(s->sample_size==2){guint16 value;memcpy(&value,raw+2*index,2);return value==(white?65535:0);}
  float value;memcpy(&value,raw+4*index,4);return value==(white?100.f:0.f);
}
static void edits_obey_mask(GlimsEngine *engine,uint32_t component,const char *work) {
  Scene *s=create_scene(engine,component);if(!s)return;Snapshot *initial=capture(engine,s);
  GlimsLabSelectOptions opt=options(GLIMS_SELECT_REPLACE);GlimsPoint points[]={{10,8},{30,24}};
  CHECK(shape(engine,s,GLIMS_SHAPE_RECTANGLE,points,2,&opt)==GLIMS_STATUS_OK,"establish public mask for actual edits");Snapshot *selected=capture(engine,s);
  CHECK(fill_lightness(engine,s)==GLIMS_STATUS_OK,"Lab Fill consumes public selection");Snapshot *filled=capture(engine,s);
  if(filled&&selected){gboolean exact=TRUE;for(unsigned i=0;i<N;i++)if(!lightness_literal(s,filled->raw[0],i,selected->mask[i]==1))exact=FALSE;
    CHECK(exact,"Fill writes physical white only inside literal selection");
    CHECK(mask_equal(selected,filled)&&metadata_equal(selected,filled)&&!memcmp(selected->raw[1],filled->raw[1],s->bytes)&&!memcmp(selected->raw[2],filled->raw[2],s->bytes),"Fill preserves mask, other axes and metadata");}
  CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"Undo Fill separately from selection");Snapshot *undone=capture(engine,s);
  if(selected&&undone)CHECK(pixels_equal(s,selected,undone)&&mask_equal(selected,undone),"Undo Fill keeps exact selected mask");snapshot_free(undone);
  CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"next Undo removes selection edit");undone=capture(engine,s);
  if(initial&&undone)CHECK(pixels_equal(s,initial,undone)&&mask_equal(initial,undone),"second Undo restores initial source and no-selection state");snapshot_free(undone);
  CHECK(api->image_redo(engine,s->id)==GLIMS_STATUS_OK,"restore selection for physical brush witness");
  GlimsStrokeID stroke=0;CHECK(start_brush(engine,s,20.5,16.5,31,&stroke)==GLIMS_STATUS_OK&&stroke,"start large brush straddling selection edge");
  if(stroke)CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"commit physical selected brush");Snapshot *painted=capture(engine,s);
  if(painted&&selected)CHECK(lightness_literal(s,painted->raw[0],16*W+20,TRUE)&&lightness_literal(s,painted->raw[0],5*W+20,FALSE)&&
    mask_equal(selected,painted)&&!memcmp(selected->raw[1],painted->raw[1],s->bytes)&&!memcmp(selected->raw[2],painted->raw[2],s->bytes),
    "Brush changes fully covered interior, clips covered exterior and preserves other axes/mask");
  CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"Undo selected brush");
  if(component==GLIMS_COLOR_COMPONENT_FLOAT) {
    opt.antialias=1;opt.feather=2;CHECK(shape(engine,s,GLIMS_SHAPE_RECTANGLE,points,2,&opt)==GLIMS_STATUS_OK,"create public fractional mask for arithmetic witness");
    Snapshot *soft=capture(engine,s);unsigned fractional=N;
    if(soft)for(unsigned i=0;i<N;i++)if(soft->mask[i]>.1f&&soft->mask[i]<.9f){fractional=i;break;}
    CHECK(fractional<N,"fractional edit witness has nontrivial coverage");
    CHECK(fill_lightness(engine,s)==GLIMS_STATUS_OK,"physical Fill through fractional public mask");Snapshot *softfill=capture(engine,s);
    if(soft&&softfill){gboolean exact=TRUE;for(unsigned i=0;i<N;i++){float actual;memcpy(&actual,softfill->raw[0]+4*i,4);float expected=(float)(100.0*(double)soft->mask[i]);if(actual!=expected)exact=FALSE;}
      CHECK(exact,"float Fill applies measured selection coverage once to physical zero-to100");}
    CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"Undo fractional Fill before brush oracle");
    if(fractional<N){stroke=0;CHECK(start_brush(engine,s,(fractional%W)+.5,(fractional/W)+.5,11,&stroke)==GLIMS_STATUS_OK&&stroke,"begin brush centered on fractional selection pixel");
      if(stroke)CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"commit fractional brush");Snapshot *softbrush=capture(engine,s);
      if(softbrush&&soft){float actual;memcpy(&actual,softbrush->raw[0]+4*fractional,4);float expected=(float)(100.0*(double)soft->mask[fractional]);CHECK(actual==expected&&mask_equal(soft,softbrush),"fully covered brush center applies fractional selection exactly once");}snapshot_free(softbrush);
      CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"Undo fractional brush");}
    snapshot_free(soft);snapshot_free(softfill);
  }
  CHECK(command(engine,s,GLIMS_SELECT_NONE)==GLIMS_STATUS_OK,"None before whole-axis Fill");CHECK(fill_lightness(engine,s)==GLIMS_STATUS_OK,"empty mask means unrestricted physical Fill");
  Snapshot *whole=capture(engine,s);if(whole){gboolean exact=TRUE;for(unsigned i=0;i<N;i++)if(!lightness_literal(s,whole->raw[0],i,TRUE))exact=FALSE;CHECK(exact,"None fills every target sample, not zero pixels");}snapshot_free(whole);
  verify_roundtrip(engine,s,work);
  snapshot_free(initial);snapshot_free(selected);snapshot_free(filled);snapshot_free(painted);close_scene(engine,s);
}
static void expect_unchanged(GlimsEngine *engine,Scene *s,const Snapshot *before,const char *label) {
  Snapshot *after=capture(engine,s);if(before&&after)CHECK(source_equal(s,before,after),label);snapshot_free(after);
}
static void refuse_shape(GlimsEngine *engine,Scene *s,GlimsImageID image,uint32_t kind,const GlimsPoint *points,size_t count,const GlimsLabSelectOptions *opt,GlimsStatus expected) {
  Snapshot *before=capture(engine,s);char *error=(char*)(uintptr_t)1;
  GlimsStatus result=api->image_select_lab_shape(engine,image,kind,points,count,opt,&error);
  if(result!=expected)fprintf(stderr,"shape refusal got=%d wanted=%d\n",result,expected);
  CHECK(result==expected,"shape invalid/readiness refusal has precise status");CHECK(error!=(char*)(uintptr_t)1,"shape entry clears caller error before admission");
  if(error!=(char*)(uintptr_t)1)api->free_string(error);
  expect_unchanged(engine,s,before,"refused shape preserves exact mask, raw axes, metadata and history");snapshot_free(before);
}
static void refuse_command(GlimsEngine *engine,Scene *s,GlimsImageID image,uint32_t cmd,GlimsStatus expected) {
  Snapshot *before=capture(engine,s);char *error=(char*)(uintptr_t)1;
  GlimsStatus result=api->image_select_lab_command(engine,image,cmd,&error);
  if(result!=expected)fprintf(stderr,"command refusal got=%d wanted=%d\n",result,expected);
  CHECK(result==expected,"command invalid/readiness refusal has precise status");CHECK(error!=(char*)(uintptr_t)1,"command entry clears caller error before admission");if(error!=(char*)(uintptr_t)1)api->free_string(error);
  expect_unchanged(engine,s,before,"refused command preserves exact mask/source/history");snapshot_free(before);
}
static void invalid_input(GlimsEngine *engine) {
  Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT);if(!s)return;
  GlimsPoint good[]={{8,8},{30,30}},bad[3]={{8,8},{30,30},{20,20}};GlimsLabSelectOptions opt=options(0);
  refuse_shape(engine,s,INT32_MAX,1,good,2,&opt,GLIMS_STATUS_NOT_FOUND);
  refuse_shape(engine,s,s->id,1,NULL,2,&opt,GLIMS_STATUS_INVALID_ARGUMENT);
  refuse_shape(engine,s,s->id,1,good,2,NULL,GLIMS_STATUS_INVALID_ARGUMENT);
  for(unsigned k=0;k<10;k++) {
    GlimsLabSelectOptions invalid=opt;
    switch(k){case 0:invalid.struct_size=sizeof invalid-1;break;case 1:invalid.operation=4;break;case 2:invalid.antialias=2;break;
    case 3:invalid.feather=-.1;break;case 4:invalid.feather=NAN;break;case 5:invalid.feather=INFINITY;break;case 6:invalid.feather=1000.01;break;
    case 7:invalid.corner_radius=-1;break;case 8:invalid.corner_radius=NAN;break;case 9:invalid.corner_radius=1000.01;break;}
    refuse_shape(engine,s,s->id,1,good,2,&invalid,GLIMS_STATUS_INVALID_ARGUMENT);
  }
  for(unsigned k=0;k<9;k++) {
    memcpy(bad,good,sizeof good);bad[2]=(GlimsPoint){20,20};size_t count=2;uint32_t kind=1;
    switch(k){case 0:bad[1].x=NAN;break;case 1:bad[1].y=INFINITY;break;case 2:bad[1].x=1048576.01;break;case 3:bad[0].y=-1048576.01;break;
    case 4:bad[1].x=bad[0].x;break;case 5:kind=0;break;case 6:count=3;break;case 7:kind=3;count=2;break;case 8:kind=3;count=65537;break;}
    refuse_shape(engine,s,s->id,kind,bad,count,&opt,GLIMS_STATUS_INVALID_ARGUMENT);
  }
  refuse_shape(engine,s,s->id,3,good,SIZE_MAX,&opt,GLIMS_STATUS_INVALID_ARGUMENT);
  GlimsPoint late_bad[]={{8,8},{30,8},{30,30},{8,NAN}};
  refuse_shape(engine,s,s->id,GLIMS_SHAPE_POLYGON,late_bad,4,&opt,GLIMS_STATUS_INVALID_ARGUMENT);

  for(unsigned cmd=0;cmd<=10;cmd++)if(cmd<1||cmd>3)refuse_command(engine,s,s->id,cmd,GLIMS_STATUS_UNSUPPORTED);
  refuse_command(engine,s,INT32_MAX,GLIMS_SELECT_ALL,GLIMS_STATUS_NOT_FOUND);
  /* Short prefix placed immediately before a protected page: no tail read. */
  size_t page=(size_t)sysconf(_SC_PAGESIZE);guint8 *pages=mmap(NULL,page*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
  CHECK(pages!=MAP_FAILED,"allocate short-prefix guard pages");
  if(pages!=MAP_FAILED){CHECK(mprotect(pages+page,page,PROT_NONE)==0,"protect unreadable options tail");guint32 short_size=4;memcpy(pages+page-4,&short_size,4);
    refuse_shape(engine,s,s->id,1,good,2,(const GlimsLabSelectOptions*)(pages+page-4),GLIMS_STATUS_INVALID_ARGUMENT);munmap(pages,page*2);}
  /* Forward prefix and arbitrary alignment are explicitly supported. */
  guint8 option_bytes[sizeof opt+18],point_bytes[sizeof good+2],saved_options[sizeof option_bytes],saved_points[sizeof point_bytes];
  memset(option_bytes,0xa5,sizeof option_bytes);memset(point_bytes,0x5a,sizeof point_bytes);
  GlimsLabSelectOptions extended=opt;extended.struct_size=sizeof opt+16;
  memcpy(option_bytes+1,&extended,sizeof extended);memcpy(point_bytes+1,good,sizeof good);memcpy(saved_options,option_bytes,sizeof option_bytes);memcpy(saved_points,point_bytes,sizeof point_bytes);
  CHECK(shape(engine,s,1,(const GlimsPoint*)(point_bytes+1),2,(const GlimsLabSelectOptions*)(option_bytes+1))==GLIMS_STATUS_OK,"unaligned points/options and ignored future tail accepted");
  CHECK(!memcmp(saved_options,option_bytes,sizeof option_bytes)&&!memcmp(saved_points,point_bytes,sizeof point_bytes),"borrowed inputs and extension canaries unchanged");
  Snapshot *unaligned=capture(engine,s);if(unaligned)CHECK(rectangle_mask(unaligned,8,8,30,30),"unaligned geometry retains literal raster");snapshot_free(unaligned);
  GlimsPoint fraction[]={{12.5,14.5},{12.5,14.5}};CHECK(shape(engine,s,1,fraction,2,&opt)==GLIMS_STATUS_OK,"equal fractional endpoints have positive floor/ceil extent");
  Snapshot *one=capture(engine,s);if(one)CHECK(rectangle_mask(one,12,14,13,15),"floor/ceil extent is exactly one pixel");snapshot_free(one);
  GlimsPoint limits[]={{-GLIMS_LAB_SELECT_COORDINATE_LIMIT,-GLIMS_LAB_SELECT_COORDINATE_LIMIT},
    {GLIMS_LAB_SELECT_COORDINATE_LIMIT,GLIMS_LAB_SELECT_COORDINATE_LIMIT}};
  CHECK(shape(engine,s,GLIMS_SHAPE_RECTANGLE,limits,2,&opt)==GLIMS_STATUS_OK,"exact inclusive coordinate limits accepted before clipping");
  Snapshot *full=capture(engine,s);if(full)CHECK(rectangle_mask(full,0,0,W,H),"extreme finite rectangle clips to exact full native mask");snapshot_free(full);
  GlimsPoint *many=g_new(GlimsPoint,GLIMS_LAB_SELECT_MAX_POINTS);
  many[0]=(GlimsPoint){8,8};many[1]=(GlimsPoint){30,8};for(unsigned i=2;i<GLIMS_LAB_SELECT_MAX_POINTS;i++)many[i]=(GlimsPoint){8,30};
  CHECK(shape(engine,s,3,many,GLIMS_LAB_SELECT_MAX_POINTS,&opt)==GLIMS_STATUS_OK,"maximum polygon count accepted without truncation");g_free(many);
  close_scene(engine,s);
}

enum { NO_AXIS, MULTIPLE_AXES, LOCKED_AXES, FROZEN_UNDO, GROUPED_UNDO, ENGINE_BUSY, BAD_UUID };
typedef struct {Scene *scene;unsigned kind;gboolean restore;GimpParasite *uuid;} Mutation;
static GlimsStatus mutate_native(GlimsEngine *engine,gpointer data) {
  Mutation *m=data;GlimsOpenImage *open=glims_lookup_image(engine,m->scene->id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  GimpItem *axis=gimp_item_get_by_id(engine->gimp,m->scene->ids[0]);if(!axis)return GLIMS_STATUS_NOT_FOUND;
  switch(m->kind) {
  case NO_AXIS:case MULTIPLE_AXES: {
    GList *items=NULL;if(m->restore || m->kind==MULTIPLE_AXES)items=g_list_append(items,axis);
    if(!m->restore && m->kind==MULTIPLE_AXES)items=g_list_append(items,gimp_item_get_by_id(engine->gimp,m->scene->ids[1]));
    gimp_image_set_selected_channels(open->image,items);g_list_free(items);break;
  }
  case LOCKED_AXES:
    for(unsigned i=0;i<3;i++)gimp_item_set_lock_content(gimp_item_get_by_id(engine->gimp,m->scene->ids[i]),!m->restore,FALSE);break;
  case FROZEN_UNDO:if(!(m->restore?gimp_image_undo_thaw(open->image):gimp_image_undo_freeze(open->image)))return GLIMS_STATUS_FAILED;break;
  case GROUPED_UNDO:if(!(m->restore?gimp_image_undo_group_end(open->image):gimp_image_undo_group_start(open->image,GIMP_UNDO_GROUP_PAINT,"Fixture external group")))return GLIMS_STATUS_FAILED;break;
  case ENGINE_BUSY:engine->busy+=m->restore?-1:1;break;
  case BAD_UUID:
    if(m->restore){if(!m->uuid)return GLIMS_STATUS_FAILED;gimp_parasite_list_add(gimp_item_get_parasites(axis),m->uuid);gimp_parasite_free(m->uuid);m->uuid=NULL;}
    else{const GimpParasite *p=gimp_item_parasite_find(axis,GLIMS_PLATE_UUID_PARASITE);if(!p)return GLIMS_STATUS_FAILED;m->uuid=gimp_parasite_copy(p);gimp_parasite_list_remove(gimp_item_get_parasites(axis),GLIMS_PLATE_UUID_PARASITE);}break;
  }
  return GLIMS_STATUS_OK;
}
static void mutate(GlimsEngine *engine,Mutation *m,gboolean restore){m->restore=restore;CHECK(glims_engine_call(engine,mutate_native,m)==GLIMS_STATUS_OK,restore?"restore native admission witness":"install native admission witness");}
static void native_admission(GlimsEngine *engine) {
  GlimsPoint points[]={{10,8},{30,24}};GlimsLabSelectOptions opt=options(0);
  for(unsigned kind=NO_AXIS;kind<=BAD_UUID;kind++) {
    Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT);if(!s)continue;Mutation m={.scene=s,.kind=kind};mutate(engine,&m,FALSE);
    if(kind<=LOCKED_AXES) {
      Snapshot *before=capture(engine,s);CHECK(shape(engine,s,1,points,2,&opt)==GLIMS_STATUS_OK,"mask selection does not depend on sole axis or pixel locks");Snapshot *after=capture(engine,s);
      if(after)CHECK(rectangle_mask(after,10,8,30,24),"root mask receives requested geometry with atypical selected axes");unchanged_axes(s,before,after);snapshot_free(before);snapshot_free(after);
      before=capture(engine,s);CHECK(command(engine,s,GLIMS_SELECT_ALL)==GLIMS_STATUS_OK,"mask command ignores pixel-axis locks and selected-axis count");after=capture(engine,s);
      if(after)CHECK(rectangle_mask(after,0,0,W,H),"Select All targets root mask, not selected scalar planes");unchanged_axes(s,before,after);snapshot_free(before);snapshot_free(after);
    } else {
      GlimsStatus expected=kind==BAD_UUID?GLIMS_STATUS_UNSUPPORTED:GLIMS_STATUS_BUSY;
      refuse_shape(engine,s,s->id,1,points,2,&opt,expected);refuse_command(engine,s,s->id,GLIMS_SELECT_ALL,expected);
    }
    mutate(engine,&m,TRUE);close_scene(engine,s);
  }
  Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_U16);if(!s)return;Snapshot *before=capture(engine,s);
  GlimsSelectOptions old={.struct_size=sizeof old,.operation=0,.antialias=true};char *error=NULL;
  CHECK(api->select_shape(engine,s->id,1,points,2,&old)==GLIMS_STATUS_UNSUPPORTED,"old generic shape slot remains unavailable for Lab");
  CHECK(api->select_command(engine,s->id,GLIMS_SELECT_ALL,0,&error)==GLIMS_STATUS_UNSUPPORTED,"old generic command slot remains unavailable for Lab");api->free_string(error);
  expect_unchanged(engine,s,before,"generic old-slot refusals do not change source/mask/history");snapshot_free(before);
  for(unsigned finish=0;finish<2;finish++) {
    before=capture(engine,s);GlimsStrokeID stroke=0;
    CHECK(start_brush(engine,s,20.5,16.5,11,&stroke)==GLIMS_STATUS_OK&&stroke,"begin live physical brush before selection refusal");
    if(stroke) {
      Snapshot *during=capture(engine,s);if(before&&during)CHECK(!pixels_equal(s,before,during),"busy witness stroke has real tentative axis damage");snapshot_free(during);
      refuse_shape(engine,s,s->id,1,points,2,&opt,GLIMS_STATUS_BUSY);refuse_command(engine,s,s->id,GLIMS_SELECT_ALL,GLIMS_STATUS_BUSY);
      GlimsStrokeSampleV2 point={.struct_size=sizeof point,.x=28.5,.y=16.5,.pressure=1,.time_ms=2};
      GlimsStrokePacketV2 input={.struct_size=sizeof input,.sample_stride=sizeof point,.samples=&point,.count=1,.byte_count=sizeof point};error=NULL;
      CHECK(api->stroke_continue_v2(engine,stroke,&input,&error)==GLIMS_STATUS_OK,"refused selection leaves existing stroke usable");api->free_string(error);
      if(finish){CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"usable stroke commits after refusal");CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"Undo committed busy witness");}
      else CHECK(api->stroke_cancel_lab(engine,stroke)==GLIMS_STATUS_OK,"usable stroke cancels after refusal");
      Snapshot *after=capture(engine,s);if(before&&after)CHECK(mask_equal(before,after)&&pixels_equal(s,before,after)&&metadata_equal(before,after),"cancel/Undo after refused selection restores source and unchanged mask");snapshot_free(after);
    }
    snapshot_free(before);
  }
  close_scene(engine,s);
}
typedef struct {GlimsImageID id;GBytes *raw,*mask,*map,*profile;int undo,redo;guint64 revision;gboolean dirty;} OtherImage;
static GlimsStatus other_capture_native(GlimsEngine *engine,gpointer data) {
  OtherImage *s=data;GlimsOpenImage *open=glims_lookup_image(engine,s->id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  GByteArray *all=g_byte_array_new();GList *items=gimp_image_get_layer_list(open->image);items=g_list_concat(items,gimp_image_get_channel_list(open->image));
  for(GList *it=items;it;it=it->next){GimpDrawable *d=GIMP_DRAWABLE(it->data);const Babl *format=gimp_drawable_get_format(d);
    size_t bytes=(size_t)W*H*babl_format_get_bytes_per_pixel(format);if(bytes>16*N){g_list_free(items);g_byte_array_unref(all);return GLIMS_STATUS_FAILED;}
    guint8 *raw=g_malloc(bytes);gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),1,format,raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);g_byte_array_append(all,raw,bytes);g_free(raw);}
  g_list_free(items);s->raw=g_byte_array_free_to_bytes(all);
  GimpDrawable *mask=GIMP_DRAWABLE(gimp_image_get_mask(open->image));const Babl *format=gimp_drawable_get_format(mask);size_t bytes=(size_t)N*babl_format_get_bytes_per_pixel(format);
  guint8 *raw=g_malloc(bytes);gegl_buffer_get(gimp_drawable_get_buffer(mask),GEGL_RECTANGLE(0,0,W,H),1,format,raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);s->mask=g_bytes_new_take(raw,bytes);
  s->map=parasite_copy(gimp_image_parasite_find(open->image,GLIMS_PLATE_MAP_PARASITE));s->profile=parasite_copy(gimp_image_parasite_find(open->image,GLIMS_PLATE_PROFILE_PARASITE));
  s->undo=gimp_undo_stack_get_depth(gimp_image_get_undo_stack(open->image));s->redo=gimp_undo_stack_get_depth(gimp_image_get_redo_stack(open->image));s->revision=open->history_revision;s->dirty=gimp_image_is_dirty(open->image);return GLIMS_STATUS_OK;
}
static void other_free(OtherImage *s){g_clear_pointer(&s->raw,g_bytes_unref);g_clear_pointer(&s->mask,g_bytes_unref);g_clear_pointer(&s->map,g_bytes_unref);g_clear_pointer(&s->profile,g_bytes_unref);}
static void wrong_modes(GlimsEngine *engine) {
  GlimsImageID ids[3]={0};char *error=NULL;
  CHECK(api->image_new(engine,W,H,&ids[0],&error)==GLIMS_STATUS_OK&&ids[0],"create ordinary RGB refusal witness");api->free_string(error);error=NULL;
  CHECK(api->image_new_multichannel(engine,W,H,GLIMS_COLOR_COMPONENT_U8,4,&ids[1],&error)==GLIMS_STATUS_OK&&ids[1],"create Multichannel refusal witness");api->free_string(error);error=NULL;
  gchar *profile=NULL;gsize bytes=0;const char *path=g_getenv("GLIMS_TEST_CMYK_PROFILE");
  CHECK(path&&g_file_get_contents(path,&profile,&bytes,NULL),"read external real CMYK fixture profile");
  if(profile){CHECK(api->image_new_cmyk(engine,W,H,GLIMS_COLOR_COMPONENT_U8,(guint8*)profile,bytes,&ids[2],&error)==GLIMS_STATUS_OK&&ids[2],"create CMYK refusal witness");api->free_string(error);g_free(profile);}
  GlimsPoint points[]={{10,8},{30,24}};GlimsLabSelectOptions opt=options(0);
  for(unsigned i=0;i<3;i++)if(ids[i]) {
    OtherImage before={.id=ids[i]},after={.id=ids[i]};CHECK(glims_engine_call(engine,other_capture_native,&before)==GLIMS_STATUS_OK,"capture independent other-mode raw state");
    error=NULL;CHECK(api->image_select_lab_shape(engine,ids[i],1,points,2,&opt,&error)==GLIMS_STATUS_UNSUPPORTED,"Lab-only shape refuses ordinary or ink image");api->free_string(error);error=NULL;
    CHECK(api->image_select_lab_command(engine,ids[i],GLIMS_SELECT_ALL,&error)==GLIMS_STATUS_UNSUPPORTED,"Lab-only command refuses ordinary or ink image");api->free_string(error);
    CHECK(glims_engine_call(engine,other_capture_native,&after)==GLIMS_STATUS_OK,"recapture other-mode refusal witness");
    CHECK(same_bytes(before.raw,after.raw)&&same_bytes(before.mask,after.mask)&&same_bytes(before.map,after.map)&&same_bytes(before.profile,after.profile)&&
      before.undo==after.undo&&before.redo==after.redo&&before.revision==after.revision&&before.dirty==after.dirty,"wrong-mode calls preserve every raw drawable/mask and component metadata/history");
    other_free(&before);other_free(&after);CHECK(api->image_close(engine,ids[i])==GLIMS_STATUS_OK,"close owned other-mode fixture");
  }
}
int main(int argc,char **argv) {
  if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api || api->struct_size<offsetof(GlimsEngineAPI,image_select_lab_command)+sizeof api->image_select_lab_command || !api->image_select_lab_shape || !api->image_select_lab_command)return 2;
  char *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL),*error=NULL;GlimsEngine *engine=NULL;
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
  GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);
  if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}api->free_string(error);
  char *missing_error=(char*)(uintptr_t)1;
  CHECK(api->image_select_lab_command(NULL,0,GLIMS_SELECT_ALL,&missing_error)==GLIMS_STATUS_NOT_RUNNING,
    "unavailable engine refuses new command safely");
  CHECK(missing_error==NULL,"unavailable engine command clears caller error");
  GlimsPoint no_engine_points[]={{1,1},{2,2}};GlimsLabSelectOptions no_engine_options=options(0);missing_error=(char*)(uintptr_t)1;
  CHECK(api->image_select_lab_shape(NULL,0,GLIMS_SHAPE_RECTANGLE,no_engine_points,2,&no_engine_options,&missing_error)==GLIMS_STATUS_NOT_RUNNING,
    "unavailable engine refuses new shape safely");
  CHECK(missing_error==NULL,"unavailable engine shape clears caller error");
  CHECK(glims_engine_call(engine,install_brush,NULL)==GLIMS_STATUS_OK,"install private deterministic brush resource");
  const uint32_t components[]={GLIMS_COLOR_COMPONENT_U8,GLIMS_COLOR_COMPONENT_U16,GLIMS_COLOR_COMPONENT_FLOAT};
  for(unsigned i=0;i<3;i++){shapes_and_operations(engine,components[i]);edits_obey_mask(engine,components[i],argv[1]);}
  invalid_input(engine);native_admission(engine);wrong_modes(engine);api->stop(engine);
  printf("checks=%u failures=%u\n",checks,failures);return failures?1:0;
}

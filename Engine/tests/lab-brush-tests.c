/* Public Lab brush facade fixture. Native callbacks only seed and capture
 * independent raw state; stroke writes use facade slots193/194 and V2 input. */
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
#include "core/gimpparasitelist.h"
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
  guint8 uuids[AXES][16];
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
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpbrush-private.h"
#include "core/gimpbrushgenerated.h"
#include "core/gimpcontext.h"
#include "core/gimppaintinfo.h"
#include "core/gimpsymmetry.h"
#include "core/gimptempbuf.h"
#include "core/gimpviewable.h"
#include "paint/gimpbrushcore.h"
#include "paint/gimppaintoptions.h"

enum { HARD, HALF, SOFT, ZERO_OPACITY, OUTSIDE, CANCEL, LATE_NAN, BYTE_MASK };

static gboolean center_literal(const Scene *s,const guint8 *raw,gboolean half) {
  unsigned i=24*W+16;
  if (s->sample_size == 1) return raw[i] == (s->role==0 ? (half?64:255) : (half?144:192));
  if (s->sample_size == 2) {
    guint16 q; memcpy(&q,raw+2*i,2);
    return q == (s->role==0 ? (half?16384:65535) : (half?37008:49344));
  }
  float value; memcpy(&value,raw+4*i,4);
  return value == (s->role==0 ? (half?25.0f:100.0f) : (half?16.0f:64.0f));
}
static GlimsStatus seed_native(GlimsEngine *engine,gpointer data) {
  Scene *s=data; GlimsOpenImage *open=glims_lookup_image(engine,s->id); GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open,&storage) || storage.map.count!=3) return GLIMS_STATUS_FAILED;
  guint8 *raw=g_malloc(MAX_BYTES); float *mask=g_new(float,PIXELS);
  for (unsigned a=0;a<3;a++) {
    GimpDrawable *d=GIMP_DRAWABLE(storage.planes[a]); s->ids[a]=gimp_item_get_id(GIMP_ITEM(d));
    guint32 uuid_size=0; const GimpParasite *p=gimp_item_parasite_find(GIMP_ITEM(d),GLIMS_PLATE_UUID_PARASITE);
    const void *uuid=p?gimp_parasite_get_data(p,&uuid_size):NULL;
    if(!uuid || uuid_size!=16) {g_free(raw);g_free(mask);return GLIMS_STATUS_FAILED;}
    memcpy(s->uuids[a],uuid,16);
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
  CHECK(status==GLIMS_STATUS_OK && s->id,"create real public Lab image for facade stroke");
  if(error) fprintf(stderr,"create: %s\n",error); api->free_string(error);
  if(status!=GLIMS_STATUS_OK || !s->id) {g_free(s); return NULL;}
  if(glims_engine_call(engine,seed_native,s)!=GLIMS_STATUS_OK) {
    CHECK(FALSE,"independent seed succeeds"); api->image_close(engine,s->id); g_free(s); return NULL;
  }
  return s;
}
static GlimsStrokeSampleV2 sample(double x,double y,unsigned time) {
  return (GlimsStrokeSampleV2){.struct_size=sizeof(GlimsStrokeSampleV2),.x=x,.y=y,.pressure=1,.time_ms=time};
}
static GlimsStrokePacketV2 packet(const void *samples,size_t count) {
  return (GlimsStrokePacketV2){.struct_size=sizeof(GlimsStrokePacketV2),.sample_stride=sizeof(GlimsStrokeSampleV2),
    .samples=samples,.count=count,.byte_count=count*sizeof(GlimsStrokeSampleV2)};
}
static GlimsLabBrushSettings brush_settings(const Scene *s) {
  GlimsLabBrushSettings value={.struct_size=sizeof value,.axis=s->ids[s->role],.role=s->role,
    .value=s->role?64:100,.opacity=1,.size=11,.hardness=1};
  memcpy(value.uuid,s->uuids[s->role],16);return value;
}
static GlimsStatus begin(GlimsEngine *engine,const Scene *s,GlimsStrokeID *id) {
  GlimsLabBrushSettings settings=brush_settings(s);GlimsStrokeSampleV2 point=sample(16.5,24.5,1);
  GlimsStrokePacketV2 first=packet(&point,1);char *error=NULL;
  GlimsStatus status=api->stroke_begin_lab(engine,s->id,0,&settings,&first,id,&error);
  if(error)fprintf(stderr,"begin: %s\n",error);api->free_string(error);return status;
}
static void close_scene(GlimsEngine *engine,Scene *s) {
  if(!s)return;if(s->id)CHECK(api->image_close(engine,s->id)==GLIMS_STATUS_OK,"owned image closes");g_free(s);
}
static void reviewer_regressions(GlimsEngine *engine) {
  Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_U8,0,HARD);if(!s)return;
  GlimsLabBrushSettings settings=brush_settings(s);settings.size=.5;
  GlimsStrokeSampleV2 point=sample(16.5,24.5,1);GlimsStrokePacketV2 first=packet(&point,1);
  GlimsStrokeID stroke=123;char *error=NULL;
  GlimsStatus status=api->stroke_begin_lab(engine,s->id,0,&settings,&first,&stroke,&error);
  printf("SIZE_HALF status=%d stroke=%d\n",status,stroke);api->free_string(error);
  CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT && stroke==0,"REGRESSION size .5 refuses with zero handle before native defaults");
  if(stroke)api->stroke_cancel_lab(engine,stroke);
  close_scene(engine,s);
  s=create_scene(engine,GLIMS_COLOR_COMPONENT_U8,0,HARD);
  Scene *other=create_scene(engine,GLIMS_COLOR_COMPONENT_U8,0,HARD);
  if(!s || !other){close_scene(engine,s);close_scene(engine,other);return;}
  stroke=0;CHECK(begin(engine,s,&stroke)==GLIMS_STATUS_OK && stroke,"begin close-cleanup witness");
  CHECK(api->image_close(engine,s->id)==GLIMS_STATUS_OK,"close image while its typed Lab stroke is live");s->id=0;
  GlimsStrokeID next=0;status=begin(engine,other,&next);
  GlimsStatus retired=api->stroke_cancel_lab(engine,stroke);
  printf("AFTER_CLOSE status=%d next=%d old_cancel=%d\n",status,next,retired);
  CHECK(retired==GLIMS_STATUS_NOT_FOUND,"closed image retires its Lab stroke handle");
  CHECK(status==GLIMS_STATUS_OK && next,"REGRESSION closing live Lab stroke does not orphan busy state");
  if(next)api->stroke_cancel_lab(engine,next);
  close_scene(engine,s);close_scene(engine,other);
}
static void save_while_live(GlimsEngine *engine,const char *work) {
  Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT,0,HARD);if(!s)return;
  Snapshot *before=g_new0(Snapshot,1),*during=g_new0(Snapshot,1),*after=g_new0(Snapshot,1);
  char *path=g_build_filename(work,"live-save.xcf",NULL),*copy=g_build_filename(work,"live-copy.xcf",NULL);
  const char sentinel[]="keep existing destination bytes";
  CHECK(g_file_set_contents(path,sentinel,sizeof sentinel,NULL),"install save destination sentinel");
  if(!capture(engine,s,before))goto done;
  GlimsStrokeID stroke=0;CHECK(begin(engine,s,&stroke)==GLIMS_STATUS_OK && stroke,"begin save-gate witness");
  if(!stroke)goto done;
  if(capture(engine,s,during))CHECK(!same_pixels(s,before,during),"save witness has real tentative painted bytes");
  char *error=NULL;GlimsStatus saved=api->image_save(engine,s->id,path,&error);api->free_string(error);error=NULL;
  GlimsStatus copied=api->image_save_copy(engine,s->id,copy,&error);api->free_string(error);
  printf("LIVE_SAVE status=%d copy=%d\n",saved,copied);
  CHECK(saved==GLIMS_STATUS_BUSY,"REGRESSION save refuses live Lab stroke with BUSY");
  CHECK(copied==GLIMS_STATUS_BUSY,"REGRESSION save_copy refuses live Lab stroke with BUSY");
  gchar *bytes=NULL;gsize length=0;
  CHECK(g_file_get_contents(path,&bytes,&length,NULL) && length==sizeof sentinel && !memcmp(bytes,sentinel,length),
        "REGRESSION refused save preserves existing destination bytes");g_free(bytes);
  CHECK(!g_file_test(copy,G_FILE_TEST_EXISTS),"REGRESSION refused save_copy does not create destination");
  CHECK(api->stroke_cancel_lab(engine,stroke)==GLIMS_STATUS_OK,"cancel after refused live save");
  if(capture(engine,s,after))CHECK(same_pixels(s,before,after)&&same_history(before,after)&&same_metadata(before,after),
        "REGRESSION cancelled tentative stroke preserves original dirty/history/file identity");
done:
  release_snapshot(before);release_snapshot(during);release_snapshot(after);g_free(before);g_free(during);g_free(after);
  g_free(path);g_free(copy);close_scene(engine,s);
}

static GlimsStatus install_private_brush(GlimsEngine *engine,gpointer unused) {
  (void)unused;
  GimpBrush *brush=GIMP_BRUSH(gimp_brush_generated_new("Private facade hard circle",
      GIMP_BRUSH_GENERATED_CIRCLE,10,2,1,1,0));
  if(!brush)return GLIMS_STATUS_FAILED;
  gimp_context_set_brush(gimp_get_user_context(engine->gimp),brush);
  g_object_unref(brush);return GLIMS_STATUS_OK;
}
static Snapshot *take_snapshot(GlimsEngine *engine,Scene *s) {
  Snapshot *result=g_new0(Snapshot,1);
  if(capture(engine,s,result))return result;
  release_snapshot(result);g_free(result);return NULL;
}
static void destroy_snapshot(Snapshot *s) {release_snapshot(s);g_free(s);}
static void expect_original(GlimsEngine *engine,Scene *s,const Snapshot *before,const char *label) {
  Snapshot *after=take_snapshot(engine,s);
  if(before && after)CHECK(same_pixels(s,before,after)&&same_metadata(before,after)&&same_history(before,after),label);
  destroy_snapshot(after);
}
static GlimsStatus advance(GlimsEngine *engine,GlimsStrokeID stroke,double x,unsigned time) {
  GlimsStrokeSampleV2 point=sample(x,24.5,time);GlimsStrokePacketV2 input=packet(&point,1);
  char *error=NULL;GlimsStatus status=api->stroke_continue_v2(engine,stroke,&input,&error);
  if(error)fprintf(stderr,"continue: %s\n",error);api->free_string(error);return status;
}
static void happy_path(GlimsEngine *engine,uint32_t component,unsigned role) {
  printf("CASE normal component=%u role=%u\n",component,role);
  Scene *s=create_scene(engine,component,role,HARD);if(!s)return;
  Snapshot *before=take_snapshot(engine,s),*painted=NULL,*undone=NULL,*redone=NULL;
  GlimsStrokeID stroke=0;
  CHECK(begin(engine,s,&stroke)==GLIMS_STATUS_OK && stroke,"public begin accepts physical role/UUID target");
  if(!stroke)goto done;
  CHECK(advance(engine,stroke,30.5,2)==GLIMS_STATUS_OK,"public V2 continuation accepts next sample");
  CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"public end commits changed stroke");
  CHECK(api->stroke_cancel_lab(engine,stroke)==GLIMS_STATUS_NOT_FOUND,"completed stroke handle retired");
  painted=take_snapshot(engine,s);
  if(!before || !painted)goto done;
  CHECK(center_literal(s,painted->raw[role],FALSE),"center equals independently specified physical endpoint code");
  CHECK(!same_pixels(s,before,painted),"committed stroke changed authoritative raw pixels");
  gboolean others=TRUE;
  for(unsigned a=0;a<3;a++)if(a!=role && memcmp(before->raw[a],painted->raw[a],s->bytes))others=FALSE;
  CHECK(others && same_metadata(before,painted),"other axes, selection and full metadata unchanged");
  if(component==GLIMS_COLOR_COMPONENT_FLOAT)
    CHECK(!memcmp(before->raw[role],painted->raw[role],8),"unaffected NaN payload and negative zero remain exact");
  CHECK(painted->undo==before->undo+1 && painted->redo==0,"one changed stroke creates exactly one Undo");
  CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"undo public Lab stroke");
  undone=take_snapshot(engine,s);
  if(undone)CHECK(same_pixels(s,before,undone)&&same_metadata(before,undone),"Undo restores exact original bytes and metadata");
  CHECK(api->image_redo(engine,s->id)==GLIMS_STATUS_OK,"redo public Lab stroke");
  redone=take_snapshot(engine,s);
  if(redone)CHECK(same_pixels(s,painted,redone)&&same_metadata(painted,redone),"Redo restores exact committed bytes and metadata");
  /* A second, different endpoint guarantees real cancellation damage. */
  GlimsLabBrushSettings settings=brush_settings(s);settings.value=role?-64:50;
  GlimsStrokeSampleV2 point=sample(16.5,24.5,1);GlimsStrokePacketV2 first=packet(&point,1);char *error=NULL;
  stroke=0;CHECK(api->stroke_begin_lab(engine,s->id,0,&settings,&first,&stroke,&error)==GLIMS_STATUS_OK && stroke,
    "begin independent cancel witness");api->free_string(error);
  if(stroke) {
    Snapshot *during=take_snapshot(engine,s);
    if(redone && during)CHECK(!same_pixels(s,redone,during),"cancel witness actually changes pixels");
    destroy_snapshot(during);
    CHECK(advance(engine,stroke,40.5,2)==GLIMS_STATUS_OK,"cancel witness includes continuation");
    CHECK(api->stroke_cancel_lab(engine,stroke)==GLIMS_STATUS_OK,"explicit public cancel succeeds");
    expect_original(engine,s,redone,"cancel restores full bytes, history and metadata");
    CHECK(api->stroke_cancel_lab(engine,stroke)==GLIMS_STATUS_NOT_FOUND,"cancelled handle is retired");
  }
done:
  destroy_snapshot(before);destroy_snapshot(painted);destroy_snapshot(undone);destroy_snapshot(redone);close_scene(engine,s);
}
static void no_op_cases(GlimsEngine *engine) {
  for(unsigned outside=0;outside<2;outside++) {
    Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT,1,outside?OUTSIDE:ZERO_OPACITY);if(!s)continue;
    Snapshot *before=take_snapshot(engine,s);
    GlimsLabBrushSettings settings=brush_settings(s);if(!outside)settings.opacity=0;
    GlimsStrokeSampleV2 point=sample(outside?-100:16.5,outside?-100:24.5,1);
    GlimsStrokePacketV2 first=packet(&point,1);GlimsStrokeID stroke=0;char *error=NULL;
    CHECK(api->stroke_begin_lab(engine,s->id,0,&settings,&first,&stroke,&error)==GLIMS_STATUS_OK && stroke,
      "zero-opacity or outside stroke begins without inspecting uncovered NaN");api->free_string(error);
    if(stroke)CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"zero-change public stroke ends");
    expect_original(engine,s,before,"zero-change stroke preserves exact bytes, history and metadata");
    destroy_snapshot(before);close_scene(engine,s);
  }
  Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT,1,HALF);if(!s)return;
  Snapshot *before=take_snapshot(engine,s);
  GlimsLabBrushSettings settings=brush_settings(s);settings.opacity=.5;
  GlimsStrokeSampleV2 point=sample(16.5,24.5,1);GlimsStrokePacketV2 first=packet(&point,1);
  GlimsStrokeID stroke=0;char *error=NULL;
  CHECK(api->stroke_begin_lab(engine,s->id,0,&settings,&first,&stroke,&error)==GLIMS_STATUS_OK && stroke,
    "half-selection half-opacity physical stroke begins");api->free_string(error);
  if(stroke) {
    CHECK(advance(engine,stroke,20.5,2)==GLIMS_STATUS_OK && advance(engine,stroke,16.5,3)==GLIMS_STATUS_OK,
      "overlapping dabs use original-source constant application");
    CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"masked stroke commits");
    Snapshot *after=take_snapshot(engine,s);
    if(after && before)CHECK(before->mask[24*W+16]==.5f && center_literal(s,after->raw[1],TRUE),
      "physical 0 to 64, selection .5 and opacity .5 produces exact 16 once");
    destroy_snapshot(after);
  }
  destroy_snapshot(before);close_scene(engine,s);
}
static void refused_begin(GlimsEngine *engine,Scene *s,GlimsImageID image,GlimsResourceID resource,
                          const GlimsLabBrushSettings *settings,const GlimsStrokePacketV2 *first,
                          GlimsStatus expected,const char *label) {
  Snapshot *before=take_snapshot(engine,s);GlimsStrokeID stroke=123;char *error=NULL;
  GlimsStatus result=api->stroke_begin_lab(engine,image,resource,settings,first,&stroke,&error);
  if(result!=expected || stroke)fprintf(stderr,"%s got status=%d handle=%d expected=%d (%s)\n",
    label,result,stroke,expected,error?error:"");
  CHECK(result==expected && stroke==0,label);api->free_string(error);
  if(stroke)api->stroke_cancel_lab(engine,stroke);
  expect_original(engine,s,before,"refused begin cannot paint, change metadata or history");destroy_snapshot(before);
}
static void settings_and_packet_refusals(GlimsEngine *engine) {
  Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_U8,0,HARD);if(!s)return;
  Scene *foreign=create_scene(engine,GLIMS_COLOR_COMPONENT_U8,0,HARD);
  GlimsStrokeSampleV2 point=sample(16.5,24.5,1);GlimsStrokePacketV2 first=packet(&point,1);
  GlimsLabBrushSettings good=brush_settings(s),bad=good;
  refused_begin(engine,s,s->id,0,NULL,&first,GLIMS_STATUS_INVALID_ARGUMENT,"NULL settings refused/out0");
  bad.struct_size=sizeof bad-1;refused_begin(engine,s,s->id,0,&bad,&first,GLIMS_STATUS_INVALID_ARGUMENT,"short settings refused/out0");
  for(unsigned kind=0;kind<20;kind++) {
    bad=good;
    switch(kind) {
    case 0:bad.axis=0;break;case 1:bad.axis=s->ids[1];break;
    case 2:bad.uuid[0]^=1;break;case 3:bad.role=3;break;
    case 4:bad.value=-1;break;case 5:bad.value=101;break;case 6:bad.value=NAN;break;case 7:bad.value=INFINITY;break;
    case 8:bad.opacity=-.1;break;case 9:bad.opacity=1.1;break;case 10:bad.opacity=NAN;break;
    case 11:bad.size=0;break;case 12:bad.size=.5;break;case 13:bad.size=10001;break;case 14:bad.size=INFINITY;break;
    case 15:bad.hardness=-1;break;case 16:bad.hardness=2;break;case 17:bad.hardness=NAN;break;
    case 18:bad.role=1;break;case 19:bad.axis=foreign?foreign->ids[0]:INT32_MAX;break;
    }
    printf("INVALID_SETTINGS %u\n",kind);
    refused_begin(engine,s,s->id,0,&bad,&first,GLIMS_STATUS_INVALID_ARGUMENT,"invalid explicit settings refused/out0");
  }
  refused_begin(engine,s,INT32_MAX,0,&good,&first,GLIMS_STATUS_NOT_FOUND,"unknown image refused/out0");
  refused_begin(engine,s,s->id,UINT64_MAX,&good,&first,GLIMS_STATUS_INVALID_ARGUMENT,"out-of-range brush resource refused/out0");
  GlimsResourceInfo pattern;int32_t count=0;
  if(api->resources(engine,GLIMS_RESOURCE_PATTERN,&pattern,1,&count)==GLIMS_STATUS_OK && count>0)
    refused_begin(engine,s,s->id,pattern.id,&good,&first,GLIMS_STATUS_INVALID_ARGUMENT,"pattern is not a brush resource");
  else CHECK(FALSE,"native resources include a wrong-kind pattern witness");
  refused_begin(engine,s,s->id,0,&good,NULL,GLIMS_STATUS_INVALID_ARGUMENT,"NULL initial packet refused/out0");
  for(unsigned kind=0;kind<13;kind++) {
    GlimsStrokeSampleV2 invalid=point;GlimsStrokePacketV2 input=packet(&invalid,1);
    switch(kind) {
    case 0:input.struct_size=sizeof input-1;break;case 1:input.sample_stride=sizeof invalid-1;break;
    case 2:input.byte_count--;break;case 3:input.count=0;input.byte_count=0;break;
    case 4:input.count=4097;input.byte_count=input.count*sizeof invalid;break;case 5:input.samples=NULL;break;
    case 6:invalid.struct_size=sizeof invalid-1;break;case 7:invalid.flags=1u<<20;break;
    case 8:invalid.reserved=1;break;case 9:invalid.x=NAN;break;case 10:invalid.pressure=1.01;break;
    case 11:invalid.time_ms=0;invalid.rotation_turns=.25;break;case 12:invalid.y=524289;break;
    }
    printf("INVALID_PACKET %u\n",kind);
    refused_begin(engine,s,s->id,0,&good,&input,GLIMS_STATUS_INVALID_ARGUMENT,"invalid initial packet refused/out0");
  }
  /* Begin admits exactly one sample; an oversized first packet paints nothing. */
  GlimsStrokeSampleV2 pair[]={point,sample(30.5,24.5,2)};pair[1].y=NAN;
  GlimsStrokePacketV2 two=packet(pair,2);
  refused_begin(engine,s,s->id,0,&good,&two,GLIMS_STATUS_INVALID_ARGUMENT,"two-sample first packet refused without painting prefix");
  close_scene(engine,foreign);close_scene(engine,s);
}
static void malformed_live_packet(GlimsEngine *engine) {
  Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_U16,2,HARD);if(!s)return;
  GlimsStrokeID stroke=0;CHECK(begin(engine,s,&stroke)==GLIMS_STATUS_OK && stroke,"begin live packet validation witness");
  if(stroke) {
    Snapshot *live=take_snapshot(engine,s);
    GlimsStrokePoint legacy={.x=35,.y=24,.pressure=1,.time_ms=2};
    CHECK(api->stroke_continue(engine,stroke,&legacy,1)==GLIMS_STATUS_UNSUPPORTED,"V1 continuation refuses typed V2 Lab stroke");
    expect_original(engine,s,live,"V1 refusal leaves tentative bytes and history unchanged");
    GlimsStrokeSampleV2 points[]={sample(35.5,24.5,2),sample(55.5,24.5,3)};
    for(unsigned kind=0;kind<4;kind++) {
      points[1]=sample(55.5,24.5,3);GlimsStrokePacketV2 input=packet(points,2);
      if(kind==0)points[1].x=NAN;
      if(kind==1)input.byte_count--;
      if(kind==2)points[1].flags=UINT32_MAX;
      if(kind==3)points[1].time_ms=0;
      char *error=NULL;CHECK(api->stroke_continue_v2(engine,stroke,&input,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
        "malformed continuation refused before any sample");api->free_string(error);
      expect_original(engine,s,live,"malformed packet preserves all tentative pixels/history");
    }
    CHECK(advance(engine,stroke,35.5,2)==GLIMS_STATUS_OK,"malformed input leaves valid stroke live");
    CHECK(api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,"still-live stroke commits after valid continuation");
    destroy_snapshot(live);
  }
  close_scene(engine,s);
}

enum { CHANGE_SELECTION, CLEAR_SELECTION, MULTI_SELECTION, DAMAGE_UUID, LOCK_AXIS, FREEZE_UNDO, GROUP_UNDO };
typedef struct { Scene *scene;unsigned kind;gboolean restore;GimpParasite *saved; } Mutation;
static GlimsStatus mutate_native(GlimsEngine *engine,gpointer data) {
  Mutation *m=data;GlimsOpenImage *open=glims_lookup_image(engine,m->scene->id);
  if(!open)return GLIMS_STATUS_NOT_FOUND;
  GimpItem *item=gimp_item_get_by_id(engine->gimp,m->scene->ids[m->scene->role]);
  if(!item)return GLIMS_STATUS_NOT_FOUND;
  switch(m->kind) {
  case CHANGE_SELECTION:case CLEAR_SELECTION:case MULTI_SELECTION: {
    GList *items=NULL;
    if(m->restore)items=g_list_append(items,item);
    else if(m->kind==CHANGE_SELECTION)items=g_list_append(items,gimp_item_get_by_id(engine->gimp,m->scene->ids[(m->scene->role+1)%3]));
    else if(m->kind==MULTI_SELECTION) {items=g_list_append(items,item);items=g_list_append(items,gimp_item_get_by_id(engine->gimp,m->scene->ids[(m->scene->role+1)%3]));}
    gimp_image_set_selected_channels(open->image,items);g_list_free(items);break;
  }
  case DAMAGE_UUID:
    if(m->restore){if(!m->saved)return GLIMS_STATUS_FAILED;gimp_parasite_list_add(gimp_item_get_parasites(item),m->saved);gimp_parasite_free(m->saved);m->saved=NULL;}
    else {const GimpParasite *p=gimp_item_parasite_find(item,GLIMS_PLATE_UUID_PARASITE);if(!p)return GLIMS_STATUS_FAILED;
      m->saved=gimp_parasite_copy(p);gimp_parasite_list_remove(gimp_item_get_parasites(item),GLIMS_PLATE_UUID_PARASITE);}
    break;
  case LOCK_AXIS:gimp_item_set_lock_content(item,!m->restore,FALSE);break;
  case FREEZE_UNDO:
    if(!(m->restore?gimp_image_undo_thaw(open->image):gimp_image_undo_freeze(open->image)))return GLIMS_STATUS_FAILED;break;
  case GROUP_UNDO:
    if(!(m->restore?gimp_image_undo_group_end(open->image):gimp_image_undo_group_start(open->image,GIMP_UNDO_GROUP_PAINT,"Fixture nested group")))return GLIMS_STATUS_FAILED;break;
  }
  return GLIMS_STATUS_OK;
}
static void mutate(GlimsEngine *engine,Mutation *m,gboolean restore) {
  m->restore=restore;CHECK(glims_engine_call(engine,mutate_native,m)==GLIMS_STATUS_OK,
    restore?"restore native target witness":"install native target witness");
}
static void target_refusals(GlimsEngine *engine) {
  for(unsigned kind=0;kind<=GROUP_UNDO;kind++) {
    Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_U8,1,HARD);if(!s)continue;
    Mutation m={.scene=s,.kind=kind};mutate(engine,&m,FALSE);
    GlimsLabBrushSettings settings=brush_settings(s);GlimsStrokeSampleV2 point=sample(16.5,24.5,1);
    GlimsStrokePacketV2 first=packet(&point,1);
    GlimsStatus expected=kind==DAMAGE_UUID?GLIMS_STATUS_UNSUPPORTED:
      kind==FREEZE_UNDO || kind==GROUP_UNDO?GLIMS_STATUS_BUSY:
      kind==LOCK_AXIS?GLIMS_STATUS_LOCKED:GLIMS_STATUS_INVALID_ARGUMENT;
    printf("TARGET_BEGIN kind=%u\n",kind);
    refused_begin(engine,s,s->id,0,&settings,&first,expected,"fresh target/lock/Undo admission refuses before paint");
    mutate(engine,&m,TRUE);close_scene(engine,s);
  }
}
static void stale_target(GlimsEngine *engine,unsigned kind,gboolean finish,gboolean explicit_cancel) {
  printf("STALE kind=%u end=%d explicit_cancel=%d\n",kind,finish,explicit_cancel);
  Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT,2,HARD);if(!s)return;
  Snapshot *before=take_snapshot(engine,s);GlimsStrokeID stroke=0;
  CHECK(begin(engine,s,&stroke)==GLIMS_STATUS_OK && stroke,"begin stale-target witness");
  if(stroke) {
    Snapshot *during=take_snapshot(engine,s);
    if(before && during)CHECK(!same_pixels(s,before,during),"stale-target witness has tentative damage");
    destroy_snapshot(during);
    Mutation m={.scene=s,.kind=kind};mutate(engine,&m,FALSE);
    Snapshot *guarded=(kind==FREEZE_UNDO || kind==GROUP_UNDO)?take_snapshot(engine,s):NULL;
    GlimsStatus result=explicit_cancel?api->stroke_cancel_lab(engine,stroke):
      finish?api->stroke_end(engine,stroke):advance(engine,stroke,40.5,2);
    if(explicit_cancel)CHECK(result==GLIMS_STATUS_OK,"explicit cancel tolerates damaged identity metadata");
    else if(kind==FREEZE_UNDO || kind==GROUP_UNDO)CHECK(result==GLIMS_STATUS_BUSY,"changed Undo state cancels with BUSY");
    else CHECK(result!=GLIMS_STATUS_OK,"stale selection/identity/lock refuses continuation or finish");
    if(guarded) {
      Snapshot *cancelled=take_snapshot(engine,s);
      if(cancelled)CHECK(same_history(guarded,cancelled),"cancel adds no native history while external Undo state is held");
      destroy_snapshot(cancelled);destroy_snapshot(guarded);
    }
    mutate(engine,&m,TRUE);
    CHECK(api->stroke_cancel_lab(engine,stroke)==GLIMS_STATUS_NOT_FOUND,"target failure retires entire stroke handle");
    Snapshot *after=take_snapshot(engine,s);
    if(before && after) {
      CHECK(same_pixels(s,before,after)&&same_metadata(before,after),"target failure restores original pixels and target metadata");
      if(kind!=GROUP_UNDO && kind!=FREEZE_UNDO)CHECK(same_history(before,after),"target failure preserves exact native history");
    }
    destroy_snapshot(after);
  }
  destroy_snapshot(before);close_scene(engine,s);
}
static void late_nan(GlimsEngine *engine) {
  Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT,0,LATE_NAN);if(!s)return;
  Snapshot *before=take_snapshot(engine,s);GlimsStrokeID stroke=0;
  CHECK(begin(engine,s,&stroke)==GLIMS_STATUS_OK && stroke,"first dab before affected later NaN succeeds");
  if(stroke) {
    Snapshot *during=take_snapshot(engine,s);
    if(before && during)CHECK(!same_pixels(s,before,during),"late failure witness first dab actually paints");destroy_snapshot(during);
    CHECK(advance(engine,stroke,80.5,2)==GLIMS_STATUS_FAILED,"affected NaN in later dab rejects physical blend");
    CHECK(api->stroke_cancel_lab(engine,stroke)==GLIMS_STATUS_NOT_FOUND,"pixel failure retires stroke");
    expect_original(engine,s,before,"late pixel failure rolls back ALL previous dabs and history");
  }
  destroy_snapshot(before);close_scene(engine,s);
}
/* A small mode-agnostic raw capture is independent of render/display conversion. */
typedef struct { GlimsImageID id;GBytes *bytes;int undo,redo;guint64 revision;gboolean dirty;GlimsItemID first; } RawImage;
static GlimsStatus raw_image_native(GlimsEngine *engine,gpointer data) {
  RawImage *state=data;GlimsOpenImage *open=glims_lookup_image(engine,state->id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  GByteArray *bytes=g_byte_array_new();GList *items=gimp_image_get_layer_list(open->image);
  items=g_list_concat(items,gimp_image_get_channel_list(open->image));
  for(GList *it=items;it;it=it->next) {
    GimpDrawable *d=GIMP_DRAWABLE(it->data);GeglBuffer *buffer=gimp_drawable_get_buffer(d);
    if(!state->first)state->first=gimp_item_get_id(GIMP_ITEM(d));
    int w=gimp_item_get_width(GIMP_ITEM(d)),h=gimp_item_get_height(GIMP_ITEM(d));
    size_t count=(size_t)w*h*babl_format_get_bytes_per_pixel(gimp_drawable_get_format(d));
    if(w>W || h>H || count>4*MAX_BYTES){g_list_free(items);g_byte_array_unref(bytes);return GLIMS_STATUS_FAILED;}
    guint8 *raw=g_malloc(count);gegl_buffer_get(buffer,GEGL_RECTANGLE(0,0,w,h),1,gimp_drawable_get_format(d),raw,
      GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);g_byte_array_append(bytes,raw,count);g_free(raw);
  }
  g_list_free(items);state->bytes=g_byte_array_free_to_bytes(bytes);
  state->undo=gimp_undo_stack_get_depth(gimp_image_get_undo_stack(open->image));
  state->redo=gimp_undo_stack_get_depth(gimp_image_get_redo_stack(open->image));
  state->revision=open->history_revision;state->dirty=gimp_image_is_dirty(open->image);return GLIMS_STATUS_OK;
}
static RawImage raw_image(GlimsEngine *engine,GlimsImageID id) {
  RawImage state={.id=id};CHECK(glims_engine_call(engine,raw_image_native,&state)==GLIMS_STATUS_OK,"capture native raw mode witness");return state;
}
static void wrong_modes_and_rgb(GlimsEngine *engine) {
  Scene *lab=create_scene(engine,GLIMS_COLOR_COMPONENT_U8,0,HARD);if(!lab)return;
  GlimsLabBrushSettings settings=brush_settings(lab);GlimsStrokeSampleV2 point=sample(16.5,24.5,1);
  GlimsStrokePacketV2 first=packet(&point,1);char *error=NULL;GlimsImageID ids[2]={0};
  CHECK(api->image_new(engine,W,H,&ids[0],&error)==GLIMS_STATUS_OK && ids[0],"create ordinary RGB witness");api->free_string(error);error=NULL;
  CHECK(api->image_new_multichannel(engine,W,H,GLIMS_COLOR_COMPONENT_U8,4,&ids[1],&error)==GLIMS_STATUS_OK && ids[1],"create ink mode witness");api->free_string(error);
  for(unsigned i=0;i<2;i++)if(ids[i]) {
    RawImage before=raw_image(engine,ids[i]);GlimsStrokeID stroke=123;error=NULL;
    CHECK(api->stroke_begin_lab(engine,ids[i],0,&settings,&first,&stroke,&error)==GLIMS_STATUS_UNSUPPORTED && stroke==0,
      "Lab begin cannot target ordinary RGB or Multichannel carrier");api->free_string(error);
    RawImage after=raw_image(engine,ids[i]);
    CHECK(bytes_equal(before.bytes,after.bytes)&&before.undo==after.undo&&before.redo==after.redo&&
      before.revision==after.revision&&before.dirty==after.dirty,"wrong-mode refusal leaves raw pixels/history unchanged");
    g_clear_pointer(&before.bytes,g_bytes_unref);g_clear_pointer(&after.bytes,g_bytes_unref);
  }
  GlimsBrushSettings rgb={.struct_size=sizeof rgb,.size=11,.opacity=1,.red=1,.green=0,.blue=0,
    .tool=GLIMS_PAINT_PAINTBRUSH,.hardness=1,.rate=-1,.flow=-1,.exposure=-1};
  GlimsStrokePoint initial={.x=16.5,.y=24.5,.pressure=1,.time_ms=1};GlimsStrokeID stroke=0;error=NULL;
  CHECK(api->stroke_begin(engine,lab->id,lab->ids[0],&rgb,&initial,&stroke,&error)==GLIMS_STATUS_UNSUPPORTED && stroke==0,
    "legacy RGB/ink brush entry refuses Lab axis");api->free_string(error);
  if(ids[0]) {
    RawImage before=raw_image(engine,ids[0]);stroke=0;error=NULL;
    CHECK(api->stroke_begin(engine,ids[0],before.first,&rgb,&initial,&stroke,&error)==GLIMS_STATUS_OK && stroke,
      "ordinary RGB stroke still begins");api->free_string(error);
    if(stroke) {
      CHECK(api->stroke_cancel_lab(engine,stroke)==GLIMS_STATUS_UNSUPPORTED,"typed Lab cancel cannot cancel ordinary RGB stroke");
      GlimsStrokePoint next={.x=30.5,.y=24.5,.pressure=1,.time_ms=2};
      CHECK(api->stroke_continue(engine,stroke,&next,1)==GLIMS_STATUS_OK && api->stroke_end(engine,stroke)==GLIMS_STATUS_OK,
        "ordinary RGB stroke remains live and commits after Lab cancel refusal");
      RawImage painted=raw_image(engine,ids[0]);
      CHECK(!bytes_equal(before.bytes,painted.bytes)&&painted.undo==before.undo+1,"ordinary RGB brush paints with one Undo");
      CHECK(api->image_undo(engine,ids[0])==GLIMS_STATUS_OK,"ordinary RGB stroke Undo succeeds");
      RawImage undone=raw_image(engine,ids[0]);CHECK(bytes_equal(before.bytes,undone.bytes),"ordinary RGB Undo exact raw pixels");
      g_clear_pointer(&painted.bytes,g_bytes_unref);g_clear_pointer(&undone.bytes,g_bytes_unref);
    }
    g_clear_pointer(&before.bytes,g_bytes_unref);
  }
  for(unsigned i=0;i<2;i++)if(ids[i])CHECK(api->image_close(engine,ids[i])==GLIMS_STATUS_OK,"close owned wrong-mode witness");
  close_scene(engine,lab);
}
typedef struct {Scene *scene;gpointer image,axis;} WeakOwners;
static GlimsStatus watch_owners(GlimsEngine *engine,gpointer data) {
  WeakOwners *w=data;GlimsOpenImage *open=glims_lookup_image(engine,w->scene->id);if(!open)return GLIMS_STATUS_NOT_FOUND;
  w->image=open->image;w->axis=gimp_item_get_by_id(engine->gimp,w->scene->ids[w->scene->role]);
  g_object_add_weak_pointer(G_OBJECT(w->image),&w->image);g_object_add_weak_pointer(G_OBJECT(w->axis),&w->axis);
  return GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
  if(argc!=2)return 2;
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api || api->struct_size<offsetof(GlimsEngineAPI,stroke_cancel_lab)+sizeof api->stroke_cancel_lab)return 2;
  char *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL),*error=NULL;
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;
  GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);
  if(status!=GLIMS_STATUS_OK || !engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}
  api->free_string(error);
  CHECK(glims_engine_call(engine,install_private_brush,NULL)==GLIMS_STATUS_OK,"install owned deterministic native brush");
  reviewer_regressions(engine);save_while_live(engine,argv[1]);
  const uint32_t components[]={GLIMS_COLOR_COMPONENT_U8,GLIMS_COLOR_COMPONENT_U16,GLIMS_COLOR_COMPONENT_FLOAT};
  for(unsigned c=0;c<3;c++)for(unsigned role=0;role<3;role++)happy_path(engine,components[c],role);
  no_op_cases(engine);settings_and_packet_refusals(engine);malformed_live_packet(engine);target_refusals(engine);
  for(unsigned kind=CHANGE_SELECTION;kind<=LOCK_AXIS;kind++) {
    stale_target(engine,kind,FALSE,FALSE);stale_target(engine,kind,TRUE,FALSE);
  }
  stale_target(engine,DAMAGE_UUID,FALSE,TRUE);
  stale_target(engine,FREEZE_UNDO,TRUE,FALSE);stale_target(engine,GROUP_UNDO,TRUE,FALSE);
  late_nan(engine);wrong_modes_and_rgb(engine);
  Scene *last=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT,1,HARD);
  WeakOwners *owners=g_new0(WeakOwners,1);GlimsStrokeID live=0;
  if(last){owners->scene=last;CHECK(begin(engine,last,&live)==GLIMS_STATUS_OK && live,"begin engine-stop cleanup witness");
    CHECK(glims_engine_call(engine,watch_owners,owners)==GLIMS_STATUS_OK,"watch native image and axis lifetime");}
  api->stop(engine);
  if(last)CHECK(!owners->image && !owners->axis,"engine stop retires live stroke and releases owned image/axis");
  /* Keep weak-pointer storage alive until all native owners were released. */
  if(!owners->image && !owners->axis)g_free(owners);
  g_free(last);
  printf("checks=%u failures=%u\n",checks,failures);return failures?1:0;
}

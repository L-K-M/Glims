/* Independent slot202 fixture. Native callbacks prepare/capture controlled
 * state; tested fills always use the public facade. Literal ICC-v4 code-space
 * oracles never call the production Lab codec, fill kernel or RGB renderer. */
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
#include <float.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

_Static_assert(offsetof(GlimsEngineAPI,image_curves_lab)==offsetof(GlimsEngineAPI,image_ink_snapshot_apply_curves)+sizeof(((GlimsEngineAPI*)0)->image_ink_snapshot_apply_curves),"append-only Lab Curves ABI");

#define W 128
#define H 96
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
      memcmp(a->mask,b->mask,sizeof a->mask) || memcmp(a->order,b->order,sizeof a->order) ||
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
static gboolean source_equal(const Scene *s, const Snapshot *a, const Snapshot *b) {
  return pixels_equal(s,a,b) && metadata_equal(a,b) && history_equal(a,b);
}

static GlimsStatus seed_native(GlimsEngine *engine, gpointer data) {
  Scene *s=data; GlimsOpenImage *open=glims_lookup_image(engine,s->id); GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open,&storage) || storage.map.count!=3) return GLIMS_STATUS_FAILED;
  guint8 *raw=g_malloc(MAX_BYTES); float *mask=g_new(float,N); GlimsStatus status=GLIMS_STATUS_FAILED;
  for (unsigned a=0;a<AXES;a++) {
    GimpDrawable *d=GIMP_DRAWABLE(storage.planes[a]); GimpItem *item=GIMP_ITEM(d);
    s->ids[a]=gimp_item_get_id(item);
    guint32 size=0; const GimpParasite *p=gimp_item_parasite_find(item,GLIMS_PLATE_UUID_PARASITE);
    const void *uuid=p?gimp_parasite_get_data(p,&size):NULL;
    if (!uuid || size!=16) goto done;
    memcpy(s->uuids[a],uuid,16);
    for (unsigned i=0;i<N;i++) {
      if (s->sample_size==1) raw[i]=a==0?0:(guint8)(20+a*70+i%31);
      else if (s->sample_size==2) { guint16 v=a==0?0:(guint16)((20+a*70+i%31)*257); memcpy(raw+i*2,&v,2); }
      else { float v=(a==0?10.f:a==1?-20.f:50.f)+(i%17)*.25f; memcpy(raw+i*4,&v,4); }
    }
    if (a==0 && s->sample_size==4 && s->bad>=1 && s->bad<=3) {
      guint32 bits=s->bad==2?UINT32_C(0x7f800000):UINT32_C(0x7fc12345);
      unsigned index=s->bad==3?4:N-1; memcpy(raw+index*4,&bits,4);
      if (s->bad==3) { const guint32 minus_zero=UINT32_C(0x80000000); memcpy(raw+8*4,&minus_zero,4); }
    }
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),0,
                    gimp_drawable_get_format(d),raw,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d,0,0,W,H);
    const char *names[]={"axis named b", "axis named L", "axis named a"};
    gimp_object_set_name(GIMP_OBJECT(item),names[a]);
    gimp_item_set_lock_content(item,FALSE,FALSE);
  }
  for (unsigned i=0;i<N;i++) {
    const float pattern[]={0.f,.25f,.5f,1.f};
    mask[i]=s->mask_kind==0?0.f:s->mask_kind==1?pattern[i%4]:1.f;
  }
  if (s->bad==4) { const guint32 nan=UINT32_C(0x7fc54321); memcpy(mask+N-1,&nan,4); }
  if (s->bad==5) mask[N-1]=1.25f;
  GimpDrawable *md=GIMP_DRAWABLE(gimp_image_get_mask(open->image));
  gegl_buffer_set(gimp_drawable_get_buffer(md),GEGL_RECTANGLE(0,0,W,H),0,babl_format("Y float"),mask,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(md,0,0,W,H);
  if (gimp_channel_is_empty(GIMP_CHANNEL(md)) != (s->mask_kind==0)) goto done;
  GList *selected=g_list_append(NULL,storage.planes[0]);
  gimp_image_set_selected_channels(open->image,selected); g_list_free(selected);
  GFile *file=g_file_new_for_uri("file:///lab-fill-fixture-source.xcf");
  gimp_image_set_file(open->image,file); gimp_image_set_imported_file(open->image,file);
  gimp_image_set_exported_file(open->image,file); gimp_image_set_save_a_copy_file(open->image,file); g_object_unref(file);
  gimp_image_undo_free(open->image); gimp_image_clean_all(open->image);
  /* Genuine dirty state and both history stacks make refusal/no-op checks meaningful. */
  GimpDrawable *d=GIMP_DRAWABLE(storage.planes[2]);
  guint8 first[4]={0},second[4]={0};
  if (s->sample_size==1) { first[0]=17; second[0]=42; }
  else if (s->sample_size==2) { guint16 a=17*257,b=42*257; memcpy(first,&a,2); memcpy(second,&b,2); }
  else { float a=.375f,b=42.f; memcpy(first,&a,4); memcpy(second,&b,4); }
  for (unsigned i=0;i<2;i++) {
    gimp_drawable_push_undo(d,"Fixture physical axis edit",NULL,0,0,1,1);
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,1,1),0,gimp_drawable_get_format(d),i?second:first,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(d,0,0,1,1);
  }
  if (!gimp_image_undo(open->image)) goto done;
  if (gimp_undo_stack_get_depth(gimp_image_get_undo_stack(open->image))!=1 ||
      gimp_undo_stack_get_depth(gimp_image_get_redo_stack(open->image))!=1 || !gimp_image_is_dirty(open->image)) goto done;
  status=GLIMS_STATUS_OK;
done: g_free(raw); g_free(mask); return status;
}
static Scene *create_scene(GlimsEngine *engine,uint32_t component,unsigned mask,unsigned bad) {
  Scene *s=g_new0(Scene,1); s->component=component; s->mask_kind=mask; s->bad=bad;
  s->sample_size=component==GLIMS_COLOR_COMPONENT_U8?1:component==GLIMS_COLOR_COMPONENT_U16?2:4;
  s->bytes=N*s->sample_size; char *error=NULL;
  GlimsStatus status=api->image_new_lab(engine,W,H,component,&s->id,&error);
  CHECK(status==GLIMS_STATUS_OK && s->id,"create public Lab image"); api->free_string(error);
  if (status!=GLIMS_STATUS_OK || !s->id) { g_free(s); return NULL; }
  gboolean ok=glims_engine_call(engine,seed_native,s)==GLIMS_STATUS_OK;
  CHECK(ok,"seed independent physical samples, selection and nonempty dirty history");
  GlimsLabAxes axes={.struct_size=sizeof axes};
  if (ok) {
    ok=api->image_lab_axes(engine,s->id,&axes)==GLIMS_STATUS_OK && axes.count==3 && axes.component==component;
    for (unsigned a=0;a<3 && ok;a++) ok=axes.axes[a].id==s->ids[a] && axes.axes[a].role==a && !memcmp(axes.axes[a].uuid,s->uuids[a],16);
    CHECK(ok,"public Lab axes match independently captured native role/UUID ownership");
  }
  if (!ok) { api->image_close(engine,s->id); g_free(s); return NULL; }
  return s;
}
static void close_scene(GlimsEngine *engine,Scene *s) {
  if (!s) return; if (s->id) CHECK(api->image_close(engine,s->id)==GLIMS_STATUS_OK,"close owned Lab fixture"); g_free(s);
}
static gboolean select_role(GlimsEngine *engine,Scene *s,unsigned role) {
  char *error=NULL; GlimsStatus status=api->channel_command(engine,s->id,s->ids[role],GLIMS_CHANNEL_SELECT,NULL,&error);
  api->free_string(error); CHECK(status==GLIMS_STATUS_OK,"public SELECT targets the physical Lab axis");
  GlimsLabAxes axes={.struct_size=sizeof axes};
  gboolean ok=status==GLIMS_STATUS_OK && api->image_lab_axes(engine,s->id,&axes)==GLIMS_STATUS_OK;
  for (unsigned a=0;a<3 && ok;a++) ok=axes.axes[a].selected==(a==role);
  CHECK(ok,"selected Lab role is sole native target"); return ok;
}
/* Zero intensity argument selects canonical identity for no-op coverage;
 * otherwise this fixture uses a constant normalized table. */
static GlimsLabCurvesSettings settings(const Scene *s,unsigned role,double value,double active) {
  GlimsLabCurvesSettings r={.struct_size=sizeof r,.axis=s->ids[role],.role=role};
  memcpy(r.uuid,s->uuids[role],16);
  double normalized=role==0?value/100.:(value+128.)/255.;
  for(unsigned i=0;i<256;i++)r.samples[i]=active?normalized:(double)i/255.;
  return r;
}
static void oracle(const Scene *s,const Snapshot *before,unsigned role,double value,double opacity,guint8 *out) {
  memcpy(out,before->raw[role],s->bytes);
  for (unsigned i=0;i<N;i++) {
    long double w=(s->mask_kind==0?1.L:(long double)before->mask[i])*(long double)opacity;
    if (w==0) continue;
    long double original,target;
    if (s->sample_size==1) original=before->raw[role][i];
    else if (s->sample_size==2) { guint16 v; memcpy(&v,before->raw[role]+i*2,2); original=v; }
    else { float v; memcpy(&v,before->raw[role]+i*4,4); original=v; }
    if (s->sample_size==4) target=(long double)value;
    else if (role==0) target=(long double)value*(s->sample_size==1?255.L:65535.L)/100.L;
    else target=((long double)value+128.L)*(s->sample_size==1?1.L:257.L);
    /* Exact physical seeds (L=0, integer chroma) avoid conflating ideal
     * code interpolation with rounded binary64 physical half-tie behavior.
     * Target remains unquantized until the single final sample quantization. */
    long double result=(1.L-w)*original+w*target;
    if (s->sample_size==1) out[i]=(guint8)floorl(result+.5L);
    else if (s->sample_size==2) { guint16 v=(guint16)floorl(result+.5L); memcpy(out+i*2,&v,2); }
    else { float v=(float)result; memcpy(out+i*4,&v,4); }
  }
}

static void verify_roundtrip(GlimsEngine *engine,Scene *s,const Snapshot *expected,const char *work,unsigned serial) {
  char *path=g_strdup_printf("%s/lab-fill-%u-%u.xcf",work,s->component,serial),*error=NULL;
  GlimsImageID reopened=0;
  GlimsStatus status=api->image_save(engine,s->id,path,&error);
  CHECK(status==GLIMS_STATUS_OK,"save filled physical Lab XCF"); api->free_string(error); error=NULL;
  if (status!=GLIMS_STATUS_OK) goto done;
  status=api->image_open(engine,path,&reopened,&error);
  CHECK(status==GLIMS_STATUS_OK && reopened,"reopen filled physical Lab XCF"); api->free_string(error); error=NULL;
  if (status!=GLIMS_STATUS_OK || !reopened) goto done;
  GlimsLabAxes axes={.struct_size=sizeof axes};
  gboolean identity=api->image_lab_axes(engine,reopened,&axes)==GLIMS_STATUS_OK && axes.count==3 && axes.component==s->component;
  Scene copy=*s; copy.id=reopened;
  for (unsigned a=0;a<AXES && identity;a++) {
    identity=axes.axes[a].role==a && !memcmp(axes.axes[a].uuid,s->uuids[a],16);
    for (unsigned b=0;b<AXES;b++) if (axes.axes[a].id==s->ids[b]) identity=FALSE;
    copy.ids[a]=axes.axes[a].id;
  }
  CHECK(identity,"XCF keeps roles, precision and UUIDs with fresh document-scoped handles");
  if (identity) {
    Snapshot *actual=capture(engine,&copy);
    if (actual) {
      gboolean exact=pixels_equal(s,expected,actual) && same_bytes(expected->map,actual->map) && !actual->profile;
      for (unsigned a=0;a<AXES;a++) exact=exact && same_bytes(expected->uuid[a],actual->uuid[a]);
      CHECK(exact,"XCF preserves all physical raw samples and authoritative identities exactly");
    }
    snapshot_free(actual);
  }
done:
  if (reopened) CHECK(api->image_close(engine,reopened)==GLIMS_STATUS_OK,"close owned reopened XCF");
  g_free(path);
}
static void success(GlimsEngine *engine,Scene *s,unsigned role,double value,double opacity,
                    gboolean changed,gboolean literal,const char *work,unsigned serial) {
  if (!select_role(engine,s,role)) return;
  Snapshot *before=capture(engine,s),*after=NULL,*undone=NULL,*redone=NULL;
  guint8 *expected=g_malloc(s->bytes);
  if (!before) goto done;
  GlimsLabCurvesSettings set=settings(s,role,value,opacity); char *error=NULL;
  GlimsStatus status=api->image_curves_lab(engine,s->id,&set,&error);
  if (status!=GLIMS_STATUS_OK) fprintf(stderr,"fill status=%d: %s\n",status,error?error:"");
  CHECK(status==GLIMS_STATUS_OK,"public physical Lab Curves succeeds"); api->free_string(error);
  after=capture(engine,s); if (!after) goto done;
  oracle(s,before,role,value,opacity,expected);
  CHECK(!memcmp(after->raw[role],expected,s->bytes),"target raw bytes match independently blended physical/code-domain oracle");
  gboolean other=TRUE;
  for (unsigned a=0;a<AXES;a++) if (a!=role && memcmp(before->raw[a],after->raw[a],s->bytes)) other=FALSE;
  CHECK(other && metadata_equal(before,after),"fill preserves other axes, selection, metadata, identities and file state");
  CHECK((memcmp(before->raw[role],expected,s->bytes)!=0)==changed,"oracle confirms meaningful changed/no-op fixture precondition");
  if (literal) {
    gboolean exact=TRUE;
    for (unsigned i=0;i<N;i++) {
      if (s->sample_size==1) { if (after->raw[role][i]!=128) exact=FALSE; }
      else if (s->sample_size==2) { guint16 got; memcpy(&got,after->raw[role]+i*2,2); if (got!=32768) exact=FALSE; }
      else { const float want=role==0?50.f:-.5f; if (memcmp(after->raw[role]+i*4,&want,4)) exact=FALSE; }
    }
    CHECK(exact,"literal midpoint goldens are 128, 32768, or physical 50/-.5");
  }
  if (!changed) { CHECK(source_equal(s,before,after),"no-op preserves exact pixels, dirty state and both history stacks"); goto done; }
  CHECK(after->undo==before->undo+1 && after->redo==0 && after->dirty,"one accepted fill adds exactly one Undo step");
  CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"public Undo succeeds");
  undone=capture(engine,s);
  if (undone) CHECK(pixels_equal(s,before,undone) && metadata_equal(before,undone) &&
      undone->undo==before->undo && undone->redo==1 && undone->dirty==before->dirty,
      "Undo restores every raw source byte and source metadata in one step");
  CHECK(api->image_redo(engine,s->id)==GLIMS_STATUS_OK,"public Redo succeeds");
  redone=capture(engine,s);
  if (redone) CHECK(pixels_equal(s,after,redone) && metadata_equal(after,redone) &&
      redone->undo==after->undo && redone->redo==0 && redone->dirty,
      "Redo restores every committed physical sample in one step");
  if (work && redone) verify_roundtrip(engine,s,redone,work,serial);
done:
  g_free(expected); snapshot_free(before); snapshot_free(after); snapshot_free(undone); snapshot_free(redone);
}
static void refusal(GlimsEngine *engine,Scene *s,const GlimsLabCurvesSettings *set,GlimsStatus expected,const char *label) {
  Snapshot *before=capture(engine,s),*after=NULL; if (!before) return;
  char *error=NULL; GlimsStatus status=api->image_curves_lab(engine,s->id,set,&error);
  CHECK(expected==GLIMS_STATUS_FAILED ? status!=GLIMS_STATUS_OK && status!=GLIMS_STATUS_NOT_RUNNING : status==expected,label);
  api->free_string(error); after=capture(engine,s);
  if (after) CHECK(source_equal(s,before,after),"refusal publishes no pixels/history and does not repair source metadata");
  snapshot_free(before); snapshot_free(after);
}

typedef struct { Scene *scene; guint count; gboolean lock; } SelectControl;
static GlimsStatus control_selection(GlimsEngine *engine,gpointer data) {
  SelectControl *c=data; GlimsOpenImage *open=glims_lookup_image(engine,c->scene->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GList *list=NULL;
  for (unsigned a=0;a<c->count;a++) {
    GimpItem *item=gimp_item_get_by_id(engine->gimp,c->scene->ids[a]);
    if (!item) { g_list_free(list); return GLIMS_STATUS_FAILED; } list=g_list_append(list,item);
  }
  gimp_image_set_selected_channels(open->image,list); g_list_free(list);
  GimpItem *item=gimp_item_get_by_id(engine->gimp,c->scene->ids[0]);
  gimp_item_set_lock_content(item,c->lock,FALSE);
  return g_list_length(gimp_image_get_selected_channels(open->image))==c->count &&
    gimp_item_get_lock_content(item)==c->lock ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}
static GlimsStatus damage_map(GlimsEngine *engine,gpointer data) {
  Scene *s=data; GlimsOpenImage *open=glims_lookup_image(engine,s->id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  gimp_image_parasite_detach(open->image,GLIMS_PLATE_MAP_PARASITE,FALSE);
  return gimp_image_parasite_find(open->image,GLIMS_PLATE_MAP_PARASITE)?GLIMS_STATUS_FAILED:GLIMS_STATUS_OK;
}
static void invalid_cases(GlimsEngine *engine,Scene *s) {
  select_role(engine,s,0);
  GlimsLabCurvesSettings good=settings(s,0,25,1),bad;
  refusal(engine,s,NULL,GLIMS_STATUS_INVALID_ARGUMENT,"NULL settings refuse atomically");
  bad=good; bad.struct_size=sizeof bad-1;
  refusal(engine,s,&bad,GLIMS_STATUS_INVALID_ARGUMENT,"short settings refuse atomically");
  long page=sysconf(_SC_PAGESIZE);
  CHECK(page>0,"guard-page size available");
  if (page>0) {
    guint8 *pages=mmap(NULL,(size_t)page*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    CHECK(pages!=MAP_FAILED,"allocate short-settings guard pages");
    if (pages!=MAP_FAILED) {
      gboolean protected=mprotect(pages+page,(size_t)page,PROT_NONE)==0;
      CHECK(protected,"protect settings guard page");
      if (protected) {
        guint32 size=4; size_t prefix=_Alignof(GlimsLabCurvesSettings);
        guint8 *guard=pages+page-prefix;
        memset(guard,0xA5,prefix); memcpy(guard,&size,4);
        refusal(engine,s,(const GlimsLabCurvesSettings *)guard,GLIMS_STATUS_INVALID_ARGUMENT,
                "short aligned settings header refuses before inaccessible payload");
        gboolean unchanged=!memcmp(guard,&size,4);
        for (size_t i=4;i<prefix;i++) if (guard[i]!=0xA5) unchanged=FALSE;
        CHECK(unchanged,"short input header and alignment padding remain unchanged");
      }
      munmap(pages,(size_t)page*2);
    }
  }
  struct { GlimsLabCurvesSettings settings; guint8 tail[32]; } future, saved;
  memset(&future,0xA5,sizeof future); future.settings=good;
  future.settings.struct_size=sizeof future; for(unsigned i=0;i<256;i++)future.settings.samples[i]=(double)i/255.; saved=future;
  Snapshot *future_before=capture(engine,s); char *future_error=NULL;
  CHECK(api->image_curves_lab(engine,s->id,&future.settings,&future_error)==GLIMS_STATUS_OK,
        "future-capacity settings accept the known identity-table prefix");
  api->free_string(future_error);
  CHECK(!memcmp(&future,&saved,sizeof future),"input settings and extension tail remain immutable");
  Snapshot *future_after=capture(engine,s);
  if (future_before && future_after) CHECK(source_equal(s,future_before,future_after),"future-prefix no-op leaves source unchanged");
  snapshot_free(future_before); snapshot_free(future_after);
  bad=good; bad.axis=0; refusal(engine,s,&bad,GLIMS_STATUS_INVALID_ARGUMENT,"zero explicit axis refuses");
  bad=good; bad.axis=-1; refusal(engine,s,&bad,GLIMS_STATUS_FAILED,"unknown explicit axis refuses");
  bad=good; bad.uuid[0]^=1; refusal(engine,s,&bad,GLIMS_STATUS_FAILED,"wrong captured UUID refuses");
  bad=good; memset(bad.uuid,0,16); refusal(engine,s,&bad,GLIMS_STATUS_FAILED,"zero UUID refuses");
  bad=good; bad.role=1; refusal(engine,s,&bad,GLIMS_STATUS_FAILED,"valid but mismatched role refuses");
  bad=good; bad.role=99; refusal(engine,s,&bad,GLIMS_STATUS_INVALID_ARGUMENT,"unknown role refuses");
  const double invalid[]={NAN,INFINITY,-INFINITY,-.01,1.01};
  for(unsigned i=0;i<G_N_ELEMENTS(invalid);i++) {
    bad=good;bad.samples[255]=invalid[i];
    refusal(engine,s,&bad,GLIMS_STATUS_INVALID_ARGUMENT,"invalid final table sample refuses atomically");
  }
  SelectControl control={s,0,FALSE};
  CHECK(glims_engine_call(engine,control_selection,&control)==GLIMS_STATUS_OK,"fixture installs no selected axis");
  refusal(engine,s,&good,GLIMS_STATUS_FAILED,"no selection refuses instead of choosing an axis");
  control.count=2; CHECK(glims_engine_call(engine,control_selection,&control)==GLIMS_STATUS_OK,"fixture installs two selected axes");
  refusal(engine,s,&good,GLIMS_STATUS_FAILED,"multiple selected axes refuse");
  control.count=1; control.lock=TRUE; CHECK(glims_engine_call(engine,control_selection,&control)==GLIMS_STATUS_OK,"fixture locks captured axis");
  refusal(engine,s,&good,GLIMS_STATUS_FAILED,"content lock refuses");
  control.lock=FALSE; CHECK(glims_engine_call(engine,control_selection,&control)==GLIMS_STATUS_OK,"restore unlocked target");
  select_role(engine,s,1); refusal(engine,s,&good,GLIMS_STATUS_FAILED,"selected axis changes do not retarget captured fill");
  select_role(engine,s,0);
  Scene *foreign=create_scene(engine,s->component,2,0);
  if (foreign) {
    bad=settings(foreign,0,25,1); refusal(engine,s,&bad,GLIMS_STATUS_FAILED,"other document handle and UUID cannot fill this owner"); close_scene(engine,foreign);
  }
  const guint commands[]={GLIMS_CHANNEL_DUPLICATE,GLIMS_CHANNEL_DELETE,GLIMS_CHANNEL_SELECT};
  for (unsigned i=0;i<G_N_ELEMENTS(commands);i++) {
    Snapshot *before=capture(engine,s); char *error=NULL; GlimsItemID result=0;
    GlimsStatus status=api->channel_command(engine,s->id,i==2?0:s->ids[0],commands[i],&result,&error);
    CHECK(status!=GLIMS_STATUS_OK,"Lab duplicate/delete/return-to-layers remain unavailable"); api->free_string(error);
    Snapshot *after=capture(engine,s); if (before && after) CHECK(source_equal(s,before,after),"unsupported channel command preserves Lab source");
    snapshot_free(before); snapshot_free(after);
  }
  CHECK(glims_engine_call(engine,damage_map,s)==GLIMS_STATUS_OK,"remove authoritative map for malformed source witness");
  refusal(engine,s,&good,GLIMS_STATUS_UNSUPPORTED,"malformed authoritative metadata refuses without repair");
}

static void late_failures(GlimsEngine *engine) {
  for (unsigned bad=1;bad<=5;bad++) {
    Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT,bad==3?1:2,bad);
    if (!s) continue;
    Snapshot *before=capture(engine,s);
    if (before) {
      float last; memcpy(&last,before->raw[0]+(N-1)*4,4);
      gboolean witness=bad==1?isnan(last):bad==2?isinf(last):
        bad==4?isnan(before->mask[N-1]):bad==5?before->mask[N-1]>1:TRUE;
      CHECK(witness,"late invalid value survives native fixture storage after earlier valid tiles");
      if (bad==3) {
        guint32 bits; memcpy(&bits,before->raw[0]+4*4,4);
        CHECK(bits==UINT32_C(0x7fc12345) && before->mask[4]==0 && before->mask[8]==0,
              "masked-out NaN payload and signed zero are literal zero-coverage witnesses");
      }
      snapshot_free(before);
    }
    if (bad==3) success(engine,s,0,50,1,TRUE,FALSE,NULL,0);
    else { GlimsLabCurvesSettings identity=settings(s,0,0,0); refusal(engine,s,&identity,GLIMS_STATUS_FAILED,"identity still validates affected samples and masks"); GlimsLabCurvesSettings set=settings(s,0,25,1); refusal(engine,s,&set,GLIMS_STATUS_FAILED,"late invalid source/mask refuses every tile atomically"); }
    close_scene(engine,s);
  }
}

typedef struct { GlimsImageID id; char digest[65]; } Foreign;
static GlimsStatus foreign_digest(GlimsEngine *engine,gpointer data) {
  Foreign *f=data; GlimsOpenImage *open=glims_lookup_image(engine,f->id); GlimsPlateStorage storage;
  if (!open || !glims_plate_storage_read_open(open,&storage)) return GLIMS_STATUS_FAILED;
  GChecksum *sum=g_checksum_new(G_CHECKSUM_SHA256); guint8 *raw=g_malloc(MAX_BYTES);
  for (unsigned a=0;a<storage.map.count;a++) {
    GimpDrawable *d=GIMP_DRAWABLE(storage.planes[a]); const Babl *format=gimp_drawable_get_format(d);
    size_t bytes=N*(size_t)babl_format_get_bytes_per_pixel(format);
    if (bytes>MAX_BYTES) { g_free(raw); g_checksum_free(sum); return GLIMS_STATUS_FAILED; }
    gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,W,H),1,format,raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    g_checksum_update(sum,raw,bytes);
    const GimpParasite *p=gimp_item_parasite_find(GIMP_ITEM(d),GLIMS_PLATE_UUID_PARASITE); guint32 size=0;
    const void *uuid=p?gimp_parasite_get_data(p,&size):NULL;
    if (!uuid || size!=16) { g_free(raw); g_checksum_free(sum); return GLIMS_STATUS_FAILED; }
    g_checksum_update(sum,uuid,size);
  }
  const char *parasites[]={GLIMS_PLATE_MAP_PARASITE,GLIMS_PLATE_PROFILE_PARASITE};
  for (unsigned i=0;i<2;i++) {
    const GimpParasite *p=gimp_image_parasite_find(open->image,parasites[i]); guint32 size=0;
    const void *bytes=p?gimp_parasite_get_data(p,&size):NULL;
    if (bytes) g_checksum_update(sum,bytes,size);
  }
  g_strlcpy(f->digest,g_checksum_get_string(sum),sizeof f->digest);
  g_free(raw); g_checksum_free(sum); return GLIMS_STATUS_OK;
}
static void other_modes(GlimsEngine *engine,const guint8 *profile,gsize profile_size) {
  Scene *owner=create_scene(engine,GLIMS_COLOR_COMPONENT_U8,2,0); if (!owner) return;
  GlimsLabCurvesSettings set=settings(owner,0,25,1);
  for (unsigned mode=0;mode<3;mode++) {
    GlimsImageID id=0; char *error=NULL; GlimsStatus status;
    if (mode==0) status=api->image_new(engine,W,H,&id,&error);
    else if (mode==1) status=api->image_new_multichannel(engine,W,H,GLIMS_COLOR_COMPONENT_U8,3,&id,&error);
    else status=api->image_new_cmyk(engine,W,H,GLIMS_COLOR_COMPONENT_U16,profile,profile_size,&id,&error);
    CHECK(status==GLIMS_STATUS_OK && id,"create real ordinary/Multichannel/CMYK refusal witness"); api->free_string(error); error=NULL;
    if (status!=GLIMS_STATUS_OK || !id) continue;
    GlimsImageInfo ib={0},ia={0}; GlimsUndoInfo ub={0},ua={0};
    gboolean captured=api->image_info(engine,id,&ib)==GLIMS_STATUS_OK && api->image_undo_info(engine,id,&ub)==GLIMS_STATUS_OK;
    Foreign before={.id=id},after={.id=id}; guint8 *rgb_before=NULL,*rgb_after=NULL;
    if (mode==0) {
      rgb_before=g_malloc(N*4); rgb_after=g_malloc(N*4);
      captured=captured && api->image_render(engine,id,1,(GlimsRect){0,0,W,H},rgb_before,W*4)==GLIMS_STATUS_OK;
    } else captured=captured && glims_engine_call(engine,foreign_digest,&before)==GLIMS_STATUS_OK;
    CHECK(captured,"capture other mode source independently before refusal");
    status=api->image_curves_lab(engine,id,&set,&error);
    CHECK(status==GLIMS_STATUS_UNSUPPORTED,"Lab Curves explicitly refuses ordinary and ink documents"); api->free_string(error);
    gboolean exact=api->image_info(engine,id,&ia)==GLIMS_STATUS_OK && api->image_undo_info(engine,id,&ua)==GLIMS_STATUS_OK &&
      !memcmp(&ib,&ia,sizeof ib) && !memcmp(&ub,&ua,sizeof ub);
    if (mode==0) exact=exact && api->image_render(engine,id,1,(GlimsRect){0,0,W,H},rgb_after,W*4)==GLIMS_STATUS_OK && !memcmp(rgb_before,rgb_after,N*4);
    else exact=exact && glims_engine_call(engine,foreign_digest,&after)==GLIMS_STATUS_OK && !strcmp(before.digest,after.digest);
    CHECK(captured && exact,"ordinary/ink refusal preserves pixels, metadata and history");
    g_free(rgb_before); g_free(rgb_after); CHECK(api->image_close(engine,id)==GLIMS_STATUS_OK,"close owned other-mode witness");
  }
  close_scene(engine,owner);
}

/* Progress callbacks schedule a test-only idle; they never reenter the facade. */
typedef struct {
  GlimsEngine *engine; Scene *scene;
  gint armed,paused,release,timed_out,projection_events;
  double pause_value;
  GlimsStatus status;
  char *error;
  GlimsLabCurvesSettings settings;
} Control;
static gboolean pause_idle(gpointer data) {
  Control *c=data; gint64 deadline=g_get_monotonic_time()+WAIT_US;
  g_atomic_int_set(&c->paused,1);
  while (!g_atomic_int_get(&c->release)) {
    g_mutex_lock(&c->engine->lock); gboolean stopping=c->engine->stopping; g_mutex_unlock(&c->engine->lock);
    if (stopping) break;
    if (g_get_monotonic_time()>deadline) { g_atomic_int_set(&c->timed_out,1); break; }
    g_main_context_iteration(NULL,FALSE); g_usleep(1000);
  }
  return G_SOURCE_REMOVE;
}
static void event(void *data,const GlimsEvent *event) {
  Control *c=data;
  Scene *scene=g_atomic_pointer_get(&c->scene);
  if (scene && event->kind==GLIMS_EVENT_PROJECTION_CHANGED && event->image==scene->id)
    g_atomic_int_inc(&c->projection_events);
  if (event->kind==GLIMS_EVENT_PROGRESS && event->active && g_atomic_int_get(&c->armed)==1 && event->value>=c->pause_value &&
      g_atomic_int_compare_and_exchange(&c->armed,1,0)) g_idle_add_full(G_PRIORITY_HIGH,pause_idle,c,NULL);
}
static gpointer fill_worker(gpointer data) {
  Control *c=data; c->status=api->image_curves_lab(c->engine,c->scene->id,&c->settings,&c->error); return NULL;
}
static GlimsStatus drain_idle(GlimsEngine *engine,gpointer data) { (void)engine; (void)data; return GLIMS_STATUS_OK; }
static void controlled_cases(Control *c) {
  Scene *scene=create_scene(c->engine,GLIMS_COLOR_COMPONENT_U16,1,0);
  g_atomic_pointer_set(&c->scene,scene); if (!scene) return;
  for (unsigned kind=0;kind<3;kind++) {
    select_role(c->engine,c->scene,0);
    Snapshot *before=capture(c->engine,c->scene),*injected=NULL,*after=NULL;
    if (!before) continue;
    c->settings=settings(c->scene,0,100,1); c->status=GLIMS_STATUS_FAILED; c->error=NULL;
    c->pause_value=kind==0?.25:1.;
    g_atomic_int_set(&c->paused,0); g_atomic_int_set(&c->release,0); g_atomic_int_set(&c->timed_out,0);
    g_atomic_int_set(&c->projection_events,0); g_atomic_int_set(&c->armed,1);
    GThread *thread=g_thread_new("lab-fill-controlled",fill_worker,c);
    gint64 deadline=g_get_monotonic_time()+WAIT_US;
    while (!g_atomic_int_get(&c->paused) && g_get_monotonic_time()<deadline) g_usleep(1000);
    gboolean paused=g_atomic_int_get(&c->paused);
    CHECK(paused,kind==0?"reach an actual partial-staging checkpoint":"reach final staging checkpoint before publication");
    if (paused) {
      Snapshot *during=capture(c->engine,c->scene);
      if (during) CHECK(source_equal(c->scene,before,during),"staged fill has not published any source state");
      snapshot_free(during);
      char *error=NULL;
      CHECK(api->image_curves_lab(c->engine,c->scene->id,&c->settings,&error)==GLIMS_STATUS_BUSY,
            "another pixel mutation refuses while Lab Curves owns the engine"); api->free_string(error); error=NULL;
      if (kind<2) CHECK(api->procedure_cancel(c->engine)==GLIMS_STATUS_OK,"Cancel reaches active staged Lab Curves");
      else {
        CHECK(api->channel_command(c->engine,c->scene->id,c->scene->ids[1],GLIMS_CHANNEL_SELECT,NULL,&error)==GLIMS_STATUS_OK,
              "public target selection remains admitted during staging");
        api->free_string(error);
        injected=capture(c->engine,c->scene);
        if (injected) CHECK(injected->selected_count==1 && injected->selected[0]==c->scene->ids[1] &&
            pixels_equal(c->scene,before,injected) && history_equal(before,injected),
            "interference changes only selection, not candidate pixels or history");
      }
    }
    g_atomic_int_set(&c->release,1); g_thread_join(thread); g_atomic_int_set(&c->armed,0);
    /* A late scheduled high-priority idle must finish before state is reused. */
    CHECK(glims_engine_call(c->engine,drain_idle,NULL)==GLIMS_STATUS_OK,"drain owned progress idle safely");
    CHECK(!g_atomic_int_get(&c->timed_out),"progress checkpoint exits without watchdog timeout");
    CHECK(kind<2?c->status==GLIMS_STATUS_CANCELLED:c->status!=GLIMS_STATUS_OK,
          kind<2?"cancelled operation reports CANCELLED":"changed captured selection refuses publication");
    api->free_string(c->error); c->error=NULL; after=capture(c->engine,c->scene);
    const Snapshot *expected=kind==2?injected:before;
    if (after && expected) CHECK(source_equal(c->scene,expected,after),"interruption preserves every raw axis and exact history");
    CHECK(g_atomic_int_get(&c->projection_events)==0,"interruption publishes no projection damage");
    CHECK(api->procedure_cancel(c->engine)==GLIMS_STATUS_NOT_FOUND,"operation releases cancellation ownership");
    snapshot_free(before); snapshot_free(injected); snapshot_free(after);
  }
  success(c->engine,c->scene,0,50,1,TRUE,FALSE,NULL,0);
  Scene *owned=c->scene; g_atomic_pointer_set(&c->scene,NULL); close_scene(c->engine,owned);
}

int main(int argc,char **argv) {
  if (argc<2) { fprintf(stderr,"usage: %s WORK [CMYK_PROFILE]\n",argv[0]); return 2; }
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size<offsetof(GlimsEngineAPI,image_curves_lab)+sizeof api->image_curves_lab || !api->image_curves_lab) {
    fprintf(stderr,"Adapter lacks slot202 image_curves_lab\n"); return 2;
  }
  const char *profile_path=argc>2?argv[2]:getenv("GLIMS_TEST_CMYK_PROFILE");
  gchar *profile=NULL; gsize profile_size=0;
  if (!profile_path || !g_file_get_contents(profile_path,&profile,&profile_size,NULL) || profile_size<128 || profile_size>4u*1024u*1024u) {
    fprintf(stderr,"CMYK refusal witness requires a readable real ICC profile\n"); g_free(profile); return 2;
  }
  Control *control=g_new0(Control,1);
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache,
    .on_event=event,.event_context=control}; char *error=NULL;
  GlimsStatus status=api->start(&config,&control->engine,&error); g_free(user); g_free(cache);
  if (status!=GLIMS_STATUS_OK || !control->engine) {
    fprintf(stderr,"engine start: %s\n",error?error:""); api->free_string(error); g_free(profile); g_free(control); return 2;
  }
  api->free_string(error); GlimsEngine *engine=control->engine; unsigned serial=0;
  const uint32_t components[]={GLIMS_COLOR_COMPONENT_U8,GLIMS_COLOR_COMPONENT_U16,GLIMS_COLOR_COMPONENT_FLOAT};
  for (unsigned c=0;c<3;c++) {
    for (unsigned role=0;role<3;role++) {
      Scene *s=create_scene(engine,components[c],2,0);
      if (s) { success(engine,s,role,role==0?50:-.5,1,TRUE,TRUE,argv[1],serial++); close_scene(engine,s); }
      s=create_scene(engine,components[c],1,0);
      if (s) { success(engine,s,role,role==0?50:-.5,1,TRUE,FALSE,NULL,0); close_scene(engine,s); }
    }
    Scene *s=create_scene(engine,components[c],0,0);
    if (s) { success(engine,s,0,50,1,TRUE,TRUE,NULL,0); close_scene(engine,s); }
    s=create_scene(engine,components[c],1,0);
    if (s) {
      success(engine,s,0,25,0,FALSE,FALSE,NULL,0);
      success(engine,s,1,0,0,FALSE,FALSE,NULL,0);
      invalid_cases(engine,s); close_scene(engine,s);
    }
  }
  late_failures(engine); other_modes(engine,(const guint8 *)profile,profile_size); controlled_cases(control);
  api->stop(engine); g_free(control); g_free(profile);
  printf("checks=%u failures=%u\n",checks,failures); return failures?1:0;
}

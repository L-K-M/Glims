/* Bounded slot210-212 Lab Levels edit and snapshot checks.
 * Self-contained; reuses the public facade plus Core callbacks only to seed and
 * read raw Lab planes, selection, metadata and history (patterns from existing
 * Lab Curves edit/snapshot fixtures). Literal/independent expected outputs only;
 * no production Levels codec/kernel is used to derive expected bytes. */
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

_Static_assert(offsetof(GlimsEngineAPI, image_levels_lab) ==
               offsetof(GlimsEngineAPI, stroke_cancel_ink) + sizeof(((GlimsEngineAPI*)0)->stroke_cancel_ink),
               "append-only Lab Levels ABI");

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
  unsigned mask_kind; /* 0 empty/no selection, 1 patterned, 2 full */
  unsigned bad; /* 1 NaN,2 Inf,3 masked NaN,4 bad mask NaN,5 bad mask >1 */
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
static gboolean same_bytes(GBytes *a, GBytes *b) { return (!a || !b) ? a == b : g_bytes_equal(a, b); }
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
    GimpItem *item = gimp_item_get_by_id(engine->gimp, scene->ids[a]);
    if (!item || !GIMP_IS_CHANNEL(item) || !gimp_item_is_attached(item) ||
        gimp_item_get_image(item) != image) return GLIMS_STATUS_FAILED;
    GimpDrawable *d = GIMP_DRAWABLE(item);
    const Babl *format = gimp_drawable_get_format(d);
    if (babl_format_get_n_components(format) != 1 ||
        (size_t)babl_format_get_bytes_per_pixel(format) != scene->sample_size)
      return GLIMS_STATUS_FAILED;
    gegl_buffer_get(gimp_drawable_get_buffer(d), GEGL_RECTANGLE(0,0,W,H), 1, format, s->raw[a],
                    GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
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
      if (s->sample_size==1) raw[i]=(guint8)(a==0?(20+i%200):128);
      else if (s->sample_size==2) { guint16 v=a==0?(guint16)((20+i%200)*257u):32896u; memcpy(raw+i*2,&v,2); }
      else { float v=(a==0?10.f:a==1?0.f:50.f)+(i%17)*.25f;
        if(i==7)v=a==0?25.f:0.f; /* exact physical literal, full mask at index7 */
        memcpy(raw+i*4,&v,4); }
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
  GFile *file=g_file_new_for_uri("file:///lab-levels-fixture-source.xcf");
  gimp_image_set_file(open->image,file); gimp_image_set_imported_file(open->image,file);
  gimp_image_set_exported_file(open->image,file); gimp_image_set_save_a_copy_file(open->image,file); g_object_unref(file);
  gimp_image_undo_free(open->image); gimp_image_clean_all(open->image);
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

static GlimsLevelsChannel identity_channel(void) {
  GlimsLevelsChannel c={.low_input=0,.high_input=1,.gamma=1,.low_output=0,.high_output=1};
  return c;
}
static GlimsLabLevelsSettings level_settings(const Scene *s,unsigned role,GlimsLevelsChannel c,uint32_t clamp_in,uint32_t clamp_out) {
  GlimsLabLevelsSettings r={.struct_size=sizeof r,.axis=s->ids[role],.role=role,.value=c,.clamp_input=clamp_in,.clamp_output=clamp_out};
  memcpy(r.uuid,s->uuids[role],16);
  return r;
}

/* Independent analytic Levels on decoded physical samples (not production codec/kernel). */
static long double clamp01l(long double v){return v<0?0:(v>1?1:v);}
static long double decode_physical(const Scene *s,unsigned role,const guint8 *raw,size_t i) {
  if (s->sample_size==1) { guint8 q=raw[i]; return role==0?100.L*q/255.L:(long double)q-128.L; }
  if (s->sample_size==2) { guint16 q; memcpy(&q,raw+i*2,2); return role==0?100.L*q/65535.L:(long double)q/257.L-128.L; }
  float v; memcpy(&v,raw+i*4,4); return v;
}
static void write_physical(const Scene *s,unsigned role,guint8 *out,size_t i,long double physical) {
  if (s->sample_size==4) {float v=(float)physical;memcpy(out+i*4,&v,4);return;}
  long double maximum=s->sample_size==1?255.L:65535.L;
  long double code=role==0?physical*maximum/100.L:
    (physical+128.L)*(s->sample_size==1?1.L:257.L);
  code=floorl(code+.5L);if(code<0)code=0;if(code>maximum)code=maximum;
  if(s->sample_size==1)out[i]=(guint8)code;
  else {guint16 v=(guint16)code;memcpy(out+i*2,&v,2);}
}
static long double norm_from_physical(unsigned role,long double p){return role==0?p/100.L:(p+128.L)/255.L;}
static long double physical_from_norm(unsigned role,long double n){return role==0?n*100.L:n*255.L-128.L;}
static void levels_oracle(const Scene *s,const Snapshot *before,unsigned role,GlimsLevelsChannel c,uint32_t clamp_in,uint32_t clamp_out,guint8 *out) {
  memcpy(out,before->raw[role],s->bytes);
  for (unsigned i=0;i<N;i++) {
    long double cov=s->mask_kind==0?1.L:(long double)before->mask[i];
    if (cov==0) continue;
    long double original=decode_physical(s,role,before->raw[role],i);
    /* Exact affine algebra is independently stronger than normalize/denormalize:
     * identity is p, inversion is 100-p or -1-p. Do not introduce neutral
     * cancellation residue into a raw-byte oracle, even for fractional masks. */
    if(c.gamma==1 && !clamp_in && !clamp_out) {
      long double span=c.high_input!=c.low_input?(long double)c.high_input-c.low_input:1.L;
      long double slope=((long double)c.high_output-c.low_output)/span;
      long double scale=role==0?100.L:255.L, offset=role==0?0.L:-128.L;
      long double intercept=offset*(1.L-slope)+scale*((long double)c.low_output-c.low_input*slope);
      long double coefficient=1.L-cov+cov*slope;
      if(coefficient==1.L && cov*intercept==0.L)continue;
      write_physical(s,role,out,i,fmal(coefficient,original,cov*intercept));
      continue;
    }
    long double n=norm_from_physical(role,original);
    long double denom=(c.high_input!=c.low_input)?(c.high_input-c.low_input):1.L;
    long double t=(n-c.low_input)/denom;
    if (clamp_in) t=clamp01l(t);
    if (c.gamma!=1.L && t>0.L) t=powl(t,1.L/c.gamma);
    long double mapped=c.low_output+t*(c.high_output-c.low_output);
    if (clamp_out) mapped=clamp01l(mapped);
    long double target=physical_from_norm(role,mapped);
    long double blended=(1.L-cov)*original+cov*target;
    write_physical(s,role,out,i,blended);
  }
}

static gboolean oracle_matches(const Scene *s,const Snapshot *before,unsigned role,
                                GlimsLevelsChannel settings,const guint8 *expected,
                                const guint8 *actual,const char *phase) {
  if(!memcmp(expected,actual,s->bytes))return TRUE;
  unsigned shown=0;
  for(size_t i=0;i<N && shown<8;i++)if(memcmp(expected+i*s->sample_size,actual+i*s->sample_size,s->sample_size)) {
    uint32_t src=0,want=0,got=0;memcpy(&src,before->raw[role]+i*s->sample_size,s->sample_size);
    memcpy(&want,expected+i*s->sample_size,s->sample_size);memcpy(&got,actual+i*s->sample_size,s->sample_size);
    fprintf(stderr,"ORACLE %s component=%u role=%u index=%zu mask=%.9g settings=[%.17g %.17g %.17g %.17g %.17g] source_raw=%08x expected_raw=%08x actual_raw=%08x source_phys=%La expected_phys=%La actual_phys=%La\n",
      phase,s->component,role,i,(double)before->mask[i],settings.low_input,settings.high_input,settings.gamma,
      settings.low_output,settings.high_output,src,want,got,
      decode_physical(s,role,before->raw[role],i),decode_physical(s,role,expected,i),decode_physical(s,role,actual,i));
    shown++;
  }
  return FALSE;
}

static void verify_roundtrip(GlimsEngine *engine,Scene *s,const Snapshot *expected,const char *work,unsigned serial) {
  char *path=g_strdup_printf("%s/lab-levels-%u-%u.xcf",work,s->component,serial),*error=NULL;
  GlimsImageID reopened=0;
  GlimsStatus status=api->image_save(engine,s->id,path,&error);
  CHECK(status==GLIMS_STATUS_OK,"save leveled physical Lab XCF"); api->free_string(error); error=NULL;
  if (status!=GLIMS_STATUS_OK) goto done;
  status=api->image_open(engine,path,&reopened,&error);
  CHECK(status==GLIMS_STATUS_OK && reopened,"reopen leveled physical Lab XCF"); api->free_string(error); error=NULL;
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
      snapshot_free(actual);
    }
  }
done:
  if (reopened) CHECK(api->image_close(engine,reopened)==GLIMS_STATUS_OK,"close owned reopened XCF");
  g_free(path);
}

static void direct_success(GlimsEngine *engine,Scene *s,unsigned role,GlimsLevelsChannel c,
                           gboolean expect_changed,gboolean xcf,const char *work,unsigned serial,const char *label) {
  if (!select_role(engine,s,role)) return;
  Snapshot *before=capture(engine,s),*after=NULL,*undone=NULL,*redone=NULL;
  guint8 *expected=g_malloc(s->bytes);
  if (!before) goto done;
  GlimsLabLevelsSettings set=level_settings(s,role,c,0,0); char *error=NULL;
  GlimsStatus status=api->image_levels_lab(engine,s->id,&set,&error);
  if (status!=GLIMS_STATUS_OK) fprintf(stderr,"direct status=%d: %s\n",status,error?error:"");
  CHECK(status==GLIMS_STATUS_OK,label); api->free_string(error);
  after=capture(engine,s); if (!after) goto done;
  levels_oracle(s,before,role,c,0,0,expected);
  CHECK(oracle_matches(s,before,role,c,expected,after->raw[role],"direct"),"target raw bytes match independent analytic Lab Levels oracle");
  if(s->sample_size==4 && before->mask[7]==1 && c.low_input==0 && c.high_input==1) {
    float actual;memcpy(&actual,after->raw[role]+7*sizeof(float),sizeof actual);
    if(c.gamma==1 && c.low_output==1 && c.high_output==0)
      CHECK(actual==(role==0?75.f:-1.f),"literal physical L25 inversion is75 and chroma0 inversion is-1");
    if(role==0 && c.gamma==2 && c.low_output==0 && c.high_output==1)
      CHECK(actual==50.f,"literal physical L25 gamma2 is50 at full mask coverage");
  }
  {
    gboolean other=TRUE;
    for (unsigned a=0;a<AXES;a++) if (a!=role && memcmp(before->raw[a],after->raw[a],s->bytes)) other=FALSE;
    CHECK(other && metadata_equal(before,after),"levels preserve other axes, selection, metadata, identities and file state");
  }
  CHECK((memcmp(before->raw[role],expected,s->bytes)!=0)==expect_changed,"oracle confirms meaningful changed/no-op fixture precondition");
  if (!expect_changed) { CHECK(source_equal(s,before,after),"identity direct levels preserve exact pixels, dirty state and both history stacks"); goto done; }
  CHECK(after->undo==before->undo+1 && after->redo==0 && after->dirty,"one accepted direct levels adds exactly one Undo step");
  CHECK(api->image_undo(engine,s->id)==GLIMS_STATUS_OK,"public Undo succeeds after direct levels");
  undone=capture(engine,s);
  if (undone) CHECK(pixels_equal(s,before,undone) && metadata_equal(before,undone) &&
      undone->undo==before->undo && undone->redo==1 && undone->dirty==before->dirty,
      "Undo restores every raw source byte and source metadata in one step");
  CHECK(api->image_redo(engine,s->id)==GLIMS_STATUS_OK,"public Redo succeeds after direct levels");
  redone=capture(engine,s);
  if (redone) CHECK(pixels_equal(s,after,redone) && metadata_equal(after,redone) &&
      redone->undo==after->undo && redone->redo==0 && redone->dirty,
      "Redo restores every committed physical sample in one step");
  if (xcf && work && redone) verify_roundtrip(engine,s,redone,work,serial);
done:
  g_free(expected); snapshot_free(before); snapshot_free(after); snapshot_free(undone); snapshot_free(redone);
}

static void refusal_direct(GlimsEngine *engine,Scene *s,const GlimsLabLevelsSettings *set,GlimsStatus expected,const char *label) {
  Snapshot *before=capture(engine,s),*after=NULL; if (!before) return;
  char *error=NULL; GlimsStatus status=api->image_levels_lab(engine,s->id,set,&error);
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

static void direct_invalid(GlimsEngine *engine,Scene *s) {
  select_role(engine,s,0);
  GlimsLevelsChannel id=identity_channel(), inv=id; inv.low_output=1; inv.high_output=0;
  GlimsLabLevelsSettings good=level_settings(s,0,inv,0,0), bad;
  refusal_direct(engine,s,NULL,GLIMS_STATUS_INVALID_ARGUMENT,"NULL settings refuse atomically");
  bad=good; bad.struct_size=sizeof bad-1;
  refusal_direct(engine,s,&bad,GLIMS_STATUS_INVALID_ARGUMENT,"short settings refuse atomically");
  bad=good; bad.axis=0; refusal_direct(engine,s,&bad,GLIMS_STATUS_INVALID_ARGUMENT,"zero explicit axis refuses");
  bad=good; bad.axis=-1; refusal_direct(engine,s,&bad,GLIMS_STATUS_FAILED,"unknown explicit axis refuses");
  bad=good; bad.uuid[0]^=1; refusal_direct(engine,s,&bad,GLIMS_STATUS_FAILED,"wrong captured UUID refuses");
  bad=good; bad.role=1; refusal_direct(engine,s,&bad,GLIMS_STATUS_FAILED,"valid but mismatched role refuses");
  bad=good; bad.role=99; refusal_direct(engine,s,&bad,GLIMS_STATUS_INVALID_ARGUMENT,"unknown role refuses");
  bad=good; bad.value.gamma=0.05; refusal_direct(engine,s,&bad,GLIMS_STATUS_INVALID_ARGUMENT,"invalid gamma refuses");
  bad=good; bad.clamp_input=2; refusal_direct(engine,s,&bad,GLIMS_STATUS_INVALID_ARGUMENT,"invalid clamp flag refuses");
  SelectControl control={s,0,FALSE};
  CHECK(glims_engine_call(engine,control_selection,&control)==GLIMS_STATUS_OK,"fixture installs no selected axis");
  refusal_direct(engine,s,&good,GLIMS_STATUS_FAILED,"no selection refuses instead of choosing an axis");
  control.count=2; CHECK(glims_engine_call(engine,control_selection,&control)==GLIMS_STATUS_OK,"fixture installs two selected axes");
  refusal_direct(engine,s,&good,GLIMS_STATUS_FAILED,"multiple selected axes refuse");
  control.count=1; control.lock=TRUE; CHECK(glims_engine_call(engine,control_selection,&control)==GLIMS_STATUS_OK,"fixture locks captured axis");
  refusal_direct(engine,s,&good,GLIMS_STATUS_FAILED,"content lock refuses");
  control.lock=FALSE; CHECK(glims_engine_call(engine,control_selection,&control)==GLIMS_STATUS_OK,"restore unlocked target");
  select_role(engine,s,1); refusal_direct(engine,s,&good,GLIMS_STATUS_FAILED,"selected axis changes do not retarget captured fill");
  select_role(engine,s,0);
  Scene *foreign=create_scene(engine,s->component,2,0);
  if (foreign) { bad=level_settings(foreign,0,inv,0,0); refusal_direct(engine,s,&bad,GLIMS_STATUS_FAILED,"other document handle and UUID cannot fill this owner"); close_scene(engine,foreign); }
}

static gboolean levels_capable(const GlimsEngineAPI *table) {
  if (!table || table->struct_size < offsetof(GlimsEngineAPI,image_lab_snapshot_apply_levels) +
      sizeof(table->image_lab_snapshot_apply_levels)) return FALSE;
  return table->image_levels_lab && table->image_lab_snapshot_levels && table->image_lab_snapshot_apply_levels;
}
static void old_prefix_refusal(void) {
  /* Guard-page witness for our consumer gate, not a call to absent old slots. */
  size_t page=(size_t)sysconf(_SC_PAGESIZE), bytes=offsetof(GlimsEngineAPI,image_levels_lab);
  void *memory=mmap(NULL,2*page,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
  if(memory==MAP_FAILED){CHECK(FALSE,"allocate protected old209 prefix");return;}
  if(bytes>page || mprotect((char *)memory+page,page,PROT_NONE)){
    CHECK(FALSE,"protect old209 absent footer");munmap(memory,2*page);return;
  }
  GlimsEngineAPI *old=(GlimsEngineAPI *)((char *)memory+page-bytes);
  memcpy(old,api,bytes);old->struct_size=(uint32_t)bytes;
  CHECK(!levels_capable(old),"consumer refuses protected old209 prefix before reading missing slots");
  munmap(memory,2*page);
}

static uint64_t begin_lab(GlimsEngine *e, Scene *s, unsigned role) {
  GlimsLabSnapshotTarget target={.struct_size=sizeof target,.axis=s->ids[role],.role=role};
  memcpy(target.uuid,s->uuids[role],16); uint64_t token=0; char *error=NULL;
  GlimsStatus status=api->image_lab_snapshot_begin(e,s->id,&target,&token,&error);
  if(status!=GLIMS_STATUS_OK) fprintf(stderr,"begin status %d: %s\n",status,error?error:"");
  CHECK(status==GLIMS_STATUS_OK && token,"begin captured physical Lab preview");
  api->free_string(error); return status==GLIMS_STATUS_OK?token:0;
}
static Snapshot *preview_capture(GlimsEngine *e, Scene *s, GlimsImageID id) {
  GlimsLabAxes axes={.struct_size=sizeof axes}; Scene copy=*s; copy.id=id;
  gboolean ok=api->image_lab_axes(e,id,&axes)==GLIMS_STATUS_OK && axes.count==3;
  for(unsigned i=0;i<3 && ok;i++) {
    ok=axes.axes[i].role==i && !memcmp(axes.axes[i].uuid,s->uuids[i],16) && axes.axes[i].id!=s->ids[i];
    copy.ids[i]=axes.axes[i].id;
  }
  CHECK(ok,"preview retains axis roles and UUIDs with independent native handles");
  return ok?capture(e,&copy):NULL;
}
static void unchanged(GlimsEngine *e, Scene *s, Snapshot *before, const char *label) {
  Snapshot *after=capture(e,s);
  if(after && before) CHECK(source_equal(s,before,after),label);
  snapshot_free(after);
}

static void snapshot_levels_success(GlimsEngine *e,uint32_t component,unsigned role,gboolean identity,const char *work,unsigned serial) {
  Scene *s=create_scene(e,component,1,0); if(!s)return;
  if(!select_role(e,s,role)){close_scene(e,s);return;}
  Snapshot *before=capture(e,s),*preview=NULL,*after=NULL;
  uint64_t token=begin_lab(e,s,role); GlimsImageID copy=0,again=0;
  GlimsLevelsChannel idc=identity_channel(), inv=idc; inv.low_output=1; inv.high_output=0;
  GlimsLevelsChannel gamma=idc; gamma.gamma=2.0; /* L25->50 via levels gamma */
  GlimsLevelsChannel ch = identity ? idc : (role==0?gamma:inv);
  GlimsLabLevelsSettings set=level_settings(s,role,ch,0,0); char *error=NULL;
  if(!before || !token) goto done;
  GlimsStatus status=api->image_lab_snapshot_levels(e,s->id,token,&set,&copy,&error);
  CHECK(status==GLIMS_STATUS_OK && copy>0 && copy!=s->id,"render owned Lab Levels preview copy");
  api->free_string(error);error=NULL;
  if(status!=GLIMS_STATUS_OK || !copy)goto done;
  preview=preview_capture(e,s,copy);
  if(preview){
    guint8 expected[MAX_BYTES];
    if(identity) memcpy(expected,before->raw[role],s->bytes);
    else levels_oracle(s,before,role,ch,0,0,expected);
    CHECK(oracle_matches(s,before,role,ch,expected,preview->raw[role],"snapshot"),"preview matches independent analytic Lab Levels oracle");
    gboolean others=TRUE;
    for(unsigned i=0;i<3;i++) if(i!=role && memcmp(before->raw[i],preview->raw[i],s->bytes)) others=FALSE;
    CHECK(others,"preview leaves every other physical axis exact");
  }
  unchanged(e,s,before,"render leaves source pixels, history and metadata unchanged");
  GlimsLabAxes copy_axes={.struct_size=sizeof copy_axes};
  if(api->image_lab_axes(e,copy,&copy_axes)==GLIMS_STATUS_OK){
    GlimsLabLevelsSettings edit=level_settings(s,role,inv,0,0); edit.axis=copy_axes.axes[role].id; memcpy(edit.uuid,s->uuids[role],16);
    CHECK(api->image_levels_lab(e,copy,&edit,&error)==GLIMS_STATUS_OK,"caller may edit returned copy independently of private cache");
    api->free_string(error);error=NULL;
  } else CHECK(FALSE,"read returned copy axes for mutation witness");
  CHECK(api->image_close(e,copy)==GLIMS_STATUS_OK,"close first returned preview copy");copy=0;
  status=api->image_lab_snapshot_levels(e,s->id,token,&set,&again,&error);
  CHECK(status==GLIMS_STATUS_OK && again>0 && again!=s->id,"render from private cache after caller closes copy");
  api->free_string(error);error=NULL;
  if(status==GLIMS_STATUS_OK && again){
    Snapshot *cached=preview_capture(e,s,again);
    if(cached && preview) CHECK(pixels_equal(s,preview,cached),"cached copy has exact independently verified pixels");
    snapshot_free(cached);
  }

  /* Levels↔Curves cachediscrimination on SHARED token: different settings/operation kinds must not reuse wrong cache. */
  GlimsLabCurvesSettings cset={.struct_size=sizeof cset,.axis=s->ids[role],.role=role};
  memcpy(cset.uuid,s->uuids[role],16);
  for(unsigned i=0;i<256;i++) cset.samples[i]=(double)i/255.; /* curves identity */
  GlimsImageID curves_copy=0;
  status=api->image_lab_snapshot_curves(e,s->id,token,&cset,&curves_copy,&error);
  CHECK(status==GLIMS_STATUS_OK && curves_copy>0,"shared token supports curves render for cache discrimination");
  api->free_string(error);error=NULL;
  if(status==GLIMS_STATUS_OK && curves_copy){
    Snapshot *cprev=preview_capture(e,s,curves_copy);
    if(cprev) CHECK(pixels_equal(s,before,cprev),"curves identity render on shared token differs from original/state as expected and is independent");
    snapshot_free(cprev); CHECK(api->image_close(e,curves_copy)==GLIMS_STATUS_OK,"close curves discrimination copy");
  }
  /* Now render levels again with different settings to ensure levels cache is not confused */
  GlimsLevelsChannel inv2=idc; inv2.low_output=1; inv2.high_output=0;
  GlimsLabLevelsSettings set2=level_settings(s,role,inv2,0,0);
  GlimsImageID levels_copy2=0;
  status=api->image_lab_snapshot_levels(e,s->id,token,&set2,&levels_copy2,&error);
  CHECK(status==GLIMS_STATUS_OK && levels_copy2>0,"shared token renders different levels settings without cache confusion");
  api->free_string(error);error=NULL;
  if(status==GLIMS_STATUS_OK && levels_copy2){
    Snapshot *lprev=preview_capture(e,s,levels_copy2);
    if(lprev && preview) CHECK(!identity || !pixels_equal(s,preview,lprev),"different levels settings produce different preview than identity (cache discriminated)");
    snapshot_free(lprev); CHECK(api->image_close(e,levels_copy2)==GLIMS_STATUS_OK,"close different levels copy");
  }

  status=api->image_lab_snapshot_apply_levels(e,s->id,token,&set,&error);
  CHECK(status==GLIMS_STATUS_OK,"apply captured Lab Levels preview");api->free_string(error);error=NULL;
  after=capture(e,s);
  if(after && preview) CHECK(pixels_equal(s,after,preview),"Apply and preview agree exactly on all native bytes");
  if(after && before){
    CHECK(metadata_equal(before,after),"Apply preserves metadata, selection and file identities");
    if(identity) CHECK(source_equal(s,before,after),"identity Apply consumes preview without changing Undo or dirty state");
    else {
      CHECK(after->undo==before->undo+1 && after->redo==0,"Apply adds exactly one native Undo step");
      CHECK(api->image_undo(e,s->id)==GLIMS_STATUS_OK,"Undo applied Lab levels");
      Snapshot *undone=capture(e,s);
      if(undone) CHECK(pixels_equal(s,before,undone),"Undo restores exact source bytes");
      snapshot_free(undone);
      CHECK(api->image_redo(e,s->id)==GLIMS_STATUS_OK,"Redo applied Lab levels");
      Snapshot *redone=capture(e,s);
      if(redone) CHECK(pixels_equal(s,after,redone),"Redo restores exact applied bytes");
      snapshot_free(redone);
    }
  }
  CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_NOT_FOUND,"successful Apply consumes token");token=0;
  if (work && after && !identity) verify_roundtrip(e,s,after,work,serial);
done:
  if(copy) CHECK(api->image_close(e,copy)==GLIMS_STATUS_OK,"close owned preview on failure");
  if(again) CHECK(api->image_close(e,again)==GLIMS_STATUS_OK,"close cached result");
  if(token) CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_OK,"clean up remaining preview token");
  snapshot_free(before);snapshot_free(preview);snapshot_free(after);close_scene(e,s);
}

typedef struct { Scene *scene; unsigned kind; } Stale;
static GlimsStatus mutate_baseline(GlimsEngine *e,gpointer data){
  Stale *m=data; Scene *s=m->scene; GlimsOpenImage *open=glims_lookup_image(e,s->id);
  if(!open) return GLIMS_STATUS_NOT_FOUND;
  GimpItem *item=gimp_item_get_by_id(e->gimp,s->ids[m->kind==1?1:0]);
  if(m->kind<2){
    guint8 value=201; GimpDrawable *d=GIMP_DRAWABLE(item);
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(W-1,H-1,1,1),0,gimp_drawable_get_format(d),&value,GEGL_AUTO_ROWSTRIDE);
  } else if(m->kind==2){
    float value=.37f; GimpDrawable *d=GIMP_DRAWABLE(gimp_image_get_mask(open->image));
    gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(W-1,H-1,1,1),0,babl_format("Y float"),&value,GEGL_AUTO_ROWSTRIDE);
  } else if(m->kind==3) gimp_object_set_name(GIMP_OBJECT(item),"Changed after preview");
  else gimp_item_set_lock_content(item,TRUE,FALSE);
  return GLIMS_STATUS_OK;
}
static void stale_cases(GlimsEngine *e){
  for(unsigned kind=0;kind<6;kind++){
    Scene *s=create_scene(e,GLIMS_COLOR_COMPONENT_U8,1,0); if(!s) continue;
    select_role(e,s,0); uint64_t token=begin_lab(e,s,0);
    if(!token){ close_scene(e,s); continue; }
    if(kind==5) select_role(e,s,1);
    else { Stale m={s,kind}; CHECK(glims_engine_call(e,mutate_baseline,&m)==GLIMS_STATUS_OK,"inject independent source change after begin"); }
    Snapshot *changed=capture(e,s);
    GlimsLevelsChannel inv=identity_channel(); inv.low_output=1; inv.high_output=0;
    GlimsLabLevelsSettings set=level_settings(s,0,inv,0,0); char *error=NULL;
    CHECK(api->image_lab_snapshot_apply_levels(e,s->id,token,&set,&error)!=GLIMS_STATUS_OK,"stale baseline or locked target refuses Apply");
    api->free_string(error);
    unchanged(e,s,changed,"refused Apply preserves changed source and exact history");
    CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_OK,"failed Apply retains token for cancellation");
    snapshot_free(changed); close_scene(e,s);
  }
}

static void snapshot_invalid(GlimsEngine *e){
  Scene *s=create_scene(e,GLIMS_COLOR_COMPONENT_U8,1,0); if(!s) return;
  select_role(e,s,0); uint64_t token=begin_lab(e,s,0); Snapshot *before=capture(e,s);
  GlimsLevelsChannel inv=identity_channel(); inv.low_output=1; inv.high_output=0;
  if(token) for(unsigned kind=0;kind<6;kind++){
    GlimsLabLevelsSettings set=level_settings(s,0,inv,0,0); char *error=NULL; GlimsImageID copy=123;
    if(kind==0) set.struct_size=4;
    else if(kind==1) set.axis=s->ids[1];
    else if(kind==2) set.role=GLIMS_LAB_AXIS_A;
    else if(kind==3) set.uuid[0]^=1;
    else if(kind==4) set.value.gamma=0.01;
    else set.clamp_output=2;
    CHECK(api->image_lab_snapshot_levels(e,s->id,token,&set,&copy,&error)==GLIMS_STATUS_INVALID_ARGUMENT && copy==0,"malformed or retargeted preview refuses and clears result"); api->free_string(error); error=NULL;
    CHECK(api->image_lab_snapshot_apply_levels(e,s->id,token,&set,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"malformed or retargeted Apply refuses"); api->free_string(error);
    unchanged(e,s,before,"invalid request preserves source bytes, metadata and history");
  }
  if(token) CHECK(api->image_lab_snapshot_end(e,s->id,token)==GLIMS_STATUS_OK,"cancel after invalid requests retains valid token");
  unchanged(e,s,before,"Cancel preserves entire source"); snapshot_free(before); close_scene(e,s);
}

/* Native Undo state is controlled only on the engine thread. Captures are taken
 * AFTER configuration changes, so refusal must not repair/free native history. */
typedef struct { Scene *scene; unsigned mode; gboolean restore; } UndoControl;
static GlimsStatus undo_control(GlimsEngine *engine,gpointer data) {
  UndoControl *c=data;GlimsOpenImage *open=glims_lookup_image(engine,c->scene->id);
  if(!open)return GLIMS_STATUS_NOT_FOUND;
  GimpImage *image=open->image;gboolean ok;
  if(c->mode==0)ok=c->restore?gimp_image_undo_enable(image):gimp_image_undo_disable(image);
  else if(c->mode==1)ok=c->restore?gimp_image_undo_thaw(image):gimp_image_undo_freeze(image);
  else ok=c->restore?gimp_image_undo_group_end(image):
    gimp_image_undo_group_start(image,GIMP_UNDO_GROUP_IMAGE_RESIZE,"Controlled foreign group");
  if(!ok)return GLIMS_STATUS_FAILED;
  if(c->restore)return gimp_image_undo_is_enabled(image) && !gimp_image_get_undo_group_count(image)?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
  return (c->mode==2?gimp_image_get_undo_group_count(image)==1:!gimp_image_undo_is_enabled(image))?GLIMS_STATUS_OK:GLIMS_STATUS_FAILED;
}
static void undo_admission(GlimsEngine *engine) {
  for(unsigned mode=0;mode<3;mode++)for(unsigned snapshot=0;snapshot<2;snapshot++) {
    Scene *s=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT,2,0);if(!s)continue;
    if(!select_role(engine,s,0)){close_scene(engine,s);continue;}
    uint64_t token=snapshot?begin_lab(engine,s,0):0;
    if(snapshot&&!token){close_scene(engine,s);continue;}
    UndoControl control={s,mode,FALSE};
    GlimsStatus configured=glims_engine_call(engine,undo_control,&control);
    CHECK(configured==GLIMS_STATUS_OK,"install disabled/frozen/grouped native Undo precondition");
    if(configured!=GLIMS_STATUS_OK){if(token)api->image_lab_snapshot_end(engine,s->id,token);close_scene(engine,s);continue;}
    Snapshot *before=capture(engine,s);
    GlimsLevelsChannel inv=identity_channel();inv.low_output=1;inv.high_output=0;
    GlimsLabLevelsSettings set=level_settings(s,0,inv,0,0);char *error=NULL;
    GlimsStatus status=snapshot?api->image_lab_snapshot_apply_levels(engine,s->id,token,&set,&error):
      api->image_levels_lab(engine,s->id,&set,&error);
    CHECK(status==GLIMS_STATUS_BUSY,snapshot?"snapshot Apply refuses unavailable/foreign-group Undo":"direct Levels refuses unavailable/foreign-group Undo");
    api->free_string(error);
    unchanged(engine,s,before,"Undo refusal preserves exact pixels, selection, metadata and both history stacks");
    if(token)CHECK(api->image_lab_snapshot_end(engine,s->id,token)==GLIMS_STATUS_OK,"Undo refusal retains snapshot token for explicit cancellation");
    control.restore=TRUE;
    CHECK(glims_engine_call(engine,undo_control,&control)==GLIMS_STATUS_OK,"restore native Undo configuration after probe");
    snapshot_free(before);close_scene(engine,s);
  }
}

/* Schedule Core-only interference from the progress callback. The callback
 * itself never calls the facade (public on_event forbids that reentry). */
typedef struct {
  GlimsEngine *engine;
  UndoControl undo;
  Snapshot *injected_state;
  guint source;
  gint armed, scheduled, configured, injected;
} ProgressUndo;
static gboolean inject_progress_undo(gpointer data) {
  ProgressUndo *c=data;c->source=0;
  GlimsStatus status=undo_control(c->engine,&c->undo);
  g_atomic_int_set(&c->configured,status==GLIMS_STATUS_OK);
  if(status==GLIMS_STATUS_OK) {
    c->injected_state=g_new0(Snapshot,1);c->injected_state->scene=c->undo.scene;
    status=capture_native(c->engine,c->injected_state);
  }
  g_atomic_int_set(&c->injected,status==GLIMS_STATUS_OK?1:-1);
  return G_SOURCE_REMOVE;
}
static void levels_event(void *data,const GlimsEvent *event) {
  ProgressUndo *c=data;
  if(event->kind==GLIMS_EVENT_PROGRESS && event->active && event->value>=1. &&
     g_atomic_int_compare_and_exchange(&c->armed,1,0)) {
    g_atomic_int_set(&c->scheduled,1);
    c->source=g_idle_add_full(G_PRIORITY_HIGH,inject_progress_undo,c,NULL);
  }
}
static GlimsStatus drain_progress_idle(GlimsEngine *engine,gpointer data) {
  (void)engine;(void)data;return GLIMS_STATUS_OK;
}
static void progress_undo_admission(GlimsEngine *engine,ProgressUndo *c) {
  for(unsigned mode=0;mode<3;mode++)for(unsigned snapshot=0;snapshot<2;snapshot++) {
    Scene *scene=create_scene(engine,GLIMS_COLOR_COMPONENT_FLOAT,2,0);if(!scene)continue;
    if(!select_role(engine,scene,0)){close_scene(engine,scene);continue;}
    uint64_t token=snapshot?begin_lab(engine,scene,0):0;
    if(snapshot&&!token){close_scene(engine,scene);continue;}
    c->undo=(UndoControl){scene,mode,FALSE};c->injected_state=NULL;c->source=0;
    g_atomic_int_set(&c->scheduled,0);g_atomic_int_set(&c->configured,0);g_atomic_int_set(&c->injected,0);g_atomic_int_set(&c->armed,1);
    GlimsLevelsChannel inv=identity_channel();inv.low_output=1;inv.high_output=0;
    GlimsLabLevelsSettings set=level_settings(scene,0,inv,0,0);char *error=NULL;
    GlimsStatus status=snapshot?api->image_lab_snapshot_apply_levels(engine,scene->id,token,&set,&error):
      api->image_levels_lab(engine,scene->id,&set,&error);
    g_atomic_int_set(&c->armed,0);
    CHECK(glims_engine_call(engine,drain_progress_idle,NULL)==GLIMS_STATUS_OK,"drain owned progress idle before resetting fixture");
    if(c->source){g_source_remove(c->source);c->source=0;}
    gboolean injected=g_atomic_int_get(&c->injected)==1 && c->injected_state;
    CHECK(g_atomic_int_get(&c->scheduled)==1 && injected,"final staging progress actually changed native Undo state");
    if(injected) {
      CHECK(status==GLIMS_STATUS_BUSY,"prepublication recheck refuses changed Undo state after valid admission");
      unchanged(engine,scene,c->injected_state,"progress-time refusal preserves injected native history and all source bytes");
    }
    if(g_atomic_int_get(&c->configured)) {
      c->undo.restore=TRUE;
      CHECK(glims_engine_call(engine,undo_control,&c->undo)==GLIMS_STATUS_OK,"restore progress-injected Undo configuration");
    }
    api->free_string(error);
    if(token)CHECK(api->image_lab_snapshot_end(engine,scene->id,token)==GLIMS_STATUS_OK,"progress-time refused Apply retains cancellable snapshot");
    snapshot_free(c->injected_state);c->injected_state=NULL;c->undo.scene=NULL;
    close_scene(engine,scene);
  }
}

int main(int argc,char **argv) {
  if(argc<2){fprintf(stderr,"usage: %s WORK\n",argv[0]);return 2;}
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api||api->api_version!=GLIMS_ENGINE_API_VERSION||!levels_capable(api)){
    fprintf(stderr,"matching adapter lacks required Lab Levels slots210-212\n");return 2;
  }
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  ProgressUndo progress={0};
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache,
    .on_event=levels_event,.event_context=&progress};
  GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus started=api->start(&config,&engine,&error);
  g_free(user);g_free(cache);
  if(started!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start status%d: %s\n",started,error?error:"");api->free_string(error);return 2;}
  api->free_string(error);progress.engine=engine;unsigned serial=0;
  const uint32_t components[]={GLIMS_COLOR_COMPONENT_U8,GLIMS_COLOR_COMPONENT_U16,GLIMS_COLOR_COMPONENT_FLOAT};
  GlimsLevelsChannel identity=identity_channel(),invert=identity,gamma=identity;invert.low_output=1;invert.high_output=0;gamma.gamma=2;
  old_prefix_refusal();
  for(unsigned c=0;c<3;c++)for(unsigned role=0;role<3;role++) {
    Scene *s=create_scene(engine,components[c],2,0);
    if(s){direct_success(engine,s,role,identity,FALSE,FALSE,NULL,0,"identity Levels succeeds without mutation");close_scene(engine,s);}
    s=create_scene(engine,components[c],2,0);
    if(s){direct_success(engine,s,role,invert,TRUE,TRUE,argv[1],serial++,"full physical inversion succeeds");close_scene(engine,s);}
    s=create_scene(engine,components[c],1,0);
    if(s){direct_success(engine,s,role,role==0?gamma:invert,TRUE,FALSE,NULL,0,"masked analytic transfer succeeds");close_scene(engine,s);}
    snapshot_levels_success(engine,components[c],role,FALSE,argv[1],serial++);
  }
  for(unsigned c=0;c<3;c++){
    Scene *s=create_scene(engine,components[c],1,0);if(s){direct_invalid(engine,s);close_scene(engine,s);}
    snapshot_levels_success(engine,components[c],0,TRUE,NULL,0);
  }
  stale_cases(engine);snapshot_invalid(engine);undo_admission(engine);progress_undo_admission(engine,&progress);
  api->stop(engine);printf("Lab Levels edit: %u checks, %u failures\n",checks,failures);return failures?1:0;
}

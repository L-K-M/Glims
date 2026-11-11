/* Core-only fixtures. Never free borrowed selected-layer lists or compensate
 * for native Undo/XCF config-setter retention with extra unrefs. */
#include "engine-private.h"
#include "curves-config.h"
#include "core/gimpcurve.h"
#include "core/gimpdata.h"
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpfilter.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#include "operations/operations-types.h"
#include "operations/gimpcurvesconfig.h"
#include "core/gimpcurve-map.h"
#include "operations/gimpoperationpointfilter.h"
#include "operations/gimpoperationsettings.h"
#include "libgimpconfig/gimpconfig.h"
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

#define SIDE 6
#define VALUES (SIDE * SIDE * 4)
int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static const gchar *work_dir;
static int failures;
#define CHECK(c, text) do { gboolean ok_ = (c); printf ("%s %s\n", ok_ ? "ok  " : "FAIL", text); if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, text) do { gboolean need_ = (c); CHECK (need_, text); if (!need_) goto cleanup; } while (0)

typedef struct {
  GlimsEngine *engine;
  GlimsImageID id;
  GimpImage *image;             /* borrowed while id is open */
  GimpLayer *layer;             /* borrowed from image */
} Fixture;

static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }
static GlimsItemID layer_id (Fixture *f) { return gimp_item_get_id (GIMP_ITEM (f->layer)); }

static gboolean
fixture_open (GlimsEngine *engine, Fixture *f)
{
  memset (f, 0, sizeof *f); f->engine = engine;
  GimpImage *image = gimp_create_image (engine->gimp, SIDE, SIDE, GIMP_RGB,
                                        GIMP_PRECISION_FLOAT_LINEAR, FALSE);
  if (!image) return FALSE;
  if (glims_adopt_image (engine, image, &f->id) != GLIMS_STATUS_OK) {
    g_object_unref (image); return FALSE;
  }
  f->image = image;
  f->layer = gimp_layer_new (image, SIDE, SIDE, gimp_image_get_layer_format (image, TRUE),
                             "linear FLOAT target", 1.0, GIMP_LAYER_MODE_NORMAL);
  if (!f->layer) return FALSE;
  if (!gimp_image_add_layer (image, f->layer, NULL, 0, FALSE)) {
    g_object_unref (f->layer); f->layer = NULL; return FALSE;
  }
  gfloat pixels[VALUES];
  for (guint i = 0; i < VALUES; i += 4) {
    pixels[i] = 0.25; pixels[i+1] = 0.5; pixels[i+2] = 0.75; pixels[i+3] = 0.25;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->layer)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                   babl_format ("RGBA float"), pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->layer), 0, 0, SIDE, SIDE);
  gimp_image_clean_all (image);
  return TRUE;
}

static void
fixture_close (Fixture *f)
{
  if (f->id) api->image_close (f->engine, f->id);
  f->id = 0; f->layer = NULL; f->image = NULL;
}

static gboolean
read_pixels (Fixture *f, gboolean effects, gfloat pixels[VALUES])
{
  GeglBuffer *buffer;
  if (effects) {
    gimp_pickable_flush (GIMP_PICKABLE (f->layer));
    buffer = gimp_drawable_get_buffer_with_effects (GIMP_DRAWABLE (f->layer)); /* owned */
  } else {
    buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (f->layer));
  }
  if (!buffer) return FALSE;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 1.0,
                   babl_format ("RGBA float"), pixels, GEGL_AUTO_ROWSTRIDE,
                   GEGL_ABYSS_NONE);
  if (effects) g_object_unref (buffer);
  return TRUE;
}

static gboolean
close_pixels (const gfloat *a, const gfloat *b)
{
  for (guint i = 0; i < VALUES; i++)
    if (!isfinite (b[i]) || fabs ((double) a[i] - (double) b[i]) > 2e-4)
      return FALSE;
  return TRUE;
}

static GlimsCurvesSnapshot empty (void) {
  return (GlimsCurvesSnapshot) { .struct_size = sizeof (GlimsCurvesSnapshot) };
}
static gboolean same_curve (const GlimsCurveState *a, const GlimsCurveState *b) {
  if (a->kind != b->kind || a->identity != b->identity || a->point_count != b->point_count || a->sample_count != b->sample_count) return FALSE;
  for (guint i=0;i<a->point_count;i++)
    if (a->points[i].x != b->points[i].x || a->points[i].y != b->points[i].y || a->points[i].kind != b->points[i].kind) return FALSE;
  return !memcmp(a->samples,b->samples,a->sample_count*sizeof(double));
}
static gboolean same_snapshot (const GlimsCurvesSnapshot *a, const GlimsCurvesSnapshot *b) {
  return a->trc == b->trc && same_curve(&a->value,&b->value) && same_curve(&a->red,&b->red) &&
    same_curve(&a->green,&b->green) && same_curve(&a->blue,&b->blue) && same_curve(&a->alpha,&b->alpha);
}
static GimpOperationPointFilter *point (GeglNode *node) {
  return GIMP_OPERATION_POINT_FILTER(gegl_node_get_gegl_operation(node));
}
static GlimsCurveEdit smooth (uint32_t channel, GlimsCurvePoint *points, uint32_t count) {
  return (GlimsCurveEdit){.struct_size=sizeof(GlimsCurveEdit),.channel=channel,.mode=GLIMS_CURVE_EDIT_SMOOTH_POINTS,.point_count=count,.points=points};
}
static void map (GeglNode *node, const gfloat input[4], gfloat out[4]) {
  GimpCurvesConfig *c=GIMP_CURVES_CONFIG(point(node)->config);
  gfloat in[4]; memcpy(in,input,sizeof in);
  gimp_curve_map_pixels(c->curve[0],c->curve[1],c->curve[2],c->curve[3],c->curve[4],in,out,1);
}
static gboolean close4(const gfloat *a,const gfloat *b) {
  for(guint i=0;i<4;i++) if(!isfinite(a[i])||fabs(a[i]-b[i])>2e-5) return FALSE;
  return TRUE;
}
typedef struct { GlimsCurvesSnapshot value; guint64 tail; } LifetimeSnapshot;
static gboolean empty_owned(const GlimsCurvesSnapshot *s) {
  const GlimsCurveState *states[]={&s->value,&s->red,&s->green,&s->blue,&s->alpha};
  if(s->trc!=GLIMS_COLOR_TRC_UNKNOWN)return FALSE;
  for(guint i=0;i<G_N_ELEMENTS(states);i++) {
    const GlimsCurveState *v=states[i];
    if(v->kind||v->identity||v->point_count||v->points||v->sample_count||v->samples)return FALSE;
  }
  return TRUE;
}
static gboolean graph_matches(const gfloat actual[8],const gfloat expected[4]) {
  for(guint i=0;i<8;i++)if(!isfinite(actual[i])||fabs((double)actual[i]-expected[i%4])>2e-4)return FALSE;
  return TRUE;
}
static gboolean raw_curves_result(const GlimsCurveEdit *edit,uint32_t trc,const gfloat input[4],
                                 const Babl *format,gboolean import_identity,gfloat output[8],char **error) {
  gboolean result=FALSE,changed=FALSE;GeglRectangle rect={0,0,2,1};
  GeglBuffer *buffer=gegl_buffer_new(&rect,format);GeglNode *graph=gegl_node_new();
  GeglNode *source=gegl_node_new_child(graph,"operation","gegl:buffer-source","buffer",buffer,NULL);
  GeglNode *operation=gegl_node_new_child(graph,"operation","gimp:curves",NULL);
  GlimsCurvesSnapshot out=empty();gfloat pixels[8];
  memcpy(pixels,input,4*sizeof(gfloat));memcpy(pixels+4,input,4*sizeof(gfloat));
  if(!buffer||!source||!operation)goto cleanup;
  gegl_buffer_set(buffer,&rect,0,format,pixels,GEGL_AUTO_ROWSTRIDE);gegl_node_link(source,operation);
  if(glims_curves_config_prepare(operation,error)!=GLIMS_STATUS_OK)goto cleanup;
  /* Imported Core identity flags are fixtures; Reset's trailing dirty clears them. */
  if(import_identity)for(guint i=0;i<5;i++)GIMP_CURVES_CONFIG(point(operation)->config)->curve[i]->identity=TRUE;
  if(edit&&glims_curves_config_edit(operation,edit,&out,&changed,error)!=GLIMS_STATUS_OK)goto cleanup;
  api->free_curves_snapshot(&out);
  if(glims_curves_config_set_trc(operation,trc,&out,&changed,error)!=GLIMS_STATUS_OK)goto cleanup;
  gegl_node_blit(operation,1.0,&rect,format,output,GEGL_AUTO_ROWSTRIDE,GEGL_BLIT_DEFAULT);result=TRUE;
cleanup:
  api->free_curves_snapshot(&out);g_clear_object(&graph);g_clear_object(&buffer);return result;
}
static GlimsStatus graph_oracles(GlimsEngine *engine,gpointer unused) {
  (void)engine;(void)unused;char *error=NULL;
  GlimsCurvePoint half[]={{0,0,GLIMS_CURVE_POINT_SMOOTH},{1,.5,GLIMS_CURVE_POINT_SMOOTH}};
  GlimsCurveEdit edit=smooth(GLIMS_CURVE_CHANNEL_VALUE,half,2);
  const Babl *spaces[]={babl_space("sRGB"),babl_space_with_trc(babl_space("sRGB"),babl_trc("linear"))};
  const uint32_t modes[]={GLIMS_COLOR_TRC_LINEAR,GLIMS_COLOR_TRC_NONLINEAR,GLIMS_COLOR_TRC_PERCEPTUAL};
  /* Fixed arithmetic-only literals from curves-derived-oracles.json: encode(decode(.5)/2)
   * and decode(encode(.5)/2), with NONLINEAR following the source profile TRC. */
  const gfloat expected[2][3]={{.3607802138332792,.25,.25},{.25,.25,.11133160089467067}};
  const gfloat input[4]={.5,.5,.5,.25};
  for(guint space=0;space<2;space++) {
    NEED(spaces[space]!=NULL,"Curves TRC fixture has the requested source profile");
    const Babl *format=babl_format_with_space("R'G'B'A float",spaces[space]);
    for(guint mode=0;mode<3;mode++) {
      gfloat actual[8]={0},oracle[4]={expected[space][mode],expected[space][mode],expected[space][mode],.25};
      NEED(raw_curves_result(&edit,modes[mode],input,format,FALSE,actual,&error),"actual two-pixel Curves graph accepts patch and TRC setter");
      CHECK(graph_matches(actual,oracle),"Curves graph obeys source-space LINEAR/NONLINEAR/PERCEPTUAL literal and preserves alpha");
    }
  }
  const gfloat hdr[4]={-.5,.5,1.5,1.25};
  const gfloat hdr_expected[][4]={{-.5,.5,1.5,1.25},{0,.25,.5,1.25},{-.5,.5,1.5,.5}};
  for(guint mapping=0;mapping<3;mapping++) {
    gfloat actual[8]={0};edit.channel=mapping==2?GLIMS_CURVE_CHANNEL_ALPHA:GLIMS_CURVE_CHANNEL_VALUE;
    NEED(raw_curves_result(mapping?&edit:NULL,GLIMS_COLOR_TRC_LINEAR,hdr,babl_format("RGBA float"),TRUE,actual,&error),"HDR Curves graph starts with imported native identity flags");
    CHECK(graph_matches(actual,hdr_expected[mapping]),"HDR graph preserves identity excursions and applies only selected Value or Alpha endpoint saturation");
  }
cleanup:
  clear_error(&error);return GLIMS_STATUS_OK;
}
static GlimsStatus output_boundaries(GlimsEngine *engine,gpointer data) {
  LifetimeSnapshot *retained=data;char *error=NULL;gboolean changed=FALSE;
  GeglNode *node=gegl_node_new_child(NULL,"operation","gimp:curves",NULL);
  GlimsCurvesSnapshot before=empty(),out=empty(),small,witness;
  GObject *native=NULL;GimpCurve *held=NULL;double saved[256],large[4096];gboolean identity=FALSE;
  NEED(glims_curves_config_prepare(node,&error)==GLIMS_STATUS_OK,"boundary fixture prepares native Curves");
  GimpCurvesConfig *c=GIMP_CURVES_CONFIG(point(node)->config);GimpCurve *v=c->curve[GIMP_HISTOGRAM_VALUE];
  g_object_set(c,"channel",GIMP_HISTOGRAM_BLUE,NULL);
  v->points[0].x=-0.0;v->points[0].y=-0.0;v->samples[17]=.37;v->identity=TRUE;
  NEED(glims_curves_config_get(node,&before,&error)==GLIMS_STATUS_OK,"non-Value cursor reads an imported noncanonical Smooth table");
  CHECK(c->channel==GIMP_HISTOGRAM_BLUE&&v->samples[17]==.37&&v->identity,"Get preserves the native access cursor, actual table and HDR bypass");
  GlimsCurvePoint diagonal[]={{0,0,GLIMS_CURVE_POINT_SMOOTH},{1,1,GLIMS_CURVE_POINT_SMOOTH}};
  GlimsCurveEdit edit=smooth(GLIMS_CURVE_CHANNEL_VALUE,diagonal,2);native=g_object_ref(point(node)->config);
  NEED(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_OK,"signed-zero numeric no-op is accepted");
  CHECK(!changed&&point(node)->config==native&&signbit(v->points[0].x)&&signbit(v->points[0].y)&&
        same_snapshot(&before,&out)&&c->channel==GIMP_HISTOGRAM_BLUE,"signed-zero no-op keeps config identity, cursor and noncanonical samples");api->free_curves_snapshot(&out);
  memset(&small,0xA5,sizeof small);small.struct_size=sizeof small-1;memcpy(&witness,&small,sizeof small);
  CHECK(api->filter_curves_get(engine,0,&small,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&
        api->filter_curves_edit(engine,0,&edit,&small,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&
        api->filter_curves_set_trc(engine,0,GLIMS_COLOR_TRC_LINEAR,&small,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
        "all owned facade calls refuse undersized output before session lookup");clear_error(&error);
  api->free_curves_snapshot(&small);CHECK(!memcmp(&small,&witness,sizeof small),"undersized Get/Edit/TRC/Free preserve every caller sentinel byte");
  held=g_object_ref(v);memcpy(saved,held->samples,sizeof saved);identity=held->identity;
  gimp_curve_set_n_samples(held,4096);double *large_storage=held->samples;memcpy(large,held->samples,sizeof large);changed=TRUE;
  CHECK(glims_curves_config_get(node,&out,&error)==GLIMS_STATUS_UNSUPPORTED&&empty_owned(&out),"native 4096-sample Get is a read-only unsupported refusal");clear_error(&error);
  CHECK(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_UNSUPPORTED&&!changed&&empty_owned(&out)&&
        point(node)->config==native&&held->samples==large_storage&&held->n_samples==4096&&!memcmp(held->samples,large,sizeof large)&&
        c->channel==GIMP_HISTOGRAM_BLUE,"native 4096-sample Edit preserves storage, all samples, config and cursor");clear_error(&error);
  gimp_curve_set_n_samples(held,256);memcpy(held->samples,saved,sizeof saved);held->identity=identity;g_clear_object(&held);
  NEED(glims_curves_config_get(node,&retained->value,&error)==GLIMS_STATUS_OK,"extensible owned output survives beyond the native fixture");
  CHECK(retained->value.struct_size==sizeof *retained&&retained->tail==G_GUINT64_CONSTANT(0x123456789abcdef0)&&
        same_snapshot(&before,&retained->value),"successful snapshot preserves size/future tail and every payload");
  v->samples[17]=.81;CHECK(retained->value.value.samples[17]==.37,"owned output has independent sample storage");
cleanup:
  if(held){gimp_curve_set_n_samples(held,256);memcpy(held->samples,saved,sizeof saved);held->identity=identity;g_object_unref(held);}
  clear_error(&error);api->free_curves_snapshot(&before);api->free_curves_snapshot(&out);g_clear_object(&native);g_clear_object(&node);return GLIMS_STATUS_OK;
}
static void host_output_cases(LifetimeSnapshot *retained) {
  char *error=NULL;
  CHECK(retained->value.value.samples&&retained->value.value.point_count==2&&retained->value.value.samples[17]==.37&&
        signbit(retained->value.value.points[0].x)&&retained->value.value.identity&&retained->tail==G_GUINT64_CONSTANT(0x123456789abcdef0),
        "host thread reads independently owned samples and points after engine stop");
  api->free_curves_snapshot(&retained->value);api->free_curves_snapshot(&retained->value);
  CHECK(empty_owned(&retained->value)&&retained->value.struct_size==sizeof *retained&&retained->tail==G_GUINT64_CONSTANT(0x123456789abcdef0),"host-thread Free after stop is repeatable and preserves future tail");
  for(guint slot=0;slot<3;slot++) {
    LifetimeSnapshot stopped;memset(&stopped,0xA5,sizeof stopped);stopped.value.struct_size=sizeof stopped;guint64 tail=stopped.tail;
    GlimsStatus status=slot==0?api->filter_curves_get(NULL,1,&stopped.value,&error):slot==1?
      api->filter_curves_edit(NULL,1,NULL,&stopped.value,&error):api->filter_curves_set_trc(NULL,1,GLIMS_COLOR_TRC_LINEAR,&stopped.value,&error);
    CHECK(status==GLIMS_STATUS_NOT_RUNNING&&empty_owned(&stopped.value)&&stopped.value.struct_size==sizeof stopped&&stopped.tail==tail,
          "nonrunning Get/Edit/TRC clears every owned field while preserving size and future tail");clear_error(&error);api->free_curves_snapshot(&stopped.value);
  }
}
static GlimsStatus core_cases(GlimsEngine *engine,gpointer unused) {
  (void)engine;(void)unused;
  GeglNode *node=gegl_node_new_child(NULL,"operation","gimp:curves",NULL);
  GlimsCurvesSnapshot original=empty(),out=empty(),after=empty();
  char *error=NULL;gboolean changed=FALSE;
  NEED(glims_curves_config_prepare(node,&error)==GLIMS_STATUS_OK,"prepare native Curves");clear_error(&error);
  NEED(glims_curves_config_get(node,&original,&error)==GLIMS_STATUS_OK,"export complete owned snapshot");clear_error(&error);
  CHECK(original.trc==GLIMS_COLOR_TRC_PERCEPTUAL,"product default transfer curve is perceptual");
  CHECK(original.value.sample_count==256&&original.red.sample_count==256&&original.green.sample_count==256&&original.blue.sample_count==256&&original.alpha.sample_count==256,"all five native sample tables exported");
  GObject *native=point(node)->config;
  GlimsCurvePoint invert[]={{0,1,GLIMS_CURVE_POINT_SMOOTH},{1,0,GLIMS_CURVE_POINT_SMOOTH}};
  GlimsCurveEdit edit=smooth(GLIMS_CURVE_CHANNEL_VALUE,invert,2);
  NEED(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_OK&&changed,"immutable Value edit succeeds");clear_error(&error);
  CHECK(point(node)->config!=native,"changed edit replaces native config identity");
  CHECK(same_curve(&original.red,&out.red)&&same_curve(&original.green,&out.green)&&same_curve(&original.blue,&out.blue)&&same_curve(&original.alpha,&out.alpha),"Value edit preserves four other channel payloads");
  const gfloat input[4]={.25,.5,.75,.25},inverted[4]={.75,.5,.25,.25};gfloat pixels[4];map(node,input,pixels);
  CHECK(close4(pixels,inverted),"literal Value inversion changes RGB while preserving alpha");
  api->free_curves_snapshot(&out);native=point(node)->config;changed=TRUE;
  NEED(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_OK&&!changed,"same points are a numeric no-op");clear_error(&error);
  CHECK(point(node)->config==native,"no-op keeps installed config identity");api->free_curves_snapshot(&out);
  GlimsCurvePoint half[]={{0,0,GLIMS_CURVE_POINT_CORNER},{1,.5,GLIMS_CURVE_POINT_CORNER}};
  edit=smooth(GLIMS_CURVE_CHANNEL_RED,half,2);
  NEED(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_OK,"independent Red edit succeeds");clear_error(&error);
  const gfloat combined[4]={.875,.5,.25,.25};map(node,input,pixels);
  CHECK(close4(pixels,combined),"literal Red mapping precedes Value mapping");api->free_curves_snapshot(&out);
  edit=smooth(GLIMS_CURVE_CHANNEL_ALPHA,invert,2);
  NEED(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_OK,"Alpha edit succeeds");clear_error(&error);
  const gfloat alpha[4]={.875,.5,.25,.75};map(node,input,pixels);
  CHECK(close4(pixels,alpha),"literal Alpha mapping remains independent");api->free_curves_snapshot(&out);
  for(guint channel=GLIMS_CURVE_CHANNEL_VALUE;channel<=GLIMS_CURVE_CHANNEL_ALPHA;channel++) {
    edit=(GlimsCurveEdit){.struct_size=sizeof edit,.channel=channel,.mode=GLIMS_CURVE_EDIT_RESET};
    NEED(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_OK,"native channel Reset accepted");clear_error(&error);api->free_curves_snapshot(&out);
  }
  double samples[256]={0};samples[127]=.2;samples[128]=.8;
  edit=(GlimsCurveEdit){.struct_size=sizeof edit,.channel=GLIMS_CURVE_CHANNEL_VALUE,.mode=GLIMS_CURVE_EDIT_FREE_SAMPLES,.sample_count=256,.samples=samples};
  NEED(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_OK,"complete Free table accepted");clear_error(&error);
  const gfloat midpoint[4]={.5,.5,.5,.25};map(node,midpoint,pixels);
  CHECK(close4(pixels,midpoint),"render interpolates Free samples rather than rounding sample getter");
  CHECK(out.value.kind==GLIMS_CURVE_KIND_FREE&&out.value.samples[127]==.2&&out.value.samples[128]==.8,"returned authoritative Free table retains exact values");
  api->free_curves_snapshot(&out);
  NEED(glims_curves_config_get(node,&after,&error)==GLIMS_STATUS_OK,"capture before invalid edits");clear_error(&error);native=point(node)->config;
  for(guint invalid=0;invalid<8;invalid++) {
    edit=smooth(GLIMS_CURVE_CHANNEL_RED,half,2);GlimsCurvePoint bad[]={{0,0,GLIMS_CURVE_POINT_SMOOTH},{1,1,GLIMS_CURVE_POINT_SMOOTH}};
    if(invalid==0)edit.channel=0;
    if(invalid==1)edit.mode=999;
    if(invalid==2){bad[0].x=NAN;edit.points=bad;}
    if(invalid==3){bad[1].y=1.1;edit.points=bad;}
    if(invalid==4){bad[0].kind=999;edit.points=bad;}
    if(invalid==5){bad[0].x=1;bad[1].x=0;edit.points=bad;}
    if(invalid==6)edit.point_count=GLIMS_CURVE_MAX_POINTS+1;
    if(invalid==7)edit.sample_count=1;
    changed=TRUE;
    CHECK(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&!changed&&out.value.samples==NULL&&point(node)->config==native,"invalid complete patch refuses without native mutation or owned output");clear_error(&error);api->free_curves_snapshot(&out);
  }
  NEED(glims_curves_config_get(node,&out,&error)==GLIMS_STATUS_OK,"read after refusals");clear_error(&error);
  CHECK(same_snapshot(&after,&out),"all invalid edits preserve every native channel");api->free_curves_snapshot(&out);api->free_curves_snapshot(&after);
  /* Import a deliberately noncanonical Smooth table and native HDR bypass.
   * Private duplication must not recalculate it while editing another channel. */
  GimpCurvesConfig *c=GIMP_CURVES_CONFIG(point(node)->config);
  GimpCurve *green=c->curve[GIMP_HISTOGRAM_GREEN];
  for(guint i=0;i<256;i++)green->samples[i]=.37;
  green->identity=TRUE;
  NEED(glims_curves_config_get(node,&after,&error)==GLIMS_STATUS_OK,"noncanonical imported sample snapshot readable");clear_error(&error);
  g_object_set(c,"channel",GIMP_HISTOGRAM_BLUE,NULL);
  native=g_object_ref(point(node)->config);edit=smooth(GLIMS_CURVE_CHANNEL_RED,half,2);
  NEED(glims_curves_config_edit(node,&edit,&out,&changed,&error)==GLIMS_STATUS_OK&&changed,"other-channel edit admits noncanonical native samples");clear_error(&error);
  CHECK(same_curve(&after.green,&out.green),"private clone preserves noncanonical unrelated samples and identity flag exactly");
  CHECK(GIMP_CURVES_CONFIG(native)->curve[GIMP_HISTOGRAM_GREEN]->samples[17]==.37&&GIMP_CURVES_CONFIG(native)->curve[GIMP_HISTOGRAM_GREEN]->identity,"source config stays immutable after edit");
  api->free_curves_snapshot(&out);api->free_curves_snapshot(&after);g_object_unref(native);
  for(guint trc=GLIMS_COLOR_TRC_LINEAR;trc<=GLIMS_COLOR_TRC_PERCEPTUAL;trc++) {
    NEED(glims_curves_config_set_trc(node,trc,&out,&changed,&error)==GLIMS_STATUS_OK,"owned global TRC change accepted");clear_error(&error);
    CHECK(out.trc==trc,"TRC write returns authoritative all-channel snapshot");api->free_curves_snapshot(&out);
  }
  /* Existing config/op mismatch is a read-only refusal, never repair on Get. */
  GimpTRCType old=point(node)->trc;
  point(node)->trc=old==GIMP_TRC_LINEAR?GIMP_TRC_NON_LINEAR:GIMP_TRC_LINEAR;
  native=point(node)->config;
  CHECK(glims_curves_config_get(node,&out,&error)==GLIMS_STATUS_UNSUPPORTED&&point(node)->config==native,"legacy TRC mismatch refuses read without replacing config");clear_error(&error);point(node)->trc=old;
cleanup:
  clear_error(&error);api->free_curves_snapshot(&original);api->free_curves_snapshot(&out);api->free_curves_snapshot(&after);g_clear_object(&node);return GLIMS_STATUS_OK;
}
static GlimsStatus image_cases(GlimsEngine *engine,gpointer unused) {
  (void)unused; Fixture f={0};GlimsFilterID filter=0;char *error=NULL;
  GlimsCurvesSnapshot a=empty(),b=empty(),c=empty(),out=empty();
  gfloat raw[VALUES],preview[VALUES],actual[VALUES];GlimsUndoInfo before={0},after={0};
  GlimsEffectInfo rows[4]={{0}};int32_t count=0;GlimsImageID reopened=0;
  NEED(fixture_open(engine,&f)&&read_pixels(&f,FALSE,raw),"real FLOAT image fixture starts");
  NEED(api->image_undo_info(engine,f.id,&before)==GLIMS_STATUS_OK,"capture initial native Undo");
  NEED(api->filter_begin(engine,f.id,layer_id(&f),"gimp:curves",&filter,&error)==GLIMS_STATUS_OK,"public preview starts");clear_error(&error);
  NEED(api->filter_curves_set_trc(engine,filter,GLIMS_COLOR_TRC_LINEAR,&out,&error)==GLIMS_STATUS_OK,"public global TRC marshals");clear_error(&error);api->free_curves_snapshot(&out);
  GlimsCurvePoint invert[]={{0,1,GLIMS_CURVE_POINT_CORNER},{1,0,GLIMS_CURVE_POINT_CORNER}};
  GlimsCurveEdit edit=smooth(GLIMS_CURVE_CHANNEL_VALUE,invert,2);
  NEED(api->filter_curves_edit(engine,filter,&edit,&a,&error)==GLIMS_STATUS_OK&&read_pixels(&f,TRUE,preview),"public edit returns authoritative snapshot and real preview");clear_error(&error);
  CHECK(fabs(preview[0]-.75)<2e-4&&fabs(preview[1]-.5)<2e-4&&fabs(preview[2]-.25)<2e-4&&fabs(preview[3]-.25)<2e-4,"real LINEAR preview matches literal inversion");
  CHECK(read_pixels(&f,FALSE,actual)&&!memcmp(raw,actual,sizeof raw),"live preview preserves stored source floats");
  NEED(api->filter_commit(engine,filter,&error)==GLIMS_STATUS_OK,"Apply commits real Curves effect");filter=0;clear_error(&error);
  CHECK(api->image_undo_info(engine,f.id,&after)==GLIMS_STATUS_OK&&after.undo_count==before.undo_count+1,"Apply contributes exactly one native Undo");
  NEED(api->drawable_effects(engine,f.id,layer_id(&f),rows,4,&count)==GLIMS_STATUS_OK&&count==1,"committed Curves effect remains editable");
  GlimsEffectID effect=rows[0].id;
  NEED(api->filter_edit_begin(engine,f.id,layer_id(&f),effect,&filter,&error)==GLIMS_STATUS_OK,"captured existing effect opens");clear_error(&error);
  NEED(api->filter_curves_get(engine,filter,&out,&error)==GLIMS_STATUS_OK&&same_snapshot(&a,&out),"existing effect starts with exact all-channel settings");clear_error(&error);api->free_curves_snapshot(&out);
  GlimsCurvePoint half[]={{0,0,GLIMS_CURVE_POINT_SMOOTH},{1,.5,GLIMS_CURVE_POINT_SMOOTH}};edit=smooth(GLIMS_CURVE_CHANNEL_RED,half,2);
  NEED(api->filter_curves_edit(engine,filter,&edit,&b,&error)==GLIMS_STATUS_OK,"B preview is isolated");clear_error(&error);
  GlimsCurvePoint constant[]={{0,.3,GLIMS_CURVE_POINT_CORNER},{1,.3,GLIMS_CURVE_POINT_CORNER}};edit=smooth(GLIMS_CURVE_CHANNEL_BLUE,constant,2);
  NEED(api->filter_curves_edit(engine,filter,&edit,&c,&error)==GLIMS_STATUS_OK,"C preview builds on B privately");clear_error(&error);
  CHECK(same_curve(&a.red,&a.green)&&a.red.samples[255]==1&&b.red.samples[255]==.5&&c.blue.samples[0]==.3,"owned A/B snapshots stay unchanged after later writes");
  NEED(api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"Cancel aborts existing preview");filter=0;
  NEED(api->filter_edit_begin(engine,f.id,layer_id(&f),effect,&filter,&error)==GLIMS_STATUS_OK,"effect reopens after Cancel");clear_error(&error);
  NEED(api->filter_curves_get(engine,filter,&out,&error)==GLIMS_STATUS_OK,"read after Cancel");clear_error(&error);
  CHECK(same_snapshot(&a,&out),"Cancel restores exact accepted A");api->free_curves_snapshot(&out);
  edit=smooth(GLIMS_CURVE_CHANNEL_RED,half,2);
  NEED(api->filter_curves_edit(engine,filter,&edit,&out,&error)==GLIMS_STATUS_OK,"second edit accepts B");clear_error(&error);api->free_curves_snapshot(&out);
  NEED(api->filter_commit(engine,filter,&error)==GLIMS_STATUS_OK,"existing Apply commits B");filter=0;clear_error(&error);
  CHECK(api->image_undo(engine,f.id)==GLIMS_STATUS_OK,"existing Apply undoes once");
  NEED(api->filter_edit_begin(engine,f.id,layer_id(&f),effect,&filter,&error)==GLIMS_STATUS_OK,"Undo result reopens");clear_error(&error);
  NEED(api->filter_curves_get(engine,filter,&out,&error)==GLIMS_STATUS_OK,"read Undo result");clear_error(&error);
  CHECK(same_snapshot(&a,&out),"native Undo restores exact A payload and identity flags");api->free_curves_snapshot(&out);
  NEED(api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"Undo inspection aborts");filter=0;
  CHECK(api->image_redo(engine,f.id)==GLIMS_STATUS_OK,"existing edit redoes once");
  NEED(api->filter_edit_begin(engine,f.id,layer_id(&f),effect,&filter,&error)==GLIMS_STATUS_OK,"Redo result reopens");clear_error(&error);
  NEED(api->filter_curves_get(engine,filter,&out,&error)==GLIMS_STATUS_OK,"read Redo result");clear_error(&error);
  CHECK(same_snapshot(&b,&out),"native Redo restores exact B payload and identity flags");api->free_curves_snapshot(&out);
  NEED(api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"Redo inspection aborts");filter=0;
  /* Native XCF deserialization intentionally clears identity flags; check real
   * normalized-pixel fidelity, without claiming raw HDR bypass persistence. */
  gchar *path=g_build_filename(work_dir,"curves-normalized.xcf",NULL);
  gboolean saved=read_pixels(&f,TRUE,preview)&&api->image_save(engine,f.id,path,&error)==GLIMS_STATUS_OK&&api->image_open(engine,path,&reopened,&error)==GLIMS_STATUS_OK;
  g_free(path);NEED(saved,"real Curves XCF saves and reopens");clear_error(&error);
  GlimsLayerInfo layers[2]={{0}};GlimsOpenImage *open=glims_lookup_image(engine,reopened);
  NEED(api->image_layers(engine,reopened,layers,2,&count)==GLIMS_STATUS_OK&&count==1,"reopened XCF retains source layer");
  Fixture loaded={.engine=engine,.id=reopened,.image=open->image,.layer=GIMP_LAYER(glims_lookup_drawable(open,layers[0].id))};
  CHECK(read_pixels(&loaded,TRUE,actual)&&close_pixels(preview,actual),"XCF round trip preserves actual normalized rendered pixels");
  NEED(api->filter_begin(engine,f.id,layer_id(&f),"gimp:curves",&filter,&error)==GLIMS_STATUS_OK,"guard preview starts");clear_error(&error);
  engine->busy++;
  CHECK(api->filter_curves_get(engine,filter,&out,&error)==GLIMS_STATUS_BUSY&&out.value.samples==NULL,"busy Get clears owned output");clear_error(&error);
  CHECK(api->filter_curves_edit(engine,filter,&edit,&out,&error)==GLIMS_STATUS_BUSY&&out.value.samples==NULL,"busy Edit refuses without ownership transfer");clear_error(&error);engine->busy--;
  GlimsFilter *session=g_hash_table_lookup(engine->filters,GINT_TO_POINTER(filter));
  GimpOperationPointFilter *p=point(session->operation);GimpTRCType old=p->trc;p->trc=GIMP_TRC_LINEAR;
  if(old==GIMP_TRC_LINEAR)p->trc=GIMP_TRC_NON_LINEAR;
  CHECK(api->filter_commit(engine,filter,&error)==GLIMS_STATUS_UNSUPPORTED,"new effect Commit refuses incoherent TRC");clear_error(&error);p->trc=old;
cleanup:
  if(filter)api->filter_abort(engine,filter);
  if(reopened)api->image_close(engine,reopened);
  clear_error(&error);api->free_curves_snapshot(&a);api->free_curves_snapshot(&b);api->free_curves_snapshot(&c);api->free_curves_snapshot(&out);fixture_close(&f);return GLIMS_STATUS_OK;
}
static GlimsStatus whole_value_cases(GlimsEngine *engine,gpointer unused) {
  (void)unused; char *error=NULL; gboolean changed=FALSE;
  GeglNode *node=gegl_node_new_child(NULL,"operation","gimp:curves",NULL);
  GlimsCurvesSnapshot desired=empty(),out=empty(),original=empty();
  GObject *held=NULL; Fixture f={0}; GlimsFilterID filter=0;
  NEED(glims_curves_config_prepare(node,&error)==GLIMS_STATUS_OK,"whole-value fixture prepares");
  NEED(glims_curves_config_get(node,&desired,&error)==GLIMS_STATUS_OK&&
       glims_curves_config_get(node,&original,&error)==GLIMS_STATUS_OK,"whole-value inputs own complete snapshots");
  GlimsCurveState *states[]={&desired.value,&desired.red,&desired.green,&desired.blue,&desired.alpha};
  for(guint c=0;c<5;c++) {
    states[c]->kind=c%2?GLIMS_CURVE_KIND_FREE:GLIMS_CURVE_KIND_SMOOTH;
    states[c]->identity=c%2;
    states[c]->points[0].kind=GLIMS_CURVE_POINT_CORNER;
    states[c]->points[1].y=.2+c*.1;
    for(guint s=0;s<256;s++)states[c]->samples[s]=(s+c)/(259.0);
  }
  g_free(desired.green.points);desired.green.points=NULL;desired.green.point_count=0;
  held=g_object_ref(point(node)->config);
  for(guint trc=GLIMS_COLOR_TRC_LINEAR;trc<=GLIMS_COLOR_TRC_PERCEPTUAL;trc++) {
    desired.trc=trc;
    NEED(glims_curves_config_set(node,&desired,&changed,&error)==GLIMS_STATUS_OK&&changed,"whole-value set accepts all five channels and each TRC");
    NEED(glims_curves_config_get(node,&out,&error)==GLIMS_STATUS_OK,"whole-value read succeeds");
    CHECK(same_snapshot(&desired,&out),"whole-value set preserves kinds, HDR identity, inactive points and noncanonical samples exactly");
    api->free_curves_snapshot(&out);
    GObject *same=point(node)->config;changed=TRUE;
    CHECK(glims_curves_config_set(node,&desired,&changed,&error)==GLIMS_STATUS_OK&&!changed&&point(node)->config==same,"equal whole-value set keeps config identity");
  }
  CHECK(GIMP_CURVES_CONFIG(held)->curve[0]->points[1].y==original.value.points[1].y&&
        !memcmp(GIMP_CURVES_CONFIG(held)->curve[0]->samples,original.value.samples,256*sizeof(double)),"whole-value installation never mutates held source config");
  GObject *accepted=point(node)->config;
  for(guint bad=0;bad<14;bad++) {
    GlimsCurvesSnapshot invalid=desired;
    GlimsCurvePoint bad_points[]={{0,0,GLIMS_CURVE_POINT_SMOOTH},{1,1,GLIMS_CURVE_POINT_SMOOTH}};
    double bad_samples[256];memcpy(bad_samples,desired.alpha.samples,sizeof bad_samples);
    if(bad==0)invalid.trc=999;
    if(bad==1)invalid.alpha.kind=999;
    if(bad==2)invalid.alpha.identity=2;
    if(bad==3)invalid.alpha.point_count=GLIMS_CURVE_MAX_POINTS+1;
    if(bad==4)invalid.alpha.points=NULL;
    if(bad==5)invalid.alpha.sample_count=255;
    if(bad==6)invalid.alpha.samples=NULL;
    if(bad==7){bad_points[0].x=NAN;invalid.alpha.points=bad_points;}
    if(bad==8){bad_points[1].y=1.1;invalid.alpha.points=bad_points;}
    if(bad==9){bad_points[0].kind=999;invalid.alpha.points=bad_points;}
    if(bad==10){bad_points[0].x=1;bad_points[1].x=0;invalid.alpha.points=bad_points;}
    if(bad==11){bad_samples[255]=NAN;invalid.alpha.samples=bad_samples;}
    if(bad==12)invalid.alpha.point_count=0;
    if(bad==13)invalid.value.sample_count=257;
    changed=TRUE;
    CHECK(glims_curves_config_set(node,&invalid,&changed,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&!changed&&point(node)->config==accepted,"invalid last-channel whole value refuses atomically before installation");clear_error(&error);
  }
  NEED(glims_curves_config_get(node,&out,&error)==GLIMS_STATUS_OK,"read after invalid whole values");
  CHECK(same_snapshot(&desired,&out),"all invalid whole values preserve all five accepted channels");api->free_curves_snapshot(&out);
  /* Deliberately contradictory Smooth points/table plus bypassed garbage in
   * the other channels: literal HDR arithmetic detects any reconstruction. */
  desired.trc=GLIMS_COLOR_TRC_LINEAR;
  for(guint c=0;c<5;c++) {
    states[c]->identity=c!=0;
    for(guint s=0;s<256;s++)states[c]->samples[s]=c?.37:(double)s/510;
  }
  NEED(glims_curves_config_set(node,&desired,&changed,&error)==GLIMS_STATUS_OK,"HDR whole value installs");
  const gfloat input[]={-.5,.5,1.5,1.25},expected[]={0,.25,.5,1.25};gfloat actual[4]={0};
  map(node,input,actual);CHECK(close4(actual,expected),"whole-value rendering obeys literal sample interpolation and independent HDR bypass");
  double saved=desired.value.samples[128];desired.value.samples[128]=.99;
  map(node,input,actual);CHECK(close4(actual,expected),"caller mutation after return cannot alter installed curves");desired.value.samples[128]=saved;

  NEED(fixture_open(engine,&f),"public whole-value image opens");
  GlimsUndoInfo before={0},after={0};gfloat raw[VALUES],preview[VALUES],pixels[VALUES];
  NEED(api->image_undo_info(engine,f.id,&before)==GLIMS_STATUS_OK&&read_pixels(&f,FALSE,raw),"whole-value captures source and Undo");
  NEED(api->filter_begin(engine,f.id,layer_id(&f),"gimp:curves",&filter,&error)==GLIMS_STATUS_OK,"whole-value preview begins");
  LifetimeSnapshot future={.value=desired,.tail=G_GUINT64_CONSTANT(0xfedcba9876543210)};
  future.value.struct_size=sizeof future;
  unsigned char unaligned[sizeof future+1];memcpy(unaligned+1,&future,sizeof future);
  NEED(api->filter_curves_set(engine,filter,(const GlimsCurvesSnapshot *)(unaligned+1),&error)==GLIMS_STATUS_OK,"public whole-value setter accepts unaligned prefix and future tail");
  CHECK(!memcmp(unaligned+1,&future,sizeof future),"borrowed future input remains byte identical");
  NEED(api->filter_curves_get(engine,filter,&out,&error)==GLIMS_STATUS_OK,"whole-value public read");
  CHECK(same_snapshot(&desired,&out),"public whole-value call preserves complete borrowed state");api->free_curves_snapshot(&out);
  CHECK(read_pixels(&f,TRUE,preview)&&fabs(preview[0]-.125)<2e-4&&fabs(preview[1]-.25)<2e-4&&fabs(preview[2]-.375)<2e-4&&fabs(preview[3]-.25)<2e-4,"real image graph renders sample-table half RGB and bypassed alpha");
  CHECK(read_pixels(&f,FALSE,pixels)&&!memcmp(raw,pixels,sizeof raw),"whole-value live preview keeps source pixels immutable");
  CHECK(api->image_undo_info(engine,f.id,&after)==GLIMS_STATUS_OK&&before.undo_count==after.undo_count,"whole-value preview adds no native Undo before Commit");
  GlimsCurvesSnapshot short_input=desired;short_input.struct_size--;
  error=(char *)(uintptr_t)1;
  CHECK(api->filter_curves_set(engine,filter,&short_input,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&!error,"short prefix clears error and refuses");
  CHECK(api->filter_curves_set(engine,filter,NULL,&error)==GLIMS_STATUS_INVALID_ARGUMENT,"missing whole value refuses");clear_error(&error);
  engine->busy++;
  CHECK(api->filter_curves_set(engine,filter,&desired,&error)==GLIMS_STATUS_BUSY,"busy engine refuses whole-value set");clear_error(&error);engine->busy--;
  GlimsFilter *session=g_hash_table_lookup(engine->filters,GINT_TO_POINTER(filter));
  GimpOperationPointFilter *p=point(session->operation);GimpTRCType old=p->trc;
  p->trc=old==GIMP_TRC_LINEAR?GIMP_TRC_NON_LINEAR:GIMP_TRC_LINEAR;
  CHECK(api->filter_curves_set(engine,filter,&desired,&error)==GLIMS_STATUS_UNSUPPORTED,"incoherent native TRC refuses whole-value replacement");clear_error(&error);p->trc=old;
  NEED(api->filter_commit(engine,filter,&error)==GLIMS_STATUS_OK,"whole-value preview commits");filter=0;
  CHECK(api->image_undo_info(engine,f.id,&after)==GLIMS_STATUS_OK&&after.undo_count==before.undo_count+1,"whole-value Commit contributes one Undo");
  CHECK(api->image_undo(engine,f.id)==GLIMS_STATUS_OK&&read_pixels(&f,TRUE,pixels)&&close_pixels(raw,pixels),"whole-value Undo restores original image pixels");
  CHECK(api->image_redo(engine,f.id)==GLIMS_STATUS_OK&&read_pixels(&f,TRUE,pixels)&&close_pixels(preview,pixels),"whole-value Redo restores exact rendered pixels");
  GlimsEffectInfo effects[2]={{0}};int32_t count=0;
  NEED(api->drawable_effects(engine,f.id,layer_id(&f),effects,2,&count)==GLIMS_STATUS_OK&&count==1,"whole-value effect survives Redo");
  NEED(api->filter_edit_begin(engine,f.id,layer_id(&f),effects[0].id,&filter,&error)==GLIMS_STATUS_OK,"whole-value effect reopens");
  NEED(api->filter_curves_get(engine,filter,&out,&error)==GLIMS_STATUS_OK,"whole-value reopens with payload");
  CHECK(same_snapshot(&desired,&out),"Undo/Redo retains every whole-value field, including inactive state");api->free_curves_snapshot(&out);
  NEED(api->filter_curves_set(engine,filter,&original,&error)==GLIMS_STATUS_OK,"whole-value existing edit accepts replacement");
  NEED(api->filter_abort(engine,filter)==GLIMS_STATUS_OK,"whole-value existing edit Cancel");filter=0;
  NEED(api->filter_edit_begin(engine,f.id,layer_id(&f),effects[0].id,&filter,&error)==GLIMS_STATUS_OK&&api->filter_curves_get(engine,filter,&out,&error)==GLIMS_STATUS_OK,"whole-value Cancel result reopens");
  CHECK(same_snapshot(&desired,&out),"whole-value Cancel restores exact accepted payload");
cleanup:
  if(filter)api->filter_abort(engine,filter);
  clear_error(&error);api->free_curves_snapshot(&desired);api->free_curves_snapshot(&out);api->free_curves_snapshot(&original);
  g_clear_object(&held);g_clear_object(&node);fixture_close(&f);return GLIMS_STATUS_OK;
}
static GlimsStatus begin_guards(GlimsEngine *engine,gpointer unused) {
  (void)unused;
  for(guint mode=0;mode<3;mode++) {
    Fixture f={0};GlimsFilterID filter=0;char *error=NULL;
    if(!fixture_open(engine,&f)){CHECK(FALSE,"history guard fixture opens");fixture_close(&f);continue;}
    gboolean blocked=mode==0?gimp_image_undo_disable(f.image):mode==1?gimp_image_undo_freeze(f.image):gimp_image_undo_group_start(f.image,GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE,"Curves guard");
    CHECK(blocked,"native Undo guard enters disabled/frozen/grouped state");
    guint sessions=g_hash_table_size(engine->filters);
    GlimsStatus status=api->filter_begin(engine,f.id,layer_id(&f),"gimp:curves",&filter,&error);
    CHECK(status==GLIMS_STATUS_BUSY&&filter==0&&g_hash_table_size(engine->filters)==sessions,"Curves Begin refuses unavailable Undo before installing preview");
    if(filter)api->filter_abort(engine,filter);
    if(mode==0)gimp_image_undo_enable(f.image);else if(mode==1)gimp_image_undo_thaw(f.image);else gimp_image_undo_group_end(f.image);
    clear_error(&error);filter=0;
    CHECK(api->filter_begin(engine,f.id,layer_id(&f),"gimp:curves",&filter,&error)==GLIMS_STATUS_OK,"available Undo permits a Curves preview");clear_error(&error);
    if(filter) {
      GlimsFilterID nested=0;
      CHECK(api->filter_begin(engine,f.id,layer_id(&f),"gimp:curves",&nested,&error)==GLIMS_STATUS_BUSY&&nested==0,"another live preview refuses a second Curves Begin");clear_error(&error);
      if(nested)api->filter_abort(engine,nested);
      CHECK(api->filter_commit(engine,filter,&error)==GLIMS_STATUS_OK,"guard fixture stores one real effect");clear_error(&error);filter=0;
      GlimsEffectInfo rows[2]={{0}};int32_t count=0;
      if(api->drawable_effects(engine,f.id,layer_id(&f),rows,2,&count)==GLIMS_STATUS_OK&&count==1) {
        blocked=mode==0?gimp_image_undo_disable(f.image):mode==1?gimp_image_undo_freeze(f.image):gimp_image_undo_group_start(f.image,GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE,"Curves edit guard");
        CHECK(blocked,"Undo admission is blocked before existing edit");
        status=api->filter_edit_begin(engine,f.id,layer_id(&f),rows[0].id,&filter,&error);
        CHECK(status==GLIMS_STATUS_BUSY&&filter==0,"existing Curves EditBegin refuses unavailable Undo before parking effect");clear_error(&error);
        if(filter)api->filter_abort(engine,filter);
        if(mode==0)gimp_image_undo_enable(f.image);else if(mode==1)gimp_image_undo_thaw(f.image);else gimp_image_undo_group_end(f.image);
      } else CHECK(FALSE,"guard fixture resolves committed Curves effect");
    }
    clear_error(&error);fixture_close(&f);
  }
  return GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
  if(argc!=2)return 2;work_dir=argv[1];api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api||api->struct_size<sizeof *api)return 2;
  GlimsCurvesSnapshot out=empty();char *error=NULL;
  CHECK(api->filter_curves_get(NULL,1,&out,&error)==GLIMS_STATUS_NOT_RUNNING&&out.value.samples==NULL,"nonrunning Get preserves empty owned output");clear_error(&error);
  api->free_curves_snapshot(&out);api->free_curves_snapshot(&out);
  CHECK(out.struct_size==sizeof out&&out.value.samples==NULL,"snapshot Free is reusable and preserves size");
  gchar *user=g_build_filename(work_dir,"user",NULL),*cache=g_build_filename(work_dir,"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;
  if(api->start(&config,&engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"%s\n",error?error:"startup failed");clear_error(&error);g_free(user);g_free(cache);return 2;}
  LifetimeSnapshot retained={.value={.struct_size=sizeof retained},.tail=G_GUINT64_CONSTANT(0x123456789abcdef0)};
  CHECK(glims_engine_call(engine,graph_oracles,NULL)==GLIMS_STATUS_OK,"real GEGL Curves TRC and HDR literal fixtures run on worker");
  CHECK(glims_engine_call(engine,output_boundaries,&retained)==GLIMS_STATUS_OK,"owned-output and native-domain boundaries run on worker");
  CHECK(glims_engine_call(engine,core_cases,NULL)==GLIMS_STATUS_OK,"Core snapshots and independent raw oracles run on worker");
  CHECK(glims_engine_call(engine,begin_guards,NULL)==GLIMS_STATUS_OK,"new Curves Begin history admission runs on worker");
  CHECK(glims_engine_call(engine,image_cases,NULL)==GLIMS_STATUS_OK,"real preview/Cancel/Undo/Redo/XCF guards run on worker");
  CHECK(glims_engine_call(engine,whole_value_cases,NULL)==GLIMS_STATUS_OK,"whole-value Curves storage, HDR, lifetime, admission and native history run on worker");
  api->stop(engine);host_output_cases(&retained);g_free(user);g_free(cache);printf("%s: %d failures\n",failures?"FAILED":"PASSED",failures);return failures!=0;
}

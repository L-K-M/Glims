/* Native four-plane brush fixture. Raw plane bytes and native history are
 * observed independently of the private brush implementation. */
#include "engine-private.h"
#include "lab-layer-brush-core.h"
#include "lab-layer-storage.h"
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpbrush-private.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpdynamics.h"
#include "core/gimpdynamicsoutput.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimppaintinfo.h"
#include "core/gimptempbuf.h"
#include "core/gimpundostack.h"
#include "core/gimpviewable.h"
#include "paint/gimpbrushcore.h"
#include "paint/gimppaintoptions.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

#define W 64
#define H 48
#define PIXELS (W * H)
static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c,n) do { gboolean pass=!!(c); checks++; if(!pass)failures++; printf("%s %s\n",pass?"ok":"FAIL",n); fflush(stdout); } while(0)

static gboolean read_root(GimpImage *image, unsigned root, guint8 pixels[4][PIXELS]) {
  GlimsLabLayerStorage storage;
  if(glims_lab_layer_storage_read(image,&storage)!=GLIMS_LAB_LAYER_STORAGE_VALID || root>=storage.map.count)return FALSE;
  for(unsigned i=0;i<4;i++){
    GimpDrawable *drawable=GIMP_DRAWABLE(storage.layers[root].planes[i]);
    gegl_buffer_get(gimp_drawable_get_buffer(drawable),GEGL_RECTANGLE(0,0,W,H),1,
      gimp_drawable_get_format(drawable),pixels[i],GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  }
  return TRUE;
}

static GimpBrush *hard_brush(void) {
  GimpBrush *brush=g_object_new(GIMP_TYPE_BRUSH,"name","Private Lab layer test",
                                "mime-type","image/x-gimp-gbr",NULL);
  brush->priv->mask=gimp_temp_buf_new(11,11,babl_format("Y u8"));
  memset(gimp_temp_buf_get_data(brush->priv->mask),255,121);
  brush->priv->x_axis.x=5.5;brush->priv->x_axis.y=0;
  brush->priv->y_axis.x=0;brush->priv->y_axis.y=5.5;brush->priv->spacing=15;
  return brush;
}

static gboolean stroke(GlimsEngine *engine,GimpImage *image,GList *planes,double opacity,
                       gboolean cancel,gboolean interpolate,gboolean reorder,gboolean invalid_mask) {
  GimpBrush *brush=hard_brush();
  if(invalid_mask){
    gimp_temp_buf_unref(brush->priv->mask);
    brush->priv->mask=gimp_temp_buf_new(11,11,babl_format("Y float"));
    float *mask=(float *)gimp_temp_buf_get_data(brush->priv->mask);
    for(unsigned i=0;i<121;i++)mask[i]=1;
    mask[60]=NAN;
  }
  GimpPaintInfo *info=glims_paint_info_for_tool(engine->gimp,GLIMS_PAINT_PAINTBRUSH);
  if(!brush||!info){g_clear_object(&brush);return FALSE;}
  GlimsBrushSettings settings={.struct_size=sizeof settings,.size=11,.opacity=1,
    .tool=GLIMS_PAINT_PAINTBRUSH,.hardness=1,.rate=-1,.flow=-1,.exposure=-1};
  GimpPaintOptions *options=glims_make_paint_options(engine->gimp,info,&settings,brush);
  g_object_set(options,"brush-spacing",.15,"brush-angle",0.0,"brush-aspect-ratio",0.0,
               "brush-hardness",1.0,"hard",FALSE,"use-applicator",FALSE,NULL);
  gimp_paint_options_enable_dynamics(options,FALSE);
  GimpPaintCore *core=glims_lab_layer_brush_core_new(100,64,-64,opacity);
  if(!core){g_object_unref(options);g_object_unref(brush);return FALSE;}
  GimpCoords point=GIMP_COORDS_DEFAULT_VALUES;point.x=16.5;point.y=24.5;point.pressure=1;
  GError *error=NULL;
  gboolean started=gimp_paint_core_start(core,planes,options,&point,&error);
  CHECK(started,"four-plane native stroke starts");
  if(error){fprintf(stderr,"stroke start: %s\n",error->message);g_clear_error(&error);}
  if(started){
    core->last_coords=point;
    gimp_paint_core_paint(core,planes,options,GIMP_PAINT_STATE_INIT,1);
    gimp_paint_core_paint(core,planes,options,GIMP_PAINT_STATE_MOTION,1);
    CHECK(invalid_mask ? glims_lab_layer_brush_core_error(core)!=NULL :
                        glims_lab_layer_brush_core_error(core)==NULL,
          invalid_mask ? "nonfinite mask rejects the dab" : "four-plane first dab succeeds");
    if(interpolate){GimpCoords end=point;end.x+=4;
      gimp_paint_core_interpolate(core,planes,options,&end,33);
      CHECK(!glims_lab_layer_brush_core_error(core),"interpolated dabs succeed");}
    if(reorder){
      guint8 before_rejected[4][PIXELS],after_rejected[4][PIXELS];
      CHECK(read_root(image,0,before_rejected),"capture first dab before invalid packet");
      GList *wrong=g_list_copy(planes);gpointer first=wrong->data;
      wrong->data=wrong->next->data;wrong->next->data=first;
      core->cur_coords=point;core->cur_coords.x+=12;
      gimp_paint_core_paint(core,wrong,options,GIMP_PAINT_STATE_MOTION,34);
      CHECK(glims_lab_layer_brush_core_error(core)!=NULL,"reordered planes refuse the next dab");
      CHECK(read_root(image,0,after_rejected)&&!memcmp(before_rejected,after_rejected,sizeof before_rejected),
            "rejected dab publishes no plane changes");
      g_list_free(wrong);
    }
    CHECK(!core->paint_buffer && !core->applicators,"brush avoids RGB paint buffer and applicator");
    gboolean damaged=core->x1!=core->x2 && core->y1!=core->y2;
    if(cancel && damaged)gimp_paint_core_cancel(core,planes);
    else gimp_paint_core_finish(core,planes,!cancel);
    for(GList *it=planes;it;it=it->next)
      CHECK(!gimp_viewable_preview_is_frozen(GIMP_VIEWABLE(it->data)),"plane preview thaws");
    gimp_image_flush(image);
  }
  gimp_paint_core_cleanup(core);
  g_object_unref(core);g_object_unref(options);g_object_unref(brush);
  return started;
}

/* Exercise native brush geometry with a private, size-only dynamics object.
 * The two separated dabs use different pressures in the same stroke; all
 * four planes must agree on their coverage and cancellation must restore
 * the complete pre-stroke state. */
static gboolean pressure_probe(GlimsEngine *engine,GimpImage *image,GList *planes,int scenario) {
  guint8 before[4][PIXELS],after[4][PIXELS],restored[4][PIXELS];
  if(!read_root(image,0,before))return FALSE;
  int undo=gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image));
  int redo=gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image));
  GimpBrush *brush=hard_brush();
  GimpPaintInfo *info=glims_paint_info_for_tool(engine->gimp,GLIMS_PAINT_PAINTBRUSH);
  if(!brush||!info){g_clear_object(&brush);return FALSE;}
  GlimsBrushSettings settings={.struct_size=sizeof settings,.size=11,.opacity=1,
    .tool=GLIMS_PAINT_PAINTBRUSH,.hardness=1,.rate=-1,.flow=-1,.exposure=-1};
  GimpPaintOptions *options=glims_make_paint_options(engine->gimp,info,&settings,brush);
  GimpDynamics *parent_dynamics=gimp_context_get_dynamics(gimp_get_user_context(engine->gimp));
  if(!glims_lab_layer_brush_enable_pressure_size(options)){
    g_object_unref(options);g_object_unref(brush);return FALSE;
  }
  GimpDynamics *dynamics=gimp_context_get_dynamics(GIMP_CONTEXT(options));
  gboolean size_only=dynamics&&dynamics!=parent_dynamics&&
    parent_dynamics==gimp_context_get_dynamics(gimp_get_user_context(engine->gimp))&&
    gimp_paint_options_are_dynamics_enabled(options);
  for(int output=GIMP_DYNAMICS_OUTPUT_OPACITY;output<=GIMP_DYNAMICS_OUTPUT_JITTER;output++)
    size_only=size_only&&(gimp_dynamics_is_output_enabled(dynamics,output)==
                          (output==GIMP_DYNAMICS_OUTPUT_SIZE));
  CHECK(size_only,"private dynamics enables size alone");
  g_object_set(options,"brush-spacing",.15,"brush-angle",0.0,"brush-aspect-ratio",0.0,
               "brush-hardness",1.0,"hard",FALSE,"use-applicator",FALSE,NULL);
  GimpPaintCore *core=glims_lab_layer_brush_core_new(100,64,-64,1);
  GimpCoords point=GIMP_COORDS_DEFAULT_VALUES;point.x=8.5;point.y=10.5;
  point.pressure=scenario==1?1:scenario==2?0:.25;
  GError *error=NULL;
  gboolean started=core&&gimp_paint_core_start(core,planes,options,&point,&error);
  CHECK(started,"private size-only pressure stroke starts");
  if(error){fprintf(stderr,"pressure start: %s\n",error->message);g_clear_error(&error);}
  if(started){
    core->last_coords=point;
    gimp_paint_core_paint(core,planes,options,GIMP_PAINT_STATE_INIT,1);
    gimp_paint_core_paint(core,planes,options,GIMP_PAINT_STATE_MOTION,1);
    point.x=24.5;point.pressure=scenario==1?.25:1;core->cur_coords=point;
    gimp_paint_core_paint(core,planes,options,GIMP_PAINT_STATE_MOTION,2);
    gboolean valid=!glims_lab_layer_brush_core_error(core)&&read_root(image,0,after);
    unsigned small=0,large=0,mismatch=0;
    if(valid)for(unsigned y=4;y<17;y++)for(unsigned x=2;x<31;x++){
      unsigned p=y*W+x;gboolean changed=after[3][p]!=before[3][p];
      if(x<16)small+=changed;else large+=changed;
      for(unsigned plane=0;plane<3;plane++)
        if((after[plane][p]!=before[plane][p])!=changed)mismatch++;
    }
    CHECK(valid&&(scenario==2?small==0&&large>0:
                  small>0&&large>0&&(scenario==1?small>large*2:large>small*2)),
          "pressure changes the footprint of separated dabs");
    CHECK(valid&&!mismatch,"pressure-driven coverage stays aligned across four planes");
    gimp_paint_core_cancel(core,planes);gimp_image_flush(image);
    CHECK(read_root(image,0,restored)&&!memcmp(before,restored,sizeof before)&&
          undo==gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))&&
          redo==gimp_undo_stack_get_depth(gimp_image_get_redo_stack(image)),
          "cancelling pressure-driven dabs restores all four planes and history");
    gimp_paint_core_cleanup(core);
  }
  g_clear_object(&core);g_object_unref(options);g_object_unref(brush);
  return started;
}

static GlimsStatus worker(GlimsEngine *engine,gpointer context) {
  (void)context;
  GlimsLabLayerMap map={.width=W,.height=H,.count=2,.mode=3,.storage=1,.encoding=2};
  for(guint i=0;i<2;i++)for(guint role=0;role<5;role++){
    guint8 *id=(guint8 *)&map.entries[i]+16*role;id[0]=0x31;id[14]=i+1;id[15]=role+1;
  }
  char *error=NULL;GimpImage *image=glims_lab_layer_storage_create(engine,&map,&error);
  CHECK(image && !error,"two-root layered Lab carrier creates");
  if(error)api->free_string(error);if(!image)return GLIMS_STATUS_FAILED;
  GlimsLabLayerStorage storage;
  if(glims_lab_layer_storage_read(image,&storage)!=GLIMS_LAB_LAYER_STORAGE_VALID){g_object_unref(image);return GLIMS_STATUS_FAILED;}
  GList *planes=NULL;
  for(unsigned i=0;i<4;i++){
    GimpDrawable *plane=GIMP_DRAWABLE(storage.layers[0].planes[i]);
    guint8 seed[PIXELS];memset(seed,i==3?0:11+11*i,sizeof seed);
    gegl_buffer_set(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,W,H),0,
                    gimp_drawable_get_format(plane),seed,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(plane,0,0,W,H);planes=g_list_append(planes,plane);
  }
  float mask[PIXELS];for(unsigned y=0;y<H;y++)for(unsigned x=0;x<W;x++)mask[y*W+x]=x<32?.5f:0;
  GimpDrawable *selection=GIMP_DRAWABLE(gimp_image_get_mask(image));
  gegl_buffer_set(gimp_drawable_get_buffer(selection),GEGL_RECTANGLE(0,0,W,H),0,babl_format("Y float"),mask,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(selection,0,0,W,H);
  CHECK(!gimp_channel_is_empty(GIMP_CHANNEL(selection)),"half-opacity selection is active");
  gimp_image_undo_free(image);gimp_image_clean_all(image);
  guint8 before[4][PIXELS],after[4][PIXELS],other[4][PIXELS],other_after[4][PIXELS];
  CHECK(read_root(image,0,before)&&read_root(image,1,other),"capture independent initial planes");
  int depth=gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image));
  CHECK(stroke(engine,image,planes,1,FALSE,TRUE,FALSE,FALSE),"masked brush stroke completes");
  CHECK(read_root(image,0,after)&&read_root(image,1,other_after),"capture painted planes");
  unsigned center=24*W+16;
  CHECK(after[0][center]==255 && after[1][center]==192 && after[2][center]==64 && after[3][center]==128,
        "hard brush writes physical color and selection-weighted alpha");
  CHECK(after[0][24*W+40]==before[0][24*W+40] && after[3][24*W+40]==before[3][24*W+40],
        "unselected and uncovered pixels remain unchanged");
  CHECK(!memcmp(other,other_after,sizeof other),"other logical root is byte-exact");
  CHECK(gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==depth+1,"four planes form one native Undo");
  guint8 painted[4][PIXELS];memcpy(painted,after,sizeof painted);
  CHECK(gimp_image_undo(image)&&read_root(image,0,after)&&!memcmp(before,after,sizeof before),"Undo restores all source bytes");
  CHECK(gimp_image_redo(image)&&read_root(image,0,after)&&!memcmp(painted,after,sizeof painted),"Redo restores all four planes");
  depth=gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image));
  CHECK(stroke(engine,image,planes,.5,TRUE,FALSE,FALSE,FALSE),"cancelled stroke completes native cleanup");
  CHECK(read_root(image,0,after)&&!memcmp(painted,after,sizeof painted)&&
        gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==depth,"cancel restores all planes and history");
  CHECK(stroke(engine,image,planes,0,FALSE,FALSE,FALSE,FALSE),"zero-opacity stroke completes");
  CHECK(read_root(image,0,after)&&!memcmp(painted,after,sizeof painted)&&
        gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==depth,"zero opacity changes no pixels or history");
  CHECK(stroke(engine,image,planes,.5,TRUE,FALSE,TRUE,FALSE),"invalid later dab is cancelled");
  CHECK(read_root(image,0,after)&&!memcmp(painted,after,sizeof painted)&&
        gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==depth,
        "failed stroke cancellation restores all planes and history");
  CHECK(stroke(engine,image,planes,1,TRUE,FALSE,FALSE,TRUE),"invalid brush mask completes cleanup");
  CHECK(read_root(image,0,after)&&!memcmp(painted,after,sizeof painted)&&
        gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==depth,
        "invalid brush mask publishes no planes or history");
  CHECK(!glims_lab_layer_brush_core_new(NAN,0,0,1),"nonfinite physical color is refused");
  CHECK(!glims_lab_layer_brush_enable_pressure_size(NULL),"missing pressure options are refused");
  CHECK(pressure_probe(engine,image,planes,0),"private pressure geometry probe completes");
  CHECK(pressure_probe(engine,image,planes,1),"reversed pressure geometry probe completes");
  CHECK(pressure_probe(engine,image,planes,2),"zero pressure followed by full pressure completes");
  g_list_free(planes);g_object_unref(image);
  return GLIMS_STATUS_OK;
}

int main(int argc,char **argv){
  if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig cfg={.struct_size=sizeof cfg,.user_directory=user,.cache_directory=cache};
  GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&cfg,&engine,&error);
  g_free(user);g_free(cache);if(status||!engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}
  api->free_string(error);status=glims_engine_call(engine,worker,argv[1]);api->stop(engine);
  printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;
}

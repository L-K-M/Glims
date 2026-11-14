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

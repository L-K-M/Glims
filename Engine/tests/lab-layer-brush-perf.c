/* Bounded native timing observation; no timing threshold or UI claim. */
#include "engine-private.h"
#include "lab-layer-brush-core.h"
#include "lab-layer-storage.h"
#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpbrushgenerated.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimppaintinfo.h"
#include "core/gimpundostack.h"
#include "paint/gimpbrushcore.h"
#include "paint/gimppaintoptions.h"
#include <stdio.h>
#include <string.h>

static const GlimsEngineAPI *api;

static gboolean trial(GlimsEngine *engine,int width,int height,unsigned run,gboolean populated){
  GlimsLabLayerMap map={.width=width,.height=height,.count=1,.mode=3,.storage=1,.encoding=2};
  for(unsigned role=0;role<5;role++){guint8 *id=(guint8 *)&map.entries[0]+16*role;id[0]=0x31;id[15]=role+1;}
  char *error=NULL;GimpImage *image=glims_lab_layer_storage_create(engine,&map,&error);
  if(!image){fprintf(stderr,"fixture: %s\n",error?error:"");api->free_string(error);return FALSE;}
  api->free_string(error);GlimsLabLayerStorage storage;
  if(glims_lab_layer_storage_read(image,&storage)!=GLIMS_LAB_LAYER_STORAGE_VALID){g_object_unref(image);return FALSE;}
  GList *planes=NULL;
  for(unsigned i=0;i<4;i++)planes=g_list_append(planes,storage.layers[0].planes[i]);
  if(populated){
    gsize count=(gsize)width*(gsize)height;
    guint8 *seed=g_malloc(count);
    for(unsigned role=0;role<4;role++){
      memset(seed,role==0?64:role==3?255:128,count);
      GimpDrawable *plane=GIMP_DRAWABLE(storage.layers[0].planes[role]);
      gegl_buffer_set(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,width,height),0,
                      gimp_drawable_get_format(plane),seed,GEGL_AUTO_ROWSTRIDE);
      gimp_drawable_update(plane,0,0,width,height);
    }
    g_free(seed);
  }
  GimpBrush *brush=GIMP_BRUSH(gimp_brush_generated_new("Layer brush timing",GIMP_BRUSH_GENERATED_CIRCLE,10,2,1,1,0));
  GimpPaintInfo *info=glims_paint_info_for_tool(engine->gimp,GLIMS_PAINT_PAINTBRUSH);
  if(!brush||!info){g_clear_object(&brush);g_list_free(planes);g_object_unref(image);return FALSE;}
  GlimsBrushSettings settings={.struct_size=sizeof settings,.size=11,.opacity=1,
    .tool=GLIMS_PAINT_PAINTBRUSH,.hardness=1,.rate=-1,.flow=-1,.exposure=-1};
  GimpPaintOptions *options=glims_make_paint_options(engine->gimp,info,&settings,brush);
  g_object_set(options,"brush-spacing",.15,"brush-angle",0.0,"brush-aspect-ratio",0.0,
               "brush-hardness",1.0,"hard",TRUE,"use-applicator",FALSE,NULL);
  gimp_paint_options_enable_dynamics(options,FALSE);
  GimpPaintCore *core=glims_lab_layer_brush_core_new(100,64,-64,1);
  if(!core){g_object_unref(options);g_object_unref(brush);g_list_free(planes);g_object_unref(image);return FALSE;}
  GimpCoords first=GIMP_COORDS_DEFAULT_VALUES;first.x=64.5;first.y=64.5;first.pressure=1;
  GimpDrawable *axis=GIMP_DRAWABLE(storage.layers[0].planes[1]);
  const Babl *format=gimp_drawable_get_format(axis);
  guint8 original=0;gegl_buffer_get(gimp_drawable_get_buffer(axis),GEGL_RECTANGLE(64,64,1,1),1,format,&original,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  GError *native_error=NULL;gint64 begin=g_get_monotonic_time();
  gboolean started=gimp_paint_core_start(core,planes,options,&first,&native_error);
  if(!started){fprintf(stderr,"start: %s\n",native_error?native_error->message:"");g_clear_error(&native_error);
    gimp_paint_core_cleanup(core);g_object_unref(core);g_object_unref(options);g_object_unref(brush);
    g_list_free(planes);g_object_unref(image);return FALSE;}
  core->last_coords=first;gimp_paint_core_paint(core,planes,options,GIMP_PAINT_STATE_INIT,1);
  gint64 initialized=g_get_monotonic_time();
  for(unsigned i=0;i<64 && !glims_lab_layer_brush_core_error(core);i++){
    core->cur_coords=first;core->cur_coords.x+=8*(i%8);core->cur_coords.y+=8*(i/8);
    gimp_paint_core_paint(core,planes,options,GIMP_PAINT_STATE_MOTION,i+1);
  }
  gint64 drawn=g_get_monotonic_time();
  gboolean ok=glims_lab_layer_brush_core_error(core)==NULL;
  if(ok){gimp_paint_core_paint(core,planes,options,GIMP_PAINT_STATE_FINISH,65);
    gimp_paint_core_finish(core,planes,TRUE);}
  else if(core->x1!=core->x2 && core->y1!=core->y2)gimp_paint_core_cancel(core,planes);
  else gimp_paint_core_finish(core,planes,FALSE);
  gimp_paint_core_cleanup(core);gint64 finished=g_get_monotonic_time();
  guint8 first_value=0,last_value=0;
  gegl_buffer_get(gimp_drawable_get_buffer(axis),GEGL_RECTANGLE(64,64,1,1),1,format,&first_value,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  gegl_buffer_get(gimp_drawable_get_buffer(axis),GEGL_RECTANGLE(120,120,1,1),1,format,&last_value,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  ok=ok && first_value>original && last_value>original && gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==1 && gimp_image_undo(image);
  guint8 undone=255;gegl_buffer_get(gimp_drawable_get_buffer(axis),GEGL_RECTANGLE(64,64,1,1),1,format,&undone,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  ok=ok && undone==original;
  printf("TIMING width=%d height=%d populated=%d run=%u start_ms=%.3f dabs64_ms=%.3f finish_ms=%.3f valid=%d\n",
         width,height,populated,run,(initialized-begin)/1000.0,(drawn-initialized)/1000.0,(finished-drawn)/1000.0,ok);
  fflush(stdout);g_object_unref(core);g_object_unref(options);g_object_unref(brush);g_list_free(planes);g_object_unref(image);
  return ok;
}

static GlimsStatus worker(GlimsEngine *engine,gpointer data){
  (void)data;for(unsigned i=0;i<3;i++)for(unsigned populated=0;populated<2;populated++)
    if(!trial(engine,256,256,i,populated)||!trial(engine,6000,4000,i,populated))return GLIMS_STATUS_FAILED;
  return GLIMS_STATUS_OK;
}
int main(int argc,char **argv){
  if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig cfg={.struct_size=sizeof cfg,.user_directory=user,.cache_directory=cache};
  GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&cfg,&engine,&error);
  g_free(user);g_free(cache);if(status||!engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}
  api->free_string(error);status=glims_engine_call(engine,worker,argv[1]);api->stop(engine);return status==GLIMS_STATUS_OK?0:1;
}

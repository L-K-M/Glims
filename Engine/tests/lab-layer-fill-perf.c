/* Diagnostic native throughput only; not an app interaction benchmark. */
#include "lab-layer-fill.h"
#include "lab-layer-storage.h"
#include <stdio.h>
#include <time.h>
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimplayer.h"

static const GlimsEngineAPI *api;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec*1e-9; }
static GlimsStatus worker(GlimsEngine *engine,gpointer unused)
{
  (void)unused;
  GlimsLabLayerMap map={.width=6000,.height=4000,.count=1,.mode=3,.storage=1,.encoding=2};
  for(guint p=0;p<5;p++){guint8 *id=(guint8 *)&map.entries[0]+16*p;id[0]=1;id[15]=p+1;}
  char *error=NULL;double start=now();GimpImage *image=glims_lab_layer_storage_create(engine,&map,&error);
  if(!image){fprintf(stderr,"create: %s\n",error?error:"");if(error)api->free_string(error);return GLIMS_STATUS_FAILED;}
  printf("24MP carrier creation %.3f s\n",now()-start);
  GlimsLabLayerStorage storage;
  if(glims_lab_layer_storage_read(image,&storage)!=GLIMS_LAB_LAYER_STORAGE_VALID){g_object_unref(image);return GLIMS_STATUS_FAILED;}
  GimpLayer *root=storage.layers[0].group;GList *selected=g_list_prepend(NULL,root);
  gimp_image_set_selected_layers(image,selected);g_list_free(selected);
  gboolean changed=FALSE;start=now();
  GlimsStatus status=glims_lab_layer_fill(engine,image,root,50,0,0,.5,&changed,&error);
  double elapsed=now()-start;
  printf("24MP staged fill %.3f s status=%d changed=%d\n",elapsed,status,changed);
  if(error){fprintf(stderr,"fill: %s\n",error);api->free_string(error);}
  if(status==GLIMS_STATUS_OK&&changed){
    guint8 q=0;GimpDrawable *alpha=GIMP_DRAWABLE(storage.layers[0].planes[3]);
    gegl_buffer_get(gimp_drawable_get_buffer(alpha),GEGL_RECTANGLE(5999,3999,1,1),1,gimp_drawable_get_format(alpha),&q,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    if(q!=128)status=GLIMS_STATUS_FAILED;
  } else status=GLIMS_STATUS_FAILED;
  g_object_unref(image);return status;
}
int main(int argc,char **argv)
{
  if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig cfg={.struct_size=sizeof cfg,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;
  GlimsStatus status=api->start(&cfg,&engine,&error);g_free(user);g_free(cache);
  if(status||!engine){fprintf(stderr,"start: %s\n",error?error:"");if(error)api->free_string(error);return 2;}
  if(error)api->free_string(error);status=glims_engine_call(engine,worker,NULL);api->stop(engine);
  printf("checks=1 failures=%d\n",status==GLIMS_STATUS_OK?0:1);
  return status==GLIMS_STATUS_OK?0:1;
}

/* Private export admission and signature round-trip on the engine thread. */
#include "engine-private.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimplayer.h"
#include "core/gimpdrawable.h"
#include "core/gimplayer-new.h"
static unsigned checks,failures;
#define CHECK(c,s) do { gboolean ok=!!(c);checks++;failures+=!ok;printf("%s %s\n",ok?"ok":"FAIL",s);fflush(stdout); } while(0)
static gboolean attach(GimpImage *image,const char *name,guint32 size,const void *bytes)
{
 GimpParasite *p=gimp_parasite_new(name,GIMP_PARASITE_PERSISTENT,size,bytes);if(!p)return FALSE;
 gimp_image_parasite_attach(image,p,FALSE);gimp_parasite_free(p);return gimp_image_parasite_find(image,name)!=NULL;
}
static GlimsStatus probe(GlimsEngine *engine,void *data)
{
 const char *work=data,*primary="psd-duotone-data",*bim="psd-image-resource-8BIM-042a",*mesa="psd-image-resource-MeSa-042a";
 const guint8 metadata[]={1,2,3}, alternate[]={9,8,7};
 GimpImage *image=gimp_create_image(engine->gimp,1,1,GIMP_GRAY,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
 CHECK(image!=NULL,"create grayscale export image");if(!image)return GLIMS_STATUS_FAILED;
 GimpLayer *layer=gimp_layer_new(image,1,1,gimp_image_get_layer_format(image,TRUE),"Layer",1,GIMP_LAYER_MODE_NORMAL);
 gboolean added=layer && gimp_image_add_layer(image,layer,NULL,0,FALSE);
 if(layer && !added)g_object_unref(layer);
 if(!added){g_object_unref(image);return GLIMS_STATUS_FAILED;}
 const guint8 pixel[]={128,255};
 gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)),GEGL_RECTANGLE(0,0,1,1),0,babl_format("Y'A u8"),pixel,GEGL_AUTO_ROWSTRIDE);
 gimp_drawable_update(GIMP_DRAWABLE(layer),0,0,1,1);
 gboolean tags=attach(image,primary,sizeof metadata,metadata) && attach(image,bim,sizeof alternate,alternate) && attach(image,mesa,sizeof alternate,alternate);
 CHECK(tags,"attach conflicting signatures");
 GlimsImageID id=0;GlimsStatus status=tags?glims_adopt_image(engine,image,&id):GLIMS_STATUS_FAILED;
 CHECK(status==GLIMS_STATUS_OK && id,"adopt image");if(status!=GLIMS_STATUS_OK||!id){g_object_unref(image);return GLIMS_STATUS_FAILED;}
 char *path=g_build_filename(work,"alternate-export.psd",NULL), *error=NULL, *saved=NULL;gsize length=0;
 gboolean seeded=g_file_set_contents(path,"keep",4,NULL);
 status=glims_image_export_duotone_psd(engine,id,path,&error);
 gboolean read=g_file_get_contents(path,&saved,&length,NULL);
 CHECK(seeded && status==GLIMS_STATUS_UNSUPPORTED && error && strstr(error,"conflicting") && read && length==4 && !memcmp(saved,"keep",4),"both signatures refuse without replacing destination");
 free(error);error=NULL;g_free(saved);saved=NULL;
 gimp_image_parasite_detach(image,bim,FALSE);
 status=glims_image_export_duotone_psd(engine,id,path,&error);
 read=g_file_get_contents(path,&saved,&length,NULL);
 const guint8 expected[]={'M','e','S','a',4,42,0,0,0,0,0,3,9,8,7,0};
 CHECK(status==GLIMS_STATUS_OK && read && length>=30+sizeof metadata+4+sizeof expected &&
       !memcmp(saved+30+sizeof metadata+4,expected,sizeof expected),"MeSa resource exports exact bytes with padding");
 free(error);error=NULL;
 gimp_image_parasite_detach(image,mesa,FALSE);
 CHECK(attach(image,bim,0,NULL),"attach empty resource");
 status=glims_image_export_duotone_psd(engine,id,path,&error);
 char *after=NULL;gsize after_length=0;read=g_file_get_contents(path,&after,&after_length,NULL);
 CHECK(status==GLIMS_STATUS_UNSUPPORTED && error && strstr(error,"unusable") && saved && read && length==after_length && !memcmp(saved,after,length),"empty resource refuses without replacing destination");
 free(error);error=NULL;g_free(after);
 size_t big_size=16u*1024u*1024u+1u;guint8 *big=g_malloc0(big_size);
 CHECK(big && attach(image,bim,(guint32)big_size,big),"attach oversized resource");g_free(big);
 status=glims_image_export_duotone_psd(engine,id,path,&error);
 after=NULL;after_length=0;read=g_file_get_contents(path,&after,&after_length,NULL);
 CHECK(status==GLIMS_STATUS_UNSUPPORTED && error && strstr(error,"unusable") && saved && read && length==after_length && !memcmp(saved,after,length),"oversized resource refuses without replacing destination");
 free(error);g_free(after);g_free(saved);g_free(path);glims_image_close(engine,id);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv)
{
 if(argc!=2)return 2;const GlimsEngineAPI *api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
 char *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
 GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
 GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&config,&engine,&error);
 g_free(user);g_free(cache);if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}
 api->free_string(error);status=glims_engine_call(engine,probe,argv[1]);api->stop(engine);
 printf("%u checks, %u failures\n",checks,failures);return status!=GLIMS_STATUS_OK||failures?1:0;
}

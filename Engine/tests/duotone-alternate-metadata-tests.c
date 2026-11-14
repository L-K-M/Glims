/* Exercise promotion on the engine thread without relying on PSD loader input. */
#include "engine-private.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"

static unsigned checks, failures;
#define CHECK(c,label) do { gboolean ok=!!(c); checks++; if(!ok)failures++; \
  printf("%s %s\n",ok?"ok":"FAIL",label); fflush(stdout); } while(0)
static const char *primary="psd-duotone-data";
static const char *alternate="psd-image-resource-8BIM-042a";
static const char *mesa="psd-image-resource-MeSa-042a";
static const unsigned char a[]={1,0,2,0xff,0x7f};
static const unsigned char b[]={9,8,7};

static gboolean attach (GimpImage *image, const char *name, guint32 flags,
                        guint32 size, const void *data)
{
  GimpParasite *tag=gimp_parasite_new(name,flags,size,data);
  if(!tag)return FALSE;
  gimp_image_parasite_attach(image,tag,FALSE);
  gimp_parasite_free(tag);
  return gimp_image_parasite_find(image,name)!=NULL;
}
static gboolean matches (GimpImage *image, const char *name, gboolean persistent,
                         guint32 flags, guint32 size, const void *data)
{
  const GimpParasite *tag=gimp_image_parasite_find(image,name); guint32 actual=0;
  const void *payload=tag?gimp_parasite_get_data(tag,&actual):NULL;
  return tag && !!gimp_parasite_is_persistent(tag)==!!persistent &&
    gimp_parasite_get_flags(tag)==flags && actual==size &&
    (!size || (payload && data && !memcmp(payload,data,size)));
}
static GlimsStatus probe (GlimsEngine *engine, void *unused)
{
  const char *work=unused;
  CHECK(glims_duotone_preserve_import(NULL,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"null image refuses");
  GimpImage *image=gimp_create_image(engine->gimp,1,1,GIMP_GRAY,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
  CHECK(image!=NULL,"create grayscale image"); if(!image)return GLIMS_STATUS_FAILED;
  CHECK(attach(image,alternate,0,sizeof a,a),"attach unrelated alternate metadata");
  CHECK(glims_duotone_preserve_import(image,NULL)==GLIMS_STATUS_OK &&
        matches(image,alternate,FALSE,0,sizeof a,a),"no Duotone tag leaves metadata unchanged");
  CHECK(attach(image,primary,0,sizeof b,b) && attach(image,mesa,GIMP_PARASITE_UNDOABLE,sizeof b,b),
        "attach Duotone and MeSa metadata");
  CHECK(glims_duotone_preserve_import(image,NULL)==GLIMS_STATUS_OK &&
        matches(image,primary,TRUE,GIMP_PARASITE_PERSISTENT,sizeof b,b) &&
        matches(image,alternate,TRUE,GIMP_PARASITE_PERSISTENT,sizeof a,a) &&
        matches(image,mesa,TRUE,GIMP_PARASITE_PERSISTENT|GIMP_PARASITE_UNDOABLE,sizeof b,b),
        "promote both alternate signatures and retain the original flags and bytes");
  CHECK(glims_duotone_preserve_import(image,NULL)==GLIMS_STATUS_OK &&
        matches(image,alternate,TRUE,GIMP_PARASITE_PERSISTENT,sizeof a,a),"promotion is idempotent");
  g_object_unref(image);

  image=gimp_create_image(engine->gimp,1,1,GIMP_GRAY,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
  CHECK(image!=NULL,"create persistent-primary image"); if(!image)return GLIMS_STATUS_FAILED;
  CHECK(attach(image,primary,GIMP_PARASITE_PERSISTENT,sizeof b,b) && attach(image,alternate,0,sizeof a,a),
        "attach persistent primary with transient alternate");
  CHECK(glims_duotone_preserve_import(image,NULL)==GLIMS_STATUS_OK &&
        matches(image,alternate,TRUE,GIMP_PARASITE_PERSISTENT,sizeof a,a),
        "persistent primary does not skip transient alternate");
  g_object_unref(image);

  image=gimp_create_image(engine->gimp,1,1,GIMP_RGB,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
  CHECK(image!=NULL,"create RGB image"); if(!image)return GLIMS_STATUS_FAILED;
  CHECK(attach(image,primary,0,sizeof b,b) && attach(image,alternate,0,sizeof a,a),"attach RGB tags");
  CHECK(glims_duotone_preserve_import(image,NULL)==GLIMS_STATUS_OK &&
        matches(image,primary,FALSE,0,sizeof b,b) && matches(image,alternate,FALSE,0,sizeof a,a),
        "non-grayscale images remain untouched");
  g_object_unref(image);

  image=gimp_create_image(engine->gimp,1,1,GIMP_GRAY,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
  CHECK(image!=NULL,"create malformed-resource image"); if(!image)return GLIMS_STATUS_FAILED;
  CHECK(attach(image,primary,0,sizeof b,b) && attach(image,alternate,0,0,NULL),"attach empty alternate resource");
  char *error=NULL; GlimsStatus status=glims_duotone_preserve_import(image,&error);
  CHECK(status==GLIMS_STATUS_UNSUPPORTED && error && strstr(error,"empty or too large") &&
        matches(image,alternate,FALSE,0,0,NULL),"empty transient resource refuses with reason");
  free(error);g_object_unref(image);

  image=gimp_create_image(engine->gimp,1,1,GIMP_GRAY,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
  CHECK(image!=NULL,"create oversized-resource image"); if(!image)return GLIMS_STATUS_FAILED;
  size_t large_size=16u*1024u*1024u+1u; unsigned char *large=calloc(large_size,1);
  CHECK(large!=NULL,"allocate oversized resource");
  if(large){
    CHECK(attach(image,primary,0,sizeof b,b) && attach(image,alternate,0,(guint32)large_size,large),
          "attach oversized alternate resource");
    error=NULL;status=glims_duotone_preserve_import(image,&error);
    CHECK(status==GLIMS_STATUS_UNSUPPORTED && error && strstr(error,"too large") &&
          matches(image,alternate,FALSE,0,(guint32)large_size,large),"oversized transient resource refuses without changing it");
    free(error);free(large);
  }
  g_object_unref(image);

  /* Inspect the actual parasite objects after XCF reload, including MeSa. */
  image=gimp_create_image(engine->gimp,1,1,GIMP_GRAY,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
  CHECK(image!=NULL,"create XCF round-trip image");if(!image)return GLIMS_STATUS_FAILED;
  GimpLayer *layer=gimp_layer_new(image,1,1,gimp_image_get_layer_format(image,TRUE),
                                 "Layer",1,GIMP_LAYER_MODE_NORMAL);
  gboolean added=layer && gimp_image_add_layer(image,layer,NULL,0,FALSE);
  if(layer && !added)g_object_unref(layer);
  gboolean ready=added &&
    attach(image,primary,0,sizeof b,b) && attach(image,alternate,0,sizeof a,a) &&
    attach(image,mesa,GIMP_PARASITE_UNDOABLE,sizeof b,b) &&
    glims_duotone_preserve_import(image,NULL)==GLIMS_STATUS_OK;
  CHECK(ready,"prepare both alternate signatures for XCF");
  GlimsImageID first=0,reopened=0;char *path=g_build_filename(work,"alternate-roundtrip.xcf",NULL);
  if(ready){
    status=glims_adopt_image(engine,image,&first);
    CHECK(status==GLIMS_STATUS_OK && first,"adopt the round-trip image");
    if(status==GLIMS_STATUS_OK && first){
      error=NULL;status=glims_image_save(engine,first,path,&error);
      CHECK(status==GLIMS_STATUS_OK,"save both alternate signatures to XCF");
      free(error);error=NULL;
      if(status==GLIMS_STATUS_OK){
        status=glims_image_open(engine,path,&reopened,&error);
        CHECK(status==GLIMS_STATUS_OK && reopened,"reopen the saved XCF");
        free(error);error=NULL;
        if(status==GLIMS_STATUS_OK && reopened){
          GlimsOpenImage *open=glims_lookup_image(engine,reopened);
          CHECK(open && matches(open->image,primary,TRUE,GIMP_PARASITE_PERSISTENT,sizeof b,b) &&
                matches(open->image,alternate,TRUE,GIMP_PARASITE_PERSISTENT,sizeof a,a) &&
                matches(open->image,mesa,TRUE,GIMP_PARASITE_PERSISTENT|GIMP_PARASITE_UNDOABLE,sizeof b,b),
                "reopened parasite objects retain both signatures, flags and bytes");
          glims_image_close(engine,reopened);
        }
      }
      glims_image_close(engine,first);
    } else g_object_unref(image);
  } else g_object_unref(image);
  g_free(path);
  return GLIMS_STATUS_OK;
}
int main(int argc,char **argv)
{
  if(argc!=2)return 2;
  const GlimsEngineAPI *api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  char *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
  GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&config,&engine,&error);
  g_free(user);g_free(cache);if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}
  api->free_string(error);status=glims_engine_call(engine,probe,argv[1]);api->stop(engine);
  printf("%u checks, %u failures\n",checks,failures);return status!=GLIMS_STATUS_OK||failures?1:0;
}

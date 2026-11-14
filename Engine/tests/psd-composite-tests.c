#define _POSIX_C_SOURCE 200809L
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c,label) do { int ok=!!(c); checks++; failures+=!ok; printf("%s %s\n",ok?"ok":"FAIL",label); fflush(stdout); } while(0)
static size_t read_bytes(const char *path, unsigned char *bytes, size_t capacity)
{
  FILE *f=fopen(path,"rb"); if(!f)return 0;
  size_t n=fread(bytes,1,capacity,f); int bad=ferror(f)||!feof(f); fclose(f); return bad?0:n;
}
static void clear_error(const GlimsEngineAPI *api,char **error)
{
  if(*error){fprintf(stderr,"%s\n",*error);api->free_string(*error);*error=NULL;}
}
int main(int argc,char **argv)
{
  if(argc!=4)return 2;
  void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if(!library){fprintf(stderr,"%s\n",dlerror());return 2;}
  GlimsEngineGetAPIFunction get=(GlimsEngineGetAPIFunction)dlsym(library,"glims_engine_get_api");
  const GlimsEngineAPI *api=get?get(GLIMS_ENGINE_API_VERSION):NULL;
  if(!api || api->struct_size<offsetof(GlimsEngineAPI,image_open_psd_composite)+sizeof api->image_open_psd_composite || !api->image_open_psd_composite)return 2;
  char user[1024],cache[1024],fixture[1024],fake[1024],xcf[1024];
  snprintf(user,sizeof user,"%s/user",argv[2]); snprintf(cache,sizeof cache,"%s/cache",argv[2]);
  snprintf(fixture,sizeof fixture,"%s/photoshop-cc2018-duotone.psd",argv[3]);
  snprintf(fake,sizeof fake,"%s/not-a-psd.psd",argv[2]); snprintf(xcf,sizeof xcf,"%s/composite.xcf",argv[2]);
  FILE *f=fopen(fake,"wb"); if(!f)return 2; if(fwrite("bad input",1,9,f)!=9||fclose(f))return 2;
  unsigned char original[65536],after[65536]; size_t n=read_bytes(fixture,original,sizeof original); if(n<30)return 2;
  size_t block=((size_t)original[26]<<24)|((size_t)original[27]<<16)|((size_t)original[28]<<8)|original[29];
  if(!block||block>n-30)return 2;
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
  GlimsEngine *engine=NULL;char *error=NULL; GlimsStatus status=api->start(&config,&engine,&error);
  CHECK(status==GLIMS_STATUS_OK && engine,"engine starts");clear_error(api,&error);if(!engine)return 1;
  GlimsImageID image=77;
  status=api->image_open_psd_composite(engine,"relative.psd",&image,&error);
  CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT && !image,"relative path refuses and clears output");clear_error(api,&error);
  image=77;status=api->image_open_psd_composite(engine,fake,&image,&error);
  CHECK(status!=GLIMS_STATUS_OK && !image && error,"a non-PSD refuses despite its suffix");clear_error(api,&error);
  status=api->image_open_psd_composite(engine,fixture,&image,&error);
  CHECK(status==GLIMS_STATUS_OK && image,"open Photoshop-authored merged composite");clear_error(api,&error);
  if(image){
    GlimsImageInfo info={0};int32_t count=0;unsigned char pixels[64]={0};
    CHECK(api->image_info(engine,image,&info)==GLIMS_STATUS_OK && info.width==4 && info.height==4 && !info.dirty,
          "composite has expected dimensions and clean native history");
    CHECK(api->image_layers(engine,image,NULL,0,&count)==GLIMS_STATUS_OK && count==1,"composite has one flattened layer");
    CHECK(api->image_render(engine,image,1,(GlimsRect){0,0,4,4},pixels,16)==GLIMS_STATUS_OK &&
          pixels[0]>=23 && pixels[0]<=25 && pixels[0]==pixels[1] && pixels[1]==pixels[2] && pixels[3]==255,
          "Photoshop gradient's first pixel is visible and opaque");
    /* Independent macOS ImageIO sRGB decode of the Photoshop fixture. Allow
     * two levels for differing grayscale conversion/rounding. */
    static const unsigned char expected[16]={24,50,94,172, 50,24,50,94, 95,50,24,50, 172,95,50,23};
    int matches=1;
    for(size_t i=0;i<16;i++)
      for(size_t c=0;c<4;c++)
        if(c==3 ? pixels[i*4+c]!=255 : abs((int)pixels[i*4+c]-(int)expected[i])>2)matches=0;
    CHECK(matches,"merged pixels match independent ImageIO decode within two levels");
    status=api->image_save(engine,image,xcf,&error);
    size_t saved=read_bytes(xcf,after,sizeof after);int found=0;
    for(size_t i=0;i+block<=saved;i++)if(!memcmp(after+i,original+30,block)){found=1;break;}
    CHECK(status==GLIMS_STATUS_OK && found,"XCF retains the exact Duotone settings");clear_error(api,&error);
    CHECK(read_bytes(fixture,after,sizeof after)==n && !memcmp(original,after,n),"source PSD bytes remain unchanged");
    api->image_close(engine,image);
  }
  api->stop(engine);dlclose(library);printf("%u checks, %u failures\n",checks,failures);return failures?1:0;
}

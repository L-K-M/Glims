#define _POSIX_C_SOURCE 200809L
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c,label) do { bool ok=!!(c); checks++; failures+=!ok; \
  printf("%s %s\n",ok?"ok":"FAIL",label); fflush(stdout); } while(0)
static const unsigned char opaque[] = "Glims-opaque-duotone-spec-82f7a3";
static int contains(const char *path, const unsigned char *needle, size_t length)
{
  FILE *f=fopen(path,"rb"); if(!f)return 0;
  if(fseek(f,0,SEEK_END)!=0){fclose(f);return 0;} long n=ftell(f);
  if(n<0 || n>16*1024*1024 || fseek(f,0,SEEK_SET)!=0){fclose(f);return 0;}
  unsigned char *data=malloc((size_t)n+1); if(!data){fclose(f);return 0;}
  int found=0; if(fread(data,1,(size_t)n,f)==(size_t)n)
    for(size_t i=0;i+length<=(size_t)n;i++) if(!memcmp(data+i,needle,length)){found=1;break;}
  free(data); fclose(f); return found;
}
static size_t read_small(const char *path, unsigned char *out, size_t capacity)
{
  FILE *f=fopen(path,"rb"); if(!f)return 0;
  size_t n=fread(out,1,capacity,f); int bad=ferror(f) || !feof(f);
  fclose(f); return bad ? 0 : n;
}
static int fixture(const char *path)
{
  /* Synthetic PSD v1 Duotone envelope. Adobe describes this color block as
   * opaque; bytes here are a marker, not a claim of a valid Photoshop ink spec. */
  unsigned char header[30]={'8','B','P','S',0,1};
  header[13]=1; header[17]=1; header[21]=4; header[23]=8; header[25]=8;
  unsigned size=(unsigned)sizeof opaque-1;
  header[26]=(unsigned char)(size>>24); header[27]=(unsigned char)(size>>16);
  header[28]=(unsigned char)(size>>8); header[29]=(unsigned char)size;
  unsigned char tail[]={0,0,0,0, 0,0,0,0, 0,0, 0,85,170,255};
  FILE *f=fopen(path,"wb");if(!f)return 0;
  int okay=fwrite(header,1,sizeof header,f)==sizeof header && fwrite(opaque,1,size,f)==size && fwrite(tail,1,sizeof tail,f)==sizeof tail;
  return fclose(f)==0 && okay;
}
static int oversized_fixture(const char *path)
{
  const unsigned size=16u*1024u*1024u+1u;
  unsigned char header[30]={'8','B','P','S',0,1};
  header[13]=1; header[17]=1; header[21]=4; header[23]=8; header[25]=8;
  header[26]=(unsigned char)(size>>24); header[27]=(unsigned char)(size>>16);
  header[28]=(unsigned char)(size>>8); header[29]=(unsigned char)size;
  unsigned char tail[]={0,0,0,0, 0,0,0,0, 0,0, 0,85,170,255};
  FILE *f=fopen(path,"wb"); if(!f)return 0;
  int okay=fwrite(header,1,sizeof header,f)==sizeof header &&
           fseek(f,(long)size-1,SEEK_CUR)==0 && fputc(0,f)!=EOF &&
           fwrite(tail,1,sizeof tail,f)==sizeof tail;
  return fclose(f)==0 && okay;
}
int main(int argc,char **argv)
{
  if(argc!=4)return 2;
  void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
  GlimsEngineGetAPIFunction get=(GlimsEngineGetAPIFunction)dlsym(lib,"glims_engine_get_api");
  const GlimsEngineAPI *api=get?get(GLIMS_ENGINE_API_VERSION):NULL;if(!api)return 2;
  char user[1024],cache[1024],psd[1024],xcf[1024],again[1024],large[1024],real[1024],real_xcf[1024],real_again[1024];
  snprintf(user,sizeof user,"%s/user",argv[2]);snprintf(cache,sizeof cache,"%s/cache",argv[2]);
  snprintf(large,sizeof large,"%s/oversized.psd",argv[2]);snprintf(psd,sizeof psd,"%s/input.psd",argv[2]);snprintf(xcf,sizeof xcf,"%s/first.xcf",argv[2]);snprintf(again,sizeof again,"%s/again.xcf",argv[2]);
  snprintf(real,sizeof real,"%s/photoshop-cc2018-duotone.psd",argv[3]);
  snprintf(real_xcf,sizeof real_xcf,"%s/photoshop.xcf",argv[2]);
  snprintf(real_again,sizeof real_again,"%s/photoshop-again.xcf",argv[2]);
  unsigned char real_before[65536], real_after[65536];
  size_t real_size=read_small(real,real_before,sizeof real_before); if(real_size<30)return 2;
  size_t block_size=((size_t)real_before[26]<<24)|((size_t)real_before[27]<<16)|((size_t)real_before[28]<<8)|real_before[29];
  if(real_before[24]!=0 || real_before[25]!=8 || block_size==0 || block_size>real_size-30)return 2;
  if(!fixture(psd))return 2;
  unsigned char source_before[256], source_after[256];
  size_t source_size=read_small(psd,source_before,sizeof source_before); if(!source_size)return 2;
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
  GlimsEngine *engine=NULL;char *error=NULL; GlimsStatus status=api->start(&config,&engine,&error);
  CHECK(status==GLIMS_STATUS_OK && engine,"engine starts");
  if(error){fprintf(stderr,"start: %s\n",error);api->free_string(error);error=NULL;} if(!engine)return 1;
  GlimsImageID image=0,reopened=0;
  status=api->image_open(engine,psd,&image,&error);
  CHECK(status==GLIMS_STATUS_OK && image,"GIMP imports synthetic Duotone envelope");
  if(error){fprintf(stderr,"open: %s\n",error);api->free_string(error);error=NULL;}
  if(image){
    GlimsImageInfo info={0}; GlimsUndoInfo undo={0};
    CHECK(api->image_info(engine,image,&info)==GLIMS_STATUS_OK && info.width==4 && info.height==1 && !info.dirty &&
          api->image_undo_info(engine,image,&undo)==GLIMS_STATUS_OK && undo.undo_count==0,
          "import retains dimensions and remains clean without an Undo step");
    status=api->image_save(engine,image,xcf,&error);
    CHECK(status==GLIMS_STATUS_OK && contains(xcf,(const unsigned char *)"psd-duotone-data",16) &&
          contains(xcf,opaque,sizeof opaque-1), "XCF save retains the named opaque Duotone block");
    if(error){fprintf(stderr,"save: %s\n",error);api->free_string(error);error=NULL;}
    status=api->image_open(engine,xcf,&reopened,&error);
    CHECK(status==GLIMS_STATUS_OK && reopened,"saved XCF reopens");
    if(error){fprintf(stderr,"reopen: %s\n",error);api->free_string(error);error=NULL;}
    if(reopened){
      status=api->image_save(engine,reopened,again,&error);
      CHECK(status==GLIMS_STATUS_OK && contains(again,opaque,sizeof opaque-1), "XCF reopen and save retains exact opaque bytes");
      if(error){fprintf(stderr,"resave: %s\n",error);api->free_string(error);error=NULL;}api->image_close(engine,reopened);
    }
    size_t after_size=read_small(psd,source_after,sizeof source_after);
    CHECK(after_size==source_size && !memcmp(source_before,source_after,source_size), "original PSD remains byte-for-byte unchanged");
    api->image_close(engine,image);
  }
  GlimsImageID photoshop=0, photoshop_reopened=0;
  status=api->image_open(engine,real,&photoshop,&error);
  CHECK(status==GLIMS_STATUS_OK && photoshop,"open Photoshop-authored Duotone fixture");
  if(error){fprintf(stderr,"Photoshop fixture: %s\n",error);api->free_string(error);error=NULL;}
  if(photoshop) {
    status=api->image_save(engine,photoshop,real_xcf,&error);
    CHECK(status==GLIMS_STATUS_OK && contains(real_xcf,real_before+30,block_size),
          "XCF preserves Photoshop's exact opaque color-mode block");
    if(error){api->free_string(error);error=NULL;}
    status=api->image_open(engine,real_xcf,&photoshop_reopened,&error);
    CHECK(status==GLIMS_STATUS_OK && photoshop_reopened,"Photoshop fixture's XCF reopens");
    if(error){api->free_string(error);error=NULL;}
    if(photoshop_reopened) {
      status=api->image_save(engine,photoshop_reopened,real_again,&error);
      CHECK(status==GLIMS_STATUS_OK && contains(real_again,real_before+30,block_size),
            "XCF resave preserves Photoshop's exact opaque color-mode block");
      if(error){api->free_string(error);error=NULL;}
      api->image_close(engine,photoshop_reopened);
    }
    api->image_close(engine,photoshop);
  }
  size_t real_after_size=read_small(real,real_after,sizeof real_after);
  CHECK(real_after_size==real_size && !memcmp(real_before,real_after,real_size),
        "Photoshop fixture remains byte-for-byte unchanged");
  CHECK(oversized_fixture(large), "create an oversized opaque-block fixture");
  GlimsImageID rejected=0;
  status=api->image_open(engine,large,&rejected,&error);
  CHECK(status==GLIMS_STATUS_UNSUPPORTED && rejected==0 && error && strstr(error,"too large"),
        "oversized Duotone block refuses without adopting an image");
  if(error){api->free_string(error);error=NULL;}
  if(rejected)api->image_close(engine,rejected);
  api->stop(engine);dlclose(lib);printf("%u checks, %u failures\n",checks,failures);
  return failures?1:0;
}

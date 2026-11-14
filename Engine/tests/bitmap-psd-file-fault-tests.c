/* Inject errors only into the transaction translation unit. Fixture writes
 * and checks use real syscalls and inspect the entire private directory. */
#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#include "bitmap-psd-file.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum Fault { NO_FAULT, WRITE_ERROR, SYNC_ERROR, RENAME_ERROR };
static enum Fault fault;
static unsigned checks, failures, reads;
#define CHECK(c,label) do { bool ok=!!(c); checks++; failures+=!ok; printf("%s %s\n",ok?"ok":"FAIL",label); } while(0)
ssize_t glims_test_write(int fd,const void *buffer,size_t size)
{ if(fault==WRITE_ERROR){errno=ENOSPC;return -1;} return write(fd,buffer,size); }
int glims_test_fsync(int fd)
{ if(fault==SYNC_ERROR){errno=EIO;return -1;} return fsync(fd); }
int glims_test_renameat(int oldfd,const char *old,int newfd,const char *newname)
{ if(fault==RENAME_ERROR){errno=EACCES;return -1;} return renameat(oldfd,old,newfd,newname); }
static bool read_pixels(void *context,uint32_t y,uint32_t x,uint32_t count,uint8_t *pixels)
{
  (void)context;reads++;for(uint32_t i=0;i<count;i++)pixels[i]=((x+i+y)&1)?255:0;return true;
}
static bool has_original(const char *path)
{
  unsigned char b[16];FILE *f=fopen(path,"rb");if(!f)return false;
  size_t n=fread(b,1,sizeof b,f);bool ok=!ferror(f)&&feof(f)&&n==8&&!memcmp(b,"original",8);
  fclose(f);return ok;
}
static bool only_target(const char *directory)
{
  DIR *d=opendir(directory);if(!d)return false;struct dirent *entry;bool good=true;
  while((entry=readdir(d)))if(strcmp(entry->d_name,".")&&strcmp(entry->d_name,"..")&&strcmp(entry->d_name,"out.psd"))good=false;
  closedir(d);return good;
}
int main(void)
{
  char dir[]="/tmp/glims-bitmap-faults-XXXXXX";if(!mkdtemp(dir))return 2;
  char path[256];snprintf(path,sizeof path,"%s/out.psd",dir);
  GlimsBitmapPsdSpec spec={9,2};
  for(fault=NO_FAULT;fault<=RENAME_ERROR;fault++){
    FILE *f=fopen(path,"wb");if(!f)return 2;
    if(fwrite("original",1,8,f)!=8||fclose(f))return 2;
    if(chmod(path,0640))return 2;
    reads=0;int error=-1;
    GlimsBitmapPsdFileStatus result=glims_bitmap_psd_write_file(&spec,read_pixels,NULL,path,NULL,NULL,&error);
    int expected=fault==WRITE_ERROR?ENOSPC:fault==SYNC_ERROR?EIO:fault==RENAME_ERROR?EACCES:0;
    CHECK(result==(fault==NO_FAULT?GLIMS_BITMAP_PSD_FILE_OK:GLIMS_BITMAP_PSD_FILE_IO_FAILED) && error==expected,
          "write, fsync and rename faults map to the Bitmap IO status");
    CHECK(only_target(dir),"transaction leaves no temporary file after injected fault");
    CHECK(fault==NO_FAULT || has_original(path),"injected fault leaves original destination intact");
    struct stat st;CHECK(stat(path,&st)==0 && (st.st_mode&0777)==0640,"destination permissions are preserved");
    CHECK(fault!=WRITE_ERROR || reads==0,"header write failure stops before reading pixels");
  }
  unlink(path);rmdir(dir);printf("Bitmap PSD file faults: %u checks, %u failures\n",checks,failures);return failures?1:0;
}

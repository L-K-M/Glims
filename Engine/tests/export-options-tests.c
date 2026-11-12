/* Public-facade tests; file headers are decoded independently of the engine. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int checks, failures;
#define CHECK(c, label) do { int ok_ = !!(c); checks++; failures += !ok_; printf ("%s %s\n", ok_ ? "ok" : "FAIL", label); fflush (stdout); } while (0)

typedef struct { unsigned char *bytes; size_t count; } File;
static File read_file (const char *path)
{
  File f = {0}; FILE *stream = fopen (path, "rb");
  if (!stream) return f;
  if (fseek (stream, 0, SEEK_END) || ftell (stream) < 0) { fclose (stream); return f; }
  f.count = (size_t) ftell (stream); rewind (stream);
  f.bytes = malloc (f.count ? f.count : 1);
  if (!f.bytes || fread (f.bytes, 1, f.count, stream) != f.count) { free (f.bytes); f = (File) {0}; }
  fclose (stream); return f;
}
static unsigned word (const unsigned char *p, int little)
{ return little ? p[0] | p[1]<<8 : p[0]<<8 | p[1]; }
static unsigned dword (const unsigned char *p, int little)
{ return little ? word (p, 1) | word (p+2, 1)<<16 : word (p, 0)<<16 | word (p+2, 0); }
static int tiff_compression (File f)
{
  if (f.count < 8) return -1;
  int little = f.bytes[0]=='I';
  if ((!little && f.bytes[0]!='M') || f.bytes[1]!=f.bytes[0] || word (f.bytes+2,little)!=42) return -1;
  size_t offset = dword (f.bytes+4,little);
  if (offset > f.count-2) return -1;
  unsigned n = word (f.bytes+offset,little); offset+=2;
  for (unsigned i=0; i<n && offset+12<=f.count; i++,offset+=12)
    if (word (f.bytes+offset,little)==259 && word (f.bytes+offset+2,little)==3 && dword (f.bytes+offset+4,little)==1)
      return (int) word (f.bytes+offset+8,little);
  return -1;
}
typedef struct { int frame, sampling, quantization; } JPEG;
static JPEG jpeg_info (File f)
{
  JPEG info = {-1,-1,-1};
  if (f.count<4 || f.bytes[0]!=255 || f.bytes[1]!=216) return info;
  size_t i=2;
  while (i+4<=f.count && f.bytes[i]==255)
    {
      int marker=f.bytes[i+1]; size_t length=word (f.bytes+i+2,0);
      if (length<2 || i+2+length>f.count || marker==218) break;
      if (marker==219 && length>=67 && f.bytes[i+4]==0) info.quantization=f.bytes[i+5];
      if ((marker==192 || marker==194) && length>=17 && f.bytes[i+9]==3)
        { info.frame=marker; info.sampling=f.bytes[i+11]; }
      i+=2+length;
    }
  return info;
}
static GlimsExportSettings defaults (uint32_t format)
{
  return (GlimsExportSettings) { .struct_size=sizeof (GlimsExportSettings), .format=format,
    .jpeg_quality=.9, .jpeg_progressive=1, .jpeg_optimize=1, .png_compression=9,
    .tiff_preserve_transparent_color=1 };
}
static int export_to (GlimsImageID image, const char *path, GlimsExportSettings *s)
{
  char *error=NULL; GlimsStatus status=api->image_export_configured (engine,image,path,s,&error);
  if (error) { printf ("export: %s\n", error); api->free_string(error); }
  return status==GLIMS_STATUS_OK;
}
static int same_pixels (GlimsImageID image, const GlimsPixelBuffer *before)
{
  GlimsPixelBuffer after={0}; int same=0;
  if (api->image_copy_pixels (engine,image,1,&after,NULL)==GLIMS_STATUS_OK)
    same=before->byte_count==after.byte_count && !memcmp(before->pixels,after.pixels,after.byte_count);
  if (!same) {
    fprintf(stderr,"pixel sizes %zu / %zu\n",(size_t)before->byte_count,(size_t)after.byte_count);
    size_t shown=0;
    for (size_t i=0;i<before->byte_count && i<after.byte_count && shown<12;i++)
      if (before->pixels[i]!=after.pixels[i]) { fprintf(stderr,"byte %zu: %u -> %u\n",i,before->pixels[i],after.pixels[i]);shown++; }
  }
  api->free_pixels(after.pixels); return same;
}
int main (int argc, char **argv)
{
  if (argc!=3) return 2;
  void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
  if (!library) { fprintf(stderr,"%s\n",dlerror()); return 2; }
  GlimsEngineGetAPIFunction get=(GlimsEngineGetAPIFunction)dlsym(library,"glims_engine_get_api");
  api=get?get(GLIMS_ENGINE_API_VERSION):NULL;
  if (!api || api->struct_size<sizeof *api) return 2;
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=argv[2],.cache_directory=argv[2]};
  char *error=NULL;
  if (api->start(&config,&engine,&error)!=GLIMS_STATUS_OK) { fprintf(stderr,"%s\n",error?error:"start failed"); return 1; }
  unsigned char pixels[64*64*4];
  for (int y=0;y<64;y++) for (int x=0;x<64;x++) {
    int i=(y*64+x)*4; pixels[i]=(unsigned char)(x*4); pixels[i+1]=(unsigned char)(y*4);
    pixels[i+2]=(unsigned char)((x*y)%256);pixels[i+3]=255;
  }
  GlimsImageID image=0; GlimsPixelBuffer before={0}; GlimsUndoInfo undo_before={0},undo_after={0};
  GlimsImageInfo image_before={0},image_after={0};
  CHECK(api->image_from_pixels(engine,64,64,pixels,sizeof pixels,&image,NULL)==GLIMS_STATUS_OK,"create export fixture");
  if (!image) goto done;
  CHECK(api->image_copy_pixels(engine,image,1,&before,NULL)==GLIMS_STATUS_OK,"capture source projection");
  api->image_undo_info(engine,image,&undo_before); api->image_info(engine,image,&image_before);
  char path[4096]; snprintf(path,sizeof path,"%s/refused.png",argv[2]);
  GlimsExportSettings s=defaults(GLIMS_EXPORT_PNG),bad=s;
  bad.jpeg_quality=NAN;
  CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"reject nonfinite inactive settings");
  bad=s;bad.png_compression=10;
  CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"reject out-of-range compression");
  bad=s;bad.png_interlaced=2;
  CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"reject non-boolean interlacing");
  bad=s;bad.struct_size=4;error=(char*)1;
  CHECK(api->image_export_configured(engine,image,path,&bad,&error)==GLIMS_STATUS_INVALID_ARGUMENT && !error,"short settings refuse and clear error");
  bad=s;bad.format=GLIMS_EXPORT_JPEG;
  CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"format must match filename");
  CHECK(access(path,F_OK)!=0,"invalid settings do not create a destination");
  bad=s;bad.jpeg_subsampling=UINT32_MAX;
  CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"reject unknown sampling enum");
  bad=s;bad.tiff_compression=UINT32_MAX;
  CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"reject unknown TIFF compression enum");
  CHECK(api->image_export_configured(engine,image,"",&s,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"reject empty destination");
  CHECK(api->image_export_configured(engine,image,path,NULL,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"reject missing settings");
  CHECK(api->image_export_configured(engine,INT32_MAX,path,&s,NULL)==GLIMS_STATUS_NOT_FOUND,"reject stale image");
  FILE *sentinel=fopen(path,"wb");
  if(sentinel) { fwrite("keep",1,4,sentinel);fclose(sentinel); }
  bad=s;bad.png_compression=-1;
  CHECK(api->image_export_configured(engine,image,path,&bad,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,"refuse invalid overwrite settings");
  File saved=read_file(path);
  CHECK(saved.count==4 && !memcmp(saved.bytes,"keep",4),"refused overwrite preserves existing destination");free(saved.bytes);
  snprintf(path,sizeof path,"%s/directory.png",argv[2]);mkdir(path,0700);
  CHECK(api->image_export_configured(engine,image,path,&s,NULL)!=GLIMS_STATUS_OK,"directory destination is refused");
  snprintf(path,sizeof path,"%s/unaligned.PNG",argv[2]);
  unsigned char packed[sizeof s+9];s.struct_size=sizeof s+8;memcpy(packed+1,&s,sizeof s);
  CHECK(export_to(image,path,(GlimsExportSettings*)(packed+1)),"unaligned known prefix and larger future tail are accepted");

  size_t png_sizes[2]={0};
  for (int pass=0;pass<2;pass++) {
    s=defaults(GLIMS_EXPORT_PNG);s.png_compression=pass?9:0;s.png_interlaced=(unsigned)pass;
    snprintf(path,sizeof path,"%s/png-%d.png",argv[2],pass);
    CHECK(export_to(image,path,&s),"configured PNG export succeeds"); File f=read_file(path);png_sizes[pass]=f.count;
    CHECK(f.count>=29 && !memcmp(f.bytes,"\x89PNG\r\n\x1a\n",8) && f.bytes[28]==pass,"PNG IHDR records requested interlacing");free(f.bytes);
    GlimsImageID reopened=0;
    CHECK(api->image_open(engine,path,&reopened,NULL)==GLIMS_STATUS_OK,"configured PNG reopens");
    if(reopened) { CHECK(same_pixels(reopened,&before),"PNG remains lossless"); api->image_close(engine,reopened); }
  }
  CHECK(png_sizes[0]>png_sizes[1] && png_sizes[1]>0,"PNG compression changes encoded size");
  int quant[2]={0};
  for(int pass=0;pass<2;pass++) {
    s=defaults(GLIMS_EXPORT_JPEG);s.jpeg_quality=pass?.95:.1;s.jpeg_progressive=(unsigned)pass;s.jpeg_subsampling=pass?GLIMS_JPEG_FULL:GLIMS_JPEG_BOTH;
    snprintf(path,sizeof path,"%s/jpeg-%d.jpg",argv[2],pass);
    CHECK(export_to(image,path,&s),"configured JPEG export succeeds");File f=read_file(path);JPEG info=jpeg_info(f);quant[pass]=info.quantization;
    CHECK(info.frame==(pass?194:192),"JPEG frame records progressive or baseline encoding");
    CHECK(info.sampling==(pass?0x11:0x22),"JPEG frame records chosen chroma sampling");free(f.bytes);
  }
  CHECK(quant[0]>quant[1] && quant[1]>0,"JPEG quality changes quantization tables");
  const int compression_tags[]={1,5,8,32773};
  for(unsigned c=0;c<4;c++) {
    s=defaults(GLIMS_EXPORT_TIFF);s.tiff_compression=c;
    snprintf(path,sizeof path,"%s/tiff-%u.tif",argv[2],c);
    CHECK(export_to(image,path,&s),"configured TIFF export succeeds");File f=read_file(path);
    CHECK(tiff_compression(f)==compression_tags[c],"TIFF IFD records requested compression");free(f.bytes);
    GlimsImageID reopened=0;
    CHECK(api->image_open(engine,path,&reopened,NULL)==GLIMS_STATUS_OK,"configured TIFF reopens");
    if(reopened) { CHECK(same_pixels(reopened,&before),"TIFF remains lossless"); api->image_close(engine,reopened); }
  }
  CHECK(same_pixels(image,&before),"all exports preserve source pixels");
  api->image_undo_info(engine,image,&undo_after);api->image_info(engine,image,&image_after);
  CHECK(undo_after.undo_count==undo_before.undo_count && undo_after.redo_count==undo_before.redo_count,"all exports preserve Undo/Redo");
  CHECK(image_after.dirty==image_before.dirty,"export does not mark the document saved");
  api->free_pixels(before.pixels);api->image_close(engine,image);

  const unsigned char transparent[] = {200,60,80,0, 20,140,60,32, 100,200,40,128, 10,20,30,255};
  image=0;before=(GlimsPixelBuffer){0};
  CHECK(api->image_from_pixels(engine,4,1,transparent,sizeof transparent,&image,NULL)==GLIMS_STATUS_OK,"create partial-alpha export fixture");
  if (image) {
    CHECK(api->image_copy_pixels(engine,image,0,&before,NULL)==GLIMS_STATUS_OK,"capture straight source color beneath transparency");
    for (unsigned format=GLIMS_EXPORT_PNG;format<=GLIMS_EXPORT_TIFF;format+=2) {
      s=defaults(format);s.png_preserve_transparent_color=1;s.tiff_preserve_transparent_color=1;
      snprintf(path,sizeof path,"%s/transparent.%s",argv[2],format==GLIMS_EXPORT_PNG?"png":"tif");
      CHECK(export_to(image,path,&s),"export with preserved transparent color succeeds");
      GlimsImageID reopened=0;GlimsPixelBuffer actual={0};
      CHECK(api->image_open(engine,path,&reopened,NULL)==GLIMS_STATUS_OK,"transparent export reopens");
      if(reopened) {
        CHECK(api->image_copy_pixels(engine,reopened,0,&actual,NULL)==GLIMS_STATUS_OK &&
              actual.byte_count==before.byte_count && !memcmp(actual.pixels,before.pixels,before.byte_count),
              "straight RGB and alpha survive including completely transparent color");
        api->free_pixels(actual.pixels);api->image_close(engine,reopened);
      }
    }
    api->free_pixels(before.pixels);api->image_close(engine,image);
  }
done:
  api->stop(engine);printf("%d checks, %d failure(s)\n",checks,failures);return failures?1:0;
}

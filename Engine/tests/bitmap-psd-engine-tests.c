#define _POSIX_C_SOURCE 200809L
#include "glims_engine.h"
#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int failures, checks;
#define CHECK(c, text) do { int ok = !!(c); checks++; failures += !ok; \
  printf("%s %s\n", ok ? "ok" : "FAIL", text); fflush(stdout); } while (0)

static int write_bytes(const char *path, const void *bytes, size_t count)
{
  FILE *f = fopen(path, "wb"); if (!f) return 0;
  int ok = fwrite(bytes, 1, count, f) == count;
  return fclose(f) == 0 && ok;
}
static int has_bytes(const char *path, const void *bytes, size_t count)
{
  unsigned char data[64]; FILE *f = fopen(path, "rb"); if (!f) return 0;
  size_t n = fread(data, 1, sizeof data, f); int ok = !ferror(f) && n == count && !memcmp(data, bytes, count);
  fclose(f); return ok;
}
typedef unsigned int (*IdleAdd)(int (*callback)(void *), void *data);
typedef struct {
  const GlimsEngineAPI *api;
  GlimsEngine *engine;
  IdleAdd idle_add;
  int armed, scheduled, cancelled;
} CancelFixture;
static int cancel_idle(void *data)
{
  CancelFixture *f = data;
  f->cancelled = f->api->procedure_cancel(f->engine) == GLIMS_STATUS_OK;
  return 0;
}
static void on_event(void *data, const GlimsEvent *event)
{
  CancelFixture *f = data;
  if (f->armed && !f->scheduled && event->kind == GLIMS_EVENT_PROGRESS &&
      event->active && event->value >= 1.0) {
    f->scheduled = f->idle_add(cancel_idle, f) != 0;
  }
}
static int packed_byte(const char *path, unsigned char value)
{
  FILE *f=fopen(path,"rb"); if (!f) return 0;
  unsigned char bytes[42]; size_t n=fread(bytes,1,sizeof bytes,f);
  int ok=!ferror(f) && n==41 && bytes[23]==1 && bytes[25]==0 && bytes[40]==value;
  fclose(f); return ok;
}
static void free_error(const GlimsEngineAPI *api, char **error)
{
  if (*error) api->free_string(*error);
  *error = NULL;
}
int main(int argc, char **argv)
{
  if (argc != 3) { fprintf(stderr, "usage: %s ADAPTER WORK\n", argv[0]); return 2; }
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf(stderr, "%s\n", dlerror()); return 2; }
  GlimsEngineGetAPIFunction get_api = (GlimsEngineGetAPIFunction) dlsym(library, "glims_engine_get_api");
  const GlimsEngineAPI *api = get_api ? get_api(GLIMS_ENGINE_API_VERSION) : NULL;
  if (!api || api->struct_size < offsetof(GlimsEngineAPI, image_export_bitmap_psd) + sizeof api->image_export_bitmap_psd || !api->image_export_bitmap_psd ||
      api->struct_size < offsetof(GlimsEngineAPI, image_export_bitmap_threshold_psd) + sizeof api->image_export_bitmap_threshold_psd || !api->image_export_bitmap_threshold_psd) return 2;
  char user[1024], cache[1024], input[1024], nonbinary[1024], single[1024], ramp[1024], ramp16[1024], output[1024];
  snprintf(user,sizeof user,"%s/user",argv[2]); snprintf(cache,sizeof cache,"%s/cache",argv[2]);
  snprintf(input,sizeof input,"%s/input.pgm",argv[2]); snprintf(nonbinary,sizeof nonbinary,"%s/gray.pgm",argv[2]);
  snprintf(output,sizeof output,"%s/output.psd",argv[2]); snprintf(single,sizeof single,"%s/single.pgm",argv[2]);
  snprintf(ramp,sizeof ramp,"%s/ramp.pgm",argv[2]); snprintf(ramp16,sizeof ramp16,"%s/ramp16.pgm",argv[2]);
  static const unsigned char pgm[] = "P5\n9 2\n255\n"
    "\000\377\000\377\000\377\000\377\000"
    "\377\000\377\000\377\000\377\000\377";
  static const unsigned char gray[] = "P5\n1 1\n255\n\200";
  static const unsigned char white[] = "P5\n1 1\n255\n\377";
  static const unsigned char ramp_bytes[] = "P5\n5 1\n255\n\000\100\177\200\377";
  static const unsigned char ramp16_bytes[] = "P5\n5 1\n65535\n\000\000\100\100\177\377\200\000\377\377";
  static const unsigned char psd[] = {
    '8','B','P','S',0,1, 0,0,0,0,0,0, 0,1, 0,0,0,2, 0,0,0,9, 0,1, 0,0,
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0, 0xaa,0x80,0x55,0x00
  };
  if (!write_bytes(input,pgm,sizeof pgm-1) || !write_bytes(nonbinary,gray,sizeof gray-1) || !write_bytes(single,white,sizeof white-1) || !write_bytes(ramp,ramp_bytes,sizeof ramp_bytes-1) || !write_bytes(ramp16,ramp16_bytes,sizeof ramp16_bytes-1)) return 2;
  CancelFixture cancel = { .api=api, .idle_add=(IdleAdd)dlsym(library,"g_idle_add") };
  if (!cancel.idle_add) { fprintf(stderr,"missing g_idle_add in adapter dependencies\n"); return 2; }
  GlimsEngineConfig config = { .struct_size=sizeof config, .user_directory=user, .cache_directory=cache,
                               .event_context=&cancel, .on_event=on_event };
  GlimsEngine *engine = NULL; char *error = NULL;
  GlimsStatus status = api->start(&config,&engine,&error);
  CHECK(status == GLIMS_STATUS_OK && engine, "engine starts");
  if (!engine) { if(error) fprintf(stderr,"%s\n",error); free_error(api,&error); return 1; }
  free_error(api,&error);
  cancel.engine = engine;
  GlimsImageID image = 0, reopened = 0, bad = 0;
  status=api->image_open(engine,input,&image,&error);
  CHECK(status==GLIMS_STATUS_OK && image, "open binary grayscale fixture");
  if (error) fprintf(stderr,"open: %s\n",error); free_error(api,&error);
  if (image) {
    GlimsImageInfo before={0},after={0}; GlimsUndoInfo undo_before={0},undo_after={0};
    CHECK(api->image_info(engine,image,&before)==GLIMS_STATUS_OK && api->image_undo_info(engine,image,&undo_before)==GLIMS_STATUS_OK, "capture source state");
    status=api->image_export_bitmap_psd(engine,image,output,&error);
    CHECK(status==GLIMS_STATUS_OK && has_bytes(output,psd,sizeof psd), "export writes literal one-bit Bitmap PSD pixels");
    if(error) fprintf(stderr,"export: %s\n",error); free_error(api,&error);
    CHECK(api->image_info(engine,image,&after)==GLIMS_STATUS_OK && api->image_undo_info(engine,image,&undo_after)==GLIMS_STATUS_OK && before.dirty==after.dirty && undo_before.undo_count==undo_after.undo_count && undo_before.redo_count==undo_after.redo_count, "export leaves source dirty state and history unchanged");
    status=api->image_open(engine,output,&reopened,&error);
    CHECK(status==GLIMS_STATUS_OK && reopened, "GIMP opens the exported Bitmap PSD");
    if(error) fprintf(stderr,"reopen: %s\n",error); free_error(api,&error);
    if(reopened) {
      unsigned char pixels[9*2*4]={0};
      CHECK(api->image_render(engine,reopened,1.0,(GlimsRect){0,0,9,2},pixels,9*4)==GLIMS_STATUS_OK && pixels[0]==0 && pixels[4]==255 && pixels[9*4]==255 && pixels[10*4]==0, "GIMP round trip retains black and white pixels");
      CHECK(api->image_export_bitmap_psd(engine,reopened,output,&error)==GLIMS_STATUS_OK && has_bytes(output,psd,sizeof psd), "indexed Bitmap import re-exports with Bitmap mode"); free_error(api,&error);
      api->image_close(engine,reopened);
    }
    GlimsItemID link = 0;
    status=api->image_place_link(engine,image,input,&link,&error);
    free_error(api,&error);
    if (status==GLIMS_STATUS_OK && link) {
      static const char link_sentinel[]="before-link";
      if (!write_bytes(output,link_sentinel,sizeof link_sentinel-1)) return 2;
      status=api->image_export_bitmap_psd(engine,image,output,&error);
      CHECK(status==GLIMS_STATUS_UNSUPPORTED && has_bytes(output,link_sentinel,sizeof link_sentinel-1),
            "linked-layer source refuses before replacing destination");
      free_error(api,&error);
      GlimsLayerChange hidden={.struct_size=sizeof hidden,.properties=GLIMS_LAYER_VISIBLE,.visible=false};
      CHECK(api->layer_change(engine,image,link,&hidden,&error)==GLIMS_STATUS_OK, "hide the linked layer"); free_error(api,&error);
      status=api->image_export_bitmap_psd(engine,image,output,&error);
      CHECK(status==GLIMS_STATUS_UNSUPPORTED && has_bytes(output,link_sentinel,sizeof link_sentinel-1),
            "hidden linked layer still refuses safely"); free_error(api,&error);
      CHECK(api->layer_command(engine,image,link,GLIMS_LAYER_RASTERIZE,NULL,&error)==GLIMS_STATUS_OK,
            "rasterize linked test layer"); free_error(api,&error);
      status=api->image_export_bitmap_psd(engine,image,output,&error);
      CHECK(status==GLIMS_STATUS_UNSUPPORTED && has_bytes(output,link_sentinel,sizeof link_sentinel-1),
            "retained rasterized link still refuses safely"); free_error(api,&error);
      CHECK(api->image_undo(engine,image)==GLIMS_STATUS_OK && api->image_undo(engine,image)==GLIMS_STATUS_OK &&
            api->image_undo(engine,image)==GLIMS_STATUS_OK, "remove linked test layer and changes with Undo");
    } else {
      CHECK(status==GLIMS_STATUS_UNSUPPORTED, "engine without linked layers explicitly refuses placement");
      CHECK(link==0, "unavailable linked-layer placement creates no layer");
    }
    static const char cancellation_sentinel[]="before-cancel";
    if (!write_bytes(output,cancellation_sentinel,sizeof cancellation_sentinel-1)) return 2;
    cancel.armed=1;
    status=api->image_export_bitmap_psd(engine,image,output,&error);
    cancel.armed=0;
    CHECK(cancel.scheduled && cancel.cancelled && status==GLIMS_STATUS_CANCELLED &&
          has_bytes(output,cancellation_sentinel,sizeof cancellation_sentinel-1),
          "engine cancellation at completed pixels preserves destination");
    free_error(api,&error);
    GlimsLayerInfo layer; int32_t count=0;
    if(api->image_layers(engine,image,&layer,1,&count)==GLIMS_STATUS_OK && count>0) {
      GlimsLayerChange change={.struct_size=sizeof change,.properties=GLIMS_LAYER_OPACITY,.opacity=0.5};
      CHECK(api->layer_change(engine,image,layer.id,&change,&error)==GLIMS_STATUS_OK, "make a partially transparent source"); free_error(api,&error);
      static const char sentinel[]="existing"; write_bytes(output,sentinel,sizeof sentinel-1);
      status=api->image_export_bitmap_psd(engine,image,output,&error);
      CHECK(status!=GLIMS_STATUS_OK && has_bytes(output,sentinel,sizeof sentinel-1), "transparency refuses and preserves existing destination"); free_error(api,&error);
    } else CHECK(0,"find fixture layer");
    api->image_close(engine,image);
  }
  status=api->image_open(engine,nonbinary,&bad,&error);
  CHECK(status==GLIMS_STATUS_OK && bad, "open intermediate-gray fixture"); free_error(api,&error);
  if(bad) {
    static const char sentinel[]="existing"; write_bytes(output,sentinel,sizeof sentinel-1);
    status=api->image_export_bitmap_psd(engine,bad,output,&error);
    CHECK(status!=GLIMS_STATUS_OK && has_bytes(output,sentinel,sizeof sentinel-1), "intermediate gray refuses and preserves destination"); free_error(api,&error);
    api->image_close(engine,bad);
  }
  GlimsImageID shades=0;
  status=api->image_open(engine,ramp,&shades,&error);
  CHECK(status==GLIMS_STATUS_OK && shades, "open grayscale threshold ramp"); free_error(api,&error);
  if(shades) {
    GlimsUndoInfo before={0},after={0};
    api->image_undo_info(engine,shades,&before);
    status=api->image_export_bitmap_threshold_psd(engine,shades,output,127,&error);
    CHECK(status==GLIMS_STATUS_OK && packed_byte(output,0xe0), "threshold 127 includes 127 as black and maps 128 white"); free_error(api,&error);
    status=api->image_export_bitmap_threshold_psd(engine,shades,output,128,&error);
    CHECK(status==GLIMS_STATUS_OK && packed_byte(output,0xf0), "threshold 128 maps its boundary to black"); free_error(api,&error);
    status=api->image_export_bitmap_threshold_psd(engine,shades,output,0,&error);
    CHECK(status==GLIMS_STATUS_OK && packed_byte(output,0x80), "threshold zero leaves only zero black"); free_error(api,&error);
    status=api->image_export_bitmap_threshold_psd(engine,shades,output,255,&error);
    CHECK(status==GLIMS_STATUS_OK && packed_byte(output,0xf8), "threshold 255 maps all samples black"); free_error(api,&error);
    static const char sentinel[]="threshold-original"; write_bytes(output,sentinel,sizeof sentinel-1);
    status=api->image_export_bitmap_threshold_psd(engine,shades,output,256,&error);
    CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT && has_bytes(output,sentinel,sizeof sentinel-1), "out-of-range threshold refuses before replacing destination"); free_error(api,&error);
    CHECK(api->image_undo_info(engine,shades,&after)==GLIMS_STATUS_OK && before.undo_count==after.undo_count && before.redo_count==after.redo_count,
          "threshold export leaves Undo and Redo unchanged");
    cancel.scheduled=cancel.cancelled=0; cancel.armed=1;
    status=api->image_export_bitmap_threshold_psd(engine,shades,output,127,&error);
    cancel.armed=0;
    CHECK(cancel.scheduled && cancel.cancelled && status==GLIMS_STATUS_CANCELLED &&
          has_bytes(output,sentinel,sizeof sentinel-1), "threshold cancellation preserves destination");
    free_error(api,&error);
    GlimsLayerInfo layer; int32_t count=0;
    if(api->image_layers(engine,shades,&layer,1,&count)==GLIMS_STATUS_OK && count>0) {
      GlimsLayerChange change={.struct_size=sizeof change,.properties=GLIMS_LAYER_OPACITY,.opacity=0.5};
      CHECK(api->layer_change(engine,shades,layer.id,&change,&error)==GLIMS_STATUS_OK, "make threshold fixture transparent"); free_error(api,&error);
      status=api->image_export_bitmap_threshold_psd(engine,shades,output,127,&error);
      CHECK(status!=GLIMS_STATUS_OK && has_bytes(output,sentinel,sizeof sentinel-1), "threshold export refuses transparency without replacing destination"); free_error(api,&error);
    } else CHECK(0,"find threshold fixture layer");
    api->image_close(engine,shades);
  }
  GlimsImageID shades16=0;
  status=api->image_open(engine,ramp16,&shades16,&error);
  CHECK(status==GLIMS_STATUS_OK && shades16, "open 16-bit grayscale threshold ramp"); free_error(api,&error);
  if(shades16) {
    GlimsImageInfo info={0};
    CHECK(api->image_info(engine,shades16,&info)==GLIMS_STATUS_OK && strstr(info.precision,"u16")!=NULL,
          "threshold ramp remains a 16-bit image");
    status=api->image_export_bitmap_threshold_psd(engine,shades16,output,127,&error);
    CHECK(status==GLIMS_STATUS_OK && packed_byte(output,0xe0), "16-bit threshold rounds grayscale before the cutoff"); free_error(api,&error);
    status=api->image_export_bitmap_threshold_psd(engine,shades16,output,128,&error);
    CHECK(status==GLIMS_STATUS_OK && packed_byte(output,0xf0), "16-bit threshold honors its inclusive boundary"); free_error(api,&error);
    api->image_close(engine,shades16);
  }
  GlimsImageID one=0, rgb=0;
  status=api->image_open(engine,single,&one,&error);
  CHECK(status==GLIMS_STATUS_OK && one, "open one-pixel white fixture"); free_error(api,&error);
  if (one) {
    unsigned char expected[41]={ '8','B','P','S',0,1 };
    expected[13]=1; expected[17]=1; expected[21]=1; expected[23]=1;
    status=api->image_export_bitmap_psd(engine,one,output,&error);
    CHECK(status==GLIMS_STATUS_OK && has_bytes(output,expected,sizeof expected), "one-pixel projection exports fresh white with zero padding"); free_error(api,&error);
    api->image_close(engine,one);
  }
  status=api->image_new(engine,1,1,&rgb,&error);
  CHECK(status==GLIMS_STATUS_OK && rgb, "create ordinary RGB source"); free_error(api,&error);
  if (rgb) {
    static const char sentinel[]="existing"; write_bytes(output,sentinel,sizeof sentinel-1);
    status=api->image_export_bitmap_psd(engine,rgb,output,&error);
    CHECK(status==GLIMS_STATUS_UNSUPPORTED && has_bytes(output,sentinel,sizeof sentinel-1), "RGB source refuses without replacing destination"); free_error(api,&error);
    api->image_close(engine,rgb);
  }
  api->stop(engine); dlclose(library);
  printf("%d checks, %d failures\n",checks,failures);
  return failures ? 1 : 0;
}

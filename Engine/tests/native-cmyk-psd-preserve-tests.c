/* Independent slot198 acceptance. The PSD producer below writes literal
 * big-endian fields and planes; it never calls Glims's PSD codec or reader.
 * Private engine callbacks only observe storage/lifetime. All document writes
 * and import/save/close operations use the public facade. */
#include "engine-private.h"
#include "plate-storage.h"
#include "core/gimp.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimpobject.h"
#include <lcms2.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static unsigned checks, failures;
#define CHECK(c, text) do { gboolean pass = !!(c); checks++; \
  printf("%s %s\n", pass ? "ok" : "FAIL", text); \
  if (!pass) failures++; fflush(stdout); } while (0)

typedef struct {
  guint width, height, depth;
  GByteArray *bytes;
  gsize icc_offset, pixel_offset, layer_offset, compression_offset;
} Literal;
typedef struct { guint published, native; } Counts;
typedef struct {
  GlimsImageID id;
  const Literal *literal;
  const guint8 *icc;
  gsize icc_size;
  const char *imported, *native;
  GBytes *raw[4], *map, *profile;
  guint8 uuid[4][16];
  GlimsItemID ids[4];
  gboolean valid, source_identity, visible;
} Capture;
typedef struct {
  GlimsEngine *engine;
  const char *path;
  gint armed, paused, release, timed_out, idle;
  GlimsStatus status;
  GlimsImageID result;
  char *error;
} Control;

static void put16 (guint8 *p, guint v) { p[0] = (guint8) (v >> 8); p[1] = (guint8) v; }
static void put32 (guint8 *p, guint32 v) {
  p[0]=(guint8)(v>>24); p[1]=(guint8)(v>>16); p[2]=(guint8)(v>>8); p[3]=(guint8)v;
}
static void append16 (GByteArray *a, guint v) { guint8 b[2]; put16(b,v); g_byte_array_append(a,b,2); }
static void append32 (GByteArray *a, guint32 v) { guint8 b[4]; put32(b,v); g_byte_array_append(a,b,4); }

static guint16
sample (guint depth, guint channel, guint x, guint y)
{
  static const guint8 bytes[] = { 0,255,1,254,128,127,2,253,17,240,85,170,3,252,64,192 };
  static const guint16 words[] = { 0,65535,1,0x0102,0x00ff,0xff00,0x8000,0x7fff,
                                 0x1234,0xabcd,0x5555,0xaaaa,2,65534,0x0080,0x8001 };
  guint index = (x + y * 7 + channel * 3 + x / 4096) % G_N_ELEMENTS (words);
  return depth == 8 ? bytes[index] : words[index];
}

static Literal
literal_psd (guint width, guint height, guint depth, const guint8 *icc, gsize icc_size)
{
  Literal f = { .width=width, .height=height, .depth=depth, .bytes=g_byte_array_new() };
  guint8 header[26] = { '8','B','P','S',0,1,0,0,0,0,0,0,0,4 };
  put32(header+14,height); put32(header+18,width); put16(header+22,depth); put16(header+24,4);
  g_byte_array_append(f.bytes,header,sizeof header);
  append32(f.bytes,0); /* Color-mode data. */
  /* Six signature/ID bytes, four Pascal-name bytes, four size bytes. The
   * two-character name requires a present, deliberately nonzero padding byte. */
  append32(f.bytes,(guint32)(14 + icc_size + (icc_size & 1)));
  g_byte_array_append(f.bytes,(const guint8 *)"8BIM",4); append16(f.bytes,1039);
  const guint8 name[] = {2,'i','c',0xa5}; g_byte_array_append(f.bytes,name,sizeof name);
  append32(f.bytes,(guint32)icc_size); f.icc_offset=f.bytes->len;
  g_byte_array_append(f.bytes,icc,(guint)icc_size);
  if(icc_size&1){const guint8 pad=0x7e;g_byte_array_append(f.bytes,&pad,1);}
  f.layer_offset=f.bytes->len; append32(f.bytes,0);
  f.compression_offset=f.bytes->len; append16(f.bytes,0); f.pixel_offset=f.bytes->len;
  for(guint c=0;c<4;c++) for(guint y=0;y<height;y++) for(guint x=0;x<width;x++) {
    guint16 value=sample(depth,c,x,y);
    if(depth==8){guint8 b=(guint8)value;g_byte_array_append(f.bytes,&b,1);}
    else append16(f.bytes,value);
  }
  return f;
}

static gboolean file_equals (const char *path, const GByteArray *expected) {
  gchar *bytes=NULL;gsize n=0;
  gboolean same=g_file_get_contents(path,&bytes,&n,NULL)&&n==expected->len&&
                !memcmp(bytes,expected->data,n);
  g_free(bytes);return same;
}
static void free_error (char **error) {
  if(*error && *error!=(char *)1) api->free_string(*error);
  *error=NULL;
}
static GlimsStatus counts_on_engine (GlimsEngine *e,gpointer data) {
  Counts *c=data;c->published=g_hash_table_size(e->images);
  c->native=g_list_length(gimp_get_image_iter(e->gimp));return GLIMS_STATUS_OK;
}
static Counts counts_of (GlimsEngine *e) {
  Counts c={0};CHECK(glims_engine_call(e,counts_on_engine,&c)==GLIMS_STATUS_OK,"inspect public/native image ownership");return c;
}
static gboolean counts_equal (Counts a,Counts b) {return a.published==b.published&&a.native==b.native;}
static void clear_capture (Capture *c) {
  for(guint i=0;i<4;i++)g_clear_pointer(&c->raw[i],g_bytes_unref);
  g_clear_pointer(&c->map,g_bytes_unref);g_clear_pointer(&c->profile,g_bytes_unref);
}
static gboolean path_equals (GFile *file,const char *path) {
  if(!file||!path)return FALSE;
  GFile *expected=g_file_new_for_path(path);gboolean same=g_file_equal(file,expected);
  g_object_unref(expected);return same;
}
static GlimsStatus capture_on_engine (GlimsEngine *e,gpointer data) {
  Capture *c=data;GlimsOpenImage *open=glims_lookup_image(e,c->id);GlimsPlateStorage s;
  if(!open||!glims_plate_storage_read_open(open,&s)||s.map.mode!=GLIMS_PLATE_MODE_CMYK||
     s.map.count!=4||s.map.width!=c->literal->width||s.map.height!=c->literal->height||
     s.map.storage!=(c->literal->depth==8?GLIMS_PLATE_STORAGE_U8:GLIMS_PLATE_STORAGE_U16)||
     s.map.encoding!=GLIMS_PLATE_ENCODING_INTENSITY)return GLIMS_STATUS_FAILED;
  const GimpParasite *map=gimp_image_parasite_find(open->image,GLIMS_PLATE_MAP_PARASITE);
  guint32 map_size=0;const guint8 *map_data=map?gimp_parasite_get_data(map,&map_size):NULL;
  if(!map_data||!map_size||!s.profile)return GLIMS_STATUS_FAILED;
  c->map=g_bytes_new(map_data,map_size);c->profile=g_bytes_new(s.profile,s.profile_size);
  c->valid=s.profile_size==c->icc_size&&!memcmp(s.profile,c->icc,c->icc_size);
  c->visible=TRUE;
  gsize size=(gsize)c->literal->width*c->literal->height*(c->literal->depth/8);
  const Babl *format=babl_format(c->literal->depth==8?"Y u8":"Y u16");
  for(guint i=0;i<4;i++) {
    GimpDrawable *d=GIMP_DRAWABLE(s.planes[i]);
    if(gimp_drawable_get_format(d)!=format)return GLIMS_STATUS_FAILED;
    gpointer raw=g_malloc(size);
    gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,c->literal->width,c->literal->height),
                    1,format,raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    c->raw[i]=g_bytes_new_take(raw,size);memcpy(c->uuid[i],s.map.entries[i].uuid,16);
    c->ids[i]=gimp_item_get_id(GIMP_ITEM(d));c->visible=c->visible&&s.visible[i];
  }
  if(c->imported)c->source_identity=path_equals(gimp_image_get_imported_file(open->image),c->imported)&&
    !gimp_image_get_file(open->image)&&!gimp_image_get_exported_file(open->image);
  else if(c->native)c->source_identity=path_equals(gimp_image_get_file(open->image),c->native)&&
    !gimp_image_get_exported_file(open->image);
  return GLIMS_STATUS_OK;
}
static gboolean exact_samples (const Capture *cap) {
  for(guint c=0;c<4;c++) {
    gsize size=0;const guint8 *raw=g_bytes_get_data(cap->raw[c],&size);
    if(size!=(gsize)cap->literal->width*cap->literal->height*(cap->literal->depth/8))return FALSE;
    for(guint y=0;y<cap->literal->height;y++)for(guint x=0;x<cap->literal->width;x++) {
      gsize i=(gsize)y*cap->literal->width+x;guint16 actual;
      if(cap->literal->depth==8)actual=raw[i];else memcpy(&actual,raw+i*2,2);
      guint16 expected=sample(cap->literal->depth,c,x,y);
      if(actual!=expected){printf("INFO raw mismatch c%u (%u,%u) expected%u actual%u\n",c,x,y,expected,actual);return FALSE;}
    }
  }
  return TRUE;
}
static gboolean persistent_equal (const Capture *a,const Capture *b) {
  if(!g_bytes_equal(a->map,b->map)||!g_bytes_equal(a->profile,b->profile)||
     memcmp(a->uuid,b->uuid,sizeof a->uuid))return FALSE;
  for(guint c=0;c<4;c++)if(!g_bytes_equal(a->raw[c],b->raw[c]))return FALSE;
  return TRUE;
}

static void verify_facade (GlimsEngine *e,Capture *c) {
  GlimsColorInfo color={0};GlimsComponentState components={0};GlimsImageInfo image={0};GlimsUndoInfo undo={0};
  CHECK(api->image_info(e,c->id,&image)==GLIMS_STATUS_OK&&image.width==(gint)c->literal->width&&
    image.height==(gint)c->literal->height&&image.layer_count==0&&!image.dirty,"import is full-size layerless clean native storage");
  CHECK(api->image_color_info(e,c->id,&color)==GLIMS_STATUS_OK&&color.mode==GLIMS_COLOR_MODE_CMYK&&
    color.component==(c->literal->depth==8?GLIMS_COLOR_COMPONENT_U8:GLIMS_COLOR_COMPONENT_U16)&&
    color.profile_embedded&&color.profile_label[0],"facade exposes exact integer CMYK precision and embedded profile");
  CHECK(api->image_components(e,c->id,&components)==GLIMS_STATUS_OK&&components.mode==GLIMS_COMPONENT_MODE_CMYK,"component mode remains CMYK");
  CHECK(api->image_undo_info(e,c->id,&undo)==GLIMS_STATUS_OK&&!undo.undo_count&&!undo.redo_count,"newly imported/reopened image has empty Undo and Redo");
  bool empty=false;GlimsRect bounds={0};
  CHECK(api->selection_bounds(e,c->id,&empty,&bounds)==GLIMS_STATUS_OK&&empty,"root selection is empty");
  GlimsChannelInfo channels[4]={0};gint32 count=0;const char *names[]={"Cyan","Magenta","Yellow","Black"};
  CHECK(api->image_channels(e,c->id,channels,4,&count)==GLIMS_STATUS_OK&&count==4,"four authoritative channels are visible to facade");
  if(count!=4)return;
  for(guint i=0;i<4;i++) {
    GlimsInkChannelIdentity identity={.struct_size=sizeof identity};
    CHECK(channels[i].id==c->ids[i]&&!strcmp(channels[i].name,names[i])&&channels[i].selected==(i==0),"canonical C/M/Y/K names and sole Cyan selection");
    CHECK(api->image_ink_channel_identity(e,c->id,channels[i].id,&identity)==GLIMS_STATUS_OK&&
      identity.color_mode==GLIMS_COLOR_MODE_CMYK&&identity.role==i+1&&identity.ordinal==i&&identity.count==4&&
      !memcmp(identity.uuid,c->uuid[i],16),"facade process role and durable identity match actual plane");
    guint8 zero[16]={0};CHECK(memcmp(identity.uuid,zero,16)!=0,"plane UUID is nonzero");
    for(guint j=0;j<i;j++)CHECK(memcmp(c->uuid[i],c->uuid[j],16)!=0,"plane UUIDs are distinct within document");
  }
}

static void preview_oracle (GlimsEngine *e,const Capture *c) {
  cmsHPROFILE source=cmsOpenProfileFromMem(c->icc,(cmsUInt32Number)c->icc_size);
  cmsHPROFILE target=cmsCreate_sRGBProfile();
  cmsHTRANSFORM transform=source&&target?cmsCreateTransform(source,TYPE_CMYK_DBL,target,TYPE_RGB_DBL,
    INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_BLACKPOINTCOMPENSATION|cmsFLAGS_NOCACHE):NULL;
  CHECK(transform!=NULL,"independent LCMS double-precision preview oracle exists");
  if(transform) {
    gsize pixels=(gsize)c->literal->width*c->literal->height;guint8 *rgba=g_malloc(pixels*4);
    GlimsStatus status=api->image_render(e,c->id,1,(GlimsRect){0,0,c->literal->width,c->literal->height},rgba,c->literal->width*4);
    CHECK(status==GLIMS_STATUS_OK,"imported native CMYK renders");
    if(status==GLIMS_STATUS_OK) {
      guint maximum=0;gboolean finite=TRUE,opaque=TRUE;
      for(guint y=0;y<c->literal->height;y++)for(guint x=0;x<c->literal->width;x++) {
        double ink[4],rgb[3];gsize p=(gsize)y*c->literal->width+x;
        for(guint i=0;i<4;i++)ink[i]=100*(1-sample(c->literal->depth,i,x,y)/(c->literal->depth==8?255.0:65535.0));
        cmsDoTransform(transform,ink,rgb,1);opaque=opaque&&rgba[p*4+3]==255;
        for(guint i=0;i<3;i++) {
          if(!isfinite(rgb[i])){finite=FALSE;continue;}
          long value=lrint(fmax(0,fmin(1,rgb[i]))*255);
          guint error=(guint)abs((int)value-(int)rgba[p*4+i]);if(error>maximum)maximum=error;
        }
      }
      printf("INFO preview maximum absolute error %u U8 levels\n",maximum);
      CHECK(finite&&opaque&&maximum<=2,"opaque appearance matches independent relative+BPC oracle within fixed two levels");
    }
    g_free(rgba);cmsDeleteTransform(transform);
  }
  if(source)cmsCloseProfile(source);if(target)cmsCloseProfile(target);
}

static void run_valid (GlimsEngine *e,const char *work,const guint8 *icc,gsize icc_size,
                       guint width,guint height,guint depth) {
  printf("INFO literal %ux%u depth%u\n",width,height,depth);
  Literal f=literal_psd(width,height,depth,icc,icc_size);
  gchar *path=g_strdup_printf("%s/literal-%u-%u-%u.psd",work,width,height,depth);
  gchar *xcf=g_strdup_printf("%s/literal-%u-%u-%u.xcf",work,width,height,depth);
  Counts before=counts_of(e);char *error=NULL;GlimsImageID id=0,second=0,reopened=0;
  Capture first={.literal=&f,.icc=icc,.icc_size=icc_size,.imported=path};
  Capture other={.literal=&f,.icc=icc,.icc_size=icc_size,.imported=path};
  Capture saved={.literal=&f,.icc=icc,.icc_size=icc_size,.native=xcf};
  CHECK(g_file_set_contents(path,(const gchar *)f.bytes->data,f.bytes->len,NULL),"write independent literal PSD fixture");
  GlimsStatus status=api->image_import_native_cmyk_psd(e,path,&id,&error);
  if(error)printf("INFO import status%d %s\n",status,error);
  CHECK(status==GLIMS_STATUS_OK&&id!=0,"explicit preserving import succeeds");free_error(&error);
  if(!id)goto cleanup;
  first.id=id;
  gboolean captured=glims_engine_call(e,capture_on_engine,&first)==GLIMS_STATUS_OK;
  CHECK(captured,"inspect authoritative raw storage without conversion");if(!captured)goto cleanup;
  CHECK(first.valid&&first.visible&&first.source_identity,"exact source ICC, all ink visibility and imported-only file identity");
  CHECK(exact_samples(&first),"every native raw sample equals independent literal expectation");
  verify_facade(e,&first);
  if(width==7)preview_oracle(e,&first);
  status=api->image_import_native_cmyk_psd(e,path,&second,&error);free_error(&error);
  CHECK(status==GLIMS_STATUS_OK&&second&&second!=id,"a second import has a separate image handle");
  if(second) {
    other.id=second;gboolean ok=glims_engine_call(e,capture_on_engine,&other)==GLIMS_STATUS_OK;
    CHECK(ok,"read second import identities");
    if(ok)for(guint i=0;i<4;i++)for(guint j=0;j<4;j++)
      CHECK(memcmp(first.uuid[i],other.uuid[j],16)!=0,"UUID never equates distinct imported documents");
    CHECK(api->image_close(e,second)==GLIMS_STATUS_OK,"close second import");second=0;
  }
  status=api->image_save(e,id,xcf,&error);
  if(error)printf("INFO XCF save status%d %s\n",status,error);
  CHECK(status==GLIMS_STATUS_OK,"save preserving import as native XCF");free_error(&error);
  if(status!=GLIMS_STATUS_OK)goto cleanup;
  CHECK(api->image_close(e,id)==GLIMS_STATUS_OK,"close source before reading XCF");id=0;
  status=api->image_open(e,xcf,&reopened,&error);free_error(&error);
  CHECK(status==GLIMS_STATUS_OK&&reopened,"reopen mapped XCF through ordinary native open");
  if(reopened) {
    saved.id=reopened;gboolean ok=glims_engine_call(e,capture_on_engine,&saved)==GLIMS_STATUS_OK;
    CHECK(ok,"reopened XCF still has native CMYK storage");
    if(ok) {
      CHECK(saved.valid&&saved.visible&&saved.source_identity&&exact_samples(&saved),"XCF retains source ICC, raw samples and native saved identity");
      CHECK(persistent_equal(&first,&saved),"XCF preserves exact plane/map/profile bytes and UUIDs");
      for(guint i=0;i<4;i++)CHECK(first.ids[i]!=saved.ids[i],"reopened planes have new runtime handles");
      verify_facade(e,&saved);
    }
  }
cleanup:
  if(id)CHECK(api->image_close(e,id)==GLIMS_STATUS_OK,"close owned import");
  if(second)CHECK(api->image_close(e,second)==GLIMS_STATUS_OK,"close owned second import");
  if(reopened)CHECK(api->image_close(e,reopened)==GLIMS_STATUS_OK,"close owned reopened XCF");
  free_error(&error);clear_capture(&first);clear_capture(&other);clear_capture(&saved);
  CHECK(counts_equal(before,counts_of(e)),"valid case releases all public and native images");
  CHECK(file_equals(path,f.bytes),"import/save/reopen never changes original PSD bytes");
  g_byte_array_unref(f.bytes);g_free(path);g_free(xcf);
}

static void refuse (GlimsEngine *e,const char *path,GByteArray *bytes,GlimsStatus expected,const char *name) {
  printf("INFO refusal %s\n",name);Counts before=counts_of(e);
  CHECK(g_file_set_contents(path,(const gchar *)bytes->data,bytes->len,NULL),"write refusal fixture");
  GlimsImageID id=12345;char *error=(char *)1;
  GlimsStatus status=api->image_import_native_cmyk_psd(e,path,&id,&error);
  if(error&&error!=(char *)1)printf("INFO refusal status%d %s\n",status,error);
  CHECK(status!=GLIMS_STATUS_OK&&(expected==GLIMS_STATUS_OK||status==expected),"input refuses with promised status and no RGB fallback");
  CHECK(id==0&&error!=(char *)1,"refusal resets output handle and error slot");
  if(status==GLIMS_STATUS_OK&&id)api->image_close(e,id);
  free_error(&error);CHECK(counts_equal(before,counts_of(e)),"refusal publishes/leaks no image");
  CHECK(file_equals(path,bytes),"refusal leaves source bytes unchanged");
  GlimsImageID next=0;CHECK(api->image_new(e,3,3,&next,&error)==GLIMS_STATUS_OK&&next,"next mutating operation works after refusal");
  free_error(&error);if(next)CHECK(api->image_close(e,next)==GLIMS_STATUS_OK,"close post-refusal usability image");
}

static void run_refusals (GlimsEngine *e,const char *work,const guint8 *icc,gsize size) {
  Literal f=literal_psd(7,3,8,icc,size);gchar *path=g_build_filename(work,"refused.psd",NULL);
  struct Mutation {gsize offset;guint8 value;GlimsStatus expected;const char *name;} mutations[]={
    {0,'x',GLIMS_STATUS_UNSUPPORTED,"non-PSD"},{5,2,GLIMS_STATUS_UNSUPPORTED,"PSB"},
    {6,1,GLIMS_STATUS_FAILED,"nonzero reserved header"},{13,5,GLIMS_STATUS_UNSUPPORTED,"fifth alpha/extra plane"},
    {23,32,GLIMS_STATUS_UNSUPPORTED,"32-bit samples"},{25,3,GLIMS_STATUS_UNSUPPORTED,"RGB mode"},
    {39,0x10,GLIMS_STATUS_UNSUPPORTED,"unhandled resource ID"},
    {f.compression_offset+1,1,GLIMS_STATUS_UNSUPPORTED,"RLE"},
    {f.compression_offset+1,2,GLIMS_STATUS_UNSUPPORTED,"ZIP"},
    {f.layer_offset+3,1,GLIMS_STATUS_UNSUPPORTED,"nonempty layer/mask section"},
    {f.icc_offset+36,'x',GLIMS_STATUS_FAILED,"bad ICC signature"}
  };
  for(guint i=0;i<G_N_ELEMENTS(mutations);i++) {
    GByteArray *b=g_byte_array_sized_new(f.bytes->len);g_byte_array_append(b,f.bytes->data,f.bytes->len);
    b->data[mutations[i].offset]=mutations[i].value;
    refuse(e,path,b,mutations[i].expected,mutations[i].name);g_byte_array_unref(b);
  }
  const gsize cuts[]={4,25,f.icc_offset+127,f.pixel_offset,f.bytes->len-1};
  for(guint i=0;i<G_N_ELEMENTS(cuts);i++) {
    GByteArray *b=g_byte_array_new();g_byte_array_append(b,f.bytes->data,(guint)cuts[i]);
    refuse(e,path,b,GLIMS_STATUS_FAILED,"truncated header/profile/pixels");g_byte_array_unref(b);
  }
  GByteArray *b=g_byte_array_new();g_byte_array_append(b,f.bytes->data,f.bytes->len);
  const guint8 extra=7;g_byte_array_append(b,&extra,1);refuse(e,path,b,GLIMS_STATUS_FAILED,"unexpected trailing byte");g_byte_array_unref(b);
  guint8 fake[128]={0};put32(fake,128);memcpy(fake+12,"prtrCMYK",8);memcpy(fake+36,"acsp",4);
  Literal invalid=literal_psd(7,3,8,fake,sizeof fake);
  refuse(e,path,invalid.bytes,GLIMS_STATUS_OK,"structurally plausible but unusable CMYK ICC");
  g_byte_array_unref(invalid.bytes);
  GlimsImageID out=12345;char *error=(char *)1;
  CHECK(api->image_import_native_cmyk_psd(e,"relative.psd",&out,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&out==0&&error!=(char *)1,"relative path resets outputs and refuses");free_error(&error);
  out=12345;error=(char *)1;
  CHECK(api->image_import_native_cmyk_psd(e,NULL,&out,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&out==0&&error!=(char *)1,"null path resets outputs and refuses");free_error(&error);
  error=(char *)1;
  CHECK(api->image_import_native_cmyk_psd(e,path,NULL,&error)==GLIMS_STATUS_INVALID_ARGUMENT&&error!=(char *)1,"null result pointer refuses and resets error");free_error(&error);
  out=12345;error=(char *)1;
  CHECK(api->image_import_native_cmyk_psd(NULL,path,&out,&error)==GLIMS_STATUS_NOT_RUNNING&&out==0&&error==NULL,"pre-dispatch NOT_RUNNING clears both outputs");
  g_byte_array_unref(f.bytes);g_free(path);
}

static gboolean pause_idle (gpointer data) {
  Control *c=data;g_atomic_int_set(&c->idle,0);g_atomic_int_set(&c->paused,1);
  gint64 deadline=g_get_monotonic_time()+10*G_TIME_SPAN_SECOND;
  while(!g_atomic_int_get(&c->release)) {
    if(g_get_monotonic_time()>deadline){g_atomic_int_set(&c->timed_out,1);break;}
    g_main_context_iteration(NULL,FALSE);g_usleep(1000);
  }
  return G_SOURCE_REMOVE;
}
static void event (void *data,const GlimsEvent *ev) {
  Control *c=data;
  if(ev->kind==GLIMS_EVENT_PROGRESS&&ev->active&&g_atomic_int_compare_and_exchange(&c->armed,1,0))
    g_atomic_int_set(&c->idle,(gint)g_idle_add_full(G_PRIORITY_HIGH,pause_idle,c,NULL));
}
static gpointer import_worker (gpointer data) {
  Control *c=data;c->status=api->image_import_native_cmyk_psd(c->engine,c->path,&c->result,&c->error);return NULL;
}
static void run_cancel (Control *c,const char *work,const guint8 *icc,gsize size) {
  Literal f=literal_psd(4097,17,16,icc,size);gchar *path=g_build_filename(work,"cancel.psd",NULL);
  CHECK(g_file_set_contents(path,(const gchar *)f.bytes->data,f.bytes->len,NULL),"write cancellation literal");
  Counts initial=counts_of(c->engine);GlimsImageID anchor=0;char *anchor_error=NULL;
  CHECK(api->image_new(c->engine,3,3,&anchor,&anchor_error)==GLIMS_STATUS_OK&&anchor,"create unrelated document for reentrant read/close checks");
  free_error(&anchor_error);
  GlimsImageInfo anchor_before={0},anchor_after={0};
  CHECK(anchor&&api->image_info(c->engine,anchor,&anchor_before)==GLIMS_STATUS_OK,"capture unrelated document before import");
  Counts before=counts_of(c->engine);c->path=path;g_atomic_int_set(&c->armed,1);
  GThread *worker=g_thread_new("preserving-import",import_worker,c);
  gint64 deadline=g_get_monotonic_time()+10*G_TIME_SPAN_SECOND;
  while(!g_atomic_int_get(&c->paused)&&g_get_monotonic_time()<deadline)g_usleep(1000);
  gboolean paused=g_atomic_int_get(&c->paused);CHECK(paused,"native import services cooperative progress checkpoint");
  if(paused) {
    CHECK(before.published==counts_of(c->engine).published,"checkpoint publishes no partial document");
    if(anchor) {
      CHECK(api->image_info(c->engine,anchor,&anchor_after)==GLIMS_STATUS_OK,"read RPC is deliverable during import");
      CHECK(api->image_close(c->engine,anchor)==GLIMS_STATUS_BUSY,"close of existing document refuses while import is busy");
    }
    GlimsImageID second=12345;char *error=(char *)1;
    GlimsStatus status=api->image_import_native_cmyk_psd(c->engine,path,&second,&error);
    CHECK(status==GLIMS_STATUS_BUSY&&second==0&&error!=(char *)1,"reentrant preserving import is BUSY with reset result");
    free_error(&error);if(status==GLIMS_STATUS_OK&&second)api->image_close(c->engine,second);
    CHECK(api->procedure_cancel(c->engine)==GLIMS_STATUS_OK,"cancellation reaches import progress owner");
  }
  g_atomic_int_set(&c->release,1);g_thread_join(worker);
  gint idle=g_atomic_int_get(&c->idle);if(idle)g_source_remove((guint)idle);
  CHECK(!g_atomic_int_get(&c->timed_out),"test checkpoint releases without timeout");
  CHECK(c->status==GLIMS_STATUS_CANCELLED&&c->result==0,"cancelled import returns no adopted image");
  if(c->status==GLIMS_STATUS_OK&&c->result)api->image_close(c->engine,c->result);
  free_error(&c->error);CHECK(counts_equal(before,counts_of(c->engine)),"cancel releases every unpublished/public image");
  CHECK(api->procedure_cancel(c->engine)==GLIMS_STATUS_NOT_FOUND,"cancel clears progress ownership");
  CHECK(file_equals(path,f.bytes),"cancellation leaves source bytes unchanged");
  CHECK(anchor&&api->image_info(c->engine,anchor,&anchor_after)==GLIMS_STATUS_OK&&
    !memcmp(&anchor_before,&anchor_after,sizeof anchor_before),"cancel/reentrant refusal preserves unrelated document");
  g_atomic_int_set(&c->armed,0);GlimsImageID retry=0;char *error=NULL;
  CHECK(api->image_import_native_cmyk_psd(c->engine,path,&retry,&error)==GLIMS_STATUS_OK&&retry,"same file imports successfully after cancellation");
  free_error(&error);if(retry)CHECK(api->image_close(c->engine,retry)==GLIMS_STATUS_OK,"close retry import");
  CHECK(counts_equal(before,counts_of(c->engine)),"retry leaves no image leak");
  if(anchor)CHECK(api->image_close(c->engine,anchor)==GLIMS_STATUS_OK,"close unrelated control document");
  CHECK(counts_equal(initial,counts_of(c->engine)),"control case releases every owned image");
  g_byte_array_unref(f.bytes);g_free(path);c->path=NULL;
}

int main (int argc,char **argv) {
  if(argc!=3){fprintf(stderr,"usage: %s WORK EXTERNAL_CMYK_PROFILE\n",argv[0]);return 2;}
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);
  if(!api||api->struct_size<offsetof(GlimsEngineAPI,image_import_native_cmyk_psd)+sizeof api->image_import_native_cmyk_psd||!api->image_import_native_cmyk_psd)return 2;
  gchar *icc=NULL;gsize size=0;if(!g_file_get_contents(argv[2],&icc,&size,NULL)||size<128||size>4*1024*1024){g_free(icc);return 2;}
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  Control control={0};GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache,.on_event=event,.event_context=&control};
  char *error=NULL;if(api->start(&config,&control.engine,&error)!=GLIMS_STATUS_OK){fprintf(stderr,"start failed: %s\n",error?error:"");free_error(&error);g_free(icc);g_free(user);g_free(cache);return 2;}
  free_error(&error);
  for(guint depth=8;depth<=16;depth+=8) {
    run_valid(control.engine,argv[1],(const guint8 *)icc,size,1,7,depth);
    run_valid(control.engine,argv[1],(const guint8 *)icc,size,7,3,depth);
    run_valid(control.engine,argv[1],(const guint8 *)icc,size,4097,3,depth);
  }
  run_refusals(control.engine,argv[1],(const guint8 *)icc,size);
  run_cancel(&control,argv[1],(const guint8 *)icc,size);
  api->stop(control.engine);g_free(icc);g_free(user);g_free(cache);
  printf("%u checks, %u failures\n",checks,failures);return failures?1:0;
}

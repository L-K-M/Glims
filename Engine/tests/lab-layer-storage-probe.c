/* Test-only ordinary native layer storage. No Lab admission or compositor. */
#include "engine-private.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpobject.h"
#include "core/gimppickable.h"
#include "core/gimpprojection.h"
#include "core/gimpundostack.h"
#include "core/gimpviewable.h"
#include "file/file-open.h"
#include "file/file-save.h"
#include "pdb/gimppdb.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
#include "plug-in/gimppluginprocedure.h"
#define W 4
#define H 3
#define N (W*H)
#define PROBE_CAPACITY (N*4*4)
static const GlimsEngineAPI *api;
static unsigned checks, failures;
static const char *label;
static void row(const char *operation, gboolean pass) {
  checks++; if (!pass) failures++;
  printf("ROW\t%s\t%s\t%s\n", label, operation, pass ? "PASS" : "FAIL"); fflush(stdout);
}
static gboolean equal_bytes(const guint8 *expected, const guint8 *actual, size_t length) {
  if (!memcmp(expected, actual, length)) return TRUE;
  for (size_t i=0;i<length;i++) if (expected[i]!=actual[i]) {
    printf("MISMATCH\t%s\tbyte=%zu\texpected=%02x\tactual=%02x\n",label,i,expected[i],actual[i]); break;
  }
  return FALSE;
}
static void get_raw(GimpLayer *layer, const Babl *format, int width, int height, void *data) {
  gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)), GEGL_RECTANGLE(0,0,width,height),
                  1,format,data,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
}
static void put_raw(GimpLayer *layer, const Babl *format, int width, int height, const void *data) {
  gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)), GEGL_RECTANGLE(0,0,width,height),
                  0,format,data,GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update(GIMP_DRAWABLE(layer),0,0,width,height);
}
static GimpLayer *top_layer(GimpImage *image, const char *name) {
  GimpObject *item=gimp_container_get_child_by_name(gimp_image_get_layers(image),name);
  return GIMP_IS_LAYER(item) ? GIMP_LAYER(item) : NULL;
}
static void seed(guint8 *data, unsigned channels, unsigned width, unsigned layer) {
  static const guint8 u8[]={0,17,128,255,64,201,1,254};
  static const guint16 u16[]={0,1,32768,65535,32896,257,65534,513};
  static const guint32 floating[]={0xc3000000u,0x42c80000u,0x43800000u,0x80000000u,
    1u,0x7f7fffffu,0xff7fffffu,0x7fc01234u,0x7f800000u,0xff800000u,0x3f000000u};
  static const guint32 alpha[]={0u,0x3f000000u,0x3f800000u,0x80000000u};
  memset(data,0,PROBE_CAPACITY);
  for (unsigned p=0;p<N;p++) for (unsigned c=0;c<channels;c++) {
    unsigned index=p+3*c+5*layer; guint8 *out=data+(p*channels+c)*width;
    if (width==1) { guint8 v=c+1==channels ? (guint8[]){0,128,255,64}[p%4] : u8[index%G_N_ELEMENTS(u8)]; memcpy(out,&v,1); }
    else if (width==2) { guint16 v=c+1==channels ? (guint16[]){0,32768,65535,16384}[p%4] : u16[index%G_N_ELEMENTS(u16)]; memcpy(out,&v,2); }
    else { guint32 v=c+1==channels ? alpha[p%4] : floating[index%G_N_ELEMENTS(floating)]; memcpy(out,&v,4); }
  }
}
static gboolean image_bytes(GimpImage *image, const Babl *format, const guint8 expected[2][PROBE_CAPACITY], size_t bytes) {
  static const char *names[]={"probe-first","probe-second"}; guint8 actual[PROBE_CAPACITY];
  gboolean ok=gimp_container_get_n_children(gimp_image_get_layers(image))==2;
  for (unsigned i=0;i<2;i++) {
    GimpLayer *layer=top_layer(image,names[i]);
    if (!layer || gimp_drawable_get_format(GIMP_DRAWABLE(layer))!=format) { ok=FALSE; continue; }
    get_raw(layer,format,W,H,actual); if (!equal_bytes(expected[i],actual,bytes)) ok=FALSE;
  }
  return ok;
}
static GimpImage *open_xcf(Gimp *gimp, const char *path, GimpPDBStatusType *status, GError **error) {
  GFile *file = g_file_new_for_path(path);
  const gchar *mime = NULL;
#if GIMP_CHECK_VERSION(3, 2, 0)
  gboolean handles_vector = FALSE;
  GimpImage *image = file_open_image(gimp, gimp_get_user_context(gimp), NULL, file,
                                     0, 0, FALSE, FALSE, NULL, GIMP_RUN_NONINTERACTIVE,
                                     &handles_vector, status, &mime, error);
#else
  GimpImage *image = file_open_image(gimp, gimp_get_user_context(gimp), NULL, file,
                                     0, 0, FALSE, NULL, GIMP_RUN_NONINTERACTIVE,
                                     status, &mime, error);
#endif
  g_object_unref(file);
  return image;
}

static gboolean save_xcf(Gimp *gimp, GimpImage *image, const char *path, char *errbuf, size_t errsz) {
  GError *gerror = NULL;
  GFile *file = g_file_new_for_path(path);
  GimpPlugInProcedure *proc = gimp_plug_in_manager_file_procedure_find(
      gimp->plug_in_manager, GIMP_FILE_PROCEDURE_GROUP_SAVE, file, &gerror);
  if (!proc) {
    snprintf(errbuf, errsz, "no save proc: %s", gerror ? gerror->message : "unknown");
    g_clear_error(&gerror); g_object_unref(file); return FALSE;
  }
  GimpPDBStatusType status = file_save(gimp, image, NULL, file, proc, GIMP_RUN_NONINTERACTIVE,
                                       TRUE, FALSE, FALSE, &gerror);
  if (status != GIMP_PDB_SUCCESS) {
    snprintf(errbuf, errsz, "save status=%d error=%s", (int)status, gerror ? gerror->message : "none");
    g_clear_error(&gerror); g_object_unref(file); return FALSE;
  }
  g_clear_error(&gerror);
  g_object_unref(file);
  errbuf[0] = '\0';
  return TRUE;
}


typedef struct { const char *work; GimpImageBaseType base; GimpPrecision precision; unsigned width, channels; const char *name; } Case;
static GlimsStatus run_case(GlimsEngine *engine,gpointer data) {
  Case *c=data; label=c->name;
  GimpImage *image=gimp_create_image(engine->gimp,W,H,c->base,c->precision,FALSE);
  row("create",image!=NULL); if (!image) return GLIMS_STATUS_OK;
  const Babl *format=gimp_image_get_layer_format(image,TRUE); size_t bpp=c->width*c->channels, bytes=N*bpp;
  printf("FORMAT\t%s\t%s\tbpp=%d\n",label,babl_get_name(format),babl_format_get_bytes_per_pixel(format));
  if ((size_t)babl_format_get_bytes_per_pixel(format)!=bpp) { row("format-width",FALSE); g_object_unref(image); return GLIMS_STATUS_OK; }
  guint8 before[2][PROBE_CAPACITY],after[2][PROBE_CAPACITY],actual[PROBE_CAPACITY]; GimpLayer *layers[2]={NULL,NULL};
  gimp_image_undo_disable(image);
  for (unsigned i=0;i<2;i++) {
    seed(before[i],c->channels,c->width,i);
    layers[i]=gimp_layer_new(image,W,H,format,i ? "probe-second":"probe-first",1,GIMP_LAYER_MODE_NORMAL);
    if (!layers[i] || !gimp_image_add_layer(image,layers[i],NULL,(gint)i,FALSE)) {
      row("insert-layer",FALSE); if (layers[i]) g_object_unref(layers[i]); g_object_unref(image); return GLIMS_STATUS_OK;
    }
    gimp_item_set_visible(GIMP_ITEM(layers[i]),TRUE,FALSE); put_raw(layers[i],format,W,H,before[i]);
  }
  gimp_image_undo_enable(image); gimp_image_clean_all(image);
  row("write-read",image_bytes(image,format,before,bytes));
  memcpy(after,before,sizeof after);
  for (unsigned p=0;p<N;p++) memcpy(after[0]+p*bpp,before[0]+((p+5)%N)*bpp,bpp);
  row("mutation-witness",memcmp(before[0],after[0],bytes)!=0);
  GimpImage *copy=gimp_image_duplicate(image);
  row("duplicate",copy && image_bytes(copy,format,before,bytes));
  if (copy) {
    GimpLayer *first=top_layer(copy,"probe-first");
    if (first) put_raw(first,format,W,H,after[0]);
    row("duplicate-independent",first && image_bytes(image,format,before,bytes) && image_bytes(copy,format,after,bytes));
    g_object_unref(copy);
  }
  gimp_drawable_push_undo(GIMP_DRAWABLE(layers[0]),"probe pixels",NULL,0,0,W,H);
  put_raw(layers[0],format,W,H,after[0]);
  row("edit-one-layer",image_bytes(image,format,after,bytes));
  row("one-pixel-undo-step",gimp_undo_stack_get_depth(gimp_image_get_undo_stack(image))==1);
  gboolean ok=gimp_image_undo(image); row("pixel-undo",ok && image_bytes(image,format,before,bytes));
  ok=gimp_image_redo(image); row("pixel-redo",ok && image_bytes(image,format,after,bytes));
  gimp_item_set_visible(GIMP_ITEM(layers[0]),FALSE,TRUE);
  ok=gimp_image_undo(image); ok=ok && gimp_item_get_visible(GIMP_ITEM(layers[0]));
  ok=gimp_image_redo(image) && ok;
  row("visibility-undo-redo",ok && !gimp_item_get_visible(GIMP_ITEM(layers[0])) && image_bytes(image,format,after,bytes));
  gimp_layer_set_opacity(layers[0],.375,TRUE);
  ok=gimp_image_undo(image); ok=ok && gimp_layer_get_opacity(layers[0])==1;
  ok=gimp_image_redo(image) && ok;
  row("opacity-undo-redo",ok && gimp_layer_get_opacity(layers[0])==.375 && image_bytes(image,format,after,bytes));
  gchar *path=g_strdup_printf("%s/%s.xcf",c->work,c->name); char message[512];
  ok=save_xcf(engine->gimp,image,path,message,sizeof message); row("xcf-save",ok);
  if (!ok) printf("ERROR\t%s\t%s\n",label,message);
  row("save-source-unchanged",image_bytes(image,format,after,bytes));
  if (ok) {
    GimpPDBStatusType status; GError *error=NULL;
    GimpImage *opened=open_xcf(engine->gimp,path,&status,&error);
    row("xcf-open",opened && status==GIMP_PDB_SUCCESS);
    if (error) { printf("ERROR\t%s\t%s\n",label,error->message); g_clear_error(&error); }
    if (opened) {
      row("xcf-raw-exact",gimp_image_get_precision(opened)==c->precision && gimp_image_get_base_type(opened)==c->base && image_bytes(opened,format,after,bytes));
      GimpLayer *first=top_layer(opened,"probe-first");
      row("xcf-attributes",first && !gimp_item_get_visible(GIMP_ITEM(first)) && gimp_layer_get_opacity(first)==.375);
      g_object_unref(opened);
    }
  }
  /* A final same-format read checks that file work did not rewrite source. */
  get_raw(layers[0],format,W,H,actual);
  row("final-raw-retained",equal_bytes(after[0],actual,bytes));
  g_free(path); g_object_unref(image); return GLIMS_STATUS_OK;
}
static const char *child_names[]={"probe-L","probe-a","probe-b","probe-alpha"};
static gboolean group_bytes(GimpImage *image,const Babl *format,const guint8 expected[4][16],gboolean visible,double opacity) {
  GimpLayer *group=top_layer(image,"probe-group");
  if (!group || !GIMP_IS_GROUP_LAYER(group)) return FALSE;
  GimpContainer *children=gimp_viewable_get_children(GIMP_VIEWABLE(group));
  gboolean ok=gimp_container_get_n_children(gimp_image_get_layers(image))==1 && children &&
    gimp_container_get_n_children(children)==4 && gimp_item_get_visible(GIMP_ITEM(group))==visible && gimp_layer_get_opacity(group)==opacity;
  for (unsigned i=0;i<4;i++) {
    GimpObject *object=children ? gimp_container_get_child_by_name(children,child_names[i]) : NULL;
    if (!GIMP_IS_LAYER(object)) { ok=FALSE; continue; }
    GimpLayer *layer=GIMP_LAYER(object); guint8 actual[16];
    if (gimp_item_get_parent(GIMP_ITEM(layer))!=GIMP_ITEM(group) || gimp_drawable_get_format(GIMP_DRAWABLE(layer))!=format || gimp_drawable_has_alpha(GIMP_DRAWABLE(layer))) { ok=FALSE; continue; }
    get_raw(layer,format,2,2,actual); if (!equal_bytes(expected[i],actual,sizeof actual)) ok=FALSE;
  }
  return ok;
}
static GlimsStatus run_group(GlimsEngine *engine,gpointer data) {
  const char *work=data; label="GRAY_GROUP_Y_FLOAT";
  GimpImage *image=gimp_create_image(engine->gimp,2,2,GIMP_GRAY,GIMP_PRECISION_FLOAT_LINEAR,FALSE);
  row("create",image!=NULL); if (!image) return GLIMS_STATUS_OK;
  const Babl *format=gimp_image_get_layer_format(image,FALSE);
  const guint32 bits[4][4]={{0x42c80000u,0x41c80000u,0x80000000u,0x43800000u},
    {0xc3000000u,0xc2800000u,0u,0x43000000u},{0x42fe0000u,0x42800000u,0x80000000u,0xc3800000u},
    {0u,0x3e800000u,0x3f000000u,0x3f800000u}};
  guint8 expected[4][16]; memcpy(expected,bits,sizeof expected);
  gimp_image_undo_disable(image);
  GimpLayer *group=gimp_group_layer_new(image);
  if (!group || !gimp_image_add_layer(image,group,NULL,0,FALSE)) { row("insert-group",FALSE); if(group)g_object_unref(group); g_object_unref(image); return GLIMS_STATUS_OK; }
  gimp_object_set_name(GIMP_OBJECT(group),"probe-group"); gimp_item_set_visible(GIMP_ITEM(group),TRUE,FALSE);
  for(unsigned i=0;i<4;i++) {
    GimpLayer *child=gimp_layer_new(image,2,2,format,child_names[i],1,GIMP_LAYER_MODE_NORMAL);
    if(!child || !gimp_image_add_layer(image,child,group,(gint)i,FALSE)) { row("insert-child",FALSE); if(child)g_object_unref(child); g_object_unref(image); return GLIMS_STATUS_OK; }
    gimp_item_set_visible(GIMP_ITEM(child),TRUE,FALSE); put_raw(child,format,2,2,expected[i]);
  }
  gimp_image_undo_enable(image); gimp_image_clean_all(image);
  row("raw-parentage",group_bytes(image,format,expected,TRUE,1));
  gimp_item_set_visible(GIMP_ITEM(group),FALSE,TRUE); gimp_layer_set_opacity(group,.375,TRUE);
  gboolean ok=gimp_image_undo(image); ok=ok && group_bytes(image,format,expected,FALSE,1);
  ok=gimp_image_undo(image) && ok; ok=group_bytes(image,format,expected,TRUE,1) && ok;
  ok=gimp_image_redo(image) && ok; ok=group_bytes(image,format,expected,FALSE,1) && ok;
  ok=gimp_image_redo(image) && ok;
  row("group-attribute-undo-redo",ok && group_bytes(image,format,expected,FALSE,.375));
  GimpImage *copy=gimp_image_duplicate(image);
  row("duplicate-parentage",copy && group_bytes(copy,format,expected,FALSE,.375)); if(copy)g_object_unref(copy);
  gchar *path=g_build_filename(work,"gray-group.xcf",NULL); char message[512];
  ok=save_xcf(engine->gimp,image,path,message,sizeof message); row("xcf-save",ok);
  if(!ok)printf("ERROR\t%s\t%s\n",label,message);
  if(ok) {
    GimpPDBStatusType status; GError *error=NULL; GimpImage *opened=open_xcf(engine->gimp,path,&status,&error);
    row("xcf-open",opened && status==GIMP_PDB_SUCCESS);
    if(error){printf("ERROR\t%s\t%s\n",label,error->message);g_clear_error(&error);}
    if(opened){row("xcf-raw-parentage",group_bytes(opened,format,expected,FALSE,.375));g_object_unref(opened);}
  }
  row("save-source-unchanged",group_bytes(image,format,expected,FALSE,.375));
  g_free(path);g_object_unref(image);return GLIMS_STATUS_OK;
}
static GlimsStatus observe_projection(GlimsEngine *engine,gpointer data) {
  GimpImageBaseType base=GPOINTER_TO_INT(data); label=base==GIMP_GRAY ? "GRAY_PROJECTION" : "RGB_PROJECTION";
  GimpImage *image=gimp_create_image(engine->gimp,2,2,base,GIMP_PRECISION_FLOAT_LINEAR,FALSE);
  row("create",image!=NULL); if(!image)return GLIMS_STATUS_OK;
  const Babl *format=gimp_image_get_layer_format(image,TRUE); unsigned channels=base==GIMP_GRAY ? 2:4;
  const float pixel[]={-64,100,256,.5}; float values[16]={0},actual[16]={0};
  for(unsigned p=0;p<4;p++)for(unsigned c=0;c<channels;c++)
    values[p*channels+c]=base==GIMP_GRAY ? (c==0 ? 100:.5) : pixel[c];
  GimpLayer *layer=gimp_layer_new(image,2,2,format,"finite-projection-control",1,GIMP_LAYER_MODE_NORMAL);
  if(!layer || !gimp_image_add_layer(image,layer,NULL,0,FALSE)) { row("insert-layer",FALSE);if(layer)g_object_unref(layer);g_object_unref(image);return GLIMS_STATUS_OK; }
  gimp_item_set_visible(GIMP_ITEM(layer),TRUE,FALSE);put_raw(layer,format,2,2,values);
  GimpPickable *pickable=GIMP_PICKABLE(gimp_image_get_projection(image));gimp_pickable_flush(pickable);
  GeglBuffer *projection=gimp_pickable_get_buffer(pickable);row("projection-buffer",projection!=NULL);
  if(projection) {
    float rgba[4];gegl_buffer_get(projection,GEGL_RECTANGLE(0,0,1,1),1,babl_format("RGBA float"),rgba,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
    printf("PROJECTION\t%s\tnative-format=%s\tlinear-RGBA=%a,%a,%a,%a\n",label,babl_get_name(gegl_buffer_get_format(projection)),(double)rgba[0],(double)rgba[1],(double)rgba[2],(double)rgba[3]);
  }
  get_raw(layer,format,2,2,actual);row("projection-source-unchanged",equal_bytes((guint8 *)values,(guint8 *)actual,4*channels*sizeof(float)));
  g_object_unref(image);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
  if(argc!=2){fprintf(stderr,"usage: %s PRIVATE_WORK\n",argv[0]);return 2;}
  api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
  gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
  GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
  GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);
  if(status!=GLIMS_STATUS_OK || !engine){fprintf(stderr,"start: %s\n",error?error:"failed");api->free_string(error);return 2;}api->free_string(error);
  Case cases[]={{argv[1],GIMP_GRAY,GIMP_PRECISION_U8_LINEAR,1,2,"YA_U8"},{argv[1],GIMP_GRAY,GIMP_PRECISION_U16_LINEAR,2,2,"YA_U16"},{argv[1],GIMP_GRAY,GIMP_PRECISION_FLOAT_LINEAR,4,2,"YA_FLOAT"},
    {argv[1],GIMP_RGB,GIMP_PRECISION_U8_LINEAR,1,4,"RGBA_U8"},{argv[1],GIMP_RGB,GIMP_PRECISION_U16_LINEAR,2,4,"RGBA_U16"},{argv[1],GIMP_RGB,GIMP_PRECISION_FLOAT_LINEAR,4,4,"RGBA_FLOAT"}};
  for(unsigned i=0;i<G_N_ELEMENTS(cases);i++) { if(glims_engine_call(engine,run_case,&cases[i])!=GLIMS_STATUS_OK) {label=cases[i].name;row("worker",FALSE);} }
  if(glims_engine_call(engine,run_group,argv[1])!=GLIMS_STATUS_OK){label="group";row("worker",FALSE);}
  if(glims_engine_call(engine,observe_projection,GINT_TO_POINTER(GIMP_GRAY))!=GLIMS_STATUS_OK){label="GRAY_PROJECTION";row("worker",FALSE);}
  if(glims_engine_call(engine,observe_projection,GINT_TO_POINTER(GIMP_RGB))!=GLIMS_STATUS_OK){label="RGB_PROJECTION";row("worker",FALSE);}
  api->stop(engine);printf("SUMMARY checks=%u failures=%u\n",checks,failures);return failures ? 1:0;
}

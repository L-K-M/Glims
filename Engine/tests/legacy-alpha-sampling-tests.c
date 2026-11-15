#include "engine-private.h"
#include <cairo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libgimpcolor/gimpcolor.h"
#include "core/gimp.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
static unsigned checks, failures;
#define CHECK(v,label) do { checks++; if (!(v)) { failures++; printf("FAIL %s\n",label); } else printf("ok %s\n",label); } while(0)
static GlimsStatus probe(GlimsEngine *engine, gpointer unused) {
 (void)unused;
 GimpImage *image=gimp_create_image(engine->gimp,4,4,GIMP_RGB,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
 CHECK(image!=NULL,"ordinary native image"); if(!image)return GLIMS_STATUS_OK;
 gimp_image_undo_disable(image);
 GimpLayer *layer=gimp_layer_new(image,4,4,gimp_image_get_layer_format(image,TRUE),"Corner",1,GIMP_LAYER_MODE_NORMAL);
 CHECK(layer!=NULL,"ordinary alpha layer"); if(!layer){g_object_unref(image);return GLIMS_STATUS_OK;}
 CHECK(gimp_image_add_layer(image,layer,NULL,0,FALSE),"ordinary root attaches");
 guint8 source[4*4*4]={0};source[4*(3*4+3)]=255;source[4*(3*4+3)+3]=255;
 gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)),GEGL_RECTANGLE(0,0,4,4),0,babl_format("R'G'B'A u8"),source,GEGL_AUTO_ROWSTRIDE);
 gimp_drawable_update(GIMP_DRAWABLE(layer),0,0,4,4);
 gimp_image_undo_enable(image);gimp_image_clean_all(image);
 GlimsImageID id=0;GlimsStatus status=glims_adopt_image(engine,image,&id);
 CHECK(status==GLIMS_STATUS_OK&&id,"ordinary facade adoption");if(status||!id){g_object_unref(image);return GLIMS_STATUS_OK;}
 guint8 pixel[4]={0};status=glims_image_render(engine,id,1,(GlimsRect){3,3,1,1},pixel,4);
 printf("SOURCE legacy status=%d RGBA=%u,%u,%u,%u\n",status,pixel[0],pixel[1],pixel[2],pixel[3]);
 CHECK(status==GLIMS_STATUS_OK&&pixel[0]==255&&pixel[3]==255,"ordinary source is opaque red corner");
 /* The only opaque source pixel is (3,3). At half scale its mip cell
  * contains one of four opaque pixels. Standard-center interpolation at
  * 3/4 and 5/4 gives weights (5/6)^2 and (3/10)^2 respectively. Since the
  * source color is red, premultiplied red must equal the resulting alpha. */
 const double scales[]={.5,.75,1.25}; const unsigned alpha[]={64,177,23};
 for(unsigned i=0;i<3;i++) {
   int xy=(int)(3*scales[i]); memset(pixel,0,sizeof pixel);
   status=glims_image_render(engine,id,scales[i],(GlimsRect){xy,xy,1,1},pixel,4);
   printf("LEGACY %.2f status=%d RGBA=%u,%u,%u,%u expected=%u\n",scales[i],status,pixel[0],pixel[1],pixel[2],pixel[3],alpha[i]);
   CHECK(status==GLIMS_STATUS_OK && abs((int)pixel[3]-(int)alpha[i])<=1 && abs((int)pixel[0]-(int)alpha[i])<=1 && pixel[1]==0 && pixel[2]==0,"legacy alpha-aware pure red sample");
 }
 /* Padded rows and one-pixel requests must agree for the entire viewport. */
 guint8 padded[5*27]; memset(padded,0xa5,sizeof padded);
 status=glims_image_render(engine,id,1.25,(GlimsRect){0,0,5,5},padded,27);
 CHECK(status==GLIMS_STATUS_OK,"legacy padded viewport renders");
 for(int y=0;y<5;y++) {
  for(int x=0;x<5;x++) {
   guint8 single[4];
   status=glims_image_render(engine,id,1.25,(GlimsRect){x,y,1,1},single,4);
   CHECK(status==GLIMS_STATUS_OK && !memcmp(single,padded+y*27+x*4,4),"legacy viewport matches one-pixel read");
  }
  for(int x=20;x<27;x++) CHECK(padded[y*27+x]==0xa5,"legacy output preserves row padding");
 }
 /* A plug-in can hold global busy while its nested loop permits viewing.
  * A read already active for this image must still reject reentry. */
 GlimsOpenImage *open=glims_lookup_image(engine,id);
 CHECK(open!=NULL,"legacy image is available to the engine worker");
 if(open) {
  int busy_before=engine->busy; engine->busy++;
  status=glims_image_render(engine,id,.5,(GlimsRect){1,1,1,1},pixel,4);
  CHECK(status==GLIMS_STATUS_OK && engine->busy==busy_before+1,"legacy view works during unrelated busy activity");
  engine->busy--;
  open->display_sample_active=TRUE; memset(pixel,0xa5,sizeof pixel);
  status=glims_image_render(engine,id,.5,(GlimsRect){1,1,1,1},pixel,4);
  CHECK(status==GLIMS_STATUS_BUSY && open->display_sample_active && engine->busy==busy_before &&
        pixel[0]==0xa5 && pixel[1]==0xa5 && pixel[2]==0xa5 && pixel[3]==0xa5,
        "legacy reentry refuses without disturbing the active read");
  open->display_sample_active=FALSE;
 }
 /* The same cached source must reflect a later drawable write. */
 source[4*(3*4+3)]=0; source[4*(3*4+3)+2]=255;
 gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)),GEGL_RECTANGLE(0,0,4,4),0,
                 babl_format("R'G'B'A u8"),source,GEGL_AUTO_ROWSTRIDE);
 gimp_drawable_update(GIMP_DRAWABLE(layer),0,0,4,4);
 status=glims_image_render(engine,id,.5,(GlimsRect){1,1,1,1},pixel,4);
 CHECK(status==GLIMS_STATUS_OK && pixel[0]==0 && pixel[1]==0 &&
       abs((int)pixel[2]-64)<=1 && abs((int)pixel[3]-64)<=1,
       "legacy cached read reflects later drawable write");
 memset(pixel,0xa5,sizeof pixel);
 status=glims_image_render(engine,id,.5,(GlimsRect){1,1,1,1},pixel,3);
 CHECK(status==GLIMS_STATUS_INVALID_ARGUMENT && pixel[0]==0xa5 && pixel[3]==0xa5,
       "legacy fractional read refuses a short stride without writing");
 GlimsIndexedSettings indexed={.struct_size=sizeof indexed,.palette=GLIMS_INDEXED_PALETTE_GENERATED,
   .max_colors=64,.dither=GLIMS_INDEXED_DITHER_NONE,.preservation=GLIMS_INDEXED_PRESERVE_EDITABLE};
 status=glims_image_convert_indexed(engine,id,&indexed,NULL,0,NULL);
 CHECK(status==GLIMS_STATUS_OK,"legacy indexed fixture converts");
 if(status==GLIMS_STATUS_OK){
  memset(pixel,0,sizeof pixel);status=glims_image_render(engine,id,.5,(GlimsRect){1,1,1,1},pixel,4);
  CHECK(status==GLIMS_STATUS_OK&&pixel[0]==0&&pixel[1]==0&&abs((int)pixel[2]-64)<=1&&abs((int)pixel[3]-64)<=1,
        "indexed projection retains alpha-aware fractional rendering");
 }
 CHECK(glims_image_close(engine,id)==GLIMS_STATUS_OK,"ordinary probe closes owned image");

 /* A gray source uses two linear components but still produces RGBA. */
 image=gimp_create_image(engine->gimp,4,4,GIMP_GRAY,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
 CHECK(image!=NULL,"gray native image"); if(!image)return GLIMS_STATUS_OK;
 gimp_image_undo_disable(image);
 layer=gimp_layer_new(image,4,4,gimp_image_get_layer_format(image,TRUE),"Gray corner",1,GIMP_LAYER_MODE_NORMAL);
 CHECK(layer!=NULL,"gray alpha layer"); if(!layer){g_object_unref(image);return GLIMS_STATUS_OK;}
 CHECK(gimp_image_add_layer(image,layer,NULL,0,FALSE),"gray root attaches");
 guint8 gray_source[4*4*2]={0}; gray_source[2*(3*4+3)]=255; gray_source[2*(3*4+3)+1]=255;
 gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)),GEGL_RECTANGLE(0,0,4,4),0,babl_format("Y'A u8"),gray_source,GEGL_AUTO_ROWSTRIDE);
 gimp_drawable_update(GIMP_DRAWABLE(layer),0,0,4,4);
 gimp_image_undo_enable(image);gimp_image_clean_all(image);id=0;
 status=glims_adopt_image(engine,image,&id);
 CHECK(status==GLIMS_STATUS_OK&&id,"gray facade adoption");
 if(status||!id){g_object_unref(image);return GLIMS_STATUS_OK;}
 status=glims_image_render(engine,id,.5,(GlimsRect){1,1,1,1},pixel,4);
 CHECK(status==GLIMS_STATUS_OK && abs((int)pixel[3]-64)<=1 &&
       abs((int)pixel[0]-64)<=1 && abs((int)pixel[1]-64)<=1 && abs((int)pixel[2]-64)<=1,
       "gray half-scale white corner retains alpha and color");
 CHECK(glims_image_close(engine,id)==GLIMS_STATUS_OK,"gray probe closes owned image");

 /* Cover both the 4096-column and 256-row renderer chunk boundaries. */
 image=gimp_create_image(engine->gimp,8200,520,GIMP_RGB,GIMP_PRECISION_U8_NON_LINEAR,FALSE);
 CHECK(image!=NULL,"wide native image"); if(!image)return GLIMS_STATUS_OK;
 gimp_image_undo_disable(image);
 layer=gimp_layer_new(image,8200,520,gimp_image_get_layer_format(image,TRUE),"Wide corner",1,GIMP_LAYER_MODE_NORMAL);
 CHECK(layer!=NULL,"wide alpha layer"); if(!layer){g_object_unref(image);return GLIMS_STATUS_OK;}
 CHECK(gimp_image_add_layer(image,layer,NULL,0,FALSE),"wide root attaches");
 const guint8 red[4]={255,0,0,255};
 gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)),GEGL_RECTANGLE(3276,205,1,1),0,
                 babl_format("R'G'B'A u8"),red,GEGL_AUTO_ROWSTRIDE);
 gimp_drawable_update(GIMP_DRAWABLE(layer),3276,205,1,1);
 gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)),GEGL_RECTANGLE(8192,512,1,1),0,
                 babl_format("R'G'B'A u8"),red,GEGL_AUTO_ROWSTRIDE);
 gimp_drawable_update(GIMP_DRAWABLE(layer),8192,512,1,1);
 gimp_image_undo_enable(image);gimp_image_clean_all(image);id=0;
 status=glims_adopt_image(engine,image,&id);
 CHECK(status==GLIMS_STATUS_OK&&id,"wide facade adoption");
 if(status||!id){g_object_unref(image);return GLIMS_STATUS_OK;}
 const size_t wide_stride=4100*4+7, wide_size=257*wide_stride;
 guint8 *wide=g_malloc(wide_size);memset(wide,0xa5,wide_size);
 status=glims_image_render(engine,id,1.25,(GlimsRect){0,0,4100,257},wide,wide_stride);
 CHECK(status==GLIMS_STATUS_OK,"wide padded viewport renders across both chunk boundaries");
 const int xs[]={4095,4096}, ys[]={255,256};
 for(unsigned yi=0;yi<2;yi++)for(unsigned xi=0;xi<2;xi++){
  guint8 single[4]={0x5a,0x5a,0x5a,0x5a};int x=xs[xi],y=ys[yi];
  status=glims_image_render(engine,id,1.25,(GlimsRect){x,y,1,1},single,4);
  CHECK(status==GLIMS_STATUS_OK && !memcmp(single,wide+(size_t)y*wide_stride+x*4,4),
        "wide render matches a single pixel across chunk seams");
  if(y==256)CHECK(single[0]>0 && single[3]>0,"wide seam samples the seeded red pixel");
 }
 for(int y=0;y<257;y++){
  gboolean intact=TRUE;for(size_t x=4100*4;x<wide_stride;x++)if(wide[(size_t)y*wide_stride+x]!=0xa5)intact=FALSE;
  CHECK(intact,"wide render preserves row padding");
 }
 memset(wide,0xa5,wide_size);
 status=glims_image_render(engine,id,.5,(GlimsRect){0,0,4100,257},wide,wide_stride);
 CHECK(status==GLIMS_STATUS_OK,"half-scale viewport renders across both chunk boundaries");
 gboolean seam_checked=FALSE;
 for(unsigned yi=0;yi<2;yi++)for(unsigned xi=0;xi<2;xi++){
  guint8 single[4]={0x5a,0x5a,0x5a,0x5a};int x=xs[xi],y=ys[yi];
  status=glims_image_render(engine,id,.5,(GlimsRect){x,y,1,1},single,4);
  CHECK(status==GLIMS_STATUS_OK && !memcmp(single,wide+(size_t)y*wide_stride+x*4,4),
        "half-scale chunk seam matches a single-pixel read");
  if(x==4096 && y==256){
   CHECK(single[0]>0 && single[3]>0,"half-scale seam samples the seeded red pixel");seam_checked=TRUE;
  }
 }
 CHECK(seam_checked,"half-scale seeded seam is included in the probes");
 for(int y=0;y<257;y++){
  gboolean intact=TRUE;for(size_t x=4100*4;x<wide_stride;x++)if(wide[(size_t)y*wide_stride+x]!=0xa5)intact=FALSE;
  CHECK(intact,"half-scale viewport preserves row padding");
 }
 /* Compare the optimized read with an explicit eager projection validation
  * after a fresh edit. Both routes use the same sampler and conversion; this
  * checks that skipping the earlier validation does not leave stale pixels. */
 const guint8 blue[4]={0,0,255,255};
 gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(layer)),GEGL_RECTANGLE(8192,512,1,1),0,
                 babl_format("R'G'B'A u8"),blue,GEGL_AUTO_ROWSTRIDE);
 gimp_drawable_update(GIMP_DRAWABLE(layer),8192,512,1,1);
 memset(wide,0xa5,wide_size);
 status=glims_image_render(engine,id,.5,(GlimsRect){0,0,4100,257},wide,wide_stride);
 CHECK(status==GLIMS_STATUS_OK,"half-scale optimized render follows a fresh edit");
 CHECK(wide[(size_t)256*wide_stride+4096*4+2]>0,
       "half-scale optimized read sees the edited blue seam pixel");
 guint8 *eager=g_malloc(wide_size);memset(eager,0xa5,wide_size);
 open=glims_lookup_image(engine,id);GeglBuffer *projection=NULL;
 status=open ? glims_projection_prepare_read(open,.5,(GlimsRect){0,0,4100,257},&projection) : GLIMS_STATUS_FAILED;
 CHECK(status==GLIMS_STATUS_OK && projection,"eager validation prepares the same edited projection");
 if(status==GLIMS_STATUS_OK && projection){
  status=glims_image_render(engine,id,.5,(GlimsRect){0,0,4100,257},eager,wide_stride);
  CHECK(status==GLIMS_STATUS_OK && !memcmp(wide,eager,wide_size),
        "optimized and eagerly validated half-scale reads agree after edit including padding");
 }
 g_free(eager);
 g_free(wide);CHECK(glims_image_close(engine,id)==GLIMS_STATUS_OK,"wide probe closes owned image");
 return GLIMS_STATUS_OK;
}
int main(int argc,char **argv){if(argc!=2)return 2;const GlimsEngineAPI *api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;
 char *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);GlimsEngineConfig c={.struct_size=sizeof c,.user_directory=user,.cache_directory=cache};GlimsEngine *e=NULL;char *error=NULL;
 GlimsStatus status=api->start(&c,&e,&error);g_free(user);g_free(cache);if(status||!e){fprintf(stderr,"start %s\n",error?error:"");api->free_string(error);return 2;}api->free_string(error);status=glims_engine_call(e,probe,NULL);api->stop(e);printf("checks=%u failures=%u\n",checks,failures);return status||failures?1:0;}

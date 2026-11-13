/* Public read-only layered Lab acceptance probe, with an LCMS color oracle. */
#include "engine-private.h"
#include "lab-layer-storage.h"
#include "plate-storage.h"
#include <lcms2.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpdrawable.h"
#include "core/gimpitem.h"
#include "file/file-save.h"
#include "plug-in/gimppluginmanager.h"
#include "plug-in/gimppluginmanager-file.h"
static const GlimsEngineAPI *api;static unsigned checks,failures;
#define CHECK(c,n) do{gboolean b=!!(c);checks++;if(!b)failures++;printf("%s %s\n",b?"ok":"FAIL",n);fflush(stdout);}while(0)
static gboolean save_fixture(Gimp *g,GimpImage *im,const char *path){GError *err=NULL;GFile *f=g_file_new_for_path(path);GimpPlugInProcedure *p=gimp_plug_in_manager_file_procedure_find(g->plug_in_manager,GIMP_FILE_PROCEDURE_GROUP_SAVE,f,&err);GimpPDBStatusType s=p?file_save(g,im,NULL,f,p,GIMP_RUN_NONINTERACTIVE,TRUE,FALSE,FALSE,&err):GIMP_PDB_EXECUTION_ERROR;if(err){fprintf(stderr,"fixture save: %s\n",err->message);g_clear_error(&err);}g_object_unref(f);return s==GIMP_PDB_SUCCESS;}
static GlimsStatus worker(GlimsEngine *engine,gpointer work){
 GlimsLabLayerMap m={.width=4,.height=4,.count=2,.mode=GLIMS_LAB_LAYER_MAP_MODE_LAB,.storage=GLIMS_LAB_LAYER_MAP_STORAGE_U8,.encoding=GLIMS_LAB_LAYER_MAP_ENCODING_LAB_D50};
 for(guint i=0;i<2;i++)for(guint role=0;role<5;role++){guint8 *p=(guint8*)&m.entries[i]+16*role;p[14]=i+1;p[15]=role+1;}
 char *error=NULL;GimpImage *image=glims_lab_layer_storage_create(engine,&m,&error);CHECK(image&&!error,"valid layered Lab fixture creates");if(error)api->free_string(error);if(!image)return GLIMS_STATUS_OK;
 GlimsLabLayerStorage storage;gboolean valid=glims_lab_layer_storage_read(image,&storage)==GLIMS_LAB_LAYER_STORAGE_VALID;CHECK(valid,"fixture passes strict native storage validation");
 if(!valid){g_object_unref(image);return GLIMS_STATUS_OK;}
 for(guint i=0;i<2;i++)for(guint role=0;role<4;role++){
  guint8 values[16];memset(values,role==3?255:role==0?(i?255:128):128,sizeof values);
  GimpDrawable *d=GIMP_DRAWABLE(storage.layers[i].planes[role]);gegl_buffer_set(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,4,4),0,gimp_drawable_get_format(d),values,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(d,0,0,4,4);
 }
 GList *private_selection=g_list_prepend(NULL,storage.layers[0].planes[0]);
 gimp_image_set_selected_layers(image,private_selection);g_list_free(private_selection);
 CHECK(gimp_image_get_selected_layers(image) &&
       gimp_image_get_selected_layers(image)->data==storage.layers[0].planes[0],
       "fixture initially selects a private scalar plane");
 gchar *path=g_build_filename((const gchar*)work,"layered-lab.xcf",NULL);gboolean saved=save_fixture(engine->gimp,image,path);CHECK(saved,"valid layered carrier saves as XCF");g_object_unref(image);if(!saved){g_free(path);return GLIMS_STATUS_OK;}
 gchar *before=NULL,*after=NULL;gsize before_size=0,after_size=0;CHECK(g_file_get_contents(path,&before,&before_size,NULL),"source XCF bytes captured");
 GlimsImageID id=0;error=NULL;GlimsStatus s=api->image_open(engine,path,&id,&error);printf("OPEN status=%d id=%d error=%s\n",s,id,error?error:"");CHECK(s==GLIMS_STATUS_OK&&id!=0,"public open accepts valid layered Lab XCF");if(error)api->free_string(error);
 if(s==GLIMS_STATUS_OK&&id){
  guint8 info_bytes[sizeof(GlimsImageStorageInfo)+2];memset(info_bytes,0xa5,sizeof info_bytes);
  guint32 info_size=sizeof(GlimsImageStorageInfo);memcpy(info_bytes+1,&info_size,sizeof info_size);
  s=api->image_storage_info(engine,id,(GlimsImageStorageInfo*)(info_bytes+1));
  GlimsImageStorageInfo layout;memcpy(&layout,info_bytes+1,sizeof layout);
  CHECK(s==GLIMS_STATUS_OK&&layout.layout==GLIMS_IMAGE_LAYOUT_LAYERED_LAB&&
        (layout.flags&GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES)&&!(layout.flags&GLIMS_IMAGE_STORAGE_READ_ONLY)&&
        info_bytes[0]==0xa5&&info_bytes[sizeof info_bytes-1]==0xa5,
        "size-versioned unaligned layout reports limited layer-property editing");
  guint8 short_info[sizeof(GlimsImageStorageInfo)+2],saved_short[sizeof short_info];
  memset(short_info,0xa5,sizeof short_info);info_size=sizeof(GlimsImageStorageInfo)-1;
  memcpy(short_info+1,&info_size,sizeof info_size);memcpy(saved_short,short_info,sizeof short_info);
  CHECK(api->image_storage_info(engine,id,(GlimsImageStorageInfo*)(short_info+1))==GLIMS_STATUS_INVALID_ARGUMENT&&
        !memcmp(short_info,saved_short,sizeof short_info),"short layout output is refused without writing");
  guint8 extended[sizeof(GlimsImageStorageInfo)+8];memset(extended,0xa5,sizeof extended);
  info_size=sizeof extended;memcpy(extended,&info_size,sizeof info_size);
  CHECK(api->image_storage_info(engine,id,(GlimsImageStorageInfo*)extended)==GLIMS_STATUS_OK &&
        !memcmp(extended+sizeof(GlimsImageStorageInfo),"\xa5\xa5\xa5\xa5\xa5\xa5\xa5\xa5",8),
        "extended layout output leaves its unknown tail untouched");
  CHECK(api->image_storage_info(engine,id,NULL)==GLIMS_STATUS_INVALID_ARGUMENT,
        "null layout output is refused");
  GlimsImageStorageInfo absent={.struct_size=sizeof absent};
  CHECK(api->image_storage_info(engine,0,&absent)==GLIMS_STATUS_NOT_FOUND,
        "layout query for an unknown image is refused");
  GlimsColorInfo color;CHECK(api->image_color_info(engine,id,&color)==GLIMS_STATUS_OK&&color.mode==GLIMS_COLOR_MODE_LAB,"public color info reports Lab");
  GlimsLayerInfo rows[8];int32_t count=0;CHECK(api->image_layers(engine,id,rows,8,&count)==GLIMS_STATUS_OK&&count==2,"only two logical layer roots are exposed");
  if(count==2){
   CHECK(rows[0].depth==0&&rows[1].depth==0&&rows[0].parent==0&&rows[1].parent==0,"logical rows are top-level");
   int32_t initial_count=0;GlimsItemID initial[8]={0};
   CHECK(api->image_selected_layers(engine,id,initial,8,&initial_count)==GLIMS_STATUS_OK&&
         initial_count==1&&initial[0]==rows[0].id,
         "private XCF selection is normalized to its logical root");
   int32_t item_count=0;GlimsItemID items[8]={0};
   CHECK(api->image_selected_items(engine,id,GLIMS_ITEM_SET_LAYER,items,8,&item_count)==GLIMS_STATUS_OK&&
         item_count==1&&items[0]==rows[0].id,
         "generic selected-items query exposes only the logical root");
   CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_OK,"selecting a logical root succeeds");
   GlimsLayerChange visibility={.struct_size=sizeof visibility,.properties=GLIMS_LAYER_VISIBLE,.visible=FALSE};
   error=NULL;GlimsStatus changed=api->layer_change(engine,id,rows[0].id,&visibility,&error);
   CHECK(changed==GLIMS_STATUS_OK,"logical Lab layer visibility can be edited");
   if(error)api->free_string(error);error=NULL;
   if(changed==GLIMS_STATUS_OK){
    GlimsLayerInfo after_change[8];int32_t n=0;
    CHECK(api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&n==2&&!after_change[0].visible,
          "visibility edit updates the logical root");
    guint8 visible_pixel[4]={0};
    CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},visible_pixel,4)==GLIMS_STATUS_OK&&visible_pixel[0]>=250&&visible_pixel[3]==255,
          "visibility edit reveals the white lower layer");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"visibility change can be undone");
    CHECK(api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&n==2&&after_change[0].visible,
          "undo restores logical visibility");
    CHECK(api->image_redo(engine,id)==GLIMS_STATUS_OK,"visibility change can be redone");
    CHECK(api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&n==2&&!after_change[0].visible,
          "redo restores the visibility edit");
    CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"fixture visibility restored");
    GlimsLayerChange combined={.struct_size=sizeof combined,.properties=GLIMS_LAYER_VISIBLE|GLIMS_LAYER_OPACITY,.visible=FALSE,.opacity=.5};
    error=NULL;GlimsStatus both=api->layer_change(engine,id,rows[0].id,&combined,&error);
    CHECK(both==GLIMS_STATUS_OK,"visibility and opacity can change together");if(error)api->free_string(error);
    if(both==GLIMS_STATUS_OK){
     CHECK(api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&!after_change[0].visible&&fabs(after_change[0].opacity-.5)<1e-6,
           "combined layer properties are applied");
     CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK&&api->image_layers(engine,id,after_change,8,&n)==GLIMS_STATUS_OK&&
           after_change[0].visible&&fabs(after_change[0].opacity-1)<1e-6,
           "one undo restores both layer properties");
    }
    GlimsLayerChange opacity={.struct_size=sizeof opacity,.properties=GLIMS_LAYER_OPACITY,.opacity=.5};
    error=NULL;GlimsStatus adjusted=api->layer_change(engine,id,rows[0].id,&opacity,&error);
    CHECK(adjusted==GLIMS_STATUS_OK,"logical Lab layer opacity can be edited");if(error)api->free_string(error);
    if(adjusted==GLIMS_STATUS_OK){
     guint8 blended[4]={0};
     CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},blended,4)==GLIMS_STATUS_OK&&blended[0]>180&&blended[0]<250&&blended[3]==255,
           "opacity edit changes the composite while retaining opaque output");
     gchar *property_path=g_build_filename((const gchar*)work,"layered-lab-properties.xcf",NULL);error=NULL;
     GlimsStatus persisted=api->image_save_copy(engine,id,property_path,&error);
     CHECK(persisted==GLIMS_STATUS_OK,"edited Lab layer properties save as XCF");if(error)api->free_string(error);
     if(persisted==GLIMS_STATUS_OK){
      GlimsImageID reopened=0;error=NULL;GlimsStatus opened=api->image_open(engine,property_path,&reopened,&error);
      CHECK(opened==GLIMS_STATUS_OK&&reopened,"edited Lab layer properties reopen");if(error)api->free_string(error);
      if(opened==GLIMS_STATUS_OK&&reopened){
       GlimsLayerInfo persisted_rows[8];int32_t persisted_count=0;
       CHECK(api->image_layers(engine,reopened,persisted_rows,8,&persisted_count)==GLIMS_STATUS_OK&&persisted_count==2&&
             persisted_rows[0].visible&&fabs(persisted_rows[0].opacity-.5)<1e-6,
             "XCF retains edited opacity and visibility");
       GlimsOpenImage *reopened_image=glims_lookup_image(engine,reopened);GlimsLabLayerStorage persisted_storage;
       gboolean persisted_valid=reopened_image&&glims_lab_layer_storage_read(reopened_image->image,&persisted_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
       CHECK(persisted_valid&&!memcmp(&persisted_storage.map,&m,sizeof m),"edited XCF retains the Lab identity map");
       if(persisted_valid)for(guint li=0;li<2;li++)for(guint role=0;role<4;role++){
        GimpDrawable *plane=GIMP_DRAWABLE(persisted_storage.layers[li].planes[role]);guint8 raw[16];
        gegl_buffer_get(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,4,4),1,gimp_drawable_get_format(plane),raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
        guint8 expected=role==3?255:role==0?(li?255:128):128;gboolean matches=TRUE;
        for(guint px=0;px<16;px++)if(raw[px]!=expected)matches=FALSE;
        CHECK(matches,"edited XCF preserves scalar samples");
       }
       CHECK(api->image_close(engine,reopened)==GLIMS_STATUS_OK,"edited XCF copy closes");
      }
     }
     g_free(property_path);
     CHECK(api->image_undo(engine,id)==GLIMS_STATUS_OK,"opacity edit can be undone");
    }
   }
   GlimsOpenImage *open=glims_lookup_image(engine,id);GlimsLabLayerStorage current;
   gboolean intact=open&&glims_lab_layer_storage_read(open->image,&current)==GLIMS_LAB_LAYER_STORAGE_VALID;
   CHECK(intact,"adopted storage remains strictly valid");
   if(intact){
    GlimsItemID hidden=gimp_item_get_id(GIMP_ITEM(current.layers[0].planes[0]));
    GlimsUndoInfo undo_before={0},undo_after={0};
    CHECK(api->image_undo_info(engine,id,&undo_before)==GLIMS_STATUS_OK,"history captured before invalid property edits");
    CHECK(api->layer_select(engine,id,hidden)!=GLIMS_STATUS_OK,"private scalar plane cannot be selected as a public layer");
    GlimsLayerChange bad={.struct_size=sizeof bad,.properties=GLIMS_LAYER_VISIBLE,.visible=FALSE};error=NULL;
    CHECK(api->layer_change(engine,id,hidden,&bad,&error)==GLIMS_STATUS_UNSUPPORTED,
          "private scalar plane properties cannot be edited");
    if(error)api->free_string(error);error=NULL;
    bad.properties=GLIMS_LAYER_OPACITY;bad.opacity=NAN;
    CHECK(api->layer_change(engine,id,rows[0].id,&bad,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
          "non-finite opacity is refused before mutation");
    if(error)api->free_string(error);error=NULL;
    bad.properties=GLIMS_LAYER_MODE;
    CHECK(api->layer_change(engine,id,rows[0].id,&bad,&error)==GLIMS_STATUS_INVALID_ARGUMENT,
          "unsupported Lab blend-mode edits are refused before mutation");
    if(error)api->free_string(error);error=NULL;
    CHECK(api->image_undo_info(engine,id,&undo_after)==GLIMS_STATUS_OK&&
          undo_after.undo_count==undo_before.undo_count&&undo_after.redo_count==undo_before.redo_count,
          "invalid property edits leave Undo and Redo unchanged");
    GlimsItemID mixed[]={rows[0].id,hidden};error=NULL;
    CHECK(api->image_select_layers(engine,id,mixed,2,&error)!=GLIMS_STATUS_OK,
          "mixed logical and private selection is refused atomically");
    if(error)api->free_string(error);error=NULL;
    CHECK(api->image_select_items(engine,id,GLIMS_ITEM_SET_LAYER,&hidden,1,&error)==GLIMS_STATUS_UNSUPPORTED,
          "generic item selection cannot bypass logical-root admission");
    if(error)api->free_string(error);
    guint8 thumbnail[4*16*16]={0};int32_t width=0,height=0;
    CHECK(api->drawable_thumbnail(engine,id,hidden,16,thumbnail,sizeof thumbnail,&width,&height)==GLIMS_STATUS_UNSUPPORTED,
          "private scalar plane thumbnail is unavailable");
    int32_t selected_count=0;GlimsItemID selected[8]={0};
    CHECK(api->image_selected_layers(engine,id,selected,8,&selected_count)==GLIMS_STATUS_OK&&selected_count==1&&selected[0]==rows[0].id,
          "rejected hidden-plane selection preserves the logical root");
   }
   GlimsItemID result=0;error=NULL;
   CHECK(api->layer_command(engine,id,rows[0].id,GLIMS_LAYER_DELETE,&result,&error)==GLIMS_STATUS_UNSUPPORTED,
         "ordinary delete is quarantined for read-only layered Lab");
   if(error)api->free_string(error);
  }
  GlimsPixelBuffer copied={0};error=NULL;
  CHECK(api->image_copy_pixels(engine,id,TRUE,&copied,&error)==GLIMS_STATUS_UNSUPPORTED,
        "ordinary merged clipboard copy is quarantined");
  if(error)api->free_string(error);if(copied.pixels)api->free_pixels(copied.pixels);
  cmsHPROFILE lab=cmsCreateLab4Profile(NULL),rgb=cmsCreate_sRGBProfile();cmsHTRANSFORM transform=lab&&rgb?cmsCreateTransform(lab,TYPE_Lab_DBL,rgb,TYPE_RGB_DBL,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE):NULL;
  double input[3]={100.0*128/255,0,0},expected[3]={0};CHECK(transform!=NULL,"independent Lab to sRGB oracle creates");if(transform)cmsDoTransform(transform,input,expected,1);
  const double scales[]={1,.75,1.3};for(unsigned i=0;i<3;i++){guint8 pixel[4]={0};s=api->image_render(engine,id,scales[i],(GlimsRect){1,1,1,1},pixel,4);CHECK(s==GLIMS_STATUS_OK,"public layered Lab render succeeds");if(transform&&s==GLIMS_STATUS_OK){for(unsigned c=0;c<3;c++)CHECK(abs((int)pixel[c]-(int)floor(fmin(1,fmax(0,expected[c]))*255+.5))<=3,"rendered Lab color matches independent LCMS");CHECK(pixel[3]==255,"opaque logical layer remains opaque");}}
  cmsUInt32Number icc_size=0;guint8 *icc=NULL;
  if(rgb&&cmsSaveProfileToMem(rgb,NULL,&icc_size)&&icc_size){icc=g_malloc(icc_size);if(!cmsSaveProfileToMem(rgb,icc,&icc_size))g_clear_pointer(&icc,g_free);}
  CHECK(icc!=NULL,"independent sRGB destination profile serializes");
  if(icc){
   for(unsigned i=0;i<3;i++){
    guint8 pixel[4]={0};error=NULL;
    s=api->image_render_to_profile(engine,id,scales[i],(GlimsRect){1,1,1,1},icc,icc_size,pixel,4,&error);
    CHECK(s==GLIMS_STATUS_OK,"profile-aware layered Lab render succeeds");if(error)api->free_string(error);
    if(transform&&s==GLIMS_STATUS_OK){for(unsigned c=0;c<3;c++)CHECK(abs((int)pixel[c]-(int)floor(fmin(1,fmax(0,expected[c]))*255+.5))<=3,"profile-aware Lab color matches independent LCMS");CHECK(pixel[3]==255,"profile-aware logical layer remains opaque");}
   }
   GlimsProofSettings proof={.struct_size=sizeof proof,.proof_intent=GLIMS_PROFILE_RELATIVE_COLORIMETRIC,.display_intent=GLIMS_PROFILE_RELATIVE_COLORIMETRIC};
   guint8 pixel[4]={0};error=NULL;
   s=api->image_render_proofed(engine,id,1,(GlimsRect){1,1,1,1},icc,icc_size,icc,icc_size,&proof,pixel,4,&error);
   CHECK(s==GLIMS_STATUS_UNSUPPORTED,"unqualified layered Lab soft proof is refused");if(error)api->free_string(error);
  }
  g_free(icc);
  if(transform)cmsDeleteTransform(transform);if(lab)cmsCloseProfile(lab);if(rgb)cmsCloseProfile(rgb);
  gchar *copy_path=g_build_filename((const gchar*)work,"layered-lab-copy.xcf",NULL);error=NULL;
  s=api->image_save_copy(engine,id,copy_path,&error);
  CHECK(s==GLIMS_STATUS_OK,"public Save Copy preserves layered Lab format");if(error)api->free_string(error);
  if(s==GLIMS_STATUS_OK){
   GlimsImageID copy_id=0;error=NULL;GlimsStatus opened=api->image_open(engine,copy_path,&copy_id,&error);
   CHECK(opened==GLIMS_STATUS_OK&&copy_id!=0,"saved layered Lab copy reopens");if(error)api->free_string(error);
   if(opened==GLIMS_STATUS_OK&&copy_id){
    GlimsOpenImage *copy=glims_lookup_image(engine,copy_id);GlimsLabLayerStorage readback;
    gboolean valid_copy=copy&&glims_lab_layer_storage_read(copy->image,&readback)==GLIMS_LAB_LAYER_STORAGE_VALID;
    CHECK(valid_copy && !memcmp(&readback.map,&m,sizeof m),"saved copy preserves the full Lab identity map");
    if(valid_copy)for(guint i=0;i<2;i++)for(guint role=0;role<4;role++){
     GimpDrawable *d=GIMP_DRAWABLE(readback.layers[i].planes[role]);const Babl *fmt=gimp_drawable_get_format(d);
     guint8 raw[16];memset(raw,0,sizeof raw);
     gboolean one_byte=babl_format_get_n_components(fmt)==1&&babl_format_get_bytes_per_pixel(fmt)==1;
     CHECK(one_byte,"saved scalar plane retains one-byte samples");
     if(one_byte){gegl_buffer_get(gimp_drawable_get_buffer(d),GEGL_RECTANGLE(0,0,4,4),1,fmt,raw,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
      guint8 expected_byte=role==3?255:role==0?(i?255:128):128;gboolean matches=TRUE;
      for(guint p=0;p<16;p++)if(raw[p]!=expected_byte)matches=FALSE;
      CHECK(matches,"saved scalar plane preserves every sample");}
    }
    CHECK(api->image_close(engine,copy_id)==GLIMS_STATUS_OK,"saved copy closes");
   }
  }
  g_free(copy_path);
  /* Exercise the public display conversions with a translucent source and
   * transparent abyss, using LCMS independently for the expected color. */
  GlimsOpenImage *alpha_open=glims_lookup_image(engine,id);GlimsLabLayerStorage alpha_storage;
  gboolean alpha_valid=alpha_open&&glims_lab_layer_storage_read(alpha_open->image,&alpha_storage)==GLIMS_LAB_LAYER_STORAGE_VALID;
  CHECK(alpha_valid,"storage is valid for translucent display probe");
  if(alpha_valid){
   for(guint i=0;i<2;i++){
    guint8 alpha[16];memset(alpha,i==0?128:0,sizeof alpha);
    GimpDrawable *plane=GIMP_DRAWABLE(alpha_storage.layers[i].planes[3]);
    gegl_buffer_set(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,4,4),0,gimp_drawable_get_format(plane),alpha,GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update(plane,0,0,4,4);
   }
   cmsHPROFILE lp=cmsCreateLab4Profile(NULL),sp=cmsCreate_sRGBProfile();
   cmsHTRANSFORM tx=lp&&sp?cmsCreateTransform(lp,TYPE_Lab_DBL,sp,TYPE_RGB_DBL,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE):NULL;
   double lab_pixel[3]={100.0*128/255,0,0},rgb_pixel[3]={0};
   CHECK(tx!=NULL,"translucent display oracle creates");if(tx)cmsDoTransform(tx,lab_pixel,rgb_pixel,1);
   guint8 out[28];memset(out,0xa5,sizeof out);
   s=api->image_render(engine,id,1,(GlimsRect){0,0,2,2},out+1,13);
   CHECK(s==GLIMS_STATUS_OK&&out[0]==0xa5&&out[9]==0xa5&&out[13]==0xa5&&out[22]==0xa5&&out[27]==0xa5,
         "unaligned translucent render preserves row padding and guards");
   if(tx&&s==GLIMS_STATUS_OK)for(guint y=0;y<2;y++)for(guint x=0;x<2;x++){
    guint8 *p=out+1+y*13+x*4;gboolean match=abs((int)p[3]-128)<=1;
    for(guint c=0;c<3;c++)if(abs((int)p[c]-(int)floor(fmin(1,fmax(0,rgb_pixel[c]))*128+.5))>3)match=FALSE;
    CHECK(match,"translucent public render matches premultiplied LCMS color");
   }
   cmsUInt32Number profile_size=0;guint8 *profile=NULL;
   if(sp&&cmsSaveProfileToMem(sp,NULL,&profile_size)&&profile_size){
    profile=g_malloc(profile_size);if(!cmsSaveProfileToMem(sp,profile,&profile_size))g_clear_pointer(&profile,g_free);
   }
   CHECK(profile!=NULL,"translucent destination profile serializes");
   if(profile){
    guint8 profiled[4]={0};error=NULL;
    s=api->image_render_to_profile(engine,id,1,(GlimsRect){1,1,1,1},profile,profile_size,profiled,4,&error);
    gboolean match=s==GLIMS_STATUS_OK&&abs((int)profiled[3]-128)<=1;
    if(tx)for(guint c=0;c<3;c++)if(abs((int)profiled[c]-(int)floor(fmin(1,fmax(0,rgb_pixel[c]))*128+.5))>3)match=FALSE;
    CHECK(tx&&match,"profile-aware translucent render matches premultiplied LCMS color");
    if(error)api->free_string(error);g_free(profile);
   }
   guint8 zero[16]={0};GimpDrawable *plane=GIMP_DRAWABLE(alpha_storage.layers[0].planes[3]);
   gegl_buffer_set(gimp_drawable_get_buffer(plane),GEGL_RECTANGLE(0,0,4,4),0,gimp_drawable_get_format(plane),zero,GEGL_AUTO_ROWSTRIDE);
   gimp_drawable_update(plane,0,0,4,4);
   guint8 transparent[4]={0x5a,0x5a,0x5a,0x5a};
   CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},transparent,4)==GLIMS_STATUS_OK &&
         transparent[0]==0&&transparent[1]==0&&transparent[2]==0&&transparent[3]==0,
         "transparent Lab display is canonical transparent black after alpha change");
   if(tx)cmsDeleteTransform(tx);if(lp)cmsCloseProfile(lp);if(sp)cmsCloseProfile(sp);
  }
  /* Corrupt only the in-memory copy after a successful save. Every admitted
   * operation must revalidate the carrier, while close must remain possible. */
  GlimsOpenImage *damaged=glims_lookup_image(engine,id);
  CHECK(damaged!=NULL,"open image remains available for damaged-storage probe");
  if(damaged){
   gimp_image_parasite_detach(damaged->image,GLIMS_PLATE_MAP_PARASITE,FALSE);
   GlimsImageStorageInfo damaged_info={.struct_size=sizeof damaged_info};
   CHECK(api->image_storage_info(engine,id,&damaged_info)==GLIMS_STATUS_UNSUPPORTED,
         "storage query rejects a damaged adopted carrier");
   guint8 pixel[4]={0x5a,0x5a,0x5a,0x5a};
   CHECK(api->image_render(engine,id,1,(GlimsRect){1,1,1,1},pixel,4)==GLIMS_STATUS_UNSUPPORTED &&
         pixel[0]==0x5a&&pixel[1]==0x5a&&pixel[2]==0x5a&&pixel[3]==0x5a,
         "render rejects damaged storage without writing output");
   if(count==2)CHECK(api->layer_select(engine,id,rows[0].id)==GLIMS_STATUS_UNSUPPORTED,
                     "selection rejects damaged storage");
   GlimsLayerChange damaged_change={.struct_size=sizeof damaged_change,.properties=GLIMS_LAYER_VISIBLE,.visible=FALSE};error=NULL;
   if(count==2)CHECK(api->layer_change(engine,id,rows[0].id,&damaged_change,&error)==GLIMS_STATUS_UNSUPPORTED,
                     "layer edits reject damaged storage");
   if(error)api->free_string(error);error=NULL;
   CHECK(api->image_undo(engine,id)==GLIMS_STATUS_UNSUPPORTED&&api->image_redo(engine,id)==GLIMS_STATUS_UNSUPPORTED,
         "Undo and Redo reject damaged storage");
   gchar *damaged_path=g_build_filename((const gchar*)work,"damaged-copy.xcf",NULL);error=NULL;
   CHECK(api->image_save_copy(engine,id,damaged_path,&error)==GLIMS_STATUS_UNSUPPORTED &&
         !g_file_test(damaged_path,G_FILE_TEST_EXISTS),"save copy rejects damaged storage without creating a file");
   if(error)api->free_string(error);g_free(damaged_path);
  }
  CHECK(api->image_close(engine,id)==GLIMS_STATUS_OK,"public layered Lab image closes");
 }
 CHECK(g_file_get_contents(path,&after,&after_size,NULL)&&before&&before_size==after_size&&!memcmp(before,after,before_size),"open/read leaves source XCF bytes unchanged");g_free(before);g_free(after);g_free(path);return GLIMS_STATUS_OK;
}
int main(int argc,char **argv){if(argc!=2)return 2;api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api)return 2;gchar *u=g_build_filename(argv[1],"user",NULL),*c=g_build_filename(argv[1],"cache",NULL);GlimsEngineConfig cfg={.struct_size=sizeof cfg,.user_directory=u,.cache_directory=c};GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus s=api->start(&cfg,&engine,&error);g_free(u);g_free(c);if(s||!engine){fprintf(stderr,"start: %s\n",error?error:"");api->free_string(error);return 2;}api->free_string(error);s=glims_engine_call(engine,worker,argv[1]);api->stop(engine);printf("checks=%u failures=%u\n",checks,failures);return s==GLIMS_STATUS_OK&&!failures?0:1;}

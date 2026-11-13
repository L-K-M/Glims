/* Independent ordinary display sampling: Core seeds, public facade reads. */
#include "engine-private.h"
#include "display-sample.h"
#include <cairo.h>
#include <lcms2.h>
#include "gegl/gimptilehandlervalidate.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "libgimpcolor/gimpcolor.h"
static const GlimsEngineAPI *api;static unsigned checks,failures;
#define CHECK(c,msg) do{gboolean ok_=!!(c);checks++;if(!ok_)failures++;printf("%s %s\n",ok_?"ok":"FAIL",msg);fflush(stdout);}while(0)
typedef struct {guint8 *data;gsize size;cmsHPROFILE profile;} ICC;
static ICC srgb,linear,gray;
static gboolean load_icc(const char *dir,const char *name,ICC *out){gchar *path=g_build_filename(dir,name,NULL);gchar *bytes=NULL;gsize size=0;gboolean ok=g_file_get_contents(path,&bytes,&size,NULL);g_free(path);if(!ok)return FALSE;out->data=(guint8*)bytes;out->size=size;out->profile=cmsOpenProfileFromMem(bytes,(cmsUInt32Number)size);return out->profile!=NULL;}
static gboolean srgb_new(void){srgb.profile=cmsCreate_sRGBProfile();cmsUInt32Number size=0;if(!srgb.profile||!cmsSaveProfileToMem(srgb.profile,NULL,&size))return FALSE;srgb.data=g_malloc(size);srgb.size=size;return cmsSaveProfileToMem(srgb.profile,srgb.data,&size);}
static void icc_free(ICC *p){if(p->profile)cmsCloseProfile(p->profile);g_free(p->data);memset(p,0,sizeof *p);}
typedef struct {GlimsImageID id;GimpImage *image;GimpLayer *layer;guint w,h,channels;gboolean gray;ICC *profile;float color[3];} Fixture;
static void fill_source(Fixture *f,guint pattern,const float *color){gsize n=(gsize)f->w*f->h*f->channels;float *raw=g_new0(float,n);for(guint y=0;y<f->h;y++)for(guint x=0;x<f->w;x++){float *p=raw+f->channels*(y*f->w+x);for(guint c=0;c<f->channels-1;c++)p[c]=color[c];p[f->channels-1]=pattern==0?(x==f->w-1&&y==f->h-1):pattern==1?((x+y)%2==0):1;}
 const Babl *fmt=gimp_drawable_get_format(GIMP_DRAWABLE(f->layer));gboolean safe=babl_format_get_n_components(fmt)==(gint)f->channels&&babl_format_get_bytes_per_pixel(fmt)==(gint)(f->channels*sizeof(float));CHECK(safe,"fixture independently guards native float buffer width");if(safe){gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(f->layer)),GEGL_RECTANGLE(0,0,f->w,f->h),0,fmt,raw,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(GIMP_DRAWABLE(f->layer),0,0,f->w,f->h);}g_free(raw);}
static gboolean fixture_new(GlimsEngine *e,Fixture *f,gboolean is_gray,ICC *profile,guint w,guint h,gboolean linear_precision,guint pattern,const float *color){memset(f,0,sizeof *f);f->w=w;f->h=h;f->channels=is_gray?2:4;f->gray=is_gray;f->profile=profile;memcpy(f->color,color,sizeof f->color);
 GimpImage *im=gimp_create_image(e->gimp,w,h,is_gray?GIMP_GRAY:GIMP_RGB,linear_precision?GIMP_PRECISION_FLOAT_LINEAR:GIMP_PRECISION_FLOAT_NON_LINEAR,FALSE);if(!im)return FALSE;gimp_image_undo_disable(im);
 if(profile!=&srgb){GError *error=NULL;GimpColorProfile *native=gimp_color_profile_new_from_icc_profile(profile->data,profile->size,&error);gboolean ok=native&&gimp_image_set_color_profile(im,native,&error);g_clear_object(&native);g_clear_error(&error);if(!ok){g_object_unref(im);return FALSE;}}
 GimpLayer *layer=gimp_layer_new(im,w,h,gimp_image_get_layer_format(im,TRUE),"Sampling source",1,GIMP_LAYER_MODE_NORMAL);if(!layer||!gimp_image_add_layer(im,layer,NULL,0,FALSE)){if(layer)g_object_unref(layer);g_object_unref(im);return FALSE;}f->image=im;f->layer=layer;fill_source(f,pattern,color);gimp_image_undo_enable(im);gimp_image_clean_all(im);
 if(glims_adopt_image(e,im,&f->id)!=GLIMS_STATUS_OK){g_object_unref(im);memset(f,0,sizeof *f);return FALSE;}return TRUE;}
typedef struct {GBytes *raw,*mask,*profile;GlimsImageInfo info;GlimsUndoInfo undo;guint64 revision;gint dirty;gint64 dirty_time;} Snapshot;
static GBytes *buffer_bytes(GeglBuffer *b){const Babl *fmt=gegl_buffer_get_format(b);const GeglRectangle *r=gegl_buffer_get_extent(b);gint bpp=babl_format_get_bytes_per_pixel(fmt);if(r->width<0||r->height<0||bpp<=0||bpp>32||(gsize)r->width*r->height>100000)return NULL;gsize n=(gsize)r->width*r->height*bpp;guint8 *bytes=g_malloc(n);gegl_buffer_get(b,r,1,fmt,bytes,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);return g_bytes_new_take(bytes,n);}
static gboolean snapshot(GlimsEngine *e,Fixture *f,Snapshot *s){memset(s,0,sizeof *s);s->raw=buffer_bytes(gimp_drawable_get_buffer(GIMP_DRAWABLE(f->layer)));s->mask=buffer_bytes(gimp_drawable_get_buffer(GIMP_DRAWABLE(gimp_image_get_mask(f->image))));const GimpParasite *p=gimp_image_parasite_find(f->image,GIMP_ICC_PROFILE_PARASITE_NAME);guint32 n=0;const void *data=p?gimp_parasite_get_data(p,&n):NULL;s->profile=g_bytes_new(data,n);s->dirty=gimp_image_is_dirty(f->image);s->dirty_time=gimp_image_get_dirty_time(f->image);GlimsOpenImage *open=glims_lookup_image(e,f->id);if(!open)return FALSE;s->revision=open->history_revision;return s->raw&&s->mask&&api->image_info(e,f->id,&s->info)==GLIMS_STATUS_OK&&api->image_undo_info(e,f->id,&s->undo)==GLIMS_STATUS_OK;}
static void snap_free(Snapshot *s){g_clear_pointer(&s->raw,g_bytes_unref);g_clear_pointer(&s->mask,g_bytes_unref);g_clear_pointer(&s->profile,g_bytes_unref);}
static gboolean equal_snap(const Snapshot *a,const Snapshot *b){return a->raw&&b->raw&&a->mask&&b->mask&&a->profile&&b->profile&&g_bytes_equal(a->raw,b->raw)&&g_bytes_equal(a->mask,b->mask)&&g_bytes_equal(a->profile,b->profile)&&!memcmp(&a->info,&b->info,sizeof a->info)&&!memcmp(&a->undo,&b->undo,sizeof a->undo)&&a->revision==b->revision&&a->dirty==b->dirty&&a->dirty_time==b->dirty_time;}
static void oracle_color(Fixture *f,ICC *destination,gboolean proof,const double *source,double out[3]){cmsUInt32Number type=f->gray?TYPE_GRAY_DBL:TYPE_RGB_DBL;cmsHTRANSFORM transform=proof?cmsCreateProofingTransform(f->profile->profile,type,destination->profile,TYPE_RGB_DBL,srgb.profile,INTENT_RELATIVE_COLORIMETRIC,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_SOFTPROOFING|cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE):cmsCreateTransform(f->profile->profile,type,destination->profile,TYPE_RGB_DBL,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE);CHECK(transform!=NULL,"independent LCMS transform constructs");if(!transform){out[0]=out[1]=out[2]=NAN;return;}cmsDoTransform(transform,source,out,1);cmsDeleteTransform(transform);}
static GlimsStatus render(GlimsEngine *e,Fixture *f,guint route,ICC *dest,double scale,GlimsRect area,guint8 *out,gsize stride){char *error=NULL;GlimsStatus status;if(route==0)status=api->image_render(e,f->id,scale,area,out,stride);else if(route==1)status=api->image_render_to_profile(e,f->id,scale,area,dest->data,dest->size,out,stride,&error);else{GlimsProofSettings settings={sizeof settings,GLIMS_PROFILE_RELATIVE_COLORIMETRIC,GLIMS_PROFILE_RELATIVE_COLORIMETRIC,0};status=api->image_render_proofed(e,f->id,scale,area,dest->data,dest->size,srgb.data,srgb.size,&settings,out,stride,&error);}if(error){printf("render error=%s\n",error);api->free_string(error);}return status;}
static gint byte(double v){return(gint)floor(fmin(1,fmax(0,v))*255+.5);}
static void pixel_expected(const guint8 *actual,const double rgb[3],double alpha){for(guint c=0;c<4;c++){gint expected=byte(c==3?alpha:rgb[c]*alpha);if(abs((gint)actual[c]-expected)>2)printf("MISMATCH c=%u actual=%u expected=%d alpha=%g\n",c,actual[c],expected,alpha);CHECK(abs((gint)actual[c]-expected)<=2,"facade pixel matches independent spatial/color/premultiply oracle");}if(alpha==0)CHECK(actual[0]==0&&actual[1]==0&&actual[2]==0&&actual[3]==0,"zero coverage is canonical transparent bytes");}
static double checker_alpha(guint w,guint h,gint x,gint y,double scale){long double sx=((long double)x+.5L)/(long double)scale-.5L,sy=((long double)y+.5L)/(long double)scale-.5L;gint left=floorl(sx),top=floorl(sy);long double tx=sx-left,ty=sy-top;const long double weights[4]={(1-tx)*(1-ty),tx*(1-ty),(1-tx)*ty,tx*ty};long double sum=0;for(guint k=0;k<4;k++){gint xx=left+k%2,yy=top+k/2;if(xx>=0&&yy>=0&&xx<(gint)w&&yy<(gint)h&&(xx+yy)%2==0)sum+=weights[k];}return(double)sum;}
static void constant_checks(GlimsEngine *e,Fixture *f,guint pattern){Snapshot before,after;CHECK(snapshot(e,f,&before),"source baseline captures raw/profile/mask/history");const double src[3]={f->color[0],f->color[1],f->color[2]};
 for(guint route=0;route<3;route++){ICC *dest=route==1?&linear:&srgb;double rgb[3];oracle_color(f,dest,route==2,src,rgb);guint8 out[8]={0};printf("CASE model=%s source=%s pattern=%u route=%u\n",f->gray?"Gray":"RGB",f->profile==&srgb?"sRGB":f->profile==&linear?"linearRGB":"grayGamma22",pattern,route);
  if(route==0){GlimsRect point=pattern?(GlimsRect){0,0,1,1}:(GlimsRect){3,3,1,1};CHECK(render(e,f,0,&srgb,1,point,out,4)==GLIMS_STATUS_OK,"legacy unit-scale positive source/profile compatibility");pixel_expected(out,rgb,1);}
if(pattern==0){CHECK(render(e,f,route,dest,1,(GlimsRect){3,3,1,1},out,4)==GLIMS_STATUS_OK,"unit-scale opaque source/profile baseline succeeds");pixel_expected(out,rgb,1);CHECK(render(e,f,route,dest,1.25,(GlimsRect){3,3,1,1},out,4)==GLIMS_STATUS_OK,"fractional corner render succeeds");pixel_expected(out,rgb,.09);}else{CHECK(render(e,f,route,dest,.5,(GlimsRect){0,0,1,1},out,4)==GLIMS_STATUS_OK,"dyadic transparent checker render succeeds");pixel_expected(out,rgb,.5);}
  if(pattern==1){guint8 reduced[3*3*4];memset(reduced,0,sizeof reduced);CHECK(render(e,f,route,dest,.75,(GlimsRect){0,0,3,3},reduced,12)==GLIMS_STATUS_OK,"non-dyadic reduction succeeds");guint partial=0;for(guint i=0;i<9;i++){double a=reduced[i*4+3]/255.;if(a>0&&a<1)partial++;for(guint c=0;c<3;c++)CHECK(abs((int)reduced[4*i+c]-byte(rgb[c]*a))<=2,"non-dyadic covered-color invariant has no nonlinear transparent fringe");}CHECK(partial>0,"non-dyadic test positively has fractional alpha");}}
 CHECK(snapshot(e,f,&after)&&equal_snap(&before,&after),"ordinary renders preserve source pixels/profile/mask/history/dirty");snap_free(&after);snap_free(&before);}
static void wide_checks(GlimsEngine *e){const float color[3]={.8f,.2f,.1f};Fixture f;CHECK(fixture_new(e,&f,FALSE,&srgb,267,3,FALSE,1,color),"odd-width RGB fixture creates");if(!f.id)return;double src[3]={color[0],color[1],color[2]},rgb[3];oracle_color(&f,&srgb,FALSE,src,rgb);Snapshot before,after;CHECK(snapshot(e,&f,&before),"wide source snapshot");guint width=348,height=4;guint8 *full=g_malloc0(width*height*4),*split=g_malloc0(width*height*4);CHECK(render(e,&f,1,&srgb,1.3,(GlimsRect){0,0,width,height},full,width*4)==GLIMS_STATUS_OK,"odd full-frame magnification succeeds");
 for(guint y=0;y<height;y++)for(guint x=0;x<width;x++)pixel_expected(full+4*(y*width+x),rgb,checker_alpha(f.w,f.h,x,y,1.3));
 CHECK(render(e,&f,1,&srgb,1.3,(GlimsRect){0,0,256,height},split,width*4)==GLIMS_STATUS_OK,"left partition succeeds");CHECK(render(e,&f,1,&srgb,1.3,(GlimsRect){256,0,width-256,height},split+256*4,width*4)==GLIMS_STATUS_OK,"offset right partition succeeds");CHECK(!memcmp(full,split,width*height*4),"global magnification is byte-identical across 256-pixel partition");CHECK(snapshot(e,&f,&after)&&equal_snap(&before,&after),"odd reads preserve exact source state");snap_free(&after);snap_free(&before);g_free(split);g_free(full);CHECK(api->image_close(e,f.id)==GLIMS_STATUS_OK,"odd fixture closes");}
static void hdr_checks(GlimsEngine *e){const float color[3]={1,0,.5};Fixture f;CHECK(fixture_new(e,&f,FALSE,&linear,2,2,TRUE,2,color),"linear float HDR fixture creates");if(!f.id)return;const Babl *fmt=gimp_drawable_get_format(GIMP_DRAWABLE(f.layer));float raw[16]={-1,2,.5,1,1,0,.5,1,1,0,.5,1,1,0,.5,1};gegl_buffer_set(gimp_drawable_get_buffer(GIMP_DRAWABLE(f.layer)),GEGL_RECTANGLE(0,0,2,2),0,fmt,raw,GEGL_AUTO_ROWSTRIDE);gimp_drawable_update(GIMP_DRAWABLE(f.layer),0,0,2,2);float actual[16];gegl_buffer_get(gimp_drawable_get_buffer(GIMP_DRAWABLE(f.layer)),GEGL_RECTANGLE(0,0,2,2),1,fmt,actual,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);CHECK(!memcmp(raw,actual,sizeof raw),"signed and extended source values positively survive seeding");double mean[3]={.5,.5,.5};for(guint route=1;route<3;route++){ICC *dest=route==1?&linear:&srgb;double rgb[3];oracle_color(&f,dest,route==2,mean,rgb);guint8 pixel[4];CHECK(render(e,&f,route,dest,.5,(GlimsRect){0,0,1,1},pixel,4)==GLIMS_STATUS_OK,"HDR dyadic reduction succeeds");pixel_expected(pixel,rgb,1);}CHECK(api->image_close(e,f.id)==GLIMS_STATUS_OK,"HDR fixture closes");}
static void freshness_and_guards(GlimsEngine *e){const float color[3]={1,0,0};Fixture f;CHECK(fixture_new(e,&f,FALSE,&srgb,4,4,FALSE,0,color),"freshness fixture creates");if(!f.id)return;Snapshot baseline,after;CHECK(snapshot(e,&f,&baseline),"freshness baseline snapshot");guint8 pixel[4];CHECK(render(e,&f,1,&srgb,1.25,(GlimsRect){3,3,1,1},pixel,4)==GLIMS_STATUS_OK,"initial fractional cache warms");gimp_drawable_push_undo(GIMP_DRAWABLE(f.layer),"sampling fixture",NULL,0,0,4,4);const float edited[3]={0,1,0};fill_source(&f,2,edited);double green[3]={0,1,0};CHECK(render(e,&f,1,&srgb,1.25,(GlimsRect){3,3,1,1},pixel,4)==GLIMS_STATUS_OK,"post-edit render refreshes");pixel_expected(pixel,green,1);CHECK(api->image_undo(e,f.id)==GLIMS_STATUS_OK,"native pixel edit Undo succeeds");double red[3]={1,0,0};CHECK(render(e,&f,1,&srgb,1.25,(GlimsRect){3,3,1,1},pixel,4)==GLIMS_STATUS_OK,"post-Undo render refreshes");pixel_expected(pixel,red,.09);
 Snapshot guard_before;CHECK(snapshot(e,&f,&guard_before),"bounds/BUSY read-only baseline after legitimate Undo");
 guint8 out[32],saved[32];memset(out,0xa5,sizeof out);memcpy(saved,out,sizeof out);const double invalid[]={0,NAN,INFINITY,33};for(guint i=0;i<G_N_ELEMENTS(invalid);i++){CHECK(render(e,&f,1,&srgb,invalid[i],(GlimsRect){0,0,1,1},out,4)==GLIMS_STATUS_INVALID_ARGUMENT,"invalid scale refuses");CHECK(!memcmp(out,saved,sizeof out),"invalid render preserves whole output");}CHECK(render(e,&f,1,&srgb,.75,(GlimsRect){0,0,2,1},out,7)==GLIMS_STATUS_INVALID_ARGUMENT&&!memcmp(out,saved,sizeof out),"bad stride refuses before output");
 e->busy++;for(guint route=1;route<3;route++)CHECK(render(e,&f,route,&srgb,.75,(GlimsRect){0,0,1,1},out,4)==GLIMS_STATUS_OK,"sampling profile/proof render remains viewable during global plugin BUSY");CHECK(render(e,&f,0,&srgb,.75,(GlimsRect){0,0,1,1},out,4)==GLIMS_STATUS_OK,"legacy render retains read admission");CHECK(render(e,&f,1,&srgb,1,(GlimsRect){0,0,1,1},out,4)==GLIMS_STATUS_OK,"unit profile render retains read admission");e->busy--;
 GlimsOpenImage *open=glims_lookup_image(e,f.id);
 CHECK(open!=NULL,"sampler reentry control resolves captured image");
 if(open){
  open->display_sample_active=TRUE;
  memset(out,0xa5,sizeof out);memcpy(saved,out,sizeof out);
  for(guint route=1;route<3;route++){
   CHECK(render(e,&f,route,&srgb,.75,(GlimsRect){0,0,1,1},out,4)==GLIMS_STATUS_BUSY,
         "actual same-image sampler reentry refuses");
   CHECK(!memcmp(out,saved,sizeof out),"sampler reentry preserves entire output");
  }
  open->display_sample_active=FALSE;
 }
 CHECK(snapshot(e,&f,&after)&&equal_snap(&guard_before,&after),"bounds/BUSY calls preserve exact source/history/dirty state");snap_free(&guard_before);
 CHECK(g_bytes_equal(baseline.raw,after.raw)&&g_bytes_equal(baseline.mask,after.mask)&&g_bytes_equal(baseline.profile,after.profile),"post-Undo raw/profile/mask restore exactly");snap_free(&after);snap_free(&baseline);CHECK(api->image_close(e,f.id)==GLIMS_STATUS_OK,"freshness fixture closes");}
static void private_tiny(void){for(guint channels=2;channels<=4;channels+=2){const Babl *fmt=babl_format(channels==2?"YA float":"RGBA float");GeglBuffer *buffer=gegl_buffer_new(GEGL_RECTANGLE(0,0,4,4),fmt);CHECK(buffer!=NULL,"tiny helper source allocates");if(!buffer)continue;float raw[64]={0};const float c[3]={-.4f,.8f,1.2f};for(guint k=0;k<channels-1;k++)raw[15*channels+k]=c[k];raw[15*channels+channels-1]=0x1p-20f;gegl_buffer_set(buffer,GEGL_RECTANGLE(0,0,4,4),0,fmt,raw,GEGL_AUTO_ROWSTRIDE);GlimsDisplaySample *sample=glims_display_sample_new(buffer,fmt);CHECK(sample!=NULL,"tiny same-space helper constructs");if(sample){const double scales[]={.5,1.25},coverage[]={.25,.09};for(guint i=0;i<2;i++){guint8 bytes[4*sizeof(float)+2];memset(bytes,0xa5,sizeof bytes);GlimsRect area=i?(GlimsRect){3,3,1,1}:(GlimsRect){1,1,1,1};CHECK(glims_display_sample_read(sample,scales[i],area,bytes+1,channels*sizeof(float))==GLIMS_STATUS_OK,"tiny helper spatial read succeeds");float actual[4];memcpy(actual,bytes+1,channels*sizeof(float));for(guint k=0;k<channels-1;k++)CHECK(fabs(actual[k]-c[k])<2e-5,"helper preserves signed/extended straight color below alpha floor");CHECK(fabs(actual[channels-1]-coverage[i]*0x1p-20)<1e-12,"helper tiny alpha has independent literal spatial coverage");CHECK(bytes[0]==0xa5&&bytes[1+channels*sizeof(float)]==0xa5,"tiny unaligned helper output preserves canaries");}glims_display_sample_free(sample);}float after[64]={0};gegl_buffer_get(buffer,GEGL_RECTANGLE(0,0,4,4),1,fmt,after,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);CHECK(!memcmp(raw,after,4*4*channels*sizeof(float)),"tiny helper leaves source exact");g_object_unref(buffer);}}

/* Independent lazy source: invalidate changes its promised pixels without writing
 * any tile. This distinguishes invalidated-only projection damage from changed. */
typedef struct { GimpTileHandlerValidate parent; float rgba[4]; guint calls; } SamplingValidate;
typedef struct { GimpTileHandlerValidateClass parent; } SamplingValidateClass;
G_DEFINE_TYPE(SamplingValidate, sampling_validate, GIMP_TYPE_TILE_HANDLER_VALIDATE)
static void sampling_validate_pixels(GimpTileHandlerValidate *base,
 const GeglRectangle *rect,const Babl *format,gpointer out,gint stride)
{
 SamplingValidate *v=(SamplingValidate*)base;v->calls++;
 CHECK(babl_format_get_bytes_per_pixel(format)==16&&babl_format_get_n_components(format)==4,
       "custom validator guards exact float RGBA destination");
 if(babl_format_get_bytes_per_pixel(format)!=16||babl_format_get_n_components(format)!=4)return;
 for(gint y=0;y<rect->height;y++)for(gint x=0;x<rect->width;x++)
  memcpy((guint8*)out+(gsize)y*stride+(gsize)x*16,v->rgba,16);
}
static void sampling_validate_buffer(GimpTileHandlerValidate *base,
 const GeglRectangle *rect,GeglBuffer *buffer)
{
 SamplingValidate *v=(SamplingValidate*)base;v->calls++;
 const Babl *fmt=gegl_buffer_get_format(buffer);
 CHECK(babl_format_get_bytes_per_pixel(fmt)==16&&babl_format_get_n_components(fmt)==4,
       "custom validator guards exact float RGBA buffer");
 if(babl_format_get_bytes_per_pixel(fmt)!=16||babl_format_get_n_components(fmt)!=4)return;
 float *row=g_new(float,(gsize)rect->width*4);
 for(gint x=0;x<rect->width;x++)memcpy(row+4*x,v->rgba,16);
 for(gint y=0;y<rect->height;y++)gegl_buffer_set(buffer,
  GEGL_RECTANGLE(rect->x,rect->y+y,rect->width,1),0,fmt,row,GEGL_AUTO_ROWSTRIDE);
 g_free(row);
}
static void sampling_validate_class_init(SamplingValidateClass *klass)
{
 GimpTileHandlerValidateClass *base=GIMP_TILE_HANDLER_VALIDATE_CLASS(klass);
 base->validate=sampling_validate_pixels;base->validate_buffer=sampling_validate_buffer;
}
static void sampling_validate_init(SamplingValidate *v)
{v->rgba[0]=v->rgba[3]=1;}
static gboolean helper_literal(GlimsDisplaySample *sample,GlimsRect area,
 double scale,const float expected[4])
{
 float pixel[4]={NAN,NAN,NAN,NAN};
 GlimsStatus status=glims_display_sample_read(sample,scale,area,pixel,sizeof pixel);
 CHECK(status==GLIMS_STATUS_OK,"persistent helper read succeeds");
 gboolean exact=status==GLIMS_STATUS_OK;
 for(guint c=0;c<4;c++)if(!isfinite(pixel[c])||fabsf(pixel[c]-expected[c])>2e-6f)exact=FALSE;
 if(!exact)printf("CACHE MISMATCH scale=%g xy=%d,%d actual=%g,%g,%g,%g expected=%g,%g,%g,%g\n",
  scale,area.x,area.y,pixel[0],pixel[1],pixel[2],pixel[3],expected[0],expected[1],expected[2],expected[3]);
 CHECK(exact,"persistent cache matches independent constant color/alpha literal");
 return exact;
}
static void persistent_checks(void)
{
 const Babl *fmt=babl_format("RGBA float");
 const GeglRectangle extent={0,0,512,8};
 const float red[4]={1,0,0,1},green[4]={0,1,0,1},blue[4]={0,0,1,1};
 GeglBuffer *source=gegl_buffer_new(&extent,fmt);
 SamplingValidate *validator=g_object_new(sampling_validate_get_type(),NULL);
 gimp_tile_handler_validate_assign(GIMP_TILE_HANDLER_VALIDATE(validator),source);
 gimp_tile_handler_validate_invalidate(GIMP_TILE_HANDLER_VALIDATE(validator),&extent);
 GlimsDisplaySample *cache=NULL;
 CHECK(glims_display_sample_prepare(source,fmt,&cache)==GLIMS_STATUS_OK&&cache,
       "persistent cache prepares lazy source");
 if(!cache){gimp_tile_handler_validate_unassign(GIMP_TILE_HANDLER_VALIDATE(validator),source);g_object_unref(validator);g_object_unref(source);return;}
 GlimsDisplaySample *same=cache;
 helper_literal(cache,(GlimsRect){1,1,1,1},.5,red);
 CHECK(glims_display_sample_prepare(source,fmt,&cache)==GLIMS_STATUS_OK&&cache==same,
       "same source/format key reuses exact cache object");
 guint calls=validator->calls;
 memcpy(validator->rgba,green,sizeof green);
 gimp_tile_handler_validate_invalidate(GIMP_TILE_HANDLER_VALIDATE(validator),&extent);
 CHECK(validator->calls==calls,"invalidated-only source has not written new pixels yet");
 CHECK(glims_display_sample_prepare(source,fmt,&cache)==GLIMS_STATUS_OK&&cache==same,
       "invalidated-only damage retains compatible cache");
 helper_literal(cache,(GlimsRect){1,1,1,1},.5,green);
 CHECK(validator->calls>calls,"read actually validates newly promised source pixels");
 /* Pan to a source region that was never sampled before the invalidation. */
 helper_literal(cache,(GlimsRect){200,1,1,1},.5,green);
 float patch[4*4*4];for(guint i=0;i<16;i++)memcpy(patch+4*i,blue,16);
 gegl_buffer_set(source,GEGL_RECTANGLE(2,2,4,4),0,fmt,patch,GEGL_AUTO_ROWSTRIDE);
 CHECK(glims_display_sample_prepare(source,fmt,&cache)==GLIMS_STATUS_OK,
       "ordinary same-buffer write prepares fresh derived data");
 helper_literal(cache,(GlimsRect){1,1,1,1},.5,blue);
 /* Replacing the assigned validator on the identical buffer is also a key
  * change; the replacement promises red without writing any source bytes. */
 gimp_tile_handler_validate_unassign(GIMP_TILE_HANDLER_VALIDATE(validator),source);
 g_object_unref(validator);
 validator=g_object_new(sampling_validate_get_type(),NULL);
 gimp_tile_handler_validate_assign(GIMP_TILE_HANDLER_VALIDATE(validator),source);
 gimp_tile_handler_validate_invalidate(GIMP_TILE_HANDLER_VALIDATE(validator),&extent);
 CHECK(glims_display_sample_prepare(source,fmt,&cache)==GLIMS_STATUS_OK,
       "same buffer with replacement validator prepares");
 helper_literal(cache,(GlimsRect){1,1,1,1},.5,red);
 /* Freeing the final external source reference must be safe: cache owns it. */
 GWeakRef weak;g_weak_ref_init(&weak,source);g_object_unref(source);source=NULL;
 helper_literal(cache,(GlimsRect){1,1,1,1},.5,red);
 glims_display_sample_free(cache);cache=NULL;
 GObject *alive=g_weak_ref_get(&weak);CHECK(alive==NULL,"cache releases its owned source on free");
 g_clear_object(&alive);g_weak_ref_clear(&weak);g_object_unref(validator);
 /* Replacement format and extent are fresh keys; no pointer-address inequality
  * assertion (allocator reuse is permitted). Positive output proves rebinding. */
 source=gegl_buffer_new(GEGL_RECTANGLE(4,4,8,8),fmt);
 float solid[8*8*4];for(guint i=0;i<64;i++)memcpy(solid+4*i,red,16);
 gegl_buffer_set(source,GEGL_RECTANGLE(4,4,8,8),0,fmt,solid,GEGL_AUTO_ROWSTRIDE);
 CHECK(glims_display_sample_prepare(source,fmt,&cache)==GLIMS_STATUS_OK,"replacement buffer and extent prepare");
 helper_literal(cache,(GlimsRect){3,3,1,1},.5,red);
 gegl_buffer_set_extent(source,GEGL_RECTANGLE(4,4,4,4));
 CHECK(glims_display_sample_prepare(source,fmt,&cache)==GLIMS_STATUS_OK,"in-place extent change prepares");
 const float zero[4]={0,0,0,0};helper_literal(cache,(GlimsRect){5,5,1,1},.5,zero);
 GeglBuffer *other=gegl_buffer_new(GEGL_RECTANGLE(0,0,4,4),babl_format("R'G'B'A float"));
 float opaque_blue[64];for(guint i=0;i<16;i++)memcpy(opaque_blue+4*i,blue,16);
 gegl_buffer_set(other,GEGL_RECTANGLE(0,0,4,4),0,babl_format("R'G'B'A float"),opaque_blue,GEGL_AUTO_ROWSTRIDE);
 CHECK(glims_display_sample_prepare(other,fmt,&cache)==GLIMS_STATUS_OK,"replacement nonlinear source key prepares");
 helper_literal(cache,(GlimsRect){1,1,1,1},.5,blue);
 glims_display_sample_free(cache);g_object_unref(other);g_object_unref(source);
}
static void large_coordinate_checks(void)
{
 const Babl *associated=babl_format("RaGaBaA float"),*linear_fmt=babl_format("RGBA float");
 /* Mirrored X/Y controls use the same retained witness geometry; no broad
  * coordinate stress or changed acceptance bound is implied. */
 for(guint axis=0;axis<2;axis++)for(guint negative=0;negative<2;negative++){
  gint sign=negative?-1:1;
  GeglRectangle extent=axis?(GeglRectangle){0,sign*22369620-(negative?8:0),2,8}:
    (GeglRectangle){sign*22369620-(negative?8:0),0,8,2};
  GeglBuffer *source=gegl_buffer_new(&extent,associated);
  float raw[64];for(guint i=0;i<16;i++){raw[4*i]=raw[4*i+3]=1;raw[4*i+1]=raw[4*i+2]=0;}
  gegl_buffer_set(source,&extent,0,associated,raw,GEGL_AUTO_ROWSTRIDE);
  GlimsDisplaySample *sample=glims_display_sample_new(source,linear_fmt);
  CHECK(sample!=NULL,"large-coordinate associated source constructs");
  if(sample)for(gint width=2;width>=1;width--){
   gint offset=sign*16777216-(negative?width:0);
   GlimsRect area=axis?(GlimsRect){0,offset,1,width}:(GlimsRect){offset,0,width,1};
   float pixels[8];for(guint i=0;i<8;i++)pixels[i]=-123;
   GlimsStatus status=glims_display_sample_read(sample,.75,area,pixels,(gsize)area.width*16);
   CHECK(status==GLIMS_STATUS_OK,"valid large-coordinate request succeeds");
   gboolean exact=status==GLIMS_STATUS_OK;
   for(gint i=0;i<width;i++)for(guint c=0;c<4;c++)
    if(!isfinite(pixels[4*i+c])||fabsf(pixels[4*i+c]-((c==0||c==3)?1.f:0.f))>1e-6f)exact=FALSE;
   CHECK(exact,"fully covered red remains opaque at large signed X/Y coordinates");
  }
  glims_display_sample_free(sample);float after[64];gegl_buffer_get(source,&extent,1,associated,after,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(!memcmp(raw,after,sizeof raw),"large-coordinate source stays byte-exact");g_object_unref(source);
 }
}


static void deepest_scale_checks(void)
{
 const Babl *associated=babl_format("RaGaBaA float"),*linear_fmt=babl_format("RGBA float");
 const GeglRectangle extents[2]={{0,0,4,4},{-2,-2,4,4}};
 /* A coarse cell has area 2^40. Positive-origin covers sixteen pixels;
  * the straddling source contributes only four pixels to cell (0,0). */
 const float expected_alpha[2]={0x1p-36f,0x1p-38f};
 for(guint k=0;k<2;k++){
  GeglBuffer *buffer=gegl_buffer_new(&extents[k],associated);
  float raw[64];for(guint i=0;i<16;i++){raw[4*i]=raw[4*i+3]=1;raw[4*i+1]=raw[4*i+2]=0;}
  gegl_buffer_set(buffer,&extents[k],0,associated,raw,GEGL_AUTO_ROWSTRIDE);
  GlimsDisplaySample *sample=glims_display_sample_new(buffer,linear_fmt);
  CHECK(sample!=NULL,"minimum-scale tiny source constructs without huge allocation");
  if(sample){float output[4]={-123,-123,-123,-123};
   CHECK(glims_display_sample_read(sample,0x1p-20,(GlimsRect){0,0,1,1},output,sizeof output)==GLIMS_STATUS_OK,
         "minimum supported scale completes within bounded fixture process");
   CHECK(output[0]==1&&output[1]==0&&output[2]==0&&output[3]==expected_alpha[k],
         "minimum-scale straight red and literal tiny coverage remain exact");
  }
  glims_display_sample_free(sample);float after[64];
  gegl_buffer_get(buffer,&extents[k],1,associated,after,GEGL_AUTO_ROWSTRIDE,GEGL_ABYSS_NONE);
  CHECK(!memcmp(raw,after,sizeof raw),"minimum-scale sampling leaves source bytes unchanged");
  g_object_unref(buffer);
 }
}

/* A source edit after warm reads must invalidate every profile/proof mip
 * footprint, including a request crossing the native 256-pixel boundary. */
static void profile_damage_scales(GlimsEngine *e)
{
 const float color[3]={.8f,.2f,.1f}; Fixture f;
 CHECK(fixture_new(e,&f,FALSE,&srgb,270,270,FALSE,2,color),"multi-scale damage fixture creates");
 if(!f.id)return;
 GlimsOpenImage *open=glims_lookup_image(e,f.id); GeglBuffer *buffer=NULL;
 CHECK(open!=NULL,"multi-scale damage fixture resolves image");
 if(!open){api->image_close(e,f.id);return;}
 CHECK(glims_projection_prepare_sample(open,1,(GlimsRect){0,0,1,1},&buffer)==GLIMS_STATUS_INVALID_ARGUMENT,
       "sampling-only preparation refuses unit scale");
 CHECK(glims_projection_prepare_sample(open,2,(GlimsRect){0,0,1,1},&buffer)==GLIMS_STATUS_INVALID_ARGUMENT,
       "sampling-only preparation refuses direct magnification");
 CHECK(glims_projection_prepare_sample(open,0,(GlimsRect){0,0,1,1},&buffer)==GLIMS_STATUS_INVALID_ARGUMENT &&
       glims_projection_prepare_sample(open,-.5,(GlimsRect){0,0,1,1},&buffer)==GLIMS_STATUS_INVALID_ARGUMENT,
       "sampling-only preparation refuses nonpositive scales");
 const double scales[]={.225,.5,.75,1.25}; guint8 before[4][2][36]={0},after[36]={0};
 GlimsLayerInfo layer={0}; int32_t count=0;
 GlimsStatus status=api->image_layers(e,f.id,&layer,1,&count);
 CHECK(status==GLIMS_STATUS_OK&&count==1,"damage fixture resolves layer");
 if(status!=GLIMS_STATUS_OK||count!=1){api->image_close(e,f.id);return;}
 for(guint i=0;i<4;i++)for(guint route=1;route<=2;route++){
  GlimsRect area={(gint)floor(255*scales[i]),(gint)floor(255*scales[i]),3,3};
  CHECK(render(e,&f,route,&srgb,scales[i],area,before[i][route-1],12)==GLIMS_STATUS_OK,"profile or proof warm read succeeds");
  CHECK(before[i][route-1][3]>0,"warm footprint includes visible source pixels");
 }
 GlimsLayerChange change={.struct_size=sizeof change,.properties=GLIMS_LAYER_OPACITY,.opacity=0}; char *error=NULL;
 status=api->layer_change(e,f.id,layer.id,&change,&error);
 CHECK(status==GLIMS_STATUS_OK,"opacity edit invalidates projection"); api->free_string(error);
 for(guint i=0;i<4;i++)for(guint route=1;route<=2;route++){
  GlimsRect area={(gint)floor(255*scales[i]),(gint)floor(255*scales[i]),3,3}; memset(after,0xa5,sizeof after);
  CHECK(render(e,&f,route,&srgb,scales[i],area,after,12)==GLIMS_STATUS_OK,"profile or proof read after damage succeeds");
  /* Both public routes promise premultiplied RGBA: zero alpha clears RGB. */
  gboolean clear=TRUE;for(guint n=0;n<sizeof after;n++)if(after[n])clear=FALSE;
  CHECK(clear,"profile or proof read sees transparent edited projection");
 }
 CHECK(api->image_undo(e,f.id)==GLIMS_STATUS_OK,"damage fixture Undo succeeds");
 for(guint i=0;i<4;i++)for(guint route=1;route<=2;route++){
  GlimsRect area={(gint)floor(255*scales[i]),(gint)floor(255*scales[i]),3,3};
  memset(after,0xa5,sizeof after);
  CHECK(render(e,&f,route,&srgb,scales[i],area,after,12)==GLIMS_STATUS_OK,"profile or proof read after Undo succeeds");
  CHECK(!memcmp(before[i][route-1],after,sizeof after),"Undo restores exact profile or proof pixels");
 }
 CHECK(api->image_close(e,f.id)==GLIMS_STATUS_OK,"multi-scale damage fixture closes");
}

static GlimsStatus worker(GlimsEngine *e,gpointer unused){(void)unused;const float rgb[3]={.8f,.2f,.1f},g[3]={.25f,0,0};for(guint kind=0;kind<3;kind++)for(guint pattern=0;pattern<2;pattern++){Fixture f;CHECK(fixture_new(e,&f,kind==2,kind==0?&srgb:kind==1?&linear:&gray,4,4,FALSE,pattern,kind==2?g:rgb),"RGB/Gray profile sampling fixture creates");if(f.id){constant_checks(e,&f,pattern);CHECK(api->image_close(e,f.id)==GLIMS_STATUS_OK,"profile fixture closes");}}wide_checks(e);hdr_checks(e);freshness_and_guards(e);profile_damage_scales(e);private_tiny();persistent_checks();large_coordinate_checks();deepest_scale_checks();return GLIMS_STATUS_OK;}
int main(int argc,char **argv){if(argc!=2)return 2;const char *fixtures=g_getenv("GLIMS_DISPLAY_FIXTURES");if(!fixtures||!g_path_is_absolute(fixtures))return 2;if(!srgb_new()||!load_icc(fixtures,"linear-rgb.icc",&linear)||!load_icc(fixtures,"gray.icc",&gray)){icc_free(&gray);icc_free(&linear);icc_free(&srgb);return 2;}api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);if(!api||api->struct_size<offsetof(GlimsEngineAPI,image_render_proofed)+sizeof api->image_render_proofed||!api->image_render_proofed)return 2;gchar *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};GlimsEngine *engine=NULL;char *error=NULL;GlimsStatus status=api->start(&config,&engine,&error);g_free(user);g_free(cache);if(status!=GLIMS_STATUS_OK||!engine){fprintf(stderr,"start %s\n",error?error:"");api->free_string(error);icc_free(&gray);icc_free(&linear);icc_free(&srgb);return 2;}api->free_string(error);status=glims_engine_call(engine,worker,NULL);api->stop(engine);icc_free(&gray);icc_free(&linear);icc_free(&srgb);printf("checks=%u failures=%u\n",checks,failures);return status==GLIMS_STATUS_OK&&!failures?0:1;}

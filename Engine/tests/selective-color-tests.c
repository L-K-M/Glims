/* Public-facade acceptance for the owned Selective Color operation.
 * Expected RGB values below are literal, independent of the pixel kernel. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int failures, checks;
#define CHECK(test, name) do { bool pass = (test); checks++; failures += !pass; printf("%s %s\n", pass ? "ok  " : "FAIL", name); fflush(stdout); } while (0)
#define OP "glims:selective-color"
static const unsigned char pixels[16] = {255,0,0,32, 0,255,0,96, 0,0,255,160, 128,128,128,224};
static const unsigned char expected[16] = {128,0,0,32, 0,191,0,96, 0,0,128,160, 65,65,65,224};
static const char *ranges[] = {"red","yellow","green","cyan","blue","magenta","white","neutral","black"};
static const char *components[] = {"cyan","magenta","yellow","black"};

static int depth(GlimsImageID image) {
 GlimsUndoInfo value; return api->image_undo_info(engine,image,&value)==GLIMS_STATUS_OK ? value.undo_count : -1;
}
static bool copy(GlimsImageID image,bool merged,unsigned char result[16]) {
 GlimsPixelBuffer buffer={0};
 if(api->image_copy_pixels(engine,image,merged,&buffer,NULL)!=GLIMS_STATUS_OK)return false;
 bool valid=buffer.pixels && buffer.byte_count==16 && buffer.bounds.width==4 && buffer.bounds.height==1;
 if(valid)memcpy(result,buffer.pixels,16);api->free_pixels(buffer.pixels);return valid;
}
static bool matches(GlimsImageID image,const unsigned char wanted[16],bool merged) {
 unsigned char actual[16];if(!copy(image,merged,actual))return false;
 for(int i=0;i<16;i++)if(i%4==3 ? actual[i]!=wanted[i] : abs(actual[i]-wanted[i])>1){printf("pixel mismatch:");for(int j=0;j<16;j++)printf(" %u/%u",actual[j],wanted[j]);printf("\n");return false;}
 return true;
}
static GlimsItemID first(GlimsImageID image) {
 GlimsLayerInfo rows[4];int32_t count=0;
 return api->image_layers(engine,image,rows,4,&count)==GLIMS_STATUS_OK && count>0 ? rows[0].id : 0;
}
static bool write_oracle(GlimsFilterID filter) {
 GlimsFilterValue relative={.kind=GLIMS_FILTER_VALUE_BOOL,.boolean=false};
 return api->filter_set_property(engine,filter,"relative",&relative)==GLIMS_STATUS_OK &&
 api->filter_set_double(engine,filter,"red-cyan",.5)==GLIMS_STATUS_OK &&
 api->filter_set_double(engine,filter,"green-magenta",.25)==GLIMS_STATUS_OK &&
 api->filter_set_double(engine,filter,"blue-yellow",.5)==GLIMS_STATUS_OK &&
 api->filter_set_double(engine,filter,"neutral-black",.25)==GLIMS_STATUS_OK;
}
static void discovery(void) {
 int32_t count=0;CHECK(api->filter_operations(engine,NULL,0,&count)==GLIMS_STATUS_OK && count>0,"operation catalog counts");
 if(count<1 || count>4096)return;
 int32_t capacity=count;GlimsOperationInfo *rows=calloc((size_t)capacity,sizeof *rows);bool found=false;
 if(rows && api->filter_operations(engine,rows,capacity,&count)==GLIMS_STATUS_OK && count>=0 && count<=capacity)
  for(int i=0;i<count;i++)if(!strcmp(rows[i].name,OP))found=rows[i].support==GLIMS_FILTER_OP_SUPPORTED && !strcmp(rows[i].title,"Selective Color");
 CHECK(found,"Selective Color is discoverable with its generic property protocol");free(rows);
 GlimsFilterProperty properties[40];count=0;
 bool valid=api->filter_operation_properties(engine,OP,properties,40,&count)==GLIMS_STATUS_OK && count==37;
 int numbers=0,booleans=0;
 if(valid)for(int i=0;i<count;i++){
  if(properties[i].kind==GLIMS_FILTER_VALUE_NUMBER && properties[i].min==-1 && properties[i].max==1 && properties[i].default_number==0)numbers++;
  if(properties[i].kind==GLIMS_FILTER_VALUE_BOOL && !strcmp(properties[i].name,"relative"))booleans++;
 }
 CHECK(valid && numbers==36 && booleans==1,"nine CMYK ranges and relative mode have bounded typed properties");
}
static void workflow(const char *work,bool adjustment) {
 GlimsImageID image=0;GlimsFilterID filter=0;GlimsItemID layer=0;GlimsEffectID effect=0;
 CHECK(api->image_from_pixels(engine,4,1,pixels,sizeof pixels,&image,NULL)==GLIMS_STATUS_OK,"partial-alpha fixture opens");if(!image)return;
 GlimsItemID base=first(image);layer=base;
 if(adjustment){
  CHECK(api->adjustment_layer_new(engine,image,0,0,OP,"Selective Color",&layer,&effect,NULL)==GLIMS_STATUS_OK,"neutral adjustment group creates");
  CHECK(matches(image,pixels,true),"default adjustment is neutral including alpha");
 }
 int baseline=depth(image);
 GlimsStatus status=adjustment ? api->filter_edit_begin(engine,image,layer,effect,&filter,NULL) : api->filter_begin(engine,image,layer,OP,&filter,NULL);
 CHECK(status==GLIMS_STATUS_OK && filter,"effect preview opens");if(!filter){api->image_close(engine,image);return;}
 CHECK(write_oracle(filter) && matches(image,expected,true),"absolute RGB oracle matches while alpha stays exact");
 CHECK(depth(image)==baseline,"preview has no Undo entry");
 CHECK(api->filter_abort(engine,filter)==GLIMS_STATUS_OK && matches(image,pixels,true) && depth(image)==baseline,"Cancel restores exact input and history");
 filter=0;status=adjustment ? api->filter_edit_begin(engine,image,layer,effect,&filter,NULL) : api->filter_begin(engine,image,layer,OP,&filter,NULL);
 CHECK(status==GLIMS_STATUS_OK && filter,"preview reopens");if(!filter){api->image_close(engine,image);return;}
 GlimsFilterValue invalid={.kind=GLIMS_FILTER_VALUE_NUMBER,.number=1.01};
 GlimsStatus invalid_nan=api->filter_set_double(engine,filter,"red-cyan",NAN);
 GlimsStatus invalid_bound=api->filter_set_property(engine,filter,"black-yellow",&invalid);
 CHECK(invalid_nan==GLIMS_STATUS_INVALID_ARGUMENT && invalid_bound==GLIMS_STATUS_INVALID_ARGUMENT && matches(image,pixels,true),"invalid settings leave the neutral preview unchanged");
 CHECK(write_oracle(filter) && api->filter_commit(engine,filter,NULL)==GLIMS_STATUS_OK && depth(image)==baseline+1 && matches(image,expected,true),"Apply commits the literal result as one Undo");
 CHECK(api->layer_select(engine,image,base)==GLIMS_STATUS_OK && matches(image,pixels,false),"stored source pixels remain intact");
 CHECK(api->image_undo(engine,image)==GLIMS_STATUS_OK && depth(image)==baseline && matches(image,pixels,true),"one Undo restores input");
 CHECK(api->image_redo(engine,image)==GLIMS_STATUS_OK && depth(image)==baseline+1 && matches(image,expected,true),"Redo restores adjusted pixels and alpha");
 GlimsEffectInfo effects[2];int32_t n=0;
 CHECK(api->drawable_effects(engine,image,layer,effects,2,&n)==GLIMS_STATUS_OK && n==1,"committed effect remains editable");
 if(n!=1){api->image_close(engine,image);return;}
 CHECK(api->filter_edit_begin(engine,image,layer,effects[0].id,&filter,NULL)==GLIMS_STATUS_OK,"all-range persistence edit opens");
 bool all=true;char name[64];
 for(int r=0;r<9;r++)for(int c=0;c<4;c++){
  snprintf(name,sizeof name,"%s-%s",ranges[r],components[c]);
  all &= api->filter_set_double(engine,filter,name,(r*4+c-18)/32.0)==GLIMS_STATUS_OK;
 }
 CHECK(all && api->filter_commit(engine,filter,NULL)==GLIMS_STATUS_OK,"all 36 independently named values commit");
 unsigned char saved[16]={0};CHECK(copy(image,true,saved),"save oracle captured");
 char path[2048];snprintf(path,sizeof path,"%s/selective-%d.xcf",work,adjustment);
 CHECK(api->image_save(engine,image,path,NULL)==GLIMS_STATUS_OK,"XCF saves the owned operation");
 api->image_close(engine,image);image=0;
 CHECK(api->image_open(engine,path,&image,NULL)==GLIMS_STATUS_OK && image,"XCF reopens");if(!image)return;
 CHECK(matches(image,saved,true),"reopened composite matches every color and alpha");
 layer=first(image);n=0;
 CHECK(api->drawable_effects(engine,image,layer,effects,2,&n)==GLIMS_STATUS_OK && n==1 && !strcmp(effects[0].operation,OP),"XCF retains operation identity");
 filter=0;
 CHECK(n==1 && api->filter_edit_begin(engine,image,layer,effects[0].id,&filter,NULL)==GLIMS_STATUS_OK && filter,"saved effect reopens for editing");
 if(filter){
  all=true;
  for(int r=0;r<9;r++)for(int c=0;c<4;c++){
   GlimsFilterValue v={0};snprintf(name,sizeof name,"%s-%s",ranges[r],components[c]);
   all &= api->filter_get_property(engine,filter,name,&v)==GLIMS_STATUS_OK && v.kind==GLIMS_FILTER_VALUE_NUMBER && fabs(v.number-(r*4+c-18)/32.0)<1e-6;
  }
  GlimsFilterValue v={0};all &= api->filter_get_property(engine,filter,"relative",&v)==GLIMS_STATUS_OK && v.kind==GLIMS_FILTER_VALUE_BOOL && !v.boolean;
  CHECK(all,"all 36 values and correction method survive XCF and edit cloning");
  CHECK(api->filter_set_double(engine,filter,"red-cyan",.75)==GLIMS_STATUS_OK && api->filter_commit(engine,filter,NULL)==GLIMS_STATUS_OK,"reloaded adjustment accepts a real edit");
 }
 api->image_close(engine,image);
}
int main(int argc,char **argv) {
 if(argc!=3)return 2;void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){puts(dlerror());return 2;}
 GlimsEngineGetAPIFunction get=(GlimsEngineGetAPIFunction)dlsym(lib,"glims_engine_get_api");api=get ? get(GLIMS_ENGINE_API_VERSION):NULL;
 if(!api)return 2;GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=argv[2],.cache_directory=argv[2]};
 char *error=NULL;GlimsStatus started=api->start(&config,&engine,&error);if(started!=GLIMS_STATUS_OK){puts(error?error:"engine failed");return 1;}
 discovery();workflow(argv[2],false);workflow(argv[2],true);api->stop(engine);printf("%d checks, %d failures\n",checks,failures);return failures?1:0;
}

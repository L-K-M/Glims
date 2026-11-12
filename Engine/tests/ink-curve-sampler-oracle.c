/* Independent oracle: calls unmodified native GimpCurve, never the Swift sampler. */
#include "engine-private.h"
#include "core/gimpcurve.h"
#include "core/gimpdata.h"
#include "libgimpbase/gimpbase.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"
int main(int argc, char **argv);
typedef struct { double x, y; int kind; } Point;
static FILE *output;
static int failed;
static void dump(const char *name, const Point *points, size_t count, int first) {
 GimpCurve *curve=GIMP_CURVE(gimp_curve_new("oracle"));
 GimpValueArray *coords=gimp_value_array_new((int)count*2), *types=gimp_value_array_new((int)count);
 GValue coord=G_VALUE_INIT, type=G_VALUE_INIT;
 g_value_init(&coord,G_TYPE_DOUBLE);g_value_init(&type,GIMP_TYPE_CURVE_POINT_TYPE);
 for(size_t i=0;i<count;i++) {
  g_value_set_double(&coord,points[i].x);gimp_value_array_append(coords,&coord);
  g_value_set_double(&coord,points[i].y);gimp_value_array_append(coords,&coord);
  g_value_set_enum(&type,points[i].kind==1?GIMP_CURVE_POINT_SMOOTH:GIMP_CURVE_POINT_CORNER);gimp_value_array_append(types,&type);
 }
 gimp_data_freeze(GIMP_DATA(curve));
 for(int i=0;i<256;i++)curve->samples[i]=(double)(i%7)/6.0;
 g_object_set(curve,"points",coords,"point-types",types,NULL);
 gimp_data_dirty(GIMP_DATA(curve));gimp_data_thaw(GIMP_DATA(curve));
 fprintf(output,"%s{\"name\":\"%s\",\"samples\":[",first?"":",",name);
 if(curve->n_samples!=256)failed=1;
 for(int i=0;i<256;i++) { if(!isfinite(curve->samples[i]))failed=1;fprintf(output,"%s%.17g",i?",":"",curve->samples[i]); }
 fputs("]}",output);
 g_value_unset(&coord);g_value_unset(&type);gimp_value_array_unref(coords);gimp_value_array_unref(types);g_object_unref(curve);
}
static GlimsStatus run(GlimsEngine *engine, gpointer unused) {
 (void)engine;(void)unused;fputs("[",output);
 const Point p0[]={{0,0,1},{1,1,1}}; dump("identity",p0,2,1);
 const Point p1[]={{0,1,1},{1,0,1}}; dump("inverted",p1,2,0);
 const Point p2[]={{0,0,1}}; dump("zero",p2,0,0);
 const Point p3[]={{0.4,0.3,1}}; dump("one",p3,1,0);
 const Point p4[]={{0,0.1,2},{1,0.9,2}}; dump("linear_corner",p4,2,0);
 const Point p5[]={{0,0.1,1},{0.4,0.8,1},{1,0.3,1}}; dump("three_smooth",p5,3,0);
 const Point p6[]={{0,0.2,1},{0.2,0.9,1},{0.75,0.1,1},{1,0.7,1}}; dump("four_smooth",p6,4,0);
 const Point p7[]={{0,0.2,1},{0.2,0.9,2},{0.75,0.1,1},{1,0.7,2}}; dump("mixed_corner",p7,4,0);
 const Point p8[]={{0.15,0.2,1},{0.7,0.9,1}}; dump("end_gaps",p8,2,0);
 const Point p9[]={{0.25,0.2,2},{0.75,0.8,2}}; dump("rounded_endpoint_overlap",p9,2,0);
 const Point p10[]={{0,0,2},{0.5,1,2},{0.5,0,2},{1,1,2}}; dump("duplicate_corner",p10,4,0);
 const Point p11[]={{0,0,1},{0.05,1,1},{0.95,1,1},{1,0,1}}; dump("overshoot",p11,4,0);
 const Point p12[]={{0,0.1,1},{0.5,0.3,1},{0.5,0.9,1},{1,0.2,1}}; dump("duplicates",p12,4,0);
 const Point p13[]={{0.3,0.1,1},{0.3,0.7,2},{0.3,0.2,1}}; dump("all_coincident",p13,3,0);
 const Point p14[]={{0,0.1,1},{0.501,0.3,1},{0.502,0.9,1},{1,0.8,1}}; dump("same_bin",p14,4,0);
 const Point p15[]={{0,0.1,1},{0.5,0.3,1},{0.5000009,0.9,1},{1,0.8,1}}; dump("epsilon_below",p15,4,0);
 const Point p16[]={{0,0.1,1},{0.5,0.3,1},{0.5000011,0.9,1},{1,0.8,1}}; dump("epsilon_above",p16,4,0);
 const Point p17[]={{0,0.1,1},{0.3941176470196079,0.7,1},{1,0.9,1}}; dump("half_bin_below",p17,3,0);
 const Point p18[]={{0,0.1,1},{0.3941176470980392,0.7,1},{1,0.9,1}}; dump("half_bin_above",p18,3,0);
 const Point p19[]={{0,0.1,1},{0,0.7,2},{1,0.2,1},{1,0.8,2}}; dump("coincident_ends",p19,4,0);
 const Point p20[]={{0.0,0.1,1},{0.125,0.4,1},{0.25,0.2,1},{0.375,0.8,1},{0.5,0.7,1},{0.625,0.4,1},{0.75,0.9,1},{0.875,0.3,1},{1.0,0.6,1}}; dump("nine_points",p20,9,0);
 fputs("]\n",output);return failed?GLIMS_STATUS_FAILED:GLIMS_STATUS_OK;
}
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 char *path=g_build_filename(argv[1],"oracles.json",NULL);output=fopen(path,"wx");g_free(path);if(!output)return 2;
 const GlimsEngineAPI *api=glims_engine_get_api(GLIMS_ENGINE_API_VERSION);GlimsEngine *engine=NULL;char *error=NULL;
 char *user=g_build_filename(argv[1],"user",NULL),*cache=g_build_filename(argv[1],"cache",NULL);
 GlimsEngineConfig config={.struct_size=sizeof config,.user_directory=user,.cache_directory=cache};
 int code=api->start(&config,&engine,&error);
 if(code==GLIMS_STATUS_OK){code=glims_engine_call(engine,run,NULL);api->stop(engine);}
 if(error){fprintf(stderr,"%s\n",error);api->free_string(error);}
 if(fclose(output))code=2;g_free(user);g_free(cache);return code==GLIMS_STATUS_OK?0:2;
}

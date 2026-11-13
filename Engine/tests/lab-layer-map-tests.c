#include "lab-layer-map.h"
#include "plate-map.h"
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static unsigned checks, failures;
#define CHECK(ok, name) do { checks++; if (!(ok)) { failures++; \
    fprintf(stderr, "FAIL: %s (line %d)\n", (name), __LINE__); } } while (0)

/* Literal wire witnesses, independent of either codec or the test builders.
 * Multibyte dimensions expose byte order; UUID ends expose role/entry order. */
static const uint8_t empty_wire[40] = {
    'G','L','I','M','S','P','M','1',
    [8]=2, [12]=7, [16]=9, [24]=3, [28]=1, [32]=2
};
static const uint8_t two_wire[200] = {
    'G','L','I','M','S','P','M','1',
    [8]=2, [12]=4,3,2,1, [16]=13,12,11,10,
    [20]=2, [24]=3, [28]=1, [32]=2,
    [40]=1, [55]=0xf1, [56]=2, [71]=0xf2,
    [72]=3, [87]=0xf3, [88]=4, [103]=0xf4,
    [104]=5, [119]=0xf5, [120]=6, [135]=0xf6,
    [136]=7, [151]=0xf7, [152]=8, [167]=0xf8,
    [168]=9, [183]=0xf9, [184]=10, [199]=0xfa
};
static const uint8_t ids[10][16] = {
    {[0]=1,[15]=0xf1}, {[0]=2,[15]=0xf2}, {[0]=3,[15]=0xf3},
    {[0]=4,[15]=0xf4}, {[0]=5,[15]=0xf5}, {[0]=6,[15]=0xf6},
    {[0]=7,[15]=0xf7}, {[0]=8,[15]=0xf8}, {[0]=9,[15]=0xf9},
    {[0]=10,[15]=0xfa}
};
static const uint8_t v1_wire[160] = {
    'G','L','I','M','S','P','M','1',
    [8]=1, [12]=7, [16]=9, [20]=3, [24]=3, [28]=1, [32]=2,
    [40]=1, [55]=0xf1, [80]=2, [95]=0xf2, [120]=3, [135]=0xf3
};

static int filled(const void *data, size_t length, uint8_t value)
{
    const uint8_t *bytes = data;
    for (size_t i=0; i<length; i++) if (bytes[i]!=value) return 0;
    return 1;
}

static uint8_t *role_id(GlimsLabLayerMap *map, unsigned index)
{
    GlimsLabLayerEntry *entry = &map->entries[index/5];
    switch (index%5) {
    case 0: return entry->group;
    case 1: return entry->l;
    case 2: return entry->a;
    case 3: return entry->b;
    default: return entry->alpha;
    }
}

static void write_u32(uint8_t *bytes, uint32_t value)
{
    for (unsigned i=0; i<4; i++) bytes[i]=(uint8_t)(value>>(8*i));
}

static GlimsLabLayerMap golden_map(void)
{
    GlimsLabLayerMap map={.width=0x01020304u,.height=0x0a0b0c0du,
        .count=2,.mode=3,.storage=1,.encoding=2};
    for (unsigned i=0; i<10; i++) memcpy(role_id(&map,i),ids[i],16);
    return map;
}

static int matches_golden(const GlimsLabLayerMap *map)
{
    if (map->width!=0x01020304u || map->height!=0x0a0b0c0du ||
        map->count!=2 || map->mode!=3 || map->storage!=1 || map->encoding!=2)
        return 0;
    for (unsigned i=0; i<2; i++) {
        const GlimsLabLayerEntry *entry=&map->entries[i];
        if (memcmp(entry->group,ids[5*i],16) || memcmp(entry->l,ids[5*i+1],16) ||
            memcmp(entry->a,ids[5*i+2],16) || memcmp(entry->b,ids[5*i+3],16) ||
            memcmp(entry->alpha,ids[5*i+4],16)) return 0;
    }
    return filled(map->entries+2,sizeof map->entries-2*sizeof map->entries[0],0);
}

static void reject_decode(const uint8_t *bytes, size_t length, const char *name)
{
    GlimsLabLayerMap out;
    memset(&out,0xa5,sizeof out);
    CHECK(!glims_lab_layer_map_decode(bytes,length,&out),name);
    CHECK(filled(&out,sizeof out,0),"failed decode clears entire destination");
}

static void reject_encode(const GlimsLabLayerMap *map, size_t capacity, const char *name)
{
    uint8_t out[GLIMS_LAB_LAYER_MAP_MAX_SIZE+3];
    memset(out,0xa5,sizeof out);
    size_t written=123;
    CHECK(!glims_lab_layer_map_encode(map,out+1,capacity,&written),name);
    CHECK(written==0,"failed encode resets written");
    CHECK(filled(out,sizeof out,0xa5),"failed encode changes no output byte");
}

static void golden_and_unaligned_checks(void)
{
    GlimsLabLayerMap map=golden_map(), decoded;
    uint8_t out[20523];
    size_t written=0;
    CHECK(glims_lab_layer_map_validate(&map),"independent two-entry host map valid");
    memset(&decoded,0xa5,sizeof decoded);
    CHECK(glims_lab_layer_map_decode(two_wire,sizeof two_wire,&decoded),"literal two-entry wire decodes");
    CHECK(matches_golden(&decoded),"literal decoded dimensions and every role UUID exact");
    memset(out,0xa5,sizeof out);
    CHECK(glims_lab_layer_map_encode(&map,out+1,sizeof out-2,&written),"unaligned encode accepts valid map");
    CHECK(written==200 && !memcmp(out+1,two_wire,200),"encoder exactly matches independent literal");
    CHECK(out[0]==0xa5 && filled(out+201,sizeof out-201,0xa5),"successful encode leaves all spare bytes intact");
    memset(&decoded,0xa5,sizeof decoded);
    CHECK(glims_lab_layer_map_decode(out+1,200,&decoded) && matches_golden(&decoded),"unaligned input retains exact values");
    memcpy(out+3,two_wire,200);
    CHECK(glims_lab_layer_map_decode(out+3,200,&decoded) && matches_golden(&decoded),"unaligned literal decode");

    map.width=7; map.height=9; map.count=0;
    memset(map.entries,0xa5,sizeof map.entries);
    CHECK(glims_lab_layer_map_validate(&map),"empty stack ignores inactive duplicate UUIDs");
    memset(out,0xa5,sizeof out);
    CHECK(glims_lab_layer_map_encode(&map,out,sizeof out,&written) && written==40 &&
          !memcmp(out,empty_wire,40),"empty encode matches literal header");
    CHECK(filled(out+40,sizeof out-40,0xa5),"empty encode leaves whole tail intact");
    memset(&decoded,0xa5,sizeof decoded);
    CHECK(glims_lab_layer_map_decode(empty_wire,40,&decoded) && decoded.width==7 &&
          decoded.height==9 && decoded.count==0 && decoded.mode==3 &&
          decoded.storage==1 && decoded.encoding==2 &&
          filled(decoded.entries,sizeof decoded.entries,0),"empty literal clears inactive owned entries");
}

static void wire_validation_checks(void)
{
    uint8_t bad[201];
    for (size_t n=0; n<sizeof two_wire; n++)
        reject_decode(two_wire,n,"every truncated literal prefix refuses");
    memcpy(bad,two_wire,200); bad[200]=0;
    reject_decode(bad,201,"extra zero byte refuses");
    bad[200]=0xff; reject_decode(bad,201,"extra nonzero byte refuses");
    reject_decode(two_wire,SIZE_MAX,"impossible claimed length refuses before entry reads");
    for (unsigned i=0; i<8; i++) {
        memcpy(bad,two_wire,200); bad[i]^=1;
        reject_decode(bad,200,"each magic byte is checked");
    }
    const struct { size_t offset; uint32_t value; } fields[]={
        {8,0},{8,1},{8,3},{8,UINT32_MAX},
        {12,0},{12,0x80000000u},{12,UINT32_MAX},
        {16,0},{16,0x80000000u},{16,UINT32_MAX},
        {20,0},{20,1},{20,3},{20,257},{20,UINT32_MAX},
        {24,0},{24,1},{24,2},{24,4},{24,UINT32_MAX},
        {28,0},{28,2},{28,3},{28,UINT32_MAX},
        {32,0},{32,1},{32,3},{32,UINT32_MAX}
    };
    for (size_t i=0; i<sizeof fields/sizeof fields[0]; i++) {
        memcpy(bad,two_wire,200); write_u32(bad+fields[i].offset,fields[i].value);
        reject_decode(bad,200,"invalid header field or inconsistent count refuses");
    }
    for (unsigned i=0; i<4; i++) {
        memcpy(bad,two_wire,200); bad[36+i]=1;
        reject_decode(bad,200,"each reserved byte must be zero");
    }
    for (unsigned i=0; i<10; i++) {
        GlimsLabLayerMap map=golden_map();
        memcpy(bad,two_wire,200); memset(bad+40+16*i,0,16);
        reject_decode(bad,200,"zero UUID refuses in every entry role");
        memset(role_id(&map,i),0,16);
        CHECK(!glims_lab_layer_map_validate(&map),"owned zero UUID invalid");
        reject_encode(&map,200,"owned zero UUID cannot publish");
    }
    for (unsigned i=0; i<10; i++) for (unsigned j=i+1; j<10; j++) {
        GlimsLabLayerMap map=golden_map();
        memcpy(bad,two_wire,200); memcpy(bad+40+16*j,bad+40+16*i,16);
        reject_decode(bad,200,"all same-entry and cross-entry role duplicates refuse");
        memcpy(role_id(&map,j),role_id(&map,i),16);
        CHECK(!glims_lab_layer_map_validate(&map),"owned role duplicate invalid");
        reject_encode(&map,200,"owned role duplicate cannot publish");
    }
}

static void encode_boundary_checks(void)
{
    GlimsLabLayerMap map=golden_map();
    for (size_t capacity=0; capacity<200; capacity++)
        reject_encode(&map,capacity,"every insufficient capacity refuses atomically");
    const uint32_t invalids[]={0,0x80000000u,UINT32_MAX};
    for (unsigned i=0; i<3; i++) {
        GlimsLabLayerMap invalid=map; invalid.width=invalids[i];
        reject_encode(&invalid,200,"invalid owned width refuses");
        invalid=map; invalid.height=invalids[i];
        reject_encode(&invalid,200,"invalid owned height refuses");
    }
    const uint32_t counts[]={257,UINT32_MAX};
    for (unsigned i=0; i<2; i++) {
        GlimsLabLayerMap invalid=map; invalid.count=counts[i];
        reject_encode(&invalid,200,"invalid count refuses before reading inactive storage");
    }
    for (uint32_t value=0; value<5; value++) {
        GlimsLabLayerMap invalid=map;
        if (value!=3) { invalid.mode=value; reject_encode(&invalid,200,"unsupported owned mode refuses"); }
        invalid=map;
        if (value!=1) { invalid.storage=value; reject_encode(&invalid,200,"unsupported owned storage refuses"); }
        invalid=map;
        if (value!=2) { invalid.encoding=value; reject_encode(&invalid,200,"unsupported owned encoding refuses"); }
    }
    reject_encode(NULL,200,"null owned map refuses");
    CHECK(!glims_lab_layer_map_validate(NULL),"null map validation refuses");
    size_t written=123;
    CHECK(!glims_lab_layer_map_encode(&map,NULL,200,&written) && written==0,"null bytes resets written");
    uint8_t out[200]; memset(out,0xa5,sizeof out);
    CHECK(!glims_lab_layer_map_encode(&map,out,sizeof out,NULL) && filled(out,sizeof out,0xa5),"null written leaves all bytes intact");
    reject_decode(NULL,200,"null bytes decode clears destination");
    CHECK(!glims_lab_layer_map_decode(two_wire,200,NULL),"null output map refuses");
}

static void maximum_and_overlap_checks(void)
{
    GlimsLabLayerMap map={.width=INT32_MAX,.height=INT32_MAX,
        .count=256,.mode=3,.storage=1,.encoding=2};
    for (unsigned i=0; i<1280; i++) {
        write_u32(role_id(&map,i),i+1); role_id(&map,i)[15]=0x7f;
    }
    uint8_t wire[20520]; size_t written=0;
    clock_t start=clock();
    CHECK(glims_lab_layer_map_encode(&map,wire,sizeof wire,&written) && written==20520,"256 entries and maximum dimensions encode to exact bound");
    clock_t encoded=clock();
    GlimsLabLayerMap decoded;
    CHECK(glims_lab_layer_map_decode(wire,sizeof wire,&decoded),"maximum literal-indexed IDs decode");
    CHECK(decoded.width==INT32_MAX && decoded.height==INT32_MAX && decoded.count==256 &&
          !memcmp(decoded.entries[255].alpha,(uint8_t[16]){0,5,[15]=0x7f},16),"last maximum-count UUID and dimensions retained");
    clock_t finished=clock();
    printf("TIMING max256 encode_seconds=%.6f decode_seconds=%.6f\n",
           (double)(encoded-start)/CLOCKS_PER_SEC,(double)(finished-encoded)/CLOCKS_PER_SEC);
    memcpy(map.entries[255].alpha,map.entries[0].group,16);
    reject_encode(&map,sizeof wire,"late global duplicate refuses before publication");
    memcpy(wire+20504,wire+40,16);
    reject_decode(wire,sizeof wire,"late wire duplicate refuses");

    /* Both outcomes consume all input before writing the overlapping map. */
    memcpy(&decoded,two_wire,sizeof two_wire);
    CHECK(glims_lab_layer_map_decode((const uint8_t *)&decoded,200,&decoded) &&
          matches_golden(&decoded),"overlapping byte input and owned output safely stage");
    memcpy(&decoded,two_wire,sizeof two_wire);
    ((uint8_t *)&decoded)[8]=1;
    CHECK(!glims_lab_layer_map_decode((const uint8_t *)&decoded,200,&decoded) &&
          filled(&decoded,sizeof decoded,0),"overlapping failed decode clears entire owned output");
}

static void version_isolation_checks(void)
{
    GlimsPlateMap old;
    CHECK(glims_plate_map_decode(v1_wire,sizeof v1_wire,&old) && old.count==3 &&
          old.mode==3,"independent v1 literal remains valid to unchanged v1 reader");
    reject_decode(v1_wire,sizeof v1_wire,"v2 decoder rejects valid v1 bytes");
    memset(&old,0xa5,sizeof old);
    CHECK(!glims_plate_map_decode(two_wire,sizeof two_wire,&old) &&
          filled(&old,sizeof old,0),"unchanged v1 decoder rejects v2 bytes and clears output");
}

int main(void)
{
    golden_and_unaligned_checks();
    wire_validation_checks();
    encode_boundary_checks();
    maximum_and_overlap_checks();
    version_isolation_checks();
    printf("SUMMARY checks=%u failures=%u\n",checks,failures);
    return failures ? 1 : 0;
}

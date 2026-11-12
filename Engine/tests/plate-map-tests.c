/* Independent literal wire and malformed-input checks for the private plate map.
 * This codec alone never activates a document mode or owns image pixels. */
#include "plate-map.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned checks, failures;
#define CHECK(value, label) do { checks++; if (!(value)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, label); } } while (0)
/* 48x32, two ink-intensity u8 planes. Canonical v1 metadata, authored as
 * wire bytes independently of the encoder. Ink RGB: (0,.5,1), (1,.25,0). */
static const uint8_t literal[120] = {
  'G','L','I','M','S','P','M','1',
  [8]=1, [12]=48, [16]=32, [20]=2, [24]=1, [28]=1, [32]=1,
  [40]=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,
  [70]=0xe0, [71]=0x3f, [78]=0xf0, [79]=0x3f,
  [80]=17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,
  [102]=0xf0, [103]=0x3f, [110]=0xd0, [111]=0x3f, [119]=0
};
static void reject(const uint8_t *bytes, size_t length, const char *label) {
  GlimsPlateMap map; uint8_t zeros[sizeof map];
  memset(&map,0xa5,sizeof map);memset(zeros,0,sizeof zeros);
  CHECK(!glims_plate_map_decode(bytes,length,&map),label);
  CHECK(!memcmp(&map,zeros,sizeof map),"decode failure clears the entire destination");
}
static void fail_encode(const GlimsPlateMap *map, size_t capacity) {
  uint8_t bytes[144], unchanged[144];size_t written=99;
  memset(bytes,0xa5,sizeof bytes);memcpy(unchanged,bytes,sizeof bytes);
  CHECK(!glims_plate_map_encode(map,bytes,capacity,&written),"invalid encode refuses");
  CHECK(written==0 && !memcmp(bytes,unchanged,sizeof bytes),"failed encode preserves output and resets count");
}
int main(void) {
  GlimsPlateMap map={0};uint8_t encoded[144],bad[121],unaligned[121];size_t written=0;
  CHECK(glims_plate_map_decode(literal,sizeof literal,&map),"independent literal decodes");
  CHECK(map.width==48 && map.height==32 && map.count==2 && map.mode==1 && map.storage==1 && map.encoding==1,"owned fields match the literal");
  CHECK(glims_plate_map_validate(&map),"literal yields valid owned data");
  CHECK(map.entries[0].uuid[0]==1 && map.entries[1].uuid[15]==32 &&
        map.entries[0].ink_rgb[0]==0 && map.entries[0].ink_rgb[1]==0.5 && map.entries[0].ink_rgb[2]==1 &&
        map.entries[1].ink_rgb[0]==1 && map.entries[1].ink_rgb[1]==0.25 && map.entries[1].ink_rgb[2]==0,
        "UUID and RGB values have their independent literal meanings");
  memset(encoded,0xa5,sizeof encoded);
  CHECK(glims_plate_map_encode(&map,encoded,sizeof encoded,&written),"decoded literal encodes");
  CHECK(written==sizeof literal && !memcmp(encoded,literal,sizeof literal),"encoder matches the independent wire bytes exactly");
  int tail=1;for(size_t i=sizeof literal;i<sizeof encoded;i++)if(encoded[i]!=0xa5)tail=0;
  CHECK(tail,"encoder leaves unused capacity alone");
  memcpy(unaligned+1,literal,sizeof literal);
  CHECK(glims_plate_map_decode(unaligned+1,sizeof literal,&map),"unaligned input is supported");
  for(size_t n=0;n<sizeof literal;n++)reject(literal,n,"every truncated prefix refuses");
  memcpy(bad,literal,sizeof literal);bad[120]=0;reject(bad,sizeof bad,"zero trailing byte refuses");bad[120]=0x7f;reject(bad,sizeof bad,"nonzero trailing byte refuses");
  for(size_t offset=0;offset<8;offset++){memcpy(bad,literal,sizeof literal);bad[offset]^=1;reject(bad,sizeof literal,"each magic byte matters");}
  const size_t required_nonzero[]={8,12,16,20,24,28,32};
  for(size_t i=0;i<sizeof required_nonzero/sizeof required_nonzero[0];i++){memcpy(bad,literal,sizeof literal);bad[required_nonzero[i]]=0;reject(bad,sizeof literal,"required zero field refuses");}
  const size_t unknown_field[]={8,24,28,32};
  for(size_t i=0;i<sizeof unknown_field/sizeof unknown_field[0];i++){memcpy(bad,literal,sizeof literal);bad[unknown_field[i]]=0xff;reject(bad,sizeof literal,"unknown version or owned enum refuses");}
  for(size_t offset=36;offset<40;offset++){memcpy(bad,literal,sizeof literal);bad[offset]=1;reject(bad,sizeof literal,"each reserved byte must be zero");}
  memcpy(bad,literal,sizeof literal);bad[20]=33;reject(bad,sizeof literal,"over-limit count refuses");
  memcpy(bad,literal,sizeof literal);bad[20]=1;reject(bad,sizeof literal,"extra entry refuses");
  memcpy(bad,literal,sizeof literal);bad[15]=0x80;reject(bad,sizeof literal,"width outside signed native range refuses");
  memcpy(bad,literal,sizeof literal);bad[19]=0x80;reject(bad,sizeof literal,"height outside signed native range refuses");
  memcpy(bad,literal,sizeof literal);memset(bad+40,0,16);reject(bad,sizeof literal,"zero UUID refuses");
  memcpy(bad,literal,sizeof literal);memcpy(bad+80,bad+40,16);reject(bad,sizeof literal,"duplicate UUID refuses");
  const uint8_t invalid_colors[][8]={
    {0,0,0,0,0,0,0xf8,0x7f}, /* quiet NaN */
    {1,0,0,0,0,0,0xf0,0x7f}, /* signaling NaN */
    {0,0,0,0,0,0,0xf0,0x7f}, /* +infinity */
    {0,0,0,0,0,0,0xf0,0xff}, /* -infinity */
    {0,0,0,0,0,0,0xe0,0xbf}, /* -0.5 */
    {0,0,0,0,0,0,0,0x40},    /* 2 */
    {0,0,0,0,0,0,0,0x80}     /* noncanonical -0 */
  };
  for(size_t i=0;i<sizeof invalid_colors/sizeof invalid_colors[0];i++)for(size_t component=0;component<3;component++){
    memcpy(bad,literal,sizeof literal);memcpy(bad+56+8*component,invalid_colors[i],8);reject(bad,sizeof literal,"invalid ink component refuses");
  }
  for(uint8_t storage=2;storage<=3;storage++){
    memcpy(bad,literal,sizeof literal);bad[28]=storage;CHECK(glims_plate_map_decode(bad,sizeof literal,&map),"remaining declared storage encodings decode");
    CHECK(map.storage==storage,"owned storage identity is retained");
  }
  CHECK(glims_plate_map_decode(literal,sizeof literal,&map),"reset canonical map");
  fail_encode(&map,0);fail_encode(&map,sizeof literal-1);fail_encode(NULL,sizeof encoded);
  GlimsPlateMap invalid=map;invalid.width=0;fail_encode(&invalid,sizeof encoded);invalid=map;invalid.count=33;fail_encode(&invalid,sizeof encoded);
  reject(NULL,sizeof literal,"null input refuses");
  CHECK(!glims_plate_map_decode(literal,sizeof literal,NULL),"null destination refuses");
  CHECK(!glims_plate_map_validate(NULL),"null owned map refuses");
  written=99;CHECK(!glims_plate_map_encode(&map,NULL,sizeof encoded,&written) && written==0,"null output refuses and resets count");
  memset(encoded,0xa5,sizeof encoded);CHECK(!glims_plate_map_encode(&map,encoded,sizeof encoded,NULL),"missing written count refuses");
  tail=1;for(size_t i=0;i<sizeof encoded;i++)if(encoded[i]!=0xa5)tail=0;CHECK(tail,"missing output count leaves bytes intact");
  /* Host callers may supply -0; the persisted form is always canonical +0. */
  map.entries[0].ink_rgb[0]=-0.0;
  CHECK(glims_plate_map_validate(&map),"host negative zero is valid");
  CHECK(glims_plate_map_encode(&map,encoded,sizeof encoded,&written) &&
        written==sizeof literal && !memcmp(encoded,literal,sizeof literal),"encoder canonicalizes host negative zero");
  for(size_t i=0;i<sizeof invalid_colors/sizeof invalid_colors[0]-1;i++){
    invalid=map;uint64_t bits=0;
    for(unsigned b=0;b<8;b++)bits|=(uint64_t)invalid_colors[i][b]<<(8*b);
    memcpy(&invalid.entries[1].ink_rgb[2],&bits,8);fail_encode(&invalid,sizeof encoded);
  }
  invalid=map;memset(invalid.entries[1].uuid,0,16);fail_encode(&invalid,sizeof encoded);
  invalid=map;memcpy(invalid.entries[1].uuid,invalid.entries[0].uuid,16);fail_encode(&invalid,sizeof encoded);
  /* Both accepted dimension and count boundaries, with a late duplicate to
   * ensure validation visits every entry rather than only the first pair. */
  GlimsPlateMap maximum={.width=INT32_MAX,.height=INT32_MAX,.count=32,.mode=1,.storage=3,.encoding=1};
  for(unsigned i=0;i<32;i++){
    maximum.entries[i].uuid[15]=(uint8_t)(i+1);
    maximum.entries[i].ink_rgb[0]=i/32.0;
    maximum.entries[i].ink_rgb[1]=1;
    maximum.entries[i].ink_rgb[2]=0.125;
  }
  uint8_t largest[1320];
  CHECK(glims_plate_map_encode(&maximum,largest,sizeof largest,&written) && written==1320,"maximum count and dimensions encode to exact bound");
  CHECK(glims_plate_map_decode(largest,sizeof largest,&invalid) && invalid.count==32 &&
        invalid.entries[31].uuid[15]==32 && invalid.entries[31].ink_rgb[0]==31/32.0,
        "last maximum-count entry survives");
  memcpy(largest+40+31*40,largest+40+30*40,16);reject(largest,sizeof largest,"late duplicate identity refuses");
  memcpy(maximum.entries[31].uuid,maximum.entries[30].uuid,16);
  CHECK(!glims_plate_map_validate(&maximum),"host late duplicate identity refuses");
  printf("%u plate-map checks, %u failures\n",checks,failures);return failures?1:0;
}

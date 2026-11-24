/* Standalone harness for the pure Image > Trap kernel. Expected values are
 * hand-computed literals from docs/trap.md, not re-derivations through the
 * implementation. */
#include "trap-math.h"

#include <stdio.h>

static int failures;

#define CHECK(cond, text)                                                \
  do {                                                                   \
    const int ok_ = (cond);                                              \
    printf ("%s %s\n", ok_ ? "ok  " : "FAIL", text);                     \
    if (!ok_) failures++;                                                \
  } while (0)

/* Colors as C, M, Y, K coverages. */
#define CYAN    1.0f, 0.0f, 0.0f, 0.0f
#define MAGENTA 0.0f, 1.0f, 0.0f, 0.0f
#define YELLOW  0.0f, 0.0f, 1.0f, 0.0f
#define BLACK   0.0f, 0.0f, 0.0f, 1.0f
#define PAPER   0.0f, 0.0f, 0.0f, 0.0f

#define MAX_PIXELS 4096
static float tile[MAX_PIXELS * GLIMS_TRAP_PLANES];
static float out[MAX_PIXELS * 3];
static int32_t winner[MAX_PIXELS * 3];

static void
fill (size_t width, size_t height, float c, float m, float y, float k)
{
  for (size_t i = 0; i < width * height; i++)
    {
      tile[i * 4 + 0] = c;
      tile[i * 4 + 1] = m;
      tile[i * 4 + 2] = y;
      tile[i * 4 + 3] = k;
    }
}

static void
put (size_t tile_width, size_t x, size_t y, float c, float m, float yy, float k)
{
  size_t i = (y * tile_width + x) * 4;

  tile[i + 0] = c;
  tile[i + 1] = m;
  tile[i + 2] = yy;
  tile[i + 3] = k;
}

static float
coverage (size_t inner_width, size_t x, size_t y, size_t plane)
{
  return out[(y * inner_width + x) * 3 + plane];
}

static void
test_arguments (void)
{
  size_t tile_pixels = (4 + 2) * (2 + 2);

  fill (tile_pixels, 1, PAPER);
  CHECK (! glims_trap_inner (NULL, 6, 4, 1, 1, 4, 2, 1, 1, 4, 2, 1, out, winner),
         "arguments: NULL tile is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 1, 1, 4, 2, 1, 1, 4, 2, 0, out, winner),
         "arguments: width 0 is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 1, 1, 4, 2, 1, 1, 4, 2, 17, out, winner),
         "arguments: width 17 is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 0, 1, 4, 2, 1, 1, 4, 2, 1, out, winner),
         "arguments: inner left of the canvas is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 2, 1, 4, 2, 1, 1, 4, 2, 1, out, winner),
         "arguments: inner right of the canvas is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 1, 0, 4, 2, 1, 1, 4, 2, 1, out, winner),
         "arguments: inner above the canvas is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 1, 2, 4, 2, 1, 1, 4, 2, 1, out, winner),
         "arguments: inner below the canvas is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 1, 1, 4, 2, 0, 1, 4, 2, 1, out, winner),
         "arguments: canvas left of the tile is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 1, 1, 4, 2, 1, 1, 6, 2, 1, out, winner),
         "arguments: canvas wider than the tile is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 1, 1, 4, 2, 1, 1, 4, 4, 1, out, winner),
         "arguments: canvas taller than the tile is refused");
  CHECK (! glims_trap_inner (tile, 6, 4, 1, 1, 4, 2, 1, 1, 4, 2, 1, NULL, NULL),
         "arguments: NULL output with pixels is refused");
  CHECK (glims_trap_inner (tile, 6, 4, 1, 1, 0, 0, 1, 1, 4, 2, 1, NULL, NULL),
         "arguments: an empty inner region needs no output");
}

/* An 8x3 canvas of four columns of yellow next to four columns of cyan at
 * width 1: the lighter yellow spreads one pixel under the cyan, and the
 * darker cyan does not spread at all. The tile carries one row and column
 * of margin that lies outside the canvas and must never be read; it holds
 * yellow, which would spread into the cyan's edge pixels if it were. */
static void
test_yellow_into_cyan (void)
{
  size_t tile_width = 10, tile_height = 5;

  fill (tile_width * tile_height, 1, YELLOW);
  for (size_t y = 0; y < 3; y++)
    for (size_t x = 0; x < 4; x++)
      put (tile_width, x + 1, y + 1, YELLOW);
  for (size_t y = 0; y < 3; y++)
    for (size_t x = 4; x < 8; x++)
      put (tile_width, x + 1, y + 1, CYAN);

  CHECK (glims_trap_inner (tile, tile_width, tile_height,
                           1, 1, 8, 3, 1, 1, 8, 3, 1, out, winner),
         "yellow/cyan: the call is accepted");
  CHECK (coverage (8, 3, 1, 0) == 0.0f && coverage (8, 3, 1, 2) == 1.0f,
         "yellow/cyan: yellow keeps its own ink");
  CHECK (coverage (8, 4, 1, 2) == 1.0f,
         "yellow/cyan: yellow spreads one pixel under cyan");
  CHECK (coverage (8, 4, 1, 0) == 1.0f && coverage (8, 5, 1, 2) == 0.0f,
         "yellow/cyan: cyan keeps its ink and the spread stops at width 1");
  {
    int kept = 1, untouched = 1;
    for (size_t y = 0; y < 3; y++)
      for (size_t x = 4; x < 8; x++)
        if (coverage (8, x, y, 0) != 1.0f)
          kept = 0;
    for (size_t x = 0; x < 4; x++)
      if (coverage (8, x, 1, 0) != 0.0f || coverage (8, x, 1, 1) != 0.0f)
        untouched = 0;
    CHECK (kept, "yellow/cyan: cyan ink is never lost");
    CHECK (untouched, "yellow/cyan: nothing spreads into the yellow block");
  }
  {
    int clean = 1;
    for (size_t y = 0; y < 3; y++)
      for (size_t x = 5; x < 8; x++)
        if (coverage (8, x, y, 2) != 0.0f)
          clean = 0;
    CHECK (clean, "yellow/cyan: the yellow margin outside the canvas is never read");
  }
  {
    int consistent = 1;
    for (size_t i = 0; i < 8 * 3 * 3; i++)
      if (winner[i] < 0 || tile[(size_t) winner[i] * 4 + i % 3] != out[i])
        consistent = 0;
    CHECK (consistent, "yellow/cyan: each winner names the tile pixel it took");
  }
  /* Width 1 reaches the four edge neighbours only, so the yellow comes
   * from the pixel to the left: tile (4, 2). */
  CHECK (winner[(1 * 8 + 4) * 3 + 2] == (int32_t) (2 * tile_width + 4),
         "yellow/cyan: the trapped pixel names its yellow neighbour");
}

/* Cyan, black, yellow, black at width 1: everything is lighter than
 * black, so each black column takes the ink of its lighter neighbours,
 * and black, being darkest, never spreads into the colors. */
static void
test_color_into_black (void)
{
  size_t tile_width = 6, tile_height = 3;

  fill (tile_width * tile_height, 1, PAPER);
  for (size_t y = 0; y < 3; y++)
    {
      put (tile_width, 1, y, CYAN);
      put (tile_width, 2, y, BLACK);
      put (tile_width, 3, y, YELLOW);
      put (tile_width, 4, y, BLACK);
    }

  CHECK (glims_trap_inner (tile, tile_width, tile_height,
                           1, 0, 4, 3, 1, 0, 4, 3, 1, out, winner),
         "black: the call is accepted");
  CHECK (coverage (4, 1, 1, 0) == 1.0f && coverage (4, 1, 1, 2) == 1.0f,
         "black: cyan and yellow both spread under the black between them");
  CHECK (coverage (4, 0, 1, 2) == 0.0f && coverage (4, 2, 1, 0) == 0.0f,
         "black: no ink crosses a black column into the next color");
  CHECK (coverage (4, 3, 1, 2) == 1.0f && coverage (4, 3, 1, 0) == 0.0f,
         "black: yellow spreads under black too");
  CHECK (coverage (4, 0, 1, 0) == 1.0f,
         "black: the canvas edge keeps its cyan ink");
}

/* A single yellow pixel beside one of the same color has no strictly
 * lighter neighbour, so nothing moves. */
static void
test_equal_darkness (void)
{
  size_t tile_width = 5, tile_height = 3;

  fill (tile_width * tile_height, 1, PAPER);
  for (size_t y = 0; y < 3; y++)
    {
      put (tile_width, 1, y, YELLOW);
      put (tile_width, 2, y, YELLOW);
      put (tile_width, 3, y, CYAN);
    }
  put (tile_width, 3, 1, 0.0f, 0.0f, 0.5f, 0.0f); /* lighter yellow ink */

  CHECK (glims_trap_inner (tile, tile_width, tile_height,
                           1, 0, 4, 3, 1, 0, 4, 3, 1, out, winner),
         "equal: the call is accepted");
  CHECK (coverage (4, 0, 1, 2) == 1.0f && coverage (4, 1, 1, 2) == 1.0f,
         "equal: identical neighbors spread nothing");
  CHECK (coverage (4, 2, 1, 2) == 0.5f,
         "equal: a lighter pixel keeps its own weaker coverage");
  CHECK (coverage (4, 0, 1, 0) == 0.0f && coverage (4, 1, 1, 0) == 0.0f,
         "equal: cyan coverage does not appear");
}

/* At width 2 the disk excludes the (2,2) diagonal at distance sqrt(8)
 * and the (2,1) diagonal at sqrt(5), but includes (2,0), (1,1) and
 * (0,2). One yellow pixel per offset proves the boundary. */
static void
test_disk_shape (void)
{
  size_t tile_width = 7, tile_height = 7;

  fill (tile_width * tile_height, 1, CYAN);
  put (tile_width, 5, 5, YELLOW); /* (2,2) from center: outside */
  put (tile_width, 5, 4, YELLOW); /* (2,1) from center: outside */
  put (tile_width, 5, 3, YELLOW); /* (2,0) from center: inside  */
  put (tile_width, 4, 4, YELLOW); /* (1,1) from center: inside  */
  put (tile_width, 3, 5, YELLOW); /* (0,2) from center: inside  */

  CHECK (glims_trap_inner (tile, tile_width, tile_height,
                           3, 3, 1, 1, 0, 0, 7, 7, 2, out, winner),
         "disk: the call is accepted");
  CHECK (coverage (1, 0, 0, 2) == 1.0f,
         "disk: in-disk neighbours spread");

  fill (tile_width * tile_height, 1, CYAN);
  put (tile_width, 5, 5, YELLOW); /* (2,2) only */
  put (tile_width, 5, 4, YELLOW); /* (2,1) only */
  put (tile_width, 4, 5, YELLOW); /* (1,2) only: sqrt(5) */
  CHECK (glims_trap_inner (tile, tile_width, tile_height,
                           3, 3, 1, 1, 0, 0, 7, 7, 2, out, winner),
         "disk: the clipped call is accepted");
  CHECK (coverage (1, 0, 0, 2) == 0.0f,
         "disk: sqrt(5) and sqrt(8) neighbours stay outside");
}

/* A 20x1 canvas: a yellow two-pixel cap at the left spreads exactly the
 * width-16 disk reach into the cyan, never further. */
static void
test_width_bounds (void)
{
  size_t tile_width = 20, tile_height = 1;

  fill (tile_width * tile_height, 1, CYAN);
  put (tile_width, 0, 0, YELLOW);
  put (tile_width, 1, 0, YELLOW);

  CHECK (glims_trap_inner (tile, tile_width, tile_height,
                           0, 0, 20, 1, 0, 0, 20, 1, 16, out, winner),
         "width 16: the call is accepted");
  CHECK (coverage (20, 17, 0, 2) == 1.0f && coverage (20, 18, 0, 2) == 0.0f,
         "width 16: the spread reaches 16 pixels and stops");

  CHECK (glims_trap_inner (tile, tile_width, tile_height,
                           0, 0, 20, 1, 0, 0, 20, 1, 1, out, winner),
         "width 1: the call is accepted");
  CHECK (coverage (20, 2, 0, 2) == 1.0f && coverage (20, 3, 0, 2) == 0.0f,
         "width 1: the spread reaches one pixel and stops");
}

/* The canvas edge has no out-of-canvas neighbour: a yellow pixel in the
 * corner of a 2x2 canvas still spreads along the edge it has, and a lone
 * cyan pixel keeps its own ink. */
static void
test_edges (void)
{
  size_t tile_width = 4, tile_height = 3;

  fill (tile_width * tile_height, 1, PAPER);
  put (tile_width, 1, 0, YELLOW);
  put (tile_width, 2, 0, CYAN);
  put (tile_width, 1, 1, CYAN);
  put (tile_width, 2, 1, MAGENTA);

  CHECK (glims_trap_inner (tile, tile_width, tile_height,
                           1, 0, 2, 2, 1, 0, 2, 2, 1, out, winner),
         "edges: the call is accepted");
  CHECK (coverage (2, 1, 0, 2) == 1.0f,
         "edges: yellow spreads under the darker edge neighbor");
  CHECK (coverage (2, 0, 1, 2) == 1.0f,
         "edges: yellow spreads under the darker corner neighbor");
  CHECK (coverage (2, 1, 1, 1) == 1.0f,
         "edges: magenta keeps its own ink under the spread");
}

/* A 6x3 canvas of three yellow columns next to three cyan columns, read
 * through a 2x2 window of cyan beside the boundary in a tile whose margin
 * is yellow. The window's yellow neighbour lies outside the window but on
 * the canvas and must spread into both window rows; the output uses the
 * window's own stride, and the margin above the window must not spread. */
static void
test_inner_window (void)
{
  size_t tile_width = 8, tile_height = 5;

  fill (tile_width * tile_height, 1, YELLOW);
  for (size_t y = 1; y <= 3; y++)
    for (size_t x = 4; x <= 6; x++)
      put (tile_width, x, y, CYAN);
  for (size_t i = 0; i < 2 * 2 * 3; i++)
    out[i] = -1.0f;

  CHECK (glims_trap_inner (tile, tile_width, tile_height,
                           4, 1, 2, 2, 1, 1, 6, 3, 1, out, winner),
         "window: the call is accepted");
  CHECK (coverage (2, 0, 0, 2) == 1.0f && coverage (2, 0, 1, 2) == 1.0f,
         "window: yellow beside the window spreads into both of its rows");
  CHECK (winner[2] == (int32_t) (1 * tile_width + 3),
         "window: the winner names the yellow pixel outside the window");
  CHECK (coverage (2, 1, 1, 2) == 0.0f,
         "window: the spread stops at width 1");
  CHECK (coverage (2, 1, 0, 2) == 0.0f,
         "window: the margin outside the canvas is never read");
  CHECK (coverage (2, 0, 0, 0) == 1.0f && coverage (2, 1, 1, 0) == 1.0f,
         "window: cyan keeps its ink");
}

/* The header lets `out` and `winner` be NULL only when the inner rectangle
 * is empty; pin that so a kernel that rejects NULL unconditionally, or that
 * dereferences the outputs before checking the window area, fails here. */
static void
test_empty_window_null_outputs (void)
{
  CHECK (glims_trap_inner (tile, 8, 5, 0, 0, 0, 0, 0, 0, 8, 5, 1, NULL, NULL),
         "empty window: NULL out and winner are accepted");
  CHECK (glims_trap_inner (tile, 8, 5, 0, 0, 1, 0, 0, 0, 8, 5, 1, NULL, NULL),
         "height-zero window still counts as empty for NULL outputs");
  CHECK (! glims_trap_inner (tile, 8, 5, 0, 0, 1, 1, 0, 0, 8, 5, 1, NULL, NULL),
         "non-empty window: NULL out and winner are refused");
  CHECK (! glims_trap_inner (tile, (size_t) 1 << 31, 2, 0, 0, 0, 0, 0, 0, 1, 1, 1, NULL, NULL),
         "a tile above 2^31 pixels is refused before any index can wrap");
}

int
main (void)
{
  test_arguments ();
  test_yellow_into_cyan ();
  test_color_into_black ();
  test_equal_darkness ();
  test_disk_shape ();
  test_width_bounds ();
  test_edges ();
  test_inner_window ();
  test_empty_window_null_outputs ();

  printf ("failures=%d\n", failures);
  return failures ? 1 : 0;
}

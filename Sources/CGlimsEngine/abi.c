/* The facade is header-only on the Swift side; the adapter library in
 * Engine/ implements it. This file only checks the header compiles as C. */
#include "glims_engine.h"

_Static_assert (GLIMS_ENGINE_API_VERSION == 1u, "update the Swift wrapper with the facade");

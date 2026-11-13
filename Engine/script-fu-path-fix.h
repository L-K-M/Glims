#pragma once

#include "core/core-types.h"

/* Install after gimp_initialize, before extension processes start. */
void glims_script_fu_path_fix_install (Gimp *gimp, const gchar *contents);

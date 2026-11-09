#ifndef GLIMS_RESOURCE_RENAME_H
#define GLIMS_RESOURCE_RENAME_H
#include "resource-mutation.h"
GlimsStatus glims_resource_rename_checked (GlimsEngine *engine, GlimsResourceID id,
                                            const char *expected_guard,
                                            const char *name, char **error);
#endif

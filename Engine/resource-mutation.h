#ifndef GLIMS_RESOURCE_MUTATION_H
#define GLIMS_RESOURCE_MUTATION_H
#include "resource-mutation-inspect.h"
/* Opaque equality guard for one observed native/file snapshot; not an
 * authorization credential or a guarantee against concurrent external writers. */
gchar *glims_resource_mutation_guard (const GlimsResourceMutationFacts *facts);
GlimsStatus glims_resource_delete_checked (GlimsEngine *engine, GlimsResourceID id,
                                            const char *expected_guard, char **error);
#endif

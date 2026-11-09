#ifndef GLIMS_RESOURCE_MUTATION_H
#define GLIMS_RESOURCE_MUTATION_H
#include "resource-mutation-inspect.h"
/* Opaque equality guard for one observed native/file snapshot; not an
 * authorization credential or a guarantee against concurrent external writers. */
GlimsStatus glims_resource_mutation_info (GlimsEngine *engine, GlimsResourceID id,
                                           uint32_t *flags, char **guard, char **reason,
                                           char **error);
gchar *glims_resource_mutation_guard (const GlimsResourceMutationFacts *facts);
GlimsStatus glims_resource_delete_checked (GlimsEngine *engine, GlimsResourceID id,
                                            const char *expected_guard, char **error);
#endif

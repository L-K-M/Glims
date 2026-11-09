#ifndef GLIMS_RESOURCE_MUTATION_INSPECT_H
#define GLIMS_RESOURCE_MUTATION_INSPECT_H
#include "engine-private.h"

/* Private engine-thread snapshot, never a durable authorship claim or a
 * permission to mutate later without fresh validation. */
enum {
  GLIMS_RESOURCE_MUTATION_RENAME = 1u << 0,
  GLIMS_RESOURCE_MUTATION_DELETE = 1u << 1
};
typedef struct {
  GimpData *data;                 /* strong, current factory member at inspection */
  GimpDataFactory *factory;       /* strong */
  GFile *file;                    /* strong, may be NULL */
  gchar *file_id, *etag, *reason;  /* owned, may be NULL */
  guint capabilities;
  gint64 native_mtime;
} GlimsResourceMutationFacts;

GlimsStatus glims_resource_mutation_inspect (GlimsEngine *engine, GlimsResourceID id,
                                             GlimsResourceMutationFacts **out,
                                             char **error);
void glims_resource_mutation_facts_free (GlimsResourceMutationFacts *facts);
#endif

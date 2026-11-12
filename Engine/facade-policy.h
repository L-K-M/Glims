#ifndef GLIMS_FACADE_POLICY_H
#define GLIMS_FACADE_POLICY_H
#include "engine-private.h"

typedef enum {
  GLIMS_FACADE_TARGET_NONE,
  GLIMS_FACADE_TARGET_IMAGE,
  GLIMS_FACADE_TARGET_FILTER,
  GLIMS_FACADE_TARGET_STROKE,
  GLIMS_FACADE_TARGET_ALL_IMAGES
} GlimsFacadeTargetKind;

typedef enum {
#define GLIMS_FACADE(name, wrapper, target, policy) GLIMS_FACADE_OP_##name,
#include "facade-operations.def"
#undef GLIMS_FACADE
  GLIMS_FACADE_OPERATION_COUNT
} GlimsFacadeOperation;

typedef struct {
  GlimsFacadeTargetKind kind;
  int32_t id;
  GlimsItemID sources[2];
} GlimsFacadeTarget;

/* Capture IDs only; their ownership is resolved on the serialized engine
 * thread immediately before the backend, for queued and inline calls alike. */
GlimsStatus glims_facade_call (GlimsEngine *engine, GlimsFacadeOperation operation,
                               GlimsFacadeTarget target, GlimsEngineFunc func,
                               gpointer data, char **error);
/* Reports whether the backend was invoked, even if it later fails. This lets
 * an overlapping output contract reset only transport/admission refusals. */
GlimsStatus glims_facade_call_reporting_admission (GlimsEngine *engine, GlimsFacadeOperation operation,
                                                   GlimsFacadeTarget target, GlimsEngineFunc func,
                                                   gpointer data, char **error, gboolean *invoked);
/* Inspect only the declared complete brush layout, and only source tools. */
GlimsItemID glims_facade_brush_source (const GlimsBrushSettings *settings);
GlimsFacadeTargetKind glims_facade_target_kind (GlimsFacadeOperation operation);
const char *glims_facade_operation_name (GlimsFacadeOperation operation);
#endif

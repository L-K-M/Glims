/* Forced only into a private engine.c compilation, never the harness. */
#ifndef GLIMS_TEST_CALL_ADMISSION_SHIMS_H
#define GLIMS_TEST_CALL_ADMISSION_SHIMS_H
#include <glib.h>
guint glims_test_call_admission_attach (GSource *source, GMainContext *context);
#endif

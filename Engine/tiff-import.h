#ifndef GLIMS_TIFF_IMPORT_H
#define GLIMS_TIFF_IMPORT_H

#include <gio/gio.h>

/* Prepare a local file for TIFF import. When source is a TIFF whose main
 * IFD chain mixes directories explicitly tagged NewSubfileType
 * FILETYPE_REDUCEDIMAGE with ordinary pages, *prepared receives a private
 * staged copy in which only the tagged directories were unlinked from the
 * chain; the unmodified native loader can then decode the copy. For
 * non-TIFF input, TIFFs without such mixed chains, and files without a
 * local path *prepared stays NULL and the caller proceeds with source
 * unchanged. source is never written. A staged copy remains valid until
 * glims_tiff_import_prepared_cleanup(). The caller also owns the returned
 * GFile reference and must unref it after cleanup. */
gboolean glims_tiff_import_prepare (GFile *source, GFile **prepared,
                                    GError **error);

/* Release a staged copy returned by glims_tiff_import_prepare(): removes
 * the file and its private staging directory. NULL, and files outside a
 * staging directory created by prepare, are ignored. Does not unref the
 * GFile object. */
void glims_tiff_import_prepared_cleanup (GFile *prepared);

#endif

# Resource mutation admission

This candidate manages explicitly selected user resource files. Native
writability is a capability, not proof that Glims created a file; UUID
filenames do not establish ownership. The initial policy admits known native
GBR/VBR/GIH/PAT/GGR resources only when Core marks them writable and deletable,
they are not internal, and their regular, nonsymlink file is directly in a
directory present in both the factory search and writable paths. Subdirectories
and unsaved, shared or stock resources remain read-only. Duplicate is available
for resources that cannot be changed in place.

`resource-mutation-inspect.c` returns owned native/file references and owned
identity strings, including a reason for ineligible current resources. A held
reference does not restore removed factory membership. These facts are an
engine-thread snapshot; every operation must resolve current membership and
reinspect it. They are not a durable authorship record or permission to mutate
later without validation. No public facade slot or management UI is added by
inspection alone.

The private observed-state guard hashes delimited native ID, current name,
file URI, native file identity and etag fields. It prevents an old confirmation
from deleting a replaced or changed file. It is an equality token, not an
authorization credential or a guarantee against concurrent external writers.

Checked Delete refuses active native work, ineligible files and stale guards
before mutation. It deletes the file while catalog membership and context
selection still exist. Only after disk success does it use the native factory
removal with disk deletion disabled. This avoids the convenience method's
remove-first failure behavior. A rare failure after successful disk removal
must be reported and reconciled; it is not an unchanged-state promise. Native
context fallback runs under the adapter busy gate to reject reentrant edits.
Resource deletion is outside image Undo and still needs explicit UI confirmation.

Inspection passes 50 private checks on each supported engine, including folder
boundaries, missing/directory/symlink files, exact byte preservation, context and
image/history invariance, and held native references after catalog removal. The
source review found no important issue. Checked Delete passes 28 checks per engine: an injected disk error preserves
file bytes, membership and context; a stale confirmation preserves a replacement
sentinel; success removes membership once under the reentry gate; open-image
pixels, facts and history remain unchanged. Rename passes 29 fault/PAT checks
and 87 format checks per engine: save/commit failures preserve the original,
an unwritable native staging association refuses before save, private file
permissions and extended attributes survive, and fresh native loaders preserve
known bitmap/pipe/generated-brush/pattern/gradient payloads and names.

The rename commit serializes an owned private copy into a unique directory under
the actual source parent, preserves file security and extended metadata through
macOS file-descriptor APIs, reinspects the observed guard, then atomically replaces
the local file. Only after that commit does the live name/clean state change.
No fsync or conditional concurrent-writer transaction is claimed. Source reviews
closed the staging-writability precondition finding; later runtime metadata fixes
were reviewed locally. Public facade wiring and management controls remain.

The stricter tests also forced a pending native RC autosave through engine exit,
reproducing an unrelated shutdown ordering assertion. That fix is isolated in
PR #123; the complete resource matrix passes against its fixed producers.

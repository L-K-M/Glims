# Measurement scripts

Research-grade scripts from round 2, kept as the starting point for the
interface diff described in [`../../plan.md`](../../plan.md). They read GIMP
sources and git history as text and never build or run GIMP code.

- `api-churn/`: the churn study. Parses engine headers per tag, finds the
  symbols GIMP's UI references, and diffs them across tags.
- `api-churn-recount/`: the reviewer's independent recount with a different
  parser.

They contain hard-coded paths under `/tmp/gimp-fork-research/` and expect a
bare blobless clone of GIMP there. Parameterize them before using them in CI.
Run Python scripts with `python3 -I`.

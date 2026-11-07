# Synthetic ai-workflow tracker

Made-up tickets in the frozen ai-workflow tracker's format, for the
importer's tests. Nothing here comes from a real tracker. Between them the
tickets use every frontmatter shape the frozen tracker uses, plus edge
cases: missing and unknown fields, empty lists, references to excluded,
missing and the same ticket, an unknown or absent status, no frontmatter,
no title heading, an empty body, non-ASCII text, and links to present,
missing and unrelated files. The tests exclude AIWF-0004.

# The brief

`brief` is the agent-owned named document holding a ticket's current handoff:
what a reader needs to act on it now. Comments and research notes may remain as
evidence, but must not be the only place to find the current decisions. An
older ticket may hold it as `implementation-brief`.

Update it before handing off and after every consequential answer from the
human. It covers:

- Goal, confirmed scope and explicit non-goals.
- Confirmed decisions and acceptance criteria, including relevant tests.
- Open decisions for the human, each with a recommendation and the condition
  that unblocks the work; say so explicitly when none remain.
- Technical choices left to the implementation rather than awaiting approval.
- The next action and how far work is authorized: investigation only,
  implementation, or waiting on a named decision. Cite the human instruction
  that sets this; the brief cannot grant authority by itself.
- Earlier proposals or restrictions it supersedes, and why, so that an
  obsolete "do not implement" is not left ambiguous.

Keep it concise and self-contained: link detailed research, typically in
`notes`, rather than accumulating a chronological transcript. When blocked,
record the blocker and its unblock condition, and update the brief and the
status together when it resolves.
